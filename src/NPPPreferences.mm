// NPPPreferences.mm — NSUserDefaults-backed settings, the Preferences window, the Style Configurator,
// the editor context-menu editor and file association. See the header for the two apply paths.
#import "NPPPreferences.h"
#import "NPPLanguageManager.h"
#import "NPPTabBarView.h"
#import "NPPStatusBarView.h"
#import "NPPUtils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>          // the self-check walks the declared properties
#import "NPPEditCommands.h"
#include "Scintilla.h"

NSNotificationName const NPPPreferencesDidChangeNotification = @"NPPPreferencesDidChangeNotification";

// The private command block in the header has to stay clear of NPPEditCommands' (13000/13001), which is itself
// above every range NPPCommands.h declares.
static_assert((NSInteger)NPPCmdEditCopyLink > (NSInteger)NPPCmdEditClipboardCopy,
              "NPPCmdEditCopyLink collides with NPPEditCommands' tags");

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *const kDefaultThemeName = @"Default (stylers.xml)";
static NSString *const kCustomisedDefaultThemeName = @"Default (customised)";

// The main window controller's chrome. NPPEditorWindowController.h is deliberately not imported (a feature module
// talks to the window through id<NPPCommandContext>), but the three accessors below have to be type-checked, so
// they are declared here and reached by -respondsToSelector: on the context.
@protocol NPPPrefsWindowChrome <NSObject>
- (NPPTabBarView *)tabBar;
- (NPPStatusBarView *)statusBar;
- (void)layoutContent;
@end

@interface NPPPreferencesWindowController : NSWindowController
+ (instancetype)shared;
- (void)selectPageNamed:(NSString *)name;
- (void)refresh;      // re-reads every control through KVC; the self-check calls it to prove the identifiers exist
// For the self-check: a setting with no control is invisible, and a control the port cannot honour must be disabled
// rather than quietly missing. Both are things only the built window can answer.
- (NSSet<NSString *> *)controlIdentifiers;
- (BOOL)everyControlDisabledForIdentifier:(NSString *)key;
@end

@interface NPPStyleConfiguratorController : NSWindowController
+ (instancetype)shared;
- (void)loadCurrentTheme;   // what -showWindow: does; the self-check fills the lists with it instead of showing one
@end

@interface NPPContextMenuEditorController : NSWindowController
+ (instancetype)shared;
@end

@interface NPPFileAssociationController : NSWindowController
+ (instancetype)shared;
@end

// The file-association table, shared by the Preferences page and the Settings > File Association… window.
@interface NPPFileAssociationView : NSView
@end

#pragma mark - Small shared helpers

// N++ NppGUI::_uriSchemes. NPPDocument keeps the same list as its own fallback for the NPPUriSchemes key; the two
// have to agree or registering this one would change which links it marks.
static NSString *NPPDefaultUriSchemes(void) {
    return @"svn:// cvs:// git:// imap:// irc:// irc6:// ircs:// ldap:// ldaps:// "
            "news: telnet:// gopher:// ssh:// sftp:// smb:// skype: snmp:// "
            "spotify: steam:// sms: slack:// chrome:// bitcoin:";
}

static NSColor *NPPColorFromHexString(NSString *hex) {
    return NPPNSColorFromSci(NPPColorFromHex(hex.length ? hex : @"000000"));
}
static NSString *NPPHexStringFromColor(NSColor *c) {
    long bgr = NPPSciColorFromNSColor(c);
    return [NSString stringWithFormat:@"%02lX%02lX%02lX", bgr & 0xFF, (bgr >> 8) & 0xFF, (bgr >> 16) & 0xFF];
}

// ~/Library/Application Support/Notepad++/<sub>, created on demand. Same root NPPBackupManager uses.
static NSURL *NPPSupportSubdirectory(NSString *sub) {
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                             appropriateForURL:nil create:YES error:nil];
    if (!base) return nil;
    NSURL *dir = [[base URLByAppendingPathComponent:@"Notepad++" isDirectory:YES] URLByAppendingPathComponent:sub isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir checkResourceIsReachableAndReturnError:nil] ? dir : nil;
}

static NSURL *NPPBundleThemesDirectory(void) {
    NSString *p = NSBundle.mainBundle.resourcePath;
    return p ? [NSURL fileURLWithPath:[p stringByAppendingPathComponent:@"themes"] isDirectory:YES] : nil;
}

// The bundled themes directory is inside the app bundle, which is read-only once the app is installed, so an
// imported or edited theme has to go somewhere else: a writable directory under Application Support, registered
// with NPPLanguageManager -addThemeSearchDirectory:. That folder is searched *before* the bundled one, so both
// sets show up in -availableThemeNames and a saved copy shadows the bundled theme of the same name.
static NSURL *gUserThemesDir = nil;
static BOOL gUserThemesFailed = NO;      // do not redo the filesystem work on every menu validation
static BOOL NPPActivateUserThemesDirectory(void) {
    if (gUserThemesDir) return YES;
    if (gUserThemesFailed) return NO;
    gUserThemesFailed = YES;             // cleared again only on the success path below
    NSURL *dir = NPPSupportSubdirectory(@"themes");
    if (!dir) return NO;
    // Versions that could register only one search directory seeded this one with symlinks to every bundled theme.
    // The bundled folder is searched on its own now, so those links are redundant — harmless while they resolve,
    // but one left behind by a theme since dropped from the bundle lists a theme that cannot be read. Only the
    // dangling ones go: a live symlink may be the user's own (ln -s ~/dotfiles/mytheme.xml) and deleting that
    // would make their theme vanish from the list.
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSURL *u in [fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil])
        if ([fm destinationOfSymbolicLinkAtPath:u.path error:nil] && ![u checkResourceIsReachableAndReturnError:nil])
            [fm removeItemAtURL:u error:nil];
    [NPPLanguageManager.shared addThemeSearchDirectory:dir];
    gUserThemesDir = dir;
    gUserThemesFailed = NO;
    return YES;
}

// Where an imported or edited theme is written. nil until NPPActivateUserThemesDirectory() has succeeded, which
// both callers check first.
static NSURL *NPPThemesDirectory(void) { return gUserThemesDir; }

// The file NPPLanguageManager would read for this theme name: the user directory shadows the bundled one.
// ponytail: this repeats -themeFileURLNamed:, which is private to that class. Publish it there if a third search
// directory is ever added — this copy would silently miss it.
static NSURL *NPPThemeFileURL(NSString *name) {
    if (name.length == 0 || [name isEqualToString:kDefaultThemeName])
        return [NSBundle.mainBundle URLForResource:@"stylers.model" withExtension:@"xml"];
    NSString *file = [name stringByAppendingPathExtension:@"xml"];
    NSURL *user = [gUserThemesDir URLByAppendingPathComponent:file];
    if ([user checkResourceIsReachableAndReturnError:nil]) return user;
    return [NPPBundleThemesDirectory() URLByAppendingPathComponent:file];
}

// A module that may not be linked in: NPPAutoCompletion and NPPBackupManager both own their own defaults keys and
// reschedule/re-read on their setters, so the pages proxy through the shared instance instead of writing the keys.
static id NPPModuleShared(NSString *className) {
    Class c = NSClassFromString(className);
    return [c respondsToSelector:@selector(shared)] ? [c performSelector:@selector(shared)] : nil;
}

#pragma mark - Property plumbing

// Internals, declared up front so the C helpers below can call them.
@interface NPPPreferences () <NSMenuDelegate>
- (void)attachToContext:(id)context;
- (void)currentDocumentDidChange:(id)context;
- (void)applyLiveSettings;
- (void)applyLiveSettingsToDocument:(NPPDocument *)doc;
- (void)applyDefaultCodepageToDocument:(NPPDocument *)doc;
- (void)applyLiveSettingsToEditor:(ScintillaView *)ed languageName:(nullable NSString *)languageName;
- (void)applyLanguageSensitiveSettingsToEditor:(ScintillaView *)ed languageName:(nullable NSString *)languageName;
- (NSMenu *)cachedEditorContextMenu;
- (void)applyWindowChrome;
- (void)applyTabLabelCompaction;
- (NSDictionary<NSNumber *, NSString *> *)commandTitlesByTag;
- (NSDictionary<NSNumber *, NSString *> *)commandTitlesInMenu:(nullable NSMenu *)root
                                                       owners:(nullable NSMutableDictionary<NSNumber *, NSString *> *)owners;
- (NSArray<NPPDocument *> *)openDocuments;
- (void)applyGlobalOverrideToEditor:(ScintillaView *)ed;
+ (BOOL)importStyleThemeWithContext:(nullable id<NPPCommandContext>)context;
@end

NSString *NPPCompactTabTitle(NSString *title, NSInteger max);   // tab-label compaction, exercised by the self-check

static NSArray<NSString *> *NPPPreferencesSelfCheck(void);   // defined at the end of this file

// Property accessors are generated: key = "NPP" + capitalized property name. Every setter posts the change
// notification (synchronous observers: NPPDocument -applyPreferences, the window controller) and then schedules the
// deferred pass for the settings only this file knows how to apply.
static void NPPScheduleLiveApply(void);
#define POST(prop) do { \
    [NSNotificationCenter.defaultCenter postNotificationName:NPPPreferencesDidChangeNotification object:self userInfo:@{@"key": @#prop}]; \
    NPPScheduleLiveApply(); \
} while (0)
#define BOOL_PROP(prop, Prop) \
    - (BOOL)prop { return [D() boolForKey:@"NPP" #Prop]; } \
    - (void)set##Prop:(BOOL)v { [D() setBool:v forKey:@"NPP" #Prop]; POST(prop); }
#define INT_PROP(type, prop, Prop) \
    - (type)prop { return (type)[D() integerForKey:@"NPP" #Prop]; } \
    - (void)set##Prop:(type)v { [D() setInteger:(NSInteger)v forKey:@"NPP" #Prop]; POST(prop); }
#define OBJ_PROP(type, prop, Prop, fallback) \
    - (type)prop { return [D() objectForKey:@"NPP" #Prop] ?: fallback; } \
    - (void)set##Prop:(type)v { [D() setObject:v forKey:@"NPP" #Prop]; POST(prop); }

@implementation NPPPreferences {
    __weak id _context;                // id<NPPCommandContext>, from NPPCommandContextReadyNotification
    NSHashTable<ScintillaView *> *_configuredEditors;   // weak: editors that have had the full pass at least once
    NSMenu *_cachedContextMenu;                          // rebuilt only when the context-menu model changes
    BOOL _chromeApplied;                                 // tab bar / status bar visibility pushed at least once
    BOOL _appliedTabBarHidden, _appliedStatusBarHidden;  // last values pushed; see -applyWindowChrome
    BOOL _mergedLanguagesLoaded;                         // the language table came from langs.user.xml, not the bundle
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _configuredEditors = [NSHashTable weakObjectsHashTable];
    return self;
}

+ (instancetype)shared {
    static NPPPreferences *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NPPPreferences new]; [s registerDefaults]; });
    return s;
}

// The four Settings commands this file owns are not routed through NPPEditorWindowController's handler table
// (that list is not ours to edit), so their menu items are re-targeted at us once the window exists. Claiming the
// item's target short-circuits the responder chain, so this stays correct if the class is added to that table later.
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NPPCommandContextReadyNotification object:nil queue:nil
        usingBlock:^(NSNotification *n) { [NPPPreferences.shared attachToContext:n.object]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NPPCurrentDocumentDidChangeNotification object:nil queue:nil
        usingBlock:^(NSNotification *n) { [NPPPreferences.shared currentDocumentDidChange:n.object]; }];
    // Selecting a theme re-applies every style from scratch, which drops this file's global override; the deferred
    // pass puts it back. Coalesced, so the reload inside -reloadLanguagesWithUserEntries costs one extra pass.
    [NSNotificationCenter.defaultCenter addObserverForName:NPPThemeDidChangeNotification object:nil queue:nil
        usingBlock:^(NSNotification *n) { NPPScheduleLiveApply(); }];
}

- (void)attachToContext:(id)context {
    _context = context;
    [self claimOwnMenuItemsIn:NSApp.mainMenu];
    // The window controller publishes its context from -init, which NPPAppDelegate does before it opens anything,
    // so the user's extra extensions are in the table before the first file is typed by extension.
    [self reloadLanguagesWithUserEntries];
    [self applyLiveSettings];
}

- (void)claimOwnMenuItemsIn:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) [self claimOwnMenuItemsIn:item.submenu];
        if ([NPPPreferences handlesCommand:(NPPCmd)item.tag] && item.tag != NPPCmdSettingsPreferences) {
            item.target = self;
            item.action = @selector(nppCommand:);
        }
    }
}

- (void)nppCommand:(id)sender {
    NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    if (![NPPPreferences performCommand:(NPPCmd)tag context:_context]) NSBeep();
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return [NPPPreferences canPerformCommand:(NPPCmd)item.tag context:_context];
}

- (void)registerDefaults {
    [D() registerDefaults:@{
        // General / toolbar / tab bar
        @"NPPHideStatusBar": @NO, @"NPPToolbarHidden": @NO, @"NPPToolbarIconSet": @(NPPToolbarFluentSmall),
        @"NPPTabBarHidden": @NO, @"NPPTabBarVertical": @NO, @"NPPTabBarMultiLine": @NO, @"NPPTabBarLocked": @NO,
        @"NPPTabPeekOnTab": @NO, @"NPPExitOnClosingLastTab": @NO, @"NPPTabMaxLabelLength": @0,
        @"NPPTabBarShowCloseButtons": @YES, @"NPPTabBarDoubleClickToClose": @NO,
        // Editing
        @"NPPTabSize": @4, @"NPPReplaceTabsBySpaces": @NO, @"NPPWordWrap": @NO,
        @"NPPLineWrapMethod": @(NPPLineWrapAligned), @"NPPCurrentLineIndicator": @(NPPCurrentLineHighlight),
        @"NPPCurrentLineFrameWidth": @1, @"NPPCaretWidth": @1, @"NPPCaretBlinkRate": @600,
        @"NPPVirtualSpace": @NO, @"NPPScrollBeyondLastLine": @NO,
        @"NPPMultiSelection": @YES, @"NPPColumnSelectionToMultiEditing": @YES,
        @"NPPEolDisplayMode": @(NPPEOLDisplayRoundedRect), @"NPPEolCustomColorEnabled": @NO, @"NPPEolCustomColor": @"DADADA",
        @"NPPShowEOL": @NO, @"NPPShowNonPrintingChars": @NO, @"NPPNonPrintingMode": @(NPPNonPrintingAbbreviation),
        @"NPPNonPrintingCustomColorEnabled": @NO, @"NPPNonPrintingCustomColor": @"FF0000",
        @"NPPNonPrintingIncludeC1AndUnicodeEOL": @NO,
        // Margins / border / edge
        @"NPPFoldMarginStyle": @(NPPFoldMarginBox), @"NPPShowLineNumbers": @YES, @"NPPShowBookmarkMargin": @YES,
        @"NPPShowChangeHistoryMargin": @YES, @"NPPChangeHistoryIndicator": @NO, @"NPPShowIndentGuides": @YES,
        @"NPPShowWhitespace": @NO, @"NPPShowWrapSymbol": @NO,
        @"NPPShowEdgeLine": @NO, @"NPPEdgeColumns": @"80", @"NPPEdgeBackgroundMode": @NO,
        @"NPPPaddingLeft": @0, @"NPPPaddingRight": @0,
        // New document / files
        @"NPPDefaultEOL": @(NPPEOLUnix), @"NPPDefaultEncoding": @(NPPEncodingUTF8),
        @"NPPDefaultCodepage": @(kCFStringEncodingWindowsLatin1), @"NPPDefaultLanguageName": @"normal",
        @"NPPDefaultDirectoryMode": @0, @"NPPDefaultDirectoryPath": @"",
        @"NPPOpenAnsiAsUTF8": @YES, @"NPPRecentFilePaths": @[], @"NPPMaxRecentFiles": @15,
        @"NPPTrimTrailingSpaceOnSave": @NO, @"NPPDetectEncodingWithUchardet": @YES,
        @"NPPFileAutoDetection": @(NPPFileAutoDetectionEnabled),
        // Language / indentation / highlighting
        @"NPPLanguageMenuCompact": @YES, @"NPPExcludedLanguageNames": @[], @"NPPSqlBackslashIsEscape": @YES,
        @"NPPBackspaceUnindent": @NO, @"NPPAutoIndentMode": @(NPPAutoIndentAdvanced), @"NPPLanguageIndents": @{},
        @"NPPSmartHighlighting": @YES, @"NPPSmartHighlightMatchCase": @NO, @"NPPSmartHighlightWholeWord": @YES,
        @"NPPMarkAllMatchCase": @YES, @"NPPMarkAllWholeWord": @YES, @"NPPTagMatchHighlight": @YES,
        @"NPPTagAttrHighlight": @YES, @"NPPBraceHighlighting": @YES, @"NPPAutoCloseBrackets": @NO,
        // Matched pairs / large files / clickable links: NPPDocument reads these keys directly and falls back to
        // exactly these values, so registering anything else here would silently change how it behaves.
        @"NPPMatchedPairParentheses": @YES, @"NPPMatchedPairBrackets": @YES, @"NPPMatchedPairCurlyBrackets": @YES,
        @"NPPMatchedPairQuotes": @YES, @"NPPMatchedPairDoubleQuotes": @YES, @"NPPMatchedPairsUserDefined": @[],
        @"NPPLargeFileRestrictionEnabled": @YES, @"NPPLargeFileSizeMB": @200, @"NPPLargeFileDeactivateWordWrap": @YES,
        @"NPPLargeFileAllowBraceMatch": @NO, @"NPPLargeFileAllowSmartHilite": @NO, @"NPPLargeFileAllowClickableLink": @NO,
        @"NPPLargeFileSuppress2GBWarning": @NO,
        @"NPPStyleURL": @(NPPURLStyleForegroundUnderline), @"NPPUriSchemes": NPPDefaultUriSchemes(),
        // MISC
        @"NPPDocumentSwitcher": @YES, @"NPPDocumentSwitcherMRU": @YES, @"NPPFolderDroppedOpenFiles": @NO,
        // Print (NPPPrintRenderer registers the same keys; identical values, so whoever runs first wins nothing)
        @"NPPPrintColourMode": @(SC_PRINT_COLOURONWHITE), @"NPPPrintLineNumbers": @NO, @"NPPPrintMagnification": @0,
        @"NPPPrintHeaderLeft": @"$(FULL_CURRENT_PATH)", @"NPPPrintHeaderMiddle": @"", @"NPPPrintHeaderRight": @"",
        @"NPPPrintFooterLeft": @"", @"NPPPrintFooterMiddle": @"$(CURRENT_PAGE)", @"NPPPrintFooterRight": @"",
        // Session / backup
        @"NPPRememberLastSession": @YES, @"NPPSessionFilePaths": @[], @"NPPSessionSelectedIndex": @0,
        @"NPPBackupSnapshotEnabled": @YES, @"NPPBackupSnapshotInterval": @7, @"NPPBackupMode": @0, @"NPPBackupDirectory": @"",
        // Date / delimiter / search engine / appearance
        @"NPPDateTimeFormat": @"yyyy-MM-dd HH:mm:ss", @"NPPDateTimeReverseDefaultOrder": @NO,
        @"NPPUseDefaultWordChars": @YES, @"NPPCustomWordChars": @"",
        @"NPPSearchEngine": @(NPPSearchEngineGoogle), @"NPPSearchEngineCustom": @"",
        @"NPPFontSize": @0, @"NPPThemeName": @"",

        // ---- the settings added from the preference.rc audit; every value is the one in N++'s own initialisers
        // (NppGUI / ScintillaViewParams / PrintSettings / LargeFileRestriction / DarkModeConf / TbIconInfo) ----
        // General / Toolbar
        @"NPPHideMenuBar": @NO, @"NPPHideMenuRightShortcuts": @NO,
        @"NPPToolbarColorizationComplete": @NO, @"NPPToolbarColor": @(NPPToolbarColorDefault),
        @"NPPToolbarCustomColor": @"000000",
        // Tab bar (N++ _tabStatus default bits: DRAWTOPBAR | DRAWINACTIVETAB | DRAGNDROP | REDUCE | CLOSEBUTTON | PINBUTTON)
        @"NPPTabBarReduce": @YES, @"NPPTabBarAlternateIcons": @NO, @"NPPTabBarDrawInactiveTab": @YES,
        @"NPPTabBarDrawTopBar": @YES, @"NPPTabBarShowOnlyPinnedButton": @NO, @"NPPTabBarInactiveTabShowButton": @NO,
        // Editing 1 / 2
        @"NPPSmoothFont": @NO, @"NPPFoldingCommandsToggleable": @NO, @"NPPRightClickKeepsSelection": @NO,
        @"NPPLineCopyCutWithoutSelection": @YES, @"NPPSelectedTextForegroundSingleColor": @NO,
        @"NPPDisableAdvancedScrolling": @NO, @"NPPDisableSelectedTextDragDrop": @NO, @"NPPPreventC0Input": @YES,
        // Dark mode tones (NppDarkMode::darkColors, in NppDarkMode::Colors order)
        @"NPPDarkModeTone": @(NPPDarkModeToneBlack),
        @"NPPDarkModeCustomBackground": @"202020", @"NPPDarkModeCustomSofterBackground": @"383838",
        @"NPPDarkModeCustomHotBackground": @"454545", @"NPPDarkModeCustomPureBackground": @"202020",
        @"NPPDarkModeCustomErrorBackground": @"B00000", @"NPPDarkModeCustomText": @"E0E0E0",
        @"NPPDarkModeCustomDarkerText": @"C0C0C0", @"NPPDarkModeCustomDisabledText": @"808080",
        @"NPPDarkModeCustomLinkText": @"FFFF00", @"NPPDarkModeCustomEdge": @"646464",
        @"NPPDarkModeCustomHotEdge": @"9B9B9B", @"NPPDarkModeCustomDisabledEdge": @"484848",
        // Margins / border / edge
        @"NPPBorderWidth": @2, @"NPPShowBorderEdge": @YES, @"NPPLineNumberDynamicWidth": @YES,
        @"NPPDistractionFreeDivPart": @4,
        // New document / recent files
        @"NPPAddNewDocumentOnStartup": @NO, @"NPPUseContentAsTabName": @NO,
        @"NPPCheckRecentFilesAtLaunch": @NO, @"NPPRecentFilesInSubmenu": @NO,
        @"NPPRecentFilesDisplay": @(NPPRecentFilesDisplayFullPath), @"NPPRecentFilesCustomLength": @259,
        // Highlighting
        @"NPPHighlightNonHTMLZone": @NO, @"NPPSmartHighlightAnotherView": @NO, @"NPPSmartHighlightUseFindSettings": @NO,
        // Print
        @"NPPPrintFormFeedPageBreak": @NO,
        @"NPPPrintMarginTop": @0, @"NPPPrintMarginLeft": @0, @"NPPPrintMarginRight": @0, @"NPPPrintMarginBottom": @0,
        @"NPPPrintHeaderFontName": @"", @"NPPPrintHeaderFontSize": @0,
        @"NPPPrintHeaderFontBold": @NO, @"NPPPrintHeaderFontItalic": @NO,
        @"NPPPrintFooterFontName": @"", @"NPPPrintFooterFontSize": @0,
        @"NPPPrintFooterFontBold": @NO, @"NPPPrintFooterFontItalic": @NO,
        // Searching
        @"NPPInSelectionAutocheckThreshold": @1024, @"NPPFillFindWhatThreshold": @1024,
        @"NPPMonospacedFontFindDlg": @NO, @"NPPConfirmReplaceInAllOpenDocs": @YES,
        @"NPPFillFindFieldWithSelected": @YES, @"NPPFillFindFieldSelectCaret": @YES,
        @"NPPFillDirFieldFromActiveDoc": @NO, @"NPPFindDlgAlwaysVisible": @NO,
        @"NPPReplaceStopsWithoutFindingNext": @NO, @"NPPFinderShowOnlyOneEntryPerFoundLine": @YES,
        @"NPPFindInFilesIgnoreOpenedFiles": @NO,
        // Backup / auto-completion / performance
        @"NPPKeepSessionAbsentFileEntries": @NO,
        @"NPPAutoCompleteInsertWithTab": @YES, @"NPPAutoCompleteInsertWithEnter": @YES,
        @"NPPLargeFileAllowAutoCompletion": @NO,
        // Multi-instance / panel state / delimiter / cloud
        @"NPPMultiInstanceMode": @(NPPMultiInstanceMono),
        @"NPPClipboardHistoryPanelKeepState": @NO, @"NPPDocListPanelKeepState": @NO, @"NPPCharPanelKeepState": @NO,
        @"NPPFileBrowserPanelKeepState": @NO, @"NPPProjectPanelKeepState": @NO, @"NPPDocMapPanelKeepState": @NO,
        @"NPPFuncListPanelKeepState": @NO, @"NPPPluginPanelKeepState": @NO,
        @"NPPDelimiterOpen": @"(", @"NPPDelimiterClose": @")", @"NPPDelimiterSelectionOnEntireDocument": @NO,
        @"NPPSettingsDirectoryEnabled": @NO, @"NPPSettingsDirectory": @"",
        // MISC
        @"NPPPeekOnDocumentMap": @NO, @"NPPMuteAllSounds": @NO, @"NPPShortTitleBar": @NO, @"NPPSaveAllConfirm": @YES,
        @"NPPFawAllowSymlink": @NO, @"NPPSessionFileExtension": @"", @"NPPWorkspaceFileExtension": @"",
        @"NPPSystemTrayAction": @(NPPSystemTrayNone), @"NPPRenderingMode": @(NPPRenderingDirectWrite),
        @"NPPAutoUpdateMode": @(NPPAutoUpdateOnStartup),
        // Style Configurator: user ext. / user keywords / global override (N++ WordStyleDlg + NppGUI::_globalOverride)
        @"NPPLanguageUserExtensions": @{}, @"NPPLanguageUserKeywords": @{},
        @"NPPGlobalOverrideForeground": @NO, @"NPPGlobalOverrideBackground": @NO, @"NPPGlobalOverrideFont": @NO,
        @"NPPGlobalOverrideFontSize": @NO, @"NPPGlobalOverrideBold": @NO, @"NPPGlobalOverrideItalic": @NO,
        @"NPPGlobalOverrideUnderline": @NO,
    }];
    // Before anything can ask for -availableThemeNames: NPPAppDelegate applies the saved theme in
    // -applicationWillFinishLaunching, and until this runs the user's themes directory is not in the search path,
    // so an imported or saved theme is not found and the app silently falls back to the default one. Cheap, and
    // idempotent — the second call (this method is also called explicitly at launch) returns straight away.
    NPPActivateUserThemesDirectory();
}

#pragma mark Generated accessors

BOOL_PROP(hideStatusBar, HideStatusBar)
BOOL_PROP(hideMenuBar, HideMenuBar)
BOOL_PROP(hideMenuRightShortcuts, HideMenuRightShortcuts)
BOOL_PROP(toolbarHidden, ToolbarHidden)
INT_PROP(NPPToolbarIconSet, toolbarIconSet, ToolbarIconSet)
BOOL_PROP(toolbarColorizationComplete, ToolbarColorizationComplete)
INT_PROP(NPPToolbarColor, toolbarColor, ToolbarColor)
OBJ_PROP(NSString *, toolbarCustomColor, ToolbarCustomColor, @"000000")
BOOL_PROP(tabBarHidden, TabBarHidden)
BOOL_PROP(tabBarVertical, TabBarVertical)
BOOL_PROP(tabBarMultiLine, TabBarMultiLine)
BOOL_PROP(tabBarLocked, TabBarLocked)
BOOL_PROP(tabPeekOnTab, TabPeekOnTab)
BOOL_PROP(exitOnClosingLastTab, ExitOnClosingLastTab)
INT_PROP(NSInteger, tabMaxLabelLength, TabMaxLabelLength)
BOOL_PROP(tabBarShowCloseButtons, TabBarShowCloseButtons)
BOOL_PROP(tabBarDoubleClickToClose, TabBarDoubleClickToClose)
BOOL_PROP(tabBarReduce, TabBarReduce)
BOOL_PROP(tabBarAlternateIcons, TabBarAlternateIcons)
BOOL_PROP(tabBarDrawInactiveTab, TabBarDrawInactiveTab)
BOOL_PROP(tabBarDrawTopBar, TabBarDrawTopBar)
BOOL_PROP(tabBarShowOnlyPinnedButton, TabBarShowOnlyPinnedButton)
BOOL_PROP(tabBarInactiveTabShowButton, TabBarInactiveTabShowButton)

INT_PROP(NSInteger, tabSize, TabSize)
BOOL_PROP(replaceTabsBySpaces, ReplaceTabsBySpaces)
BOOL_PROP(wordWrap, WordWrap)
INT_PROP(NPPLineWrapMethod, lineWrapMethod, LineWrapMethod)
INT_PROP(NPPCurrentLineIndicator, currentLineIndicator, CurrentLineIndicator)
INT_PROP(NSInteger, currentLineFrameWidth, CurrentLineFrameWidth)
INT_PROP(NSInteger, caretWidth, CaretWidth)
INT_PROP(NSInteger, caretBlinkRate, CaretBlinkRate)
BOOL_PROP(virtualSpace, VirtualSpace)
BOOL_PROP(scrollBeyondLastLine, ScrollBeyondLastLine)
BOOL_PROP(smoothFont, SmoothFont)
BOOL_PROP(foldingCommandsToggleable, FoldingCommandsToggleable)
BOOL_PROP(rightClickKeepsSelection, RightClickKeepsSelection)
BOOL_PROP(lineCopyCutWithoutSelection, LineCopyCutWithoutSelection)
BOOL_PROP(selectedTextForegroundSingleColor, SelectedTextForegroundSingleColor)
BOOL_PROP(disableAdvancedScrolling, DisableAdvancedScrolling)
BOOL_PROP(disableSelectedTextDragDrop, DisableSelectedTextDragDrop)

BOOL_PROP(multiSelection, MultiSelection)
BOOL_PROP(columnSelectionToMultiEditing, ColumnSelectionToMultiEditing)
INT_PROP(NPPEOLDisplayMode, eolDisplayMode, EolDisplayMode)
BOOL_PROP(eolCustomColorEnabled, EolCustomColorEnabled)
OBJ_PROP(NSString *, eolCustomColor, EolCustomColor, @"DADADA")
BOOL_PROP(showEOL, ShowEOL)
BOOL_PROP(showNonPrintingChars, ShowNonPrintingChars)
INT_PROP(NPPNonPrintingMode, nonPrintingMode, NonPrintingMode)
BOOL_PROP(nonPrintingCustomColorEnabled, NonPrintingCustomColorEnabled)
OBJ_PROP(NSString *, nonPrintingCustomColor, NonPrintingCustomColor, @"FF0000")
BOOL_PROP(nonPrintingIncludeC1AndUnicodeEOL, NonPrintingIncludeC1AndUnicodeEOL)
BOOL_PROP(preventC0Input, PreventC0Input)

INT_PROP(NPPDarkModeTone, darkModeTone, DarkModeTone)
OBJ_PROP(NSString *, darkModeCustomBackground, DarkModeCustomBackground, @"202020")
OBJ_PROP(NSString *, darkModeCustomSofterBackground, DarkModeCustomSofterBackground, @"383838")
OBJ_PROP(NSString *, darkModeCustomHotBackground, DarkModeCustomHotBackground, @"454545")
OBJ_PROP(NSString *, darkModeCustomPureBackground, DarkModeCustomPureBackground, @"202020")
OBJ_PROP(NSString *, darkModeCustomErrorBackground, DarkModeCustomErrorBackground, @"B00000")
OBJ_PROP(NSString *, darkModeCustomText, DarkModeCustomText, @"E0E0E0")
OBJ_PROP(NSString *, darkModeCustomDarkerText, DarkModeCustomDarkerText, @"C0C0C0")
OBJ_PROP(NSString *, darkModeCustomDisabledText, DarkModeCustomDisabledText, @"808080")
OBJ_PROP(NSString *, darkModeCustomLinkText, DarkModeCustomLinkText, @"FFFF00")
OBJ_PROP(NSString *, darkModeCustomEdge, DarkModeCustomEdge, @"646464")
OBJ_PROP(NSString *, darkModeCustomHotEdge, DarkModeCustomHotEdge, @"9B9B9B")
OBJ_PROP(NSString *, darkModeCustomDisabledEdge, DarkModeCustomDisabledEdge, @"484848")

INT_PROP(NPPFoldMarginStyle, foldMarginStyle, FoldMarginStyle)
BOOL_PROP(showLineNumbers, ShowLineNumbers)
BOOL_PROP(showBookmarkMargin, ShowBookmarkMargin)
BOOL_PROP(showChangeHistoryMargin, ShowChangeHistoryMargin)
BOOL_PROP(changeHistoryIndicator, ChangeHistoryIndicator)
BOOL_PROP(showIndentGuides, ShowIndentGuides)
BOOL_PROP(showWhitespace, ShowWhitespace)
BOOL_PROP(showWrapSymbol, ShowWrapSymbol)
BOOL_PROP(showEdgeLine, ShowEdgeLine)
OBJ_PROP(NSString *, edgeColumns, EdgeColumns, @"80")
BOOL_PROP(edgeBackgroundMode, EdgeBackgroundMode)
INT_PROP(NSInteger, paddingLeft, PaddingLeft)
INT_PROP(NSInteger, paddingRight, PaddingRight)
BOOL_PROP(showBorderEdge, ShowBorderEdge)
BOOL_PROP(lineNumberDynamicWidth, LineNumberDynamicWidth)

INT_PROP(NPPEOL, defaultEOL, DefaultEOL)
INT_PROP(NPPEncoding, defaultEncoding, DefaultEncoding)
INT_PROP(NSInteger, defaultCodepage, DefaultCodepage)
OBJ_PROP(NSString *, defaultLanguageName, DefaultLanguageName, @"normal")
BOOL_PROP(openAnsiAsUTF8, OpenAnsiAsUTF8)
BOOL_PROP(addNewDocumentOnStartup, AddNewDocumentOnStartup)
BOOL_PROP(useContentAsTabName, UseContentAsTabName)
BOOL_PROP(checkRecentFilesAtLaunch, CheckRecentFilesAtLaunch)
BOOL_PROP(recentFilesInSubmenu, RecentFilesInSubmenu)
INT_PROP(NPPRecentFilesDisplay, recentFilesDisplay, RecentFilesDisplay)
INT_PROP(NSInteger, defaultDirectoryMode, DefaultDirectoryMode)
OBJ_PROP(NSString *, defaultDirectoryPath, DefaultDirectoryPath, @"")
OBJ_PROP(NSArray<NSString *> *, recentFilePaths, RecentFilePaths, @[])

BOOL_PROP(languageMenuCompact, LanguageMenuCompact)
OBJ_PROP(NSArray<NSString *> *, excludedLanguageNames, ExcludedLanguageNames, @[])
BOOL_PROP(sqlBackslashIsEscape, SqlBackslashIsEscape)

BOOL_PROP(backspaceUnindent, BackspaceUnindent)
INT_PROP(NPPAutoIndentMode, autoIndentMode, AutoIndentMode)

BOOL_PROP(smartHighlighting, SmartHighlighting)
BOOL_PROP(smartHighlightMatchCase, SmartHighlightMatchCase)
BOOL_PROP(smartHighlightWholeWord, SmartHighlightWholeWord)
BOOL_PROP(markAllMatchCase, MarkAllMatchCase)
BOOL_PROP(markAllWholeWord, MarkAllWholeWord)
BOOL_PROP(tagMatchHighlight, TagMatchHighlight)
BOOL_PROP(tagAttrHighlight, TagAttrHighlight)
BOOL_PROP(braceHighlighting, BraceHighlighting)
BOOL_PROP(highlightNonHTMLZone, HighlightNonHTMLZone)
BOOL_PROP(smartHighlightAnotherView, SmartHighlightAnotherView)
BOOL_PROP(smartHighlightUseFindSettings, SmartHighlightUseFindSettings)
BOOL_PROP(autoCloseBrackets, AutoCloseBrackets)
BOOL_PROP(matchedPairParentheses, MatchedPairParentheses)
BOOL_PROP(matchedPairBrackets, MatchedPairBrackets)
BOOL_PROP(matchedPairCurlyBrackets, MatchedPairCurlyBrackets)
BOOL_PROP(matchedPairQuotes, MatchedPairQuotes)
BOOL_PROP(matchedPairDoubleQuotes, MatchedPairDoubleQuotes)

BOOL_PROP(largeFileRestrictionEnabled, LargeFileRestrictionEnabled)
INT_PROP(NSInteger, largeFileSizeMB, LargeFileSizeMB)   // NPPDocument clamps to >= 1 MB before comparing
BOOL_PROP(largeFileDeactivateWordWrap, LargeFileDeactivateWordWrap)
BOOL_PROP(largeFileAllowBraceMatch, LargeFileAllowBraceMatch)
BOOL_PROP(largeFileAllowSmartHilite, LargeFileAllowSmartHilite)
BOOL_PROP(largeFileAllowClickableLink, LargeFileAllowClickableLink)
BOOL_PROP(largeFileAllowAutoCompletion, LargeFileAllowAutoCompletion)
BOOL_PROP(largeFileSuppress2GBWarning, LargeFileSuppress2GBWarning)

BOOL_PROP(settingsDirectoryEnabled, SettingsDirectoryEnabled)
OBJ_PROP(NSString *, settingsDirectory, SettingsDirectory, @"")
INT_PROP(NPPURLStyle, styleURL, StyleURL)
OBJ_PROP(NSString *, uriSchemes, UriSchemes, NPPDefaultUriSchemes())

BOOL_PROP(documentSwitcher, DocumentSwitcher)
BOOL_PROP(documentSwitcherMRU, DocumentSwitcherMRU)
BOOL_PROP(folderDroppedOpenFiles, FolderDroppedOpenFiles)
BOOL_PROP(peekOnDocumentMap, PeekOnDocumentMap)
BOOL_PROP(muteAllSounds, MuteAllSounds)
BOOL_PROP(shortTitleBar, ShortTitleBar)
BOOL_PROP(saveAllConfirm, SaveAllConfirm)
BOOL_PROP(fawAllowSymlink, FawAllowSymlink)
OBJ_PROP(NSString *, sessionFileExtension, SessionFileExtension, @"")
OBJ_PROP(NSString *, workspaceFileExtension, WorkspaceFileExtension, @"")
INT_PROP(NPPSystemTrayAction, systemTrayAction, SystemTrayAction)
INT_PROP(NPPRenderingMode, renderingMode, RenderingMode)
INT_PROP(NPPAutoUpdateMode, autoUpdateMode, AutoUpdateMode)

INT_PROP(NSInteger, printColourMode, PrintColourMode)
BOOL_PROP(printLineNumbers, PrintLineNumbers)
INT_PROP(NSInteger, printMagnification, PrintMagnification)
OBJ_PROP(NSString *, printHeaderLeft, PrintHeaderLeft, @"")
OBJ_PROP(NSString *, printHeaderMiddle, PrintHeaderMiddle, @"")
OBJ_PROP(NSString *, printHeaderRight, PrintHeaderRight, @"")
OBJ_PROP(NSString *, printFooterLeft, PrintFooterLeft, @"")
OBJ_PROP(NSString *, printFooterMiddle, PrintFooterMiddle, @"")
OBJ_PROP(NSString *, printFooterRight, PrintFooterRight, @"")
BOOL_PROP(printFormFeedPageBreak, PrintFormFeedPageBreak)
OBJ_PROP(NSString *, printHeaderFontName, PrintHeaderFontName, @"")
BOOL_PROP(printHeaderFontBold, PrintHeaderFontBold)
BOOL_PROP(printHeaderFontItalic, PrintHeaderFontItalic)
OBJ_PROP(NSString *, printFooterFontName, PrintFooterFontName, @"")
BOOL_PROP(printFooterFontBold, PrintFooterFontBold)
BOOL_PROP(printFooterFontItalic, PrintFooterFontItalic)

BOOL_PROP(monospacedFontFindDlg, MonospacedFontFindDlg)
BOOL_PROP(fillFindFieldWithSelected, FillFindFieldWithSelected)
BOOL_PROP(fillFindFieldSelectCaret, FillFindFieldSelectCaret)
BOOL_PROP(fillDirFieldFromActiveDoc, FillDirFieldFromActiveDoc)
BOOL_PROP(findDlgAlwaysVisible, FindDlgAlwaysVisible)
BOOL_PROP(confirmReplaceInAllOpenDocs, ConfirmReplaceInAllOpenDocs)
BOOL_PROP(replaceStopsWithoutFindingNext, ReplaceStopsWithoutFindingNext)
BOOL_PROP(finderShowOnlyOneEntryPerFoundLine, FinderShowOnlyOneEntryPerFoundLine)
BOOL_PROP(findInFilesIgnoreOpenedFiles, FindInFilesIgnoreOpenedFiles)

BOOL_PROP(trimTrailingSpaceOnSave, TrimTrailingSpaceOnSave)
BOOL_PROP(detectEncodingWithUchardet, DetectEncodingWithUchardet)
INT_PROP(NPPFileAutoDetection, fileAutoDetection, FileAutoDetection)

BOOL_PROP(rememberLastSession, RememberLastSession)
BOOL_PROP(keepSessionAbsentFileEntries, KeepSessionAbsentFileEntries)
// Not proxied through NPPAutoCompletion the way the settings above it are: the module does not own these two keys,
// it reads them (its list panel decides what TAB and RETURN do).
BOOL_PROP(autoCompleteInsertWithTab, AutoCompleteInsertWithTab)
BOOL_PROP(autoCompleteInsertWithEnter, AutoCompleteInsertWithEnter)
OBJ_PROP(NSArray<NSString *> *, sessionFilePaths, SessionFilePaths, @[])
INT_PROP(NSInteger, sessionSelectedIndex, SessionSelectedIndex)

OBJ_PROP(NSString *, dateTimeFormat, DateTimeFormat, @"yyyy-MM-dd HH:mm:ss")
BOOL_PROP(dateTimeReverseDefaultOrder, DateTimeReverseDefaultOrder)
INT_PROP(NPPMultiInstanceMode, multiInstanceMode, MultiInstanceMode)
BOOL_PROP(clipboardHistoryPanelKeepState, ClipboardHistoryPanelKeepState)
BOOL_PROP(docListPanelKeepState, DocListPanelKeepState)
BOOL_PROP(charPanelKeepState, CharPanelKeepState)
BOOL_PROP(fileBrowserPanelKeepState, FileBrowserPanelKeepState)
BOOL_PROP(projectPanelKeepState, ProjectPanelKeepState)
BOOL_PROP(docMapPanelKeepState, DocMapPanelKeepState)
BOOL_PROP(funcListPanelKeepState, FuncListPanelKeepState)
BOOL_PROP(pluginPanelKeepState, PluginPanelKeepState)
BOOL_PROP(useDefaultWordChars, UseDefaultWordChars)
OBJ_PROP(NSString *, customWordChars, CustomWordChars, @"")
BOOL_PROP(delimiterSelectionOnEntireDocument, DelimiterSelectionOnEntireDocument)
INT_PROP(NPPSearchEngine, searchEngine, SearchEngine)
OBJ_PROP(NSString *, searchEngineCustom, SearchEngineCustom, @"")

OBJ_PROP(NSString *, fontName, FontName, nil)
OBJ_PROP(NSString *, themeName, ThemeName, @"")

// Global override. Not BOOL_PROP: switching one *off* cannot be undone by writing colours (Scintilla has no "unset"),
// so the whole theme has to be re-applied — gRestyleNeeded makes the deferred pass do exactly that, once.
static BOOL gRestyleNeeded = NO;
#define OVERRIDE_PROP(prop, Prop) \
    - (BOOL)prop { return [D() boolForKey:@"NPP" #Prop]; } \
    - (void)set##Prop:(BOOL)v { [D() setBool:v forKey:@"NPP" #Prop]; gRestyleNeeded = YES; POST(prop); }
OVERRIDE_PROP(globalOverrideForeground, GlobalOverrideForeground)
OVERRIDE_PROP(globalOverrideBackground, GlobalOverrideBackground)
OVERRIDE_PROP(globalOverrideFont, GlobalOverrideFont)
OVERRIDE_PROP(globalOverrideFontSize, GlobalOverrideFontSize)
OVERRIDE_PROP(globalOverrideBold, GlobalOverrideBold)
OVERRIDE_PROP(globalOverrideItalic, GlobalOverrideItalic)
OVERRIDE_PROP(globalOverrideUnderline, GlobalOverrideUnderline)
#undef OVERRIDE_PROP
// N++ GlobalOverride::isEnable().
- (BOOL)globalOverrideEnabled {
    return self.globalOverrideForeground || self.globalOverrideBackground || self.globalOverrideFont ||
           self.globalOverrideFontSize || self.globalOverrideBold || self.globalOverrideItalic ||
           self.globalOverrideUnderline;
}

- (CGFloat)fontSize { return [D() doubleForKey:@"NPPFontSize"]; }
- (void)setFontSize:(CGFloat)v { [D() setDouble:v forKey:@"NPPFontSize"]; POST(fontSize); }

// Ranged integers. The getter clamps as well as the setter: the readers in the other modules index arrays and size
// views with these, and a value written by an older build (or by `defaults write`) must not reach them out of range.
#define CLAMPED_INT_PROP(prop, Prop, lo, hi) \
    - (NSInteger)prop { return MAX((NSInteger)(lo), MIN((NSInteger)(hi), [D() integerForKey:@"NPP" #Prop])); } \
    - (void)set##Prop:(NSInteger)v { \
        [D() setInteger:MAX((NSInteger)(lo), MIN((NSInteger)(hi), v)) forKey:@"NPP" #Prop]; POST(prop); \
    }
CLAMPED_INT_PROP(borderWidth, BorderWidth, 0, 30)               // N++ BORDERWIDTH_SMALLEST … _LARGEST
CLAMPED_INT_PROP(distractionFreeDivPart, DistractionFreeDivPart, 3, 9)   // N++ DISTRACTIONFREE_SMALLEST … _LARGEST
CLAMPED_INT_PROP(recentFilesCustomLength, RecentFilesCustomLength, 1, 259)
CLAMPED_INT_PROP(printMarginTop, PrintMarginTop, 0, 100)
CLAMPED_INT_PROP(printMarginLeft, PrintMarginLeft, 0, 100)
CLAMPED_INT_PROP(printMarginRight, PrintMarginRight, 0, 100)
CLAMPED_INT_PROP(printMarginBottom, PrintMarginBottom, 0, 100)
CLAMPED_INT_PROP(printHeaderFontSize, PrintHeaderFontSize, 0, 72)        // 0 = the renderer's own size
CLAMPED_INT_PROP(printFooterFontSize, PrintFooterFontSize, 0, 72)
CLAMPED_INT_PROP(inSelectionAutocheckThreshold, InSelectionAutocheckThreshold, 0, 1000000)
CLAMPED_INT_PROP(fillFindWhatThreshold, FillFindWhatThreshold, 0, 1000000)
#undef CLAMPED_INT_PROP

// N++ leftmost/rightmost delimiter: exactly one character each, and never the same one (a delimiter pair that
// opens and closes on the same character cannot be matched by the ⌃double-click search).
static NSString *NPPOneDelimiterChar(id raw, NSString *fallback) {
    NSString *s = [raw isKindOfClass:NSString.class] ? raw : nil;
    if (s.length == 0) return fallback;
    NSString *first = [s substringWithRange:[s rangeOfComposedCharacterSequenceAtIndex:0]];
    return [first stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length ? first : fallback;
}
- (NSString *)delimiterOpen { return NPPOneDelimiterChar([D() objectForKey:@"NPPDelimiterOpen"], @"("); }
- (void)setDelimiterOpen:(NSString *)v {
    [D() setObject:NPPOneDelimiterChar(v, @"(") forKey:@"NPPDelimiterOpen"];
    POST(delimiterOpen);
}
- (NSString *)delimiterClose { return NPPOneDelimiterChar([D() objectForKey:@"NPPDelimiterClose"], @")"); }
- (void)setDelimiterClose:(NSString *)v {
    [D() setObject:NPPOneDelimiterChar(v, @")") forKey:@"NPPDelimiterClose"];
    POST(delimiterClose);
}

// The 12 dark-mode slots back to NppDarkMode::darkColors. One pass over the registered defaults so this and
// -registerDefaults can never drift: removing the keys makes every getter fall back to the registered value.
- (void)resetDarkModeCustomColors {
    for (NSString *k in @[@"NPPDarkModeCustomBackground", @"NPPDarkModeCustomSofterBackground",
                          @"NPPDarkModeCustomHotBackground", @"NPPDarkModeCustomPureBackground",
                          @"NPPDarkModeCustomErrorBackground", @"NPPDarkModeCustomText",
                          @"NPPDarkModeCustomDarkerText", @"NPPDarkModeCustomDisabledText",
                          @"NPPDarkModeCustomLinkText", @"NPPDarkModeCustomEdge",
                          @"NPPDarkModeCustomHotEdge", @"NPPDarkModeCustomDisabledEdge"])
        [D() removeObjectForKey:k];
    POST(darkModeCustomColors);
}

// N++ MatchedPairConf: an entry is one opening and one closing single-byte character. NPPDocument drops anything
// else without a word, so nothing else is ever stored either and the token field shows exactly the pairs in force.
static BOOL NPPIsMatchedPair(id s) {
    if (![s isKindOfClass:NSString.class] || ((NSString *)s).length != 2) return NO;
    unichar open = [(NSString *)s characterAtIndex:0], close = [(NSString *)s characterAtIndex:1];
    return open > 0 && open <= 0x7F && close > 0 && close <= 0x7F;
}
static NSArray<NSString *> *NPPMatchedPairsFrom(id raw) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id s in ([raw isKindOfClass:NSArray.class] ? (NSArray *)raw : @[])) if (NPPIsMatchedPair(s)) [out addObject:s];
    return out;
}
- (NSArray<NSString *> *)matchedPairsUserDefined { return NPPMatchedPairsFrom([D() objectForKey:@"NPPMatchedPairsUserDefined"]); }
- (void)setMatchedPairsUserDefined:(NSArray<NSString *> *)v {
    [D() setObject:NPPMatchedPairsFrom(v) forKey:@"NPPMatchedPairsUserDefined"];
    POST(matchedPairsUserDefined);
}

#pragma mark Derived properties
// Each of these is the switch NPPDocument -applyPreferences already reads; deriving it from the richer setting keeps
// the two apply paths from disagreeing (and keeps the View menu's toggles working on the same storage).

- (BOOL)highlightCurrentLine { return self.currentLineIndicator != NPPCurrentLineNone; }
- (void)setHighlightCurrentLine:(BOOL)v {
    if (v == self.highlightCurrentLine) return;
    self.currentLineIndicator = v ? NPPCurrentLineHighlight : NPPCurrentLineNone;
}
- (BOOL)caretBlink { return self.caretBlinkRate > 0; }
- (void)setCaretBlink:(BOOL)v { self.caretBlinkRate = v ? MAX(100, self.caretBlinkRate) : 0; }
- (BOOL)showFoldMargin { return self.foldMarginStyle != NPPFoldMarginNone; }
- (void)setShowFoldMargin:(BOOL)v {
    if (v == self.showFoldMargin) return;
    self.foldMarginStyle = v ? NPPFoldMarginBox : NPPFoldMarginNone;
}
- (BOOL)autoIndent { return self.autoIndentMode != NPPAutoIndentNone; }
- (void)setAutoIndent:(BOOL)v {
    if (v == self.autoIndent) return;   // never downgrade Advanced to Basic just by switching it off and on again
    self.autoIndentMode = v ? NPPAutoIndentAdvanced : NPPAutoIndentNone;
}
- (BOOL)checkFileChangesOnActivation { return self.fileAutoDetection != NPPFileAutoDetectionDisabled; }
- (void)setCheckFileChangesOnActivation:(BOOL)v {
    self.fileAutoDetection = v ? NPPFileAutoDetectionEnabled : NPPFileAutoDetectionDisabled;
}

// "80 100,120" -> @[80, 100, 120]; anything unparseable is dropped, values clamped to 1..1000, order preserved.
- (NSArray<NSNumber *> *)edgeColumnList {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@" \t,;\n\r"];
    for (NSString *piece in [self.edgeColumns componentsSeparatedByCharactersInSet:seps]) {
        if (piece.length == 0) continue;
        NSInteger v = piece.integerValue;
        if (v < 1 || v > 1000) continue;
        if (![out containsObject:@(v)]) [out addObject:@(v)];
    }
    return out;
}
- (NSInteger)edgeColumn { return self.edgeColumnList.firstObject.integerValue ?: 80; }
- (void)setEdgeColumn:(NSInteger)v { self.edgeColumns = @(MAX(1, MIN(1000, v))).stringValue; }

#pragma mark Recent files

// File > Open Recent is rebuilt by NPPAppDelegate on this notification, not on NPPPreferencesDidChange: the two
// entry points on the Recent Files History page have to post it themselves or the menu keeps the trimmed entries.
// (Every other caller of -addRecentFilePath: already posts it.)
static void NPPPostRecentFilesDidChange(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"NPPRecentFilesDidChange" object:nil];
}

- (NSInteger)maxRecentFiles { return MAX(0, MIN(30, [D() integerForKey:@"NPPMaxRecentFiles"])); }
- (void)setMaxRecentFiles:(NSInteger)v {
    [D() setInteger:MAX(0, MIN(30, v)) forKey:@"NPPMaxRecentFiles"];
    NSArray *cur = self.recentFilePaths;
    if ((NSInteger)cur.count > self.maxRecentFiles)
        self.recentFilePaths = [cur subarrayWithRange:NSMakeRange(0, (NSUInteger)self.maxRecentFiles)];
    POST(maxRecentFiles);
    NPPPostRecentFilesDidChange();
}

- (void)addRecentFilePath:(NSString *)path {
    if (path.length == 0) return;
    NSInteger cap = self.maxRecentFiles;
    if (cap == 0) { if (self.recentFilePaths.count) self.recentFilePaths = @[]; return; }
    NSMutableArray *a = [self.recentFilePaths mutableCopy];
    [a removeObject:path];
    [a insertObject:path atIndex:0];
    if ((NSInteger)a.count > cap) [a removeObjectsInRange:NSMakeRange((NSUInteger)cap, a.count - (NSUInteger)cap)];
    self.recentFilePaths = a;
}
- (void)clearRecentFiles { self.recentFilePaths = @[]; NPPPostRecentFilesDidChange(); }

// N++ LastRecentFileList::updateMenu(): one int decides all three cases (0 = name only, <0 = full path, N = cut the
// middle out of the path at N characters). Kept here so the menu builder and the three radio buttons cannot drift.
- (NSString *)recentFileMenuTitleForPath:(NSString *)path {
    if (path.length == 0) return @"";
    switch (self.recentFilesDisplay) {
        case NPPRecentFilesDisplayFileName: return path.lastPathComponent ?: path;
        case NPPRecentFilesDisplayFullPath: return path;
        case NPPRecentFilesDisplayCustomLength: break;
    }
    NSInteger max = self.recentFilesCustomLength;
    if ((NSInteger)path.length <= max) return path;
    // Elide the middle, as upstream does: the file name is the part worth keeping.
    NSInteger keep = MAX(1, (max - 1) / 2);
    NSString *head = [path substringWithRange:[path rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, (NSUInteger)keep)]];
    NSString *tail = [path substringWithRange:[path rangeOfComposedCharacterSequencesForRange:
                                               NSMakeRange(path.length - (NSUInteger)keep, (NSUInteger)keep)]];
    return [NSString stringWithFormat:@"%@…%@", head, tail];
}

#pragma mark Per-language indentation

- (nullable NSDictionary *)indentSettingsForLanguageNamed:(NSString *)name {
    if (name.length == 0) return nil;
    NSDictionary *all = [D() dictionaryForKey:@"NPPLanguageIndents"];
    NSDictionary *one = all[name];
    return [one isKindOfClass:NSDictionary.class] ? one : nil;
}

- (void)setIndentSettings:(nullable NSDictionary *)settings forLanguageNamed:(NSString *)name {
    if (name.length == 0) return;
    NSMutableDictionary *all = [([D() dictionaryForKey:@"NPPLanguageIndents"] ?: @{}) mutableCopy];
    if (settings) all[name] = settings; else [all removeObjectForKey:name];
    [D() setObject:all forKey:@"NPPLanguageIndents"];
    POST(languageIndents);
}

#pragma mark User extensions / user keywords (Style Configurator)

// Both maps store the *cleared* value as "" rather than dropping the entry: an entry that is simply gone and an
// entry that is empty look identical to the merge below, and keeping it makes the field round-trip.
static NSString *const kUserExtKey = @"NPPLanguageUserExtensions";      // language name -> "ext ext"
static NSString *const kUserKeywordsKey = @"NPPLanguageUserKeywords";   // language name -> { keyword class -> "word word" }

// Takes id, not NSString *: both maps are plain defaults keys (`defaults write …`), so anything at all can turn up
// in them and a -componentsSeparatedBy… sent to an NSNumber would take the app down on launch.
static NSArray<NSString *> *NPPWords(id s) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![s isKindOfClass:NSString.class]) return out;
    for (NSString *w in [(NSString *)s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (w.length) [out addObject:w];
    return out;
}
// base words in their original order, then the ones from `extra` that are not already there. Idempotent, so merging
// a file that has already been merged (or an extension the language ships with) adds nothing.
static NSString *NPPJoinWordsUnique(NSString *base, NSString *extra) {
    NSMutableArray<NSString *> *out = [NPPWords(base) mutableCopy];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:out];
    for (NSString *w in NPPWords(extra)) if (![seen containsObject:w]) { [seen addObject:w]; [out addObject:w]; }
    return [out componentsJoinedByString:@" "];
}
// "  .Foo  BAR " -> "foo bar". langs.model.xml holds extensions bare and lowercase and NPPLanguageManager lowercases
// what it reads, so anything else would be stored, shown back, and then silently never match a file.
static NSString *NPPNormalisedExtensionList(id s) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *w in NPPWords(s)) {
        NSString *e = [[w stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]] lowercaseString];
        if (e.length && ![out containsObject:e]) [out addObject:e];
    }
    return [out componentsJoinedByString:@" "];
}
// YES when any leaf of the map holds something. A map of nothing but "" entries must behave exactly like no map.
static BOOL NPPMapHasContent(id map) {
    if (![map isKindOfClass:NSDictionary.class]) return NO;
    for (id v in ((NSDictionary *)map).allValues) {
        if ([v isKindOfClass:NSString.class] && NPPWords(v).count) return YES;
        if ([v isKindOfClass:NSDictionary.class] && NPPMapHasContent(v)) return YES;
    }
    return NO;
}
// Which language a user-mapped extension belongs to, or nil.
static NSString *NPPUserExtensionOwner(NSDictionary *exts, NSString *extension) {
    NSString *want = extension.lowercaseString;
    if (!want.length) return nil;
    for (NSString *lang in exts)
        if ([NPPWords(exts[lang]) containsObject:want]) return lang;
    return nil;
}

// Fold the two maps into a parsed langs.model.xml — the same shape upstream's Parameters.cpp ends up with after it
// has read stylers.xml. Pure, so the self-check can drive it on a three-line document.
static void NPPMergeUserLanguageEntries(NSXMLDocument *doc,
                                        NSDictionary<NSString *, NSString *> *exts,
                                        NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *keywords) {
    NSXMLElement *languages = [doc.rootElement elementsForName:@"Languages"].firstObject;
    for (NSXMLElement *e in [languages elementsForName:@"Language"]) {
        NSString *name = [e attributeForName:@"name"].stringValue;
        if (!name.length) continue;

        NSString *extraExt = NPPNormalisedExtensionList(exts[name]);
        if (extraExt.length) {
            NSString *merged = NPPJoinWordsUnique([e attributeForName:@"ext"].stringValue, extraExt);
            [e removeAttributeForName:@"ext"];
            [e addAttribute:[NSXMLNode attributeWithName:@"ext" stringValue:merged]];
        }

        id classes = keywords[name];
        if (![classes isKindOfClass:NSDictionary.class]) continue;
        for (NSString *cls in (NSDictionary *)classes) {
            if (![cls isKindOfClass:NSString.class] || cls.length == 0) continue;
            id extra = ((NSDictionary *)classes)[cls];
            if (NPPWords(extra).count == 0) continue;
            NSXMLElement *target = nil;
            for (NSXMLElement *k in [e elementsForName:@"Keywords"])
                if ([[k attributeForName:@"name"].stringValue isEqualToString:cls]) { target = k; break; }
            if (!target) {   // a class the language does not define yet: the style still asks for it
                target = [NSXMLElement elementWithName:@"Keywords"];
                [target addAttribute:[NSXMLNode attributeWithName:@"name" stringValue:cls]];
                [e addChild:target];
            }
            target.stringValue = NPPJoinWordsUnique(target.stringValue, extra);
        }
    }
}

- (NSString *)userExtensionsForLanguageNamed:(NSString *)name {
    id v = name.length ? [D() dictionaryForKey:kUserExtKey][name] : nil;
    return [v isKindOfClass:NSString.class] ? v : @"";
}

- (void)setUserExtensions:(nullable NSString *)exts forLanguageNamed:(NSString *)name {
    if (name.length == 0) return;
    NSMutableDictionary *all = [([D() dictionaryForKey:kUserExtKey] ?: @{}) mutableCopy];
    all[name] = NPPNormalisedExtensionList(exts);
    [D() setObject:all forKey:kUserExtKey];
    POST(languageUserEntries);
}

- (NSString *)userKeywordsForLanguageNamed:(NSString *)name keywordClass:(NSString *)cls {
    if (name.length == 0 || cls.length == 0) return @"";
    id one = [D() dictionaryForKey:kUserKeywordsKey][name];
    id v = [one isKindOfClass:NSDictionary.class] ? ((NSDictionary *)one)[cls] : nil;
    return [v isKindOfClass:NSString.class] ? v : @"";
}

- (void)setUserKeywords:(nullable NSString *)words forLanguageNamed:(NSString *)name keywordClass:(NSString *)cls {
    if (name.length == 0 || cls.length == 0) return;
    NSMutableDictionary *all = [([D() dictionaryForKey:kUserKeywordsKey] ?: @{}) mutableCopy];
    id one = all[name];
    NSMutableDictionary *forLang = [([one isKindOfClass:NSDictionary.class] ? one : @{}) mutableCopy];
    forLang[cls] = [NPPWords(words) componentsJoinedByString:@" "];
    all[name] = forLang;
    [D() setObject:all forKey:kUserKeywordsKey];
    POST(languageUserEntries);
}

// ponytail: the whole 0.5 MB language file is re-parsed and the table rebuilt whenever one of those two fields is
// committed — and only then; with both maps empty nothing is written and the bundled table is left alone. The
// upgrade is NPPLanguageManager taking the two maps itself (-setUserExtensions:keywords: plus a concat in
// -makeStyle:), which would also drop the copy on disk.
- (BOOL)reloadLanguagesWithUserEntries {
    NSDictionary *exts = [D() dictionaryForKey:kUserExtKey] ?: @{};
    NSDictionary *keywords = [D() dictionaryForKey:kUserKeywordsKey] ?: @{};
    BOOL any = NPPMapHasContent(exts) || NPPMapHasContent(keywords);
    if (!any && !_mergedLanguagesLoaded) return YES;   // the bundled table is already the right one

    NSBundle *bundle = NSBundle.mainBundle;
    NSURL *baseLangs = [bundle URLForResource:@"langs.model" withExtension:@"xml"];
    NSURL *stylers = [bundle URLForResource:@"stylers.model" withExtension:@"xml"];
    if (!baseLangs || !stylers) return NO;

    NSURL *dir = NPPSupportSubdirectory(@"languages");
    NSURL *merged = [dir URLByAppendingPathComponent:@"langs.user.xml"];
    NSURL *langsURL = baseLangs;
    if (any) {
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:baseLangs
                                                                 options:NSXMLNodePreserveWhitespace error:nil];
        if (!dir || !doc) return NO;
        NPPMergeUserLanguageEntries(doc, exts, keywords);
        if (![doc.XMLData writeToURL:merged options:NSDataWritingAtomic error:nil]) return NO;
        langsURL = merged;
    } else if (merged) {
        [NSFileManager.defaultManager removeItemAtURL:merged error:nil];   // half a megabyte nothing reads any more
    }

    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NSString *theme = lm.currentThemeName;   // -loadLangsXML: resets it to the stock one
    if (![lm loadLangsXML:langsURL stylersXML:stylers error:nil]) return NO;
    _mergedLanguagesLoaded = any;
    if (theme.length) [lm selectThemeNamed:theme error:nil];

    // Every buffer whose extension the user has just claimed changes language; one that was typed by hand is left
    // alone, and a buffer holding an NPPLanguage from the old table keeps working (everything is looked up by name).
    for (NPPDocument *d in [self openDocuments]) {
        if (!d.fileURL || d.userDefinedLanguageName.length) continue;
        NSString *owner = NPPUserExtensionOwner(exts, d.fileURL.pathExtension);
        NPPLanguage *want = owner ? [lm languageNamed:owner] : nil;
        if (want && ![d.language.name isEqualToString:want.name]) d.language = want;
    }
    return YES;
}

#pragma mark Module-backed settings (Auto-Completion, Backup)

- (BOOL)autoCompletionModuleAvailable { return NPPModuleShared(@"NPPAutoCompletion") != nil; }

// The module owns the "NPPAutoComplete.*" keys and re-reads them through its own properties, so go through it.
- (id)acValueForKey:(NSString *)key {
    id m = NPPModuleShared(@"NPPAutoCompletion");
    return m ? [m valueForKey:key] : nil;
}
- (void)setACValue:(id)v forKey:(NSString *)key {
    id m = NPPModuleShared(@"NPPAutoCompletion");
    if (m) [m setValue:v forKey:key];
    POST(autoCompletion);
}
- (BOOL)autoCompleteEnabled { return [[self acValueForKey:@"enabled"] boolValue]; }
- (void)setAutoCompleteEnabled:(BOOL)v { [self setACValue:@(v) forKey:@"enabled"]; }
- (NSInteger)autoCompleteMode { return [[self acValueForKey:@"mode"] integerValue]; }
- (void)setAutoCompleteMode:(NSInteger)v { [self setACValue:@(v) forKey:@"mode"]; }
- (NSInteger)autoCompleteTriggerLength { return [[self acValueForKey:@"triggerLength"] integerValue]; }
- (void)setAutoCompleteTriggerLength:(NSInteger)v { [self setACValue:@(MAX(1, MIN(9, v))) forKey:@"triggerLength"]; }
- (BOOL)autoCompleteIgnoreNumbers { return [[self acValueForKey:@"ignoreNumbers"] boolValue]; }
- (void)setAutoCompleteIgnoreNumbers:(BOOL)v { [self setACValue:@(v) forKey:@"ignoreNumbers"]; }
- (BOOL)autoCompleteBrief { return [[self acValueForKey:@"briefMode"] boolValue]; }
- (void)setAutoCompleteBrief:(BOOL)v { [self setACValue:@(v) forKey:@"briefMode"]; }
- (BOOL)autoCompleteFunctionParameterHints { return [[self acValueForKey:@"functionParameterHints"] boolValue]; }
- (void)setAutoCompleteFunctionParameterHints:(BOOL)v { [self setACValue:@(v) forKey:@"functionParameterHints"]; }
- (BOOL)autoCompleteInsertHTMLCloseTag { return [[self acValueForKey:@"insertHTMLCloseTag"] boolValue]; }
- (void)setAutoCompleteInsertHTMLCloseTag:(BOOL)v { [self setACValue:@(v) forKey:@"insertHTMLCloseTag"]; }

// NPPBackupManager reschedules its timer in its own setters, so write the key *and* poke the manager when it is
// linked in; the manager writes the same value back, which is idempotent.
- (void)setBackupValue:(id)v forDefault:(NSString *)key moduleKey:(NSString *)moduleKey {
    [D() setObject:v forKey:key];
    id m = NPPModuleShared(@"NPPBackupManager");
    if (m) [m setValue:v forKey:moduleKey];
    POST(backup);
}
- (BOOL)backupSnapshotEnabled { return [D() boolForKey:@"NPPBackupSnapshotEnabled"]; }
- (void)setBackupSnapshotEnabled:(BOOL)v { [self setBackupValue:@(v) forDefault:@"NPPBackupSnapshotEnabled" moduleKey:@"snapshotEnabled"]; }
- (NSInteger)backupSnapshotInterval { return MAX(1, [D() integerForKey:@"NPPBackupSnapshotInterval"]); }
- (void)setBackupSnapshotInterval:(NSInteger)v {
    [self setBackupValue:@(MAX(1, MIN(3600, v))) forDefault:@"NPPBackupSnapshotInterval" moduleKey:@"snapshotInterval"];
}
- (NSInteger)backupMode { return [D() integerForKey:@"NPPBackupMode"]; }
- (void)setBackupMode:(NSInteger)v { [self setBackupValue:@(v) forDefault:@"NPPBackupMode" moduleKey:@"backupMode"]; }
- (NSString *)backupDirectory { return [D() stringForKey:@"NPPBackupDirectory"] ?: @""; }
- (void)setBackupDirectory:(NSString *)v { [self setBackupValue:(v ?: @"") forDefault:@"NPPBackupDirectory" moduleKey:@"customBackupDirectory"]; }

#pragma mark Date / search engine

- (NSString *)formattedDateTimeNowCustom {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = NSLocale.currentLocale;
    f.dateFormat = self.dateTimeFormat.length ? self.dateTimeFormat : @"yyyy-MM-dd HH:mm:ss";
    NSString *s = [f stringFromDate:NSDate.date];
    return s.length ? s : @"";
}

- (nullable NSURL *)searchEngineURLForTerm:(NSString *)term {
    NSString *encoded = [term stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
    NSString *tmpl = nil;
    switch (self.searchEngine) {
        case NPPSearchEngineDuckDuckGo:    tmpl = @"https://duckduckgo.com/?q=$(CURRENT_WORD)"; break;
        case NPPSearchEngineGoogle:        tmpl = @"https://www.google.com/search?q=$(CURRENT_WORD)"; break;
        case NPPSearchEngineBing:          tmpl = @"https://www.bing.com/search?q=$(CURRENT_WORD)"; break;
        case NPPSearchEngineYahoo:         tmpl = @"https://search.yahoo.com/search?p=$(CURRENT_WORD)"; break;
        case NPPSearchEngineStackOverflow: tmpl = @"https://stackoverflow.com/search?q=$(CURRENT_WORD)"; break;
        case NPPSearchEngineCustom:        tmpl = self.searchEngineCustom; break;
    }
    if (tmpl.length == 0) return nil;
    NSString *s = [tmpl stringByReplacingOccurrencesOfString:@"$(CURRENT_WORD)" withString:encoded];
    return [NSURL URLWithString:s];
}

#pragma mark - Live application of the settings NPPDocument does not know about

// Coalesced: every setter schedules one pass, which runs after the synchronous NPPPreferencesDidChange observers
// (NPPDocument -applyPreferences among them) so this file's Scintilla calls are never overwritten by theirs.
static BOOL gApplyScheduled = NO;
static void NPPScheduleLiveApply(void) {
    if (gApplyScheduled) return;
    gApplyScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gApplyScheduled = NO;
        [NPPPreferences.shared applyLiveSettings];
    });
}

- (void)currentDocumentDidChange:(id)context {
    if (context) _context = context;
    // Cheap per-switch pass: the language may have changed (which re-applies the theme's fold markers and word
    // characters), and the tab strip has just been rebuilt from scratch.
    id doc = [_context respondsToSelector:@selector(contextCurrentDocument)] ? [_context contextCurrentDocument] : nil;
    if ([doc isKindOfClass:NPPDocument.class]) [self refreshDocumentAfterSwitch:doc];
    [self applyTabLabelCompaction];
}

- (NSArray<NPPDocument *> *)openDocuments {
    id ctx = _context;
    return [ctx respondsToSelector:@selector(contextOpenDocuments)] ? [ctx contextOpenDocuments] : @[];
}

- (void)applyLiveSettings {
    // A global override that was just switched off cannot be undone by writing colours, so the theme goes back on
    // first and the (possibly still enabled) override is layered over it again below.
    BOOL restyle = gRestyleNeeded;
    gRestyleNeeded = NO;
    for (NPPDocument *d in [self openDocuments]) {
        if (restyle) [d applyThemeAndLanguage];
        [self applyLiveSettingsToDocument:d];
    }
    [self applyWindowChrome];
    [self applyTabLabelCompaction];
}

- (void)applyLiveSettingsToDocument:(NPPDocument *)doc {
    ScintillaView *ed = doc.editor;
    if (!ed) return;
    [self applyLiveSettingsToEditor:ed languageName:doc.userDefinedLanguageName ?: doc.language.name];
    ed.menu = [self cachedEditorContextMenu];
    [self applyDefaultCodepageToDocument:doc];
}

// N++'s New Document > "other code page" choice. NPPDocument -initUntitled takes the default *encoding* from the
// preferences but not the code page that goes with ANSI, so it is stamped on here — only while the buffer is still
// an untouched, empty ANSI document, where changing it cannot reinterpret any text.
- (void)applyDefaultCodepageToDocument:(NPPDocument *)doc {
    if (self.defaultEncoding != NPPEncodingANSI || doc.encoding != NPPEncodingANSI) return;
    if (!doc.isUntitled || doc.isDirty || NPPSci(doc.editor, SCI_GETLENGTH) != 0) return;
    CFStringEncoding want = (CFStringEncoding)self.defaultCodepage;
    if (doc.codepage == want) return;
    doc.codepage = want;
    // -setCodepage: is "Convert to…" and marks an ANSI buffer dirty on purpose. Stamping the *default* code page on
    // an empty, untouched, untitled buffer is not an edit, so the forced flag goes straight back — otherwise every
    // new document would open with a "*" in its tab and ask to be saved on close.
    // ponytail: the real fix is NPPDocument -initUntitled reading NPPPreferences.defaultCodepage itself; until then
    // the private flag is cleared through KVC and the self-check asserts the buffer really did come back clean.
    if (doc.isDirty && NPPSci(doc.editor, SCI_GETMODIFY) == 0) {
        @try { [doc setValue:@NO forKey:@"forcedDirty"]; } @catch (NSException *e) {}
        [doc.delegate documentDidChangeDirtyState:doc];
    }
}

// Tab switches are frequent (the window controller broadcasts on every dirty-state change too), and applying a
// language only resets the marker shapes, the word characters and the tab settings — so re-do just those, and the
// full pass only for an editor this object has not configured yet (a document opened after the last change).
- (void)refreshDocumentAfterSwitch:(NPPDocument *)doc {
    ScintillaView *ed = doc.editor;
    if (!ed) return;
    if (![_configuredEditors containsObject:ed]) { [self applyLiveSettingsToDocument:doc]; return; }
    [self applyLanguageSensitiveSettingsToEditor:ed languageName:(doc.userDefinedLanguageName ?: doc.language.name)];
    ed.menu = [self cachedEditorContextMenu];
}

// nil when the model builds nothing (a list of separators only): NSView falls back to Scintilla's own context menu,
// which is better than a right-click that opens an empty box.
- (NSMenu *)cachedEditorContextMenu {
    if (!_cachedContextMenu) _cachedContextMenu = [self buildEditorContextMenu];
    return _cachedContextMenu.numberOfItems ? _cachedContextMenu : nil;
}

// The whole of this file's own Scintilla surface, in one place so the self-check can drive it headlessly.
- (void)applyLiveSettingsToEditor:(ScintillaView *)ed languageName:(nullable NSString *)languageName {
    if (!ed) return;

    // Editing 1
    NPPSci(ed, SCI_SETCARETLINEFRAME, self.currentLineIndicator == NPPCurrentLineFrame
                                      ? (uptr_t)MAX(1, MIN(6, self.currentLineFrameWidth)) : 0);
    NPPSci(ed, SCI_SETCARETPERIOD, (uptr_t)MAX(0, MIN(2000, self.caretBlinkRate)));
    // Rectangular selection always stays available; "virtual space" is N++'s user-accessible variant.
    NPPSci(ed, SCI_SETVIRTUALSPACEOPTIONS, SCVS_RECTANGULARSELECTION | (self.virtualSpace ? SCVS_USERACCESSIBLE : 0));
    static const int kWrapIndent[] = {SC_WRAPINDENT_FIXED, SC_WRAPINDENT_SAME, SC_WRAPINDENT_INDENT};
    NSInteger wm = MAX(0, MIN(2, (NSInteger)self.lineWrapMethod));
    NPPSci(ed, SCI_SETWRAPINDENTMODE, (uptr_t)kWrapIndent[wm]);

    // Editing 2. ponytail: upstream's _columnSel2MultiEdit gates a WM_KEYDOWN hook and leaves
    // SCI_SETADDITIONALSELECTIONTYPING on always; typing into every selection is the observable half of it and the
    // only half Scintilla exposes. The upgrade is a key handler in NPPDocument, not another preference.
    NPPSci(ed, SCI_SETADDITIONALSELECTIONTYPING, self.multiSelection && self.columnSelectionToMultiEditing);
    [self applyEOLRepresentationsToEditor:ed];
    [self applyNonPrintingRepresentationsToEditor:ed];

    // Margins / border / edge
    NPPSci(ed, SCI_SETMARGINLEFT, 0, (sptr_t)MAX(0, MIN(9, self.paddingLeft)));
    NPPSci(ed, SCI_SETMARGINRIGHT, 0, (sptr_t)MAX(0, MIN(9, self.paddingRight)));
    [self applyEdgeToEditor:ed];
    [self applyChangeHistoryToEditor:ed];

    [self applyLanguageSensitiveSettingsToEditor:ed languageName:languageName];
    [_configuredEditors addObject:ed];
}

// The three things applying a language undoes: the fold marker shapes, the word-character set and the tab settings.
- (void)applyLanguageSensitiveSettingsToEditor:(ScintillaView *)ed languageName:(nullable NSString *)languageName {
    if (!ed) return;
    [self applyFoldMarkersToEditor:ed];

    // The per-language override wins over the global tab settings NPPDocument applied.
    NPPSci(ed, SCI_SETBACKSPACEUNINDENTS, self.backspaceUnindent);
    NSDictionary *indent = [self indentSettingsForLanguageNamed:languageName];
    if (indent) {
        NPPSci(ed, SCI_SETTABWIDTH, (uptr_t)MAX(1, MIN(64, [indent[@"size"] integerValue])));
        NPPSci(ed, SCI_SETUSETABS, ![indent[@"spaces"] boolValue]);
        if (indent[@"backspaceUnindent"]) NPPSci(ed, SCI_SETBACKSPACEUNINDENTS, [indent[@"backspaceUnindent"] boolValue]);
    }

    [self applyWordCharsToEditor:ed];
    [self applyGlobalOverrideToEditor:ed];   // last: it overwrites what the theme and the lexer just set
}

#pragma mark Global override

// N++ ScintillaEditView::setStyle: each ticked box forces that attribute of the "Global override" style onto every
// style. Upstream folds it into each style as the style is applied; the port has one seam after the language has
// been applied, so it sweeps the whole style range instead — same result, and it also catches the styles a lexer
// leaves at their defaults. `fg`/`bg` are Scintilla BGR or -1, `size` an XML point size or 0, `fontStyle` the 1/2/4
// bitmask or -1; taking them as arguments is what lets the Style Configurator preview an edit that is not saved yet.
// ponytail: upstream also *clears* a colour when the override style has none. Scintilla has no "unset", so an
// override with no colour of its own is left alone here rather than blanking every style.
static void NPPApplyGlobalOverride(ScintillaView *ed, NPPPreferences *p,
                                   long fg, long bg, NSString *font, NSInteger size, NSInteger fontStyle) {
    if (!ed || !p.globalOverrideEnabled) return;
    BOOL setFg = p.globalOverrideForeground && fg != -1;
    BOOL setBg = p.globalOverrideBackground && bg != -1;
    BOOL setFont = p.globalOverrideFont && font.length > 0;
    BOOL setSize = p.globalOverrideFontSize && size > 0;
    BOOL setStyle = fontStyle != -1 &&
                    (p.globalOverrideBold || p.globalOverrideItalic || p.globalOverrideUnderline);
    if (!setFg && !setBg && !setFont && !setSize && !setStyle) return;

    // Same font policy as NPPLanguageManager: a name the Mac does not have becomes the port's monospace default
    // rather than whatever Scintilla would fall back to (stylers.model.xml names "Courier New" here). The resolved
    // NSString is held in a local: -UTF8String's buffer must not outlive the object it came from.
    NSString *resolvedFont = setFont ? (NPPFontIsAvailable(font) ? font : NPPDefaultMonospaceFontName()) : nil;
    const char *fontUTF8 = resolvedFont.UTF8String;
    sptr_t sciSize = setSize ? (sptr_t)MAX(4, lround(size * 96.0 / 72.0)) : 0;   // same XML->Mac size as NPPLanguageManager
    BOOL setBold = setStyle && p.globalOverrideBold;         // read once: the loop below runs 256 times
    BOOL setItalic = setStyle && p.globalOverrideItalic;
    BOOL setUnderline = setStyle && p.globalOverrideUnderline;
    for (uptr_t s = 0; s <= STYLE_MAX; ++s) {
        if (setFg) NPPSci(ed, SCI_STYLESETFORE, s, fg);
        if (setBg) NPPSci(ed, SCI_STYLESETBACK, s, bg);
        if (setFont) NPPSciStr(ed, SCI_STYLESETFONT, s, fontUTF8);
        if (setSize) NPPSci(ed, SCI_STYLESETSIZE, s, sciSize);
        if (setBold) NPPSci(ed, SCI_STYLESETBOLD, s, (fontStyle & 1) != 0);
        if (setItalic) NPPSci(ed, SCI_STYLESETITALIC, s, (fontStyle & 2) != 0);
        if (setUnderline) NPPSci(ed, SCI_STYLESETUNDERLINE, s, (fontStyle & 4) != 0);
    }
}

- (void)applyGlobalOverrideToEditor:(ScintillaView *)ed {
    if (!self.globalOverrideEnabled) return;
    NPPStyle *o = [NPPLanguageManager.shared globalStyleNamed:@"Global override"];
    if (!o) return;   // a theme without the style has nothing to force
    NPPApplyGlobalOverride(ed, self, o.fgColor, o.bgColor, o.fontName, o.fontSize, o.fontStyle);
}

// N++ ScintillaEditView::_markersArray — only the marker *shapes* are set here; the colours stay whatever the
// theme put there (NPPLanguageManager -applyGlobalStylesToEditor).
// ponytail: re-applied on every preference change and tab switch, because applying a language resets the markers;
// the upgrade is NPPLanguageManager honouring the fold style itself.
- (void)applyFoldMarkersToEditor:(ScintillaView *)ed {
    static const int kMarkers[7] = {SC_MARKNUM_FOLDEROPEN, SC_MARKNUM_FOLDER, SC_MARKNUM_FOLDERSUB, SC_MARKNUM_FOLDERTAIL,
                                    SC_MARKNUM_FOLDEREND, SC_MARKNUM_FOLDEROPENMID, SC_MARKNUM_FOLDERMIDTAIL};
    static const int kShapes[4][7] = {
        {SC_MARK_MINUS,       SC_MARK_PLUS,       SC_MARK_EMPTY, SC_MARK_EMPTY,        SC_MARK_EMPTY,                SC_MARK_EMPTY,                SC_MARK_EMPTY},
        {SC_MARK_ARROWDOWN,   SC_MARK_ARROW,      SC_MARK_EMPTY, SC_MARK_EMPTY,        SC_MARK_EMPTY,                SC_MARK_EMPTY,                SC_MARK_EMPTY},
        {SC_MARK_CIRCLEMINUS, SC_MARK_CIRCLEPLUS, SC_MARK_VLINE, SC_MARK_LCORNERCURVE, SC_MARK_CIRCLEPLUSCONNECTED,  SC_MARK_CIRCLEMINUSCONNECTED, SC_MARK_TCORNERCURVE},
        {SC_MARK_BOXMINUS,    SC_MARK_BOXPLUS,    SC_MARK_VLINE, SC_MARK_LCORNER,      SC_MARK_BOXPLUSCONNECTED,     SC_MARK_BOXMINUSCONNECTED,    SC_MARK_TCORNER},
    };
    // "None" hides the margin (NPPDocument reads the derived showFoldMargin) and keeps the box shapes.
    NSInteger style = self.foldMarginStyle;
    if (style < 0 || style > NPPFoldMarginBox) style = NPPFoldMarginBox;
    for (int i = 0; i < 7; ++i) NPPSci(ed, SCI_MARKERDEFINE, (uptr_t)kMarkers[i], kShapes[style][i]);
}

- (void)applyEdgeToEditor:(ScintillaView *)ed {
    NPPSci(ed, SCI_MULTIEDGECLEARALL);
    NSArray<NSNumber *> *cols = self.edgeColumnList;
    if (!self.showEdgeLine || cols.count == 0) { NPPSci(ed, SCI_SETEDGEMODE, EDGE_NONE); return; }
    if (self.edgeBackgroundMode) {
        NPPSci(ed, SCI_SETEDGEMODE, EDGE_BACKGROUND);
        NPPSci(ed, SCI_SETEDGECOLUMN, (uptr_t)cols[0].integerValue);
        return;
    }
    if (cols.count == 1) {
        NPPSci(ed, SCI_SETEDGEMODE, EDGE_LINE);
        NPPSci(ed, SCI_SETEDGECOLUMN, (uptr_t)cols[0].integerValue);
        return;
    }
    sptr_t colour = NPPSci(ed, SCI_GETEDGECOLOUR);
    NPPSci(ed, SCI_SETEDGEMODE, EDGE_MULTILINE);
    for (NSNumber *c in cols) NPPSci(ed, SCI_MULTIEDGEADDLINE, (uptr_t)c.integerValue, colour);
}

- (void)applyChangeHistoryToEditor:(ScintillaView *)ed {
    int want = SC_CHANGE_HISTORY_DISABLED;
    if (self.showChangeHistoryMargin) want |= SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS;
    if (self.changeHistoryIndicator) want |= SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_INDICATORS;
    if (NPPSci(ed, SCI_GETCHANGEHISTORY) == want) return;
    // Scintilla only accepts the switch while the undo buffer is empty (same guard NPPDocument uses).
    if (NPPSci(ed, SCI_CANUNDO) == 0 && NPPSci(ed, SCI_CANREDO) == 0) NPPSci(ed, SCI_SETCHANGEHISTORY, (uptr_t)want);
}

// N++ Editing 2 "EOL (CRLF)": Default draws the rounded blob, Plain Text draws the letters; the custom colour is
// applied to the three line-end representations only.
- (void)applyEOLRepresentationsToEditor:(ScintillaView *)ed {
    static const char *kEOLs[3] = {"\r\n", "\r", "\n"};
    static const char *kNames[3] = {"CRLF", "CR", "LF"};
    int appearance = self.eolDisplayMode == NPPEOLDisplayRoundedRect ? SC_REPRESENTATION_BLOB : SC_REPRESENTATION_PLAIN;
    if (self.eolCustomColorEnabled) appearance |= SC_REPRESENTATION_COLOUR;
    sptr_t colour = (sptr_t)(NPPColorFromHex(self.eolCustomColor) | 0xFF000000);
    for (int i = 0; i < 3; ++i) {
        NPPSci(ed, SCI_SETREPRESENTATION, (uptr_t)kEOLs[i], (sptr_t)kNames[i]);
        NPPSci(ed, SCI_SETREPRESENTATIONAPPEARANCE, (uptr_t)kEOLs[i], appearance);
        if (self.eolCustomColorEnabled) NPPSci(ed, SCI_SETREPRESENTATIONCOLOUR, (uptr_t)kEOLs[i], colour);
    }
}

// C0 mnemonics, index = code point. 0x00 is unreachable through SCI_SETREPRESENTATION (the character is passed as a
// NUL-terminated string) and keeps Scintilla's own "[NUL]" box — ponytail: SCI_SETREPRESENTATION would need a
// length-carrying variant to fix that, which Scintilla does not have.
static const char *const kC0Names[32] = {
    "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "HT", "LF", "VT", "FF", "CR", "SO", "SI",
    "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM", "SUB", "ESC", "FS", "GS", "RS", "US",
};
static const char *const kC1Names[32] = {
    "PAD", "HOP", "BPH", "NBH", "IND", "NEL", "SSA", "ESA", "HTS", "HTJ", "VTS", "PLD", "PLU", "RI", "SS2", "SS3",
    "DCS", "PU1", "PU2", "STS", "CCH", "MW", "SPA", "EPA", "SOS", "SGCI", "SCI", "CSI", "ST", "OSC", "PM", "APC",
};

- (void)applyNonPrintingRepresentationsToEditor:(ScintillaView *)ed {
    BOOL show = self.showNonPrintingChars;
    BOOL codepoint = self.nonPrintingMode == NPPNonPrintingCodepoint;
    BOOL colourise = show && self.nonPrintingCustomColorEnabled;
    sptr_t colour = (sptr_t)(NPPColorFromHex(self.nonPrintingCustomColor) | 0xFF000000);
    BOOL extended = show && self.nonPrintingIncludeC1AndUnicodeEOL;

    void (^set)(const char *, const char *) = ^(const char *encoded, const char *rep) {
        if (!rep) { NPPSci(ed, SCI_CLEARREPRESENTATION, (uptr_t)encoded); return; }
        NPPSci(ed, SCI_SETREPRESENTATION, (uptr_t)encoded, (sptr_t)rep);
        NPPSci(ed, SCI_SETREPRESENTATIONAPPEARANCE, (uptr_t)encoded,
               SC_REPRESENTATION_BLOB | (colourise ? SC_REPRESENTATION_COLOUR : 0));
        if (colourise) NPPSci(ed, SCI_SETREPRESENTATIONCOLOUR, (uptr_t)encoded, colour);
    };

    char enc[8], rep[8];
    for (int c = 1; c < 32; ++c) {
        if (c == '\t' || c == '\n' || c == '\r') continue;   // real whitespace, not a control picture
        enc[0] = (char)c; enc[1] = 0;
        if (!show) { set(enc, NULL); continue; }             // back to Scintilla's own mnemonic boxes
        if (codepoint) snprintf(rep, sizeof rep, "x%02X", c); else snprintf(rep, sizeof rep, "%s", kC0Names[c]);
        set(enc, rep);
    }
    enc[0] = (char)0x7F; enc[1] = 0;
    if (show) { snprintf(rep, sizeof rep, codepoint ? "x7F" : "DEL"); set(enc, rep); } else set(enc, NULL);

    for (int c = 0; c < 32; ++c) {                            // U+0080..U+009F, UTF-8 encoded
        enc[0] = (char)0xC2; enc[1] = (char)(0x80 + c); enc[2] = 0;
        if (!extended) { set(enc, NULL); continue; }
        if (codepoint) snprintf(rep, sizeof rep, "x%02X", 0x80 + c); else snprintf(rep, sizeof rep, "%s", kC1Names[c]);
        set(enc, rep);
    }
    // Unicode line endings N++ groups with the C1 set: NEL is U+0085 (already covered), LS U+2028, PS U+2029.
    const char *ls = "\xE2\x80\xA8", *ps = "\xE2\x80\xA9";
    if (extended) { set(ls, codepoint ? "x2028" : "LS"); set(ps, codepoint ? "x2029" : "PS"); }
    else { set(ls, NULL); set(ps, NULL); }
}

// N++ Delimiter page (ScintillaEditView::setWordChars): the custom characters are *added* to whatever word
// characters the lexer set for this language, and turning "use default" back on restores that lexer set — which is
// what N++ keeps in _defaultCharList. Here it is remembered per editor, weakly, and re-captured whenever the set no
// longer contains our additions (i.e. applying a language has just reset it).
// ponytail: re-applied on preference change and tab switch, because applying a language resets the set in between.
// NSData, not NSString: Scintilla classifies every byte >= 0x80 as a word character by default, so the set it hands
// back is raw bytes and is not valid UTF-8.
static NSMapTable<ScintillaView *, NSData *> *gLexerWordChars;   // editor -> the set before the custom chars

// The set never contains byte 0 (Scintilla files it as a control character), so it is safe as a C string.
static std::string NPPEditorWordChars(ScintillaView *ed) {
    sptr_t n = NPPSci(ed, SCI_GETWORDCHARS, 0, 0);
    if (n <= 0 || n > 4096) return std::string();
    std::string chars((size_t)n, '\0');
    NPPSci(ed, SCI_GETWORDCHARS, 0, (sptr_t)&chars[0]);
    return chars;
}

- (void)applyWordCharsToEditor:(ScintillaView *)ed {
    if (!gLexerWordChars) gLexerWordChars = [NSMapTable weakToStrongObjectsMapTable];
    NSString *custom = self.customWordChars;
    if (self.useDefaultWordChars || custom.length == 0) {
        NSData *saved = [gLexerWordChars objectForKey:ed];
        if (!saved) return;
        std::string restore((const char *)saved.bytes, saved.length);
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, restore.c_str());
        [gLexerWordChars removeObjectForKey:ed];
        return;
    }
    std::string chars = NPPEditorWordChars(ed);
    if (chars.empty()) return;
    BOOL alreadyOurs = YES;
    std::string added;
    for (NSUInteger i = 0; i < custom.length; ++i) {
        unichar u = [custom characterAtIndex:i];
        if (u == 0 || u > 0x7F) continue;                       // Scintilla's word-character set is byte based
        char c = (char)u;
        if (chars.find(c) != std::string::npos) continue;
        alreadyOurs = NO;
        if (added.find(c) == std::string::npos) added.push_back(c);
    }
    // A set that is missing one of our characters is the lexer's own again: that is the one to remember.
    if (!alreadyOurs || ![gLexerWordChars objectForKey:ed])
        [gLexerWordChars setObject:[NSData dataWithBytes:chars.data() length:chars.size()] forKey:ed];
    if (added.empty()) return;
    NPPSciStr(ed, SCI_SETWORDCHARS, 0, (chars + added).c_str());
}

#pragma mark Window chrome

- (id<NPPPrefsWindowChrome>)chrome {
    id ctx = _context;
    return [ctx respondsToSelector:@selector(tabBar)] && [ctx respondsToSelector:@selector(statusBar)]
           ? (id<NPPPrefsWindowChrome>)ctx : nil;
}

// -tabBar hands back the focused view's strip only; N++ has two edit views and "hide the tab bar" means both.
static void NPPCollectTabBars(NSView *v, NSMutableArray<NPPTabBarView *> *out) {
    if ([v isKindOfClass:NPPTabBarView.class]) { [out addObject:(NPPTabBarView *)v]; return; }
    for (NSView *sub in v.subviews) NPPCollectTabBars(sub, out);
}
- (NSArray<NPPTabBarView *> *)tabBars {
    id ctx = _context;
    NSWindow *w = [ctx respondsToSelector:@selector(contextWindow)] ? [ctx contextWindow] : nil;
    NSMutableArray<NPPTabBarView *> *out = [NSMutableArray array];
    if (w.contentView) NPPCollectTabBars(w.contentView, out);
    return out;
}

// Distraction-free mode (View > Distraction Free) hides the same two views behind this file's back, so only a
// *change* in the preference is pushed: re-asserting "not hidden" on every setter would pop the chrome back up in
// the middle of a distraction-free session.
// ponytail: the honest fix is a "chrome changed" hook on NPPEditorWindowController, whose header is not ours.
- (void)applyWindowChrome {
    id<NPPPrefsWindowChrome> chrome = [self chrome];
    if (!chrome) return;
    NSArray<NPPTabBarView *> *bars = [self tabBars];
    for (NPPTabBarView *b in bars) if (b.showCloseButtons != self.tabBarShowCloseButtons) b.showCloseButtons = self.tabBarShowCloseButtons;
    if (_chromeApplied && _appliedTabBarHidden == self.tabBarHidden && _appliedStatusBarHidden == self.hideStatusBar) return;
    _chromeApplied = YES;
    _appliedTabBarHidden = self.tabBarHidden;
    _appliedStatusBarHidden = self.hideStatusBar;
    for (NPPTabBarView *b in bars) b.hidden = _appliedTabBarHidden;
    chrome.statusBar.hidden = _appliedStatusBarHidden;
    // ponytail: -layoutContent is the window controller's private re-layout; there is no public entry point for it.
    if ([chrome respondsToSelector:@selector(layoutContent)]) [chrome layoutContent];
}

// N++ _tabCompactLabelLen. Cutting an already-cut title must be a no-op, otherwise every broadcast (the window
// controller sends one on each dirty-state change too) would report a change and reload the whole strip.
NSString *NPPCompactTabTitle(NSString *title, NSInteger max) {
    if (max <= 0 || (NSInteger)title.length <= max) return title;
    NSRange r = [title rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, (NSUInteger)max)];
    NSString *cut = [[title substringWithRange:r] stringByAppendingString:@"…"];
    return [cut isEqualToString:title] ? title : cut;   // "abcde…" cut to 5 is "abcde…" again
}

- (void)applyTabLabelCompaction {
    NSInteger max = self.tabMaxLabelLength;
    if (max <= 0) return;
    for (NPPTabBarView *bar in [self tabBars]) {
        BOOL changed = NO;
        for (NPPTabItem *item in bar.items) {
            NSString *compact = NPPCompactTabTitle(item.title, max);
            if (compact == item.title) continue;
            item.title = compact;
            changed = YES;
        }
        if (changed) [bar reloadData];
    }
}

#pragma mark - Editor context menu

// N++ URL_INDIC (ScintillaEditView.h); NPPDocument -updateClickableLinks marks every link with it.
enum { NPPIndicatorURL = 8 };

// N++ ScintillaEditView::getIndicatorRange(URL_INDIC) plus the guard NppBigSwitch.cpp:2067 puts in front of it:
// a link is offered only when nothing is selected and the caret is inside one. The port moves the caret to the
// click before showing the context menu (NPPDocument, unless "right click keeps selection"), so the caret is the
// click, exactly as it is upstream.
static BOOL NPPLinkRangeAtCaret(ScintillaView *ed, sptr_t *outStart, sptr_t *outEnd) {
    if (!ed) return NO;
    if (NPPSci(ed, SCI_GETSELECTIONSTART) != NPPSci(ed, SCI_GETSELECTIONEND)) return NO;
    sptr_t pos = NPPSci(ed, SCI_GETCURRENTPOS);
    if ((NPPSci(ed, SCI_INDICATORALLONFOR, (uptr_t)pos) & (1 << NPPIndicatorURL)) == 0) return NO;
    sptr_t start = NPPSci(ed, SCI_INDICATORSTART, NPPIndicatorURL, pos);
    sptr_t end = NPPSci(ed, SCI_INDICATOREND, NPPIndicatorURL, pos);
    if (end <= start || pos < start || pos > end) return NO;
    if (outStart) *outStart = start;
    if (outEnd) *outEnd = end;
    return YES;
}

// Undo/Cut/Copy/Paste/Select All are AppKit responder actions in this port's Edit menu, not NPPCmd tags, so the
// context-menu model reserves negative slots for them (0 stays "separator", positive stays "NPPCmd tag").
typedef struct { NSInteger slot; const char *title; const char *selectorName; } NPPStandardContextAction;
static const NPPStandardContextAction kStandardContextActions[] = {
    {-1, "Undo", "undo:"}, {-2, "Redo", "redo:"}, {-3, "Cut", "cut:"},
    {-4, "Copy", "copy:"}, {-5, "Paste", "paste:"}, {-6, "Select All", "selectAll:"},
};
static const NSUInteger kStandardContextActionCount = sizeof kStandardContextActions / sizeof kStandardContextActions[0];
static const NPPStandardContextAction *NPPStandardContextActionForSlot(NSInteger slot) {
    for (NSUInteger i = 0; i < kStandardContextActionCount; ++i)
        if (kStandardContextActions[i].slot == slot) return &kStandardContextActions[i];
    return NULL;
}

// Upstream's contextMenu.xml puts the sixteen token-styling commands in three submenus (FolderName in
// CONTEXTMENU_XML_CONTENT, NppConstants.h). The model here is a flat list of numbers, so a folder is a marker slot:
// it opens the submenu, and every entry after it goes inside until the next marker or the next separator — which
// is exactly upstream's "consecutive items sharing a FolderName".
// ponytail: the folder names upstream ships, not arbitrary ones. A user-named folder needs the model to carry
// strings instead of numbers; the day someone wants that, entries become dictionaries and this table goes away.
typedef struct { NSInteger slot; const char *name; } NPPContextFolder;
static const NPPContextFolder kContextFolders[] = {
    {-100, "Style all occurrences of token"}, {-101, "Style one token"}, {-102, "Clear style"},
};
static const NSUInteger kContextFolderCount = sizeof kContextFolders / sizeof kContextFolders[0];
static const NPPContextFolder *NPPContextFolderForSlot(NSInteger slot) {
    for (NSUInteger i = 0; i < kContextFolderCount; ++i)
        if (kContextFolders[i].slot == slot) return &kContextFolders[i];
    return NULL;
}

// A command the main menu never shows still has to be nameable, or the Edit Popup ContextMenu dialog cannot offer
// it at all. Copy link is the only one this build has.
static NSDictionary<NSNumber *, NSString *> *NPPContextOnlyCommandTitles(void) {
    return @{@(NPPCmdEditCopyLink): @"Copy link"};
}

+ (NSArray<NSNumber *> *)defaultContextMenuCommandTags {
    // N++ contextMenu.xml (NppConstants.h CONTEXTMENU_XML_CONTENT), in its order, minus the plugin-command folder
    // this port has nothing to put in — plus Undo/Redo at the top and Toggle Bookmark at the bottom, which the port
    // has always offered here and which a macOS right-click is expected to have.
    NSMutableArray<NSNumber *> *m = [@[@(-1), @(-2), @0,
                                       @(-3), @(-4), @(-5), @(NPPCmdEditDelete), @(-6),
                                       @(NPPCmdEditBeginEndSelect), @(NPPCmdEditBeginEndSelectColumn), @0] mutableCopy];
    const struct { NSInteger folder; NSInteger first; } groups[] = {
        {-100, NPPCmdSearchMarkAllExt1}, {-101, NPPCmdSearchMarkOneExt1}, {-102, NPPCmdSearchUnmarkAllExt1},
    };
    for (const auto &g : groups) {
        [m addObject:@(g.folder)];
        for (NSInteger i = 0; i < 5; ++i) [m addObject:@(g.first + i)];
    }
    [m addObject:@(NPPCmdSearchClearAllMarks)];   // sixth entry of "Clear style", as upstream (id 43032)
    [m addObjectsFromArray:@[@0,
        @(NPPCmdEditUpperCase), @(NPPCmdEditLowerCase), @0,
        @(NPPCmdEditOpenSelectedFile), @(NPPCmdEditSearchOnInternet), @0,
        @(NPPCmdEditToggleLineComment), @(NPPCmdEditBlockComment), @(NPPCmdEditBlockUncomment), @0,
        @(NPPCmdSearchToggleBookmark), @(NPPCmdViewHideLines)]];
    return m;
}

// Defaults are user-writable (`defaults write … NPPContextMenuCommandTags`), so anything that is not a number is
// dropped rather than left to blow up in -titleForEntry: / -buildEditorContextMenu.
- (NSArray<NSNumber *> *)contextMenuCommandTags {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (id v in [D() arrayForKey:@"NPPContextMenuCommandTags"])
        if ([v isKindOfClass:NSNumber.class]) [out addObject:v];
    return out.count ? out : [NPPPreferences defaultContextMenuCommandTags];
}
- (void)setContextMenuCommandTags:(nullable NSArray<NSNumber *> *)tags {
    if (tags) [D() setObject:tags forKey:@"NPPContextMenuCommandTags"];
    else [D() removeObjectForKey:@"NPPContextMenuCommandTags"];
    _cachedContextMenu = nil;
    POST(contextMenuCommandTags);
}

// Titles come from the main menu, so a command renamed there is renamed here too. `owners`, when given, collects
// the title of the menu each command was found in — "Style All Occurrences of Token" for the first "Using 1st
// Style", "Style One Token" for the second. That is upstream's MenuEntryName, and the only thing that tells the
// twenty-odd commands this menu bar titles identically apart.
static void NPPCollectMenuCommands(NSMenu *menu, NSMutableDictionary<NSNumber *, NSString *> *out,
                                   NSMutableDictionary<NSNumber *, NSString *> *owners) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) { NPPCollectMenuCommands(item.submenu, out, owners); continue; }
        if (item.isSeparatorItem || item.tag == 0 || item.action != @selector(nppCommand:)) continue;
        NSNumber *key = @(item.tag);
        if (out[key]) continue;
        out[key] = item.title;
        if (menu.title.length) owners[key] = menu.title;
    }
}

- (NSDictionary<NSNumber *, NSString *> *)commandTitlesByTag {
    return [self commandTitlesInMenu:NSApp.mainMenu owners:nil];
}

- (NSDictionary<NSNumber *, NSString *> *)commandTitlesInMenu:(nullable NSMenu *)root
                                                       owners:(nullable NSMutableDictionary<NSNumber *, NSString *> *)owners {
    NSMutableDictionary *titles = [NSMutableDictionary dictionary];
    if (root) NPPCollectMenuCommands(root, titles, owners ?: [NSMutableDictionary dictionary]);
    NSDictionary<NSNumber *, NSString *> *contextOnly = NPPContextOnlyCommandTitles();
    for (NSNumber *tag in contextOnly) if (!titles[tag]) titles[tag] = contextOnly[tag];
    return titles;
}

// The Edit Popup ContextMenu dialog's "Available" list, in order: the six responder actions, the three folder
// openers, then every named command. It is built here rather than with NSPopUpButton -addItemWithTitle:, which
// silently REMOVES an earlier item carrying the same title — and this menu bar repeats about twenty titles
// ("Using 1st Style" is in both Style All Occurrences of Token and Style One Token, "Find Mark Style" three
// times), so that call dropped the first of each pair and the dialog could not offer it at all. A repeated title
// carries the menu it came from, so the two rows are told apart.
static NSArray<NSMenuItem *> *NPPContextAvailableRows(NSDictionary<NSNumber *, NSString *> *titles,
                                                      NSDictionary<NSNumber *, NSString *> *owners) {
    NSMutableArray<NSMenuItem *> *rows = [NSMutableArray array];
    void (^row)(NSString *, NSInteger) = ^(NSString *title, NSInteger slot) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
        it.representedObject = @(slot);
        [rows addObject:it];
    };
    for (NSUInteger i = 0; i < kStandardContextActionCount; ++i)
        row(@(kStandardContextActions[i].title), kStandardContextActions[i].slot);
    for (NSUInteger i = 0; i < kContextFolderCount; ++i)
        row([NSString stringWithFormat:@"▸ %s", kContextFolders[i].name], kContextFolders[i].slot);
    NSCountedSet *repeated = [NSCountedSet setWithArray:titles.allValues];
    for (NSNumber *tag in [titles.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        // Cut and Copy are already up there as slots -3/-4, which build exactly these items (and -4 brings Copy
        // link with it); listing the tags too would be two rows for one entry.
        if (tag.integerValue == NPPCmdEditClipboardCut || tag.integerValue == NPPCmdEditClipboardCopy) continue;
        NSString *title = titles[tag], *owner = owners[tag];
        row(([repeated countForObject:title] > 1 && owner.length)
                ? [NSString stringWithFormat:@"%@ ▸ %@", owner, title] : title,
            tag.integerValue);
    }
    return rows;
}

// One model entry, as the item(s) it contributes — none when the command has no title in this build.
- (NSArray<NSMenuItem *> *)contextMenuItemsForSlot:(NSInteger)v titles:(NSDictionary<NSNumber *, NSString *> *)titles {
    if (v < 0) {
        const NPPStandardContextAction *std = NPPStandardContextActionForSlot(v);
        if (!std) return @[];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@(std->title)
                                                      action:NSSelectorFromString(@(std->selectorName)) keyEquivalent:@""];
        // Cut and Copy go through the port instead of straight to Scintilla, so this menu honours
        // "Enable Copy/Cut line without selection" the way the Edit menu does.
        if (v == -3 || v == -4) {
            item.action = @selector(nppCommand:);
            item.tag = (v == -3) ? NPPCmdEditClipboardCut : NPPCmdEditClipboardCopy;
        }
        // Upstream hangs "Copy link" off the Copy entry (ContextMenu.cpp:115) and shows it only while the caret
        // is inside a link; -menuNeedsUpdate: below does the hiding, so drop Copy and it goes too, as upstream.
        if (v != -4) return @[item];
        NSMenuItem *link = [[NSMenuItem alloc] initWithTitle:NPPContextOnlyCommandTitles()[@(NPPCmdEditCopyLink)]
                                                      action:@selector(nppCommand:) keyEquivalent:@""];
        link.tag = NPPCmdEditCopyLink;
        return @[item, link];
    }
    NSString *title = titles[@(v)];
    if (!title) return @[];   // command not in this build's menus: drop it rather than show a blank row
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(nppCommand:) keyEquivalent:@""];
    item.tag = v;
    return @[item];
}

- (NSMenu *)buildEditorContextMenu { return [self buildEditorContextMenuWithTitlesFromMenu:NSApp.mainMenu]; }

- (NSMenu *)buildEditorContextMenuWithTitlesFromMenu:(nullable NSMenu *)titleSource {
    NSDictionary<NSNumber *, NSString *> *titles = [self commandTitlesInMenu:titleSource owners:nil];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSMenu *folder = nil;                            // the open submenu, nil while at the top level
    for (NSNumber *tag in self.contextMenuCommandTags) {
        NSInteger v = tag.integerValue;
        if (v == 0) { folder = nil; [menu addItem:NSMenuItem.separatorItem]; continue; }
        const NPPContextFolder *f = NPPContextFolderForSlot(v);
        if (f) {
            folder = [[NSMenu alloc] initWithTitle:@(f->name)];
            NSMenuItem *host = [[NSMenuItem alloc] initWithTitle:@(f->name) action:NULL keyEquivalent:@""];
            host.submenu = folder;
            [menu addItem:host];
            continue;
        }
        for (NSMenuItem *item in [self contextMenuItemsForSlot:v titles:titles]) [(folder ?: menu) addItem:item];
    }
    // A submenu whose commands all dropped out is a row that opens on nothing; a separator the drop left doubled is
    // a gap with nothing in it. Both go, or a build without some command shows the hole where it was.
    for (NSInteger i = menu.numberOfItems - 1; i >= 0; --i) {
        NSMenuItem *it = [menu itemAtIndex:i];
        if (it.submenu && it.submenu.numberOfItems == 0) { [menu removeItemAtIndex:i]; continue; }
        if (it.isSeparatorItem && i + 1 < menu.numberOfItems && [menu itemAtIndex:i + 1].isSeparatorItem)
            [menu removeItemAtIndex:i];
    }
    while (menu.numberOfItems && menu.itemArray.firstObject.isSeparatorItem) [menu removeItemAtIndex:0];
    while (menu.numberOfItems && menu.itemArray.lastObject.isSeparatorItem) [menu removeItemAtIndex:menu.numberOfItems - 1];
    menu.delegate = self;
    return menu;
}

// Only the root menu carries this delegate, and a user who moved Copy link inside a folder still expects it only
// on a link, so the submenus are walked too.
static void NPPHideCopyLink(NSMenu *menu, BOOL hidden) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) NPPHideCopyLink(item.submenu, hidden);
        else if (item.tag == NPPCmdEditCopyLink) item.hidden = hidden;
    }
}

// Only "Copy link" is dynamic, and only in the "is it a link" sense — whether it can run is answered by
// +canPerformCommand:, which the window controller asks through the responder chain like any other item.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    id doc = [_context respondsToSelector:@selector(contextCurrentDocument)] ? [_context contextCurrentDocument] : nil;
    ScintillaView *ed = [doc isKindOfClass:NPPDocument.class] ? ((NPPDocument *)doc).editor : nil;
    NPPHideCopyLink(menu, !NPPLinkRangeAtCaret(ed, NULL, NULL));
}

#pragma mark - Windows

+ (void)showPreferencesWindow { [[NPPPreferencesWindowController shared] showWindow:nil]; }
+ (void)showPreferencesPageNamed:(NSString *)pageName {
    NPPPreferencesWindowController *c = [NPPPreferencesWindowController shared];
    [c showWindow:nil];
    [c selectPageNamed:pageName];
}
+ (void)showStyleConfigurator { [[NPPStyleConfiguratorController shared] showWindow:nil]; }

#pragma mark - <NPPCommandHandler>

// Exactly the five Settings tags, and nothing else. Edit > Insert > Date Time (customized), Search on Internet and
// Change Search Engine read this file's settings but are owned by NPPEditCommands (which the window controller asks
// *before* the handler table); claiming them here also re-targeted their menu items away from that owner.
+ (BOOL)handlesCommand:(NPPCmd)cmd {
    switch (cmd) {
        case NPPCmdSettingsPreferences:
        case NPPCmdSettingsStyleConfigurator:
        case NPPCmdSettingsImportStyleTheme:
        case NPPCmdSettingsEditContextMenu:
        case NPPCmdSettingsFileAssociation:
            return YES;
        // Private tag, and only ever on the editor context menu this file builds.
        case (NPPCmd)NPPCmdEditCopyLink: return YES;
        default: return NO;
    }
}

// The editor behind a command, when there is one.
static ScintillaView *NPPContextEditor(id<NPPCommandContext> context) {
    NPPDocument *doc = [context respondsToSelector:@selector(contextCurrentDocument)] ? [context contextCurrentDocument] : nil;
    return doc.editor;
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    switch (cmd) {
        case NPPCmdSettingsPreferences:      return YES;
        case NPPCmdSettingsStyleConfigurator: return NPPLanguageManager.shared.languages.count > 0;
        // Nothing to import into unless a writable themes directory could be established.
        case NPPCmdSettingsImportStyleTheme: return NPPActivateUserThemesDirectory();
        case NPPCmdSettingsEditContextMenu:  return NSApp.mainMenu != nil;
        case NPPCmdSettingsFileAssociation:  return NSBundle.mainBundle.bundleURL != nil;
        case (NPPCmd)NPPCmdEditCopyLink:     return NPPLinkRangeAtCaret(NPPContextEditor(context), NULL, NULL);
        default: return NO;
    }
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (![self canPerformCommand:cmd context:context]) return NO;
    switch (cmd) {
        case NPPCmdSettingsPreferences:       [self showPreferencesWindow]; return YES;
        case NPPCmdSettingsStyleConfigurator: [self showStyleConfigurator]; return YES;
        case NPPCmdSettingsImportStyleTheme:  return [self importStyleThemeWithContext:context];
        case NPPCmdSettingsEditContextMenu:   [[NPPContextMenuEditorController shared] showWindow:nil]; return YES;
        case NPPCmdSettingsFileAssociation:   [[NPPFileAssociationController shared] showWindow:nil]; return YES;
        // N++ NppCommands.cpp:542 selects the link, copies and puts the caret back; SCI_COPYRANGE is the same copy
        // without ever moving the selection, so an accidental Copy link leaves the buffer exactly as it was.
        case (NPPCmd)NPPCmdEditCopyLink: {
            ScintillaView *ed = NPPContextEditor(context);
            sptr_t start = 0, end = 0;
            if (!NPPLinkRangeAtCaret(ed, &start, &end)) return NO;
            NPPSci(ed, SCI_COPYRANGE, (uptr_t)start, end);
            return YES;
        }
        default: return NO;
    }
}

// Settings > Import Style Theme(s)…: copy the chosen XML into the user themes directory and select it.
+ (NSArray<NSString *> *)selfCheckFailures { return NPPPreferencesSelfCheck(); }

+ (BOOL)importStyleThemeWithContext:(id<NPPCommandContext>)context {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.title = @"Import Style Theme(s)";
    p.allowsMultipleSelection = YES;
    p.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"xml"] ?: UTTypeXML];
    if ([p runModal] != NSModalResponseOK || p.URLs.count == 0) return YES;   // cancelling is not a failure

    NSURL *dest = NPPThemesDirectory();
    NSMutableArray<NSString *> *imported = [NSMutableArray array], *rejected = [NSMutableArray array];
    for (NSURL *src in p.URLs) {
        NSError *err = nil;
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:src options:NSXMLNodeLoadExternalEntitiesNever error:&err];
        // A theme without <LexerStyles> or <GlobalStyles> would load as an empty styler set and blank the editor.
        BOOL usable = doc && ([doc.rootElement elementsForName:@"LexerStyles"].count || [doc.rootElement elementsForName:@"GlobalStyles"].count);
        if (!usable) { [rejected addObject:src.lastPathComponent]; continue; }
        NSString *name = src.URLByDeletingPathExtension.lastPathComponent;
        NSURL *target = [dest URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"xml"]];
        [NSFileManager.defaultManager removeItemAtURL:target error:nil];
        if ([NSFileManager.defaultManager copyItemAtURL:src toURL:target error:&err]) [imported addObject:name];
        else [rejected addObject:src.lastPathComponent];
    }

    if (imported.count) {
        NPPPreferences.shared.themeName = imported.lastObject;
        [NPPLanguageManager.shared selectThemeNamed:imported.lastObject error:nil];
    }
    if (rejected.count) {
        NSAlert *a = [NSAlert new];
        a.messageText = imported.count ? @"Some themes could not be imported" : @"The theme could not be imported";
        a.informativeText = [NSString stringWithFormat:@"Not a Notepad++ style theme: %@", [rejected componentsJoinedByString:@", "]];
        [a runModal];
    } else if (context && [context respondsToSelector:@selector(contextReportStatus:isError:)]) {
        [context contextReportStatus:[NSString stringWithFormat:@"Imported %lu theme(s)", (unsigned long)imported.count] isError:NO];
    }
    return YES;
}

@end

#pragma mark - Preferences window

// Cmd+W closes; the app's File > Close is routed to editor windows, so handle the key equivalent here.
@interface NPPPrefsWindow : NSWindow @end
@implementation NPPPrefsWindow
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    if ((e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand &&
        [e.charactersIgnoringModifiers isEqualToString:@"w"]) { [self performClose:nil]; return YES; }
    return [super performKeyEquivalent:e];
}
@end

// Control kinds, stored in NSControl.tag so -refresh can read a control back without a parallel table.
typedef NS_ENUM(NSInteger, NPPPrefControlKind) {
    NPPPrefCheck = 1, NPPPrefPopup, NPPPrefInt, NPPPrefString, NPPPrefColor, NPPPrefRadio, NPPPrefTokens,
};

// Page order and names follow N++ PreferenceDlg::_wVector exactly; other modules address pages by name
// (NPPEditCommands opens "Search Engine"), so the self-check asserts the names as well as the order.
static NSArray<NSString *> *NPPPreferencePageNames(void) {
    return @[@"General", @"Toolbar", @"Tab Bar", @"Editing 1", @"Editing 2", @"Dark Mode",
             @"Margins/Border/Edge", @"New Document", @"Default Directory", @"Recent Files History",
             @"File Association", @"Language", @"Indentation", @"Highlighting", @"Print", @"Searching",
             @"Backup", @"Auto-Completion", @"Multi-Instance & Date", @"Delimiter", @"Performance",
             @"Cloud & Link", @"Search Engine", @"MISC."];
}

static NSTextField *NPPLabel(NSString *s) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.alignment = NSTextAlignmentRight;
    return l;
}

// Every control's `identifier` is the NPPPreferences property it edits; actions write via KVC (live apply) and
// -refresh re-reads on NPPPreferencesDidChangeNotification so menu toggles (View > Word Wrap…) stay in sync.
@implementation NPPPreferencesWindowController {
    NSMutableArray<NSControl *> *_controls;
    NSMutableSet<NSControl *> *_unavailable;      // shown, permanently disabled: the port cannot honour them yet
    NSTabView *_tabs;
    NSTableView *_sidebar;
    NSArray<NSString *> *_pageNames;
    // The per-language indentation group is not a single property, so it is refreshed by hand.
    NSPopUpButton *_indentLangPopup;
    NSButton *_indentUseDefault, *_indentUseTab, *_indentUseSpace, *_indentBackspace;
    NSTextField *_indentSize;
    NSTextField *_dateFormatPreview;
    // Print page: the six header/footer fields, the variable combo and the field "Add" writes into.
    NSMutableArray<NSTextField *> *_printPartFields;
    NSPopUpButton *_printVarPopup;
    NSTextField *_printVarPreview;
    __weak NSTextField *_printVarTarget;
}

+ (instancetype)shared {
    static NPPPreferencesWindowController *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPPreferencesWindowController alloc] initWithWindow:nil]; });
    return s;
}

- (instancetype)initWithWindow:(NSWindow *)w {
    NPPPrefsWindow *win = [[NPPPrefsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"Preferences";
    win.releasedWhenClosed = NO;
    win.minSize = NSMakeSize(640, 420);
    [win center];
    if (!(self = [super initWithWindow:win])) return nil;
    _controls = [NSMutableArray new];
    _unavailable = [NSMutableSet new];
    self.windowFrameAutosaveName = @"NPPPreferencesWindow";

    _pageNames = NPPPreferencePageNames();
    NSArray<NSView *> *pageViews = @[[self generalPage], [self toolbarPage], [self tabBarPage],
                                     [self editing1Page], [self editing2Page], [self darkModePage],
                                     [self marginsPage], [self newDocumentPage], [self defaultDirectoryPage],
                                     [self recentFilesPage], [self fileAssociationPage], [self languagePage],
                                     [self indentationPage], [self highlightingPage], [self printPage],
                                     [self searchingPage], [self backupPage], [self autoCompletionPage],
                                     [self multiInstancePage], [self delimiterPage], [self performancePage],
                                     [self cloudAndLinkPage], [self searchEnginePage], [self miscPage]];

    NSView *content = win.contentView;
    _tabs = [[NSTabView alloc] initWithFrame:NSZeroRect];
    _tabs.tabViewType = NSNoTabsNoBorder;
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSUInteger i = 0; i < _pageNames.count; i++) {
        NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:_pageNames[i]];
        item.label = _pageNames[i];
        item.view = [self scrollWrap:pageViews[i]];
        [_tabs addTabViewItem:item];
    }

    NSScrollView *side = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    side.translatesAutoresizingMaskIntoConstraints = NO;
    side.hasVerticalScroller = YES;
    side.borderType = NSNoBorder;
    _sidebar = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"page"];
    col.width = 180;
    [_sidebar addTableColumn:col];
    _sidebar.headerView = nil;
    _sidebar.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    _sidebar.dataSource = (id)self;
    _sidebar.delegate = (id)self;
    _sidebar.allowsEmptySelection = NO;
    side.documentView = _sidebar;

    [content addSubview:side];
    [content addSubview:_tabs];
    [NSLayoutConstraint activateConstraints:@[
        [side.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [side.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [side.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [side.widthAnchor constraintEqualToConstant:190],
        [_tabs.topAnchor constraintEqualToAnchor:content.topAnchor constant:6],
        [_tabs.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [_tabs.leadingAnchor constraintEqualToAnchor:side.trailingAnchor constant:12],
        [_tabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
    ]];
    [_sidebar reloadData];
    [_sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:NPPPreferencesDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:NPPThemeDidChangeNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)showWindow:(id)sender { [self refresh]; [super showWindow:sender]; [self.window makeKeyAndOrderFront:nil]; }

- (void)selectPageNamed:(NSString *)name {
    NSUInteger i = [_pageNames indexOfObject:name];
    if (i == NSNotFound) i = 0;
    [_sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
    [_tabs selectTabViewItemAtIndex:(NSInteger)i];
}

#pragma mark Sidebar

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)_pageNames.count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSTextField *f = [t makeViewWithIdentifier:@"page" owner:self];
    if (!f) { f = [NSTextField labelWithString:@""]; f.identifier = @"page"; }
    f.stringValue = _pageNames[(NSUInteger)row];
    return f;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger row = _sidebar.selectedRow;
    if (row >= 0) [_tabs selectTabViewItemAtIndex:row];
}

- (NSSet<NSString *> *)controlIdentifiers {
    NSMutableSet<NSString *> *out = [NSMutableSet set];
    for (NSControl *c in _controls) if (c.identifier.length) [out addObject:c.identifier];
    return out;
}

- (BOOL)everyControlDisabledForIdentifier:(NSString *)key {
    BOOL found = NO;
    for (NSControl *c in _controls) {
        if (![c.identifier isEqualToString:key]) continue;
        found = YES;
        if (![_unavailable containsObject:c]) return NO;
    }
    return found;
}

#pragma mark Layout helpers

- (NSView *)scrollWrap:(NSView *)page {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 520, 480)];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSNoBorder;
    sv.drawsBackground = NO;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 10)];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:doc.topAnchor constant:8],
        [page.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor constant:12],
        [page.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor constant:-12],
        [page.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor constant:-8],
    ]];
    sv.documentView = doc;
    [NSLayoutConstraint activateConstraints:@[
        [doc.widthAnchor constraintEqualToAnchor:sv.contentView.widthAnchor],
    ]];
    return sv;
}

// A page is a vertical stack of group boxes and notes.
- (NSStackView *)page:(NSArray<NSView *> *)sections {
    NSStackView *v = [NSStackView stackViewWithViews:sections];
    v.orientation = NSUserInterfaceLayoutOrientationVertical;
    v.alignment = NSLayoutAttributeLeading;
    v.spacing = 12;
    return v;
}

- (NSGridView *)grid:(NSArray<NSArray<NSView *> *> *)rows {
    NSGridView *g = [NSGridView gridViewWithViews:rows];
    g.rowSpacing = 8;
    g.columnSpacing = 12;
    g.rowAlignment = NSGridRowAlignmentFirstBaseline;
    g.translatesAutoresizingMaskIntoConstraints = NO;
    return g;
}

- (NSBox *)group:(NSString *)title rows:(NSArray<NSArray<NSView *> *> *)rows {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.title = title;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    NSGridView *g = [self grid:rows];
    [box.contentView addSubview:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:8],
        [g.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:10],
        [g.trailingAnchor constraintLessThanOrEqualToAnchor:box.contentView.trailingAnchor constant:-10],
        [g.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-8],
    ]];
    return box;
}

- (NSTextField *)note:(NSString *)text {
    NSTextField *f = [NSTextField wrappingLabelWithString:text];
    f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    f.textColor = NSColor.secondaryLabelColor;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    [f.widthAnchor constraintLessThanOrEqualToConstant:480].active = YES;
    return f;
}

- (NSStackView *)hstack:(NSArray<NSView *> *)views {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.spacing = 8;
    s.alignment = NSLayoutAttributeCenterY;
    return s;
}

#pragma mark Control factories

- (NSButton *)check:(NSString *)title key:(NSString *)key {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:@selector(checkChanged:)];
    b.identifier = key;
    b.tag = NPPPrefCheck;
    [_controls addObject:b];
    return b;
}

// Shown but permanently disabled, with the reason in the tooltip: the port's rule is that a control never lies,
// and an absent setting is harder to explain than a disabled one that says what it is waiting for.
- (id)unavailable:(NSControl *)c because:(NSString *)reason {
    c.toolTip = reason;
    [_unavailable addObject:c];
    return c;
}

- (NSPopUpButton *)popup:(NSString *)key titles:(NSArray<NSString *> *)titles values:(NSArray *)values {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSUInteger i = 0; i < titles.count; i++) {
        [p addItemWithTitle:titles[i]];
        p.lastItem.representedObject = values[i];
    }
    p.identifier = key; p.target = self; p.action = @selector(popupChanged:);
    p.tag = NPPPrefPopup;
    [_controls addObject:p];
    return p;
}

- (NSView *)radios:(NSString *)key titles:(NSArray<NSString *> *)titles values:(NSArray *)values {
    NSMutableArray<NSView *> *buttons = [NSMutableArray new];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSButton *b = [NSButton radioButtonWithTitle:titles[i] target:self action:@selector(radioChanged:)];
        b.identifier = key;
        b.tag = NPPPrefRadio;
        b.cell.representedObject = values[i];
        [_controls addObject:b];
        [buttons addObject:b];
    }
    NSStackView *s = [NSStackView stackViewWithViews:buttons];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 4;
    return s;
}

- (NSStackView *)intField:(NSString *)key min:(NSInteger)min max:(NSInteger)max {
    NSTextField *f = [NSTextField textFieldWithString:@""];
    f.identifier = key; f.target = self; f.action = @selector(fieldChanged:);
    f.tag = NPPPrefInt;
    NSNumberFormatter *nf = [NSNumberFormatter new];
    nf.minimum = @(min); nf.maximum = @(max); nf.allowsFloats = NO;
    f.formatter = nf;
    [f.widthAnchor constraintEqualToConstant:60].active = YES;
    NSStepper *st = [NSStepper new];
    st.minValue = min; st.maxValue = max; st.increment = 1; st.valueWraps = NO;
    st.identifier = key; st.target = self; st.action = @selector(fieldChanged:);
    st.tag = NPPPrefInt;
    [_controls addObject:f]; [_controls addObject:st];
    NSStackView *sv = [NSStackView stackViewWithViews:@[f, st]];
    sv.spacing = 2;
    return sv;
}

- (NSTextField *)textField:(NSString *)key width:(CGFloat)width {
    NSTextField *f = [NSTextField textFieldWithString:@""];
    f.identifier = key; f.target = self; f.action = @selector(stringFieldChanged:);
    f.tag = NPPPrefString;
    [f.widthAnchor constraintEqualToConstant:width].active = YES;
    [_controls addObject:f];
    return f;
}

// For a list-of-strings property. The tokens are completed from the language table, but anything can be typed:
// the reader matches on both the langs.model.xml name and the short name.
- (NSTokenField *)tokenField:(NSString *)key width:(CGFloat)width {
    NSTokenField *f = [[NSTokenField alloc] initWithFrame:NSZeroRect];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.identifier = key; f.target = self; f.action = @selector(tokenFieldChanged:);
    f.tag = NPPPrefTokens;
    f.delegate = (id)self;
    [f.widthAnchor constraintEqualToConstant:width].active = YES;
    [_controls addObject:f];
    return f;
}

- (NSArray<NSString *> *)tokenField:(NSTokenField *)tokenField completionsForSubstring:(NSString *)substring
                       indexOfToken:(NSInteger)tokenIndex indexOfSelectedItem:(NSInteger *)selectedIndex {
    if (![tokenField.identifier isEqualToString:@"excludedLanguageNames"]) return @[];   // e.g. the matched pairs
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NPPLanguage *l in NPPLanguageManager.shared.languages) {
        if ([l.name isEqualToString:@"normal"]) continue;   // never hidden, so never suggested
        if ([l.shortName rangeOfString:substring options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound)
            [out addObject:l.shortName];
    }
    return out;
}

- (NSColorWell *)colorWell:(NSString *)key {
    NSColorWell *w = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 22)];
    w.identifier = key; w.target = self; w.action = @selector(colorChanged:);
    w.tag = NPPPrefColor;
    [w.widthAnchor constraintEqualToConstant:44].active = YES;
    [w.heightAnchor constraintEqualToConstant:22].active = YES;
    [_controls addObject:w];
    return w;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    return [NSButton buttonWithTitle:title target:self action:action];
}

#pragma mark Actions (live apply via KVC on the property named by `identifier`)

- (void)checkChanged:(NSButton *)b { [NPPPreferences.shared setValue:@(b.state == NSControlStateValueOn) forKey:b.identifier]; }

- (void)radioChanged:(NSButton *)b {
    id v = b.cell.representedObject;
    if (v) [NPPPreferences.shared setValue:v forKey:b.identifier];
    [self refresh];
}

- (void)popupChanged:(NSPopUpButton *)p {
    id v = p.selectedItem.representedObject;
    [NPPPreferences.shared setValue:(v == NSNull.null ? nil : v) forKey:p.identifier];
}

- (void)fieldChanged:(NSControl *)c {
    NSInteger v = c.integerValue;
    if ([c isKindOfClass:NSTextField.class]) {   // clamp to the formatter's range
        NSNumberFormatter *nf = (NSNumberFormatter *)((NSTextField *)c).formatter;
        v = MAX(nf.minimum.integerValue, MIN(nf.maximum.integerValue, v));
    }
    if (v != [[NPPPreferences.shared valueForKey:c.identifier] integerValue])
        [NPPPreferences.shared setValue:@(v) forKey:c.identifier];
    else [self refresh];   // re-normalize a clamped/garbage field
}

- (void)stringFieldChanged:(NSTextField *)f {
    [NPPPreferences.shared setValue:(f.stringValue ?: @"") forKey:f.identifier];
}

- (void)tokenFieldChanged:(NSTokenField *)f {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    id value = f.objectValue;                       // an array of tokens once anything has been typed
    for (id t in ([value isKindOfClass:NSArray.class] ? (NSArray *)value : @[]))
        if ([t isKindOfClass:NSString.class] && ((NSString *)t).length) [out addObject:t];
    [NPPPreferences.shared setValue:out forKey:f.identifier];
}

- (void)colorChanged:(NSColorWell *)w {
    [NPPPreferences.shared setValue:NPPHexStringFromColor(w.color) forKey:w.identifier];
}

- (void)refresh {
    NPPPreferences *p = NPPPreferences.shared;
    for (NSControl *c in _controls) {
        NSString *key = c.identifier;
        if (key.length == 0) continue;
        id v = [p valueForKey:key];
        switch ((NPPPrefControlKind)c.tag) {
            case NPPPrefPopup: {
                NSPopUpButton *pop = (NSPopUpButton *)c;
                id want = v ?: NSNull.null;
                NSInteger idx = 0;
                for (NSMenuItem *it in pop.itemArray) {
                    id r = it.representedObject;
                    if ([r isEqual:want] || ([r isKindOfClass:NSNumber.class] && [want isKindOfClass:NSNumber.class] && [r doubleValue] == [want doubleValue])) {
                        idx = [pop indexOfItem:it]; break;
                    }
                }
                [pop selectItemAtIndex:idx];   // ponytail: an uninstalled font / removed theme falls back to "default" visually
                break;
            }
            case NPPPrefRadio: {
                id mine = ((NSButton *)c).cell.representedObject;
                BOOL on = [mine isEqual:v] || ([mine isKindOfClass:NSNumber.class] && [v isKindOfClass:NSNumber.class] && [mine doubleValue] == [v doubleValue]);
                ((NSButton *)c).state = on ? NSControlStateValueOn : NSControlStateValueOff;
                break;
            }
            case NPPPrefCheck:  ((NSButton *)c).state = [v boolValue] ? NSControlStateValueOn : NSControlStateValueOff; break;
            case NPPPrefString: c.stringValue = [v isKindOfClass:NSString.class] ? v : @""; break;
            case NPPPrefTokens: ((NSTokenField *)c).objectValue = [v isKindOfClass:NSArray.class] ? v : @[]; break;
            case NPPPrefColor:  ((NSColorWell *)c).color = NPPColorFromHexString([v isKindOfClass:NSString.class] ? v : @"000000"); break;
            case NPPPrefInt:    c.integerValue = [v integerValue]; break;
        }
    }
    [self refreshIndentation];
    if (_dateFormatPreview) _dateFormatPreview.stringValue = [p formattedDateTimeNowCustom];
    [self updateEnabledStates];
}

- (void)updateEnabledStates {
    NPPPreferences *p = NPPPreferences.shared;
    BOOL ac = p.autoCompletionModuleAvailable;
    for (NSControl *c in _controls) {
        NSString *key = c.identifier;
        BOOL on = YES;
        // "Use the Find dialog's settings" replaces the two below it, so they stop being live while it is on
        // (upstream clears them instead; either way they never look live and do nothing).
        if ([key isEqualToString:@"smartHighlightMatchCase"] || [key isEqualToString:@"smartHighlightWholeWord"])
            on = p.smartHighlighting && !p.smartHighlightUseFindSettings;
        else if ([key isEqualToString:@"smartHighlightUseFindSettings"] || [key isEqualToString:@"smartHighlightAnotherView"])
            on = p.smartHighlighting;
        else if ([key isEqualToString:@"tagAttrHighlight"] || [key isEqualToString:@"highlightNonHTMLZone"]) on = p.tagMatchHighlight;
        else if ([key isEqualToString:@"toolbarColorizationComplete"] || [key isEqualToString:@"toolbarColor"])
            on = p.toolbarIconSet != NPPToolbarStandardSmall;
        else if ([key isEqualToString:@"toolbarCustomColor"])
            on = p.toolbarIconSet != NPPToolbarStandardSmall && p.toolbarColor == NPPToolbarColorCustom;
        else if ([key hasPrefix:@"darkModeCustom"]) on = p.darkModeTone == NPPDarkModeToneCustomized;
        else if ([key isEqualToString:@"borderWidth"]) on = p.showBorderEdge;
        else if ([key isEqualToString:@"lineNumberDynamicWidth"]) on = p.showLineNumbers;
        else if ([key isEqualToString:@"recentFilesCustomLength"]) on = p.recentFilesDisplay == NPPRecentFilesDisplayCustomLength;
        else if ([key isEqualToString:@"settingsDirectory"]) on = p.settingsDirectoryEnabled;
        else if ([key isEqualToString:@"uriSchemes"]) on = p.styleURL != NPPURLStyleDisabled;
        else if ([key isEqualToString:@"defaultDirectoryPath"]) on = p.defaultDirectoryMode == 2;
        else if ([key hasPrefix:@"matchedPair"]) on = p.autoCloseBrackets;
        else if ([key hasPrefix:@"largeFile"] && ![key isEqualToString:@"largeFileRestrictionEnabled"] &&
                 ![key isEqualToString:@"largeFileSuppress2GBWarning"]) on = p.largeFileRestrictionEnabled;
        else if ([key isEqualToString:@"edgeColumns"] || [key isEqualToString:@"edgeBackgroundMode"]) on = p.showEdgeLine;
        else if ([key isEqualToString:@"currentLineFrameWidth"]) on = p.currentLineIndicator == NPPCurrentLineFrame;
        else if ([key isEqualToString:@"eolCustomColor"]) on = p.eolCustomColorEnabled;
        else if ([key isEqualToString:@"nonPrintingMode"] || [key isEqualToString:@"nonPrintingCustomColorEnabled"] ||
                 [key isEqualToString:@"nonPrintingIncludeC1AndUnicodeEOL"]) on = p.showNonPrintingChars;
        else if ([key isEqualToString:@"nonPrintingCustomColor"]) on = p.showNonPrintingChars && p.nonPrintingCustomColorEnabled;
        else if ([key isEqualToString:@"customWordChars"]) on = !p.useDefaultWordChars;
        else if ([key isEqualToString:@"searchEngineCustom"]) on = p.searchEngine == NPPSearchEngineCustom;
        else if ([key isEqualToString:@"backupSnapshotInterval"]) on = p.backupSnapshotEnabled;
        else if ([key isEqualToString:@"backupDirectory"]) on = p.backupMode != 0;
        else if ([key isEqualToString:@"columnSelectionToMultiEditing"]) on = p.multiSelection;
        else if ([key hasPrefix:@"autoComplete"]) on = ac;
        if ([_unavailable containsObject:c]) on = NO;
        c.enabled = on;
    }
}

#pragma mark Pages (order and names follow N++ preference.rc)

- (NSView *)generalPage {
    // ponytail: N++'s "hide the menu bar" has no macOS equivalent — the menu bar belongs to the system. Its
    // Localization combo does: it is the Settings ▸ UI Language submenu (NPPLocalization owns that list).
    NSString *menuReason = @"macOS owns the menu bar: an app can go full-screen but cannot hide the bar or the "
                            "items at its right-hand end.";
    return [self page:@[
        [self group:@"Status Bar" rows:@[@[[self check:@"Hide" key:@"hideStatusBar"]]]],
        [self group:@"Menu" rows:@[
            @[[self unavailable:[self check:@"Hide (use Alt or F10 key to toggle)" key:@"hideMenuBar"] because:menuReason]],
            @[[self unavailable:[self check:@"Hide right shortcuts ＋ ▼ ✕" key:@"hideMenuRightShortcuts"] because:menuReason]],
            @[[self note:@"The menu's language is chosen in Settings ▸ UI Language."]],
        ]],
    ]];
}

- (NSView *)toolbarPage {
    NSView *iconSets = [self radios:@"toolbarIconSet"
        titles:@[@"Fluent UI: small", @"Fluent UI: large", @"Filled Fluent UI: small", @"Filled Fluent UI: large", @"Standard icons: small"]
        values:@[@(NPPToolbarFluentSmall), @(NPPToolbarFluentLarge), @(NPPToolbarFilledFluentSmall), @(NPPToolbarFilledFluentLarge), @(NPPToolbarStandardSmall)]];
    // NPPToolBar draws SF Symbols and varies them by size and by fill/weight, which covers the first four sets
    // exactly; the fifth would come out identical to "Fluent UI: small", so it is offered as what it is.
    NSArray<NSView *> *setButtons = ((NSStackView *)iconSets).views;
    if (setButtons.count == 5 && [setButtons.lastObject isKindOfClass:NSControl.class])
        [self unavailable:(NSControl *)setButtons.lastObject
                  because:@"The toolbar draws SF Symbols; this set has no look of its own here (it would be Fluent UI: small again)."];
    return [self page:@[
        [self group:@"Toolbar" rows:@[@[[self check:@"Hide" key:@"toolbarHidden"]]]],
        [self group:@"Icons" rows:@[@[iconSets]]],
        // N++ TbIconInfo::_tbUseMono: "Complete" tints the whole glyph, "Partial" only its accent parts.
        [self group:@"Colorization" rows:@[
            @[[self radios:@"toolbarColorizationComplete" titles:@[@"Complete", @"Partial"] values:@[@YES, @NO]]],
        ]],
        [self group:@"Color choice" rows:@[
            @[[self radios:@"toolbarColor"
                    titles:@[@"Default", @"Red", @"Green", @"Blue", @"Purple", @"Cyan", @"Olive", @"Yellow",
                             @"System Accent", @"Custom"]
                    values:@[@(NPPToolbarColorDefault), @(NPPToolbarColorRed), @(NPPToolbarColorGreen),
                             @(NPPToolbarColorBlue), @(NPPToolbarColorPurple), @(NPPToolbarColorCyan),
                             @(NPPToolbarColorOlive), @(NPPToolbarColorYellow), @(NPPToolbarColorAccent),
                             @(NPPToolbarColorCustom)]]],
            @[NPPLabel(@"Custom colour:"), [self colorWell:@"toolbarCustomColor"]],
            @[[NSView new], [self note:@"\"System Accent\" follows the accent colour set in System Settings ▸ Appearance. The colour choice does not apply to the standard icon set."]],
        ]],
    ]];
}

- (NSView *)tabBarPage {
    return [self page:@[
        [self group:@"Tab Bar" rows:@[@[[self check:@"Hide" key:@"tabBarHidden"]]]],
        [self group:@"Behavior" rows:@[
            @[[self check:@"Vertical" key:@"tabBarVertical"]],
            @[[self check:@"Multi-line" key:@"tabBarMultiLine"]],
            @[[self check:@"Lock (no drag and drop)" key:@"tabBarLocked"]],
            @[[self check:@"Double-click to close document" key:@"tabBarDoubleClickToClose"]],
            @[[self check:@"Exit on closing the last tab" key:@"exitOnClosingLastTab"]],
            @[NPPLabel(@"Max. tab label length:"), [self intField:@"tabMaxLabelLength" min:0 max:64]],
            @[[NSView new], [self note:@"0 = no compacting. Longer names are cut and end with an ellipsis."]],
        ]],
        [self group:@"Look & feel" rows:@[
            @[[self check:@"Reduce" key:@"tabBarReduce"]],
            @[[self check:@"Alternate icons" key:@"tabBarAlternateIcons"]],
            @[[self check:@"Change inactive tab colour" key:@"tabBarDrawInactiveTab"]],
            @[[self check:@"Draw a coloured bar on the active tab" key:@"tabBarDrawTopBar"]],
            @[[self check:@"Show close button" key:@"tabBarShowCloseButtons"]],
            @[[self check:@"Show only pinned button" key:@"tabBarShowOnlyPinnedButton"]],
            @[[self check:@"Show buttons on inactive tabs" key:@"tabBarInactiveTabShowButton"]],
            @[[self check:@"Peek at a document by hovering its tab" key:@"tabPeekOnTab"]],
            @[[NSView new], [self note:@"The peek shows the start of the document as plain text, next to the tab."]],
        ]],
    ]];
}

- (NSView *)editing1Page {
    return [self page:@[
        [self group:@"Current Line Indicator" rows:@[
            @[[self radios:@"currentLineIndicator" titles:@[@"None", @"Highlight background", @"Frame"]
                    values:@[@(NPPCurrentLineNone), @(NPPCurrentLineHighlight), @(NPPCurrentLineFrame)]]],
            @[NPPLabel(@"Frame width:"), [self intField:@"currentLineFrameWidth" min:1 max:6]],
        ]],
        [self group:@"Caret Settings" rows:@[
            @[NPPLabel(@"Width:"), [self popup:@"caretWidth" titles:@[@"1", @"2", @"3"] values:@[@1, @2, @3]]],
            @[NPPLabel(@"Blink rate:"), [self popup:@"caretBlinkRate"
                titles:@[@"Solid (no blink)", @"Fast (200 ms)", @"Normal (600 ms)", @"Slow (1200 ms)"]
                values:@[@0, @200, @600, @1200]]],
        ]],
        [self group:@"Line Wrap" rows:@[
            @[[self check:@"Word wrap" key:@"wordWrap"]],
            @[[self radios:@"lineWrapMethod" titles:@[@"Default", @"Aligned", @"Indent"]
                    values:@[@(NPPLineWrapDefault), @(NPPLineWrapAligned), @(NPPLineWrapIndent)]]],
            @[[self check:@"Show wrap symbol" key:@"showWrapSymbol"]],
        ]],
        [self group:@"Behaviour" rows:@[
            @[[self check:@"Enable smooth font" key:@"smoothFont"]],
            @[[self check:@"Enable virtual space" key:@"virtualSpace"]],
            @[[self check:@"Make current level folding/unfolding commands toggleable" key:@"foldingCommandsToggleable"]],
            @[[self check:@"Keep selection when right-clicking outside of it" key:@"rightClickKeepsSelection"]],
            @[[self check:@"Enable Copy/Cut line without selection" key:@"lineCopyCutWithoutSelection"]],
            @[[self check:@"Apply custom colour to selected text foreground" key:@"selectedTextForegroundSingleColor"]],
            @[[self check:@"Enable scrolling beyond last line" key:@"scrollBeyondLastLine"]],
            @[[self check:@"Disable advanced scrolling (trackpad)" key:@"disableAdvancedScrolling"]],
            @[[self check:@"Disable selected text drag and drop" key:@"disableSelectedTextDragDrop"]],
            @[[self check:@"Show indent guides" key:@"showIndentGuides"]],
            @[[self check:@"Show white space and tab" key:@"showWhitespace"]],
            @[[self note:@"The selected-text foreground colour is the Style Configurator's \"Selected text colour\" (Global Styles); without this switch the selection keeps each token's own colour."]],
        ]],
    ]];
}

- (NSView *)editing2Page {
    return [self page:@[
        [self group:@"Multi-Editing" rows:@[
            @[[self check:@"Enable multi-editing (⌘-click / ⌘-selection)" key:@"multiSelection"]],
            @[[self check:@"Enable column selection to multi-editing" key:@"columnSelectionToMultiEditing"]],
        ]],
        [self group:@"EOL (CRLF)" rows:@[
            @[[self check:@"Show end of line" key:@"showEOL"]],
            @[[self radios:@"eolDisplayMode" titles:@[@"Default (rounded rectangle)", @"Plain text"]
                    values:@[@(NPPEOLDisplayRoundedRect), @(NPPEOLDisplayPlainText)]]],
            @[[self hstack:@[[self check:@"Custom colour" key:@"eolCustomColorEnabled"], [self colorWell:@"eolCustomColor"]]]],
        ]],
        [self group:@"Non-Printing Characters" rows:@[
            @[[self check:@"Show non-printing characters" key:@"showNonPrintingChars"]],
            @[[self radios:@"nonPrintingMode" titles:@[@"Abbreviation (NUL, SOH, …)", @"Codepoint (x00, x01, …)"]
                    values:@[@(NPPNonPrintingAbbreviation), @(NPPNonPrintingCodepoint)]]],
            @[[self hstack:@[[self check:@"Custom colour" key:@"nonPrintingCustomColorEnabled"], [self colorWell:@"nonPrintingCustomColor"]]]],
            @[[self check:@"Apply to C1 control characters and Unicode line separators" key:@"nonPrintingIncludeC1AndUnicodeEOL"]],
            @[[self check:@"Prevent control character (C0 code) typing into the document" key:@"preventC0Input"]],
            @[[self note:@"NUL keeps Scintilla's own box: SCI_SETREPRESENTATION takes the character as a NUL-terminated string, so U+0000 cannot be given one."]],
        ]],
    ]];
}

- (NSView *)darkModePage {
    // The port follows the system appearance by default and otherwise uses the named theme; Light/Dark here pick the
    // two stock themes, which is what N++'s Light/Dark mode radio does.
    NSView *radios = [self radios:@"themeName"
        titles:@[@"Follow system appearance", @"Light mode (Default)", @"Dark mode (DarkModeDefault)"]
        values:@[@"", kDefaultThemeName, @"DarkModeDefault"]];
    // N++ DarkModeConf::_colorTone. Upstream repaints its own Win32 chrome with these; here they are the accent the
    // port's own drawn surfaces (tab strip, status bar, panel headers) tint themselves with.
    NSView *tones = [self radios:@"darkModeTone"
        titles:@[@"Black", @"Red", @"Green", @"Blue", @"Purple", @"Cyan", @"Olive", @"Customized"]
        values:@[@(NPPDarkModeToneBlack), @(NPPDarkModeToneRed), @(NPPDarkModeToneGreen), @(NPPDarkModeToneBlue),
                 @(NPPDarkModeTonePurple), @(NPPDarkModeToneCyan), @(NPPDarkModeToneOlive),
                 @(NPPDarkModeToneCustomized)]];
    return [self page:@[
        [self group:@"Appearance" rows:@[@[radios]]],
        [self group:@"Theme" rows:@[
            @[NPPLabel(@"Style theme:"), [self themePopup]],
            @[[NSView new], [self button:@"Style Configurator…" action:@selector(openStyleConfigurator:)]],
        ]],
        [self group:@"Tones" rows:@[@[tones]]],
        // The 12 slots of NppDarkMode::Colors, labelled as upstream labels them.
        [self group:@"Customized Tone" rows:@[
            @[NPPLabel(@"Content background:"), [self colorWell:@"darkModeCustomBackground"],
              NPPLabel(@"Text:"), [self colorWell:@"darkModeCustomText"]],
            @[NPPLabel(@"Hot track item:"), [self colorWell:@"darkModeCustomHotBackground"],
              NPPLabel(@"Darker text:"), [self colorWell:@"darkModeCustomDarkerText"]],
            @[NPPLabel(@"Control background:"), [self colorWell:@"darkModeCustomSofterBackground"],
              NPPLabel(@"Disabled text:"), [self colorWell:@"darkModeCustomDisabledText"]],
            @[NPPLabel(@"Dialog background:"), [self colorWell:@"darkModeCustomPureBackground"],
              NPPLabel(@"Link:"), [self colorWell:@"darkModeCustomLinkText"]],
            @[NPPLabel(@"Error:"), [self colorWell:@"darkModeCustomErrorBackground"],
              NPPLabel(@"Edge:"), [self colorWell:@"darkModeCustomEdge"]],
            @[NPPLabel(@"Edge highlight:"), [self colorWell:@"darkModeCustomHotEdge"],
              NPPLabel(@"Edge disabled:"), [self colorWell:@"darkModeCustomDisabledEdge"]],
            @[[NSView new], [self button:@"Reset" action:@selector(resetDarkModeColors:)]],
        ]],
        [self note:@"The tones colour the surfaces this app draws itself. The window frame, sheets and standard controls follow the system appearance, which macOS owns."],
    ]];
}

- (void)resetDarkModeColors:(id)sender { [NPPPreferences.shared resetDarkModeCustomColors]; }

- (NSPopUpButton *)themePopup {
    NSMutableArray *titles = [@[@"Follow system appearance"] mutableCopy], *values = [@[@""] mutableCopy];
    for (NSString *t in NPPLanguageManager.shared.availableThemeNames ?: @[]) { [titles addObject:t]; [values addObject:t]; }
    return [self popup:@"themeName" titles:titles values:values];
}

- (void)openStyleConfigurator:(id)sender { [NPPPreferences showStyleConfigurator]; }

- (NSView *)marginsPage {
    return [self page:@[
        [self group:@"Fold Margin Style" rows:@[
            @[[self radios:@"foldMarginStyle" titles:@[@"Simple", @"Arrow", @"Circle tree", @"Box tree", @"None"]
                    values:@[@(NPPFoldMarginSimple), @(NPPFoldMarginArrow), @(NPPFoldMarginCircle), @(NPPFoldMarginBox), @(NPPFoldMarginNone)]]],
        ]],
        [self group:@"Border Width" rows:@[
            @[NPPLabel(@"Width:"), [self intField:@"borderWidth" min:0 max:30], [NSTextField labelWithString:@"px"]],
            @[[NSView new], [self check:@"Show border edge" key:@"showBorderEdge"]],
            @[[NSView new], [self note:@"Upstream shows this as \"No edge\": off means the editor is drawn without its outline."]],
        ]],
        [self group:@"Line Number" rows:@[
            @[[self check:@"Display line numbers" key:@"showLineNumbers"]],
            @[[self radios:@"lineNumberDynamicWidth" titles:@[@"Dynamic width", @"Constant width"] values:@[@YES, @NO]]],
        ]],
        [self group:@"Margins" rows:@[
            @[[self check:@"Display bookmark margin" key:@"showBookmarkMargin"]],
            @[[self check:@"Change history: show in the margin" key:@"showChangeHistoryMargin"]],
            @[[self check:@"Change history: show in the text" key:@"changeHistoryIndicator"]],
        ]],
        [self group:@"Vertical Edge" rows:@[
            @[[self check:@"Show vertical edge" key:@"showEdgeLine"]],
            @[NPPLabel(@"Column(s):"), [self textField:@"edgeColumns" width:160]],
            @[[NSView new], [self note:@"One column for a single edge, several separated by spaces for the multi-column edge (e.g. \"80 100 120\")."]],
            @[[NSView new], [self check:@"Background mode" key:@"edgeBackgroundMode"]],
        ]],
        [self group:@"Padding" rows:@[
            @[NPPLabel(@"Left:"), [self intField:@"paddingLeft" min:0 max:9]],
            @[NPPLabel(@"Right:"), [self intField:@"paddingRight" min:0 max:9]],
            @[NPPLabel(@"Distraction Free:"), [self intField:@"distractionFreeDivPart" min:3 max:9]],
            @[[self note:@"Distraction Free divides the full-screen width by this number; the result is the padding put on each side (N++ getDistractionFreePadding)."]],
        ]],
    ]];
}

- (NSView *)newDocumentPage {
    NSMutableArray *names = [NSMutableArray new], *titles = [NSMutableArray new];
    for (NPPLanguage *l in NPPLanguageManager.shared.languages) { [names addObject:l.name]; [titles addObject:l.shortName]; }
    if (names.count == 0) { [names addObject:@"normal"]; [titles addObject:@"Normal Text"]; }

    NSMutableArray *cpTitles = [NSMutableArray new], *cpValues = [NSMutableArray new];
    for (NPPCharset *cs in NPPCharset.allCharsets) {
        [cpTitles addObject:[NSString stringWithFormat:@"%@ — %@", cs.groupName, cs.displayName]];
        [cpValues addObject:@((NSInteger)cs.cfEncoding)];
    }
    if (cpTitles.count == 0) { [cpTitles addObject:@"Western (Windows-1252)"]; [cpValues addObject:@((NSInteger)kCFStringEncodingWindowsLatin1)]; }

    return [self page:@[
        [self group:@"Format (line ending)" rows:@[
            @[[self radios:@"defaultEOL" titles:@[@"Windows (CR LF)", @"Unix (LF)", @"Macintosh (CR)"]
                    values:@[@(NPPEOLWindows), @(NPPEOLUnix), @(NPPEOLMac)]]],
        ]],
        [self group:@"Encoding" rows:@[
            @[[self radios:@"defaultEncoding" titles:@[@"ANSI (other code page)", @"UTF-8", @"UTF-8 with BOM", @"UTF-16 Big Endian with BOM", @"UTF-16 Little Endian with BOM"]
                    values:@[@(NPPEncodingANSI), @(NPPEncodingUTF8), @(NPPEncodingUTF8BOM), @(NPPEncodingUTF16BE), @(NPPEncodingUTF16LE)]]],
            @[NPPLabel(@"Code page:"), [self popup:@"defaultCodepage" titles:cpTitles values:cpValues]],
            @[[NSView new], [self check:@"Apply to opened ANSI files" key:@"openAnsiAsUTF8"]],
        ]],
        [self group:@"Default language" rows:@[
            @[NPPLabel(@"Language:"), [self popup:@"defaultLanguageName" titles:titles values:names]],
        ]],
        [self group:@"At Startup" rows:@[
            @[[self check:@"Always open a new document in addition at startup" key:@"addNewDocumentOnStartup"]],
            @[[self check:@"Use the first line of the document as the untitled tab name" key:@"useContentAsTabName"]],
        ]],
        [self note:@"The code page applies to a new untitled document while it is still empty; converting an existing buffer is Encoding > Character sets."],
    ]];
}

- (NSView *)defaultDirectoryPage {
    NSView *radios = [self radios:@"defaultDirectoryMode" titles:@[@"Follow current document", @"Remember last used directory", @"Always open in a fixed directory"]
                           values:@[@0, @1, @2]];
    return [self page:@[
        [self group:@"Default Open/Save Directory" rows:@[
            @[radios],
            @[NPPLabel(@"Fixed directory:"), [self textField:@"defaultDirectoryPath" width:260],
              [self button:@"Choose…" action:@selector(chooseDefaultDirectory:)]],
        ]],
        [self note:@"Each mode falls back to the others when its own answer is missing, so a panel never opens on somewhere arbitrary."],
    ]];
}

- (void)chooseDefaultDirectory:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES; p.canChooseFiles = NO; p.canCreateDirectories = YES;
    p.title = @"Choose the default Open/Save directory";
    if ([p runModal] == NSModalResponseOK && p.URL.path) NPPPreferences.shared.defaultDirectoryPath = p.URL.path;
}

- (NSView *)recentFilesPage {
    return [self page:@[
        [self group:@"Recent Files History" rows:@[
            @[NPPLabel(@"Max. number of entries:"), [self intField:@"maxRecentFiles" min:0 max:30]],
            @[[NSView new], [self check:@"Check that the files still exist at launch time" key:@"checkRecentFilesAtLaunch"]],
            @[[NSView new], [self button:@"Clear Recent Files List" action:@selector(clearRecentFiles:)]],
        ]],
        [self group:@"Display" rows:@[
            @[[self check:@"In a submenu" key:@"recentFilesInSubmenu"]],
            @[[self radios:@"recentFilesDisplay"
                    titles:@[@"Only the file name", @"Full file name path", @"Customised maximum length"]
                    values:@[@(NPPRecentFilesDisplayFileName), @(NPPRecentFilesDisplayFullPath),
                             @(NPPRecentFilesDisplayCustomLength)]]],
            @[NPPLabel(@"Maximum length:"), [self intField:@"recentFilesCustomLength" min:1 max:259]],
        ]],
        [self note:@"0 entries disables the list entirely. Shortening it drops the oldest entries immediately. Upstream's checkbox is the inverse of the one above, \"Don't check at launch time\"."],
    ]];
}

- (void)clearRecentFiles:(id)sender { [NPPPreferences.shared clearRecentFiles]; }

- (NSView *)fileAssociationPage {
    return [self page:@[[NPPFileAssociationView new]]];
}

- (NSView *)languagePage {
    // ponytail: upstream's two list boxes with < > buttons are a token field here — the same list, typed instead of
    // shuttled, with completion over every language name. Upgrade path only if the list ever needs reordering.
    return [self page:@[
        [self group:@"Language Menu" rows:@[
            @[[self check:@"Make language menu compact" key:@"languageMenuCompact"]],
            @[NPPLabel(@"Hide these:"), [self tokenField:@"excludedLanguageNames" width:300]],
            @[[NSView new], [self note:@"Type a language name (\"C++\") and press return. Hidden languages leave the Language menu; Normal Text always stays."]],
        ]],
        [self group:@"SQL" rows:@[
            @[[self check:@"Treat backslash as escape character for SQL" key:@"sqlBackslashIsEscape"]],
        ]],
    ]];
}

- (NSView *)indentationPage {
    NSMutableArray *titles = [NSMutableArray new], *values = [NSMutableArray new];
    for (NPPLanguage *l in NPPLanguageManager.shared.languages) { [titles addObject:l.shortName]; [values addObject:l.name]; }
    if (titles.count == 0) { [titles addObject:@"Normal Text"]; [values addObject:@"normal"]; }

    _indentLangPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSUInteger i = 0; i < titles.count; i++) {
        [_indentLangPopup addItemWithTitle:titles[i]];
        _indentLangPopup.lastItem.representedObject = values[i];
    }
    _indentLangPopup.target = self; _indentLangPopup.action = @selector(indentLanguageChanged:);

    _indentUseDefault = [NSButton checkboxWithTitle:@"Use default value" target:self action:@selector(indentChanged:)];
    _indentSize = [NSTextField textFieldWithString:@"4"];
    _indentSize.target = self; _indentSize.action = @selector(indentChanged:);
    NSNumberFormatter *nf = [NSNumberFormatter new]; nf.minimum = @1; nf.maximum = @64; nf.allowsFloats = NO;
    _indentSize.formatter = nf;
    [_indentSize.widthAnchor constraintEqualToConstant:60].active = YES;
    _indentUseTab = [NSButton radioButtonWithTitle:@"Tab character" target:self action:@selector(indentChanged:)];
    _indentUseSpace = [NSButton radioButtonWithTitle:@"Space character(s)" target:self action:@selector(indentChanged:)];
    _indentBackspace = [NSButton checkboxWithTitle:@"Backspace key unindents" target:self action:@selector(indentChanged:)];

    return [self page:@[
        [self group:@"Default Indent Settings" rows:@[
            @[NPPLabel(@"Indent size:"), [self intField:@"tabSize" min:1 max:64]],
            @[[NSView new], [self check:@"Replace tabs by spaces" key:@"replaceTabsBySpaces"]],
            @[[NSView new], [self check:@"Backspace key unindents instead of removing a single space" key:@"backspaceUnindent"]],
        ]],
        [self group:@"Per-Language Override" rows:@[
            @[NPPLabel(@"Language:"), _indentLangPopup],
            @[[NSView new], _indentUseDefault],
            @[NPPLabel(@"Indent size:"), _indentSize],
            @[NPPLabel(@"Indent using:"), _indentUseTab],
            @[[NSView new], _indentUseSpace],
            @[[NSView new], _indentBackspace],
        ]],
        [self group:@"Auto-Indent" rows:@[
            @[[self radios:@"autoIndentMode" titles:@[@"None", @"Basic", @"Advanced"]
                    values:@[@(NPPAutoIndentNone), @(NPPAutoIndentBasic), @(NPPAutoIndentAdvanced)]]],
            @[[self note:@"Basic copies the previous line's indent. Advanced (the default) also opens a level after \"{\" or a condition line, lines \"}\" up with its \"{\", and indents after a Python \":\"."]],
        ]],
    ]];
}

- (NSString *)selectedIndentLanguage { return _indentLangPopup.selectedItem.representedObject ?: @"normal"; }

- (void)indentLanguageChanged:(id)sender { [self refreshIndentation]; }

- (void)indentChanged:(id)sender {
    NPPPreferences *p = NPPPreferences.shared;
    NSString *lang = [self selectedIndentLanguage];
    if (_indentUseDefault.state == NSControlStateValueOn) { [p setIndentSettings:nil forLanguageNamed:lang]; }
    else {
        BOOL spaces = (sender == _indentUseSpace) ? YES : (sender == _indentUseTab ? NO : _indentUseSpace.state == NSControlStateValueOn);
        NSInteger size = MAX(1, MIN(64, _indentSize.integerValue));
        [p setIndentSettings:@{@"size": @(size), @"spaces": @(spaces), @"backspaceUnindent": @(_indentBackspace.state == NSControlStateValueOn)}
            forLanguageNamed:lang];
    }
    [self refreshIndentation];
}

- (void)refreshIndentation {
    if (!_indentLangPopup) return;
    NPPPreferences *p = NPPPreferences.shared;
    NSDictionary *o = [p indentSettingsForLanguageNamed:[self selectedIndentLanguage]];
    BOOL useDefault = (o == nil);
    _indentUseDefault.state = useDefault ? NSControlStateValueOn : NSControlStateValueOff;
    _indentSize.integerValue = useDefault ? p.tabSize : [o[@"size"] integerValue];
    BOOL spaces = useDefault ? p.replaceTabsBySpaces : [o[@"spaces"] boolValue];
    _indentUseTab.state = spaces ? NSControlStateValueOff : NSControlStateValueOn;
    _indentUseSpace.state = spaces ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL bsu = useDefault ? p.backspaceUnindent : [o[@"backspaceUnindent"] boolValue];
    _indentBackspace.state = bsu ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSControl *c in @[_indentSize, _indentUseTab, _indentUseSpace, _indentBackspace]) c.enabled = !useDefault;
}

- (NSView *)highlightingPage {
    return [self page:@[
        [self group:@"Smart Highlighting" rows:@[
            @[[self check:@"Enable" key:@"smartHighlighting"]],
            @[[self check:@"Highlight another view" key:@"smartHighlightAnotherView"]],
            @[[self check:@"Match case" key:@"smartHighlightMatchCase"]],
            @[[self check:@"Match whole word only" key:@"smartHighlightWholeWord"]],
            @[[self check:@"Use the Find dialog's settings" key:@"smartHighlightUseFindSettings"]],
        ]],
        [self group:@"Style All Occurrences of Token" rows:@[
            @[[self check:@"Match case" key:@"markAllMatchCase"]],
            @[[self check:@"Match whole word only" key:@"markAllWholeWord"]],
        ]],
        [self group:@"Matching" rows:@[
            @[[self check:@"Highlight matching braces" key:@"braceHighlighting"]],
            @[[self check:@"Highlight matching tags" key:@"tagMatchHighlight"]],
            @[[self check:@"Highlight the tag's attributes too" key:@"tagAttrHighlight"]],
            @[[self check:@"Highlight comment/PHP/ASP zone" key:@"highlightNonHTMLZone"]],
            @[[self note:@"Tag matching applies to HTML, XML and the other markup languages."]],
        ]],
    ]];
}

// N++'s IDC_COMBO_VARLIST, in its order; the tokens are the ones NPPPrintRenderer expands.
static NSArray<NSArray<NSString *> *> *NPPPrintVariables(void) {
    return @[@[@"Full file name path", @"$(FULL_CURRENT_PATH)"], @[@"File name", @"$(FILE_NAME)"],
             @[@"File directory", @"$(CURRENT_DIRECTORY)"], @[@"Name part", @"$(NAME_PART)"],
             @[@"Extension part", @"$(EXT_PART)"], @[@"Page", @"$(CURRENT_PAGE)"],
             @[@"Short date format", @"$(SHORT_DATE)"], @[@"Long date format", @"$(LONG_DATE)"],
             @[@"Time", @"$(TIME)"]];
}

- (NSTextField *)printPartField:(NSString *)key {
    NSTextField *f = [self textField:key width:230];
    f.delegate = (id<NSTextFieldDelegate>)self;     // -controlTextDidBeginEditing: makes it the Add button's target
    [_printPartFields addObject:f];
    return f;
}

- (NSPopUpButton *)printFontPopup:(NSString *)key {
    NSMutableArray<NSString *> *titles = [@[@"Default"] mutableCopy];
    NSMutableArray *values = [@[@""] mutableCopy];
    for (NSString *family in [NSFontManager.sharedFontManager availableFontFamilies]) {
        [titles addObject:family]; [values addObject:family];
    }
    return [self popup:key titles:titles values:values];
}

- (NSView *)printPage {
    _printPartFields = [NSMutableArray array];
    _printVarPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSArray<NSString *> *v in NPPPrintVariables()) {
        [_printVarPopup addItemWithTitle:v[0]];
        _printVarPopup.lastItem.representedObject = v[1];
    }
    _printVarPreview = [NSTextField labelWithString:@""];
    _printVarPreview.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_printVarPreview.widthAnchor constraintEqualToConstant:300].active = YES;

    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    for (NSInteger s = 6; s <= 24; ++s) [sizes addObject:@(s)];
    NSMutableArray<NSString *> *sizeTitles = [@[@"Default"] mutableCopy];
    NSMutableArray *sizeValues = [@[@0] mutableCopy];
    for (NSNumber *s in sizes) { [sizeTitles addObject:s.stringValue]; [sizeValues addObject:s]; }

    NSView *page = [self page:@[
        [self group:@"Colour Options" rows:@[
            @[[self radios:@"printColourMode" titles:@[@"WYSIWYG", @"Invert", @"Black on white", @"No background colour"]
                    values:@[@(SC_PRINT_NORMAL), @(SC_PRINT_INVERTLIGHT), @(SC_PRINT_BLACKONWHITE), @(SC_PRINT_COLOURONWHITE)]]],
        ]],
        [self group:@"Options" rows:@[
            @[[self check:@"Print line numbers" key:@"printLineNumbers"]],
            @[[self check:@"Print formfeed as page break" key:@"printFormFeedPageBreak"]],
            @[NPPLabel(@"Magnification:"), [self intField:@"printMagnification" min:-10 max:10]],
        ]],
        // N++ PrintSettings::_marge. 0 on every side leaves the margins to the macOS print panel.
        [self group:@"Margin Setting (unit: mm)" rows:@[
            @[NPPLabel(@"Top:"), [self intField:@"printMarginTop" min:0 max:100],
              NPPLabel(@"Bottom:"), [self intField:@"printMarginBottom" min:0 max:100]],
            @[NPPLabel(@"Left:"), [self intField:@"printMarginLeft" min:0 max:100],
              NPPLabel(@"Right:"), [self intField:@"printMarginRight" min:0 max:100]],
            @[[NSView new], [self note:@"All four at 0 = use the margins from the macOS print panel."]],
        ]],
        [self group:@"Header and Footer" rows:@[
            @[NPPLabel(@"Variable:"), _printVarPopup, [self button:@"Add" action:@selector(addPrintVariable:)]],
            @[NPPLabel(@"Editing:"), _printVarPreview],
            @[[NSView new], [self note:@"Add inserts the variable at the caret of the header or footer field you last typed in."]],
        ]],
        [self group:@"Header" rows:@[
            @[NPPLabel(@"Left:"), [self printPartField:@"printHeaderLeft"]],
            @[NPPLabel(@"Middle:"), [self printPartField:@"printHeaderMiddle"]],
            @[NPPLabel(@"Right:"), [self printPartField:@"printHeaderRight"]],
            @[NPPLabel(@"Font:"), [self printFontPopup:@"printHeaderFontName"],
              [self popup:@"printHeaderFontSize" titles:sizeTitles values:sizeValues]],
            @[[NSView new], [self hstack:@[[self check:@"Bold" key:@"printHeaderFontBold"],
                                           [self check:@"Italic" key:@"printHeaderFontItalic"]]]],
        ]],
        [self group:@"Footer" rows:@[
            @[NPPLabel(@"Left:"), [self printPartField:@"printFooterLeft"]],
            @[NPPLabel(@"Middle:"), [self printPartField:@"printFooterMiddle"]],
            @[NPPLabel(@"Right:"), [self printPartField:@"printFooterRight"]],
            @[NPPLabel(@"Font:"), [self printFontPopup:@"printFooterFontName"],
              [self popup:@"printFooterFontSize" titles:sizeTitles values:sizeValues]],
            @[[NSView new], [self hstack:@[[self check:@"Bold" key:@"printFooterFontBold"],
                                           [self check:@"Italic" key:@"printFooterFontItalic"]]]],
        ]],
    ]];
    _printVarTarget = _printPartFields.firstObject;   // Add always has somewhere to go
    return page;
}

- (void)controlTextDidBeginEditing:(NSNotification *)n {
    if ([_printPartFields containsObject:n.object]) {
        _printVarTarget = n.object;
        _printVarPreview.stringValue = _printVarTarget.stringValue ?: @"";
    }
}

// N++ IDC_BUTTON_ADDVAR: insert the chosen variable at the caret of the field being edited. The field's value only
// reaches NPPPreferences when editing ends, so write it back through the same action the field itself uses.
- (void)addPrintVariable:(id)sender {
    NSTextField *target = _printVarTarget ?: _printPartFields.firstObject;
    NSString *var = _printVarPopup.selectedItem.representedObject;
    if (!target || var.length == 0) return;
    NSText *editor = target.currentEditor;
    NSString *text = target.stringValue ?: @"";
    NSUInteger at = editor ? NSMaxRange(editor.selectedRange) : text.length;
    at = MIN(at, text.length);
    target.stringValue = [text stringByReplacingCharactersInRange:NSMakeRange(at, 0) withString:var];
    [self stringFieldChanged:target];               // stores it, exactly as pressing return in the field would
    _printVarPreview.stringValue = target.stringValue;
    // -stringFieldChanged: posts the change, which runs -refresh and rewrites the field; re-fetch the editor rather
    // than trusting the one captured above, and put the caret after what was just inserted.
    [target.currentEditor setSelectedRange:NSMakeRange(at + var.length, 0)];
}

- (NSView *)searchingPage {
    // The per-search switches (match case, whole word, search mode, wrap around) stay in the find panel, which
    // persists them itself; what belongs here is what N++ puts here — how the panel behaves when it opens, what
    // Replace All confirms, and what the results window shows.
    return [self page:@[
        [self group:@"When the Find Panel Is Opened" rows:@[
            @[NPPLabel(@"Minimum size for auto-checking \"In selection\":"),
              [self intField:@"inSelectionAutocheckThreshold" min:0 max:1000000], [NSTextField labelWithString:@"characters"]],
            @[NPPLabel(@"Max. characters to auto-fill Find from the selection:"),
              [self intField:@"fillFindWhatThreshold" min:0 max:1000000]],
            @[[NSView new], [self check:@"Use a monospaced font in the Find panel" key:@"monospacedFontFindDlg"]],
            @[[NSView new], [self check:@"Fill the Find field with the selected text" key:@"fillFindFieldWithSelected"]],
            @[[NSView new], [self check:@"Select the word under the caret when nothing is selected" key:@"fillFindFieldSelectCaret"]],
            @[[NSView new], [self check:@"Fill the Find in Files directory from the active document" key:@"fillDirFieldFromActiveDoc"]],
            @[[NSView new], [self check:@"Find in Files stays open after a search that outputs to the results window" key:@"findDlgAlwaysVisible"]],
        ]],
        [self group:@"Replace" rows:@[
            @[[self check:@"Confirm Replace All in All Opened Documents" key:@"confirmReplaceInAllOpenDocs"]],
            @[[self check:@"Replace: do not move to the following occurrence" key:@"replaceStopsWithoutFindingNext"]],
        ]],
        [self group:@"Results" rows:@[
            @[[self check:@"Search Result window: show only one entry per found line" key:@"finderShowOnlyOneEntryPerFoundLine"]],
            @[[self check:@"Find in Files: prefer the on-disk file content over open buffers" key:@"findInFilesIgnoreOpenedFiles"]],
        ]],
        [self group:@"Find History" rows:@[
            @[[self button:@"Clear Find and Replace History" action:@selector(clearFindHistory:)]],
        ]],
        [self note:@"Match case, whole word, regular expression and wrap around live in the Find panel itself and are remembered there."],
    ]];
}

- (void)clearFindHistory:(id)sender {
    for (NSString *k in @[@"NPPFindHistory", @"NPPReplaceHistory", @"NPPFindInFilesFindHistory",
                          @"NPPFindInFilesReplaceHistory", @"NPPFindInFilesDirectoryHistory", @"NPPFindInFilesFilters"])
        [D() removeObjectForKey:k];
    // The find panels read their history when they are built, so an already-open panel keeps what it has on screen.
    NSAlert *a = [NSAlert new];
    a.messageText = @"Find and Replace history cleared";
    a.informativeText = @"Open find panels keep the entries already on screen until they are reopened.";
    [a runModal];
}

- (NSView *)backupPage {
    id backup = NPPModuleShared(@"NPPBackupManager");
    NSString *snapshotDir = @"—";
    if ([backup respondsToSelector:@selector(snapshotDirectory)]) {
        NSURL *u = [backup valueForKey:@"snapshotDirectory"];
        if (u.path) snapshotDir = u.path;
    }
    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:[self group:@"Session Snapshot and Periodic Backup" rows:@[
        @[[self check:@"Remember the current session for the next launch" key:@"rememberLastSession"]],
        @[[self check:@"Enable session snapshot and periodic backup" key:@"backupSnapshotEnabled"]],
        @[NPPLabel(@"Every"), [self intField:@"backupSnapshotInterval" min:1 max:3600], [NSTextField labelWithString:@"seconds"]],
        @[NPPLabel(@"Snapshot path:"), [self note:snapshotDir]],
        @[[NSView new], [self check:@"Remember inaccessible files from a past session" key:@"keepSessionAbsentFileEntries"]],
    ]]];
    [sections addObject:[self group:@"Backup on Save" rows:@[
        @[[self radios:@"backupMode" titles:@[@"None", @"Simple backup", @"Verbose backup"] values:@[@0, @1, @2]]],
        @[NPPLabel(@"Custom directory:"), [self textField:@"backupDirectory" width:260],
          [self button:@"Choose…" action:@selector(chooseBackupDirectory:)]],
        @[[NSView new], [self note:@"Empty = beside the saved file (simple) or in nppBackup/ next to it (verbose)."]],
    ]]];
    if (!backup) [sections addObject:[self note:@"NPPBackupManager is not present in this build; these settings are stored but nothing acts on them."]];
    return [self page:sections];
}

- (void)chooseBackupDirectory:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES; p.canChooseFiles = NO; p.canCreateDirectories = YES;
    p.title = @"Choose a backup directory";
    if ([p runModal] == NSModalResponseOK && p.URL.path) NPPPreferences.shared.backupDirectory = p.URL.path;
}

- (NSView *)autoCompletionPage {
    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:[self group:@"Auto-Completion" rows:@[
        @[[self check:@"Enable auto-completion on each input" key:@"autoCompleteEnabled"]],
        @[[self radios:@"autoCompleteMode" titles:@[@"Function completion", @"Word completion", @"Function and word completion"]
                values:@[@1, @2, @3]]],
        @[NPPLabel(@"From the"), [self intField:@"autoCompleteTriggerLength" min:1 max:9], [NSTextField labelWithString:@"th character"]],
        @[[NSView new], [self check:@"Ignore numbers" key:@"autoCompleteIgnoreNumbers"]],
        @[[NSView new], [self check:@"Make the auto-completion list brief" key:@"autoCompleteBrief"]],
        @[[NSView new], [self check:@"Function parameter hints on input" key:@"autoCompleteFunctionParameterHints"]],
    ]]];
    [sections addObject:[self group:@"Insert Selection With" rows:@[
        @[[self check:@"TAB" key:@"autoCompleteInsertWithTab"]],
        @[[self check:@"ENTER" key:@"autoCompleteInsertWithEnter"]],
        @[[self note:@"With both off the list is dismissed by typing on; the highlighted entry is then never inserted."]],
    ]]];
    [sections addObject:[self group:@"Auto-Insert" rows:@[
        @[[self check:@"Close html/xml tags automatically" key:@"autoCompleteInsertHTMLCloseTag"]],
        @[[self check:@"Insert the matching ( [ { \" '" key:@"autoCloseBrackets"]],
    ]]];
    // N++ MatchedPairConf. Which pairs the switch above inserts; all of it is NPPDocument -charAdded:.
    [sections addObject:[self group:@"Matched Pairs" rows:@[
        @[[self check:@"( )" key:@"matchedPairParentheses"]],
        @[[self check:@"[ ]" key:@"matchedPairBrackets"]],
        @[[self check:@"{ }" key:@"matchedPairCurlyBrackets"]],
        @[[self check:@"' '" key:@"matchedPairQuotes"]],
        @[[self check:@"\" \"" key:@"matchedPairDoubleQuotes"]],
        @[NPPLabel(@"Your own:"), [self tokenField:@"matchedPairsUserDefined" width:220]],
        @[[NSView new], [self note:@"One pair per token, opening character then closing: \"<>\". Anything that is not two ASCII characters is dropped."]],
    ]]];
    if (!NPPPreferences.shared.autoCompletionModuleAvailable)
        [sections addObject:[self note:@"NPPAutoCompletion is not present in this build, so the auto-completion settings are disabled."]];
    return [self page:sections];
}

- (NSView *)multiInstancePage {
    _dateFormatPreview = [NSTextField labelWithString:@""];
    return [self page:@[
        [self group:@"Multi-Instance Settings" rows:@[
            @[[self radios:@"multiInstanceMode"
                    titles:@[@"Default (mono-instance)", @"Always in multi-instance mode",
                             @"Open a session in a new instance (and save it automatically on exit)"]
                    values:@[@(NPPMultiInstanceMono), @(NPPMultiInstanceAlways), @(NPPMultiInstanceSessionInNewInstance)]]],
            @[[self note:@"A second instance is a second copy of the app (\"open -n\"); the Dock and Finder always reuse the running one, so this decides what File ▸ Open in New Instance and opening a session do. Takes effect at the next launch."]],
        ]],
        [self group:@"Customise Insert Date Time" rows:@[
            @[NPPLabel(@"Custom format:"), [self textField:@"dateTimeFormat" width:240]],
            @[NPPLabel(@"Preview:"), _dateFormatPreview],
            @[[NSView new], [self check:@"Reverse the default date-time order (short and long formats)" key:@"dateTimeReverseDefaultOrder"]],
            @[[NSView new], [self note:@"Unicode date field symbols: yyyy MM dd HH mm ss, e.g. \"MMM d, yyyy  h:mm a\". Used by Edit > Insert > Date Time (customized)."]],
        ]],
        // N++ "Panel State and [-nosession]".
        [self group:@"Panel State in a New Instance" rows:@[
            @[[self check:@"Clipboard History" key:@"clipboardHistoryPanelKeepState"]],
            @[[self check:@"Document List" key:@"docListPanelKeepState"]],
            @[[self check:@"Character Panel" key:@"charPanelKeepState"]],
            @[[self check:@"Folder as Workspace" key:@"fileBrowserPanelKeepState"]],
            @[[self check:@"Project Panels" key:@"projectPanelKeepState"]],
            @[[self check:@"Document Map" key:@"docMapPanelKeepState"]],
            @[[self check:@"Function List" key:@"funcListPanelKeepState"]],
            @[[self unavailable:[self check:@"Plugin Panels" key:@"pluginPanelKeepState"]
                        because:@"Nothing reads this setting: this port has no plugin system, so NPPEditorWindowController has no plugin panel to reopen."]],
            @[[self note:@"A ticked panel reopens even when the session is not restored — in another instance, or after launching with -nosession."]],
        ]],
    ]];
}

- (NSView *)delimiterPage {
    return [self page:@[
        [self group:@"Word Character List" rows:@[
            @[[self radios:@"useDefaultWordChars"
                    titles:@[@"Use the language's default word characters", @"Add these characters as part of a word"]
                    values:@[@YES, @NO]]],
            @[NPPLabel(@"Characters:"), [self textField:@"customWordChars" width:240]],
            @[[NSView new], [self note:@"Added to whatever the current lexer already counts as a word character. ASCII only — Scintilla's word-character set is byte based."]],
        ]],
        [self group:@"Delimiter Selection Settings (⌃ + double-click)" rows:@[
            @[NPPLabel(@"Open:"), [self textField:@"delimiterOpen" width:40],
              NPPLabel(@"Close:"), [self textField:@"delimiterClose" width:40]],
            @[[NSView new], [self check:@"Allow the selection to span several lines" key:@"delimiterSelectionOnEntireDocument"]],
            @[[NSView new], [self note:@"One character each; anything longer is cut to its first character. ⌃double-click inside the pair selects what is between them."]],
        ]],
    ]];
}

- (NSView *)performancePage {
    // N++ LargeFileRestriction. Largeness is decided once, when the file is loaded, so changing the threshold
    // applies to the next document opened; the allow* switches take effect on the documents already open.
    return [self page:@[
        [self group:@"Large File Restriction" rows:@[
            @[[self check:@"Enable large file restriction" key:@"largeFileRestrictionEnabled"]],
            @[NPPLabel(@"Define large file size:"), [self intField:@"largeFileSizeMB" min:1 max:20000], [NSTextField labelWithString:@"MB"]],
            @[[NSView new], [self check:@"Deactivate word wrap globally" key:@"largeFileDeactivateWordWrap"]],
            @[[NSView new], [self check:@"Allow auto-completion" key:@"largeFileAllowAutoCompletion"]],
            @[[NSView new], [self check:@"Allow brace match" key:@"largeFileAllowBraceMatch"]],
            @[[NSView new], [self check:@"Allow smart highlighting" key:@"largeFileAllowSmartHilite"]],
            @[[NSView new], [self check:@"Allow clickable links" key:@"largeFileAllowClickableLink"]],
            @[[NSView new], [self note:@"A file over the limit is opened without syntax highlighting; the three switches above decide what else stays on. The size is read when a file is opened, so it applies to the next one."]],
        ]],
        [self group:@"Huge Files" rows:@[
            @[[self check:@"Do not warn before opening a file of 2 GB or more" key:@"largeFileSuppress2GBWarning"]],
        ]],
    ]];
}

- (NSView *)cloudAndLinkPage {
    return [self page:@[
        // N++ "Settings on cloud" is a directory its config.xml is read from and written to, so a second machine
        // pointed at the same synced folder shares the settings. The macOS equivalent is exactly that: a settings
        // directory that overrides NSUserDefaults, which -settingsDir= also sets.
        [self group:@"Settings on Cloud" rows:@[
            @[[self radios:@"settingsDirectoryEnabled"
                    titles:@[@"No cloud (store settings with the user account)",
                             @"Read and write the settings in this directory:"]
                    values:@[@NO, @YES]]],
            @[NPPLabel(@"Directory:"), [self textField:@"settingsDirectory" width:260],
              [self button:@"Choose…" action:@selector(chooseSettingsDirectory:)]],
            @[[NSView new], [self note:@"Point it at a synced folder (iCloud Drive, Dropbox…) to share the settings between machines. Takes effect at the next launch; -settingsDir= on the command line wins over it for that launch."]],
        ]],
        [self group:@"Clickable Links" rows:@[
            @[[self radios:@"styleURL"
                    titles:@[@"No clickable links", @"No underline (marked on hover)", @"Underline",
                             @"No underline, full box on hover", @"Underline, full box on hover"]
                    values:@[@(NPPURLStyleDisabled), @(NPPURLStyleForegroundPlain), @(NPPURLStyleForegroundUnderline),
                             @(NPPURLStyleBackgroundPlain), @(NPPURLStyleBackgroundUnderline)]]],
            @[NPPLabel(@"URI schemes:"), [self textField:@"uriSchemes" width:300]],
            @[[NSView new], [self note:@"Added to the built-in http:// https:// ftp:// file:// mailto:, separated by spaces. Double-click a link to open it."]],
        ]],
    ]];
}

- (void)chooseSettingsDirectory:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES; p.canChooseFiles = NO; p.canCreateDirectories = YES;
    p.title = @"Choose the settings directory";
    if ([p runModal] == NSModalResponseOK && p.URL.path) NPPPreferences.shared.settingsDirectory = p.URL.path;
}

- (NSView *)searchEnginePage {
    return [self page:@[
        [self group:@"Search Engine (for Edit > On Selection > Search on Internet)" rows:@[
            @[[self radios:@"searchEngine"
                    titles:@[@"DuckDuckGo", @"Google", @"Bing", @"Yahoo!", @"Stack Overflow", @"Custom"]
                    values:@[@(NPPSearchEngineDuckDuckGo), @(NPPSearchEngineGoogle), @(NPPSearchEngineBing),
                             @(NPPSearchEngineYahoo), @(NPPSearchEngineStackOverflow), @(NPPSearchEngineCustom)]]],
            @[NPPLabel(@"Custom URL:"), [self textField:@"searchEngineCustom" width:300]],
            @[[NSView new], [self note:@"Example: https://www.google.com/search?q=$(CURRENT_WORD)"]],
        ]],
    ]];
}

- (NSView *)miscPage {
    NSPopUpButton *detect = [self popup:@"fileAutoDetection"
        titles:@[@"Disabled", @"Enable (ask before reloading)", @"Enable and update silently", @"Enable, update silently and scroll to the last line"]
        values:@[@(NPPFileAutoDetectionDisabled), @(NPPFileAutoDetectionEnabled), @(NPPFileAutoDetectionSilent), @(NPPFileAutoDetectionSilentGoToEnd)]];

    NSPopUpButton *tray = [self popup:@"systemTrayAction"
        titles:@[@"Do not minimize to the system tray", @"Minimize to the system tray",
                 @"Close to the system tray", @"Minimize and close to the system tray"]
        values:@[@(NPPSystemTrayNone), @(NPPSystemTrayMinimize), @(NPPSystemTrayClose), @(NPPSystemTrayMinimizeAndClose)]];
    [self unavailable:tray because:@"macOS has no system tray. The nearest equivalents — the Dock icon and a menu-bar extra — are not a window-hiding target, so there is nothing for this to do."];

    NSPopUpButton *rendering = [self popup:@"renderingMode"
        titles:@[@"GDI", @"DirectWrite", @"DirectWrite (retain)", @"DirectWrite (DC)", @"DirectWrite (DX11)"]
        values:@[@(NPPRenderingDefault), @(NPPRenderingDirectWrite), @(NPPRenderingDirectWriteRetain),
                 @(NPPRenderingDirectWriteDC), @(NPPRenderingDirectWriteDX11)]];
    [self unavailable:rendering because:@"Every choice here is a Windows text back end. Scintilla's Cocoa build has one renderer (Core Text), so there is nothing to switch between."];

    NSPopUpButton *updater = [self popup:@"autoUpdateMode"
        titles:@[@"Disabled", @"Check at startup", @"Check at exit"]
        values:@[@(NPPAutoUpdateDisabled), @(NPPAutoUpdateOnStartup), @(NPPAutoUpdateOnExit)]];
    [self unavailable:updater because:@"This port has no update channel: there is no appcast to check and no updater to run."];

    return [self page:@[
        [self group:@"File Status Auto-Detection" rows:@[
            @[detect],
        ]],
        [self group:@"Files" rows:@[
            @[[self check:@"Autodetect character encoding (uchardet)" key:@"detectEncodingWithUchardet"]],
            @[[self check:@"Trim trailing white space on save" key:@"trimTrailingSpaceOnSave"]],
            @[[self check:@"Enable the Save All confirmation dialog" key:@"saveAllConfirm"]],
            @[[self check:@"Allow loading symlinks in the Folder as Workspace panel" key:@"fawAllowSymlink"]],
            @[NPPLabel(@"Session file extension:"), [self textField:@"sessionFileExtension" width:80]],
            @[NPPLabel(@"Workspace file extension:"), [self textField:@"workspaceFileExtension" width:80]],
            @[[NSView new], [self note:@"Extensions without the leading dot, e.g. \"session\". Empty keeps the default file type in the save panel."]],
        ]],
        [self group:@"Document Switching" rows:@[
            @[[self check:@"Show the document list on ⌃Tab" key:@"documentSwitcher"]],
            @[[self check:@"Enable MRU behaviour (most recently used order)" key:@"documentSwitcherMRU"]],
            @[[self note:@"MRU off: ⌃Tab and ⇧⌃Tab step through the tabs in the order they are shown."]],
        ]],
        [self group:@"Document Peeker" rows:@[
            @[[self check:@"Peek on tab" key:@"tabPeekOnTab"]],
            @[[self check:@"Peek on the document map" key:@"peekOnDocumentMap"]],
        ]],
        [self group:@"Folder Dropping" rows:@[
            @[[self check:@"Open all files of a dropped folder instead of adding it as a workspace" key:@"folderDroppedOpenFiles"]],
        ]],
        [self group:@"Appearance & Sound" rows:@[
            @[[self check:@"Mute all sounds" key:@"muteAllSounds"]],
            @[[self check:@"Show only the file name in the title bar" key:@"shortTitleBar"]],
        ]],
        [self group:@"No macOS Equivalent" rows:@[
            @[NPPLabel(@"System tray:"), tray],
            @[NPPLabel(@"Rendering mode:"), rendering],
            @[NPPLabel(@"Auto-updater:"), updater],
            @[[NSView new], [self note:@"Shown disabled rather than hidden, so it is clear the setting exists upstream and why it does nothing here. Hover for the reason."]],
        ]],
    ]];
}

@end

#pragma mark - File association

// macOS equivalent of N++'s "File Association": make this app the default handler for a file extension.
// -setDefaultApplicationAtURL:toOpenContentType: is the macOS 12 replacement for
// LSSetDefaultRoleHandlerForContentType() and reports a real error instead of an OSStatus.
@implementation NPPFileAssociationView {
    NSTableView *_table;
    NSMutableArray<NSMutableDictionary *> *_rows;
    NSTextField *_status;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _rows = [NSMutableArray array];
    for (NSString *ext in [self candidateExtensions])
        [_rows addObject:[@{@"ext": ext, @"on": @NO} mutableCopy]];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *use = [[NSTableColumn alloc] initWithIdentifier:@"on"];   use.title = @"";          use.width = 24;
    NSTableColumn *ext = [[NSTableColumn alloc] initWithIdentifier:@"ext"];  ext.title = @"Extension"; ext.width = 90;
    NSTableColumn *app = [[NSTableColumn alloc] initWithIdentifier:@"app"];  app.title = @"Opens with"; app.width = 220;
    [_table addTableColumn:use]; [_table addTableColumn:ext]; [_table addTableColumn:app];
    _table.dataSource = (id)self;
    _table.delegate = (id)self;
    _table.allowsMultipleSelection = YES;
    sv.documentView = _table;

    NSButton *assign = [NSButton buttonWithTitle:@"Make Notepad++ the Default for Checked Extensions"
                                          target:self action:@selector(assignChecked:)];
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshHandlers:)];
    _status = [NSTextField wrappingLabelWithString:@""];
    _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _status.textColor = NSColor.secondaryLabelColor;

    NSStackView *buttons = [NSStackView stackViewWithViews:@[assign, refresh]];
    buttons.spacing = 8;
    NSStackView *stack = [NSStackView stackViewWithViews:@[sv, buttons, _status]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [sv.widthAnchor constraintGreaterThanOrEqualToConstant:380],
        [sv.heightAnchor constraintGreaterThanOrEqualToConstant:260],
        [sv.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
    ]];
    [self refreshHandlers:nil];
    return self;
}

// Every extension the language table knows about, deduplicated; that is the macOS analogue of N++'s
// "supported extensions" tree.
- (NSArray<NSString *> *)candidateExtensions {
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (NPPLanguage *l in NPPLanguageManager.shared.languages)
        for (NSString *e in l.extensions)
            if (e.length && e.length <= 12) [set addObject:e.lowercaseString];
    if (set.count == 0) [set addObjectsFromArray:@[@"txt", @"log", @"ini", @"md"]];
    return [set.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (nullable UTType *)typeForRow:(NSMutableDictionary *)row {
    return [UTType typeWithFilenameExtension:row[@"ext"]];
}

// The language table knows ~250 extensions and each one is a Launch Services query, so the lookup never runs on the
// main thread: the Preferences window builds this page eagerly (so does the headless dialog sweep) and a quarter of
// a second of stall per open is a quarter of a second too many. The table shows "—" until the answers land.
- (void)refreshHandlers:(id)sender {
    NSArray<NSString *> *exts = [_rows valueForKey:@"ext"];   // immutable snapshot for the worker
    __weak NPPFileAssociationView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSWorkspace *ws = NSWorkspace.sharedWorkspace;
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:exts.count];
        for (NSString *ext in exts) {
            UTType *t = [UTType typeWithFilenameExtension:ext];
            NSURL *app = t ? [ws URLForApplicationToOpenContentType:t] : nil;
            [names addObject:app ? ([NSFileManager.defaultManager displayNameAtPath:app.path] ?: app.lastPathComponent) : @"—"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applyHandlerNames:names forExtensions:exts]; });
    });
}

- (void)applyHandlerNames:(NSArray<NSString *> *)names forExtensions:(NSArray<NSString *> *)exts {
    for (NSUInteger i = 0; i < _rows.count && i < exts.count; ++i)
        if ([_rows[i][@"ext"] isEqualToString:exts[i]]) _rows[i][@"app"] = names[i];
    [_table reloadData];
}

- (void)assignChecked:(id)sender {
    NSURL *me = NSBundle.mainBundle.bundleURL;
    NSMutableArray<NSMutableDictionary *> *wanted = [NSMutableArray array];
    for (NSMutableDictionary *row in _rows) if ([row[@"on"] boolValue]) [wanted addObject:row];
    if (wanted.count == 0) { _status.stringValue = @"Tick the extensions to claim first."; return; }

    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    NSMutableArray<NSMutableDictionary *> *typed = [NSMutableArray array];
    for (NSMutableDictionary *row in wanted) {
        if ([self typeForRow:row]) [typed addObject:row]; else [failed addObject:row[@"ext"]];
    }
    if (typed.count == 0) { _status.stringValue = @"No usable content type for the chosen extensions."; return; }

    _status.stringValue = [NSString stringWithFormat:@"Claiming %lu extension(s)…", (unsigned long)typed.count];
    const NSUInteger total = typed.count;
    __block NSUInteger done = 0;
    for (NSMutableDictionary *row in typed) {
        [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:me toOpenContentType:[self typeForRow:row]
                                             completionHandler:^(NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err) [failed addObject:row[@"ext"]];
                if (++done < total) return;
                [self refreshHandlers:nil];
                self->_status.stringValue = failed.count
                    ? [NSString stringWithFormat:@"Could not claim: %@", [failed componentsJoinedByString:@", "]]
                    : @"Done. macOS may ask you to confirm the change the first time such a file is opened.";
            });
        }];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)_rows.count; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSMutableDictionary *r = _rows[(NSUInteger)row];
    if ([col.identifier isEqualToString:@"on"]) {
        NSButton *b = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleRow:)];
        b.state = [r[@"on"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        b.tag = row;
        return b;
    }
    NSTextField *f = [NSTextField labelWithString:([col.identifier isEqualToString:@"ext"] ? r[@"ext"] : (r[@"app"] ?: @"—"))];
    return f;
}

- (void)toggleRow:(NSButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)_rows.count) return;
    _rows[(NSUInteger)b.tag][@"on"] = @(b.state == NSControlStateValueOn);
}

@end

@implementation NPPFileAssociationController

+ (instancetype)shared {
    static NPPFileAssociationController *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPFileAssociationController alloc] initWithWindow:nil]; });
    return s;
}

- (instancetype)initWithWindow:(NSWindow *)w {
    NPPPrefsWindow *win = [[NPPPrefsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"File Association";
    win.releasedWhenClosed = NO;
    [win center];
    if (!(self = [super initWithWindow:win])) return nil;
    self.windowFrameAutosaveName = @"NPPFileAssociationWindow";
    NPPFileAssociationView *v = [NPPFileAssociationView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [win.contentView addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:win.contentView.topAnchor constant:14],
        [v.leadingAnchor constraintEqualToAnchor:win.contentView.leadingAnchor constant:14],
        [v.trailingAnchor constraintEqualToAnchor:win.contentView.trailingAnchor constant:-14],
        [v.bottomAnchor constraintEqualToAnchor:win.contentView.bottomAnchor constant:-14],
    ]];
    return self;
}

- (void)showWindow:(id)sender { [super showWindow:sender]; [self.window makeKeyAndOrderFront:nil]; }

@end

#pragma mark - Editor context menu editor

// N++ keeps this list in contextMenu.xml and makes you edit the file; here the list is edited directly and the
// editors pick the new menu up immediately (NPPPreferences installs it as the ScintillaView's -menu).
@implementation NPPContextMenuEditorController {
    NSTableView *_table;
    NSPopUpButton *_available;
    NSMutableArray<NSNumber *> *_entries;
    NSDictionary<NSNumber *, NSString *> *_titles;
}

+ (instancetype)shared {
    static NPPContextMenuEditorController *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPContextMenuEditorController alloc] initWithWindow:nil]; });
    return s;
}

- (instancetype)initWithWindow:(NSWindow *)w {
    NPPPrefsWindow *win = [[NPPPrefsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 460)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"Edit Popup ContextMenu";
    win.releasedWhenClosed = NO;
    [win center];
    if (!(self = [super initWithWindow:win])) return nil;
    self.windowFrameAutosaveName = @"NPPContextMenuWindow";
    _entries = [NPPPreferences.shared.contextMenuCommandTags mutableCopy];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    c.title = @"Context menu";
    [_table addTableColumn:c];
    _table.dataSource = (id)self;
    _table.delegate = (id)self;
    sv.documentView = _table;

    _available = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_available.widthAnchor constraintEqualToConstant:280].active = YES;

    NSStackView *addRow = [NSStackView stackViewWithViews:@[
        _available,
        [NSButton buttonWithTitle:@"Add" target:self action:@selector(add:)],
        [NSButton buttonWithTitle:@"Add Separator" target:self action:@selector(addSeparator:)]]];
    addRow.spacing = 8;
    NSStackView *editRow = [NSStackView stackViewWithViews:@[
        [NSButton buttonWithTitle:@"Remove" target:self action:@selector(remove:)],
        [NSButton buttonWithTitle:@"Move Up" target:self action:@selector(moveUp:)],
        [NSButton buttonWithTitle:@"Move Down" target:self action:@selector(moveDown:)],
        [NSButton buttonWithTitle:@"Restore Default" target:self action:@selector(restoreDefault:)]]];
    editRow.spacing = 8;

    NSTextField *note = [NSTextField wrappingLabelWithString:
        @"Changes apply to every open editor as soon as they are made. Right-click in the editor to see them."];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;

    NSStackView *stack = [NSStackView stackViewWithViews:@[sv, editRow, addRow, note]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [win.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:win.contentView.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:win.contentView.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:win.contentView.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:win.contentView.bottomAnchor constant:-14],
        [sv.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [sv.heightAnchor constraintGreaterThanOrEqualToConstant:240],
    ]];
    return self;
}

- (void)showWindow:(id)sender {
    _entries = [NPPPreferences.shared.contextMenuCommandTags mutableCopy];
    [self reloadAvailable];
    [_table reloadData];
    [super showWindow:sender];
    [self.window makeKeyAndOrderFront:nil];
}

// The three submenu openers are in the list too, so a menu taken apart can be put back together — everything added
// after one lands inside it, up to the next opener or the next separator.
- (void)reloadAvailable {
    NSMutableDictionary<NSNumber *, NSString *> *owners = [NSMutableDictionary dictionary];
    _titles = [NPPPreferences.shared commandTitlesInMenu:NSApp.mainMenu owners:owners];
    [_available.menu removeAllItems];
    for (NSMenuItem *row in NPPContextAvailableRows(_titles, owners)) [_available.menu addItem:row];
}

- (NSString *)titleForEntry:(NSNumber *)entry {
    NSInteger v = entry.integerValue;
    if (v == 0) return @"———";
    const NPPContextFolder *f = NPPContextFolderForSlot(v);
    if (f) return [NSString stringWithFormat:@"▸ %s", f->name];
    if (v < 0) {
        const NPPStandardContextAction *std = NPPStandardContextActionForSlot(v);
        return std ? @(std->title) : @"(unknown)";
    }
    return _titles[entry] ?: [NSString stringWithFormat:@"(command %ld)", (long)v];
}

- (void)commit {
    NPPPreferences.shared.contextMenuCommandTags = [_entries copy];
    [_table reloadData];
}

- (void)add:(id)sender {
    id v = _available.selectedItem.representedObject;
    if (!v) return;
    NSInteger at = _table.selectedRow >= 0 ? _table.selectedRow + 1 : (NSInteger)_entries.count;
    [_entries insertObject:v atIndex:(NSUInteger)at];
    [self commit];
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)at] byExtendingSelection:NO];
}

- (void)addSeparator:(id)sender {
    NSInteger at = _table.selectedRow >= 0 ? _table.selectedRow + 1 : (NSInteger)_entries.count;
    [_entries insertObject:@0 atIndex:(NSUInteger)at];
    [self commit];
}

- (void)remove:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_entries.count) { NSBeep(); return; }
    [_entries removeObjectAtIndex:(NSUInteger)row];
    [self commit];
}

- (void)moveUp:(id)sender { [self moveBy:-1]; }
- (void)moveDown:(id)sender { [self moveBy:1]; }
- (void)moveBy:(NSInteger)delta {
    NSInteger row = _table.selectedRow, to = row + delta;
    if (row < 0 || to < 0 || to >= (NSInteger)_entries.count) { NSBeep(); return; }
    NSNumber *v = _entries[(NSUInteger)row];
    [_entries removeObjectAtIndex:(NSUInteger)row];
    [_entries insertObject:v atIndex:(NSUInteger)to];
    [self commit];
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)to] byExtendingSelection:NO];
}

- (void)restoreDefault:(id)sender {
    NPPPreferences.shared.contextMenuCommandTags = nil;
    _entries = [NPPPreferences.shared.contextMenuCommandTags mutableCopy];
    [_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)_entries.count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSString *title = [self titleForEntry:_entries[(NSUInteger)row]];
    // Indented exactly where it will sit in the built menu: inside the last folder opened above it.
    NSInteger v = _entries[(NSUInteger)row].integerValue;
    if (v != 0 && !NPPContextFolderForSlot(v))
        for (NSInteger i = row - 1; i >= 0; --i) {
            NSInteger above = _entries[(NSUInteger)i].integerValue;
            if (above == 0) break;
            if (NPPContextFolderForSlot(above)) { title = [@"      " stringByAppendingString:title]; break; }
        }
    return [NSTextField labelWithString:title];
}

@end

#pragma mark - Style Configurator

// The lexer's own keyword list for one keyword class, straight from the bundled langs.model.xml — upstream's
// NppParameters::getWordList, which fills WordStyleDlg's read-only "Default keywords" box (WordStyleDlg.cpp:1336).
// NPPLanguageManager cannot answer it: as soon as the user adds keywords its table holds the *merged* list
// (-reloadLanguagesWithUserEntries above), and the whole point of the box is to show what is being extended.
// ponytail: parses the half-megabyte language file once, the first time a style with a keyword class is selected.
// If that ever shows, NPPLanguageManager keeps the base lists beside the merged ones and this goes away.
static NSString *NPPDefaultKeywordsForLanguage(NSString *language, NSString *keywordClass) {
    static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *base;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        NSURL *url = [NSBundle.mainBundle URLForResource:@"langs.model" withExtension:@"xml"];
        NSXMLDocument *doc = url ? [[NSXMLDocument alloc] initWithContentsOfURL:url
                                                                       options:NSXMLNodeLoadExternalEntitiesNever
                                                                         error:nil] : nil;
        for (NSXMLElement *e in [[doc.rootElement elementsForName:@"Languages"].firstObject elementsForName:@"Language"]) {
            NSString *name = [e attributeForName:@"name"].stringValue;
            if (!name.length) continue;
            NSMutableDictionary *classes = [NSMutableDictionary dictionary];
            for (NSXMLElement *k in [e elementsForName:@"Keywords"]) {
                NSString *cls = [k attributeForName:@"name"].stringValue;
                if (cls.length) classes[cls] = [NPPWords(k.stringValue) componentsJoinedByString:@" "];
            }
            all[name] = classes;
        }
        base = all;
    });
    return (language.length && keywordClass.length) ? (base[language][keywordClass] ?: @"") : @"";
}

// Depth-first over a view tree; +selfCheckFailures uses it to prove a control is really on a window.
static void NPPWalkViews(NSView *view, void (^visit)(NSView *)) {
    visit(view);
    for (NSView *sub in view.subviews) NPPWalkViews(sub, visit);
}

// N++ WordStyleDlg: pick a language, pick a style in it, edit colours/font, see it immediately, save into the user
// theme. The theme XML itself is the model — NPPLanguageManager's parsed styles are private and the file has to be
// written anyway, so editing the DOM avoids keeping a second copy in step.
@implementation NPPStyleConfiguratorController {
    NSXMLDocument *_doc;
    NSString *_themeName;
    NSMutableArray<NSDictionary *> *_categories;      // name, element (LexerType / GlobalStyles), lexer (NSString or NSNull)
    NSArray<NSXMLElement *> *_styles;
    NSTableView *_categoryTable, *_styleTable;
    NSPopUpButton *_themePopup, *_fontPopup, *_sizePopup, *_globalFontPopup, *_globalSizePopup;
    NSColorWell *_fgWell, *_bgWell;
    NSButton *_fgEnabled, *_bgEnabled, *_bold, *_italic, *_underline;
    NSTextField *_status;
    NSTextField *_defaultExtLabel, *_userExtField, *_userKeywordsField;   // N++ "Default ext." / "User ext." / "User keywords"
    NSTextView *_defaultKeywordsView;                                     // N++ "Default keywords" (read-only, beside the user's)
    NSArray<NSButton *> *_globalOverrideChecks;                            // identifier == the NPPPreferences property
}

+ (instancetype)shared {
    static NPPStyleConfiguratorController *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPStyleConfiguratorController alloc] initWithWindow:nil]; });
    return s;
}

- (instancetype)initWithWindow:(NSWindow *)w {
    NPPPrefsWindow *win = [[NPPPrefsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 660)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"Style Configurator";
    win.releasedWhenClosed = NO;
    // Grown for the "Global override" box and the two keyword boxes; the minimum is what those need without clipping.
    win.minSize = NSMakeSize(830, 600);
    [win center];
    if (!(self = [super initWithWindow:win])) return nil;
    self.windowFrameAutosaveName = @"NPPStyleConfiguratorWindow";
    _categories = [NSMutableArray array];

    // --- theme + global font override -------------------------------------------------------------------------
    _themePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _themePopup.target = self; _themePopup.action = @selector(themeChanged:);
    _globalFontPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _globalFontPopup.target = self; _globalFontPopup.action = @selector(globalFontChanged:);
    _globalSizePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _globalSizePopup.target = self; _globalSizePopup.action = @selector(globalFontChanged:);
    NSStackView *top = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Theme:"], _themePopup,
        [NSTextField labelWithString:@"   Override font:"], _globalFontPopup, _globalSizePopup]];
    top.spacing = 6;

    // --- lists -------------------------------------------------------------------------------------------------
    _categoryTable = [self listTableWithTitle:@"Language"];
    _styleTable = [self listTableWithTitle:@"Style"];
    NSScrollView *catScroll = [self scrollFor:_categoryTable width:200];
    NSScrollView *styleScroll = [self scrollFor:_styleTable width:210];

    // --- editors -----------------------------------------------------------------------------------------------
    _fgEnabled = [NSButton checkboxWithTitle:@"Foreground" target:self action:@selector(styleEdited:)];
    _bgEnabled = [NSButton checkboxWithTitle:@"Background" target:self action:@selector(styleEdited:)];
    _fgWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 22)];
    _fgWell.target = self; _fgWell.action = @selector(styleEdited:);
    _bgWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 22)];
    _bgWell.target = self; _bgWell.action = @selector(styleEdited:);
    for (NSColorWell *cw in @[_fgWell, _bgWell]) {
        [cw.widthAnchor constraintEqualToConstant:44].active = YES;
        [cw.heightAnchor constraintEqualToConstant:22].active = YES;
    }
    _fontPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _fontPopup.target = self; _fontPopup.action = @selector(styleEdited:);
    _sizePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _sizePopup.target = self; _sizePopup.action = @selector(styleEdited:);
    _bold = [NSButton checkboxWithTitle:@"Bold" target:self action:@selector(styleEdited:)];
    _italic = [NSButton checkboxWithTitle:@"Italic" target:self action:@selector(styleEdited:)];
    _underline = [NSButton checkboxWithTitle:@"Underline" target:self action:@selector(styleEdited:)];
    [self fillFontPopup:_fontPopup includeDefaultTitle:@"Theme default"];
    [self fillFontPopup:_globalFontPopup includeDefaultTitle:@"Theme default"];
    [self fillSizePopup:_sizePopup];
    [self fillSizePopup:_globalSizePopup];

    NSGridView *editors = [NSGridView gridViewWithViews:@[
        @[_fgEnabled, _fgWell],
        @[_bgEnabled, _bgWell],
        @[[NSTextField labelWithString:@"Font:"], _fontPopup],
        @[[NSTextField labelWithString:@"Size:"], _sizePopup],
        @[_bold, _italic],
        @[_underline],
    ]];
    editors.rowSpacing = 8; editors.columnSpacing = 10;
    editors.translatesAutoresizingMaskIntoConstraints = NO;

    _status = [NSTextField wrappingLabelWithString:@""];
    _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _status.textColor = NSColor.secondaryLabelColor;

    NSStackView *buttons = [NSStackView stackViewWithViews:@[
        [NSButton buttonWithTitle:@"Save Theme" target:self action:@selector(saveTheme:)],
        [NSButton buttonWithTitle:@"Revert" target:self action:@selector(revert:)],
        [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeWindow:)]]];
    buttons.spacing = 8;

    // --- global override (N++ NppGUI::_globalOverride; live only while the "Global override" style is selected) ---
    NSMutableArray<NSButton *> *checks = [NSMutableArray array];
    NSArray<NSArray<NSString *> *> *goSpec = @[
        @[@"Foreground", @"globalOverrideForeground"], @[@"Background", @"globalOverrideBackground"],
        @[@"Font", @"globalOverrideFont"],             @[@"Size", @"globalOverrideFontSize"],
        @[@"Bold", @"globalOverrideBold"],             @[@"Italic", @"globalOverrideItalic"],
        @[@"Underline", @"globalOverrideUnderline"],
    ];
    for (NSArray<NSString *> *spec in goSpec) {
        NSButton *b = [NSButton checkboxWithTitle:spec[0] target:self action:@selector(globalOverrideChanged:)];
        b.identifier = spec[1];
        b.toolTip = @"Forces this attribute of the \"Global override\" style onto every style of every language.";
        [checks addObject:b];
    }
    _globalOverrideChecks = checks;
    NSGridView *overrides = [NSGridView gridViewWithViews:@[
        @[checks[0], checks[1]], @[checks[2], checks[3]], @[checks[4], checks[5]], @[checks[6]],
    ]];
    overrides.rowSpacing = 4; overrides.columnSpacing = 10;
    overrides.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *overrideBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    overrideBox.title = @"Global override";
    overrideBox.translatesAutoresizingMaskIntoConstraints = NO;
    [overrideBox.contentView addSubview:overrides];
    [NSLayoutConstraint activateConstraints:@[
        [overrides.topAnchor constraintEqualToAnchor:overrideBox.contentView.topAnchor constant:8],
        [overrides.leadingAnchor constraintEqualToAnchor:overrideBox.contentView.leadingAnchor constant:10],
        [overrides.trailingAnchor constraintLessThanOrEqualToAnchor:overrideBox.contentView.trailingAnchor constant:-10],
        [overrides.bottomAnchor constraintEqualToAnchor:overrideBox.contentView.bottomAnchor constant:-8],
    ]];

    NSStackView *right = [NSStackView stackViewWithViews:@[editors, overrideBox, buttons, _status]];
    right.orientation = NSUserInterfaceLayoutOrientationVertical;
    right.alignment = NSLayoutAttributeLeading;
    right.spacing = 12;

    NSStackView *middle = [NSStackView stackViewWithViews:@[catScroll, styleScroll, right]];
    middle.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    middle.alignment = NSLayoutAttributeTop;
    middle.spacing = 12;

    // --- the two "+" fields (N++ WordStyleDlg): an extra extension for the language, extra words for the style ---
    _defaultExtLabel = [NSTextField labelWithString:@""];
    _defaultExtLabel.textColor = NSColor.secondaryLabelColor;
    _defaultExtLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _userExtField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _userExtField.target = self; _userExtField.action = @selector(userExtEdited:);
    _userExtField.placeholderString = @"cfg conf";
    _userKeywordsField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _userKeywordsField.target = self; _userKeywordsField.action = @selector(userKeywordsEdited:);
    _userKeywordsField.placeholderString = @"extra words for this style's keyword list";
    [_userExtField.widthAnchor constraintEqualToConstant:150].active = YES;
    [_userKeywordsField.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    // A language's default extension list can be long (cpp ships eleven); it truncates rather than pushing the two
    // editable fields off the window.
    [_defaultExtLabel.widthAnchor constraintLessThanOrEqualToConstant:170].active = YES;
    [_defaultExtLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_userKeywordsField setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];

    // The read-only half of upstream's pair: the words the lexer already has, next to the ones being added to them,
    // with upstream's "+" between the two boxes (IDC_DEF_KEYWORDS_EDIT / IDC_PLUSSYMBOL_STATIC / IDC_USER_KEYWORDS_EDIT).
    NSScrollView *defaultKeywordsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 260, 54)];
    defaultKeywordsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    defaultKeywordsScroll.hasVerticalScroller = YES;
    defaultKeywordsScroll.borderType = NSBezelBorder;
    _defaultKeywordsView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 260, 54)];
    _defaultKeywordsView.editable = NO;                 // read-only: this is the lexer's list, not the user's
    _defaultKeywordsView.richText = NO;
    _defaultKeywordsView.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _defaultKeywordsView.textColor = NSColor.secondaryLabelColor;
    _defaultKeywordsView.autoresizingMask = NSViewWidthSizable;
    _defaultKeywordsView.minSize = NSMakeSize(0, 0);
    _defaultKeywordsView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _defaultKeywordsView.verticallyResizable = YES;
    _defaultKeywordsView.horizontallyResizable = NO;
    _defaultKeywordsView.textContainer.widthTracksTextView = YES;
    defaultKeywordsScroll.documentView = _defaultKeywordsView;
    [defaultKeywordsScroll.widthAnchor constraintGreaterThanOrEqualToConstant:240].active = YES;
    [defaultKeywordsScroll.heightAnchor constraintEqualToConstant:54].active = YES;

    NSStackView *extRow = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Default ext.:"], _defaultExtLabel,
        [NSTextField labelWithString:@"   User ext.:"], _userExtField]];
    extRow.spacing = 6;
    NSStackView *keywordRow = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Default keywords:"], defaultKeywordsScroll,
        [NSTextField labelWithString:@"+"],
        [NSTextField labelWithString:@"User keywords:"], _userKeywordsField]];
    keywordRow.spacing = 6;
    NSStackView *extras = [NSStackView stackViewWithViews:@[extRow, keywordRow]];
    extras.orientation = NSUserInterfaceLayoutOrientationVertical;
    extras.alignment = NSLayoutAttributeLeading;
    extras.spacing = 8;
    for (NSStackView *row in @[extRow, keywordRow, extras])
        [row setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *root = [NSStackView stackViewWithViews:@[top, middle, extras]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 12;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [win.contentView addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:win.contentView.topAnchor constant:14],
        [root.leadingAnchor constraintEqualToAnchor:win.contentView.leadingAnchor constant:14],
        [root.trailingAnchor constraintEqualToAnchor:win.contentView.trailingAnchor constant:-14],
        [root.bottomAnchor constraintEqualToAnchor:win.contentView.bottomAnchor constant:-14],
        [middle.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [extras.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor],
        [catScroll.heightAnchor constraintGreaterThanOrEqualToConstant:300],
        [styleScroll.heightAnchor constraintEqualToAnchor:catScroll.heightAnchor],
    ]];
    return self;
}

- (NSTableView *)listTableWithTitle:(NSString *)title {
    NSTableView *t = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    c.title = title;
    [t addTableColumn:c];
    t.dataSource = (id)self;
    t.delegate = (id)self;
    t.allowsEmptySelection = NO;
    return t;
}

- (NSScrollView *)scrollFor:(NSTableView *)t width:(CGFloat)width {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    sv.documentView = t;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [sv.widthAnchor constraintEqualToConstant:width].active = YES;
    return sv;
}

- (void)fillFontPopup:(NSPopUpButton *)pop includeDefaultTitle:(NSString *)defaultTitle {
    [pop removeAllItems];
    [pop addItemWithTitle:defaultTitle];
    pop.lastItem.representedObject = @"";
    NSMutableArray *fonts = [NSMutableArray array];
    for (NSString *fam in NSFontManager.sharedFontManager.availableFontFamilies) {
        if ([fam hasPrefix:@"."]) continue;
        NSFont *f = [NSFont fontWithName:fam size:12];
        if (f.isFixedPitch) [fonts addObject:fam];
    }
    [fonts sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *fam in fonts) { [pop addItemWithTitle:fam]; pop.lastItem.representedObject = fam; }
}

// A theme may name a proportional font or a size outside 6..28; those are missing from the popups, and leaving the
// popup on "Theme default" would silently drop the theme's own value the next time any control is touched. Add the
// value instead, so every style round-trips through this window unchanged.
- (void)select:(nullable NSString *)value in:(NSPopUpButton *)pop {
    if (value.length == 0) { [pop selectItemAtIndex:0]; return; }
    // The readers take -integerValue / -doubleValue / an NSString, all of which an NSString answers.
    if ([pop indexOfItemWithTitle:value] < 0) { [pop addItemWithTitle:value]; pop.lastItem.representedObject = value; }
    [pop selectItemWithTitle:value];
}

- (void)fillSizePopup:(NSPopUpButton *)pop {
    [pop removeAllItems];
    [pop addItemWithTitle:@"Default"];
    pop.lastItem.representedObject = @0;
    for (NSInteger s = 6; s <= 28; s++) { [pop addItemWithTitle:@(s).stringValue]; pop.lastItem.representedObject = @(s); }
}

- (void)showWindow:(id)sender {
    [self loadCurrentTheme];
    [super showWindow:sender];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)closeWindow:(id)sender { [self.window performClose:sender]; }

#pragma mark Model

- (void)loadCurrentTheme {
    NPPPreferences *p = NPPPreferences.shared;
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    _themeName = lm.currentThemeName ?: kDefaultThemeName;

    [_themePopup removeAllItems];
    for (NSString *t in lm.availableThemeNames ?: @[]) { [_themePopup addItemWithTitle:t]; _themePopup.lastItem.representedObject = t; }
    [_themePopup selectItemWithTitle:_themeName];

    [self select:p.fontName in:_globalFontPopup];
    [self select:(p.fontSize > 0 ? @((NSInteger)p.fontSize).stringValue : nil) in:_globalSizePopup];

    NSURL *url = NPPThemeFileURL(_themeName);
    NSError *err = nil;
    _doc = url ? [[NSXMLDocument alloc] initWithContentsOfURL:url options:NSXMLNodeLoadExternalEntitiesNever error:&err] : nil;
    [_categories removeAllObjects];
    if (!_doc) {
        _status.stringValue = [NSString stringWithFormat:@"Could not read the theme file: %@", err.localizedDescription ?: @"missing"];
        _styles = @[];   // the old document's elements are detached now; do not keep editing them
        [_categoryTable reloadData]; [_styleTable reloadData];
        [self loadSelectedStyleIntoControls];
        return;
    }
    _status.stringValue = @"";

    NSXMLElement *globals = [_doc.rootElement elementsForName:@"GlobalStyles"].firstObject;
    if (globals) [_categories addObject:@{@"name": @"Global Styles", @"element": globals, @"lexer": NSNull.null}];
    NSXMLElement *lexerStyles = [_doc.rootElement elementsForName:@"LexerStyles"].firstObject;
    NSMutableDictionary<NSString *, NSString *> *display = [NSMutableDictionary dictionary];
    for (NPPLanguage *l in lm.languages) display[l.name] = l.shortName;
    NSMutableArray *lexers = [NSMutableArray array];
    for (NSXMLElement *lt in [lexerStyles elementsForName:@"LexerType"]) {
        NSString *name = [lt attributeForName:@"name"].stringValue;
        if (name.length == 0) continue;
        [lexers addObject:@{@"name": display[name] ?: ([lt attributeForName:@"desc"].stringValue ?: name),
                            @"element": lt, @"lexer": name}];
    }
    [lexers sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    [_categories addObjectsFromArray:lexers];

    [_categoryTable reloadData];
    if (_categories.count) [_categoryTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self reloadStyles];
}

- (void)reloadStyles {
    NSInteger row = _categoryTable.selectedRow;
    NSXMLElement *e = (row >= 0 && row < (NSInteger)_categories.count) ? _categories[(NSUInteger)row][@"element"] : nil;
    NSMutableArray *styles = [NSMutableArray array];
    for (NSXMLElement *child in [e elementsForName:@"WordsStyle"]) [styles addObject:child];
    for (NSXMLElement *child in [e elementsForName:@"WidgetStyle"]) [styles addObject:child];
    _styles = styles;
    [_styleTable reloadData];
    if (_styles.count) [_styleTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self loadSelectedStyleIntoControls];
}

- (nullable NSXMLElement *)selectedStyle {
    NSInteger row = _styleTable.selectedRow;
    return (row >= 0 && row < (NSInteger)_styles.count) ? _styles[(NSUInteger)row] : nil;
}

static NSString *NPPAttr(NSXMLElement *e, NSString *name) {
    NSString *v = [e attributeForName:name].stringValue;
    return v.length ? v : nil;
}
static void NPPSetAttr(NSXMLElement *e, NSString *name, NSString *value) {
    [e removeAttributeForName:name];
    if (value) [e addAttribute:[NSXMLNode attributeWithName:name stringValue:value]];
}

// The LexerType name of the selected category ("cpp"), or nil for Global Styles.
- (nullable NSString *)selectedLexerName {
    NSInteger row = _categoryTable.selectedRow;
    id lexer = (row >= 0 && row < (NSInteger)_categories.count) ? _categories[(NSUInteger)row][@"lexer"] : nil;
    return [lexer isKindOfClass:NSString.class] ? lexer : nil;
}

- (void)loadSelectedStyleIntoControls {
    NSXMLElement *s = [self selectedStyle];

    // "User ext." belongs to the language, "User keywords" to the style, "Global override" to the one style of that
    // name — each control is live only where upstream shows it at all, and disabled (not missing) everywhere else.
    NSString *lexer = [self selectedLexerName];
    NPPLanguage *lang = lexer ? [NPPLanguageManager.shared languageNamed:lexer] : nil;
    _defaultExtLabel.stringValue = [lang.extensions componentsJoinedByString:@" "] ?: @"";
    _userExtField.enabled = lexer != nil;
    _userExtField.stringValue = lexer ? [NPPPreferences.shared userExtensionsForLanguageNamed:lexer] : @"";
    NSString *cls = s ? NPPAttr(s, @"keywordClass") : nil;
    _userKeywordsField.enabled = (lexer != nil && cls != nil);
    _userKeywordsField.stringValue = _userKeywordsField.enabled
        ? [NPPPreferences.shared userKeywordsForLanguageNamed:lexer keywordClass:cls] : @"";
    _defaultKeywordsView.string = _userKeywordsField.enabled ? NPPDefaultKeywordsForLanguage(lexer, cls) : @"";
    BOOL isOverride = s && [NPPAttr(s, @"name") isEqualToString:@"Global override"];
    for (NSButton *b in _globalOverrideChecks) {
        b.enabled = isOverride;
        b.state = [[NPPPreferences.shared valueForKey:b.identifier] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    }

    BOOL on = s != nil;
    for (NSControl *c in @[_fgEnabled, _bgEnabled, _fgWell, _bgWell, _fontPopup, _sizePopup, _bold, _italic, _underline]) c.enabled = on;
    if (!s) return;
    NSString *fg = NPPAttr(s, @"fgColor"), *bg = NPPAttr(s, @"bgColor");
    _fgEnabled.state = fg ? NSControlStateValueOn : NSControlStateValueOff;
    _bgEnabled.state = bg ? NSControlStateValueOn : NSControlStateValueOff;
    _fgWell.color = NPPColorFromHexString(fg ?: @"000000");
    _bgWell.color = NPPColorFromHexString(bg ?: @"FFFFFF");
    _fgWell.enabled = fg != nil;
    _bgWell.enabled = bg != nil;
    [self select:NPPAttr(s, @"fontName") in:_fontPopup];
    NSInteger size = NPPAttr(s, @"fontSize").integerValue;
    [self select:(size > 0 ? @(size).stringValue : nil) in:_sizePopup];
    NSInteger style = NPPAttr(s, @"fontStyle") ? NPPAttr(s, @"fontStyle").integerValue : 0;
    _bold.state      = (style & 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _italic.state    = (style & 2) ? NSControlStateValueOn : NSControlStateValueOff;
    _underline.state = (style & 4) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)styleEdited:(id)sender {
    NSXMLElement *s = [self selectedStyle];
    if (!s) return;
    NPPSetAttr(s, @"fgColor", _fgEnabled.state == NSControlStateValueOn ? NPPHexStringFromColor(_fgWell.color) : nil);
    NPPSetAttr(s, @"bgColor", _bgEnabled.state == NSControlStateValueOn ? NPPHexStringFromColor(_bgWell.color) : nil);
    NSString *font = _fontPopup.selectedItem.representedObject;
    NPPSetAttr(s, @"fontName", font.length ? font : nil);
    NSInteger size = [_sizePopup.selectedItem.representedObject integerValue];
    NPPSetAttr(s, @"fontSize", size > 0 ? @(size).stringValue : nil);
    NSInteger style = (_bold.state == NSControlStateValueOn ? 1 : 0) | (_italic.state == NSControlStateValueOn ? 2 : 0) |
                      (_underline.state == NSControlStateValueOn ? 4 : 0);
    NPPSetAttr(s, @"fontStyle", @(style).stringValue);
    _fgWell.enabled = _fgEnabled.state == NSControlStateValueOn;
    _bgWell.enabled = _bgEnabled.state == NSControlStateValueOn;
    [self previewSelectedStyle];
}

// Immediate feedback without touching the disk. Only styles that carry a styleID can be pushed straight into
// Scintilla; the rest (N++'s named widget styles without an ID) land when the theme is saved and reloaded.
- (void)previewSelectedStyle {
    NSXMLElement *s = [self selectedStyle];

    // "Global override" carries styleID 0 in stylers.model.xml but is not a style: it is the source the ticked boxes
    // force onto every style. Pushing it into style 0 would repaint whatever that lexer calls style 0 instead.
    if (s && [NPPAttr(s, @"name") isEqualToString:@"Global override"]) {
        NPPPreferences *p = NPPPreferences.shared;
        NSString *fg = NPPAttr(s, @"fgColor"), *bg = NPPAttr(s, @"bgColor");
        NSString *fontStyleAttr = NPPAttr(s, @"fontStyle");
        for (NPPDocument *d in [p openDocuments])
            NPPApplyGlobalOverride(d.editor, p, fg ? NPPColorFromHex(fg) : -1, bg ? NPPColorFromHex(bg) : -1,
                                   NPPAttr(s, @"fontName"), NPPAttr(s, @"fontSize").integerValue,
                                   fontStyleAttr ? fontStyleAttr.integerValue : -1);
        _status.stringValue = p.globalOverrideEnabled ? @"" : @"Tick a Global override box to force this style on every style.";
        return;
    }

    NSString *idAttr = NPPAttr(s, @"styleID");
    if (!idAttr) { _status.stringValue = @"This style has no style ID: it will appear after Save Theme."; return; }
    _status.stringValue = @"";
    NSInteger row = _categoryTable.selectedRow;
    id lexer = (row >= 0 && row < (NSInteger)_categories.count) ? _categories[(NSUInteger)row][@"lexer"] : NSNull.null;
    NSString *wantLexer = [lexer isKindOfClass:NSString.class] ? lexer : nil;

    uptr_t styleID = (uptr_t)idAttr.integerValue;
    NSString *fg = NPPAttr(s, @"fgColor"), *bg = NPPAttr(s, @"bgColor"), *font = NPPAttr(s, @"fontName");
    NSInteger size = NPPAttr(s, @"fontSize").integerValue, style = NPPAttr(s, @"fontStyle").integerValue;
    for (NPPDocument *d in [NPPPreferences.shared openDocuments]) {
        if (wantLexer && ![d.language.name isEqualToString:wantLexer]) continue;
        ScintillaView *ed = d.editor;
        if (!ed) continue;
        if (fg) NPPSci(ed, SCI_STYLESETFORE, styleID, NPPColorFromHex(fg));
        if (bg) NPPSci(ed, SCI_STYLESETBACK, styleID, NPPColorFromHex(bg));
        if (font.length) NPPSciStr(ed, SCI_STYLESETFONT, styleID, font.UTF8String);
        if (size > 0) NPPSci(ed, SCI_STYLESETSIZE, styleID, (sptr_t)MAX(4, (NSInteger)round(size * 4.0 / 3.0)));
        NPPSci(ed, SCI_STYLESETBOLD, styleID, (style & 1) != 0);
        NPPSci(ed, SCI_STYLESETITALIC, styleID, (style & 2) != 0);
        NPPSci(ed, SCI_STYLESETUNDERLINE, styleID, (style & 4) != 0);
    }
}

#pragma mark Actions

- (void)themeChanged:(NSPopUpButton *)pop {
    NSString *name = pop.selectedItem.representedObject;
    if (!name.length) return;
    NPPPreferences.shared.themeName = name;
    [NPPLanguageManager.shared selectThemeNamed:name error:nil];
    [self loadCurrentTheme];
}

- (void)globalFontChanged:(id)sender {
    NSString *font = _globalFontPopup.selectedItem.representedObject;
    NPPPreferences.shared.fontName = font.length ? font : nil;
    NPPPreferences.shared.fontSize = (CGFloat)[_globalSizePopup.selectedItem.representedObject doubleValue];
}

// Ticking a box re-applies the theme and then this file's override on top of it (NPPPreferences -applyLiveSettings),
// so unticking the last one really does put every style back where the theme had it.
- (void)globalOverrideChanged:(NSButton *)b {
    [NPPPreferences.shared setValue:@(b.state == NSControlStateValueOn) forKey:b.identifier];
    // The setter scheduled the deferred pass, which re-applies the theme and then the override as *saved*; run the
    // preview after it so an edit that has not been saved yet is still what the editors show.
    dispatch_async(dispatch_get_main_queue(), ^{ [self previewSelectedStyle]; });
}

// Both fields rebuild the language table; the field is then re-read so it shows what was actually stored
// (extensions are normalised) rather than what was typed.
- (void)userExtEdited:(NSTextField *)f {
    NSString *lexer = [self selectedLexerName];
    if (!lexer) return;
    [NPPPreferences.shared setUserExtensions:f.stringValue forLanguageNamed:lexer];
    f.stringValue = [NPPPreferences.shared userExtensionsForLanguageNamed:lexer];
    _status.stringValue = [NPPPreferences.shared reloadLanguagesWithUserEntries]
        ? @"" : @"The extra extensions could not be applied (no writable settings directory).";
}

- (void)userKeywordsEdited:(NSTextField *)f {
    NSString *lexer = [self selectedLexerName];
    NSString *cls = NPPAttr([self selectedStyle], @"keywordClass");
    if (!lexer || !cls) return;
    [NPPPreferences.shared setUserKeywords:f.stringValue forLanguageNamed:lexer keywordClass:cls];
    f.stringValue = [NPPPreferences.shared userKeywordsForLanguageNamed:lexer keywordClass:cls];
    _status.stringValue = [NPPPreferences.shared reloadLanguagesWithUserEntries]
        ? @"" : @"The extra keywords could not be applied (no writable settings directory).";
}

- (void)revert:(id)sender {
    [NPPLanguageManager.shared selectThemeNamed:(_themeName ?: kDefaultThemeName) error:nil];
    [self loadCurrentTheme];
    _status.stringValue = @"Reverted to the saved theme.";
}

// Saving a bundled theme writes a copy into the user themes directory, which shadows the bundled original.
// The stock stylers.model.xml is never overwritten: editing it produces a separate "Default (customised)" theme.
- (void)saveTheme:(id)sender {
    if (!_doc) { NSBeep(); return; }
    BOOL isStock = [_themeName isEqualToString:kDefaultThemeName];
    NSString *targetName = isStock ? kCustomisedDefaultThemeName : _themeName;
    if (!NPPActivateUserThemesDirectory()) {
        _status.stringValue = @"No writable themes directory; the theme could not be saved.";
        return;
    }
    NSURL *dir = NPPThemesDirectory();
    NSURL *target = [dir URLByAppendingPathComponent:[targetName stringByAppendingPathExtension:@"xml"]];
    NSError *err = nil;
    NSData *data = [_doc XMLDataWithOptions:NSXMLNodePrettyPrint];
    if (![data writeToURL:target options:NSDataWritingAtomic error:&err]) {
        _status.stringValue = [NSString stringWithFormat:@"Save failed: %@", err.localizedDescription];
        return;
    }
    _themeName = targetName;
    NPPPreferences.shared.themeName = targetName;
    [NPPLanguageManager.shared selectThemeNamed:targetName error:nil];
    [self loadCurrentTheme];
    _status.stringValue = [NSString stringWithFormat:@"Saved to %@", target.path];
}

#pragma mark Tables

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return t == _categoryTable ? (NSInteger)_categories.count : (NSInteger)_styles.count;
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSString *s = t == _categoryTable ? _categories[(NSUInteger)row][@"name"]
                                      : (NPPAttr(_styles[(NSUInteger)row], @"name") ?: @"(unnamed)");
    return [NSTextField labelWithString:s];
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    if (n.object == _categoryTable) [self reloadStyles];
    else if (n.object == _styleTable) [self loadSelectedStyleIntoControls];
}

@end

#pragma mark - Headless regression checks

// Everything the UI cannot be trusted to prove: the derived properties both apply paths depend on, the edge-column
// parser, the recent-file cap, the search-engine URLs, the context-menu model, and — on a real ScintillaView — that
// -applyLiveSettingsToEditor:languageName: actually reaches Scintilla.
static NSArray<NSString *> *NPPPreferencesSelfCheck(void) {
    Class self_ = NPPPreferences.class;
    id<NPPCommandContext> noContext = nil;
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    NPPPreferences *p = NPPPreferences.shared;
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *what) { if (!ok) [fails addObject:what]; };
    void (^expectInt)(NSString *, long long, long long) = ^(NSString *what, long long got, long long want) {
        if (got != want) [fails addObject:[NSString stringWithFormat:@"%@: got %lld, want %lld", what, got, want]];
    };

    // Snapshot everything this check writes, so a self-test run leaves the user's settings alone.
    NSArray<NSString *> *touched = @[@"NPPCurrentLineIndicator", @"NPPCurrentLineFrameWidth", @"NPPFoldMarginStyle",
                                     @"NPPAutoIndentMode", @"NPPFileAutoDetection", @"NPPCaretBlinkRate",
                                     @"NPPEdgeColumns", @"NPPShowEdgeLine", @"NPPEdgeBackgroundMode",
                                     @"NPPMaxRecentFiles", @"NPPRecentFilePaths", @"NPPSearchEngine",
                                     @"NPPSearchEngineCustom", @"NPPContextMenuCommandTags", @"NPPVirtualSpace",
                                     @"NPPPaddingLeft", @"NPPPaddingRight", @"NPPLanguageIndents",
                                     @"NPPUseDefaultWordChars", @"NPPCustomWordChars", @"NPPTabSize",
                                     @"NPPShowNonPrintingChars", @"NPPNonPrintingMode", @"NPPMultiSelection",
                                     @"NPPDefaultEncoding", @"NPPDefaultCodepage",
                                     @"NPPColumnSelectionToMultiEditing", @"NPPLineWrapMethod",
                                     // the settings wired to other modules' readers, checked below
                                     @"NPPTabPeekOnTab", @"NPPDocumentSwitcher", @"NPPFolderDroppedOpenFiles",
                                     @"NPPTagMatchHighlight", @"NPPTagAttrHighlight", @"NPPSmartHighlightWholeWord",
                                     @"NPPLanguageMenuCompact", @"NPPExcludedLanguageNames", @"NPPSqlBackslashIsEscape",
                                     @"NPPTabBarVertical", @"NPPTabBarMultiLine", @"NPPTabBarLocked",
                                     @"NPPExitOnClosingLastTab", @"NPPStyleURL", @"NPPUriSchemes",
                                     @"NPPMatchedPairParentheses", @"NPPMatchedPairBrackets", @"NPPMatchedPairCurlyBrackets",
                                     @"NPPMatchedPairQuotes", @"NPPMatchedPairDoubleQuotes", @"NPPMatchedPairsUserDefined",
                                     @"NPPLargeFileRestrictionEnabled", @"NPPLargeFileSizeMB", @"NPPLargeFileDeactivateWordWrap",
                                     @"NPPLargeFileAllowBraceMatch", @"NPPLargeFileAllowSmartHilite",
                                     @"NPPLargeFileAllowClickableLink", @"NPPLargeFileSuppress2GBWarning",
                                     @"NPPDefaultDirectoryMode", @"NPPDefaultDirectoryPath",
                                     // added by the preference.rc audit; the checks below write all of these
                                     @"NPPToolbarColor", @"NPPToolbarCustomColor", @"NPPBorderWidth",
                                     @"NPPDistractionFreeDivPart", @"NPPRecentFilesDisplay",
                                     @"NPPRecentFilesCustomLength", @"NPPPrintMarginTop", @"NPPPrintMarginLeft",
                                     @"NPPPrintMarginRight", @"NPPPrintMarginBottom", @"NPPPrintHeaderFontSize",
                                     @"NPPPrintFooterFontSize", @"NPPInSelectionAutocheckThreshold",
                                     @"NPPFillFindWhatThreshold", @"NPPDelimiterOpen", @"NPPDelimiterClose",
                                     // the Reset button clears all twelve, so all twelve have to come back
                                     @"NPPDarkModeTone", @"NPPDarkModeCustomBackground",
                                     @"NPPDarkModeCustomSofterBackground", @"NPPDarkModeCustomHotBackground",
                                     @"NPPDarkModeCustomPureBackground", @"NPPDarkModeCustomErrorBackground",
                                     @"NPPDarkModeCustomText", @"NPPDarkModeCustomDarkerText",
                                     @"NPPDarkModeCustomDisabledText", @"NPPDarkModeCustomLinkText",
                                     @"NPPDarkModeCustomEdge", @"NPPDarkModeCustomHotEdge",
                                     @"NPPDarkModeCustomDisabledEdge",
                                     @"NPPMultiInstanceMode", @"NPPSettingsDirectory", @"NPPSessionFileExtension",
                                     @"NPPWorkspaceFileExtension", @"NPPSystemTrayAction", @"NPPRenderingMode",
                                     @"NPPAutoUpdateMode",
                                     // Style Configurator: user ext. / user keywords / global override
                                     @"NPPLanguageUserExtensions", @"NPPLanguageUserKeywords",
                                     @"NPPGlobalOverrideForeground", @"NPPGlobalOverrideBackground",
                                     @"NPPGlobalOverrideFont", @"NPPGlobalOverrideFontSize",
                                     @"NPPGlobalOverrideBold", @"NPPGlobalOverrideItalic",
                                     @"NPPGlobalOverrideUnderline"];
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    for (NSString *k in touched) { id v = [D() objectForKey:k]; if (v) saved[k] = v; }

    // ---- derived properties: the two apply paths must never disagree -------------------------------------------
    p.currentLineIndicator = NPPCurrentLineNone;
    expect(!p.highlightCurrentLine, @"derive.currentLine.none");
    p.currentLineIndicator = NPPCurrentLineFrame;
    expect(p.highlightCurrentLine, @"derive.currentLine.frame");
    p.highlightCurrentLine = NO;
    expectInt(@"derive.currentLine.setBack", p.currentLineIndicator, NPPCurrentLineNone);

    p.foldMarginStyle = NPPFoldMarginNone;
    expect(!p.showFoldMargin, @"derive.foldMargin.none");
    p.foldMarginStyle = NPPFoldMarginCircle;
    expect(p.showFoldMargin, @"derive.foldMargin.circle");

    p.autoIndentMode = NPPAutoIndentNone;
    expect(!p.autoIndent, @"derive.autoIndent.none");
    p.autoIndentMode = NPPAutoIndentBasic;
    expect(p.autoIndent, @"derive.autoIndent.basic");
    p.autoIndentMode = NPPAutoIndentAdvanced;
    expect(p.autoIndent, @"derive.autoIndent.advanced");
    // Switching auto-indent off and on again through the derived flag must not quietly demote Advanced to Basic.
    p.autoIndent = NO;
    expectInt(@"derive.autoIndent.off", p.autoIndentMode, NPPAutoIndentNone);
    p.autoIndent = YES;
    expectInt(@"derive.autoIndent.back-on-is-advanced", p.autoIndentMode, NPPAutoIndentAdvanced);
    // NPPDocument reads NPPAutoIndentMode itself and treats >= 2 as advanced; the registered default is upstream's.
    [D() removeObjectForKey:@"NPPAutoIndentMode"];
    expectInt(@"default.autoIndentMode-is-advanced", p.autoIndentMode, NPPAutoIndentAdvanced);

    p.fileAutoDetection = NPPFileAutoDetectionDisabled;
    expect(!p.checkFileChangesOnActivation, @"derive.fileAutoDetection.disabled");
    p.fileAutoDetection = NPPFileAutoDetectionEnabled;
    expect(p.checkFileChangesOnActivation, @"derive.fileAutoDetection.enabled");

    p.caretBlinkRate = 0;
    expect(!p.caretBlink, @"derive.caretBlink.solid");
    p.caretBlink = YES;
    expect(p.caretBlinkRate > 0, @"derive.caretBlink.on");

    // ---- edge column parsing ----------------------------------------------------------------------------------
    p.edgeColumns = @"80 100,120";
    expectInt(@"edge.parse.count", (long long)p.edgeColumnList.count, 3);
    expectInt(@"edge.parse.first", p.edgeColumn, 80);
    expectInt(@"edge.parse.last", p.edgeColumnList.lastObject.integerValue, 120);
    p.edgeColumns = @"0 9999 abc 80 80";
    expectInt(@"edge.parse.rejects-garbage-and-dupes", (long long)p.edgeColumnList.count, 1);
    p.edgeColumn = 42;
    expect([p.edgeColumns isEqualToString:@"42"], @"edge.setColumn");

    // ---- recent files cap -------------------------------------------------------------------------------------
    p.maxRecentFiles = 3;
    p.recentFilePaths = @[];
    for (int i = 0; i < 5; ++i) [p addRecentFilePath:[NSString stringWithFormat:@"/tmp/f%d", i]];
    expectInt(@"recent.cap", (long long)p.recentFilePaths.count, 3);
    expect([p.recentFilePaths.firstObject isEqualToString:@"/tmp/f4"], @"recent.most-recent-first");
    [p addRecentFilePath:@"/tmp/f3"];
    expect([p.recentFilePaths.firstObject isEqualToString:@"/tmp/f3"], @"recent.reinsert-moves-to-front");
    expectInt(@"recent.no-duplicates", (long long)p.recentFilePaths.count, 3);
    p.maxRecentFiles = 1;
    expectInt(@"recent.shrink-trims", (long long)p.recentFilePaths.count, 1);
    p.maxRecentFiles = 0;
    [p addRecentFilePath:@"/tmp/x"];
    expectInt(@"recent.zero-disables", (long long)p.recentFilePaths.count, 0);

    // ---- per-language indentation -----------------------------------------------------------------------------
    [p setIndentSettings:nil forLanguageNamed:@"cpp"];
    expect([p indentSettingsForLanguageNamed:@"cpp"] == nil, @"indent.default-is-nil");
    [p setIndentSettings:@{@"size": @2, @"spaces": @YES} forLanguageNamed:@"cpp"];
    expectInt(@"indent.override.size", [[p indentSettingsForLanguageNamed:@"cpp"][@"size"] integerValue], 2);
    expect([p indentSettingsForLanguageNamed:@"python"] == nil, @"indent.override.is-per-language");
    [p setIndentSettings:nil forLanguageNamed:@"cpp"];
    expect([p indentSettingsForLanguageNamed:@"cpp"] == nil, @"indent.override.cleared");

    // ---- search engines ---------------------------------------------------------------------------------------
    p.searchEngine = NPPSearchEngineDuckDuckGo;
    expect([[p searchEngineURLForTerm:@"a b"].absoluteString containsString:@"duckduckgo.com"], @"search.duckduckgo");
    expect(![[p searchEngineURLForTerm:@"a b"].absoluteString containsString:@" "], @"search.term-is-percent-encoded");
    p.searchEngine = NPPSearchEngineCustom;
    p.searchEngineCustom = @"";
    expect([p searchEngineURLForTerm:@"x"] == nil, @"search.custom-empty-is-nil");
    p.searchEngineCustom = @"https://example.com/?q=$(CURRENT_WORD)";
    expect([[p searchEngineURLForTerm:@"npp"].absoluteString isEqualToString:@"https://example.com/?q=npp"], @"search.custom-expands");

    // ---- context menu model ------------------------------------------------------------------------------------
    p.contextMenuCommandTags = nil;
    expect(p.contextMenuCommandTags.count > 0, @"context.default-not-empty");
    p.contextMenuCommandTags = @[@0, @(-3), @0, @0, @(NPPCmdEditUpperCase), @0];
    NSMenu *menu = [p buildEditorContextMenu];
    expect(menu.numberOfItems > 0, @"context.menu-built");
    expect(!menu.itemArray.firstObject.isSeparatorItem, @"context.no-leading-separator");
    expect(!menu.itemArray.lastObject.isSeparatorItem, @"context.no-trailing-separator");
    p.contextMenuCommandTags = @[@(-3)];
    menu = [p buildEditorContextMenu];
    expectInt(@"context.standard-action-count", menu.numberOfItems, 1);
    // Slot -3/-4 (Cut/Copy) deliberately go through the port so the "line without selection" preference reaches
    // this menu too; every other standard slot keeps its Cocoa selector.
    expect(menu.itemArray.firstObject.action == @selector(nppCommand:) &&
           menu.itemArray.firstObject.tag == NPPCmdEditClipboardCut, @"context.standard-action-selector");
    p.contextMenuCommandTags = @[@(-5)];
    menu = [p buildEditorContextMenu];
    expect(menu.itemArray.firstObject.action == @selector(paste:), @"context.standard-action-still-cocoa");
    // "Copy link" hangs off the Copy entry, the way upstream inserts it — and only off that one.
    expectInt(@"context.copy-link-not-without-copy", menu.numberOfItems, 1);
    p.contextMenuCommandTags = @[@(-4)];
    menu = [p buildEditorContextMenu];
    expectInt(@"context.copy-link-follows-copy", menu.numberOfItems, 2);
    expectInt(@"context.copy-link-tag", menu.itemArray.lastObject.tag, NPPCmdEditCopyLink);
    expect(menu.itemArray.lastObject.action == @selector(nppCommand:), @"context.copy-link-action");

    // ---- the default model is upstream's contextMenu.xml ---------------------------------------------------------
    // Right-click is how a Notepad++ user reaches these, so the check is that the ITEMS are in the built menu, not
    // that the commands work. Titles come from the main menu and --selftest has none, so it stands one in.
    p.contextMenuCommandTags = nil;
    NSMenu *titleSource = [[NSMenu alloc] initWithTitle:@""];
    for (NSNumber *tag in [NPPPreferences defaultContextMenuCommandTags]) {
        if (tag.integerValue <= 0) continue;
        NSMenuItem *stand = [titleSource addItemWithTitle:[NSString stringWithFormat:@"command %@", tag]
                                                   action:@selector(nppCommand:) keyEquivalent:@""];
        stand.tag = tag.integerValue;
    }
    NSMenu *full = [p buildEditorContextMenuWithTitlesFromMenu:titleSource];
    NSMenu *(^folderNamed)(NSString *) = ^NSMenu *(NSString *title) {
        for (NSMenuItem *it in full.itemArray) if ([it.title isEqualToString:title]) return it.submenu;
        return nil;
    };
    BOOL (^reachable)(NSInteger) = ^BOOL(NSInteger want) {
        for (NSMenuItem *it in full.itemArray) {
            if (it.tag == want) return YES;
            for (NSMenuItem *sub in it.submenu.itemArray) if (sub.tag == want) return YES;
        }
        return NO;
    };
    expectInt(@"context.default.style-all-occurrences-folder", (long long)folderNamed(@"Style all occurrences of token").numberOfItems, 5);
    expectInt(@"context.default.style-one-token-folder", (long long)folderNamed(@"Style one token").numberOfItems, 5);
    expectInt(@"context.default.clear-style-folder", (long long)folderNamed(@"Clear style").numberOfItems, 6);
    expect(reachable(NPPCmdEditOpenSelectedFile), @"context.default.open-file");
    expect(reachable(NPPCmdEditSearchOnInternet), @"context.default.search-on-internet");
    expect(reachable(NPPCmdEditBeginEndSelect), @"context.default.begin-end-select");
    expect(reachable(NPPCmdEditBlockUncomment), @"context.default.block-uncomment");
    expect(reachable(NPPCmdViewHideLines), @"context.default.hide-lines");
    // …and nothing else in the model quietly falls out on the way to the menu.
    for (NSNumber *tag in [NPPPreferences defaultContextMenuCommandTags])
        if (tag.integerValue > 0 && !reachable(tag.integerValue))
            [fails addObject:[NSString stringWithFormat:@"context.default.unreachable-command-%@", tag]];
    // A submenu whose items all dropped out would be a row that opens on nothing.
    menu = [p buildEditorContextMenuWithTitlesFromMenu:nil];
    for (NSMenuItem *it in menu.itemArray) if (it.submenu) [fails addObject:@"context.empty-folder-survives"];
    // Nothing nameless gets a row either. This is what keeps the port's first rule on a menu the 646-item sweep
    // never walks: an NPPCmd entry only becomes an item when the main menu has that tag, and the sweep validated it
    // there. The three tags that survive a title-less build are the ones that do not come from a title at all —
    // Cut/Copy are slots -3/-4, and Copy link is the one command with no main-menu item and a handler of its own.
    NSSet<NSNumber *> *notFromTitles = [NSSet setWithObjects:@(NPPCmdEditClipboardCut), @(NPPCmdEditClipboardCopy),
                                                             @(NPPCmdEditCopyLink), nil];
    for (NSMenuItem *it in menu.itemArray)
        if (it.tag > 0 && ![notFromTitles containsObject:@(it.tag)])
            [fails addObject:[NSString stringWithFormat:@"context.nameless-command-shown-%ld", (long)it.tag]];
    // Copy link has no main-menu item at all; the Edit Popup ContextMenu dialog still has to be able to offer it.
    expect([[p commandTitlesByTag][@(NPPCmdEditCopyLink)] isEqualToString:@"Copy link"], @"context.copy-link-is-nameable");

    // ---- the dialog's "Available" list ---------------------------------------------------------------------------
    // NSPopUpButton -addItemWithTitle: removes an earlier item with the same title, and this menu bar repeats about
    // twenty titles — so the list has to be built through the menu, and the repeats told apart, or the dialog
    // cannot offer "Style all occurrences … Using 1st Style" at all.
    NSArray<NSMenuItem *> *rows = NPPContextAvailableRows(
        @{@(NPPCmdSearchMarkAllExt1): @"Using 1st Style", @(NPPCmdSearchMarkOneExt1): @"Using 1st Style",
          @(NPPCmdEditClipboardCut): @"Cut", @(NPPCmdEditCopyLink): @"Copy link"},
        @{@(NPPCmdSearchMarkAllExt1): @"Style All Occurrences of Token", @(NPPCmdSearchMarkOneExt1): @"Style One Token"});
    NSMutableSet<NSNumber *> *offered = [NSMutableSet set];
    NSMutableSet<NSString *> *labels = [NSMutableSet set];
    for (NSMenuItem *it in rows) { [offered addObject:it.representedObject]; [labels addObject:it.title]; }
    expect([offered containsObject:@(NPPCmdSearchMarkAllExt1)] && [offered containsObject:@(NPPCmdSearchMarkOneExt1)],
           @"context.dialog.both-same-titled-commands-offered");
    expectInt(@"context.dialog.rows-are-distinguishable", (long long)labels.count, (long long)rows.count);
    expect([offered containsObject:@(-3)] && ![offered containsObject:@(NPPCmdEditClipboardCut)],
           @"context.dialog.cut-offered-once");
    expect([offered containsObject:@(NPPCmdEditCopyLink)] && [offered containsObject:@(-100)],
           @"context.dialog.copy-link-and-folders-offered");
    p.contextMenuCommandTags = nil;

    // ---- the Scintilla surface this file owns, on a real editor -------------------------------------------------
    NPPDocument *doc = [[NPPDocument alloc] initUntitled];
    ScintillaView *ed = doc.editor;
    if (!ed) [fails addObject:@"apply.no-editor"];
    else {
        p.currentLineIndicator = NPPCurrentLineFrame;
        p.currentLineFrameWidth = 4;
        p.caretBlinkRate = 0;
        p.virtualSpace = YES;
        p.lineWrapMethod = NPPLineWrapIndent;
        p.paddingLeft = 5; p.paddingRight = 7;
        p.multiSelection = YES; p.columnSelectionToMultiEditing = YES;
        p.showEdgeLine = YES; p.edgeBackgroundMode = NO; p.edgeColumns = @"80 100 120";
        p.showNonPrintingChars = YES; p.nonPrintingMode = NPPNonPrintingCodepoint;
        p.useDefaultWordChars = NO; p.customWordChars = @"$";
        p.tabSize = 4;
        [p setIndentSettings:@{@"size": @7, @"spaces": @YES} forLanguageNamed:@"selfcheck-lang"];
        [p applyLiveSettingsToEditor:ed languageName:@"selfcheck-lang"];

        expectInt(@"apply.caretLineFrame", NPPSci(ed, SCI_GETCARETLINEFRAME), 4);
        expectInt(@"apply.caretPeriod", NPPSci(ed, SCI_GETCARETPERIOD), 0);
        expect((NPPSci(ed, SCI_GETVIRTUALSPACEOPTIONS) & SCVS_USERACCESSIBLE) != 0, @"apply.virtualSpace");
        expectInt(@"apply.wrapIndentMode", NPPSci(ed, SCI_GETWRAPINDENTMODE), SC_WRAPINDENT_INDENT);
        expectInt(@"apply.marginLeft", NPPSci(ed, SCI_GETMARGINLEFT), 5);
        expect(NPPSci(ed, SCI_GETADDITIONALSELECTIONTYPING) != 0, @"apply.columnToMultiEditing");
        expectInt(@"apply.edgeMode.multi", NPPSci(ed, SCI_GETEDGEMODE), EDGE_MULTILINE);
        expectInt(@"apply.edge.second-column", NPPSci(ed, SCI_GETMULTIEDGECOLUMN, 1), 100);
        expectInt(@"apply.perLanguageIndent", NPPSci(ed, SCI_GETTABWIDTH), 7);
        expectInt(@"apply.perLanguageIndent.spaces", NPPSci(ed, SCI_GETUSETABS), 0);

        char rep[32] = {0};
        const char esc[2] = {0x1B, 0};
        NPPSci(ed, SCI_GETREPRESENTATION, (uptr_t)esc, (sptr_t)rep);
        expect(strcmp(rep, "x1B") == 0, ([NSString stringWithFormat:@"apply.npc.codepoint: got \"%s\"", rep]));
        p.nonPrintingMode = NPPNonPrintingAbbreviation;
        [p applyLiveSettingsToEditor:ed languageName:nil];
        memset(rep, 0, sizeof rep);
        NPPSci(ed, SCI_GETREPRESENTATION, (uptr_t)esc, (sptr_t)rep);
        expect(strcmp(rep, "ESC") == 0, ([NSString stringWithFormat:@"apply.npc.abbreviation: got \"%s\"", rep]));

        // The custom word character must be added to the lexer's set, not replace it. The set is raw bytes (every
        // byte >= 0x80 is a word character by default), so it is compared as std::string, never as an NSString.
        std::string chars = NPPEditorWordChars(ed);
        expect(chars.find('$') != std::string::npos, @"apply.wordChars.custom-added");
        expect(chars.find('a') != std::string::npos, @"apply.wordChars.default-kept");
        // Applying twice must not keep growing the set (upstream adds only what is missing).
        [p applyLiveSettingsToEditor:ed languageName:nil];
        std::string twice = NPPEditorWordChars(ed);
        [p applyLiveSettingsToEditor:ed languageName:nil];
        expect(twice == NPPEditorWordChars(ed), @"apply.wordChars.idempotent");
        // …and turning "use default" back on must restore the lexer's own set (N++ restoreDefaultWordChars).
        p.useDefaultWordChars = YES;
        [p applyLiveSettingsToEditor:ed languageName:nil];
        chars = NPPEditorWordChars(ed);
        expect(chars.find('$') == std::string::npos, @"apply.wordChars.default-restored");
        expect(chars.find('a') != std::string::npos, @"apply.wordChars.default-restored-intact");
        p.useDefaultWordChars = NO;

        // The global tab size applies again once the per-language override is gone.
        [p setIndentSettings:nil forLanguageNamed:@"selfcheck-lang"];
        [p applyLiveSettingsToEditor:ed languageName:@"selfcheck-lang"];
        expectInt(@"apply.perLanguageIndent.removed", NPPSci(ed, SCI_GETTABWIDTH), 4);

        p.showEdgeLine = NO;
        [p applyLiveSettingsToEditor:ed languageName:nil];
        expectInt(@"apply.edgeMode.off", NPPSci(ed, SCI_GETEDGEMODE), EDGE_NONE);

        // ---- Global override: only ticked attributes move, and they move on every style ------------------------
        for (NSString *k in @[@"globalOverrideForeground", @"globalOverrideBackground", @"globalOverrideFont",
                              @"globalOverrideFontSize", @"globalOverrideBold", @"globalOverrideItalic",
                              @"globalOverrideUnderline"]) [p setValue:@NO forKey:k];
        expect(!p.globalOverrideEnabled, @"globalOverride.enabled-is-off-with-every-box-clear");
        sptr_t fgWas = NPPSci(ed, SCI_STYLEGETFORE, 5);
        long forced = (long)(fgWas ^ 0xFFFFFF);
        NPPApplyGlobalOverride(ed, p, forced, -1, nil, 0, -1);
        expectInt(@"globalOverride.no-box-ticked-is-a-no-op", NPPSci(ed, SCI_STYLEGETFORE, 5), fgWas);
        p.globalOverrideForeground = YES;
        expect(p.globalOverrideEnabled, @"globalOverride.enabled-follows-the-boxes");
        sptr_t bgWas = NPPSci(ed, SCI_STYLEGETBACK, 5);
        NPPApplyGlobalOverride(ed, p, forced, (long)(bgWas ^ 0xFFFFFF), nil, 0, -1);
        expectInt(@"globalOverride.foreground", NPPSci(ed, SCI_STYLEGETFORE, 5), forced);
        expectInt(@"globalOverride.foreground-reaches-every-style", NPPSci(ed, SCI_STYLEGETFORE, STYLE_DEFAULT), forced);
        expectInt(@"globalOverride.background-needs-its-own-box", NPPSci(ed, SCI_STYLEGETBACK, 5), bgWas);
        // The override's own fontStyle decides on *and* off, so an unticked bit clears bold instead of leaving it.
        p.globalOverrideBold = YES;
        NPPApplyGlobalOverride(ed, p, -1, -1, nil, 0, 1);
        expect(NPPSci(ed, SCI_STYLEGETBOLD, 5) != 0, @"globalOverride.bold-on");
        NPPApplyGlobalOverride(ed, p, -1, -1, nil, 0, 0);
        expect(NPPSci(ed, SCI_STYLEGETBOLD, 5) == 0, @"globalOverride.bold-off");
        for (NSString *k in @[@"globalOverrideForeground", @"globalOverrideBold"]) [p setValue:@NO forKey:k];

        // ---- Copy link: the caret inside a URL indicator, and nothing selected (N++ NppBigSwitch.cpp:2067) -----
        NPPSciStr(ed, SCI_SETTEXT, 0, "see https://example.com/a");
        NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorURL);
        NPPSci(ed, SCI_INDICATORFILLRANGE, 4, 21);
        NPPSci(ed, SCI_SETSEL, 10, 10);
        sptr_t linkStart = -1, linkEnd = -1;
        expect(NPPLinkRangeAtCaret(ed, &linkStart, &linkEnd), @"copyLink.caret-in-a-link");
        expectInt(@"copyLink.range.start", linkStart, 4);
        expectInt(@"copyLink.range.end", linkEnd, 25);
        NPPSci(ed, SCI_SETSEL, 6, 12);
        expect(!NPPLinkRangeAtCaret(ed, NULL, NULL), @"copyLink.a-selection-wins");
        NPPSci(ed, SCI_SETSEL, 1, 1);
        expect(!NPPLinkRangeAtCaret(ed, NULL, NULL), @"copyLink.caret-outside-a-link");
    }
    expect([self_ handlesCommand:(NPPCmd)NPPCmdEditCopyLink], @"cmd.handles.copyLink");
    expect(![self_ canPerformCommand:(NPPCmd)NPPCmdEditCopyLink context:noContext], @"cmd.copyLink.needs-an-editor");

    // ---- tab label compaction ------------------------------------------------------------------------------------
    // Not idempotent means every tab-switch broadcast reports a change and reloads the whole strip.
    expect([NPPCompactTabTitle(@"short.txt", 0) isEqualToString:@"short.txt"], @"tab.compact.zero-is-off");
    expect([NPPCompactTabTitle(@"ab", 5) isEqualToString:@"ab"], @"tab.compact.under-limit-untouched");
    NSString *once = NPPCompactTabTitle(@"abcdefghij.txt", 5);
    expect([once isEqualToString:@"abcde…"], ([NSString stringWithFormat:@"tab.compact.cuts: got %@", once]));
    expect(NPPCompactTabTitle(once, 5) == once, @"tab.compact.idempotent");
    // A plain -substringToIndex: would cut a surrogate pair in half, which no longer encodes as UTF-8.
    expect([NPPCompactTabTitle(@"😀😀😀😀", 3) canBeConvertedToEncoding:NSUTF8StringEncoding],
           @"tab.compact.keeps-characters-whole");

    // ---- the New Document code page reaches a fresh untitled buffer ---------------------------------------------
    p.defaultEncoding = NPPEncodingANSI;
    p.defaultCodepage = (NSInteger)kCFStringEncodingWindowsCyrillic;
    NPPDocument *fresh = [[NPPDocument alloc] initUntitled];
    [p applyDefaultCodepageToDocument:fresh];
    expectInt(@"newdoc.codepage-applied", (long long)fresh.codepage, (long long)kCFStringEncodingWindowsCyrillic);
    // -setCodepage: forces the dirty flag; a brand-new empty buffer must not come out of this asking to be saved.
    expect(!fresh.isDirty, @"newdoc.codepage-leaves-buffer-clean");
    NPPSciStr(fresh.editor, SCI_SETTEXT, 0, "typed");
    p.defaultCodepage = (NSInteger)kCFStringEncodingWindowsLatin1;
    [p applyDefaultCodepageToDocument:fresh];
    expectInt(@"newdoc.codepage-leaves-non-empty-buffer-alone", (long long)fresh.codepage, (long long)kCFStringEncodingWindowsCyrillic);

    // ---- every setting reaches the NSUserDefaults key its reader actually reads ---------------------------------
    // A wrong key is silent in both directions: the checkbox stores happily and the module never sees it. The key
    // strings here were grepped out of the readers, not out of the macros above, so a typo on either side fires.
    NSDictionary<NSString *, NSString *> *boolKeys = @{
        @"tabBarVertical":          @"NPPTabBarVertical",              // NPPTabBarView -readDefaults
        @"tabBarMultiLine":         @"NPPTabBarMultiLine",             // NPPTabBarView -readDefaults
        @"tabBarLocked":            @"NPPTabBarLocked",                // NPPTabBarView -readDefaults
        @"tabPeekOnTab":            @"NPPTabPeekOnTab",                // NPPTabBarView -peekEnabled
        @"documentSwitcher":        @"NPPDocumentSwitcher",            // NPPEditorWindowController -documentSwitcherEnabled
        @"documentSwitcherMRU":     @"NPPDocumentSwitcherMRU",         // NPPEditorWindowController, MRU vs tab order
        @"fillFindFieldWithSelected": @"NPPFillFindFieldWithSelected", // NPPFindPanelController -dialogFillTextInEditor:
        @"fillFindFieldSelectCaret":  @"NPPFillFindFieldSelectCaret",  // NPPFindPanelController -dialogFillTextInEditor:
        @"fillDirFieldFromActiveDoc": @"NPPFillDirFieldFromActiveDoc", // NPPFindInFiles +directoryForDocumentFolder:lastUsed:
        @"findDlgAlwaysVisible":      @"NPPFindDlgAlwaysVisible",      // NPPFindInFiles +shouldCloseSheetAfterSearch
        @"folderDroppedOpenFiles":  @"NPPFolderDroppedOpenFiles",      // NPPEditorWindowController, folder drop
        @"tagAttrHighlight":        @"NPPTagAttrHighlight",            // NPPDocument -tagMatch
        @"matchedPairParentheses":  @"NPPMatchedPairParentheses",      // NPPDocument NPPCurrentMatchedPairConf
        @"matchedPairBrackets":     @"NPPMatchedPairBrackets",         // …
        @"matchedPairCurlyBrackets": @"NPPMatchedPairCurlyBrackets",
        @"matchedPairQuotes":       @"NPPMatchedPairQuotes",
        @"matchedPairDoubleQuotes": @"NPPMatchedPairDoubleQuotes",
        @"largeFileRestrictionEnabled":  @"NPPLargeFileRestrictionEnabled",   // NPPDocument -restrictedAsLargeFile
        @"largeFileDeactivateWordWrap":  @"NPPLargeFileDeactivateWordWrap",   // NPPDocument -applyPreferences
        @"largeFileAllowBraceMatch":     @"NPPLargeFileAllowBraceMatch",      // NPPDocument -allowsBraceMatch
        @"largeFileAllowSmartHilite":    @"NPPLargeFileAllowSmartHilite",     // NPPDocument -allowsSmartHilite
        @"largeFileAllowClickableLink":  @"NPPLargeFileAllowClickableLink",   // NPPDocument -allowsClickableLinks
        @"largeFileSuppress2GBWarning":  @"NPPLargeFileSuppress2GBWarning",   // NPPDocument, huge-file alert
        // ---- added by the preference.rc audit; the comment names the module that reads the key ----
        @"toolbarColorizationComplete":  @"NPPToolbarColorizationComplete",   // NPPToolBar
        @"hideMenuBar":                  @"NPPHideMenuBar",                   // nothing: stored, shown disabled
        @"hideMenuRightShortcuts":       @"NPPHideMenuRightShortcuts",        // nothing: stored, shown disabled
        @"tabBarReduce":                 @"NPPTabBarReduce",                  // NPPTabBarView
        @"tabBarAlternateIcons":         @"NPPTabBarAlternateIcons",          // NPPTabBarView
        @"tabBarDrawInactiveTab":        @"NPPTabBarDrawInactiveTab",         // NPPTabBarView
        @"tabBarDrawTopBar":             @"NPPTabBarDrawTopBar",              // NPPTabBarView
        @"tabBarShowOnlyPinnedButton":   @"NPPTabBarShowOnlyPinnedButton",    // NPPTabBarView
        @"tabBarInactiveTabShowButton":  @"NPPTabBarInactiveTabShowButton",   // NPPTabBarView
        @"smoothFont":                   @"NPPSmoothFont",                    // NPPDocument
        @"foldingCommandsToggleable":    @"NPPFoldingCommandsToggleable",     // NPPEditCommands / view commands
        @"rightClickKeepsSelection":     @"NPPRightClickKeepsSelection",      // NPPDocument
        @"lineCopyCutWithoutSelection":  @"NPPLineCopyCutWithoutSelection",   // nothing: stored, shown disabled
        @"selectedTextForegroundSingleColor": @"NPPSelectedTextForegroundSingleColor",   // NPPDocument
        @"disableAdvancedScrolling":     @"NPPDisableAdvancedScrolling",      // NPPDocument
        @"disableSelectedTextDragDrop":  @"NPPDisableSelectedTextDragDrop",   // NPPDocument
        @"preventC0Input":               @"NPPPreventC0Input",                // NPPDocument -charAdded:
        @"showBorderEdge":               @"NPPShowBorderEdge",                // NPPDocument / window controller
        @"lineNumberDynamicWidth":       @"NPPLineNumberDynamicWidth",        // NPPDocument, line-number margin
        @"addNewDocumentOnStartup":      @"NPPAddNewDocumentOnStartup",       // NPPAppDelegate
        @"useContentAsTabName":          @"NPPUseContentAsTabName",           // NPPDocument / NPPTabBarView
        @"checkRecentFilesAtLaunch":     @"NPPCheckRecentFilesAtLaunch",      // NPPAppDelegate
        @"recentFilesInSubmenu":         @"NPPRecentFilesInSubmenu",          // NPPAppDelegate
        @"highlightNonHTMLZone":         @"NPPHighlightNonHTMLZone",          // NPPDocument
        @"smartHighlightAnotherView":    @"NPPSmartHighlightAnotherView",     // NPPDocument
        @"smartHighlightUseFindSettings": @"NPPSmartHighlightUseFindSettings",// NPPDocument
        @"printFormFeedPageBreak":       @"NPPPrintFormFeedPageBreak",        // NPPPrintRenderer
        @"printHeaderFontBold":          @"NPPPrintHeaderFontBold",           // NPPPrintRenderer
        @"printHeaderFontItalic":        @"NPPPrintHeaderFontItalic",         // NPPPrintRenderer
        @"printFooterFontBold":          @"NPPPrintFooterFontBold",           // NPPPrintRenderer
        @"printFooterFontItalic":        @"NPPPrintFooterFontItalic",         // NPPPrintRenderer
        @"monospacedFontFindDlg":        @"NPPMonospacedFontFindDlg",         // NPPFindPanelController
        @"confirmReplaceInAllOpenDocs":  @"NPPConfirmReplaceInAllOpenDocs",   // NPPFindPanelController
        @"replaceStopsWithoutFindingNext": @"NPPReplaceStopsWithoutFindingNext",  // NPPFindPanelController
        @"finderShowOnlyOneEntryPerFoundLine": @"NPPFinderShowOnlyOneEntryPerFoundLine", // NPPSearchViewCommands
        @"findInFilesIgnoreOpenedFiles": @"NPPFindInFilesIgnoreOpenedFiles",  // NPPFindInFiles
        @"keepSessionAbsentFileEntries": @"NPPKeepSessionAbsentFileEntries",  // NPPBackupManager / session restore
        @"autoCompleteInsertWithTab":    @"NPPAutoCompleteInsertWithTab",     // NPPAutoCompletion
        @"autoCompleteInsertWithEnter":  @"NPPAutoCompleteInsertWithEnter",   // NPPAutoCompletion
        @"largeFileAllowAutoCompletion": @"NPPLargeFileAllowAutoCompletion",  // NPPDocument / NPPAutoCompletion
        @"clipboardHistoryPanelKeepState": @"NPPClipboardHistoryPanelKeepState",  // NPPUtilityPanels / NPPPanelHost
        @"docListPanelKeepState":        @"NPPDocListPanelKeepState",         // NPPPanelHost
        @"charPanelKeepState":           @"NPPCharPanelKeepState",            // NPPPanelHost
        @"fileBrowserPanelKeepState":    @"NPPFileBrowserPanelKeepState",     // NPPPanelHost
        @"projectPanelKeepState":        @"NPPProjectPanelKeepState",         // NPPProjectPanel
        @"docMapPanelKeepState":         @"NPPDocMapPanelKeepState",          // NPPDocumentMapPanel
        @"funcListPanelKeepState":       @"NPPFuncListPanelKeepState",        // NPPFunctionListPanel
        @"pluginPanelKeepState":         @"NPPPluginPanelKeepState",          // nothing: stored, shown disabled
        @"delimiterSelectionOnEntireDocument": @"NPPDelimiterSelectionOnEntireDocument", // NPPDocument
        @"settingsDirectoryEnabled":     @"NPPSettingsDirectoryEnabled",      // NPPAppDelegate / NPPCommandLine
        @"peekOnDocumentMap":            @"NPPPeekOnDocumentMap",             // nothing: stored, shown disabled
        @"muteAllSounds":                @"NPPMuteAllSounds",                 // NPPEditorWindowController
        @"shortTitleBar":                @"NPPShortTitleBar",                 // NPPEditorWindowController
        @"saveAllConfirm":               @"NPPSaveAllConfirm",                // NPPEditorWindowController
        @"fawAllowSymlink":              @"NPPFawAllowSymlink",               // nothing: stored, shown disabled
    };
    for (NSString *prop in boolKeys) {
        NSString *key = boolKeys[prop];
        id savedValue = [D() objectForKey:key];
        // Both polarities: writing under some *other* key would still agree with whatever that key happens to
        // hold, one value out of two, so a single toggle can pass a binding that is wrong.
        BOOL ok = YES;
        for (NSNumber *want in @[@YES, @NO]) {
            [p setValue:want forKey:prop];
            ok = ok && [D() boolForKey:key] == want.boolValue && [[p valueForKey:prop] boolValue] == want.boolValue;
        }
        expect(ok, ([NSString stringWithFormat:@"key.%@ is not stored under %@", prop, key]));
        savedValue ? [D() setObject:savedValue forKey:key] : [D() removeObjectForKey:key];
    }
    p.styleURL = NPPURLStyleBackgroundUnderline;
    expectInt(@"key.styleURL does not write NPPStyleURL", [D() integerForKey:@"NPPStyleURL"], NPPURLStyleBackgroundUnderline);
    p.largeFileSizeMB = 37;
    expectInt(@"key.largeFileSizeMB does not write NPPLargeFileSizeMB", [D() integerForKey:@"NPPLargeFileSizeMB"], 37);
    p.uriSchemes = @"zzz://";
    expect([[D() stringForKey:@"NPPUriSchemes"] isEqualToString:@"zzz://"], @"key.uriSchemes does not write NPPUriSchemes");
    p.excludedLanguageNames = @[@"C++"];
    expect([[D() arrayForKey:@"NPPExcludedLanguageNames"] isEqualToArray:@[@"C++"]], @"key.excludedLanguageNames does not write NPPExcludedLanguageNames");

    // The defaults NPPDocument falls back to when a key is unset have to be the ones registered here, or turning a
    // setting on and off again would land somewhere the reader never meant.
    [D() removeObjectForKey:@"NPPLargeFileSizeMB"];
    expectInt(@"default.largeFileSizeMB", p.largeFileSizeMB, 200);
    [D() removeObjectForKey:@"NPPStyleURL"];
    expectInt(@"default.styleURL", p.styleURL, NPPURLStyleForegroundUnderline);
    // Through NSUserDefaults, not through the property's own fallback: NPPDocument reads the key directly, so the
    // default has to be registered there or the field would show a list the editor is not using.
    [D() removeObjectForKey:@"NPPUriSchemes"];
    NSString *schemes = [D() stringForKey:@"NPPUriSchemes"];
    expect([schemes containsString:@"svn://"] && [schemes containsString:@"bitcoin:"], @"default.uriSchemes");
    [D() removeObjectForKey:@"NPPDocumentSwitcher"];
    expect(p.documentSwitcher, @"default.documentSwitcher-is-on");
    [D() removeObjectForKey:@"NPPTabPeekOnTab"];
    expect(!p.tabPeekOnTab, @"default.tabPeekOnTab-is-off");
    [D() removeObjectForKey:@"NPPFolderDroppedOpenFiles"];
    expect(!p.folderDroppedOpenFiles, @"default.folderDroppedOpenFiles-is-off");
    [D() removeObjectForKey:@"NPPTagAttrHighlight"];
    expect(p.tagAttrHighlight, @"default.tagAttrHighlight-is-on");

    // A user-defined matched pair is one opening and one closing single-byte character; NPPDocument drops the rest
    // without saying so, so storing them would leave the token field showing pairs that do nothing.
    p.matchedPairsUserDefined = @[@"<>", @"bad", @"«»", @"()"];
    expectInt(@"matchedPairs.filters-junk", (long long)p.matchedPairsUserDefined.count, 2);
    expect([p.matchedPairsUserDefined.firstObject isEqualToString:@"<>"], @"matchedPairs.keeps-good-pairs");
    // Hand-written accessors, so the key is not macro-generated: check the store, not just the round trip.
    expectInt(@"key.matchedPairsUserDefined is not stored under NPPMatchedPairsUserDefined",
              (long long)[[D() arrayForKey:@"NPPMatchedPairsUserDefined"] count], 2);

    // ---- the user themes directory is *added* to the search path, not swapped in for the bundled one -----------
    // First: it has to be in the search path already. -registerDefaults does it, because NPPAppDelegate applies the
    // saved theme in -applicationWillFinishLaunching and nothing validates the Settings menu before then. Read the
    // statics rather than calling the activator, which would make this pass by doing the work itself.
    expect(gUserThemesDir != nil || gUserThemesFailed, @"theme.user-directory-not-registered-at-startup");
    NSURL *probe = NPPActivateUserThemesDirectory()
                   ? [NPPThemesDirectory() URLByAppendingPathComponent:@"NPPSelfCheckTheme.xml"] : nil;
    // A directory that cannot be written to is not this file's failure; only run the check when the probe landed.
    if (probe && [@"<NotepadPlus><GlobalStyles/></NotepadPlus>" writeToURL:probe atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        NSArray<NSString *> *themes = NPPLanguageManager.shared.availableThemeNames;
        expect([themes containsObject:@"NPPSelfCheckTheme"], @"theme.user-directory-is-not-searched");
        expect([NPPThemeFileURL(@"NPPSelfCheckTheme").path isEqualToString:probe.path], @"theme.user-file-does-not-resolve");
        // Swapping the search directory instead of adding one would hide every theme that ships in the bundle.
        NSString *bundledName = nil;
        for (NSURL *u in [NSFileManager.defaultManager contentsOfDirectoryAtURL:NPPBundleThemesDirectory()
                                                    includingPropertiesForKeys:nil options:0 error:nil])
            if ([u.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame) { bundledName = u.URLByDeletingPathExtension.lastPathComponent; break; }
        if (bundledName) {
            expect([themes containsObject:bundledName],
                   ([NSString stringWithFormat:@"theme.bundled-theme-lost: %@", bundledName]));
            expect([NPPThemeFileURL(bundledName) checkResourceIsReachableAndReturnError:nil],
                   ([NSString stringWithFormat:@"theme.bundled-file-does-not-resolve: %@", bundledName]));
        }
        [NSFileManager.defaultManager removeItemAtURL:probe error:nil];
    }

    // ---- "User ext." / "User keywords": the merge, then the whole path through NPPLanguageManager ----------------
    // The merge is pure, so it is driven on a three-line document; getting it wrong is silent (an extension that
    // never matches, keywords that never colour) because nothing else in the app reads these two maps.
    NSXMLDocument *mini = [[NSXMLDocument alloc] initWithXMLString:
        @"<NotepadPlus><Languages><Language name=\"cpp\" ext=\"cpp h\">"
         "<Keywords name=\"instre1\">if else</Keywords></Language></Languages></NotepadPlus>" options:0 error:nil];
    NSXMLElement *miniLang = [[mini.rootElement elementsForName:@"Languages"].firstObject elementsForName:@"Language"].firstObject;
    NPPMergeUserLanguageEntries(mini, @{@"cpp": @" .Foo  H "},
                                @{@"cpp": @{@"instre1": @"if selfcheckword", @"type1": @"SelfCheckType"}});
    expect([[miniLang attributeForName:@"ext"].stringValue isEqualToString:@"cpp h foo"],
           ([NSString stringWithFormat:@"merge.ext: got \"%@\"", [miniLang attributeForName:@"ext"].stringValue]));
    NSMutableDictionary<NSString *, NSString *> *miniKw = [NSMutableDictionary dictionary];
    for (NSXMLElement *k in [miniLang elementsForName:@"Keywords"]) miniKw[[k attributeForName:@"name"].stringValue] = k.stringValue;
    expect([miniKw[@"instre1"] isEqualToString:@"if else selfcheckword"],
           ([NSString stringWithFormat:@"merge.keywords.appended: got \"%@\"", miniKw[@"instre1"]]));
    expect([miniKw[@"type1"] isEqualToString:@"SelfCheckType"], @"merge.keywords.class-the-language-lacks");
    // Merging an already-merged document must add nothing, or a second launch would keep growing the lists.
    NPPMergeUserLanguageEntries(mini, @{@"cpp": @" .Foo  H "}, @{@"cpp": @{@"instre1": @"if selfcheckword"}});
    expect([[miniLang attributeForName:@"ext"].stringValue isEqualToString:@"cpp h foo"], @"merge.idempotent.ext");
    expect([[miniLang elementsForName:@"Keywords"].firstObject.stringValue isEqualToString:@"if else selfcheckword"],
           @"merge.idempotent.keywords");
    // An entry cleared to "" has to behave exactly like no entry at all: that is how both fields are cleared.
    NPPMergeUserLanguageEntries(mini, @{@"cpp": @"   "}, @{@"cpp": @{@"instre1": @"", @"type2": @"  "}});
    expect([[miniLang attributeForName:@"ext"].stringValue isEqualToString:@"cpp h foo"], @"merge.empty-entry-is-ignored");
    expectInt(@"merge.empty-entry-adds-no-class", (long long)[miniLang elementsForName:@"Keywords"].count, 2);

    expect([[p userExtensionsForLanguageNamed:@"cpp"] isEqualToString:@""], @"userExt.default-is-empty");
    [p setUserExtensions:@" .Foo  BAR foo " forLanguageNamed:@"cpp"];
    expect([[p userExtensionsForLanguageNamed:@"cpp"] isEqualToString:@"foo bar"], @"userExt.normalised-on-the-way-in");
    [p setUserKeywords:@"  a   b  " forLanguageNamed:@"cpp" keywordClass:@"instre1"];
    expect([[p userKeywordsForLanguageNamed:@"cpp" keywordClass:@"instre1"] isEqualToString:@"a b"], @"userKeywords.round-trip");
    expect([[p userKeywordsForLanguageNamed:@"cpp" keywordClass:@"type1"] isEqualToString:@""], @"userKeywords.per-class");

    // The whole path, on the real language table: the merged copy needs a writable settings directory, which is not
    // this file's failure when it is missing, so the end-to-end half only runs when one could be made.
    if ([NSBundle.mainBundle URLForResource:@"langs.model" withExtension:@"xml"] && NPPSupportSubdirectory(@"languages")) {
        NPPLanguageManager *lm = NPPLanguageManager.shared;
        NSURL *probeFile = [NSURL fileURLWithPath:@"/tmp/nppselfcheck.selfcheckext"];
        [p setUserExtensions:@"selfcheckext" forLanguageNamed:@"cpp"];
        [p setUserKeywords:@"selfcheckkeyword" forLanguageNamed:@"cpp" keywordClass:@"instre1"];
        expect([p reloadLanguagesWithUserEntries], @"userlang.reload");
        expect([[lm languageForFileURL:probeFile].name isEqualToString:@"cpp"], @"userlang.ext-does-not-type-a-file");
        expect([[lm languageNamed:@"cpp"].keywords[@"instre1"] containsString:@"selfcheckkeyword"],
               @"userlang.keywords-never-reach-the-language-table");
        // Clearing has to put the bundled table back, or a mapping would outlive the setting that made it.
        [p setUserExtensions:@"" forLanguageNamed:@"cpp"];
        [p setUserKeywords:@"" forLanguageNamed:@"cpp" keywordClass:@"instre1"];
        expect([p reloadLanguagesWithUserEntries], @"userlang.reload-after-clearing");
        expect([lm languageForFileURL:probeFile] == nil, @"userlang.ext-outlives-its-setting");
        expect(![[lm languageNamed:@"cpp"].keywords[@"instre1"] containsString:@"selfcheckkeyword"],
               @"userlang.keywords-outlive-their-setting");
    }

    // ---- the audited settings: upstream's defaults ---------------------------------------------------------------
    // Only the ones whose default is *not* NO/0 are listed: those are the ones a missing registerDefaults entry
    // silently gets wrong (an unregistered key reads back as NO/0 and looks plausible).
    NSDictionary<NSString *, NSNumber *> *onByDefault = @{
        @"NPPTabBarReduce": @YES, @"NPPTabBarDrawInactiveTab": @YES, @"NPPTabBarDrawTopBar": @YES,
        @"NPPLineCopyCutWithoutSelection": @YES, @"NPPPreventC0Input": @YES, @"NPPShowBorderEdge": @YES,
        @"NPPLineNumberDynamicWidth": @YES, @"NPPConfirmReplaceInAllOpenDocs": @YES,
        @"NPPFinderShowOnlyOneEntryPerFoundLine": @YES, @"NPPAutoCompleteInsertWithTab": @YES,
        @"NPPAutoCompleteInsertWithEnter": @YES, @"NPPSaveAllConfirm": @YES,
    };
    for (NSString *k in onByDefault) {
        id kept = [D() objectForKey:k];
        [D() removeObjectForKey:k];
        expect([D() boolForKey:k] == onByDefault[k].boolValue,
               ([NSString stringWithFormat:@"default.%@ is not registered as %@", k, onByDefault[k].boolValue ? @"YES" : @"NO"]));
        kept ? [D() setObject:kept forKey:k] : [D() removeObjectForKey:k];
    }
    NSDictionary<NSString *, NSNumber *> *intDefaults = @{
        @"NPPBorderWidth": @2,                      // ScintillaViewParams::_borderWidth
        @"NPPDistractionFreeDivPart": @4,           // ScintillaViewParams::_distractionFreeDivPart
        @"NPPInSelectionAutocheckThreshold": @1024, // FINDREPLACE_INSELECTION_THRESHOLD_DEFAULT
        @"NPPFillFindWhatThreshold": @1024,         // FILL_FINDWHAT_THRESHOLD_DEFAULT
        @"NPPRecentFilesDisplay": @(NPPRecentFilesDisplayFullPath),   // _recentFileCustomLength = RECENTFILES_SHOWFULLPATH
        @"NPPMultiInstanceMode": @(NPPMultiInstanceMono),
        @"NPPDarkModeTone": @(NPPDarkModeToneBlack),
        @"NPPToolbarColor": @(NPPToolbarColorDefault),
    };
    for (NSString *k in intDefaults) {
        id kept = [D() objectForKey:k];
        [D() removeObjectForKey:k];
        expectInt(([NSString stringWithFormat:@"default.%@", k]), [D() integerForKey:k], intDefaults[k].longLongValue);
        kept ? [D() setObject:kept forKey:k] : [D() removeObjectForKey:k];
    }

    // ---- every property this file declares is registered with a default -----------------------------------------
    // An unregistered key reads back as NO / 0 / nil, which looks like a deliberate default and is not: the page
    // would show one thing on a fresh install and the reader would see another. Driven off the runtime's property
    // list rather than a hand-kept array, so a property added to the header later cannot skip it.
    // Exempt: the derived switches and the seven proxied to NPPAutoCompletion have no key of their own,
    // contextMenuCommandTags defaults through +defaultContextMenuCommandTags, and fontName's "unset" means
    // "the theme's font" — registering one would remove that state.
    NSSet<NSString *> *notOwnKey = [NSSet setWithArray:@[
        @"highlightCurrentLine", @"caretBlink", @"showFoldMargin", @"autoIndent", @"checkFileChangesOnActivation",
        @"edgeColumn", @"contextMenuCommandTags", @"fontName",
        @"autoCompleteEnabled", @"autoCompleteMode", @"autoCompleteTriggerLength", @"autoCompleteIgnoreNumbers",
        @"autoCompleteBrief", @"autoCompleteFunctionParameterHints", @"autoCompleteInsertHTMLCloseTag",
    ]];
    NSDictionary *registrationDomain = [D() volatileDomainForName:NSRegistrationDomain];
    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(self_, &propertyCount);
    expect(propertyCount > 50, @"default.property-list-is-empty");   // an empty list would pass every check below
    for (unsigned int i = 0; i < propertyCount; i++) {
        NSString *name = @(property_getName(properties[i]));
        // Attributes are comma separated; "R" on its own is readonly, which stores nothing.
        if ([[@(property_getAttributes(properties[i])) componentsSeparatedByString:@","] containsObject:@"R"]) continue;
        if ([notOwnKey containsObject:name]) continue;
        NSString *key = [NSString stringWithFormat:@"NPP%@%@", [name substringToIndex:1].uppercaseString,
                                                               [name substringFromIndex:1]];
        expect(registrationDomain[key] != nil,
               ([NSString stringWithFormat:@"default.unregistered: %@ reads %@, which -registerDefaults never sets", name, key]));
    }
    free(properties);

    // ---- ranged settings clamp, in the getter as well as the setter ---------------------------------------------
    // A value out of range reaches the reader as an array index or a view size; the getter has to clamp too, because
    // it is what an older build or a `defaults write` leaves behind.
    p.borderWidth = 999;   expectInt(@"clamp.borderWidth.high", p.borderWidth, 30);
    p.borderWidth = -5;    expectInt(@"clamp.borderWidth.low", p.borderWidth, 0);
    p.distractionFreeDivPart = 1;  expectInt(@"clamp.distractionFree.low", p.distractionFreeDivPart, 3);
    p.distractionFreeDivPart = 99; expectInt(@"clamp.distractionFree.high", p.distractionFreeDivPart, 9);
    [D() setInteger:0 forKey:@"NPPDistractionFreeDivPart"];      // written behind the setter's back
    expectInt(@"clamp.distractionFree.getter", p.distractionFreeDivPart, 3);
    p.recentFilesCustomLength = 0;    expectInt(@"clamp.recentLength.low", p.recentFilesCustomLength, 1);
    p.recentFilesCustomLength = 9999; expectInt(@"clamp.recentLength.high", p.recentFilesCustomLength, 259);
    p.printMarginTop = 500; expectInt(@"clamp.printMargin", p.printMarginTop, 100);

    // ---- delimiters are one character each -----------------------------------------------------------------------
    p.delimiterOpen = @"<<<";
    expect([p.delimiterOpen isEqualToString:@"<"], @"delimiter.cuts-to-one-character");
    p.delimiterClose = @"";
    expect([p.delimiterClose isEqualToString:@")"], @"delimiter.empty-falls-back");
    [D() setObject:@"   " forKey:@"NPPDelimiterOpen"];           // whitespace is not a delimiter
    expect([p.delimiterOpen isEqualToString:@"("], @"delimiter.blank-falls-back");

    // ---- the recent-files display modes --------------------------------------------------------------------------
    NSString *deep = @"/Users/someone/Documents/projects/notepad-plus-plus/PowerEditor/src/Parameters.cpp";
    p.recentFilesDisplay = NPPRecentFilesDisplayFileName;
    expect([[p recentFileMenuTitleForPath:deep] isEqualToString:@"Parameters.cpp"], @"recent.title.name-only");
    p.recentFilesDisplay = NPPRecentFilesDisplayFullPath;
    expect([[p recentFileMenuTitleForPath:deep] isEqualToString:deep], @"recent.title.full-path");
    p.recentFilesDisplay = NPPRecentFilesDisplayCustomLength;
    p.recentFilesCustomLength = 20;
    NSString *cut = [p recentFileMenuTitleForPath:deep];
    expect(cut.length <= 21 && cut.length < deep.length, ([NSString stringWithFormat:@"recent.title.custom-cuts: %@", cut]));
    expect([cut containsString:@"…"], @"recent.title.custom-elides");
    p.recentFilesCustomLength = 259;
    expect([[p recentFileMenuTitleForPath:deep] isEqualToString:deep], @"recent.title.custom-keeps-short-paths");

    // ---- the dark-mode Reset button lands back on NppDarkMode::darkColors -----------------------------------------
    p.darkModeCustomBackground = @"123456";
    p.darkModeCustomText = @"654321";
    [p resetDarkModeCustomColors];
    expect([p.darkModeCustomBackground isEqualToString:@"202020"], @"darkmode.reset.background");
    expect([p.darkModeCustomText isEqualToString:@"E0E0E0"], @"darkmode.reset.text");
    expect([p.darkModeCustomDisabledEdge isEqualToString:@"484848"], @"darkmode.reset.disabledEdge");

    // ---- command surface ---------------------------------------------------------------------------------------
    expect([self_ handlesCommand:NPPCmdSettingsPreferences], @"cmd.handles.preferences");
    expect([self_ handlesCommand:NPPCmdSettingsStyleConfigurator], @"cmd.handles.styleConfigurator");
    expect([self_ handlesCommand:NPPCmdSettingsImportStyleTheme], @"cmd.handles.importTheme");
    expect([self_ handlesCommand:NPPCmdSettingsEditContextMenu], @"cmd.handles.contextMenu");
    expect([self_ handlesCommand:NPPCmdSettingsFileAssociation], @"cmd.handles.fileAssociation");
    expect(![self_ handlesCommand:NPPCmdFileNew], @"cmd.does-not-overclaim");
    // These three read this file's settings but belong to NPPEditCommands. Claiming them here also re-targets their
    // menu items away from that owner (+load / -claimOwnMenuItemsIn:), so over-claiming is a silent hijack.
    expect(![self_ handlesCommand:NPPCmdEditInsertDateTimeCustom], @"cmd.leaves-dateTime-to-NPPEditCommands");
    expect(![self_ handlesCommand:NPPCmdEditSearchOnInternet], @"cmd.leaves-searchInternet-to-NPPEditCommands");
    expect(![self_ handlesCommand:NPPCmdEditChangeSearchEngine], @"cmd.leaves-changeSearchEngine-to-NPPEditCommands");
    expect([self_ canPerformCommand:NPPCmdSettingsPreferences context:noContext], @"cmd.can.preferences");
    expect(![self_ performCommand:NPPCmdFileNew context:noContext], @"cmd.perform.rejects-foreign");
    // The page NPPEditCommands opens for Change Search Engine has to exist, or it silently lands on page 1.
    expect([NPPPreferencePageNames() containsObject:@"Search Engine"], @"page.search-engine-name");

    // ---- the Preferences window itself ---------------------------------------------------------------------------
    // Every control's identifier has to be a real NPPPreferences property: -refresh reads them all through KVC, so a
    // typo is an exception the moment the window opens. -refresh is called explicitly because the window is a
    // singleton — relying on the one -refresh in its initialiser would skip this check on every run but the first.
    @try {
        NPPPreferencesWindowController *prefsWindow = [NPPPreferencesWindowController shared];
        [prefsWindow selectPageNamed:@"Backup"];
        [prefsWindow refresh];

        // The other half of that: a property with no control is a setting nobody can reach. Everything the
        // preference.rc audit added is listed here, so declaring one and forgetting its control fails the run.
        NSSet<NSString *> *shown = [prefsWindow controlIdentifiers];
        NSArray<NSString *> *mustBeOnAPage = @[
            @"hideMenuBar", @"hideMenuRightShortcuts",
            @"toolbarColorizationComplete", @"toolbarColor", @"toolbarCustomColor",
            @"tabBarReduce", @"tabBarAlternateIcons", @"tabBarDrawInactiveTab", @"tabBarDrawTopBar",
            @"tabBarShowOnlyPinnedButton", @"tabBarInactiveTabShowButton",
            @"smoothFont", @"foldingCommandsToggleable", @"rightClickKeepsSelection",
            @"selectedTextForegroundSingleColor",
            @"disableAdvancedScrolling", @"disableSelectedTextDragDrop", @"preventC0Input",
            @"darkModeTone", @"darkModeCustomBackground", @"darkModeCustomSofterBackground",
            @"darkModeCustomHotBackground", @"darkModeCustomPureBackground", @"darkModeCustomErrorBackground",
            @"darkModeCustomText", @"darkModeCustomDarkerText", @"darkModeCustomDisabledText",
            @"darkModeCustomLinkText", @"darkModeCustomEdge", @"darkModeCustomHotEdge", @"darkModeCustomDisabledEdge",
            @"borderWidth", @"showBorderEdge", @"lineNumberDynamicWidth", @"distractionFreeDivPart",
            @"addNewDocumentOnStartup", @"useContentAsTabName",
            @"checkRecentFilesAtLaunch", @"recentFilesInSubmenu", @"recentFilesDisplay", @"recentFilesCustomLength",
            @"highlightNonHTMLZone", @"smartHighlightAnotherView", @"smartHighlightUseFindSettings",
            @"printFormFeedPageBreak", @"printMarginTop", @"printMarginLeft", @"printMarginRight", @"printMarginBottom",
            @"printHeaderFontName", @"printHeaderFontSize", @"printHeaderFontBold", @"printHeaderFontItalic",
            @"printFooterFontName", @"printFooterFontSize", @"printFooterFontBold", @"printFooterFontItalic",
            @"inSelectionAutocheckThreshold", @"fillFindWhatThreshold", @"monospacedFontFindDlg",
            @"confirmReplaceInAllOpenDocs", @"replaceStopsWithoutFindingNext",
            @"finderShowOnlyOneEntryPerFoundLine", @"findInFilesIgnoreOpenedFiles",
            @"keepSessionAbsentFileEntries", @"autoCompleteInsertWithTab", @"autoCompleteInsertWithEnter",
            @"multiInstanceMode",
            @"clipboardHistoryPanelKeepState", @"docListPanelKeepState", @"charPanelKeepState",
            @"fileBrowserPanelKeepState", @"projectPanelKeepState", @"docMapPanelKeepState",
            @"funcListPanelKeepState", @"pluginPanelKeepState",
            @"delimiterOpen", @"delimiterClose", @"delimiterSelectionOnEntireDocument",
            @"settingsDirectoryEnabled", @"settingsDirectory", @"largeFileAllowAutoCompletion",
            @"muteAllSounds", @"shortTitleBar", @"saveAllConfirm",
            @"sessionFileExtension", @"workspaceFileExtension",
            @"systemTrayAction", @"renderingMode", @"autoUpdateMode",
        ];
        for (NSString *key in mustBeOnAPage)
            if (![shown containsObject:key])
                [fails addObject:[NSString stringWithFormat:@"window.no-control-for-%@", key]];

        // Shown, and shown disabled — not quietly dropped, and not left live. The first five macOS cannot honour
        // at all; the last one is a stored setting no module in this port reads yet, so the control would look
        // live and do nothing. Each one's tooltip names the file that would have to honour it.
        for (NSString *key in @[@"systemTrayAction", @"renderingMode", @"autoUpdateMode",
                                @"hideMenuBar", @"hideMenuRightShortcuts",
                                @"pluginPanelKeepState"])
            expect([prefsWindow everyControlDisabledForIdentifier:key],
                   ([NSString stringWithFormat:@"window.unsupported-control-is-live: %@", key]));
    } @catch (NSException *e) {
        [fails addObject:[NSString stringWithFormat:@"window.build: %@: %@", e.name, e.reason]];
    }

    // The theme file the Style Configurator and Import Style Theme both address must be readable and parse.
    NSURL *themeURL = NPPThemeFileURL(NPPLanguageManager.shared.currentThemeName ?: kDefaultThemeName);
    if (themeURL) {
        NSError *themeErr = nil;
        NSXMLDocument *themeDoc = [[NSXMLDocument alloc] initWithContentsOfURL:themeURL options:NSXMLNodeLoadExternalEntitiesNever error:&themeErr];
        expect(themeDoc != nil, ([NSString stringWithFormat:@"theme.file-parses (%@)", themeURL.lastPathComponent]));
        expect([themeDoc.rootElement elementsForName:@"LexerStyles"].count > 0 ||
               [themeDoc.rootElement elementsForName:@"GlobalStyles"].count > 0, @"theme.file-has-styles");
    }

    // ---- Style Configurator: "Default keywords" beside "User keywords" (N++ WordStyleDlg) -------------------------
    // The list is the lexer's own, so it has to come from the bundled language file and not from the language table,
    // which holds base + user once anything has been added.
    expect([NPPWords(NPPDefaultKeywordsForLanguage(@"cpp", @"instre1")) containsObject:@"while"],
           @"styleconf.default-keywords-are-the-lexer's");
    expect(NPPDefaultKeywordsForLanguage(@"cpp", @"no-such-class").length == 0, @"styleconf.default-keywords-unknown-class");
    @try {   // the box and its label have to be on the window, or the list is one nobody can see
        __block BOOL sawLabel = NO;
        __block NSTextView *box = nil;
        __block NSTableView *langTable = nil, *styleTable = nil;
        NPPStyleConfiguratorController *sc = [NPPStyleConfiguratorController shared];
        [sc loadCurrentTheme];   // -showWindow: does this; the lists are empty until it runs
        NPPWalkViews(sc.window.contentView, ^(NSView *v) {
            if ([v isKindOfClass:NSTextView.class] && !((NSTextView *)v).isEditable) box = (NSTextView *)v;
            if ([v isKindOfClass:NSTextField.class] &&
                [((NSTextField *)v).stringValue hasPrefix:@"Default keywords"]) sawLabel = YES;
            if ([v isKindOfClass:NSTableView.class]) {
                NSString *col = ((NSTableView *)v).tableColumns.firstObject.title;
                if ([col isEqualToString:@"Language"]) langTable = (NSTableView *)v;
                else if ([col isEqualToString:@"Style"]) styleTable = (NSTableView *)v;
            }
        });
        expect(sawLabel, @"styleconf.default-keywords-label-shown");
        expect(box != nil, @"styleconf.default-keywords-box-shown");
        // …and the box has to be *fed*. A read-only box nobody fills passes every check above, so drive the two
        // lists the way the user does until a style with a keyword class comes up, and look for a word only the
        // lexer's own list has. This is the whole access path: theme keywordClass -> langs.model.xml -> the box.
        BOOL showsLexerList = NO;
        for (NSInteger c = 0; box && !showsLexerList && c < langTable.numberOfRows; ++c) {
            [langTable selectRowIndexes:[NSIndexSet indexSetWithIndex:c] byExtendingSelection:NO];
            for (NSInteger s = 0; s < styleTable.numberOfRows; ++s) {
                [styleTable selectRowIndexes:[NSIndexSet indexSetWithIndex:s] byExtendingSelection:NO];
                if ([NPPWords(box.string) containsObject:@"while"]) { showsLexerList = YES; break; }
            }
        }
        expect(showsLexerList, @"styleconf.default-keywords-box-is-filled");
    } @catch (NSException *e) {
        [fails addObject:[NSString stringWithFormat:@"styleconf.build: %@: %@", e.name, e.reason]];
    }

    // ---- date format --------------------------------------------------------------------------------------------
    NSString *savedFormat = p.dateTimeFormat;
    p.dateTimeFormat = @"yyyy";
    expectInt(@"date.custom-format-length", (long long)[p formattedDateTimeNowCustom].length, 4);
    p.dateTimeFormat = savedFormat;

    for (NSString *k in touched) {
        if (saved[k]) [D() setObject:saved[k] forKey:k]; else [D() removeObjectForKey:k];
    }
    // The keys went back behind the setters, so the cached context menu is still the test's; go through the
    // property once to rebuild it from whatever the user actually had.
    p.contextMenuCommandTags = saved[@"NPPContextMenuCommandTags"];
    // Same for the language table: the two maps went back behind their setters, so it still holds the test's
    // entries (or, more often, none — in which case this returns straight away).
    [p reloadLanguagesWithUserEntries];
    return fails;
}
