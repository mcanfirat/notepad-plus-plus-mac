// NPPBackupManager.mm — periodic snapshots, crash recovery and backup-on-save (see NPPBackupManager.h).
//
// HOW THE SAVE HOOK IS INSTALLED
// The "copy the previous version before it is overwritten" step has to run *inside* a save, and every save goes
// through -[NPPDocument saveToURL:error:] (File > Save and Save As both call it). This module may not edit
// NPPDocument, so it swizzles that one selector from +load, the same shape as NPPMacroManager's delegate
// forwarder. +selfCheckFailures fails loudly when the selector is gone, so the hook cannot rot in silence.
//
// WHAT IS NEVER DONE (this is data-loss prevention, so the negatives matter most)
//   * a snapshot is only ever written inside the backup folder — every write and delete is containment-checked,
//     so no buffer name, however hostile, can land on the user's own files;
//   * a snapshot is deleted only when its buffer was saved, closed, restored, or the app shut down cleanly;
//   * declining the restore prompt clears the index but leaves the snapshot files on disk;
//   * the index is written atomically, so a crash mid-write leaves the previous index intact.
#import "NPPBackupManager.h"
#import "NPPCommandLine.h"
#import "NPPDocument.h"
#import "NPPPreferences.h"
#import "NPPUtils.h"
#import <Scintilla/Scintilla.h>
#import <Scintilla/ScintillaView.h>
#import <objc/runtime.h>
#include <functional>
#include <string_view>

#pragma mark - Defaults keys / constants

static NSString *const kSnapshotEnabledKey  = @"NPPBackupSnapshotEnabled";
static NSString *const kSnapshotIntervalKey = @"NPPBackupSnapshotInterval";
static NSString *const kBackupModeKey       = @"NPPBackupMode";
static NSString *const kBackupDirectoryKey  = @"NPPBackupDirectory";

// Index entry keys (backup/index.plist is an array of these dictionaries).
static NSString *const kSnapshotKey = @"snapshot";   // file name inside the backup folder
static NSString *const kPathKey     = @"path";       // original file, absent for an untitled buffer
static NSString *const kNameKey     = @"name";       // buffer display name ("notes.txt", "new 1")
static NSString *const kModifiedKey = @"modified";   // when the snapshot was written

// The index file itself, version 2: a dictionary so the entries can be marked. Version 1 was the bare array and is
// still read — it can only have been left behind by a run that died, which is exactly what no marker means here.
static NSString *const kEntriesKey   = @"entries";
static NSString *const kCleanQuitKey = @"cleanQuit";   // YES == kept on purpose by a quit, not left behind by a crash

static NSString *const kIndexFileName = @"index.plist";
static NSString *const kVerboseSubdir = @"nppBackup";              // N++ fileSave() bak_verbose sub folder
static const NSTimeInterval kDefaultInterval = 7.0;                // N++ _snapshotBackupTiming = 7000 ms
static const NSTimeInterval kMinInterval = 1.0, kMaxInterval = 3600.0;
static const NSTimeInterval kPassThrottle = 1.0;                   // tab-switch snapshots no oftener than this
static const sptr_t kMaxSnapshotBytes = 64 * 1024 * 1024;          // N++ skips large files too (isLargeFile)

#pragma mark - Pure helpers

// A buffer name becomes part of a file name, so strip everything that could steer the path elsewhere.
static NSString *NPPBackupSanitizedName(NSString *name) {
    NSString *s = [(name ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"/\\:"];
    s = [[s componentsSeparatedByCharactersInSet:separators] componentsJoinedByString:@"_"];
    while ([s hasPrefix:@"."]) s = [s substringFromIndex:1];       // no ".." and no hidden files
    if (s.length > 100) s = [s substringToIndex:100];
    return s.length ? s : @"untitled";
}

// N++ writes wcsftime("%Y-%m-%d_%H%M%S") into both the snapshot and the verbose .bak name.
static NSString *NPPBackupTimestamp(NSDate *date) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd_HHmmss";
    });
    return [fmt stringFromDate:date ?: NSDate.date];   // main thread only (NSDateFormatter is not thread-safe)
}

// The real guard on every snapshot write, delete and restore: a snapshot name is one plain file name, never a path.
// This is a decision about the string alone — no filesystem semantics, nothing to get wrong on a symlinked volume —
// so it holds for names that came out of a hand-edited index just as well as for ones we generated.
static BOOL NPPBackupNameIsPlain(NSString *name) {
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) return NO;
    return [name rangeOfString:@"/"].location == NSNotFound && [name rangeOfString:@":"].location == NSNotFound;
}

// Second guard, in case the folder itself is ever passed in wrong.
// ponytail: lexical containment (URLByStandardizingPath resolves "..", not symlinks). The backup folder is ours and
// lives in Application Support; switch to URLByResolvingSymlinksInPath if snapshots ever move somewhere user-linked.
static BOOL NPPBackupURLIsInside(NSURL *url, NSURL *dir) {
    NSString *p = url.URLByStandardizingPath.path;
    NSString *d = dir.URLByStandardizingPath.path;
    if (!p.length || !d.length) return NO;
    if (![d hasSuffix:@"/"]) d = [d stringByAppendingString:@"/"];
    return p.length > d.length && [p hasPrefix:d];
}

// Decides whether a dirty buffer needs rewriting. The length is folded in so that skipping a needed write takes a
// 64-bit collision *at the same length*, not just a collision.
static unsigned long long NPPBackupHash(const char *bytes, size_t length) {
    std::string_view view(bytes ? bytes : "", bytes ? length : 0);
    return (unsigned long long)std::hash<std::string_view>{}(view) ^
           ((unsigned long long)length * 0x9E3779B97F4A7C15ULL);
}

// N++ NppIO.cpp loadSession(): with "Remember inaccessible files from a past session" on, a session entry whose
// file cannot be read becomes a placeholder buffer (newPlaceholderDocument) instead of being dropped — so a file
// on an unmounted volume is still in the session after the next quit. Which stored paths still need one, given
// what the window has already opened. `unreadable` answers "this path cannot be read": the filesystem in the app,
// a plain set in the self-check.
static NSArray<NSString *> *NPPBackupAbsentSessionPaths(NSArray<NSString *> *sessionPaths,
                                                        NSSet<NSString *> *openPaths,
                                                        BOOL (^unreadable)(NSString *)) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithSet:openPaths ?: [NSSet set]];
    for (NSString *p in sessionPaths) {
        if (!p.length || [seen containsObject:p] || !unreadable(p)) continue;
        [seen addObject:p];                 // a session may name the same file twice; one placeholder is enough
        [out addObject:p];
    }
    return out;
}

// What a buffer holds, as a string — the self-check's way of asking "did the text really come back?".
static NSString *NPPBackupTextOf(NPPDocument *doc) {
    std::string text = NPPSciGetText(doc.editor);
    return [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static NSTimeInterval NPPBackupClampInterval(NSTimeInterval v) {
    if (!(v > 0)) return kDefaultInterval;                          // 0, negative and NaN all mean "unset"
    return MIN(MAX(v, kMinInterval), kMaxInterval);
}

// make screenshot / exercise / typetest drive the real app headlessly: no timer and, above all, no modal restore
// prompt (it would block those runs), and no snapshots of throw-away test buffers in the user's backup folder.
static BOOL NPPBackupAutomatedRun(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    for (NSString *key in @[@"NPP_EXERCISE", @"NPP_EXERCISE_DIALOGS", @"NPP_SCREENSHOT", @"NPP_TYPETEST"])
        if (env[key]) return YES;
    return NO;
}

// The two things that must never run by themselves against the *user's* backup folder: the timer, and the launch
// restore. --selftest builds throw-away window controllers and each one posts the ready notification, so the
// silent clean-quit restore would adopt the user's real unsaved work into a controller nobody sees — and the next
// pass, over some later controller's documents, would then prune those files as stale. The checks drive both by
// hand over a scratch folder, so nothing is lost by standing down here; snapshot mode itself is deliberately NOT
// gated on this, because the checks have to be able to prove what a real quit does.
static BOOL NPPBackupHeadlessRun(void) {
    return NPPBackupAutomatedRun() || [NSProcessInfo.processInfo.arguments containsObject:@"--selftest"];
}

#pragma mark - Save hook

@interface NPPBackupManager ()
- (void)backupPreviousVersionOfFileAtURL:(NSURL *)url;
- (instancetype)initWithSnapshotDirectory:(nullable NSURL *)directory;   // nil = the real backup folder
- (void)persistIndex;
- (void)persistIndexCleanQuit:(BOOL)cleanQuit;
- (void)takeSnapshotPassOverDocuments:(NSArray<NPPDocument *> *)documents;
- (void)restorePendingAtLaunch;
- (void)applicationWillTerminate;
@end

// The one thing restore needs that id<NPPCommandContext> does not offer (see -newUntitledDocumentWithContext:).
@protocol NPPBackupHostNewDocument <NSObject>
- (NPPDocument *)newDocument;
@end

// NPPDocument posts NPPDocumentWillSaveNotification just before it writes; observing that is the whole hook.
// (This used to be a swizzle of -saveToURL:error: because the seam did not exist yet.)
static BOOL gSaveHookInstalled = NO;

// The context +selfCheckFailures hands the manager: enough of id<NPPCommandContext> to open a file, make an empty
// buffer and be told what happened. No window, on purpose — a check that reached the real restore prompt would put
// a modal alert on screen and never come back (gRestoreAnswerStub answers it, and counts it, instead).
@interface NPPBackupCheckContext : NSObject <NPPCommandContext, NPPBackupHostNewDocument>
@property (nonatomic, strong) NSMutableArray<NPPDocument *> *docs;
@end

#pragma mark - Manager

@implementation NPPBackupManager {
    __weak id<NPPCommandContext> _context;
    NSTimer *_timer;
    NSMutableDictionary<NSString *, NSDictionary *> *_index;      // live snapshots: file name -> index entry
    NSMutableArray<NSDictionary *> *_pending;                     // entries left behind by a crashed run
    NSMapTable<NPPDocument *, NSMutableDictionary *> *_docState;  // doc -> {snapshot name, hash of what was written}
    BOOL _restorePrompted;
    BOOL _passing;                                                // a snapshot pass is running (see -takeSnapshotsNow)
    NSDate *_lastPassDate;
    NSURL *_snapshotDirectoryOverride;                            // self-check only; nil = the real backup folder
    BOOL _pendingWasCleanQuit;                                    // the index we found says "kept on purpose", not "crashed"
    // Set by -snapshotDocumentsBeforeQuit: when it had to answer NO. The quit then asked about every dirty buffer,
    // so the snapshots are spent whatever the preference says: keeping them would resurrect, at the next launch, a
    // buffer the user just answered "Don't Save" to. NO by default, so a quit route that never asks keeps them.
    BOOL _quitPromptedInstead;
}

+ (void)load {
    @autoreleasepool {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentWillSave:)
                                                   name:NPPDocumentWillSaveNotification object:nil];
        gSaveHookInstalled = YES;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:(id)self selector:@selector(contextDidBecomeReady:)
                   name:NPPCommandContextReadyNotification object:nil];
        [nc addObserver:(id)self selector:@selector(currentDocumentDidChange:)
                   name:NPPCurrentDocumentDidChangeNotification object:nil];
        [nc addObserver:(id)self selector:@selector(applicationWillTerminate:)
                   name:NSApplicationWillTerminateNotification object:nil];
    }
}

+ (void)documentWillSave:(NSNotification *)note { [[self shared] documentWillSave:note]; }
+ (void)contextDidBecomeReady:(NSNotification *)note { [[self shared] attachToContext:note.object]; }
+ (void)currentDocumentDidChange:(NSNotification *)note { [[self shared] documentDidChange]; }
+ (void)applicationWillTerminate:(NSNotification *)note { [[self shared] applicationWillTerminate]; }

+ (instancetype)shared {
    static NPPBackupManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPBackupManager alloc] init]; });
    return s;
}

- (instancetype)init { return [self initWithSnapshotDirectory:nil]; }

// The directory is a parameter so +selfCheckFailures can drive a whole crashed-run/clean-shutdown cycle against a
// scratch folder. Nothing else passes one: the app only ever uses [NPPBackupManager shared].
- (instancetype)initWithSnapshotDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        _snapshotDirectoryOverride = directory;
        _index = [NSMutableDictionary dictionary];
        _docState = [NSMapTable weakToStrongObjectsMapTable];      // a closed document drops out by itself
        // An index left on disk is either a quit that kept its snapshots on purpose (snapshot mode: it says so) or a
        // run that never reached applicationWillTerminate at all — a crash. The marker is the whole difference, and
        // an index without one (every index older versions wrote) is read as the crash it was.
        BOOL clean = NO;
        _pending = [[NPPBackupManager indexEntriesAtURL:self.indexFileURL cleanQuit:&clean] mutableCopy];
        _pendingWasCleanQuit = clean;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *dir = self.snapshotDirectory;
        for (NSInteger i = (NSInteger)_pending.count - 1; i >= 0; i--) {   // drop entries whose file is gone
            NSURL *snap = [dir URLByAppendingPathComponent:_pending[(NSUInteger)i][kSnapshotKey]];
            if (![fm fileExistsAtPath:snap.path]) [_pending removeObjectAtIndex:(NSUInteger)i];
        }
    }
    return self;
}

#pragma mark Settings

- (BOOL)snapshotEnabled {
    NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:kSnapshotEnabledKey];
    return [n isKindOfClass:NSNumber.class] ? n.boolValue : YES;
}

- (void)setSnapshotEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSnapshotEnabledKey];
    [self rescheduleTimer];
}

- (NSTimeInterval)snapshotInterval {
    return NPPBackupClampInterval([NSUserDefaults.standardUserDefaults doubleForKey:kSnapshotIntervalKey]);
}

- (void)setSnapshotInterval:(NSTimeInterval)interval {
    [NSUserDefaults.standardUserDefaults setDouble:NPPBackupClampInterval(interval) forKey:kSnapshotIntervalKey];
    [self rescheduleTimer];
}

// N++ Parameters.h: isSnapshotMode() == _isSnapshotMode && _rememberLastSession && !_isCmdlineNosessionActivated.
// The single copy of the predicate: -applicationWillTerminate, the launch restore and (through
// -snapshotDocumentsBeforeQuit:) the window controller's quit prompt all ask this one method, so the three can
// never end up disagreeing about whether unsaved work is being kept.
- (BOOL)snapshotModeInForce {
    // An automated run takes no snapshots at all (see -attachToContext:), so it must never be told the unsaved work
    // is safe: whatever asks this falls back to what it did before there were snapshots.
    if (NPPBackupAutomatedRun()) return NO;
    if (!self.snapshotEnabled || !NPPPreferences.shared.rememberLastSession) return NO;
    // -nosession (implied by -quickPrint / -export=functionList): no session to come back to, so nothing is kept
    // across the quit and the prompt is the only thing standing between the user and a lost buffer.
    return [NPPCommandLine shouldSaveSessionOnQuit];
}

- (NPPBackupMode)backupMode {
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:kBackupModeKey];
    return (v >= NPPBackupModeNone && v <= NPPBackupModeVerbose) ? (NPPBackupMode)v : NPPBackupModeNone;
}

- (void)setBackupMode:(NPPBackupMode)mode {
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kBackupModeKey];
}

- (NSString *)customBackupDirectory {
    NSString *s = [NSUserDefaults.standardUserDefaults stringForKey:kBackupDirectoryKey];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s.stringByExpandingTildeInPath : nil;
}

- (void)setCustomBackupDirectory:(NSString *)dir {
    [NSUserDefaults.standardUserDefaults setObject:(dir ?: @"") forKey:kBackupDirectoryKey];
}

#pragma mark Directories

- (NSURL *)snapshotDirectory {
    if (_snapshotDirectoryOverride) return _snapshotDirectoryOverride;
    // A settings directory (-settingsDir=, or Preferences ▸ Cloud & Link) takes the whole configuration with it,
    // as N++'s _userPath does: backup/ goes inside it, and NPPEditorWindowController hangs session.xml off this
    // directory's parent — so the session travels with the settings rather than staying on this machine.
    NSString *settings = [NPPCommandLine effectiveSettingsDirectory];
    NSURL *base = settings.length
        ? [NSURL fileURLWithPath:settings isDirectory:YES]
        : [[NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                       appropriateForURL:nil create:NO error:NULL]
              URLByAppendingPathComponent:@"Notepad++"];
    return [base URLByAppendingPathComponent:@"backup"];
}

- (NSURL *)indexFileURL { return [self.snapshotDirectory URLByAppendingPathComponent:kIndexFileName]; }

- (NSUInteger)pendingRestoreCount { return _pending.count; }

#pragma mark File primitives (class methods: no window, no singleton state — the self-check drives these directly)

+ (BOOL)writeSnapshotData:(NSData *)data named:(NSString *)name inDirectory:(NSURL *)dir {
    if (!data || !dir || !NPPBackupNameIsPlain(name)) return NO;
    NSURL *url = [dir URLByAppendingPathComponent:name];
    if (!NPPBackupURLIsInside(url, dir)) return NO;                 // never outside the backup folder
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [data writeToURL:url options:NSDataWritingAtomic error:NULL];
}

+ (BOOL)removeSnapshotNamed:(NSString *)name inDirectory:(NSURL *)dir {
    if (!dir || !NPPBackupNameIsPlain(name)) return NO;
    NSURL *url = [dir URLByAppendingPathComponent:name];
    if (!NPPBackupURLIsInside(url, dir)) return NO;
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    return ![NSFileManager.defaultManager fileExistsAtPath:url.path];
}

// N++ fileSave(): custom directory wins for both modes; otherwise simple goes next to the file and verbose into
// a "nppBackup" sub folder next to it.
+ (NSURL *)backupDestinationForFileURL:(NSURL *)url mode:(NPPBackupMode)mode
                       customDirectory:(NSString *)customDir date:(NSDate *)date {
    if (mode == NPPBackupModeNone || !url.isFileURL || !url.lastPathComponent.length) return nil;
    NSString *name = url.lastPathComponent;
    NSURL *dir;
    if (customDir.length) {
        dir = [NSURL fileURLWithPath:customDir.stringByExpandingTildeInPath isDirectory:YES];
    } else {
        dir = url.URLByDeletingLastPathComponent;
        if (mode == NPPBackupModeVerbose) dir = [dir URLByAppendingPathComponent:kVerboseSubdir isDirectory:YES];
    }
    NSString *file = (mode == NPPBackupModeVerbose)
        ? [NSString stringWithFormat:@"%@.%@.bak", name, NPPBackupTimestamp(date)]
        : [NSString stringWithFormat:@"%@.bak", name];
    return [dir URLByAppendingPathComponent:file];
}

+ (BOOL)copyFileAtURL:(NSURL *)src toBackupURL:(NSURL *)dst error:(NSError **)error {
    if (!src.isFileURL || !dst.isFileURL) return NO;
    // The whole point is to preserve this file; a destination that resolves to it would destroy it instead.
    if ([src.URLByStandardizingPath.path isEqualToString:dst.URLByStandardizingPath.path]) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = dst.URLByDeletingLastPathComponent;
    if (![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    // Copy beside the destination, then rename over it. N++ copies straight onto the .bak; that turns a copy which
    // runs out of disk half way into a truncated backup sitting where the previous, complete one used to be — and a
    // .bak that looks valid and is not is worse than no .bak at all. The rename cannot fail that way.
    NSURL *tmp = [dir URLByAppendingPathComponent:
                  [NSString stringWithFormat:@".npp-bak-%@.tmp", NSUUID.UUID.UUIDString]];
    if (![fm copyItemAtURL:src toURL:tmp error:error]) { [fm removeItemAtURL:tmp error:NULL]; return NO; }
    [fm removeItemAtURL:dst error:NULL];                            // simple mode keeps one generation, like N++
    if ([fm moveItemAtURL:tmp toURL:dst error:error]) return YES;
    [fm removeItemAtURL:tmp error:NULL];
    return NO;
}

+ (NSData *)indexDataForEntries:(NSArray<NSDictionary *> *)entries { return [self indexDataForEntries:entries cleanQuit:NO]; }

+ (NSData *)indexDataForEntries:(NSArray<NSDictionary *> *)entries cleanQuit:(BOOL)cleanQuit {
    NSDictionary *index = @{kCleanQuitKey: @(cleanQuit), kEntriesKey: (entries ?: @[])};
    return [NSPropertyListSerialization dataWithPropertyList:index
                                                      format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

+ (NSArray<NSDictionary *> *)entriesFromIndexData:(NSData *)data { return [self entriesFromIndexData:data cleanQuit:NULL]; }

// Tolerant on purpose: a half-written or hand-edited index must degrade to "nothing to restore", never crash.
// Two shapes are accepted — the v2 dictionary, and the bare array v1 wrote, which carries no marker and so means
// what a leftover index has always meant: the previous run died. `cleanQuit` is NO for anything it cannot read.
+ (NSArray<NSDictionary *> *)entriesFromIndexData:(NSData *)data cleanQuit:(BOOL *)cleanQuit {
    if (cleanQuit) *cleanQuit = NO;
    if (!data.length) return @[];
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                          format:NULL error:NULL];
    NSArray *list = nil;
    if ([plist isKindOfClass:NSArray.class]) {
        list = plist;                                                   // v1: an index left behind by a crash
    } else if ([plist isKindOfClass:NSDictionary.class]) {
        id entries = ((NSDictionary *)plist)[kEntriesKey], flag = ((NSDictionary *)plist)[kCleanQuitKey];
        list = [entries isKindOfClass:NSArray.class] ? entries : nil;
        // `list &&`: an index whose entries do not parse is an index that does not parse, and one of those never
        // gets to claim it came from a clean quit.
        if (cleanQuit) *cleanQuit = list && [flag isKindOfClass:NSNumber.class] && [flag boolValue];
    }
    if (!list) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id item in list) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *snapshot = ((NSDictionary *)item)[kSnapshotKey];
        if (![snapshot isKindOfClass:NSString.class]) continue;
        if (!NPPBackupNameIsPlain(snapshot)) continue;   // not a plain name inside the folder ("..", "a/b", "")
        [out addObject:item];
    }
    return out;
}

+ (NSArray<NSDictionary *> *)indexEntriesAtURL:(NSURL *)url { return [self indexEntriesAtURL:url cleanQuit:NULL]; }

+ (NSArray<NSDictionary *> *)indexEntriesAtURL:(NSURL *)url cleanQuit:(BOOL *)cleanQuit {
    return [self entriesFromIndexData:[NSData dataWithContentsOfURL:url] cleanQuit:cleanQuit];
}

+ (BOOL)writeIndexEntries:(NSArray<NSDictionary *> *)entries toURL:(NSURL *)url {
    return [self writeIndexEntries:entries cleanQuit:NO toURL:url];
}

+ (BOOL)writeIndexEntries:(NSArray<NSDictionary *> *)entries cleanQuit:(BOOL)cleanQuit toURL:(NSURL *)url {
    if (!url) return NO;
    if (entries.count == 0) {                                        // nothing to come back to: no index at all
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
        return ![NSFileManager.defaultManager fileExistsAtPath:url.path];
    }
    NSData *data = [self indexDataForEntries:entries cleanQuit:cleanQuit];
    if (!data) return NO;
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    return [data writeToURL:url options:NSDataWritingAtomic error:NULL];   // atomic: a crash keeps the old index
}

- (void)persistIndex { [self persistIndexCleanQuit:NO]; }

// ponytail: one marker for the whole file, not one per entry — so entries a crash left pending, and that the user
// has not answered for yet, are marked clean too when this run quits in snapshot mode, and come back silently
// instead of behind the prompt. That keeps more, and asks less; give each entry its own flag if "you were asked
// about this one already" ever has to survive a quit.
- (void)persistIndexCleanQuit:(BOOL)cleanQuit {
    NSMutableArray<NSDictionary *> *all = [_pending mutableCopy];
    [all addObjectsFromArray:_index.allValues];   // pending entries stay until restored or declined
    [NPPBackupManager writeIndexEntries:all cleanQuit:cleanQuit toURL:self.indexFileURL];
}

#pragma mark Snapshots

- (NSString *)uniqueSnapshotNameForDocument:(NPPDocument *)doc {
    NSString *base = [NSString stringWithFormat:@"%@@%@",
                      NPPBackupSanitizedName(doc.displayName), NPPBackupTimestamp(NSDate.date)];
    NSString *name = base;
    NSURL *dir = self.snapshotDirectory;
    for (NSUInteger n = 2; _index[name] || [NSFileManager.defaultManager
                                            fileExistsAtPath:[dir URLByAppendingPathComponent:name].path]; n++)
        name = [NSString stringWithFormat:@"%@-%lu", base, (unsigned long)n];
    return name;
}

static NSDictionary *NPPBackupEntry(NPPDocument *doc, NSString *snapshot) {
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[kSnapshotKey] = snapshot;
    e[kNameKey] = doc.displayName ?: @"";
    e[kModifiedKey] = NSDate.date;
    if (doc.fileURL.path.length) e[kPathKey] = doc.fileURL.path;   // absent == untitled buffer
    return e;
}

// One pass: every dirty buffer whose text changed since its last snapshot is rewritten, and every snapshot whose
// buffer was saved or closed is dropped. ponytail: synchronous on the main thread, like N++'s backup timer — a
// changed multi-megabyte buffer costs one file write per pass; move the write off-thread if that ever shows up.
- (void)takeSnapshotsNow {
    id<NPPCommandContext> ctx = _context;
    if (!ctx) return;
    [self takeSnapshotPassOverDocuments:[ctx contextOpenDocuments]];
}

// The documents are a parameter so the quit can hand over exactly the buffers it is about to stop asking about
// (and so the self-check can drive a pass with no window at all).
- (void)takeSnapshotPassOverDocuments:(NSArray<NPPDocument *> *)documents {
    if (_passing || !self.snapshotEnabled) return;
    // Opening a buffer during a restore re-broadcasts NPPCurrentDocumentDidChangeNotification, which lands straight
    // back here; a pass running mid-restore would prune the very snapshots the restore has not adopted yet.
    _passing = YES;
    _lastPassDate = NSDate.date;

    NSURL *dir = self.snapshotDirectory;
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    BOOL changed = NO;

    for (NPPDocument *doc in documents) {
        ScintillaView *ed = doc.editor;
        if (!doc.isDirty || !ed) continue;
        NSMutableDictionary *state = [_docState objectForKey:doc];
        if (!state) {
            state = [@{kSnapshotKey: [self uniqueSnapshotNameForDocument:doc]} mutableCopy];
            [_docState setObject:state forKey:doc];
        }
        NSString *snapshot = state[kSnapshotKey];
        // Claimed before any early exit below: while a buffer is dirty, the snapshot it already has must never be
        // pruned out from under it — least of all because this pass decided not to *rewrite* it.
        [live addObject:snapshot];

        sptr_t length = NPPSci(ed, SCI_GETLENGTH);
        // ponytail: 64 MB, where N++ stops at its 200 MB large-file limit — a pass is synchronous on the main
        // thread, and a 200 MB write every 7 s is a visible stall. Raise it (or move the write off-thread) if
        // anyone actually edits files that size; the snapshot already taken is kept either way.
        if (length > kMaxSnapshotBytes) continue;

        // Read straight out of Scintilla's buffer (N++ backupCurrentBuffer does the same) — no copy of the
        // document per pass, and the hash lets an untouched buffer skip the write entirely.
        const char *chars = (const char *)NPPSci(ed, SCI_GETCHARACTERPOINTER);
        if (!chars) continue;
        unsigned long long hash = NPPBackupHash(chars, (size_t)length);
        if (_index[snapshot] && [state[@"hash"] unsignedLongLongValue] == hash) continue;   // nothing new to write
        NSData *data = [NSData dataWithBytesNoCopy:(void *)chars length:(NSUInteger)length freeWhenDone:NO];
        if (![NPPBackupManager writeSnapshotData:data named:snapshot inDirectory:dir]) continue;
        state[@"hash"] = @(hash);
        _index[snapshot] = NPPBackupEntry(doc, snapshot);
        changed = YES;
    }

    for (NSString *snapshot in _index.allKeys) {          // saved, closed, or otherwise no longer dirty
        if ([live containsObject:snapshot]) continue;
        [NPPBackupManager removeSnapshotNamed:snapshot inDirectory:dir];
        [_index removeObjectForKey:snapshot];
        changed = YES;
    }
    if (changed) [self persistIndex];
    _passing = NO;
}

// Is this buffer's snapshot on disk and byte for byte what the buffer holds? The hash is the one the pass writes,
// and it is only ever stored after a *successful* write — so a full disk, an unwritable backup folder or a buffer
// too large to snapshot all answer NO here, which is what stops the quit from skipping its prompt.
- (BOOL)snapshotIsCurrentForDocument:(NPPDocument *)doc {
    ScintillaView *ed = doc.editor;
    NSDictionary *state = [_docState objectForKey:doc];
    NSString *snapshot = [state[kSnapshotKey] isKindOfClass:NSString.class] ? state[kSnapshotKey] : nil;
    if (!ed || !snapshot || !_index[snapshot] || !state[@"hash"]) return NO;
    const char *chars = (const char *)NPPSci(ed, SCI_GETCHARACTERPOINTER);
    if (!chars) return NO;
    if ([state[@"hash"] unsignedLongLongValue] != NPPBackupHash(chars, (size_t)NPPSci(ed, SCI_GETLENGTH))) return NO;
    return [NSFileManager.defaultManager fileExistsAtPath:
            [self.snapshotDirectory URLByAppendingPathComponent:snapshot].path];
}

// N++ Notepad_plus::fileCloseAll(isSnapshotMode): with snapshots on, quitting asks about nothing at all — the
// buffers are written out and re-opened next time. Answering that here rather than in the window controller keeps
// the decision next to the files it depends on: this returns YES only when every dirty buffer really is on disk.
- (BOOL)snapshotDocumentsBeforeQuit:(NSArray<NPPDocument *> *)documents {
    BOOL covered = self.snapshotModeInForce;
    if (covered) {
        [self takeSnapshotPassOverDocuments:documents];
        for (NPPDocument *doc in documents)
            if (doc.isDirty && ![self snapshotIsCurrentForDocument:doc]) { covered = NO; break; }
    }
    _quitPromptedInstead = !covered;
    return covered;
}

- (void)rescheduleTimer {
    [_timer invalidate];
    _timer = nil;
    if (!_context || !self.snapshotEnabled || NPPBackupHeadlessRun()) return;
    NSTimeInterval interval = self.snapshotInterval;
    __weak __typeof__(self) weakSelf = self;
    // ponytail: one repeating timer that returns immediately when nothing is dirty, rather than start/stop
    // bookkeeping on every dirty transition — an idle pass is a loop over a handful of buffers.
    _timer = [NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
        [weakSelf takeSnapshotsNow];
    }];
    _timer.tolerance = interval / 4.0;
    // Common modes, not the default mode: otherwise snapshots stop for as long as a menu is tracking or a sheet is
    // up — exactly the stretches where a dirty buffer sits untouched and a crash costs the most.
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)documentDidChange {
    // N++ backs up on tab switches too (NppNotification.cpp). Throttled: this fires on every dirty/rename change.
    if (!_context) return;
    if (_lastPassDate && [NSDate.date timeIntervalSinceDate:_lastPassDate] < kPassThrottle) return;
    [self takeSnapshotsNow];
}

#pragma mark Lifecycle

- (void)attachToContext:(id<NPPCommandContext>)context {
    if (!context) return;
    _context = context;
    if (NPPBackupHeadlessRun()) return;
    [self rescheduleTimer];
    // Let the window finish coming up before a sheet lands on it — and, for the placeholders, before the window
    // controller and the app delegate have finished opening the readable half of the session.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restorePendingAtLaunch];
        [self openPlaceholdersForAbsentSessionFiles];
    });
}

// "Remember inaccessible files from a past session" (N++ _keepSessionAbsentFileEntries). The window controller and
// the app delegate open the session entries whose files are there and silently drop the rest; this puts the rest
// back as empty read-only buffers carrying the path, so the next quit writes them out again instead of forgetting
// them. Off by default, and never in a launch that did not restore the session at all.
- (void)openPlaceholdersForAbsentSessionFiles {
    NPPPreferences *prefs = NPPPreferences.shared;
    if (!prefs.keepSessionAbsentFileEntries || !prefs.rememberLastSession) return;
    if (![NPPCommandLine shouldRestoreSavedSession]) return;   // -nosession, or files named on the command line
    id<NPPCommandContext> ctx = _context;
    if (!ctx) return;

    NSMutableSet<NSString *> *open = [NSMutableSet set];
    for (NPPDocument *d in [ctx contextOpenDocuments]) if (d.fileURL.path) [open addObject:d.fileURL.path];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *absent = NPPBackupAbsentSessionPaths(prefs.sessionFilePaths, open,
                                                              ^BOOL(NSString *p) { return ![fm isReadableFileAtPath:p]; });
    if (!absent.count) return;

    NPPDocument *wasCurrent = [ctx contextCurrentDocument];   // each new buffer steals the selection
    NSInteger kept = 0;
    for (NSString *path in absent) {
        NPPDocument *doc = [self newUntitledDocumentWithContext:ctx];
        if (!doc) break;                                       // no -newDocument on this context: nothing to do
        doc.fileURL = [NSURL fileURLWithPath:path];
        // N++ gives a placeholder no content and no write: read-only says so, and its setter is also what tells
        // the tab strip the buffer just acquired a name.
        doc.isReadOnly = YES;
        kept++;
    }
    if (!kept) return;
    if (wasCurrent) [ctx contextSelectDocument:wasCurrent];
    [ctx contextReportStatus:[NSString stringWithFormat:
        NSLocalizedString(@"Kept %ld inaccessible file(s) from the last session", nil), (long)kept] isError:NO];
    [ctx contextRefreshUI];
}

- (void)applicationWillTerminate {
    [_timer invalidate];
    _timer = nil;
    // Snapshot mode: nothing was answered for on the way out (there was no prompt), so these snapshots are the only
    // copy of the unsaved work. One last pass — every quit route ends here, including the ones that never reach the
    // window controller — and then leave both the files and the index, marked as a quit that kept them on purpose.
    if (self.snapshotModeInForce && !_quitPromptedInstead) {
        id<NPPCommandContext> ctx = _context;
        if (ctx) [self takeSnapshotPassOverDocuments:[ctx contextOpenDocuments]];
        [self persistIndexCleanQuit:YES];
        return;
    }
    // Otherwise every dirty buffer was just answered for by the quit prompt (Save / Don't Save), so this run's
    // snapshots are spent. Clearing the index is what tells the next launch that the shutdown was clean.
    // ponytail: one running instance is assumed, as in N++ — give the index a per-instance name if the port ever
    // allows two windows' worth of app to run at once.
    NSURL *dir = self.snapshotDirectory;
    for (NSString *snapshot in _index.allKeys) [NPPBackupManager removeSnapshotNamed:snapshot inDirectory:dir];
    [_index removeAllObjects];
    // What is left is exactly what this run found and never consumed, so it keeps the marker it arrived with. A run
    // that kept nothing of its own — snapshots off, or -nosession — must not downgrade an earlier quit's clean-quit
    // index to a crash: that would greet the next launch with "Notepad++ did not shut down properly" about buffers
    // nothing ever crashed on, and there is no taking that back. _pending only ever shrinks, so one flag still
    // describes all of it.
    [self persistIndexCleanQuit:_pendingWasCleanQuit];
}

#pragma mark Restore

- (NPPDocument *)newUntitledDocumentWithContext:(id<NPPCommandContext>)ctx {
    // ponytail: id<NPPCommandContext> has no "give me an empty buffer", so ask the concrete context (the window
    // controller) for one. Add -contextNewDocument to the protocol when a second module needs it.
    // Declared (above) rather than reached through -performSelector:, which would hand ARC a +1 `new`-family result
    // it does not know to balance — one leaked document and its ScintillaView per restored untitled buffer.
    if (![(id)ctx respondsToSelector:@selector(newDocument)]) return nil;
    return [(id<NPPBackupHostNewDocument>)ctx newDocument];
}

// The window always comes up with an empty "new 1". N++ brings a restored untitled buffer back *as* that buffer
// rather than beside it, which is what "my unsaved new 1 was still there" looks like — and it is only ever an
// empty, never-edited one, so nothing can be overwritten. After the text goes in it is dirty, so the next entry
// in the same restore cannot adopt it too.
- (NPPDocument *)adoptableUntitledDocumentInContext:(id<NPPCommandContext>)ctx {
    for (NPPDocument *doc in [ctx contextOpenDocuments])
        if (doc.isUntitled && !doc.isDirty && doc.editor && NPPSci(doc.editor, SCI_GETLENGTH) == 0) return doc;
    return nil;
}

- (BOOL)restoreEntry:(NSDictionary *)entry context:(id<NPPCommandContext>)ctx {
    NSURL *dir = self.snapshotDirectory;
    NSString *snapshot = [entry[kSnapshotKey] isKindOfClass:NSString.class] ? entry[kSnapshotKey] : nil;
    if (!NPPBackupNameIsPlain(snapshot)) return NO;
    NSURL *snapURL = [dir URLByAppendingPathComponent:snapshot];
    if (!NPPBackupURLIsInside(snapURL, dir)) return NO;
    NSData *data = [NSData dataWithContentsOfURL:snapURL];
    if (!data) return NO;

    NSString *path = [entry[kPathKey] isKindOfClass:NSString.class] ? entry[kPathKey] : nil;
    NPPDocument *doc = nil;
    if (path.length && [NSFileManager.defaultManager fileExistsAtPath:path])
        doc = [ctx contextOpenFileURL:[NSURL fileURLWithPath:path]];
    // Untitled, or the file has since disappeared — either way the text must land somewhere, so an empty untitled
    // buffer is taken over if there is one and a fresh one made if there is not.
    if (!doc) doc = [self adoptableUntitledDocumentInContext:ctx] ?: [self newUntitledDocumentWithContext:ctx];
    ScintillaView *ed = doc.editor;
    if (!ed) return NO;
    // The file was deleted or renamed while the app was closed, so this snapshot is the only copy of it left. Give
    // the buffer its path back instead of dropping the text into an anonymous "new 1": the tab is still called what
    // the user called it, and the entry keeps naming the file if this has to happen again. Only for a path that is
    // really gone: a file that is there but would not open (unreadable, or a .session the context handled itself)
    // may already have a document somewhere, and two tabs claiming one path is its own bug. Nothing is overwritten
    // either way — -saveDocument: sends a buffer whose file is missing to Save As, on the right name and folder.
    if (path.length && !doc.fileURL && ![NSFileManager.defaultManager fileExistsAtPath:path])
        doc.fileURL = [NSURL fileURLWithPath:path];

    // Re-apply the snapshot on top of what was loaded and leave the buffer dirty — that is the whole point.
    // SCI_ADDTEXT is length-based (SCI_SETTEXT would stop at an embedded NUL), and the replacement stays one
    // undoable step, so Cmd-Z takes the user back to the version on disk.
    BOOL wasReadOnly = NPPSci(ed, SCI_GETREADONLY) != 0;
    if (wasReadOnly) NPPSci(ed, SCI_SETREADONLY, 0);
    NPPSci(ed, SCI_BEGINUNDOACTION);
    NPPSci(ed, SCI_CLEARALL);
    NPPSciStr(ed, SCI_ADDTEXT, (uptr_t)data.length, (const char *)data.bytes);
    NPPSci(ed, SCI_ENDUNDOACTION);
    if (wasReadOnly) NPPSci(ed, SCI_SETREADONLY, 1);

    // Adopt the snapshot instead of deleting it: the restored buffer keeps writing to the same file, so there is no
    // window in which a second crash would lose the text again.
    NSMutableDictionary *state = [@{kSnapshotKey: snapshot} mutableCopy];
    state[@"hash"] = @(NPPBackupHash((const char *)data.bytes, data.length));   // same formula as the pass, so the
                                                                                // next pass skips a pointless rewrite
    [_docState setObject:state forKey:doc];
    _index[snapshot] = NPPBackupEntry(doc, snapshot);
    return YES;
}

- (NSInteger)restorePendingWithContext:(id<NPPCommandContext>)context {
    id<NPPCommandContext> ctx = context ?: _context;
    if (!ctx) return 0;
    NSInteger restored = 0;
    // Opening a buffer re-broadcasts NPPCurrentDocumentDidChangeNotification, so a snapshot pass would otherwise run
    // in here, between two entries, with the index half-adopted — and the pruner in it deletes what it finds stale.
    _passing = YES;
    for (NSDictionary *entry in [_pending copy]) {
        if (![self restoreEntry:entry context:ctx]) continue;       // unreadable snapshot: stays pending, stays on disk
        [_pending removeObject:entry];
        restored++;
    }
    _passing = NO;
    [self persistIndex];
    [ctx contextRefreshUI];
    return restored;
}

// What the crash prompt would have answered, and that it was put up at all. Set only by +selfCheckFailures: the
// alert is modal, so a check that reached the real one would never return — and "no prompt at all" is precisely
// what the clean-quit restore has to prove.
static NSInteger gRestorePromptCount = 0;
static NSModalResponse (^gRestoreAnswerStub)(NSArray<NSDictionary *> *pending) = nil;

// The one thing the launch does with what the previous run left behind. Two endings, told apart by the index's own
// marker (see the header): a quit that kept its snapshots on purpose restores them silently, as part of the
// session the user is expecting back; a run that died still asks first.
- (void)restorePendingAtLaunch {
    if (_restorePrompted || _pending.count == 0) return;
    id<NPPCommandContext> ctx = _context;
    if (!ctx) return;
    if (_pendingWasCleanQuit) {
        // Kept on purpose, so there is nothing to announce and nothing to ask. Only where this launch is restoring
        // a session at all, though: under -nosession, or with the snapshot preference since switched off, they stay
        // on disk and stay in the index ("Restore Unsaved Documents" is one menu item away, and the next launch that
        // does restore a session brings them back). Never the crash prompt — that run did not crash.
        if (!self.snapshotModeInForce || ![NPPCommandLine shouldRestoreSavedSession]) return;
        _restorePrompted = YES;
        NSInteger n = [self restorePendingWithContext:ctx];
        if (n) [ctx contextReportStatus:[NSString stringWithFormat:
            NSLocalizedString(@"Restored %ld unsaved document(s) from the last session", nil), (long)n] isError:NO];
        return;
    }
    [self promptForRestore];
}

- (void)promptForRestore {
    id<NPPCommandContext> ctx = _context;
    if (!ctx) return;
    _restorePrompted = YES;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *e in _pending) {
        if (names.count == 5) { [names addObject:@"…"]; break; }
        [names addObject:[e[kNameKey] isKindOfClass:NSString.class] ? e[kNameKey] : e[kSnapshotKey]];
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:
                         NSLocalizedString(@"Notepad++ did not shut down properly. Restore %lu unsaved document(s)?", nil),
                         (unsigned long)_pending.count];
    alert.informativeText = [names componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:NSLocalizedString(@"Restore", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Not Now", nil)];

    __weak __typeof__(self) weakSelf = self;
    void (^handle)(NSModalResponse) = ^(NSModalResponse response) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (response == NSAlertFirstButtonReturn) {
            NSInteger n = [self_ restorePendingWithContext:self_->_context];
            [self_->_context contextReportStatus:[NSString stringWithFormat:
                NSLocalizedString(@"Restored %ld unsaved document(s) from the last session", nil), (long)n] isError:NO];
        } else {
            // Declined: forget them, but never delete them — "Open Backup Folder" is one menu item away.
            // ponytail: so declined snapshots pile up (N++ deletes them). An age-based sweep is the upgrade,
            // but deleting unseen unsaved work is exactly what this module exists to prevent, so: not yet.
            [self_->_pending removeAllObjects];
            [self_ persistIndex];
            [self_->_context contextReportStatus:
                NSLocalizedString(@"Unsaved snapshots kept in the backup folder", nil) isError:NO];
        }
        [self_->_context contextRefreshUI];
    };
    if (gRestoreAnswerStub) { gRestorePromptCount++; handle(gRestoreAnswerStub([_pending copy])); return; }
    NSWindow *window = [ctx contextWindow];
    if (window) [alert beginSheetModalForWindow:window completionHandler:handle];
    else handle([alert runModal]);
}

#pragma mark Backup on save (driven by NPPDocumentWillSaveNotification)

- (void)documentWillSave:(NSNotification *)note {
    NSURL *url = note.userInfo[@"url"];
    if ([url isKindOfClass:NSURL.class]) [self backupPreviousVersionOfFileAtURL:url];
}

- (void)backupPreviousVersionOfFileAtURL:(NSURL *)url {
    NPPBackupMode mode = self.backupMode;
    if (mode == NPPBackupModeNone || !url.isFileURL) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return;   // new file: no previous version
    NSURL *dst = [NPPBackupManager backupDestinationForFileURL:url mode:mode
                                               customDirectory:self.customBackupDirectory date:NSDate.date];
    NSError *err = nil;
    if (dst && ![NPPBackupManager copyFileAtURL:url toBackupURL:dst error:&err]) {
        // ponytail: N++ asks "save anyway?" in a modal here; a modal in the middle of a save is worse than a
        // status line, and refusing the save would be the bigger data loss. Report and let the save proceed.
        [_context contextReportStatus:[NSString stringWithFormat:
            NSLocalizedString(@"Backup failed: %@", nil), err.localizedDescription ?: dst.path] isError:YES];
    }
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    return cmd == NPPCmdBackupOpenFolder || cmd == NPPCmdBackupRestoreNow;
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    switch (cmd) {
        case NPPCmdBackupOpenFolder:  return YES;                              // the folder is created on demand
        case NPPCmdBackupRestoreNow:  return [self shared].pendingRestoreCount > 0 && context != nil;
        default:                      return NO;
    }
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (![self canPerformCommand:cmd context:context]) return NO;
    NPPBackupManager *m = [self shared];
    if (cmd == NPPCmdBackupOpenFolder) {
        NSURL *dir = m.snapshotDirectory;
        NSError *err = nil;
        if (dir) [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES
                                                         attributes:nil error:&err];
        if (!dir || ![NSWorkspace.sharedWorkspace openURL:dir])          // never fail silently
            [context contextReportStatus:[NSString stringWithFormat:NSLocalizedString(@"Could not open the backup folder: %@", nil),
                                          err.localizedDescription ?: dir.path ?: @"no Application Support folder"] isError:YES];
        return YES;
    }
    NSInteger n = [m restorePendingWithContext:context];
    [context contextReportStatus:[NSString stringWithFormat:
        NSLocalizedString(@"Restored %ld unsaved document(s)", nil), (long)n] isError:(n == 0)];
    return YES;
}

+ (NSString *)dynamicTitleForCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdBackupRestoreNow) return nil;
    NSUInteger n = [self shared].pendingRestoreCount;
    return n ? [NSString stringWithFormat:NSLocalizedString(@"Restore Unsaved Documents (%lu)", nil), (unsigned long)n]
             : NSLocalizedString(@"Restore Unsaved Documents", nil);
}

#pragma mark - Self check

// Headless: every check runs against a scratch directory, never the user's real backup folder or defaults.
+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *box = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                  [@"NPPBackupCheck-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    if (![fm createDirectoryAtURL:box withIntermediateDirectories:YES attributes:nil error:NULL])
        return @[@"could not create a scratch directory for the backup self-check"];
#define CHECK(cond, msg) do { if (!(cond)) [fails addObject:(msg)]; } while (0)

    // 1. a buffer name must never be able to point outside the backup folder
    NSString *safe = NPPBackupSanitizedName(@"../../etc/passwd");
    CHECK([safe rangeOfString:@"/"].location == NSNotFound && ![safe hasPrefix:@"."],
          ([NSString stringWithFormat:@"sanitized name still steers the path: \"%@\"", safe]));
    CHECK([NPPBackupSanitizedName(@"   ") isEqualToString:@"untitled"], @"an empty buffer name must become \"untitled\"");
    CHECK(NPPBackupNameIsPlain(@"new 1@2026-01-02_030405") && !NPPBackupNameIsPlain(@"..") &&
          !NPPBackupNameIsPlain(@".") && !NPPBackupNameIsPlain(@"a/b") && !NPPBackupNameIsPlain(@""),
          @"the snapshot-name guard lets through something that is not a plain file name");
    CHECK(NPPBackupURLIsInside([box URLByAppendingPathComponent:safe], box), @"a sanitized name landed outside the folder");
    CHECK(!NPPBackupURLIsInside([box URLByAppendingPathComponent:@"../escape"], box), @"containment check missed \"..\"");
    CHECK(!NPPBackupURLIsInside(box, box), @"the folder itself must not count as being inside it");

    NSData *probe = [@"unsaved text" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(![self writeSnapshotData:probe named:@"../escaped.txt" inDirectory:box],
          @"writeSnapshotData accepted a name that escapes the backup folder");
    CHECK(![fm fileExistsAtPath:[box URLByAppendingPathComponent:@"../escaped.txt"].path],
          @"a refused snapshot write still created a file outside the backup folder");
    CHECK(![self removeSnapshotNamed:@"../escaped.txt" inDirectory:box],
          @"removeSnapshotNamed accepted a name outside the backup folder");
    CHECK(![self removeSnapshotNamed:@".." inDirectory:box] && ![self writeSnapshotData:probe named:@".." inDirectory:box],
          @"\"..\" was accepted as a snapshot name");

    // 2. snapshot write / read back / prune
    NSString *snapName = @"note.txt@2026-01-02_030405";
    NSURL *snapURL = [box URLByAppendingPathComponent:snapName];
    CHECK([self writeSnapshotData:probe named:snapName inDirectory:box], @"could not write a snapshot");
    CHECK([[NSData dataWithContentsOfURL:snapURL] isEqualToData:probe], @"snapshot content did not survive the round trip");
    CHECK([self removeSnapshotNamed:snapName inDirectory:box] && ![fm fileExistsAtPath:snapURL.path],
          @"pruning a snapshot did not remove its file");

    // 3. N++'s timestamp shape, used by both snapshots and verbose .bak names
    NSDate *when = [NSDate dateWithTimeIntervalSince1970:1000000000];
    NSString *ts = NPPBackupTimestamp(when);
    CHECK([ts rangeOfString:@"^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$" options:NSRegularExpressionSearch].location == 0,
          ([NSString stringWithFormat:@"timestamp \"%@\" is not yyyy-MM-dd_HHmmss", ts]));

    // 4. backup-on-save destinations (N++ fileSave)
    NSURL *doc = [box URLByAppendingPathComponent:@"notes.txt"];
    CHECK([self backupDestinationForFileURL:doc mode:NPPBackupModeNone customDirectory:nil date:when] == nil,
          @"bak_none must not produce a backup destination");
    NSURL *simple = [self backupDestinationForFileURL:doc mode:NPPBackupModeSimple customDirectory:nil date:when];
    CHECK([simple.path isEqualToString:[doc.path stringByAppendingString:@".bak"]],
          ([NSString stringWithFormat:@"simple backup should be <file>.bak, got %@", simple.path]));
    NSURL *verbose = [self backupDestinationForFileURL:doc mode:NPPBackupModeVerbose customDirectory:nil date:when];
    NSString *wantVerbose = [[[box URLByAppendingPathComponent:kVerboseSubdir]
                              URLByAppendingPathComponent:[NSString stringWithFormat:@"notes.txt.%@.bak", ts]] path];
    CHECK([verbose.path isEqualToString:wantVerbose],
          ([NSString stringWithFormat:@"verbose backup should be %@, got %@", wantVerbose, verbose.path]));
    NSURL *custom = [self backupDestinationForFileURL:doc mode:NPPBackupModeVerbose customDirectory:box.path date:when];
    CHECK(([custom.path isEqualToString:[box URLByAppendingPathComponent:
                                         [NSString stringWithFormat:@"notes.txt.%@.bak", ts]].path]),
          @"a custom backup directory was not used");

    // 5. the .bak holds the version that was about to be overwritten, and the original is never touched
    [@"old" writeToURL:doc atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    CHECK([self copyFileAtURL:doc toBackupURL:simple error:NULL], @"backup copy failed");
    [@"new" writeToURL:doc atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    CHECK([[NSString stringWithContentsOfURL:simple encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"old"],
          @".bak does not hold the previous version of the file");
    CHECK([self copyFileAtURL:doc toBackupURL:simple error:NULL] &&
          [[NSString stringWithContentsOfURL:simple encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"new"],
          @"a second save did not refresh the simple .bak");
    CHECK(![self copyFileAtURL:doc toBackupURL:doc error:NULL] &&
          [[NSString stringWithContentsOfURL:doc encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"new"],
          @"a backup was allowed to overwrite the file it is protecting");

    // 6. the index: round trip, tolerant parse, and "cleared == clean shutdown"
    NSArray *entries = @[@{kSnapshotKey: @"a.txt@2026-01-02_030405", kNameKey: @"a.txt",
                           kPathKey: @"/tmp/a.txt", kModifiedKey: when},
                         @{kSnapshotKey: @"new 1@2026-01-02_030406", kNameKey: @"new 1", kModifiedKey: when}];
    NSArray *back = [self entriesFromIndexData:[self indexDataForEntries:entries]];
    CHECK(back.count == 2 && [back[0][kPathKey] isEqualToString:@"/tmp/a.txt"] &&
          back[1][kPathKey] == nil && [back[1][kNameKey] isEqualToString:@"new 1"],
          @"index entries did not survive the round trip (an untitled entry has no path)");
    CHECK([self entriesFromIndexData:[@"not a plist" dataUsingEncoding:NSUTF8StringEncoding]].count == 0,
          @"a corrupt index must parse as nothing to restore");
    CHECK([self entriesFromIndexData:nil].count == 0, @"a missing index must parse as nothing to restore");
    CHECK(([self entriesFromIndexData:[self indexDataForEntries:
            (NSArray *)@[@"junk", @{kNameKey: @"no snapshot key"}, @{kSnapshotKey: @"../evil"},
                         @{kSnapshotKey: @".."}, @{kSnapshotKey: @""}, @{kSnapshotKey: @42}]]].count == 0),
          @"malformed index entries were not rejected");

    NSURL *indexURL = [box URLByAppendingPathComponent:kIndexFileName];
    CHECK([self writeIndexEntries:entries toURL:indexURL] && [self indexEntriesAtURL:indexURL].count == 2,
          @"the index did not survive being written and read back");
    CHECK([self writeIndexEntries:@[] toURL:indexURL] && ![fm fileExistsAtPath:indexURL.path] &&
          [self indexEntriesAtURL:indexURL].count == 0,
          @"clearing the index (clean shutdown) did not remove the index file");

    // 7. settings clamp: a hand-edited interval must never stop the timer or spin it
    CHECK(NPPBackupClampInterval(0) == kDefaultInterval && NPPBackupClampInterval(-5) == kDefaultInterval &&
          NPPBackupClampInterval(0.01) == kMinInterval && NPPBackupClampInterval(1e9) == kMaxInterval &&
          NPPBackupClampInterval(7) == 7.0, @"snapshot interval clamping is wrong");

    // 8. the hash decides whether a dirty buffer's snapshot is rewritten — a constant one would freeze every
    //    snapshot at its first version.
    CHECK(NPPBackupHash("abc", 3) == NPPBackupHash("abc", 3) && NPPBackupHash("abc", 3) != NPPBackupHash("abd", 3) &&
          NPPBackupHash("ab", 2) != NPPBackupHash("ab\0", 3) && NPPBackupHash(NULL, 0) == NPPBackupHash("", 0),
          @"the content hash that decides whether to rewrite a snapshot is not doing its job");

    // 9. a full crashed-run cycle, on its own scratch folder: the index a dead run leaves behind is the only thing
    //    that tells the next launch there is unsaved work, and nothing may quietly drop it.
    NSURL *crashed = [box URLByAppendingPathComponent:@"crashed-run" isDirectory:YES];
    NSURL *crashedIndex = [crashed URLByAppendingPathComponent:kIndexFileName];
    NSString *aName = @"a.txt@2026-01-02_030405", *bName = @"new 1@2026-01-02_030406";
    [self writeSnapshotData:probe named:aName inDirectory:crashed];
    [self writeSnapshotData:probe named:bName inDirectory:crashed];
    [self writeIndexEntries:@[@{kSnapshotKey: aName, kNameKey: @"a.txt", kPathKey: @"/tmp/a.txt", kModifiedKey: when},
                              @{kSnapshotKey: bName, kNameKey: @"new 1", kModifiedKey: when},
                              @{kSnapshotKey: @"gone@2026-01-02_030407", kNameKey: @"gone", kModifiedKey: when}]
                      toURL:crashedIndex];

    NPPBackupManager *crashedRun = [[NPPBackupManager alloc] initWithSnapshotDirectory:crashed];
    CHECK(crashedRun.pendingRestoreCount == 2,
          ([NSString stringWithFormat:@"a leftover index should offer 2 restores (the third snapshot file is gone), got %lu",
            (unsigned long)crashedRun.pendingRestoreCount]));
    [crashedRun persistIndex];        // a snapshot pass while the prompt is still up
    CHECK([self indexEntriesAtURL:crashedIndex].count == 2,
          @"persisting the live index dropped the entries the crashed run left behind");
    [crashedRun applicationWillTerminate];   // quit with the restore still unanswered
    CHECK([fm fileExistsAtPath:[crashed URLByAppendingPathComponent:aName].path] &&
          [fm fileExistsAtPath:[crashed URLByAppendingPathComponent:bName].path],
          @"quitting deleted snapshots that had never been restored");
    CHECK([self indexEntriesAtURL:crashedIndex].count == 2,
          @"quitting cleared the crash marker while unrestored snapshots were still pending");

    // …and a run with nothing pending clears the marker on the way out: that is what "shut down cleanly" means.
    NSURL *clean = [box URLByAppendingPathComponent:@"clean-run" isDirectory:YES];
    NPPBackupManager *cleanRun = [[NPPBackupManager alloc] initWithSnapshotDirectory:clean];
    [cleanRun applicationWillTerminate];
    CHECK(cleanRun.pendingRestoreCount == 0 &&
          ![fm fileExistsAtPath:[clean URLByAppendingPathComponent:kIndexFileName].path],
          @"a clean shutdown must leave no index behind (a leftover one means \"we crashed\")");

    // 10. the two tags this module answers for, and nothing else
    CHECK([self handlesCommand:NPPCmdBackupOpenFolder] && [self handlesCommand:NPPCmdBackupRestoreNow] &&
          ![self handlesCommand:NPPCmdFileSave], @"handlesCommand: does not match exactly the two backup tags");

    // 11. without the save hook there is no backup on save at all
    CHECK(gSaveHookInstalled, @"the NPPDocumentWillSaveNotification backup hook is not installed");

    // 12. "Remember inaccessible files from a past session": exactly the entries the session restore dropped get a
    //     placeholder — never one that is already open (a second tab on the same file), never one that is readable
    //     (it was opened normally), and never two for the same path.
    {
        NSArray<NSString *> *stored = @[@"/gone/a.txt", @"/here/b.txt", @"/gone/a.txt", @"/open/c.txt", @""];
        NSSet<NSString *> *open = [NSSet setWithArray:@[@"/here/b.txt", @"/open/c.txt"]];
        BOOL (^missing)(NSString *) = ^BOOL(NSString *p) { return [p hasPrefix:@"/gone/"]; };
        NSArray<NSString *> *absent = NPPBackupAbsentSessionPaths(stored, open, missing);
        CHECK([absent isEqualToArray:@[@"/gone/a.txt"]],
              ([NSString stringWithFormat:@"absent session paths: got %@, want (/gone/a.txt)", absent]));
        CHECK(NPPBackupAbsentSessionPaths(stored, open, ^BOOL(NSString *p) { return NO; }).count == 0,
              @"a session whose files are all readable must produce no placeholders");
        CHECK(NPPBackupAbsentSessionPaths(@[], open, missing).count == 0 &&
              NPPBackupAbsentSessionPaths(stored, nil, missing).count == 1,
              @"absent session paths: an empty session, or no open documents, must not throw the rule off");
        // The property this pass is gated on has to be the one the Backup page writes, or the checkbox does nothing.
        CHECK(NPPPreferences.shared.keepSessionAbsentFileEntries ==
              [NSUserDefaults.standardUserDefaults boolForKey:@"NPPKeepSessionAbsentFileEntries"],
              @"keepSessionAbsentFileEntries does not read NPPKeepSessionAbsentFileEntries");
    }

    // 13. the settings directory takes backup/ (and, through its parent, session.xml) with it — otherwise the
    //     Cloud & Link page moves the preferences and silently leaves the session behind on this machine.
    {
        NSURL *cloud = [box URLByAppendingPathComponent:@"cloud" isDirectory:YES];
        [fm createDirectoryAtURL:cloud withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *effective = [NPPCommandLine effectiveSettingsDirectory];
        NSURL *dir = [[NPPBackupManager alloc] initWithSnapshotDirectory:nil].snapshotDirectory;
        NSString *wantParent = effective.length ? effective
                                                : [[fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                     appropriateForURL:nil create:NO error:NULL]
                                                      URLByAppendingPathComponent:@"Notepad++"].path;
        NSString *want = [wantParent stringByAppendingPathComponent:@"backup"].stringByStandardizingPath;
        CHECK([dir.path.stringByStandardizingPath isEqualToString:want],
              ([NSString stringWithFormat:@"snapshotDirectory is %@, want %@ (it must follow the settings directory)",
                dir.path, want]));
        CHECK([[NPPCommandLine settingsDirectoryFromCommandLine:cloud.path preferenceEnabled:NO preference:nil]
                  isEqualToString:cloud.path.stringByStandardizingPath],
              @"snapshotDirectory would not follow a -settingsDir= that names a real directory");
    }

    // 14. the marker that tells a quit which kept its snapshots from a run that died — and the old format, which
    //     has no marker and can only have come from a run that died.
    {
        BOOL clean = YES;
        NSData *v1 = [NSPropertyListSerialization dataWithPropertyList:entries
                                                                format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        CHECK([self entriesFromIndexData:v1 cleanQuit:&clean].count == 2 && !clean,
              @"a version-1 index (the bare array older versions wrote) must still read back, and still mean a crash");
        clean = NO;
        CHECK([self entriesFromIndexData:[self indexDataForEntries:entries cleanQuit:YES] cleanQuit:&clean].count == 2 && clean,
              @"the clean-quit marker did not survive the index round trip");
        clean = YES;
        CHECK([self entriesFromIndexData:[self indexDataForEntries:entries cleanQuit:NO] cleanQuit:&clean].count == 2 && !clean,
              @"an index written without the marker came back claiming a clean quit");
        clean = YES;
        CHECK([self entriesFromIndexData:[@"not a plist" dataUsingEncoding:NSUTF8StringEncoding] cleanQuit:&clean].count == 0 && !clean,
              @"a corrupt index must be nothing to restore, and must never claim a clean quit");
    }

    // 15. what the user actually asked for, driven end to end: two dirty buffers (one never saved, one a file with
    //     unsaved edits), a quit that asks nothing, a relaunch, and the text back — with no prompt anywhere. Then
    //     the same folder as a crash, which must still ask. Snapshot mode has to be in force for any of it, and
    //     that reads the user's own settings, so they are set here and put back at the end.
    {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        id savedEnabled = [ud objectForKey:kSnapshotEnabledKey];
        BOOL savedRemember = NPPPreferences.shared.rememberLastSession;
        [ud setBool:YES forKey:kSnapshotEnabledKey];
        NPPPreferences.shared.rememberLastSession = YES;

        NSURL *keptDir = [box URLByAppendingPathComponent:@"kept" isDirectory:YES];
        NSURL *editedURL = [box URLByAppendingPathComponent:@"edited.txt"];
        [@"on disk\n" writeToURL:editedURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NPPBackupManager *quitting = [[NPPBackupManager alloc] initWithSnapshotDirectory:keptDir];
        CHECK(quitting.snapshotModeInForce,
              @"the preference is on, the last session is remembered and there is no -nosession, "
              @"but snapshot mode is not in force");
        NPPPreferences.shared.rememberLastSession = NO;
        CHECK(!quitting.snapshotModeInForce,
              @"snapshot mode ignores \"remember the last session\": a quit would keep work no launch brings back");
        NPPPreferences.shared.rememberLastSession = YES;

        NPPDocument *untitled = [[NPPDocument alloc] initUntitled];
        NPPSciStr(untitled.editor, SCI_ADDTEXT, 8, "untitled");
        NPPDocument *editedDoc = [[NPPDocument alloc] initWithContentsOfURL:editedURL error:NULL];
        NPPSciStr(editedDoc.editor, SCI_INSERTTEXT, 0, "edited ");
        NSArray<NPPDocument *> *dirty = editedDoc ? @[untitled, editedDoc] : @[untitled];
        CHECK(editedDoc != nil && untitled.isDirty && editedDoc.isDirty,
              @"the clean-quit check could not produce the two dirty buffers it quits with");

        CHECK([quitting snapshotDocumentsBeforeQuit:dirty],
              @"snapshot mode is in force and both buffers were snapshotted, but the quit was still told to ask");
        [quitting applicationWillTerminate];                       // ⌘Q

        BOOL marker = NO;
        NSURL *keptIndex = [keptDir URLByAppendingPathComponent:kIndexFileName];
        CHECK([self indexEntriesAtURL:keptIndex cleanQuit:&marker].count == 2 && marker,
              @"quitting in snapshot mode must leave both snapshots behind, marked as a clean quit");

        // Relaunch: a fresh manager over the same folder, and the empty "new 1" every window comes up with.
        NPPBackupCheckContext *relaunch = [NPPBackupCheckContext new];
        NPPDocument *newOne = [relaunch newDocument];
        NPPBackupManager *relaunched = [[NPPBackupManager alloc] initWithSnapshotDirectory:keptDir];
        relaunched->_context = relaunch;
        CHECK(relaunched.pendingRestoreCount == 2,
              ([NSString stringWithFormat:@"the relaunch found %lu of the 2 buffers the quit kept",
                (unsigned long)relaunched.pendingRestoreCount]));
        gRestorePromptCount = 0;
        gRestoreAnswerStub = ^NSModalResponse(NSArray<NSDictionary *> *pending) { return NSAlertFirstButtonReturn; };
        [relaunched restorePendingAtLaunch];
        CHECK(gRestorePromptCount == 0,
              @"a quit that kept its snapshots on purpose still asked the next launch whether to restore them");
        CHECK(relaunched.pendingRestoreCount == 0, @"the silent restore left the buffers pending");

        NPPDocument *backUntitled = nil, *backFile = nil;
        for (NPPDocument *d in relaunch.docs) { if (d.fileURL) backFile = d; else backUntitled = d; }
        CHECK(backUntitled == newOne, @"the restored untitled buffer did not come back as the empty \"new 1\"");
        CHECK([NPPBackupTextOf(backUntitled) isEqualToString:@"untitled"],
              @"a buffer that had never been saved came back without its text");
        CHECK(backUntitled.isDirty, @"the restored untitled buffer came back clean: the next quit would drop it");
        CHECK([NPPBackupTextOf(backFile) isEqualToString:@"edited on disk\n"],
              ([NSString stringWithFormat:@"a saved file with unsaved edits came back as \"%@\", want the edits",
                NPPBackupTextOf(backFile)]));
        CHECK(backFile.isDirty, @"a restored file with unsaved edits came back clean, so the edits look saved");

        // The same two buffers left behind *without* the marker — a crash — still get asked about, which is also
        // what makes the "no prompt" checks above mean anything: this counter can go up.
        NSURL *diedDir = [box URLByAppendingPathComponent:@"died" isDirectory:YES];
        [self writeSnapshotData:probe named:@"new 1@2026-01-02_030405" inDirectory:diedDir];
        [self writeIndexEntries:@[@{kSnapshotKey: @"new 1@2026-01-02_030405", kNameKey: @"new 1", kModifiedKey: when}]
                      cleanQuit:NO toURL:[diedDir URLByAppendingPathComponent:kIndexFileName]];
        NPPBackupCheckContext *afterCrash = [NPPBackupCheckContext new];
        NPPBackupManager *crashed = [[NPPBackupManager alloc] initWithSnapshotDirectory:diedDir];
        crashed->_context = afterCrash;
        [crashed restorePendingAtLaunch];
        gRestoreAnswerStub = nil;
        CHECK(gRestorePromptCount == 1, @"an index with no clean-quit marker did not ask before restoring anything");
        CHECK(afterCrash.docs.count == 1 && [NPPBackupTextOf(afterCrash.docs.firstObject) isEqualToString:@"unsaved text"],
              @"answering the crash prompt with Restore did not bring the buffer back");

        // The file was deleted (or renamed) while the app was closed, so the snapshot is now the only copy of it
        // anywhere. It has to come back carrying the path it had — text alone, in an anonymous "new 1", makes the
        // user work out where it belonged before they can save it.
        NSURL *goneDir = [box URLByAppendingPathComponent:@"gone" isDirectory:YES];
        NSString *goneSnap = @"gone.txt@2026-01-02_030405";
        NSString *gonePath = [box URLByAppendingPathComponent:@"deleted-while-away.txt"].path;   // never created
        [self writeSnapshotData:probe named:goneSnap inDirectory:goneDir];
        [self writeIndexEntries:@[@{kSnapshotKey: goneSnap, kNameKey: @"gone.txt", kPathKey: gonePath, kModifiedKey: when}]
                      cleanQuit:YES toURL:[goneDir URLByAppendingPathComponent:kIndexFileName]];
        NPPBackupCheckContext *afterGone = [NPPBackupCheckContext new];
        NPPBackupManager *goneRun = [[NPPBackupManager alloc] initWithSnapshotDirectory:goneDir];
        goneRun->_context = afterGone;
        gRestorePromptCount = 0;
        gRestoreAnswerStub = ^NSModalResponse(NSArray<NSDictionary *> *pending) { return NSAlertFirstButtonReturn; };
        [goneRun restorePendingAtLaunch];
        gRestoreAnswerStub = nil;
        NPPDocument *goneBack = afterGone.docs.firstObject;
        CHECK(afterGone.docs.count == 1 && [NPPBackupTextOf(goneBack) isEqualToString:@"unsaved text"] &&
              goneBack.isDirty && [goneBack.fileURL.path isEqualToString:gonePath],
              ([NSString stringWithFormat:@"a snapshot whose file was deleted while the app was closed came back as "
                @"%lu buffer(s) named %@ holding \"%@\", want one dirty buffer at %@ holding its text",
                (unsigned long)afterGone.docs.count, goneBack.fileURL.path ?: @"(untitled)",
                NPPBackupTextOf(goneBack), gonePath]));
        CHECK(gRestorePromptCount == 0, @"restoring a clean quit's buffer whose file had gone put up the crash prompt");

        // A snapshot that cannot be written must never be mistaken for one that was: the quit falls back to asking.
        // "notes.txt" is a file (check 5), so a folder underneath it can never be created — a full disk in miniature.
        NPPBackupManager *doomed = [[NPPBackupManager alloc] initWithSnapshotDirectory:
                                    [[box URLByAppendingPathComponent:@"notes.txt"]
                                     URLByAppendingPathComponent:@"backup" isDirectory:YES]];
        CHECK(![doomed snapshotDocumentsBeforeQuit:dirty],
              @"the quit was told not to ask although the snapshots could not be written at all");

        // Snapshot mode off: the quit asks (as it always did), and this run's snapshots are spent — deleted, index
        // and all, on the way out. The pass runs with the preference still on so there is something to delete.
        NSURL *spentDir = [box URLByAppendingPathComponent:@"spent" isDirectory:YES];
        NPPBackupManager *spending = [[NPPBackupManager alloc] initWithSnapshotDirectory:spentDir];
        [spending takeSnapshotPassOverDocuments:dirty];
        CHECK([self indexEntriesAtURL:[spentDir URLByAppendingPathComponent:kIndexFileName]].count == 2,
              @"the snapshot pass wrote nothing for two dirty buffers");
        [ud setBool:NO forKey:kSnapshotEnabledKey];
        CHECK(!spending.snapshotModeInForce && ![spending snapshotDocumentsBeforeQuit:dirty],
              @"the snapshot preference is off but the quit was still told not to ask about the dirty buffers");
        [spending applicationWillTerminate];
        CHECK(![fm fileExistsAtPath:[spentDir URLByAppendingPathComponent:kIndexFileName].path] &&
              [fm contentsOfDirectoryAtPath:spentDir.path error:NULL].count == 0,
              @"with snapshot mode off, quitting must still delete this run's snapshots and its index");

        // …but a run that keeps nothing of its own (snapshots off here; -nosession is the same shape) must not
        // downgrade an *earlier* quit's clean-quit index to a crash on the way past it. Those buffers were kept on
        // purpose and nothing has answered for them yet, so the launch after this one still has to restore them
        // silently rather than open with "Notepad++ did not shut down properly".
        NSURL *throughDir = [box URLByAppendingPathComponent:@"passing-through" isDirectory:YES];
        NSURL *throughIndex = [throughDir URLByAppendingPathComponent:kIndexFileName];
        [self writeSnapshotData:probe named:bName inDirectory:throughDir];
        [self writeIndexEntries:@[@{kSnapshotKey: bName, kNameKey: @"new 1", kModifiedKey: when}]
                      cleanQuit:YES toURL:throughIndex];
        NPPBackupManager *passingBy = [[NPPBackupManager alloc] initWithSnapshotDirectory:throughDir];
        [passingBy applicationWillTerminate];
        BOOL stillClean = NO;
        CHECK([self indexEntriesAtURL:throughIndex cleanQuit:&stillClean].count == 1 && stillClean,
              @"a run that kept no snapshots of its own turned an earlier quit's clean-quit index into a crash: "
              @"the next launch would claim it did not shut down properly");
        CHECK([fm fileExistsAtPath:[throughDir URLByAppendingPathComponent:bName].path],
              @"a run that kept no snapshots of its own deleted an earlier quit's unsaved work");

        NPPPreferences.shared.rememberLastSession = savedRemember;
        if (savedEnabled) [ud setObject:savedEnabled forKey:kSnapshotEnabledKey];
        else [ud removeObjectForKey:kSnapshotEnabledKey];
    }

#undef CHECK
    [fm removeItemAtURL:box error:NULL];
    return fails;
}

@end

@implementation NPPBackupCheckContext

- (instancetype)init { if ((self = [super init])) _docs = [NSMutableArray array]; return self; }
- (NPPDocument *)contextCurrentDocument { return _docs.lastObject; }
- (NSArray<NPPDocument *> *)contextOpenDocuments { return [_docs copy]; }
- (NSWindow *)contextWindow { NSWindow *none = nil; return none; }   // no window: see the note on the interface

- (NPPDocument *)contextOpenFileURL:(NSURL *)url {
    for (NPPDocument *d in _docs) if ([d.fileURL.path isEqualToString:url.path]) return d;   // as a real tab does
    NPPDocument *doc = [[NPPDocument alloc] initWithContentsOfURL:url error:NULL];
    if (doc) [_docs addObject:doc];
    return doc;
}

- (NPPDocument *)newDocument {
    NPPDocument *doc = [[NPPDocument alloc] initUntitled];
    [_docs addObject:doc];
    return doc;
}

- (void)contextRevealFileURL:(NSURL *)url line:(NSInteger)line {}
- (void)contextSelectDocument:(NPPDocument *)doc {}
- (void)contextTogglePanel:(id<NPPPanel>)panel {}
- (void)contextShowPanel:(id<NPPPanel>)panel {}
- (BOOL)contextPanelIsVisible:(id<NPPPanel>)panel { return NO; }
- (void)contextRefreshUI {}
- (void)contextReportStatus:(NSString *)message isError:(BOOL)isError {}

@end
