// NPPFindPanelController.h — Notepad++ Find / Replace / Mark dialog (tabs) + Go To Line + Incremental Search bar.
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NPPSearchMode) { NPPSearchModeNormal = 0, NPPSearchModeExtended, NPPSearchModeRegex };

@protocol NPPFindTargetProvider <NSObject>
- (nullable ScintillaView *)currentEditorForFind;
- (NSArray<ScintillaView *> *)allOpenEditorsForFind;   // "Replace All in All Opened Documents"
- (void)findPanelDidReportStatus:(NSString *)status isError:(BOOL)isError;   // e.g. "Find: Can't find the text ..." -> window status
@end

@interface NPPFindPanelController : NSWindowController
+ (instancetype)shared;
@property (nonatomic, weak) id<NPPFindTargetProvider> targetProvider;

// Panel (NSPanel, floating, programmatic UI, tabs: Find | Replace | Mark). Initial text: current selection if single-line, else word at caret.
- (void)showFindWithInitialText:(nullable NSString *)text;
- (void)showReplaceWithInitialText:(nullable NSString *)text;
- (void)showMarkWithInitialText:(nullable NSString *)text;
- (void)showGoToLineForEditor:(ScintillaView *)editor;          // small sheet: line or offset, like N++ "Go to..."

// Options (persisted in NSUserDefaults)
@property (nonatomic) BOOL matchCase, wholeWord, wrapAround, backwardDirection, inSelection, dotMatchesNewline, purgeMarksBeforeMark, bookmarkLinesOnMark;
@property (nonatomic) NPPSearchMode searchMode;
@property (nonatomic, copy) NSString *searchText, *replaceText;
@property (nonatomic, readonly) NSArray<NSString *> *searchHistory;   // last 10

// Search engine (SCI_SETSEARCHFLAGS + SCI_SEARCHINTARGET; regex uses SCFIND_REGEXP|SCFIND_CXX11REGEX; extended mode
// unescapes \n \r \t \0 \\ \xHH \uHHHH in search and replace text; regex replace supports \1..\9 and $1..$9 groups).
- (BOOL)findNextInEditor:(nullable ScintillaView *)editor;                 // uses current options; shows panel if no search text
- (BOOL)findPreviousInEditor:(nullable ScintillaView *)editor;
- (BOOL)findText:(NSString *)text inEditor:(ScintillaView *)editor backward:(BOOL)backward wrap:(BOOL)wrap
       matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord mode:(NPPSearchMode)mode select:(BOOL)select;   // primitive
- (BOOL)replaceCurrentInEditor:(ScintillaView *)editor;                     // Replace: replaces the selection if it matches, then finds next
- (NSInteger)replaceAllInEditor:(ScintillaView *)editor;                    // honours inSelection
- (NSInteger)countInEditor:(ScintillaView *)editor;
- (NSInteger)markAllInEditor:(ScintillaView *)editor;                       // indicator 31 (+ bookmarks if bookmarkLinesOnMark)
- (void)clearMarksInEditor:(ScintillaView *)editor;
- (void)selectAndFindNextInEditor:(ScintillaView *)editor backward:(BOOL)backward;   // Search > Select and Find Next/Previous (sets searchText from selection)
- (void)volatileFindInEditor:(ScintillaView *)editor backward:(BOOL)backward;        // Find (Volatile): word under caret, no history

// Preferences > Searching "Use monospaced font in Find dialog": the font every Find-family text entry uses
// (this panel's combo boxes and the Find in Files sheet's fields). Read fresh — the pref can change any time.
+ (NSFont *)dialogFont;

// Incremental search bar (view the window controller places above the status bar).
- (NSView *)incrementalSearchBarForEditorProvider:(id<NPPFindTargetProvider>)provider;  // singleton view; has text field, ◀ ▶, "Highlight all", "Match case", close ✕
- (void)showIncrementalSearch;   // focuses the bar (window controller shows it via NPPIncrementalSearchShouldShowNotification)

// Headless checks, in the shape NPPSelfTest collects from the feature modules. This class is not a command
// handler, so NPPSelfTest's module-name list has to name it for these to run.
+ (NSArray<NSString *> *)selfCheckFailures;
@end

extern NSNotificationName const NPPIncrementalSearchShouldShowNotification;   // object: nil
extern NSNotificationName const NPPIncrementalSearchShouldHideNotification;

NS_ASSUME_NONNULL_END
