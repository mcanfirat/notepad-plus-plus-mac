// NPPFindInFiles.h — Notepad++ "Find in Files" (FindReplaceDlg's Find in Files tab + Notepad_plus::findInFiles /
// getMatchedFileNames) and the docked "Search results" panel (FindReplaceDlg's Finder, searchResult lexer).
//
// One object: the command handler (class methods, NPPCommandHandler) and the panel (+shared, NPPPanel).
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"
#import "NPPFindPanelController.h"   // NPPSearchMode

NS_ASSUME_NONNULL_BEGIN

@class NPPDocument;

@interface NPPFindInFiles : NSObject <NPPPanel, NPPCommandHandler>

// The docked "Search results" panel; the window controller docks this object.
+ (instancetype)shared;

// Kept weakly; refreshed on every command the module handles.
@property (nonatomic, weak) id<NPPCommandContext> context;

// Search > Find in Files… — modal sheet on the context's window. Defaults come from NPPFindPanelController.shared.
- (void)showFindInFilesSheetWithContext:(id<NPPCommandContext>)context;

// Search > Find All in Current Document / in All Opened Documents: appends a section to the results panel.
// `scope` is the label used in the section header ("Current Document", "All Opened Documents").
- (void)findAllIn:(NSArray<NPPDocument *> *)docs
             text:(NSString *)text
        matchCase:(BOOL)matchCase
        wholeWord:(BOOL)wholeWord
             mode:(NPPSearchMode)mode
            scope:(nullable NSString *)scope;

// Results panel operations. Also reachable through the NPPCmdSearchResults* commands and, together with the rest
// of N++'s Finder menu ("Find in these search results…", copy/open the selected pathnames, the word-wrap and
// purge toggles), through the panel's ⚙ menu and the results view's own right-click menu — one menu, built by
// -buildResultsMenu, dispatched by target/action rather than by NPPCmd tags.
// The panel's own keys (N++ Finder's run_dlgProc) arrive through the monitor -panelDidBecomeVisible installs:
// Return opens the row under the caret, ⌫ / ⌦ prunes it — a row, a file with its hits, or a whole section.
- (void)clearAllResults;
- (void)goToNextResult:(BOOL)next;      // NO = previous
- (void)copyResults;                    // selected lines, or everything when there is no selection
- (void)foldAllResults:(BOOL)collapse;
- (void)stopSearch;
@property (readonly, getter=isSearching) BOOL searching;   // atomic: written from the search queue
@property (nonatomic, readonly) BOOL hasResults;

@end

NS_ASSUME_NONNULL_END
