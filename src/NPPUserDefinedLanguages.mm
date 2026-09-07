// NPPUserDefinedLanguages.mm — User Defined Languages: registry, XML I/O, Scintilla apply, define dialog.
// Ports: NppParameters::feedUserLang/feedUserSettings/feedUserKeywordList/feedUserStyles/insertUserLang2Tree,
//        ScintillaEditView::setUserLexer/setSpecialStyle, WinControls/.../UserDefineDialog.
#import "NPPUserDefinedLanguages.h"
#import "NPPDocument.h"
#import "NPPLanguageManager.h"
#import "NPPUtils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <ILexer.h>
#include <Lexilla.h>
#include <SciLexer.h>
#include <string>

// ---------------------------------------------------------------------------------------------------------------
// Name tables (GlobalMappers in UserDefineDialog.h)
// ---------------------------------------------------------------------------------------------------------------

// index == SCE_USER_KWLIST_*, value == the name written to XML (keywordNameMapper, "last write wins" = 2.1 names).
static NSString *const kKwListNames[NPPUDLKeywordListCount] = {
    @"Comments", @"Numbers, prefix1", @"Numbers, prefix2", @"Numbers, extras1", @"Numbers, extras2",
    @"Numbers, suffix1", @"Numbers, suffix2", @"Numbers, range", @"Operators1", @"Operators2",
    @"Folders in code1, open", @"Folders in code1, middle", @"Folders in code1, close",
    @"Folders in code2, open", @"Folders in code2, middle", @"Folders in code2, close",
    @"Folders in comment, open", @"Folders in comment, middle", @"Folders in comment, close",
    @"Keywords1", @"Keywords2", @"Keywords3", @"Keywords4",
    @"Keywords5", @"Keywords6", @"Keywords7", @"Keywords8", @"Delimiters",
};

// index == SCE_USER_STYLE_*, value == the <WordsStyle> name (styleNameMapper, post-2.0 names).
static NSString *const kStyleNames[NPPUDLStyleCount] = {
    @"DEFAULT", @"COMMENTS", @"LINE COMMENTS", @"NUMBERS",
    @"KEYWORDS1", @"KEYWORDS2", @"KEYWORDS3", @"KEYWORDS4", @"KEYWORDS5", @"KEYWORDS6", @"KEYWORDS7", @"KEYWORDS8",
    @"OPERATORS", @"FOLDER IN CODE1", @"FOLDER IN CODE2", @"FOLDER IN COMMENT",
    @"DELIMITERS1", @"DELIMITERS2", @"DELIMITERS3", @"DELIMITERS4",
    @"DELIMITERS5", @"DELIMITERS6", @"DELIMITERS7", @"DELIMITERS8",
};

// keywordIdMapper: every name ever written by N++ (pre-2.0, 2.0, 2.1) -> SCE_USER_KWLIST_*.
static NSDictionary<NSString *, NSNumber *> *KwIdMapper(void) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSInteger i = 0; i < NPPUDLKeywordListCount; i++) d[kKwListNames[i]] = @(i);
        // pre-2.0
        d[@"Operators"] = @(SCE_USER_KWLIST_OPERATORS1);
        d[@"Folder+"] = @(SCE_USER_KWLIST_FOLDERS_IN_CODE1_OPEN);
        d[@"Folder-"] = @(SCE_USER_KWLIST_FOLDERS_IN_CODE1_CLOSE);
        for (int i = 0; i < 4; i++) d[[NSString stringWithFormat:@"Words%d", i + 1]] = @(SCE_USER_KWLIST_KEYWORDS1 + i);
        // 2.0
        d[@"Numbers, additional"] = @(SCE_USER_KWLIST_NUMBER_RANGE);
        d[@"Numbers, prefixes"] = @(SCE_USER_KWLIST_NUMBER_PREFIX2);
        d[@"Numbers, extras with prefixes"] = @(SCE_USER_KWLIST_NUMBER_EXTRAS2);
        d[@"Numbers, suffixes"] = @(SCE_USER_KWLIST_NUMBER_SUFFIX2);
        m = d;
    });
    return m;
}

// styleIdMapper: <WordsStyle name=...> -> SCE_USER_STYLE_*.
static NSDictionary<NSString *, NSNumber *> *StyleIdMapper(void) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSInteger i = 0; i < NPPUDLStyleCount; i++) d[kStyleNames[i]] = @(i);
        d[@"FOLDEROPEN"] = @(SCE_USER_STYLE_FOLDER_IN_CODE1);
        d[@"FOLDERCLOSE"] = @(SCE_USER_STYLE_FOLDER_IN_CODE1);
        d[@"COMMENT"] = @(SCE_USER_STYLE_COMMENT);
        d[@"COMMENT LINE"] = @(SCE_USER_STYLE_COMMENTLINE);
        d[@"NUMBER"] = @(SCE_USER_STYLE_NUMBER);
        d[@"OPERATOR"] = @(SCE_USER_STYLE_OPERATOR);
        for (int i = 0; i < 4; i++) d[[NSString stringWithFormat:@"KEYWORD%d", i + 1]] = @(SCE_USER_STYLE_KEYWORD1 + i);
        for (int i = 0; i < 3; i++) d[[NSString stringWithFormat:@"DELIMINER%d", i + 1]] = @(SCE_USER_STYLE_DELIMITER1 + i);
        m = d;
    });
    return m;
}

// setLexerMapper: keyword lists that LexUser reads as properties instead of SCI_SETKEYWORDS lists.
static const char *SetLexerProperty(NSInteger kwIndex) {
    switch (kwIndex) {
        case SCE_USER_KWLIST_COMMENTS:                return "userDefine.comments";
        case SCE_USER_KWLIST_DELIMITERS:              return "userDefine.delimiters";
        case SCE_USER_KWLIST_OPERATORS1:              return "userDefine.operators1";
        case SCE_USER_KWLIST_NUMBER_PREFIX1:          return "userDefine.numberPrefix1";
        case SCE_USER_KWLIST_NUMBER_PREFIX2:          return "userDefine.numberPrefix2";
        case SCE_USER_KWLIST_NUMBER_EXTRAS1:          return "userDefine.numberExtras1";
        case SCE_USER_KWLIST_NUMBER_EXTRAS2:          return "userDefine.numberExtras2";
        case SCE_USER_KWLIST_NUMBER_SUFFIX1:          return "userDefine.numberSuffix1";
        case SCE_USER_KWLIST_NUMBER_SUFFIX2:          return "userDefine.numberSuffix2";
        case SCE_USER_KWLIST_NUMBER_RANGE:            return "userDefine.numberRange";
        case SCE_USER_KWLIST_FOLDERS_IN_CODE1_OPEN:   return "userDefine.foldersInCode1Open";
        case SCE_USER_KWLIST_FOLDERS_IN_CODE1_MIDDLE: return "userDefine.foldersInCode1Middle";
        case SCE_USER_KWLIST_FOLDERS_IN_CODE1_CLOSE:  return "userDefine.foldersInCode1Close";
        default: return nullptr;
    }
}

static NSString *const kDefaultsImportedFiles = @"NPPUserDefinedLanguagesImportedFiles";
static NSString *const kDefaultsLastDialogLang = @"NPPUserDefinedLanguagesLastEditedLanguage";

static std::string Utf8(NSString *s) { const char *c = s.UTF8String; return c ? std::string(c) : std::string(); }

// Scintilla BGR long -> the "RRGGBB" Notepad++ writes into the XML.
static unsigned long RGBHexFromSci(long c) {
    if (c < 0) return 0;
    return (unsigned long)(((c & 0xFF) << 16) | (((c >> 8) & 0xFF) << 8) | ((c >> 16) & 0xFF));
}

// ---------------------------------------------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------------------------------------------

@implementation NPPUserStyle
- (instancetype)init {
    if ((self = [super init])) {
        _styleID = -1; _name = @""; _fgColor = -1; _bgColor = -1; _colorStyle = 3 /*COLORSTYLE_ALL*/;
        _fontStyle = -1; _fontSize = -1; _nesting = 0;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    NPPUserStyle *c = [NPPUserStyle new];
    c.styleID = _styleID; c.name = _name; c.fgColor = _fgColor; c.bgColor = _bgColor; c.colorStyle = _colorStyle;
    c.fontName = _fontName; c.fontStyle = _fontStyle; c.fontSize = _fontSize; c.nesting = _nesting;
    return c;
}
@end

@implementation NPPUserLanguage {
    NSMutableArray<NSString *> *_kwLists;                       // NPPUDLKeywordListCount entries
    BOOL _isPrefix[NPPUDLKeywordGroupCount];
    NSMutableDictionary<NSNumber *, NPPUserStyle *> *_styles;
}
@synthesize sourceURL = _sourceURL, isEditable = _isEditable;

- (instancetype)init {
    if ((self = [super init])) {
        _name = @"new user define"; _ext = @""; _udlVersion = @"2.1";
        _forcePureLC = 0; _decimalSeparator = 0; _isEditable = YES;
        _kwLists = [NSMutableArray arrayWithCapacity:NPPUDLKeywordListCount];
        for (NSInteger i = 0; i < NPPUDLKeywordListCount; i++) [_kwLists addObject:@""];
        _styles = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    NPPUserLanguage *c = [NPPUserLanguage new];
    c.name = _name; c.ext = _ext; c.udlVersion = _udlVersion; c.isDarkModeTheme = _isDarkModeTheme;
    c.isCaseIgnored = _isCaseIgnored; c.allowFoldOfComments = _allowFoldOfComments; c.foldCompact = _foldCompact;
    c.forcePureLC = _forcePureLC; c.decimalSeparator = _decimalSeparator;
    c->_sourceURL = _sourceURL; c->_isEditable = _isEditable;
    for (NSInteger i = 0; i < NPPUDLKeywordListCount; i++) [c setKeywordList:_kwLists[i] atIndex:i];
    for (NSInteger i = 0; i < NPPUDLKeywordGroupCount; i++) [c setPrefix:_isPrefix[i] forKeywordGroup:i];
    for (NSNumber *k in _styles) c->_styles[k] = [_styles[k] copy];
    return c;
}

- (void)setSourceURL:(NSURL *)url editable:(BOOL)editable { _sourceURL = url; _isEditable = editable; }

- (NSString *)keywordListAtIndex:(NSInteger)index {
    return (index >= 0 && index < NPPUDLKeywordListCount) ? _kwLists[index] : @"";
}
- (void)setKeywordList:(NSString *)list atIndex:(NSInteger)index {
    if (index >= 0 && index < NPPUDLKeywordListCount) _kwLists[index] = [list copy] ?: @"";
}
- (BOOL)isPrefixForKeywordGroup:(NSInteger)g { return (g >= 0 && g < NPPUDLKeywordGroupCount) ? _isPrefix[g] : NO; }
- (void)setPrefix:(BOOL)p forKeywordGroup:(NSInteger)g { if (g >= 0 && g < NPPUDLKeywordGroupCount) _isPrefix[g] = p; }

- (NPPUserStyle *)styleForID:(NSInteger)styleID {
    NPPUserStyle *st = _styles[@(styleID)];
    if (!st) {
        st = [NPPUserStyle new];
        st.styleID = styleID;
        st.name = (styleID >= 0 && styleID < NPPUDLStyleCount) ? kStyleNames[styleID] : @"";
        // feedUserLang: styles missing from the XML get default values (nothing set => inherit STYLE_DEFAULT).
        st.colorStyle = 0;
        _styles[@(styleID)] = st;
    }
    return st;
}

- (NSArray<NPPUserStyle *> *)styles {
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < NPPUDLStyleCount; i++) {
        NPPUserStyle *st = _styles[@(i)];
        if (st) [out addObject:st];
    }
    return out;
}

- (NSArray<NSString *> *)extensions {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *raw in [_ext componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *e = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". \t"]];
        if (e.length) [out addObject:e.lowercaseString];
    }
    return out;
}
@end

// ---------------------------------------------------------------------------------------------------------------
// Encoded keyword lists (Comments + Delimiters): "00tok1 00tok2 01tok 02tok ..."
// Ports of UserDefineDialog.cpp retrieve()/convertTo().
// ---------------------------------------------------------------------------------------------------------------

static NSString *UDLRetrieve(NSString *encoded, const char *prefix, BOOL groupAware) {
    std::string src = Utf8(encoded), dest;
    const char *s = src.c_str();
    bool begin2Copy = false, inGroup = false;
    for (size_t i = 0, len = src.size(); i < len; ++i) {
        if ((i == 0 || s[i - 1] == ' ') && s[i] == prefix[0] && s[i + 1] == prefix[1]) {
            if (!dest.empty()) dest += ' ';
            begin2Copy = true;
            ++i;
            continue;
        }
        if (groupAware) {
            if (s[i] == '(' && s[i + 1] == '(' && !inGroup && begin2Copy) inGroup = true;
            if (i >= 2 && s[i] != ')' && s[i - 1] == ')' && s[i - 2] == ')' && inGroup) inGroup = false;
        }
        if (s[i] == ' ' && begin2Copy) begin2Copy = false;
        if (begin2Copy || inGroup) dest += s[i];
    }
    return [NSString stringWithUTF8String:dest.c_str()] ?: @"";
}

static void UDLConvertTo(std::string &dest, NSString *tokens, const char *prefix) {
    std::string src = Utf8(tokens);
    const char *s = src.c_str();
    bool inGroup = false;
    if (!dest.empty()) dest += ' ';
    dest += prefix[0]; dest += prefix[1];
    for (size_t i = 0, len = src.size(); i < len; ++i) {
        if (i == 0 && s[i] == '(' && s[i + 1] == '(') {
            inGroup = true;
        } else if (s[i] == ' ' && s[i + 1] == '(' && s[i + 2] == '(') {
            inGroup = true;
            dest += ' '; dest += prefix[0]; dest += prefix[1];
            ++i;   // skip space
        }
        if (inGroup && i >= 2 && s[i - 1] == ')' && s[i - 2] == ')') inGroup = false;
        if (s[i] == ' ') {
            if (s[i + 1] != ' ' && s[i + 1] != '\0') {
                dest += ' ';
                if (!inGroup) { dest += prefix[0]; dest += prefix[1]; }
            }
        } else {
            dest += s[i];
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Dialog (declared here, implemented at the bottom)
// ---------------------------------------------------------------------------------------------------------------

@interface NPPUserDefineWindowController : NSWindowController
@property (nonatomic, weak) id<NPPCommandContext> context;
- (void)selectLanguageNamed:(nullable NSString *)name;
- (void)refreshLanguageList;
@end

// One style-editor row: colours (each with its own on/off box, off == leave unset), B/I/U, font/size, and — on
// the styles that can host other tokens — the Nesting group. Declared here so the self-checks can build one.
@interface NPPUDLStyleRow : NSStackView
@property (nonatomic) NSInteger styleID;
@property (nonatomic, weak) id rowTarget;
@property (nonatomic) SEL rowAction;
- (instancetype)initWithStyleID:(NSInteger)styleID title:(NSString *)title compact:(BOOL)compact
                         target:(nullable id)target action:(nullable SEL)action;
- (void)loadFromLanguage:(NPPUserLanguage *)lang;
- (void)storeToLanguage:(NPPUserLanguage *)lang;
- (NSArray<NSNumber *> *)nestingMasksOffered;      // SCE_USER_MASK_NESTING_* of the row's Nesting items; empty when it has none
- (NSArray<NSButton *> *)colourEnableBoxes;        // the Fg / Bg boxes; unchecking one leaves that colour unset
@end

// ---------------------------------------------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------------------------------------------

// Open buffers hold their UDL by name (NPPDocument -userDefinedLanguageName), so renaming or deleting one has to
// move them: otherwise the buffer keeps a name that resolves to nothing — the Language menu ticks nothing, a theme
// change re-styles it as plain text, and the syntax colouring on screen is a ghost of a language that is gone.
// A context is needed to reach the open buffers and this class is a NPPCommandHandler, i.e. it is called with one
// only during command dispatch, so it keeps a weak reference from the documented notification like the other
// modules that need one outside dispatch.
static __weak id<NPPCommandContext> gContext;

@interface NPPUserDefinedLanguages ()
// nil newName == the language is gone: the buffer falls back to whatever built-in language it already had.
- (void)retargetDocumentsFromUserLanguageNamed:(nullable NSString *)oldName to:(nullable NSString *)newName;
@end

// A context that owns nothing but a list of buffers, so +selfCheckFailures can exercise the rename/remove sweeps
// on scratch documents instead of on the user's open tabs.
@interface NPPUDLSelfCheckContext : NSObject <NPPCommandContext>
@property (nonatomic, copy) NSArray<NPPDocument *> *docs;
@end

@implementation NPPUDLSelfCheckContext
- (NPPDocument *)contextCurrentDocument { return _docs.firstObject; }
- (NSArray<NPPDocument *> *)contextOpenDocuments { return _docs ?: @[]; }
- (NSWindow *)contextWindow { return nil; }
- (NPPDocument *)contextOpenFileURL:(NSURL *)url { return nil; }
- (void)contextRevealFileURL:(NSURL *)url line:(NSInteger)line {}
- (void)contextSelectDocument:(NPPDocument *)doc {}
- (void)contextTogglePanel:(id<NPPPanel>)panel {}
- (void)contextShowPanel:(id<NPPPanel>)panel {}
- (BOOL)contextPanelIsVisible:(id<NPPPanel>)panel { return NO; }
- (void)contextRefreshUI {}
- (void)contextReportStatus:(NSString *)message isError:(BOOL)isError {}
@end

@implementation NPPUserDefinedLanguages {
    NSMutableArray<NPPUserLanguage *> *_langs;
    NSMapTable<ScintillaView *, NSString *> *_appliedByEditor;   // what we last put on each editor (weak keys)
    NPPUserDefineWindowController *_dialog;
}

+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NPPCommandContextReadyNotification object:nil queue:nil
                                               usingBlock:^(NSNotification *n) { gContext = n.object; }];
}

+ (instancetype)shared {
    static NPPUserDefinedLanguages *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NPPUserDefinedLanguages new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _langs = [NSMutableArray array];
        _appliedByEditor = [NSMapTable weakToStrongObjectsMapTable];
        [self reload];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeDidChange:)
                                                   name:NPPThemeDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

// The window controller re-applies each buffer's built-in language on a theme change, which wipes our styles.
// Re-apply on the next turn of the run loop (observer order is undefined), to every editor still running "user".
- (void)themeDidChange:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (ScintillaView *ed in [[self->_appliedByEditor keyEnumerator] allObjects]) {
            NSString *name = [self->_appliedByEditor objectForKey:ed];
            char lexer[32] = {0};
            NPPSci(ed, SCI_GETLEXERLANGUAGE, sizeof lexer - 1, (sptr_t)lexer);
            if (name && strcmp(lexer, "user") == 0) [self applyUserLanguageNamed:name toEditor:ed];
        }
    });
}

#pragma mark Directories / loading

- (NSURL *)userLanguageDirectory {
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                              appropriateForURL:nil create:NO error:NULL];
    NSURL *dir = [[base URLByAppendingPathComponent:@"Notepad++"] URLByAppendingPathComponent:@"userDefineLangs"];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

- (NSArray<NSURL *> *)xmlFilesInDirectory:(NSURL *)dir {
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil
                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in all) if ([u.pathExtension.lowercaseString isEqualToString:@"xml"]) [out addObject:u];
    [out sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent caseInsensitiveCompare:b.lastPathComponent];
    }];
    return out;
}

- (void)reload {
    NSMutableArray<NPPUserLanguage *> *langs = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSArray<NPPUserLanguage *> *) = ^(NSArray<NPPUserLanguage *> *found) {
        for (NPPUserLanguage *l in found) {
            if (!l.name.length || [seen containsObject:l.name.lowercaseString]) continue;
            [seen addObject:l.name.lowercaseString];
            [langs addObject:l];
        }
    };
    // User files first: a user copy of a bundled sample wins (same as N++, where the imported one is the live one).
    for (NSURL *u in [self xmlFilesInDirectory:self.userLanguageDirectory])
        add([self parseUDLFile:u editable:YES error:NULL]);
    NSURL *bundled = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"userDefineLangs"];
    if (bundled) for (NSURL *u in [self xmlFilesInDirectory:bundled]) add([self parseUDLFile:u editable:NO error:NULL]);

    [langs sortUsingComparator:^NSComparisonResult(NPPUserLanguage *a, NPPUserLanguage *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    _langs = langs;
    // Every path that can make a UDL disappear ends here — Remove, an import that replaces a file, a file deleted
    // behind the app's back — so this is the one place that has to notice a buffer left pointing at a name that no
    // longer resolves. A rename is the exception: it is a disappearance with a forwarding address, so
    // -renameLang: moves the buffers over before it reloads and they are still resolvable by the time we get here.
    for (NPPDocument *doc in [gContext contextOpenDocuments]) {
        NSString *name = doc.userDefinedLanguageName;
        if (name.length && ![self userLanguageNamed:name]) [self assignUserLanguageNamed:nil toDocument:doc];
    }
    [_dialog refreshLanguageList];
}

- (void)retargetDocumentsFromUserLanguageNamed:(NSString *)oldName to:(NSString *)newName {
    if (!oldName.length || [oldName isEqualToString:newName ?: @""]) return;
    for (NPPDocument *doc in [gContext contextOpenDocuments])
        if ([doc.userDefinedLanguageName isEqualToString:oldName])
            [self assignUserLanguageNamed:newName toDocument:doc];
}

- (NSArray<NPPUserLanguage *> *)userLanguages { return [_langs copy]; }

- (NSArray<NSString *> *)languageNames {
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:_langs.count];
    for (NPPUserLanguage *l in _langs) [names addObject:l.name];
    return names;
}

- (NPPUserLanguage *)userLanguageNamed:(NSString *)name {
    if (!name.length) return nil;
    for (NPPUserLanguage *l in _langs) if ([l.name isEqualToString:name]) return l;
    for (NPPUserLanguage *l in _langs) if ([l.name caseInsensitiveCompare:name] == NSOrderedSame) return l;
    return nil;
}

- (NSString *)userLanguageNameForFileURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if (!ext.length) return nil;
    // getUserDefinedLangNameFromExt: prefer the variant whose darkModeTheme matches the current theme;
    // otherwise fall back to the last extension match.
    BOOL dark = NPPLanguageManager.shared.currentThemeIsDark;
    NSString *fallback = nil;
    for (NPPUserLanguage *l in _langs) {
        if (![[l extensions] containsObject:ext]) continue;
        if (l.isDarkModeTheme == dark) return l.name;
        fallback = l.name;
    }
    return fallback;
}

#pragma mark XML in

// feedUserLang: several <UserLang> per file; a malformed one is skipped, the rest still load.
- (NSArray<NPPUserLanguage *> *)parseUDLFile:(NSURL *)url editable:(BOOL)editable error:(NSError **)error {
    NSError *err = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:url
                                                             options:NSXMLNodeOptionsNone | NSXMLNodePreserveCDATA error:&err];
    if (!doc) { if (error) *error = err; return @[]; }
    NSXMLElement *root = doc.rootElement;
    if (!root || ![root.name isEqualToString:@"NotepadPlus"]) {
        if (error) *error = [NSError errorWithDomain:@"NPPUserDefinedLanguages" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Not a Notepad++ UDL file (no <NotepadPlus> root)."}];
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSXMLElement *e in [root elementsForName:@"UserLang"]) {
        NPPUserLanguage *l = [self parseUserLangElement:e];
        if (!l) continue;
        [l setSourceURL:url editable:editable];
        [out addObject:l];
    }
    if (!out.count && error)
        *error = [NSError errorWithDomain:@"NPPUserDefinedLanguages" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"No usable <UserLang> definition in this file."}];
    return out;
}

static NSString *Attr(NSXMLElement *e, NSString *name) { return [e attributeForName:name].stringValue; }
static BOOL BoolAttr(NSXMLElement *e, NSString *name) {
    NSString *v = Attr(e, name);
    return v && ([v caseInsensitiveCompare:@"yes"] == NSOrderedSame || [v caseInsensitiveCompare:@"true"] == NSOrderedSame);
}
static NSInteger IntAttr(NSXMLElement *e, NSString *name, NSInteger dflt) {
    NSString *v = Attr(e, name);
    if (!v.length) return dflt;
    NSScanner *sc = [NSScanner scannerWithString:v];
    long long n = 0;
    return [sc scanLongLong:&n] ? (NSInteger)n : dflt;
}

- (NPPUserLanguage *)parseUserLangElement:(NSXMLElement *)e {
    NSString *name = Attr(e, @"name");
    if (!name.length) return nil;                       // feedUserLang: "name is missing, just ignore this entry"
    NPPUserLanguage *l = [NPPUserLanguage new];
    l.name = name;
    l.ext = Attr(e, @"ext") ?: @"";
    l.udlVersion = Attr(e, @"udlVersion") ?: @"";
    l.isDarkModeTheme = BoolAttr(e, @"darkModeTheme");

    NSXMLElement *settings = [e elementsForName:@"Settings"].firstObject;
    NSXMLElement *global = [settings elementsForName:@"Global"].firstObject;
    if (global) {
        l.isCaseIgnored = BoolAttr(global, @"caseIgnored");
        l.allowFoldOfComments = BoolAttr(global, @"allowFoldOfComments");
        l.foldCompact = BoolAttr(global, @"foldCompact");
        l.forcePureLC = IntAttr(global, @"forcePureLC", 0);
        l.decimalSeparator = IntAttr(global, @"decimalSeparator", 0);
    }
    NSXMLElement *prefix = [settings elementsForName:@"Prefix"].firstObject;
    if (prefix) {
        BOOL old = !([l.udlVersion isEqualToString:@"2.1"] || [l.udlVersion isEqualToString:@"2.0"]);
        for (NSInteger i = 0; i < NPPUDLKeywordGroupCount; i++) {
            NSString *attr = old ? (i < 4 ? [NSString stringWithFormat:@"words%ld", (long)(i + 1)] : nil)
                                 : kKwListNames[SCE_USER_KWLIST_KEYWORDS1 + i];
            if (attr) [l setPrefix:BoolAttr(prefix, attr) forKeywordGroup:i];
        }
    }

    NSXMLElement *kwl = [e elementsForName:@"KeywordLists"].firstObject;
    if (!kwl) return nil;                               // feedUserLang throws -> entry dropped
    for (NSXMLElement *kw in [kwl elementsForName:@"Keywords"]) {
        NSNumber *idx = KwIdMapper()[Attr(kw, @"name") ?: @""];
        if (idx) [l setKeywordList:(kw.stringValue ?: @"") atIndex:idx.integerValue];
        // ponytail: pre-2.0 ("Comment"/6-char "Delimiters") re-encoding is not ported — those files are 2010-era.
    }

    NSXMLElement *styles = [e elementsForName:@"Styles"].firstObject;
    if (!styles) return nil;
    for (NSXMLElement *ws in [styles elementsForName:@"WordsStyle"]) {
        NSNumber *idx = StyleIdMapper()[Attr(ws, @"name") ?: @""];
        if (!idx) continue;
        NPPUserStyle *st = [l styleForID:idx.integerValue];
        NSString *fg = Attr(ws, @"fgColor"), *bg = Attr(ws, @"bgColor"), *font = Attr(ws, @"fontName");
        st.fgColor = fg ? NPPColorFromHex(fg) : -1;
        st.bgColor = bg ? NPPColorFromHex(bg) : -1;
        st.colorStyle = IntAttr(ws, @"colorStyle", 3);
        st.fontName = font.length ? font : nil;
        st.fontStyle = IntAttr(ws, @"fontStyle", -1);
        st.fontSize = IntAttr(ws, @"fontSize", -1);
        st.nesting = IntAttr(ws, @"nesting", 0);
    }
    return l;
}

#pragma mark XML out

- (NSXMLElement *)elementForUserLanguage:(NPPUserLanguage *)l {
    NSXMLElement *root = [NSXMLElement elementWithName:@"UserLang"];
    void (^attr)(NSXMLElement *, NSString *, NSString *) = ^(NSXMLElement *e, NSString *n, NSString *v) {
        [e addAttribute:[NSXMLNode attributeWithName:n stringValue:v ?: @""]];
    };
    attr(root, @"name", l.name);
    attr(root, @"ext", l.ext);
    if (l.isDarkModeTheme) attr(root, @"darkModeTheme", @"yes");
    attr(root, @"udlVersion", l.udlVersion.length ? l.udlVersion : @"2.1");

    NSXMLElement *settings = [NSXMLElement elementWithName:@"Settings"];
    NSXMLElement *global = [NSXMLElement elementWithName:@"Global"];
    attr(global, @"caseIgnored", l.isCaseIgnored ? @"yes" : @"no");
    attr(global, @"allowFoldOfComments", l.allowFoldOfComments ? @"yes" : @"no");
    attr(global, @"foldCompact", l.foldCompact ? @"yes" : @"no");
    attr(global, @"forcePureLC", [@(l.forcePureLC) stringValue]);
    attr(global, @"decimalSeparator", [@(l.decimalSeparator) stringValue]);
    [settings addChild:global];
    NSXMLElement *prefix = [NSXMLElement elementWithName:@"Prefix"];
    for (NSInteger i = 0; i < NPPUDLKeywordGroupCount; i++)
        attr(prefix, kKwListNames[SCE_USER_KWLIST_KEYWORDS1 + i], [l isPrefixForKeywordGroup:i] ? @"yes" : @"no");
    [settings addChild:prefix];
    [root addChild:settings];

    NSXMLElement *kwl = [NSXMLElement elementWithName:@"KeywordLists"];
    for (NSInteger i = 0; i < NPPUDLKeywordListCount; i++) {
        NSXMLElement *kw = [NSXMLElement elementWithName:@"Keywords"];
        attr(kw, @"name", kKwListNames[i]);
        [kw setStringValue:[l keywordListAtIndex:i]];
        [kwl addChild:kw];
    }
    [root addChild:kwl];

    NSXMLElement *styles = [NSXMLElement elementWithName:@"Styles"];
    for (NPPUserStyle *st in [l styles]) {
        if (st.styleID < 0) continue;
        NSXMLElement *ws = [NSXMLElement elementWithName:@"WordsStyle"];
        attr(ws, @"name", st.name.length ? st.name : kStyleNames[st.styleID]);
        // N++ (UserLangContainer's copy ctor) turns "unset" into black fg / white bg before writing.
        attr(ws, @"fgColor", [NSString stringWithFormat:@"%06lX", st.fgColor >= 0 ? RGBHexFromSci(st.fgColor) : 0UL]);
        attr(ws, @"bgColor", [NSString stringWithFormat:@"%06lX", st.bgColor >= 0 ? RGBHexFromSci(st.bgColor) : 0xFFFFFFUL]);
        if (st.colorStyle != 3) attr(ws, @"colorStyle", [@(st.colorStyle) stringValue]);
        attr(ws, @"fontName", st.fontName ?: @"");
        attr(ws, @"fontStyle", st.fontStyle < 0 ? @"0" : [@(st.fontStyle) stringValue]);
        if (st.fontSize >= 0) attr(ws, @"fontSize", st.fontSize == 0 ? @"" : [@(st.fontSize) stringValue]);
        attr(ws, @"nesting", [@(st.nesting) stringValue]);
        [styles addChild:ws];
    }
    [root addChild:styles];
    return root;
}

- (NSData *)xmlDataForUserLanguages:(NSArray<NPPUserLanguage *> *)langs {
    NSXMLElement *root = [NSXMLElement elementWithName:@"NotepadPlus"];
    for (NPPUserLanguage *l in langs) [root addChild:[self elementForUserLanguage:l]];
    NSXMLDocument *doc = [NSXMLDocument documentWithRootElement:root];
    doc.version = @"1.0";
    doc.characterEncoding = @"UTF-8";
    return [doc XMLDataWithOptions:NSXMLNodePrettyPrint | NSXMLNodeCompactEmptyElement];
}

- (BOOL)writeUserLanguages:(NSArray<NPPUserLanguage *> *)langs toURL:(NSURL *)url error:(NSError **)error {
    BOOL ok = [[self xmlDataForUserLanguages:langs] writeToURL:url options:NSDataWritingAtomic error:error];
    if (ok) [self rememberImportedFile:url];
    return ok;
}

- (BOOL)saveUserLanguage:(NPPUserLanguage *)lang error:(NSError **)error {
    if (!lang) return NO;
    NSURL *dest = lang.sourceURL;
    if (!lang.isEditable || !dest) {                   // bundled sample (or brand new): write our own copy
        NSString *file = [NSString stringWithFormat:@"%@.udl.xml", [self safeFileNameForName:lang.name]];
        dest = [self.userLanguageDirectory URLByAppendingPathComponent:file];
        [lang setSourceURL:dest editable:YES];
    }
    // Keep every sibling UDL that lives in the same file.
    NSMutableArray *group = [NSMutableArray array];
    for (NPPUserLanguage *l in _langs)
        if (l == lang || [l.sourceURL.path isEqualToString:dest.path]) [group addObject:l];
    if (![group containsObject:lang]) [group addObject:lang];
    return [self writeUserLanguages:group toURL:dest error:error];
}

- (BOOL)removeUserLanguageNamed:(NSString *)name error:(NSError **)error {
    NPPUserLanguage *l = [self userLanguageNamed:name];
    if (!l || !l.isEditable) {
        if (error) *error = [NSError errorWithDomain:@"NPPUserDefinedLanguages" code:4
                                            userInfo:@{NSLocalizedDescriptionKey: l ? @"This language is bundled with the application."
                                                                                    : @"No such user defined language."}];
        return NO;
    }
    NSURL *src = l.sourceURL;
    [_langs removeObject:l];
    NSMutableArray *siblings = [NSMutableArray array];
    for (NPPUserLanguage *other in _langs)
        if (src && [other.sourceURL.path isEqualToString:src.path]) [siblings addObject:other];

    BOOL ok = YES;
    if (siblings.count) ok = [self writeUserLanguages:siblings toURL:src error:error];
    else if (src) ok = [NSFileManager.defaultManager removeItemAtURL:src error:error];
    [self reload];
    return ok;
}

- (NSString *)safeFileNameForName:(NSString *)name {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSString *s = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : @"userDefineLang";
}

- (void)rememberImportedFile:(NSURL *)url {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray *files = [([d arrayForKey:kDefaultsImportedFiles] ?: @[]) mutableCopy];
    if (![files containsObject:url.lastPathComponent]) {
        [files addObject:url.lastPathComponent];
        [d setObject:files forKey:kDefaultsImportedFiles];
    }
    // ponytail: the directory listing is the source of truth; this key only records what we put there.
}

- (BOOL)importUDLFromURL:(NSURL *)url error:(NSError **)error {
    NSArray<NPPUserLanguage *> *found = [self parseUDLFile:url editable:YES error:error];
    if (!found.count) return NO;
    NSURL *dest = [self.userLanguageDirectory URLByAppendingPathComponent:url.lastPathComponent];
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:dest.path] && i < 100; i++) {
        NSString *base = [url.lastPathComponent stringByDeletingPathExtension];
        dest = [self.userLanguageDirectory URLByAppendingPathComponent:
                [NSString stringWithFormat:@"%@-%d.%@", base, i, url.pathExtension ?: @"xml"]];
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data || ![data writeToURL:dest options:NSDataWritingAtomic error:error]) return NO;
    [self rememberImportedFile:dest];
    [self reload];
    return YES;
}

- (BOOL)exportUserLanguageNamed:(NSString *)name toURL:(NSURL *)url error:(NSError **)error {
    NPPUserLanguage *l = [self userLanguageNamed:name];
    if (!l) {
        if (error) *error = [NSError errorWithDomain:@"NPPUserDefinedLanguages" code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"No such user defined language."}];
        return NO;
    }
    return [[self xmlDataForUserLanguages:@[l]] writeToURL:url options:NSDataWritingAtomic error:error];
}

#pragma mark Apply — port of ScintillaEditView::setUserLexer()

static inline void SetProp(ScintillaView *ed, const char *key, const char *val) {
    NPPSci(ed, SCI_SETPROPERTY, (uptr_t)key, (sptr_t)val);
}
static inline void SetPropInt(ScintillaView *ed, const char *key, long value) {
    char buf[32];
    snprintf(buf, sizeof buf, "%ld", value);
    SetProp(ed, key, buf);
}

// The quote/escape transform setUserLexer applies to every list that goes through SCI_SETKEYWORDS:
// quoted runs keep their inner whitespace, encoded as \v (double quotes) or \b (single quotes).
static std::string TransformKeywordList(const std::string &in) {
    std::string out;
    out.reserve(in.size());
    const char *s = in.c_str();
    bool inDouble = false, inSingle = false, nonWSFound = false;
    for (size_t j = 0, len = in.size(); j < len; ++j) {
        if (!inSingle && s[j] == '"') { inDouble = !inDouble; continue; }
        if (!inDouble && s[j] == '\'') { inSingle = !inSingle; continue; }
        if (s[j] == '\\' && (s[j + 1] == '"' || s[j + 1] == '\'' || s[j + 1] == '\\')) { ++j; out += s[j]; continue; }
        if (inDouble || inSingle) {
            if (s[j] > ' ') { out += s[j]; nonWSFound = true; }
            else if (nonWSFound && j >= 1 && s[j - 1] != '"' && s[j + 1] != '"' && s[j + 1] > ' ')
                out += inDouble ? '\v' : '\b';
        } else {
            out += s[j];
        }
    }
    return out;
}

// setSpecialStyle, honouring colorStyle exactly like N++ does for UDL styles.
- (void)applyStyle:(NPPUserStyle *)st toEditor:(ScintillaView *)ed {
    if (!st || st.styleID < 0 || st.styleID > STYLE_MAX) return;
    uptr_t sid = (uptr_t)st.styleID;
    if ((st.colorStyle & 1) && st.fgColor >= 0) NPPSci(ed, SCI_STYLESETFORE, sid, st.fgColor);
    if ((st.colorStyle & 2) && st.bgColor >= 0) NPPSci(ed, SCI_STYLESETBACK, sid, st.bgColor);
    if (st.fontName.length) {
        NSString *font = NPPFontIsAvailable(st.fontName) ? st.fontName : NPPDefaultMonospaceFontName();
        NPPSciStr(ed, SCI_STYLESETFONT, sid, font.UTF8String);
    }
    if (st.fontStyle >= 0) {
        NPPSci(ed, SCI_STYLESETBOLD, sid, (st.fontStyle & 1) != 0);
        NPPSci(ed, SCI_STYLESETITALIC, sid, (st.fontStyle & 2) != 0);
        NPPSci(ed, SCI_STYLESETUNDERLINE, sid, (st.fontStyle & 4) != 0);
    }
    // XML sizes are Windows 96dpi points, like every other styler in this app.
    if (st.fontSize > 0) NPPSci(ed, SCI_STYLESETSIZE, sid, (int)lround(st.fontSize * 96.0 / 72.0));
}

- (BOOL)applyUserLanguageNamed:(NSString *)name toEditor:(ScintillaView *)ed {
    NPPUserLanguage *l = [self userLanguageNamed:name];
    if (!l || !ed) return NO;

    // defineDocType's prologue/epilogue (default style, STYLECLEARALL, global styles) via the normal-text language.
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    [lm applyLanguage:lm.normalTextLanguage toEditor:ed];

    Scintilla::ILexer5 *lx = CreateLexer("user");
    if (!lx) return NO;
    NPPSci(ed, SCI_SETILEXER, 0, (sptr_t)lx);

    SetProp(ed, "fold", "1");
    SetProp(ed, "userDefine.isCaseIgnored", l.isCaseIgnored ? "1" : "0");
    SetProp(ed, "userDefine.allowFoldOfComments", l.allowFoldOfComments ? "1" : "0");
    SetProp(ed, "userDefine.foldCompact", l.foldCompact ? "1" : "0");
    for (int i = 0; i < NPPUDLKeywordGroupCount; i++) {
        char key[40];
        snprintf(key, sizeof key, "userDefine.prefixKeywords%d", i + 1);
        SetProp(ed, key, [l isPrefixForKeywordGroup:i] ? "1" : "0");
    }

    int keywordsCounter = 0;
    for (NSInteger i = 0; i < NPPUDLKeywordListCount; i++) {
        std::string kw = Utf8([l keywordListAtIndex:i]);
        if (const char *prop = SetLexerProperty(i)) {
            SetProp(ed, prop, kw.c_str());
        } else {
            std::string transformed = TransformKeywordList(kw);
            NPPSciStr(ed, SCI_SETKEYWORDS, (uptr_t)keywordsCounter++, transformed.c_str());
        }
    }

    SetPropInt(ed, "userDefine.forcePureLC", (long)l.forcePureLC);
    SetPropInt(ed, "userDefine.decimalSeparator", (long)l.decimalSeparator);
    // LexUser only uses these two as cache keys (per-UDL keyword vectors / per-buffer nesting state).
    // ponytail: N++ passes pointer values; stable per-object ids do the same job here.
    SetPropInt(ed, "userDefine.udlName", (long)((NSUInteger)l.hash & 0x7FFFFFFF));
    SetPropInt(ed, "userDefine.currentBufferID", (long)(((uintptr_t)(__bridge void *)ed >> 4) & 0x7FFFFFFF));

    for (NPPUserStyle *st in [l styles]) {
        if (st.styleID < 0) continue;
        char key[40];
        snprintf(key, sizeof key, "userDefine.nesting.%02d", (int)st.styleID);
        SetPropInt(ed, key, (long)st.nesting);
        [self applyStyle:st toEditor:ed];
    }
    NPPSci(ed, SCI_COLOURISE, 0, -1);    // LexUser rebuilds its cached token vectors only when startPos == 0
    [_appliedByEditor setObject:l.name forKey:ed];
    return YES;
}

#pragma mark Per-document assignment (NPPDocument owns the state; these are conveniences over it)

- (NSString *)userLanguageNameForDocument:(NPPDocument *)doc { return doc.userDefinedLanguageName; }

- (BOOL)assignUserLanguageNamed:(NSString *)name toDocument:(NPPDocument *)doc {
    if (!doc) return NO;
    if (!name.length) {                                              // the setter clears the UDL and re-applies the built-in lexer
        doc.language = doc.language ?: NPPLanguageManager.shared.normalTextLanguage;
        return YES;
    }
    if (![self userLanguageNamed:name]) return NO;
    return [doc applyUserDefinedLanguageNamed:name];
}

- (BOOL)reapplyUserLanguageToDocument:(NPPDocument *)doc {
    NSString *name = doc.userDefinedLanguageName;
    if (!name) return NO;
    return [self applyUserLanguageNamed:name toEditor:doc.editor];
}

#pragma mark Dialog

- (void)showDefineDialogWithContext:(id<NPPCommandContext>)context {
    if (!_dialog) _dialog = [[NPPUserDefineWindowController alloc] initWithWindow:nil];
    _dialog.context = context;
    [_dialog refreshLanguageList];
    NSString *current = [context contextCurrentDocument].userDefinedLanguageName
                     ?: [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsLastDialogLang];
    [_dialog selectLanguageNamed:current];
    [_dialog showWindow:nil];
    [_dialog.window makeKeyAndOrderFront:nil];
}

#pragma mark NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    if (cmd == NPPCmdLangDefineDialog || cmd == NPPCmdLangImportUDL || cmd == NPPCmdLangExportUDL) return YES;
    return cmd >= NPPCmdLangUserDefinedBase && cmd < NPPCmdLangUserDefinedBase + 100;
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPUserDefinedLanguages *me = [self shared];
    if (cmd == NPPCmdLangDefineDialog || cmd == NPPCmdLangImportUDL) return YES;
    if (cmd == NPPCmdLangExportUDL) return me.languageNames.count > 0;
    if (![self handlesCommand:cmd]) return NO;
    NSInteger idx = cmd - NPPCmdLangUserDefinedBase;
    return idx >= 0 && idx < (NSInteger)me.languageNames.count && [context contextCurrentDocument] != nil;
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd < NPPCmdLangUserDefinedBase || ![self handlesCommand:cmd]) return NO;
    NPPUserDefinedLanguages *me = [self shared];
    NSInteger idx = cmd - NPPCmdLangUserDefinedBase;
    if (idx < 0 || idx >= (NSInteger)me.languageNames.count) return NO;
    NSString *current = [context contextCurrentDocument].userDefinedLanguageName;
    return current && [current isEqualToString:me.languageNames[idx]];
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPUserDefinedLanguages *me = [self shared];
    if (![self handlesCommand:cmd]) return NO;

    if (cmd == NPPCmdLangDefineDialog) { [me showDefineDialogWithContext:context]; return YES; }

    if (cmd == NPPCmdLangImportUDL) {
        NSOpenPanel *p = [NSOpenPanel openPanel];
        p.allowedContentTypes = @[UTTypeXML];
        p.allowsMultipleSelection = YES;
        p.message = NSLocalizedString(@"Select the user defined language XML file(s) to import.", nil);
        if ([p runModal] != NSModalResponseOK) return YES;
        NSInteger ok = 0;
        NSError *err = nil;
        for (NSURL *u in p.URLs) if ([me importUDLFromURL:u error:&err]) ok++;
        if (ok) {
            [context contextReportStatus:[NSString stringWithFormat:
                NSLocalizedString(@"Import successful: %ld file(s).", nil), (long)ok] isError:NO];
            [context contextRefreshUI];
        } else {
            [self presentError:err fallback:NSLocalizedString(@"Failed to import UDL.", nil) context:context];
        }
        return YES;
    }

    if (cmd == NPPCmdLangExportUDL) {
        NSString *name = [me chooseLanguageNameForExportInWindow:[context contextWindow]];
        if (!name) return YES;
        NSSavePanel *p = [NSSavePanel savePanel];
        p.allowedContentTypes = @[UTTypeXML];
        p.nameFieldStringValue = [NSString stringWithFormat:@"%@.udl.xml", [me safeFileNameForName:name]];
        if ([p runModal] != NSModalResponseOK || !p.URL) return YES;
        NSError *err = nil;
        if ([me exportUserLanguageNamed:name toURL:p.URL error:&err])
            [context contextReportStatus:NSLocalizedString(@"Export successful.", nil) isError:NO];
        else
            [self presentError:err fallback:NSLocalizedString(@"Failed to export UDL.", nil) context:context];
        return YES;
    }

    NSInteger idx = cmd - NPPCmdLangUserDefinedBase;
    NSArray<NSString *> *names = me.languageNames;
    if (idx < 0 || idx >= (NSInteger)names.count) return NO;
    NPPDocument *doc = [context contextCurrentDocument];
    if (!doc || ![me assignUserLanguageNamed:names[idx] toDocument:doc]) return NO;
    [context contextRefreshUI];
    return YES;
}

+ (void)presentError:(NSError *)err fallback:(NSString *)fallback context:(id<NPPCommandContext>)context {
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = fallback;
    a.informativeText = err.localizedDescription ?: @"";
    NSWindow *w = [context contextWindow];
    if (w) [a beginSheetModalForWindow:w completionHandler:nil]; else [a runModal];
}

// Small chooser for File > Export UDL (N++ shows a combo in its own dialog).
- (NSString *)chooseLanguageNameForExportInWindow:(NSWindow *)window {
    NSArray<NSString *> *names = self.languageNames;
    if (!names.count) return nil;
    if (names.count == 1) return names.firstObject;
    NSAlert *a = [NSAlert new];
    a.messageText = NSLocalizedString(@"Export user defined language", nil);
    a.informativeText = NSLocalizedString(@"Which language do you want to export?", nil);
    [a addButtonWithTitle:NSLocalizedString(@"Export", nil)];
    [a addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 25) pullsDown:NO];
    [pop addItemsWithTitles:names];
    a.accessoryView = pop;
    return [a runModal] == NSAlertFirstButtonReturn ? pop.titleOfSelectedItem : nil;
}

#pragma mark - Self-checks

// The registry reaches open buffers through the command context; the checks below need one that answers with
// buffers of their own, so the app's real tabs are never touched by a self-check.
+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *f = [NSMutableArray array];
    NPPUserDefinedLanguages *reg = [self shared];
    NSString *const first = @"npp self-check UDL", *const renamed = @"npp self-check UDL renamed";

    static NSWindow *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
        host.releasedWhenClosed = NO;
    });
    NPPDocument *doc = [[NPPDocument alloc] initUntitled];
    if (!doc.editor) return @[@"could not make a scratch buffer for the self-check"];
    doc.editor.frame = NSMakeRect(0, 0, 400, 300);
    [host.contentView addSubview:doc.editor];

    NPPUDLSelfCheckContext *stub = [NPPUDLSelfCheckContext new];
    stub.docs = @[doc];
    id<NPPCommandContext> realContext = gContext;
    gContext = (id<NPPCommandContext>)stub;

    // A real UDL on disk, because the funnel under test is -reload, which only ever sees the directory.
    NPPUserLanguage *lang = [NPPUserLanguage new];
    lang.name = first;
    lang.ext = @"nppselfcheckudl";
    NSError *err = nil;
    if (![reg saveUserLanguage:lang error:&err]) {
        [f addObject:[NSString stringWithFormat:@"could not write a UDL into %@: %@",
                      reg.userLanguageDirectory.path, err.localizedDescription ?: @"?"]];
    } else {
        NSURL *file = lang.sourceURL;
        [reg reload];
        if (![reg assignUserLanguageNamed:first toDocument:doc] ||
            ![doc.userDefinedLanguageName isEqualToString:first]) {
            [f addObject:@"a freshly written UDL could not be applied to a buffer"];
        } else {
            // Rename: the buffer follows the language instead of keeping a name that no longer exists.
            NPPUserLanguage *live = [reg userLanguageNamed:first];
            live.name = renamed;
            [reg saveUserLanguage:live error:NULL];
            [reg retargetDocumentsFromUserLanguageNamed:first to:renamed];
            [reg reload];
            if (![doc.userDefinedLanguageName isEqualToString:renamed])
                [f addObject:[NSString stringWithFormat:@"renaming a UDL left an open buffer on %@, want %@",
                              doc.userDefinedLanguageName ?: @"(none)", renamed]];

            // Remove: the buffer drops back to a built-in language rather than pointing at a deleted one.
            if (![reg removeUserLanguageNamed:renamed error:&err])
                [f addObject:[NSString stringWithFormat:@"could not remove the self-check UDL: %@",
                              err.localizedDescription ?: @"?"]];
            if (doc.userDefinedLanguageName)
                [f addObject:[NSString stringWithFormat:@"removing a UDL left an open buffer on %@",
                              doc.userDefinedLanguageName]];
            if (!doc.language)
                [f addObject:@"a buffer whose UDL was removed has no language at all"];
        }
        // Whatever went wrong above, the file must not survive the check.
        [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
        if ([reg userLanguageNamed:first] || [reg userLanguageNamed:renamed])
            [f addObject:@"the self-check UDL is still registered"];
    }

    gContext = realContext;
    [doc.editor removeFromSuperview];
    [reg reload];

    // The styler rows must carry the two things the Windows styler popup has and a UDL cannot be described
    // without: the Nesting group, and a way to leave a colour unset. Assert the controls exist, then that
    // they round-trip — a row that showed the boxes but dropped them on store would be the same bug.
    NPPUserLanguage *probe = [NPPUserLanguage new];
    NPPUDLStyleRow *(^row)(NSInteger, BOOL) = ^(NSInteger styleID, BOOL compact) {
        return [[NPPUDLStyleRow alloc] initWithStyleID:styleID title:@"" compact:compact target:nil action:NULL];
    };
    NPPUDLStyleRow *commentRow = row(SCE_USER_STYLE_COMMENT, NO);
    NSArray<NSNumber *> *masks = [commentRow nestingMasksOffered];
    NSInteger offered = 0;
    for (NSNumber *m in masks) offered |= m.integerValue;
    // The 21 boxes of UserDefineResource.h: 8 delimiters, 2 comments, 8 keywords, 2 operators, numbers.
    if (masks.count != 21 || offered != 0x0703FFFF)
        [f addObject:[NSString stringWithFormat:@"the UDL styler offers %lu Nesting items (mask %#lx), want 21 (0x703FFFF)",
                      (unsigned long)masks.count, (long)offered]];
    if ([row(SCE_USER_STYLE_DELIMITER1, YES) nestingMasksOffered].count != masks.count)
        [f addObject:@"delimiter styles have no Nesting group in the UDL styler"];
    if ([row(SCE_USER_STYLE_KEYWORD1, NO) nestingMasksOffered].count)
        [f addObject:@"the UDL styler offers Nesting on a keyword style, where N++ greys the whole group out"];

    NPPUserStyle *probeStyle = [probe styleForID:SCE_USER_STYLE_COMMENT];
    probeStyle.nesting = SCE_USER_MASK_NESTING_KEYWORD1 | SCE_USER_MASK_NESTING_NUMBERS;
    probeStyle.colorStyle = 3;
    [commentRow loadFromLanguage:probe];
    probeStyle.nesting = SCE_USER_MASK_NESTING_NONE;
    [commentRow storeToLanguage:probe];
    if (probeStyle.nesting != (SCE_USER_MASK_NESTING_KEYWORD1 | SCE_USER_MASK_NESTING_NUMBERS))
        [f addObject:[NSString stringWithFormat:@"the UDL styler's Nesting items do not round-trip: got %#lx",
                      (long)probeStyle.nesting]];

    NSArray<NSButton *> *boxes = [commentRow colourEnableBoxes];
    if (boxes.count != 2 || !boxes[0] || !boxes[1]) {
        [f addObject:@"the UDL styler has no per-colour on/off box, so no colour can be left unset"];
    } else {
        boxes[0].state = NSControlStateValueOff;                    // leave the foreground to the default style
        [commentRow storeToLanguage:probe];
        if (probeStyle.colorStyle != 2)
            [f addObject:[NSString stringWithFormat:@"unchecking the UDL styler's Fg box left colorStyle %ld, want 2",
                          (long)probeStyle.colorStyle]];
        [commentRow loadFromLanguage:probe];
        if (boxes[0].state != NSControlStateValueOff || boxes[1].state != NSControlStateValueOn)
            [f addObject:@"the UDL styler does not show back which colours a style leaves unset"];
    }
    return f;
}

@end

// ---------------------------------------------------------------------------------------------------------------
// Dialog: one reusable style-editor row
// ---------------------------------------------------------------------------------------------------------------

// The Nesting group of UserDefineResource.h's styler popup, in its order: what may appear inside this region.
static void UDLEnumerateNestingMasks(void (^body)(NSInteger mask, NSString *title)) {
    for (int i = 0; i < 8; i++)
        body(SCE_USER_MASK_NESTING_DELIMITER1 << i, [NSString stringWithFormat:NSLocalizedString(@"Delimiter %d", nil), i + 1]);
    body(SCE_USER_MASK_NESTING_COMMENT, NSLocalizedString(@"Comment", nil));
    body(SCE_USER_MASK_NESTING_COMMENT_LINE, NSLocalizedString(@"Comment line", nil));
    for (int i = 0; i < 8; i++)
        body(SCE_USER_MASK_NESTING_KEYWORD1 << i, [NSString stringWithFormat:NSLocalizedString(@"Keywords %d", nil), i + 1]);
    body(SCE_USER_MASK_NESTING_OPERATORS1, NSLocalizedString(@"Operators 1", nil));
    body(SCE_USER_MASK_NESTING_OPERATORS2, NSLocalizedString(@"Operators 2", nil));
    body(SCE_USER_MASK_NESTING_NUMBERS, NSLocalizedString(@"Numbers", nil));
}

// Nesting is offered exactly where UserDefineDialog.cpp offers it: comments and delimiters. Every other
// StylerDlg there is constructed with SCE_USER_MASK_NESTING_NONE, i.e. the whole group greyed out.
static BOOL UDLStyleCanNest(NSInteger styleID) {
    return styleID == SCE_USER_STYLE_COMMENT || styleID == SCE_USER_STYLE_COMMENTLINE
        || (styleID >= SCE_USER_STYLE_DELIMITER1 && styleID <= SCE_USER_STYLE_DELIMITER8);
}

@implementation NPPUDLStyleRow {
    NSColorWell *_fg, *_bg;
    NSButton *_fgOn, *_bgOn;
    NSButton *_bold, *_italic, *_underline;
    NSPopUpButton *_font, *_size, *_nesting;
    BOOL _compact;
}

- (instancetype)initWithStyleID:(NSInteger)styleID title:(NSString *)title compact:(BOOL)compact
                         target:(id)target action:(SEL)action {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _styleID = styleID; _rowTarget = target; _rowAction = action; _compact = compact;
        self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.alignment = NSLayoutAttributeCenterY;
        self.spacing = 6;
        if (title.length) {
            NSTextField *label = [NSTextField labelWithString:title];
            label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            [self addArrangedSubview:label];
        }
        _fgOn = [self addColourBox:NSLocalizedString(@"Fg", nil)
                               tip:NSLocalizedString(@"Uncheck to leave the foreground colour unset — the default style shows through.", nil)];
        _fg = [self addWell:NSLocalizedString(@"Foreground colour", nil)];
        _bgOn = [self addColourBox:NSLocalizedString(@"Bg", nil)
                               tip:NSLocalizedString(@"Uncheck to leave the background colour unset — the default style shows through.", nil)];
        _bg = [self addWell:NSLocalizedString(@"Background colour", nil)];
        _bold = [self addToggle:@"B"];
        _bold.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
        _italic = [self addToggle:@"I"];
        _underline = [self addToggle:@"U"];
        if (!compact) {
            _font = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            [_font addItemWithTitle:NSLocalizedString(@"Default font", nil)];
            [_font addItemsWithTitles:NSFontManager.sharedFontManager.availableFontFamilies];
            _font.target = self; _font.action = @selector(changed:);
            _font.controlSize = NSControlSizeSmall;
            _font.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            [_font.widthAnchor constraintLessThanOrEqualToConstant:170].active = YES;
            [self addArrangedSubview:_font];

            _size = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            [_size addItemWithTitle:NSLocalizedString(@"Default size", nil)];
            for (int s = 5; s <= 24; s++) [_size addItemWithTitle:[@(s) stringValue]];
            _size.target = self; _size.action = @selector(changed:);
            _size.controlSize = NSControlSizeSmall;
            _size.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            [self addArrangedSubview:_size];
        }
        // ponytail: the Nesting group is a pull-down of ticked items rather than 21 loose checkboxes — these rows
        // are inline, not the separate popup N++ opens per style. Give it its own panel if the list ever grows.
        if (UDLStyleCanNest(styleID)) {
            _nesting = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
            _nesting.controlSize = NSControlSizeSmall;
            _nesting.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            _nesting.toolTip = NSLocalizedString(@"Nesting: what may appear inside this styled region.", nil);
            [_nesting.menu addItemWithTitle:NSLocalizedString(@"Nesting", nil) action:NULL keyEquivalent:@""];
            NSMenu *menu = _nesting.menu;
            NPPUDLStyleRow *me = self;
            UDLEnumerateNestingMasks(^(NSInteger mask, NSString *title) {
                NSMenuItem *mi = [menu addItemWithTitle:title action:@selector(nestingToggled:) keyEquivalent:@""];
                mi.target = me;
                mi.tag = mask;
            });
            [self addArrangedSubview:_nesting];
        }
    }
    return self;
}

- (NSButton *)addColourBox:(NSString *)title tip:(NSString *)tip {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:@selector(colourEnableChanged:)];
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    b.state = NSControlStateValueOn;
    b.toolTip = tip;
    [self addArrangedSubview:b];
    return b;
}

- (NSColorWell *)addWell:(NSString *)tip {
    NSColorWell *w = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
    w.toolTip = tip;
    w.target = self; w.action = @selector(changed:);
    w.continuous = NO;
    [w.widthAnchor constraintEqualToConstant:38].active = YES;
    [w.heightAnchor constraintEqualToConstant:22].active = YES;
    [self addArrangedSubview:w];
    return w;
}

- (NSButton *)addToggle:(NSString *)title {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:@selector(changed:)];
    b.bezelStyle = NSBezelStyleRounded;
    b.buttonType = NSButtonTypePushOnPushOff;
    b.controlSize = NSControlSizeSmall;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [self addArrangedSubview:b];
    return b;
}

- (void)loadFromLanguage:(NPPUserLanguage *)lang {
    NPPUserStyle *st = [lang styleForID:_styleID];
    _fg.color = NPPNSColorFromSci(st.fgColor) ?: NSColor.textColor;
    _bg.color = NPPNSColorFromSci(st.bgColor) ?: NSColor.textBackgroundColor;
    _fgOn.state = (st.colorStyle & 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _bgOn.state = (st.colorStyle & 2) ? NSControlStateValueOn : NSControlStateValueOff;
    _fg.enabled = (_fgOn.state == NSControlStateValueOn);
    _bg.enabled = (_bgOn.state == NSControlStateValueOn);
    for (NSMenuItem *mi in _nesting.itemArray)
        if (mi.tag) mi.state = (st.nesting & mi.tag) ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateNestingTitle];
    _bold.state = (st.fontStyle > 0 && (st.fontStyle & 1)) ? NSControlStateValueOn : NSControlStateValueOff;
    _italic.state = (st.fontStyle > 0 && (st.fontStyle & 2)) ? NSControlStateValueOn : NSControlStateValueOff;
    _underline.state = (st.fontStyle > 0 && (st.fontStyle & 4)) ? NSControlStateValueOn : NSControlStateValueOff;
    if (_font) {
        if (st.fontName.length && [_font itemWithTitle:st.fontName]) [_font selectItemWithTitle:st.fontName];
        else [_font selectItemAtIndex:0];
    }
    if (_size) {
        NSString *s = st.fontSize > 0 ? [@(st.fontSize) stringValue] : nil;
        if (s && [_size itemWithTitle:s]) [_size selectItemWithTitle:s]; else [_size selectItemAtIndex:0];
    }
}

- (void)storeToLanguage:(NPPUserLanguage *)lang {
    NPPUserStyle *st = [lang styleForID:_styleID];
    st.fgColor = NPPSciColorFromNSColor(_fg.color);
    st.bgColor = NPPSciColorFromNSColor(_bg.color);
    // The colour stays in the file either way (N++ writes it too); the bit is what decides whether it is used.
    st.colorStyle = (_fgOn.state == NSControlStateValueOn ? 1 : 0) | (_bgOn.state == NSControlStateValueOn ? 2 : 0);
    if (_nesting) {
        NSInteger nest = SCE_USER_MASK_NESTING_NONE;
        for (NSMenuItem *mi in _nesting.itemArray)
            if (mi.state == NSControlStateValueOn) nest |= mi.tag;
        st.nesting = nest;
    }
    st.fontStyle = (_bold.state == NSControlStateValueOn ? 1 : 0)
                 | (_italic.state == NSControlStateValueOn ? 2 : 0)
                 | (_underline.state == NSControlStateValueOn ? 4 : 0);
    if (_font) st.fontName = _font.indexOfSelectedItem > 0 ? _font.titleOfSelectedItem : nil;
    if (_size) st.fontSize = _size.indexOfSelectedItem > 0 ? _size.titleOfSelectedItem.integerValue : -1;
}

- (void)colourEnableChanged:(id)sender {
    _fg.enabled = (_fgOn.state == NSControlStateValueOn);
    _bg.enabled = (_bgOn.state == NSControlStateValueOn);
    [self changed:sender];
}

- (void)nestingToggled:(NSMenuItem *)item {
    item.state = (item.state == NSControlStateValueOn) ? NSControlStateValueOff : NSControlStateValueOn;
    [self updateNestingTitle];
    [self changed:item];
}

// Pull-downs show the title of item 0; carry the tick count there so the row says what it holds without opening.
- (void)updateNestingTitle {
    if (!_nesting) return;
    NSInteger on = 0;
    for (NSMenuItem *mi in _nesting.itemArray) if (mi.tag && mi.state == NSControlStateValueOn) on++;
    _nesting.itemArray.firstObject.title = on ? [NSString stringWithFormat:NSLocalizedString(@"Nesting (%ld)", nil), (long)on]
                                              : NSLocalizedString(@"Nesting", nil);
    [_nesting synchronizeTitleAndSelectedItem];
}

- (NSArray<NSNumber *> *)nestingMasksOffered {
    NSMutableArray<NSNumber *> *masks = [NSMutableArray array];
    for (NSMenuItem *mi in _nesting.itemArray) if (mi.tag) [masks addObject:@(mi.tag)];
    return masks;
}

- (NSArray<NSButton *> *)colourEnableBoxes { return @[_fgOn, _bgOn]; }

- (void)changed:(id)sender {
    if (_rowTarget && _rowAction && [_rowTarget respondsToSelector:_rowAction]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [_rowTarget performSelector:_rowAction withObject:self];
        #pragma clang diagnostic pop
    }
}
@end

// ---------------------------------------------------------------------------------------------------------------
// Dialog: the window
// ---------------------------------------------------------------------------------------------------------------

// Tags of the plain text fields: kwlist index, or one of the encoded slots below.
enum {
    kTagCommentLineOpen = 1000, kTagCommentLineContinue, kTagCommentLineClose, kTagCommentOpen, kTagCommentClose,
    kTagDelimiterBase = 1100,   // + (3 * delimiter + 0/1/2) == open/escape/close
};

@interface NPPUserDefineWindowController () <NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate>
@end

@implementation NPPUserDefineWindowController {
    NSPopUpButton *_langPopup;
    NSTextField *_extField;
    NSButton *_ignoreCase, *_foldCompact, *_foldComments, *_prefixCheck, *_defaultExtCheck;
    NSSegmentedControl *_kwGroup;
    NSTextView *_kwText;
    NSMutableArray<NSTextField *> *_fields;
    NSMutableArray<NPPUDLStyleRow *> *_rows;
    NSButton *_lcAnywhere, *_lcBOL, *_lcWhitespace;
    NSButton *_sepDot, *_sepComma, *_sepBoth;
    NSTextField *_statusLabel;
    NPPUserLanguage *_current;
    BOOL _loading;
}

- (instancetype)initWithWindow:(NSWindow *)window {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 620)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:YES];
    w.title = NSLocalizedString(@"User Defined Language", nil);
    w.releasedWhenClosed = NO;
    [w center];
    if ((self = [super initWithWindow:w])) {
        w.delegate = self;
        _fields = [NSMutableArray array];
        _rows = [NSMutableArray array];
        [self buildUI];
        self.windowFrameAutosaveName = @"NPPUserDefineLanguageWindow";
    }
    return self;
}

#pragma mark UI construction

- (NSTextField *)fieldWithTag:(NSInteger)tag width:(CGFloat)width {
    NSTextField *f = [NSTextField textFieldWithString:@""];
    f.tag = tag;
    f.delegate = self;
    f.target = self;
    f.action = @selector(fieldChanged:);
    f.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    f.controlSize = NSControlSizeSmall;
    [f.widthAnchor constraintEqualToConstant:width].active = YES;
    [_fields addObject:f];
    return f;
}

- (NPPUDLStyleRow *)rowForStyle:(NSInteger)styleID title:(NSString *)title compact:(BOOL)compact {
    NPPUDLStyleRow *r = [[NPPUDLStyleRow alloc] initWithStyleID:styleID title:title compact:compact
                                                        target:self action:@selector(styleRowChanged:)];
    [_rows addObject:r];
    return r;
}

static NSTextField *SectionLabel(NSString *s) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
    return l;
}

static NSButton *Check(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton checkboxWithTitle:title target:target action:action];
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    return b;
}

static NSButton *Radio(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton radioButtonWithTitle:title target:target action:action];
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    return b;
}

static NSStackView *HStack(NSArray<NSView *> *views) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment = NSLayoutAttributeCenterY;
    s.spacing = 6;
    return s;
}

static NSStackView *VStack(NSArray<NSView *> *views) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 8;
    return s;
}

- (void)buildUI {
    NSView *content = self.window.contentView;

    _langPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _langPopup.target = self;
    _langPopup.action = @selector(languageSelected:);
    [_langPopup.widthAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;

    NSButton *newBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Create New...", nil) target:self action:@selector(createNew:)];
    NSButton *saveAsBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Save As...", nil) target:self action:@selector(saveAs:)];
    NSButton *renameBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Rename", nil) target:self action:@selector(renameLang:)];
    NSButton *removeBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Remove", nil) target:self action:@selector(removeLang:)];
    for (NSButton *b in @[newBtn, saveAsBtn, renameBtn, removeBtn]) b.controlSize = NSControlSizeSmall;

    _extField = [self fieldWithTag:-1 width:180];
    _extField.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _extField.placeholderString = @"md markdown";
    _ignoreCase = Check(NSLocalizedString(@"Ignore case", nil), self, @selector(settingChanged:));
    // ponytail: N++'s "default ext" toggle only matters when a UDL and a built-in language claim the same extension;
    // here the UDL always wins (NPPDocument's open path asks us first), so the box is shown checked and disabled.
    _defaultExtCheck = Check(NSLocalizedString(@"Use as default for these extensions", nil), self, @selector(settingChanged:));
    _defaultExtCheck.state = NSControlStateValueOn;
    _defaultExtCheck.enabled = NO;
    _defaultExtCheck.toolTip = NSLocalizedString(@"A UDL always wins over a built-in language for its own extensions.", nil);

    NSStackView *top = HStack(@[[NSTextField labelWithString:NSLocalizedString(@"User language:", nil)],
                                _langPopup, newBtn, saveAsBtn, renameBtn, removeBtn]);
    NSStackView *top2 = HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Ext.:", nil)],
                                 _extField, _ignoreCase, _defaultExtCheck]);

    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSZeroRect];
    [tabs addTabViewItem:[self makeTabWithLabel:NSLocalizedString(@"Folder && Default", nil) view:[self buildFolderTab]]];
    [tabs addTabViewItem:[self makeTabWithLabel:NSLocalizedString(@"Keywords Lists", nil) view:[self buildKeywordsTab]]];
    [tabs addTabViewItem:[self makeTabWithLabel:NSLocalizedString(@"Comment && Number", nil) view:[self buildCommentTab]]];
    [tabs addTabViewItem:[self makeTabWithLabel:NSLocalizedString(@"Operators && Delimiters", nil) view:[self buildSymbolsTab]]];

    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *importBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Import...", nil) target:self action:@selector(importUDL:)];
    NSButton *exportBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Export...", nil) target:self action:@selector(exportUDL:)];
    NSButton *saveBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Save", nil) target:self action:@selector(saveNow:)];
    saveBtn.keyEquivalent = @"s";
    saveBtn.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSButton *closeBtn = [NSButton buttonWithTitle:NSLocalizedString(@"Close", nil) target:self action:@selector(closeWindow:)];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *bottom = HStack(@[importBtn, exportBtn, _statusLabel, spacer, saveBtn, closeBtn]);

    NSStackView *outer = VStack(@[top, top2, tabs, bottom]);
    outer.translatesAutoresizingMaskIntoConstraints = NO;
    outer.alignment = NSLayoutAttributeLeading;
    [content addSubview:outer];
    [NSLayoutConstraint activateConstraints:@[
        [outer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [outer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [outer.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
        [outer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [tabs.widthAnchor constraintEqualToAnchor:outer.widthAnchor],
        [bottom.widthAnchor constraintEqualToAnchor:outer.widthAnchor],
    ]];
}

- (NSTabViewItem *)makeTabWithLabel:(NSString *)label view:(NSView *)view {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:label];
    item.label = label;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = view;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor constant:10],
        [view.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor constant:10],
        [view.trailingAnchor constraintLessThanOrEqualToAnchor:scroll.contentView.trailingAnchor constant:-10],
        [view.bottomAnchor constraintLessThanOrEqualToAnchor:scroll.contentView.bottomAnchor constant:-10],
    ]];
    item.view = scroll;
    return item;
}

- (NSStackView *)tripleRow:(NSString *)title tags:(NSArray<NSNumber *> *)tags labels:(NSArray<NSString *> *)labels {
    NSMutableArray *views = [NSMutableArray array];
    if (title.length) {
        NSTextField *l = [NSTextField labelWithString:title];
        l.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        [l.widthAnchor constraintEqualToConstant:150].active = YES;
        l.alignment = NSTextAlignmentRight;
        [views addObject:l];
    }
    for (NSUInteger i = 0; i < tags.count; i++) {
        NSTextField *cap = [NSTextField labelWithString:labels[i]];
        cap.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        cap.textColor = NSColor.secondaryLabelColor;
        [views addObject:cap];
        [views addObject:[self fieldWithTag:tags[i].integerValue width:130]];
    }
    return HStack(views);
}

- (NSView *)buildFolderTab {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:HStack(@[SectionLabel(NSLocalizedString(@"Default style", nil)),
                             [self rowForStyle:SCE_USER_STYLE_DEFAULT title:@"" compact:NO]])];
    struct { const char *title; int open, middle, close, style; } groups[] = {
        {"Folding in code 1", SCE_USER_KWLIST_FOLDERS_IN_CODE1_OPEN, SCE_USER_KWLIST_FOLDERS_IN_CODE1_MIDDLE,
         SCE_USER_KWLIST_FOLDERS_IN_CODE1_CLOSE, SCE_USER_STYLE_FOLDER_IN_CODE1},
        {"Folding in code 2", SCE_USER_KWLIST_FOLDERS_IN_CODE2_OPEN, SCE_USER_KWLIST_FOLDERS_IN_CODE2_MIDDLE,
         SCE_USER_KWLIST_FOLDERS_IN_CODE2_CLOSE, SCE_USER_STYLE_FOLDER_IN_CODE2},
        {"Folding in comment", SCE_USER_KWLIST_FOLDERS_IN_COMMENT_OPEN, SCE_USER_KWLIST_FOLDERS_IN_COMMENT_MIDDLE,
         SCE_USER_KWLIST_FOLDERS_IN_COMMENT_CLOSE, SCE_USER_STYLE_FOLDER_IN_COMMENT},
    };
    NSArray *labels = @[NSLocalizedString(@"Open:", nil), NSLocalizedString(@"Middle:", nil), NSLocalizedString(@"Close:", nil)];
    for (auto &g : groups) {
        [rows addObject:SectionLabel(NSLocalizedString(@(g.title), nil))];
        [rows addObject:[self tripleRow:@"" tags:@[@(g.open), @(g.middle), @(g.close)] labels:labels]];
        [rows addObject:HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Style:", nil)],
                                 [self rowForStyle:g.style title:@"" compact:NO]])];
    }
    _foldCompact = Check(NSLocalizedString(@"Fold compact (fold empty lines too)", nil), self, @selector(settingChanged:));
    [rows addObject:_foldCompact];
    return VStack(rows);
}

- (NSView *)buildKeywordsTab {
    _kwGroup = [NSSegmentedControl segmentedControlWithLabels:@[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8"]
                                                 trackingMode:NSSegmentSwitchTrackingSelectOne
                                                       target:self action:@selector(keywordGroupChanged:)];
    _kwGroup.selectedSegment = 0;
    _prefixCheck = Check(NSLocalizedString(@"Prefix mode", nil), self, @selector(settingChanged:));

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 760, 330)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    _kwText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 760, 330)];
    _kwText.delegate = self;
    _kwText.richText = NO;
    _kwText.automaticQuoteSubstitutionEnabled = NO;
    _kwText.automaticDashSubstitutionEnabled = NO;
    _kwText.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _kwText.minSize = NSMakeSize(0, 0);
    _kwText.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _kwText.verticallyResizable = YES;
    _kwText.horizontallyResizable = NO;
    _kwText.autoresizingMask = NSViewWidthSizable;
    _kwText.textContainer.widthTracksTextView = YES;
    scroll.documentView = _kwText;
    [scroll.widthAnchor constraintEqualToConstant:760].active = YES;
    [scroll.heightAnchor constraintEqualToConstant:330].active = YES;

    NSStackView *v = VStack(@[HStack(@[SectionLabel(NSLocalizedString(@"Keywords group:", nil)), _kwGroup, _prefixCheck]),
                              scroll,
                              HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Style:", nil)],
                                       [self rowForStyle:SCE_USER_STYLE_KEYWORD1 title:@"" compact:NO]])]);
    return v;
}

- (NSView *)buildCommentTab {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:SectionLabel(NSLocalizedString(@"Line comment", nil))];
    [rows addObject:[self tripleRow:@"" tags:@[@(kTagCommentLineOpen), @(kTagCommentLineContinue), @(kTagCommentLineClose)]
                             labels:@[NSLocalizedString(@"Open:", nil), NSLocalizedString(@"Continue:", nil), NSLocalizedString(@"Close:", nil)]]];
    _lcAnywhere = Radio(NSLocalizedString(@"Allow anywhere", nil), self, @selector(pureLCChanged:));
    _lcBOL = Radio(NSLocalizedString(@"Force at beginning of line", nil), self, @selector(pureLCChanged:));
    _lcWhitespace = Radio(NSLocalizedString(@"Allow preceding whitespace", nil), self, @selector(pureLCChanged:));
    [rows addObject:HStack(@[_lcAnywhere, _lcBOL, _lcWhitespace])];
    [rows addObject:HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Style:", nil)],
                             [self rowForStyle:SCE_USER_STYLE_COMMENTLINE title:@"" compact:NO]])];

    [rows addObject:SectionLabel(NSLocalizedString(@"Comment", nil))];
    [rows addObject:[self tripleRow:@"" tags:@[@(kTagCommentOpen), @(kTagCommentClose)]
                             labels:@[NSLocalizedString(@"Open:", nil), NSLocalizedString(@"Close:", nil)]]];
    _foldComments = Check(NSLocalizedString(@"Allow folding of comments", nil), self, @selector(settingChanged:));
    [rows addObject:_foldComments];
    [rows addObject:HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Style:", nil)],
                             [self rowForStyle:SCE_USER_STYLE_COMMENT title:@"" compact:NO]])];

    [rows addObject:SectionLabel(NSLocalizedString(@"Number", nil))];
    [rows addObject:[self tripleRow:@"" tags:@[@(SCE_USER_KWLIST_NUMBER_PREFIX1), @(SCE_USER_KWLIST_NUMBER_PREFIX2)]
                             labels:@[NSLocalizedString(@"Prefix 1:", nil), NSLocalizedString(@"Prefix 2:", nil)]]];
    [rows addObject:[self tripleRow:@"" tags:@[@(SCE_USER_KWLIST_NUMBER_EXTRAS1), @(SCE_USER_KWLIST_NUMBER_EXTRAS2)]
                             labels:@[NSLocalizedString(@"Extras 1:", nil), NSLocalizedString(@"Extras 2:", nil)]]];
    [rows addObject:[self tripleRow:@"" tags:@[@(SCE_USER_KWLIST_NUMBER_SUFFIX1), @(SCE_USER_KWLIST_NUMBER_SUFFIX2)]
                             labels:@[NSLocalizedString(@"Suffix 1:", nil), NSLocalizedString(@"Suffix 2:", nil)]]];
    [rows addObject:[self tripleRow:@"" tags:@[@(SCE_USER_KWLIST_NUMBER_RANGE)]
                             labels:@[NSLocalizedString(@"Range:", nil)]]];
    _sepDot = Radio(NSLocalizedString(@"Dot", nil), self, @selector(separatorChanged:));
    _sepComma = Radio(NSLocalizedString(@"Comma", nil), self, @selector(separatorChanged:));
    _sepBoth = Radio(NSLocalizedString(@"Both", nil), self, @selector(separatorChanged:));
    [rows addObject:HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Decimal separator:", nil)], _sepDot, _sepComma, _sepBoth])];
    [rows addObject:HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Style:", nil)],
                             [self rowForStyle:SCE_USER_STYLE_NUMBER title:@"" compact:NO]])];
    return VStack(rows);
}

- (NSView *)buildSymbolsTab {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:SectionLabel(NSLocalizedString(@"Operators", nil))];
    [rows addObject:[self tripleRow:@"" tags:@[@(SCE_USER_KWLIST_OPERATORS1), @(SCE_USER_KWLIST_OPERATORS2)]
                             labels:@[NSLocalizedString(@"Operators 1:", nil), NSLocalizedString(@"Operators 2:", nil)]]];
    [rows addObject:HStack(@[[NSTextField labelWithString:NSLocalizedString(@"Style:", nil)],
                             [self rowForStyle:SCE_USER_STYLE_OPERATOR title:@"" compact:NO]])];

    [rows addObject:SectionLabel(NSLocalizedString(@"Delimiters", nil))];
    for (int i = 0; i < 8; i++) {
        NSStackView *fieldsRow = [self tripleRow:[NSString stringWithFormat:NSLocalizedString(@"Delimiter %d", nil), i + 1]
                                            tags:@[@(kTagDelimiterBase + 3 * i), @(kTagDelimiterBase + 3 * i + 1), @(kTagDelimiterBase + 3 * i + 2)]
                                          labels:@[NSLocalizedString(@"Open:", nil), NSLocalizedString(@"Escape:", nil), NSLocalizedString(@"Close:", nil)]];
        [rows addObject:fieldsRow];
        // ponytail: delimiter styles get colours + B/I/U + Nesting; font/size per delimiter is a rarely used N++ corner.
        [rows addObject:HStack(@[[NSTextField labelWithString:@"        "],
                                 [self rowForStyle:SCE_USER_STYLE_DELIMITER1 + i title:@"" compact:YES]])];
    }
    return VStack(rows);
}

#pragma mark Loading / storing

- (void)refreshLanguageList {
    NSString *keep = _current.name;
    NSArray<NSString *> *names = NPPUserDefinedLanguages.shared.languageNames;
    [_langPopup removeAllItems];
    if (names.count) [_langPopup addItemsWithTitles:names]; else [_langPopup addItemWithTitle:NSLocalizedString(@"(none)", nil)];
    if (keep && [names containsObject:keep]) [_langPopup selectItemWithTitle:keep];
    [self loadCurrentFromPopup];
}

- (void)selectLanguageNamed:(NSString *)name {
    if (name.length && [_langPopup itemWithTitle:name]) [_langPopup selectItemWithTitle:name];
    [self loadCurrentFromPopup];
}

- (void)loadCurrentFromPopup {
    _current = [NPPUserDefinedLanguages.shared userLanguageNamed:_langPopup.titleOfSelectedItem ?: @""];
    if (_current) [NSUserDefaults.standardUserDefaults setObject:_current.name forKey:kDefaultsLastDialogLang];
    [self loadUI];
}

- (void)loadUI {
    _loading = YES;
    NPPUserLanguage *l = _current;
    BOOL has = (l != nil);
    _extField.stringValue = l.ext ?: @"";
    _ignoreCase.state = l.isCaseIgnored ? NSControlStateValueOn : NSControlStateValueOff;
    _foldCompact.state = l.foldCompact ? NSControlStateValueOn : NSControlStateValueOff;
    _foldComments.state = l.allowFoldOfComments ? NSControlStateValueOn : NSControlStateValueOff;
    _lcAnywhere.state = (l.forcePureLC == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    _lcBOL.state = (l.forcePureLC == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _lcWhitespace.state = (l.forcePureLC == 2) ? NSControlStateValueOn : NSControlStateValueOff;
    _sepDot.state = (l.decimalSeparator == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    _sepComma.state = (l.decimalSeparator == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _sepBoth.state = (l.decimalSeparator == 2) ? NSControlStateValueOn : NSControlStateValueOff;

    for (NSTextField *f in _fields) {
        if (f == _extField) continue;
        f.stringValue = has ? [self valueForFieldTag:f.tag inLanguage:l] : @"";
        f.enabled = has;
    }
    [self loadKeywordGroup];
    for (NPPUDLStyleRow *r in _rows) {
        if (has) [r loadFromLanguage:l];
        r.hidden = !has;
    }
    _extField.enabled = has;
    _ignoreCase.enabled = _foldCompact.enabled = _foldComments.enabled = has;
    _lcAnywhere.enabled = _lcBOL.enabled = _lcWhitespace.enabled = has;
    _sepDot.enabled = _sepComma.enabled = _sepBoth.enabled = has;
    _kwText.editable = has;
    _statusLabel.stringValue = has ? (l.isEditable
        ? [NSString stringWithFormat:NSLocalizedString(@"File: %@", nil), l.sourceURL.lastPathComponent ?: @"—"]
        : NSLocalizedString(@"Bundled sample — Save writes your own copy.", nil)) : @"";
    _loading = NO;
}

- (NSString *)valueForFieldTag:(NSInteger)tag inLanguage:(NPPUserLanguage *)l {
    if (tag >= kTagDelimiterBase) {
        char prefix[3];
        snprintf(prefix, sizeof prefix, "%02d", (int)(tag - kTagDelimiterBase));
        return UDLRetrieve([l keywordListAtIndex:SCE_USER_KWLIST_DELIMITERS], prefix, YES);
    }
    if (tag >= kTagCommentLineOpen && tag <= kTagCommentClose) {
        char prefix[3];
        snprintf(prefix, sizeof prefix, "0%d", (int)(tag - kTagCommentLineOpen));
        return UDLRetrieve([l keywordListAtIndex:SCE_USER_KWLIST_COMMENTS], prefix, YES);
    }
    return [l keywordListAtIndex:tag];
}

- (NSTextField *)fieldWithTagValue:(NSInteger)tag {
    for (NSTextField *f in _fields) if (f.tag == tag) return f;
    return nil;
}

// Rebuild the whole encoded list (Comments or Delimiters) out of its fields — convertTo() in the N++ dialog.
- (void)storeEncodedListForTag:(NSInteger)tag {
    if (!_current) return;
    if (tag >= kTagDelimiterBase) {
        std::string dest;
        for (int i = 0; i < 24; i++) {
            char prefix[3];
            snprintf(prefix, sizeof prefix, "%02d", i);
            UDLConvertTo(dest, [self fieldWithTagValue:kTagDelimiterBase + i].stringValue ?: @"", prefix);
        }
        [_current setKeywordList:[NSString stringWithUTF8String:dest.c_str()] atIndex:SCE_USER_KWLIST_DELIMITERS];
    } else {
        std::string dest;
        for (int i = 0; i < 5; i++) {
            char prefix[3];
            snprintf(prefix, sizeof prefix, "0%d", i);
            UDLConvertTo(dest, [self fieldWithTagValue:kTagCommentLineOpen + i].stringValue ?: @"", prefix);
        }
        [_current setKeywordList:[NSString stringWithUTF8String:dest.c_str()] atIndex:SCE_USER_KWLIST_COMMENTS];
    }
}

- (void)loadKeywordGroup {
    NSInteger g = MAX(0, _kwGroup.selectedSegment);
    _kwText.string = _current ? [_current keywordListAtIndex:SCE_USER_KWLIST_KEYWORDS1 + g] : @"";
    _prefixCheck.state = [_current isPrefixForKeywordGroup:g] ? NSControlStateValueOn : NSControlStateValueOff;
    _prefixCheck.enabled = (_current != nil);
    for (NPPUDLStyleRow *r in _rows) {
        if (r.styleID >= SCE_USER_STYLE_KEYWORD1 && r.styleID <= SCE_USER_STYLE_KEYWORD8) {
            r.styleID = SCE_USER_STYLE_KEYWORD1 + g;
            if (_current) [r loadFromLanguage:_current];
        }
    }
}

#pragma mark Live apply

- (void)applyLive {
    if (!_current) return;
    NPPUserDefinedLanguages *reg = NPPUserDefinedLanguages.shared;
    for (NPPDocument *doc in [self.context contextOpenDocuments] ?: @[]) {
        NSString *n = doc.userDefinedLanguageName;
        if (n && [n isEqualToString:_current.name]) [reg applyUserLanguageNamed:n toEditor:doc.editor];
    }
}

#pragma mark Actions

- (void)languageSelected:(id)sender { [self loadCurrentFromPopup]; }

- (void)keywordGroupChanged:(id)sender { [self loadKeywordGroup]; }

- (void)fieldChanged:(NSTextField *)sender {
    if (_loading || !_current) return;
    if (sender == _extField) { _current.ext = sender.stringValue; [self applyLive]; return; }
    if (sender.tag >= kTagCommentLineOpen) [self storeEncodedListForTag:sender.tag];
    else [_current setKeywordList:sender.stringValue atIndex:sender.tag];
    [self applyLive];
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    if ([n.object isKindOfClass:NSTextField.class]) [self fieldChanged:n.object];
}

- (void)textDidEndEditing:(NSNotification *)n {
    if (_loading || !_current || n.object != _kwText) return;
    [_current setKeywordList:_kwText.string atIndex:SCE_USER_KWLIST_KEYWORDS1 + MAX(0, _kwGroup.selectedSegment)];
    [self applyLive];
}

- (void)settingChanged:(NSButton *)sender {
    if (_loading || !_current) return;
    if (sender == _ignoreCase) _current.isCaseIgnored = (sender.state == NSControlStateValueOn);
    else if (sender == _foldCompact) _current.foldCompact = (sender.state == NSControlStateValueOn);
    else if (sender == _foldComments) _current.allowFoldOfComments = (sender.state == NSControlStateValueOn);
    else if (sender == _prefixCheck)
        [_current setPrefix:(sender.state == NSControlStateValueOn) forKeywordGroup:MAX(0, _kwGroup.selectedSegment)];
    [self applyLive];
}

- (void)pureLCChanged:(NSButton *)sender {
    if (_loading || !_current) return;
    _current.forcePureLC = (sender == _lcBOL) ? 1 : (sender == _lcWhitespace) ? 2 : 0;
    _lcAnywhere.state = (_current.forcePureLC == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    _lcBOL.state = (_current.forcePureLC == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _lcWhitespace.state = (_current.forcePureLC == 2) ? NSControlStateValueOn : NSControlStateValueOff;
    [self applyLive];
}

- (void)separatorChanged:(NSButton *)sender {
    if (_loading || !_current) return;
    _current.decimalSeparator = (sender == _sepComma) ? 1 : (sender == _sepBoth) ? 2 : 0;
    _sepDot.state = (_current.decimalSeparator == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    _sepComma.state = (_current.decimalSeparator == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _sepBoth.state = (_current.decimalSeparator == 2) ? NSControlStateValueOn : NSControlStateValueOff;
    [self applyLive];
}

- (void)styleRowChanged:(NPPUDLStyleRow *)row {
    if (_loading || !_current) return;
    [row storeToLanguage:_current];
    [self applyLive];
}

- (NSString *)askForName:(NSString *)prompt initial:(NSString *)initial {
    NSAlert *a = [NSAlert new];
    a.messageText = prompt;
    [a addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    [a addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    NSTextField *f = [NSTextField textFieldWithString:initial ?: @""];
    f.frame = NSMakeRect(0, 0, 260, 24);
    a.accessoryView = f;
    [a.window setInitialFirstResponder:f];
    if ([a runModal] != NSAlertFirstButtonReturn) return nil;
    NSString *name = [f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) return nil;
    if ([NPPUserDefinedLanguages.shared userLanguageNamed:name]) {
        NSAlert *dup = [NSAlert new];
        dup.messageText = NSLocalizedString(@"This name is already used by another user defined language.", nil);
        [dup runModal];
        return nil;
    }
    return name;
}

- (void)saveLanguage:(NPPUserLanguage *)lang {
    NSError *err = nil;
    if (![NPPUserDefinedLanguages.shared saveUserLanguage:lang error:&err]) {
        NSAlert *a = [NSAlert new];
        a.messageText = NSLocalizedString(@"Could not save the user defined language.", nil);
        a.informativeText = err.localizedDescription ?: @"";
        [a runModal];
    }
}

- (void)createNew:(id)sender {
    NSString *name = [self askForName:NSLocalizedString(@"Name of the new user defined language:", nil)
                              initial:NSLocalizedString(@"new user define", nil)];
    if (!name) return;
    NPPUserLanguage *l = [NPPUserLanguage new];
    l.name = name;
    [self saveLanguage:l];
    [NPPUserDefinedLanguages.shared reload];
    [self selectLanguageNamed:name];
    [self.context contextRefreshUI];
}

- (void)saveAs:(id)sender {
    if (!_current) return;
    NSString *name = [self askForName:NSLocalizedString(@"Save the current language as:", nil)
                              initial:[_current.name stringByAppendingString:@" copy"]];
    if (!name) return;
    NPPUserLanguage *copy = [_current copy];
    copy.name = name;
    [copy setSourceURL:nil editable:YES];
    [self saveLanguage:copy];
    [NPPUserDefinedLanguages.shared reload];
    [self selectLanguageNamed:name];
    [self.context contextRefreshUI];
}

- (void)renameLang:(id)sender {
    if (!_current) return;
    NSString *name = [self askForName:NSLocalizedString(@"New name:", nil) initial:_current.name];
    if (!name) return;
    NPPUserDefinedLanguages *reg = NPPUserDefinedLanguages.shared;
    if (!_current.isEditable) {   // bundled sample: renaming makes a private copy, the sample stays
        NPPUserLanguage *copy = [_current copy];
        copy.name = name;
        [copy setSourceURL:nil editable:YES];
        [self saveLanguage:copy];
        // Nothing to retarget: the sample keeps its name and its buffers, which is what "the sample stays" means.
    } else {
        NSString *oldName = _current.name;
        _current.name = name;         // _current is the registry's own object, so the new name already resolves
        [self saveLanguage:_current];
        // Before the reload, whose sweep would otherwise see the old name vanish and drop those buffers to plain text.
        [reg retargetDocumentsFromUserLanguageNamed:oldName to:name];
    }
    [reg reload];
    [self selectLanguageNamed:name];
    [self.context contextRefreshUI];
}

- (void)removeLang:(id)sender {
    if (!_current) return;
    if (!_current.isEditable) {
        NSAlert *a = [NSAlert new];
        a.messageText = NSLocalizedString(@"This language is bundled with the application and cannot be removed.", nil);
        [a runModal];
        return;
    }
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = [NSString stringWithFormat:NSLocalizedString(@"Remove \"%@\"?", nil), _current.name];
    a.informativeText = NSLocalizedString(@"This deletes the language definition from disk.", nil);
    [a addButtonWithTitle:NSLocalizedString(@"Remove", nil)];
    [a addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    if ([a runModal] != NSAlertFirstButtonReturn) return;

    NSError *err = nil;
    if (![NPPUserDefinedLanguages.shared removeUserLanguageNamed:_current.name error:&err]) {
        NSAlert *fail = [NSAlert new];
        fail.messageText = NSLocalizedString(@"Could not remove the user defined language.", nil);
        fail.informativeText = err.localizedDescription ?: @"";
        [fail runModal];
    }
    _current = nil;
    [self refreshLanguageList];
    [self.context contextRefreshUI];
}

- (void)saveNow:(id)sender {
    if (!_current) return;
    [self saveLanguage:_current];
    [NPPUserDefinedLanguages.shared reload];
    [self selectLanguageNamed:_current.name ?: _langPopup.titleOfSelectedItem];
    _statusLabel.stringValue = NSLocalizedString(@"Saved.", nil);
}

- (void)importUDL:(id)sender {
    [NPPUserDefinedLanguages performCommand:NPPCmdLangImportUDL context:self.context];
    [self refreshLanguageList];
}

- (void)exportUDL:(id)sender {
    [NPPUserDefinedLanguages performCommand:NPPCmdLangExportUDL context:self.context];
}

- (void)closeWindow:(id)sender { [self.window performClose:sender]; }

@end
