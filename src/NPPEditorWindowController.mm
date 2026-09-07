// NPPEditorWindowController.mm — main window + command hub (port of Notepad_plus / NppIO / NppCommands, main view only).
#import "NPPEditorWindowController.h"
#import "NPPAppDelegate.h"
#import "NPPEditCommands.h"
#import "NPPSearchViewCommands.h"
#import "NPPPreferences.h"
#import "NPPLanguageManager.h"
#import "NPPUtils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Commands owned by NPPAppDelegate (Preferences, Style Theme, Help/About). The window controller is earlier in the
// responder chain, so it hands exactly these on. The ranges must stay narrow: the app delegate bounces everything it
// does not own back to us, so a too-wide predicate here is an infinite mutual recursion (it was, once).
static BOOL NPPIsAppLevelCommand(NSInteger tag) {
    return (tag >= NPPCmdSettingsPreferences && tag < NPPCmdSettingsThemeBase + 200) ||
           (tag >= NPPCmdHelpAbout && tag < NPPCmdHelpAbout + 100);
}

// Feature modules (macros, Run, Find in Files, panels, UDL, column editor) register themselves by name: each is a class
// implementing <NPPCommandHandler> as class methods. Looking them up dynamically keeps this file free of a dependency on
// every feature header, and a module that is not built simply leaves its menu items disabled.
static NSArray *NPPFeatureHandlerClasses(void) {
    static NSArray *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *m = [NSMutableArray array];
        for (NSString *name in @[@"NPPMacroManager", @"NPPRunCommands", @"NPPFindInFiles", @"NPPWorkspacePanel",
                                 @"NPPDocumentMapPanel", @"NPPFunctionListPanel", @"NPPColumnEditor",
                                 @"NPPUserDefinedLanguages", @"NPPUtilityPanels", @"NPPProjectPanel",
                                 @"NPPBackupManager", @"NPPAutoCompletion", @"NPPHashTools", @"NPPShortcutMapper",
                                 @"NPPPreferences", @"NPPLocalization", @"NPPCommandLine"]) {
            Class c = NSClassFromString(name);
            if (c && [c respondsToSelector:@selector(handlesCommand:)]) [m addObject:c];
        }
        classes = m;
    });
    return classes;
}
static Class NPPFeatureHandlerForCommand(NPPCmd cmd) {
    for (Class c in NPPFeatureHandlerClasses()) {
        Class<NPPCommandHandler> h = (Class<NPPCommandHandler>)c;
        if ([h handlesCommand:cmd]) return c;
    }
    return nil;
}

// The two Project Panel entry points a workspace file needs, declared (never implemented) so the compiler knows
// their types — a -performSelector: would hand the panel index over as a pointer and read a BOOL as one. Every
// call site is guarded by -respondsToSelector:, exactly like the other modules this file reaches by name.
@interface NSObject (NPPProjectPanelWorkspaceLookup)
+ (id)panelAtIndex:(NSInteger)index;
- (BOOL)openWorkspaceURL:(NSURL *)url;
@end

// Belt and braces: if the two sides ever disagree again, the command is reported as unavailable instead of crashing.
static BOOL gForwardingToAppDelegate = NO;
struct NPPForwardGuard {
    BOOL entered;
    NPPForwardGuard() : entered(!gForwardingToAppDelegate) { if (entered) gForwardingToAppDelegate = YES; }
    ~NPPForwardGuard() { if (entered) gForwardingToAppDelegate = NO; }
};

#include "Scintilla.h"

static NSString *const NPPRecentFilesDidChange = @"NPPRecentFilesDidChange";
static const NSUInteger kClosedStackMax = 10;

// Preferences ▸ MISC "Mute all sounds" (N++ NppGUI::_muteSounds). Every beep this window makes goes through here,
// and +beep publishes it so the feature modules can route their own NSBeep calls through one switch too.
// The counter is what makes the preference checkable at all: NSBeep() itself tells nobody it was called.
static NSUInteger gBeepCount = 0;
static void NPPBeepUnlessMuted(void) {
    if (NPPPreferences.shared.muteAllSounds) return;
    gBeepCount++;
    NSBeep();
}

// Does `path` end in the user-defined extension `ext` (N++ isFileSession / isFileWorkspace)? Upstream accepts the
// extension with or without its dot and compares case-insensitively; an empty setting matches nothing at all.
static BOOL NPPPathHasUserExtension(NSString *path, NSString *ext) {
    NSString *want = [ext stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    while ([want hasPrefix:@"."]) want = [want substringFromIndex:1];
    if (!want.length || !path.length) return NO;
    NSString *have = path.pathExtension;
    return have.length > 0 && [have caseInsensitiveCompare:want] == NSOrderedSame;
}

// What opening a path that is not there should do (N++ NppIO.cpp doOpen). Split out from the alerts so the
// headless check can walk all three branches without a modal dialog on screen.
typedef NS_ENUM(NSInteger, NPPMissingFileAction) {
    NPPMissingFileNone = 0,     // the file is there: just open it
    NPPMissingFileOfferCreate,  // its folder exists — "…doesn't exist. Create it?"
    NPPMissingFileNoFolder,     // its folder does not exist either: nothing to offer
};

// Where a tab dragged off its strip was let go (N++ NppNotification.cpp TCN_TABDROPPEDOUTSIDE, which asks
// WindowFromPoint the same three questions). Split out from the pop-up so the headless check can score the
// decision without a menu on screen.
typedef NS_ENUM(NSInteger, NPPTabDropTarget) {
    NPPTabDropSameWindow = 0,   // still over this window: offer Move / Clone to Other View
    NPPTabDropOtherView,        // the other view's strip or editor: send the buffer straight there
    NPPTabDropOutside,          // off the window altogether: open the file in a new instance
};

// Settings this window owns that have no NPPPreferences property yet (NPPPreferences is not ours to edit; its
// Multi-Instance page says as much). These NSUserDefaults keys are the contract a pane would bind to.
static NSString *const kDocSwitcherKey     = @"NPPDocumentSwitcher";          // N++ NppGUI::_doTaskList, default YES
static NSString *const kDocSwitcherMRUKey  = @"NPPDocumentSwitcherMRU";       // N++ NppGUI::_styleMRU (Preferences ▸ MISC "Enable MRU behaviour"), default YES
static NSString *const kFolderDropOpenKey  = @"NPPFolderDroppedOpenFiles";    // N++ _isFolderDroppedOpenFiles, default NO
static NSString *const kOpenPanelsKey      = @"NPPOpenPanels";                // N++ NppGUI::_*KeepState, one tag per open panel
static const NSInteger kFolderDropWarnAt   = 200;                             // N++ NbFileToOpenImportantWarning

// N++ WindowsDlg BufferEquivalent columns (Window ▸ Sort By), in the order the command tags are laid out.
typedef NS_ENUM(NSInteger, NPPSortKey) { NPPSortByName = 0, NPPSortByPath, NPPSortByType, NPPSortBySize, NPPSortByDate };

// N++ NumericStringEquivalence: case-insensitive, digit runs compared as numbers ("f2" before "f10").
static NSComparisonResult NPPNaturalCompare(NSString *a, NSString *b) {
    return [(a ?: @"") compare:(b ?: @"") options:NSCaseInsensitiveSearch | NSNumericSearch];
}

static BOOL NPPURLIsDirectory(NSURL *url) {
    NSNumber *isDir = nil;
    return [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL] && isDir.boolValue;
}

// make exercise / screenshot / typetest drive the *real* app: they open every panel in turn, and that throw-away
// layout must not become the one the user's next launch restores. Same guard, same keys, as NPPBackupManager puts
// on its snapshots — three lines rather than a shared header for a check two files make.
static BOOL NPPAutomatedRun(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    for (NSString *key in @[@"NPP_EXERCISE", @"NPP_EXERCISE_DIALOGS", @"NPP_SCREENSHOT", @"NPP_TYPETEST"])
        if (env[key]) return YES;
    return NO;
}

// Terminal.app is the macOS answer to IDM_FILE_OPEN_CMD's %COMSPEC%. ponytail: not the user's preferred terminal —
// there is no public API for that; read a bundle id out of NSUserDefaults here if anyone wants iTerm.
static NSURL *NPPTerminalApplicationURL(void) {
    static NSURL *url;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Terminal"]; });
    return url;
}

// Can a folder be handed to the workspace panel? The one predicate both -addFolderAsWorkspace: and the menu
// validation ask, so the two can never drift into "the item is live but the command does nothing". Answered
// without instantiating the panel — menu validation runs on every menu open.
static BOOL NPPWorkspacePanelTakesFolders(void) {
    Class c = NSClassFromString(@"NPPWorkspacePanel");
    return NPPFeatureHandlerForCommand(NPPCmdViewWorkspacePanel) != nil &&
           [c respondsToSelector:@selector(shared)] &&
           [c instancesRespondToSelector:@selector(addRootFolderURL:)];
}

// -nosession (and the -quickPrint / -export=functionList that imply it) decides both whether this launch restores
// a session and whether the quit writes one. NPPCommandLine owns both answers and is asked by name, like every
// other optional module here, so this file keeps no feature-header dependency; a name that does not resolve means
// yes, which is what a session did before there was a command line to turn it off.
// The two selectors live in this one function so the self-check can send exactly what the callers send: a check
// spelling them out a second time would pass happily while a typo in the callers' copy failed open and quietly
// saved a session under -nosession again. `landed` is how it tells "the module said yes" from "nobody answered".
static BOOL NPPSessionSwitchAllows(BOOL restoringAtLaunch, BOOL *landed) {
    SEL question = restoringAtLaunch ? @selector(shouldRestoreSavedSession) : @selector(shouldSaveSessionOnQuit);
    if (landed) *landed = NO;
    Class c = NSClassFromString(@"NPPCommandLine");
    if (![c respondsToSelector:question]) return YES;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[c methodSignatureForSelector:question]];
    inv.target = c;
    inv.selector = question;
    [inv invoke];
    BOOL answer = YES;
    [inv getReturnValue:&answer];
    if (landed) *landed = YES;
    return answer;
}

// Notepad++ has two edit views, a main and a sub. Everything here is indexed by view: 0 is the main view, 1 the
// sub view. A document lives in exactly one of them, exactly one view has the focus, and a view with no documents
// is not shown — so with every document in view 0 the window is laid out exactly as it was before the split
// existed. See -isSplit / -layoutContent.
static const NSInteger kMainView = 0, kSubView = 1;

// Margins ▸ "No edge" (inverted: NppGUI::_showBorderEdge). One constant, because the frame is drawn by
// -applyEditorBorderEdge and the room for it is left by -editorFrameInView: — the two drifting apart is exactly
// how the edge ends up under the edit view and the checkbox stops meaning anything.
static const CGFloat kBorderEdgeWidth = 1;

@interface NPPEditorWindowController () {
    NSMutableArray<NPPDocument *> *_docs[2];   // per view, in tab order; a document is in exactly one of them
    NPPDocument *_cur[2];                      // each view's current document
    NPPTabBarView *_tabBars[2];
    NSView *_containers[2];                    // inside _panelHost.centerView / .secondaryCenterView
    NSInteger _view;                           // the focused view (kMainView / kSubView)
    NSMutableSet<NPPDocument *> *_pinnedDocs;  // NPPTabItem.pinned lives on a view object we rebuild; keep it here
    BOOL _syncScrollV, _syncScrollH, _zoomSync;
    sptr_t _syncLine, _syncXOffset;            // main-minus-sub offsets captured when a sync was switched on
    BOOL _syncing;                             // re-entrancy guard: mirroring a scroll makes the other view report one
    NSView *_incrementalBar;            // nil until first shown
    BOOL _incrementalVisible;
    NPPStatusBarView *_statusBar;
    NSMutableArray<NSURL *> *_closedStack;
    NSMutableSet<NPPDocument *> *_pendingReloadPrompt;
    BOOL _checkingDisk;                 // one activation sweep at a time: its alerts are modal and re-key the window
    NSURL *_lastUsedDirectory;          // last folder an Open / Save panel landed on (N++ dir_last)
    BOOL _distractionFree;
    BOOL _enteredFullScreenForDistractionFree;
    BOOL _quitApproved;                 // windowShouldClose already prompted; skip the prompt in applicationShouldTerminate
    NSUInteger _statusFlashToken;
    NSMapTable<NPPDocument *, NSDate *> *_declinedReloadDates;   // external change the user chose not to reload
    BOOL _halvesSwapped;                // Rotate Left/Right: which half of the split each view sits in
    BOOL _didShowWindow;                // -showWindow: happened: this is the app's window, not a headless one
    BOOL _didAddStartupDocument;        // "Always open a new document in addition at startup": once per launch
    BOOL _restoringPanels;              // re-opening the remembered panels; do not write the list back while doing it
    NSMutableArray<NPPDocument *> *_mru;             // most recently used first (N++ TaskListInfo order)
    NSPanel *_switcher;                              // ⌃Tab HUD (N++ WinControls/TaskList), nil until first use
    NSTextField *_switcherLabel;
    NSArray<NPPDocument *> *_switcherOrder;          // frozen MRU order for the run of ⌃Tab presses
    NSInteger _switcherIndex;
    id _switcherMonitor;                             // NSEvent local monitor, removed in -dealloc
    // The Open / Save panel currently on screen and its file-type accessory. Weak throughout: the panel owns the
    // accessory view and both go away when the modal run ends, and nothing here is touched outside that run.
    __weak NSSavePanel *_filterPanel;
    __weak NSPopUpButton *_filterPopUp;
    __weak NSButton *_filterAppendCheck;             // Save panels only ("Append extension")
}
// Reached by the headless checks at the bottom of this file, which drive them without a key window.
- (void)cycleDocumentSwitcherBackward:(BOOL)backward;
- (void)commitDocumentSwitcher;
- (BOOL)reloadDocumentSilentlyIfPreferred:(NPPDocument *)doc;
- (void)sortDocumentsByKey:(NPPSortKey)key descending:(BOOL)descending;
- (void)rotateSplitToLeft:(BOOL)left;
- (nullable NSURL *)defaultPanelDirectoryForDocument:(nullable NPPDocument *)doc;
- (NSXMLDocument *)sessionXMLDocument;
- (void)applySessionXMLDocument:(NSXMLDocument *)xml;
- (void)layoutContent;
- (void)checkDocumentsChangedOnDisk;
- (nullable NSURL *)autoSessionURL;
- (BOOL)restoreAutoSession;
// The preference-driven decisions the checks drive directly: each one is the answer a modal dialog (or a second
// process) would be built on, so it can be scored without either.
- (void)applyDistractionFreePadding;
- (NSRect)editorFrameInView:(NSInteger)v;
- (BOOL)saveAllNeedsConfirmation;
- (BOOL)loadSessionShouldOpenNewInstance;
- (NPPMissingFileAction)actionForMissingFileAtURL:(NSURL *)url;
- (NPPTabDropTarget)dropTargetForScreenPoint:(NSPoint)p fromView:(NSInteger)v;
- (NSMenu *)tabDropMenu;
+ (BOOL)panelCommandKeepsStateWithoutSession:(NPPCmd)cmd;
// View ▸ Tab ▸ Pin Tab, inserted into a main menu built elsewhere. Takes the root so the check can drive it.
+ (nullable NSMenuItem *)addPinTabItemToMainMenu:(nullable NSMenu *)mainMenu;
@end

@implementation NPPEditorWindowController {
    NPPPanelHost *_panelHost;
}
@synthesize panelHost = _panelHost;

#pragma mark - Init / layout

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 700)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:w])) return nil;
    w.minSize = NSMakeSize(480, 320);
    w.tabbingMode = NSWindowTabbingModeDisallowed;
    w.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    [w center];
    [w setFrameAutosaveName:@"NPPMainWindow"];
    w.delegate = self;
    w.title = @"Notepad++";

    _closedStack = [NSMutableArray array];
    _pendingReloadPrompt = [NSMutableSet set];
    _pinnedDocs = [NSMutableSet set];
    _mru = [NSMutableArray array];

    NSView *content = w.contentView;
    content.autoresizesSubviews = YES;

    _panelHost = [[NPPPanelHost alloc] initWithFrame:NSZeroRect];
    _panelHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_panelHost];
    __weak NPPEditorWindowController *weakForSplit = self;
    _panelHost.splitDidResize = ^{ [weakForSplit layoutContent]; };

    // Both views exist from the start; the sub view stays empty (and therefore invisible) until a document moves in.
    for (NSInteger v = kMainView; v <= kSubView; v++) {
        _docs[v] = [NSMutableArray array];
        _tabBars[v] = [[NPPTabBarView alloc] initWithFrame:NSZeroRect];
        _tabBars[v].delegate = self;
        _tabBars[v].autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;   // top of whichever view hosts it
        [content addSubview:_tabBars[v]];
        _containers[v] = [[NSView alloc] initWithFrame:NSZeroRect];
        _containers[v].wantsLayer = YES;
        _containers[v].autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [_panelHost.centerView addSubview:_containers[v]];
    }
    _view = kMainView;
    // Zoom sync is a setting (N++ keeps it in ScintillaViewParams); the two scroll syncs are session state that
    // only means anything while both views are up, and N++ drops them whenever the second view goes away.
    _zoomSync = [NSUserDefaults.standardUserDefaults boolForKey:@"NPPZoomSync"];

    _statusBar = [[NPPStatusBarView alloc] initWithFrame:NSZeroRect];
    _statusBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    __weak NPPEditorWindowController *weakSelf = self;
    _statusBar.insertModeClicked = ^{
        NPPEditorWindowController *self_ = weakSelf;
        ScintillaView *ed = self_.currentDocument.editor;
        if (!ed) return;
        NPPSci(ed, SCI_SETOVERTYPE, !NPPSci(ed, SCI_GETOVERTYPE));
        [self_ updateStatusBar];
    };
    [content addSubview:_statusBar];
    [self layoutContent];

    NPPFindPanelController.shared.targetProvider = self;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(showIncrementalBar:) name:NPPIncrementalSearchShouldShowNotification object:nil];
    [nc addObserver:self selector:@selector(hideIncrementalBar:) name:NPPIncrementalSearchShouldHideNotification object:nil];
    [nc addObserver:self selector:@selector(themeDidChange:) name:NPPThemeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(preferencesDidChange:) name:NPPPreferencesDidChangeNotification object:nil];

    [self applyTheme];
    // Feature modules that need a long-lived context (rather than a per-command one) observe this and keep a weak
    // reference to us. Posted before the first document so a module can install itself on every editor.
    [nc postNotificationName:NPPCommandContextReadyNotification object:self];
    [self newDocument];   // N++ always starts with "new 1"; session restore replaces it when it is untouched
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_switcherMonitor) [NSEvent removeMonitor:_switcherMonitor];
    [_switcher orderOut:nil];   // a window still ordered in is retained by AppKit: it would outlive us on screen
}

// The one hook that says "this controller is the application's window": the headless self-test and the module
// checks build controllers they never show, and those must not restore panels, quit the app, or — an app-wide
// registration one per controller — install the ⌃Tab event monitor.
- (void)showWindow:(id)sender {
    [super showWindow:sender];
    if (_didShowWindow) return;
    _didShowWindow = YES;
    [self installDocumentSwitcherMonitor];
    [NPPEditorWindowController pruneRecentFilesAtLaunch];
    [NPPEditorWindowController addPinTabItemToMainMenu:NSApp.mainMenu];
    [self restoreRememberedPanels];
    [self restoreAutoSessionAtLaunch];
    // N++ adds it at the very end of startup (Notepad_plus_Window::init), after the session and the command line
    // have opened everything; here that is the next main-queue turn, because the app delegate opens the session
    // and the named files right after this returns. Idempotent, so the delegate may call it instead.
    __weak NPPEditorWindowController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf addStartupDocumentIfPreferred]; });
}

// Preferences ▸ New Document "Always open a new document in addition at startup". N++ gates it on
// rememberLastSession too: without a session to add to, "new 1" is already that document.
- (void)addStartupDocumentIfPreferred {
    if (_didAddStartupDocument) return;
    _didAddStartupDocument = YES;
    NPPPreferences *prefs = NPPPreferences.shared;
    if (!prefs.addNewDocumentOnStartup || !prefs.rememberLastSession) return;
    [self newDocument];
}

// Preferences ▸ Recent Files History "Check that the files still exist at launch time" (N++
// NppGUI::_checkHistoryFiles, whose checkbox is the inverse "Don't check at launch time"): the entries that have
// gone are dropped once, at startup, so every later reader — the File menu above all — sees the pruned list.
+ (void)pruneRecentFilesAtLaunch {
    NPPPreferences *prefs = NPPPreferences.shared;
    if (!prefs.checkRecentFilesAtLaunch) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *path in prefs.recentFilePaths) if ([fm fileExistsAtPath:path]) [kept addObject:path];
    if (kept.count == prefs.recentFilePaths.count) return;
    prefs.recentFilePaths = kept;
    [NSNotificationCenter.defaultCenter postNotificationName:NPPRecentFilesDidChange object:self];
}

// The one beep the app should make, so "Mute all sounds" is a single switch rather than a per-module habit.
+ (void)beep { NPPBeepUnlessMuted(); }

// A view is shown when it holds documents. One view: the window is laid out exactly as it was before the split
// existed — one tab strip across the top of the window, the editor filling the panel host's centre. Two views:
// each half carries its own tab strip, so the strips sit inside the split area instead.
- (BOOL)isSplit { return _docs[kMainView].count > 0 && _docs[kSubView].count > 0; }
- (NSInteger)soleView { return _docs[kMainView].count > 0 ? kMainView : kSubView; }
- (NSInteger)otherView { return 1 - _view; }

// The strip owns its own shape (single row / multi-line / vertical, all three read straight from the preferences
// by NPPTabBarView) and asks the window for the room: -preferredWidth > 0 means "make me a column down the
// leading edge", otherwise -preferredHeight is the band across the top. Each view's strip is asked separately,
// so a split can have a wrapped strip over one half and a single row over the other.
- (void)layoutContent {
    if (!_containers[kSubView]) return;   // still inside -init; the explicit call at the end of it lays out once
    NSRect b = self.window.contentView.bounds;
    BOOL split = [self isSplit];
    NSInteger sole = split ? -1 : [self soleView];
    CGFloat statusH = _statusBar.hidden ? 0 : _statusBar.preferredHeight;
    CGFloat incH = (_incrementalVisible && _incrementalBar) ? NSHeight(_incrementalBar.frame) : 0;
    if (_incrementalVisible && incH <= 0) incH = 28;

    _statusBar.frame = NSMakeRect(0, 0, NSWidth(b), statusH);
    if (_incrementalBar) _incrementalBar.frame = NSMakeRect(0, statusH, NSWidth(b), incH);
    CGFloat bottom = statusH + incH;
    // No strip at all in distraction-free mode or under Preferences ▸ Tab Bar ▸ Hide (which -notabbar also sets).
    // NPPPreferences pushes that one by setting -hidden on both strips and then calling straight back in here, so
    // this has to derive the same answer from the same preference rather than overwrite what it just set —
    // asking the strip for its own -hidden instead would make distraction-free and the preference fight.
    BOOL noStrip = _distractionFree || NPPPreferences.shared.tabBarHidden;
    // The window-wide strip only exists while there is one view: a column takes width off the panel host, a band
    // takes height off it.
    CGFloat windowTabW = 0, windowTabH = 0;
    if (!split && !noStrip) {
        windowTabW = _tabBars[sole].preferredWidth;
        if (windowTabW <= 0) windowTabH = _tabBars[sole].preferredHeight;
    }
    _panelHost.splitEnabled = split;
    _panelHost.frame = NSMakeRect(windowTabW, bottom, MAX(0, NSWidth(b) - windowTabW), MAX(0, NSHeight(b) - bottom - windowTabH));
    [_panelHost layout];

    for (NSInteger v = kMainView; v <= kSubView; v++) {
        BOOL inWindow = (v == sole);                       // this view owns the window-wide strip
        // Rotate Left/Right can swap which half each view sits in (SplitterContainer::rotateTo), so the main view
        // is not always the first half. With one view the sole strip fills the centre either way.
        BOOL firstHalf = ((v == kMainView) != _halvesSwapped);
        NSView *half = (!split || firstHalf) ? _panelHost.centerView : _panelHost.secondaryCenterView;
        NPPTabBarView *bar = _tabBars[v];
        NSView *barParent = inWindow ? self.window.contentView : half;
        if (bar.superview != barParent) [barParent addSubview:bar];
        NSRect hb = half.bounds;
        CGFloat w = 0, h = 0;
        if (inWindow) {
            w = windowTabW; h = windowTabH;
        } else if (split && !noStrip) {
            w = bar.preferredWidth;
            if (w <= 0) h = bar.preferredHeight;
        }
        bar.hidden = (w <= 0 && h <= 0);
        if (w > 0) {   // a column on the leading edge, full height of whatever it sits in
            bar.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
            bar.frame = inWindow ? NSMakeRect(0, bottom, w, MAX(0, NSHeight(b) - bottom))
                                 : NSMakeRect(0, 0, w, NSHeight(hb));
        } else {
            bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
            bar.frame = inWindow ? NSMakeRect(0, NSMaxY(b) - h, NSWidth(b), h)
                                 : NSMakeRect(0, NSHeight(hb) - h, NSWidth(hb), h);
        }

        NSView *c = _containers[v];
        if (c.superview != half) [half addSubview:c];
        c.hidden = _docs[v].count == 0;
        // The window-wide strip is outside the panel host (already inset for it above); a split half's strip
        // shares the half with its editor, so the editor gives up that edge.
        CGFloat inset = inWindow ? 0 : w;
        c.frame = NSMakeRect(inset, 0, MAX(0, NSWidth(hb) - inset), MAX(0, NSHeight(hb) - (inWindow ? 0 : h)));
        _cur[v].editor.frame = [self editorFrameInView:v];
    }
    [self applyEditorBorderEdge];
    // Distraction Free padding is a fraction of the editor's *width*, so it is re-derived on every resize, exactly
    // as N++ re-derives it on WM_SIZE (NppBigSwitch.cpp). Off, this puts the Margins ▸ padding back.
    [self applyDistractionFreePadding];
}

// N++ DocTabView::reSizeTo insets the edit view by ScintillaViewParams::_borderWidth inside the tab area. Both
// places that frame an editor (here and -selectDocument:) ask this one method, so they cannot drift apart.
// The edge costs a point of its own on top of that: it is drawn on the *container* (see -applyEditorBorderEdge),
// so without that point the edit view covers it and "No edge" would change nothing at all whenever the border
// width is 0 — Win32's WS_EX_CLIENTEDGE likewise takes its frame out of the Scintilla client area.
- (NSRect)editorFrameInView:(NSInteger)v {
    if (v < kMainView || v > kSubView) return NSZeroRect;
    NPPPreferences *prefs = NPPPreferences.shared;
    CGFloat inset = MAX(0, MIN(30, (CGFloat)prefs.borderWidth)) + (prefs.showBorderEdge ? kBorderEdgeWidth : 0);
    NSRect b = _containers[v].bounds;
    if (NSWidth(b) <= 2 * inset || NSHeight(b) <= 2 * inset) return b;   // never inset a container into nothing
    return NSInsetRect(b, inset, inset);
}

// N++ ScintillaEditView::setBorderEdge (the WS_EX_CLIENTEDGE frame around each edit view); the preference's
// checkbox is the inverse, "No edge". Drawn on the editor's container, which is the view the border width above
// leaves room for. ponytail: a flat hairline rather than Win32's sunken 3D edge — macOS has no such frame.
- (void)applyEditorBorderEdge {
    BOOL show = NPPPreferences.shared.showBorderEdge;
    // NppDarkMode::darkColors.edge is 0x646464; light mode gets a plain separator grey.
    NSColor *edge = NPPNSColorFromSci([NPPLanguageManager.shared currentThemeIsDark] ? 0x646464 : 0xC8C8C8);
    for (NSInteger v = kMainView; v <= kSubView; v++) {
        _containers[v].layer.borderWidth = show ? kBorderEdgeWidth : 0;
        _containers[v].layer.borderColor = show ? edge.CGColor : NULL;
    }
}

// N++ ScintillaViewParams::getDistractionFreePadding: in Distraction Free mode the left and right margins are the
// edit view's width divided by the preference (3-9 parts); otherwise they are the plain Margins ▸ padding, which
// is what NPPPreferences itself applies. Every open buffer gets it, so switching tabs inside the mode keeps it.
- (void)applyDistractionFreePadding {
    NPPPreferences *prefs = NPPPreferences.shared;
    sptr_t left = (sptr_t)MAX(0, MIN(9, prefs.paddingLeft)), right = (sptr_t)MAX(0, MIN(9, prefs.paddingRight));
    if (_distractionFree) {
        CGFloat w = NSWidth(self.currentDocument.editor.frame);
        if (w <= 0) w = NSWidth([self editorFrameInView:_view]);
        left = right = (sptr_t)(w / MAX(3, MIN(9, prefs.distractionFreeDivPart)));
    }
    for (NPPDocument *d in [self allDocuments]) {
        if (!d.editor) continue;
        NPPSci(d.editor, SCI_SETMARGINLEFT, 0, left);
        NPPSci(d.editor, SCI_SETMARGINRIGHT, 0, right);
    }
}

- (void)windowDidResize:(NSNotification *)notification { [self layoutContent]; }

- (void)showIncrementalBar:(NSNotification *)n {
    if (!_incrementalBar) {
        _incrementalBar = [NPPFindPanelController.shared incrementalSearchBarForEditorProvider:self];
        _incrementalBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    }
    if (_incrementalBar.superview != self.window.contentView) [self.window.contentView addSubview:_incrementalBar];
    _incrementalBar.hidden = NO;
    _incrementalVisible = YES;
    [self layoutContent];
}

- (void)hideIncrementalBar:(NSNotification *)n {
    if (!_incrementalVisible) return;
    _incrementalVisible = NO;
    _incrementalBar.hidden = YES;
    [self layoutContent];
    [self focusEditor];
}

- (void)focusEditor {
    ScintillaView *ed = self.currentDocument.editor;
    if (ed) [self.window makeFirstResponder:[ed content]];
}

#pragma mark - Accessors

// The main view's documents then the sub view's: one flat list for everything that means "every open buffer"
// (session, Find in Files, Save All, Close All). With one view it is that view's list, exactly as before.
- (NSArray<NPPDocument *> *)allDocuments {
    if (_docs[kSubView].count == 0) return [_docs[kMainView] copy];
    return [_docs[kMainView] arrayByAddingObjectsFromArray:_docs[kSubView]];
}
- (NSArray<NPPDocument *> *)documents { return [self allDocuments]; }
- (NPPDocument *)currentDocument { return _cur[_view]; }
- (NPPTabBarView *)tabBar { return _tabBars[_view]; }        // the focused view's strip
- (NPPStatusBarView *)statusBar { return _statusBar; }

- (NSInteger)viewOfDocument:(NPPDocument *)doc {
    if (!doc) return -1;
    for (NSInteger v = kMainView; v <= kSubView; v++)
        if ([_docs[v] indexOfObjectIdenticalTo:doc] != NSNotFound) return v;
    return -1;
}

// Index inside the document's own view — that is what the tab bars, Close All to the Left/Right and the
// tab-order commands work in, matching N++, where they all act on the current view's tab strip.
- (NSInteger)indexOfDocument:(NPPDocument *)doc {
    NSInteger v = [self viewOfDocument:doc];
    return v < 0 ? NSNotFound : (NSInteger)[_docs[v] indexOfObjectIdenticalTo:doc];
}

- (NSInteger)viewForTabBar:(NPPTabBarView *)bar { return bar == _tabBars[kSubView] ? kSubView : kMainView; }

- (nullable NPPDocument *)documentInView:(NSInteger)v atIndex:(NSInteger)index {
    if (v < 0 || v > kSubView || index < 0 || index >= (NSInteger)_docs[v].count) return nil;
    return _docs[v][(NSUInteger)index];
}

#pragma mark - Alerts

- (NSModalResponse)runAlert:(NSString *)message info:(NSString *)info buttons:(NSArray<NSString *> *)buttons style:(NSAlertStyle)style {
    NSAlert *a = [NSAlert new];
    a.messageText = message ?: @"";
    a.informativeText = info ?: @"";
    a.alertStyle = style;
    for (NSString *b in buttons) [a addButtonWithTitle:b];
    return [a runModal];
}

- (void)showError:(NSError *)error title:(NSString *)title {
    NSString *info = error.localizedDescription ?: @"";
    if (error.localizedRecoverySuggestion) info = [info stringByAppendingFormat:@"\n%@", error.localizedRecoverySuggestion];
    [self runAlert:title info:info buttons:@[@"OK"] style:NSAlertStyleCritical];
}

#pragma mark - Tabs (model -> view)

- (void)reloadTabs {
    // ponytail: rebuild every NPPTabItem on any change; document counts are tiny, no per-item diffing needed.
    for (NSInteger v = kMainView; v <= kSubView; v++) {
        NSMutableArray<NPPTabItem *> *items = [NSMutableArray arrayWithCapacity:_docs[v].count];
        for (NPPDocument *d in _docs[v]) {
            NPPTabItem *it = [NPPTabItem new];
            it.title = d.displayName;
            it.toolTip = d.fileURL.path;
            it.dirty = d.isDirty;
            it.readOnly = d.isReadOnly || d.isFileReadOnlyOnDisk;
            it.color = d.tabColor;
            it.monitoring = d.isMonitoring;
            it.pinned = [_pinnedDocs containsObject:d];   // the flag belongs to the buffer; the item is rebuilt
            [items addObject:it];
        }
        _tabBars[v].items = items;
        NSInteger sel = _cur[v] ? (NSInteger)[_docs[v] indexOfObjectIdenticalTo:_cur[v]] : NSNotFound;
        _tabBars[v].selectedIndex = sel == NSNotFound ? -1 : sel;
    }
    // Every add / remove / move lands here, so this is the one place that has to notice a view losing its last
    // document — Close All, Close All but Pinned and Close All Unchanged all collapse the split through it.
    [self checkSyncState];
    [self layoutContent];   // a view that just gained or lost its first document splits or collapses the window
    // ponytail: single funnel — every document add/remove/move/rename/dirty/read-only change lands here,
    // so one broadcast keeps the panels (Document List above all) in sync. N++ has per-event hooks
    // (closeItem / setItemIconStatus); add those if a panel's redraw ever gets expensive enough to notice.
    [_panelHost broadcastCurrentDocument:self.currentDocument];
    [NSNotificationCenter.defaultCenter postNotificationName:NPPCurrentDocumentDidChangeNotification object:self];
    // NPPPreferences configures a brand-new editor off that notification, and its first pass writes the plain
    // Margins padding over what -layoutContent just set. So a buffer opened *while* Distraction Free is on gets
    // the padding back here — the only path where a Scintilla view exists that has never been configured.
    if (_distractionFree) [self applyDistractionFreePadding];
}

#pragma mark - Documents

// New documents join the focused view, like N++ opening into the active view.
- (void)addDocument:(NPPDocument *)doc atIndex:(NSInteger)index {
    [self addDocument:doc atIndex:index inView:_view];
}

- (void)addDocument:(NPPDocument *)doc atIndex:(NSInteger)index inView:(NSInteger)v {
    doc.delegate = self;
    if (index < 0 || index > (NSInteger)_docs[v].count) index = (NSInteger)_docs[v].count;
    [_docs[v] insertObject:doc atIndex:(NSUInteger)index];
    [self reloadTabs];
    [self selectDocument:doc];
}

- (NPPDocument *)newDocument { return [self newDocumentInView:_view]; }

- (NPPDocument *)newDocumentInView:(NSInteger)v {
    NPPDocument *doc = [[NPPDocument alloc] initUntitled];
    [self addDocument:doc atIndex:-1 inView:v];
    return doc;
}

- (BOOL)documentIsUntouchedUntitled:(NPPDocument *)doc {
    return doc && doc.isUntitled && !doc.isDirty && NPPSci(doc.editor, SCI_GETLENGTH) == 0;
}

- (NPPDocument *)documentForURL:(NSURL *)url {
    NSString *path = url.path;
    // Prefer a hit in the focused view: with a clone in the other view, Open should re-activate the copy you are on.
    for (NSInteger i = 0; i < 2; i++)
        for (NPPDocument *d in _docs[i == 0 ? _view : [self otherView]])
            if (d.fileURL && [d.fileURL.path isEqualToString:path]) return d;
    return nil;
}

- (void)addToRecents:(NSURL *)url {
    if (!url.path) return;
    [NPPPreferences.shared addRecentFilePath:url.path];
    [NSNotificationCenter.defaultCenter postNotificationName:NPPRecentFilesDidChange object:self];
}

// Preferences ▸ MISC "Session file extension" / "Workspace file extension" (N++ NppIO.cpp isFileSession /
// isFileWorkspace): a file whose extension matches is not text at all — it is loaded as a session, or handed to
// Project Panel 1 as a workspace. YES when it was taken this way and no buffer should be opened for it.
- (BOOL)openedAsSessionOrWorkspace:(NSURL *)url {
    NSString *path = url.path;
    NPPPreferences *prefs = NPPPreferences.shared;
    BOOL isSession = NPPPathHasUserExtension(path, prefs.sessionFileExtension);
    BOOL isWorkspace = !isSession && NPPPathHasUserExtension(path, prefs.workspaceFileExtension);
    if (!isSession && !isWorkspace) return NO;                                  // both settings are empty by default
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return NO;       // upstream requires it to exist
    if (isSession) {
        NSXMLDocument *xml = [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:NULL];
        if (!xml) {
            [self contextReportStatus:[NSString stringWithFormat:@"\"%@\" is not a session file.", path.lastPathComponent] isError:YES];
            return YES;   // it *is* the session extension: opening it as text is not the fallback the user asked for
        }
        if ([self loadSessionShouldOpenNewInstance] && [self launchNewInstanceWithArguments:@[@"-multiInst", @"-nosession", @"-openSession", path]])
            return YES;
        [self applySessionXMLDocument:xml];
        return YES;
    }
    // N++ setWorkSpaceFilePath(0, …) + launchProjectPanel(IDM_VIEW_PROJECT_PANEL_1): the workspace always lands in
    // the first panel. Reached by name, like every other optional module in this file.
    Class c = NSClassFromString(@"NPPProjectPanel");
    id panel = [c respondsToSelector:@selector(panelAtIndex:)] ? [c panelAtIndex:0] : nil;
    if (![panel respondsToSelector:@selector(openWorkspaceURL:)]) return NO;   // no module: open it as text
    if (![panel openWorkspaceURL:url]) {
        [self contextReportStatus:[NSString stringWithFormat:@"\"%@\" is not a workspace file.", path.lastPathComponent] isError:YES];
        return YES;
    }
    if (![self contextPanelIsVisible:panel]) [self performFeatureCommand:NPPCmdViewProjectPanel1];
    return YES;
}

// N++ NppIO.cpp doOpen: a path that is not there is offered for creation when its folder exists, and refused with
// a "folder doesn't exist" message when it does not. The decision is separate from the two alerts so the headless
// check can walk every branch.
- (NPPMissingFileAction)actionForMissingFileAtURL:(NSURL *)url {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *path = url.path;
    if (!path.length || [fm fileExistsAtPath:path]) return NPPMissingFileNone;
    NSString *dir = path.stringByDeletingLastPathComponent;
    BOOL isDir = NO;
    return (dir.length && [fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) ? NPPMissingFileOfferCreate : NPPMissingFileNoFolder;
}

- (NPPDocument *)openDocumentAtURL:(NSURL *)url {
    if (!url) return nil;
    url = url.URLByStandardizingPath.URLByResolvingSymlinksInPath ?: url;
    if (NPPURLIsDirectory(url)) { [self openFolderURL:url]; return nil; }   // N++ doOpen()'s directory branch

    NPPDocument *existing = [self documentForURL:url];
    if (existing) { [self selectDocument:existing]; return existing; }

    // Upstream order: an already-open buffer wins, then the session / workspace extensions, then "create it?".
    if ([self openedAsSessionOrWorkspace:url]) return nil;
    switch ([self actionForMissingFileAtURL:url]) {
        case NPPMissingFileOfferCreate: {
            NSString *info = [NSString stringWithFormat:@"\"%@\" doesn't exist. Create it?", url.path];
            if ([self runAlert:@"Create new file" info:info buttons:@[@"Yes", @"No"] style:NSAlertStyleInformational] != NSAlertFirstButtonReturn)
                return nil;
            if (![[NSData data] writeToURL:url options:NSDataWritingAtomic error:NULL]) {
                [self runAlert:@"Create new file"
                          info:[NSString stringWithFormat:@"Cannot create the file \"%@\".", url.path]
                       buttons:@[@"OK"] style:NSAlertStyleCritical];
                return nil;
            }
            break;   // it exists now: fall through and open it like any other file
        }
        case NPPMissingFileNoFolder:
            [self runAlert:@"Cannot open file"
                      info:[NSString stringWithFormat:@"\"%@\" cannot be opened:\nFolder \"%@\" doesn't exist.",
                            url.path, url.path.stringByDeletingLastPathComponent]
                   buttons:@[@"OK"] style:NSAlertStyleWarning];
            return nil;
        case NPPMissingFileNone: break;
    }

    NSError *err = nil;
    NPPDocument *doc = [[NPPDocument alloc] initWithContentsOfURL:url error:&err];
    if (!doc) {
        [self showError:err title:[NSString stringWithFormat:@"Cannot open file \"%@\".", url.path]];
        return nil;
    }
    NSArray<NPPDocument *> *all = [self allDocuments];
    NPPDocument *replace = (all.count == 1 && [self documentIsUntouchedUntitled:all.firstObject]) ? all.firstObject : nil;
    [self addDocument:doc atIndex:-1];
    if (replace) [self removeDocument:replace rememberClosed:NO];
    [self addToRecents:url];
    return doc;
}

- (void)openDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *u in urls) [self openDocumentAtURL:u];   // -openDocumentAtURL: sends a folder on to -openFolderURL:
}

// A folder — dropped on the window or the tab bar, or handed over on the command line. N++ NppGUI::
// _isFolderDroppedOpenFiles: off (the default) launches Folder as Workspace, on opens every file inside.
// Files land here through one funnel, so both drop paths and the app delegate get the same behaviour.
- (void)openFolderURL:(NSURL *)folder {
    if (!folder) return;
    if (![NSUserDefaults.standardUserDefaults boolForKey:kFolderDropOpenKey] && [self addFolderAsWorkspace:folder]) return;

    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSDirectoryEnumerator<NSURL *> *e =
        [NSFileManager.defaultManager enumeratorAtURL:folder
                           includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                              options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                                         errorHandler:nil];
    // ponytail: the whole tree is walked before the count can be quoted, exactly as N++ does it — drop a home
    // folder and the main thread is busy for as long as that takes. Enumerate on a queue if anyone ever does.
    for (NSURL *u in e) if (!NPPURLIsDirectory(u)) [files addObject:u];   // recursive, like N++'s getMatchedFileNames
    if (files.count == 0) {
        [self contextReportStatus:[NSString stringWithFormat:@"No files in \"%@\".", folder.lastPathComponent] isError:YES];
        return;
    }
    if (files.count > kFolderDropWarnAt) {   // N++ NbFileToOpenImportantWarning
        NSString *info = [NSString stringWithFormat:@"%lu files are about to be opened.\nAre you sure you want to open them?",
                          (unsigned long)files.count];
        if ([self runAlert:@"Amount of files to open is too large" info:info buttons:@[@"Yes", @"No"] style:NSAlertStyleWarning] != NSAlertFirstButtonReturn) return;
    }
    for (NSURL *u in files) [self openDocumentAtURL:u];
}

// The workspace panel is an optional module: reach it the way every other feature is reached (by name, through
// the command handler table) so this file keeps no dependency on its header. Returns NO when it is not built.
- (BOOL)addFolderAsWorkspace:(NSURL *)folder {
    if (!folder || !NPPWorkspacePanelTakesFolders()) return NO;
    id panel = [NSClassFromString(@"NPPWorkspacePanel") performSelector:@selector(shared)];
    if (!panel) return NO;
    [panel performSelector:@selector(addRootFolderURL:) withObject:folder];
    // Toggling it on (rather than -contextShowPanel:) is what hands the module its command context, so the tree's
    // own double-click-to-open keeps working.
    if (![self contextPanelIsVisible:panel]) [self performFeatureCommand:NPPCmdViewWorkspacePanel];
    return YES;
}

- (BOOL)performFeatureCommand:(NPPCmd)cmd {
    Class h = NPPFeatureHandlerForCommand(cmd);
    return h && [(Class<NPPCommandHandler>)h performCommand:cmd context:self];
}

// Index into -documents (main view then sub view), the order the session and the app delegate use.
- (void)selectDocumentAtIndex:(NSInteger)index {
    NSArray<NPPDocument *> *all = [self allDocuments];
    if (index < 0 || index >= (NSInteger)all.count) return;
    [self selectDocument:all[(NSUInteger)index]];
}

- (void)selectDocument:(NPPDocument *)doc {
    NSInteger v = [self viewOfDocument:doc];
    if (v < 0) return;
    if (doc != _cur[v]) {
        [_cur[v].editor removeFromSuperview];
        _cur[v] = doc;
        ScintillaView *ed = doc.editor;
        ed.frame = [self editorFrameInView:v];   // Margins ▸ Border width, the same inset -layoutContent uses
        ed.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [_containers[v] addSubview:ed];
    }
    _view = v;   // selecting a document focuses the view it lives in
    [_mru removeObjectIdenticalTo:doc];             // N++ TaskListInfo order: most recently used first
    [_mru insertObject:doc atIndex:0];
    NSInteger idx = (NSInteger)[_docs[v] indexOfObjectIdenticalTo:doc];
    _tabBars[v].selectedIndex = idx;
    [_tabBars[v] scrollTabToVisible:idx];
    [self focusEditor];
    [self updateWindowTitle];
    [self updateStatusBar];
    if ([_pendingReloadPrompt containsObject:doc]) {
        [_pendingReloadPrompt removeObject:doc];
        [self promptReloadForDocument:doc];
    }
    [_panelHost broadcastCurrentDocument:doc];
}

// Reorder within one view (drag, Move Tab Forward/Backward). Indices are that view's tab indices.
- (void)moveDocumentAtIndex:(NSInteger)from toIndex:(NSInteger)to inView:(NSInteger)v {
    if (v < 0 || v > kSubView) return;   // _docs is a C array: bound the view *before* indexing it
    NSInteger n = (NSInteger)_docs[v].count;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    NPPDocument *d = _docs[v][(NSUInteger)from];
    [_docs[v] removeObjectAtIndex:(NSUInteger)from];
    [_docs[v] insertObject:d atIndex:(NSUInteger)to];
    [self reloadTabs];
}

- (void)moveDocumentAtIndex:(NSInteger)from toIndex:(NSInteger)to { [self moveDocumentAtIndex:from toIndex:to inView:_view]; }

// Removes without prompting. Keeps a fresh "new 1" when the last tab of the last view goes (N++); a view that
// loses its last document just disappears and the window collapses back to a single view.
- (void)removeDocument:(NPPDocument *)doc rememberClosed:(BOOL)remember {
    NSInteger v = [self viewOfDocument:doc];
    if (v < 0) return;
    NSInteger idx = (NSInteger)[_docs[v] indexOfObjectIdenticalTo:doc];
    if (remember && doc.fileURL) {
        [_closedStack removeObject:doc.fileURL];
        [_closedStack addObject:doc.fileURL];
        while (_closedStack.count > kClosedStackMax) [_closedStack removeObjectAtIndex:0];
    }
    [_pendingReloadPrompt removeObject:doc];
    [_pinnedDocs removeObject:doc];
    [_mru removeObjectIdenticalTo:doc];
    // A ⌃Tab run holding this buffer would commit a document that is no longer open (a silent no-op): end the run.
    if (_switcherOrder && [_switcherOrder indexOfObjectIdenticalTo:doc] != NSNotFound) {
        [_switcher orderOut:nil];
        _switcherOrder = nil;
    }
    doc.isMonitoring = NO;
    doc.delegate = nil;
    [_docs[v] removeObjectAtIndex:(NSUInteger)idx];
    if (doc == _cur[v]) {
        [doc.editor removeFromSuperview];
        _cur[v] = nil;
    }
    if (_docs[kMainView].count == 0 && _docs[kSubView].count == 0) {
        _view = kMainView;
        // N++ NppGUI::_isExitOnClosingLastTab: the last tab takes the application with it instead of leaving a
        // fresh "new 1". Only for the window that is actually on screen — a headless controller never quits the app.
        if (_didShowWindow && NPPPreferences.shared.exitOnClosingLastTab) {
            [self reloadTabs];
            [NSApp terminate:nil];   // returns only when the quit was cancelled — then fall through, never leave
        }                            // the window with no buffer at all
        [self newDocument];
        return;
    }
    if (_docs[v].count == 0) {                      // that view is gone: fall back to the one still holding documents
        _view = 1 - v;
        [self reloadTabs];   // drops the scroll syncs on the way through -checkSyncState
        [self selectDocument:_cur[_view] ?: _docs[_view].firstObject];
        return;
    }
    [self reloadTabs];
    if (!_cur[v]) [self selectDocument:[self documentInView:v atIndex:MIN(idx, (NSInteger)_docs[v].count - 1)]];
}

// The answer N++ Notepad_plus::doSaveOrNot(fn, isMulti) comes back with. One dirty file in the batch gets the
// three plain buttons; two or more grow the two "…to All" ones, so closing ten modified files is one decision.
typedef NS_ENUM(NSInteger, NPPSaveAnswer) {
    NPPSaveAnswerSave = 0,   // IDYES     — the button order *is* the mapping: index into the button array below
    NPPSaveAnswerDont,       // IDNO
    NPPSaveAnswerCancel,     // IDCANCEL  — abort the whole batch
    NPPSaveAnswerSaveAll,    // IDRETRY   — "Yes to all": this one and every one after it
    NPPSaveAnswerDontAll,    // IDIGNORE  — "No to all"
};

// What the prompt would have answered. Set only by the headless checks at the bottom of this file: the prompt is
// modal, and a self-check that puts one on screen never returns.
static NPPSaveAnswer (^gSaveAnswerStub)(NPPDocument *doc, BOOL offersAll) = nil;

- (NPPSaveAnswer)askToSaveDocument:(NPPDocument *)doc offeringAll:(BOOL)offersAll {
    if (gSaveAnswerStub) return gSaveAnswerStub(doc, offersAll);
    NSArray<NSString *> *buttons = offersAll ? @[@"Save", @"Don't Save", @"Cancel", @"Save All", @"Don't Save Any"]
                                             : @[@"Save", @"Don't Save", @"Cancel"];
    NSModalResponse r = [self runAlert:[NSString stringWithFormat:@"Save file \"%@\" ?", doc.displayName] info:@""
                               buttons:buttons style:NSAlertStyleWarning];
    NSInteger i = r - NSAlertFirstButtonReturn;
    return (i >= 0 && i < (NSInteger)buttons.count) ? (NPPSaveAnswer)i : NPPSaveAnswerCancel;
}

// The one place a batch of buffers is asked about, so every Close All / Close to the Left / quit path offers the
// same two "…to All" buttons and stops on the same Cancel. NO means the whole operation is off: upstream aborts
// the entire procedure the moment a save fails or is cancelled, and closes nothing.
- (BOOL)confirmSaveOfDocuments:(NSArray<NPPDocument *> *)docs {
    NSInteger dirty = 0;
    for (NPPDocument *d in docs) if (d.isDirty) dirty++;
    BOOL saveAll = NO, dontSaveAny = NO;
    for (NPPDocument *d in docs) {
        if (!d.isDirty || dontSaveAny) continue;
        if (!saveAll) {
            [self selectDocument:d];
            switch ([self askToSaveDocument:d offeringAll:dirty > 1]) {
                case NPPSaveAnswerCancel:  return NO;
                case NPPSaveAnswerDont:    continue;
                case NPPSaveAnswerDontAll: dontSaveAny = YES; continue;
                case NPPSaveAnswerSaveAll: saveAll = YES; break;
                case NPPSaveAnswerSave:    break;
            }
        }
        if (![self saveDocument:d]) return NO;   // a failed write, or a Save As the user cancelled
    }
    return YES;
}

- (BOOL)closeDocument:(NPPDocument *)doc {
    if (!doc || [self indexOfDocument:doc] == NSNotFound) return YES;
    if (![self confirmSaveOfDocuments:@[doc]]) return NO;
    [self removeDocument:doc rememberClosed:YES];
    return YES;
}

// N++ fileCloseAll: every dirty buffer is asked about first and nothing is closed until they all have an answer,
// so Cancel leaves the batch exactly as it was instead of half closed.
- (BOOL)closeDocuments:(NSArray<NPPDocument *> *)docs {
    if (![self confirmSaveOfDocuments:docs]) return NO;
    for (NPPDocument *d in docs) [self removeDocument:d rememberClosed:YES];
    return YES;
}

- (BOOL)closeAllDocuments { return [self closeDocuments:[self allDocuments]]; }

- (BOOL)hasDirtyDocuments {
    for (NPPDocument *d in [self allDocuments]) if (d.isDirty) return YES;
    return NO;
}

- (BOOL)promptToSaveAllBeforeQuit {
    if (_quitApproved) return YES;
    if (![self confirmSaveOfDocuments:[self allDocuments]]) return NO;
    [self storeSessionInPreferences];
    // A panel closed by its own close button never went through -panelsDidChange, so take the list once more on the
    // way out — N++ writes the *KeepState flags with the rest of its config at shutdown.
    [self rememberOpenPanels];
    return YES;
}

// The session the next launch restores. Two preferences carry the flat list (NPPAppDelegate and NPPCommandLine
// read them and are not ours to change); everything else a session knows — language, read-only, selection, first
// visible line, bookmarks, and which of the two views each file was in — goes to the same XML Save Session
// writes. -restoreAutoSession reads it back before the delegate re-opens the paths, so the delegate's pass then
// only re-activates tabs that are already open and the two never disagree about order or selection.
- (void)storeSessionInPreferences {
    // -nosession (and -quickPrint / -export=functionList, which imply it): this launch leaves the stored session
    // alone. NPPAppDelegate's own -saveSession asks the same question; without it here a one-file -quickPrint run
    // would quit through -promptToSaveAllBeforeQuit and replace the user's whole session with that one file.
    if (!NPPSessionSwitchAllows(/*restoringAtLaunch=*/NO, NULL)) return;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSInteger sel = 0;
    for (NPPDocument *d in [self allDocuments]) {
        if (!d.fileURL) continue;
        if (d == self.currentDocument) sel = (NSInteger)paths.count;
        [paths addObject:d.fileURL.path];
    }
    NPPPreferences.shared.sessionFilePaths = paths;
    NPPPreferences.shared.sessionSelectedIndex = sel;

    NSURL *url = [self autoSessionURL];
    if (!url) return;   // no backup module: the auto-session stays the flat path list, exactly as it always was
    // Untitled buffers are left out on purpose: NPPBackupManager already snapshots unsaved work and restores it
    // after a crash, and a second copy here would resurrect buffers the quit prompt was told not to save.
    NSData *data = [[self sessionXMLDocumentParkingUntitled:NO] XMLDataWithOptions:NSXMLNodePrettyPrint];
    [data writeToURL:url options:NSDataWritingAtomic error:NULL];   // written every time: never restore a stale one
}

// Where that XML lives: beside NPPBackupManager's snapshot folder rather than inside it (N++ keeps session.xml in
// its config folder, next to backup/). nil when the backup module is not built.
- (NSURL *)autoSessionURL {
    NSURL *dir = [self sessionBackupDirectory].URLByDeletingLastPathComponent;
    return dir ? [dir URLByAppendingPathComponent:@"session.xml"] : nil;
}

// Reads it back. Files that have gone missing are dropped instead of reported: the delegate's path filters the
// same way, and an alert per vanished file is not how an app should come up. NO when there was nothing to restore.
- (BOOL)restoreAutoSession {
    NSURL *url = [self autoSessionURL];
    NSXMLDocument *xml = url ? [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:NULL] : nil;
    if (!xml) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSXMLNode *n in [xml nodesForXPath:@"//File" error:NULL]) {
        NSString *path = [(NSXMLElement *)n attributeForName:@"filename"].stringValue;
        if (!path.length || ![fm fileExistsAtPath:path]) [n detach];
    }
    if ([xml nodesForXPath:@"//File" error:NULL].count == 0) return NO;
    [self applySessionXMLDocument:xml];
    return YES;
}

// Startup. Literally the same gate as NPPAppDelegate's own restore — the preference, and NPPCommandLine's own
// answer to "does this launch restore a session" (NO under -nosession, and NO when files were named, which the
// delegate opens instead) — so this replaces nothing the delegate would not have done itself. Asking NPPCommandLine
// rather than re-reading argv is the point: -quickPrint and -export=functionList imply -nosession, and a
// hand-rolled "does it start with a dash" scan says yes to both.
- (void)restoreAutoSessionAtLaunch {
    if (!NPPPreferences.shared.rememberLastSession) return;
    if (!NPPSessionSwitchAllows(/*restoringAtLaunch=*/YES, NULL)) return;
    if (NPPAutomatedRun()) return;   // as for the remembered panels: a sweep must drive the files it was given
    NSArray<NPPDocument *> *all = [self allDocuments];
    if (all.count != 1 || ![self documentIsUntouchedUntitled:all.firstObject]) return;
    [self restoreAutoSession];
}

#pragma mark - Saving

// N++ OpenSaveDirSetting (Preferences ▸ Default Directory): what an Open / Save panel starts on.
//   0 dir_followCurrent — the current document's folder
//   1 dir_last          — wherever the last panel ended up
//   2 dir_userDef       — a fixed folder
// Each mode falls back to the others rather than opening on something arbitrary when its own answer is missing.
- (NSURL *)defaultPanelDirectoryForDocument:(NPPDocument *)doc {
    NPPPreferences *prefs = NPPPreferences.shared;
    NSURL *docDir = doc.fileURL ? doc.fileURL.URLByDeletingLastPathComponent : nil;
    NSString *fixedPath = prefs.defaultDirectoryPath.stringByExpandingTildeInPath;
    NSURL *fixed = fixedPath.length ? [NSURL fileURLWithPath:fixedPath isDirectory:YES] : nil;
    if (fixed && !NPPURLIsDirectory(fixed)) fixed = nil;
    switch (prefs.defaultDirectoryMode) {
        case 2: if (fixed) return fixed; break;
        case 1: if (_lastUsedDirectory) return _lastUsedDirectory; break;
        default: if (docDir) return docDir; break;
    }
    return docDir ?: (_lastUsedDirectory ?: fixed);
}

#pragma mark - Open / Save file-type filter (N++ Notepad_plus::setFileOpenSaveDlgFilters)

// N++ NppGUI::_setSaveDlgExtFiltToAllTypes, inverted: with the box ticked the Save panel puts the chosen type's
// extension on the name — which on macOS is what the panel does by itself once other types are refused. Read
// straight from NSUserDefaults, the contract a Preferences page would bind to (as for the two switcher keys).
static NSString *const kSaveAppendExtKey = @"NPPSaveDialogAppendExtension";   // default YES, like upstream's box

- (BOOL)saveDialogAppendsExtension {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:kSaveAppendExtKey];
    return v ? v.boolValue : YES;
}

// The languages the filter list offers, in Language-menu order: every one that actually claims an extension
// (upstream skips a language whose filter string comes out empty, which is how "Normal Text" drops out).
// ponytail: built-in languages only. N++ appends the user-defined ones; a UDL carries no extension list in this
// port, so its filter would match nothing. Add them here once NPPUserDefinedLanguages can name its extensions.
- (NSArray<NPPLanguage *> *)fileTypeFilterLanguages {
    // N++ setFileOpenSaveDlgFilters skips L_TEXT: "Normal text" is what you pick when you want no filter, and its
    // own extension list would narrow the panel to exactly the files the "All types" row already shows.
    NPPLanguage *normal = NPPLanguageManager.shared.normalTextLanguage;
    NSMutableArray<NPPLanguage *> *out = [NSMutableArray array];
    for (NPPLanguage *l in NPPLanguageManager.shared.languages)
        if (l.extensions.count && l != normal) [out addObject:l];
    return out;
}

// nil — the "All types" row — means no filtering at all.
- (NSArray<UTType *> *)contentTypesForFilterLanguage:(NPPLanguage *)lang {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *ext in lang.extensions) {
        UTType *t = [UTType typeWithFilenameExtension:ext];   // an extension macOS has no type for gets a dynamic one
        if (t && ![types containsObject:t]) [types addObject:t];
    }
    return types;
}

// One row per language, "All types" first, the document's own language pre-selected (N++ setExtIndex). Built with
// NSMenuItems rather than -addItemWithTitle:, which would drop an earlier row that happened to share a title.
- (NSPopUpButton *)fileTypeFilterPopUpSelecting:(NPPLanguage *)lang {
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 340, 25) pullsDown:NO];
    [popUp.menu addItem:[[NSMenuItem alloc] initWithTitle:@"All types (*.*)" action:NULL keyEquivalent:@""]];
    for (NPPLanguage *l in [self fileTypeFilterLanguages]) {
        NSMutableString *exts = [NSMutableString string];
        // N++ exts2Filters caps the label at 40 characters on a Save dialog; the filter itself still uses them all.
        for (NSString *e in l.extensions) {
            if (exts.length > 40) { [exts appendString:@";…"]; break; }
            [exts appendFormat:@"%@*.%@", exts.length ? @";" : @"", e];
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%@)", l.longName ?: l.shortName, exts]
                                                      action:NULL keyEquivalent:@""];
        item.representedObject = l;
        [popUp.menu addItem:item];
        if (lang && (l == lang || [l.name isEqualToString:lang.name])) [popUp selectItem:item];
    }
    popUp.target = self;
    popUp.action = @selector(fileTypeFilterChanged:);
    return popUp;
}

// Both panels' filter in one place. "All types" clears it; a language restricts to its extensions; and on a Save
// panel the "Append extension" box decides whether a name the filter does not match is still allowed — with it
// off the panel keeps whatever was typed, with it on macOS completes the extension for us.
- (void)applyFileTypeFilter {
    NSSavePanel *p = _filterPanel;
    if (!p) return;
    NPPLanguage *lang = _filterPopUp.selectedItem.representedObject;
    NSArray<UTType *> *types = lang ? [self contentTypesForFilterLanguage:lang] : @[];
    p.allowedContentTypes = types;
    if (_filterAppendCheck) {
        BOOL append = _filterAppendCheck.state == NSControlStateValueOn;
        [NSUserDefaults.standardUserDefaults setBool:append forKey:kSaveAppendExtKey];   // upstream remembers it too
        p.allowsOtherFileTypes = !(append && types.count);
    }
}

- (void)fileTypeFilterChanged:(id)sender { [self applyFileTypeFilter]; }

// Hangs the filter (and, for a Save panel, the "Append extension" box) under the panel and applies it once.
- (void)attachFileTypeFilterToPanel:(NSSavePanel *)panel language:(NPPLanguage *)lang appendExtensionBox:(BOOL)withBox {
    NSPopUpButton *popUp = [self fileTypeFilterPopUpSelecting:lang];
    NSStackView *row = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"File type:"], popUp]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    NSButton *box = nil;
    if (withBox) {
        box = [NSButton checkboxWithTitle:@"Append extension" target:self action:@selector(fileTypeFilterChanged:)];
        box.state = [self saveDialogAppendsExtension] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    NSStackView *stack = [NSStackView stackViewWithViews:box ? @[row, box] : @[row]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.edgeInsets = NSEdgeInsetsMake(10, 16, 10, 16);
    panel.accessoryView = stack;
    _filterPanel = panel;
    _filterPopUp = popUp;
    _filterAppendCheck = box;
    [self applyFileTypeFilter];
}

#pragma mark - Saving (continued)

- (NSSavePanel *)savePanelForDocument:(NPPDocument *)doc title:(NSString *)title {
    NSSavePanel *p = [NSSavePanel savePanel];
    p.title = title;
    p.nameFieldStringValue = doc.displayName ?: @"";
    p.canCreateDirectories = YES;
    p.allowsOtherFileTypes = YES;
    p.extensionHidden = NO;
    p.treatsFilePackagesAsDirectories = YES;
    NSURL *dir = [self defaultPanelDirectoryForDocument:doc];
    if (dir) p.directoryURL = dir;
    [self attachFileTypeFilterToPanel:p language:doc.language appendExtensionBox:YES];
    return p;
}

- (BOOL)saveDocument:(NPPDocument *)doc {
    if (!doc) return NO;
    if (doc.isUntitled || ![NSFileManager.defaultManager fileExistsAtPath:doc.fileURL.path]) return [self saveDocumentAs:doc];
    NSError *err = nil;
    if (![doc saveToURL:doc.fileURL error:&err]) {
        [self showError:err title:[NSString stringWithFormat:@"Save failed: \"%@\"", doc.fileURL.path]];
        return NO;
    }
    [self addToRecents:doc.fileURL];
    [self refreshDocument:doc];
    return YES;
}

- (BOOL)saveDocumentAs:(NPPDocument *)doc {
    if (!doc) return NO;
    [self selectDocument:doc];
    NSSavePanel *p = [self savePanelForDocument:doc title:@"Save As"];
    if ([p runModal] != NSModalResponseOK || !p.URL) return NO;
    _lastUsedDirectory = p.URL.URLByDeletingLastPathComponent;
    NPPDocument *other = [self documentForURL:p.URL];
    if (other && other != doc) {
        // N++: "The file is already opened in Notepad++" — refuse rather than end up with two buffers on one path.
        [self runAlert:@"The file is already opened in Notepad++." info:p.URL.path buttons:@[@"OK"] style:NSAlertStyleWarning];
        return NO;
    }
    NSError *err = nil;
    if (![doc saveToURL:p.URL error:&err]) {
        [self showError:err title:[NSString stringWithFormat:@"Save failed: \"%@\"", p.URL.path]];
        return NO;
    }
    [self addToRecents:p.URL];
    [self refreshDocument:doc];
    return YES;
}

- (BOOL)saveCopyAs:(NPPDocument *)doc {
    NSSavePanel *p = [self savePanelForDocument:doc title:@"Save a Copy As"];
    if ([p runModal] != NSModalResponseOK || !p.URL) return NO;
    _lastUsedDirectory = p.URL.URLByDeletingLastPathComponent;
    NSError *err = nil;
    if (![doc saveCopyToURL:p.URL error:&err]) {
        [self showError:err title:[NSString stringWithFormat:@"Save failed: \"%@\"", p.URL.path]];
        return NO;
    }
    return YES;
}

// N++ NppIO.cpp fileSaveAll: one dirty buffer and it is the one you are looking at goes straight to disk; anything
// else asks first, while Preferences ▸ MISC "Enable the Save All confirmation dialog" is on.
- (BOOL)saveAllNeedsConfirmation {
    if (!NPPPreferences.shared.saveAllConfirm) return NO;
    NSInteger dirty = 0;
    for (NPPDocument *d in [self allDocuments]) if (d.isDirty) dirty++;
    if (dirty == 0) return NO;
    return !(dirty == 1 && self.currentDocument.isDirty);
}

- (BOOL)saveAllDocuments {
    if ([self saveAllNeedsConfirmation]) {
        // N++ DoSaveAllBox: Yes / Always yes / No, where "Always yes" unticks the preference for good.
        NSModalResponse r = [self runAlert:@"Are you sure you want to save all modified documents?"
                                      info:@"Choose \"Always Yes\" if you don't want to see this dialog again.\n"
                                            "You can re-activate this dialog in Preferences later."
                                   buttons:@[@"Yes", @"Always Yes", @"No"] style:NSAlertStyleWarning];
        if (r == NSAlertThirdButtonReturn) return NO;
        if (r == NSAlertSecondButtonReturn) NPPPreferences.shared.saveAllConfirm = NO;
    }
    BOOL ok = YES;
    for (NPPDocument *d in [self allDocuments]) if (d.isDirty && ![self saveDocument:d]) ok = NO;
    return ok;
}

- (void)renameDocument:(NPPDocument *)doc {
    if (!doc.fileURL) return;
    NSSavePanel *p = [self savePanelForDocument:doc title:@"Rename"];
    p.prompt = @"Rename";
    if ([p runModal] != NSModalResponseOK || !p.URL) return;
    _lastUsedDirectory = p.URL.URLByDeletingLastPathComponent;   // a file dialog landed here: N++ dir_last, as for the others
    if ([p.URL.path isEqualToString:doc.fileURL.path]) return;
    if ([self documentForURL:p.URL]) {
        [self runAlert:@"The file is already opened in Notepad++." info:p.URL.path buttons:@[@"OK"] style:NSAlertStyleWarning];
        return;
    }
    NSError *err = nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:p.URL.path] && ![fm removeItemAtURL:p.URL error:&err]) { [self showError:err title:@"Rename failed"]; return; }
    if (![fm moveItemAtURL:doc.fileURL toURL:p.URL error:&err]) { [self showError:err title:@"Rename failed"]; return; }
    doc.fileURL = p.URL;
    NPPLanguage *lang = [NPPLanguageManager.shared languageForFileURL:p.URL];
    if (lang && lang != doc.language) doc.language = lang;
    [self addToRecents:p.URL];
    [self refreshDocument:doc];
}

- (void)moveDocumentToTrash:(NPPDocument *)doc {
    if (!doc.fileURL) return;
    NSModalResponse r = [self runAlert:@"Delete file" info:[NSString stringWithFormat:@"Are you sure you want to move \"%@\" to the Trash?", doc.fileURL.path]
                               buttons:@[@"OK", @"Cancel"] style:NSAlertStyleWarning];
    if (r != NSAlertFirstButtonReturn) return;
    NSError *err = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:doc.fileURL resultingItemURL:NULL error:&err]) {
        [self showError:err title:@"Delete File failed"];
        return;
    }
    [self removeDocument:doc rememberClosed:NO];
}

- (void)reloadDocument:(NPPDocument *)doc {
    if (!doc.fileURL) return;
    if (doc.isDirty) {
        NSModalResponse r = [self runAlert:@"Reload" info:@"Are you sure you want to reload the current file and lose the changes made in Notepad++?"
                                   buttons:@[@"Yes", @"No"] style:NSAlertStyleWarning];
        if (r != NSAlertFirstButtonReturn) return;
    }
    NSError *err = nil;
    if (![doc reloadFromDisk:&err]) [self showError:err title:[NSString stringWithFormat:@"Cannot reload \"%@\"", doc.fileURL.path]];
    [self refreshDocument:doc];
}

// Preferences ▸ MISC "Update silently" (N++ cdAutoUpdate, plus cdGo2end for "Scroll to the last line after update").
// A dirty buffer is still asked about — reloading it silently would throw the user's edits away (Notepad_plus.cpp:
// `if (!autoUpdate || buffer->isDirty())`). Returns YES when the reload was handled without asking.
- (BOOL)reloadDocumentSilentlyIfPreferred:(NPPDocument *)doc {
    NPPFileAutoDetection mode = NPPPreferences.shared.fileAutoDetection;
    BOOL silent = (mode == NPPFileAutoDetectionSilent || mode == NPPFileAutoDetectionSilentGoToEnd);
    if (!silent || doc.isDirty) return NO;
    if (![doc reloadFromDisk:NULL]) return NO;   // failed: fall through to the prompt, which reports the error
    if (mode == NPPFileAutoDetectionSilentGoToEnd) NPPSci(doc.editor, SCI_DOCUMENTEND);
    [_declinedReloadDates removeObjectForKey:doc];
    [self refreshDocument:doc];
    return YES;
}

- (void)promptReloadForDocument:(NPPDocument *)doc {
    if (!doc.fileURL) return;
    if ([self reloadDocumentSilentlyIfPreferred:doc]) return;
    // N++ asks once per external change. Remember the timestamp the user declined (or that failed to reload), otherwise
    // every window activation would ask again for the very same change.
    NSDate *diskDate = nil;
    [doc.fileURL getResourceValue:&diskDate forKey:NSURLContentModificationDateKey error:NULL];
    if (!_declinedReloadDates) _declinedReloadDates = [NSMapTable weakToStrongObjectsMapTable];
    NSDate *declined = [_declinedReloadDates objectForKey:doc];
    if (declined && diskDate && [declined isEqualToDate:diskDate]) return;

    NSString *info = doc.isDirty
        ? @"This file has been modified by another program.\nDo you want to reload it and lose the changes made in Notepad++?"
        : @"This file has been modified by another program.\nDo you want to reload it?";
    NSModalResponse r = [self runAlert:[NSString stringWithFormat:@"\"%@\"", doc.fileURL.path] info:info buttons:@[@"Yes", @"No"] style:NSAlertStyleWarning];
    BOOL reloaded = NO;
    if (r == NSAlertFirstButtonReturn) {
        NSError *err = nil;
        reloaded = [doc reloadFromDisk:&err];
        if (!reloaded) [self showError:err title:@"Reload failed"];
    }
    if (reloaded) [_declinedReloadDates removeObjectForKey:doc];
    else if (diskDate) [_declinedReloadDates setObject:diskDate forKey:doc];   // do not ask again until it changes again
    [self refreshDocument:doc];
}

// Which NPPPrintRenderer entry point a print goes through. A function rather than a literal at the call site so
// the Print Now self-check can ask exactly what the printer asks: a check that only asked whether the renderer
// publishes the no-panel selector would still pass with Print Now routed back to the plain-text fallback.
static SEL NPPPrintRendererSelector(BOOL showPanel, BOOL hasSelection) {
    if (!showPanel) return @selector(printEditor:documentName:window:showPanel:);   // N++ filePrint(false)
    return hasSelection ? @selector(printSelectionOfEditor:documentName:window:)
                        : @selector(printEditor:documentName:window:);
}

- (void)printDocument:(NPPDocument *)doc { [self printDocument:doc showPanel:YES]; }

// IDM_FILE_PRINT (showPanel) / IDM_FILE_PRINTNOW (N++ filePrint(false): straight to the printer). Both take the
// syntax-coloured path — Print Now is the same renderer with showPanel:NO.
- (void)printDocument:(NPPDocument *)doc showPanel:(BOOL)showPanel {
    if (!doc) return;
    // Syntax-coloured printing goes through Scintilla's SCI_FORMATRANGEFULL (NPPPrintRenderer, N++'s Printer.cpp).
    // Named rather than imported, like every other optional module here: a build without it falls through below.
    Class renderer = NSClassFromString(@"NPPPrintRenderer");
    BOOL hasSelection = NPPSci(doc.editor, SCI_GETSELECTIONEMPTY) == 0;
    // ponytail: Print Now prints the whole document even with a selection (N++ hands Printer the selection range
    // either way) — the renderer has no printSelectionOfEditor:…:showPanel:. Route one here if it grows one.
    SEL sel = NPPPrintRendererSelector(showPanel, hasSelection);
    if ([renderer respondsToSelector:sel]) {
        NSMethodSignature *sig = [renderer methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = renderer;
        inv.selector = sel;
        ScintillaView *ed = doc.editor;
        NSString *name = doc.displayName;
        NSWindow *win = self.window;
        [inv setArgument:&ed atIndex:2];
        [inv setArgument:&name atIndex:3];
        [inv setArgument:&win atIndex:4];
        if (!showPanel) { BOOL panel = NO; [inv setArgument:&panel atIndex:5]; }
        [inv invoke];
        return;
    }
    // Fallback when the renderer is not built: plain text through an NSTextView, in one font.
    std::string text = NPPSciGetText(doc.editor);
    NSString *s = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
    char fontName[256] = {0};
    NPPSciStr(doc.editor, SCI_STYLEGETFONT, STYLE_DEFAULT, fontName);
    CGFloat size = (CGFloat)NPPSci(doc.editor, SCI_STYLEGETSIZE, STYLE_DEFAULT);
    NSFont *font = [NSFont fontWithName:@(fontName) size:size > 0 ? size : 11] ?: [NSFont userFixedPitchFontOfSize:11];

    NSPrintInfo *pi = [NSPrintInfo.sharedPrintInfo copy];
    pi.horizontalPagination = NSPrintingPaginationModeFit;
    pi.verticalPagination = NSPrintingPaginationModeAutomatic;
    NSRect page = pi.imageablePageBounds;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(page), NSHeight(page))];
    tv.font = font;
    tv.string = s;
    tv.textContainer.widthTracksTextView = YES;
    tv.verticallyResizable = YES;
    [tv sizeToFit];
    NSPrintOperation *op = [NSPrintOperation printOperationWithView:tv printInfo:pi];
    op.jobTitle = doc.displayName;
    op.showsPrintPanel = showPanel;
    [op runOperation];
}

#pragma mark - Sessions (N++ session.xml)

// Where an untitled buffer's text is parked so a session can carry it (N++ writes session backups into the same
// backup folder). Reuses NPPBackupManager's directory instead of inventing a second one; nil when it is not built,
// and then untitled buffers are skipped exactly as they were before.
- (NSURL *)sessionBackupDirectory {
    Class c = NSClassFromString(@"NPPBackupManager");
    if (![c respondsToSelector:@selector(shared)]) return nil;
    id mgr = [c performSelector:@selector(shared)];
    if (![mgr respondsToSelector:@selector(snapshotDirectory)]) return nil;
    NSURL *dir = [mgr performSelector:@selector(snapshotDirectory)];
    if (!dir) return nil;
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

// The lines carrying a bookmark, as N++ writes them: <File …><Mark line="12"/>…</File>.
static NSArray<NSNumber *> *NPPBookmarkedLines(ScintillaView *ed) {
    NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
    const int mask = 1 << NPPMarkerBookmark;
    for (sptr_t l = NPPSci(ed, SCI_MARKERNEXT, 0, mask); l >= 0; l = NPPSci(ed, SCI_MARKERNEXT, (uptr_t)(l + 1), mask))
        [lines addObject:@(l)];
    return lines;
}

// The collapsed fold headers, as N++ writes them: <File …><Fold line="12"/>…</File>. Port of
// ScintillaEditView::getCurrentFoldStates — SCI_CONTRACTEDFOLDNEXT walks straight to the next collapsed header
// instead of asking every line of the document.
static NSArray<NSNumber *> *NPPContractedFoldLines(ScintillaView *ed) {
    NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
    for (sptr_t l = NPPSci(ed, SCI_CONTRACTEDFOLDNEXT, 0); l >= 0; l = NPPSci(ed, SCI_CONTRACTEDFOLDNEXT, (uptr_t)(l + 1)))
        [lines addObject:@(l)];
    return lines;
}

// N++ ScintillaEditView::syncFoldStateWith. SCI_FOLDLINE only does something on a line the lexer has already
// given SC_FOLDLEVELHEADERFLAG to, and Scintilla styles lazily — so style up to the last line we are about to
// fold first, or every fold in the session silently reopens. A large file has no styling (and so no folds) at
// all, and is left alone rather than made to lex hundreds of megabytes on the way up.
static void NPPRestoreContractedFoldLines(NPPDocument *doc, NSArray<NSNumber *> *lines) {
    ScintillaView *ed = doc.editor;
    if (!ed || !lines.count || doc.isLargeFile) return;
    sptr_t last = 0;
    for (NSNumber *l in lines) last = MAX(last, l.longLongValue);
    // One line past the last fold, because a lexer settles a line's fold level only once it has read past its end.
    // SCI_POSITIONFROMLINE answers -1 beyond the last line, which SCI_COLOURISE reads as "to the end" — the same
    // thing when the fold is that close to the bottom.
    NPPSci(ed, SCI_COLOURISE, 0, NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)(last + 2)));
    for (NSNumber *l in lines) NPPSci(ed, SCI_FOLDLINE, (uptr_t)l.longLongValue, SC_FOLDACTION_CONTRACT);
}

- (void)saveSession {
    NSSavePanel *p = [NSSavePanel savePanel];
    p.title = @"Save Session";
    NSArray<UTType *> *types = [self sessionPanelContentTypes];   // the configured session extension first
    p.nameFieldStringValue = [@"session" stringByAppendingPathExtension:types.firstObject.preferredFilenameExtension ?: @"xml"];
    p.allowedContentTypes = types;
    p.allowsOtherFileTypes = YES;
    p.canCreateDirectories = YES;
    NSURL *startDir = [self defaultPanelDirectoryForDocument:self.currentDocument];
    if (startDir) p.directoryURL = startDir;
    if ([p runModal] != NSModalResponseOK || !p.URL) return;

    NSError *err = nil;
    if (![[[self sessionXMLDocument] XMLDataWithOptions:NSXMLNodePrettyPrint] writeToURL:p.URL options:NSDataWritingAtomic error:&err])
        [self showError:err title:@"Save Session failed"];
    _lastUsedDirectory = p.URL.URLByDeletingLastPathComponent;
}

- (NSXMLDocument *)sessionXMLDocument { return [self sessionXMLDocumentParkingUntitled:YES]; }

// `park` is what makes an untitled buffer part of the session: its text is written into the backup folder and
// `backupFilePath` points at it (N++ does the same). With NO — the auto-session, whose untitled buffers belong to
// NPPBackupManager — untitled buffers are skipped, the same branch a build with no backup folder already takes.
- (NSXMLDocument *)sessionXMLDocumentParkingUntitled:(BOOL)park {
    NSURL *backupDir = park ? [self sessionBackupDirectory] : nil;
    NSXMLElement *root = [NSXMLElement elementWithName:@"NotepadPlus"];
    NSXMLElement *session = [NSXMLElement elementWithName:@"Session"];
    [session addAttribute:[NSXMLNode attributeWithName:@"activeView" stringValue:@(_view).stringValue]];
    // <mainView> and <subView>, so a saved session carries which view each file was in — the split survives a
    // Save Session / Load Session round trip even though the auto-restored session is a flat list of paths.
    for (NSInteger v = kMainView; v <= kSubView; v++) {
        NSXMLElement *viewEl = [NSXMLElement elementWithName:(v == kMainView ? @"mainView" : @"subView")];
        NSInteger active = 0, i = 0;
        for (NPPDocument *d in _docs[v]) {
            ScintillaView *ed = d.editor;
            if (!ed) continue;
            // N++ keeps an untitled buffer in the session by parking its text in the backup folder and pointing
            // `backupFilePath` at it. Skipped only when there is nowhere to park it.
            NSString *backupPath = @"";
            if (!d.fileURL) {
                NSURL *dst = backupDir ? [backupDir URLByAppendingPathComponent:
                                          [NSString stringWithFormat:@"session@%@", d.displayName]] : nil;
                std::string text = NPPSciGetText(ed);
                NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
                // ponytail: one file per untitled buffer *name*, so two sessions holding a "new 1" share it and the
                // newest write wins. Name it after the session file instead if that ever bites.
                if (!dst || ![data writeToURL:dst options:NSDataWritingAtomic error:NULL]) continue;
                backupPath = dst.path;
            }
            if (d == _cur[v]) active = i;
            NSXMLElement *f = [NSXMLElement elementWithName:@"File"];
            NSDictionary *attrs = @{
                @"firstVisibleLine": @(NPPSci(ed, SCI_GETFIRSTVISIBLELINE)).stringValue,
                @"xOffset": @"0", @"scrollWidth": @"0",
                @"startPos": @(NPPSci(ed, SCI_GETSELECTIONSTART)).stringValue,
                @"endPos": @(NPPSci(ed, SCI_GETSELECTIONEND)).stringValue,
                @"selMode": @"0", @"offset": @"0", @"wrapCount": @"1",
                @"lang": d.language.shortName ?: @"Normal Text",
                // N++ Buffer::getEncoding(): -1 unless the buffer is being read as an 8-bit code page, and then the
                // code page itself, so a character set the user picked by hand survives a restart. The number is a
                // CFStringEncoding, not N++'s EncodingMapper index — the two are not the same table.
                @"encoding": d.encoding == NPPEncodingANSI ? @((long long)d.codepage).stringValue : @"-1",
                @"userReadOnly": d.isReadOnly ? @"yes" : @"no",
                @"filename": d.fileURL.path ?: @"",
                @"backupFilePath": backupPath,
                @"originalFileLastModifTimestamp": @"0", @"originalFileLastModifTimestampHigh": @"0",
                @"tabColourId": @([self tabColorIndexOfDocument:d]).stringValue, @"RTL": @"no",
            };
            for (NSString *k in @[@"firstVisibleLine", @"xOffset", @"scrollWidth", @"startPos", @"endPos", @"selMode", @"offset", @"wrapCount",
                                  @"lang", @"encoding", @"userReadOnly", @"filename", @"backupFilePath",
                                  @"originalFileLastModifTimestamp", @"originalFileLastModifTimestampHigh", @"tabColourId", @"RTL"])
                [f addAttribute:[NSXMLNode attributeWithName:k stringValue:attrs[k]]];
            for (NSNumber *line in NPPBookmarkedLines(ed)) {
                NSXMLElement *m = [NSXMLElement elementWithName:@"Mark"];
                [m addAttribute:[NSXMLNode attributeWithName:@"line" stringValue:line.stringValue]];
                [f addChild:m];
            }
            for (NSNumber *line in NPPContractedFoldLines(ed)) {
                NSXMLElement *fold = [NSXMLElement elementWithName:@"Fold"];
                [fold addAttribute:[NSXMLNode attributeWithName:@"line" stringValue:line.stringValue]];
                [f addChild:fold];
            }
            [viewEl addChild:f];
            i++;
        }
        [viewEl addAttribute:[NSXMLNode attributeWithName:@"activeIndex" stringValue:@(active).stringValue]];
        [session addChild:viewEl];
    }
    [root addChild:session];
    NSXMLDocument *xml = [[NSXMLDocument alloc] initWithRootElement:root];
    xml.version = @"1.0";
    xml.characterEncoding = @"UTF-8";
    return xml;
}

// N++ fileLoadSession's file filter is built from NppGUI::_definedSessionExt, so the extension the user configured
// on the MISC page is the one the panel offers first.
- (NSArray<UTType *> *)sessionPanelContentTypes {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    NSString *ext = [NPPPreferences.shared.sessionFileExtension stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    while ([ext hasPrefix:@"."]) ext = [ext substringFromIndex:1];
    UTType *custom = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
    if (custom) [types addObject:custom];
    [types addObject:([UTType typeWithFilenameExtension:@"xml"] ?: UTTypeXML)];
    return types;
}

- (void)loadSession {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.title = @"Load Session";
    // ponytail: the configured extension and .xml only. N++'s dialog also carries an "All types" filter, which on
    // macOS needs an accessory view; -allowsOtherFileTypes is a save-panel property and does nothing here, so it
    // is not set. Add the accessory popup if anyone keeps sessions under a third extension.
    p.allowedContentTypes = [self sessionPanelContentTypes];
    NSURL *startDir = [self defaultPanelDirectoryForDocument:self.currentDocument];
    if (startDir) p.directoryURL = startDir;
    if ([p runModal] != NSModalResponseOK || !p.URL) return;
    NSError *err = nil;
    NSXMLDocument *xml = [[NSXMLDocument alloc] initWithContentsOfURL:p.URL options:0 error:&err];
    if (!xml) { [self showError:err title:@"Load Session failed"]; return; }
    _lastUsedDirectory = p.URL.URLByDeletingLastPathComponent;
    // Multi-instance: hand the session to a second copy of the app instead of replacing what is open here.
    if ([self loadSessionShouldOpenNewInstance] &&
        [self launchNewInstanceWithArguments:@[@"-multiInst", @"-nosession", @"-openSession", p.URL.path]]) return;
    [self applySessionXMLDocument:xml];
}

- (void)applySessionXMLDocument:(NSXMLDocument *)xml {
    if (!xml) return;
    NSArray<NSXMLNode *> *mainFiles = [xml nodesForXPath:@"/NotepadPlus/Session/mainView/File" error:NULL];
    NSArray<NSXMLNode *> *subFiles = [xml nodesForXPath:@"/NotepadPlus/Session/subView/File" error:NULL];
    if (!mainFiles.count && !subFiles.count) mainFiles = [xml nodesForXPath:@"//File" error:NULL];   // tolerate other layouts
    NSXMLElement *session = (NSXMLElement *)[xml nodesForXPath:@"/NotepadPlus/Session" error:NULL].firstObject;
    NSInteger activeView = [session attributeForName:@"activeView"].stringValue.integerValue == kSubView ? kSubView : kMainView;

    NPPDocument *toActivate = nil;
    for (NSInteger v = kMainView; v <= kSubView; v++) {
        NSArray<NSXMLNode *> *files = (v == kMainView) ? mainFiles : subFiles;
        NSXMLElement *viewEl = (NSXMLElement *)[xml nodesForXPath:(v == kMainView ? @"/NotepadPlus/Session/mainView"
                                                                                  : @"/NotepadPlus/Session/subView") error:NULL].firstObject;
        NSString *activeStr = [viewEl attributeForName:@"activeIndex"].stringValue ?: [session attributeForName:@"activeIndex"].stringValue;
        NSMutableArray<NPPDocument *> *opened = [NSMutableArray array];
        for (NSXMLNode *n in files) {
            if (![n isKindOfClass:NSXMLElement.class]) continue;
            NSXMLElement *f = (NSXMLElement *)n;
            NSString *path = [f attributeForName:@"filename"].stringValue;
            NSString *backupPath = [f attributeForName:@"backupFilePath"].stringValue;
            _view = v;   // the file opens into the view the session put it in
            NPPDocument *d = nil;
            if (path.length) {
                // N++ loadSession: a file that has gone is skipped (never offered for creation), and a session or
                // workspace file inside a session is dropped — no recursive sessions, and no re-entering the
                // extension branch of -openDocumentAtURL: on the very file being loaded.
                NPPPreferences *prefs = NPPPreferences.shared;
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
                if (NPPPathHasUserExtension(path, prefs.sessionFileExtension) ||
                    NPPPathHasUserExtension(path, prefs.workspaceFileExtension)) continue;
                d = [self openDocumentAtURL:[NSURL fileURLWithPath:path]];
            } else if (backupPath.length) {
                // An untitled buffer the session parked in the backup folder: a fresh "new N" with that text,
                // left dirty, exactly as it was when the session was saved.
                NSData *data = [NSData dataWithContentsOfFile:backupPath];
                if (!data) continue;
                d = [self newDocumentInView:v];
                NPPSciStr(d.editor, SCI_ADDTEXT, (uptr_t)data.length, (const char *)data.bytes);
            }
            if (!d) continue;
            [opened addObject:d];
            NSString *lang = [f attributeForName:@"lang"].stringValue;
            if (lang.length) {
                for (NPPLanguage *l in NPPLanguageManager.shared.languages)
                    if ([l.shortName isEqualToString:lang]) { if (l != d.language) d.language = l; break; }
            }
            d.isReadOnly = [[f attributeForName:@"userReadOnly"].stringValue isEqualToString:@"yes"];
            // The character set the session recorded, before anything looks at the text: re-decoding the bytes
            // moves the caret and the marks would land on the wrong lines otherwise. An unknown code page (a
            // session from another machine, or a hand-edited file) is ignored rather than applied blindly.
            NSString *encStr = [f attributeForName:@"encoding"].stringValue;
            long long cp = encStr.longLongValue;
            if (encStr.length && cp >= 0 && [NPPCharset charsetForCFEncoding:(CFStringEncoding)cp])
                [d reinterpretAsEncoding:NPPEncodingANSI codepage:(CFStringEncoding)cp];
            // tabColourId: absent is "no colour", never colour 0 — .integerValue on a nil attribute is 0.
            NSXMLNode *colourAttr = [f attributeForName:@"tabColourId"];
            NSInteger colourId = colourAttr ? colourAttr.stringValue.integerValue : -1;
            if (colourId >= 0 && colourId <= 4) d.tabColor = [self tabColorForIndex:colourId + 1];
            sptr_t start = [f attributeForName:@"startPos"].stringValue.longLongValue, end = [f attributeForName:@"endPos"].stringValue.longLongValue;
            sptr_t len = NPPSci(d.editor, SCI_GETLENGTH);
            if (start >= 0 && end >= 0 && start <= len && end <= len) NPPSci(d.editor, SCI_SETSEL, (uptr_t)start, end);
            sptr_t fvl = [f attributeForName:@"firstVisibleLine"].stringValue.longLongValue;
            if (fvl > 0) NPPSci(d.editor, SCI_SETFIRSTVISIBLELINE, (uptr_t)fvl);
            sptr_t lastLine = NPPSci(d.editor, SCI_GETLINECOUNT) - 1;
            for (NSXMLElement *mn in [f elementsForName:@"Mark"]) {
                sptr_t line = [mn attributeForName:@"line"].stringValue.longLongValue;
                if (line >= 0 && line <= lastLine) NPPSci(d.editor, SCI_MARKERADD, (uptr_t)line, NPPMarkerBookmark);
            }
            NSMutableArray<NSNumber *> *folds = [NSMutableArray array];
            for (NSXMLElement *fn in [f elementsForName:@"Fold"]) {
                sptr_t line = [fn attributeForName:@"line"].stringValue.longLongValue;
                if (line >= 0 && line <= lastLine) [folds addObject:@(line)];
            }
            NPPRestoreContractedFoldLines(d, folds);
        }
        NSInteger active = activeStr.integerValue;
        if (opened.count) {
            NPPDocument *sel = opened[(NSUInteger)MAX(0, MIN(active, (NSInteger)opened.count - 1))];
            [self selectDocument:sel];
            if (v == activeView || !toActivate) toActivate = sel;
        }
    }
    if (toActivate) [self selectDocument:toActivate];
    // Every file the session named was missing (nothing opened, but _view followed the session into the sub view):
    // never leave the focus on a view that holds no document — the window would come up blank.
    if (_docs[_view].count == 0) [self selectDocument:_cur[[self otherView]] ?: _docs[[self otherView]].firstObject];
}

#pragma mark - Second edit view (Notepad_plus::docGotoAnotherEditView / doSynScroll / syncZoom)

- (void)focusView:(NSInteger)v {
    if (v < kMainView || v > kSubView || _docs[v].count == 0) return;
    [self selectDocument:_cur[v] ?: _docs[v].firstObject];
}

// N++ clones a buffer by showing the same Scintilla document in both views (SCI_SETDOCPOINTER): one buffer, two
// windows onto it, edits and undo shared. The clone is a second NPPDocument re-read from the same file — that is
// what gets its encoding, EOL and language right — whose editor is then pointed at the original's document.
// ponytail: a buffer converted to another encoding but not yet saved gives the clone the on-disk encoding; the
// only fix is a copy initialiser on NPPDocument, which is not ours to add.
- (NPPDocument *)cloneOfDocument:(NPPDocument *)doc {
    if (!doc.editor) return nil;
    NPPDocument *twin = doc.fileURL ? [[NPPDocument alloc] initWithContentsOfURL:doc.fileURL error:NULL] : nil;
    if (!twin) twin = [[NPPDocument alloc] initUntitled];
    if (doc.fileURL) twin.fileURL = doc.fileURL;   // untitled clones keep their own "new N" name
    NPPSci(twin.editor, SCI_SETDOCPOINTER, 0, NPPSci(doc.editor, SCI_GETDOCPOINTER));
    if (doc.language && doc.language != twin.language) twin.language = doc.language;
    if (doc.userDefinedLanguageName.length) [twin applyUserDefinedLanguageNamed:doc.userDefinedLanguageName];
    [twin applyThemeAndLanguage];   // styles live on the view, so the new one has to be painted for this lexer
    twin.isReadOnly = doc.isReadOnly;
    return twin;
}

// A clone shares the original's Scintilla document, so the document pointer is what "the same buffer" means.
- (nullable NPPDocument *)documentInView:(NSInteger)v sharingBufferWith:(NPPDocument *)doc {
    if (!doc.editor || v < 0 || v > kSubView) return nil;
    sptr_t buffer = NPPSci(doc.editor, SCI_GETDOCPOINTER);
    for (NPPDocument *d in _docs[v])
        if (d != doc && d.editor && NPPSci(d.editor, SCI_GETDOCPOINTER) == buffer) return d;
    return nil;
}

// IDM_VIEW_GOTO_ANOTHER_VIEW / IDM_VIEW_CLONE_TO_ANOTHER_VIEW. Moving carries the ScintillaView across, so the
// caret and scroll position come with it (N++ has to copy them by hand).
- (void)sendCurrentDocumentToOtherViewCloning:(BOOL)clone {
    NPPDocument *doc = self.currentDocument;
    NSInteger from = _view, to = [self otherView];
    if (!doc) return;
    // N++ (docGotoAnotherEditView, indexFound != -1): the buffer is already open over there, so activate that copy
    // instead of making another. Without this, Clone pressed twice piles up buffers on one file.
    NPPDocument *already = [self documentInView:to sharingBufferWith:doc];
    if (already) {
        [self selectDocument:already];
        if (!clone) [self removeDocument:doc rememberClosed:NO];   // TransferMove closes it in the view it came from
        [self checkSyncState];
        return;
    }
    if (clone) {
        NPPDocument *twin = [self cloneOfDocument:doc];
        if (!twin) return;
        [self addDocument:twin atIndex:-1 inView:to];
    } else {
        // N++ refuses to move the last document of a view into a hidden one: that only swaps which view is shown.
        if (_docs[from].count == 1 && _docs[to].count == 0) return;
        NSInteger idx = (NSInteger)[_docs[from] indexOfObjectIdenticalTo:doc];
        [doc.editor removeFromSuperview];
        if (_cur[from] == doc) _cur[from] = nil;
        [_docs[from] removeObjectAtIndex:(NSUInteger)idx];
        [_docs[to] addObject:doc];
        [self reloadTabs];
        if (_docs[from].count && !_cur[from])
            [self selectDocument:[self documentInView:from atIndex:MIN(idx, (NSInteger)_docs[from].count - 1)]];
        [self selectDocument:doc];   // the focus follows the document, like N++
    }
    [self checkSyncState];
}

// IDM_VIEW_GOTO_NEW_INSTANCE / IDM_VIEW_LOAD_IN_NEW_INSTANCE. N++ relaunches itself with "-multiInst -nosession";
// on macOS that is a second instance of this bundle with the file as an argument (passing a file argument already
// makes the app delegate skip session restore).
// Another copy of the bundle, which is what "multi-instance" means on macOS (N++ ShellExecute's its own exe).
// The launch itself is asynchronous, so the answer is only "the request went out" — the caller must not undo
// anything on the strength of it.
- (BOOL)launchNewInstanceWithArguments:(NSArray<NSString *> *)args {
    NSURL *bundle = NSBundle.mainBundle.bundleURL;
    if (!bundle) return NO;
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.createsNewApplicationInstance = YES;
    cfg.arguments = args ?: @[];
    cfg.activates = YES;
    __weak NPPEditorWindowController *weakSelf = self;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:bundle configuration:cfg
                                    completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (!error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf contextReportStatus:[NSString stringWithFormat:@"New instance failed: %@", error.localizedDescription] isError:YES];
        });
    }];
    return YES;
}

- (void)openCurrentDocumentInNewInstanceMoving:(BOOL)move {
    NPPDocument *doc = self.currentDocument;
    NSURL *file = doc.fileURL;
    if (!file || doc.isDirty) return;   // the new instance loads from disk, so unsaved work would be lost
    if (move && ![self closeDocument:doc]) return;
    [self launchNewInstanceWithArguments:@[file.path]];
}

// Nothing but untouched new buffers (N++ fileLoadSession's isEmptyNpp): a session can replace those in place.
- (BOOL)isEmptyWindow {
    for (NPPDocument *d in [self allDocuments]) if (!d.isUntitled || d.isDirty) return NO;
    return YES;
}

// Preferences ▸ Multi-Instance: "Open session in a new instance" and "Always in multi-instance mode" both send a
// session to a second copy of Notepad++ rather than replacing the documents in this one — unless there is nothing
// here to replace (N++ NppIO.cpp fileLoadSession).
- (BOOL)loadSessionShouldOpenNewInstance {
    return NPPPreferences.shared.multiInstanceMode != NPPMultiInstanceMono && ![self isEmptyWindow];
}

// N++ drops both scroll syncs when the second view goes away (Notepad_plus::checkSyncState) and equalises the zoom
// as soon as both views are up again. Zoom sync is a setting rather than session state, so it survives the collapse.
- (void)checkSyncState {
    if (![self isSplit]) { _syncScrollV = _syncScrollH = NO; return; }
    [self syncZoomFromDocument:self.currentDocument];
}

// The offset between the two views at the moment a sync is switched on is kept, so turning it on does not jump.
- (void)captureSyncOffsets {
    ScintillaView *a = _cur[kMainView].editor, *b = _cur[kSubView].editor;
    if (!a || !b) { _syncLine = _syncXOffset = 0; return; }
    _syncLine = NPPSci(a, SCI_GETFIRSTVISIBLELINE) - NPPSci(b, SCI_GETFIRSTVISIBLELINE);
    _syncXOffset = NPPSci(a, SCI_GETXOFFSET) - NPPSci(b, SCI_GETXOFFSET);
}

// Called for every SCN_UPDATEUI: mirror the scroll into the other view, and ignore the update that mirroring
// itself provokes there (that is the feedback loop).
// ponytail: the horizontal offset is mirrored in pixels, where N++ converts to columns first; identical while
// both views use the same font, which they do — the font is global. Convert if per-view fonts ever land.
- (void)syncScrollFromDocument:(NPPDocument *)doc {
    if (_syncing || !(_syncScrollV || _syncScrollH) || ![self isSplit]) return;
    NSInteger from = [self viewOfDocument:doc];
    if (from < 0 || doc != _cur[from]) return;
    ScintillaView *src = doc.editor, *dst = _cur[1 - from].editor;
    if (!src || !dst) return;
    sptr_t sign = (from == kMainView) ? -1 : 1;   // the offset is main minus sub
    _syncing = YES;
    if (_syncScrollV)
        NPPSci(dst, SCI_SETFIRSTVISIBLELINE, (uptr_t)MAX((sptr_t)0, NPPSci(src, SCI_GETFIRSTVISIBLELINE) + sign * _syncLine));
    if (_syncScrollH)
        NPPSci(dst, SCI_SETXOFFSET, (uptr_t)MAX((sptr_t)0, NPPSci(src, SCI_GETXOFFSET) + sign * _syncXOffset));
    _syncing = NO;
}

- (void)syncZoomFromDocument:(NPPDocument *)doc {
    if (_syncing || !_zoomSync || ![self isSplit]) return;
    NSInteger from = [self viewOfDocument:doc];
    if (from < 0 || doc != _cur[from]) return;
    ScintillaView *dst = _cur[1 - from].editor;
    if (!dst || !doc.editor) return;
    sptr_t zoom = NPPSci(doc.editor, SCI_GETZOOM);
    if (NPPSci(dst, SCI_GETZOOM) == zoom) return;   // -checkSyncState calls this on every model change; do not stir SCN_ZOOM for nothing
    _syncing = YES;
    NPPSci(dst, SCI_SETZOOM, (uptr_t)zoom);
    _syncing = NO;
}

// IDM_FILE_CLOSEALL_BUT_PINNED, in both views. N++ keeps the pinned block at the head of each strip and closes
// everything after it; we simply skip any pinned tab, which is the same thing while the block stays contiguous.
- (NSArray<NPPDocument *> *)unpinnedDocuments {
    NSMutableArray<NPPDocument *> *r = [NSMutableArray array];
    for (NPPDocument *d in [self allDocuments]) if (![_pinnedDocs containsObject:d]) [r addObject:d];
    return r;
}

// IDM_VIEW_ROTATE_* (WinControls/SplitterContainer): flip the split between side-by-side and stacked. Rotating
// left turns a vertical split into a stacked one *and* swaps the halves; rotating right does the swap on the way
// back — which is the only thing that tells the two commands apart.
- (void)rotateSplitToLeft:(BOOL)left {
    BOOL wasVertical = _panelHost.splitVertical;
    _panelHost.splitVertical = !wasVertical;
    if (wasVertical == left) _halvesSwapped = !_halvesSwapped;
    [self layoutContent];
}

#pragma mark - Window ▸ Sort By (N++ WindowsDlg::doSort — the real tab order, not a list view)

// N++ BufferEquivalent: one key per column, the full path as the tiebreak, and the whole comparison inverted for
// the descending variants (it swaps the two items rather than negating each key).
- (void)sortDocumentsByKey:(NPPSortKey)key descending:(BOOL)descending {
    NSInteger v = _view;   // N++ sorts _pDocTab: the focused view's strip
    if (_docs[v].count < 2) return;
    NPPDocument *current = _cur[v];
    __weak NPPEditorWindowController *weakSelf = self;
    NSArray<NPPDocument *> *sorted = [_docs[v] sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NPPDocument *a, NPPDocument *b) {
        NPPEditorWindowController *self_ = weakSelf;
        NSComparisonResult r = NSOrderedSame;
        switch (key) {
            case NPPSortByName: r = NPPNaturalCompare(a.displayName, b.displayName); break;
            // Language *name*, not the extension — N++ sorts on getLangFromID(...)->getLangName().
            case NPPSortByType: r = NPPNaturalCompare(a.userDefinedLanguageName ?: a.language.name,
                                                      b.userDefinedLanguageName ?: b.language.name); break;
            case NPPSortBySize: {
                sptr_t la = a.editor ? NPPSci(a.editor, SCI_GETLENGTH) : 0, lb = b.editor ? NPPSci(b.editor, SCI_GETLENGTH) : 0;
                if (la != lb) r = la < lb ? NSOrderedAscending : NSOrderedDescending;
                break;
            }
            case NPPSortByDate: {
                NSDate *da = a.lastKnownModificationDate ?: NSDate.distantPast;
                NSDate *db = b.lastKnownModificationDate ?: NSDate.distantPast;
                r = [da compare:db];
                break;
            }
            case NPPSortByPath: break;   // the tiebreak below *is* the path comparison
        }
        if (r == NSOrderedSame) r = NPPNaturalCompare([self_ pathOrNameOf:a], [self_ pathOrNameOf:b]);
        return descending ? (NSComparisonResult)(-r) : r;
    }];
    [_docs[v] setArray:sorted];
    [self reloadTabs];
    if (current) [self selectDocument:current];   // N++ re-activates the tab that was current before the sort
}

#pragma mark - ⌃Tab document switcher (N++ WinControls/TaskList, NppGUI::_doTaskList / _styleMRU)

- (BOOL)documentSwitcherEnabled {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:kDocSwitcherKey];
    return v ? v.boolValue : YES;   // N++ _doTaskList defaults to on
}

// N++ NppGUI::_styleMRU (IDC_CHECK_STYLEMRU). On, the switcher lists the documents most recently used first; off,
// it lists them in tab order and starts from the tab you are on (NppBigSwitch.cpp WM_GETTASKLISTINFO).
- (BOOL)documentSwitcherMRUEnabled {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:kDocSwitcherMRUKey];
    return v ? v.boolValue : YES;   // N++ _styleMRU defaults to on
}

// Local monitor rather than a key equivalent: the HUD has to stay up while ⌃ is held and commit when it is
// released, and only a raw flags-changed event says when that happens.
- (void)installDocumentSwitcherMonitor {
    __weak NPPEditorWindowController *weakSelf = self;
    _switcherMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskFlagsChanged)
                                                            handler:^NSEvent *(NSEvent *e) {
        NPPEditorWindowController *self_ = weakSelf;
        return self_ ? [self_ handleSwitcherEvent:e] : e;
    }];
}

- (NSEvent *)handleSwitcherEvent:(NSEvent *)e {
    if (e.window != self.window) return e;
    BOOL control = (e.modifierFlags & NSEventModifierFlagControl) != 0;
    if (e.type == NSEventTypeFlagsChanged) {
        if (!control && _switcherOrder) [self commitDocumentSwitcher];   // ⌃ released: take the highlighted document
        return e;
    }
    if (e.keyCode != 48 /* tab */ || !control) return e;
    if (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) return e;
    [self cycleDocumentSwitcherBackward:(e.modifierFlags & NSEventModifierFlagShift) != 0];
    return nil;   // swallowed: Scintilla must not see a tab
}

// Every open buffer, most recently used first. Anything the MRU has not seen (a tab opened but never activated)
// keeps its tab order at the back.
- (NSArray<NPPDocument *> *)documentsInMRUOrder {
    NSMutableArray<NPPDocument *> *order = [NSMutableArray array];
    NSArray<NPPDocument *> *all = [self allDocuments];
    for (NPPDocument *d in _mru) if ([all indexOfObjectIdenticalTo:d] != NSNotFound) [order addObject:d];
    for (NPPDocument *d in all) if ([order indexOfObjectIdenticalTo:d] == NSNotFound) [order addObject:d];
    return order;
}

- (void)cycleDocumentSwitcherBackward:(BOOL)backward {
    // MRU behaviour off: the same list in plain tab order, both views, exactly as N++ builds TaskListInfo then.
    NSArray<NPPDocument *> *order = [self documentSwitcherMRUEnabled] ? [self documentsInMRUOrder] : [self allDocuments];
    if (order.count < 2) return;
    if (![self documentSwitcherEnabled]) {
        // N++ activateNextDoc(): no HUD, just the next / previous tab of the focused view.
        NSInteger count = (NSInteger)_docs[_view].count, idx = [self indexOfDocument:_cur[_view]];
        if (count < 2 || idx == NSNotFound) return;
        [self selectDocument:[self documentInView:_view atIndex:(idx + (backward ? count - 1 : 1)) % count]];
        return;
    }
    // _switcherOrder, not the panel, is what says a run of presses is under way: the HUD is only shown for a
    // window that is on screen, and the cycling has to work the same either way.
    if (!_switcherOrder) {
        _switcherOrder = order;
        // The first press already moves off "current" — which is the head of the list under MRU, but anywhere in
        // it in tab order (N++ sets _currentIndex to the current tab when _styleMRU is off).
        NSInteger n = (NSInteger)order.count;
        NSUInteger cur = [order indexOfObjectIdenticalTo:self.currentDocument];
        NSInteger from = cur == NSNotFound ? 0 : (NSInteger)cur;
        _switcherIndex = (from + (backward ? n - 1 : 1)) % n;
        [self showDocumentSwitcher];
    } else {
        NSInteger n = (NSInteger)_switcherOrder.count;
        _switcherIndex = (_switcherIndex + (backward ? n - 1 : 1)) % n;
    }
    [self updateDocumentSwitcherLabel];
}

- (void)commitDocumentSwitcher {
    NPPDocument *pick = (_switcherIndex >= 0 && _switcherIndex < (NSInteger)_switcherOrder.count)
                      ? _switcherOrder[(NSUInteger)_switcherIndex] : nil;
    [_switcher orderOut:nil];
    _switcherOrder = nil;
    if (pick) [self selectDocument:pick];
}

- (void)showDocumentSwitcher {
    if (!self.window.isVisible) return;   // headless controller: cycle, but put nothing on screen
    if (!_switcher) {
        // ponytail: a HUD panel with one attributed string, where N++ has a list view with icons. Swap in an
        // NSTableView if the list ever needs per-row controls.
        _switcher = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 100)
                                              styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                backing:NSBackingStoreBuffered defer:NO];
        _switcher.opaque = NO;
        _switcher.backgroundColor = NSColor.clearColor;
        _switcher.level = NSFloatingWindowLevel;
        _switcher.hidesOnDeactivate = YES;
        _switcher.ignoresMouseEvents = YES;
        NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        bg.material = NSVisualEffectMaterialHUDWindow;
        bg.state = NSVisualEffectStateActive;
        bg.wantsLayer = YES;
        bg.layer.cornerRadius = 10;
        bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _switcherLabel = [NSTextField labelWithString:@""];
        // +labelWithString: makes a non-wrapping label; the list is one string of newline-separated rows, so it has
        // to be told it may use them, or the HUD shows a single line whatever the buffer count.
        _switcherLabel.usesSingleLineMode = NO;
        _switcherLabel.maximumNumberOfLines = 0;
        _switcherLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _switcherLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [bg addSubview:_switcherLabel];
        _switcher.contentView = bg;
    }
    [self updateDocumentSwitcherLabel];
    // Ordered in without taking key, so the editor keeps the focus and the modifier keeps reaching our monitor.
    [_switcher orderFront:nil];
}

- (void)updateDocumentSwitcherLabel {
    if (!_switcherLabel) return;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    NSFont *font = [NSFont systemFontOfSize:13];
    for (NSUInteger i = 0; i < _switcherOrder.count; i++) {
        NPPDocument *d = _switcherOrder[i];
        BOOL selected = ((NSInteger)i == _switcherIndex);
        NSString *line = [NSString stringWithFormat:@" %@%@%@\n", d.isDirty ? @"* " : @"", d.displayName,
                          d.fileURL ? [NSString stringWithFormat:@"  —  %@", d.fileURL.URLByDeletingLastPathComponent.path] : @""];
        NSMutableDictionary *attrs = [@{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.labelColor} mutableCopy];
        if (selected) {
            attrs[NSFontAttributeName] = [NSFont boldSystemFontOfSize:13];
            attrs[NSBackgroundColorAttributeName] = NSColor.selectedContentBackgroundColor;
            attrs[NSForegroundColorAttributeName] = NSColor.selectedMenuItemTextColor;
        }
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attrs]];
    }
    _switcherLabel.attributedStringValue = text;

    CGFloat rowH = 18, pad = 10;
    CGFloat h = MIN(_switcherOrder.count, 20u) * rowH + 2 * pad;
    NSRect visible = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    NSRect on = self.window.isVisible ? self.window.frame : visible;
    NSRect frame = NSMakeRect(NSMidX(on) - 230, NSMidY(on) - h / 2, 460, h);
    [_switcher setFrame:frame display:YES];
    _switcherLabel.frame = NSInsetRect(_switcher.contentView.bounds, pad, pad);
}

#pragma mark - Panel visibility across launches (N++ NppGUI::_*KeepState)

// The panel toggles are one contiguous range of tags, and each module answers -commandIsChecked: with "is my panel
// visible" — so remembering which panels were open is remembering which of those tags are ticked.
- (void)rememberOpenPanels {
    // Only the window that is really on screen owns this setting: a headless controller (the self-test, every
    // module's own checks) and an automated run both toggle panels the user never asked for.
    if (_restoringPanels || !_didShowWindow || NPPAutomatedRun()) return;
    NSMutableArray<NSNumber *> *open = [NSMutableArray array];
    for (NPPCmd cmd = NPPCmdViewWorkspacePanel; cmd <= NPPCmdViewProjectPanel3; cmd = (NPPCmd)(cmd + 1)) {
        Class h = NPPFeatureHandlerForCommand(cmd);
        if ([h respondsToSelector:@selector(commandIsChecked:context:)] &&
            [(Class<NPPCommandHandler>)h commandIsChecked:cmd context:self])
            [open addObject:@(cmd)];
    }
    [NSUserDefaults.standardUserDefaults setObject:open forKey:kOpenPanelsKey];
}

// Preferences ▸ Multi-Instance & Date ▸ "Panel State and [-nosession]" (N++ NppGUI::_*KeepState, read in
// Notepad_plus::init): under -nosession only the panels the user ticked here come back. Without -nosession every
// remembered panel comes back and these flags say nothing at all.
+ (BOOL)panelCommandKeepsStateWithoutSession:(NPPCmd)cmd {
    NPPPreferences *prefs = NPPPreferences.shared;
    switch (cmd) {
        case NPPCmdViewWorkspacePanel:   return prefs.fileBrowserPanelKeepState;   // Folder as Workspace
        case NPPCmdViewDocumentMap:      return prefs.docMapPanelKeepState;
        case NPPCmdViewFunctionList:     return prefs.funcListPanelKeepState;
        case NPPCmdViewDocumentList:     return prefs.docListPanelKeepState;
        case NPPCmdViewClipboardHistory: return prefs.clipboardHistoryPanelKeepState;
        case NPPCmdViewCharacterPanel:   return prefs.charPanelKeepState;
        case NPPCmdViewProjectPanel1: case NPPCmdViewProjectPanel2: case NPPCmdViewProjectPanel3:
            return prefs.projectPanelKeepState;
        default: return NO;
    }
}

- (void)restoreRememberedPanels {
    // make exercise / screenshot toggle each panel exactly once and count what opened; starting from the user's
    // remembered layout would close half of them instead.
    if (NPPAutomatedRun()) return;
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kOpenPanelsKey];
    if (![saved isKindOfClass:NSArray.class]) return;
    // "Does this launch restore a session at all" is the same -nosession answer the quit path asks for (the module
    // owns both); it is NO only under -nosession, never merely because files were named on the command line.
    BOOL noSession = !NPPSessionSwitchAllows(/*restoringAtLaunch=*/NO, NULL);
    _restoringPanels = YES;
    for (id entry in saved) {
        if (![entry isKindOfClass:NSNumber.class]) continue;
        NPPCmd cmd = (NPPCmd)[entry integerValue];
        if (cmd < NPPCmdViewWorkspacePanel || cmd > NPPCmdViewProjectPanel3) continue;
        if (noSession && ![NPPEditorWindowController panelCommandKeepsStateWithoutSession:cmd]) continue;
        Class h = NPPFeatureHandlerForCommand(cmd);
        if (![h respondsToSelector:@selector(commandIsChecked:context:)]) continue;
        if (![(Class<NPPCommandHandler>)h commandIsChecked:cmd context:self]) [self performFeatureCommand:cmd];
    }
    _restoringPanels = NO;
}

#pragma mark - Command dispatch

- (NSString *)findInitialText {
    ScintillaView *ed = self.currentDocument.editor;
    if (!ed) return nil;
    NSString *sel = NPPSciSelectedString(ed);
    if (sel.length && [sel rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) return sel;
    return NPPSciWordAtCaret(ed);
}

- (NSColor *)tabColorForIndex:(NSInteger)n {   // 1..5
    NPPLanguageManager *m = NPPLanguageManager.shared;
    NSColor *c = nil;
    if ([m currentThemeIsDark]) c = [m globalBackgroundColorNamed:[NSString stringWithFormat:@"Tab color dark mode %ld", (long)n]];
    if (!c) c = [m globalBackgroundColorNamed:[NSString stringWithFormat:@"Tab color %ld", (long)n]];
    if (!c) {   // N++ defaults (Parameters.h individualTabColor)
        static const long defaults[5] = {0x8A9EF0 /*red-ish*/, 0x00C0FF /*orange*/, 0x6DD866 /*green*/, 0xD0A0FF /*purple*/, 0xFFD070 /*cyan*/};
        c = NPPNSColorFromSci(defaults[MAX(0, MIN(4, n - 1))]);
    }
    return c;
}

// The other direction, for the session's tabColourId: the 0-based index of the "Apply Color N" that produced this
// tab's colour, -1 for none — the numbering N++ writes. Matched by colour, which is exactly how -validateMenuItem:
// decides which of the five menu items carries the tick.
// ponytail: swap the theme between saving and restoring a session and the five colours change, so the tab comes
// back uncoloured. Store the index on the buffer instead if that ever matters — NPPDocument needs the property.
- (NSInteger)tabColorIndexOfDocument:(NPPDocument *)doc {
    if (!doc.tabColor) return -1;
    for (NSInteger n = 1; n <= 5; n++) {
        NSColor *c = [self tabColorForIndex:n];
        if (c && [doc.tabColor isEqual:c]) return n - 1;
    }
    return -1;
}

- (void)copyToPasteboard:(NSString *)s {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:s ?: @"" forType:NSPasteboardTypeString];
}

- (NSString *)pathOrNameOf:(NPPDocument *)d { return d.fileURL.path ?: d.displayName; }

- (void)setDistractionFree:(BOOL)on {
    if (on == _distractionFree) return;
    _distractionFree = on;
    for (NSInteger v = kMainView; v <= kSubView; v++) _tabBars[v].hidden = on;
    _statusBar.hidden = on;
    [self layoutContent];
    BOOL fullScreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (on && !fullScreen) { _enteredFullScreenForDistractionFree = YES; [self.window toggleFullScreen:nil]; }
    else if (!on && fullScreen && _enteredFullScreenForDistractionFree) { _enteredFullScreenForDistractionFree = NO; [self.window toggleFullScreen:nil]; }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    if (_distractionFree) { _enteredFullScreenForDistractionFree = NO; [self setDistractionFree:NO]; }
    [self layoutContent];
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification { [self layoutContent]; }

- (IBAction)nppCommand:(id)sender {
    NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    NPPDocument *doc = self.currentDocument;
    ScintillaView *ed = doc.editor;
    NSInteger idx = [self indexOfDocument:doc];
    NSInteger count = (NSInteger)_docs[_view].count;   // tab commands act on the focused view, like N++
    NPPPreferences *prefs = NPPPreferences.shared;
    NPPFindPanelController *find = NPPFindPanelController.shared;

    // ---- ranges first ----
    if (tag >= NPPCmdFileRecentBase && tag < NPPCmdFileClearRecent) {
        NSArray *recent = prefs.recentFilePaths;
        NSInteger i = tag - NPPCmdFileRecentBase;
        if (i < (NSInteger)recent.count) [self openDocumentAtURL:[NSURL fileURLWithPath:recent[(NSUInteger)i]]];
        return;
    }
    if (tag >= NPPCmdEncodingCharsetBase && tag < NPPCmdLanguageBase) {
        NSArray<NPPCharset *> *cs = NPPCharset.allCharsets;
        NSInteger i = tag - NPPCmdEncodingCharsetBase;
        if (doc && i < (NSInteger)cs.count) [doc reinterpretAsEncoding:NPPEncodingANSI codepage:cs[(NSUInteger)i].cfEncoding];
        return;
    }
    if (tag >= NPPCmdLanguageBase && tag < NPPCmdSettingsPreferences) {
        NSArray<NPPLanguage *> *langs = NPPLanguageManager.shared.languages;
        NSInteger i = tag - NPPCmdLanguageBase;
        if (doc && i < (NSInteger)langs.count) doc.language = langs[(NSUInteger)i];
        return;
    }
    // The tab commands count within the focused view's strip, like N++ (they are the same thing with one view).
    if (tag >= NPPCmdViewTab1 && tag <= NPPCmdViewTab9) { [self selectDocument:[self documentInView:_view atIndex:tag - NPPCmdViewTab1]]; return; }
    if (tag >= NPPCmdViewTabColor1 && tag <= NPPCmdViewTabColor5) {
        doc.tabColor = [self tabColorForIndex:tag - NPPCmdViewTabColor1 + 1];
        [self reloadTabs];
        return;
    }
    // Window ▸ Sort By: name / path / type / content length / modified time, ascending then descending.
    if (tag >= NPPCmdWindowSortNameAsc && tag <= NPPCmdWindowSortDateDesc) {
        NSInteger offset = tag - NPPCmdWindowSortNameAsc;
        [self sortDocumentsByKey:(NPPSortKey)(offset / 2) descending:(offset % 2) != 0];
        return;
    }

    switch ((NPPCmd)tag) {
        // ---- File ----
        case NPPCmdFileNew: [self newDocument]; return;
        case NPPCmdFileOpen: {
            NSOpenPanel *p = [NSOpenPanel openPanel];
            p.allowsMultipleSelection = YES;
            p.canChooseDirectories = NO;
            p.treatsFilePackagesAsDirectories = YES;
            NSURL *dir = [self defaultPanelDirectoryForDocument:doc];
            if (dir) p.directoryURL = dir;
            // N++ opens this one on "All types" (showAllExt) rather than on the current buffer's language.
            [self attachFileTypeFilterToPanel:p language:nil appendExtensionBox:NO];
            if ([p runModal] == NSModalResponseOK) {
                _lastUsedDirectory = p.URLs.firstObject.URLByDeletingLastPathComponent ?: _lastUsedDirectory;
                [self openDocumentsAtURLs:p.URLs];
            }
            return;
        }
        // IDM_FILE_OPEN_CMD / _POWERSHELL: a shell sitting in the file's folder.
        case NPPCmdFileOpenInTerminal: {
            NSURL *dir = doc.fileURL.URLByDeletingLastPathComponent, *term = NPPTerminalApplicationURL();
            if (!dir || !term) return;
            __weak NPPEditorWindowController *weakSelf = self;
            [NSWorkspace.sharedWorkspace openURLs:@[dir] withApplicationAtURL:term
                                    configuration:[NSWorkspaceOpenConfiguration configuration]
                                completionHandler:^(NSRunningApplication *app, NSError *error) {
                if (!error) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf contextReportStatus:[NSString stringWithFormat:@"Open in Terminal failed: %@", error.localizedDescription] isError:YES];
                });
            }];
            return;
        }
        case NPPCmdFileContainingFolderAsWorkspace:
            if (doc.fileURL) [self addFolderAsWorkspace:doc.fileURL.URLByDeletingLastPathComponent];
            return;
        case NPPCmdFileOpenContainingFolder:
            if (doc.fileURL) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[doc.fileURL]];
            return;
        case NPPCmdFileOpenInDefaultViewer:
            if (doc.fileURL) [NSWorkspace.sharedWorkspace openURL:doc.fileURL];
            return;
        case NPPCmdFileReload: [self reloadDocument:doc]; return;
        case NPPCmdFileSave: [self saveDocument:doc]; return;
        case NPPCmdFileSaveAs: [self saveDocumentAs:doc]; return;
        case NPPCmdFileSaveCopyAs: [self saveCopyAs:doc]; return;
        case NPPCmdFileSaveAll: [self saveAllDocuments]; return;
        case NPPCmdFileRename: [self renameDocument:doc]; return;
        case NPPCmdFileClose: [self closeDocument:doc]; return;
        case NPPCmdFileCloseAll: [self closeAllDocuments]; return;
        case NPPCmdFileCloseAllButCurrent: {
            NSMutableArray *others = [[self allDocuments] mutableCopy];
            [others removeObjectIdenticalTo:doc];
            [self closeDocuments:others];
            return;
        }
        case NPPCmdFileCloseAllToLeft:
            if (idx != NSNotFound && idx > 0) [self closeDocuments:[_docs[_view] subarrayWithRange:NSMakeRange(0, (NSUInteger)idx)]];
            return;
        case NPPCmdFileCloseAllToRight:
            if (idx != NSNotFound && idx + 1 < count) [self closeDocuments:[_docs[_view] subarrayWithRange:NSMakeRange((NSUInteger)idx + 1, (NSUInteger)(count - idx - 1))]];
            return;
        case NPPCmdFileCloseAllUnchanged:
            for (NPPDocument *d in [self allDocuments]) if (!d.isDirty) [self removeDocument:d rememberClosed:YES];
            return;
        case NPPCmdFileCloseAllButPinned: [self closeDocuments:[self unpinnedDocuments]]; return;
        case NPPCmdFileMoveToTrash: [self moveDocumentToTrash:doc]; return;
        case NPPCmdFileLoadSession: [self loadSession]; return;
        case NPPCmdFileSaveSession: [self saveSession]; return;
        case NPPCmdFilePrint: [self printDocument:doc showPanel:YES]; return;
        case NPPCmdFilePrintNow: [self printDocument:doc showPanel:NO]; return;
        case NPPCmdFileRestoreLastClosed: {
            NSURL *u = _closedStack.lastObject;
            if (u) { [_closedStack removeLastObject]; [self openDocumentAtURL:u]; }
            return;
        }
        case NPPCmdFileClearRecent:
            [prefs clearRecentFiles];
            [NSNotificationCenter.defaultCenter postNotificationName:NPPRecentFilesDidChange object:self];
            return;

        // ---- Edit (window-level) ----
        case NPPCmdEditCopyFullPath: [self copyToPasteboard:[self pathOrNameOf:doc]]; return;
        case NPPCmdEditCopyFileName: [self copyToPasteboard:doc.displayName]; return;
        case NPPCmdEditCopyDirPath: [self copyToPasteboard:doc.fileURL.URLByDeletingLastPathComponent.path ?: @""]; return;
        case NPPCmdEditCopyAllNames: [self copyToPasteboard:[[[self allDocuments] valueForKey:@"displayName"] componentsJoinedByString:@"\n"]]; return;
        case NPPCmdEditCopyAllPaths: {
            NSMutableArray *a = [NSMutableArray array];
            for (NPPDocument *d in [self allDocuments]) [a addObject:[self pathOrNameOf:d]];
            [self copyToPasteboard:[a componentsJoinedByString:@"\n"]];
            return;
        }
        case NPPCmdEditEOLToWindows: [doc convertEOLTo:NPPEOLWindows]; [self updateStatusBar]; return;
        case NPPCmdEditEOLToUnix: [doc convertEOLTo:NPPEOLUnix]; [self updateStatusBar]; return;
        case NPPCmdEditEOLToMac: [doc convertEOLTo:NPPEOLMac]; [self updateStatusBar]; return;
        case NPPCmdEditToggleReadOnly: doc.isReadOnly = !doc.isReadOnly; [self refreshDocument:doc]; return;
        case NPPCmdEditSetReadOnlyAll: for (NPPDocument *d in [self allDocuments]) d.isReadOnly = YES; [self reloadTabs]; return;
        case NPPCmdEditClearReadOnlyAll: for (NPPDocument *d in [self allDocuments]) d.isReadOnly = NO; [self reloadTabs]; return;

        // ---- Search -> find panel ----
        case NPPCmdSearchFind: [find showFindWithInitialText:[self findInitialText]]; return;
        case NPPCmdSearchFindNext: [find findNextInEditor:ed]; return;
        case NPPCmdSearchFindPrev: [find findPreviousInEditor:ed]; return;
        case NPPCmdSearchSelectAndFindNext: if (ed) [find selectAndFindNextInEditor:ed backward:NO]; return;
        case NPPCmdSearchSelectAndFindPrev: if (ed) [find selectAndFindNextInEditor:ed backward:YES]; return;
        case NPPCmdSearchVolatileFindNext: if (ed) [find volatileFindInEditor:ed backward:NO]; return;
        case NPPCmdSearchVolatileFindPrev: if (ed) [find volatileFindInEditor:ed backward:YES]; return;
        case NPPCmdSearchReplace: [find showReplaceWithInitialText:[self findInitialText]]; return;
        case NPPCmdSearchMark: [find showMarkWithInitialText:[self findInitialText]]; return;
        case NPPCmdSearchIncremental: [self showIncrementalBar:nil]; [find showIncrementalSearch]; return;
        case NPPCmdSearchGoToLine: if (ed) [find showGoToLineForEditor:ed]; return;

        // ---- View (window/tabs) ----
        case NPPCmdViewAlwaysOnTop:
            self.window.level = (self.window.level == NSFloatingWindowLevel) ? NSNormalWindowLevel : NSFloatingWindowLevel;
            return;
        case NPPCmdViewFullScreen: [self.window toggleFullScreen:nil]; return;
        case NPPCmdViewDistractionFree: [self setDistractionFree:!_distractionFree]; return;
        case NPPCmdViewTabFirst: [self selectDocument:[self documentInView:_view atIndex:0]]; return;
        case NPPCmdViewTabLast: [self selectDocument:[self documentInView:_view atIndex:count - 1]]; return;
        // idx is NSNotFound (== NSIntegerMax) when the focused view has no current document: never do arithmetic on it.
        case NPPCmdViewTabNext: if (count && idx != NSNotFound) [self selectDocument:[self documentInView:_view atIndex:(idx + 1) % count]]; return;
        case NPPCmdViewTabPrev: if (count && idx != NSNotFound) [self selectDocument:[self documentInView:_view atIndex:(idx - 1 + count) % count]]; return;
        case NPPCmdViewTabMoveForward: if (idx + 1 < count) [self moveDocumentAtIndex:idx toIndex:idx + 1]; return;
        case NPPCmdViewTabMoveBackward: if (idx > 0) [self moveDocumentAtIndex:idx toIndex:idx - 1]; return;
        case NPPCmdViewTabColorNone: doc.tabColor = nil; [self reloadTabs]; return;

        // ---- second edit view ----
        case NPPCmdViewMoveToOtherView: [self sendCurrentDocumentToOtherViewCloning:NO]; return;
        case NPPCmdViewCloneToOtherView: [self sendCurrentDocumentToOtherViewCloning:YES]; return;
        case NPPCmdViewSwitchToOtherView: {
            // N++: only switches when the focus is already in an edit view; from anywhere else (a docked panel,
            // the find bar) it puts the focus back into the current one.
            NSResponder *r = self.window.firstResponder;
            BOOL inEditor = [r isKindOfClass:NSView.class] && ed && [(NSView *)r isDescendantOf:ed];
            NSInteger want = inEditor ? [self otherView] : _view;
            if (_docs[want].count == 0) want = _view;   // N++: "if (!viewVisible(view_to_focus)) view_to_focus = _activeView"
            [self focusView:want];
            return;
        }
        case NPPCmdViewSyncScrollVertical:
            _syncScrollV = !_syncScrollV;
            if (_syncScrollV) [self captureSyncOffsets];
            return;
        case NPPCmdViewSyncScrollHorizontal:
            _syncScrollH = !_syncScrollH;
            if (_syncScrollH) [self captureSyncOffsets];
            return;
        case NPPCmdViewZoomSync:
            _zoomSync = !_zoomSync;
            [NSUserDefaults.standardUserDefaults setBool:_zoomSync forKey:@"NPPZoomSync"];
            if (_zoomSync) [self syncZoomFromDocument:doc];
            return;
        case NPPCmdViewMoveToNewInstance: [self openCurrentDocumentInNewInstanceMoving:YES]; return;
        case NPPCmdViewOpenInNewInstance: [self openCurrentDocumentInNewInstanceMoving:NO]; return;
        case NPPCmdViewRotateRight: [self rotateSplitToLeft:NO]; return;
        case NPPCmdViewRotateLeft: [self rotateSplitToLeft:YES]; return;

        // ---- tab bar owned commands: the strip is a view, so the window controller is what can reach it ----
        case NPPCmdTabPin: [_tabBars[_view] togglePinnedAtIndex:idx]; return;
        case NPPCmdTabDropDownList: [_tabBars[_view] showTabListMenu]; return;

        case NPPCmdViewMonitoring:
            if (doc.fileURL) { doc.isMonitoring = !doc.isMonitoring; [self refreshDocument:doc]; }
            return;

        // ---- Encoding ----
        case NPPCmdEncodingANSI: [doc reinterpretAsEncoding:NPPEncodingANSI codepage:doc.codepage]; return;
        case NPPCmdEncodingUTF8: [doc reinterpretAsEncoding:NPPEncodingUTF8 codepage:doc.codepage]; return;
        case NPPCmdEncodingUTF8BOM: [doc reinterpretAsEncoding:NPPEncodingUTF8BOM codepage:doc.codepage]; return;
        case NPPCmdEncodingUTF16BE: [doc reinterpretAsEncoding:NPPEncodingUTF16BE codepage:doc.codepage]; return;
        case NPPCmdEncodingUTF16LE: [doc reinterpretAsEncoding:NPPEncodingUTF16LE codepage:doc.codepage]; return;
        case NPPCmdEncodingConvertToANSI: doc.encoding = NPPEncodingANSI; return;
        case NPPCmdEncodingConvertToUTF8: doc.encoding = NPPEncodingUTF8; return;
        case NPPCmdEncodingConvertToUTF8BOM: doc.encoding = NPPEncodingUTF8BOM; return;
        case NPPCmdEncodingConvertToUTF16BE: doc.encoding = NPPEncodingUTF16BE; return;
        case NPPCmdEncodingConvertToUTF16LE: doc.encoding = NPPEncodingUTF16LE; return;
        default: break;
    }

    if (ed && [NPPEditCommands handlesCommand:(NPPCmd)tag]) { [NPPEditCommands performCommand:(NPPCmd)tag onEditor:ed language:doc.language]; [self updateStatusBar]; return; }
    if (ed && [NPPSearchViewCommands handlesCommand:(NPPCmd)tag]) { [NPPSearchViewCommands performCommand:(NPPCmd)tag onEditor:ed]; [self updateStatusBar]; return; }
    // A user-defined language is applied through the document, so the buffer knows which UDL is active (status bar,
    // Save As re-detection); the UDL module itself only owns the dialog, import and export.
    if (tag >= NPPCmdLangUserDefinedBase && tag < NPPCmdLangUserDefinedBase + 100 && doc) {
        NSArray<NSString *> *names = [self userDefinedLanguageNames];
        NSInteger i = tag - NPPCmdLangUserDefinedBase;
        if (i < (NSInteger)names.count) [doc applyUserDefinedLanguageNamed:names[(NSUInteger)i]];
        [self updateStatusBar];
        return;
    }
    if (Class h = NPPFeatureHandlerForCommand((NPPCmd)tag)) {
        [(Class<NPPCommandHandler>)h performCommand:(NPPCmd)tag context:self];
        [self updateStatusBar];
        return;
    }
    if (NPPIsAppLevelCommand(tag)) {   // Settings / Help / theme items live in the app delegate, which sits after us in the responder chain
        NPPForwardGuard guard;
        id d = NSApp.delegate;
        if (guard.entered && [d respondsToSelector:@selector(nppCommand:)]) { [d performSelector:@selector(nppCommand:) withObject:sender]; return; }
    }
    NPPBeepUnlessMuted();   // Preferences ▸ MISC "Mute all sounds"
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action != @selector(nppCommand:)) return [self respondsToSelector:item.action];
    NSInteger tag = item.tag;
    NPPDocument *doc = self.currentDocument;
    ScintillaView *ed = doc.editor;
    NSInteger idx = [self indexOfDocument:doc];
    NSInteger count = (NSInteger)_docs[_view].count;
    BOOL hasFile = doc.fileURL != nil;
    BOOL fullScreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    item.state = NSControlStateValueOff;

    if (tag >= NPPCmdFileRecentBase && tag < NPPCmdFileClearRecent) return (tag - NPPCmdFileRecentBase) < (NSInteger)NPPPreferences.shared.recentFilePaths.count;
    if (tag >= NPPCmdEncodingCharsetBase && tag < NPPCmdLanguageBase) {
        NSArray<NPPCharset *> *cs = NPPCharset.allCharsets;
        NSInteger i = tag - NPPCmdEncodingCharsetBase;
        if (!doc || i >= (NSInteger)cs.count) return NO;
        BOOL isCurrent = doc.encoding == NPPEncodingANSI && doc.codepage == cs[(NSUInteger)i].cfEncoding;
        item.state = isCurrent ? NSControlStateValueOn : NSControlStateValueOff;
        return !doc.isDirty || isCurrent;
    }
    if (tag >= NPPCmdLanguageBase && tag < NPPCmdSettingsPreferences) {
        NSArray<NPPLanguage *> *langs = NPPLanguageManager.shared.languages;
        NSInteger i = tag - NPPCmdLanguageBase;
        if (!doc || i >= (NSInteger)langs.count) return NO;
        item.state = (langs[(NSUInteger)i] == doc.language || [langs[(NSUInteger)i].name isEqualToString:doc.language.name]) ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (tag >= NPPCmdViewTab1 && tag <= NPPCmdViewTab9) return (tag - NPPCmdViewTab1) < count;
    if (tag >= NPPCmdWindowSortNameAsc && tag <= NPPCmdWindowSortDateDesc) return count > 1;
    if (tag >= NPPCmdViewTabColor1 && tag <= NPPCmdViewTabColor5) {
        NSColor *c = [self tabColorForIndex:tag - NPPCmdViewTabColor1 + 1];
        item.state = (doc.tabColor && c && [doc.tabColor isEqual:c]) ? NSControlStateValueOn : NSControlStateValueOff;
        return doc != nil;
    }

    switch ((NPPCmd)tag) {
        case NPPCmdFileNew: case NPPCmdFileOpen: case NPPCmdFileLoadSession: case NPPCmdFileSaveSession: case NPPCmdFileClearRecent:
            return YES;
        case NPPCmdFileOpenContainingFolder: case NPPCmdFileOpenInDefaultViewer: case NPPCmdFileReload: case NPPCmdFileRename: case NPPCmdFileMoveToTrash:
            return hasFile;
        // Nowhere to put the folder without the workspace panel module, so the item stays dead rather than silent.
        case NPPCmdFileContainingFolderAsWorkspace: return hasFile && NPPWorkspacePanelTakesFolders();
        case NPPCmdFileOpenInTerminal: return hasFile && NPPTerminalApplicationURL() != nil;
        case NPPCmdFileSave: return doc && (doc.isDirty || doc.isUntitled || !doc.isReadOnly);
        case NPPCmdFileSaveAs: case NPPCmdFileSaveCopyAs: case NPPCmdFilePrint: case NPPCmdFilePrintNow: case NPPCmdFileClose: case NPPCmdFileCloseAll:
            return doc != nil;
        case NPPCmdFileSaveAll: return [self hasDirtyDocuments];
        // Closes across both views (N++ fileCloseAllButCurrent), so it is the total that decides, not the focused strip.
        case NPPCmdFileCloseAllButCurrent: return [self allDocuments].count > 1;
        case NPPCmdFileCloseAllToLeft: return idx != NSNotFound && idx > 0;
        case NPPCmdFileCloseAllToRight: return idx != NSNotFound && idx + 1 < count;
        case NPPCmdFileCloseAllUnchanged: for (NPPDocument *d in [self allDocuments]) if (!d.isDirty) return YES; return NO;
        case NPPCmdFileRestoreLastClosed: return _closedStack.count > 0;

        case NPPCmdEditCopyFullPath: case NPPCmdEditCopyFileName: case NPPCmdEditCopyAllNames: case NPPCmdEditCopyAllPaths: return doc != nil;
        case NPPCmdEditCopyDirPath: return hasFile;
        case NPPCmdEditEOLToWindows: item.state = doc.eolMode == NPPEOLWindows ? NSControlStateValueOn : NSControlStateValueOff; return doc && doc.eolMode != NPPEOLWindows && !doc.isReadOnly;
        case NPPCmdEditEOLToUnix: item.state = doc.eolMode == NPPEOLUnix ? NSControlStateValueOn : NSControlStateValueOff; return doc && doc.eolMode != NPPEOLUnix && !doc.isReadOnly;
        case NPPCmdEditEOLToMac: item.state = doc.eolMode == NPPEOLMac ? NSControlStateValueOn : NSControlStateValueOff; return doc && doc.eolMode != NPPEOLMac && !doc.isReadOnly;
        case NPPCmdEditToggleReadOnly: item.state = doc.isReadOnly ? NSControlStateValueOn : NSControlStateValueOff; return doc != nil;
        case NPPCmdEditSetReadOnlyAll: case NPPCmdEditClearReadOnlyAll: return count > 0;

        case NPPCmdSearchFind: case NPPCmdSearchReplace: case NPPCmdSearchMark: case NPPCmdSearchIncremental: case NPPCmdSearchGoToLine:
        case NPPCmdSearchSelectAndFindNext: case NPPCmdSearchSelectAndFindPrev: case NPPCmdSearchVolatileFindNext: case NPPCmdSearchVolatileFindPrev:
            return ed != nil;
        case NPPCmdSearchFindNext: case NPPCmdSearchFindPrev:
            return ed != nil && NPPFindPanelController.shared.searchText.length > 0;

        case NPPCmdViewAlwaysOnTop: item.state = self.window.level == NSFloatingWindowLevel ? NSControlStateValueOn : NSControlStateValueOff; return YES;
        case NPPCmdViewFullScreen: item.state = fullScreen ? NSControlStateValueOn : NSControlStateValueOff; return !_distractionFree;
        case NPPCmdViewDistractionFree: item.state = _distractionFree ? NSControlStateValueOn : NSControlStateValueOff; return _distractionFree || !fullScreen;
        case NPPCmdViewTabFirst: case NPPCmdViewTabLast: case NPPCmdViewTabNext: case NPPCmdViewTabPrev: return count > 1;
        case NPPCmdViewTabMoveForward: return idx != NSNotFound && idx + 1 < count;
        case NPPCmdViewTabMoveBackward: return idx != NSNotFound && idx > 0;
        case NPPCmdViewTabColorNone: return doc.tabColor != nil;

        // ---- second edit view ----
        // Moving the last document of a view into an empty one only swaps which view is shown, so N++ refuses it.
        case NPPCmdViewMoveToOtherView: return doc && !(count == 1 && _docs[[self otherView]].count == 0);
        case NPPCmdViewCloneToOtherView: return doc != nil;
        case NPPCmdViewSwitchToOtherView: return [self isSplit];
        case NPPCmdViewSyncScrollVertical:
            item.state = _syncScrollV ? NSControlStateValueOn : NSControlStateValueOff;
            return [self isSplit];
        case NPPCmdViewSyncScrollHorizontal:
            item.state = _syncScrollH ? NSControlStateValueOn : NSControlStateValueOff;
            return [self isSplit];
        case NPPCmdViewZoomSync:
            item.state = _zoomSync ? NSControlStateValueOn : NSControlStateValueOff;
            return [self isSplit];
        // The new instance loads the file from disk: an unsaved or untitled buffer has nothing to open there.
        case NPPCmdViewMoveToNewInstance: case NPPCmdViewOpenInNewInstance: return hasFile && !doc.isDirty;
        // Nothing to rotate with one view: N++ only offers these on the splitter itself.
        case NPPCmdViewRotateRight: case NPPCmdViewRotateLeft: return [self isSplit];
        case NPPCmdFileCloseAllButPinned: return [self unpinnedDocuments].count > 0;
        case NPPCmdTabPin:
            item.state = (doc && [_pinnedDocs containsObject:doc]) ? NSControlStateValueOn : NSControlStateValueOff;
            return doc && [_tabBars[_view] respondsToSelector:@selector(togglePinnedAtIndex:)];
        case NPPCmdTabDropDownList: return count > 0 && [_tabBars[_view] respondsToSelector:@selector(showTabListMenu)];

        case NPPCmdViewMonitoring: item.state = doc.isMonitoring ? NSControlStateValueOn : NSControlStateValueOff; return hasFile;

        case NPPCmdEncodingANSI: case NPPCmdEncodingUTF8: case NPPCmdEncodingUTF8BOM: case NPPCmdEncodingUTF16BE: case NPPCmdEncodingUTF16LE: {
            if (!doc) return NO;
            static const NPPEncoding map[] = {NPPEncodingANSI, NPPEncodingUTF8, NPPEncodingUTF8BOM, NPPEncodingUTF16BE, NPPEncodingUTF16LE};
            NPPEncoding e = map[tag - NPPCmdEncodingANSI];
            BOOL isCurrent = doc.encoding == e && (e != NPPEncodingANSI || ![NPPCharset charsetForCFEncoding:doc.codepage] || doc.codepage == kCFStringEncodingWindowsLatin1);
            item.state = isCurrent ? NSControlStateValueOn : NSControlStateValueOff;
            return !doc.isDirty || isCurrent;
        }
        case NPPCmdEncodingConvertToANSI: case NPPCmdEncodingConvertToUTF8: case NPPCmdEncodingConvertToUTF8BOM: case NPPCmdEncodingConvertToUTF16BE: case NPPCmdEncodingConvertToUTF16LE: {
            if (!doc) return NO;
            static const NPPEncoding map[] = {NPPEncodingANSI, NPPEncodingUTF8, NPPEncodingUTF8BOM, NPPEncodingUTF16BE, NPPEncodingUTF16LE};
            return doc.encoding != map[tag - NPPCmdEncodingConvertToANSI];
        }
        default: break;
    }

    if ([NPPEditCommands handlesCommand:(NPPCmd)tag]) return ed && [NPPEditCommands canPerformCommand:(NPPCmd)tag onEditor:ed language:doc.language];
    if ([NPPSearchViewCommands handlesCommand:(NPPCmd)tag]) {
        if (!ed) return NO;
        item.state = [NPPSearchViewCommands commandIsChecked:(NPPCmd)tag onEditor:ed] ? NSControlStateValueOn : NSControlStateValueOff;
        return [NPPSearchViewCommands canPerformCommand:(NPPCmd)tag onEditor:ed];
    }
    if (tag >= NPPCmdLangUserDefinedBase && tag < NPPCmdLangUserDefinedBase + 100) {
        NSArray<NSString *> *names = [self userDefinedLanguageNames];
        NSInteger i = tag - NPPCmdLangUserDefinedBase;
        if (!doc || i >= (NSInteger)names.count) return NO;
        item.state = [doc.userDefinedLanguageName isEqualToString:names[(NSUInteger)i]] ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (Class h = NPPFeatureHandlerForCommand((NPPCmd)tag)) {
        Class<NPPCommandHandler> handler = (Class<NPPCommandHandler>)h;
        if ([handler respondsToSelector:@selector(commandIsChecked:context:)])
            item.state = [handler commandIsChecked:(NPPCmd)tag context:self] ? NSControlStateValueOn : NSControlStateValueOff;
        if ([handler respondsToSelector:@selector(dynamicTitleForCommand:context:)]) {
            NSString *t = [handler dynamicTitleForCommand:(NPPCmd)tag context:self];
            if (t.length) item.title = t;
        }
        return [handler canPerformCommand:(NPPCmd)tag context:self];
    }
    if (NPPIsAppLevelCommand(tag)) {
        NPPForwardGuard guard;
        id d = NSApp.delegate;
        if (guard.entered && [d respondsToSelector:@selector(validateMenuItem:)]) return [d validateMenuItem:item];
    }
    return NO;
}

#pragma mark - Title / status bar

- (void)updateWindowTitle {
    NPPDocument *doc = self.currentDocument;
    // N++ Notepad_plus::setTitle: NppGUI::_shortTitlebar ("Show only the file name in the title bar") shows the
    // buffer's name, otherwise the full path. An untitled buffer has only its name either way.
    NSString *name = NPPPreferences.shared.shortTitleBar ? doc.displayName : (doc.fileURL.path ?: doc.displayName);
    if (!name) name = @"";
    self.window.title = [NSString stringWithFormat:@"%@%@ - Notepad++", doc.isDirty ? @"*" : @"", name];
    self.window.representedURL = doc.fileURL;
    self.window.documentEdited = doc.isDirty;
}

- (void)updateStatusBar {
    NPPDocument *doc = self.currentDocument;
    ScintillaView *ed = doc.editor;
    if (!ed) {
        _statusBar.docTypeText = @""; _statusBar.docSizeText = @""; _statusBar.cursorText = @"";
        _statusBar.eolText = @""; _statusBar.encodingText = @""; _statusBar.insertModeText = @"";
        return;
    }
    // Menus come from the app delegate; fetch lazily (nil-safe for the headless self-test).
    id appDelegate = NSApp.delegate;
    if (!_statusBar.eolMenu && [appDelegate respondsToSelector:@selector(eolMenu)]) _statusBar.eolMenu = [appDelegate eolMenu];
    if (!_statusBar.encodingMenu && [appDelegate respondsToSelector:@selector(encodingMenu)]) _statusBar.encodingMenu = [appDelegate encodingMenu];

    // A user-defined language replaces the built-in lexer for this buffer, so it is what the status bar should name.
    _statusBar.docTypeText = doc.userDefinedLanguageName.length ? [NSString stringWithFormat:@"%@ (User Defined)", doc.userDefinedLanguageName]
                                                                : (doc.language.longName ?: @"");
    _statusBar.docSizeText = [NSString stringWithFormat:@"length : %@    lines : %@",
                              NPPFormatGroupedInteger(NPPSci(ed, SCI_GETLENGTH)), NPPFormatGroupedInteger(NPPSci(ed, SCI_GETLINECOUNT))];

    sptr_t pos = NPPSci(ed, SCI_GETCURRENTPOS);
    sptr_t line = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)pos);
    sptr_t col = NPPSci(ed, SCI_GETCOLUMN, (uptr_t)pos);
    long long selChars = 0, selLines = 0;
    sptr_t nSel = NPPSci(ed, SCI_GETSELECTIONS);
    if (!NPPSci(ed, SCI_GETSELECTIONEMPTY)) {
        // ponytail: N++ distinguishes rectangular ("NxM") and multi-stream selections; we sum chars over <=99 selections
        // and count lines from the main one (rows for rectangular).
        sptr_t limit = MIN(nSel, (sptr_t)99);
        for (sptr_t i = 0; i < limit; i++) {
            sptr_t s = NPPSci(ed, SCI_GETSELECTIONNSTART, (uptr_t)i), e = NPPSci(ed, SCI_GETSELECTIONNEND, (uptr_t)i);
            if (e < s) std::swap(s, e);
            selChars += NPPSci(ed, SCI_COUNTCHARACTERS, (uptr_t)s, e);
        }
        if (nSel > 1 && NPPSci(ed, SCI_SELECTIONISRECTANGLE)) {
            selLines = nSel;
        } else {
            sptr_t s = NPPSci(ed, SCI_GETSELECTIONSTART), e = NPPSci(ed, SCI_GETSELECTIONEND);
            selLines = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)e) - NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)s) + 1;
        }
    }
    _statusBar.cursorText = [NSString stringWithFormat:@"Ln : %@    Col : %@    Pos : %@    Sel : %@ | %@",
                             NPPFormatGroupedInteger(line + 1), NPPFormatGroupedInteger(col + 1), NPPFormatGroupedInteger(pos + 1),
                             NPPFormatGroupedInteger(selChars), NPPFormatGroupedInteger(selLines)];
    _statusBar.eolText = doc.eolDisplayName ?: @"";
    _statusBar.encodingText = doc.encodingDisplayName ?: @"";
    _statusBar.insertModeText = NPPSci(ed, SCI_GETOVERTYPE) ? @"OVR" : @"INS";
}

// Tab item + title + status bar for one document.
- (void)refreshDocument:(NPPDocument *)doc {
    [self reloadTabs];
    if (doc == self.currentDocument) {
        [self updateWindowTitle];
        [self updateStatusBar];
    }
}

#pragma mark - Theme / preferences

- (void)applyTheme {
    NPPLanguageManager *m = NPPLanguageManager.shared;
    BOOL dark = [m currentThemeIsDark];
    NSColor *defBg = [m globalBackgroundColorNamed:@"Default Style"];
    NSColor *defFg = [m globalForegroundColorNamed:@"Default Style"];
    NSColor *c;
    for (NPPTabBarView *bar in @[_tabBars[kMainView], _tabBars[kSubView]]) {
        if (defBg) bar.activeTabBackgroundColor = defBg;
        if ((c = [m globalForegroundColorNamed:@"Active tab focused indicator"])) bar.activeIndicatorColor = c;
        if (dark) {
            // N++ dark mode paints its own chrome (NppDarkMode: background 0x202020, text 0xE0E0E0, darker text 0xC0C0C0) and ignores the
            // light-mode "Inactive tabs"/"Active tab text" styler colours — do the same so the tab strip is not a light-grey band.
            NSColor *darkBg = [NSColor colorWithSRGBRed:0x20/255.0 green:0x20/255.0 blue:0x20/255.0 alpha:1];
            bar.barBackgroundColor = darkBg;
            bar.inactiveTabBackgroundColor = darkBg;
            bar.inactiveTabTextColor = [NSColor colorWithSRGBRed:0xC0/255.0 green:0xC0/255.0 blue:0xC0/255.0 alpha:1];
            bar.activeTabTextColor = defFg ?: [NSColor colorWithSRGBRed:0xE0/255.0 green:0xE0/255.0 blue:0xE0/255.0 alpha:1];
        } else {
            if ((c = [m globalForegroundColorNamed:@"Active tab text"])) bar.activeTabTextColor = c;
            if ((c = [m globalBackgroundColorNamed:@"Inactive tabs"])) { bar.inactiveTabBackgroundColor = c; bar.barBackgroundColor = c; }
            if ((c = [m globalForegroundColorNamed:@"Inactive tabs"])) bar.inactiveTabTextColor = c;
        }
        bar.showCloseButtons = NPPPreferences.shared.tabBarShowCloseButtons;
    }
    // ponytail: N++ paints the status bar with the system control colour; we use the window colour when light, editor bg when dark.
    _statusBar.backgroundColor = dark && defBg ? defBg : NSColor.windowBackgroundColor;
    _statusBar.textColor = dark && defFg ? defFg : NSColor.labelColor;
    for (NSInteger v = kMainView; v <= kSubView; v++) _containers[v].layer.backgroundColor = (defBg ?: NSColor.textBackgroundColor).CGColor;
    [self applyEditorBorderEdge];   // its colour follows the theme, so it is re-derived with the rest of the chrome
    [_panelHost applyThemeBackground:(dark ? defBg : nil) text:(dark ? defFg : nil)];
    self.window.appearance = dark ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
    for (NPPDocument *d in [self allDocuments]) [d applyThemeAndLanguage];
    for (NSInteger v = kMainView; v <= kSubView; v++) [_tabBars[v] reloadData];
    [_statusBar setNeedsDisplay:YES];
}

- (void)themeDidChange:(NSNotification *)n { [self applyTheme]; }

- (void)preferencesDidChange:(NSNotification *)n {
    NPPPreferences *prefs = NPPPreferences.shared;
    NPPLanguageManager *m = NPPLanguageManager.shared;
    NSString *wantName = prefs.fontName.length ? prefs.fontName : nil;
    BOOL fontChanged = !((wantName == m.overrideFontName) || [wantName isEqualToString:m.overrideFontName]) || m.overrideFontSize != prefs.fontSize;
    if (fontChanged) {
        m.overrideFontName = wantName;
        m.overrideFontSize = prefs.fontSize;
    }
    for (NPPDocument *d in [self allDocuments]) {
        [d applyPreferences];
        if (fontChanged) [d applyThemeAndLanguage];
    }
    for (NSInteger v = kMainView; v <= kSubView; v++) _tabBars[v].showCloseButtons = prefs.tabBarShowCloseButtons;
    // Margins ▸ Border width / "No edge" / Distraction Free padding, and MISC ▸ short title bar: all of them are
    // window geometry rather than editor state, so they land here rather than in -applyPreferences.
    [self layoutContent];
    [self updateWindowTitle];
    [self updateStatusBar];
    // NPPPreferences applies the plain Margins ▸ padding one main-queue turn from now (its own two-apply-paths
    // note), which would undo the Distraction Free padding -layoutContent just set. Put it back after it.
    if (_distractionFree) {
        __weak NPPEditorWindowController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applyDistractionFreePadding]; });
    }
}

#pragma mark - NPPTabBarDelegate

// Every callback carries the strip it came from: with two views the index is that view's tab index, and clicking
// a tab in the unfocused view moves the focus there (-selectDocument: does that).
- (void)tabBar:(NPPTabBarView *)bar didSelectTabAtIndex:(NSInteger)index {
    [self selectDocument:[self documentInView:[self viewForTabBar:bar] atIndex:index]];
}

- (void)tabBar:(NPPTabBarView *)bar didRequestCloseTabAtIndex:(NSInteger)index {
    NPPDocument *doc = [self documentInView:[self viewForTabBar:bar] atIndex:index];
    if (doc) [self closeDocument:doc];
}

- (void)tabBar:(NPPTabBarView *)bar didMoveTabFromIndex:(NSInteger)from toIndex:(NSInteger)to {
    [self moveDocumentAtIndex:from toIndex:to inView:[self viewForTabBar:bar]];
}

// Pinning is the tab bar's; the flag belongs to the buffer, because we rebuild every NPPTabItem on any change.
- (void)tabBar:(NPPTabBarView *)bar didSetPinned:(BOOL)pinned forTabAtIndex:(NSInteger)index {
    NPPDocument *doc = [self documentInView:[self viewForTabBar:bar] atIndex:index];
    if (!doc) return;
    if (pinned) [_pinnedDocs addObject:doc]; else [_pinnedDocs removeObject:doc];
}

- (NSString *)tabBar:(NPPTabBarView *)bar previewTextForTabAtIndex:(NSInteger)index {
    NPPDocument *doc = [self documentInView:[self viewForTabBar:bar] atIndex:index];
    if (!doc.editor) return nil;
    // ponytail: first 2 KB is plenty for a hover preview; the peeker truncates anyway.
    std::string head = NPPSciGetRange(doc.editor, 0, MIN((sptr_t)2048, NPPSci(doc.editor, SCI_GETLENGTH)));
    return [[NSString alloc] initWithBytes:head.data() length:head.size() encoding:NSUTF8StringEncoding];
}

// A new document joins the view whose strip was used.
// The strip needs a different amount of room: multi-line gained or lost a row, or the vertical preference was
// toggled. Its frame is ours, so re-run the layout — NPPTabBarView suppresses the notification the new frame
// would otherwise send straight back.
- (void)tabBarDidChangePreferredSize:(NPPTabBarView *)bar { [self layoutContent]; }

- (void)tabBar:(NPPTabBarView *)bar didDoubleClickEmptyArea:(NSPoint)point { [self newDocumentInView:[self viewForTabBar:bar]]; }
- (void)tabBarDidClickNewTab:(NPPTabBarView *)bar { [self newDocumentInView:[self viewForTabBar:bar]]; }

// A saved tab shows its path; an untitled one shows when it was created, which is the only thing telling
// "new 1", "new 2" and "new 3" apart (upstream appends Buffer::tabCreatedTimeString() in TTN_GETDISPINFO).
- (NSString *)tabBar:(NPPTabBarView *)bar toolTipForTabAtIndex:(NSInteger)index {
    NPPDocument *doc = [self documentInView:[self viewForTabBar:bar] atIndex:index];
    if (!doc) return nil;
    if (doc.fileURL) return doc.fileURL.path;
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateStyle = NSDateFormatterShortStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:@"%@\n%@", doc.displayName, [f stringFromDate:doc.createdDate]];
}

// ---- A tab dragged out of its strip (N++ TCN_TABDROPPEDOUTSIDE) ----------------------------------------------
// The strip only reports "let go here, in screen coordinates"; the three destinations are ours to tell apart.

// Screen rect of a view that is actually showing. A hidden one is NSZeroRect, which no point is ever inside — the
// unused view's container keeps a stale frame on top of the visible one, so its own rect would swallow every drop.
- (NSRect)screenFrameOfView:(NSView *)v {
    if (!v || v.isHiddenOrHasHiddenAncestor || !self.window) return NSZeroRect;
    return [self.window convertRectToScreen:[v convertRect:v.bounds toView:nil]];
}

- (NPPTabDropTarget)dropTargetForScreenPoint:(NSPoint)p fromView:(NSInteger)v {
    NSInteger other = 1 - v;
    if ([self isSplit] && (NSPointInRect(p, [self screenFrameOfView:_tabBars[other]]) ||
                           NSPointInRect(p, [self screenFrameOfView:_containers[other]])))
        return NPPTabDropOtherView;
    return NSPointInRect(p, self.window.frame) ? NPPTabDropSameWindow : NPPTabDropOutside;
}

// N++ builds _tabPopupDropMenu once and keeps it; two items are cheaper to rebuild than to invalidate. Both go
// through -nppCommand:, so -validateMenuItem: greys "Move" out for a view's last document exactly as the View
// menu does rather than offering something that would do nothing.
- (NSMenu *)tabDropMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tab drop"];
    for (NSArray *item in @[@[@"Move to Other View", @(NPPCmdViewMoveToOtherView)],
                            @[@"Clone to Other View", @(NPPCmdViewCloneToOtherView)]]) {
        NSMenuItem *it = [menu addItemWithTitle:item[0] action:@selector(nppCommand:) keyEquivalent:@""];
        it.target = self;
        it.tag = [item[1] integerValue];
    }
    return menu;
}

- (void)tabBar:(NPPTabBarView *)bar didDropTabAtIndex:(NSInteger)index outsideAtScreenPoint:(NSPoint)point {
    NSInteger v = [self viewForTabBar:bar];
    NPPDocument *doc = [self documentInView:v atIndex:index];
    if (!doc) return;
    [self selectDocument:doc];   // everything below acts on the current buffer, as the equivalent menu items do
    switch ([self dropTargetForScreenPoint:point fromView:v]) {
        case NPPTabDropOtherView:
            // ponytail: a plain move; N++ clones instead when ⌃ is held at the drop. Read the modifier here if
            // anyone misses it.
            [self sendCurrentDocumentToOtherViewCloning:NO];
            return;
        case NPPTabDropOutside:
            // The new instance loads the file from disk, so there has to be one and it has to be saved — N++ puts
            // up a "Document is modified, save it then try again" box; the status bar is this port's version.
            if (!doc.fileURL || doc.isDirty)
                [self contextReportStatus:@"Save the document before dragging it out to a new window." isError:YES];
            else
                [self openCurrentDocumentInNewInstanceMoving:NO];
            return;
        case NPPTabDropSameWindow:
            [[self tabDropMenu] popUpMenuPositioningItem:nil atLocation:point inView:nil];   // inView:nil = screen coordinates
            return;
    }
}

- (void)tabBar:(NPPTabBarView *)bar didDropFileURLs:(NSArray<NSURL *> *)urls {
    _view = [self viewForTabBar:bar];
    [self openDocumentsAtURLs:urls];
}

// N++ builds this list in NppNotification.cpp:1096-1140. The Windows shells become their macOS opposite numbers
// (Explorer → Finder, cmd / PowerShell → Terminal), but the two groupings N++ taught the hand — "Open into" and
// "Move Document" — are kept as submenus, because that is the shape the muscle memory reaches into.
- (NSMenu *)tabBar:(NPPTabBarView *)bar contextMenuForTabAtIndex:(NSInteger)index {
    NPPDocument *clicked = [self documentInView:[self viewForTabBar:bar] atIndex:index];
    if (!clicked) return nil;
    [self selectDocument:clicked];   // N++ activates the right-clicked tab, commands act on the current buffer
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tab"];
    NSMenuItem *(^add)(NSMenu *, NSString *, NPPCmd) = ^NSMenuItem *(NSMenu *m, NSString *title, NPPCmd cmd) {
        NSMenuItem *it = [m addItemWithTitle:title action:@selector(nppCommand:) keyEquivalent:@""];
        it.target = self;
        it.tag = cmd;
        return it;
    };
    NSMenu *(^sub)(NSString *) = ^NSMenu *(NSString *title) {
        NSMenu *m = [[NSMenu alloc] initWithTitle:title];
        [menu addItemWithTitle:title action:NULL keyEquivalent:@""].submenu = m;
        return m;
    };
    add(menu, @"Close", NPPCmdFileClose);
    add(menu, @"Close All BUT This", NPPCmdFileCloseAllButCurrent);
    add(menu, @"Close All BUT Pinned", NPPCmdFileCloseAllButPinned);
    add(menu, @"Close All to the Left", NPPCmdFileCloseAllToLeft);
    add(menu, @"Close All to the Right", NPPCmdFileCloseAllToRight);
    add(menu, @"Close All Unchanged", NPPCmdFileCloseAllUnchanged);
    // N++ renames this item rather than checking it (NppNotification.cpp:1217-1236). The menu is rebuilt on every
    // right-click, so the title is simply chosen here; the checkmark -validateMenuItem: puts on the tag would then
    // be a second signal saying the same thing, so this copy hides the mark. It is the only way to pin a tab once
    // Preferences ▸ "Show only pinned button" has taken the pin box off every unpinned tab.
    add(menu, [_pinnedDocs containsObject:clicked] ? @"Unpin Tab" : @"Pin Tab", NPPCmdTabPin).onStateImage = nil;
    [menu addItem:NSMenuItem.separatorItem];
    add(menu, @"Save", NPPCmdFileSave);
    add(menu, @"Save As…", NPPCmdFileSaveAs);
    NSMenu *openInto = sub(@"Open into");
    add(openInto, @"Open Containing Folder in Finder", NPPCmdFileOpenContainingFolder);
    add(openInto, @"Open in Terminal", NPPCmdFileOpenInTerminal);
    add(openInto, @"Open Containing Folder as Workspace", NPPCmdFileContainingFolderAsWorkspace);
    [openInto addItem:NSMenuItem.separatorItem];
    add(openInto, @"Open in Default Viewer", NPPCmdFileOpenInDefaultViewer);
    add(menu, @"Rename…", NPPCmdFileRename);
    add(menu, @"Move to Trash", NPPCmdFileMoveToTrash);
    add(menu, @"Reload", NPPCmdFileReload);
    add(menu, @"Print…", NPPCmdFilePrint);
    [menu addItem:NSMenuItem.separatorItem];
    add(menu, @"Read-Only", NPPCmdEditToggleReadOnly);
    add(menu, @"Clear Read-Only Flag", NPPCmdEditClearReadOnlyAll);
    [menu addItem:NSMenuItem.separatorItem];
    add(menu, @"Copy Full File Path", NPPCmdEditCopyFullPath);
    add(menu, @"Copy Filename", NPPCmdEditCopyFileName);
    add(menu, @"Copy Current Dir. Path", NPPCmdEditCopyDirPath);
    [menu addItem:NSMenuItem.separatorItem];
    // N++ groups all six under "Move Document"; right-clicking a tab is how most people reach the second view, and
    // View ▸ Move/Clone Current Document is not where anyone looks first.
    NSMenu *moveDoc = sub(@"Move Document");
    add(moveDoc, @"Move to Start", NPPCmdViewTabMoveToStart);
    add(moveDoc, @"Move to End", NPPCmdViewTabMoveToEnd);
    [moveDoc addItem:NSMenuItem.separatorItem];
    add(moveDoc, @"Move to Other View", NPPCmdViewMoveToOtherView);
    add(moveDoc, @"Clone to Other View", NPPCmdViewCloneToOtherView);
    add(moveDoc, @"Move to New Instance", NPPCmdViewMoveToNewInstance);
    add(moveDoc, @"Open in New Instance", NPPCmdViewOpenInNewInstance);
    NSMenu *colors = sub(@"Apply Color to Tab");
    for (NSInteger i = 0; i < 5; i++)
        add(colors, [NSString stringWithFormat:@"Apply Color %ld", (long)(i + 1)], (NPPCmd)(NPPCmdViewTabColor1 + i));
    add(colors, @"Remove Color", NPPCmdViewTabColorNone);
    return menu;
}

// The menu that directly holds the nppCommand: item with this tag, or nil. Same shape as NPPDocument's
// NPPBookmarkMenu(), which finds Search ▸ Bookmark the same way.
static NSMenu *NPPMenuHoldingCommand(NSMenu *root, NPPCmd tag) {
    for (NSMenuItem *item in root.itemArray) {
        if (item.submenu) { NSMenu *found = NPPMenuHoldingCommand(item.submenu, tag); if (found) return found; }
        else if (item.tag == (NSInteger)tag && item.action == @selector(nppCommand:)) return item.menu;
    }
    return nil;
}

// N++ offers Pin Tab on the tab context menu only (NppNotification.cpp:1106). A command that is on no main menu is
// invisible to the Shortcut Mapper and to the context-menu editor — both build their tables from NSApp.mainMenu —
// so the port also hangs it off View ▸ Tab, the submenu that already owns every other whole-tab command. That menu
// is built in NPPAppDelegate.mm, which is not ours to edit; the item is inserted here instead, once, from the app's
// own window (-showWindow:). Returns the item, or nil when the root carries no View ▸ Tab submenu; idempotent, so
// a second window hands back the item the first one added. Takes the root so the self-check can drive it.
// ponytail: a fixed title plus the checkmark -validateMenuItem: already sets, rather than N++'s Pin/Unpin rename.
// NPPLocalization re-translates on NSMenuDidChangeItem keyed on the English string, so a main-menu title rewritten
// on every validation pass would fight it. Upgrade: build the item in -buildMainMenu and rename it there.
+ (NSMenuItem *)addPinTabItemToMainMenu:(NSMenu *)mainMenu {
    if (!mainMenu) return nil;
    NSMenu *tab = NPPMenuHoldingCommand(mainMenu, NPPCmdViewTabMoveToEnd);   // the View ▸ Tab submenu
    if (!tab) return nil;
    for (NSMenuItem *it in tab.itemArray) if (it.tag == NPPCmdTabPin) return it;
    [tab addItem:NSMenuItem.separatorItem];
    NSMenuItem *pin = [tab addItemWithTitle:@"Pin Tab" action:@selector(nppCommand:) keyEquivalent:@""];
    pin.tag = NPPCmdTabPin;   // target nil: the responder chain reaches the key window's controller, as elsewhere
    return pin;
}

#pragma mark - NPPDocumentDelegate

- (void)documentDidChangeDirtyState:(NPPDocument *)doc { [self refreshDocument:doc]; }
- (void)documentDidUpdateUI:(NPPDocument *)doc { [self syncScrollFromDocument:doc]; if (doc == self.currentDocument) [self updateStatusBar]; }
- (void)documentDidChangeMetadata:(NPPDocument *)doc { [self refreshDocument:doc]; }
- (void)documentDidZoom:(NPPDocument *)doc { [self syncZoomFromDocument:doc]; if (doc == self.currentDocument) [self updateStatusBar]; }
- (void)document:(NPPDocument *)doc didReceiveDroppedFileURLs:(NSArray<NSURL *> *)urls { [self openDocumentsAtURLs:urls]; }

- (void)documentFileDidChangeOnDisk:(NPPDocument *)doc {
    if (doc.isMonitoring) { if (doc == self.currentDocument) [self updateStatusBar]; return; }   // tail -f: document reloads itself
    if (doc == self.currentDocument && self.window.isKeyWindow) [self promptReloadForDocument:doc];
    else [_pendingReloadPrompt addObject:doc];
}

#pragma mark - NPPFindTargetProvider

- (ScintillaView *)currentEditorForFind { return self.currentDocument.editor; }

- (NSArray<ScintillaView *> *)allOpenEditorsForFind {
    NSArray<NPPDocument *> *all = [self allDocuments];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:all.count];
    for (NPPDocument *d in all) if (d.editor) [a addObject:d.editor];
    return a;
}

- (void)findPanelDidReportStatus:(NSString *)status isError:(BOOL)isError {
    // ponytail: N++ shows this inside the dialog; we flash it in the doc-type field for 3 s.
    _statusBar.docTypeText = status ?: @"";
    NSUInteger token = ++_statusFlashToken;
    __weak NPPEditorWindowController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NPPEditorWindowController *self_ = weakSelf;
        if (self_ && self_->_statusFlashToken == token) [self_ updateStatusBar];
    });
}

// The UDL list lives in an optional module; look it up by name so this file does not depend on its header.
- (NSArray<NSString *> *)userDefinedLanguageNames {
    Class c = NSClassFromString(@"NPPUserDefinedLanguages");
    if (![c respondsToSelector:@selector(shared)]) return @[];
    id mgr = [c performSelector:@selector(shared)];
    return [mgr respondsToSelector:@selector(languageNames)] ? [mgr performSelector:@selector(languageNames)] : @[];
}

#pragma mark - NPPCommandContext (services for the feature modules)

- (NPPDocument *)contextCurrentDocument { return self.currentDocument; }
- (NSArray<NPPDocument *> *)contextOpenDocuments { return [self allDocuments]; }
- (NSWindow *)contextWindow { return self.window; }
- (NPPDocument *)contextOpenFileURL:(NSURL *)url { return [self openDocumentAtURL:url]; }

- (void)contextRevealFileURL:(NSURL *)url line:(NSInteger)line {
    NPPDocument *doc = [self openDocumentAtURL:url];
    if (!doc) return;
    if (line > 0) {
        ScintillaView *ed = doc.editor;
        sptr_t l = MIN((sptr_t)line - 1, NPPSci(ed, SCI_GETLINECOUNT) - 1);
        NPPSci(ed, SCI_ENSUREVISIBLEENFORCEPOLICY, (uptr_t)l);
        NPPSci(ed, SCI_GOTOLINE, (uptr_t)l);
        NPPSci(ed, SCI_SETSEL, (uptr_t)NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)l), NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)l));
        NPPSci(ed, SCI_SCROLLCARET);
        [self.window makeFirstResponder:[ed content]];
    }
    [self updateStatusBar];
}

- (void)contextSelectDocument:(NPPDocument *)doc { [self selectDocument:doc]; }
- (void)contextTogglePanel:(id<NPPPanel>)panel { [_panelHost togglePanel:panel]; [self panelsDidChange]; }
- (void)contextShowPanel:(id<NPPPanel>)panel { [_panelHost showPanel:panel]; [self panelsDidChange]; }
- (BOOL)contextPanelIsVisible:(id<NPPPanel>)panel { return [_panelHost isPanelVisible:panel]; }
- (void)contextRefreshUI { [self updateStatusBar]; [self updateWindowTitle]; }
- (void)contextReportStatus:(NSString *)message isError:(BOOL)isError { [self findPanelDidReportStatus:message isError:isError]; }

// A panel appearing or disappearing changes the editor area, and every panel wants the current document.
- (void)panelsDidChange {
    [self layoutContent];
    [_panelHost broadcastCurrentDocument:self.currentDocument];
    [self rememberOpenPanels];   // N++ writes the *KeepState flags out with the rest of its config
}

#pragma mark - NSWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
    // N++: closing the main window quits the application.
    if ([self promptToSaveAllBeforeQuit]) {
        _quitApproved = YES;
        [NSApp terminate:nil];
        _quitApproved = NO;   // only reached if termination was cancelled elsewhere
    }
    return NO;
}

#pragma mark - Headless checks (NPPSelfTest calls +selfCheckFailures)

// Drives a real controller through the second edit view the way the menu does: validate first, then dispatch, so a
// command that stops being reachable shows up as a failure rather than as a menu item that quietly does nothing.
static BOOL NPPRunCmd(NPPEditorWindowController *wc, NPPCmd cmd, NSMutableArray<NSString *> *fails) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
    item.tag = cmd;
    if (![wc validateMenuItem:item]) {
        [fails addObject:[NSString stringWithFormat:@"command %ld is disabled but should be available", (long)cmd]];
        return NO;
    }
    [wc nppCommand:item];
    return YES;
}
static BOOL NPPCmdEnabled(NPPEditorWindowController *wc, NPPCmd cmd) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
    item.tag = cmd;
    return [wc validateMenuItem:item];
}
// Validation is also what puts the tick on a toggle, so this is how the check reads a persisted setting back.
static BOOL NPPCmdChecked(NPPEditorWindowController *wc, NPPCmd cmd) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
    item.tag = cmd;
    [wc validateMenuItem:item];
    return item.state == NSControlStateValueOn;
}
static void NPPFill(NPPDocument *doc, NSString *text) {
    NPPSciStr(doc.editor, SCI_SETTEXT, 0, text.UTF8String);
    NPPSci(doc.editor, SCI_SETSAVEPOINT);   // stay clean: closing a dirty buffer would put up a modal alert
}

// The divider geometry on its own, without a window: two halves that do not overlap, a gap for the drag handle,
// and a centre view that gets the whole editor area back when the split goes away.
+ (void)appendPanelHostSplitFailures:(NSMutableArray<NSString *> *)f {
    const NSRect area = NSMakeRect(0, 0, 800, 600);
    NPPPanelHost *host = [[NPPPanelHost alloc] initWithFrame:area];
    [host layout];
    if (host.splitEnabled || !host.secondaryCenterView.isHidden || !NSEqualRects(host.centerView.frame, area))
        [f addObject:[NSString stringWithFormat:@"panel host: unsplit centre is %@, want the whole area",
                      NSStringFromRect(host.centerView.frame)]];
    CGFloat wantedPosition = host.splitPosition;   // both are persisted: put the user's divider back before returning
    BOOL wantedVertical = host.splitVertical;
    host.splitVertical = YES;
    host.splitEnabled = YES;
    NSRect first = host.centerView.frame, second = host.secondaryCenterView.frame;
    if (NSMinX(second) <= NSMaxX(first) || NSHeight(first) != NSHeight(area) || NSHeight(second) != NSHeight(area))
        [f addObject:[NSString stringWithFormat:@"vertical split halves overlap or are misshapen: %@ / %@",
                      NSStringFromRect(first), NSStringFromRect(second)]];
    host.splitPosition = 0.25;
    if (NSWidth(host.centerView.frame) >= NSWidth(first)) [f addObject:@"moving the divider did not resize the first half"];
    host.splitVertical = NO;
    if (NSMinY(host.secondaryCenterView.frame) <= NSMaxY(host.centerView.frame))
        [f addObject:@"a horizontal split does not stack the halves"];
    host.splitPosition = wantedPosition;
    host.splitVertical = wantedVertical;
    host.splitEnabled = NO;
    [host layout];
    if (!host.secondaryCenterView.isHidden || !NSEqualRects(host.centerView.frame, area))
        [f addObject:@"collapsing the split did not give the editor area back to the centre view"];
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *f = [NSMutableArray array];
    [self appendPanelHostSplitFailures:f];
    NPPEditorWindowController *wc = [[NPPEditorWindowController alloc] init];   // never ordered front
    NPPDocument *a = wc.currentDocument;
    if (!a) { [f addObject:@"no initial document"]; return f; }

    // One view is the default and must look like it always did: documents, tab bar and selection all line up.
    if (wc.panelHost.splitEnabled) [f addObject:@"split is on for a fresh window"];
    NPPDocument *b = [wc newDocument];
    // Lines far wider than the window and far more of them than fit on screen, so both axes really do have somewhere
    // to scroll to — Scintilla clamps SCI_SETFIRSTVISIBLELINE to what the content allows, and a document that fits on
    // screen would clamp both views to line 0 and let a sync that does nothing at all pass.
    NSString *body = [@"" stringByPaddingToLength:80000 withString:
                      [[@"" stringByPaddingToLength:200 withString:@"the quick brown fox " startingAtIndex:0] stringByAppendingString:@"\n"]
                                       startingAtIndex:0];
    NPPFill(a, body);
    NPPFill(b, body);
    if (wc.documents.count != 2) [f addObject:[NSString stringWithFormat:@"documents %lu, want 2", (unsigned long)wc.documents.count]];
    if (wc.tabBar.items.count != 2) [f addObject:@"one view: the tab bar does not hold every document"];
    [wc selectDocumentAtIndex:1];
    if (wc.tabBar.selectedIndex != 1) [f addObject:@"one view: -selectDocumentAtIndex: and the tab bar disagree"];

    // Moving the only document of a view into an empty one would just swap which view is shown: N++ refuses.
    if (NPPCmdEnabled(wc, NPPCmdViewSwitchToOtherView)) [f addObject:@"Focus on Another View is enabled without a second view"];
    if (NPPCmdEnabled(wc, NPPCmdViewSyncScrollVertical)) [f addObject:@"sync scrolling is enabled without a second view"];

    NPPRunCmd(wc, NPPCmdViewMoveToOtherView, f);            // b moves across, the window splits
    if (!wc.panelHost.splitEnabled) [f addObject:@"moving a document to the other view did not split the window"];
    if (wc.documents.count != 2) [f addObject:@"a moved document was lost from -documents"];
    if (wc.currentDocument != b) [f addObject:@"the focus did not follow the moved document"];
    if (wc.tabBar.items.count != 1) [f addObject:@"the sub view's strip does not hold exactly the moved document"];
    // Commands that act on every buffer must not start reading the focused view's tab count once the window splits.
    if (!NPPCmdEnabled(wc, NPPCmdFileCloseAllButCurrent))
        [f addObject:@"Close All BUT This went dead with one document in each view"];

    NPPRunCmd(wc, NPPCmdViewSwitchToOtherView, f);
    if (wc.currentDocument != a) [f addObject:@"Focus on Another View did not go back to the main view"];

    // Synchronised scrolling mirrors the other view and must not bounce back (the mirror re-enters this path). The two
    // views are nudged apart first and the check refuses to score itself unless they really are apart, so a sync that
    // does nothing can never pass by accident. Scintilla clamps both axes, so the source's own value is the target.
    // Nothing is ever drawn here, so Scintilla never widens its scroll width past the visible width and clamps every
    // x offset to 0 (ScintillaCocoa::SetHorizontalScrollPos); word wrap, a user preference, pins it at 0 too. Set both
    // now that the split has stopped re-framing the editors — NPPDocument resets the scroll width on every reframe —
    // or the horizontal check has no offset to mirror and passes on 0 == 0 whatever the sync does.
    for (NPPDocument *d in @[a, b]) {
        d.editor.scrollView.contentView.postsFrameChangedNotifications = NO;   // that is the reset NPPDocument hangs off
        NPPSci(d.editor, SCI_SETWRAPMODE, SC_WRAP_NONE);
        NPPSci(d.editor, SCI_SETSCROLLWIDTHTRACKING, 0);
        NPPSci(d.editor, SCI_SETSCROLLWIDTH, 8000);
    }
    NPPRunCmd(wc, NPPCmdViewSyncScrollHorizontal, f);
    NPPSci(b.editor, SCI_SETXOFFSET, 0);
    NPPSci(a.editor, SCI_SETXOFFSET, 320);
    sptr_t xOffset = NPPSci(a.editor, SCI_GETXOFFSET);
    if (NPPSci(b.editor, SCI_GETXOFFSET) == xOffset)
        [f addObject:[NSString stringWithFormat:@"horizontal sync: both views sit at x offset %ld, so the check proves nothing", (long)xOffset]];
    [wc syncScrollFromDocument:a];
    if (NPPSci(b.editor, SCI_GETXOFFSET) != xOffset)
        [f addObject:[NSString stringWithFormat:@"horizontal sync: other view at %ld, want %ld",
                      (long)NPPSci(b.editor, SCI_GETXOFFSET), (long)xOffset]];
    NPPRunCmd(wc, NPPCmdViewSyncScrollVertical, f);
    NPPSci(b.editor, SCI_SETFIRSTVISIBLELINE, 1);
    NPPSci(a.editor, SCI_SETFIRSTVISIBLELINE, 60);
    sptr_t firstLine = NPPSci(a.editor, SCI_GETFIRSTVISIBLELINE);
    if (NPPSci(b.editor, SCI_GETFIRSTVISIBLELINE) == firstLine)
        [f addObject:[NSString stringWithFormat:@"vertical sync: both views sit on line %ld, so the check proves nothing", (long)firstLine]];
    [wc syncScrollFromDocument:a];
    if (NPPSci(b.editor, SCI_GETFIRSTVISIBLELINE) != firstLine)
        [f addObject:[NSString stringWithFormat:@"vertical sync: other view at line %ld, want %ld",
                      (long)NPPSci(b.editor, SCI_GETFIRSTVISIBLELINE), (long)firstLine]];

    // Zoom sync is persisted, so it can start either way: drive it on from wherever it was and put it back after.
    BOOL zoomSyncWasOn = NPPCmdChecked(wc, NPPCmdViewZoomSync);
    if (!zoomSyncWasOn) NPPRunCmd(wc, NPPCmdViewZoomSync, f);
    if (!NPPCmdChecked(wc, NPPCmdViewZoomSync)) [f addObject:@"Zoom Sync does not tick when it is on"];
    NPPSci(b.editor, SCI_SETZOOM, 0);
    NPPSci(a.editor, SCI_SETZOOM, 3);
    [wc syncZoomFromDocument:a];
    if (NPPSci(b.editor, SCI_GETZOOM) != 3)
        [f addObject:[NSString stringWithFormat:@"zoom sync: other view at %ld, want 3", (long)NPPSci(b.editor, SCI_GETZOOM)]];
    if (!zoomSyncWasOn) NPPRunCmd(wc, NPPCmdViewZoomSync, f);

    // A clone is a second window onto the same buffer: an edit in one is the same text in the other.
    NPPRunCmd(wc, NPPCmdViewCloneToOtherView, f);
    if (wc.documents.count != 3) [f addObject:@"Clone to Other View did not add a buffer"];
    NPPDocument *twin = wc.currentDocument;
    if (twin == a) [f addObject:@"Clone to Other View did not focus the clone"];
    NPPSciStr(a.editor, SCI_INSERTTEXT, 0, "cloned!");
    if (NPPSci(twin.editor, SCI_GETLENGTH) != NPPSci(a.editor, SCI_GETLENGTH))
        [f addObject:@"the clone does not share the original's Scintilla document"];
    NPPSci(a.editor, SCI_SETSAVEPOINT);

    // Cloning again must not pile up a third buffer on the same file: N++ activates the copy that is already in the
    // other view (docGotoAnotherEditView's indexFound branch) rather than making another.
    NPPRunCmd(wc, NPPCmdViewCloneToOtherView, f);
    if (wc.documents.count != 3)
        [f addObject:[NSString stringWithFormat:@"cloning a buffer already open in the other view made a copy: %lu documents",
                      (unsigned long)wc.documents.count]];
    if (wc.currentDocument != a) [f addObject:@"cloning again did not activate the copy already in the other view"];
    [wc selectDocument:twin];

    // The sub view now holds two documents: the tab commands must count inside the focused strip, the way N++
    // counts them, not across every open buffer.
    NPPRunCmd(wc, NPPCmdViewTabFirst, f);
    if (wc.currentDocument != b) [f addObject:@"First Tab left the focused view"];
    [wc selectDocument:twin];

    // Close All but Pinned reads the tab bar's pinned flag, which we rebuild on every model change.
    [wc.tabBar togglePinnedAtIndex:wc.tabBar.selectedIndex];
    NPPDocument *pinned = wc.currentDocument;
    if (!NPPRunCmd(wc, NPPCmdFileCloseAllButPinned, f)) return f;
    if (wc.documents.count != 1 || wc.documents.firstObject != pinned)
        [f addObject:[NSString stringWithFormat:@"Close All but Pinned left %lu document(s), want the pinned one",
                      (unsigned long)wc.documents.count]];
    if (wc.panelHost.splitEnabled) [f addObject:@"the window stayed split with one view left"];
    if (NPPCmdEnabled(wc, NPPCmdFileCloseAllButPinned)) [f addObject:@"Close All but Pinned is offered with nothing left to close"];
    // One document, one view: moving it across would only swap which view is shown, so N++ refuses — and a
    // command we cannot perform has to be disabled, never a menu item that looks live and does nothing.
    if (NPPCmdEnabled(wc, NPPCmdViewMoveToOtherView)) [f addObject:@"Move to Other View is offered for a lone document"];
    if (!NPPCmdEnabled(wc, NPPCmdViewCloneToOtherView)) [f addObject:@"Clone to Other View is disabled with a document open"];
    if (NPPCmdEnabled(wc, NPPCmdViewSyncScrollVertical) || NPPCmdEnabled(wc, NPPCmdViewZoomSync))
        [f addObject:@"the sync commands stayed enabled after the split collapsed"];
    // Disabled is not enough: N++ clears the two scroll flags as the second view goes (checkSyncState), or they come
    // back silently on with a stale offset the next time the window splits.
    if (NPPCmdChecked(wc, NPPCmdViewSyncScrollVertical) || NPPCmdChecked(wc, NPPCmdViewSyncScrollHorizontal))
        [f addObject:@"the scroll syncs are still on after the split collapsed"];

    [self appendSortRotateAndSwitcherFailures:f controller:wc];
    [self appendTabDropOutFailures:f];
    [self appendPreferenceAndSessionFailures:f controller:wc];
    [self appendLayoutReloadAndAutoSessionFailures:f];
    [self appendMiscPreferenceFailures:f];
    [self appendSaveBatchFilterAndSessionDetailFailures:f];
    return f;
}

// Three things a session used to drop on the floor (collapsed folds, a hand-picked character set, the tab
// colour), the batch save prompt's two "…to All" answers, and the Open / Save panels' language filter.
// Its own controller: the prompt checks deliberately leave modified buffers behind, and a modified buffer in the
// shared one would put a real alert on screen the next time something closed it.
+ (void)appendSaveBatchFilterAndSessionDetailFailures:(NSMutableArray<NSString *> *)f {
    NPPEditorWindowController *wc = [[NPPEditorWindowController alloc] init];   // never ordered front
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *savedRecents = NPPPreferences.shared.recentFilePaths;   // saving here must not rewrite it
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"npp-window-savebatch-selfcheck"] isDirectory:YES];
    [fm removeItemAtURL:tmp error:NULL];
    [fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:NULL];

    // ---- The tab context menu: for several commands it is the only place a hand ever finds them ----
    // Pin Tab most of all — with Preferences ▸ "Show only pinned button" ticked the pin box is gone from every
    // unpinned tab, so an absent menu item means nothing can ever be pinned again.
    NSMenu *tabMenu = [wc tabBar:wc->_tabBars[kMainView] contextMenuForTabAtIndex:0];
    NSMutableSet<NSNumber *> *tabTags = [NSMutableSet set];
    for (NSMutableArray<NSMenu *> *pending = [NSMutableArray arrayWithObject:tabMenu]; pending.count; ) {
        NSMenu *m = pending.lastObject;
        [pending removeLastObject];
        for (NSMenuItem *it in m.itemArray) { if (it.submenu) [pending addObject:it.submenu]; else if (it.tag) [tabTags addObject:@(it.tag)]; }
    }
    for (NSNumber *want in @[@(NPPCmdTabPin), @(NPPCmdViewMoveToOtherView), @(NPPCmdViewCloneToOtherView),
                             @(NPPCmdViewTabMoveToStart), @(NPPCmdViewTabMoveToEnd),
                             @(NPPCmdFileOpenInTerminal), @(NPPCmdFileContainingFolderAsWorkspace)])
        if (![tabTags containsObject:want])
            [f addObject:[NSString stringWithFormat:@"the tab context menu lost command %@ (right-clicking a tab is where N++ put it)", want]];
    // N++ renames the pin item instead of checking it (NppNotification.cpp:1217-1236).
    NSMenuItem *(^pinItemIn)(NSMenu *) = ^NSMenuItem *(NSMenu *m) {
        for (NSMenuItem *it in m.itemArray) if (it.tag == NPPCmdTabPin) return it;
        return nil;
    };
    NSMenuItem *pinItem = pinItemIn(tabMenu);
    if (![pinItem.title isEqualToString:@"Pin Tab"])
        [f addObject:[NSString stringWithFormat:@"an unpinned tab is offered \"%@\", want \"Pin Tab\"", pinItem.title]];
    [wc->_tabBars[kMainView] togglePinnedAtIndex:0];
    NSMenuItem *unpinItem = pinItemIn([wc tabBar:wc->_tabBars[kMainView] contextMenuForTabAtIndex:0]);
    if (![unpinItem.title isEqualToString:@"Unpin Tab"])
        [f addObject:[NSString stringWithFormat:@"a pinned tab is offered \"%@\", want \"Unpin Tab\"", unpinItem.title]];
    [wc->_tabBars[kMainView] togglePinnedAtIndex:0];   // leave the controller as it was found

    // ---- View ▸ Tab ▸ Pin Tab: a command on no main menu is invisible to the Shortcut Mapper ----
    NSMenu *fakeMain = [[NSMenu alloc] initWithTitle:@""];
    NSMenu *fakeView = [[NSMenu alloc] initWithTitle:@"View"];
    [fakeMain addItemWithTitle:@"View" action:NULL keyEquivalent:@""].submenu = fakeView;
    NSMenu *fakeTab = [[NSMenu alloc] initWithTitle:@"Tab"];
    [fakeView addItemWithTitle:@"Tab" action:NULL keyEquivalent:@""].submenu = fakeTab;
    [fakeTab addItemWithTitle:@"Move to End" action:@selector(nppCommand:) keyEquivalent:@""].tag = NPPCmdViewTabMoveToEnd;
    NSMenuItem *viewPin = [NPPEditorWindowController addPinTabItemToMainMenu:fakeMain];
    if (viewPin.menu != fakeTab || viewPin.tag != NPPCmdTabPin || viewPin.action != @selector(nppCommand:))
        [f addObject:@"View ▸ Tab did not gain a working Pin Tab item"];
    if ([NPPEditorWindowController addPinTabItemToMainMenu:fakeMain] != viewPin)
        [f addObject:@"Pin Tab was added to View ▸ Tab a second time"];
    if ([NPPEditorWindowController addPinTabItemToMainMenu:[[NSMenu alloc] initWithTitle:@""]])
        [f addObject:@"Pin Tab was hung off a menu that has no View ▸ Tab submenu"];

    // ---- The Open / Save panels' file-type filter (N++ setFileOpenSaveDlgFilters) ----
    NSArray<NPPLanguage *> *filterLangs = [wc fileTypeFilterLanguages];
    if (filterLangs.count < 10)
        [f addObject:[NSString stringWithFormat:@"the file-type filter offers %lu languages; the language list is far longer",
                      (unsigned long)filterLangs.count]];
    for (NPPLanguage *l in filterLangs)
        if (!l.extensions.count) { [f addObject:@"the file-type filter offers a language that claims no extension"]; break; }
    NPPLanguage *normal = lm.normalTextLanguage;
    if (normal && [filterLangs indexOfObjectIdenticalTo:normal] != NSNotFound)
        [f addObject:@"the file-type filter offers Normal Text, whose filter would match nothing"];
    NPPLanguage *cpp = [lm languageNamed:@"cpp"];
    if (!cpp) {
        [f addObject:@"the self-check has no C++ language to build a file-type filter from"];
    } else {
        UTType *cppType = [UTType typeWithFilenameExtension:@"cpp"];
        if (cppType && ![[wc contentTypesForFilterLanguage:cpp] containsObject:cppType])
            [f addObject:@"the C++ filter does not accept .cpp: the panel filter is not built from the language's extensions"];
        NSPopUpButton *popUp = [wc fileTypeFilterPopUpSelecting:cpp];
        if (popUp.numberOfItems != (NSInteger)filterLangs.count + 1)
            [f addObject:[NSString stringWithFormat:@"the filter list has %ld rows, want %lu languages plus \"All types\"",
                          (long)popUp.numberOfItems, (unsigned long)filterLangs.count]];
        if ([popUp itemAtIndex:0].representedObject) [f addObject:@"the first filter row is not the unfiltered \"All types\" one"];
        if (popUp.selectedItem.representedObject != cpp)
            [f addObject:@"the Save panel's filter did not start on the document's own language"];
        if ([wc fileTypeFilterPopUpSelecting:nil].indexOfSelectedItem != 0)
            [f addObject:@"the Open panel's filter did not start on \"All types\""];
    }
    // "Append extension" is upstream's default and is remembered between panels (NppGUI::_setSaveDlgExtFiltToAllTypes).
    id savedAppend = [ud objectForKey:kSaveAppendExtKey];
    [ud removeObjectForKey:kSaveAppendExtKey];
    if (![wc saveDialogAppendsExtension]) [f addObject:@"\"Append extension\" is off out of the box; N++ ships it ticked"];
    [ud setBool:NO forKey:kSaveAppendExtKey];
    if ([wc saveDialogAppendsExtension]) [f addObject:@"unticking \"Append extension\" was not remembered"];
    if (savedAppend) [ud setObject:savedAppend forKey:kSaveAppendExtKey]; else [ud removeObjectForKey:kSaveAppendExtKey];

    // ---- A session round trip carrying a collapsed fold, a chosen character set and a tab colour ----
    NSURL *cppURL = [tmp URLByAppendingPathComponent:@"folded.cpp"];
    [@"int main()\n{\n    return 0;\n}\nint other()\n{\n    return 1;\n}\n"
        writeToURL:cppURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NPPDocument *cppDoc = [wc openDocumentAtURL:cppURL];
    NPPCharset *charset = [NPPCharset charsetForIANAName:@"windows-1254"] ?: NPPCharset.allCharsets.firstObject;
    NSColor *colour3 = [wc tabColorForIndex:3];
    sptr_t header = -1;
    if (!cppDoc || !charset) {
        [f addObject:@"the self-check could not set up its session fixture (C++ file / character set)"];
    } else {
        ScintillaView *ed = cppDoc.editor;
        [cppDoc reinterpretAsEncoding:NPPEncodingANSI codepage:charset.cfEncoding];   // before folding: it re-reads the text
        NPPSci(ed, SCI_COLOURISE, 0, -1);
        for (sptr_t l = 0, n = NPPSci(ed, SCI_GETLINECOUNT); l < n && header < 0; l++)
            if (NPPSci(ed, SCI_GETFOLDLEVEL, (uptr_t)l) & SC_FOLDLEVELHEADERFLAG) header = l;
        if (header < 0) [f addObject:@"the C++ fixture produced no fold header: folding is not being computed at all"];
        else {
            NPPSci(ed, SCI_FOLDLINE, (uptr_t)header, SC_FOLDACTION_CONTRACT);
            if (NPPSci(ed, SCI_GETFOLDEXPANDED, (uptr_t)header)) [f addObject:@"the fixture's fold refused to collapse"];
        }
        cppDoc.tabColor = colour3;
    }
    // Untitled buffers are skipped, so this session is exactly the one file above — and nothing is parked in the
    // backup folder for the check to clean up afterwards.
    NSXMLDocument *xml = [wc sessionXMLDocumentParkingUntitled:NO];
    NSXMLElement *el = nil;
    for (NSXMLNode *n in [xml nodesForXPath:@"//File" error:NULL])
        if ([[(NSXMLElement *)n attributeForName:@"filename"].stringValue isEqualToString:cppURL.path]) el = (NSXMLElement *)n;
    if (!el) {
        [f addObject:@"the session did not carry the open C++ file"];
    } else {
        NSArray<NSXMLElement *> *folds = [el elementsForName:@"Fold"];
        if (header >= 0 && !folds.count)
            [f addObject:@"the session wrote no <Fold> line: collapsed folds are still being dropped"];
        else if (header >= 0 && [folds.firstObject attributeForName:@"line"].stringValue.integerValue != header)
            [f addObject:[NSString stringWithFormat:@"the session wrote <Fold line=\"%@\">, want line %ld",
                          [folds.firstObject attributeForName:@"line"].stringValue, (long)header]];
        if ([el attributeForName:@"tabColourId"].stringValue.integerValue != 2)
            [f addObject:[NSString stringWithFormat:@"the session wrote tabColourId=\"%@\", want 2 (the third colour)",
                          [el attributeForName:@"tabColourId"].stringValue]];
        if (charset && [el attributeForName:@"encoding"].stringValue.longLongValue != (long long)charset.cfEncoding)
            [f addObject:[NSString stringWithFormat:@"the session wrote encoding=\"%@\", want the chosen code page %lu",
                          [el attributeForName:@"encoding"].stringValue, (unsigned long)charset.cfEncoding]];
    }
    if (cppDoc) {
        [wc removeDocument:cppDoc rememberClosed:NO];
        [wc applySessionXMLDocument:xml];
        NPPDocument *back = nil;
        for (NPPDocument *d in wc.documents) if ([d.fileURL.path isEqualToString:cppURL.path]) back = d;
        if (!back) {
            [f addObject:@"loading the session back did not re-open the file"];
        } else {
            if (header >= 0 && NPPSci(back.editor, SCI_GETFOLDEXPANDED, (uptr_t)header))
                [f addObject:@"the restored session left the collapsed fold expanded"];
            if (![back.tabColor isEqual:colour3]) [f addObject:@"the restored session lost the tab colour"];
            if (charset && (back.encoding != NPPEncodingANSI || back.codepage != charset.cfEncoding))
                [f addObject:@"the restored session lost the hand-picked character set"];
            [wc removeDocument:back rememberClosed:NO];
        }
    }

    // ---- The batch save prompt (N++ doSaveOrNot's "Yes to all" / "No to all") ----
    // The dialog is modal, so the checks answer for it and count how often it was asked.
    __block NPPSaveAnswer answer = NPPSaveAnswerDont;
    __block NSInteger asks = 0;
    __block BOOL offeredAll = NO;
    gSaveAnswerStub = ^NPPSaveAnswer(NPPDocument *doc, BOOL offersAll) { asks++; offeredAll = offersAll; return answer; };

    NSMutableArray<NPPDocument *> * (^dirtyBatch)(NSInteger) = ^(NSInteger n) {
        NSMutableArray<NPPDocument *> *batch = [NSMutableArray array];
        for (NSInteger i = 0; i < n; i++) {
            NPPDocument *d = [wc newDocument];
            NPPSciStr(d.editor, SCI_SETTEXT, 0, "unsaved");   // no savepoint: the buffer is modified
            [batch addObject:d];
        }
        return batch;
    };
    BOOL (^stillOpen)(NPPDocument *) = ^BOOL(NPPDocument *d) { return [wc.documents indexOfObjectIdenticalTo:d] != NSNotFound; };

    NSMutableArray<NPPDocument *> *batch = dirtyBatch(3);
    asks = 0; offeredAll = NO; answer = NPPSaveAnswerDontAll;
    if (![wc closeDocuments:batch]) [f addObject:@"\"Don't Save Any\" cancelled the close instead of finishing it"];
    if (asks != 1)
        [f addObject:[NSString stringWithFormat:@"closing 3 modified files asked %ld times; \"Don't Save Any\" answers the rest",
                      (long)asks]];
    if (!offeredAll) [f addObject:@"three modified files were not offered the \"…to All\" buttons"];
    for (NPPDocument *d in batch) if (stillOpen(d)) { [f addObject:@"\"Don't Save Any\" left a modified file open"]; break; }

    // Cancel stops the whole batch, and nothing may already have been closed behind it (N++ fileCloseAll asks
    // about every dirty buffer before it closes the first).
    batch = dirtyBatch(3);
    asks = 0; answer = NPPSaveAnswerCancel;
    if ([wc closeDocuments:batch]) [f addObject:@"Cancel did not stop the close"];
    for (NPPDocument *d in batch) if (!stillOpen(d)) { [f addObject:@"Cancel still closed a file: the batch is closed before it is agreed"]; break; }
    answer = NPPSaveAnswerDontAll;
    [wc closeDocuments:batch];

    // One dirty file in the batch is not "several": it gets the three plain buttons, and the clean buffer beside
    // it does not count towards the total (nor does it get asked about).
    NPPDocument *clean = [wc newDocument];
    NPPFill(clean, @"saved already");
    NSMutableArray<NPPDocument *> *lone = dirtyBatch(1);
    asks = 0; offeredAll = YES; answer = NPPSaveAnswerDont;
    if (![wc closeDocuments:@[clean, lone.firstObject]]) [f addObject:@"closing one modified file and one clean one was cancelled"];
    if (asks != 1) [f addObject:[NSString stringWithFormat:@"one modified file (beside a clean one) asked %ld times, want 1", (long)asks]];
    if (offeredAll) [f addObject:@"a single modified file was still offered \"Save All\" / \"Don't Save Any\""];

    // "Save All": one question, and every file in the batch is on disk afterwards. Real files — an untitled buffer
    // would answer with a Save As panel, which a headless run cannot dismiss.
    NSMutableArray<NPPDocument *> *onDisk = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        NSURL *u = [tmp URLByAppendingPathComponent:[NSString stringWithFormat:@"batch-%ld.txt", (long)i]];
        [@"before\n" writeToURL:u atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NPPDocument *d = [wc openDocumentAtURL:u];
        if (!d) continue;
        NPPSciStr(d.editor, SCI_INSERTTEXT, 0, "after ");
        [onDisk addObject:d];
    }
    if (onDisk.count != 3) {
        [f addObject:@"the self-check could not open the three files it wrote for the \"Save All\" check"];
    } else {
        asks = 0; answer = NPPSaveAnswerSaveAll;
        if (![wc closeDocuments:onDisk]) [f addObject:@"\"Save All\" cancelled the close"];
        if (asks != 1)
            [f addObject:[NSString stringWithFormat:@"\"Save All\" asked %ld times; it answers for the rest of the batch", (long)asks]];
        for (NSInteger i = 0; i < 3; i++) {
            NSString *body = [NSString stringWithContentsOfURL:[tmp URLByAppendingPathComponent:[NSString stringWithFormat:@"batch-%ld.txt", (long)i]]
                                                      encoding:NSUTF8StringEncoding error:NULL];
            if (![body hasPrefix:@"after "]) { [f addObject:@"\"Save All\" closed a file without writing it"]; break; }
        }
    }

    gSaveAnswerStub = nil;   // never leave the app answering its own prompts
    NPPPreferences.shared.recentFilePaths = savedRecents;
    [fm removeItemAtURL:tmp error:NULL];
}

// The Margins / New Document / Recent Files / Multi-Instance / MISC preferences this window is the consumer of.
// Its own controller: these flip window geometry, the title and the document set, and the one above is left
// mid-session. Every preference touched here is put back — this runs inside the user's own defaults.
+ (void)appendMiscPreferenceFailures:(NSMutableArray<NSString *> *)f {
    NPPEditorWindowController *wc = [[NPPEditorWindowController alloc] init];   // never ordered front
    NPPPreferences *prefs = NPPPreferences.shared;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"npp-window-misc-selfcheck"] isDirectory:YES];
    [fm removeItemAtURL:tmp error:NULL];
    [fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:NULL];
    // Nothing here may ever launch a second copy of the app: force mono-instance for the duration and restore it.
    NPPMultiInstanceMode savedInstance = prefs.multiInstanceMode;
    prefs.multiInstanceMode = NPPMultiInstanceMono;

    // ---- Margins ▸ Border width: the edit view is inset inside its container (N++ DocTabView::reSizeTo) ----
    NSInteger savedBorder = prefs.borderWidth;
    BOOL savedEdge = prefs.showBorderEdge;
    prefs.borderWidth = 0;
    [wc layoutContent];
    NSRect full = wc.currentDocument.editor.frame;   // only the *current* editor of a view is ever re-framed
    if (NSWidth(full) <= 20 || NSHeight(full) <= 20) {
        [f addObject:[NSString stringWithFormat:@"the edit view is %@: the border checks would prove nothing",
                      NSStringFromRect(full)]];
    } else {
        prefs.borderWidth = 6;
        [wc layoutContent];
        NSRect want = NSInsetRect(full, 6, 6);
        if (!NSEqualRects(wc.currentDocument.editor.frame, want))
            [f addObject:[NSString stringWithFormat:@"a 6 px border width left the edit view at %@, want %@",
                          NSStringFromRect(wc.currentDocument.editor.frame), NSStringFromRect(want)]];
        // -selectDocument: frames the editor it brings on screen, so it has to use the same inset.
        NPPDocument *second = [wc newDocument];
        if (!NSEqualRects(second.editor.frame, want))
            [f addObject:[NSString stringWithFormat:@"a newly selected document ignored the border width: %@, want %@",
                          NSStringFromRect(second.editor.frame), NSStringFromRect(want)]];
        prefs.borderWidth = 0;
        [wc layoutContent];
        if (!NSEqualRects(wc.currentDocument.editor.frame, full))
            [f addObject:@"a zero border width did not give the whole area back to the edit view"];
    }
    // "No edge" is the inverse of the preference, and the frame is drawn on the container the inset above leaves.
    // Driven at a 0 px border width on purpose: that is the setting where an edge the edit view covers would be a
    // checkbox that changes nothing on screen.
    prefs.borderWidth = 0;
    prefs.showBorderEdge = YES;
    [wc layoutContent];
    NSView *edgeHost = wc->_containers[kMainView];
    if (edgeHost.layer.borderWidth <= 0) [f addObject:@"the border edge is on but nothing is drawn around the edit view"];
    if (!edgeHost.layer.borderColor) [f addObject:@"the border edge is drawn in no colour at all"];
    if (NSWidth(edgeHost.bounds) > 20 && NSHeight(edgeHost.bounds) > 20 &&
        !NSContainsRect(NSInsetRect(edgeHost.bounds, edgeHost.layer.borderWidth, edgeHost.layer.borderWidth),
                        wc.currentDocument.editor.frame))
        [f addObject:[NSString stringWithFormat:@"the edit view (%@) covers the border edge drawn on its container (%@): "
                      @"\"No edge\" would do nothing at a 0 px border width",
                      NSStringFromRect(wc.currentDocument.editor.frame), NSStringFromRect(edgeHost.bounds)]];
    prefs.showBorderEdge = NO;
    [wc layoutContent];
    if (edgeHost.layer.borderWidth != 0) [f addObject:@"\"No edge\" left the border around the edit view"];
    prefs.borderWidth = savedBorder;
    prefs.showBorderEdge = savedEdge;

    // ---- Distraction Free padding: width / divider, and the plain Margins padding back when it is off ----
    NSInteger savedDiv = prefs.distractionFreeDivPart, savedPadL = prefs.paddingLeft, savedPadR = prefs.paddingRight;
    ScintillaView *dfEd = wc.currentDocument.editor;   // the padding is a fraction of the *current* view's width
    prefs.paddingLeft = 3;
    prefs.paddingRight = 4;
    wc->_distractionFree = YES;   // the mode itself toggles full screen, which a window that was never shown cannot
    prefs.distractionFreeDivPart = 4;
    [wc applyDistractionFreePadding];
    sptr_t wide = NPPSci(dfEd, SCI_GETMARGINLEFT);
    CGFloat dfWidth = NSWidth(dfEd.frame);
    if (labs((long)wide - (long)(dfWidth / 4)) > 1)
        [f addObject:[NSString stringWithFormat:@"Distraction Free padding is %ld px, want a quarter of the %g pt edit view",
                      (long)wide, dfWidth]];
    prefs.distractionFreeDivPart = 9;
    [wc applyDistractionFreePadding];
    sptr_t narrow = NPPSci(dfEd, SCI_GETMARGINLEFT);
    if (narrow <= 0 || narrow >= wide)
        [f addObject:[NSString stringWithFormat:@"9 parts gave %ld px of padding, 4 parts gave %ld: the divider is not read",
                      (long)narrow, (long)wide]];
    // A buffer opened while the mode is on has to come up padded too. NPPPreferences configures a never-seen
    // editor from the current-document notification -reloadTabs posts, and that pass writes the plain Margins
    // padding — so this fails unless -reloadTabs puts the Distraction Free padding back over it.
    prefs.distractionFreeDivPart = 4;
    NPPDocument *born = [wc newDocument];
    sptr_t bornPad = NPPSci(born.editor, SCI_GETMARGINLEFT);
    if (bornPad <= MAX(prefs.paddingLeft, prefs.paddingRight))
        [f addObject:[NSString stringWithFormat:@"a document opened in Distraction Free mode has %ld px of padding: "
                      @"it came up on the plain Margins padding", (long)bornPad]];
    wc->_distractionFree = NO;
    [wc applyDistractionFreePadding];
    if (NPPSci(dfEd, SCI_GETMARGINLEFT) != 3 || NPPSci(dfEd, SCI_GETMARGINRIGHT) != 4)
        [f addObject:@"leaving Distraction Free did not put the Margins ▸ padding back"];
    prefs.distractionFreeDivPart = savedDiv;
    prefs.paddingLeft = savedPadL;
    prefs.paddingRight = savedPadR;

    // ---- MISC ▸ "Show only the file name in the title bar" (N++ _shortTitlebar) ----
    BOOL savedShort = prefs.shortTitleBar;
    NPPDocument *titled = wc.currentDocument;
    titled.fileURL = [NSURL fileURLWithPath:@"/npp-selfcheck/titlebar/deep.txt"];
    prefs.shortTitleBar = NO;
    [wc updateWindowTitle];
    if ([wc.window.title rangeOfString:@"/npp-selfcheck/titlebar/deep.txt"].location == NSNotFound)
        [f addObject:[NSString stringWithFormat:@"the title bar shows \"%@\", want the full path", wc.window.title]];
    prefs.shortTitleBar = YES;
    [wc updateWindowTitle];
    if ([wc.window.title rangeOfString:@"/npp-selfcheck/titlebar"].location != NSNotFound ||
        [wc.window.title rangeOfString:@"deep.txt"].location == NSNotFound)
        [f addObject:[NSString stringWithFormat:@"the short title bar shows \"%@\", want the file name alone", wc.window.title]];
    prefs.shortTitleBar = savedShort;

    // ---- MISC ▸ the Save All confirmation (N++ fileSaveAll / DoSaveAllBox) ----
    BOOL savedConfirm = prefs.saveAllConfirm;
    prefs.saveAllConfirm = YES;
    if ([wc saveAllNeedsConfirmation]) [f addObject:@"Save All asks to confirm with nothing modified"];
    NPPDocument *dirtyOne = wc.currentDocument;
    NPPSciStr(dirtyOne.editor, SCI_INSERTTEXT, 0, "modified");
    if ([wc saveAllNeedsConfirmation])
        [f addObject:@"Save All asked about the current document, the only modified one: N++ just saves it"];
    NPPDocument *dirtyTwo = [wc newDocument];
    NPPSciStr(dirtyTwo.editor, SCI_INSERTTEXT, 0, "modified");
    if (![wc saveAllNeedsConfirmation]) [f addObject:@"Save All did not ask about two modified documents"];
    prefs.saveAllConfirm = NO;
    if ([wc saveAllNeedsConfirmation]) [f addObject:@"the Save All confirmation is switched off but it still asks"];
    prefs.saveAllConfirm = savedConfirm;
    NPPSci(dirtyOne.editor, SCI_SETSAVEPOINT);   // clean again: a dirty buffer would put a modal prompt up later
    NPPSci(dirtyTwo.editor, SCI_SETSAVEPOINT);

    // ---- MISC ▸ "Mute all sounds": an unhandled command is what makes the window beep ----
    BOOL savedMute = prefs.muteAllSounds;
    NSMenuItem *unknown = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
    unknown.tag = -1;   // below every command range: -nppCommand: falls all the way through to the beep
    prefs.muteAllSounds = YES;
    NSUInteger beeps = gBeepCount;
    [wc nppCommand:unknown];
    if (gBeepCount != beeps) [f addObject:@"\"Mute all sounds\" is on and the window beeped anyway"];
    prefs.muteAllSounds = NO;
    [wc nppCommand:unknown];
    if (gBeepCount == beeps) [f addObject:@"an unhandled command did not beep at all, so the mute check proves nothing"];
    prefs.muteAllSounds = savedMute;

    // ---- MISC ▸ session / workspace file extensions (N++ isFileSession / isFileWorkspace) ----
    if (!NPPPathHasUserExtension(@"/a/b.sess", @"sess")) [f addObject:@"the session extension does not match its own name"];
    if (!NPPPathHasUserExtension(@"/a/b.SESS", @".sess")) [f addObject:@"the session extension is case sensitive, or the leading dot is not stripped"];
    if (NPPPathHasUserExtension(@"/a/b.session", @"sess")) [f addObject:@"\"sess\" matched a \".session\" file"];
    if (NPPPathHasUserExtension(@"/a/b.sess", @"")) [f addObject:@"an unset extension matched a file anyway"];

    // Opening a file with that extension loads it as a session instead of as text.
    // ponytail: the workspace half shares this matcher and dispatch but is not driven here — it would build the
    // real Project Panel singleton inside a headless run. Drive it from the panel's own checks if that changes.
    NSArray<NSString *> *savedRecents = prefs.recentFilePaths;
    NSString *savedSessionExt = prefs.sessionFileExtension;
    NSURL *member = [tmp URLByAppendingPathComponent:@"member.txt"];
    [@"in the session\n" writeToURL:member atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSURL *sessionFile = [tmp URLByAppendingPathComponent:@"work.nppsess"];
    NSString *sessionXML = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<NotepadPlus><Session activeView=\"0\">"
         "<mainView activeIndex=\"0\"><File filename=\"%@\"/></mainView><subView activeIndex=\"0\"/></Session></NotepadPlus>",
        member.path];
    [sessionXML writeToURL:sessionFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    prefs.sessionFileExtension = @"nppsess";
    NPPDocument *asText = [wc openDocumentAtURL:sessionFile];
    if (asText) [f addObject:@"a file with the session extension was opened as a text buffer"];
    BOOL loaded = NO;
    for (NPPDocument *d in wc.documents) if ([d.fileURL.path isEqualToString:member.path]) loaded = YES;
    if (!loaded) [f addObject:@"the session extension was recognised but the session's own file was not opened"];
    prefs.sessionFileExtension = savedSessionExt;

    // ---- "<file> doesn't exist. Create it?" (N++ CreateNewFileOrNot), which branch each path takes ----
    if ([wc actionForMissingFileAtURL:member] != NPPMissingFileNone)
        [f addObject:@"an existing file was treated as missing"];
    if ([wc actionForMissingFileAtURL:[tmp URLByAppendingPathComponent:@"not-there.txt"]] != NPPMissingFileOfferCreate)
        [f addObject:@"a missing file in an existing folder was not offered for creation"];
    if ([wc actionForMissingFileAtURL:[tmp URLByAppendingPathComponent:@"no/such/folder/x.txt"]] != NPPMissingFileNoFolder)
        [f addObject:@"a file whose folder is missing was offered for creation anyway"];

    // ---- Recent Files History ▸ "Check that the files still exist at launch time" ----
    BOOL savedCheck = prefs.checkRecentFilesAtLaunch;
    NSString *gone = [tmp URLByAppendingPathComponent:@"vanished.txt"].path;
    prefs.recentFilePaths = @[member.path, gone];
    prefs.checkRecentFilesAtLaunch = NO;
    [NPPEditorWindowController pruneRecentFilesAtLaunch];
    if (prefs.recentFilePaths.count != 2) [f addObject:@"the launch check is off, but the recent files list was pruned"];
    prefs.checkRecentFilesAtLaunch = YES;
    [NPPEditorWindowController pruneRecentFilesAtLaunch];
    if (![prefs.recentFilePaths isEqualToArray:@[member.path]])
        [f addObject:[NSString stringWithFormat:@"the launch check left %@, want only the file that still exists",
                      prefs.recentFilePaths]];
    prefs.checkRecentFilesAtLaunch = savedCheck;
    prefs.recentFilePaths = savedRecents;

    // ---- Multi-Instance: which Load Session goes to a second copy of the app ----
    prefs.multiInstanceMode = NPPMultiInstanceMono;
    if ([wc loadSessionShouldOpenNewInstance]) [f addObject:@"mono-instance still sent the session to a second copy"];
    prefs.multiInstanceMode = NPPMultiInstanceAlways;
    if (![wc loadSessionShouldOpenNewInstance]) [f addObject:@"\"always multi-instance\" loaded the session over the open documents"];
    prefs.multiInstanceMode = NPPMultiInstanceSessionInNewInstance;
    if (![wc loadSessionShouldOpenNewInstance]) [f addObject:@"\"session in a new instance\" loaded the session in this one"];
    // …except into an untouched window, which has nothing to protect (N++ isEmptyNpp).
    NPPEditorWindowController *emptyOne = [[NPPEditorWindowController alloc] init];
    if ([emptyOne loadSessionShouldOpenNewInstance])
        [f addObject:@"a window holding only an untouched new buffer opened a second copy for the session"];
    prefs.multiInstanceMode = savedInstance;

    [self appendPanelStateAndStartupFailures:f];
    [fm removeItemAtURL:tmp error:NULL];
}

// The "Panel State and [-nosession]" checkboxes and the extra startup document, both of which need their own
// controllers (the startup one is a once-per-window latch).
+ (void)appendPanelStateAndStartupFailures:(NSMutableArray<NSString *> *)f {
    NPPPreferences *prefs = NPPPreferences.shared;
    // One checkbox per panel command; project panels 2 and 3 follow panel 1's, exactly as upstream reads them.
    NSDictionary<NSNumber *, NSString *> *panels = @{
        @(NPPCmdViewWorkspacePanel):   @"fileBrowserPanelKeepState",
        @(NPPCmdViewDocumentMap):      @"docMapPanelKeepState",
        @(NPPCmdViewFunctionList):     @"funcListPanelKeepState",
        @(NPPCmdViewDocumentList):     @"docListPanelKeepState",
        @(NPPCmdViewClipboardHistory): @"clipboardHistoryPanelKeepState",
        @(NPPCmdViewCharacterPanel):   @"charPanelKeepState",
        @(NPPCmdViewProjectPanel1):    @"projectPanelKeepState",
    };
    NSMutableDictionary<NSString *, NSNumber *> *savedPanels = [NSMutableDictionary dictionary];
    for (NSString *key in panels.allValues) {
        savedPanels[key] = [prefs valueForKey:key];
        [prefs setValue:@NO forKey:key];
    }
    for (NSNumber *cmd in panels)
        if ([self panelCommandKeepsStateWithoutSession:(NPPCmd)cmd.integerValue])
            [f addObject:[NSString stringWithFormat:@"%@ is off, but its panel still survives -nosession", panels[cmd]]];
    for (NSNumber *cmd in panels) {
        [prefs setValue:@YES forKey:panels[cmd]];
        if (![self panelCommandKeepsStateWithoutSession:(NPPCmd)cmd.integerValue])
            [f addObject:[NSString stringWithFormat:@"%@ is on, but its panel is not restored under -nosession", panels[cmd]]];
        for (NSNumber *other in panels)   // a copy-pasted case in the switch would light two panels at once
            if (![other isEqualToNumber:cmd] && [self panelCommandKeepsStateWithoutSession:(NPPCmd)other.integerValue])
                [f addObject:[NSString stringWithFormat:@"%@ also restores the panel of %@", panels[cmd], panels[other]]];
        [prefs setValue:@NO forKey:panels[cmd]];
    }
    prefs.projectPanelKeepState = YES;
    if (![self panelCommandKeepsStateWithoutSession:NPPCmdViewProjectPanel2] ||
        ![self panelCommandKeepsStateWithoutSession:NPPCmdViewProjectPanel3])
        [f addObject:@"the project panel checkbox covers panel 1 only, not all three"];
    for (NSString *key in savedPanels) [prefs setValue:savedPanels[key] forKey:key];

    // ---- New Document ▸ "Always open a new document in addition at startup" ----
    BOOL savedAdd = prefs.addNewDocumentOnStartup, savedRemember = prefs.rememberLastSession;
    prefs.addNewDocumentOnStartup = YES;
    prefs.rememberLastSession = YES;
    NPPEditorWindowController *starter = [[NPPEditorWindowController alloc] init];
    NSUInteger before = starter.documents.count;
    [starter addStartupDocumentIfPreferred];
    if (starter.documents.count != before + 1)
        [f addObject:@"\"open a new document in addition at startup\" did not add one"];
    [starter addStartupDocumentIfPreferred];   // the app delegate may call it too: once per launch, not once per call
    if (starter.documents.count != before + 1)
        [f addObject:@"the extra startup document was added twice"];
    prefs.addNewDocumentOnStartup = NO;
    NPPEditorWindowController *plain = [[NPPEditorWindowController alloc] init];
    NSUInteger plainCount = plain.documents.count;
    [plain addStartupDocumentIfPreferred];
    if (plain.documents.count != plainCount)
        [f addObject:@"a document was added at startup with the preference off"];
    prefs.addNewDocumentOnStartup = savedAdd;
    prefs.rememberLastSession = savedRemember;
}

// Window ▸ Sort By, the split rotation and the ⌃Tab switcher, driven on the controller the checks above left behind.
+ (void)appendSortRotateAndSwitcherFailures:(NSMutableArray<NSString *> *)f controller:(NPPEditorWindowController *)wc {
    // Names, paths, languages and lengths all disagree on purpose, so a sort that reads the wrong key cannot pass.
    // The files need not exist: every key but the modification date comes out of the buffer.
    NPPDocument *s1 = [wc newDocument], *s2 = [wc newDocument], *s3 = [wc newDocument];
    s1.fileURL = [NSURL fileURLWithPath:@"/npp-selfcheck/c/alpha.cpp"];
    s2.fileURL = [NSURL fileURLWithPath:@"/npp-selfcheck/a/zebra.py"];
    s3.fileURL = [NSURL fileURLWithPath:@"/npp-selfcheck/b/middle.txt"];
    NPPFill(s1, [@"" stringByPaddingToLength:10 withString:@"x" startingAtIndex:0]);
    NPPFill(s2, [@"" stringByPaddingToLength:30 withString:@"x" startingAtIndex:0]);
    NPPFill(s3, [@"" stringByPaddingToLength:20 withString:@"x" startingAtIndex:0]);
    NSInteger (^orderOf)(NPPDocument *) = ^NSInteger(NPPDocument *d) {
        return (NSInteger)[wc.documents indexOfObjectIdenticalTo:d];
    };
    void (^expect)(NSString *, NPPDocument *, NPPDocument *, NPPDocument *) =
        ^(NSString *what, NPPDocument *a, NPPDocument *b, NPPDocument *c) {
        if (orderOf(a) < orderOf(b) && orderOf(b) < orderOf(c)) return;
        [f addObject:[NSString stringWithFormat:@"%@ put the tabs in the order %ld/%ld/%ld", what,
                      (long)orderOf(a), (long)orderOf(b), (long)orderOf(c)]];
    };

    NPPDocument *before = wc.currentDocument;
    if (!NPPRunCmd(wc, NPPCmdWindowSortNameAsc, f)) return;
    expect(@"Sort by name A-Z", s1, s3, s2);          // alpha, middle, zebra
    if (wc.currentDocument != before) [f addObject:@"sorting the tabs moved the selection off the current document"];
    NPPRunCmd(wc, NPPCmdWindowSortNameDesc, f);
    expect(@"Sort by name Z-A", s2, s3, s1);
    NPPRunCmd(wc, NPPCmdWindowSortPathAsc, f);
    expect(@"Sort by path A-Z", s2, s3, s1);          // a/…, b/…, c/… — the opposite of the name order
    NPPRunCmd(wc, NPPCmdWindowSortSizeAsc, f);
    expect(@"Sort by content length ascending", s1, s3, s2);   // 10, 20, 30
    NPPRunCmd(wc, NPPCmdWindowSortSizeDesc, f);
    expect(@"Sort by content length descending", s2, s3, s1);
    NPPLanguage *cpp = [NPPLanguageManager.shared languageNamed:@"cpp"], *xml = [NPPLanguageManager.shared languageNamed:@"xml"];
    if (cpp && xml) {   // "cpp" sorts before "xml", and neither is the extension of the file it is put on
        s1.language = xml;
        s2.language = cpp;
        NPPRunCmd(wc, NPPCmdWindowSortTypeAsc, f);
        if (orderOf(s2) > orderOf(s1)) [f addObject:@"Sort by type went by extension, not by language name"];
    }
    NSUInteger docsBeforeDateSort = wc.documents.count;
    NPPRunCmd(wc, NPPCmdWindowSortDateAsc, f);   // no timestamps here: falls back to the path order, must not lose tabs
    if (wc.documents.count != docsBeforeDateSort) [f addObject:@"Sort by modified time lost documents"];

    // ---- Rotate: the split flips between side by side and stacked, and the two directions differ ----
    if (NPPCmdEnabled(wc, NPPCmdViewRotateRight)) [f addObject:@"Rotate is offered without a second view"];
    NPPRunCmd(wc, NPPCmdViewMoveToOtherView, f);
    BOOL wasVertical = wc.panelHost.splitVertical;
    NSView *halfBefore = wc.tabBar.superview;
    if (!NPPRunCmd(wc, NPPCmdViewRotateRight, f)) return;
    if (wc.panelHost.splitVertical == wasVertical) [f addObject:@"Rotate to Right did not flip the split orientation"];
    NPPRunCmd(wc, NPPCmdViewRotateRight, f);
    if (wc.panelHost.splitVertical != wasVertical) [f addObject:@"rotating twice did not come back to the original orientation"];
    if (wc.tabBar.superview == halfBefore)
        [f addObject:@"rotating twice to the right did not swap the two halves (Rotate Left and Right are the same command)"];
    NPPRunCmd(wc, NPPCmdViewRotateLeft, f);
    NPPRunCmd(wc, NPPCmdViewRotateLeft, f);
    if (wc.panelHost.splitVertical != wasVertical || wc.tabBar.superview != halfBefore)
        [f addObject:@"Rotate Left did not undo Rotate Right"];

    // ---- ⌃Tab: MRU order, cycling on repeated presses, committing on release ----
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    id savedSwitcher = [ud objectForKey:kDocSwitcherKey];
    [ud setBool:YES forKey:kDocSwitcherKey];
    [wc selectDocument:s1];
    [wc selectDocument:s2];
    [wc selectDocument:s3];                       // MRU now s3, s2, s1, …
    [wc cycleDocumentSwitcherBackward:NO];
    [wc commitDocumentSwitcher];
    if (wc.currentDocument != s2) [f addObject:@"⌃Tab did not land on the previously used document"];
    [wc selectDocument:s3];                       // MRU s3, s2, s1, …
    [wc cycleDocumentSwitcherBackward:NO];
    [wc cycleDocumentSwitcherBackward:NO];        // held down: two presses walk two documents back
    [wc commitDocumentSwitcher];
    if (wc.currentDocument != s1) [f addObject:@"a second ⌃Tab press did not move further down the MRU list"];
    [wc selectDocument:s3];
    [wc cycleDocumentSwitcherBackward:YES];       // ⌃⇧Tab from the top wraps to the least recently used
    [wc commitDocumentSwitcher];
    if (wc.currentDocument == s3 || wc.currentDocument == s2)
        [f addObject:@"⌃⇧Tab did not step backwards through the MRU list"];
    // MRU behaviour (N++ _styleMRU / IDC_CHECK_STYLEMRU): on, ⌃Tab goes to the last used document; off, to the
    // next tab. The two orders are made to disagree first — the tab *before* the current one is touched last — so
    // neither answer can pass for the other.
    id savedMRU = [ud objectForKey:kDocSwitcherMRUKey];
    NSArray<NPPDocument *> *tabs = wc.documents;
    NSInteger tn = (NSInteger)tabs.count;
    NSUInteger ci = [tabs indexOfObjectIdenticalTo:wc.currentDocument];
    if (tn < 3 || ci == NSNotFound) {
        [f addObject:@"the MRU check has too few documents to tell tab order from MRU order"];
    } else {
        NPPDocument *cur = tabs[ci];
        NPPDocument *tabNext = tabs[(NSUInteger)(((NSInteger)ci + 1) % tn)];
        NPPDocument *tabPrev = tabs[(NSUInteger)(((NSInteger)ci + tn - 1) % tn)];
        for (NSNumber *mru in @[@YES, @NO]) {
            [wc selectDocument:tabPrev];
            [wc selectDocument:cur];              // MRU: cur, tabPrev, …   tab order: … tabPrev, cur, tabNext …
            [ud setBool:mru.boolValue forKey:kDocSwitcherMRUKey];
            [wc cycleDocumentSwitcherBackward:NO];
            [wc commitDocumentSwitcher];
            NPPDocument *want = mru.boolValue ? tabPrev : tabNext;
            if (wc.currentDocument != want)
                [f addObject:[NSString stringWithFormat:@"⌃Tab with MRU behaviour %@ landed on \"%@\", want \"%@\"",
                              mru.boolValue ? @"on" : @"off", wc.currentDocument.displayName, want.displayName]];
        }
    }
    if (savedMRU) [ud setObject:savedMRU forKey:kDocSwitcherMRUKey]; else [ud removeObjectForKey:kDocSwitcherMRUKey];

    [ud setBool:NO forKey:kDocSwitcherKey];       // preference off: plain next/previous tab, no HUD
    [wc selectDocument:s1];                       // s1's view still holds several tabs, so "next" has somewhere to go
    if ([wc cycleDocumentSwitcherBackward:NO], wc.currentDocument == s1)
        [f addObject:@"with the document switcher off, ⌃Tab did not move to the next tab"];
    if (savedSwitcher) [ud setObject:savedSwitcher forKey:kDocSwitcherKey]; else [ud removeObjectForKey:kDocSwitcherKey];
}

// Dragging a tab out of its strip (N++ TCN_TABDROPPEDOUTSIDE): the three places it can land, and the transfer one
// of them really performs. Its own controller — the transfer collapses the split, which the checks around the
// shared one lean on.
+ (void)appendTabDropOutFailures:(NSMutableArray<NSString *> *)f {
    NPPEditorWindowController *wc = [[NPPEditorWindowController alloc] init];   // never ordered front
    NPPDocument *a = wc.currentDocument, *b = [wc newDocument];
    if (!a || !b) { [f addObject:@"the tab drop check could not open two documents"]; return; }
    NPPRunCmd(wc, NPPCmdViewMoveToOtherView, f);   // b crosses over, so there is a second strip to drop onto
    // The user may have the strips hidden; this check needs both of them on screen to have somewhere to drop.
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    id savedHide = [ud objectForKey:@"NPPTabBarHidden"];
    void (^restoreHide)(void) = ^{
        if (savedHide) [ud setObject:savedHide forKey:@"NPPTabBarHidden"]; else [ud removeObjectForKey:@"NPPTabBarHidden"];
    };
    [ud setBool:NO forKey:@"NPPTabBarHidden"];
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:ud];
    [wc layoutContent];
    NPPTabBarView *mainBar = wc->_tabBars[kMainView], *subBar = wc->_tabBars[kSubView];
    NSRect mainRect = [wc screenFrameOfView:mainBar], subRect = [wc screenFrameOfView:subBar];
    if (!wc.panelHost.splitEnabled || NSIsEmptyRect(mainRect) || NSIsEmptyRect(subRect) || NSIntersectsRect(mainRect, subRect)) {
        [f addObject:[NSString stringWithFormat:@"the tab drop check has no two separate strips: %@ / %@",
                      NSStringFromRect(mainRect), NSStringFromRect(subRect)]];
        restoreHide();
        return;
    }
    NSPoint onOther = NSMakePoint(NSMidX(subRect), NSMidY(subRect));
    NSPoint onSelf = NSMakePoint(NSMidX(mainRect), NSMidY(mainRect));
    NSPoint away = NSMakePoint(NSMaxX(wc.window.frame) + 500, NSMaxY(wc.window.frame) + 500);
    if ([wc dropTargetForScreenPoint:onOther fromView:kMainView] != NPPTabDropOtherView)
        [f addObject:@"a tab dropped on the other view's strip was not read as a transfer"];
    if ([wc dropTargetForScreenPoint:onSelf fromView:kMainView] != NPPTabDropSameWindow)
        [f addObject:@"a tab dropped back inside the window did not ask for the Move / Clone menu"];
    if ([wc dropTargetForScreenPoint:away fromView:kMainView] != NPPTabDropOutside)
        [f addObject:@"a tab dropped clear of the window was not read as a new instance"];

    // Both entries of that menu have to be live commands, not labels: they go through -nppCommand: like every
    // other menu item, so -validateMenuItem: can grey the wrong one out.
    NSMenu *menu = [wc tabDropMenu];
    if (menu.numberOfItems != 2) {
        [f addObject:[NSString stringWithFormat:@"the tab drop menu has %ld items, want Move and Clone", (long)menu.numberOfItems]];
    } else {
        NSMenuItem *move = [menu itemAtIndex:0], *clone = [menu itemAtIndex:1];
        if (move.tag != NPPCmdViewMoveToOtherView || clone.tag != NPPCmdViewCloneToOtherView ||
            move.action != @selector(nppCommand:) || move.target != wc)
            [f addObject:@"the tab drop menu does not dispatch Move / Clone to Other View"];
    }

    // ...and the gesture itself, through the very call the strip makes: "a" is the main view's only tab.
    [wc selectDocument:a];
    [wc tabBar:mainBar didDropTabAtIndex:0 outsideAtScreenPoint:onOther];
    if (wc.documents.count != 2 || [wc viewOfDocument:a] != kSubView)
        [f addObject:@"dropping a tab on the other view's strip did not move that buffer there"];
    // An untitled buffer cannot be handed to a new instance (it has no file on disk): the drop has to say so
    // rather than look like it worked, and above all must not lose the document.
    [wc tabBar:wc->_tabBars[kSubView] didDropTabAtIndex:0 outsideAtScreenPoint:away];
    if (wc.documents.count != 2) [f addObject:@"dropping an unsaved tab off the window lost it"];
    restoreHide();
}

// The three preferences the window has to honour, the folder drop and a session round trip.
+ (void)appendPreferenceAndSessionFailures:(NSMutableArray<NSString *> *)f controller:(NPPEditorWindowController *)wc {
    NPPPreferences *prefs = NPPPreferences.shared;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"npp-window-selfcheck"] isDirectory:YES];
    [fm removeItemAtURL:tmp error:NULL];
    [fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:NULL];

    // ---- Default Directory: what the Open / Save panels start on (N++ OpenSaveDirSetting) ----
    NSInteger savedMode = prefs.defaultDirectoryMode;
    NSString *savedDir = prefs.defaultDirectoryPath;
    NPPDocument *filed = [wc newDocument];
    // The File commands that need a path. A command we cannot perform has to be *disabled*, never a live menu item
    // that quietly does nothing — and the two folder-as-workspace predicates (validation and the command itself)
    // have to be the same one, or the item goes live on a build with no workspace panel.
    if (NPPCmdEnabled(wc, NPPCmdFileOpenInTerminal)) [f addObject:@"Open in Terminal is offered for an untitled buffer"];
    if (NPPCmdEnabled(wc, NPPCmdFileContainingFolderAsWorkspace))
        [f addObject:@"Containing Folder as Workspace is offered for an untitled buffer"];
    if (!NPPCmdEnabled(wc, NPPCmdFilePrintNow)) [f addObject:@"Print Now is disabled with a document open"];
    filed.fileURL = [NSURL fileURLWithPath:@"/npp-selfcheck/dir/file.txt"];
    if (NPPTerminalApplicationURL() && !NPPCmdEnabled(wc, NPPCmdFileOpenInTerminal))
        [f addObject:@"Open in Terminal stayed disabled for a buffer with a path"];
    if (NPPWorkspacePanelTakesFolders() && !NPPCmdEnabled(wc, NPPCmdFileContainingFolderAsWorkspace))
        [f addObject:@"Containing Folder as Workspace stayed disabled for a buffer with a path"];
    prefs.defaultDirectoryMode = 0;
    if (![[wc defaultPanelDirectoryForDocument:filed].path isEqualToString:@"/npp-selfcheck/dir"])
        [f addObject:[NSString stringWithFormat:@"Default Directory \"follow current document\" gave %@",
                      [wc defaultPanelDirectoryForDocument:filed].path]];
    prefs.defaultDirectoryMode = 2;
    prefs.defaultDirectoryPath = tmp.path;
    NSString *fixed = [wc defaultPanelDirectoryForDocument:filed].path.stringByStandardizingPath;
    if (![fixed isEqualToString:tmp.path.stringByStandardizingPath])
        [f addObject:[NSString stringWithFormat:@"Default Directory \"fixed folder\" gave %@, want %@", fixed, tmp.path]];
    prefs.defaultDirectoryPath = @"/npp-selfcheck/does-not-exist";
    if (![[wc defaultPanelDirectoryForDocument:filed].path isEqualToString:@"/npp-selfcheck/dir"])
        [f addObject:@"a fixed default directory that is gone did not fall back to the document's own folder"];
    prefs.defaultDirectoryMode = savedMode;
    prefs.defaultDirectoryPath = savedDir;

    // ---- File status auto-detection: the silent variants reload without a prompt, and never over unsaved work ----
    NSURL *watched = [tmp URLByAppendingPathComponent:@"watched.txt"];
    [@"first\n" writeToURL:watched atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSArray<NSString *> *savedRecents = prefs.recentFilePaths;   // opening files here must not rewrite the user's list
    NPPFileAutoDetection savedDetection = prefs.fileAutoDetection;
    NPPDocument *onDisk = [wc openDocumentAtURL:watched];
    if (!onDisk) {
        [f addObject:@"the self-check could not open its own temporary file"];
    } else {
        [@"second line\n" writeToURL:watched atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        prefs.fileAutoDetection = NPPFileAutoDetectionEnabled;
        if ([wc reloadDocumentSilentlyIfPreferred:onDisk])
            [f addObject:@"\"Update silently\" is off, but the file was reloaded without asking"];
        prefs.fileAutoDetection = NPPFileAutoDetectionSilent;
        if (![wc reloadDocumentSilentlyIfPreferred:onDisk]) [f addObject:@"\"Update silently\" did not reload the changed file"];
        else if (NPPSci(onDisk.editor, SCI_GETLENGTH) != (sptr_t)strlen("second line\n"))
            [f addObject:@"the silent reload did not pick up the new contents"];
        NPPSciStr(onDisk.editor, SCI_INSERTTEXT, 0, "unsaved edit");   // dirty: N++ asks even in silent mode
        if ([wc reloadDocumentSilentlyIfPreferred:onDisk])
            [f addObject:@"a silent reload threw away unsaved changes instead of asking"];
        NPPSci(onDisk.editor, SCI_SETSAVEPOINT);
    }
    prefs.fileAutoDetection = savedDetection;

    // ---- Dropping a folder, with "open all files of folder" on (the workspace branch would touch real settings) ----
    NSURL *subdir = [tmp URLByAppendingPathComponent:@"sub" isDirectory:YES];
    [fm createDirectoryAtURL:subdir withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"x\n" writeToURL:[tmp URLByAppendingPathComponent:@"drop-a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"x\n" writeToURL:[tmp URLByAppendingPathComponent:@"drop-b.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"x\n" writeToURL:[subdir URLByAppendingPathComponent:@"drop-c.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    // Sort by modified time (below) needs two timestamps that say the opposite of what the paths say, or the path
    // tiebreak alone would carry the check. The date is read when the file is opened, so it is set before the drop.
    [fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400]}
         ofItemAtPath:[tmp URLByAppendingPathComponent:@"drop-b.txt"].path error:NULL];
    id savedDropPref = [ud objectForKey:kFolderDropOpenKey];
    [ud setBool:YES forKey:kFolderDropOpenKey];
    [wc openDocumentsAtURLs:@[tmp]];               // the folder itself, exactly as a drop delivers it
    NSUInteger dropped = 0;
    for (NPPDocument *d in wc.documents) if ([d.fileURL.lastPathComponent hasPrefix:@"drop-"]) dropped++;
    if (dropped != 3)                              // the two at the top and the one in the sub folder
        [f addObject:[NSString stringWithFormat:@"dropping a folder opened %lu of its 3 files (sub folders included)",
                      (unsigned long)dropped]];
    if (savedDropPref) [ud setObject:savedDropPref forKey:kFolderDropOpenKey]; else [ud removeObjectForKey:kFolderDropOpenKey];

    // ---- Sort by modified time, on the only two buffers here whose dates are real and disagree with their paths ----
    NPPDocument *newer = nil, *older = nil;
    for (NPPDocument *d in wc.documents) {
        if ([d.fileURL.lastPathComponent isEqualToString:@"drop-a.txt"]) newer = d;   // written now, sorts first by path
        if ([d.fileURL.lastPathComponent isEqualToString:@"drop-b.txt"]) older = d;   // back-dated a day
    }
    if (!newer || !older) {
        [f addObject:@"the self-check lost the two files it dated for the Sort by modified time check"];
    } else {
        NSInteger (^pos)(NPPDocument *) = ^NSInteger(NPPDocument *d) { return (NSInteger)[wc.documents indexOfObjectIdenticalTo:d]; };
        NPPRunCmd(wc, NPPCmdWindowSortDateAsc, f);
        if (pos(older) > pos(newer))
            [f addObject:@"Sort by modified time ascending kept the path order: it is not reading the timestamps"];
        NPPRunCmd(wc, NPPCmdWindowSortDateDesc, f);
        if (pos(newer) > pos(older)) [f addObject:@"Sort by modified time descending did not reverse the order"];
    }
    prefs.recentFilePaths = savedRecents;

    // ---- Closing the last tab, with the exit preference on: a window that was never shown must not quit the app ----
    BOOL savedExit = prefs.exitOnClosingLastTab;
    prefs.exitOnClosingLastTab = YES;
    if (![wc closeAllDocuments]) [f addObject:@"Close All was cancelled by a prompt in the self-check"];
    prefs.exitOnClosingLastTab = savedExit;
    if (wc.documents.count != 1)
        [f addObject:[NSString stringWithFormat:@"closing every tab left %lu documents, want one fresh buffer",
                      (unsigned long)wc.documents.count]];

    // ---- Session round trip: bookmarks and an untitled buffer both have to survive it ----
    NPPDocument *sess = wc.currentDocument;
    NPPFill(sess, @"one\ntwo\nthree\n");
    NPPSci(sess.editor, SCI_MARKERADD, 1, NPPMarkerBookmark);
    NSURL *backupDir = [wc sessionBackupDirectory];
    NSURL *parked = [backupDir URLByAppendingPathComponent:[NSString stringWithFormat:@"session@%@", sess.displayName]];
    NSXMLDocument *xml = [wc sessionXMLDocument];
    if (!backupDir) {
        // No backup module in this build: untitled buffers have nowhere to be parked, which is not a failure.
    } else if ([xml nodesForXPath:@"//File" error:NULL].count != 1) {
        [f addObject:@"the session dropped the untitled buffer instead of backing it up"];
    } else {
        NSUInteger beforeLoad = wc.documents.count;
        [wc applySessionXMLDocument:xml];
        NPPDocument *restored = wc.currentDocument;
        if (wc.documents.count != beforeLoad + 1 || restored == sess) {
            [f addObject:@"loading a session did not re-open the untitled buffer it had backed up"];
        } else {
            if (NPPSci(restored.editor, SCI_GETLENGTH) != NPPSci(sess.editor, SCI_GETLENGTH))
                [f addObject:@"the restored untitled buffer does not hold the text the session saved"];
            if (!(NPPSci(restored.editor, SCI_MARKERGET, 1) & (1 << NPPMarkerBookmark)))
                [f addObject:@"the session did not carry the bookmarks over"];
        }
    }
    if (parked) [fm removeItemAtURL:parked error:NULL];   // the check's own backup file, not the user's
    [fm removeItemAtURL:tmp error:NULL];
}

// Three things the window owes the rest of the app: the room the tab strip asks for (a column when the vertical
// preference is on, extra rows when multi-line wraps), the activation sweep over *every* open buffer, and an
// auto-session as detailed as the one Save Session writes. Its own controller, because the checks above leave a
// dirty buffer behind and closing that would put a modal prompt up in a headless run.
+ (void)appendLayoutReloadAndAutoSessionFailures:(NSMutableArray<NSString *> *)f {
    NPPEditorWindowController *wc = [[NPPEditorWindowController alloc] init];   // never ordered front
    NPPPreferences *prefs = NPPPreferences.shared;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"npp-window-layout-selfcheck"] isDirectory:YES];
    [fm removeItemAtURL:tmp error:NULL];
    [fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:NULL];

    // ---- Tab strip layout: the strip asks (NPPTabBarVertical / NPPTabBarMultiLine, which it reads itself), the
    // window grants. Both keys are flipped the way the Preferences window flips them: write, then let the change
    // notification arrive — nothing here calls -layoutContent, so the strip's own "I need other room" callback is
    // the only thing that can move it.
    NPPTabBarView *bar = wc.tabBar;
    id savedVert = [ud objectForKey:@"NPPTabBarVertical"], savedMulti = [ud objectForKey:@"NPPTabBarMultiLine"];
    id savedHide = [ud objectForKey:@"NPPTabBarHidden"];
    void (^setMode)(NSString *, BOOL) = ^(NSString *key, BOOL on) {
        [ud setBool:on forKey:key];
        [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:ud];
    };
    // All three off first: the user may have any of them on, and the untouched default is what is checked here.
    setMode(@"NPPTabBarVertical", NO);
    setMode(@"NPPTabBarMultiLine", NO);
    setMode(@"NPPTabBarHidden", NO);
    [wc layoutContent];
    NSRect content = wc.window.contentView.bounds;
    CGFloat rowH = bar.preferredHeight;                        // one row: the default this must not disturb
    if (!NSEqualRects(bar.frame, NSMakeRect(0, NSMaxY(content) - rowH, NSWidth(content), rowH)))
        [f addObject:[NSString stringWithFormat:@"the default tab strip is %@, want one row across the top of %@",
                      NSStringFromRect(bar.frame), NSStringFromRect(content)]];
    if (NSMinX(wc.panelHost.frame) != 0 || NSMaxY(wc.panelHost.frame) != NSHeight(content) - rowH)
        [f addObject:[NSString stringWithFormat:@"the default editor area is %@, want the window minus one tab row",
                      NSStringFromRect(wc.panelHost.frame)]];

    setMode(@"NPPTabBarVertical", YES);
    if (bar.preferredWidth <= 0) {
        [f addObject:@"the tab strip did not pick the vertical preference up at all"];
    } else {
        if (NSWidth(bar.frame) != bar.preferredWidth || !bar.vertical)
            [f addObject:[NSString stringWithFormat:@"vertical: the window left the strip at %@, want a %g pt column",
                          NSStringFromRect(bar.frame), bar.preferredWidth]];
        if (NSMinX(wc.panelHost.frame) < NSMaxX(bar.frame))
            [f addObject:[NSString stringWithFormat:@"vertical: the editor area %@ still runs under the tab column %@",
                          NSStringFromRect(wc.panelHost.frame), NSStringFromRect(bar.frame)]];
    }
    setMode(@"NPPTabBarVertical", NO);

    // Multi-line: a narrow window and enough tabs that they cannot fit on one row. The window frame is autosaved
    // under the same name the app's own window uses, so it is put back before this returns.
    NSRect savedWindowFrame = wc.window.frame;
    [wc.window setContentSize:NSMakeSize(480, 400)];
    setMode(@"NPPTabBarMultiLine", YES);
    while (wc.documents.count < 8) [wc newDocument];
    content = wc.window.contentView.bounds;
    if (bar.preferredHeight < 2 * rowH) {
        [f addObject:[NSString stringWithFormat:@"multi-line: 8 tabs in a %g pt window still ask for %g pt",
                      NSWidth(content), bar.preferredHeight]];
    } else if (NSHeight(bar.frame) != bar.preferredHeight) {
        [f addObject:[NSString stringWithFormat:@"multi-line: the strip asked for %g pt and was given %g",
                      bar.preferredHeight, NSHeight(bar.frame)]];
    } else if (NSMaxY(wc.panelHost.frame) != NSHeight(content) - bar.preferredHeight) {
        [f addObject:@"multi-line: the editor area did not make room for the extra rows"];
    }
    // Both modes off again: the strip has to go back to exactly the band it started as, extra tabs and all.
    setMode(@"NPPTabBarMultiLine", NO);
    [wc.window setFrame:savedWindowFrame display:NO];
    [wc layoutContent];
    if (NSHeight(bar.frame) != rowH || NSWidth(bar.frame) != NSWidth(wc.window.contentView.bounds))
        [f addObject:[NSString stringWithFormat:@"the strip did not go back to a single row: %@", NSStringFromRect(bar.frame)]];

    // Preferences ▸ Tab Bar ▸ Hide (and -notabbar, which sets the same preference). NPPPreferences hides both
    // strips and then calls -layoutContent, so this is what stops the layout handing the room straight back and
    // unhiding them — a live checkbox that did nothing at all.
    setMode(@"NPPTabBarHidden", YES);
    [wc layoutContent];
    content = wc.window.contentView.bounds;
    if (!bar.hidden || NSMaxY(wc.panelHost.frame) != NSHeight(content))
        [f addObject:[NSString stringWithFormat:@"hidden tab bar: strip hidden=%d at %@, editor area %@, want no strip and the full height",
                      bar.hidden, NSStringFromRect(bar.frame), NSStringFromRect(wc.panelHost.frame)]];
    setMode(@"NPPTabBarHidden", NO);
    [wc layoutContent];
    if (bar.hidden) [f addObject:@"the tab strip stayed hidden after Tab Bar ▸ Hide was turned off again"];

    if (savedVert) [ud setObject:savedVert forKey:@"NPPTabBarVertical"]; else [ud removeObjectForKey:@"NPPTabBarVertical"];
    if (savedMulti) [ud setObject:savedMulti forKey:@"NPPTabBarMultiLine"]; else [ud removeObjectForKey:@"NPPTabBarMultiLine"];
    if (savedHide) [ud setObject:savedHide forKey:@"NPPTabBarHidden"]; else [ud removeObjectForKey:@"NPPTabBarHidden"];
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:ud];

    // ---- Print Now takes the syntax-coloured path (N++ filePrint(false)). Nothing here can drive a printer, so
    // what is checked is both halves of the contract: the selector this window actually routes Print Now through
    // (asked of the same function -printDocument:showPanel: asks, selection or not), and that NPPPrintRenderer
    // publishes it. Either half breaking drops Print Now silently back to the plain-text fallback.
    Class printer = NSClassFromString(@"NPPPrintRenderer");
    SEL printNow = NPPPrintRendererSelector(NO, YES), noPanel = @selector(printEditor:documentName:window:showPanel:);
    if (printNow != noPanel || NPPPrintRendererSelector(NO, NO) != noPanel)
        [f addObject:[NSString stringWithFormat:@"Print Now is routed through %@, not the renderer's no-panel entry point",
                      NSStringFromSelector(printNow)]];
    else if (printer && ![printer respondsToSelector:printNow])
        [f addObject:@"Print Now cannot reach the syntax-coloured renderer: no printEditor:documentName:window:showPanel:"];

    // ---- -nosession. Both session gates are asked of NPPCommandLine by name, and a name that no longer resolves
    // fails *open*: the auto-session would quietly start saving and restoring under -nosession / -quickPrint again,
    // with nothing to show for it. So check the two selectors still land, and that the answer survives the trip
    // through NSInvocation as a BOOL (a nil class answers YES here, which is the no-command-line-module default).
    if (NSClassFromString(@"NPPCommandLine")) {
        BOOL savedLanded = NO, restoreLanded = NO;
        BOOL maySave = NPPSessionSwitchAllows(NO, &savedLanded), mayRestore = NPPSessionSwitchAllows(YES, &restoreLanded);
        if (!savedLanded || !restoreLanded)
            [f addObject:[NSString stringWithFormat:@"the -nosession gates never reach NPPCommandLine (save asked=%d, restore asked=%d): "
                          @"both fail open, so a session would be saved and restored under -nosession", savedLanded, restoreLanded]];
        // No switches are parsed in a headless run, so both must come back YES — a plumbing slip that always said
        // NO would stop the session being written at all, just as quietly.
        else if (!maySave || !mayRestore)
            [f addObject:@"the session switches came back NO on a command line that carries neither"];
    }

    // ---- Coming back to the front checks every open buffer, not just the one on screen (N++
    // checkModifiedDocument(false)). Silent detection throughout: a prompt would stop a headless run dead.
    NPPFileAutoDetection savedDetection = prefs.fileAutoDetection;
    NSArray<NSString *> *savedRecents = prefs.recentFilePaths;
    NSURL *frontURL = [tmp URLByAppendingPathComponent:@"front.txt"], *backURL = [tmp URLByAppendingPathComponent:@"back.txt"];
    [@"one\n" writeToURL:frontURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"one\n" writeToURL:backURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NPPDocument *front = [wc openDocumentAtURL:frontURL], *back = [wc openDocumentAtURL:backURL];
    [wc selectDocument:front];
    prefs.fileAutoDetection = NPPFileAutoDetectionSilent;
    NSString *grown = @"one\ntwo\nthree\n";
    for (NSURL *u in @[frontURL, backURL]) {
        [grown writeToURL:u atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // An atomic write already moves the timestamp; pinning it a whole second on makes the check independent of
        // how fine the filesystem's mtime is, so it can never pass (or fail) on timing.
        [fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:1]} ofItemAtPath:u.path error:NULL];
    }
    if (!front || !back) {
        [f addObject:@"the activation sweep could not open its own temporary files"];
    } else {
        [wc checkDocumentsChangedOnDisk];
        sptr_t want = (sptr_t)grown.length;
        if (NPPSci(front.editor, SCI_GETLENGTH) != want)
            [f addObject:@"the activation sweep did not reload the document on screen"];
        if (NPPSci(back.editor, SCI_GETLENGTH) != want)
            [f addObject:@"the activation sweep reloaded only the document on screen, not every open buffer"];
    }
    prefs.fileAutoDetection = savedDetection;

    // ---- The auto-session carries what Save Session carries, and comes back the way the next launch brings it
    // back. Both the preferences it writes and the file it writes are the user's, so both are put back after.
    NSURL *autoURL = [wc autoSessionURL];
    if (autoURL && front && back) {
        NSArray<NSString *> *savedPaths = prefs.sessionFilePaths;
        NSInteger savedIndex = prefs.sessionSelectedIndex;
        NSData *savedAuto = [NSData dataWithContentsOfURL:autoURL];
        NPPLanguage *lang = nil;                              // the last language a .txt is not already in
        for (NPPLanguage *l in NPPLanguageManager.shared.languages)
            if (l != front.language && l.shortName.length) lang = l;

        [wc selectDocument:back];
        NPPRunCmd(wc, NPPCmdViewMoveToOtherView, f);          // back.txt now lives in the sub view
        NPPSci(front.editor, SCI_MARKERADD, 1, NPPMarkerBookmark);
        NPPSci(front.editor, SCI_SETSEL, 2, 5);
        if (lang) front.language = lang;
        front.isReadOnly = YES;
        [wc selectDocument:front];
        [wc storeSessionInPreferences];
        if (prefs.sessionFilePaths.count != 2)
            [f addObject:[NSString stringWithFormat:@"the auto-session recorded %lu of the 2 open files",
                          (unsigned long)prefs.sessionFilePaths.count]];

        front.isReadOnly = NO;                                // nothing read-only on the way out of the check
        if (![wc closeAllDocuments]) [f addObject:@"closing the auto-session check's documents was cancelled"];
        if (![wc restoreAutoSession]) {
            [f addObject:@"the stored auto-session could not be restored"];
        } else if (wc.documents.count != 2 || !wc.panelHost.splitEnabled) {
            [f addObject:[NSString stringWithFormat:@"the auto-session restored %lu document(s) into %@ view(s), want 2 into two",
                          (unsigned long)wc.documents.count, wc.panelHost.splitEnabled ? @"two" : @"one"]];
        } else {
            NPPDocument *r = wc.documents.firstObject;        // main view first: front.txt
            if (![r.fileURL.path isEqualToString:frontURL.path] ||
                ![wc.documents.lastObject.fileURL.path isEqualToString:backURL.path])
                [f addObject:@"the auto-session lost which view each document was in"];
            if (lang && ![r.language.shortName isEqualToString:lang.shortName])
                [f addObject:[NSString stringWithFormat:@"the auto-session lost the language: %@, want %@",
                              r.language.shortName, lang.shortName]];
            if (!r.isReadOnly) [f addObject:@"the auto-session lost the read-only flag"];
            if (!(NPPSci(r.editor, SCI_MARKERGET, 1) & (1 << NPPMarkerBookmark)))
                [f addObject:@"the auto-session lost the bookmarks"];
            if (NPPSci(r.editor, SCI_GETSELECTIONSTART) != 2 || NPPSci(r.editor, SCI_GETSELECTIONEND) != 5)
                [f addObject:[NSString stringWithFormat:@"the auto-session restored the selection as %ld-%ld, want 2-5",
                              (long)NPPSci(r.editor, SCI_GETSELECTIONSTART), (long)NPPSci(r.editor, SCI_GETSELECTIONEND)]];
            r.isReadOnly = NO;
        }
        if (savedAuto) [savedAuto writeToURL:autoURL options:NSDataWritingAtomic error:NULL];
        else [fm removeItemAtURL:autoURL error:NULL];
        prefs.sessionFilePaths = savedPaths;
        prefs.sessionSelectedIndex = savedIndex;
    }
    prefs.recentFilePaths = savedRecents;
    [fm removeItemAtURL:tmp error:NULL];
}

// ⌃ can go up while another window is key (or the app deactivates), and then no flags-changed event ever reaches
// our monitor: commit the run here instead of leaving the HUD on screen and the next ⌃Tab continuing a stale one.
- (void)windowDidResignKey:(NSNotification *)notification {
    if (_switcherOrder) [self commitDocumentSwitcher];
}

- (void)windowDidBecomeKey:(NSNotification *)notification { [self checkDocumentsChangedOnDisk]; }

// N++ Notepad_plus::checkModifiedDocument(false) — coming back to the front checks *every* open buffer, in both
// views, not just the one on screen. Each is handled in turn, and the silent/prompt decision stays per-document
// (-promptReloadForDocument: asks -reloadDocumentSilentlyIfPreferred: first). The re-entrancy guard is what keeps
// the prompts from stacking: each alert is modal, and dismissing one makes the window key again, which would
// otherwise start a second sweep on top of the first — upstream guards the same way (_isFileOpening / one sweep
// at a time). -allDocuments hands back a copy, so a reload that closes nothing can still not trip the loop.
- (void)checkDocumentsChangedOnDisk {
    if (_checkingDisk) return;
    _checkingDisk = YES;
    BOOL onActivation = NPPPreferences.shared.checkFileChangesOnActivation;
    for (NPPDocument *doc in [self allDocuments]) {
        if (!doc.fileURL || doc.isMonitoring) continue;   // monitoring (tail -f) reloads itself
        if ([_pendingReloadPrompt containsObject:doc]) [_pendingReloadPrompt removeObject:doc];
        else if (!(onActivation && [doc fileChangedOnDiskSinceLoad])) continue;
        // A file that has gone (deleted, renamed, its volume unmounted) reports "changed" and can never reload, so
        // the prompt would come back on every single activation — once per lost file, now that the sweep walks all
        // of them. ponytail: upstream asks "keep this file in editor?" instead; that dialog is the upgrade.
        if (![doc.fileURL checkResourceIsReachableAndReturnError:NULL]) continue;
        // ponytail: the document is not brought to the front first — the alert names its full path. Select it
        // here if "which file is this?" ever comes up.
        [self promptReloadForDocument:doc];
    }
    _checkingDisk = NO;
}

@end
