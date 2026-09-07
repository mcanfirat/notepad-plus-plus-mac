// NPPEditorWindowController.h — the Notepad++ main window: tab bar + editor area + (incremental search bar) + status bar.
// Single-window MDI like N++. Menu commands arrive via -nppCommand: through the responder chain.
//
// Two edit views, a main and a sub, as in N++: a document lives in exactly one of them and exactly one has the
// focus. A view with no documents is not shown, so with every document in the main view the window is laid out
// exactly as it was before the split existed — one tab strip across the top, the editor filling the panel host.
// Move / Clone to Other View split it; closing the last document of a view collapses it again. Orientation and
// divider position live in NPPPanelHost; which view each file was in round-trips through Save/Load Session and
// through the auto-restored session (session.xml beside NPPBackupManager's backup folder, which also carries
// language, read-only, selection, first visible line, bookmarks, the collapsed fold lines, the tab colour and,
// when the buffer is being read as an 8-bit code page, that code page — NPPPreferences keeps the flat path list
// the app delegate re-opens).
//
// Each view's tab strip is given the room it asks for: NPPTabBarView reads the vertical / multi-line preferences
// itself, and -layoutContent honours -preferredWidth (a column down the leading edge) or -preferredHeight (a band
// across the top, one row or many). A strip that needs a different amount of room says so and the window re-lays
// out. Distraction-free mode and Preferences ▸ Tab Bar ▸ Hide (which -notabbar sets) give it no room at all, and
// the editor takes the space. One view, one row, no preference on: the window is laid out exactly as it always was.
//
// Right-clicking a tab pops N++'s own tab context menu (NppNotification.cpp:1096-1140), submenu groupings and
// all: "Open into" (Finder / Terminal / as Workspace / default viewer), "Move Document" (to start, to end, to the
// other view, to a new instance) and "Apply Color to Tab". Pin / Unpin Tab is on it too, with the title N++ swaps
// rather than a checkmark — and it is the only way left to pin anything once Preferences ▸ "Show only pinned
// button" has hidden the pin box on every unpinned tab, so Pin Tab is also inserted into View ▸ Tab (which is what
// puts the command in front of the Shortcut Mapper and the context-menu editor, both of which read NSApp.mainMenu).
//
// Dragging a tab out of its strip (N++ TCN_TABDROPPEDOUTSIDE) lands in one of three places, told apart from the
// screen point NPPTabBarView reports: the other view's strip or editor moves the buffer there, anywhere else in
// this window pops a Move / Clone to Other View menu, and off the window opens the file in a new instance (which
// needs a saved file, so an unsaved one says so in the status bar instead).
//
// Three settings here have no NPPPreferences property yet and are read straight from NSUserDefaults, which is the
// contract a Preferences page would bind to: NPPDocumentSwitcher (N++ NppGUI::_doTaskList, default YES),
// NPPDocumentSwitcherMRU (NppGUI::_styleMRU, default YES — off, ⌃Tab cycles in tab order instead of MRU order),
// and NPPSaveDialogAppendExtension (NppGUI::_setSaveDlgExtFiltToAllTypes inverted, default YES), which the Save
// panel's own "Append extension" box writes back.
//
// Both file panels carry the language file-type filter N++ builds in setFileOpenSaveDlgFilters: one row per
// language that claims an extension, "All types" first, and on a Save panel an "Append extension" box — macOS
// completes the chosen type's extension itself once other types are refused. Open starts on "All types" and Save
// on the buffer's own language, as upstream does.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPDocument.h"
#import "NPPTabBarView.h"
#import "NPPStatusBarView.h"
#import "NPPFindPanelController.h"
#import "NPPCommands.h"
#import "NPPFeatureProtocols.h"
#import "NPPPanelHost.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPEditorWindowController : NSWindowController <NSWindowDelegate, NPPTabBarDelegate, NPPDocumentDelegate, NPPFindTargetProvider, NSMenuItemValidation, NPPCommandContext>
@property (nonatomic, readonly) NSArray<NPPDocument *> *documents;   // every open buffer: main view's, then sub view's
@property (nonatomic, readonly, nullable) NPPDocument *currentDocument;   // the focused view's current document
@property (nonatomic, readonly) NPPTabBarView *tabBar;                    // the focused view's tab strip
@property (nonatomic, readonly) NPPStatusBarView *statusBar;
@property (nonatomic, readonly) NPPPanelHost *panelHost;   // docked feature panels around the editor area

- (instancetype)init;   // builds the window programmatically (no XIB), 1000x700 centered, autosave frame "NPPMainWindow"

// Documents
- (NPPDocument *)newDocument;                                            // "new N", becomes current
// Activates the existing tab when the file is already open; a folder goes to Folder as Workspace (or is opened
// file by file, per NPPFolderDroppedOpenFiles). A path whose extension matches Preferences ▸ MISC's session or
// workspace extension is loaded as a session / handed to Project Panel 1 and returns nil (N++ NppIO isFileSession
// / isFileWorkspace); a path that is not there is offered for creation when its folder exists and refused with a
// "folder doesn't exist" alert when it does not (N++ CreateNewFileOrNot). Otherwise loads; nil + alert on failure.
// Adds to recent files.
- (nullable NPPDocument *)openDocumentAtURL:(NSURL *)url;
- (void)openDocumentsAtURLs:(NSArray<NSURL *> *)urls;                    // a folder among them is opened file by file or added as a workspace, per NPPFolderDroppedOpenFiles
// Asks to save if dirty (Save / Don't Save / Cancel); returns NO if cancelled. Keeps one "new 1" when the last tab
// closes unless NPPPreferences.exitOnClosingLastTab, which quits instead. Remembers closed file path for Restore
// Last Closed. Closing several at once (Close All, Close to the Left/Right, quit) is one batch: with more than one
// buffer dirty the prompt also offers "Save All" / "Don't Save Any" (N++ doSaveOrNot's "Yes to all" / "No to all"),
// and nothing is closed until every dirty buffer has an answer, so Cancel leaves the batch untouched.
- (BOOL)closeDocument:(NPPDocument *)doc;
- (BOOL)closeAllDocuments;                                               // returns NO if cancelled
- (BOOL)saveDocument:(NPPDocument *)doc;                                 // Save; untitled -> Save As panel
- (BOOL)saveDocumentAs:(NPPDocument *)doc;
- (BOOL)saveAllDocuments;                                                // confirms first per Preferences ▸ MISC "Enable the Save All confirmation dialog"
- (void)selectDocument:(NPPDocument *)doc;                               // focuses the view the document lives in
- (void)selectDocumentAtIndex:(NSInteger)index;                          // index into -documents
- (void)moveDocumentAtIndex:(NSInteger)from toIndex:(NSInteger)to;       // reorder inside the focused view's strip
- (BOOL)hasDirtyDocuments;
- (BOOL)promptToSaveAllBeforeQuit;                                       // used by app delegate applicationShouldTerminate; NO = cancel quit

// Commands
- (IBAction)nppCommand:(id)sender;                                       // dispatch by [sender tag] (NPPCmd): File/View/Encoding/Language/Tab commands here; Edit -> NPPEditCommands; Search/View editor ops -> NPPSearchViewCommands; Find -> NPPFindPanelController
- (BOOL)validateMenuItem:(NSMenuItem *)item;                             // enable/disable + check marks (word wrap, show EOL, current language, current encoding/EOL, always on top, monitoring, read-only ...)

// Status bar refresh (called from document delegate callbacks)
- (void)updateStatusBar;
- (void)updateWindowTitle;                                               // "path - Notepad++" with "*" prefix when dirty (N++ style), represented file URL set for proxy icon; just the file name under Preferences ▸ MISC "Show only the file name in the title bar"
- (void)applyTheme;                                                      // recolour tab bar / status bar / all editors after NPPThemeDidChangeNotification or appearance change

// ---- Launch-time services (what NPPAppDelegate needs from the preferences this window owns) ----
// Recent Files History ▸ "Check that the files still exist at launch time": drops the entries that have gone and
// posts NPPRecentFilesDidChange, so the File menu is rebuilt from the pruned list. Called once from -showWindow:;
// safe (and a no-op) to call again. The menu's own two settings are read straight from NPPPreferences:
// -recentFileMenuTitleForPath: for every label, and `recentFilesInSubmenu` for where the list goes.
+ (void)pruneRecentFilesAtLaunch;
// New Document ▸ "Always open a new document in addition at startup" (N++ gates it on Remember Last Session too).
// -showWindow: schedules it for the next main-queue turn, after the session and the command line have opened
// their files; it happens exactly once per window whoever calls it.
- (void)addStartupDocumentIfPreferred;
// The app's one beep, silenced by Preferences ▸ MISC "Mute all sounds" (N++ NppGUI::_muteSounds). Feature modules
// should call this rather than NSBeep() so the switch means what it says.
+ (void)beep;

// Headless regression checks: the two edit views (split / collapse, move, clone, sync scrolling and zoom, Close
// All but Pinned), Window ▸ Sort By, the split rotation, the ⌃Tab switcher's two orders, dragging a tab out of
// its strip (the three destinations and the transfer one of them performs), the Default Directory /
// silent-reload / exit-on-last-tab preferences, dropping a folder, a session round trip carrying bookmarks and an
// untitled buffer, the tab strip's four layout states (single row, wrapped rows, column, hidden), the activation
// sweep over every open buffer, and the auto-session's fidelity and its -nosession gate. Also the Margins / MISC
// preferences this window owns: the border-width inset and the border edge, Distraction Free padding, the short
// title bar, the Save All confirmation, muted sounds, the session / workspace file extensions, "create it?" for a
// path that is not there, the recent-files launch check, the extra startup document, the multi-instance session
// branch, and the panel-state flags that decide what -nosession still restores. Then the batch save prompt (how
// often it asks, when it offers the two "…to All" buttons, and that Cancel closes nothing), the session details a
// round trip has to carry beyond the text — a collapsed fold, a hand-picked character set, the tab colour — and
// the panels' language file-type filter with its "Append extension" default. Builds and drives its own
// Then the tab context menu (that it still carries the commands reachable nowhere else — pinning above all — and
// that the pin item renames itself) and View ▸ Tab's inserted Pin Tab item. Builds and drives its own
// controller in a window that is never shown; one string per
// failure, empty when all pass. Same shape as a feature module's +selfCheckFailures, so NPPSelfTest can call it.
+ (NSArray<NSString *> *)selfCheckFailures;
@end

NS_ASSUME_NONNULL_END
