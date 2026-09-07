// NPPCommandLine.mm — see header.
#import "NPPCommandLine.h"
#import "NPPCommands.h"
#import "NPPDocument.h"
#import "NPPEditorWindowController.h"
#import "NPPLanguageManager.h"
#import "NPPLocalization.h"
#import "NPPPreferences.h"
#import "NPPPrintRenderer.h"
#import "NPPUtils.h"
#import "NPPWorkspacePanel.h"
#include <fnmatch.h>
#include "Scintilla.h"

const NSInteger NPPCommandLineNoValue = NSNotFound;

// Pinned library versions for Debug Info, matching scintilla/version.txt (566) and lexilla/version.txt (553)
// in the Notepad++ checkout this app is built against. Neither library exposes its version at runtime.
// ponytail: two literals rather than a generated header — add -DNPP_SCINTILLA_VERSION='"x.y.z"' to APPFLAGS
// in the Makefile (from those two files) and these defaults stop being used.
#ifndef NPP_SCINTILLA_VERSION
#define NPP_SCINTILLA_VERSION "5.6.6"
#endif
#ifndef NPP_LEXILLA_VERSION
#define NPP_LEXILLA_VERSION "5.5.3"
#endif

// ---------------------------------------------------------------------------------------------------------------
// Switch tables. Every switch Notepad++ documents appears in exactly one of these, which is what stops a
// recognised switch from being opened as a file. The self-check walks them, so a switch added without a line in
// +usageText — or without a property to land in — fails the build's regression run.
// ---------------------------------------------------------------------------------------------------------------

// Exact match -> the NPPCommandLineOptions BOOL property it sets (via KVC).
static NSDictionary<NSString *, NSString *> *NPPFlagTable(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{ @"-multiInst": @"multiInstance",
               @"-nosession": @"noSession",
               @"-notabbar": @"noTabBar",
               @"-ro": @"readOnly",
               @"-fullReadOnly": @"fullReadOnly",
               @"-fullReadOnlySavingForbidden": @"savingForbidden",
               @"-alwaysOnTop": @"alwaysOnTop",
               @"-r": @"recursive",
               @"-openSession": @"openSession",
               @"-openFoldersAsWorkspace": @"openFoldersAsWorkspace",
               @"-monitor": @"monitor",
               @"-monitoringMode": @"monitoringMode",
               @"-quickPrint": @"quickPrint",
               @"-export=functionList": @"exportFunctionList",
               @"-notepadStyleCmdline": @"notepadStyleCmdline",
               @"-loadingTime": @"showLoadingTime",
               @"-noPlugin": @"noPlugin",
               @"-systemtray": @"systemTray",
               @"--help": @"displayHelp" };
    });
    return t;
}

// "-name=" prefix -> the NSString property that takes the rest of the token.
static NSDictionary<NSString *, NSString *> *NPPValueTable(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{ @"-settingsDir=": @"settingsDirectory",
               @"-titleAdd=": @"titleAdd",
               @"-udl=": @"udlName",
               @"-pluginMessage=": @"pluginMessage" };
    });
    return t;
}

// Single-letter switches carrying their value in the same token: "-n42", "-lcpp".
static NSDictionary<NSString *, NSString *> *NPPLetterTable(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{ @"-n": @"line", @"-c": @"column", @"-p": @"position", @"-x": @"left", @"-y": @"top",
               @"-l": @"languageName", @"-L": @"localizationCode" };
    });
    return t;
}
static BOOL NPPLetterIsNumeric(NSString *key) { return ![key isEqualToString:@"-l"] && ![key isEqualToString:@"-L"]; }

// Ghost typing (N++ easter eggs): "-qn=" / "-qt=" / "-qf=" name the source, "-qSpeed" the speed. Parsed below,
// played back by +startGhostTypingText:speed:context:.
static NSArray<NSString *> *NPPEasterEggPrefixes(void) { return @[@"-qn=", @"-qt=", @"-qf=", @"-qSpeed"]; }

// Recognised but not honoured by this port. One line each, surfaced through -unsupportedNotes.
static NSDictionary<NSString *, NSString *> *NPPUnsupportedTable(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{ @"-noPlugin": @"-noPlugin: this port has no plugin system, so there is nothing to skip; ignored.",
               @"-systemtray": @"-systemtray: macOS has no system tray; ignored.",
               @"-pluginMessage=": @"-pluginMessage=: this port has no plugin system; ignored.",
               @"-multiInst": @"-multiInst: macOS reuses the running app; launch a second copy with 'open -n Notepad++.app'. Ignored.",
               @"-export=functionList": @"-export=functionList: no headless function-list export in this port; ignored." };
    });
    return t;
}

// Arguments macOS itself adds. LaunchServices appends "-psn_0_<n>"; Xcode and the "Restore windows" machinery add
// "-NSxxx <value>" / "-Applexxx <value>" pairs, which NSUserDefaults reads out of the argument domain. None of them
// is ours and none is a file — swallow them silently rather than reporting them as unknown switches.
static BOOL NPPIsCocoaLaunchArgument(NSString *a, BOOL *takesValue) {
    *takesValue = NO;
    if ([a hasPrefix:@"-psn_"]) return YES;
    if ([a hasPrefix:@"-NS"] || [a hasPrefix:@"-Apple"]) { *takesValue = YES; return YES; }
    return NO;
}

// ---------------------------------------------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------------------------------------------

static NSString *NPPUnquote(NSString *s) {
    if (s.length >= 2 && [s hasPrefix:@"\""] && [s hasSuffix:@"\""]) return [s substringWithRange:NSMakeRange(1, s.length - 2)];
    return s;
}

static NSString *NPPAbsolutePath(NSString *arg) {
    NSString *p = arg.stringByExpandingTildeInPath;
    if (!p.isAbsolutePath) p = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:p];
    return p.stringByStandardizingPath;
}

static BOOL NPPHasWildcard(NSString *s) {
    static NSCharacterSet *glob;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ glob = [NSCharacterSet characterSetWithCharactersInString:@"*?["]; });
    return [s rangeOfCharacterFromSet:glob].location != NSNotFound;
}

// "-r": expand "dir/*.cpp" against the file system, walking subdirectories. Without -r only the named directory is
// read — which is also N++'s rule that -r is ignored unless the path holds a wildcard. fnmatch() does the matching,
// so ?, * and [] classes behave as in a shell; matching is case-insensitive, like the file systems macOS ships with.
static NSArray<NSURL *> *NPPMatchWildcard(NSString *path, BOOL recursive) {
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSString *pattern = path.lastPathComponent;
    if (!dir.length) dir = @"/";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names;
    if (recursive) {
        NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (NSString *rel in [fm enumeratorAtPath:dir]) [all addObject:rel];
        names = all;
    } else {
        names = [fm contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    }
    const char *pat = pattern.fileSystemRepresentation;
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    for (NSString *rel in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (fnmatch(pat, rel.lastPathComponent.fileSystemRepresentation, FNM_CASEFOLD) != 0) continue;
        NSString *full = [dir stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) [out addObject:[NSURL fileURLWithPath:full]];
    }
    return out;
}

// "-openSession": the argument is an N++ session XML; open the files it names.
// ponytail: files only — the view split, the caret positions and the per-file language recorded in the session are
// dropped. Upgrade path is a public -loadSessionAtURL: on NPPEditorWindowController (its -loadSession is private
// and starts with an NSOpenPanel, so there is nothing to reuse from here).
static NSArray<NSURL *> *NPPSessionFileURLs(NSString *path) {
    NSXMLDocument *xml = [[NSXMLDocument alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] options:0 error:NULL];
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    for (NSXMLNode *n in [xml nodesForXPath:@"//File" error:NULL]) {
        if (![n isKindOfClass:NSXMLElement.class]) continue;
        NSString *p = [(NSXMLElement *)n attributeForName:@"filename"].stringValue;
        if (p.length) [out addObject:[NSURL fileURLWithPath:NPPAbsolutePath(p)]];
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Ghost typing (-qn=, -qt=, -qf=, -qSpeed) — winmain.cpp getEasterEggNameFromParam/getGhostTypingSpeedFromParam
// and Notepad_plus.cpp threadTextPlayer. Notepad++ replays a text as if it were being typed; it is how the
// project demos itself.
// ---------------------------------------------------------------------------------------------------------------

// 1 slow, 2 fast, 3 instant. Everything else — absent, 0, 4, "x" — is 2, the speed threadTextPlayer() starts
// from before a quote overrides it. Upstream returns -1 for a bad -qSpeed and then falls back to the same value.
static NSInteger NPPGhostSpeed(NSInteger raw) { return (raw >= 1 && raw <= 3) ? raw : 2; }

// A command line argument cannot carry a real newline (on Windows it cannot even carry one inside quotes), so a
// multi-line -qt= is written with escapes. -qn= and -qf= name things, so only -qt= is unescaped.
// An unknown escape is left exactly as typed — a Windows path in the text ("c:\temp") must survive.
static NSString *NPPGhostUnescape(NSString *s) {
    if ([s rangeOfString:@"\\"].location == NSNotFound) return s;
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; ++i) {
        unichar c = [s characterAtIndex:i];
        if (c != '\\' || i + 1 >= s.length) { [out appendFormat:@"%C", c]; continue; }
        unichar next = [s characterAtIndex:++i];
        switch (next) {
            case 'n': [out appendString:@"\n"]; break;
            case 'r': [out appendString:@"\r"]; break;
            case 't': [out appendString:@"\t"]; break;
            case '\\': [out appendString:@"\\"]; break;
            default: [out appendFormat:@"\\%C", next]; break;
        }
    }
    return out;
}

// -qn=<name>. ponytail: this port's own scripts, not upstream's ~200 attributed quotations — the demo works, the
// quote table is not copied. Upgrade path: more entries in this dictionary, nothing else changes.
static NSDictionary<NSString *, NSString *> *NPPGhostBuiltIns(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{ @"hello": @"Hello, world!\n",
               @"npp": @"Notepad++ for macOS.\n"
                        "The same menus, the same shortcuts, the same Scintilla underneath.\n"
                        "No Wine, no virtual machine, no tray icon.\n",
               @"lorem": @"Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n"
                          "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n",
               @"tab": @"\tif (indented) {\n\t\tstillWorks();\n\t}\n" };
    });
    return t;
}

// Upstream's typing rhythm (Notepad_plus.cpp): a random 0..199 ms plus a table entry, a longer one after a space
// or a full stop, the whole thing divided by the speed. slow is x=1/y=1 (as written), fast x=2/y=1 (halved),
// instant x=1/y=0 (no wait at all).
// ponytail: the rhythm only. threadTextPlayer's second half — the "trolling" quotes it types and deletes again
// mid-sentence, and the quoter signature after the text — is not here, because both belong to the quote table
// this port does not carry. Upgrade path: a per-script flag in NPPGhostBuiltIns() and a second schedule of
// SCI_DELETEBACK steps run the same way.
static const int NPPGhostIntervalMs[] = {30, 30, 30, 30, 200};
static const int NPPGhostPauseMs[] = {200, 400, 600};
static const int NPPGhostMaxRange = 200;

// Pure, and separate from the schedule so the self-check can pin the formula at a chosen draw.
static NSTimeInterval NPPGhostDelay(unichar c, NSInteger speed, int ran) {
    if (NPPGhostSpeed(speed) == 3) return 0;
    int ms = (c == ' ' || c == '.') ? ran + NPPGhostPauseMs[ran % 3] : ran + NPPGhostIntervalMs[ran % 5];
    if (NPPGhostSpeed(speed) == 2) ms /= 2;
    return ms / 1000.0;
}

// One playback at a time. -qn=/-qt=/-qf= run once at startup, but a second start would interleave two texts into
// one buffer — and the flag is what the "already running" check reads.
static BOOL gGhostTyping = NO;

// The smallest context the player needs: a document to type into. Only +selfCheckFailures builds one — everything
// else in the app hands it the real NPPEditorWindowController — and without it the "already running" guard could
// not be exercised at all, because a start with no editor is refused before the guard is even reached.
@interface NPPGhostProbeContext : NSObject <NPPCommandContext>
@property (nonatomic, strong, nullable) NPPDocument *doc;
@end
@implementation NPPGhostProbeContext
- (NPPDocument *)contextCurrentDocument { return _doc; }
- (NSArray<NPPDocument *> *)contextOpenDocuments { return _doc ? @[_doc] : @[]; }
- (NSWindow *)contextWindow { NSWindow *none = nil; return none; }
- (NPPDocument *)contextOpenFileURL:(NSURL *)url { return nil; }
- (void)contextRevealFileURL:(NSURL *)url line:(NSInteger)line {}
- (void)contextSelectDocument:(NPPDocument *)doc {}
- (void)contextTogglePanel:(id<NPPPanel>)panel {}
- (void)contextShowPanel:(id<NPPPanel>)panel {}
- (BOOL)contextPanelIsVisible:(id<NPPPanel>)panel { return NO; }
- (void)contextRefreshUI {}
- (void)contextReportStatus:(NSString *)message isError:(BOOL)isError {}
@end

// ---------------------------------------------------------------------------------------------------------------
// Options object
// ---------------------------------------------------------------------------------------------------------------

@interface NPPCommandLineOptions ()
@property (nonatomic, copy) NSArray<NSURL *> *fileURLs;
@property (nonatomic, copy) NSArray<NSString *> *fileArguments;
@property (nonatomic, copy) NSArray<NSURL *> *folderURLs;
@property (nonatomic) BOOL multiInstance, noSession, noTabBar, readOnly, fullReadOnly, savingForbidden,
                           alwaysOnTop, recursive, openSession, openFoldersAsWorkspace, monitor, monitoringMode,
                           quickPrint, exportFunctionList, notepadStyleCmdline, showLoadingTime, noPlugin,
                           systemTray, displayHelp;
@property (nonatomic, copy, nullable) NSString *settingsDirectory, *titleAdd, *udlName, *languageName,
                                               *localizationCode, *pluginMessage;
@property (nonatomic) NSInteger line, column, position, left, top;
@property (nonatomic) NPPGhostTypingSource ghostTypingSource;
@property (nonatomic, copy, nullable) NSString *ghostTypingArgument;
@property (nonatomic) NSInteger ghostTypingSpeed;
@property (nonatomic, copy) NSArray<NSString *> *unrecognisedArguments;
@property (nonatomic, copy) NSArray<NSString *> *unsupportedNotes;
@property (nonatomic, copy) NSArray<NSString *> *ignoredArguments;
@end

@implementation NPPCommandLineOptions

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _fileURLs = _folderURLs = @[];
    _fileArguments = _unrecognisedArguments = _unsupportedNotes = _ignoredArguments = @[];
    _line = _column = _position = _left = _top = NPPCommandLineNoValue;
    _ghostTypingSource = NPPGhostTypingNone;
    _ghostTypingSpeed = NPPGhostSpeed(0);
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<NPPCommandLineOptions %lu file(s)%@%@>", (unsigned long)_fileURLs.count,
            _unrecognisedArguments.count ? @", unknown switches" : @"", _displayHelp ? @", --help" : @""];
}

@end

// ---------------------------------------------------------------------------------------------------------------

static NPPCommandLineOptions *gCurrent = nil;
static __weak id<NPPCommandContext> gContext = nil;
static NSDate *gLaunchStart = nil;
static NSNumber *gTabBarHiddenToRestore = nil;    // -notabbar must not persist into the next launch
static NSString *gUILanguageToRestore = nil;      // -L must not persist into the next launch either…
static NSString *gUILanguageApplied = nil;        // …but must not undo a language picked from the menu meanwhile
static BOOL gApplied = NO;                     // the startup options are applied to the first window only
static NSMutableDictionary<NSString *, NSWindow *> *gTextWindows = nil;
static NSString *gSettingsFile = nil;             // the settings directory's plist, once it is in charge of the domain
static NSString *gSettingsDirComplaint = nil;     // -settingsDir=/Cloud & Link named something unusable

// Puts back everything a switch overrode for this run. Runs from NSApplicationWillTerminateNotification *and*
// from atexit(): main.mm's debug hooks (NPP_SCREENSHOT, NPP_EXERCISE) leave through exit(), which posts no
// terminate notification, and a switch that survived into NSUserDefaults would silently become a setting.
// Both paths are idempotent — whichever runs first clears the pending values.
static void NPPRestoreCommandLineOverrides(void) {
    if (gTabBarHiddenToRestore) {
        NPPPreferences.shared.tabBarHidden = gTabBarHiddenToRestore.boolValue;
        gTabBarHiddenToRestore = nil;
    }
    if (gUILanguageToRestore) {
        // Only while -L is still what is showing: a language chosen from Settings ▸ UI Language during this run is
        // the user's setting now, and putting the pre-launch one back would silently throw their choice away.
        if ([NPPLocalization.shared.currentFileName isEqualToString:gUILanguageApplied])
            NPPLocalization.shared.currentFileName = gUILanguageToRestore;
        gUILanguageToRestore = gUILanguageApplied = nil;
    }
}

@interface NPPCommandLine ()
+ (void)applyToContext:(id<NPPCommandContext>)ctx;
+ (void)applyCaretToEditor:(ScintillaView *)ed;
+ (void)ghostTypePieces:(NSArray<NSString *> *)pieces schedule:(NSArray<NSNumber *> *)schedule
                  index:(NSUInteger)index document:(NPPDocument *)doc context:(id<NPPCommandContext>)ctx;
+ (void)quickPrintAndQuit:(id<NPPCommandContext>)ctx;
+ (NSURL *)configDirectory;
+ (NSSet<NSString *> *)pathSetOf:(NSArray<NSURL *> *)urls;
+ (void)showTextWindowNamed:(NSString *)key title:(NSString *)title text:(NSString *)text;
+ (void)copyTextWindowContents:(NSButton *)sender;
@end

@implementation NPPCommandLine

+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NPPCommandContextReadyNotification object:nil queue:nil
                                               usingBlock:^(NSNotification *note) {
        gContext = (id<NPPCommandContext>)note.object;
        // The context is published from the window controller's -init, before the delegate opens the command
        // line's files. Everything that needs those documents therefore waits one main-queue turn.
        dispatch_async(dispatch_get_main_queue(), ^{ [NPPCommandLine applyToContext:gContext]; });
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                                               usingBlock:^(NSNotification *note) { NPPRestoreCommandLineOverrides(); }];
    atexit(NPPRestoreCommandLineOverrides);
}

+ (NPPCommandLineOptions *)current {
    if (!gCurrent) gCurrent = [NPPCommandLineOptions new];
    return gCurrent;
}

#pragma mark - Parsing

+ (NPPCommandLineOptions *)parseArguments:(NSArray<NSString *> *)arguments {
    NPPCommandLineOptions *o = [NPPCommandLineOptions new];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSMutableArray<NSString *> *unknown = [NSMutableArray array];
    NSMutableArray<NSString *> *ignored = [NSMutableArray array];
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    NSMutableSet<NSString *> *noted = [NSMutableSet set];
    void (^note)(NSString *) = ^(NSString *key) {
        NSString *text = NPPUnsupportedTable()[key];
        if (text && ![noted containsObject:key]) { [noted addObject:key]; [notes addObject:text]; }
    };

    // N++ converts /p and /P to -quickPrint only when -notepadStyleCmdline is present anywhere on the line, so
    // that flag has to be known before the main pass. Only where it is still a switch, though: after "--" the
    // same text is a file name, and a file must not turn on a mode.
    NSUInteger switchCount = [arguments indexOfObject:@"--"];
    if (switchCount == NSNotFound) switchCount = arguments.count;
    BOOL notepadStyle = [[arguments subarrayWithRange:NSMakeRange(0, switchCount)] containsObject:@"-notepadStyleCmdline"];

    BOOL endOfSwitches = NO;    // after "--" every remaining argument is a file, even "-noPlugin"

    for (NSUInteger i = 0; i < arguments.count; ++i) {
        NSString *arg = arguments[i];
        if (endOfSwitches) { [files addObject:arg]; continue; }
        if ([arg isEqualToString:@"--"]) { endOfSwitches = YES; continue; }
        // "-z": ignore the next argument outright, whatever it looks like (the Notepad replacement syntax puts
        // the path of the notepad.exe it replaced there). A trailing "-z" has nothing to swallow.
        if ([arg isEqualToString:@"-z"]) { if (i + 1 < arguments.count) [ignored addObject:arguments[++i]]; continue; }
        if (notepadStyle && ([arg isEqualToString:@"/p"] || [arg isEqualToString:@"/P"])) { o.quickPrint = YES; continue; }

        if (NSString *prop = NPPFlagTable()[arg]) {
            [o setValue:@YES forKey:prop];
            note(arg);
            continue;
        }
        BOOL takesValue = NO;
        if (NPPIsCocoaLaunchArgument(arg, &takesValue)) {
            // Only eat the value when there is one that is not itself a switch, so "-NSFoo file.txt" still opens
            // the file if macOS ever passes a valueless key.
            if (takesValue && i + 1 < arguments.count && ![arguments[i + 1] hasPrefix:@"-"]) ++i;
            continue;
        }

        NSString *matched = nil;
        for (NSString *prefix in NPPValueTable()) {
            if (![arg hasPrefix:prefix]) continue;
            [o setValue:NPPUnquote([arg substringFromIndex:prefix.length]) forKey:NPPValueTable()[prefix]];
            note(prefix);
            matched = prefix;
            break;
        }
        if (matched) continue;
        for (NSString *prefix in NPPEasterEggPrefixes()) {
            if (![arg hasPrefix:prefix]) continue;
            NSString *value = NPPUnquote([arg substringFromIndex:prefix.length]);
            if ([prefix isEqualToString:@"-qSpeed"]) {
                // Upstream's switch carries the digit with no separator ("-qSpeed1"); "=" is accepted too because
                // every other value-carrying switch here uses one and the mistake is otherwise silent.
                if ([value hasPrefix:@"="]) value = [value substringFromIndex:1];
                o.ghostTypingSpeed = NPPGhostSpeed(value.integerValue);       // 0 for "x" -> the default, as upstream
            } else if (o.ghostTypingSource == NPPGhostTypingNone) {
                // Only one text can be played, so the first source on the line wins. (Upstream prefers -qn= over
                // -qt= over -qf= wherever they sit; giving two at once is a typo either way.)
                o.ghostTypingSource = [prefix isEqualToString:@"-qn="] ? NPPGhostTypingBuiltIn
                                    : [prefix isEqualToString:@"-qt="] ? NPPGhostTypingText : NPPGhostTypingFile;
                if (o.ghostTypingSource == NPPGhostTypingText) value = NPPGhostUnescape(value);
                if (o.ghostTypingSource == NPPGhostTypingFile) value = NPPAbsolutePath(value);
                o.ghostTypingArgument = value;
            }
            matched = prefix;
            break;
        }
        if (matched) continue;

        // Single-letter switches carrying their value: checked last so "-nosession" and "-pluginMessage=" win.
        if (arg.length > 2 && [arg hasPrefix:@"-"]) {
            NSString *key = [arg substringToIndex:2];
            if (NSString *prop = NPPLetterTable()[key]) {
                NSString *value = [arg substringFromIndex:2];
                if (!NPPLetterIsNumeric(key)) {
                    [o setValue:NPPUnquote(value) forKey:prop];
                    note(key);
                    continue;
                }
                NSScanner *scanner = [NSScanner scannerWithString:value];
                long long n = 0;
                if ([scanner scanLongLong:&n] && scanner.isAtEnd) { [o setValue:@(n) forKey:prop]; continue; }
                [unknown addObject:arg];   // "-nfoo": a malformed switch, never a file called "-nfoo"
                continue;
            }
        }

        // A bare "-" is the conventional name for standard input, not a switch; everything else that starts with
        // a dash is a switch this build does not know, and must not be opened as a document.
        if (arg.length > 1 && [arg hasPrefix:@"-"]) { [unknown addObject:arg]; continue; }
        [files addObject:arg];
    }

    // ponytail: -fullReadOnlySavingForbidden only implies -fullReadOnly here; the extra strictness (Edit ▸ Toggle
    // Read-Only stays locked out) is not enforced, so the buffers open read-only but the user can still unlock them.
    // Upgrade path: a flag NPPEditorWindowController consults in its NPPCmdEditToggleReadOnly validation.
    if (o.savingForbidden) o.fullReadOnly = YES;              // the stricter flag implies the weaker one
    if (o.notepadStyleCmdline) { o.multiInstance = YES; o.noTabBar = YES; o.noSession = YES; }   // winmain.cpp
    if (o.quickPrint || o.exportFunctionList) { o.multiInstance = YES; o.noSession = YES; }      // ditto: stay silent

    // Expand the file arguments once, here, so every caller sees the same list.
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableArray<NSURL *> *folders = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *arg in files) {
        if (!arg.length) continue;              // upstream skips those too (winmain.cpp: `if (currentFile[0])`);
                                                // without this an empty argument resolves to the working directory
        NSString *path = NPPAbsolutePath(arg);
        NSArray<NSURL *> *expanded;
        BOOL isDir = NO;
        if (NPPHasWildcard(path)) {
            expanded = NPPMatchWildcard(path, o.recursive);
        } else if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
            if (![seen containsObject:path]) { [seen addObject:path]; [folders addObject:[NSURL fileURLWithPath:path isDirectory:YES]]; }
            continue;                                          // a directory is never a document
        } else if (o.openSession) {
            expanded = NPPSessionFileURLs(path);
        } else {
            expanded = @[[NSURL fileURLWithPath:path]];
        }
        for (NSURL *u in expanded)
            if (![seen containsObject:u.path]) { [seen addObject:u.path]; [urls addObject:u]; }
    }

    o.fileArguments = files;
    o.fileURLs = urls;
    o.folderURLs = folders;
    o.unrecognisedArguments = unknown;
    o.unsupportedNotes = notes;
    o.ignoredArguments = ignored;
    return o;
}

#pragma mark - Startup

+ (void)applyProcessArguments:(NSArray<NSString *> *)processArguments {
    gLaunchStart = [NSDate date];   // close enough to process start: main() calls this before anything is shown
    NSArray<NSString *> *args = processArguments.count > 1
        ? [processArguments subarrayWithRange:NSMakeRange(1, processArguments.count - 1)] : @[];
    gCurrent = [self parseArguments:args];
    // Before anything reads a setting: -settingsDir= (and Preferences ▸ Cloud & Link) decide which preference
    // domain this launch runs on, so they have to be in place while main() is still the only thing running.
    [self applySettingsDirectory];
    if (gSettingsDirComplaint) fprintf(stderr, "Notepad++: %s\n", gSettingsDirComplaint.UTF8String);

    for (NSString *n in gCurrent.unsupportedNotes) fprintf(stderr, "Notepad++: %s\n", n.UTF8String);
    for (NSString *bad in gCurrent.unrecognisedArguments)
        fprintf(stderr, "Notepad++: unknown option \"%s\" — see Help > Command Line Arguments.\n", bad.UTF8String);
    if (gCurrent.displayHelp) fputs([self usageText].UTF8String, stdout);   // useful when launched from a terminal
}

// The session decisions, answered here rather than in the app delegate so the switch and the rule that reads it
// stay in one file — and so the self-check can exercise them without a running app.
+ (BOOL)shouldRestoreSavedSession {
    // Files on the command line replace the session, exactly as a double-clicked document does upstream.
    return ![self current].noSession && [self current].fileURLs.count == 0;
}

+ (BOOL)shouldSaveSessionOnQuit { return ![self current].noSession; }

#pragma mark - Settings directory (-settingsDir= / Preferences ▸ Cloud & Link)

// One file, named after the app so a directory shared with a Windows Notepad++ (config.xml, session.xml) stays
// readable to both.
// ponytail: NSUserDefaults cannot be pointed at another file, so the directory's plist is loaded over the
// preference domain at launch and the domain is mirrored back to it on every change — the local plist keeps a
// copy of whatever the directory last held. It is a mirror, not a move; two machines writing the same synced
// directory at the same time still overwrite each other, exactly as N++'s config.xml does. Upgrade path: a
// preferences layer of our own reading and writing that plist directly, which means owning NPPPreferences.
//
// ponytail: it carries what this file can reach — the whole preference domain (so every NPP* setting and the
// flat session list) plus NPPBackupManager's backup/ and the session.xml hung off it. The theme and
// user-defined-language folders under ~/Library/Application Support/Notepad++ stay put, because the code that
// builds those paths lives in NPPPreferences.mm and NPPUserDefinedLanguages.mm. Upgrade path: one shared
// "config directory" accessor (+configDirectory below is already it) that those two call instead of rebuilding
// the Application Support path themselves.
static NSString *const kSettingsFileName = @"Notepad++.plist";

static BOOL NPPPathIsDirectory(NSString *path) {
    BOOL isDir = NO;
    return path.length && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

// May this file stand in for the preference domain? Loading it REPLACES the domain, so nil (unreadable, corrupt,
// still syncing) and an empty-but-valid plist both have to be refused: an empty dictionary would silently wipe
// every setting the user has, and no configuration this app has ever written is empty — it seeds the file itself.
static BOOL NPPSettingsDomainIsUsable(NSDictionary *stored) { return stored.count > 0; }

+ (NSString *)settingsDirectoryFromCommandLine:(NSString *)commandLineValue
                             preferenceEnabled:(BOOL)enabled
                                    preference:(NSString *)preferenceValue {
    // N++ Parameters.cpp: -settingsDir= is the 1st priority, the cloud path the 2nd, and a path that is not a
    // directory is reported and ignored — never created, because a typo would then quietly start a fresh config.
    // "Read and write the settings in this directory" with no directory named does nothing at all; say so rather
    // than leaving the radio button looking as though it took.
    if (enabled && !preferenceValue.length && !commandLineValue.length)
        gSettingsDirComplaint = @"No settings directory is named; the settings stay with the user account.";
    for (NSString *candidate in @[commandLineValue ?: @"", (enabled ? preferenceValue : nil) ?: @""]) {
        if (!candidate.length) continue;
        NSString *path = NPPAbsolutePath(candidate);
        if (NPPPathIsDirectory(path)) return path;
        gSettingsDirComplaint = [NSString stringWithFormat:
            @"Settings directory \"%@\" is not a directory; the settings stay with the user account.", candidate];
    }
    return nil;
}

+ (NSString *)effectiveSettingsDirectory {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NPPPreferences *p = NPPPreferences.shared;
        dir = [self settingsDirectoryFromCommandLine:[self current].settingsDirectory
                                   preferenceEnabled:p.settingsDirectoryEnabled
                                          preference:p.settingsDirectory];
    });
    return dir;
}

// Everything the app has ever written: NSUserDefaults' own persistent domain for this bundle, which is exactly
// what the plist in the settings directory has to hold for the redirection to be complete.
+ (NSString *)settingsDomainName { return NSBundle.mainBundle.bundleIdentifier; }

+ (void)writeSettingsDirectoryFile {
    NSString *suite = [self settingsDomainName];
    if (!gSettingsFile || !suite.length) return;
    NSDictionary *domain = [NSUserDefaults.standardUserDefaults persistentDomainForName:suite] ?: @{};
    NSError *err = nil;
    if (![domain writeToURL:[NSURL fileURLWithPath:gSettingsFile] error:&err])
        fprintf(stderr, "Notepad++: could not write %s: %s\n", gSettingsFile.UTF8String,
                err.localizedDescription.UTF8String ?: "unknown error");
}

// Coalesced: NSUserDefaultsDidChangeNotification fires on every keystroke in a preferences text field.
// ponytail: half a second, and the whole domain is rewritten each time — a few tens of KB, which is nothing next
// to the sync the directory is usually inside. Upgrade path: diff the domain and skip the write when nothing the
// app owns actually changed.
+ (void)settingsDidChange:(NSNotification *)note {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self settingsDidChange:note]; }); return; }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(writeSettingsDirectoryFile) object:nil];
    [self performSelector:@selector(writeSettingsDirectoryFile) withObject:nil afterDelay:0.5];
}

+ (void)settingsWillTerminate:(NSNotification *)note {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(writeSettingsDirectoryFile) object:nil];
    [self writeSettingsDirectoryFile];      // the session was written into the defaults on the way here
}

// Called by +applyProcessArguments:, i.e. from main() before the delegate exists and before anything has read a
// setting. After this the directory's plist IS the preference domain: reads see it, and writes are mirrored back.
+ (void)applySettingsDirectory {
    NSString *dir = [self effectiveSettingsDirectory];
    NSString *suite = [self settingsDomainName];
    if (!dir.length || !suite.length) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *file = [dir stringByAppendingPathComponent:kSettingsFileName];

    if ([NSFileManager.defaultManager fileExistsAtPath:file]) {
        NSDictionary *stored = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:file] error:NULL];
        if (!NPPSettingsDomainIsUsable(stored)) {
            // A directory that is momentarily unreadable (still syncing, a lock, a zero-byte placeholder) must not
            // cost the user their settings: leave the local domain alone and say so, rather than replacing every
            // setting with nothing.
            gSettingsDirComplaint = [NSString stringWithFormat:
                @"Settings file %@ is empty or could not be read; this launch uses the settings stored with the "
                @"user account.", file];
            return;
        }
        // Where to look is a decision of THIS machine: a directory carrying a different answer (or none) must not
        // send the next launch somewhere else, and -settingsDir= must not rewrite the preference at all.
        NPPPreferences *p = NPPPreferences.shared;
        const BOOL wasEnabled = p.settingsDirectoryEnabled;
        NSString *wasPath = p.settingsDirectory;
        [d setPersistentDomain:stored forName:suite];
        p.settingsDirectoryEnabled = wasEnabled;
        p.settingsDirectory = wasPath;
    }
    gSettingsFile = file;
    [self writeSettingsDirectoryFile];       // seeds a directory used for the first time
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(settingsDidChange:)
               name:NSUserDefaultsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(settingsWillTerminate:)
               name:NSApplicationWillTerminateNotification object:nil];
}

// -L<code>: a browser language code ("fr", "pt-BR") -> one of the bundled nativeLang files. The file names are
// the English language name in lower case ("french.xml"), and each file says what it calls itself, so NSLocale's
// two names for the code are enough to find one without a table.
// ponytail: no table, and only the primary subtag is looked at, so the regional files are out of reach — "zh"
// (chineseSimplified.xml) and "zh-TW" (taiwaneseMandarin.xml) report unknown, and "pt-BR" quietly lands on
// European portuguese.xml rather than brazilian_portuguese.xml. Upgrade path: paste upstream's code->file list
// (NppParameters::getLocPathFromStr) into a dictionary consulted before this.
+ (NSString *)localizationFileNameForCode:(NSString *)code {
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@"-_"];
    NSString *primary = [code componentsSeparatedByCharactersInSet:sep].firstObject.lowercaseString;
    if (!primary.length) return nil;
    NSString *english = [[NSLocale localeWithLocaleIdentifier:@"en_US"] localizedStringForLanguageCode:primary];
    NSString *native = [[NSLocale localeWithLocaleIdentifier:primary] localizedStringForLanguageCode:primary];
    NSString *wantFile = english.length ? [english.lowercaseString stringByAppendingPathExtension:@"xml"] : nil;
    for (NPPUILanguage *l in NPPLocalization.shared.availableLanguages) {
        if (wantFile && [l.fileName.lowercaseString isEqualToString:wantFile]) return l.fileName;
        if (native.length && [l.displayName caseInsensitiveCompare:native] == NSOrderedSame) return l.fileName;
        if (english.length && [l.displayName caseInsensitiveCompare:english] == NSOrderedSame) return l.fileName;
    }
    return nil;
}

// Documents are matched to command line arguments by path, not by NSURL identity: the delegate may have built its
// own URL objects for the same files and -isEqual: on NSURL is stricter than the file system is.
+ (NSSet<NSString *> *)pathSetOf:(NSArray<NSURL *> *)urls {
    NSMutableSet<NSString *> *s = [NSMutableSet set];
    for (NSURL *u in urls) if (u.path) [s addObject:u.path];
    return s;
}

// Everything that needs the main window and the command line's open documents. Runs one main-queue turn after the
// window controller published its context, i.e. after -applicationDidFinishLaunching opened the files.
+ (void)applyToContext:(id<NPPCommandContext>)ctx {
    NPPCommandLineOptions *o = [self current];
    NSWindow *win = [ctx contextWindow];
    if (!ctx || !win || gApplied) return;
    // The command line describes the launch, not every window: the controller is recreated when the last one is
    // closed and reopened, and applying twice would re-lock buffers the user unlocked, re-hide a tab bar that was
    // brought back — and, with -quickPrint, print and quit a second time.
    gApplied = YES;

    if (o.noTabBar && !NPPPreferences.shared.tabBarHidden) {
        gTabBarHiddenToRestore = @NO;                 // put back on quit: a switch must not change a setting
        NPPPreferences.shared.tabBarHidden = YES;
    }
    if (o.alwaysOnTop) win.level = NSFloatingWindowLevel;
    // N++ appends the extra to the title bar text; macOS has a dedicated slot for exactly that, and unlike the
    // title it is not rebuilt by -updateWindowTitle on every keystroke.
    if (o.titleAdd.length) win.subtitle = o.titleAdd;
    // -L<code>: the UI language, put back on quit like every other override — a launch must not change a setting.
    if (o.localizationCode.length) {
        NSString *file = [self localizationFileNameForCode:o.localizationCode];
        if (file) {
            gUILanguageToRestore = NPPLocalization.shared.currentFileName ?: @"";
            gUILanguageApplied = file;
            NPPLocalization.shared.currentFileName = file;
        } else {
            [ctx contextReportStatus:[NSString stringWithFormat:@"Unknown localization \"%@\"", o.localizationCode]
                             isError:YES];
        }
    }
    // A settings directory that could not be used is the one option whose failure the user must see: silently
    // falling back to the local settings looks exactly like the directory being in use and empty.
    if (gSettingsDirComplaint) [ctx contextReportStatus:gSettingsDirComplaint isError:YES];
    if (o.left != NPPCommandLineNoValue || o.top != NPPCommandLineNoValue) {
        NSRect f = win.frame;
        NSRect screen = (win.screen ?: NSScreen.mainScreen).frame;
        if (o.left != NPPCommandLineNoValue) f.origin.x = NSMinX(screen) + o.left;
        if (o.top != NPPCommandLineNoValue) f.origin.y = NSMaxY(screen) - o.top - NSHeight(f);   // -y is from the top, as on Windows
        [win setFrame:f display:YES];
    }

    // Folder arguments, before the loop below so that whatever they open is covered by -fullReadOnly and
    // -monitoringMode too. Upstream has two paths here and so does this: -openFoldersAsWorkspace means the file
    // browser whatever else is configured (Notepad_plus.cpp, launchFileBrowser), while a plain folder argument
    // goes down doOpen()'s directory branch — here -contextOpenFileURL:, which forwards a directory to
    // -openFolderURL:, the one place NPPFolderDroppedOpenFiles decides workspace-root vs open-every-file-inside,
    // so a folder argument and a dropped folder cannot drift apart. Putting the plain argument behind the switch
    // as well is what made a bare "Notepad++ ~/project" open nothing at all.
    if (o.openFoldersAsWorkspace && o.folderURLs.count) {
        for (NSURL *u in o.folderURLs) [NPPWorkspacePanel.shared addRootFolderURL:u];
        // Toggling the panel on rather than -contextShowPanel: is what hands the module its command context, so
        // the tree's own double-click-to-open keeps working — the reason -[NPPEditorWindowController
        // addFolderAsWorkspace:] does it this way too.
        if (![NPPWorkspacePanel commandIsChecked:NPPCmdViewWorkspacePanel context:ctx])
            [NPPWorkspacePanel performCommand:NPPCmdViewWorkspacePanel context:ctx];
    } else {
        for (NSURL *u in o.folderURLs) [ctx contextOpenFileURL:u];
    }

    // Per-document options. -ro and -udl/-l apply to the files named on the command line; -fullReadOnly and
    // -monitoringMode apply to every buffer. ponytail: "every buffer" means every buffer open right now —
    // a document opened later is not covered. Upgrade path: a preferences flag the document reads on creation.
    NSSet<NSString *> *fromCmdLine = [NPPCommandLine pathSetOf:o.fileURLs];
    NPPLanguage *lang = o.languageName.length ? [NPPLanguageManager.shared languageNamed:o.languageName] : nil;
    if (o.languageName.length && !lang)
        [ctx contextReportStatus:[NSString stringWithFormat:@"Unknown language \"%@\"", o.languageName] isError:YES];
    for (NPPDocument *doc in [ctx contextOpenDocuments]) {
        BOOL named = doc.fileURL.path && [fromCmdLine containsObject:doc.fileURL.path];
        if (o.fullReadOnly || (o.readOnly && named)) doc.isReadOnly = YES;
        if (o.monitoringMode || (o.monitor && named)) doc.isMonitoring = YES;
        if (!named) continue;
        if (o.udlName.length) {          // a UDL replaces the lexer, so -udl wins over -l rather than both applying
            if (![doc applyUserDefinedLanguageNamed:o.udlName])
                [ctx contextReportStatus:[NSString stringWithFormat:@"Unknown user defined language \"%@\"", o.udlName] isError:YES];
        } else if (lang) {
            doc.language = lang;
        }
        [self applyCaretToEditor:doc.editor];
    }

    // Ghost typing, last of the startup work: the files this launch asked for are open by now, and it needs a
    // document of its own.
    if (o.ghostTypingSource != NPPGhostTypingNone) {
        NSString *why = nil;
        NSString *text = [self ghostTypingTextForOptions:o reason:&why];
        if (why) {
            [ctx contextReportStatus:why isError:YES];
        } else {
            // Upstream's player opens a new document before it types a character (threadTextPlayer's
            // IDM_FILE_NEW). Without that the demo appends itself to whatever file the same command line just
            // opened — an easter egg must not dirty the user's buffer.
            if ([ctx isKindOfClass:NPPEditorWindowController.class]) [(NPPEditorWindowController *)ctx newDocument];
            // "-l: Open file or Ghost type with syntax highlighting of choice" (AboutDlg.cpp) — the one option
            // upstream documents as applying to the ghost typed document as well as to a file.
            if (lang) [ctx contextCurrentDocument].language = lang;
            if (![self startGhostTypingText:text speed:o.ghostTypingSpeed context:ctx])
                [ctx contextReportStatus:@"Nothing to ghost type." isError:YES];
        }
    }

    if (o.showLoadingTime && gLaunchStart)
        [ctx contextReportStatus:[NSString stringWithFormat:@"Loading time: %.0f ms", -gLaunchStart.timeIntervalSinceNow * 1000.0]
                         isError:NO];

    if (o.displayHelp) [self showTextWindowNamed:@"args" title:@"Command Line Arguments" text:[self usageText]];

    if (o.quickPrint) [self quickPrintAndQuit:ctx];
}

// -n / -c / -p, applied to every file named on the command line — upstream does the same in
// Notepad_plus::loadCommandlineParams() and then switches to the last one, so what the user sees is the last file
// at the requested spot. A column without a line does nothing, also as upstream (its guard is line || position).
+ (void)applyCaretToEditor:(ScintillaView *)ed {
    NPPCommandLineOptions *o = [self current];
    if (!ed) return;
    sptr_t length = NPPSci(ed, SCI_GETLENGTH), pos;
    if (o.position != NPPCommandLineNoValue) {
        pos = MAX((sptr_t)0, MIN((sptr_t)o.position, length));
        // Never land inside a multibyte character or between CR and LF: round the position outwards, as upstream.
        if (pos > 0) pos = NPPSci(ed, SCI_POSITIONAFTER, (uptr_t)NPPSci(ed, SCI_POSITIONBEFORE, (uptr_t)pos));
    } else if (o.line != NPPCommandLineNoValue) {
        sptr_t line = MIN(MAX((sptr_t)0, (sptr_t)o.line - 1), NPPSci(ed, SCI_GETLINECOUNT) - 1);   // SCI_GOTOLINE clamps too
        // SCI_FINDCOLUMN, not "line start + n": a column counts tab stops and characters, not bytes.
        pos = (o.column != NPPCommandLineNoValue)
            ? NPPSci(ed, SCI_FINDCOLUMN, (uptr_t)line, MAX((sptr_t)0, (sptr_t)o.column - 1))
            : NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)line);
    } else {
        return;
    }
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)MAX((sptr_t)0, MIN(pos, length)));
    NPPSci(ed, SCI_SCROLLCARET);
}

#pragma mark - Ghost typing

+ (NSArray<NSString *> *)ghostTypingBuiltInNames {
    return [NPPGhostBuiltIns().allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}

+ (NSString *)ghostTypingTextForOptions:(NPPCommandLineOptions *)o reason:(NSString **)why {
    if (why) *why = nil;
    NSString *arg = o.ghostTypingArgument ?: @"";
    switch (o.ghostTypingSource) {
        case NPPGhostTypingNone:
            return nil;
        case NPPGhostTypingText:
            return arg.length ? arg : nil;      // "-qt=" with nothing after it has nothing to type
        case NPPGhostTypingBuiltIn: {
            NSDictionary<NSString *, NSString *> *all = NPPGhostBuiltIns();
            if ([arg caseInsensitiveCompare:@"random"] == NSOrderedSame)   // upstream's own special name
                return all[[self ghostTypingBuiltInNames][arc4random_uniform((uint32_t)all.count)]];
            for (NSString *name in all)
                if ([name caseInsensitiveCompare:arg] == NSOrderedSame) return all[name];
            if (why) *why = [NSString stringWithFormat:@"Unknown ghost typing script \"%@\"; try %@ or random.",
                             arg, [[self ghostTypingBuiltInNames] componentsJoinedByString:@", "]];
            return nil;
        }
        case NPPGhostTypingFile: {
            NSError *err = nil;
            NSString *text = [NSString stringWithContentsOfFile:arg encoding:NSUTF8StringEncoding error:&err];
            // Upstream reads the file as UTF-8 and gives up; a file the user picked themselves is worth one more
            // try in whatever encoding it really is, which is the same fallback the editor uses when opening one.
            if (!text) text = [NSString stringWithContentsOfFile:arg usedEncoding:NULL error:NULL];
            if (!text.length && why)
                *why = [NSString stringWithFormat:@"Cannot ghost type \"%@\": %@", arg,
                        text ? @"the file is empty" : (err.localizedDescription ?: @"unreadable")];
            return text.length ? text : nil;
        }
    }
    return nil;
}

+ (NSArray<NSNumber *> *)ghostTypingScheduleForText:(NSString *)text speed:(NSInteger)speed {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange r, NSRange e, BOOL *stop) {
        [out addObject:@(NPPGhostDelay([piece characterAtIndex:0], speed, (int)arc4random_uniform(NPPGhostMaxRange)))];
    }];
    return out;
}

// One step of the playback: the delay for `index` has already elapsed, so type it — plus every character behind
// it that costs no wait, which is what keeps -qSpeed3 from spending one run loop turn per character.
+ (void)ghostTypePieces:(NSArray<NSString *> *)pieces schedule:(NSArray<NSNumber *> *)schedule
                  index:(NSUInteger)index document:(NPPDocument *)doc context:(id<NPPCommandContext>)ctx {
    ScintillaView *ed = doc.editor;
    // Upstream stops when the user leaves the buffer it was typing into (threadTextPlayer's targetBufID check).
    if (index >= pieces.count || !ed || [ctx contextCurrentDocument] != doc) {
        gGhostTyping = NO;
        [ctx contextRefreshUI];
        return;
    }
    NSMutableString *chunk = [NSMutableString string];
    NSUInteger next = index;
    do { [chunk appendString:pieces[next++]]; } while (next < pieces.count && schedule[next].doubleValue <= 0);
    const char *utf8 = chunk.UTF8String;
    NPPSciStr(ed, SCI_APPENDTEXT, strlen(utf8), utf8);
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)NPPSci(ed, SCI_GETLENGTH));
    NPPSci(ed, SCI_SCROLLCARET);
    if (next >= pieces.count) { gGhostTyping = NO; [ctx contextRefreshUI]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(schedule[next].doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self ghostTypePieces:pieces schedule:schedule index:next document:doc context:ctx];
    });
}

+ (BOOL)startGhostTypingText:(NSString *)text speed:(NSInteger)speed context:(id<NPPCommandContext>)ctx {
    NPPDocument *doc = [ctx contextCurrentDocument];
    if (gGhostTyping || !text.length || !doc.editor) return NO;
    NSMutableArray<NSString *> *pieces = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange r, NSRange e, BOOL *stop) { [pieces addObject:piece]; }];
    NSArray<NSNumber *> *schedule = [self ghostTypingScheduleForText:text speed:speed];
    gGhostTyping = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(schedule.firstObject.doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self ghostTypePieces:pieces schedule:schedule index:0 document:doc context:ctx];
    });
    return YES;
}

// -quickPrint: print the files from the command line, then quit — N++ uses this for the shell's "Print" verb.
// ponytail: macOS runs every print job through the print panel, so this is one confirmation per file rather than
// N++'s silent print to the default printer. Upgrade path is an NPPPrintRenderer entry point with
// showsPrintPanel = NO.
+ (void)quickPrintAndQuit:(id<NPPCommandContext>)ctx {
    NSSet<NSString *> *wanted = [self pathSetOf:[self current].fileURLs];
    for (NPPDocument *doc in [ctx contextOpenDocuments]) {
        if (!doc.editor || !doc.fileURL.path || ![wanted containsObject:doc.fileURL.path]) continue;
        // Full path, not the display name: it is what the header/footer's $(FULL_CURRENT_PATH) expands to
        // (NPPPrintRenderer derives $(FILE_NAME) from it with -lastPathComponent).
        [NPPPrintRenderer printEditor:doc.editor documentName:doc.fileURL.path window:nil];
    }
    [NSApp terminate:nil];
}

#pragma mark - Help texts

+ (NSString *)usageText {
    return
    @"Usage:\n"
    @"\n"
    @"Notepad++ [--help] [-multiInst] [-noPlugin] [-l<language>] [-udl=\"My UDL Name\"]\n"
    @"          [-L<langCode>] [-n<line>] [-c<column>] [-p<position>] [-x<left>] [-y<top>]\n"
    @"          [-monitor] [-monitoringMode] [-nosession] [-notabbar] [-systemtray]\n"
    @"          [-loadingTime] [-alwaysOnTop] [-ro] [-fullReadOnly]\n"
    @"          [-fullReadOnlySavingForbidden] [-openSession] [-r] [-quickPrint]\n"
    @"          [-export=functionList] [-settingsDir=\"/your/settings/dir\"]\n"
    @"          [-openFoldersAsWorkspace] [-titleAdd=\"extra title bar text\"]\n"
    @"          [-notepadStyleCmdline] [-pluginMessage=\"your message\"] [-z <arg>]\n"
    @"          [-qn=\"script name\" | -qt=\"a text to type\" | -qf=\"/my/quote.txt\"] [-qSpeed1|2|3]\n"
    @"          [--] [filePath...]\n"
    @"\n"
    @"--help: Show this help\n"
    @"-multiInst: Launch another Notepad++ instance\n"
    @"-noPlugin: Launch Notepad++ without loading any plugin\n"
    @"-l<language>: Open the files with the given syntax highlighting (langs.model.xml name, e.g. -lcpp)\n"
    @"-udl=\"My UDL Name\": Open the files with the given User Defined Language applied\n"
    @"-L<langCode>: Apply the indicated localization to the menus for this run; langCode is a browser language\n"
    @"    code (\"fr\", \"de\") whose translation is named after it — see Settings > UI Language for the full list\n"
    @"-n<line>: Scroll to the indicated line of the file\n"
    @"-c<column>: Scroll to the indicated column of the line given by -n (on its own it does nothing, as upstream)\n"
    @"-p<position>: Scroll to the indicated character position of the file\n"
    @"-x<left>: Move the window to the indicated position from the left of the screen\n"
    @"-y<top>: Move the window to the indicated position from the top of the screen\n"
    @"-monitor: Open the files given as arguments with file monitoring enabled\n"
    @"-monitoringMode: Monitor every file opened in Notepad++\n"
    @"-nosession: Launch without restoring the previous session\n"
    @"-notabbar: Launch without the tab bar\n"
    @"-ro: Make the files given as arguments read-only\n"
    @"-fullReadOnly: Open all files read-only; the read-only flag can still be switched off\n"
    @"-fullReadOnlySavingForbidden: Open all files read-only; this port stops there, the read-only flag can still\n"
    @"    be switched off per document\n"
    @"-systemtray: Launch directly in the system tray\n"
    @"-loadingTime: Report the time Notepad++ took to start\n"
    @"-alwaysOnTop: Keep the Notepad++ window above other windows\n"
    @"-openSession: Treat each file argument as a session file and open the files it lists\n"
    @"-r: Open files recursively; ignored unless a file argument contains a wildcard\n"
    @"-quickPrint: Print the files given as arguments, then quit\n"
    @"-export=functionList: Write the function list of each file argument next to it, then quit\n"
    @"-settingsDir=\"/your/settings/dir\": Read and write the settings, the session and the backup folder in this\n"
    @"    directory instead of the user account's own (Preferences > Cloud & Link sets the same thing; this wins\n"
    @"    for the launch it is given on). Ignored, with a warning, when it is not an existing directory\n"
    @"-openFoldersAsWorkspace: Add the folder arguments to the workspace panel, whatever Folder Dropping is set to\n"
    @"-pluginMessage=\"string\": Message passed to the plugins at startup\n"
    @"-titleAdd=\"string\": Add the string to the Notepad++ title bar\n"
    @"-notepadStyleCmdline: Notepad replacement syntax; /p and /P then mean -quickPrint\n"
    @"-z <arg>: Ignore the next argument (used by the Notepad replacement syntax)\n"
    @"-qn=\"name\": Ghost type a built-in script into a new document, replaying it as if it were being typed\n"
    @"    Built-in scripts: hello, lorem, npp, tab — and \"random\", which picks one of them\n"
    @"-qt=\"text\": Ghost type the given text; write \\n, \\r or \\t for the characters an argument cannot carry,\n"
    @"    and \\\\ for a backslash. Anything else after a backslash stays as typed\n"
    @"-qf=\"/my/quote.txt\": Ghost type the contents of the file\n"
    @"-qSpeed<1|2|3>: Ghost typing speed: 1 slow, 2 fast (the default), 3 instant. Any other value means 2\n"
    @"--: Everything after this is a file name, even if it starts with a dash\n"
    @"filePath: File or folder to open, absolute or relative; may contain wildcards (see -r). Without\n"
    @"    -openFoldersAsWorkspace a folder is treated exactly as one dropped on the window: workspace root, or every\n"
    @"    file inside it when Preferences > MISC. > Folder Dropping says so\n"
    @"\n"
    @"Not honoured by the macOS port (recognised and ignored, never opened as a file):\n"
    @"  -noPlugin, -systemtray, -pluginMessage=, -multiInst, -export=functionList\n";
}

+ (NSURL *)configDirectory {
    NSString *settings = [self effectiveSettingsDirectory];
    if (settings.length) return [NSURL fileURLWithPath:settings isDirectory:YES];
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                              appropriateForURL:nil create:NO error:NULL];
    return [base URLByAppendingPathComponent:@"Notepad++" isDirectory:YES];
}

+ (NSString *)debugInfoText {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"(unknown)";
#if defined(__arm64__)
    NSString *arch = @"ARM 64-bit";
#elif defined(__x86_64__)
    NSString *arch = @"x86 64-bit";
#else
    NSString *arch = @"(unknown architecture)";
#endif
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"Notepad++ v%@   (%@)\n", version, arch];
    [s appendFormat:@"Build time: %s - %s\n", __DATE__, __TIME__];
#if defined(__clang_version__)
    [s appendFormat:@"Built with: Clang %s\n", __clang_version__];
#endif
    [s appendFormat:@"Scintilla/Lexilla included: %s/%s\n", NPP_SCINTILLA_VERSION, NPP_LEXILLA_VERSION];
    [s appendFormat:@"OS: macOS %@\n", NSProcessInfo.processInfo.operatingSystemVersionString];
    [s appendFormat:@"Path: %@\n", NSBundle.mainBundle.bundlePath ?: @"(unknown)"];
    [s appendFormat:@"Config directory: %@\n", [self configDirectory].path ?: @"(unavailable)"];
    [s appendFormat:@"Settings: %@\n", gSettingsFile ?: [NSString stringWithFormat:@"NSUserDefaults, suite %@",
                                                         info[@"CFBundleIdentifier"] ?: @"(unknown)"]];
    // N++'s Debug Info reports this switch too (AboutDlg.cpp), and it is the only place the user can see whether
    // the session keeps entries it cannot open.
    [s appendFormat:@"Remember inaccessible files from a past session: %@\n",
     NPPPreferences.shared.keepSessionAbsentFileEntries ? @"ON" : @"OFF"];
    if (gSettingsDirComplaint) [s appendFormat:@"Settings directory: %@\n", gSettingsDirComplaint];
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    if (args.count > 1) args = [args subarrayWithRange:NSMakeRange(1, args.count - 1)]; else args = @[];
    [s appendFormat:@"Command line: %@\n", args.count ? [args componentsJoinedByString:@" "] : @"(none)"];
    NPPCommandLineOptions *o = [self current];
    if (o.unrecognisedArguments.count)
        [s appendFormat:@"Unknown options: %@\n", [o.unrecognisedArguments componentsJoinedByString:@" "]];
    if (o.ignoredArguments.count)
        [s appendFormat:@"Ignored after -z: %@\n", [o.ignoredArguments componentsJoinedByString:@" "]];
    for (NSString *n in o.unsupportedNotes) [s appendFormat:@"Note: %@\n", n];
    return s;
}

#pragma mark - The two Help windows

// One read-only, selectable, monospaced text window, reused for both entries — N++ has two near-identical
// dialogs. Modeless on purpose: nothing here may block the main thread (see main.mm's dialog watchdog).
+ (void)showTextWindowNamed:(NSString *)key title:(NSString *)title text:(NSString *)text {
    if (!gTextWindows) gTextWindows = [NSMutableDictionary dictionary];
    NSWindow *win = gTextWindows[key];
    if (!win) {
        win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 480)
                                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered defer:NO];
        win.releasedWhenClosed = NO;     // reused; ARC + this dictionary own it
        win.title = title;
        win.minSize = NSMakeSize(420, 260);
        NSView *content = win.contentView;

        NSButton *copy = [NSButton buttonWithTitle:NSLocalizedString(@"Copy to Clipboard", nil)
                                            target:self action:@selector(copyTextWindowContents:)];
        copy.bezelStyle = NSBezelStyleRounded;
        [copy sizeToFit];
        NSRect cf = copy.frame;
        cf.origin = NSMakePoint(NSWidth(content.bounds) - NSWidth(cf) - 16, 14);
        copy.frame = cf;
        copy.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
        [content addSubview:copy];

        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(16, NSMaxY(cf) + 12, NSWidth(content.bounds) - 32, NSHeight(content.bounds) - NSMaxY(cf) - 28)];
        scroll.hasVerticalScroller = YES;
        scroll.hasHorizontalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.borderType = NSBezelBorder;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
        tv.editable = NO;
        tv.selectable = YES;
        tv.richText = NO;
        tv.font = [NSFont fontWithName:NPPDefaultMonospaceFontName() size:12] ?: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        tv.textContainerInset = NSMakeSize(6, 6);
        tv.minSize = NSMakeSize(0, 0);
        tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        tv.verticallyResizable = YES;
        tv.horizontallyResizable = YES;
        tv.textContainer.widthTracksTextView = NO;
        tv.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        scroll.documentView = tv;
        [content addSubview:scroll];
        [win center];
        gTextWindows[key] = win;
    }
    // Refreshed on every open: Debug Info is a snapshot, not a constant.
    for (NSView *v in win.contentView.subviews)
        if ([v isKindOfClass:NSScrollView.class]) ((NSTextView *)((NSScrollView *)v).documentView).string = text;
    [win makeKeyAndOrderFront:nil];
}

+ (void)copyTextWindowContents:(NSButton *)sender {
    for (NSView *v in sender.window.contentView.subviews) {
        if (![v isKindOfClass:NSScrollView.class]) continue;
        NSString *s = ((NSTextView *)((NSScrollView *)v).documentView).string ?: @"";
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
        return;
    }
}

#pragma mark - <NPPCommandHandler>

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    return cmd == NPPCmdHelpCommandLineArgs || cmd == NPPCmdHelpDebugInfo;
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return [self handlesCommand:cmd];       // both are pure text; neither needs a document
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    switch (cmd) {
        case NPPCmdHelpCommandLineArgs:
            [self showTextWindowNamed:@"args" title:NSLocalizedString(@"Command Line Arguments", nil) text:[self usageText]];
            return YES;
        case NPPCmdHelpDebugInfo:
            [self showTextWindowNamed:@"debug" title:NSLocalizedString(@"Debug Info", nil) text:[self debugInfoText]];
            return YES;
        default:
            return NO;
    }
}

#pragma mark - Self-checks

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(NSString *, BOOL) = ^(NSString *what, BOOL ok) { if (!ok) [fails addObject:what]; };
    NPPCommandLineOptions *(^parse)(NSArray<NSString *> *) = ^(NSArray<NSString *> *a) { return [self parseArguments:a]; };

    // 1. Every exact flag sets exactly its own property, alone and in company, and never becomes a file.
    for (NSString *flag in NPPFlagTable()) {
        NPPCommandLineOptions *o = parse(@[flag]);
        NSString *prop = NPPFlagTable()[flag];
        expect(([NSString stringWithFormat:@"%@ did not set %@", flag, prop]), [[o valueForKey:prop] boolValue]);
        expect(([NSString stringWithFormat:@"%@ was treated as a file", flag]), o.fileArguments.count == 0);
        expect(([NSString stringWithFormat:@"%@ reported as unknown", flag]), o.unrecognisedArguments.count == 0);
        // "flag:" and not a loose substring: every documented switch owns a "-switch: what it does" line, and a
        // plain search for "-r" is satisfied by the line describing "-ro".
        expect(([NSString stringWithFormat:@"%@ missing from usageText", flag]),
               [[self usageText] rangeOfString:[flag stringByAppendingString:@":"]].location != NSNotFound);
    }

    // 1b. The other direction: every switch the help text documents must be one the parser recognises. Checks 1, 2,
    // 2b and 9b all walk table -> text, so a line left behind by a renamed or never-implemented switch is invisible
    // to every one of them — and telling the user about an option that silently becomes a file name is the worse
    // half of the bargain. Switch lines start at column 0; prose, continuations and the not-honoured block are
    // indented, which is what makes "starts with a dash" a good enough parser for the help text.
    NSMutableSet<NSString *> *documented = [NSMutableSet setWithArray:NPPFlagTable().allKeys];
    [documented addObjectsFromArray:NPPValueTable().allKeys];
    [documented addObjectsFromArray:NPPLetterTable().allKeys];
    [documented addObjectsFromArray:NPPEasterEggPrefixes()];
    [documented addObjectsFromArray:@[@"-z", @"--"]];   // handled inline by the parser rather than through a table
    NSCharacterSet *notSwitchChar = [[NSCharacterSet characterSetWithCharactersInString:
        @"-=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
    for (NSString *line in [[self usageText] componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:@"-"]) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        // "/" splits "-qn=/-qt=/-qf=/-qSpeed"; the pieces of a path inside an example do not start with a dash.
        for (NSString *piece in [[line substringToIndex:colon.location] componentsSeparatedByString:@"/"]) {
            if (![piece hasPrefix:@"-"]) continue;
            NSRange stop = [piece rangeOfCharacterFromSet:notSwitchChar];
            NSString *sw = stop.location == NSNotFound ? piece : [piece substringToIndex:stop.location];
            expect(([NSString stringWithFormat:@"usageText documents \"%@\", which the parser does not recognise", sw]),
                   [documented containsObject:sw]);
        }
    }

    // 2. "-name=value" switches: value taken, surrounding quotes dropped, documented, never a file.
    for (NSString *prefix in NPPValueTable()) {
        NSString *prop = NPPValueTable()[prefix];
        NPPCommandLineOptions *o = parse(@[[prefix stringByAppendingString:@"\"a b\""], @"real.txt"]);
        expect(([NSString stringWithFormat:@"%@ value wrong: %@", prefix, [o valueForKey:prop]]),
               [[o valueForKey:prop] isEqual:@"a b"]);
        expect(([NSString stringWithFormat:@"%@ ate the file argument", prefix]),
               [o.fileArguments isEqualToArray:@[@"real.txt"]] && o.unrecognisedArguments.count == 0);
        expect(([NSString stringWithFormat:@"%@ missing from usageText", prefix]),
               [[self usageText] rangeOfString:prefix].location != NSNotFound);
    }

    // 2b. Single-letter switches carry their value in the same token, are documented as "-x<what>", and never
    // become files. Walked from the table, so a letter added without a property or a usage line fails here.
    for (NSString *key in NPPLetterTable()) {
        NSString *prop = NPPLetterTable()[key];
        id want = NPPLetterIsNumeric(key) ? (id)@7 : (id)@"7";
        NPPCommandLineOptions *o = parse(@[[key stringByAppendingString:@"7"]]);
        expect(([NSString stringWithFormat:@"%@7 gave %@, want %@", key, [o valueForKey:prop], want]),
               [[o valueForKey:prop] isEqual:want]);
        expect(([NSString stringWithFormat:@"%@7 was treated as a file or an unknown switch", key]),
               o.fileArguments.count == 0 && o.unrecognisedArguments.count == 0);
        expect(([NSString stringWithFormat:@"%@ missing from usageText", key]),
               [[self usageText] rangeOfString:[key stringByAppendingString:@"<"]].location != NSNotFound);
    }

    // 3. Numeric single-letter forms, including a negative -y and a value that is not a number at all.
    NPPCommandLineOptions *nums = parse(@[@"-n42", @"-c7", @"-p1234", @"-x10", @"-y-30"]);
    expect(@"-n42 not 42", nums.line == 42);
    expect(@"-c7 not 7", nums.column == 7);
    expect(@"-p1234 not 1234", nums.position == 1234);
    expect(@"-x10 not 10", nums.left == 10);
    expect(@"-y-30 not -30", nums.top == -30);
    expect(@"numeric switches leaked into the file list", nums.fileURLs.count == 0);
    NPPCommandLineOptions *empty = parse(@[]);
    expect(@"missing -n is not NPPCommandLineNoValue", empty.line == NPPCommandLineNoValue);
    expect(@"missing -x is not NPPCommandLineNoValue", empty.left == NPPCommandLineNoValue);
    NPPCommandLineOptions *bad = parse(@[@"-nfoo"]);
    expect(@"-nfoo not reported as unknown", [bad.unrecognisedArguments isEqualToArray:@[@"-nfoo"]]);
    expect(@"-nfoo opened as a file", bad.fileArguments.count == 0);
    expect(@"-nfoo set a line number", bad.line == NPPCommandLineNoValue);

    // 4. The exact-match switches must win over the single-letter prefixes that shadow them.
    NPPCommandLineOptions *shadow = parse(@[@"-nosession", @"-notabbar", @"-noPlugin", @"-notepadStyleCmdline",
                                            @"-pluginMessage=hi", @"-loadingTime"]);
    expect(@"-nosession parsed as -n", shadow.line == NPPCommandLineNoValue && shadow.noSession);
    expect(@"-notabbar not recognised", shadow.noTabBar);
    expect(@"-noPlugin not recognised", shadow.noPlugin);
    expect(@"-pluginMessage= parsed as -p", shadow.position == NPPCommandLineNoValue && [shadow.pluginMessage isEqual:@"hi"]);
    expect(@"-loadingTime parsed as -l", shadow.languageName == nil && shadow.showLoadingTime);
    expect(@"shadowed switches produced files", shadow.fileArguments.count == 0);

    // 5. -l / -L carry a value, and both are honoured now — neither may claim to be ignored.
    NPPCommandLineOptions *langs = parse(@[@"-lcpp", @"-Lfr"]);
    expect(@"-lcpp language wrong", [langs.languageName isEqual:@"cpp"]);
    expect(@"-Lfr localization wrong", [langs.localizationCode isEqual:@"fr"]);
    expect(@"-l/-L reported as unsupported", langs.unsupportedNotes.count == 0);

    // 6. "-z" swallows exactly one argument — the Notepad replacement syntax — and neither is a file.
    NPPCommandLineOptions *z = parse(@[@"-notepadStyleCmdline", @"-z", @"/System/Applications/TextEdit.app", @"note.txt"]);
    expect(@"-z did not swallow its argument", [z.fileArguments isEqualToArray:@[@"note.txt"]]);
    expect(@"-z argument not recorded", [z.ignoredArguments isEqualToArray:@[@"/System/Applications/TextEdit.app"]]);
    NPPCommandLineOptions *zEnd = parse(@[@"-z"]);
    expect(@"a trailing -z produced a file", zEnd.fileArguments.count == 0 && zEnd.unrecognisedArguments.count == 0);

    // 7. "--" ends the switches: a file really named like a switch opens as a file and changes no mode — including
    // -notepadStyleCmdline, which is looked for before the main pass and so has to stop at "--" as well.
    NPPCommandLineOptions *dd = parse(@[@"-ro", @"--", @"-noPlugin", @"-n5", @"-notepadStyleCmdline", @"/p"]);
    expect(@"-ro before -- was lost", dd.readOnly);
    expect(@"-- did not protect switch-shaped file names",
           ([dd.fileArguments isEqualToArray:(@[@"-noPlugin", @"-n5", @"-notepadStyleCmdline", @"/p"])]));
    expect(@"a file after -- set a flag",
           !dd.noPlugin && dd.line == NPPCommandLineNoValue && !dd.notepadStyleCmdline && !dd.quickPrint);
    expect(@"\"--\" itself became a file", ![dd.fileArguments containsObject:@"--"]);
    // The only place the pre-pass is observable: "/p" is a switch here, "-notepadStyleCmdline" is a file name there.
    NPPCommandLineOptions *ddp = parse(@[@"/p", @"--", @"-notepadStyleCmdline"]);
    expect(@"a file named -notepadStyleCmdline turned /p into -quickPrint",
           !ddp.quickPrint && !ddp.notepadStyleCmdline &&
           ([ddp.fileArguments isEqualToArray:(@[@"/p", @"-notepadStyleCmdline"])]));

    // 8. Unknown switches are reported, never opened.
    NPPCommandLineOptions *unknown = parse(@[@"-nosuchswitch", @"--alsoNot", @"good.txt"]);
    expect(@"unknown switches not collected",
           ([unknown.unrecognisedArguments isEqualToArray:(@[@"-nosuchswitch", @"--alsoNot"])]));
    expect(@"unknown switches opened as files", [unknown.fileArguments isEqualToArray:@[@"good.txt"]]);

    // 9. The three switches this port cannot honour: recognised, noted, and not files.
    NPPCommandLineOptions *unsup = parse(@[@"-noPlugin", @"-systemtray", @"-pluginMessage=x"]);
    expect(@"unsupported switches became files", unsup.fileArguments.count == 0 && unsup.fileURLs.count == 0);
    expect(@"unsupported switches not noted", unsup.unsupportedNotes.count == 3);

    // 9b. Every key in the not-honoured table is really recognised by the parser and really documented. A typo
    // there is otherwise invisible: the note never fires and the switch quietly becomes a file name.
    for (NSString *key in NPPUnsupportedTable()) {
        NSString *arg = ([key hasSuffix:@"="] || key.length == 2) ? [key stringByAppendingString:@"x"] : key;
        NPPCommandLineOptions *o = parse(@[arg, @"real.txt"]);
        expect(([NSString stringWithFormat:@"%@ became a file or an unknown switch", arg]),
               [o.fileArguments isEqualToArray:@[@"real.txt"]] && o.unrecognisedArguments.count == 0);
        expect(([NSString stringWithFormat:@"%@ produced %lu notes, want 1", arg, (unsigned long)o.unsupportedNotes.count]),
               o.unsupportedNotes.count == 1);
        expect(([NSString stringWithFormat:@"%@ missing from usageText", key]),
               [[self usageText] rangeOfString:key].location != NSNotFound);
    }
    // The ghost-typing switches are played back now, so none of them may still claim to be ignored — a stale note
    // would print "not ported" on the very launch that types the text.
    for (NSString *prefix in NPPEasterEggPrefixes())
        expect(([NSString stringWithFormat:@"%@ is still listed as not honoured", prefix]),
               NPPUnsupportedTable()[prefix] == nil);

    // 10. Notepad replacement syntax: /p only means -quickPrint together with -notepadStyleCmdline.
    expect(@"/p printed without -notepadStyleCmdline", !parse(@[@"/p"]).quickPrint);
    expect(@"/p is not a file without -notepadStyleCmdline", parse(@[@"/p"]).fileArguments.count == 1);
    NPPCommandLineOptions *np = parse(@[@"-notepadStyleCmdline", @"/P"]);
    expect(@"/P did not become -quickPrint", np.quickPrint && np.fileArguments.count == 0);
    expect(@"-notepadStyleCmdline did not imply -multiInst/-notabbar/-nosession",
           np.multiInstance && np.noTabBar && np.noSession);

    // 11. macOS's own launch arguments are swallowed, never opened, never reported as unknown.
    NPPCommandLineOptions *cocoa = parse(@[@"-psn_0_123456", @"-NSDocumentRevisionsDebugMode", @"YES",
                                           @"-ApplePersistenceIgnoreState", @"YES", @"real.txt"]);
    expect(@"Cocoa launch arguments leaked", [cocoa.fileArguments isEqualToArray:@[@"real.txt"]]);
    expect(@"Cocoa launch arguments reported as unknown", cocoa.unrecognisedArguments.count == 0);

    // 12. File arguments become absolute URLs, in order, without duplicates.
    NPPCommandLineOptions *paths = parse(@[@"a.txt", @"a.txt", @"/tmp/b.txt"]);
    expect(@"relative path not made absolute", [paths.fileURLs.firstObject.path hasPrefix:@"/"]);
    expect(@"duplicate file not removed", paths.fileURLs.count == 2);
    expect(@"file order changed", [paths.fileURLs.lastObject.path hasSuffix:@"b.txt"]);
    // An empty argument resolves to the working directory, which is a real directory: unskipped it would open
    // the whole cwd as a workspace root.
    NPPCommandLineOptions *blank = parse(@[@"", @"real.txt"]);
    expect(@"an empty argument became a file or a folder", blank.fileURLs.count == 1 && blank.folderURLs.count == 0);

    // 13. Wildcards and -r against a real directory tree (own unique directory: several checks may run at once).
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"npp-cmdline-%@", NSUUID.UUID.UUIDString]];
    NSString *sub = [root stringByAppendingPathComponent:@"sub"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:NULL]) {
        for (NSString *rel in @[@"one.cpp", @"two.cpp", @"skip.txt", @"sub/three.cpp"])
            [@"x" writeToFile:[root stringByAppendingPathComponent:rel] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *pattern = [root stringByAppendingPathComponent:@"*.cpp"];
        NPPCommandLineOptions *flat = parse(@[pattern]);
        expect(([NSString stringWithFormat:@"wildcard matched %lu files, want 2", (unsigned long)flat.fileURLs.count]),
               flat.fileURLs.count == 2);
        NPPCommandLineOptions *deep = parse(@[@"-r", pattern]);
        expect(([NSString stringWithFormat:@"-r matched %lu files, want 3", (unsigned long)deep.fileURLs.count]),
               deep.fileURLs.count == 3);
        expect(@"-r pulled in a non-matching file",
               [deep.fileURLs indexOfObjectPassingTest:^BOOL(NSURL *u, NSUInteger i, BOOL *stop) {
                   return [u.lastPathComponent isEqual:@"skip.txt"]; }] == NSNotFound);
        // A directory argument is a folder, never a document — with or without the switch. Without it the folder
        // still has to reach -folderURLs or +applyToContext: has nothing to hand the dropped-folder path, and
        // "Notepad++ ~/project" opens nothing at all.
        NPPCommandLineOptions *dir = parse(@[@"-openFoldersAsWorkspace", root]);
        expect(@"directory argument opened as a document", dir.fileURLs.count == 0 && dir.folderURLs.count == 1);
        NPPCommandLineOptions *bareDir = parse(@[root]);
        expect(@"a folder argument without -openFoldersAsWorkspace was dropped",
               bareDir.fileURLs.count == 0 && bareDir.folderURLs.count == 1);

        // 14. -openSession expands the session file into the documents it lists.
        NSString *session = [root stringByAppendingPathComponent:@"s.xml"];
        NSString *xml = [NSString stringWithFormat:
            @"<NotepadPlus><Session activeView=\"0\"><mainView activeIndex=\"0\">"
             "<File filename=\"%@/one.cpp\"/><File filename=\"%@/sub/three.cpp\"/>"
             "</mainView></Session></NotepadPlus>", root, root];
        [xml writeToFile:session atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NPPCommandLineOptions *sess = parse(@[@"-openSession", session]);
        expect(([NSString stringWithFormat:@"-openSession gave %lu files, want 2", (unsigned long)sess.fileURLs.count]),
               sess.fileURLs.count == 2);
        expect(@"-openSession opened the session file itself",
               ![sess.fileURLs.firstObject.lastPathComponent isEqual:@"s.xml"]);
        [fm removeItemAtPath:root error:NULL];
    } else {
        [fails addObject:@"could not create the temporary directory for the wildcard checks"];
    }

    // 15. The stricter read-only flag implies the weaker one, and -quickPrint stays silent (no session).
    expect(@"-fullReadOnlySavingForbidden did not imply -fullReadOnly",
           parse(@[@"-fullReadOnlySavingForbidden"]).fullReadOnly);
    expect(@"-quickPrint did not imply -nosession", parse(@[@"-quickPrint"]).noSession);
    expect(@"-export=functionList did not imply -nosession", parse(@[@"-export=functionList"]).noSession);

    // 16. An empty command line is inert.
    expect(@"empty command line is not inert",
           empty.fileURLs.count == 0 && empty.unsupportedNotes.count == 0 && empty.unrecognisedArguments.count == 0
           && !empty.displayHelp && !empty.noSession);

    // 17. Both Help texts carry what they promise.
    for (NSString *needle in @[@"Usage", @"--help", @"-titleAdd=", @"filePath"])
        expect(([NSString stringWithFormat:@"usageText missing \"%@\"", needle]),
               [[self usageText] rangeOfString:needle].location != NSNotFound);
    NSString *dbg = [self debugInfoText];
    for (NSString *needle in @[@"Notepad++ v", @"Build time:", @"Scintilla/Lexilla included:", @"OS: macOS",
                               @"Config directory:", @"Command line:", @NPP_SCINTILLA_VERSION, @NPP_LEXILLA_VERSION])
        expect(([NSString stringWithFormat:@"debugInfoText missing \"%@\"", needle]),
               [dbg rangeOfString:needle].location != NSNotFound);

    // 18. The caret options against a real editor. +applyCaretToEditor: reads +current, so it is swapped for the
    // duration and put back: this runs inside the live process, whose real command line must survive the check.
    NPPCommandLineOptions *saved = gCurrent;
    ScintillaView *ed = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NPPSci(ed, SCI_SETTABWIDTH, 4);
    NPPSciStr(ed, SCI_SETTEXT, 0, "alpha\n\tbravo\ncharlie\n");   // line 2 starts with one tab = columns 0..3
    sptr_t (^caretFor)(NSArray<NSString *> *) = ^(NSArray<NSString *> *a) {
        gCurrent = [self parseArguments:a];
        NPPSci(ed, SCI_GOTOPOS, 0);
        [self applyCaretToEditor:ed];
        return NPPSci(ed, SCI_GETCURRENTPOS);
    };
    expect(@"-n2 did not go to the start of line 2", caretFor(@[@"-n2"]) == 6);
    expect(@"-n2 -c5 ignored the tab width (want the position after the tab)", caretFor(@[@"-n2", @"-c5"]) == 7);
    expect(@"-p3 did not go to position 3", caretFor(@[@"-p3"]) == 3);
    expect(@"a column without a line moved the caret", caretFor(@[@"-c4"]) == 0);
    expect(@"-n0 was not clamped to the first line", caretFor(@[@"-n0"]) == 0);
    expect(@"-n9999 was not clamped to the last line", caretFor(@[@"-n9999"]) == NPPSci(ed, SCI_GETLENGTH));
    expect(@"-p9999 was not clamped to the end of the text", caretFor(@[@"-p9999"]) == NPPSci(ed, SCI_GETLENGTH));
    expect(@"an empty command line moved the caret", caretFor(@[]) == 0);
    gCurrent = saved;

    // 19. Startup routing: what -applicationDidFinishLaunching:/-saveSession ask this class before they act.
    // +current is process state, so it is swapped for the duration and put back (as in 18).
    NPPCommandLineOptions *savedCurrent = gCurrent;
    gCurrent = parse(@[]);
    expect(@"an empty command line does not restore the saved session", [self shouldRestoreSavedSession]);
    expect(@"an empty command line does not save the session", [self shouldSaveSessionOnQuit]);
    gCurrent = parse(@[@"note.txt"]);
    expect(@"a file on the command line did not replace the saved session", ![self shouldRestoreSavedSession]);
    expect(@"a file on the command line stopped the session being saved", [self shouldSaveSessionOnQuit]);
    gCurrent = parse(@[@"-openFoldersAsWorkspace", @"/tmp"]);
    expect(@"a folder-only command line did not restore the saved session", [self shouldRestoreSavedSession]);
    gCurrent = parse(@[@"-nosession"]);
    expect(@"-nosession restored the saved session", ![self shouldRestoreSavedSession]);
    expect(@"-nosession overwrote the saved session on quit", ![self shouldSaveSessionOnQuit]);
    gCurrent = parse(@[@"-quickPrint", @"note.txt"]);
    expect(@"-quickPrint overwrote the saved session on quit", ![self shouldSaveSessionOnQuit]);
    gCurrent = parse(@[@"-export=functionList"]);
    expect(@"-export=functionList overwrote the saved session on quit", ![self shouldSaveSessionOnQuit]);
    gCurrent = savedCurrent;

    // 19b. -L resolves against the bundled translations: the file named after the code in English, the one that
    // calls itself what the code is called, and nothing at all for a code that names neither.
    if (NPPLocalization.shared.availableLanguages.count > 1) {
        expect(@"-Lfr did not resolve to french.xml", [[self localizationFileNameForCode:@"fr"] isEqual:@"french.xml"]);
        expect(@"-Lfr-FR did not resolve to french.xml", [[self localizationFileNameForCode:@"fr-FR"] isEqual:@"french.xml"]);
        expect(@"-Lde did not resolve to german.xml", [[self localizationFileNameForCode:@"de"] isEqual:@"german.xml"]);
        expect(@"-Len did not resolve to the built-in English", [[self localizationFileNameForCode:@"en"] isEqual:@""]);
        expect(@"an unknown -L code resolved to a translation", [self localizationFileNameForCode:@"zz"] == nil);
        expect(@"an empty -L code resolved to a translation", [self localizationFileNameForCode:@""] == nil);
    } else {
        [fails addObject:@"-L cannot resolve: no bundled translations (nativeLang missing)"];
    }

    // 20. The command handler owns exactly its two menu items and refuses everything else.
    expect(@"NPPCmdHelpCommandLineArgs not handled", [self handlesCommand:NPPCmdHelpCommandLineArgs]);
    expect(@"NPPCmdHelpDebugInfo not handled", [self handlesCommand:NPPCmdHelpDebugInfo]);
    expect(@"a foreign command was claimed", ![self handlesCommand:NPPCmdHelpAbout] && ![self handlesCommand:NPPCmdFileNew]);
    id noContext = nil;   // neither window needs a document, so both must answer YES without one
    expect(@"a handled command reported as unavailable",
           [self canPerformCommand:NPPCmdHelpCommandLineArgs context:noContext] &&
           [self canPerformCommand:NPPCmdHelpDebugInfo context:noContext]);

    // 21. -settingsDir= is honoured, so it must NOT be in the not-honoured table any more — and the value must
    //     still reach -settingsDirectory rather than becoming a file name.
    {
        // Anchored on the section, not on one old spelling: a reworded not-honoured block that quietly put
        // -settingsDir= back would slip past a plain substring test.
        NSString *usage = [self usageText];
        const NSRange notHonoured = [usage rangeOfString:@"Not honoured by the macOS port"];
        expect(@"the help text lost its not-honoured section, so nothing below can be checked",
               notHonoured.location != NSNotFound);
        const NSRange below = NSMakeRange(notHonoured.location, usage.length - notHonoured.location);
        expect(@"-settingsDir= is still listed as not honoured",
               NPPUnsupportedTable()[@"-settingsDir="] == nil &&
               [usage rangeOfString:@"-settingsDir" options:0 range:below].location == NSNotFound);
        expect(@"-settingsDir= is not documented as an option that works",
               [usage rangeOfString:@"-settingsDir=" options:0
                              range:NSMakeRange(0, notHonoured.location)].location != NSNotFound);
    }
    expect(@"-settingsDir= did not reach the option object",
           [parse(@[@"-settingsDir=/tmp/npp-settings"]).settingsDirectory isEqualToString:@"/tmp/npp-settings"]);

    // 22. Which directory a launch runs on. The command line beats the preference, the preference is only read
    //     when its switch is on, and a path that is not an existing directory is refused at both — a typo must
    //     not silently start the app on a fresh, empty configuration.
    {
        NSFileManager *fm2 = NSFileManager.defaultManager;
        NSString *seed = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"npp-settings-%@", NSUUID.UUID.UUIDString]];
        [fm2 createDirectoryAtPath:seed withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm2 createDirectoryAtPath:[seed stringByAppendingString:@"-other"] withIntermediateDirectories:YES
                        attributes:nil error:NULL];
        // Standardised only now that the directories exist: the resolver standardises what it is given, and
        // /var/folders is a symlink to /private/var/folders — comparing the two spellings would fail for the
        // wrong reason.
        NSString *real = NPPAbsolutePath(seed);
        NSString *other = NPPAbsolutePath([seed stringByAppendingString:@"-other"]);
        NSString *aFile = [real stringByAppendingPathComponent:@"not-a-directory"];
        [@"x" writeToFile:aFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *savedComplaint = gSettingsDirComplaint;   // process state, as in 18/19
        NSString *(^resolve)(NSString *, BOOL, NSString *) = ^(NSString *cmd, BOOL on, NSString *pref) {
            return [self settingsDirectoryFromCommandLine:cmd preferenceEnabled:on preference:pref];
        };
        expect(@"nothing set must leave the settings with the user account", resolve(nil, NO, nil) == nil);
        expect(@"-settingsDir= naming a real directory was not used", [resolve(real, NO, nil) isEqualToString:real]);
        expect(@"the Cloud & Link directory was not used", [resolve(nil, YES, real) isEqualToString:real]);
        expect(@"the Cloud & Link directory was used with its switch off", resolve(nil, NO, real) == nil);
        gSettingsDirComplaint = nil;
        expect(@"the switch on with no directory named was accepted", resolve(nil, YES, @"") == nil);
        expect(@"the switch on with no directory named was not complained about", gSettingsDirComplaint != nil);
        gSettingsDirComplaint = nil;
        expect(@"an unused Cloud & Link page complained about nothing",
               resolve(nil, NO, nil) == nil && gSettingsDirComplaint == nil);
        expect(@"-settingsDir= did not win over the preference", [resolve(real, YES, other) isEqualToString:real]);
        expect(@"a bad -settingsDir= must fall through to the preference, not win",
               [resolve(@"/no/such/dir", YES, real) isEqualToString:real]);
        expect(@"a file was accepted as a settings directory", resolve(aFile, NO, nil) == nil);
        expect(@"a non-existent settings directory was accepted", resolve(@"/no/such/dir", YES, @"/nor/this") == nil);
        expect(@"a bad settings directory was not complained about", gSettingsDirComplaint != nil);
        gSettingsDirComplaint = savedComplaint;

        // The redirection itself: what the app has written must be in the directory's file, whole and unchanged.
        // This is the entire promise of the Cloud & Link page — a file holding a lossy subset of the preference
        // domain silently drops settings on the machine that reads it back.
        NSString *suite = [self settingsDomainName];
        if (suite.length) {
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            NSString *file = [real stringByAppendingPathComponent:kSettingsFileName];
            NSString *savedSettingsFile = gSettingsFile;
            gSettingsFile = file;
            [d setObject:@"npp-selfcheck" forKey:@"NPPSettingsDirectoryProbe"];
            [d setInteger:4242 forKey:@"NPPSettingsDirectoryProbeInt"];
            [self writeSettingsDirectoryFile];
            NSDictionary *back = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:file] error:NULL];
            expect(@"the settings directory file does not hold what the app has written",
                   [back[@"NPPSettingsDirectoryProbe"] isEqual:@"npp-selfcheck"] &&
                   [back[@"NPPSettingsDirectoryProbeInt"] isEqual:@4242]);
            expect(@"the settings directory file is not the whole preference domain (a subset loses settings)",
                   back.count == [d persistentDomainForName:suite].count);
            // Loading REPLACES the domain, so the one thing that must never be loaded is nothing: a zero-byte or
            // half-synced file parses to nil and an empty plist parses to @{}, and either one taken as the
            // configuration would wipe every setting on this machine.
            expect(@"an unreadable or empty settings file would be loaded over the user's whole configuration",
                   !NPPSettingsDomainIsUsable(nil) && !NPPSettingsDomainIsUsable(@{}) &&
                   NPPSettingsDomainIsUsable(back));
            [d removeObjectForKey:@"NPPSettingsDirectoryProbe"];
            [d removeObjectForKey:@"NPPSettingsDirectoryProbeInt"];
            gSettingsFile = savedSettingsFile;
        } else {
            [fails addObject:@"no bundle identifier: the settings directory cannot stand in for the preference domain"];
        }
        [fm2 removeItemAtPath:real error:NULL];
        [fm2 removeItemAtPath:other error:NULL];
    }

    // 23. Ghost typing: the four switches, what they resolve to, and the schedule that stands in for the
    //     keystrokes. Everything here is headless except the last block, which types into an editor of its own.
    {
        NPPCommandLineOptions *qn = parse(@[@"-qn=hello", @"real.txt"]);
        expect(@"-qn= did not name a built-in script",
               qn.ghostTypingSource == NPPGhostTypingBuiltIn && [qn.ghostTypingArgument isEqual:@"hello"]);
        expect(@"-qn= ate the file argument or was reported as unknown",
               [qn.fileArguments isEqualToArray:@[@"real.txt"]] && qn.unrecognisedArguments.count == 0);
        expect(@"-qn= is still reported as not honoured", qn.unsupportedNotes.count == 0);
        NPPCommandLineOptions *qt = parse(@[@"-qt=\"a b\""]);
        expect(@"-qt= did not take the text with its surrounding quotes stripped",
               qt.ghostTypingSource == NPPGhostTypingText && [qt.ghostTypingArgument isEqual:@"a b"]);
        NPPCommandLineOptions *qf = parse(@[@"-qf=quote.txt"]);
        expect(@"-qf= did not resolve its path against the working directory",
               qf.ghostTypingSource == NPPGhostTypingFile && [qf.ghostTypingArgument hasPrefix:@"/"] &&
               [qf.ghostTypingArgument hasSuffix:@"quote.txt"]);
        expect(@"a command line without -qn=/-qt=/-qf= asked for ghost typing",
               parse(@[@"real.txt"]).ghostTypingSource == NPPGhostTypingNone);

        // The escapes: an argument cannot carry a newline or a tab, so -qt= spells them. An unknown escape stays
        // as typed — a text mentioning a Windows path must survive being ghost typed.
        NPPCommandLineOptions *esc = parse(@[@"-qt=a\\nb\\tc\\\\d\\qe"]);
        expect(([NSString stringWithFormat:@"-qt= escapes decoded to \"%@\"", esc.ghostTypingArgument]),
               [esc.ghostTypingArgument isEqual:@"a\nb\tc\\d\\qe"]);
        expect(@"a trailing backslash was swallowed", [parse(@[@"-qt=x\\"]).ghostTypingArgument isEqual:@"x\\"]);
        expect(@"-qn= decoded escapes, which belong to -qt= alone",
               [parse(@[@"-qn=a\\nb"]).ghostTypingArgument isEqual:@"a\\nb"]);

        // The speed, with and without the "=" this port also accepts. Anything else is the default 2 — never an
        // unknown switch, and never a file called "-qSpeed9".
        expect(@"-qSpeed1 is not slow", parse(@[@"-qSpeed1"]).ghostTypingSpeed == 1);
        expect(@"-qSpeed=3 is not instant", parse(@[@"-qSpeed=3"]).ghostTypingSpeed == 3);
        expect(@"a command line without -qSpeed is not fast", parse(@[@"-qt=x"]).ghostTypingSpeed == 2);
        for (NSString *badSpeed in @[@"-qSpeed0", @"-qSpeed4", @"-qSpeed-1", @"-qSpeedx", @"-qSpeed"]) {
            NPPCommandLineOptions *s = parse(@[badSpeed, @"real.txt"]);
            expect(([NSString stringWithFormat:@"%@ gave speed %ld, want the default 2", badSpeed, (long)s.ghostTypingSpeed]),
                   s.ghostTypingSpeed == 2);
            expect(([NSString stringWithFormat:@"%@ became a file or an unknown switch", badSpeed]),
                   [s.fileArguments isEqualToArray:@[@"real.txt"]] && s.unrecognisedArguments.count == 0);
        }

        // What the switches resolve to. Every built-in name has to produce text, or -qn= lists a script that
        // types nothing; an unknown name and an unreadable file must say so rather than fail silently.
        NSString *why = nil;
        expect(@"-qn= offers no built-in scripts at all", [self ghostTypingBuiltInNames].count > 0);
        for (NSString *name in [self ghostTypingBuiltInNames]) {
            NPPCommandLineOptions *o = parse(@[[@"-qn=" stringByAppendingString:name]]);
            expect(([NSString stringWithFormat:@"the built-in script \"%@\" has no text", name]),
                   [self ghostTypingTextForOptions:o reason:NULL].length > 0);
            expect(([NSString stringWithFormat:@"the built-in script \"%@\" is missing from usageText", name]),
                   [[self usageText] rangeOfString:name].location != NSNotFound);
        }
        expect(@"-qn=random typed nothing", [self ghostTypingTextForOptions:parse(@[@"-qn=random"]) reason:NULL].length > 0);
        expect(@"-qn= is case sensitive", [self ghostTypingTextForOptions:parse(@[@"-qn=HELLO"]) reason:NULL].length > 0);
        expect(@"-qt= text did not reach the player",
               [[self ghostTypingTextForOptions:parse(@[@"-qt=hi"]) reason:NULL] isEqual:@"hi"]);
        expect(@"an empty command line resolved to something to type",
               [self ghostTypingTextForOptions:parse(@[]) reason:NULL] == nil);
        expect(@"an unknown script name typed something", [self ghostTypingTextForOptions:parse(@[@"-qn=nope"]) reason:&why] == nil);
        expect(@"an unknown script name was not reported", why.length > 0);
        why = nil;
        expect(@"a missing -qf= file produced text",
               [self ghostTypingTextForOptions:parse(@[@"-qf=/no/such/npp-quote.txt"]) reason:&why] == nil);
        expect(@"a missing -qf= file was not reported", why.length > 0);
        NSString *quoteFile = [NSTemporaryDirectory() stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"npp-ghost-%@.txt", NSUUID.UUID.UUIDString]];
        [@"typed from a file\n" writeToFile:quoteFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        why = nil;
        expect(@"-qf= did not read the file it was given",
               [[self ghostTypingTextForOptions:parse(@[[@"-qf=" stringByAppendingString:quoteFile]]) reason:&why]
                isEqual:@"typed from a file\n"] && why == nil);
        [NSFileManager.defaultManager removeItemAtPath:quoteFile error:NULL];

        // The rhythm. The formula is pinned at a chosen draw, then the schedule is checked against the bounds
        // that draw can produce — the delays are random, as upstream, so only the bounds are certain.
        expect(@"the slow delay is not the interval table's first entry", fabs(NPPGhostDelay('a', 1, 0) - 0.030) < 1e-9);
        expect(@"speed 2 does not halve the delay", fabs(NPPGhostDelay('a', 2, 0) - 0.015) < 1e-9);
        expect(@"speed 3 waits at all", NPPGhostDelay('a', 3, 199) == 0);
        expect(@"a space is not a pause", NPPGhostDelay(' ', 1, 0) > NPPGhostDelay('a', 1, 0));
        expect(@"a full stop is not a pause", NPPGhostDelay('.', 1, 4) > NPPGhostDelay('a', 1, 4));
        NSString *demo = @"one. two three.\nfour five. six seven.";
        NSArray<NSNumber *> *slow = [self ghostTypingScheduleForText:demo speed:1];
        NSArray<NSNumber *> *fast = [self ghostTypingScheduleForText:demo speed:2];
        NSArray<NSNumber *> *instant = [self ghostTypingScheduleForText:demo speed:3];
        expect(([NSString stringWithFormat:@"the schedule has %lu delays for %lu characters",
                 (unsigned long)slow.count, (unsigned long)demo.length]), slow.count == demo.length);
        // "e" + U+0301 is three UTF-16 units but two characters to a typist, and the accent must not arrive one
        // turn after the letter it sits on.
        expect(@"a combining mark was scheduled as a keystroke of its own",
               [self ghostTypingScheduleForText:@"e\u0301x" speed:1].count == 2);
        expect(@"an empty text produced a schedule", [self ghostTypingScheduleForText:@"" speed:1].count == 0);
        double slowTotal = 0, fastTotal = 0;
        for (NSNumber *d in slow) { slowTotal += d.doubleValue; expect(@"a slow delay is outside its bounds", d.doubleValue >= 0.030 && d.doubleValue <= 0.799); }
        for (NSNumber *d in fast) { fastTotal += d.doubleValue; expect(@"a fast delay is outside its bounds", d.doubleValue >= 0.015 && d.doubleValue <= 0.400); }
        for (NSNumber *d in instant) expect(@"speed 3 is not instant", d.doubleValue == 0);
        expect(([NSString stringWithFormat:@"slow (%.2fs) is not slower than fast (%.2fs)", slowTotal, fastTotal]),
               slowTotal > fastTotal);

        // The player, against an editor of its own: it types what it was given and refuses to start twice.
        NPPGhostProbeContext *probe = [NPPGhostProbeContext new];
        probe.doc = [[NPPDocument alloc] initUntitled];
        expect(@"the probe document has no editor", probe.doc.editor != nil);
        expect(@"ghost typing started with nothing to type", ![self startGhostTypingText:@"" speed:3 context:probe]);
        id noCtx = nil;
        expect(@"ghost typing started without an editor", ![self startGhostTypingText:@"x" speed:3 context:noCtx]);
        expect(@"a refused start left the playback flag set", !gGhostTyping);
        expect(@"ghost typing did not start", [self startGhostTypingText:@"hello\n" speed:3 context:probe]);
        expect(@"a second playback started while the first was running",
               ![self startGhostTypingText:@"second" speed:3 context:probe]);
        // Speed 3 has no delays, so this is one turn of the run loop; the bound is only there so a player that
        // never finishes fails the check instead of hanging the whole test run.
        for (int turn = 0; turn < 200 && gGhostTyping; ++turn)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        expect(@"ghost typing never finished", !gGhostTyping);
        expect(([NSString stringWithFormat:@"ghost typing produced \"%s\"", NPPSciGetText(probe.doc.editor).c_str()]),
               NPPSciGetText(probe.doc.editor) == "hello\n");
        expect(@"the caret was not left at the end of what was typed",
               NPPSci(probe.doc.editor, SCI_GETCURRENTPOS) == NPPSci(probe.doc.editor, SCI_GETLENGTH));
        // And it starts again once the first one is over — the flag is a lock, not a one-shot fuse.
        expect(@"ghost typing could not be started a second time after the first finished",
               [self startGhostTypingText:@"x" speed:3 context:probe]);
        for (int turn = 0; turn < 200 && gGhostTyping; ++turn)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        gGhostTyping = NO;
    }

    return fails;
}

@end
