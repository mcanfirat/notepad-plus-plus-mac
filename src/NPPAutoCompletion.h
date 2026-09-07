// NPPAutoCompletion.h — Notepad++ auto-completion (N++ ScintillaComponent/AutoCompletion.cpp + FunctionCallTip.cpp).
//
// Five things, all of which N++ hangs off one class:
//   * the popup that appears while typing (word / API / both, after N characters),
//   * API "function completion" from the per-language word lists in PowerEditor/installer/APIs/<language>.xml,
//   * function parameter hints (SCI_CALLTIPSHOW) with overload cycling,
//   * path completion for a filesystem path being typed (usually inside a string),
//   * auto-insertion of the closing HTML/XML tag when ">" finishes an opening tag.
//
// Typing is hooked by installing a Scintilla delegate forwarder on the current editor (NPPDocument owns the real
// delegate), re-installed on NPPCurrentDocumentDidChangeNotification — same pattern as NPPMacroManager.
//
// Three settings live outside this class and are read straight from NPPPreferences, because that is where their
// controls are:
//   * NPPAutoCompleteInsertWithTab / …WithEnter (N++ _autocInsertSelectedUseTAB / …ENTER) — which key accepts the
//     highlighted entry. Switching one off gives the key back its ordinary meaning while the list is up, which
//     Scintilla only allows from inside SCN_AUTOCSELECTION;
//   * NPPLargeFileAllowAutoCompletion (N++ LargeFileRestriction::_allowAutoCompletion, Performance page) — above
//     the large-file threshold the automatic path is off entirely unless this says otherwise, exactly as in
//     Buffer::allowAutoCompletion(). The Edit ▸ Completion commands stay available, as upstream.
// The list and call-tip colours (N++ AutoCompletion::setColour) are not settings at all: they are derived from the
// current theme's Default Style each time the list or the tip is shown.
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// N++ NppGUI::AutocStatus, same order.
typedef NS_ENUM(NSInteger, NPPAutoCompleteMode) {
    NPPAutoCompleteModeNone = 0,      // never trigger while typing
    NPPAutoCompleteModeFunction,      // API word list only
    NPPAutoCompleteModeWord,          // words of the current document only
    NPPAutoCompleteModeBoth,          // both, merged (N++ default)
};

@interface NPPAutoCompletion : NSObject <NPPCommandHandler>

+ (instancetype)shared;

// Settings. All persist in NSUserDefaults under "NPPAutoComplete.*"; defaults mirror N++ (Parameters.h NppGUI).
@property (nonatomic) BOOL enabled;                  // trigger while typing at all                        (YES)
@property (nonatomic) NPPAutoCompleteMode mode;      // _autocStatus                                       (Both)
@property (nonatomic) NSInteger triggerLength;       // _autocFromLen: characters typed before the popup    (1)
@property (nonatomic) BOOL ignoreNumbers;            // _autocIgnoreNumbers: no popup on a numeric prefix  (YES)
@property (nonatomic) BOOL briefMode;                // _autocBrief: keep re-filtering while the list is up (NO)
@property (nonatomic) BOOL functionParameterHints;   // _funcParams: call tip on the start/separator char  (YES)
@property (nonatomic) BOOL insertHTMLCloseTag;       // _matchedPairConf._doHtmlXmlTag                      (YES)

// Handled: NPPCmdEditCompleteFunction, NPPCmdEditCompletePath, NPPCmdEditFunctionCallTip and the
// Previous/Next call-tip variants. The API-backed commands report NO when the current language has no API file
// (so the menu item is disabled rather than silently doing nothing); Previous/Next report NO unless this tab's own
// call tip is on screen with more than one overload.
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (NSArray<NSString *> *)selfCheckFailures;          // headless: XML parsing, matching, close tags, call-tip parsing

@end

NS_ASSUME_NONNULL_END
