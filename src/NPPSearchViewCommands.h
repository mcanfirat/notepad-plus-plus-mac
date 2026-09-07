// NPPSearchViewCommands.h — bookmarks, mark styles 1-5, brace matching, folding, "show symbol", zoom,
// change-history navigation, summary. Everything in N++'s Search/View menus that acts directly on the editor.
//
// Zoom is the one command here that is not per-buffer: like upstream it belongs to the view, so it is applied to
// every open document and persisted (NSUserDefaults "NPPZoom"). See the comment above spreadZoom().
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#import "NPPCommands.h"

NS_ASSUME_NONNULL_BEGIN

// Margin/marker/indicator numbers shared with NPPDocument/NPPLanguageManager (mirror N++ ScintillaEditView).
enum {
    NPPMarginLineNumber = 0,
    NPPMarginSymbol = 1,          // bookmarks (N++ _SC_MARGE_SYMBOL)
    NPPMarginFolder = 2,          // fold margin (N++ _SC_MARGE_FOLDER)
    NPPMarginChangeHistory = 3,
    NPPMarkerBookmark = 20,       // N++ MARK_BOOKMARK
    NPPMarkerHideLinesBegin = 19, NPPMarkerHideLinesEnd = 18, NPPMarkerHideLinesUnderline = 17,   // N++ MARK_HIDELINESBEGIN/END; 21..24 are Scintilla change-history markers
    // 8 is the clickable-URL indicator (NPPDocument.mm). 9 is not a N++ indicator: it is how NPPEditCommands
    // keeps its Begin/End Select mark, hidden and one character wide, so Scintilla moves it through every edit.
    NPPIndicatorBeginEndSelect = 9,
    NPPIndicatorFindMark = 31,    // SCE_UNIVERSAL_FOUND_STYLE (Find Mark Style)
    NPPIndicatorSmartHighlight = 29,
    NPPIndicatorIncremental = 28,
    NPPIndicatorTagMatch = 27, NPPIndicatorTagAttr = 26,
    NPPIndicatorMarkExt1 = 25, NPPIndicatorMarkExt2 = 24, NPPIndicatorMarkExt3 = 23, NPPIndicatorMarkExt4 = 22, NPPIndicatorMarkExt5 = 21,
};

@interface NPPSearchViewCommands : NSObject
+ (BOOL)performCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor;   // YES if handled by this module
+ (BOOL)canPerformCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor;
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)commandIsChecked:(NPPCmd)cmd onEditor:(ScintillaView *)editor;  // menu check state for toggles (show EOL, wrap, ...)

// Reusable pieces
+ (void)markAllOccurrencesOfSelection:(ScintillaView *)editor indicator:(int)indicator;   // Style All Occurrences of Token (uses word under caret / selection, match case + whole word like N++)
+ (void)markOneOccurrence:(ScintillaView *)editor indicator:(int)indicator;              // Style One Token
+ (void)clearIndicator:(int)indicator onEditor:(ScintillaView *)editor;
+ (BOOL)goToNextIndicator:(int)indicator onEditor:(ScintillaView *)editor backward:(BOOL)backward wrap:(BOOL)wrap;
+ (void)toggleBookmarkOnCurrentLine:(ScintillaView *)editor;
+ (BOOL)goToBookmark:(ScintillaView *)editor next:(BOOL)next;
+ (void)braceMatchCommand:(ScintillaView *)editor selectBetween:(BOOL)selectBetween;    // Go to matching brace / Select all in-between
+ (NSString *)summaryText:(ScintillaView *)editor;   // N++ View > Summary: characters (without blanks), words, lines, document length, current selection info

+ (NSArray<NSString *> *)selfCheckFailures;   // headless regression checks; NPPSelfTest runs these
@end

NS_ASSUME_NONNULL_END
