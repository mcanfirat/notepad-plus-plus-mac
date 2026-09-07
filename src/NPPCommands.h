// NPPCommands.h — command tags shared by menus, window controller and command modules.
// Every menu item carries one of these as its `tag`; its action is -nppCommand: (target nil,
// resolved through the responder chain to NPPEditorWindowController / NPPAppDelegate).
// Standard editing actions (undo:/redo:/cut:/copy:/paste:/selectAll:) use the Cocoa selectors
// directly so text fields in panels keep working; they are NOT in this enum.
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NPPCmd) {
    // ---- File ----
    NPPCmdFileNew = 1000, NPPCmdFileOpen, NPPCmdFileOpenContainingFolder, NPPCmdFileOpenInDefaultViewer,
    NPPCmdFileReload, NPPCmdFileSave, NPPCmdFileSaveAs, NPPCmdFileSaveCopyAs, NPPCmdFileSaveAll, NPPCmdFileRename,
    NPPCmdFileClose, NPPCmdFileCloseAll, NPPCmdFileCloseAllButCurrent, NPPCmdFileCloseAllToLeft, NPPCmdFileCloseAllToRight,
    NPPCmdFileCloseAllUnchanged, NPPCmdFileMoveToTrash, NPPCmdFileLoadSession, NPPCmdFileSaveSession,
    NPPCmdFilePrint, NPPCmdFileRestoreLastClosed, NPPCmdFileRecentBase = 1100, /* +index into recent list (<1200) */
    NPPCmdFileClearRecent = 1199,

    // ---- Edit (text transforms; implemented by NPPEditCommands) ----
    NPPCmdEditDelete = 2000, NPPCmdEditBeginEndSelect,
    NPPCmdEditInsertDateTimeShort, NPPCmdEditInsertDateTimeLong,
    NPPCmdEditCopyFullPath, NPPCmdEditCopyFileName, NPPCmdEditCopyDirPath, NPPCmdEditCopyAllNames, NPPCmdEditCopyAllPaths,
    NPPCmdEditIndent, NPPCmdEditUnindent,
    NPPCmdEditUpperCase, NPPCmdEditLowerCase, NPPCmdEditProperCase, NPPCmdEditProperCaseBlend,
    NPPCmdEditSentenceCase, NPPCmdEditSentenceCaseBlend, NPPCmdEditInvertCase, NPPCmdEditRandomCase,
    NPPCmdEditDuplicateLine, NPPCmdEditRemoveDuplicateLines, NPPCmdEditRemoveConsecutiveDuplicateLines,
    NPPCmdEditSplitLines, NPPCmdEditJoinLines, NPPCmdEditMoveLineUp, NPPCmdEditMoveLineDown,
    NPPCmdEditRemoveEmptyLines, NPPCmdEditRemoveEmptyLinesWithBlank, NPPCmdEditInsertBlankLineAbove, NPPCmdEditInsertBlankLineBelow,
    NPPCmdEditReverseLineOrder, NPPCmdEditRandomizeLineOrder,
    NPPCmdEditSortLexAsc, NPPCmdEditSortLexCaseInsAsc, NPPCmdEditSortLocaleAsc, NPPCmdEditSortIntAsc,
    NPPCmdEditSortDecCommaAsc, NPPCmdEditSortDecDotAsc, NPPCmdEditSortLengthAsc,
    NPPCmdEditSortLexDesc, NPPCmdEditSortLexCaseInsDesc, NPPCmdEditSortLocaleDesc, NPPCmdEditSortIntDesc,
    NPPCmdEditSortDecCommaDesc, NPPCmdEditSortDecDotDesc, NPPCmdEditSortLengthDesc,
    NPPCmdEditToggleLineComment, NPPCmdEditLineComment, NPPCmdEditLineUncomment, NPPCmdEditBlockComment, NPPCmdEditBlockUncomment,
    NPPCmdEditAutoCompleteWord,
    NPPCmdEditEOLToWindows, NPPCmdEditEOLToUnix, NPPCmdEditEOLToMac,
    NPPCmdEditTrimTrailing, NPPCmdEditTrimLeading, NPPCmdEditTrimBoth, NPPCmdEditEOLToSpace, NPPCmdEditTrimAll,
    NPPCmdEditTabToSpace, NPPCmdEditSpaceToTabAll, NPPCmdEditSpaceToTabLeading,
    NPPCmdEditMultiSelectAll, NPPCmdEditMultiSelectAllMatchCase, NPPCmdEditMultiSelectAllWholeWord, NPPCmdEditMultiSelectAllMatchCaseWholeWord,
    NPPCmdEditMultiSelectNext, NPPCmdEditMultiSelectNextMatchCase, NPPCmdEditMultiSelectNextWholeWord, NPPCmdEditMultiSelectNextMatchCaseWholeWord,
    NPPCmdEditMultiSelectUndo, NPPCmdEditMultiSelectSkip,
    NPPCmdEditToggleReadOnly, NPPCmdEditSetReadOnlyAll, NPPCmdEditClearReadOnlyAll,
    NPPCmdEditColumnEditor,

    // ---- Search (find panel + NPPSearchViewCommands) ----
    NPPCmdSearchFind = 3000, NPPCmdSearchFindNext, NPPCmdSearchFindPrev, NPPCmdSearchSelectAndFindNext, NPPCmdSearchSelectAndFindPrev,
    NPPCmdSearchVolatileFindNext, NPPCmdSearchVolatileFindPrev, NPPCmdSearchReplace, NPPCmdSearchIncremental,
    NPPCmdSearchGoToLine, NPPCmdSearchGoToMatchingBrace, NPPCmdSearchSelectBetweenBraces, NPPCmdSearchMark,
    NPPCmdSearchChangedNext, NPPCmdSearchChangedPrev, NPPCmdSearchClearChangeHistory,
    NPPCmdSearchMarkAllExt1, NPPCmdSearchMarkAllExt2, NPPCmdSearchMarkAllExt3, NPPCmdSearchMarkAllExt4, NPPCmdSearchMarkAllExt5,
    NPPCmdSearchMarkOneExt1, NPPCmdSearchMarkOneExt2, NPPCmdSearchMarkOneExt3, NPPCmdSearchMarkOneExt4, NPPCmdSearchMarkOneExt5,
    NPPCmdSearchUnmarkAllExt1, NPPCmdSearchUnmarkAllExt2, NPPCmdSearchUnmarkAllExt3, NPPCmdSearchUnmarkAllExt4, NPPCmdSearchUnmarkAllExt5,
    NPPCmdSearchClearAllMarks,
    NPPCmdSearchGoPrevMarker1, NPPCmdSearchGoPrevMarker2, NPPCmdSearchGoPrevMarker3, NPPCmdSearchGoPrevMarker4, NPPCmdSearchGoPrevMarker5, NPPCmdSearchGoPrevMarkerDef,
    NPPCmdSearchGoNextMarker1, NPPCmdSearchGoNextMarker2, NPPCmdSearchGoNextMarker3, NPPCmdSearchGoNextMarker4, NPPCmdSearchGoNextMarker5, NPPCmdSearchGoNextMarkerDef,
    NPPCmdSearchToggleBookmark, NPPCmdSearchNextBookmark, NPPCmdSearchPrevBookmark, NPPCmdSearchClearBookmarks,
    NPPCmdSearchCutBookmarkedLines, NPPCmdSearchCopyBookmarkedLines, NPPCmdSearchPasteToBookmarkedLines,
    NPPCmdSearchRemoveBookmarkedLines, NPPCmdSearchRemoveNonBookmarkedLines, NPPCmdSearchInverseBookmarks,

    // ---- View ----
    NPPCmdViewAlwaysOnTop = 4000, NPPCmdViewFullScreen, NPPCmdViewDistractionFree,
    NPPCmdViewShowSpaceTab, NPPCmdViewShowEOL, NPPCmdViewShowNonPrinting, NPPCmdViewShowAllChars, NPPCmdViewShowIndentGuide, NPPCmdViewShowWrapSymbol,
    NPPCmdViewZoomIn, NPPCmdViewZoomOut, NPPCmdViewZoomRestore,
    NPPCmdViewTab1, NPPCmdViewTab2, NPPCmdViewTab3, NPPCmdViewTab4, NPPCmdViewTab5, NPPCmdViewTab6, NPPCmdViewTab7, NPPCmdViewTab8, NPPCmdViewTab9,
    NPPCmdViewTabFirst, NPPCmdViewTabLast, NPPCmdViewTabNext, NPPCmdViewTabPrev, NPPCmdViewTabMoveForward, NPPCmdViewTabMoveBackward,
    NPPCmdViewTabColor1, NPPCmdViewTabColor2, NPPCmdViewTabColor3, NPPCmdViewTabColor4, NPPCmdViewTabColor5, NPPCmdViewTabColorNone,
    NPPCmdViewWordWrap, NPPCmdViewHideLines,
    NPPCmdViewFoldAll, NPPCmdViewUnfoldAll, NPPCmdViewFoldCurrent, NPPCmdViewUnfoldCurrent,
    NPPCmdViewFoldLevel1, NPPCmdViewFoldLevel2, NPPCmdViewFoldLevel3, NPPCmdViewFoldLevel4, NPPCmdViewFoldLevel5, NPPCmdViewFoldLevel6, NPPCmdViewFoldLevel7, NPPCmdViewFoldLevel8,
    NPPCmdViewUnfoldLevel1, NPPCmdViewUnfoldLevel2, NPPCmdViewUnfoldLevel3, NPPCmdViewUnfoldLevel4, NPPCmdViewUnfoldLevel5, NPPCmdViewUnfoldLevel6, NPPCmdViewUnfoldLevel7, NPPCmdViewUnfoldLevel8,
    NPPCmdViewSummary, NPPCmdViewMonitoring, NPPCmdViewTextDirectionRTL, NPPCmdViewTextDirectionLTR,

    // ---- Encoding ----
    NPPCmdEncodingANSI = 5000, NPPCmdEncodingUTF8, NPPCmdEncodingUTF8BOM, NPPCmdEncodingUTF16BE, NPPCmdEncodingUTF16LE,
    NPPCmdEncodingConvertToANSI, NPPCmdEncodingConvertToUTF8, NPPCmdEncodingConvertToUTF8BOM, NPPCmdEncodingConvertToUTF16BE, NPPCmdEncodingConvertToUTF16LE,
    NPPCmdEncodingCharsetBase = 5100, /* +index into NPPCharsetTable (<5300) */

    // ---- Language ----
    NPPCmdLanguageBase = 6000, /* +index into NPPLanguageManager.languages (<6500) */

    // ---- Settings ----
    NPPCmdSettingsPreferences = 7000, NPPCmdSettingsThemeBase = 7100, /* +index into availableThemeNames (<7200) */

    // ---- Help ----
    NPPCmdHelpAbout = 9000, NPPCmdHelpHomepage, NPPCmdHelpProjectPage, NPPCmdHelpOnlineDocs, NPPCmdHelpCommunity,

    // ---- Macro (NPPMacroManager) ----
    NPPCmdMacroStartRecording = 10000, NPPCmdMacroStopRecording, NPPCmdMacroPlayback, NPPCmdMacroSaveCurrent,
    NPPCmdMacroRunMultiple, NPPCmdMacroModifyShortcuts,
    NPPCmdMacroSavedBase = 10100, /* +index into NPPMacroManager.savedMacros (<10200) */

    // ---- Run (NPPRunCommands) ----
    NPPCmdRunDialog = 10200, NPPCmdRunModifyCommands,
    NPPCmdRunSavedBase = 10300, /* +index into NPPRunCommands.savedCommands (<10400) */

    // ---- Find in Files / search results (NPPFindInFiles, NPPSearchResultsPanel) ----
    NPPCmdSearchFindInFiles = 10400, NPPCmdSearchFindAllInCurrent, NPPCmdSearchFindAllInOpened,
    NPPCmdSearchResultsPanel, NPPCmdSearchResultsClear, NPPCmdSearchResultsNext, NPPCmdSearchResultsPrevious,
    NPPCmdSearchResultsCopy, NPPCmdSearchResultsCollapseAll, NPPCmdSearchResultsExpandAll,

    // ---- Panels ----
    NPPCmdViewWorkspacePanel = 10500,      // Folder as Workspace
    NPPCmdViewDocumentMap, NPPCmdViewFunctionList, NPPCmdViewDocumentList,
    NPPCmdViewClipboardHistory, NPPCmdViewCharacterPanel,
    NPPCmdViewProjectPanel1, NPPCmdViewProjectPanel2, NPPCmdViewProjectPanel3,
    NPPCmdFileOpenFolderAsWorkspace,       // File > Open Folder as Workspace...

    // ---- User Defined Languages (NPPUserDefinedLanguages) ----
    NPPCmdLangDefineDialog = 10600, NPPCmdLangImportUDL, NPPCmdLangExportUDL,
    NPPCmdLangUserDefinedBase = 10700, /* +index into NPPUserDefinedLanguages.languages (<10800) */

    // ---- Backup & crash recovery (NPPBackupManager) ----
    NPPCmdBackupOpenFolder = 11000, NPPCmdBackupRestoreNow,

    // ---- Auto-completion (NPPAutoCompletion); Word Completion stays NPPCmdEditAutoCompleteWord above ----
    NPPCmdEditCompleteFunction = 11100, NPPCmdEditCompletePath,
    NPPCmdEditFunctionCallTip, NPPCmdEditFunctionCallTipPrevious, NPPCmdEditFunctionCallTipNext,

    // ---- Hash tools (NPPHashTools): algorithm-major, 4 algorithms x 3 actions ----
    NPPCmdToolHashBase = 11200,   /* + algo*3 + action; algo 0..3 = MD5, SHA-1, SHA-256, SHA-512;
                                     action 0 = from text dialog, 1 = from files, 2 = selection to clipboard (<11300) */

    // ---- Shortcut mapper (NPPShortcutMapper) ----
    NPPCmdSettingsShortcutMapper = 11300,

    // ---- Second edit view (NPPEditorWindowController) ----
    NPPCmdViewMoveToOtherView = 11400, NPPCmdViewCloneToOtherView, NPPCmdViewSwitchToOtherView,
    NPPCmdViewSyncScrollVertical, NPPCmdViewSyncScrollHorizontal, NPPCmdViewZoomSync,
    NPPCmdViewMoveToNewInstance, NPPCmdViewOpenInNewInstance,

    // ---- Edit menu gaps (NPPEditCommands) ----
    NPPCmdEditPasteHTML = 11500, NPPCmdEditPasteRTF, NPPCmdEditCopyBinary, NPPCmdEditCutBinary, NPPCmdEditPasteBinary,
    NPPCmdEditOpenSelectedFile, NPPCmdEditOpenSelectedFileFolder, NPPCmdEditRedactSelection,
    NPPCmdEditSearchOnInternet, NPPCmdEditChangeSearchEngine,
    NPPCmdEditInsertDateTimeCustom, NPPCmdEditColumnModeTip, NPPCmdEditBeginEndSelectColumn,
    NPPCmdEditToggleFileReadOnlyAttribute,

    // ---- Search / View gaps (NPPSearchViewCommands) ----
    NPPCmdSearchStyleToClipBase = 11600, /* +0..4 = styles 1..5 (<11605) */
    NPPCmdSearchAllStylesToClip = 11605, NPPCmdSearchMarkedToClip, NPPCmdSearchFindCharsInRange,
    NPPCmdViewNonPrintingChars = 11620, NPPCmdViewNPCControlChars, NPPCmdViewPostIt,
    NPPCmdViewTabMoveToStart, NPPCmdViewTabMoveToEnd,
    NPPCmdViewInBrowserBase = 11630, /* +0..4 = default browser, Safari, Chrome, Firefox, Edge (<11640) */

    // ---- Tab bar (NPPTabBarView) ----
    NPPCmdTabPin = 11700, NPPCmdTabDropDownList, NPPCmdFileCloseAllButPinned,

    // ---- Style configurator / imports (NPPPreferences) ----
    NPPCmdSettingsStyleConfigurator = 11800, NPPCmdSettingsImportStyleTheme, NPPCmdSettingsEditContextMenu,
    NPPCmdSettingsFileAssociation,

    // ---- File gaps (NPPEditorWindowController) ----
    NPPCmdFileOpenInTerminal = 11900, NPPCmdFileContainingFolderAsWorkspace, NPPCmdFilePrintNow,

    // ---- Window ▸ Sort By: reorders the real tabs, not just the Document List panel ----
    NPPCmdWindowSortNameAsc = 11920, NPPCmdWindowSortNameDesc, NPPCmdWindowSortPathAsc, NPPCmdWindowSortPathDesc,
    NPPCmdWindowSortTypeAsc, NPPCmdWindowSortTypeDesc, NPPCmdWindowSortSizeAsc, NPPCmdWindowSortSizeDesc,
    NPPCmdWindowSortDateAsc, NPPCmdWindowSortDateDesc,

    // ---- Split orientation (NPPEditorWindowController) ----
    NPPCmdViewRotateRight = 11940, NPPCmdViewRotateLeft,

    // ---- Language / Help entries ----
    NPPCmdLangOpenUDLFolder = 11950, NPPCmdLangUDLCollectionSite,
    NPPCmdHelpCommandLineArgs, NPPCmdHelpDebugInfo,

    // ---- Toolbar (NPPToolBar) ----
    NPPCmdViewToolbarShow = 11960, NPPCmdViewToolbarCustomise,
    NPPCmdViewToolbarIconsBase = 11970, /* +0..3 = small, large, small fluent, large fluent (<11980) */

    // ---- UI language (NPPLocalization) ----
    NPPCmdSettingsUILanguageBase = 12000, /* +index into the available translations (<12200) */
};

// Menu item validation: implementers return NO for commands they cannot currently perform.
// Anything unimplemented must be reported as unsupported (disabled), never silently ignored.

NS_ASSUME_NONNULL_END
