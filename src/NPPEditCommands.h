// NPPEditCommands.h — Notepad++ "Edit" menu text operations on a ScintillaView (pure, stateless).
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#import "NPPCommands.h"
#import "NPPLanguageManager.h"

NS_ASSUME_NONNULL_BEGIN

@class NPPDocument;

// ---- Edit ▸ Cut / Copy -----------------------------------------------------------------------------------------
// These two items cannot use the standard cut:/copy: selectors: those go straight to Scintilla's content view, so
// the port never sees the command and Preferences ▸ "Enable Copy/Cut line without selection" could never be
// honoured. They carry -nppCommand: with the tags below instead, and NPPEditCommands claims them in
// +handlesCommand: — which is the only route the window controller offers a module that does not own a shared tag.
// The tags are deliberately NOT in NPPCommands.h: that file is shared, has no spare Edit tags, and is not this
// module's to edit. 13000 sits above every range declared there (the highest is NPPCmdSettingsUILanguageBase + 200
// = 12200), so nothing else can grow into it — NPPEditCommands.mm holds a static_assert to that effect.
// One context refuses to route a custom action at all: inside an app-modal NSAlert, AppKit matches the ⌘X/⌘C item,
// finds nothing that answers -nppCommand:, and swallows the key. NPPAppDelegate therefore hands these two items
// their standard cut:/copy: selectors back whenever -nppCommand: stops being deliverable (-syncClipboardMenuItems),
// so the runModal name prompts keep the Cut and Copy they have today; they just do not honour the preference.
// ponytail: the main menu only. The toolbar's Cut/Copy buttons (NPPToolBar.mm) and the editor context menu
// (NPPPreferences -buildEditorContextMenu, tags -3/-4) still carry cut:/copy:, so those two entry points keep the
// plain Scintilla behaviour and ignore the preference. Upgrade path: point them at these tags — both call sites
// build items from a table, so it is one row each; neither file is this module's to edit.
typedef NS_ENUM(NSInteger, NPPClipboardCmd) {
    NPPCmdEditClipboardCut = 13000,
    NPPCmdEditClipboardCopy,
};

// What Cut/Copy must do right now. Takes the focused editor as a parameter rather than reading the key window, so
// the self-check can drive every branch headlessly.
typedef NS_ENUM(NSInteger, NPPClipboardAction) {
    NPPClipboardForward = 0,   // focus is not an edit view: the Find field / sheet / table keeps its own Cut/Copy
    NPPClipboardSelection,     // SCI_CUT / SCI_COPY
    NPPClipboardWholeLine,     // empty selection + lineCopyCutWithoutSelection: SCI_LINECUT / SCI_COPYALLOWLINE
};

// The customised date/time format and the search engine live in NPPPreferences (-dateTimeFormat /
// -formattedDateTimeNowCustom, -searchEngine / -searchEngineURLForTerm:), which owns the "Multi-Instance & Date" and
// "Search Engine" pages. This module only invokes them, exactly as N++ does.

@interface NPPEditCommands : NSObject
// Returns YES if `cmd` belongs to this module (whether or not it did anything). Wraps multi-step edits in
// SCI_BEGINUNDOACTION/ENDUNDOACTION. Semantics follow N++: with no selection, line operations act on the whole
// document (sort/remove-duplicates/trim/tab-space/EOL) or the current line (duplicate/move/join/split/comment);
// case conversion with no selection converts the word under the caret (N++ behaviour).
+ (BOOL)performCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor language:(nullable NPPLanguage *)language;
+ (BOOL)canPerformCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor language:(nullable NPPLanguage *)language;
+ (BOOL)handlesCommand:(NPPCmd)cmd;

// Exposed for reuse/tests
+ (void)convertCase:(NPPCmd)cmd onEditor:(ScintillaView *)editor;                    // Upper/Lower/Proper(/Blend)/Sentence(/Blend)/Invert/Random
+ (void)sortLines:(NPPCmd)cmd onEditor:(ScintillaView *)editor;                      // all NPPCmdEditSort*
+ (void)toggleLineComment:(ScintillaView *)editor language:(nullable NPPLanguage *)lang set:(NSInteger)mode; // mode: 0 toggle, 1 set, -1 unset. Uses language.commentLine (falls back to commentStart/End block when nil). Comment token followed by one space like N++.
+ (void)blockComment:(ScintillaView *)editor language:(nullable NPPLanguage *)lang uncomment:(BOOL)uncomment;
// NSDateFormatter short/long (locale). Order follows N++: time then date, or date then time when
// Preferences ▸ Multi-Instance & Date "Reverse the default date-time order" is on.
+ (void)insertDateTime:(ScintillaView *)editor longFormat:(BOOL)longFormat;
+ (void)wordCompletion:(ScintillaView *)editor;                                      // words from current document via SCI_AUTOCSHOW
+ (void)multiSelect:(NPPCmd)cmd onEditor:(ScintillaView *)editor;                    // SCI_MULTIPLESELECTADDNEXT / ADDEACH with search flags
+ (void)beginOrEndSelect:(ScintillaView *)editor column:(BOOL)column;                // first call marks the anchor, second one selects (stream or rectangular)

// N++ ScintillaEditView.cpp:795-833 (WM_KEYDOWN): while Preferences ▸ Editing 2 ▸ "Enable column selection to
// multi-editing" is on, a rectangular selection turns into independent carets the moment an arrow key, Home, End,
// Enter or Backspace is pressed; Escape collapses it to the single main caret instead. `keyCode` is an NSEvent
// hardware key code. Returns YES when the selection was converted — the key itself is never swallowed, it goes on
// to Scintilla, which is what moves the carets. Installed as a local key monitor; taken as a parameter so the
// self-check can drive every branch without an event.
+ (BOOL)columnSelectionToMultiCaretsForKeyCode:(unsigned short)keyCode onEditor:(nullable ScintillaView *)editor;

// Selection as raw bytes: the private pasteboard flavour carries embedded NULs, the plain-text flavour is the
// NUL-truncated prefix other apps see (N++ pairs CF_TEXT with its own CF_NPPTEXTLEN). Pasteboard is a parameter so the
// self-check can round-trip through a scratch pasteboard instead of the user's clipboard.
+ (BOOL)copyBinaryFromEditor:(ScintillaView *)editor toPasteboard:(NSPasteboard *)pasteboard cut:(BOOL)cut;
+ (BOOL)pasteBinaryIntoEditor:(ScintillaView *)editor fromPasteboard:(NSPasteboard *)pasteboard;

// Replace every character of every selection range with `symbol`, keeping CR/LF so the line structure survives.
+ (void)redactSelectionsOnEditor:(ScintillaView *)editor symbol:(NSString *)symbol;

// The selection read as a path: absolute, or relative to the file the selection came from. nil = not a usable path.
+ (nullable NSURL *)fileURLForSelectionText:(NSString *)text relativeToFileURL:(nullable NSURL *)base;

// Cut/Copy for the two tags above (NppCommands.cpp IDM_EDIT_CUT / IDM_EDIT_COPY). Both read the key window's first
// responder, not the passed-around "current" editor, so a focused Find field / sheet / table keeps its own Cut and
// Copy. NPPAppDelegate calls these directly for the case where the find panel is key and the window controller is
// out of the responder chain; -performCommand:/-canPerformCommand: route to them for every other case.
+ (NPPClipboardAction)clipboardActionForFocusedEditor:(nullable ScintillaView *)editor;
+ (void)performClipboardCommand:(NPPCmd)cmd sender:(nullable id)sender;
+ (BOOL)canPerformClipboardCommand:(NPPCmd)cmd;

+ (NSArray<NSString *> *)selfCheckFailures;   // headless regression checks (NPPSelfTest picks these up)
@end

NS_ASSUME_NONNULL_END
