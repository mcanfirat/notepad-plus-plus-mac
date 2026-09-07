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

#pragma mark - Save hook

@interface NPPBackupManager ()
- (void)backupPreviousVersionOfFileAtURL:(NSURL *)url;
- (instancetype)initWithSnapshotDirectory:(nullable NSURL *)directory;   // nil = the real backup folder
- (void)persistIndex;
- (void)applicationWillTerminate;
@end

// The one thing restore needs that id<NPPCommandContext> does not offer (see -newUntitledDocumentWithContext:).
@protocol NPPBackupHostNewDocument <NSObject>
- (NPPDocument *)newDocument;
@end

// NPPDocument posts NPPDocumentWillSaveNotification just before it writes; observing that is the whole hook.
// (This used to be a swizzle of -saveToURL:error: because the seam did not exist yet.)
static BOOL gSaveHookInstalled = NO;

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
        // An index left on disk means the previous run never reached applicationWillTerminate: a crash.
        _pending = [[NPPBackupManager indexEntriesAtURL:self.indexFileURL] mutableCopy];
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

+ (NSData *)indexDataForEntries:(NSArray<NSDictionary *> *)entries {
    return [NSPropertyListSerialization dataWithPropertyList:(entries ?: @[])
                                                      format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

// Tolerant on purpose: a half-written or hand-edited index must degrade to "nothing to restore", never crash.
+ (NSArray<NSDictionary *> *)entriesFromIndexData:(NSData *)data {
    if (!data.length) return @[];
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                          format:NULL error:NULL];
    if (![plist isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id item in (NSArray *)plist) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *snapshot = ((NSDictionary *)item)[kSnapshotKey];
        if (![snapshot isKindOfClass:NSString.class]) continue;
        if (!NPPBackupNameIsPlain(snapshot)) continue;   // not a plain name inside the folder ("..", "a/b", "")
        [out addObject:item];
    }
    return out;
}

+ (NSArray<NSDictionary *> *)indexEntriesAtURL:(NSURL *)url {
    return [self entriesFromIndexData:[NSData dataWithContentsOfURL:url]];
}

+ (BOOL)writeIndexEntries:(NSArray<NSDictionary *> *)entries toURL:(NSURL *)url {
    if (!url) return NO;
    if (entries.count == 0) {                                        // no index == the previous run ended cleanly
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
        return ![NSFileManager.defaultManager fileExistsAtPath:url.path];
    }
    NSData *data = [self indexDataForEntries:entries];
    if (!data) return NO;
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    return [data writeToURL:url options:NSDataWritingAtomic error:NULL];   // atomic: a crash keeps the old index
}

- (void)persistIndex {
    NSMutableArray<NSDictionary *> *all = [_pending mutableCopy];
    [all addObjectsFromArray:_index.allValues];   // pending entries stay until restored or declined
    [NPPBackupManager writeIndexEntries:all toURL:self.indexFileURL];
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
    if (!ctx || _passing || !self.snapshotEnabled) return;
    // Opening a buffer during a restore re-broadcasts NPPCurrentDocumentDidChangeNotification, which lands straight
    // back here; a pass running mid-restore would prune the very snapshots the restore has not adopted yet.
    _passing = YES;
    _lastPassDate = NSDate.date;

    NSURL *dir = self.snapshotDirectory;
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    BOOL changed = NO;

    for (NPPDocument *doc in [ctx contextOpenDocuments]) {
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

- (void)rescheduleTimer {
    [_timer invalidate];
    _timer = nil;
    if (!_context || !self.snapshotEnabled || NPPBackupAutomatedRun()) return;
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
    if (NPPBackupAutomatedRun()) return;
    [self rescheduleTimer];
    // Let the window finish coming up before a sheet lands on it — and, for the placeholders, before the window
    // controller and the app delegate have finished opening the readable half of the session.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self promptForRestoreIfNeeded];
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
    // Every dirty buffer was just answered for by the quit prompt (Save / Don't Save), so this run's snapshots are
    // spent. Clearing the index is what tells the next launch that the shutdown was clean.
    // ponytail: one running instance is assumed, as in N++ — give the index a per-instance name if the port ever
    // allows two windows' worth of app to run at once.
    NSURL *dir = self.snapshotDirectory;
    for (NSString *snapshot in _index.allKeys) [NPPBackupManager removeSnapshotNamed:snapshot inDirectory:dir];
    [_index removeAllObjects];
    [self persistIndex];
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
    if (!doc) doc = [self newUntitledDocumentWithContext:ctx];      // untitled, or the file has since disappeared
    ScintillaView *ed = doc.editor;
    if (!ed) return NO;

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

- (void)promptForRestoreIfNeeded {
    if (_restorePrompted || _pending.count == 0) return;
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

#undef CHECK
    [fm removeItemAtURL:box error:NULL];
    return fails;
}

@end
