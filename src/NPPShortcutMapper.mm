// NPPShortcutMapper.mm — see header.
#import "NPPShortcutMapper.h"
#import "NPPCommands.h"

// ponytail: overrides are keyed by command tag, like upstream keys shortcuts.xml by menu id — renumbering an
// NPPCmd therefore moves a stored shortcut onto whatever command inherits the number. The tags in NPPCommands.h are
// explicit and stable; key by a command name string if that ever stops being true.
static NSString *const kOverridesKey = @"NPPShortcutOverrides";   // { "<tag>": "Ctrl+Shift+K" }, "" = no shortcut

// Tabs, like upstream's ShortcutMapper (Main menu / Macros / Run commands; plugin and Scintilla tabs have no
// equivalent here). Everything that is not a saved macro or a saved Run command is "Main menu".
enum { kTabMain = 0, kTabMacros, kTabRun, kTabCount };
static NSInteger NPPTabForTag(NSInteger tag) {
    if (tag >= NPPCmdMacroSavedBase && tag < NPPCmdMacroSavedBase + 100) return kTabMacros;
    if (tag >= NPPCmdRunSavedBase && tag < NPPCmdRunSavedBase + 100) return kTabRun;
    return kTabMain;
}

#pragma mark - Key names

// Keys that have no printable character. ponytail: named in words ("F5", "PageUp") in the glyph form too, where
// macOS would draw ⇞/⌫ — one table instead of two, and the persisted string stays typeable. Add a glyph column
// here if the display ever needs to match Apple's exactly.
static NSDictionary<NSString *, NSString *> *NPPNamedKeys(void) {
    static NSDictionary *named;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        void (^add)(NSString *, unichar) = ^(NSString *name, unichar c) { m[name] = [NSString stringWithCharacters:&c length:1]; };
        add(@"Space", ' '); add(@"Tab", '\t'); add(@"Enter", '\r'); add(@"Backspace", '\b'); add(@"Esc", 0x1B);
        add(@"Delete", NSDeleteFunctionKey); add(@"Insert", NSInsertFunctionKey);
        add(@"Up", NSUpArrowFunctionKey); add(@"Down", NSDownArrowFunctionKey);
        add(@"Left", NSLeftArrowFunctionKey); add(@"Right", NSRightArrowFunctionKey);
        add(@"Home", NSHomeFunctionKey); add(@"End", NSEndFunctionKey);
        add(@"PageUp", NSPageUpFunctionKey); add(@"PageDown", NSPageDownFunctionKey);
        for (unichar i = 0; i < 15; i++) add([NSString stringWithFormat:@"F%u", (unsigned)i + 1], (unichar)(NSF1FunctionKey + i));
        named = m;
    });
    return named;
}

// "f5" / "return" / "pgdn" -> the key equivalent string; nil when the name is not one we can bind.
static NSString *NPPKeyForName(NSString *name) {
    static NSDictionary *byLowercaseName;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        [NPPNamedKeys() enumerateKeysAndObjectsUsingBlock:^(NSString *n, NSString *k, BOOL *stop) { m[n.lowercaseString] = k; }];
        // Spellings a user (or an imported shortcuts.xml) is likely to type.
        for (NSArray *pair in @[@[@"return", @"enter"], @[@"escape", @"esc"], @[@"del", @"delete"], @[@"ins", @"insert"],
                                @[@"pgup", @"pageup"], @[@"pgdn", @"pagedown"], @[@"page up", @"pageup"],
                                @[@"page down", @"pagedown"], @[@"back", @"backspace"], @[@"bksp", @"backspace"]])
            m[pair[0]] = m[pair[1]];
        byLowercaseName = m;
    });
    return byLowercaseName[name.lowercaseString];
}

// The inverse: key equivalent -> display name ("F5", "Tab", "K").
static NSString *NPPNameForKey(NSString *key) {
    if (key.length == 0) return @"";
    static NSDictionary *byKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        [NPPNamedKeys() enumerateKeysAndObjectsUsingBlock:^(NSString *n, NSString *k, BOOL *stop) { m[k] = n; }];
        byKey = m;
    });
    return byKey[key] ?: key.uppercaseString;
}

// Modifier token -> flag, for the "Ctrl+Alt+..." form. 0 means "not a modifier".
static NSEventModifierFlags NPPModifierForToken(NSString *token) {
    NSString *t = token.lowercaseString;
    if ([t isEqualToString:@"ctrl"] || [t isEqualToString:@"control"]) return NSEventModifierFlagControl;
    if ([t isEqualToString:@"alt"] || [t isEqualToString:@"opt"] || [t isEqualToString:@"option"]) return NSEventModifierFlagOption;
    if ([t isEqualToString:@"shift"]) return NSEventModifierFlagShift;
    if ([t isEqualToString:@"cmd"] || [t isEqualToString:@"command"] || [t isEqualToString:@"meta"]) return NSEventModifierFlagCommand;
    return 0;
}

static NSEventModifierFlags NPPModifierForGlyph(unichar c) {
    switch (c) {
        case 0x2303: return NSEventModifierFlagControl;   // ⌃
        case 0x2325: return NSEventModifierFlagOption;    // ⌥
        case 0x21E7: return NSEventModifierFlagShift;     // ⇧
        case 0x2318: return NSEventModifierFlagCommand;   // ⌘
        default:     return 0;
    }
}

static const NSEventModifierFlags kSupportedModifiers =
    NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagCommand;

#pragma mark - One row

// A bindable command, or (tag == 0) a menu item whose key equivalent is not ours to change but must still be
// counted as taken — Quit, Redo, the standard text-editing items AppKit installs.
@interface NPPShortcutEntry : NSObject
@property (nonatomic) NSInteger tag;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *category;          // the menu it lives in ("Edit", "Macro", …)
@property (nonatomic, copy) NSString *shortcut;          // effective, portable form
@property (nonatomic, copy) NSString *defaultShortcut;   // what the menu was built with
@property (nonatomic, readonly) BOOL isOverridden;
@end

@implementation NPPShortcutEntry
- (BOOL)isOverridden { return ![self.shortcut isEqualToString:self.defaultShortcut]; }
@end

#pragma mark - Filter

// Upstream's filter box (ShortcutMapper.cpp, isFilterValid): the text is split on whitespace and every word has to
// appear, case-insensitively, in the command's name or in its shortcut — so "sort ctrl" finds Sort Lines only when
// it is on a Ctrl binding. The category counts here too, standing in for upstream's plugin-name column.
static NSArray<NSString *> *NPPFilterWords(NSString *filter) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *w in [(filter ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (w.length) [words addObject:w.lowercaseString];
    return words;
}

// ponytail: matched against the portable spelling ("Shift+Cmd+K"), which is the one a Notepad++ user types, not the
// glyphs the table draws. Append the glyph form to the haystack if anyone ever tries to filter by pasting ⌘.
static BOOL NPPEntryMatchesFilterWords(NPPShortcutEntry *e, NSArray<NSString *> *words) {
    if (words.count == 0) return YES;
    NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", e.name, e.category, e.shortcut].lowercaseString;
    for (NSString *w in words)
        if ([hay rangeOfString:w].location == NSNotFound) return NO;
    return YES;
}

#pragma mark - Mapper

@interface NPPShortcutMapper () <NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate>
@end

@implementation NPPShortcutMapper {
    NSMutableDictionary<NSNumber *, NSString *> *_builtinDefaults;   // tag -> shortcut the menu was built with
    NSDictionary<NSString *, NSString *> *_overridesCache;           // nil = re-read NSUserDefaults on next ask
    BOOL _observingMenus;                                            // the context notification can fire more than once
    NSArray<NPPShortcutEntry *> *_entries;                           // last walk, all tabs + the reserved items
    NSArray<NSArray<NPPShortcutEntry *> *> *_allTabEntries;          // per tab, before the filter
    NSArray<NSArray<NPPShortcutEntry *> *> *_tabEntries;             // per tab, what the tables show
    NSWindow *_window;
    NSTabView *_tabView;
    NSArray<NSTableView *> *_tables;
    NSSearchField *_filterField;
    NSTextField *_infoLabel;
    BOOL _applying;                                                  // re-entrancy guard for the menu observers
    __weak id<NPPCommandContext> _context;
}

+ (instancetype)shared {
    static NPPShortcutMapper *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPShortcutMapper alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) _builtinDefaults = [NSMutableDictionary dictionary];
    return self;
}

// The overrides have to be put back on the menu at every launch, and again every time NPPAppDelegate rebuilds a
// dynamic menu (Macro, Run, Language) from its menu delegate.
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NPPCommandContextReadyNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) {
        [[NPPShortcutMapper shared] contextDidBecomeReady:n.object];
    }];
}

- (void)contextDidBecomeReady:(id<NPPCommandContext>)context {
    _context = context;
    if (!_observingMenus) {   // posted once per window controller; a second window must not double the observers
        _observingMenus = YES;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSMenuDidAddItemNotification, NSMenuDidChangeItemNotification,
                                          NSMenuDidBeginTrackingNotification])
            [nc addObserver:self selector:@selector(menuDidChange:) name:name object:nil];
    }
    if (NSApp.mainMenu) [self applyOverridesToMenu:NSApp.mainMenu];
}

// Re-applied synchronously, and it has to be: AppKit asks NPPAppDelegate's menu delegate to rebuild the dynamic
// Macro / Run / Language menus *while* it matches a key equivalent, so a deferred apply would miss the very
// keystroke that caused the rebuild. Rebuilding the Language menu is ~90 separate NSMenuDidAddItem posts, so an
// add/change is applied to just the one item the notification names (userInfo NSMenuItemIndex) — otherwise this is
// quadratic in the item count on every keystroke that reaches the menu bar (measured: 17 ms a rebuild against
// 0.8 ms). Begin-tracking has no index and walks the menu, once per menu open.
// ponytail: the per-item path assumes the tag is on the item by the time a notification names it — true because
// NPPAppDelegate's I() sets the tag and then the modifier mask, and the mask write is what posts. The ceiling is
// that an item built with no mask write of its own (key equivalent plus exactly Cmd, the I() default) posts
// nothing after its tag, so a rebuilt one would keep its built-in shortcut until the menu is next opened. No
// dynamic menu builds items that way today and "rebuild.item-notifies-after-its-tag-is-set" fails if that changes.
// Upgrade: have NPPAppDelegate call -applyOverridesToMenu: at the end of each rebuild, which needs that file.
- (void)menuDidChange:(NSNotification *)note {
    if (_applying) return;
    NSMenu *menu = note.object;
    if (![menu isKindOfClass:NSMenu.class]) return;
    NSMenu *root = menu;
    while (root.supermenu) root = root.supermenu;
    if (root != NSApp.mainMenu) return;   // context menus, panel action menus, the self-check's throwaway menu

    NSNumber *index = note.userInfo[@"NSMenuItemIndex"];   // documented key; no exported constant for it
    if ([index isKindOfClass:NSNumber.class] && index.integerValue >= 0 && index.integerValue < menu.numberOfItems) {
        NSMenuItem *item = [menu itemAtIndex:index.integerValue];
        if (!item.submenu) {   // a whole submenu arriving at once still needs the full walk
            _applying = YES;
            [self applyToItem:item];
            _applying = NO;
            return;
        }
    }
    [self applyOverridesToMenu:menu];
}

#pragma mark - Shortcut strings

+ (NSString *)stringForKey:(NSString *)key modifiers:(NSEventModifierFlags)mods glyphs:(BOOL)glyphs {
    if (key.length == 0) return @"";
    // An uppercase key equivalent is Shift on macOS; normalise so "S"+Cmd|Shift and "s"+Cmd|Shift are one binding.
    if (key.length == 1 && [key isEqualToString:key.uppercaseString] && ![key isEqualToString:key.lowercaseString]) {
        mods |= NSEventModifierFlagShift;
        key = key.lowercaseString;
    }
    mods &= kSupportedModifiers;
    NSMutableString *s = [NSMutableString string];
    if (mods & NSEventModifierFlagControl) [s appendString:glyphs ? @"⌃" : @"Ctrl+"];
    if (mods & NSEventModifierFlagOption)  [s appendString:glyphs ? @"⌥" : @"Alt+"];
    if (mods & NSEventModifierFlagShift)   [s appendString:glyphs ? @"⇧" : @"Shift+"];
    if (mods & NSEventModifierFlagCommand) [s appendString:glyphs ? @"⌘" : @"Cmd+"];
    [s appendString:NPPNameForKey(key)];
    return s;
}

+ (BOOL)parseShortcut:(NSString *)string key:(NSString **)outKey modifiers:(NSEventModifierFlags *)outMods {
    NSEventModifierFlags mods = 0;
    NSString *s = [(string ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    NSUInteger i = 0;                                  // glyph form: ⌃⌥⇧⌘ then the key name
    while (i < s.length) {
        NSEventModifierFlags f = NPPModifierForGlyph([s characterAtIndex:i]);
        if (!f) break;
        mods |= f;
        i++;
    }
    s = [s substringFromIndex:i];

    NSString *token = nil;
    if ([s isEqualToString:@"+"]) {                    // the key is '+' and there is nothing else
        token = s;
        s = @"";
    } else if ([s hasSuffix:@"+"] && s.length > 1) {   // "Cmd++": the trailing '+' is the key, not a separator
        token = @"+";
        s = [s substringToIndex:s.length - 1];
    }
    for (NSString *raw in [s componentsSeparatedByString:@"+"]) {
        NSString *part = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (part.length == 0) continue;
        NSEventModifierFlags f = NPPModifierForToken(part);
        if (f) { mods |= f; continue; }
        if (token) return NO;                          // two keys in one shortcut
        token = part;
    }

    NSString *key;
    if (token.length == 0) {
        if (mods != 0) return NO;                      // modifiers without a key
        key = @"";
    } else if (token.length == 1) {
        // Case carries no meaning in a shortcut *string* — the key is always spelled uppercase for display, and
        // Shift is spelled out. (Uppercase does mean Shift in a raw NSMenuItem key equivalent; that is normalised
        // in stringForKey:, on the way in from the menu.)
        key = token.lowercaseString;
    } else {
        key = NPPKeyForName(token);
        if (!key) return NO;
    }
    if (outKey) *outKey = key;
    if (outMods) *outMods = mods & kSupportedModifiers;
    return YES;
}

// Both spellings reduced to one canonical string, or nil when the input is malformed.
+ (NSString *)normalizedShortcut:(NSString *)s {
    NSString *key = @"";
    NSEventModifierFlags mods = 0;
    if (![self parseShortcut:s key:&key modifiers:&mods]) return nil;
    return [self stringForKey:key modifiers:mods glyphs:NO];
}

+ (BOOL)shortcut:(NSString *)a conflictsWithShortcut:(NSString *)b {
    NSString *na = [self normalizedShortcut:a];
    return na.length > 0 && [na isEqualToString:[self normalizedShortcut:b]];
}

// Upstream refuses a letter, digit, Space, Backspace or Return with neither Ctrl nor Alt (shortcut.h,
// Shortcut::isValid) — a bare one of those is a character the editor has to be able to type. The same hole is
// worse on macOS: an NSMenuItem with key equivalent "k" and an empty modifier mask swallows every "k" the user
// types, everywhere, and only this window could undo it. So the rule here is upstream's, over Cmd/Ctrl/Option.
// Shift does not count — ⇧K is still the K key.
static BOOL NPPKeyNeedsModifier(NSString *key) {
    // One character below AppKit's 0xF700 function-key block is something the editor has to be able to type:
    // letters and digits, punctuation, and Space / Tab / Return / Backspace / Esc. From 0xF700 up it is a key and
    // not a character — F1…F15, the arrows, Home/End/PageUp/PageDown, Insert, forward Delete — and those stay
    // bindable bare, as upstream leaves them and as the port's own F2 = Next Bookmark needs.
    // Esc is the one that departs from upstream (which allows it bare): on macOS it dismisses autocompletion and
    // sheets, so taking it for a menu command is the same kind of trap as taking a letter.
    return key.length == 1 && [key characterAtIndex:0] < 0xF700;
}

+ (NSString *)problemWithShortcut:(NSString *)shortcut {
    NSString *key = @"";
    NSEventModifierFlags mods = 0;
    if (![self parseShortcut:shortcut key:&key modifiers:&mods])
        return [NSString stringWithFormat:NSLocalizedString(@"\"%@\" is not a shortcut that can be bound.", nil),
                                          shortcut ?: @""];
    if (key.length == 0) return nil;   // "no shortcut" is always fine
    if (NPPKeyNeedsModifier(key) &&
        !(mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)))
        return [NSString stringWithFormat:
            NSLocalizedString(@"%@ needs Command, Control or Option — without one it would stop \"%@\" being typed.", nil),
            [self stringForKey:key modifiers:mods glyphs:YES], NPPNameForKey(key)];
    return nil;
}

#pragma mark - Overrides

// Read through a cache. Every menu item on every walk asks for its override, and AppKit walks the whole main menu
// while it matches a key equivalent — hitting NSUserDefaults thousands of times per keystroke is not affordable.
// We are the only writer, so the cache is only dropped on our own writes and whenever the window is (re)shown.
// ponytail: that leaves an out-of-process `defaults write` unnoticed until the mapper window is next opened, and
// a second NPPShortcutMapper instance holding its own stale cache (only the self-check makes one; the app uses
// +shared). Upgrade: observe NSUserDefaultsDidChangeNotification and drop the cache there.
- (NSDictionary<NSString *, NSString *> *)storedOverrides {
    if (!_overridesCache) {
        NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:kOverridesKey];
        _overridesCache = [d isKindOfClass:NSDictionary.class] ? [d copy] : @{};
    }
    return _overridesCache;
}

- (NSString *)overrideForTag:(NSInteger)tag {
    NSString *s = [self storedOverrides][@(tag).stringValue];
    if (![s isKindOfClass:NSString.class]) return nil;
    // A stored override is not necessarily one we wrote — the plist is a file a user (or an older build) can edit,
    // and a bad one must not be able to make a key untypeable or to blank an item's shortcut by being unparseable.
    return [NPPShortcutMapper problemWithShortcut:s] ? nil : s;
}

- (void)setOverride:(NSString *)shortcut forTag:(NSInteger)tag {
    NSMutableDictionary *d = [[self storedOverrides] mutableCopy];
    if (shortcut) d[@(tag).stringValue] = shortcut; else [d removeObjectForKey:@(tag).stringValue];
    _overridesCache = nil;
    [NSUserDefaults.standardUserDefaults setObject:d forKey:kOverridesKey];
}

- (void)removeAllOverrides {
    _overridesCache = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kOverridesKey];
}

#pragma mark - Menu walking

- (NSString *)shortcutOfItem:(NSMenuItem *)item {
    return [NPPShortcutMapper stringForKey:item.keyEquivalent modifiers:item.keyEquivalentModifierMask glyphs:NO];
}

// Capture-then-resolve for one tag. The first sighting records the shortcut the menu was built with, which is why
// capture always has to precede apply — a rebuilt dynamic menu arrives with its built-in binding, not ours.
- (NSString *)effectiveShortcutForTag:(NSInteger)tag ofItem:(NSMenuItem *)item builtin:(NSString **)outBuiltin {
    NSString *builtin = _builtinDefaults[@(tag)];
    if (!builtin) {
        builtin = [self shortcutOfItem:item];
        _builtinDefaults[@(tag)] = builtin;
    }
    if (outBuiltin) *outBuiltin = builtin;
    return [self overrideForTag:tag] ?: builtin;
}

// One item, straight off a menu notification — the caller owns the _applying guard.
- (void)applyToItem:(NSMenuItem *)item {
    if (item.isSeparatorItem || item.tag == 0 || !item.action) return;
    [self applyShortcut:[self effectiveShortcutForTag:item.tag ofItem:item builtin:NULL] toItem:item];
}

// The single pass that does everything: capture the built-in default for tags we have not seen, apply the effective
// shortcut when `apply`, and collect the rows when `out` is given.
- (void)walkMenu:(NSMenu *)menu category:(NSString *)category apply:(BOOL)apply
             out:(NSMutableArray<NPPShortcutEntry *> *)out seen:(NSMutableSet<NSNumber *> *)seen {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        if (item.submenu) {
            [self walkMenu:item.submenu category:(category ?: item.title) apply:apply out:out seen:seen];
            continue;
        }
        NSInteger tag = item.tag;
        if (tag == 0) {
            // Not ours to rebind, but its key equivalent is taken (Quit, Redo, …) — the conflict scan needs it.
            if (out && item.keyEquivalent.length && item.action) {
                NPPShortcutEntry *e = [NPPShortcutEntry new];
                e.tag = 0;
                e.name = item.title ?: @"";
                e.category = category ?: @"";
                e.shortcut = e.defaultShortcut = [self shortcutOfItem:item];
                [out addObject:e];
            }
            continue;
        }
        if (!item.action) continue;

        NSString *builtin = nil;
        NSString *effective = [self effectiveShortcutForTag:tag ofItem:item builtin:&builtin];
        if (apply) [self applyShortcut:effective toItem:item];
        if (out && ![seen containsObject:@(tag)]) {
            [seen addObject:@(tag)];
            NPPShortcutEntry *e = [NPPShortcutEntry new];
            e.tag = tag;
            e.name = item.title ?: @"";
            e.category = category ?: @"";
            e.shortcut = effective;
            e.defaultShortcut = builtin;
            [out addObject:e];
        }
    }
}

- (void)applyShortcut:(NSString *)shortcut toItem:(NSMenuItem *)item {
    NSString *key = @"";
    NSEventModifierFlags mods = 0;
    if (![NPPShortcutMapper parseShortcut:shortcut key:&key modifiers:&mods]) return;   // corrupt defaults: leave it alone
    if (key.length == 0) mods = 0;
    if ([item.keyEquivalent isEqualToString:key] && item.keyEquivalentModifierMask == mods) return;
    item.keyEquivalent = key;
    item.keyEquivalentModifierMask = mods;
}

- (void)applyOverridesToMenu:(NSMenu *)menu {
    if (!menu || _applying) return;
    _applying = YES;                 // our own writes post NSMenuDidChangeItemNotification; don't chase them
    [self walkMenu:menu category:nil apply:YES out:nil seen:nil];
    _applying = NO;
}

- (NSArray<NPPShortcutEntry *> *)entriesInMenu:(NSMenu *)menu {
    NSMutableArray *out = [NSMutableArray array];
    [self walkMenu:menu category:nil apply:NO out:out seen:[NSMutableSet set]];
    return out;
}

// Every command already on this binding. More than one is possible: the reserved AppKit items are all tag 0, and a
// hand-edited plist can double-book. Taking a shortcut has to free all of them, or the user assigns and still loses.
- (NSArray<NPPShortcutEntry *> *)entriesIn:(NSArray<NPPShortcutEntry *> *)entries
                           conflictingWith:(NSString *)shortcut excludingTag:(NSInteger)tag {
    NSMutableArray *out = [NSMutableArray array];
    for (NPPShortcutEntry *e in entries)
        if ((e.tag == 0 || e.tag != tag) && [NPPShortcutMapper shortcut:e.shortcut conflictsWithShortcut:shortcut])
            [out addObject:e];
    return out;
}

- (NSArray<NPPShortcutEntry *> *)entriesConflictingWith:(NSString *)shortcut excludingTag:(NSInteger)tag {
    return [self entriesIn:_entries conflictingWith:shortcut excludingTag:tag];
}

#pragma mark - Window

- (void)showWindowWithContext:(id<NPPCommandContext>)context {
    if (context) _context = context;
    if (!_window) [self buildWindow];
    [self reload];
    [_window makeKeyAndOrderFront:nil];
}

- (void)buildWindow {
    const CGFloat W = 700, H = 480;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                               backing:NSBackingStoreBuffered defer:NO];
    w.title = NSLocalizedString(@"Shortcut Mapper", nil);
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(560, 360);
    [w center];
    NSView *content = w.contentView;

    // Upstream's filter box, in the place macOS puts one: above the list, filtering every tab at once.
    _filterField = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, H - 34, 260, 22)];
    _filterField.placeholderString = NSLocalizedString(@"Filter commands", nil);
    _filterField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    _filterField.target = self;
    _filterField.action = @selector(filterChanged:);
    ((NSSearchFieldCell *)_filterField.cell).sendsWholeSearchString = NO;   // filter as you type, like the panels
    [content addSubview:_filterField];

    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(12, 88, W - 24, H - 134)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSMutableArray *tables = [NSMutableArray array];
    NSArray<NSString *> *titles = @[NSLocalizedString(@"Main menu", nil), NSLocalizedString(@"Macros", nil),
                                    NSLocalizedString(@"Run commands", nil)];
    for (NSInteger i = 0; i < kTabCount; i++) {
        NSTabViewItem *tab = [[NSTabViewItem alloc] initWithIdentifier:@(i)];
        tab.label = titles[(NSUInteger)i];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, W - 48, H - 140)];
        scroll.hasVerticalScroller = YES;
        scroll.borderType = NSBezelBorder;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
        table.tag = i;
        for (NSArray *spec in @[@[@"name", NSLocalizedString(@"Name", nil), @280],
                                @[@"shortcut", NSLocalizedString(@"Shortcut", nil), @160],
                                @[@"category", NSLocalizedString(@"Category", nil), @160]]) {
            NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
            col.title = spec[1];
            col.width = [spec[2] doubleValue];
            [table addTableColumn:col];
        }
        table.dataSource = self;
        table.delegate = self;
        table.usesAlternatingRowBackgroundColors = YES;
        table.allowsMultipleSelection = NO;
        table.target = self;
        table.doubleAction = @selector(modifyClicked:);
        scroll.documentView = table;
        tab.view = scroll;
        [tabs addTabViewItem:tab];
        [tables addObject:table];
    }
    _tables = tables;
    _tabView = tabs;
    tabs.delegate = self;
    [content addSubview:tabs];

    NSButton *(^button)(NSString *, CGFloat, CGFloat, SEL) = ^(NSString *title, CGFloat x, CGFloat width, SEL sel) {
        NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
        b.frame = NSMakeRect(x, 48, width, 32);
        b.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
        [content addSubview:b];
        return b;
    };
    button(NSLocalizedString(@"Modify…", nil), 12, 100, @selector(modifyClicked:));
    button(NSLocalizedString(@"Clear", nil), 118, 90, @selector(clearClicked:));
    button(NSLocalizedString(@"Restore Default", nil), 214, 140, @selector(restoreDefaultClicked:));
    NSButton *all = button(NSLocalizedString(@"Restore All Defaults", nil), 360, 170, @selector(restoreAllClicked:));
    all.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;

    _infoLabel = [NSTextField labelWithString:@""];
    _infoLabel.frame = NSMakeRect(12, 16, W - 130, 17);
    _infoLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _infoLabel.textColor = NSColor.secondaryLabelColor;
    _infoLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:_infoLabel];

    NSButton *close = [NSButton buttonWithTitle:NSLocalizedString(@"Close", nil) target:w action:@selector(performClose:)];
    close.frame = NSMakeRect(W - 102, 12, 90, 32);
    close.keyEquivalent = @"\033";
    close.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:close];

    w.initialFirstResponder = _filterField;   // open the mapper and start typing the command's name
    _window = w;
}

- (void)reload {
    _overridesCache = nil;   // the one place an out-of-process `defaults write` is cheap to notice
    _entries = [self entriesInMenu:NSApp.mainMenu];
    NSMutableArray *byTab = [NSMutableArray array];
    for (NSInteger i = 0; i < kTabCount; i++) [byTab addObject:[NSMutableArray array]];
    for (NPPShortcutEntry *e in _entries) {
        if (e.tag == 0) continue;                       // reserved rows exist for conflict detection only
        [byTab[(NSUInteger)NPPTabForTag(e.tag)] addObject:e];
    }
    _allTabEntries = byTab;
    [self applyFilter];
}

// The filter never touches _entries: a hidden command still owns its shortcut, so the conflict scan has to see it.
- (void)applyFilter {
    NSArray<NSString *> *words = NPPFilterWords(_filterField.stringValue);
    NSMutableArray *byTab = [NSMutableArray array];
    for (NSArray<NPPShortcutEntry *> *tab in _allTabEntries) {
        if (words.count == 0) { [byTab addObject:tab]; continue; }
        NSMutableArray *keep = [NSMutableArray array];
        for (NPPShortcutEntry *e in tab)
            if (NPPEntryMatchesFilterWords(e, words)) [keep addObject:e];
        [byTab addObject:keep];
    }
    _tabEntries = byTab;
    for (NSTableView *t in _tables) [t reloadData];
    [self updateInfoLabel];
}

- (void)filterChanged:(id)sender { [self applyFilter]; }

- (NSArray<NPPShortcutEntry *> *)entriesForTab:(NSInteger)tab {
    if (tab < 0 || tab >= (NSInteger)_tabEntries.count) return @[];
    return _tabEntries[(NSUInteger)tab];
}

- (NSTableView *)selectedTable {
    NSInteger i = [_tabView indexOfTabViewItem:_tabView.selectedTabViewItem];
    return (i >= 0 && i < (NSInteger)_tables.count) ? _tables[(NSUInteger)i] : _tables.firstObject;
}

- (NPPShortcutEntry *)selectedEntry {
    NSTableView *t = [self selectedTable];
    NSArray *rows = [self entriesForTab:t.tag];
    NSInteger row = t.selectedRow;
    return (row >= 0 && row < (NSInteger)rows.count) ? rows[(NSUInteger)row] : nil;
}

- (void)updateInfoLabel {
    NPPShortcutEntry *e = [self selectedEntry];
    if (!e) {
        BOOL emptied = NPPFilterWords(_filterField.stringValue).count > 0 &&
                       [self entriesForTab:[self selectedTable].tag].count == 0;
        _infoLabel.stringValue = emptied ? NSLocalizedString(@"No command matches the filter.", nil)
                                         : NSLocalizedString(@"Select a command to change its shortcut.", nil);
        return;
    }
    NSArray<NPPShortcutEntry *> *clashes = [self entriesConflictingWith:e.shortcut excludingTag:e.tag];
    NPPShortcutEntry *clash = clashes.firstObject;
    if (!clash) {
        _infoLabel.stringValue = NSLocalizedString(@"No shortcut conflicts for this item.", nil);
    } else if (clashes.count == 1) {
        _infoLabel.stringValue = [NSString stringWithFormat:
            NSLocalizedString(@"Conflict: \"%@\" (%@) uses the same shortcut.", nil), clash.name, clash.category];
    } else {
        _infoLabel.stringValue = [NSString stringWithFormat:
            NSLocalizedString(@"Conflict: \"%@\" (%@) and %lu other commands use the same shortcut.", nil),
            clash.name, clash.category, (unsigned long)(clashes.count - 1)];
    }
}

#pragma mark - NSTableView / NSTabView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[self entriesForTab:tableView.tag].count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSArray<NPPShortcutEntry *> *rows = [self entriesForTab:tableView.tag];
    if (row < 0 || row >= (NSInteger)rows.count) return @"";
    NPPShortcutEntry *e = rows[(NSUInteger)row];
    if ([col.identifier isEqualToString:@"name"]) return e.name;
    if ([col.identifier isEqualToString:@"category"]) return e.category;
    // The Shortcut column is the one people read: macOS notation, with a marker for "not the default any more".
    NSString *glyphs = @"";
    NSString *k = @"";
    NSEventModifierFlags m = 0;
    if ([NPPShortcutMapper parseShortcut:e.shortcut key:&k modifiers:&m])
        glyphs = [NPPShortcutMapper stringForKey:k modifiers:m glyphs:YES];
    if (glyphs.length == 0) glyphs = NSLocalizedString(@"None", nil);
    return e.isOverridden ? [glyphs stringByAppendingString:@" *"] : glyphs;
}

- (void)tableViewSelectionDidChange:(NSNotification *)note { [self updateInfoLabel]; }
- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item { [self updateInfoLabel]; }

#pragma mark - Actions

- (void)clearClicked:(id)sender {
    NPPShortcutEntry *e = [self selectedEntry];
    if (!e) { NSBeep(); return; }
    [self commitShortcut:@"" forEntry:e];
}

- (void)restoreDefaultClicked:(id)sender {
    NPPShortcutEntry *e = [self selectedEntry];
    if (!e) { NSBeep(); return; }
    [self setOverride:nil forTag:e.tag];
    [self applyOverridesToMenu:NSApp.mainMenu];
    [self reload];
}

- (void)restoreAllClicked:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NSLocalizedString(@"Restore all default shortcuts?", nil);
    alert.informativeText = NSLocalizedString(@"Every shortcut you changed goes back to the one Notepad++ ships with.", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"Restore All", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    __weak __typeof__(self) weakSelf = self;
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || response != NSAlertFirstButtonReturn) return;
        [self_ removeAllOverrides];
        [self_ applyOverridesToMenu:NSApp.mainMenu];
        [self_ reload];
    }];
}

// The upstream shortcut editor: three (here four) modifier checkboxes and a key.
- (void)modifyClicked:(id)sender {
    NPPShortcutEntry *e = [self selectedEntry];
    if (!e) { NSBeep(); return; }

    NSString *key = @"";
    NSEventModifierFlags mods = 0;
    [NPPShortcutMapper parseShortcut:e.shortcut key:&key modifiers:&mods];

    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 88)];
    NSMutableArray<NSButton *> *boxes = [NSMutableArray array];
    NSArray *specs = @[@[@"⌃ Control", @(NSEventModifierFlagControl)], @[@"⌥ Option", @(NSEventModifierFlagOption)],
                       @[@"⇧ Shift", @(NSEventModifierFlagShift)], @[@"⌘ Command", @(NSEventModifierFlagCommand)]];
    for (NSUInteger i = 0; i < specs.count; i++) {
        NSButton *b = [NSButton checkboxWithTitle:specs[i][0] target:nil action:nil];
        b.frame = NSMakeRect(4 + 95 * (CGFloat)i, 60, 95, 20);
        b.tag = [specs[i][1] integerValue];
        b.state = (mods & (NSEventModifierFlags)b.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [box addSubview:b];
        [boxes addObject:b];
    }
    NSTextField *label = [NSTextField labelWithString:NSLocalizedString(@"Key:", nil)];
    label.frame = NSMakeRect(4, 24, 40, 17);
    [box addSubview:label];
    NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(46, 20, 150, 24)];
    combo.completes = YES;
    [combo addItemsWithObjectValues:[NPPNamedKeys().allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]];
    combo.stringValue = NPPNameForKey(key);
    [box addSubview:combo];
    NSTextField *hint = [NSTextField labelWithString:NSLocalizedString(@"a single character, or a key name such as F5", nil)];
    hint.frame = NSMakeRect(202, 24, 174, 32);
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    ((NSTextFieldCell *)hint.cell).wraps = YES;
    [box addSubview:hint];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"Shortcut for \"%@\"", nil), e.name];
    alert.informativeText = NSLocalizedString(@"Leave the key empty to give this command no shortcut.", nil);
    alert.accessoryView = box;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    alert.window.initialFirstResponder = combo;

    __weak __typeof__(self) weakSelf = self;
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || response != NSAlertFirstButtonReturn) return;
        NSString *typed = [combo.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableString *shortcut = [NSMutableString string];
        for (NSButton *b in boxes)
            if (b.state == NSControlStateValueOn)
                [shortcut appendFormat:@"%@+", (NSEventModifierFlags)b.tag == NSEventModifierFlagControl ? @"Ctrl" :
                                              (NSEventModifierFlags)b.tag == NSEventModifierFlagOption ? @"Alt" :
                                              (NSEventModifierFlags)b.tag == NSEventModifierFlagShift ? @"Shift" : @"Cmd"];
        if (typed.length == 0) [shortcut setString:@""];   // no key = no shortcut, whatever the checkboxes say
        else [shortcut appendString:typed];
        // Off the sheet's own completion handler: commitShortcut: puts up a sheet of its own (invalid combination,
        // or a conflict to confirm) and AppKit drops a sheet begun while the previous one is still going away.
        dispatch_async(dispatch_get_main_queue(), ^{ [self_ commitShortcut:shortcut forEntry:e]; });
    }];
}

- (void)reportProblem:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = message;
    if (_window) [alert beginSheetModalForWindow:_window completionHandler:nil];
    else [alert runModal];
}

// Assign, after the two checks upstream does: the combination has to be a legal accelerator at all, and it has to
// be free — else refuse, or clear the other commands and take it.
- (void)commitShortcut:(NSString *)shortcut forEntry:(NPPShortcutEntry *)entry {
    NSString *problem = [NPPShortcutMapper problemWithShortcut:shortcut];
    if (problem) { [self reportProblem:problem]; return; }

    NSArray<NPPShortcutEntry *> *clashes = [self entriesConflictingWith:shortcut excludingTag:entry.tag];
    if (clashes.count == 0) { [self assignShortcut:shortcut toTag:entry.tag]; return; }

    // A key equivalent this module does not own (Quit, Redo, the AppKit-supplied editing items) can only be
    // reported, never taken — clearing it would mean editing the menu behind NPPAppDelegate's back.
    NPPShortcutEntry *reserved = nil;
    for (NPPShortcutEntry *e in clashes) if (e.tag == 0) { reserved = e; break; }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    NSString *pretty = [NPPShortcutMapper normalizedShortcut:shortcut] ?: shortcut;
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"%@ is already used by \"%@\".", nil),
                                                   pretty, clashes.firstObject.name];
    if (reserved) {
        alert.informativeText = [NSString stringWithFormat:
            NSLocalizedString(@"\"%@\" (%@) is not managed by the Shortcut Mapper, so this shortcut cannot be taken from it.", nil),
            reserved.name, reserved.category];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
        [alert beginSheetModalForWindow:_window completionHandler:nil];
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSNumber *> *clashTags = [NSMutableArray array];
    for (NPPShortcutEntry *e in clashes) {
        [names addObject:[NSString stringWithFormat:@"\"%@\" (%@)", e.name, e.category]];
        [clashTags addObject:@(e.tag)];
    }
    alert.informativeText = [NSString stringWithFormat:
        NSLocalizedString(@"Assigning it here leaves %@ with no shortcut.", nil),
        [names componentsJoinedByString:NSLocalizedString(@" and ", nil)]];
    [alert addButtonWithTitle:NSLocalizedString(@"Assign Anyway", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    __weak __typeof__(self) weakSelf = self;
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || response != NSAlertFirstButtonReturn) return;
        for (NSNumber *t in clashTags) [self_ setOverride:@"" forTag:t.integerValue];
        [self_ assignShortcut:shortcut toTag:entry.tag];
    }];
}

- (void)assignShortcut:(NSString *)shortcut toTag:(NSInteger)tag {
    NSString *builtin = _builtinDefaults[@(tag)];
    NSString *normalized = [NPPShortcutMapper normalizedShortcut:shortcut] ?: @"";
    // Back to the built-in binding = no override at all, so a future change to the default is picked up.
    [self setOverride:([normalized isEqualToString:builtin] ? nil : normalized) forTag:tag];
    [self applyOverridesToMenu:NSApp.mainMenu];
    [self reload];
    [_context contextRefreshUI];
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd { return cmd == NPPCmdSettingsShortcutMapper; }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return cmd == NPPCmdSettingsShortcutMapper && NSApp.mainMenu != nil;   // the menu *is* the shortcut table
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (![self canPerformCommand:cmd context:context]) return NO;
    [[self shared] showWindowWithContext:context];
    return YES;
}

#pragma mark - Self test

// Tags no command uses, so the persistence checks cannot disturb a real binding.
static const NSInteger kSelfCheckTag = 999001;
static const NSInteger kSelfCheckTag2 = 999002;
static const NSInteger kSelfCheckTag3 = 999003;

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *f = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *what) { if (!ok) [f addObject:what]; };
    void (^expectEq)(NSString *, NSString *, NSString *) = ^(NSString *got, NSString *want, NSString *what) {
        if (![got isEqualToString:want]) [f addObject:[NSString stringWithFormat:@"%@: got \"%@\", want \"%@\"", what, got, want]];
    };

    // ---- formatting -------------------------------------------------------------------------------------------
    NSEventModifierFlags cmdShift = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    expectEq([self stringForKey:@"k" modifiers:cmdShift glyphs:NO], @"Shift+Cmd+K", @"format.portable");
    expectEq([self stringForKey:@"k" modifiers:cmdShift glyphs:YES], @"⇧⌘K", @"format.glyphs");
    expectEq([self stringForKey:@"" modifiers:cmdShift glyphs:NO], @"", @"format.no-key");
    expectEq([self stringForKey:NPPNamedKeys()[@"F5"] modifiers:NSEventModifierFlagControl glyphs:NO], @"Ctrl+F5", @"format.named-key");
    // An uppercase key equivalent already means Shift on macOS: both spellings must format the same.
    expectEq([self stringForKey:@"S" modifiers:NSEventModifierFlagCommand glyphs:NO],
             [self stringForKey:@"s" modifiers:cmdShift glyphs:NO], @"format.uppercase-is-shift");

    // ---- parsing ----------------------------------------------------------------------------------------------
    NSString *key = nil;
    NSEventModifierFlags mods = 0;
    expect([self parseShortcut:@"Ctrl+Shift+K" key:&key modifiers:&mods] &&
           [key isEqualToString:@"k"] && mods == (NSEventModifierFlagControl | NSEventModifierFlagShift),
           @"parse.upstream-form");
    expect([self parseShortcut:@"⌥⌘F5" key:&key modifiers:&mods] &&
           [key isEqualToString:NPPNamedKeys()[@"F5"]] &&
           mods == (NSEventModifierFlagOption | NSEventModifierFlagCommand), @"parse.glyph-form");
    expect([self parseShortcut:@"" key:&key modifiers:&mods] && key.length == 0 && mods == 0, @"parse.empty-is-no-shortcut");
    expect([self parseShortcut:@"Cmd++" key:&key modifiers:&mods] && [key isEqualToString:@"+"] &&
           mods == NSEventModifierFlagCommand, @"parse.plus-is-a-key");
    expect(![self parseShortcut:@"Cmd+Nope" key:NULL modifiers:NULL], @"parse.rejects-unknown-key");
    expect(![self parseShortcut:@"Cmd+Shift" key:NULL modifiers:NULL], @"parse.rejects-modifiers-only");
    expect(![self parseShortcut:@"Cmd+K+J" key:NULL modifiers:NULL], @"parse.rejects-two-keys");
    // Every string the mapper displays must parse back to itself — "Cmd+K" included (an uppercase key in a
    // shortcut string is just how the key is spelled, it does not smuggle in a Shift).
    for (NSString *s in @[@"Shift+Cmd+K", @"Cmd+K", @"Ctrl+Alt+F12", @"Cmd+Tab", @"Cmd+Left", @"", @"Alt+Space"])
        expectEq([self normalizedShortcut:s], s, @"parse.round-trip");
    expectEq([self normalizedShortcut:@"cmd+k"], @"Cmd+K", @"parse.case-insensitive");
    expectEq([self normalizedShortcut:@"⇧⌘K"], @"Shift+Cmd+K", @"parse.glyph-round-trip");

    // ---- conflicts --------------------------------------------------------------------------------------------
    expect([self shortcut:@"Cmd+Shift+K" conflictsWithShortcut:@"⇧⌘K"], @"conflict.same-binding-two-spellings");
    expect([self shortcut:@"Cmd+K" conflictsWithShortcut:@"Cmd+k"], @"conflict.case-insensitive");
    expect(![self shortcut:@"Cmd+K" conflictsWithShortcut:@"Cmd+Shift+K"], @"conflict.different-modifiers");
    expect(![self shortcut:@"" conflictsWithShortcut:@""], @"conflict.two-unbound-never-conflict");

    // ---- what may be bound at all (upstream Shortcut::isValid) -------------------------------------------------
    expect([self problemWithShortcut:@"K"] != nil, @"valid.bare-letter-refused");
    expect([self problemWithShortcut:@"Shift+K"] != nil, @"valid.shift-alone-is-not-a-modifier");
    expect([self problemWithShortcut:@"Space"] != nil, @"valid.bare-space-refused");
    expect([self problemWithShortcut:@"Tab"] != nil, @"valid.bare-tab-refused");
    expect([self problemWithShortcut:@"Enter"] != nil, @"valid.bare-enter-refused");
    expect([self problemWithShortcut:@"Cmd+K"] == nil, @"valid.cmd-letter-allowed");
    expect([self problemWithShortcut:@"Ctrl+K"] == nil, @"valid.ctrl-letter-allowed");
    expect([self problemWithShortcut:@"Alt+K"] == nil, @"valid.alt-letter-allowed");
    expect([self problemWithShortcut:@"Esc"] != nil, @"valid.bare-esc-refused");   // dismisses sheets and autocomplete
    expect([self problemWithShortcut:@"F2"] == nil, @"valid.bare-function-key-allowed");   // the port ships F2
    expect([self problemWithShortcut:@"Left"] == nil, @"valid.bare-arrow-allowed");
    expect([self problemWithShortcut:@"Delete"] == nil, @"valid.bare-forward-delete-allowed");
    expect([self problemWithShortcut:@"PageDown"] == nil, @"valid.bare-navigation-key-allowed");
    expect([self problemWithShortcut:@""] == nil, @"valid.no-shortcut-allowed");
    expect([self problemWithShortcut:@"Cmd+Nope"] != nil, @"valid.malformed-refused");

    // ---- tabs -------------------------------------------------------------------------------------------------
    expect(NPPTabForTag(NPPCmdSettingsShortcutMapper) == kTabMain, @"tab.main");
    expect(NPPTabForTag(NPPCmdMacroSavedBase) == kTabMacros && NPPTabForTag(NPPCmdMacroSavedBase + 99) == kTabMacros,
           @"tab.saved-macros");
    expect(NPPTabForTag(NPPCmdRunSavedBase) == kTabRun && NPPTabForTag(NPPCmdRunSavedBase + 99) == kTabRun,
           @"tab.saved-run-commands");
    expect(NPPTabForTag(NPPCmdMacroPlayback) == kTabMain, @"tab.macro-menu-command-is-not-a-saved-macro");

    // ---- menu walk: capture defaults, apply an override, restore -----------------------------------------------
    // A throwaway instance with its own captured defaults, on a menu of our own (the observers installed on the
    // shared instance ignore anything that is not rooted at NSApp.mainMenu, so this cannot fight with them).
    // Two levels of submenu, because the category of a row is the *top* menu it lives under, not its nearest one.
    NPPShortcutMapper *m = [[NPPShortcutMapper alloc] init];
    SEL cmd = NSSelectorFromString(@"nppCommand:");
    NSMenu *root = [[NSMenu alloc] initWithTitle:@"root"];
    NSMenuItem *editItem = [root addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    editItem.submenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *linesItem = [editItem.submenu addItemWithTitle:@"Line Operations" action:nil keyEquivalent:@""];
    linesItem.submenu = [[NSMenu alloc] initWithTitle:@"Line Operations"];
    NSMenuItem *item = [linesItem.submenu addItemWithTitle:@"Column Editor…" action:cmd keyEquivalent:@"c"];
    item.tag = kSelfCheckTag;
    item.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    // A second bindable command, and one reserved item (tag 0, ours to report but never to rebind).
    NSMenuItem *other = [editItem.submenu addItemWithTitle:@"Sort Lines" action:cmd keyEquivalent:@"o"];
    other.tag = kSelfCheckTag2;
    other.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem *reserved = [editItem.submenu addItemWithTitle:@"Redo" action:NSSelectorFromString(@"redo:") keyEquivalent:@"Z"];
    reserved.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    for (NSNumber *t in @[@(kSelfCheckTag), @(kSelfCheckTag2)])
        [[NPPShortcutMapper shared] setOverride:nil forTag:t.integerValue];   // start clean even after a crashed run

    NSArray<NPPShortcutEntry *> *entries = [m entriesInMenu:root];
    expect(entries.count == 3, [NSString stringWithFormat:@"walk.three-rows: got %lu", (unsigned long)entries.count]);
    NPPShortcutEntry *row = entries.firstObject;
    expectEq(row.name, @"Column Editor…", @"walk.name");
    expectEq(row.category, @"Edit", @"walk.category-is-the-top-menu-not-the-submenu");
    expectEq(row.shortcut, @"Alt+Cmd+C", @"walk.reads-the-built-in-shortcut");
    expect(!row.isOverridden, @"walk.built-in-is-not-an-override");
    NPPShortcutEntry *reservedRow = entries.lastObject;
    expect(reservedRow.tag == 0, @"walk.untagged-item-is-a-reserved-row");
    expectEq(reservedRow.shortcut, @"Shift+Cmd+Z", @"walk.reserved-row-keeps-its-binding");   // "Z" already means ⇧

    // ---- conflicts across the walked rows ----------------------------------------------------------------------
    expect([m entriesIn:entries conflictingWith:@"Cmd+O" excludingTag:kSelfCheckTag].count == 1,
           @"conflict.finds-the-other-command");
    expect([m entriesIn:entries conflictingWith:@"Cmd+O" excludingTag:kSelfCheckTag2].count == 0,
           @"conflict.a-command-never-conflicts-with-itself");
    NSArray<NPPShortcutEntry *> *onReserved = [m entriesIn:entries conflictingWith:@"Shift+Cmd+Z" excludingTag:kSelfCheckTag];
    expect(onReserved.count == 1 && onReserved.firstObject.tag == 0, @"conflict.reserved-rows-count-as-taken");
    expect([m entriesIn:entries conflictingWith:@"" excludingTag:kSelfCheckTag].count == 0,
           @"conflict.no-shortcut-clashes-with-nothing");
    expect([m entriesIn:entries conflictingWith:@"Ctrl+Alt+Cmd+Q" excludingTag:0].count == 0, @"conflict.free-binding");

    // ---- the filter box over the list (upstream's IDC_BABYGRID_FILTER) ------------------------------------------
    // Word matching first, then the control itself: a filter box that is not in the window, or is in it but wired to
    // nothing, leaves six hundred commands reachable only by scrolling the whole table.
    // The two bindable rows of the walk above (a broken walk must fail these checks, not crash the run).
    NSArray<NPPShortcutEntry *> *bindable = entries.count >= 2 ? [entries subarrayWithRange:NSMakeRange(0, 2)] : @[];
    NPPShortcutEntry *columnEditor = bindable.firstObject, *sortLines = bindable.lastObject;
    expect(NPPFilterWords(@"   ").count == 0, @"filter.blank-is-no-filter");
    expect(NPPEntryMatchesFilterWords(columnEditor, NPPFilterWords(@"")), @"filter.no-words-matches-everything");
    expect(NPPEntryMatchesFilterWords(columnEditor, NPPFilterWords(@"COLUMN")), @"filter.name-is-case-insensitive");
    expect(NPPEntryMatchesFilterWords(columnEditor, NPPFilterWords(@"alt+cmd")), @"filter.matches-the-shortcut");
    expect(NPPEntryMatchesFilterWords(sortLines, NPPFilterWords(@"edit")), @"filter.matches-the-category");
    expect(NPPEntryMatchesFilterWords(columnEditor, NPPFilterWords(@"column cmd")), @"filter.all-words-must-match");
    expect(!NPPEntryMatchesFilterWords(sortLines, NPPFilterWords(@"sort alt")), @"filter.one-missing-word-rejects");

    NPPShortcutMapper *ui = [[NPPShortcutMapper alloc] init];   // its own window; the shared one is left alone
    [ui buildWindow];
    expect(ui->_filterField != nil && [ui->_window.contentView.subviews containsObject:ui->_filterField],
           @"filter.box-is-in-the-window");
    expect(!ui->_filterField.isHidden && NSWidth(ui->_filterField.frame) > 80, @"filter.box-is-visible");
    expect(ui->_filterField.target == ui && ui->_filterField.action == @selector(filterChanged:),
           @"filter.box-is-wired-to-something");
    expect(!NSIntersectsRect(ui->_filterField.frame, ui->_tabView.frame), @"filter.box-does-not-sit-on-the-list");
    expect(ui->_window.initialFirstResponder == ui->_filterField, @"filter.box-has-the-focus-when-the-window-opens");

    ui->_allTabEntries = @[bindable, @[], @[]];
    ui->_entries = entries;
    [ui applyFilter];
    expect([ui numberOfRowsInTableView:ui->_tables.firstObject] == 2, @"filter.empty-box-shows-every-command");
    ui->_filterField.stringValue = @"sort";
    [ui filterChanged:nil];
    NSArray<NPPShortcutEntry *> *shown = [ui entriesForTab:kTabMain];
    expect(shown.count == 1 && shown.firstObject == sortLines, @"filter.narrows-the-list");
    expect([ui numberOfRowsInTableView:ui->_tables.firstObject] == 1, @"filter.reaches-the-table");
    // A filtered-out command still holds its shortcut, so the conflict scan must keep seeing it.
    expect([ui entriesConflictingWith:@"Alt+Cmd+C" excludingTag:kSelfCheckTag2].count == 1,
           @"filter.hidden-command-still-owns-its-shortcut");
    ui->_filterField.stringValue = @"nosuchcommand";
    [ui filterChanged:nil];
    expect([ui numberOfRowsInTableView:ui->_tables.firstObject] == 0, @"filter.no-match-empties-the-list");

    [m setOverride:@"Ctrl+Shift+K" forTag:kSelfCheckTag];
    [m applyOverridesToMenu:root];
    expectEq(item.keyEquivalent, @"k", @"apply.key");
    expect(item.keyEquivalentModifierMask == (NSEventModifierFlagControl | NSEventModifierFlagShift), @"apply.modifiers");
    expect([m entriesInMenu:root].firstObject.isOverridden, @"apply.row-marked-as-overridden");
    expectEq(other.keyEquivalent, @"o", @"apply.leaves-other-commands-alone");
    expectEq(reserved.keyEquivalent, @"Z", @"apply.never-touches-a-reserved-item");
    [m applyOverridesToMenu:root];                    // a second pass must not drift (it runs on every menu open)
    expectEq(item.keyEquivalent, @"k", @"apply.idempotent");
    expectEq([m entriesInMenu:root].firstObject.defaultShortcut, @"Alt+Cmd+C", @"apply.default-is-captured-once-only");

    // The notification path applies one item at a time — a rebuilt Macro / Run / Language menu is one
    // NSMenuDidAddItem post per item — so it has to reach the same place the full walk does, and leave the
    // reserved items alone just the same.
    item.keyEquivalent = @"c";
    item.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;   // as if rebuilt
    [m applyToItem:item];
    expectEq(item.keyEquivalent, @"k", @"apply-one.matches-the-full-walk");
    [m applyToItem:reserved];
    expectEq(reserved.keyEquivalent, @"Z", @"apply-one.never-touches-a-reserved-item");
    expect(reserved.keyEquivalentModifierMask == NSEventModifierFlagCommand, @"apply-one.reserved-modifiers-untouched");

    // The dynamic Macro / Run / Language menus are rebuilt item by item, and applying per item is only safe
    // because AppKit posts a change for an item *after* NPPAppDelegate's builder has given it its tag — on the add
    // itself the tag is still 0. That ordering is the whole reason the re-apply can be O(1) instead of walking the
    // menu again per item (a 90-item Language menu rebuilt on every keystroke: 0.8 ms against 17 ms). It is also
    // someone else's file, so it is checked here rather than assumed: if it stops holding, a rebound saved macro
    // silently stops firing. (An item left on AppKit's own default mask posts nothing after its tag — no dynamic
    // menu builds items that way today, and this check is what would notice if one started.)
    __block NSInteger tagWhenNotified = -1;
    id watcher = [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidChangeItemNotification object:nil
                                                                  queue:nil usingBlock:^(NSNotification *n) {
        NSMenu *changed = n.object;
        NSNumber *i = n.userInfo[@"NSMenuItemIndex"];
        if ([changed isKindOfClass:NSMenu.class] && [i isKindOfClass:NSNumber.class] &&
            i.integerValue >= 0 && i.integerValue < changed.numberOfItems)
            tagWhenNotified = [changed itemAtIndex:i.integerValue].tag;
    }];
    NSMenu *rebuilt = [[NSMenu alloc] initWithTitle:@"Macro"];
    NSMenuItem *fresh = [rebuilt addItemWithTitle:@"My Macro" action:cmd keyEquivalent:@""];
    fresh.tag = kSelfCheckTag3;                         // exactly NPPAppDelegate's I(): add, then tag, then mask
    fresh.keyEquivalentModifierMask = 0;
    [NSNotificationCenter.defaultCenter removeObserver:watcher];
    expect(tagWhenNotified == kSelfCheckTag3, @"rebuild.item-notifies-after-its-tag-is-set");

    NPPShortcutMapper *m2 = [[NPPShortcutMapper alloc] init];   // no captured defaults, like a menu seen for the first time
    [m2 setOverride:@"Ctrl+Shift+K" forTag:kSelfCheckTag3];
    [m2 applyToItem:fresh];
    expectEq(fresh.keyEquivalent, @"k", @"rebuild.override-lands-on-a-freshly-rebuilt-item");
    [m2 setOverride:nil forTag:kSelfCheckTag3];

    // A stored override that is not bindable must be ignored rather than applied: the plist is a file, and a bad
    // value here is a key the user can no longer type.
    [m setOverride:@"J" forTag:kSelfCheckTag];
    expect([m overrideForTag:kSelfCheckTag] == nil, @"guard.unbindable-stored-override-ignored");
    [m applyOverridesToMenu:root];
    expectEq(item.keyEquivalent, @"c", @"guard.unbindable-stored-override-falls-back-to-the-default");
    [m setOverride:@"Cmd+Nope" forTag:kSelfCheckTag];
    expect([m overrideForTag:kSelfCheckTag] == nil, @"guard.malformed-stored-override-ignored");

    [m setOverride:@"" forTag:kSelfCheckTag];        // "cleared on purpose" is not the same as "no override"
    [m applyOverridesToMenu:root];
    expectEq(item.keyEquivalent, @"", @"clear.key-equivalent-removed");
    expect(item.keyEquivalentModifierMask == 0, @"clear.modifiers-removed");

    [m setOverride:nil forTag:kSelfCheckTag];
    [m applyOverridesToMenu:root];
    expectEq(item.keyEquivalent, @"c", @"restore.default-key");
    expect(item.keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagOption), @"restore.default-modifiers");

    // ---- persistence round trip -------------------------------------------------------------------------------
    // A fresh instance stands in for a restart: it has no captured defaults and no cache, so anything it can still
    // see came back out of NSUserDefaults.
    [m setOverride:@"Shift+Cmd+J" forTag:kSelfCheckTag];
    expectEq([[[NPPShortcutMapper alloc] init] overrideForTag:kSelfCheckTag], @"Shift+Cmd+J", @"persist.round-trip");
    expectEq([NSUserDefaults.standardUserDefaults dictionaryForKey:kOverridesKey][@(kSelfCheckTag).stringValue],
             @"Shift+Cmd+J", @"persist.actually-reaches-nsuserdefaults");
    [m setOverride:@"" forTag:kSelfCheckTag];
    expectEq([[[NPPShortcutMapper alloc] init] overrideForTag:kSelfCheckTag], @"", @"persist.cleared-survives");
    [m setOverride:nil forTag:kSelfCheckTag];
    expect([[[NPPShortcutMapper alloc] init] overrideForTag:kSelfCheckTag] == nil, @"persist.removal-survives");
    // Other tags must be untouched by any of that — setOverride: rewrites the whole dictionary.
    [m setOverride:@"Cmd+9" forTag:kSelfCheckTag2];
    [m setOverride:@"Cmd+8" forTag:kSelfCheckTag];
    expectEq([[[NPPShortcutMapper alloc] init] overrideForTag:kSelfCheckTag2], @"Cmd+9", @"persist.writes-do-not-clobber-siblings");
    [m setOverride:nil forTag:kSelfCheckTag];
    [m setOverride:nil forTag:kSelfCheckTag2];
    return f;
}

@end
