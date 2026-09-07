// NPPAppDelegate.mm — application lifecycle + programmatic main menu mirroring Notepad++'s IDR_M30_MENU.
#import "NPPAppDelegate.h"
#import "NPPCommands.h"
#import "NPPCommandLine.h"
#import "NPPEditCommands.h"
#import "NPPPreferences.h"
#import "NPPLanguageManager.h"
#import "NPPLocalization.h"
#import "NPPDocument.h"

static NSString *const kRecentChanged = @"NPPRecentFilesDidChange";
static NSString *const kRecentInline = @"NPPRecentFileInline";   // stamp on the File-menu items the recent list owns
static NSString *const kThemeDefault = @"Default (stylers.xml)";
static NSString *const kThemeDark = @"DarkModeDefault";

// ---- tiny menu DSL --------------------------------------------------------------------------
static NSMenuItem *I(NSMenu *m, NSString *title, NSInteger tag, NSString *key = @"",
                     NSEventModifierFlags mods = NSEventModifierFlagCommand, SEL action = @selector(nppCommand:)) {
    NSMenuItem *it = [m addItemWithTitle:title action:action keyEquivalent:key];
    it.tag = tag;
    it.keyEquivalentModifierMask = key.length ? mods : 0;
    return it;
}
static NSMenu *Sub(NSMenu *parent, NSString *title) {
    NSMenuItem *it = [parent addItemWithTitle:title action:nil keyEquivalent:@""];
    it.submenu = [[NSMenu alloc] initWithTitle:title];
    return it.submenu;
}
static void Sep(NSMenu *m) { [m addItem:[NSMenuItem separatorItem]]; }
static NSString *K(unichar c) { return [NSString stringWithCharacters:&c length:1]; }

#define CMD   NSEventModifierFlagCommand
#define SHIFT NSEventModifierFlagShift
#define OPT   NSEventModifierFlagOption
#define CTRL  NSEventModifierFlagControl

@interface NPPAppDelegate ()
@property (nonatomic, strong) NPPEditorWindowController *mainWindowController;
@property (nonatomic, strong) NSMenu *recentMenu, *fileMenu, *languageMenu, *themeMenu, *macroMenu, *runMenu,
                                     *settingsMenu, *uiLanguageMenu;
@property (nonatomic, strong) NSMenuItem *clipboardCutItem, *clipboardCopyItem;
@property (nonatomic) BOOL observingAppearance;
- (NSMenu *)makeMainMenu;
- (NSInteger)liveMacroRecordingCommand;
@end

// ---- Edit ▸ Cut / Copy: the fallback that keeps them working everywhere ----------------------------------------
// The two items carry -nppCommand: so the port can honour Preferences ▸ "Enable Copy/Cut line without selection"
// (cut:/copy: would reach Scintilla without passing through us). But AppKit will not deliver a *custom* action into
// an app-modal NSAlert's session: it matches the ⌘X/⌘C item, finds nothing that answers -nppCommand:, and swallows
// the key — measured, not assumed. That would kill Cut and Copy inside the runModal name prompts (project panel,
// folder-as-workspace, "New User Defined Language"), where ⌘V would still work. So whenever nothing answers
// -nppCommand: any more, the two items get their standard selectors back and behave exactly as they did before this
// module owned them; the key-window notifications fire while the modal session is already up, which is what makes
// the flip land before the first keystroke. Sheets, panels, Preferences and the Open/Save panels all keep
// -nppCommand: (their sessions do reach us), so the preference still applies there.
static void SetClipboardItemAction(NSMenuItem *item, BOOL deliverable) {
    if (!item) return;
    if (deliverable) item.action = @selector(nppCommand:);
    else item.action = (item.tag == NPPCmdEditClipboardCut) ? @selector(cut:) : @selector(copy:);
}

@implementation NPPAppDelegate

#pragma mark - lifecycle

- (void)applicationWillFinishLaunching:(NSNotification *)n {
    NPPPreferences *prefs = NPPPreferences.shared;
    [prefs registerDefaults];

    NSError *err = nil;
    if (![NPPLanguageManager.shared loadDefaultsFromBundle:[NSBundle mainBundle] error:&err]) {
        NSAlert *a = [NSAlert new];
        a.alertStyle = NSAlertStyleCritical;
        a.messageText = @"Notepad++ cannot load its language definitions.";
        a.informativeText = err.localizedDescription ?: @"langs.model.xml / stylers.model.xml missing from the application bundle.";
        [a runModal];
        [NSApp terminate:nil];
        return;
    }
    [self applyFontOverride];
    [self applyThemePreference];
    [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:NULL];
    self.observingAppearance = YES;   // -dealloc must not unregister for an instance that never launched (self-check)

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(rebuildRecentFilesMenu) name:kRecentChanged object:nil];
    [nc addObserver:self selector:@selector(themeDidChange:) name:NPPThemeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(prefsDidChange:) name:NPPPreferencesDidChangeNotification object:nil];
    // Which window is key decides whether -nppCommand: can still be delivered at all (see SetClipboardItemAction).
    [nc addObserver:self selector:@selector(syncClipboardMenuItems) name:NSWindowDidBecomeKeyNotification object:nil];
    [nc addObserver:self selector:@selector(syncClipboardMenuItems) name:NSWindowDidResignKeyNotification object:nil];

    [self buildMainMenu];
}

// main.mm hands the arguments to NPPCommandLine before this object exists, so what to open is already decided:
// the file list is wildcard-expanded, session-expanded (-openSession) and "--"-aware, switches never reach it as
// file names, and the folder arguments, the caret (-n/-c/-p), the window (-x/-y/-alwaysOnTop/-titleAdd/-notabbar),
// -ro/-fullReadOnly, -monitor, -udl/-l/-L and -quickPrint are applied by NPPCommandLine itself one main-queue turn
// from now — it waits for the window controller's context, which is published by -ensureWindow below.
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self ensureWindow];

    NPPPreferences *prefs = NPPPreferences.shared;
    NSArray<NSURL *> *urls = NPPCommandLine.current.fileURLs;
    if (urls.count) { [self openFileURLs:urls]; return; }
    if (![NPPCommandLine shouldRestoreSavedSession] || !prefs.rememberLastSession) return;

    NSMutableArray<NSURL *> *session = [NSMutableArray array];
    for (NSString *p in prefs.sessionFilePaths)
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) [session addObject:[NSURL fileURLWithPath:p]];
    if (!session.count) return;
    [self.mainWindowController openDocumentsAtURLs:session];
    NSInteger sel = prefs.sessionSelectedIndex;
    if (sel >= 0 && sel < (NSInteger)self.mainWindowController.documents.count)
        [self.mainWindowController selectDocumentAtIndex:sel];
}

- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)files {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *f in files) [urls addObject:[NSURL fileURLWithPath:f]];
    [self openFileURLs:urls];
    [app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // Prompt FIRST. The controller writes session.xml on its way out; writing the flat path list before the prompt
    // meant a cancelled quit left the two disagreeing — the list updated, the XML still describing the last real quit.
    if (self.mainWindowController && ![self.mainWindowController promptToSaveAllBeforeQuit]) return NSTerminateCancel;
    [self saveSession];
    return NSTerminateNow;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self ensureWindow];
    return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

- (void)saveSession {
    // -nosession (implied by -quickPrint and -export=functionList): this launch leaves the stored session alone.
    if (![NPPCommandLine shouldSaveSessionOnQuit]) return;
    NPPEditorWindowController *wc = self.mainWindowController;
    if (!wc) return;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSInteger selected = 0;
    for (NPPDocument *d in wc.documents) {
        if (!d.fileURL) continue;
        if (d == wc.currentDocument) selected = (NSInteger)paths.count;
        [paths addObject:d.fileURL.path];
    }
    NPPPreferences.shared.sessionFilePaths = paths;
    NPPPreferences.shared.sessionSelectedIndex = selected;
}

- (void)ensureWindow {
    if (!self.mainWindowController) {
        self.mainWindowController = [[NPPEditorWindowController alloc] init];
        // ponytail: the status bar's language menu is a copy of ours, refreshed from -rebuildLanguageMenu.
        if (self.languageMenu && !self.mainWindowController.statusBar.docTypeMenu)
            self.mainWindowController.statusBar.docTypeMenu = [self.languageMenu copy];
        // -init posted NPPCommandContextReadyNotification, which is where NPPLocalization attaches its own copy.
        [self dropDuplicateUILanguageMenus];
    }
    // -showWindow: is the launch path for the two preferences the window controller owns and we only have to reach:
    // Recent Files History ▸ "check that the files still exist" (+pruneRecentFilesAtLaunch — with the preference off
    // nothing is stat'ed, and a pruned list posts kRecentChanged, which rebuilds the menu below), and New Document ▸
    // "always open a new document in addition at startup" (-addStartupDocumentIfPreferred, scheduled for the next
    // main-queue turn so the session and the command line have opened their files first). Both are once-per-launch
    // no matter how often we are called, so we must not add a document of our own here.
    [self.mainWindowController showWindow:nil];
    [self.mainWindowController.window makeKeyAndOrderFront:nil];
}

- (void)openFileURLs:(NSArray<NSURL *> *)urls {
    [self ensureWindow];
    if (urls.count) [self.mainWindowController openDocumentsAtURLs:urls];
}

#pragma mark - theme / font

- (BOOL)systemIsDark {
    NSAppearanceName n = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [n isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)applyThemePreference {
    NSString *want = NPPPreferences.shared.themeName;
    if (!want.length) want = [self systemIsDark] ? kThemeDark : kThemeDefault;
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    if (![lm.availableThemeNames containsObject:want]) want = kThemeDefault;
    if ([lm.currentThemeName isEqualToString:want]) return;
    NSError *err = nil;
    if (![lm selectThemeNamed:want error:&err]) NSLog(@"theme '%@' failed: %@", want, err);
}

- (void)applyFontOverride {
    NPPPreferences *p = NPPPreferences.shared;
    NPPLanguageManager.shared.overrideFontName = p.fontName.length ? p.fontName : nil;
    NPPLanguageManager.shared.overrideFontSize = p.fontSize;
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
    if ([kp isEqualToString:@"effectiveAppearance"] && NPPPreferences.shared.themeName.length == 0)
        [self applyThemePreference];
}

- (void)themeDidChange:(NSNotification *)n { [self rebuildThemeMenu]; }

- (void)prefsDidChange:(NSNotification *)n {
    // The window observes prefs too and re-applies; we only keep manager state in sync.
    [self applyFontOverride];
    [self applyThemePreference];
    // Recent Files History ▸ submenu / label settings: the list itself has not changed (so no kRecentChanged),
    // only where it goes and what each entry is called.
    [self rebuildRecentFilesMenu];
}

#pragma mark - main menu

- (void)buildMainMenu {
    NSApp.mainMenu = [self makeMainMenu];
    [self rebuildRecentFilesMenu];
}

// The menu bar, built but not installed. +selfCheckFailures runs this to check the real items and the real key
// equivalents without ever becoming NSApp.mainMenu — the one menu NPPShortcutMapper and NPPLocalization follow.
- (NSMenu *)makeMainMenu {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"MainMenu"];

    // App
    NSMenu *app = Sub(main, @"Notepad++");
    I(app, @"About Notepad++", NPPCmdHelpAbout);
    Sep(app);
    I(app, @"Preferences…", NPPCmdSettingsPreferences, @",");
    Sep(app);
    NSMenu *services = Sub(app, @"Services");
    NSApp.servicesMenu = services;
    Sep(app);
    I(app, @"Hide Notepad++", 0, @"h", CMD, @selector(hide:));
    I(app, @"Hide Others", 0, @"h", CMD | OPT, @selector(hideOtherApplications:));
    I(app, @"Show All", 0, @"", 0, @selector(unhideAllApplications:));
    Sep(app);
    I(app, @"Quit Notepad++", 0, @"q", CMD, @selector(terminate:));

    // File
    NSMenu *file = self.fileMenu = Sub(main, @"File");
    I(file, @"New", NPPCmdFileNew, @"n");
    I(file, @"Open…", NPPCmdFileOpen, @"o");
    self.recentMenu = Sub(file, @"Open Recent");
    I(file, @"Open Containing Folder", NPPCmdFileOpenContainingFolder);
    I(file, @"Open in Terminal", NPPCmdFileOpenInTerminal);
    I(file, @"Open Containing Folder as Workspace", NPPCmdFileContainingFolderAsWorkspace);
    I(file, @"Open in Default Viewer", NPPCmdFileOpenInDefaultViewer);
    I(file, @"Open Folder as Workspace…", NPPCmdFileOpenFolderAsWorkspace);
    I(file, @"Reload from Disk", NPPCmdFileReload, @"r");
    Sep(file);
    I(file, @"Save", NPPCmdFileSave, @"s");
    I(file, @"Save As…", NPPCmdFileSaveAs, @"S", CMD | SHIFT);
    I(file, @"Save a Copy As…", NPPCmdFileSaveCopyAs);
    I(file, @"Save All", NPPCmdFileSaveAll, @"s", CMD | OPT);
    I(file, @"Rename…", NPPCmdFileRename);
    Sep(file);
    I(file, @"Close", NPPCmdFileClose, @"w");
    I(file, @"Close All", NPPCmdFileCloseAll, @"W", CMD | SHIFT);
    NSMenu *closeMulti = Sub(file, @"Close Multiple Documents");
    I(closeMulti, @"Close All but Active Document", NPPCmdFileCloseAllButCurrent);
    I(closeMulti, @"Close All to the Left", NPPCmdFileCloseAllToLeft);
    I(closeMulti, @"Close All to the Right", NPPCmdFileCloseAllToRight);
    I(closeMulti, @"Close All Unchanged", NPPCmdFileCloseAllUnchanged);
    I(closeMulti, @"Close All but Pinned Documents", NPPCmdFileCloseAllButPinned);
    I(file, @"Move to Trash", NPPCmdFileMoveToTrash);
    Sep(file);
    I(file, @"Load Session…", NPPCmdFileLoadSession);
    I(file, @"Save Session…", NPPCmdFileSaveSession);
    Sep(file);
    I(file, @"Print…", NPPCmdFilePrint, @"p");
    I(file, @"Print Now", NPPCmdFilePrintNow);
    Sep(file);
    I(file, @"Restore Recent Closed File", NPPCmdFileRestoreLastClosed, @"T", CMD | SHIFT);

    // Edit
    NSMenu *edit = Sub(main, @"Edit");
    I(edit, @"Undo", 0, @"z", CMD, @selector(undo:));
    I(edit, @"Redo", 0, @"Z", CMD | SHIFT, @selector(redo:));
    Sep(edit);
    // Cut and Copy are the only standard editing pair the port has to own: Preferences ▸ "Enable Copy/Cut line
    // without selection" cannot be honoured through cut:/copy:, which reach Scintilla without passing through us.
    // NPPEditCommands hands every non-editor responder its standard selector straight back (see
    // +performClipboardCommand:sender:), and -syncClipboardMenuItems below hands the *items* their standard
    // selectors back for the one context AppKit refuses to route, so Cut and Copy keep working wherever they work
    // today.
    self.clipboardCutItem = I(edit, @"Cut", NPPCmdEditClipboardCut, @"x", CMD);
    self.clipboardCopyItem = I(edit, @"Copy", NPPCmdEditClipboardCopy, @"c", CMD);
    I(edit, @"Paste", 0, @"v", CMD, @selector(paste:));
    I(edit, @"Delete", NPPCmdEditDelete);
    I(edit, @"Select All", 0, @"a", CMD, @selector(selectAll:));
    I(edit, @"Begin/End Select", NPPCmdEditBeginEndSelect);
    Sep(edit);
    NSMenu *ins = Sub(edit, @"Insert");
    I(ins, @"Date Time (short)", NPPCmdEditInsertDateTimeShort);
    I(ins, @"Date Time (long)", NPPCmdEditInsertDateTimeLong);
    I(ins, @"Date Time (customized)", NPPCmdEditInsertDateTimeCustom);
    NSMenu *clip = Sub(edit, @"Copy to Clipboard");
    I(clip, @"Copy Current Full File Path", NPPCmdEditCopyFullPath);
    I(clip, @"Copy Current Filename", NPPCmdEditCopyFileName);
    I(clip, @"Copy Current Dir. Path", NPPCmdEditCopyDirPath);
    Sep(clip);
    I(clip, @"Copy All Filenames", NPPCmdEditCopyAllNames);
    I(clip, @"Copy All File Paths", NPPCmdEditCopyAllPaths);
    NSMenu *indent = Sub(edit, @"Indent");
    I(indent, @"Increase Line Indent", NPPCmdEditIndent, @"]");
    I(indent, @"Decrease Line Indent", NPPCmdEditUnindent, @"[");
    NSMenu *cases = Sub(edit, @"Convert Case to");
    I(cases, @"UPPERCASE", NPPCmdEditUpperCase, @"U", CMD | SHIFT);
    I(cases, @"lowercase", NPPCmdEditLowerCase, @"u");
    I(cases, @"Proper Case", NPPCmdEditProperCase);
    I(cases, @"Proper Case (blend)", NPPCmdEditProperCaseBlend);
    I(cases, @"Sentence case", NPPCmdEditSentenceCase);
    I(cases, @"Sentence case (blend)", NPPCmdEditSentenceCaseBlend);
    I(cases, @"iNVERT cASE", NPPCmdEditInvertCase);
    I(cases, @"ranDOm CasE", NPPCmdEditRandomCase);
    NSMenu *lines = Sub(edit, @"Line Operations");
    I(lines, @"Duplicate Current Line", NPPCmdEditDuplicateLine, @"d");
    I(lines, @"Remove Duplicate Lines", NPPCmdEditRemoveDuplicateLines);
    I(lines, @"Remove Consecutive Duplicate Lines", NPPCmdEditRemoveConsecutiveDuplicateLines);
    I(lines, @"Split Lines", NPPCmdEditSplitLines, @"i");
    I(lines, @"Join Lines", NPPCmdEditJoinLines, @"j");
    I(lines, @"Move Up Current Line", NPPCmdEditMoveLineUp, K(NSUpArrowFunctionKey), CMD | SHIFT);
    I(lines, @"Move Down Current Line", NPPCmdEditMoveLineDown, K(NSDownArrowFunctionKey), CMD | SHIFT);
    I(lines, @"Remove Empty Lines", NPPCmdEditRemoveEmptyLines);
    I(lines, @"Remove Empty Lines (Containing Blank characters)", NPPCmdEditRemoveEmptyLinesWithBlank);
    I(lines, @"Insert Blank Line Above Current", NPPCmdEditInsertBlankLineAbove, @"\r", CMD | OPT);
    I(lines, @"Insert Blank Line Below Current", NPPCmdEditInsertBlankLineBelow, @"\r");
    I(lines, @"Reverse Line Order", NPPCmdEditReverseLineOrder);
    I(lines, @"Randomize Line Order", NPPCmdEditRandomizeLineOrder);
    Sep(lines);
    I(lines, @"Sort Lines Lexicographically Ascending", NPPCmdEditSortLexAsc);
    I(lines, @"Sort Lines Lex. Ascending Ignoring Case", NPPCmdEditSortLexCaseInsAsc);
    I(lines, @"Sort Lines In Locale Order Ascending", NPPCmdEditSortLocaleAsc);
    I(lines, @"Sort Lines As Integers Ascending", NPPCmdEditSortIntAsc);
    I(lines, @"Sort Lines As Decimals (Comma) Ascending", NPPCmdEditSortDecCommaAsc);
    I(lines, @"Sort Lines As Decimals (Dot) Ascending", NPPCmdEditSortDecDotAsc);
    I(lines, @"Sort Lines By Length Ascending", NPPCmdEditSortLengthAsc);
    Sep(lines);
    I(lines, @"Sort Lines Lexicographically Descending", NPPCmdEditSortLexDesc);
    I(lines, @"Sort Lines Lex. Descending Ignoring Case", NPPCmdEditSortLexCaseInsDesc);
    I(lines, @"Sort Lines In Locale Order Descending", NPPCmdEditSortLocaleDesc);
    I(lines, @"Sort Lines As Integers Descending", NPPCmdEditSortIntDesc);
    I(lines, @"Sort Lines As Decimals (Comma) Descending", NPPCmdEditSortDecCommaDesc);
    I(lines, @"Sort Lines As Decimals (Dot) Descending", NPPCmdEditSortDecDotDesc);
    I(lines, @"Sort Lines By Length Descending", NPPCmdEditSortLengthDesc);
    NSMenu *comment = Sub(edit, @"Comment/Uncomment");
    I(comment, @"Toggle Single Line Comment", NPPCmdEditToggleLineComment, @"/");
    I(comment, @"Single Line Comment", NPPCmdEditLineComment, @"k");
    I(comment, @"Single Line Uncomment", NPPCmdEditLineUncomment, @"K", CMD | SHIFT);
    I(comment, @"Block Comment", NPPCmdEditBlockComment, @"/", CMD | SHIFT);
    I(comment, @"Block Uncomment", NPPCmdEditBlockUncomment, @"/", CMD | SHIFT | OPT);
    NSMenu *ac = Sub(edit, @"Auto-Completion");
    I(ac, @"Function Completion", NPPCmdEditCompleteFunction, @" ", CTRL | SHIFT);
    I(ac, @"Word Completion", NPPCmdEditAutoCompleteWord, @" ", CTRL);
    I(ac, @"Path Completion", NPPCmdEditCompletePath);
    Sep(ac);
    I(ac, @"Function Parameters Hint", NPPCmdEditFunctionCallTip, @" ", CMD | SHIFT);
    I(ac, @"Function Parameters Previous Hint", NPPCmdEditFunctionCallTipPrevious);
    I(ac, @"Function Parameters Next Hint", NPPCmdEditFunctionCallTipNext);
    NSMenu *eol = Sub(edit, @"EOL Conversion");
    [self populateEOLMenu:eol];
    NSMenu *blank = Sub(edit, @"Blank Operations");
    I(blank, @"Trim Trailing Space", NPPCmdEditTrimTrailing);
    I(blank, @"Trim Leading Space", NPPCmdEditTrimLeading);
    I(blank, @"Trim Leading and Trailing Space", NPPCmdEditTrimBoth);
    I(blank, @"EOL to Space", NPPCmdEditEOLToSpace);
    I(blank, @"Trim both and EOL to Space", NPPCmdEditTrimAll);
    Sep(blank);
    I(blank, @"TAB to Space", NPPCmdEditTabToSpace);
    I(blank, @"Space to TAB (All)", NPPCmdEditSpaceToTabAll);
    I(blank, @"Space to TAB (Leading)", NPPCmdEditSpaceToTabLeading);
    Sep(edit);
    NSMenu *msAll = Sub(edit, @"Multi-select All");
    I(msAll, @"Ignore Case & Whole Word", NPPCmdEditMultiSelectAll);
    I(msAll, @"Match Case Only", NPPCmdEditMultiSelectAllMatchCase);
    I(msAll, @"Match Whole Word Only", NPPCmdEditMultiSelectAllWholeWord);
    I(msAll, @"Match Case & Whole Word", NPPCmdEditMultiSelectAllMatchCaseWholeWord);
    NSMenu *msNext = Sub(edit, @"Multi-select Next");
    I(msNext, @"Ignore Case & Whole Word", NPPCmdEditMultiSelectNext);
    I(msNext, @"Match Case Only", NPPCmdEditMultiSelectNextMatchCase);
    I(msNext, @"Match Whole Word Only", NPPCmdEditMultiSelectNextWholeWord);
    I(msNext, @"Match Case & Whole Word", NPPCmdEditMultiSelectNextMatchCaseWholeWord);
    I(edit, @"Undo the Latest Added Multi-Select", NPPCmdEditMultiSelectUndo);
    I(edit, @"Skip Current & Go to Next Multi-select", NPPCmdEditMultiSelectSkip);
    Sep(edit);
    I(edit, @"Column Editor…", NPPCmdEditColumnEditor, @"c", CMD | OPT);   // Alt+C upstream (Parameters.cpp:235)
    Sep(edit);
    NSMenu *pasteSpecial = Sub(edit, @"Paste Special");
    I(pasteSpecial, @"Paste HTML Content", NPPCmdEditPasteHTML);
    I(pasteSpecial, @"Paste RTF Content", NPPCmdEditPasteRTF);
    Sep(pasteSpecial);
    I(pasteSpecial, @"Copy Binary Content", NPPCmdEditCopyBinary);
    I(pasteSpecial, @"Cut Binary Content", NPPCmdEditCutBinary);
    I(pasteSpecial, @"Paste Binary Content", NPPCmdEditPasteBinary);

    NSMenu *onSel = Sub(edit, @"On Selection");
    I(onSel, @"Open File", NPPCmdEditOpenSelectedFile);
    I(onSel, @"Open Containing Folder", NPPCmdEditOpenSelectedFileFolder);
    I(onSel, @"Redact Selection", NPPCmdEditRedactSelection);
    Sep(onSel);
    I(onSel, @"Search on Internet", NPPCmdEditSearchOnInternet);
    I(onSel, @"Change Search Engine…", NPPCmdEditChangeSearchEngine);

    I(edit, @"Begin/End Select in Column Mode", NPPCmdEditBeginEndSelectColumn);
    I(edit, @"Column Mode…", NPPCmdEditColumnModeTip);

    NSMenu *ro = Sub(edit, @"Read-Only");
    I(ro, @"Read-Only on Current Document", NPPCmdEditToggleReadOnly);
    I(ro, @"Read-Only for All Documents", NPPCmdEditSetReadOnlyAll);
    I(ro, @"Clear Read-Only for All Documents", NPPCmdEditClearReadOnlyAll);
    I(ro, @"Read-Only Attribute of the File", NPPCmdEditToggleFileReadOnlyAttribute);

    // Search
    NSMenu *search = Sub(main, @"Search");
    I(search, @"Find…", NPPCmdSearchFind, @"f");
    I(search, @"Find Next", NPPCmdSearchFindNext, @"g");
    I(search, @"Find Previous", NPPCmdSearchFindPrev, @"G", CMD | SHIFT);
    I(search, @"Select and Find Next", NPPCmdSearchSelectAndFindNext, @"e");
    I(search, @"Select and Find Previous", NPPCmdSearchSelectAndFindPrev, @"E", CMD | SHIFT);
    I(search, @"Find (Volatile) Next", NPPCmdSearchVolatileFindNext, @"g", CMD | CTRL);
    I(search, @"Find (Volatile) Previous", NPPCmdSearchVolatileFindPrev, @"G", CMD | CTRL | SHIFT);
    I(search, @"Replace…", NPPCmdSearchReplace, @"f", CMD | OPT);
    I(search, @"Incremental Search", NPPCmdSearchIncremental, @"i", CMD | OPT);
    I(search, @"Go to…", NPPCmdSearchGoToLine, @"l");
    I(search, @"Go to Matching Brace", NPPCmdSearchGoToMatchingBrace, @"b");
    I(search, @"Select All In-between {} [] or ()", NPPCmdSearchSelectBetweenBraces, @"b", CMD | OPT);
    I(search, @"Mark…", NPPCmdSearchMark, @"M", CMD | SHIFT);
    Sep(search);
    I(search, @"Find in Files…", NPPCmdSearchFindInFiles, @"F", CMD | SHIFT);
    I(search, @"Find All in Current Document", NPPCmdSearchFindAllInCurrent);
    I(search, @"Find All in All Opened Documents", NPPCmdSearchFindAllInOpened);
    I(search, @"Search Results Window", NPPCmdSearchResultsPanel, @"0", CMD | SHIFT);
    // F4 / Shift-F4, as upstream (Parameters.cpp:253-254). Cmd-G/Cmd-Shift-G above stay on Find Next/Previous, which
    // is the macOS idiom for those; the function-key row is where N++ muscle memory lives and is left to N++.
    I(search, @"Next Search Result", NPPCmdSearchResultsNext, K(NSF4FunctionKey), 0);
    I(search, @"Previous Search Result", NPPCmdSearchResultsPrevious, K(NSF4FunctionKey), SHIFT);
    Sep(search);
    NSMenu *ch = Sub(search, @"Change History");
    I(ch, @"Go to Next Change", NPPCmdSearchChangedNext);
    I(ch, @"Go to Previous Change", NPPCmdSearchChangedPrev);
    I(ch, @"Clear Change History", NPPCmdSearchClearChangeHistory);
    Sep(search);
    static NSString *const ord[] = {@"1st", @"2nd", @"3rd", @"4th", @"5th"};
    NSMenu *styleAll = Sub(search, @"Style All Occurrences of Token");
    NSMenu *styleOne = Sub(search, @"Style One Token");
    NSMenu *clear = Sub(search, @"Clear Style");
    NSMenu *jumpUp = Sub(search, @"Jump Up");
    NSMenu *jumpDown = Sub(search, @"Jump Down");
    for (NSInteger i = 0; i < 5; i++) {
        I(styleAll, [NSString stringWithFormat:@"Using %@ Style", ord[i]], NPPCmdSearchMarkAllExt1 + i);
        I(styleOne, [NSString stringWithFormat:@"Using %@ Style", ord[i]], NPPCmdSearchMarkOneExt1 + i);
        I(clear, [NSString stringWithFormat:@"Clear %@ Style", ord[i]], NPPCmdSearchUnmarkAllExt1 + i);
        I(jumpUp, [NSString stringWithFormat:@"%@ Style", ord[i]], NPPCmdSearchGoPrevMarker1 + i);
        I(jumpDown, [NSString stringWithFormat:@"%@ Style", ord[i]], NPPCmdSearchGoNextMarker1 + i);
    }
    Sep(clear);
    I(clear, @"Clear all Styles", NPPCmdSearchClearAllMarks);
    I(jumpUp, @"Find Mark Style", NPPCmdSearchGoPrevMarkerDef);
    I(jumpDown, @"Find Mark Style", NPPCmdSearchGoNextMarkerDef);
    Sep(search);
    NSMenu *styledClip = Sub(search, @"Copy Styled Text");
    NSArray<NSString *> *ordinals = @[@"1st", @"2nd", @"3rd", @"4th", @"5th"];
    for (NSInteger k = 0; k < (NSInteger)ordinals.count; k++)
        I(styledClip, [ordinals[(NSUInteger)k] stringByAppendingString:@" Style"], NPPCmdSearchStyleToClipBase + k);
    I(styledClip, @"All Styles", NPPCmdSearchAllStylesToClip);
    I(styledClip, @"Find Mark Style", NPPCmdSearchMarkedToClip);
    I(search, @"Find characters in range…", NPPCmdSearchFindCharsInRange);

    NSMenu *bm = Sub(search, @"Bookmark");
    I(bm, @"Toggle Bookmark", NPPCmdSearchToggleBookmark, K(NSF2FunctionKey), CMD);
    I(bm, @"Next Bookmark", NPPCmdSearchNextBookmark, K(NSF2FunctionKey), 0);
    I(bm, @"Previous Bookmark", NPPCmdSearchPrevBookmark, K(NSF2FunctionKey), SHIFT);
    I(bm, @"Clear All Bookmarks", NPPCmdSearchClearBookmarks);
    I(bm, @"Cut Bookmarked Lines", NPPCmdSearchCutBookmarkedLines);
    I(bm, @"Copy Bookmarked Lines", NPPCmdSearchCopyBookmarkedLines);
    I(bm, @"Paste to (Replace) Bookmarked Lines", NPPCmdSearchPasteToBookmarkedLines);
    I(bm, @"Remove Bookmarked Lines", NPPCmdSearchRemoveBookmarkedLines);
    I(bm, @"Remove Non-Bookmarked Lines", NPPCmdSearchRemoveNonBookmarkedLines);
    I(bm, @"Inverse Bookmarks", NPPCmdSearchInverseBookmarks);

    // View
    NSMenu *view = Sub(main, @"View");
    NSMenu *toolbar = Sub(view, @"Toolbar");
    I(toolbar, @"Show Toolbar", NPPCmdViewToolbarShow);
    I(toolbar, @"Customise…", NPPCmdViewToolbarCustomise);
    Sep(toolbar);
    NSArray<NSString *> *iconSets = @[@"Small Icons", @"Large Icons", @"Small Fluent Icons", @"Large Fluent Icons"];
    for (NSInteger k = 0; k < (NSInteger)iconSets.count; k++)
        I(toolbar, iconSets[(NSUInteger)k], NPPCmdViewToolbarIconsBase + k);

    I(view, @"Always on Top", NPPCmdViewAlwaysOnTop);
    I(view, @"Toggle Full Screen Mode", NPPCmdViewFullScreen, @"f", CMD | CTRL);
    I(view, @"Distraction Free Mode", NPPCmdViewDistractionFree);
    Sep(view);
    NSMenu *sym = Sub(view, @"Show Symbol");
    I(sym, @"Show Space and Tab", NPPCmdViewShowSpaceTab);
    I(sym, @"Show End of Line", NPPCmdViewShowEOL);
    I(sym, @"Show All Characters", NPPCmdViewShowAllChars);
    Sep(sym);
    I(sym, @"Show Indent Guide", NPPCmdViewShowIndentGuide);
    I(sym, @"Show Wrap Symbol", NPPCmdViewShowWrapSymbol);
    I(sym, @"Show Non-Printing Characters", NPPCmdViewNonPrintingChars);
    I(sym, @"Show Control Characters and Unicode EOL", NPPCmdViewNPCControlChars);
    NSMenu *zoom = Sub(view, @"Zoom");
    I(zoom, @"Zoom In", NPPCmdViewZoomIn, @"=");
    I(zoom, @"Zoom Out", NPPCmdViewZoomOut, @"-");
    I(zoom, @"Restore Default Zoom", NPPCmdViewZoomRestore, @"0");
    I(zoom, @"Synchronize Across Views", NPPCmdViewZoomSync);
    NSMenu *browser = Sub(view, @"View Current File in");
    I(browser, @"Default Browser", NPPCmdViewInBrowserBase + 0);
    I(browser, @"Safari", NPPCmdViewInBrowserBase + 1);
    I(browser, @"Chrome", NPPCmdViewInBrowserBase + 2);
    I(browser, @"Firefox", NPPCmdViewInBrowserBase + 3);
    I(browser, @"Edge", NPPCmdViewInBrowserBase + 4);

    NSMenu *moveClone = Sub(view, @"Move/Clone Current Document");
    I(moveClone, @"Move to Other View", NPPCmdViewMoveToOtherView);
    I(moveClone, @"Clone to Other View", NPPCmdViewCloneToOtherView);
    I(moveClone, @"Move to New Instance", NPPCmdViewMoveToNewInstance);
    I(moveClone, @"Open in New Instance", NPPCmdViewOpenInNewInstance);
    I(view, @"Focus on Another View", NPPCmdViewSwitchToOtherView, K(NSF8FunctionKey), 0);   // VK_F8, Parameters.cpp:355
    I(view, @"Synchronize Vertical Scrolling", NPPCmdViewSyncScrollVertical);
    I(view, @"Synchronize Horizontal Scrolling", NPPCmdViewSyncScrollHorizontal);
    I(view, @"Rotate to Right", NPPCmdViewRotateRight);
    I(view, @"Rotate to Left", NPPCmdViewRotateLeft);
    I(view, @"Post-It", NPPCmdViewPostIt);

    NSMenu *tab = Sub(view, @"Tab");
    static NSString *const tabOrd[] = {@"1st", @"2nd", @"3rd", @"4th", @"5th", @"6th", @"7th", @"8th", @"9th"};
    for (NSInteger i = 0; i < 9; i++)
        I(tab, [NSString stringWithFormat:@"%@ Tab", tabOrd[i]], NPPCmdViewTab1 + i, [NSString stringWithFormat:@"%ld", (long)(i + 1)]);
    Sep(tab);
    I(tab, @"First Tab", NPPCmdViewTabFirst);
    I(tab, @"Last Tab", NPPCmdViewTabLast);
    I(tab, @"Next Tab", NPPCmdViewTabNext, @"]", CMD | SHIFT);
    I(tab, @"Previous Tab", NPPCmdViewTabPrev, @"[", CMD | SHIFT);
    Sep(tab);
    I(tab, @"Move Tab Forward", NPPCmdViewTabMoveForward);
    I(tab, @"Move Tab Backward", NPPCmdViewTabMoveBackward);
    Sep(tab);
    for (NSInteger i = 0; i < 5; i++) I(tab, [NSString stringWithFormat:@"Apply Color %ld", (long)(i + 1)], NPPCmdViewTabColor1 + i);
    I(tab, @"Remove Color", NPPCmdViewTabColorNone);
    I(view, @"Word wrap", NPPCmdViewWordWrap);
    I(view, @"Hide Lines", NPPCmdViewHideLines);
    Sep(view);
    // Alt+0 / Alt+Shift+0 upstream (Parameters.cpp:357-358), i.e. the Fold/Unfold Level keys below with 0 for "all".
    I(view, @"Fold All", NPPCmdViewFoldAll, @"0", CMD | OPT);
    I(view, @"Unfold All", NPPCmdViewUnfoldAll, @"0", CMD | OPT | SHIFT);
    I(view, @"Fold Current Level", NPPCmdViewFoldCurrent);
    I(view, @"Unfold Current Level", NPPCmdViewUnfoldCurrent);
    I(tab, @"Move to Start", NPPCmdViewTabMoveToStart);
    I(tab, @"Move to End", NPPCmdViewTabMoveToEnd);
    NSMenu *foldL = Sub(view, @"Fold Level");
    NSMenu *unfoldL = Sub(view, @"Unfold Level");
    for (NSInteger i = 0; i < 8; i++) {
        NSString *k = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
        I(foldL, k, NPPCmdViewFoldLevel1 + i, k, CMD | OPT);
        I(unfoldL, k, NPPCmdViewUnfoldLevel1 + i, k, CMD | OPT | SHIFT);
    }
    Sep(view);
    NSMenu *projects = Sub(view, @"Project Panels");
    I(projects, @"Project Panel 1", NPPCmdViewProjectPanel1);
    I(projects, @"Project Panel 2", NPPCmdViewProjectPanel2);
    I(projects, @"Project Panel 3", NPPCmdViewProjectPanel3);
    I(view, @"Folder as Workspace", NPPCmdViewWorkspacePanel);
    I(view, @"Document Map", NPPCmdViewDocumentMap);
    I(view, @"Document List", NPPCmdViewDocumentList);
    I(view, @"Function List", NPPCmdViewFunctionList);
    I(view, @"Clipboard History", NPPCmdViewClipboardHistory);
    I(view, @"Character Panel", NPPCmdViewCharacterPanel);
    Sep(view);
    I(view, @"Summary…", NPPCmdViewSummary);
    Sep(view);
    I(view, @"Monitoring (tail -f)", NPPCmdViewMonitoring);
    Sep(view);
    I(view, @"Text Direction RTL", NPPCmdViewTextDirectionRTL);
    I(view, @"Text Direction LTR", NPPCmdViewTextDirectionLTR);

    // Encoding
    NSMenu *enc = Sub(main, @"Encoding");
    [self populateEncodingMenu:enc];

    // Language
    self.languageMenu = Sub(main, @"Language");
    self.languageMenu.delegate = self;   // rebuilt on open: user-defined languages can be imported at any time
    [self rebuildLanguageMenu];

    // Settings
    NSMenu *settings = self.settingsMenu = Sub(main, @"Settings");
    I(settings, @"Preferences…", NPPCmdSettingsPreferences);
    I(settings, @"Style Configurator…", NPPCmdSettingsStyleConfigurator);
    I(settings, @"Import Style Theme(s)…", NPPCmdSettingsImportStyleTheme);
    I(settings, @"Edit Popup ContextMenu", NPPCmdSettingsEditContextMenu);
    I(settings, @"File Association…", NPPCmdSettingsFileAssociation);
    I(settings, @"Shortcut Mapper…", NPPCmdSettingsShortcutMapper);
    I(settings, @"Restore Unsaved Files…", NPPCmdBackupRestoreNow);
    I(settings, @"Open Backup Folder", NPPCmdBackupOpenFolder);
    self.themeMenu = Sub(settings, @"Style Theme");
    [self rebuildThemeMenu];
    // The UI language list is fixed at launch (the translations ship in the bundle), so unlike the theme menu it is
    // built once. NPPLocalization owns the tags: it validates, checks and switches them through the command table.
    NSArray<NPPUILanguage *> *uiLangs = NPPLocalization.shared.availableLanguages;
    if (uiLangs.count) {
        self.uiLanguageMenu = Sub(settings, @"UI Language");
        for (NSUInteger i = 0; i < uiLangs.count && i < 200; i++)   // 200 = the width of the tag range
            I(self.uiLanguageMenu, uiLangs[i].displayName, NPPCmdSettingsUILanguageBase + (NSInteger)i);
    }

    // Tools
    NSMenu *tools = Sub(main, @"Tools");
    NSArray<NSString *> *algos = @[@"MD5", @"SHA-1", @"SHA-256", @"SHA-512"];
    NSArray<NSString *> *acts = @[@"Generate…", @"Generate from files…", @"Generate from selection into clipboard"];
    for (NSInteger a = 0; a < (NSInteger)algos.count; a++) {
        NSMenu *sub = Sub(tools, algos[(NSUInteger)a]);
        for (NSInteger k = 0; k < (NSInteger)acts.count; k++)
            I(sub, acts[(NSUInteger)k], NPPCmdToolHashBase + a * 3 + k);
    }

    // Macro
    self.macroMenu = Sub(main, @"Macro");
    self.macroMenu.delegate = self;      // rebuilt on open: the saved-macro list is owned by NPPMacroManager
    [self rebuildMacroMenu];

    // Run
    self.runMenu = Sub(main, @"Run");
    self.runMenu.delegate = self;        // rebuilt on open: the saved-command list is owned by NPPRunCommands
    [self rebuildRunMenu];

    // Window
    NSMenu *window = Sub(main, @"Window");
    NSMenu *sortBy = Sub(window, @"Sort By");
    I(sortBy, @"Name A to Z", NPPCmdWindowSortNameAsc);
    I(sortBy, @"Name Z to A", NPPCmdWindowSortNameDesc);
    I(sortBy, @"Path A to Z", NPPCmdWindowSortPathAsc);
    I(sortBy, @"Path Z to A", NPPCmdWindowSortPathDesc);
    I(sortBy, @"Type A to Z", NPPCmdWindowSortTypeAsc);
    I(sortBy, @"Type Z to A", NPPCmdWindowSortTypeDesc);
    I(sortBy, @"Content Length Ascending", NPPCmdWindowSortSizeAsc);
    I(sortBy, @"Content Length Descending", NPPCmdWindowSortSizeDesc);
    I(sortBy, @"Modified Time Ascending", NPPCmdWindowSortDateAsc);
    I(sortBy, @"Modified Time Descending", NPPCmdWindowSortDateDesc);

    I(window, @"Minimize", 0, @"m", CMD, @selector(performMiniaturize:));
    I(window, @"Zoom", 0, @"", 0, @selector(performZoom:));
    Sep(window);
    I(window, @"Bring All to Front", 0, @"", 0, @selector(arrangeInFront:));
    NSApp.windowsMenu = window;

    // Help
    NSMenu *help = Sub(main, @"Help");
    I(help, @"Notepad++ Home", NPPCmdHelpHomepage);
    I(help, @"Notepad++ Project Page", NPPCmdHelpProjectPage);
    I(help, @"Online Documentation", NPPCmdHelpOnlineDocs);
    I(help, @"Community", NPPCmdHelpCommunity);
    Sep(help);
    I(help, @"Command Line Arguments…", NPPCmdHelpCommandLineArgs);
    I(help, @"Debug Info…", NPPCmdHelpDebugInfo);
    Sep(help);
    I(help, @"About Notepad++", NPPCmdHelpAbout);
    NSApp.helpMenu = help;

    return main;
}

- (void)populateEOLMenu:(NSMenu *)m {
    I(m, @"Windows (CR LF)", NPPCmdEditEOLToWindows);
    I(m, @"Unix (LF)", NPPCmdEditEOLToUnix);
    I(m, @"Macintosh (CR)", NPPCmdEditEOLToMac);
}

- (void)populateEncodingMenu:(NSMenu *)enc {
    I(enc, @"ANSI", NPPCmdEncodingANSI);
    I(enc, @"UTF-8", NPPCmdEncodingUTF8);
    I(enc, @"UTF-8-BOM", NPPCmdEncodingUTF8BOM);
    I(enc, @"UTF-16 BE BOM", NPPCmdEncodingUTF16BE);
    I(enc, @"UTF-16 LE BOM", NPPCmdEncodingUTF16LE);
    NSMenu *charsets = Sub(enc, @"Character sets");
    NSMutableDictionary<NSString *, NSMenu *> *groups = [NSMutableDictionary dictionary];
    NSArray<NPPCharset *> *all = NPPCharset.allCharsets;
    for (NSUInteger i = 0; i < all.count; i++) {
        NPPCharset *cs = all[i];
        NSMenu *g = groups[cs.groupName];
        if (!g) groups[cs.groupName] = g = Sub(charsets, cs.groupName);
        I(g, cs.displayName, NPPCmdEncodingCharsetBase + (NSInteger)i);
    }
    Sep(enc);
    I(enc, @"Convert to ANSI", NPPCmdEncodingConvertToANSI);
    I(enc, @"Convert to UTF-8", NPPCmdEncodingConvertToUTF8);
    I(enc, @"Convert to UTF-8-BOM", NPPCmdEncodingConvertToUTF8BOM);
    I(enc, @"Convert to UTF-16 BE BOM", NPPCmdEncodingConvertToUTF16BE);
    I(enc, @"Convert to UTF-16 LE BOM", NPPCmdEncodingConvertToUTF16LE);
}

- (NSMenu *)eolMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"EOL"];
    [self populateEOLMenu:m];
    return m;
}

- (NSMenu *)encodingMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Encoding"];
    [self populateEncodingMenu:m];
    return m;
}

// Upstream NppParameters::putRecentFileInSubMenu(): off (the default) leaves the list in the File menu itself,
// on moves it into "Open Recent". The submenu's item is hidden rather than removed, so the File menu keeps its own
// layout either way and the two modes can be flipped from Preferences without rebuilding the whole menu bar. The
// entries carry the same tags in both places, so -nppCommand:/-validateMenuItem: never have to care which it is.
// A class method taking both menus, so +selfCheckFailures drives this placement rather than a copy of it.
+ (void)populateRecentFilesInFileMenu:(NSMenu *)file submenu:(NSMenu *)recentSubmenu {
    if (!file || !recentSubmenu) return;
    NPPPreferences *prefs = NPPPreferences.shared;
    BOOL inSubmenu = prefs.recentFilesInSubmenu;

    [recentSubmenu removeAllItems];
    for (NSInteger i = file.numberOfItems - 1; i >= 0; i--)          // whatever the previous rebuild left inline
        if ([[file itemAtIndex:i].representedObject isEqual:kRecentInline]) [file removeItemAtIndex:i];
    NSInteger host = [file indexOfItemWithSubmenu:recentSubmenu];
    if (host >= 0) [file itemAtIndex:host].hidden = !inSubmenu;

    NSMenu *dest = inSubmenu ? recentSubmenu : file;
    NSInteger firstAdded = dest.numberOfItems;
    if (!inSubmenu) Sep(dest);                                       // detach the list from the File menu's own items
    NSArray<NSString *> *recent = prefs.recentFilePaths;
    for (NSUInteger i = 0; i < recent.count && i < 99; i++)          // 99 = the width of the tag range
        I(dest, [prefs recentFileMenuTitleForPath:recent[i]], NPPCmdFileRecentBase + (NSInteger)i);
    if (recent.count) Sep(dest);
    I(dest, @"Clear Recent", NPPCmdFileClearRecent);
    if (!inSubmenu)
        for (NSInteger i = firstAdded; i < dest.numberOfItems; i++) [dest itemAtIndex:i].representedObject = kRecentInline;
}

- (void)rebuildRecentFilesMenu {
    [NPPAppDelegate populateRecentFilesInFileMenu:self.fileMenu submenu:self.recentMenu];
}

// N++ ships two Language menus and throws one away at startup (Notepad_plus::init): the flat list, or the compact
// one that files every language under a submenu named for its initial. The excluded languages are then deleted from
// whichever survived, and a submenu left empty by that goes with them — here nothing empty is ever created.
// The tag stays NPPCmdLanguageBase + the language's index in -languages, which is what the window controller
// resolves it back through, so hiding an entry must never renumber the others.
- (void)rebuildLanguageMenu {
    NSMenu *m = self.languageMenu;
    if (!m) return;
    [m removeAllItems];
    NPPPreferences *prefs = NPPPreferences.shared;
    NSSet<NSString *> *excluded = [NSSet setWithArray:prefs.excludedLanguageNames ?: @[]];
    BOOL compact = prefs.languageMenuCompact;
    NSMutableDictionary<NSString *, NSMenu *> *groups = [NSMutableDictionary dictionary];
    NSArray<NPPLanguage *> *langs = NPPLanguageManager.shared.languages;
    for (NSUInteger i = 0; i < langs.count; i++) {
        NPPLanguage *l = langs[i];
        BOOL normal = [l.name isEqualToString:@"normal"];
        // Normal Text is never hidden: it is the way back from every other language.
        if (!normal && ([excluded containsObject:l.name] || [excluded containsObject:l.shortName])) continue;
        NSString *title = normal ? @"None (Normal Text)" : l.shortName;
        NSMenu *dest = m;
        if (compact && !normal && title.length) {
            NSString *initial = [title substringToIndex:1].uppercaseString;
            dest = groups[initial];
            if (!dest) { dest = Sub(m, initial); groups[initial] = dest; }
        }
        I(dest, title, NPPCmdLanguageBase + (NSInteger)i);
        if (normal && langs.count > 1) Sep(m);
    }
    Sep(m);
    NSArray<NSString *> *udls = [self userDefinedLanguageNames];
    if (udls.count) {
        NSMenu *ud = Sub(m, @"User-Defined");
        for (NSUInteger i = 0; i < udls.count && i < 99; i++) I(ud, udls[i], NPPCmdLangUserDefinedBase + (NSInteger)i);
    }
    I(m, @"Define your language…", NPPCmdLangDefineDialog);
    I(m, @"Import User-Defined Language…", NPPCmdLangImportUDL);
    I(m, @"Export User-Defined Language…", NPPCmdLangExportUDL);
    // These two are ours, and their tags sit outside the range the window controller forwards to us: claiming the
    // items short-circuits the responder chain so both the click and the validation land here.
    I(m, @"Open User Defined Language Folder…", NPPCmdLangOpenUDLFolder).target = self;
    I(m, @"Notepad++ User Defined Languages Collection", NPPCmdLangUDLCollectionSite).target = self;
    // The status bar pops its own copy of this menu, and only the main menu gets -menuNeedsUpdate:. Re-copying here
    // is what makes an imported UDL — or a change to either language preference — reach both language pickers.
    if (self.mainWindowController.statusBar) self.mainWindowController.statusBar.docTypeMenu = [m copy];
}

// ~/Library/Application Support/Notepad++/userDefineLangs, owned by the UDL module (which may not be linked in).
- (NSURL *)userDefinedLanguageDirectory {
    Class c = NSClassFromString(@"NPPUserDefinedLanguages");
    if (![c respondsToSelector:@selector(shared)]) return nil;
    id mgr = [c performSelector:@selector(shared)];
    if (![mgr respondsToSelector:@selector(userLanguageDirectory)]) return nil;
    id dir = [mgr performSelector:@selector(userLanguageDirectory)];
    return [dir isKindOfClass:NSURL.class] ? dir : nil;
}

// Dynamic menus fed by the feature modules. They are rebuilt whenever the module says its list changed
// (NPPFeatureListsDidChangeNotification) and are empty-but-present when a module is unavailable.
- (NSArray<NSString *> *)userDefinedLanguageNames {
    Class c = NSClassFromString(@"NPPUserDefinedLanguages");
    if (![c respondsToSelector:@selector(shared)]) return @[];
    id mgr = [c performSelector:@selector(shared)];
    return [mgr respondsToSelector:@selector(languageNames)] ? [mgr performSelector:@selector(languageNames)] : @[];
}

- (void)rebuildMacroMenu {
    NSMenu *m = self.macroMenu;
    if (!m) return;
    [m removeAllItems];
    I(m, @"Start Recording", NPPCmdMacroStartRecording);
    I(m, @"Stop Recording", NPPCmdMacroStopRecording);
    // The N++ macro loop is Ctrl+Shift+R, edit, Ctrl+Shift+R, Ctrl+Shift+P — one key that records and then stops.
    // Upstream spends a separate command on it (see NPPCmdMacroToggleRecording); the two items above are the ones
    // that do the work, and this one is the key that reaches them. Ours, like the two UDL items in the Language menu.
    I(m, @"Toggle Recording", NPPCmdMacroToggleRecording, @"r", CMD | SHIFT).target = self;
    I(m, @"Playback", NPPCmdMacroPlayback, @"p", CMD | SHIFT);
    I(m, @"Save Current Recorded Macro…", NPPCmdMacroSaveCurrent);
    Sep(m);
    I(m, @"Run a Macro Multiple Times…", NPPCmdMacroRunMultiple);
    I(m, @"Modify or Delete Macro…", NPPCmdMacroModifyShortcuts);
    Class c = NSClassFromString(@"NPPMacroManager");
    id mgr = [c respondsToSelector:@selector(shared)] ? [c performSelector:@selector(shared)] : nil;
    NSArray<NSString *> *names = [mgr respondsToSelector:@selector(savedMacroNames)] ? [mgr performSelector:@selector(savedMacroNames)] : @[];
    if (names.count) {
        Sep(m);
        for (NSUInteger i = 0; i < names.count && i < 99; i++) I(m, names[i], NPPCmdMacroSavedBase + (NSInteger)i);
    }
}

- (void)rebuildRunMenu {
    NSMenu *m = self.runMenu;
    if (!m) return;
    [m removeAllItems];
    I(m, @"Run…", NPPCmdRunDialog, K(NSF5FunctionKey), 0);   // VK_F5 upstream (Parameters.cpp:482); ⇧⌘R is the macro key
    I(m, @"Modify or Delete Command…", NPPCmdRunModifyCommands);
    Class c = NSClassFromString(@"NPPRunCommands");
    id mgr = [c respondsToSelector:@selector(shared)] ? [c performSelector:@selector(shared)] : nil;
    NSArray<NSString *> *names = [mgr respondsToSelector:@selector(savedCommandNames)] ? [mgr performSelector:@selector(savedCommandNames)] : @[];
    if (names.count) {
        Sep(m);
        for (NSUInteger i = 0; i < names.count && i < 99; i++) I(m, names[i], NPPCmdRunSavedBase + (NSInteger)i);
    }
}

- (void)rebuildThemeMenu {
    NSMenu *m = self.themeMenu;
    if (!m) return;
    [m removeAllItems];
    I(m, @"Follow System Appearance", NPPCmdSettingsThemeBase);
    Sep(m);
    NSArray<NSString *> *names = NPPLanguageManager.shared.availableThemeNames;
    for (NSUInteger i = 0; i < names.count && i < 99; i++) I(m, names[i], NPPCmdSettingsThemeBase + 1 + (NSInteger)i);
}

#pragma mark - NSMenuDelegate (menus whose contents come from a feature module)

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.macroMenu) [self rebuildMacroMenu];
    else if (menu == self.runMenu) [self rebuildRunMenu];
    else if (menu == self.languageMenu) [self rebuildLanguageMenu];
}

// ponytail: NPPLocalization still appends a second copy of the UI Language submenu from -contextDidBecomeReady:
// (its owner has been asked to drop -attachLanguageMenuIfNeeded now that the menu is built here). Until that lands,
// the stray copy is dropped right after the notification that creates it — not on menu open, so that the menu-bar
// sweep and any screenshot see one submenu too. Delete this and its call in -ensureWindow with it.
- (void)dropDuplicateUILanguageMenus {
    NSMenu *m = self.settingsMenu;
    for (NSInteger i = m.numberOfItems - 1; i >= 0; i--) {
        NSMenu *sub = [m itemAtIndex:i].submenu;
        if (!sub || sub == self.uiLanguageMenu || sub.numberOfItems == 0) continue;
        NSInteger tag = [sub itemAtIndex:0].tag;
        if (tag >= NPPCmdSettingsUILanguageBase && tag < NPPCmdSettingsUILanguageBase + 200) [m removeItemAtIndex:i];
    }
}

#pragma mark - commands

- (void)nppCommand:(id)sender {
    NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    NPPPreferences *prefs = NPPPreferences.shared;

    if (tag >= NPPCmdSettingsThemeBase && tag < NPPCmdSettingsThemeBase + 100) {
        NSInteger i = tag - NPPCmdSettingsThemeBase;
        NSArray<NSString *> *names = NPPLanguageManager.shared.availableThemeNames;
        prefs.themeName = (i == 0 || i - 1 >= (NSInteger)names.count) ? @"" : names[i - 1];
        [self applyThemePreference];
        return;
    }
    if (tag >= NPPCmdFileRecentBase && tag < NPPCmdFileClearRecent) {
        NSInteger i = tag - NPPCmdFileRecentBase;
        NSArray<NSString *> *recent = prefs.recentFilePaths;
        if (i < (NSInteger)recent.count) [self openFileURLs:@[[NSURL fileURLWithPath:recent[i]]]];
        return;
    }
    switch (tag) {
        // Handled here as well as through NPPEditCommands' own dispatch: when the find panel is key the window
        // controller is out of the responder chain, and its route needs a current editor this one does not.
        case NPPCmdEditClipboardCut:
        case NPPCmdEditClipboardCopy:
            [NPPEditCommands performClipboardCommand:(NPPCmd)tag sender:sender];
            return;
        case NPPCmdFileNew:
            [self ensureWindow];
            [self.mainWindowController newDocument];
            return;
        case NPPCmdFileOpen:
            [self ensureWindow];
            [self.mainWindowController nppCommand:sender];   // window owns the NSOpenPanel
            return;
        case NPPCmdFileClearRecent:
            [prefs clearRecentFiles];
            [self rebuildRecentFilesMenu];
            return;
        case NPPCmdSettingsPreferences:
            [NPPPreferences showPreferencesWindow];
            return;
        case NPPCmdHelpAbout: {
            NSAttributedString *credits = [[NSAttributedString alloc] initWithString:
                @"Notepad++ v8.9.8 for macOS\nA native port built on Scintilla 5.6.6 and Lexilla 5.5.3 from the Notepad++ source tree.\nNotepad++ © 2003-2026 Don HO — GPL-3.0"];
            [NSApp orderFrontStandardAboutPanelWithOptions:@{
                NSAboutPanelOptionCredits: credits,
                NSAboutPanelOptionApplicationName: @"Notepad++",
                NSAboutPanelOptionApplicationVersion: @"8.9.8",
            }];
            return;
        }
        // IDM_LANG_OPENUDLDIR: N++ ShellExecutes the folder; Finder opens it the same way.
        case NPPCmdLangOpenUDLFolder: {
            NSURL *dir = [self userDefinedLanguageDirectory];
            if (!dir || ![NSWorkspace.sharedWorkspace openURL:dir]) NSBeep();
            return;
        }
        case NPPCmdMacroToggleRecording: {
            NSInteger live = [self liveMacroRecordingCommand];
            if (!live) { NSBeep(); return; }
            NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(nppCommand:) keyEquivalent:@""];
            it.tag = live;
            [self.mainWindowController nppCommand:it];
            return;
        }
        case NPPCmdLangUDLCollectionSite:   // IDM_LANG_UDLCOLLECTION_PROJECT_SITE
            [self openURLString:@"https://github.com/notepad-plus-plus/userDefinedLanguages"]; return;
        case NPPCmdHelpHomepage:    [self openURLString:@"https://notepad-plus-plus.org/"]; return;
        case NPPCmdHelpProjectPage: [self openURLString:@"https://github.com/notepad-plus-plus/notepad-plus-plus"]; return;
        case NPPCmdHelpOnlineDocs:  [self openURLString:@"https://npp-user-manual.org/"]; return;
        case NPPCmdHelpCommunity:   [self openURLString:@"https://community.notepad-plus-plus.org/"]; return;
        default:
            // The find panel may be key, so the window controller isn't in the responder chain: forward explicitly.
            if (self.mainWindowController) [self.mainWindowController nppCommand:sender];
            else NSBeep();
    }
}

// Which half of the record/stop pair ⇧⌘R means right now. NPPMacroManager enables exactly one of the two (Start
// needs a document and no recording in progress, Stop needs one in progress), so asking them is the whole toggle —
// no recording state of our own to get out of step with theirs. 0 = neither, i.e. nothing to toggle.
- (NSInteger)liveMacroRecordingCommand {
    NPPEditorWindowController *wc = self.mainWindowController;
    if (!wc) return 0;
    NSMenuItem *probe = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(nppCommand:) keyEquivalent:@""];
    probe.tag = NPPCmdMacroStopRecording;
    if ([wc validateMenuItem:probe]) return NPPCmdMacroStopRecording;
    probe.tag = NPPCmdMacroStartRecording;
    return [wc validateMenuItem:probe] ? NPPCmdMacroStartRecording : 0;
}

// Asked on every key-window change: can -nppCommand: still reach anything from these items? The question is put to
// AppKit itself rather than guessed from NSApp.modalWindow, so a context nobody thought of answers it correctly too.
- (void)syncClipboardMenuItems {
    NSMenuItem *probe = self.clipboardCutItem ?: self.clipboardCopyItem;
    if (!probe) return;
    BOOL deliverable = [NSApp targetForAction:@selector(nppCommand:) to:nil from:probe] != nil;
    SetClipboardItemAction(self.clipboardCutItem, deliverable);
    SetClipboardItemAction(self.clipboardCopyItem, deliverable);
}

- (void)openURLString:(NSString *)s {
    NSURL *u = [NSURL URLWithString:s];
    if (u) [NSWorkspace.sharedWorkspace openURL:u];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action != @selector(nppCommand:)) return YES;
    NSInteger tag = item.tag;
    if (tag >= NPPCmdSettingsThemeBase && tag < NPPCmdSettingsThemeBase + 100) {
        NSString *pref = NPPPreferences.shared.themeName;
        NSInteger i = tag - NPPCmdSettingsThemeBase;
        BOOL on = (i == 0) ? pref.length == 0 : [item.title isEqualToString:pref];
        item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (tag >= NPPCmdFileRecentBase && tag < NPPCmdFileClearRecent) return YES;
    switch (tag) {
        case NPPCmdEditClipboardCut:
        case NPPCmdEditClipboardCopy:
            return [NPPEditCommands canPerformClipboardCommand:(NPPCmd)tag];
        case NPPCmdFileNew: case NPPCmdFileOpen: case NPPCmdSettingsPreferences:
        case NPPCmdHelpAbout: case NPPCmdHelpHomepage: case NPPCmdHelpProjectPage: case NPPCmdHelpOnlineDocs: case NPPCmdHelpCommunity:
        case NPPCmdLangUDLCollectionSite:
            return YES;
        case NPPCmdLangOpenUDLFolder:
            return [self userDefinedLanguageDirectory] != nil;   // no UDL module linked in = no folder to open
        case NPPCmdMacroToggleRecording:
            return [self liveMacroRecordingCommand] != 0;
        case NPPCmdFileClearRecent:
            return NPPPreferences.shared.recentFilePaths.count > 0;
        default:
            return self.mainWindowController ? [self.mainWindowController validateMenuItem:item] : NO;
    }
}

#pragma mark - Headless checks (NPPSelfTest calls +selfCheckFailures)

// AppKit hands a key equivalent to the FIRST item that carries it and stops there even when that item is disabled
// (measured with -performKeyEquivalent:, both auto-enabled and manually enabled menus). So a key on two items is a
// key that dies as soon as the first of them is unavailable — an item that looks live and does nothing. These three
// walk a menu tree that was really built, so the check below inspects the items, not a copy of the table.
static NSMenuItem *NPPFindItemWithTag(NSMenu *menu, NSInteger tag) {
    for (NSMenuItem *it in menu.itemArray) {
        if (it.submenu) { NSMenuItem *found = NPPFindItemWithTag(it.submenu, tag); if (found) return found; }
        else if (it.tag == tag && it.action) return it;
    }
    return nil;
}

// ⇧⌘S and ⌘"S" are one keystroke to AppKit: an uppercase key equivalent carries the shift itself.
static NSString *NPPKeySignature(NSMenuItem *item) {
    NSString *key = item.keyEquivalent;
    if (!key.length) return nil;
    NSEventModifierFlags mods = item.keyEquivalentModifierMask;
    if (![key.lowercaseString isEqualToString:key]) mods |= SHIFT;
    return [NSString stringWithFormat:@"%@ %lu", key.lowercaseString, (unsigned long)(mods & (CMD | SHIFT | OPT | CTRL))];
}

static void NPPCollectKeyClashes(NSMenu *menu, NSMutableDictionary<NSString *, NSString *> *taken,
                                 NSMutableArray<NSString *> *out) {
    if ([menu.title isEqualToString:@"Services"]) return;   // AppKit fills that one; its keys are the system's, not ours
    for (NSMenuItem *it in menu.itemArray) {
        if (it.submenu) { NPPCollectKeyClashes(it.submenu, taken, out); continue; }
        NSString *sig = NPPKeySignature(it);
        if (!sig) continue;
        if (taken[sig])
            [out addObject:[NSString stringWithFormat:@"\"%@\" and \"%@\" carry the same key equivalent, so the second never gets it",
                            taken[sig], it.title]];
        else taken[sig] = it.title ?: @"";
    }
}

// Drives +populateRecentFilesInFileMenu:submenu: — the real placement code — against menus built here, so
// NSApp.mainMenu is untouched and this runs under --selftest, where no delegate instance exists at all.
+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *f = [NSMutableArray array];
    NPPPreferences *prefs = NPPPreferences.shared;
    NSArray<NSString *> *savedPaths = prefs.recentFilePaths;
    BOOL savedInSubmenu = prefs.recentFilesInSubmenu;
    NPPRecentFilesDisplay savedDisplay = prefs.recentFilesDisplay;

    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    I(file, @"New", NPPCmdFileNew);
    NSMenu *recent = Sub(file, @"Open Recent");
    NSInteger ownItems = file.numberOfItems;          // the File menu's own items, before any recent entry
    NSMenuItem *hostItem = [file itemAtIndex:[file indexOfItemWithSubmenu:recent]];
    NSArray<NSString *> *paths = @[@"/npp-selfcheck/deep/alpha.cpp", @"/npp-selfcheck/beta.txt"];
    prefs.recentFilePaths = paths;

    // ---- off: the list belongs to the File menu itself ----------------------------------------------------------
    prefs.recentFilesInSubmenu = NO;
    prefs.recentFilesDisplay = NPPRecentFilesDisplayFileName;
    [self populateRecentFilesInFileMenu:file submenu:recent];
    if (recent.numberOfItems)
        [f addObject:@"the recent list is inline, but \"Open Recent\" was filled in as well"];
    if (!hostItem.hidden)
        [f addObject:@"the recent list is inline, but the empty \"Open Recent\" item is still shown"];
    NSMenuItem *first = [file itemWithTag:NPPCmdFileRecentBase];
    if (!first) [f addObject:@"no recent file reached the File menu with the submenu preference off"];
    else if (![first.title isEqualToString:@"alpha.cpp"])
        [f addObject:[NSString stringWithFormat:@"recent labels ignore Recent Files History ▸ display: \"%@\"", first.title]];
    if (![file itemWithTag:NPPCmdFileClearRecent])
        [f addObject:@"Clear Recent did not follow the list into the File menu"];
    NSInteger inlineItems = file.numberOfItems;
    [self populateRecentFilesInFileMenu:file submenu:recent];   // a rebuild must replace the list, not stack a copy
    if (file.numberOfItems != inlineItems)
        [f addObject:[NSString stringWithFormat:@"rebuilding the inline recent list changed the File menu from %ld items to %ld",
                      (long)inlineItems, (long)file.numberOfItems]];

    prefs.recentFilesDisplay = NPPRecentFilesDisplayFullPath;
    [self populateRecentFilesInFileMenu:file submenu:recent];
    if (![[file itemWithTag:NPPCmdFileRecentBase].title isEqualToString:paths[0]])
        [f addObject:@"switching the display setting to Full Path did not relabel the recent entries"];

    // ---- on: the same list, in the submenu, and nothing of it left behind ---------------------------------------
    prefs.recentFilesInSubmenu = YES;
    [self populateRecentFilesInFileMenu:file submenu:recent];
    if (file.numberOfItems != ownItems)
        [f addObject:[NSString stringWithFormat:@"moving the recent list into its submenu left %ld item(s) in the File menu",
                      (long)(file.numberOfItems - ownItems)]];
    if (hostItem.hidden)
        [f addObject:@"the recent list is in \"Open Recent\", but that item is hidden"];
    if (![recent itemWithTag:NPPCmdFileRecentBase] || ![recent itemWithTag:NPPCmdFileClearRecent])
        [f addObject:@"the recent list is in a submenu, but the submenu is missing its entries"];

    prefs.recentFilePaths = savedPaths;
    prefs.recentFilesInSubmenu = savedInSubmenu;
    prefs.recentFilesDisplay = savedDisplay;

    // ---- Edit ▸ Cut / Copy: the fallback that keeps them alive where -nppCommand: cannot be delivered. Drives the
    // ---- real switch on real items; if it stops handing back cut:/copy:, Cut and Copy go dead inside every
    // ---- app-modal name prompt, and if it stops restoring -nppCommand: the preference stops applying at all.
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *cut = I(edit, @"Cut", NPPCmdEditClipboardCut, @"x");
    NSMenuItem *copy = I(edit, @"Copy", NPPCmdEditClipboardCopy, @"c");
    for (NSMenuItem *it in @[cut, copy]) {
        SEL want = (it.tag == NPPCmdEditClipboardCut) ? @selector(cut:) : @selector(copy:);
        SetClipboardItemAction(it, NO);
        if (it.action != want)
            [f addObject:[NSString stringWithFormat:@"\"%@\" keeps %@ where -nppCommand: cannot be delivered, so it would be swallowed",
                          it.title, NSStringFromSelector(it.action)]];
        SetClipboardItemAction(it, YES);
        if (it.action != @selector(nppCommand:))
            [f addObject:[NSString stringWithFormat:@"\"%@\" does not go back to -nppCommand: once it can be delivered", it.title]];
        if (it.tag != (it == cut ? NPPCmdEditClipboardCut : NPPCmdEditClipboardCopy))
            [f addObject:[NSString stringWithFormat:@"\"%@\" lost its tag while its action was swapped", it.title]];
    }

    // ---- the gestures Notepad++ taught, on the menu bar this class really builds. A feature whose key is gone is a
    // ---- feature its user cannot find, so these assert the items and their keys, not that the commands exist.
    NSMenu *savedServices = NSApp.servicesMenu, *savedWindows = NSApp.windowsMenu, *savedHelp = NSApp.helpMenu;
    NSMenu *bar = [[NPPAppDelegate new] makeMainMenu];   // built, never installed: NSApp.mainMenu is the one the
    NSApp.servicesMenu = savedServices;                  // shortcut mapper and the localizer follow, and --selftest
    NSApp.windowsMenu = savedWindows;                    // runs before any of it exists.
    NSApp.helpMenu = savedHelp;

    NSArray<NSArray *> *keys = @[
        @[@(NPPCmdSearchResultsNext),     K(NSF4FunctionKey), @(0),                 @"F4"],
        @[@(NPPCmdSearchResultsPrevious), K(NSF4FunctionKey), @(SHIFT),             @"Shift-F4"],
        @[@(NPPCmdRunDialog),             K(NSF5FunctionKey), @(0),                 @"F5"],
        @[@(NPPCmdViewSwitchToOtherView), K(NSF8FunctionKey), @(0),                 @"F8"],
        @[@(NPPCmdMacroToggleRecording),  @"r",               @(CMD | SHIFT),       @"Cmd-Shift-R (Ctrl+Shift+R)"],
        @[@(NPPCmdEditColumnEditor),      @"c",               @(CMD | OPT),         @"Cmd-Opt-C (Alt+C)"],
        @[@(NPPCmdViewFoldAll),           @"0",               @(CMD | OPT),         @"Cmd-Opt-0 (Alt+0)"],
        @[@(NPPCmdViewUnfoldAll),         @"0",               @(CMD | OPT | SHIFT), @"Cmd-Opt-Shift-0 (Alt+Shift+0)"],
    ];
    for (NSArray *want in keys) {
        NSInteger tag = [want[0] integerValue];
        NSMenuItem *it = NPPFindItemWithTag(bar, tag);
        if (!it) { [f addObject:[NSString stringWithFormat:@"no menu item runs command %ld, so %@ reaches nothing", (long)tag, want[3]]]; continue; }
        if (![it.keyEquivalent isEqualToString:want[1]] ||
            it.keyEquivalentModifierMask != (NSEventModifierFlags)[want[2] unsignedIntegerValue])
            [f addObject:[NSString stringWithFormat:@"\"%@\" no longer answers %@", it.title, want[3]]];
    }
    // ⇧⌘R only toggles because exactly one item carries it; the same holds for every other key in the bar.
    NPPCollectKeyClashes(bar, [NSMutableDictionary dictionary], f);
    return f;
}

- (void)dealloc {
    if (_observingAppearance) [NSApp removeObserver:self forKeyPath:@"effectiveAppearance"];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
