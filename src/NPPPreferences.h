// NPPPreferences.h — user settings (NSUserDefaults-backed) + the Preferences window.
//
// Page set and setting names follow N++ WinControls/Preference/preference.rc and Parameters.h (NppGUI,
// ScintillaViewParams); defaults mirror N++ where they make sense on macOS.
//
// TWO APPLY PATHS. Everything NPPDocument -applyPreferences already knows about is applied there, synchronously,
// from NPPPreferencesDidChangeNotification. Settings this file added (current-line frame, multi-column edge,
// fold marker shapes, non-printing characters, per-language indentation, custom word characters, editor padding)
// are applied by NPPPreferences itself, on the *next* main-queue turn, so they always land after the
// synchronous observers rather than racing them. Old properties that a new one subsumes are derived from it
// (highlightCurrentLine <- currentLineIndicator, showFoldMargin <- foldMarginStyle, autoIndent <- autoIndentMode,
// caretBlink <- caretBlinkRate, checkFileChangesOnActivation <- fileAutoDetection) so both paths agree.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPDocument.h"
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const NPPPreferencesDidChangeNotification;   // posted after any setter

// N++ ScintillaViewParams::lineHiliteMode
typedef NS_ENUM(NSInteger, NPPCurrentLineIndicator) {
    NPPCurrentLineNone = 0, NPPCurrentLineHighlight, NPPCurrentLineFrame,
};
// N++ folderStyle, in preference.rc order.
typedef NS_ENUM(NSInteger, NPPFoldMarginStyle) {
    NPPFoldMarginSimple = 0, NPPFoldMarginArrow, NPPFoldMarginCircle, NPPFoldMarginBox, NPPFoldMarginNone,
};
// N++ ScintillaViewParams::crlfMode (the two colour variants are the "custom colour" checkbox here).
typedef NS_ENUM(NSInteger, NPPEOLDisplayMode) { NPPEOLDisplayPlainText = 0, NPPEOLDisplayRoundedRect };
// N++ ScintillaViewParams::npcMode
typedef NS_ENUM(NSInteger, NPPNonPrintingMode) { NPPNonPrintingAbbreviation = 0, NPPNonPrintingCodepoint };
// N++ lineWrapMethod
typedef NS_ENUM(NSInteger, NPPLineWrapMethod) { NPPLineWrapDefault = 0, NPPLineWrapAligned, NPPLineWrapIndent };
// N++ AutoIndentMode. Basic carries the previous line's indent over; Advanced is NPPDocument's language-aware
// block indenting (C-like braces, Python colons) and is upstream's default.
typedef NS_ENUM(NSInteger, NPPAutoIndentMode) { NPPAutoIndentNone = 0, NPPAutoIndentBasic, NPPAutoIndentAdvanced };
// N++ urlMode (NppConstants.h): what a clickable link looks like. NPPDocument reads the raw values from NPPStyleURL.
typedef NS_ENUM(NSInteger, NPPURLStyle) {
    NPPURLStyleDisabled = 0, NPPURLStyleForegroundPlain, NPPURLStyleForegroundUnderline,
    NPPURLStyleBackgroundPlain, NPPURLStyleBackgroundUnderline,
};
// N++ cdDisabled / cdEnabledNew / cdAutoUpdate / cdGo2end, flattened into the combo it is shown as.
typedef NS_ENUM(NSInteger, NPPFileAutoDetection) {
    NPPFileAutoDetectionDisabled = 0, NPPFileAutoDetectionEnabled, NPPFileAutoDetectionSilent, NPPFileAutoDetectionSilentGoToEnd,
};
// N++ NppGUI::SearchEngineChoice, same order.
typedef NS_ENUM(NSInteger, NPPSearchEngine) {
    NPPSearchEngineCustom = 0, NPPSearchEngineDuckDuckGo, NPPSearchEngineGoogle, NPPSearchEngineBing,
    NPPSearchEngineYahoo, NPPSearchEngineStackOverflow,
};
// N++ toolBarStatusType, in preference.rc order. NPPToolBar renders the first four; the fifth has no distinct
// look here (it would be Fluent small again), so the Toolbar page shows it disabled.
typedef NS_ENUM(NSInteger, NPPToolbarIconSet) {
    NPPToolbarFluentSmall = 0, NPPToolbarFluentLarge, NPPToolbarFilledFluentSmall, NPPToolbarFilledFluentLarge, NPPToolbarStandardSmall,
};
// N++ FluentColor (NppConstants.h), same order. "Accent" is the macOS accent colour here.
typedef NS_ENUM(NSInteger, NPPToolbarColor) {
    NPPToolbarColorDefault = 0, NPPToolbarColorRed, NPPToolbarColorGreen, NPPToolbarColorBlue,
    NPPToolbarColorPurple, NPPToolbarColorCyan, NPPToolbarColorOlive, NPPToolbarColorYellow,
    NPPToolbarColorAccent, NPPToolbarColorCustom,
};
// N++ NppDarkMode::ColorTone, same values — including the 32 that "Customized" really is upstream.
typedef NS_ENUM(NSInteger, NPPDarkModeTone) {
    NPPDarkModeToneBlack = 0, NPPDarkModeToneRed, NPPDarkModeToneGreen, NPPDarkModeToneBlue,
    NPPDarkModeTonePurple, NPPDarkModeToneCyan, NPPDarkModeToneOlive, NPPDarkModeToneCustomized = 32,
};
// N++ keeps one int (-1 = full path, 0 = file name only, N = that many characters); split in two here so the
// customised length survives switching to another mode and back.
typedef NS_ENUM(NSInteger, NPPRecentFilesDisplay) {
    NPPRecentFilesDisplayFileName = 0, NPPRecentFilesDisplayFullPath, NPPRecentFilesDisplayCustomLength,
};
// N++ MultiInstSetting, same order.
typedef NS_ENUM(NSInteger, NPPMultiInstanceMode) {
    NPPMultiInstanceMono = 0, NPPMultiInstanceSessionInNewInstance, NPPMultiInstanceAlways,
};
// The three N++ combos macOS has no answer for. Stored so the disabled controls on the MISC page have a real
// property to read back, never acted on. N++ SysTrayAction / writeTechnologyEngine / NppGUI::AutoUpdateMode.
typedef NS_ENUM(NSInteger, NPPSystemTrayAction) {
    NPPSystemTrayNone = 0, NPPSystemTrayMinimize, NPPSystemTrayClose, NPPSystemTrayMinimizeAndClose,
};
typedef NS_ENUM(NSInteger, NPPRenderingMode) {
    NPPRenderingDefault = 0, NPPRenderingDirectWrite, NPPRenderingDirectWriteRetain,
    NPPRenderingDirectWriteDC, NPPRenderingDirectWriteDX11,
};
typedef NS_ENUM(NSInteger, NPPAutoUpdateMode) {
    NPPAutoUpdateDisabled = 0, NPPAutoUpdateOnStartup, NPPAutoUpdateOnExit,
};

// N++ IDM_EDIT_COPY_LINK (menuCmdID.h; the context menu builds it in ContextMenu.cpp:115). NPPCommands.h is shared
// and has no spare Edit tag, so the tag is private to this file. 13000/13001 are NPPEditCommands' clipboard pair,
// so this block starts at 13100 — anything added here must stay above it.
typedef NS_ENUM(NSInteger, NPPPreferencesPrivateCmd) {
    NPPCmdEditCopyLink = 13100,
};

@interface NPPPreferences : NSObject <NPPCommandHandler>
+ (instancetype)shared;

// ---- General ----
@property (nonatomic) BOOL hideStatusBar;                // NO
@property (nonatomic) BOOL hideMenuBar;                  // NO (N++ _menuBarShow = true)
@property (nonatomic) BOOL hideMenuRightShortcuts;       // NO

// ---- Toolbar (read by NPPToolBar) ----
@property (nonatomic) BOOL toolbarHidden;                // NO
@property (nonatomic) NPPToolbarIconSet toolbarIconSet;  // NPPToolbarFluentSmall
@property (nonatomic) BOOL toolbarColorizationComplete;  // NO (N++ TbIconInfo::_tbUseMono; NO = "Partial")
@property (nonatomic) NPPToolbarColor toolbarColor;      // NPPToolbarColorDefault
@property (nonatomic, copy) NSString *toolbarCustomColor;   // "RRGGBB", "000000"; used when toolbarColor is Custom

// ---- Tab Bar (NPPTabBarView reads vertical/multi-line/locked/peek itself; tabBarHidden is pushed by this file) ----
@property (nonatomic) BOOL tabBarHidden;                    // NO
@property (nonatomic) BOOL tabBarVertical;                  // NO
@property (nonatomic) BOOL tabBarMultiLine;                 // NO
@property (nonatomic) BOOL tabBarLocked;                    // NO
@property (nonatomic) BOOL tabPeekOnTab;                    // NO (N++ _isDocPeekOnTab: hover a tab to preview it)
@property (nonatomic) BOOL exitOnClosingLastTab;            // NO
@property (nonatomic) NSInteger tabMaxLabelLength;          // 0 = no compacting (N++ _tabCompactLabelLen)
@property (nonatomic) BOOL tabBarShowCloseButtons;          // YES
@property (nonatomic) BOOL tabBarDoubleClickToClose;        // NO
// The rest of N++'s _tabStatus bit field, one property per bit; defaults are the bits set in its initialiser.
@property (nonatomic) BOOL tabBarReduce;                    // YES (TAB_REDUCE — the short tab strip)
@property (nonatomic) BOOL tabBarAlternateIcons;            // NO  (TAB_ALTICONS)
@property (nonatomic) BOOL tabBarDrawInactiveTab;           // YES (TAB_DRAWINACTIVETAB — tint inactive tabs)
@property (nonatomic) BOOL tabBarDrawTopBar;                // YES (TAB_DRAWTOPBAR — coloured bar on the active tab)
@property (nonatomic) BOOL tabBarShowOnlyPinnedButton;      // NO  (TAB_SHOWONLYPINNEDBUTTON)
@property (nonatomic) BOOL tabBarInactiveTabShowButton;     // NO  (TAB_INACTIVETABSHOWBUTTON)

// ---- Editing 1 ----
@property (nonatomic) NSInteger tabSize;                 // 4
@property (nonatomic) BOOL replaceTabsBySpaces;          // NO
@property (nonatomic) BOOL wordWrap;                     // NO
@property (nonatomic) NPPLineWrapMethod lineWrapMethod;  // NPPLineWrapAligned (N++ default)
@property (nonatomic) NPPCurrentLineIndicator currentLineIndicator;   // NPPCurrentLineHighlight
@property (nonatomic) NSInteger currentLineFrameWidth;   // 1..6, 1
@property (nonatomic) NSInteger caretWidth;              // 1..3, 1
@property (nonatomic) NSInteger caretBlinkRate;          // ms, 0 = solid caret; 600
@property (nonatomic) BOOL virtualSpace;                 // NO
@property (nonatomic) BOOL scrollBeyondLastLine;         // NO
@property (nonatomic) BOOL highlightCurrentLine;         // derived: currentLineIndicator != None
@property (nonatomic) BOOL caretBlink;                   // derived: caretBlinkRate > 0
@property (nonatomic) BOOL smoothFont;                       // NO  (N++ _doSmoothFont)
@property (nonatomic) BOOL foldingCommandsToggleable;        // NO  (N++ _enableFoldCmdToggable)
@property (nonatomic) BOOL rightClickKeepsSelection;         // NO  (N++ _rightClickKeepsSelection)
@property (nonatomic) BOOL lineCopyCutWithoutSelection;      // YES (N++ _lineCopyCutWithoutSelection)
@property (nonatomic) BOOL selectedTextForegroundSingleColor;// NO  (N++ _selectedTextForegroundSingleColor)
@property (nonatomic) BOOL disableAdvancedScrolling;         // NO  (N++ _disableAdvancedScrolling)
@property (nonatomic) BOOL disableSelectedTextDragDrop;      // NO  (N++ _disableSelectedTextDragDrop)

// ---- Editing 2 ----
@property (nonatomic) BOOL multiSelection;                    // YES (multi-editing)
@property (nonatomic) BOOL columnSelectionToMultiEditing;     // YES
@property (nonatomic) NPPEOLDisplayMode eolDisplayMode;       // NPPEOLDisplayRoundedRect
@property (nonatomic) BOOL eolCustomColorEnabled;             // NO
@property (nonatomic, copy) NSString *eolCustomColor;         // "RRGGBB", "DADADA"
@property (nonatomic) BOOL showEOL;                           // NO (View > Show Symbol)
@property (nonatomic) BOOL showNonPrintingChars;              // NO
@property (nonatomic) NPPNonPrintingMode nonPrintingMode;     // NPPNonPrintingAbbreviation
@property (nonatomic) BOOL nonPrintingCustomColorEnabled;     // NO
@property (nonatomic, copy) NSString *nonPrintingCustomColor; // "RRGGBB", "FF0000"
@property (nonatomic) BOOL nonPrintingIncludeC1AndUnicodeEOL; // NO
@property (nonatomic) BOOL preventC0Input;                    // YES (N++ _npcNoInputC0)

// ---- Dark Mode (N++ DarkModeConf; the tones are Win32 chrome, see the page's note) ----
@property (nonatomic) NPPDarkModeTone darkModeTone;              // NPPDarkModeToneBlack
// The 12 slots of NppDarkMode::Colors, in its own order; used when darkModeTone is Customized. "RRGGBB".
@property (nonatomic, copy) NSString *darkModeCustomBackground;        // "202020" (content background)
@property (nonatomic, copy) NSString *darkModeCustomSofterBackground;  // "383838" (control background)
@property (nonatomic, copy) NSString *darkModeCustomHotBackground;     // "454545" (hot track item)
@property (nonatomic, copy) NSString *darkModeCustomPureBackground;    // "202020" (dialog background)
@property (nonatomic, copy) NSString *darkModeCustomErrorBackground;   // "B00000"
@property (nonatomic, copy) NSString *darkModeCustomText;              // "E0E0E0"
@property (nonatomic, copy) NSString *darkModeCustomDarkerText;        // "C0C0C0"
@property (nonatomic, copy) NSString *darkModeCustomDisabledText;      // "808080"
@property (nonatomic, copy) NSString *darkModeCustomLinkText;          // "FFFF00"
@property (nonatomic, copy) NSString *darkModeCustomEdge;              // "646464"
@property (nonatomic, copy) NSString *darkModeCustomHotEdge;           // "9B9B9B"
@property (nonatomic, copy) NSString *darkModeCustomDisabledEdge;      // "484848"
- (void)resetDarkModeCustomColors;                            // back to the 12 values above

// ---- Margins / Border / Edge ----
@property (nonatomic) NPPFoldMarginStyle foldMarginStyle;   // NPPFoldMarginBox
@property (nonatomic) BOOL showFoldMargin;                  // derived: foldMarginStyle != None
@property (nonatomic) BOOL showLineNumbers;                 // YES
@property (nonatomic) BOOL showBookmarkMargin;              // YES
@property (nonatomic) BOOL showChangeHistoryMargin;         // YES
@property (nonatomic) BOOL changeHistoryIndicator;          // NO (marks in the text as well as the margin)
@property (nonatomic) BOOL showIndentGuides;                // YES
@property (nonatomic) BOOL showWhitespace;                  // NO
@property (nonatomic) BOOL showWrapSymbol;                  // NO
@property (nonatomic) BOOL showEdgeLine;                    // NO
@property (nonatomic, copy) NSString *edgeColumns;          // "80", or "80 100 120" for the multi-column edge
@property (nonatomic) NSInteger edgeColumn;                 // derived: first entry of edgeColumns
@property (nonatomic) BOOL edgeBackgroundMode;              // NO
@property (nonatomic) NSInteger paddingLeft;                // 0..9 px
@property (nonatomic) NSInteger paddingRight;               // 0..9 px
@property (nonatomic) NSInteger borderWidth;                // 0..30 px, 2 (N++ _borderWidth: the editor's frame)
@property (nonatomic) BOOL showBorderEdge;                  // YES (N++ _showBorderEdge; its checkbox is "No edge")
@property (nonatomic) BOOL lineNumberDynamicWidth;          // YES (N++ _lineNumberMarginDynamicWidth; NO = constant)
@property (nonatomic) NSInteger distractionFreeDivPart;     // 3..9, 4 — Distraction Free padding is width/this
@property (nonatomic, readonly) NSArray<NSNumber *> *edgeColumnList;   // parsed, clamped, de-duplicated

// ---- New Document ----
@property (nonatomic) NPPEOL defaultEOL;                 // NPPEOLUnix on macOS
@property (nonatomic) NPPEncoding defaultEncoding;       // NPPEncodingUTF8
@property (nonatomic) NSInteger defaultCodepage;         // CFStringEncoding used when defaultEncoding is ANSI
@property (nonatomic, copy) NSString *defaultLanguageName;   // "normal"
@property (nonatomic) BOOL openAnsiAsUTF8;               // YES
@property (nonatomic) BOOL addNewDocumentOnStartup;      // NO (N++ _addNewDocumentOnStartup)
@property (nonatomic) BOOL useContentAsTabName;          // NO (N++ _useContentAsTabName: first line names the tab)

// ---- Default Directory (N++ OpenSaveDirSetting; NPPEditorWindowController -defaultPanelDirectoryForDocument:) ----
@property (nonatomic) NSInteger defaultDirectoryMode;       // 0 follow current document, 1 last used, 2 fixed
@property (nonatomic, copy) NSString *defaultDirectoryPath; // used when defaultDirectoryMode == 2

// ---- Recent Files History ----
@property (nonatomic, copy) NSArray<NSString *> *recentFilePaths;    // most recent first
@property (nonatomic) NSInteger maxRecentFiles;                      // 0..30, 15
@property (nonatomic) BOOL checkRecentFilesAtLaunch;                 // NO (N++ _checkHistoryFiles; its checkbox is
                                                                    // the inverse, "Don't check at launch time")
@property (nonatomic) BOOL recentFilesInSubmenu;                     // NO (N++ putRecentFileInSubMenu())
@property (nonatomic) NPPRecentFilesDisplay recentFilesDisplay;      // NPPRecentFilesDisplayFullPath
@property (nonatomic) NSInteger recentFilesCustomLength;             // 1..259, 259 — used by …DisplayCustomLength
- (void)addRecentFilePath:(NSString *)path;
- (void)clearRecentFiles;
- (NSString *)recentFileMenuTitleForPath:(NSString *)path;           // the label the File menu should show

// ---- Language (read by NPPAppDelegate -rebuildLanguageMenu; the SQL one by NPPLanguageManager) ----
@property (nonatomic) BOOL languageMenuCompact;                          // YES
@property (nonatomic, copy) NSArray<NSString *> *excludedLanguageNames;  // @[] — langs.model.xml names or short names
@property (nonatomic) BOOL sqlBackslashIsEscape;                         // YES

// ---- Indentation ----
@property (nonatomic) BOOL backspaceUnindent;               // NO
@property (nonatomic) NPPAutoIndentMode autoIndentMode;     // NPPAutoIndentAdvanced (N++ default)
@property (nonatomic) BOOL autoIndent;                      // derived: autoIndentMode != None
// Per-language override, N++'s <Language name=… tabSize=… replaceSpace=…>. nil = "use default value".
- (nullable NSDictionary *)indentSettingsForLanguageNamed:(NSString *)name;   // keys: size (NSNumber), spaces, backspaceUnindent (NSNumber BOOL)
- (void)setIndentSettings:(nullable NSDictionary *)settings forLanguageNamed:(NSString *)name;

// ---- Highlighting ----
@property (nonatomic) BOOL smartHighlighting;            // YES
@property (nonatomic) BOOL smartHighlightMatchCase;      // NO
@property (nonatomic) BOOL smartHighlightWholeWord;      // YES
@property (nonatomic) BOOL markAllMatchCase;             // YES
@property (nonatomic) BOOL markAllWholeWord;             // YES
@property (nonatomic) BOOL tagMatchHighlight;            // YES (N++ _enableTagsMatchHilite)
@property (nonatomic) BOOL tagAttrHighlight;             // YES (N++ _enableTagAttrsHilite; only with tagMatchHighlight)
@property (nonatomic) BOOL braceHighlighting;            // YES
@property (nonatomic) BOOL highlightNonHTMLZone;         // NO  (N++ _enableHiliteNonHTMLZone: comment/PHP/ASP zones)
@property (nonatomic) BOOL smartHighlightAnotherView;    // NO  (N++ _smartHiliteOnAnotherView)
@property (nonatomic) BOOL smartHighlightUseFindSettings;// NO  (N++ _smartHiliteUseFindSettings)

// ---- Print (the keys NPPPrintRenderer reads) ----
@property (nonatomic) NSInteger printColourMode;         // SC_PRINT_* (SC_PRINT_COLOURONWHITE)
@property (nonatomic) BOOL printLineNumbers;             // NO
@property (nonatomic) NSInteger printMagnification;      // -10..10, 0
@property (nonatomic, copy) NSString *printHeaderLeft;
@property (nonatomic, copy) NSString *printHeaderMiddle;
@property (nonatomic, copy) NSString *printHeaderRight;
@property (nonatomic, copy) NSString *printFooterLeft;
@property (nonatomic, copy) NSString *printFooterMiddle;
@property (nonatomic, copy) NSString *printFooterRight;
@property (nonatomic) BOOL printFormFeedPageBreak;       // NO (N++ _printFormFeedPageBreak)
// N++ PrintSettings::_marge, in millimetres; 0 on every side means "let the print panel decide".
@property (nonatomic) NSInteger printMarginTop;          // 0..100 mm, 0
@property (nonatomic) NSInteger printMarginLeft;         // 0..100 mm, 0
@property (nonatomic) NSInteger printMarginRight;        // 0..100 mm, 0
@property (nonatomic) NSInteger printMarginBottom;       // 0..100 mm, 0
@property (nonatomic, copy) NSString *printHeaderFontName;   // "" = the renderer's own band font
@property (nonatomic) NSInteger printHeaderFontSize;         // 0 = the renderer's own size
@property (nonatomic) BOOL printHeaderFontBold;              // NO (N++ _headerFontStyle & FONTSTYLE_BOLD)
@property (nonatomic) BOOL printHeaderFontItalic;            // NO
@property (nonatomic, copy) NSString *printFooterFontName;   // ""
@property (nonatomic) NSInteger printFooterFontSize;         // 0
@property (nonatomic) BOOL printFooterFontBold;              // NO
@property (nonatomic) BOOL printFooterFontItalic;            // NO

// ---- Searching (read by NPPFindPanelController / NPPFindInFiles / NPPSearchViewCommands) ----
@property (nonatomic) NSInteger inSelectionAutocheckThreshold;  // 1024 — selection this big auto-ticks "In selection"
@property (nonatomic) NSInteger fillFindWhatThreshold;          // 1024 — longer selections do not fill the Find field
@property (nonatomic) BOOL monospacedFontFindDlg;               // NO
@property (nonatomic) BOOL fillFindFieldWithSelected;           // YES (N++ _fillFindFieldWithSelected)
@property (nonatomic) BOOL fillFindFieldSelectCaret;            // YES (N++ _fillFindFieldSelectCaret)
@property (nonatomic) BOOL fillDirFieldFromActiveDoc;           // NO  (N++ _fillDirFieldFromActiveDoc)
@property (nonatomic) BOOL findDlgAlwaysVisible;                // NO  (N++ _findDlgAlwaysVisible)
@property (nonatomic) BOOL confirmReplaceInAllOpenDocs;         // YES
@property (nonatomic) BOOL replaceStopsWithoutFindingNext;      // NO  ("Replace: don't move to the next occurrence")
@property (nonatomic) BOOL finderShowOnlyOneEntryPerFoundLine;  // YES
@property (nonatomic) BOOL findInFilesIgnoreOpenedFiles;        // NO  (N++ _fif_ignoreunsavedChangesInOpenedFiles)

// ---- Files ----
@property (nonatomic) BOOL trimTrailingSpaceOnSave;         // NO
@property (nonatomic) BOOL detectEncodingWithUchardet;      // YES
@property (nonatomic) NPPFileAutoDetection fileAutoDetection;  // NPPFileAutoDetectionEnabled
@property (nonatomic) BOOL checkFileChangesOnActivation;    // derived: fileAutoDetection != Disabled

// ---- MISC (read by NPPEditorWindowController) ----
@property (nonatomic) BOOL documentSwitcher;                // YES — ⌃Tab MRU switcher (N++ NppGUI::_doTaskList)
@property (nonatomic) BOOL documentSwitcherMRU;              // YES — cycle in MRU order, not tab order (N++ _styleMRU)
@property (nonatomic) BOOL folderDroppedOpenFiles;          // NO — a dropped folder opens its files instead of
                                                            // becoming a workspace (N++ _isFolderDroppedOpenFiles)
@property (nonatomic) BOOL peekOnDocumentMap;               // NO  (N++ _isDocPeekOnMap)
@property (nonatomic) BOOL muteAllSounds;                   // NO  (N++ _muteSounds — suppresses NSBeep)
@property (nonatomic) BOOL shortTitleBar;                   // NO  (N++ _shortTitlebar — file name only, no path)
@property (nonatomic) BOOL saveAllConfirm;                  // YES (N++ _saveAllConfirm)
@property (nonatomic) BOOL fawAllowSymlink;                 // NO  (N++ _isFawSymlinkAllowed, Folder as Workspace)
@property (nonatomic, copy) NSString *sessionFileExtension;    // "" (N++ _definedSessionExt), no leading dot
@property (nonatomic, copy) NSString *workspaceFileExtension;  // "" (N++ _definedWorkspaceExt), no leading dot
@property (nonatomic) NPPSystemTrayAction systemTrayAction;    // NPPSystemTrayNone
@property (nonatomic) NPPRenderingMode renderingMode;          // NPPRenderingDirectWrite (N++ default)
@property (nonatomic) NPPAutoUpdateMode autoUpdateMode;        // NPPAutoUpdateOnStartup (N++ default)

// ---- Backup (the keys NPPBackupManager reads) ----
@property (nonatomic) BOOL rememberLastSession;             // YES
@property (nonatomic) BOOL backupSnapshotEnabled;           // YES
@property (nonatomic) NSInteger backupSnapshotInterval;     // seconds, 7
@property (nonatomic) NSInteger backupMode;                 // NPPBackupMode: 0 none / 1 simple / 2 verbose
@property (nonatomic, copy) NSString *backupDirectory;      // "" = beside the saved file
@property (nonatomic) BOOL keepSessionAbsentFileEntries;    // NO (N++ _keepSessionAbsentFileEntries: a file that has
                                                            // gone missing stays in the session instead of dropping)

// ---- Auto-Completion (proxied to NPPAutoCompletion, which owns the "NPPAutoComplete.*" keys) ----
@property (nonatomic) BOOL autoCompleteEnabled;
@property (nonatomic) NSInteger autoCompleteMode;           // NPPAutoCompleteMode
@property (nonatomic) NSInteger autoCompleteTriggerLength;  // 1..9
@property (nonatomic) BOOL autoCompleteIgnoreNumbers;
@property (nonatomic) BOOL autoCompleteBrief;
@property (nonatomic) BOOL autoCompleteFunctionParameterHints;
@property (nonatomic) BOOL autoCompleteInsertHTMLCloseTag;
@property (nonatomic) BOOL autoCloseBrackets;               // NPPDocument's matched-pair insertion, the master switch
// Which key accepts the highlighted completion (N++ _autocInsertSelectedUseTAB / …UseENTER). Unlike the settings
// above these are not proxied: NPPAutoCompletion reads the two keys below.
@property (nonatomic) BOOL autoCompleteInsertWithTab;       // YES
@property (nonatomic) BOOL autoCompleteInsertWithEnter;     // YES
@property (nonatomic, readonly) BOOL autoCompletionModuleAvailable;

// Which pairs autoCloseBrackets inserts (N++ MatchedPairConf; read by NPPDocument -charAdded:).
@property (nonatomic) BOOL matchedPairParentheses;          // YES
@property (nonatomic) BOOL matchedPairBrackets;             // YES
@property (nonatomic) BOOL matchedPairCurlyBrackets;        // YES
@property (nonatomic) BOOL matchedPairQuotes;               // YES
@property (nonatomic) BOOL matchedPairDoubleQuotes;         // YES
@property (nonatomic, copy) NSArray<NSString *> *matchedPairsUserDefined;   // @[], entries are 2 ASCII chars: @"<>"

// ---- Multi-Instance & Date ----
@property (nonatomic) NPPMultiInstanceMode multiInstanceMode;  // NPPMultiInstanceMono
@property (nonatomic, copy) NSString *dateTimeFormat;       // "yyyy-MM-dd HH:mm:ss" (N++ _dateTimeFormat)
@property (nonatomic) BOOL dateTimeReverseDefaultOrder;     // NO (N++ _dateTimeReverseDefaultOrder)
- (NSString *)formattedDateTimeNowCustom;                   // dateTimeFormat applied to now
// N++ "Panel State and [-nosession]": these panels reopen even when the session is not restored.
@property (nonatomic) BOOL clipboardHistoryPanelKeepState;  // NO
@property (nonatomic) BOOL docListPanelKeepState;           // NO
@property (nonatomic) BOOL charPanelKeepState;              // NO
@property (nonatomic) BOOL fileBrowserPanelKeepState;       // NO
@property (nonatomic) BOOL projectPanelKeepState;           // NO
@property (nonatomic) BOOL docMapPanelKeepState;            // NO
@property (nonatomic) BOOL funcListPanelKeepState;          // NO
@property (nonatomic) BOOL pluginPanelKeepState;            // NO — stored, never acted on: no plugin system here

// ---- Delimiter ----
@property (nonatomic) BOOL useDefaultWordChars;             // YES
@property (nonatomic, copy) NSString *customWordChars;      // extra characters counted as part of a word
// N++ delimiter selection (⌃double-click selects between the two): one ASCII character each.
@property (nonatomic, copy) NSString *delimiterOpen;        // "("
@property (nonatomic, copy) NSString *delimiterClose;       // ")"
@property (nonatomic) BOOL delimiterSelectionOnEntireDocument;   // NO — allow the match to span several lines

// ---- Performance (N++ LargeFileRestriction; all read by NPPDocument, which decides largeness once, at load) ----
@property (nonatomic) BOOL largeFileRestrictionEnabled;     // YES
@property (nonatomic) NSInteger largeFileSizeMB;            // 200 (NPP_STYLING_FILESIZE_LIMIT_DEFAULT)
@property (nonatomic) BOOL largeFileDeactivateWordWrap;     // YES
@property (nonatomic) BOOL largeFileAllowBraceMatch;        // NO
@property (nonatomic) BOOL largeFileAllowSmartHilite;       // NO
@property (nonatomic) BOOL largeFileAllowClickableLink;     // NO
@property (nonatomic) BOOL largeFileAllowAutoCompletion;    // NO
@property (nonatomic) BOOL largeFileSuppress2GBWarning;     // NO

// ---- Cloud & Link (clickable links; read by NPPDocument -updateClickableLinks) ----
// N++'s "Settings on cloud" is a directory its config.xml is read from and written to; the macOS equivalent is a
// settings-directory override, which is also what -settingsDir= sets (N++ drives _cloudPath from it too).
@property (nonatomic) BOOL settingsDirectoryEnabled;        // NO ("No Cloud")
@property (nonatomic, copy) NSString *settingsDirectory;    // "" — absolute path, used when the switch above is on
@property (nonatomic) NPPURLStyle styleURL;                 // NPPURLStyleForegroundUnderline
@property (nonatomic, copy) NSString *uriSchemes;           // space separated, added to http/https/ftp/file/mailto

// ---- Search Engine ----
@property (nonatomic) NPPSearchEngine searchEngine;         // NPPSearchEngineGoogle
@property (nonatomic, copy) NSString *searchEngineCustom;   // "https://…?q=$(CURRENT_WORD)"
- (nullable NSURL *)searchEngineURLForTerm:(NSString *)term;

// ---- Appearance / theme (edited in the Style Configurator, kept here) ----
@property (nonatomic, copy, nullable) NSString *fontName;   // nil = theme's Default Style font
@property (nonatomic) CGFloat fontSize;                     // 0 = theme's
@property (nonatomic, copy) NSString *themeName;            // "" = follow system appearance

// ---- Style Configurator: "User ext." and "User keywords" (N++ WordStyleDlg) ----
// Upstream keeps both in stylers.xml and folds them into the language table it builds: an extra extension mapped
// onto a built-in language, and extra words appended to one keyword class of its lexer. NPPLanguageManager builds
// its table from langs.model.xml, and the per-lexer SCI_SETKEYWORDS / SCI_SETIDENTIFIERS mapping that decides where
// a keyword class lands is private to it — so both are folded into a *copy* of langs.model.xml and handed back
// through its public -loadLangsXML:stylersXML:, which then does that mapping itself, substyles included.
- (NSString *)userExtensionsForLanguageNamed:(NSString *)name;    // "" when none; space separated, lowercase, no dots
- (void)setUserExtensions:(nullable NSString *)exts forLanguageNamed:(NSString *)name;
- (NSString *)userKeywordsForLanguageNamed:(NSString *)name keywordClass:(NSString *)cls;   // "instre1", "type1", "substyle3"…
- (void)setUserKeywords:(nullable NSString *)words forLanguageNamed:(NSString *)name keywordClass:(NSString *)cls;
// Rebuilds NPPLanguageManager's language table with the two maps above folded in and re-selects the current theme;
// buffers whose extension the maps have just claimed are re-typed. Called at launch (once the window controller
// publishes its context, which is before any file is opened) and by the two fields in the Style Configurator.
// While both maps are empty this is a no-op and nothing is written.
- (BOOL)reloadLanguagesWithUserEntries;

// ---- Style Configurator: "Global override" (N++ NppGUI::_globalOverride) ----
// Each flag forces the matching attribute of the theme's "Global override" style onto every style of every editor.
// The style itself (colours, font, size, bold/italic/underline) is edited in the Style Configurator like any other.
@property (nonatomic) BOOL globalOverrideForeground;        // NO
@property (nonatomic) BOOL globalOverrideBackground;        // NO
@property (nonatomic) BOOL globalOverrideFont;              // NO
@property (nonatomic) BOOL globalOverrideFontSize;          // NO
@property (nonatomic) BOOL globalOverrideBold;              // NO
@property (nonatomic) BOOL globalOverrideItalic;            // NO
@property (nonatomic) BOOL globalOverrideUnderline;         // NO
@property (nonatomic, readonly) BOOL globalOverrideEnabled; // any of the seven (N++ GlobalOverride::isEnable())

// ---- Session ----
@property (nonatomic, copy) NSArray<NSString *> *sessionFilePaths;
@property (nonatomic) NSInteger sessionSelectedIndex;

// ---- Editor context menu (Settings > Edit Popup ContextMenu) ----
// Command tags (NPPCmd) in menu order; 0 means a separator, a slot in -1..-6 one of the AppKit responder actions
// (Undo/Redo/Cut/Copy/Paste/Select All), and a slot in -100..-102 opens one of upstream's FolderName submenus —
// everything after it hangs off that submenu until the next folder slot or the next separator. nil resets to the
// built-in default, which is upstream's shipped contextMenu.xml.
@property (nonatomic, copy, null_resettable) NSArray<NSNumber *> *contextMenuCommandTags;
+ (NSArray<NSNumber *> *)defaultContextMenuCommandTags;
// Titles resolved from the main menu. "Copy link" (NPPCmdEditCopyLink) rides along behind the Copy entry the way
// upstream builds it, and the menu's delegate hides it unless the caret is inside a clickable link.
- (NSMenu *)buildEditorContextMenu;
// The same, taking the menu the titles are read from — NSApp.mainMenu is the app's, and nil (the self-check, which
// runs with no menu bar) leaves every NPPCmd entry nameless and therefore dropped.
- (NSMenu *)buildEditorContextMenuWithTitlesFromMenu:(nullable NSMenu *)titleSource;

// ---- Windows ----
+ (void)showPreferencesWindow;
+ (void)showPreferencesPageNamed:(NSString *)pageName;       // e.g. @"Backup"; unknown name = first page
+ (void)showStyleConfigurator;
- (void)registerDefaults;                                    // call at launch

// Commands owned: NPPCmdSettingsPreferences, NPPCmdSettingsStyleConfigurator, NPPCmdSettingsImportStyleTheme,
// NPPCmdSettingsEditContextMenu, NPPCmdSettingsFileAssociation, NPPCmdEditCopyLink.
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (NSArray<NSString *> *)selfCheckFailures;
@end

NS_ASSUME_NONNULL_END
