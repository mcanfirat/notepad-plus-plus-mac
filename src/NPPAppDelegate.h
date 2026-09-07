// NPPAppDelegate.h — application lifecycle + main menu (programmatic, mirrors Notepad++'s menu bar adapted to macOS).
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPEditorWindowController.h"

NS_ASSUME_NONNULL_BEGIN

// Upstream's Ctrl+Shift+R is IDC_EDIT_TOGGLEMACRORECORDING (Parameters.cpp:475): one accelerator that starts
// recording and then stops it, while Start/Stop Recording themselves stay unbound. It has no IDM_ id upstream and so
// none in NPPCommands.h, and it cannot be faked by putting ⇧⌘R on both items: AppKit hands a key equivalent to the
// FIRST item carrying it and stops there even when that item is disabled (measured), so the key would go dead as soon
// as recording started. The Macro menu owns the toggle, and this menu owns its tag.
enum : NSInteger { NPPCmdMacroToggleRecording = 13200 };

@interface NPPAppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate>
@property (nonatomic, readonly) NPPEditorWindowController *mainWindowController;

- (void)buildMainMenu;              // App | File | Edit | Search | View | Encoding | Language | Settings | Window | Help
// The recent-file list (NPPCmdFileRecentBase + i, "Clear Recent"): in the File menu itself, or — Preferences ▸
// Recent Files History "Put the recent files in a submenu" — in "Open Recent". Labels follow the display setting.
- (void)rebuildRecentFilesMenu;
- (void)rebuildLanguageMenu;        // Language menu from NPPLanguageManager.languages (NPPCmdLanguageBase + i); also handed to the status bar
- (void)rebuildThemeMenu;
- (void)rebuildMacroMenu;           // Macro menu incl. the saved macros (NPPCmdMacroSavedBase + i)
- (void)rebuildRunMenu;             // Run menu incl. the saved commands (NPPCmdRunSavedBase + i)           // Settings > Style Theme > (Follow System | Default (stylers.xml) | themes...) (NPPCmdSettingsThemeBase + i)
- (NSMenu *)eolMenu;                // shared with status bar
- (NSMenu *)encodingMenu;           // shared with status bar (Encoding menu clone)
- (void)openFileURLs:(NSArray<NSURL *> *)urls;   // Finder / dock / argv / recent
- (IBAction)nppCommand:(id)sender;  // fallback for app-level commands (New/Open/Preferences/About/Help/Theme/Recent) when no window handles them

// Headless regression checks on the recent-file menu: where the list goes (inline vs "Open Recent"), that a
// rebuild replaces the previous placement instead of stacking a second copy, and that every label comes from
// -[NPPPreferences recentFileMenuTitleForPath:]; plus the Edit ▸ Cut/Copy fallback, which must hand those two items
// their standard cut:/copy: selectors back whenever -nppCommand: cannot be delivered (an app-modal NSAlert) and
// take them back afterwards; plus the keys a Notepad++ user arrives with — F4/Shift-F4, F5, F8, ⇧⌘R, ⌥⌘C, ⌥⌘0 —
// asserted on a real menu bar built by this class, along with the rule that makes them work at all: no two items in
// it may carry the same key equivalent. Drives menus of its own, never NSApp.mainMenu. One string per failure, empty
// when all pass — same shape as a feature module's, so NPPSelfTest can call it.
+ (NSArray<NSString *> *)selfCheckFailures;
@end

NS_ASSUME_NONNULL_END
