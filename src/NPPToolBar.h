// NPPToolBar.h — the main window's toolbar (port of WinControls/ToolBar/ToolBar.cpp + the toolBarIcons table in
// Notepad_plus.cpp).
//
// An NSToolbar on the window reached through id<NPPCommandContext> -contextWindow. Every button carries the same
// NPPCmd tag its menu item carries and fires -nppCommand: with target nil, so a click travels the responder chain
// exactly like the menu command does; the five standard editing buttons (Cut/Copy/Paste/Undo/Redo) use the Cocoa
// selectors the Edit menu uses, for the same reason. Buttons are enabled from the window controller's own
// -validateMenuItem:, so a button is live only when the matching menu item is, and a toggle button (word wrap,
// show all characters, indent guide, sync scrolling, macro recording) shows the menu's check mark as an accented
// icon.
//
// Upstream's icons are Windows bitmap resources in PowerEditor/src/icons; here the icons are SF Symbols and the
// four icon sets differ by size and weight/fill instead. Upstream's "customise" is a hand-edited
// toolbarButtonsConf.xml; here it is the standard macOS customization palette.
//
// Upstream's Colorization (TbIconInfo) is ported straight across: Complete repaints the whole glyph in the chosen
// tone, Partial repaints only its secondary layers — SF Symbols' hierarchical and palette rendering respectively —
// and Default paints nothing at all unless the colorization is Complete, exactly as IconList::changeFluentIconColor
// does. A ticked toggle stays accented *and* heavier, so it still reads as ticked when the whole toolbar is
// already accent-coloured. The standard icon set is left untinted whatever the colour choice says, because upstream
// only recolours the Fluent sets and the Preferences page greys those controls out for it.
//
// Persisted in NSUserDefaults: NPPToolbarHidden, NPPToolbarIconSet, NPPToolbarColorizationComplete, NPPToolbarColor
// and NPPToolbarCustomColor (the keys NPPPreferences already owns — the Preferences > Toolbar page drives the same
// toolbar), plus NPPToolbarButtons (the button set, an ordered array of item identifiers).
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPToolBar : NSObject <NSToolbarDelegate, NSMenuItemValidation, NPPCommandHandler>

+ (instancetype)shared;   // installs itself on NPPCommandContextReadyNotification; nothing else needs to call this

@property (nonatomic, readonly, nullable) NSToolbar *toolbar;                       // nil until a window is attached
@property (nonatomic, readonly) NSArray<NSToolbarItemIdentifier> *buttonIdentifiers;   // what is on the toolbar now

// The upstream default button set, in upstream order, with NSToolbarSpaceItemIdentifier where N++ has a separator.
+ (NSArray<NSToolbarItemIdentifier> *)defaultButtonIdentifiers;
// Everything the customization palette offers (every button + the two space items).
+ (NSArray<NSToolbarItemIdentifier> *)allowedButtonIdentifiers;

// View > Toolbar: Show Toolbar (checked), Customise…, and the four icon sets (radio-checked).
// The context is unused (the toolbar keeps its own weak reference to the window it is on), so these are safe to
// call with anything, including from the menu path below.
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context;

// The View > Toolbar menu items are retargeted to the shared instance once a window exists, because the window
// controller's handler table is fixed and cannot be extended from here. Both are the menu's entry points.
- (IBAction)nppCommand:(id)sender;
- (BOOL)validateMenuItem:(NSMenuItem *)item;

// Headless regression checks (symbol names resolve, default/allowed sets agree, the two groups a user reaches by
// position — panels and macro — are upstream's full contiguous runs, icon-set mapping, the colorization
// table, that icon set / colorization / colour choice each on their own reach a built item's pixels and that a
// change repaints a toolbar already built, button-set persistence round-trip, item construction and the
// enable/check path, the Show/Customise menu path — which brings its own window when there is not one yet — and the
// one-toolbar-one-window attach rule). One string per failure. The user's toolbar visibility, icon set, colour
// settings and button set are put back before it returns.
+ (NSArray<NSString *> *)selfCheckFailures;

@end

NS_ASSUME_NONNULL_END
