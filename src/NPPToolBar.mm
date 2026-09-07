// NPPToolBar.mm — main window toolbar (N++ WinControls/ToolBar/ToolBar.cpp + the toolBarIcons table at the top of
// Notepad_plus.cpp). See NPPToolBar.h for the shape; the only surprises are documented where they happen.
#import "NPPToolBar.h"
#import "NPPPreferences.h"
#import "NPPUtils.h"   // NPPColorFromHex / NPPNSColorFromSci, for the Custom colour
#import "NPPEditCommands.h"   // NPPCmdEditClipboardCut/Copy: Cut and Copy go through the port, not straight to Scintilla

static NSString *const kButtonsKey = @"NPPToolbarButtons";       // ordered item identifiers
static NSString *const kToolbarIdentifier = @"NPPToolbar";

// ---- button table ---------------------------------------------------------------------------------------------
// Upstream order, upstream separators. `tag` is the NPPCmd the menu item carries; a button with tag 0 is one of the
// five standard editing actions, which the Edit menu also dispatches by Cocoa selector rather than by NPPCmd, so
// text fields in panels keep working (see the note at the top of NPPCommands.h).
struct NPPToolBarButtonDef {
    const char *ident;     // toolbar item identifier; "|" = separator
    const char *label;     // palette label and tool tip
    const char *symbol;    // SF Symbol; the ".fill" variant is preferred by the Fluent icon sets when one exists
    NSInteger   tag;       // NPPCmd, or 0 when `selectorName` is set
    const char *selectorName;
};

static const NPPToolBarButtonDef kButtons[] = {
    {"NPPTB.FileNew",       "New",                 "doc.badge.plus",                  NPPCmdFileNew,        nullptr},
    {"NPPTB.FileOpen",      "Open",                "folder",                          NPPCmdFileOpen,       nullptr},
    {"NPPTB.FileSave",      "Save",                "square.and.arrow.down",           NPPCmdFileSave,       nullptr},
    {"NPPTB.FileSaveAll",   "Save All",            "square.and.arrow.down.on.square", NPPCmdFileSaveAll,    nullptr},
    {"NPPTB.FileClose",     "Close",               "xmark.circle",                    NPPCmdFileClose,      nullptr},
    {"NPPTB.FileCloseAll",  "Close All",           "xmark.square",                    NPPCmdFileCloseAll,   nullptr},
    {"NPPTB.FilePrint",     "Print",               "printer",                         NPPCmdFilePrint,      nullptr},
    {"|", nullptr, nullptr, 0, nullptr},
    {"NPPTB.EditCut",       "Cut",                 "scissors",                        NPPCmdEditClipboardCut,  "nppCommand:"},
    {"NPPTB.EditCopy",      "Copy",                "doc.on.doc",                      NPPCmdEditClipboardCopy, "nppCommand:"},
    {"NPPTB.EditPaste",     "Paste",               "doc.on.clipboard",                0,                    "paste:"},
    {"|", nullptr, nullptr, 0, nullptr},
    {"NPPTB.EditUndo",      "Undo",                "arrow.uturn.backward",            0,                    "undo:"},
    {"NPPTB.EditRedo",      "Redo",                "arrow.uturn.forward",             0,                    "redo:"},
    {"|", nullptr, nullptr, 0, nullptr},
    {"NPPTB.SearchFind",    "Find",                "magnifyingglass",                 NPPCmdSearchFind,     nullptr},
    {"NPPTB.SearchReplace", "Replace",             "arrow.2.squarepath",              NPPCmdSearchReplace,  nullptr},
    {"|", nullptr, nullptr, 0, nullptr},
    {"NPPTB.ZoomIn",        "Zoom In",             "plus.magnifyingglass",            NPPCmdViewZoomIn,     nullptr},
    {"NPPTB.ZoomOut",       "Zoom Out",            "minus.magnifyingglass",           NPPCmdViewZoomOut,    nullptr},
    {"|", nullptr, nullptr, 0, nullptr},
    {"NPPTB.SyncScrollV",   "Sync Vertical Scrolling",   "arrow.up.arrow.down",       NPPCmdViewSyncScrollVertical,   nullptr},
    {"NPPTB.SyncScrollH",   "Sync Horizontal Scrolling", "arrow.left.arrow.right",    NPPCmdViewSyncScrollHorizontal, nullptr},
    {"|", nullptr, nullptr, 0, nullptr},
    {"NPPTB.WordWrap",      "Word Wrap",           "arrow.turn.down.left",            NPPCmdViewWordWrap,         nullptr},
    {"NPPTB.ShowAllChars",  "Show All Characters", "paragraphsign",                   NPPCmdViewShowAllChars,     nullptr},
    {"NPPTB.IndentGuide",   "Indent Guide",        "increase.indent",                 NPPCmdViewShowIndentGuide,  nullptr},
    {"|", nullptr, nullptr, 0, nullptr},
    // Upstream's panel group, in upstream's order (Notepad_plus.cpp toolbarIcons): the User-Defined dialogue,
    // Document Map, Document List, Function List, Folder as Workspace.
    {"NPPTB.UserDefinedDlg","Define Your Language","paintbrush",                      NPPCmdLangDefineDialog,     nullptr},
    {"NPPTB.DocumentMap",   "Document Map",        "map",                             NPPCmdViewDocumentMap,      nullptr},
    {"NPPTB.DocumentList",  "Document List",       "list.bullet.rectangle",           NPPCmdViewDocumentList,     nullptr},
    {"NPPTB.FunctionList",  "Function List",       "list.bullet.indent",              NPPCmdViewFunctionList,     nullptr},
    {"NPPTB.Workspace",     "Folder as Workspace", "folder.badge.gearshape",          NPPCmdViewWorkspacePanel,   nullptr},
    {"|", nullptr, nullptr, 0, nullptr},
    // …and the macro group in full, ending where upstream's toolbar ends.
    {"NPPTB.MacroRecord",   "Start Recording",     "record.circle",                   NPPCmdMacroStartRecording,  nullptr},
    {"NPPTB.MacroStop",     "Stop Recording",      "stop.circle",                     NPPCmdMacroStopRecording,   nullptr},
    {"NPPTB.MacroPlay",     "Play Macro",          "play.circle",                     NPPCmdMacroPlayback,        nullptr},
    {"NPPTB.MacroRunMulti", "Run a Macro Multiple Times", "repeat.circle",            NPPCmdMacroRunMultiple,     nullptr},
    {"NPPTB.MacroSave",     "Save Current Recorded Macro", "arrow.down.doc",          NPPCmdMacroSaveCurrent,     nullptr},
    // Run is the port's own addition (upstream has no toolbar button for it), so it gets its own group rather than
    // sitting inside the macro run where a Notepad++ user reaches for Save Current Recorded Macro.
    {"|", nullptr, nullptr, 0, nullptr},
    {"NPPTB.Run",           "Run",                 "terminal",                        NPPCmdRunDialog,            nullptr},
};
static const size_t kButtonCount = sizeof(kButtons) / sizeof(kButtons[0]);

static BOOL NPPToolBarIsSeparator(const NPPToolBarButtonDef &b) { return b.ident[0] == '|'; }

static const NPPToolBarButtonDef *NPPToolBarDefForIdentifier(NSString *ident) {
    for (size_t i = 0; i < kButtonCount; ++i)
        if (!NPPToolBarIsSeparator(kButtons[i]) && [ident isEqualToString:@(kButtons[i].ident)]) return &kButtons[i];
    return nullptr;
}

// The six View > Toolbar tags, and nothing else.
static BOOL NPPToolBarOwnsTag(NSInteger tag) {
    return tag == NPPCmdViewToolbarShow || tag == NPPCmdViewToolbarCustomise ||
           (tag >= NPPCmdViewToolbarIconsBase && tag < NPPCmdViewToolbarIconsBase + 4);
}

// One NSToolbar belongs to one window: handing it to a second one takes it off the first, and both windows then
// report the same toolbar. So attach when there is nowhere to leave (no window yet, the same window again, or the
// window we are on has been closed) and refuse only to walk off a window that is still on screen — which is what
// the throwaway controller inside +[NPPEditorWindowController selfCheckFailures] would otherwise make us do.
static BOOL NPPToolBarShouldAttachTo(NSWindow *want, NSWindow *current) {
    return current == nil || current == want || !current.isVisible;
}

// The one bit of NPPEditorWindowController that NPPCommandContext does not expose. Declared rather than imported
// so this file keeps no build dependency on the window controller, and the call is respondsToSelector-guarded —
// the same shape NPPSearchViewCommands uses to reach -layoutContent.
@protocol NPPToolBarHostWindow <NSObject>
- (void)layoutContent;   // private re-layout, run on every real resize
@end

// ---- icon sets ------------------------------------------------------------------------------------------------
// The menu offers four sets (Small / Large / Small Fluent / Large Fluent) at NPPCmdViewToolbarIconsBase + 0..3, and
// NPPPreferences' NPPToolbarIconSet enum starts with exactly those four, so the menu index *is* the enum value.
// ponytail: upstream ships hand-drawn bitmap icon sets; here one SF Symbol per button varies by size and by
// weight/fill, so "Fluent" means filled-and-heavier. Swap NPPToolBarSymbolImage for a real asset catalogue if the
// port ever grows one.
static BOOL NPPToolBarSetIsLarge(NPPToolbarIconSet s) { return s == NPPToolbarFluentLarge || s == NPPToolbarFilledFluentLarge; }
static BOOL NPPToolBarSetIsFluent(NPPToolbarIconSet s) { return s == NPPToolbarFilledFluentSmall || s == NPPToolbarFilledFluentLarge; }

// ---- colorization (Preferences > Toolbar) ---------------------------------------------------------------------
// Port of IconList::changeFluentIconColor (WinControls/ImageListSet/ImageListSet.cpp): the seven upstream tones by
// their exact RGB, plus System Accent and Custom. Two rules carried over verbatim, because both are reachable from
// the page: a Custom colour of 0 is treated as "no custom colour" and falls through to Default, and Default itself
// paints nothing unless the colorization is Complete — upstream's `default: return false`, i.e. the icons are left
// exactly as the icon set drew them. nil means "leave the icon alone".
static NSColor *NPPToolBarTintColor(NPPToolbarColor choice, NSString *customHex, BOOL complete) {
    static const struct { NPPToolbarColor choice; unsigned rgb; } kTones[] = {
        {NPPToolbarColorRed,    0xE81123}, {NPPToolbarColorGreen,  0x008B00},
        {NPPToolbarColorBlue,   0x0078D4}, {NPPToolbarColorPurple, 0xB146C2},
        {NPPToolbarColorCyan,   0x00B7C3}, {NPPToolbarColorOlive,  0x498205},
        {NPPToolbarColorYellow, 0xFFB900},
    };
    for (size_t i = 0; i < sizeof(kTones) / sizeof(kTones[0]); ++i)
        if (kTones[i].choice == choice)
            return [NSColor colorWithSRGBRed:((kTones[i].rgb >> 16) & 0xFF) / 255.0
                                       green:((kTones[i].rgb >> 8) & 0xFF) / 255.0
                                        blue:(kTones[i].rgb & 0xFF) / 255.0 alpha:1];
    if (choice == NPPToolbarColorAccent) return NSColor.controlAccentColor;
    if (choice == NPPToolbarColorCustom) {
        long bgr = NPPColorFromHex(customHex);   // -1 = unreadable, 0 = black, which upstream reads as "unset"
        if (bgr > 0) return NPPNSColorFromSci(bgr);
    }
    // Default (and a Custom colour of black): Complete repaints every pixel in the mono main colour
    // (upstream g_cDefaultMainLight / g_cDefaultMainDark, which is what NSColor.labelColor already is);
    // Partial has no secondary colour to replace, so it leaves the icon untouched.
    return complete ? NSColor.labelColor : nil;
}

// `complete` is upstream's TbIconInfo::_tbUseMono: Complete recolours the whole glyph (hierarchical), Partial
// recolours only the secondary layers and leaves the body in the normal text colour (palette) — the same split
// upstream makes between "every non-transparent pixel" and "the pixels that match the icon's accent tone".
// `emphasised` is the ticked-toggle look; the heavier weight is what keeps it readable when the user has already
// colourised the whole toolbar in the accent colour, where the tint alone would say nothing.
// ponytail: Partial only shows on a symbol that has more than one layer (Save, New, Workspace…); a single-layer one
// like Find has no secondary tone and stays mono, exactly as an upstream icon with no accent pixels would. Upgrade
// path is the same as the icon sets': a real asset catalogue with a named accent layer per icon.
static NSImage *NPPToolBarSymbolImage(NSString *name, NPPToolbarIconSet set, NSColor *tint, BOOL complete, BOOL emphasised) {
    BOOL fluent = NPPToolBarSetIsFluent(set);
    NSImage *img = nil;
    if (fluent) img = [NSImage imageWithSystemSymbolName:[name stringByAppendingString:@".fill"] accessibilityDescription:name];
    if (!img) img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
    if (!img) return nil;
    NSFontWeight weight = emphasised ? NSFontWeightBlack : (fluent ? NSFontWeightSemibold : NSFontWeightRegular);
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:(NPPToolBarSetIsLarge(set) ? 17 : 13) weight:weight];
    if (tint) {
        NSImageSymbolConfiguration *colour =
            complete ? [NSImageSymbolConfiguration configurationWithHierarchicalColor:tint]
                     : [NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.labelColor, tint, tint]];
        cfg = [cfg configurationByApplyingConfiguration:colour];
    }
    return [img imageWithSymbolConfiguration:cfg] ?: img;
}

// ---- the item -------------------------------------------------------------------------------------------------
@interface NPPToolBarItem : NSToolbarItem
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, strong, nullable) NSImage *plainImage;
@property (nonatomic, strong, nullable) NSImage *checkedImage;
@end

@interface NPPToolBar ()
@property (nonatomic, strong, nullable) NSToolbar *toolbar;
@property (nonatomic, weak, nullable) id<NPPCommandContext> context;
// Whatever answers -validateMenuItem: for this window — the window controller, in practice. A button validates
// against exactly the object the menu validates against, so the two can never disagree.
@property (nonatomic, weak, nullable) id<NSMenuItemValidation> commandValidator;
@property (nonatomic) BOOL rebuilding;
@property (nonatomic) BOOL appliedHidden;   // the last toolbarHidden this module acted on; see -applyVisibility
- (void)setHidden:(BOOL)hidden;
+ (nullable NSArray<NSToolbarItemIdentifier> *)savedButtonIdentifiers;
@end

@implementation NPPToolBarItem

- (void)validate {
    if (self.action != @selector(nppCommand:)) { [super validate]; return; }   // Cut/Copy/Paste/Undo/Redo: responder chain
    id<NSMenuItemValidation> validator = NPPToolBar.shared.commandValidator;
    if (!validator) { self.enabled = NO; return; }
    NSMenuItem *probe = [[NSMenuItem alloc] initWithTitle:(self.label ?: @"") action:@selector(nppCommand:) keyEquivalent:@""];
    probe.tag = self.tag;
    self.enabled = [validator validateMenuItem:probe];
    NSImage *want = (probe.state == NSControlStateValueOn && self.checkedImage) ? self.checkedImage : self.plainImage;
    if (want && self.image != want) self.image = want;
}

@end

// Stands in for the window controller so the enable/check path can be exercised with no window.
@interface NPPToolBarStubValidator : NSObject <NSMenuItemValidation>
@property (nonatomic) NSInteger disabledTag;
@property (nonatomic) NSInteger checkedTag;
@end
@implementation NPPToolBarStubValidator
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    item.state = (item.tag == self.checkedTag) ? NSControlStateValueOn : NSControlStateValueOff;
    return item.tag != self.disabledTag;
}
@end

@implementation NPPToolBar

+ (instancetype)shared {
    static NPPToolBar *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [NPPToolBar new]; });
    return shared;
}

// The window controller posts its context once it is usable; that is the first moment there is a window to put a
// toolbar on, and the main menu already exists by then (it is built in -applicationWillFinishLaunching).
+ (void)load {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:[self shared] selector:@selector(contextDidBecomeReady:)
               name:NPPCommandContextReadyNotification object:nil];
    [nc addObserver:[self shared] selector:@selector(preferencesDidChange:)
               name:NPPPreferencesDidChangeNotification object:nil];
}

- (void)contextDidBecomeReady:(NSNotification *)note {
    id<NPPCommandContext> ctx = note.object;
    if (![ctx respondsToSelector:@selector(contextWindow)]) return;
    NSWindow *win = ctx.contextWindow;
    if (!win) return;
    if (!NPPToolBarShouldAttachTo(win, self.context.contextWindow)) return;   // read before self.context moves
    self.context = ctx;
    self.commandValidator = [ctx conformsToProtocol:@protocol(NSMenuItemValidation)] ? (id<NSMenuItemValidation>)ctx : nil;
    [self attachToWindow:win];
    [self retargetMenu:NSApp.mainMenu];
}

#pragma mark - Building

- (void)attachToWindow:(NSWindow *)win {
    if (!self.toolbar) {
        NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:kToolbarIdentifier];
        tb.delegate = self;
        tb.allowsUserCustomization = YES;
        tb.displayMode = NSToolbarDisplayModeIconOnly;   // upstream is icon-only
        self.toolbar = tb;
    }
    win.toolbar = self.toolbar;
    [self applySavedButtons];
    [self applyIconAppearance];
    self.appliedHidden = NPPPreferences.shared.toolbarHidden;
    self.toolbar.visible = !self.appliedHidden;
    [self relayoutWindow];   // gaining a toolbar changed the content height
}

- (NSArray<NSToolbarItemIdentifier> *)buttonIdentifiers {
    NSMutableArray<NSToolbarItemIdentifier> *ids = [NSMutableArray array];
    for (NSToolbarItem *it in self.toolbar.items) [ids addObject:it.itemIdentifier];
    return ids;
}

+ (NSArray<NSToolbarItemIdentifier> *)defaultButtonIdentifiers {
    NSMutableArray<NSToolbarItemIdentifier> *ids = [NSMutableArray array];
    for (size_t i = 0; i < kButtonCount; ++i)
        [ids addObject:NPPToolBarIsSeparator(kButtons[i]) ? NSToolbarSpaceItemIdentifier : @(kButtons[i].ident)];
    return ids;
}

+ (NSArray<NSToolbarItemIdentifier> *)allowedButtonIdentifiers {
    NSMutableArray<NSToolbarItemIdentifier> *ids = [NSMutableArray array];
    for (size_t i = 0; i < kButtonCount; ++i)
        if (!NPPToolBarIsSeparator(kButtons[i])) [ids addObject:@(kButtons[i].ident)];
    [ids addObject:NSToolbarSpaceItemIdentifier];
    [ids addObject:NSToolbarFlexibleSpaceItemIdentifier];
    return ids;
}

// A set saved by an older build may name buttons this one no longer has; unknown identifiers are dropped rather
// than handed to NSToolbar, which would leave holes in the strip. nil = "use the default set".
+ (NSArray<NSToolbarItemIdentifier> *)savedButtonIdentifiers {
    NSArray<NSString *> *saved = [NSUserDefaults.standardUserDefaults stringArrayForKey:kButtonsKey];
    if (!saved.count) return nil;
    NSArray<NSToolbarItemIdentifier> *allowed = [self allowedButtonIdentifiers];
    NSMutableArray<NSToolbarItemIdentifier> *ids = [NSMutableArray array];
    for (NSString *i in saved) if ([allowed containsObject:i]) [ids addObject:i];
    return ids.count ? ids : nil;
}

- (void)applySavedButtons {
    NSArray<NSToolbarItemIdentifier> *want = [NPPToolBar savedButtonIdentifiers];
    if (!want || [want isEqualToArray:self.buttonIdentifiers]) return;
    self.rebuilding = YES;
    while (self.toolbar.items.count) [self.toolbar removeItemAtIndex:0];
    NSInteger at = 0;
    for (NSToolbarItemIdentifier i in want) [self.toolbar insertItemWithItemIdentifier:i atIndex:at++];
    self.rebuilding = NO;
}

// Upstream keeps the button set in toolbarButtonsConf.xml; here the customization palette is the editor and the set
// lands in NSUserDefaults. NSToolbar reports one add/remove at a time, so coalesce onto the next turn. A set that
// still matches the default is stored as "no preference", so a later build's default set still reaches the user.
- (void)saveButtonsSoon {
    if (self.rebuilding) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.rebuilding || !self.toolbar) return;
        NSArray<NSToolbarItemIdentifier> *now = self.buttonIdentifiers;
        if ([now isEqualToArray:[NPPToolBar defaultButtonIdentifiers]])
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kButtonsKey];
        else
            [NSUserDefaults.standardUserDefaults setObject:now forKey:kButtonsKey];
    });
}

#pragma mark - Applying settings

// The Preferences > Toolbar page writes the same two keys, so it drives this toolbar too.
- (void)preferencesDidChange:(NSNotification *)note {
    if (!self.toolbar) return;
    [self applyIconAppearance];
    // -configureItem: puts the *plain* image back, so a ticked toggle (word wrap, show all characters …) loses its
    // accent until something validates it again. Ask now rather than leaving it wrong until the next event.
    [self.toolbar validateVisibleItems];
    [self applyVisibility];
}

- (void)configureItem:(NPPToolBarItem *)item {
    NPPPreferences *p = NPPPreferences.shared;
    NPPToolbarIconSet set = p.toolbarIconSet;
    BOOL complete = p.toolbarColorizationComplete;
    // Upstream recolours only the Fluent sets (IconList::addIcon's `if (isToolbarNormal)`), and the Toolbar page
    // greys the colorization out for the standard set and says in so many words that the colour choice does not
    // apply to it. Honour that here, or a disabled control would go on tinting the toolbar behind the user's back.
    NSColor *tint = set == NPPToolbarStandardSmall
                        ? nil : NPPToolBarTintColor(p.toolbarColor, p.toolbarCustomColor, complete);
    item.plainImage = NPPToolBarSymbolImage(item.symbolName, set, tint, complete, NO);
    // The ticked look is always the accent colour drawn over the whole glyph, and always heavier than the plain
    // one, so it still reads as "on" when the plain icons are already accent-coloured.
    item.checkedImage = NPPToolBarSymbolImage(item.symbolName, set, NSColor.controlAccentColor, YES, YES);
    item.image = item.plainImage;
}

// Icon set, colorization and colour choice all land the same way: rebuild every item's image. NSToolbar.sizeMode is
// inert since Big Sur — it reports Regular whatever you assign — so the icon's own point size is the only thing that
// makes Large larger; the row grows to fit it. Setting sizeMode here would be a no-op that reads like the mechanism.
- (void)applyIconAppearance {
    for (NSToolbarItem *it in self.toolbar.items)
        if ([it isKindOfClass:NPPToolBarItem.class]) [self configureItem:(NPPToolBarItem *)it];
}

// Only a change to the setting moves the toolbar. macOS lets the user hide it from the title bar's context menu
// without telling anyone, so re-asserting the stored value on every unrelated preference change would keep
// resurrecting a toolbar the user just dismissed.
- (void)applyVisibility {
    BOOL hidden = NPPPreferences.shared.toolbarHidden;
    if (hidden == self.appliedHidden) return;
    [self setHidden:hidden];
}

// Moves the toolbar and stores the setting together, so View > Toolbar > Show Toolbar still works after the user
// hid the toolbar from the title bar (which leaves the stored setting saying "shown").
- (void)setHidden:(BOOL)hidden {
    self.appliedHidden = hidden;
    if (self.toolbar.isVisible != !hidden) {
        self.toolbar.visible = !hidden;
        [self relayoutWindow];
    }
    if (NPPPreferences.shared.toolbarHidden != hidden) NPPPreferences.shared.toolbarHidden = hidden;
}

// Showing, hiding or resizing the toolbar changes the window's content height without changing its frame, so the
// window controller's -windowDidResize: does not run on its own. Call the re-layout it would have called: faking
// NSWindowDidResizeNotification would also hand a resize that never happened to AppKit's own observers of that
// window.
- (void)relayoutWindow {
    id ctx = self.context;
    if ([ctx respondsToSelector:@selector(layoutContent)]) [(id<NPPToolBarHostWindow>)ctx layoutContent];
}

#pragma mark - <NSToolbarDelegate>

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return [NPPToolBar defaultButtonIdentifiers];   // stays the factory set, so the palette's Reset really resets
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [NPPToolBar allowedButtonIdentifiers];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    const NPPToolBarButtonDef *def = NPPToolBarDefForIdentifier(identifier);
    if (!def) return nil;
    NPPToolBarItem *item = [[NPPToolBarItem alloc] initWithItemIdentifier:identifier];
    item.label = item.paletteLabel = item.toolTip = @(def->label);
    item.symbolName = @(def->symbol);
    item.tag = def->tag;
    // target nil on purpose: the click travels the responder chain to the window controller, exactly as the menu's
    // does. -validate is what keeps the button's enabled/checked state on the menu item's.
    item.target = nil;
    item.action = def->selectorName ? NSSelectorFromString(@(def->selectorName)) : @selector(nppCommand:);
    [self configureItem:item];
    return item;
}

- (void)toolbarWillAddItem:(NSNotification *)note { [self saveButtonsSoon]; }
- (void)toolbarDidRemoveItem:(NSNotification *)note { [self saveButtonsSoon]; }

#pragma mark - <NPPCommandHandler>

+ (BOOL)handlesCommand:(NPPCmd)cmd { return NPPToolBarOwnsTag(cmd); }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NSToolbar *tb = NPPToolBar.shared.toolbar;
    if (!tb) return NO;                                     // no window yet: nothing to show, size or customise
    if (!NPPToolBarOwnsTag(cmd)) return NO;
    if (cmd == NPPCmdViewToolbarCustomise) return tb.allowsUserCustomization && tb.isVisible;
    return YES;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (![self canPerformCommand:cmd context:context]) return NO;
    NPPToolBar *bar = NPPToolBar.shared;
    if (cmd == NPPCmdViewToolbarShow) { [bar setHidden:bar.toolbar.isVisible]; return YES; }
    if (cmd == NPPCmdViewToolbarCustomise) { [bar.toolbar runCustomizationPalette:nil]; return YES; }
    // The setter posts, and -preferencesDidChange: repaints every button at the new size and weight.
    NPPPreferences.shared.toolbarIconSet = (NPPToolbarIconSet)(cmd - NPPCmdViewToolbarIconsBase);
    return YES;
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd == NPPCmdViewToolbarShow) return NPPToolBar.shared.toolbar.isVisible;
    if (cmd != NPPCmdViewToolbarCustomise && NPPToolBarOwnsTag(cmd))
        // ponytail: NPPToolbarStandardSmall (a fifth set only the Preferences page offers) has no menu item, so
        // with it selected no icon-set item is checked. Give it one in NPPAppDelegate if it should be reachable.
        return NPPPreferences.shared.toolbarIconSet == (NPPToolbarIconSet)(cmd - NPPCmdViewToolbarIconsBase);
    return NO;
}

#pragma mark - Menu entry points

// The window controller's feature-handler table is a fixed list this module is not on, so the six View > Toolbar
// items are pointed straight at the shared instance instead. Everything else in the menu is left alone.
- (void)retargetMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) { [self retargetMenu:item.submenu]; continue; }
        if (item.action == @selector(nppCommand:) && NPPToolBarOwnsTag(item.tag)) item.target = self;
    }
}

- (IBAction)nppCommand:(id)sender {
    NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    if (![NPPToolBar performCommand:(NPPCmd)tag context:self.context]) NSBeep();
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action != @selector(nppCommand:)) return YES;
    item.state = [NPPToolBar commandIsChecked:(NPPCmd)item.tag context:self.context] ? NSControlStateValueOn : NSControlStateValueOff;
    return [NPPToolBar canPerformCommand:(NPPCmd)item.tag context:self.context];
}

#pragma mark - Self-checks

// A symbol configuration is opaque, so the only way to tell "the tint was computed" from "the tint was applied" is
// to draw the image and look at the pixels. Off-screen, so it works in the headless self-test run.
static NSData *NPPToolBarRasterise(NSImage *img) {
    if (!img || img.size.width < 1 || img.size.height < 1) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)ceil(img.size.width) pixelsHigh:(NSInteger)ceil(img.size.height)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!ctx) return nil;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    [img drawInRect:NSMakeRect(0, 0, img.size.width, img.size.height)];
    [NSGraphicsContext restoreGraphicsState];
    return [NSData dataWithBytes:rep.bitmapData length:(NSUInteger)(rep.bytesPerRow * rep.pixelsHigh)];
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *what) { if (!ok) [fails addObject:what]; };
    id<NPPCommandContext> noContext = nil;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    id savedButtons = [d objectForKey:kButtonsKey];
    NPPPreferences *prefs = NPPPreferences.shared;
    NPPToolbarIconSet savedSet = prefs.toolbarIconSet;
    BOOL savedComplete = prefs.toolbarColorizationComplete;
    NPPToolbarColor savedColour = prefs.toolbarColor;
    NSString *savedCustom = prefs.toolbarCustomColor;

    // 1. every button resolves to a real SF Symbol in every icon set (a typo'd name is a blank button)
    for (size_t i = 0; i < kButtonCount; ++i) {
        if (NPPToolBarIsSeparator(kButtons[i])) continue;
        NSString *name = @(kButtons[i].symbol);
        for (NSInteger s = NPPToolbarFluentSmall; s <= NPPToolbarFilledFluentLarge; s++)
            expect(NPPToolBarSymbolImage(name, (NPPToolbarIconSet)s, nil, NO, NO) != nil,
                   [NSString stringWithFormat:@"symbol %@ missing for icon set %ld", name, (long)s]);
    }

    // 2. the default set: no repeated button, every entry offered by the palette, every named command present
    NSArray<NSToolbarItemIdentifier> *def = [self defaultButtonIdentifiers], *allowed = [self allowedButtonIdentifiers];
    NSCountedSet *seen = [NSCountedSet set];
    for (NSToolbarItemIdentifier i in def) {
        if (![i isEqualToString:NSToolbarSpaceItemIdentifier]) [seen addObject:i];
        expect([allowed containsObject:i], [NSString stringWithFormat:@"default identifier %@ is not allowed", i]);
    }
    for (NSToolbarItemIdentifier i in seen)
        expect([seen countForObject:i] == 1, [NSString stringWithFormat:@"default set repeats %@", i]);
    for (NSNumber *tag in @[@(NPPCmdFileNew), @(NPPCmdFileOpen), @(NPPCmdFileSave), @(NPPCmdFileSaveAll),
                            @(NPPCmdFileClose), @(NPPCmdFileCloseAll), @(NPPCmdFilePrint), @(NPPCmdSearchFind),
                            @(NPPCmdSearchReplace), @(NPPCmdViewZoomIn), @(NPPCmdViewZoomOut),
                            @(NPPCmdViewSyncScrollVertical), @(NPPCmdViewSyncScrollHorizontal),
                            @(NPPCmdViewWordWrap), @(NPPCmdViewShowAllChars),
                            @(NPPCmdViewShowIndentGuide), @(NPPCmdViewFunctionList), @(NPPCmdViewDocumentMap),
                            @(NPPCmdViewWorkspacePanel), @(NPPCmdMacroStartRecording), @(NPPCmdMacroStopRecording),
                            @(NPPCmdMacroPlayback), @(NPPCmdRunDialog)]) {
        BOOL found = NO;
        for (size_t i = 0; i < kButtonCount && !found; ++i) found = (kButtons[i].tag == tag.integerValue);
        expect(found, [NSString stringWithFormat:@"no default button for command %@", tag]);
    }
    // The five standard editing buttons carry tag 0, so the loop above cannot see them: deleting Cut would fail
    // nothing without this.
    // Cut and Copy now carry NPPCmd tags (they honour "Copy/Cut line without selection"); the other three are
    // still plain Cocoa selectors, and deleting any of the five must fail here.
    for (NSNumber *tag in @[@(NPPCmdEditClipboardCut), @(NPPCmdEditClipboardCopy)]) {
        BOOL found = NO;
        for (size_t i = 0; i < kButtonCount && !found; ++i) found = (kButtons[i].tag == tag.integerValue);
        expect(found, [NSString stringWithFormat:@"no default button for clipboard command %@", tag]);
    }
    for (NSString *sel in @[@"paste:", @"undo:", @"redo:"]) {
        BOOL found = NO;
        for (size_t i = 0; i < kButtonCount && !found; ++i)
            found = kButtons[i].selectorName && [sel isEqualToString:@(kButtons[i].selectorName)];
        expect(found, [NSString stringWithFormat:@"no default button for %@", sel]);
    }
    // 2b. Two groups a Notepad++ user reaches by position, checked as a contiguous run in upstream's order — a
    // button that exists but sits somewhere else on the strip is not where the muscle memory points, and a group
    // that quietly loses its last two entries (Document List; Save Current Recorded Macro / Run a Macro Multiple
    // Times) is exactly what the loop above cannot see.
    for (NSArray<NSNumber *> *group in @[@[@(NPPCmdLangDefineDialog), @(NPPCmdViewDocumentMap), @(NPPCmdViewDocumentList),
                                           @(NPPCmdViewFunctionList), @(NPPCmdViewWorkspacePanel)],
                                         @[@(NPPCmdMacroStartRecording), @(NPPCmdMacroStopRecording), @(NPPCmdMacroPlayback),
                                           @(NPPCmdMacroRunMultiple), @(NPPCmdMacroSaveCurrent)]]) {
        size_t start = kButtonCount;
        for (size_t i = 0; i < kButtonCount && start == kButtonCount; ++i)
            if (kButtons[i].tag == group.firstObject.integerValue) start = i;
        BOOL ok = (start != kButtonCount && start + group.count <= kButtonCount);
        for (NSUInteger k = 0; ok && k < group.count; ++k) ok = (kButtons[start + k].tag == group[k].integerValue);
        expect(ok, [NSString stringWithFormat:@"the toolbar group starting at command %@ is not upstream's run of %lu buttons",
                                              group.firstObject, (unsigned long)group.count]);
        for (NSNumber *tag in group) {   // …and each of them is offered by the customization palette
            const char *ident = nullptr;
            for (size_t i = 0; i < kButtonCount && !ident; ++i)
                if (kButtons[i].tag == tag.integerValue) ident = kButtons[i].ident;
            expect(ident && [allowed containsObject:@(ident)],
                   [NSString stringWithFormat:@"command %@ cannot be added from the customization palette", tag]);
        }
    }

    // 3. icon sets: menu index == NPPToolbarIconSet value, and exactly one item is radio-checked
    expect(!NPPToolBarSetIsLarge(NPPToolbarFluentSmall) && !NPPToolBarSetIsFluent(NPPToolbarFluentSmall), @"icon set 0 should be small/plain");
    expect(NPPToolBarSetIsLarge(NPPToolbarFluentLarge) && !NPPToolBarSetIsFluent(NPPToolbarFluentLarge), @"icon set 1 should be large/plain");
    expect(!NPPToolBarSetIsLarge(NPPToolbarFilledFluentSmall) && NPPToolBarSetIsFluent(NPPToolbarFilledFluentSmall), @"icon set 2 should be small/fluent");
    expect(NPPToolBarSetIsLarge(NPPToolbarFilledFluentLarge) && NPPToolBarSetIsFluent(NPPToolbarFilledFluentLarge), @"icon set 3 should be large/fluent");
    // …and the size the set names is the size the button actually gets. NSToolbar.sizeMode cannot deliver this any
    // more (see -applyIconAppearance), so the point size in NPPToolBarSymbolImage is the whole mechanism: if that ever stops
    // varying, "Large Icons" silently becomes a no-op menu item.
    for (NSInteger k = 0; k < 4; k++) {
        if (!NPPToolBarSetIsLarge((NPPToolbarIconSet)k)) continue;
        CGFloat large = NPPToolBarSymbolImage(@"folder", (NPPToolbarIconSet)k, nil, NO, NO).size.height;
        CGFloat small = NPPToolBarSymbolImage(@"folder", (NPPToolbarIconSet)(k - 1), nil, NO, NO).size.height;
        expect(large > small, [NSString stringWithFormat:@"icon set %ld is not drawn larger than set %ld (%g vs %g)",
                                                         (long)k, (long)(k - 1), large, small]);
    }
    for (NSInteger k = 0; k < 4; k++) {
        NPPPreferences.shared.toolbarIconSet = (NPPToolbarIconSet)k;
        NSInteger checked = 0;
        for (NSInteger j = 0; j < 4; j++)
            if ([self commandIsChecked:(NPPCmd)(NPPCmdViewToolbarIconsBase + j) context:noContext]) checked++;
        expect(checked == 1, [NSString stringWithFormat:@"icon set %ld checked %ld menu items", (long)k, (long)checked]);
        expect([self commandIsChecked:(NPPCmd)(NPPCmdViewToolbarIconsBase + k) context:noContext],
               [NSString stringWithFormat:@"icon set %ld is not the checked one", (long)k]);
    }

    // 3b. Colorization. The colour table first (every tone is a radio button on the Toolbar page, so a wrong
    // constant is a control that lies), then that the answer actually reaches the icon.
    NSDictionary<NSNumber *, NSColor *> *tones = @{
        @(NPPToolbarColorRed):    [NSColor colorWithSRGBRed:0xE8/255.0 green:0x11/255.0 blue:0x23/255.0 alpha:1],
        @(NPPToolbarColorGreen):  [NSColor colorWithSRGBRed:0x00/255.0 green:0x8B/255.0 blue:0x00/255.0 alpha:1],
        @(NPPToolbarColorBlue):   [NSColor colorWithSRGBRed:0x00/255.0 green:0x78/255.0 blue:0xD4/255.0 alpha:1],
        @(NPPToolbarColorPurple): [NSColor colorWithSRGBRed:0xB1/255.0 green:0x46/255.0 blue:0xC2/255.0 alpha:1],
        @(NPPToolbarColorCyan):   [NSColor colorWithSRGBRed:0x00/255.0 green:0xB7/255.0 blue:0xC3/255.0 alpha:1],
        @(NPPToolbarColorOlive):  [NSColor colorWithSRGBRed:0x49/255.0 green:0x82/255.0 blue:0x05/255.0 alpha:1],
        @(NPPToolbarColorYellow): [NSColor colorWithSRGBRed:0xFF/255.0 green:0xB9/255.0 blue:0x00/255.0 alpha:1],
    };
    for (NSNumber *choice in tones) {
        for (int c = 0; c < 2; c++) {   // a named tone paints the same colour whichever colorization is picked
            NSColor *got = NPPToolBarTintColor((NPPToolbarColor)choice.integerValue, @"000000", c == 1);
            expect([got isEqual:tones[choice]],
                   [NSString stringWithFormat:@"toolbar colour %@ is %@, expected %@", choice, got, tones[choice]]);
        }
    }
    expect([NPPToolBarTintColor(NPPToolbarColorAccent, @"000000", NO) isEqual:NSColor.controlAccentColor],
           @"System Accent is not the system accent colour");
    expect([NPPToolBarTintColor(NPPToolbarColorCustom, @"FF8800", NO) isEqual:NPPNSColorFromSci(NPPColorFromHex(@"FF8800"))],
           @"a Custom colour did not reach the icons");
    // Upstream's two fall-throughs: an unset (black) Custom colour behaves as Default, and Default leaves the icons
    // alone unless the colorization is Complete. Without the first, picking Custom and never opening the colour well
    // would silently blacken the toolbar; without the second, "Default + Partial" would repaint icons it must not.
    expect(NPPToolBarTintColor(NPPToolbarColorCustom, @"000000", NO) == nil, @"Custom black should fall back to Default");
    expect(NPPToolBarTintColor(NPPToolbarColorDefault, @"000000", NO) == nil, @"Default + Partial must not tint at all");
    expect([NPPToolBarTintColor(NPPToolbarColorDefault, @"000000", YES) isEqual:NSColor.labelColor],
           @"Default + Complete must repaint in the mono main colour");
    expect([NPPToolBarTintColor(NPPToolbarColorCustom, @"000000", YES) isEqual:NSColor.labelColor],
           @"Custom black + Complete must behave as Default + Complete");
    expect(NPPToolBarTintColor(NPPToolbarColorCustom, @"", NO) == nil, @"an unreadable Custom colour must fall back to Default");

    // …and the pixels. Complete, Partial and untinted have to be three different icons, or two of the three radio
    // buttons are decoration. Then the same three through -configureItem:, which is the only path the real toolbar
    // takes — a tint function nothing calls would pass every check above.
    NSColor *red = tones[@(NPPToolbarColorRed)];
    NSData *plainPixels = NPPToolBarRasterise(NPPToolBarSymbolImage(@"doc.badge.plus", NPPToolbarFluentSmall, nil, NO, NO));
    NSData *completePixels = NPPToolBarRasterise(NPPToolBarSymbolImage(@"doc.badge.plus", NPPToolbarFluentSmall, red, YES, NO));
    NSData *partialPixels = NPPToolBarRasterise(NPPToolBarSymbolImage(@"doc.badge.plus", NPPToolbarFluentSmall, red, NO, NO));
    expect(plainPixels.length > 0 && completePixels.length > 0 && partialPixels.length > 0, @"a toolbar icon would not rasterise");
    expect(![plainPixels isEqual:completePixels], @"Complete colorization does not change the icon");
    expect(![plainPixels isEqual:partialPixels], @"Partial colorization does not change the icon");
    expect(![completePixels isEqual:partialPixels], @"Complete and Partial colorization draw the same icon");

    NPPToolBar *shared = [self shared];
    NSToolbar *probeBar = [[NSToolbar alloc] initWithIdentifier:@"NPPToolbar.selfCheck"];
    // Every argument is one of the three Preferences > Toolbar settings, so exactly one can be varied at a time.
    // That matters: a comparison that moves two at once still passes when -configureItem: honours only one of
    // them (a red/Complete icon differs from a default/Partial one even if the colour is thrown away).
    NSData *(^itemPixels)(NSToolbarItemIdentifier, NPPToolbarIconSet, NPPToolbarColor, BOOL, BOOL) =
        ^(NSToolbarItemIdentifier ident, NPPToolbarIconSet set, NPPToolbarColor colour, BOOL complete, BOOL checked) {
            prefs.toolbarIconSet = set;
            prefs.toolbarColor = colour;
            prefs.toolbarColorizationComplete = complete;
            NPPToolBarItem *it = (NPPToolBarItem *)[shared toolbar:probeBar itemForItemIdentifier:ident
                                        willBeInsertedIntoToolbar:NO];
            return NPPToolBarRasterise(checked ? it.checkedImage : it.plainImage);
        };
    prefs.toolbarCustomColor = @"FF8800";   // a real one, so the Custom rows below exercise the Custom branch
    // doc.badge.plus, the multi-layer symbol the pixel checks above already proved Partial can tell apart — on a
    // single-layer glyph Partial has no secondary tone to recolour and two different tones would agree.
    NSToolbarItemIdentifier layered = @"NPPTB.FileNew";
    expect(![itemPixels(layered, NPPToolbarFluentSmall, NPPToolbarColorRed, NO, NO)
             isEqual:itemPixels(layered, NPPToolbarFluentSmall, NPPToolbarColorBlue, NO, NO)],
           @"the Toolbar page's colour choice never reaches a built item");
    expect(![itemPixels(layered, NPPToolbarFluentSmall, NPPToolbarColorRed, YES, NO)
             isEqual:itemPixels(layered, NPPToolbarFluentSmall, NPPToolbarColorRed, NO, NO)],
           @"Complete vs Partial never reaches a built item");
    expect(![itemPixels(layered, NPPToolbarFluentSmall, NPPToolbarColorRed, YES, NO)
             isEqual:itemPixels(layered, NPPToolbarFluentLarge, NPPToolbarColorRed, YES, NO)],
           @"the icon set never reaches a built item");
    // …and the one set that must stay untinted, because the page disables its colorization controls and says so.
    expect([itemPixels(layered, NPPToolbarStandardSmall, NPPToolbarColorRed, YES, NO)
            isEqual:itemPixels(layered, NPPToolbarStandardSmall, NPPToolbarColorDefault, NO, NO)],
           @"the standard icon set is tinted although the Toolbar page greys its colour choice out");
    // A ticked toggle must stay visibly ticked in every combination — including System Accent + Complete, where the
    // plain icon is already the accent colour and only the heavier weight tells the two apart.
    for (NSNumber *choice in @[@(NPPToolbarColorDefault), @(NPPToolbarColorAccent), @(NPPToolbarColorRed), @(NPPToolbarColorCustom)]) {
        for (int c = 0; c < 2; c++) {
            NPPToolbarColor colour = (NPPToolbarColor)choice.integerValue;
            expect(![itemPixels(@"NPPTB.WordWrap", NPPToolbarFluentSmall, colour, c == 1, NO)
                     isEqual:itemPixels(@"NPPTB.WordWrap", NPPToolbarFluentSmall, colour, c == 1, YES)],
                   [NSString stringWithFormat:@"colour %@ / complete %d: a ticked button looks like an unticked one", choice, c]);
        }
    }

    // …and that the page repaints a toolbar that is already built. -configureItem: is reached from the item
    // factory above whatever -preferencesDidChange: does, so without this the Toolbar page's radio buttons could
    // compute a new icon that no button on screen ever receives. On a throwaway toolbar, never the user's: an
    // insert into the live one would hand their saved button set to -saveButtonsSoon.
    NSToolbar *liveProbe = [[NSToolbar alloc] initWithIdentifier:@"NPPToolbar.selfCheck.live"];
    liveProbe.delegate = shared;
    NSToolbar *toolbarBeforeProbe = shared.toolbar;
    shared.toolbar = liveProbe;
    shared.rebuilding = YES;                 // -saveButtonsSoon returns on this before it schedules anything
    [liveProbe insertItemWithItemIdentifier:layered atIndex:0];
    prefs.toolbarColor = NPPToolbarColorRed;
    prefs.toolbarColorizationComplete = YES;
    NSData *builtRed = NPPToolBarRasterise(liveProbe.items.firstObject.image);
    prefs.toolbarColor = NPPToolbarColorBlue;   // the setter posts; -preferencesDidChange: has to do the rest
    NSData *builtBlue = NPPToolBarRasterise(liveProbe.items.firstObject.image);
    expect(builtRed.length > 0, @"self-check bug: the throwaway toolbar built no item, so the live repaint is untested");
    expect(![builtRed isEqual:builtBlue], @"changing the colour did not repaint a toolbar that was already built");
    shared.toolbar = toolbarBeforeProbe;
    shared.rebuilding = NO;                  // only now: the user's saved button set must never see the probe's

    prefs.toolbarColor = savedColour;
    prefs.toolbarColorizationComplete = savedComplete;
    prefs.toolbarCustomColor = savedCustom;
    prefs.toolbarIconSet = savedSet;

    // 4. command ownership: exactly the six View > Toolbar tags
    expect([self handlesCommand:NPPCmdViewToolbarShow] && [self handlesCommand:NPPCmdViewToolbarCustomise] &&
           [self handlesCommand:(NPPCmd)(NPPCmdViewToolbarIconsBase + 3)], @"does not claim its own tags");
    expect(![self handlesCommand:NPPCmdFileNew] && ![self handlesCommand:(NPPCmd)(NPPCmdViewToolbarIconsBase + 4)],
           @"claims a foreign tag");
    // With a toolbar in hand, so the ownership test is reached instead of short-circuited by canPerform's "no
    // toolbar yet". It is the only thing between a foreign tag and -performCommand: writing (tag - IconsBase)
    // into the icon-set preference.
    NSToolbar *hadToolbar = shared.toolbar;
    if (!hadToolbar) shared.toolbar = [[NSToolbar alloc] initWithIdentifier:@"NPPToolbar.selfCheck"];
    NPPToolbarIconSet setBefore = NPPPreferences.shared.toolbarIconSet;
    expect(![self canPerformCommand:NPPCmdFileNew context:noContext], @"claims it can perform a foreign tag");
    expect(![self performCommand:NPPCmdFileNew context:noContext], @"performs a foreign tag");
    expect(NPPPreferences.shared.toolbarIconSet == setBefore, @"a foreign tag reached the icon-set preference");
    shared.toolbar = hadToolbar;

    // 5. the saved button set round-trips, and unknown identifiers are dropped
    [d setObject:@[@"NPPTB.FileNew", @"NPPTB.Nonsense", NSToolbarSpaceItemIdentifier, @"NPPTB.Run"] forKey:kButtonsKey];
    NSArray<NSToolbarItemIdentifier> *loaded = [self savedButtonIdentifiers];
    expect([loaded isEqualToArray:@[@"NPPTB.FileNew", NSToolbarSpaceItemIdentifier, @"NPPTB.Run"]],
           [NSString stringWithFormat:@"saved button set did not round-trip: %@", loaded]);
    [d setObject:@[@"NPPTB.Nonsense"] forKey:kButtonsKey];
    expect([self savedButtonIdentifiers] == nil, @"an entirely unknown saved set should fall back to the default");
    [d removeObjectForKey:kButtonsKey];
    expect([self savedButtonIdentifiers] == nil, @"no saved set should fall back to the default");

    // 6. items carry the tag and action the menu uses, and follow the validator's enabled / checked state
    NPPToolBar *bar = [self shared];
    NSToolbar *probeToolbar = [[NSToolbar alloc] initWithIdentifier:@"NPPToolbar.selfCheck"];
    NPPToolBarStubValidator *stub = [NPPToolBarStubValidator new];
    stub.disabledTag = NPPCmdViewZoomIn;
    stub.checkedTag = NPPCmdViewWordWrap;
    id<NSMenuItemValidation> previousValidator = bar.commandValidator;
    bar.commandValidator = stub;
    for (NSToolbarItemIdentifier ident in allowed) {
        if ([ident isEqualToString:NSToolbarSpaceItemIdentifier] || [ident isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) continue;
        NPPToolBarItem *item = (NPPToolBarItem *)[bar toolbar:probeToolbar itemForItemIdentifier:ident willBeInsertedIntoToolbar:NO];
        const NPPToolBarButtonDef *bdef = NPPToolBarDefForIdentifier(ident);
        if (!item || !bdef) { expect(NO, [NSString stringWithFormat:@"no item built for %@", ident]); continue; }
        expect(item.image != nil, [NSString stringWithFormat:@"%@ has no icon", ident]);
        expect(item.label.length > 0 && item.toolTip.length > 0, [NSString stringWithFormat:@"%@ has no label", ident]);
        if (bdef->selectorName && bdef->tag == 0) {
            expect(item.tag == 0 && item.action == NSSelectorFromString(@(bdef->selectorName)),
                   [NSString stringWithFormat:@"%@ should fire the Cocoa selector %s", ident, bdef->selectorName]);
            continue;
        }
        expect(item.tag == bdef->tag && item.action == @selector(nppCommand:) && item.target == nil,
               [NSString stringWithFormat:@"%@ does not fire nppCommand: with tag %ld up the responder chain", ident, (long)bdef->tag]);
        [item validate];
        expect(item.isEnabled == (item.tag != stub.disabledTag),
               [NSString stringWithFormat:@"%@ ignored the menu's validation", ident]);
    }
    // The accent goes on when the command is ticked and — the half a one-way -validate would still pass — comes
    // off again when it stops being ticked, instead of leaving the button lit for the rest of the session.
    NPPToolBarItem *toggle = (NPPToolBarItem *)[bar toolbar:probeToolbar itemForItemIdentifier:@"NPPTB.WordWrap" willBeInsertedIntoToolbar:NO];
    [toggle validate];
    expect(toggle.image == toggle.checkedImage, @"a checked command did not get the accented icon");
    stub.checkedTag = 0;
    [toggle validate];
    expect(toggle.image == toggle.plainImage, @"a command that stopped being checked kept the accented icon");

    bar.commandValidator = nil;
    NPPToolBarItem *orphan = (NPPToolBarItem *)[bar toolbar:probeToolbar itemForItemIdentifier:@"NPPTB.FileNew" willBeInsertedIntoToolbar:NO];
    [orphan validate];
    expect(!orphan.isEnabled, @"a button with nothing to validate against must be disabled, not live");
    expect([bar toolbar:probeToolbar itemForItemIdentifier:@"NPPTB.Nonsense" willBeInsertedIntoToolbar:NO] == nil,
           @"an unknown identifier should not build an item");
    bar.commandValidator = previousValidator;

    // 7. the menu path. Both halves run every time: with no toolbar every owned tag must report unsupported, and
    // with one Show Toolbar must round-trip. NSToolbar.visible does not move off a window (the setter is ignored
    // on a detached toolbar), so when this runs before any window exists the check brings its own — otherwise
    // half of it would only ever run when some earlier module happened to leave a window behind.
    NSMenuItem *probe = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
    probe.tag = NPPCmdFileNew;
    expect(![bar validateMenuItem:probe], @"validateMenuItem: must refuse a foreign tag");

    NSToolbar *liveToolbar = bar.toolbar;
    bar.toolbar = nil;
    for (NSNumber *owned in @[@(NPPCmdViewToolbarShow), @(NPPCmdViewToolbarCustomise), @(NPPCmdViewToolbarIconsBase)]) {
        probe.tag = owned.integerValue;
        expect(![bar validateMenuItem:probe],
               [NSString stringWithFormat:@"command %@ must be disabled while there is no toolbar", owned]);
    }
    NSWindow *standInWindow = nil;
    if (liveToolbar) {
        bar.toolbar = liveToolbar;
    } else {
        standInWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 200)
                                                    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        bar.toolbar = [[NSToolbar alloc] initWithIdentifier:@"NPPToolbar.selfCheck"];
        bar.toolbar.allowsUserCustomization = YES;
        standInWindow.toolbar = bar.toolbar;
        [standInWindow orderBack:nil];
    }
    // Start from a known state rather than from whatever the user left: someone who runs this with their toolbar
    // hidden must not see a failure for it.
    BOOL wasVisible = bar.toolbar.isVisible, wasHidden = NPPPreferences.shared.toolbarHidden;
    bar.appliedHidden = NO;
    bar.toolbar.visible = YES;
    expect(bar.toolbar.isVisible, @"self-check bug: the toolbar under test is not on screen, so Show Toolbar is untested");
    // The palette has nowhere to open while the toolbar is off screen, so Customise is dead exactly then.
    expect([self canPerformCommand:NPPCmdViewToolbarCustomise context:noContext], @"Customise must be live while the toolbar is shown");
    bar.toolbar.visible = NO;
    expect(![self canPerformCommand:NPPCmdViewToolbarCustomise context:noContext], @"Customise must be dead while the toolbar is hidden");
    bar.toolbar.visible = YES;
    // Show Toolbar round-trips, and still works when the toolbar was hidden behind this module's back (the
    // title bar's own Hide Toolbar leaves the stored setting saying "shown").
    [self performCommand:NPPCmdViewToolbarShow context:noContext];
    expect(!bar.toolbar.isVisible, @"Show Toolbar did not hide the toolbar");
    expect(NPPPreferences.shared.toolbarHidden, @"Show Toolbar did not store the new state");
    [self performCommand:NPPCmdViewToolbarShow context:noContext];
    expect(bar.toolbar.isVisible, @"Show Toolbar did not toggle back");
    expect(!NPPPreferences.shared.toolbarHidden, @"Show Toolbar did not store the state it toggled back to");
    bar.appliedHidden = NO;                         // as the title bar's own Hide Toolbar leaves things:
    NPPPreferences.shared.toolbarHidden = NO;       // the setting says "shown"…
    bar.toolbar.visible = NO;                       // …while the toolbar is not
    [self performCommand:NPPCmdViewToolbarShow context:noContext];
    expect(bar.toolbar.isVisible, @"Show Toolbar must show a toolbar the title bar hid");
    [bar setHidden:wasHidden];
    bar.toolbar.visible = wasVisible;
    if (standInWindow) { standInWindow.toolbar = nil; [standInWindow orderOut:nil]; }
    bar.toolbar = liveToolbar;

    // 8. the attach guard. Handing one NSToolbar to a second window takes it off the first and leaves both windows
    // reporting the same toolbar, so a second controller (the throwaway one +[NPPEditorWindowController
    // selfCheckFailures] builds) must not collect it — while a main window that was closed and replaced must.
    NSWindow *held = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 120, 80)
                                                 styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 120, 80)
                                                 styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    expect(NPPToolBarShouldAttachTo(held, nil), @"the first window should get the toolbar");
    expect(NPPToolBarShouldAttachTo(held, held), @"the same window again should keep the toolbar");
    expect(NPPToolBarShouldAttachTo(other, held), @"a replacement for a closed window should get the toolbar");
    [held orderBack:nil];
    expect(held.isVisible, @"self-check bug: -orderBack: left the window off screen, so the guard is untested");
    expect(!NPPToolBarShouldAttachTo(other, held), @"the toolbar must not walk off a window that is still on screen");
    [held orderOut:nil];

    if (savedButtons) [d setObject:savedButtons forKey:kButtonsKey]; else [d removeObjectForKey:kButtonsKey];
    NPPPreferences.shared.toolbarIconSet = savedSet;
    return fails;
}

@end
