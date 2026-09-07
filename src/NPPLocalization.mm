// NPPLocalization.mm — apply a Notepad++ nativeLang translation to the live main menu.
//
// Upstream (localization.cpp) can do this because the Win32 menu already carries the IDM_ ids the XML is keyed
// by. Here the join is by structure + English text; see the exception tables below.
#import "NPPLocalization.h"

#import <objc/runtime.h>
#import "NPPUtils.h"

static NSString *const kDefaultsKey = @"NPPUILanguageFileName";   // "" = built-in English
static const void *kTitleMemoKey = &kTitleMemoKey;                // NSMenuItem -> @[untranslated title, what we wrote]

#pragma mark - Win32 menu text

// "&&" is a literal ampersand, "&x" an accelerator marker macOS has no use for. A few translations write a bare
// "& " where upstream writes "&&", so only a "&" glued to an alphanumeric counts as a marker.
static NSString *NPPStripAccelerators(NSString *s) {
    if ([s rangeOfString:@"&"].location == NSNotFound) return s;
    NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet;
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0, n = s.length; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c != '&') { [out appendFormat:@"%C", c]; continue; }
        unichar next = (i + 1 < n) ? [s characterAtIndex:i + 1] : 0;
        if (next == '&') { [out appendString:@"&"]; i++; }
        else if (next && [alnum characterIsMember:next]) { /* marker: drop it */ }
        else [out appendString:@"&"];
    }
    return out;
}

// Match key for a menu title, on both sides of the join: no accelerators, one spelling of the ellipsis, no case.
static NSString *NPPTitleKey(NSString *title) {
    NSString *s = [NPPStripAccelerators(title) stringByReplacingOccurrencesOfString:@"…" withString:@"..."];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
}

// Menu items whose title is data, not UI: recent paths, and the language / theme / macro / Run command /
// user-defined-language lists (plus this module's own language list, which must stay in its native names).
// Upstream leaves all of these alone too — they come from langs.xml and shortcuts.xml, not from nativeLang —
// and translating them corrupts user data: a macro the user called "Copy" would show up as "Copier", and
// Language ▸ PowerShell would take id 41027, which is really "Open containing folder in PowerShell".
static BOOL NPPTitleIsUserData(NSInteger tag) {
    static const NSInteger ranges[][2] = {
        {NPPCmdFileRecentBase, NPPCmdFileClearRecent},   // recent file paths — "Clear Recent" sits at the top end
        {NPPCmdLanguageBase,            6500},   // language names
        {NPPCmdSettingsThemeBase,       7200},   // theme names
        {NPPCmdMacroSavedBase,         10200},   // saved macros
        {NPPCmdRunSavedBase,           10400},   // saved Run commands
        {NPPCmdLangUserDefinedBase,    10800},   // user-defined languages
        {NPPCmdSettingsUILanguageBase, NPPCmdSettingsUILanguageBase + 200},
    };
    for (size_t i = 0; i < sizeof(ranges) / sizeof(ranges[0]); i++)
        if (tag >= ranges[i][0] && tag < ranges[i][1]) return YES;
    return NO;
}

#pragma mark - the exception table

// Titles the port words differently from english.xml, plus the ones english.xml repeats (the hash and mark-style
// submenus say the same thing four or five times). A repeated title is keyed "<parent menu title>/<item title>",
// both normalised by NPPTitleKey. Everything else joins on the English text alone and needs no entry here.
//
// ponytail: hand-kept, ~35 lines, and only ever wrong in the safe direction — a stale entry means one item keeps
// its English title. Upgrade path if it drifts: emit it from NppCommands.cpp's IDM_ switch at build time.
static NSDictionary<NSString *, NSString *> *NPPLeafOverrides(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSString *> *t = [NSMutableDictionary dictionary];
        void (^put)(NSString *, NSString *) = ^(NSString *title, NSString *idm) { t[NPPTitleKey(title)] = idm; };

        put(@"Open Containing Folder", @"42074");            // "Open Containing Folder in Explorer"
        put(@"Open Folder as Workspace…", @"41022");
        put(@"Close All but Active Document", @"41005");     // "Close All BUT Current Document"
        put(@"Move to Trash", @"41016");                     // "Move to Recycle Bin"
        put(@"Clear Recent", @"42041");                      // "Empty Recent Files List"
        put(@"Copy Current Full File Path", @"42029");       // "Copy Current File Path"
        put(@"Read-Only Attribute of the File", @"42033");   // "Read-Only Attribute in Windows"
        put(@"Redact Selection", @"42106");                  // upstream appends the redaction glyphs
        put(@"Find in Files…", @"43013");
        put(@"Zoom In", @"44023");                           // upstream appends "(Ctrl+Mouse Wheel Up)"
        put(@"Zoom Out", @"44024");
        put(@"Show Control Characters and Unicode EOL", @"44131");
        put(@"Synchronize Vertical Scrolling", @"44035");    // upstream spells it "Synchronise"
        put(@"Synchronize Horizontal Scrolling", @"44036");
        put(@"Folder as Workspace", @"44085");               // ambiguous by title alone
        put(@"Save Current Recorded Macro…", @"42025");
        put(@"Modify or Delete Macro…", @"48016");           // "Modify Shortcut/Delete Macro..."
        put(@"Modify or Delete Command…", @"48017");
        put(@"Online Documentation", @"47003");              // "Notepad++ Online User Manual"
        put(@"Community", @"47004");                         // "Notepad++ Community (Forum)"

        // Mark/style submenus: five identical titles per submenu, told apart by their parent.
        NSArray<NSString *> *ord = @[@"1st", @"2nd", @"3rd", @"4th", @"5th"];
        for (NSInteger i = 0; i < 5; i++) {
            put([NSString stringWithFormat:@"Style All Occurrences of Token/Using %@ Style", ord[(NSUInteger)i]],
                [NSString stringWithFormat:@"%ld", (long)(43022 + i * 2)]);
            put([NSString stringWithFormat:@"Style One Token/Using %@ Style", ord[(NSUInteger)i]],
                [NSString stringWithFormat:@"%ld", (long)(43062 + i)]);
            put([NSString stringWithFormat:@"Jump Up/%@ Style", ord[(NSUInteger)i]],
                [NSString stringWithFormat:@"%ld", (long)(43033 + i)]);
            put([NSString stringWithFormat:@"Jump Down/%@ Style", ord[(NSUInteger)i]],
                [NSString stringWithFormat:@"%ld", (long)(43039 + i)]);
            put([NSString stringWithFormat:@"Copy Styled Text/%@ Style", ord[(NSUInteger)i]],
                [NSString stringWithFormat:@"%ld", (long)(43055 + i)]);
        }
        // Edit ▸ Multi-select All / Multi-select Next: the same four titles under both parents (42090 / 42094).
        NSArray<NSString *> *modes = @[@"Ignore Case & Whole Word", @"Match Case Only",
                                       @"Match Whole Word Only", @"Match Case & Whole Word"];
        for (NSInteger k = 0; k < 4; k++) {
            put([@"Multi-select All/" stringByAppendingString:modes[(NSUInteger)k]],
                [NSString stringWithFormat:@"%ld", (long)(42090 + k)]);
            put([@"Multi-select Next/" stringByAppendingString:modes[(NSUInteger)k]],
                [NSString stringWithFormat:@"%ld", (long)(42094 + k)]);
        }
        put(@"Jump Up/Find Mark Style", @"43038");
        put(@"Jump Down/Find Mark Style", @"43044");
        put(@"Copy Styled Text/Find Mark Style", @"43061");

        // Tools ▸ MD5/SHA-* : the same three actions under four parents (IDM_TOOL_MD5_GENERATE = 48501).
        NSArray<NSString *> *algos = @[@"MD5", @"SHA-1", @"SHA-256", @"SHA-512"];
        NSArray<NSString *> *acts = @[@"Generate…", @"Generate from files…", @"Generate from selection into clipboard"];
        for (NSInteger a = 0; a < 4; a++)
            for (NSInteger k = 0; k < 3; k++)
                put([NSString stringWithFormat:@"%@/%@", algos[(NSUInteger)a], acts[(NSUInteger)k]],
                    [NSString stringWithFormat:@"%ld", (long)(48501 + a * 3 + k)]);
        table = t;
    });
    return table;
}

// Submenu titles the port words differently from <SubEntries>. Top-level menus (File, Edit, …) match by name.
static NSDictionary<NSString *, NSString *> *NPPGroupOverrides(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{NPPTitleKey(@"Open Recent"):     @"file-recentFiles",
                  NPPTitleKey(@"Read-Only"):       @"edit-readonlyInNotepad++",
                  NPPTitleKey(@"Project Panels"):  @"view-project",
                  NPPTitleKey(@"Character sets"):  @"encoding-characterSets",
                  NPPTitleKey(@"User-Defined"):    @"language-userDefinedLanguage"};
    });
    return table;
}

#pragma mark -

@interface NPPUILanguage ()
- (instancetype)initWithFileName:(NSString *)f displayName:(NSString *)d;
@end

@implementation NPPUILanguage
- (instancetype)initWithFileName:(NSString *)f displayName:(NSString *)d {
    if ((self = [super init])) { _fileName = [f copy]; _displayName = [d copy]; }
    return self;
}
@end

@implementation NPPLocalization {
    NSArray<NPPUILanguage *> *_available;
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *_stringsCache;
    NSDictionary<NSString *, id> *_commandIdByTitle;   // NSString id, or NSNull when the title is ambiguous
    NSDictionary<NSString *, id> *_groupIdByTitle;
    NSMenu *_languageMenu;
    BOOL _applying;
}

+ (instancetype)shared {
    static NPPLocalization *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPLocalization alloc] init]; });
    return s;
}

// The menu exists long before any command context does, and the Language/Macro/Run menus are rebuilt from a menu
// delegate we do not own — so the trigger is the menu itself changing, not a lifecycle hook.
+ (void)load {
    @autoreleasepool {
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NPPLocalization *me = [self shared];
        [nc addObserver:me selector:@selector(contextDidBecomeReady:)
                   name:NPPCommandContextReadyNotification object:nil];
        // Both, and they are not interchangeable: refilling a rebuilt menu posts only …DidAddItem…, while a
        // title the app writes itself posts only …DidChangeItem….
        [nc addObserver:me selector:@selector(menuDidChangeItem:)
                   name:NSMenuDidAddItemNotification object:nil];
        [nc addObserver:me selector:@selector(menuDidChangeItem:)
                   name:NSMenuDidChangeItemNotification object:nil];
    }
}

- (instancetype)init {
    if ((self = [super init])) _stringsCache = [NSMutableDictionary dictionary];
    return self;
}

#pragma mark - where the translations live

// The Makefile bundles Resources/nativeLang; the upstream checkout stays as a fallback for a dev build that
// runs the binary straight out of build/.
+ (nullable NSURL *)nativeLangDirectoryURL {
    static NSURL *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *u = [NSBundle.mainBundle URLForResource:@"nativeLang" withExtension:nil];
        if (u && [fm fileExistsAtPath:u.path]) { dir = u; return; }
        NSString *path = NPPUpstreamPath(@"PowerEditor/installer/nativeLang");   // development fallback only
        if (path) dir = [NSURL fileURLWithPath:path];
    });
    return dir;
}

// The name a translation calls itself, from <Native-Langue name="…">. Reading the whole 200 KB file just for the
// header, ninety times over, is not worth it; the tag is always in the first few KB.
+ (nullable NSString *)nativeNameOfFileAtURL:(NSURL *)url {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    NSData *data = [fh readDataUpToLength:8192 error:NULL];
    [fh closeAndReturnError:NULL];
    NSString *head = nil;
    for (NSUInteger drop = 0; drop < 4 && !head && data.length > drop; drop++)   // do not split a UTF-8 sequence
        head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, data.length - drop)]
                                     encoding:NSUTF8StringEncoding];
    if (!head) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"<Native-Langue[^>]*\\sname=\"([^\"]*)\""
                                                                          options:0 error:NULL]; });
    NSTextCheckingResult *m = [re firstMatchInString:head options:0 range:NSMakeRange(0, head.length)];
    return m ? [head substringWithRange:[m rangeAtIndex:1]] : nil;
}

- (NSArray<NPPUILanguage *> *)availableLanguages {
    if (_available) return _available;
    NSMutableArray<NPPUILanguage *> *found = [NSMutableArray array];
    NSURL *dir = [[self class] nativeLangDirectoryURL];
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.path error:NULL]
                         sortedArrayUsingSelector:@selector(compare:)]) {
        // english.xml is the reference the mapping is built from; picking it would be a no-op with worse wording.
        if (![f.pathExtension.lowercaseString isEqualToString:@"xml"]) continue;
        if ([f hasPrefix:@"english"]) continue;
        NSString *name = [[self class] nativeNameOfFileAtURL:[dir URLByAppendingPathComponent:f]];
        if (name.length) [found addObject:[[NPPUILanguage alloc] initWithFileName:f displayName:name]];
    }
    [found sortUsingComparator:^NSComparisonResult(NPPUILanguage *a, NPPUILanguage *b) {
        return [a.displayName localizedStandardCompare:b.displayName];
    }];
    [found insertObject:[[NPPUILanguage alloc] initWithFileName:@"" displayName:@"English"] atIndex:0];
    _available = found;
    return _available;
}

#pragma mark - parsing

- (nullable NSDictionary<NSString *, NSString *> *)stringsForFileNamed:(NSString *)fileName {
    if (!fileName.length) return nil;
    id cached = _stringsCache[fileName];
    if (cached) return cached == NSNull.null ? nil : cached;

    NSURL *dir = [[self class] nativeLangDirectoryURL];
    NSXMLDocument *doc = dir ? [[NSXMLDocument alloc] initWithContentsOfURL:[dir URLByAppendingPathComponent:fileName]
                                                                   options:0 error:NULL] : nil;
    NSMutableDictionary<NSString *, NSString *> *map = doc ? [NSMutableDictionary dictionary] : nil;
    for (NSArray *spec in @[@[@"//Menu/Main/Commands/Item", @"id"],
                            @[@"//Menu/Main/Entries/Item", @"menuId"],
                            @[@"//Menu/Main/SubEntries/Item", @"subMenuId"]]) {
        for (NSXMLNode *n in [doc nodesForXPath:spec[0] error:NULL]) {
            NSXMLElement *e = (NSXMLElement *)n;
            NSString *key = [e attributeForName:spec[1]].stringValue;
            NSString *name = [e attributeForName:@"name"].stringValue;
            if (key.length && name.length) map[key] = NPPStripAccelerators(name);
        }
    }
    _stringsCache[fileName] = map ?: (id)NSNull.null;
    return map;
}

// english.xml is the join table: English title -> the id every other translation is keyed by. A title used more
// than once maps to NSNull and can only be resolved through the parent-qualified exception table.
- (void)buildEnglishIndexIfNeeded {
    if (_commandIdByTitle) return;
    NSDictionary<NSString *, NSString *> *english = [self stringsForFileNamed:@"english.xml"];
    NSMutableDictionary<NSString *, id> *cmds = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, id> *groups = [NSMutableDictionary dictionary];
    [english enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *name, BOOL *stop) {
        BOOL numeric = [key rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
        NSMutableDictionary<NSString *, id> *into = numeric ? cmds : groups;
        NSString *title = NPPTitleKey(name);
        into[title] = into[title] ? (id)NSNull.null : key;
    }];
    _commandIdByTitle = cmds;
    _groupIdByTitle = groups;
}

#pragma mark - applying

// A submenu is looked up among <SubEntries>/<Entries>, a leaf among <Commands> — exactly upstream's own split, and
// what keeps Window ▸ Zoom (a leaf, no upstream twin) from stealing View ▸ Zoom's translation.
- (nullable NSString *)translationIdForTitle:(NSString *)english isGroup:(BOOL)isGroup parentTitle:(NSString *)parent {
    [self buildEnglishIndexIfNeeded];
    NSString *key = NPPTitleKey(english);
    if (isGroup) {
        NSString *o = NPPGroupOverrides()[key];
        if (o) return o;
        id found = _groupIdByTitle[key];
        return found == NSNull.null ? nil : found;
    }
    NSDictionary<NSString *, NSString *> *overrides = NPPLeafOverrides();
    NSString *o = overrides[[NSString stringWithFormat:@"%@/%@", NPPTitleKey(parent), key]] ?: overrides[key];
    if (o) return o;
    id found = _commandIdByTitle[key];
    return found == NSNull.null ? nil : found;
}

- (void)applyStrings:(nullable NSDictionary<NSString *, NSString *> *)strings toMenu:(NSMenu *)menu {
    if (_applying) return;
    _applying = YES;
    [self applyStringsUnguarded:strings toMenu:menu];
    _applying = NO;
}

- (void)applyStringsUnguarded:(nullable NSDictionary<NSString *, NSString *> *)strings toMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        // NPPAppDelegate's I() sets the title first and the tag second, so a data item is briefly untagged and
        // can be translated before we can tell what it is; the following add in the same rebuild undoes it.
        // ponytail: an item that is BOTH data and the last thing added to its menu keeps the translation until
        // that menu is next walked. Upgrade path if a real list ever ends in a data item: coalesce one re-apply
        // onto the next runloop pass.
        if (NPPTitleIsUserData(item.tag)) {
            NSArray<NSString *> *memo = objc_getAssociatedObject(item, kTitleMemoKey);
            if ([memo.lastObject isEqualToString:item.title] && ![memo.firstObject isEqualToString:item.title])
                item.title = memo.firstObject;
            objc_setAssociatedObject(item, kTitleMemoKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }

        // The app re-titles items behind our back: -[NPPEditorWindowController validateMenuItem:] writes
        // dynamicTitleForCommand: over macro names and "Restore Unsaved Documents (3)", and AppKit owns the
        // window list in NSApp.windowsMenu outright. Both arrive here as NSMenuDidChangeItemNotification, so
        // anything that is not the title we last wrote is the new English original — putting the previous one
        // back would freeze those titles at whatever they said the first time this ran.
        NSArray<NSString *> *memo = objc_getAssociatedObject(item, kTitleMemoKey);
        NSString *english = [memo.lastObject isEqualToString:item.title] ? memo.firstObject : item.title;

        NSString *idm = strings.count ? [self translationIdForTitle:english isGroup:(item.submenu != nil)
                                                        parentTitle:menu.title ?: @""] : nil;
        NSString *want = (idm ? strings[idm] : nil) ?: english;   // never blank an item we could not map
        if (![item.title isEqualToString:want]) item.title = want;
        if (![memo.firstObject isEqualToString:english] || ![memo.lastObject isEqualToString:want])
            objc_setAssociatedObject(item, kTitleMemoKey, (@[english, want]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (item.submenu) [self applyStringsUnguarded:strings toMenu:item.submenu];
    }
}

- (void)applyToMenu:(NSMenu *)menu {
    [self applyStrings:[self stringsForFileNamed:self.currentFileName] toMenu:menu];
}

#pragma mark - the chosen language

- (NSString *)currentFileName {
    return [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsKey] ?: @"";
}

- (void)setCurrentFileName:(NSString *)fileName {
    [NSUserDefaults.standardUserDefaults setObject:(fileName ?: @"") forKey:kDefaultsKey];
    if (NSApp.mainMenu) [self applyToMenu:NSApp.mainMenu];
    [self syncLanguageMenuState];
}

#pragma mark - the Settings ▸ UI Language submenu

// ponytail: this module builds and owns the submenu because NPPAppDelegate.mm is not ours to edit. It is a plain
// submenu with explicit targets, so lifting it into -buildMainMenu later is a copy/paste with target:nil.

- (void)syncLanguageMenuState {
    NSString *current = self.currentFileName;
    NSArray<NPPUILanguage *> *langs = self.availableLanguages;
    for (NSMenuItem *item in _languageMenu.itemArray) {
        NSUInteger i = (NSUInteger)(item.tag - NPPCmdSettingsUILanguageBase);
        item.state = (i < langs.count && [langs[i].fileName isEqualToString:current]) ? NSControlStateValueOn
                                                                                      : NSControlStateValueOff;
    }
}

#pragma mark - staying applied

- (void)contextDidBecomeReady:(NSNotification *)n {
    if (NSApp.mainMenu) [self applyToMenu:NSApp.mainMenu];
}

// The Language, Macro, Run, Recent and Theme menus are emptied and refilled by NPPAppDelegate's menu delegate, so
// their fresh English items have to be re-titled. Registered for NSMenuDidAddItem (the refill) and
// NSMenuDidChangeItem (a title the app writes itself); setting a title posts one back, hence the _applying guard.
// ponytail: re-titles the whole changed menu per notification rather than the single item, so a rebuild is O(n²)
// in that menu's item count, and the re-walk is also what undoes the translation of a data item whose tag was set
// after its title. Measured at ~1 ms per menu open for the lists that are actually rebuilt (Recent, Language,
// Macro, Run — their long tails are data tags and bail on the first test); a menu of 90 items that all need a
// lookup would cost ~8 ms, and the port has none. Upgrade path if one appears: apply to the single item named by
// userInfo[@"NSMenuItemIndex"] and coalesce one whole-menu pass onto the next runloop turn.
- (void)menuDidChangeItem:(NSNotification *)n {
    if (_applying) return;
    NSMenu *menu = n.object;
    if (![menu isKindOfClass:NSMenu.class] || !NSApp.mainMenu) return;
    for (NSMenu *m = menu; m; m = m.supermenu) if (m == NSApp.mainMenu) { [self applyToMenu:menu]; return; }
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    return cmd >= NPPCmdSettingsUILanguageBase && cmd < NPPCmdSettingsUILanguageBase + 200;
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return [[self shared] hasLanguageAtIndex:cmd - NPPCmdSettingsUILanguageBase];
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return [[self shared] selectLanguageAtIndex:cmd - NPPCmdSettingsUILanguageBase];
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return [[self shared] languageIsCurrentAtIndex:cmd - NPPCmdSettingsUILanguageBase];
}

- (BOOL)hasLanguageAtIndex:(NSInteger)i {
    return i >= 0 && (NSUInteger)i < self.availableLanguages.count;
}

- (BOOL)languageIsCurrentAtIndex:(NSInteger)i {
    return [self hasLanguageAtIndex:i] &&
           [self.availableLanguages[(NSUInteger)i].fileName isEqualToString:self.currentFileName];
}

- (BOOL)selectLanguageAtIndex:(NSInteger)i {
    if (![self hasLanguageAtIndex:i]) return NO;
    self.currentFileName = self.availableLanguages[(NSUInteger)i].fileName;
    return YES;
}

// The submenu built above targets this object directly, so it works whether or not the window controller knows
// about this class; validateMenuItem: also keeps `make exercise` from counting the items as unresolved.
- (void)nppCommand:(id)sender {
    NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    [self selectLanguageAtIndex:tag - NPPCmdSettingsUILanguageBase];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (![[self class] handlesCommand:(NPPCmd)item.tag]) return YES;
    NSInteger i = item.tag - NPPCmdSettingsUILanguageBase;
    item.state = [self languageIsCurrentAtIndex:i] ? NSControlStateValueOn : NSControlStateValueOff;
    return [self hasLanguageAtIndex:i];
}

#pragma mark - self-check

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) { if (!ok) [fails addObject:msg]; };
    void (^same)(NSString *, NSString *, NSString *) = ^(NSString *what, NSString *got, NSString *want) {
        if (![got isEqualToString:want])
            [fails addObject:[NSString stringWithFormat:@"%@: got \"%@\", want \"%@\"", what, got ?: @"(nil)", want]];
    };
    NPPLocalization *loc = [self shared];

    if (![self nativeLangDirectoryURL]) return @[@"l10n.dir: no nativeLang directory in the bundle or the upstream checkout"];

    NSArray<NPPUILanguage *> *langs = loc.availableLanguages;
    expect(langs.count > 50, ([NSString stringWithFormat:@"l10n.available: only %lu translations", (unsigned long)langs.count]));
    same(@"l10n.available[0].file", langs.firstObject.fileName, @"");
    same(@"l10n.available[0].name", langs.firstObject.displayName, @"English");
    BOOL hasFrench = NO;
    for (NPPUILanguage *l in langs) if ([l.fileName isEqualToString:@"french.xml"]) hasFrench = [l.displayName isEqualToString:@"Français"];
    expect(hasFrench, @"l10n.available: french.xml missing or not named \"Français\"");

    // Parsing a real upstream translation: a command id, a top-level menu id, a submenu id.
    NSDictionary<NSString *, NSString *> *fr = [loc stringsForFileNamed:@"french.xml"];
    expect(fr.count > 300, ([NSString stringWithFormat:@"l10n.parse: french.xml gave %lu strings", (unsigned long)fr.count]));
    same(@"l10n.parse.41001", fr[@"41001"], @"Nouveau");                 // "&Nouveau" — accelerator dropped
    same(@"l10n.parse.file", fr[@"file"], @"Fichier");
    same(@"l10n.parse.edit-insert", fr[@"edit-insert"], @"Insertion");
    same(@"l10n.accelerators", NPPStripAccelerators(@"A && B, &Cee, R & D"), @"A & B, Cee, R & D");
    same(@"l10n.parse.44131", fr[@"44131"], @"Afficher les caractères de contrôle & Unicode EOL");

    // A stand-in for the real main menu: the same structure and the same English titles.
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSMenu * (^sub)(NSMenu *, NSString *) = ^NSMenu *(NSMenu *parent, NSString *title) {
        NSMenuItem *it = [parent addItemWithTitle:title action:nil keyEquivalent:@""];
        it.submenu = [[NSMenu alloc] initWithTitle:title];
        return it.submenu;
    };
    NSMenu *file = sub(main, @"File");
    [file addItemWithTitle:@"New" action:NULL keyEquivalent:@""];
    [file addItemWithTitle:@"Close All but Active Document" action:NULL keyEquivalent:@""];   // exception table
    NSMenu *edit = sub(main, @"Edit");
    sub(edit, @"Insert");
    NSMenu *md5 = sub(sub(main, @"Tools"), @"MD5");
    [md5 addItemWithTitle:@"Generate…" action:NULL keyEquivalent:@""];                        // 4x ambiguous title
    NSMenu *window = sub(main, @"Window");
    [window addItemWithTitle:@"Bring All to Front" action:NULL keyEquivalent:@""];            // no upstream twin
    // The leaf/group split, checked both ways with titles english.xml uses on one side only: "Insert" is a
    // <SubEntries> name and "New" a <Commands> name, so a side that leaks gives Insertion / Nouveau.
    [window addItemWithTitle:@"Insert" action:NULL keyEquivalent:@""];
    sub(window, @"New");

    [loc applyStrings:fr toMenu:main];
    same(@"l10n.apply.menu", [main itemAtIndex:0].title, @"Fichier");
    same(@"l10n.apply.command", [file itemAtIndex:0].title, @"Nouveau");
    same(@"l10n.apply.override", [file itemAtIndex:1].title, @"Fermer tout sauf le document actuel");
    same(@"l10n.apply.submenu", [edit itemAtIndex:0].title, @"Insertion");
    same(@"l10n.apply.byParent", [md5 itemAtIndex:0].title, @"Générer...");
    same(@"l10n.apply.unmapped", [window itemAtIndex:0].title, @"Bring All to Front");
    same(@"l10n.apply.leaf-not-group", [window itemAtIndex:1].title, @"Insert");
    same(@"l10n.apply.group-not-leaf", [window itemAtIndex:2].title, @"New");

    [loc applyStrings:nil toMenu:main];
    same(@"l10n.restore.menu", [main itemAtIndex:0].title, @"File");
    same(@"l10n.restore.command", [file itemAtIndex:0].title, @"New");
    same(@"l10n.restore.byParent", [md5 itemAtIndex:0].title, @"Generate…");

    // Everything above drove -applyStrings:toMenu: by hand. The rest is the path the app actually takes: the
    // choice comes out of NSUserDefaults and the menu is kept in step by the NSMenu notifications, which is
    // where the Language/Macro/Run menus — emptied and refilled on every open — get their titles back.
    id noContext = nil;   // none of these commands looks at a context; typed id so -Wnonnull sees a value
    expect([self handlesCommand:(NPPCmd)NPPCmdSettingsUILanguageBase] &&
           ![self handlesCommand:(NPPCmd)(NPPCmdSettingsUILanguageBase + 200)], @"l10n.cmd: wrong tag range");
    expect(![self canPerformCommand:(NPPCmd)(NPPCmdSettingsUILanguageBase + 199) context:noContext],
           @"l10n.cmd: an index with no translation behind it must disable its menu item");
    NSInteger french = -1;
    for (NSUInteger i = 0; i < langs.count; i++) if ([langs[i].fileName isEqualToString:@"french.xml"]) french = (NSInteger)i;

    NSMenu *savedMain = NSApp.mainMenu;            // --selftest runs before any menu is built; put it back anyway
    NSString *savedChoice = loc.currentFileName;
    NSApp.mainMenu = main;
    expect(french >= 0 && [self performCommand:(NPPCmd)(NPPCmdSettingsUILanguageBase + french) context:noContext],
           @"l10n.cmd: selecting french.xml failed");
    same(@"l10n.live.persisted", [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsKey], @"french.xml");
    expect([self commandIsChecked:(NPPCmd)(NPPCmdSettingsUILanguageBase + french) context:noContext],
           @"l10n.cmd: the chosen language is not checked");
    same(@"l10n.live.applied", [file itemAtIndex:0].title, @"Nouveau");

    NSMenuItem *late = [file addItemWithTitle:@"Save" action:NULL keyEquivalent:@""];   // as a menu rebuild does
    same(@"l10n.live.rebuilt", late.title, @"Enregistrer");
    late.title = @"Save (2 files)";                       // as -validateMenuItem: does for a dynamic title, and
    same(@"l10n.live.appOwnsItsTitles", late.title, @"Save (2 files)");   // as AppKit does for NSApp.windowsMenu
    NSMenuItem *macro = [file addItemWithTitle:@"Copy" action:NULL keyEquivalent:@""];
    macro.tag = NPPCmdMacroSavedBase;                     // a macro the user happened to name after a command
    // A real UI string living at the top of a data range (NPPCmdFileClearRecent is NPPCmdFileRecentBase + 99).
    NSMenuItem *clear = [file addItemWithTitle:@"Clear Recent" action:NULL keyEquivalent:@""];
    clear.tag = NPPCmdFileClearRecent;
    [file addItemWithTitle:@"Print…" action:NULL keyEquivalent:@""];      // the next add re-walks and undoes it
    same(@"l10n.live.userDataNeverTranslated", macro.title, @"Copy");
    same(@"l10n.live.notDataJustNearIt", clear.title, @"Vider la liste des fichiers récents");

    [self performCommand:(NPPCmd)NPPCmdSettingsUILanguageBase context:noContext];             // index 0 = English
    same(@"l10n.live.restored", [file itemAtIndex:0].title, @"New");
    loc.currentFileName = savedChoice;
    NSApp.mainMenu = savedMain;
    return fails;
}

@end
