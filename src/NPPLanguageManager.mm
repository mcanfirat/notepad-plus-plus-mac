// NPPLanguageManager.mm — port of N++ Parameters.cpp (langs/stylers XML) + ScintillaEditView::defineDocType/performGlobalStyles.
#import "NPPLanguageManager.h"
#import "NPPUtils.h"
#import "NPPPreferences.h"          // sql.backslash.escapes follows the SQL preference
#import "NPPSearchViewCommands.h"   // margin/marker/indicator numbers
#include <ILexer.h>
#include <Lexilla.h>
#include <SciLexer.h>
#include <string>
#include <vector>

NSNotificationName const NPPThemeDidChangeNotification = @"NPPThemeDidChangeNotification";

// N++ LANG_INDEX_x: keyword class -> index into the per-language keyword array (and SCI_SETKEYWORDS index for generic lexers).
enum { kNumKwClasses = 17, kSubstyle1 = 9 };
static int kwClassIndex(NSString *name) {
    static NSDictionary<NSString *, NSNumber *> *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{@"instre1": @0, @"instre2": @1, @"type1": @2, @"type2": @3, @"type3": @4, @"type4": @5, @"type5": @6,
              @"type6": @7, @"type7": @8, @"substyle1": @9, @"substyle2": @10, @"substyle3": @11, @"substyle4": @12,
              @"substyle5": @13, @"substyle6": @14, @"substyle7": @15, @"substyle8": @16};
    });
    if (!name) return -1;
    NSNumber *n = m[name];
    if (n) return n.intValue;
    if (name.length == 1 && [name characterAtIndex:0] >= '0' && [name characterAtIndex:0] <= '8') return [name characterAtIndex:0] - '0';
    return -1;
}

// ScintillaEditView::_langNameInfoArray (udf/ext excluded). php/asp/jsp are styled by the "hypertext" lexer in defineDocType, so
// that is what we report as lexerName (N++'s table says "phpscript" for php but never uses it).
struct LangInfo { const char *name, *shortName, *longName, *lexer; };
static const LangInfo kLangTable[] = {
    {"normal", "Normal text", "Normal text file", "null"},
    {"php", "PHP", "PHP Hypertext Preprocessor file", "hypertext"},
    {"c", "C", "C source file", "cpp"},
    {"cpp", "C++", "C++ source file", "cpp"},
    {"cs", "C#", "C# source file", "cpp"},
    {"objc", "Objective-C", "Objective-C source file", "objc"},
    {"java", "Java", "Java source file", "cpp"},
    {"rc", "RC", "Windows Resource file", "cpp"},
    {"html", "HTML", "Hyper Text Markup Language file", "hypertext"},
    {"xml", "XML", "eXtensible Markup Language file", "xml"},
    {"makefile", "Makefile", "Makefile", "makefile"},
    {"pascal", "Pascal", "Pascal source file", "pascal"},
    {"batch", "Batch", "Batch file", "batch"},
    {"ini", "ini", "MS ini file", "props"},
    {"nfo", "NFO", "MSDOS Style/ASCII Art", "null"},
    {"asp", "ASP", "Active Server Pages script file", "hypertext"},
    {"sql", "SQL", "Structured Query Language file", "sql"},
    {"vb", "Visual Basic", "Visual Basic file", "vb"},
    {"javascript", "Embedded JS", "Embedded JavaScript", "cpp"},
    {"css", "CSS", "Cascade Style Sheets File", "css"},
    {"perl", "Perl", "Perl source file", "perl"},
    {"python", "Python", "Python file", "python"},
    {"lua", "Lua", "Lua source File", "lua"},
    {"tex", "TeX", "TeX file", "tex"},
    {"fortran", "Fortran free form", "Fortran free form source file", "fortran"},
    {"bash", "Shell", "Unix script file", "bash"},
    {"actionscript", "ActionScript", "Flash ActionScript file", "cpp"},
    {"nsis", "NSIS", "Nullsoft Scriptable Install System script file", "nsis"},
    {"tcl", "TCL", "Tool Command Language file", "tcl"},
    {"lisp", "Lisp", "List Processing language file", "lisp"},
    {"scheme", "Scheme", "Scheme file", "lisp"},
    {"asm", "Assembly", "Assembly language source file", "asm"},
    {"diff", "Diff", "Diff file", "diff"},
    {"props", "Properties file", "Properties file", "props"},
    {"postscript", "PostScript", "PostScript file", "ps"},
    {"ruby", "Ruby", "Ruby file", "ruby"},
    {"smalltalk", "Smalltalk", "Smalltalk file", "smalltalk"},
    {"vhdl", "VHDL", "VHSIC Hardware Description Language file", "vhdl"},
    {"kix", "KiXtart", "KiXtart file", "kix"},
    {"autoit", "AutoIt", "AutoIt", "au3"},
    {"caml", "CAML", "Categorical Abstract Machine Language", "caml"},
    {"ada", "Ada", "Ada file", "ada"},
    {"verilog", "Verilog", "Verilog file", "verilog"},
    {"matlab", "MATLAB", "MATrix LABoratory", "matlab"},
    {"haskell", "Haskell", "Haskell", "haskell"},
    {"inno", "Inno Setup", "Inno Setup script", "inno"},
    {"searchResult", "Internal Search", "Internal Search", "searchResult"},
    {"cmake", "CMake", "CMake file", "cmake"},
    {"yaml", "YAML", "YAML Ain't Markup Language", "yaml"},
    {"cobol", "COBOL", "COmmon Business Oriented Language", "COBOL"},
    {"gui4cli", "Gui4Cli", "Gui4Cli file", "gui4cli"},
    {"d", "D", "D programming language", "d"},
    {"powershell", "PowerShell", "Windows PowerShell", "powershell"},
    {"r", "R", "R programming language", "r"},
    {"jsp", "JSP", "JavaServer Pages script file", "hypertext"},
    {"coffeescript", "CoffeeScript", "CoffeeScript file", "coffeescript"},
    {"json", "json", "JSON file", "json"},
    {"javascript.js", "JavaScript", "JavaScript file", "cpp"},
    {"fortran77", "Fortran fixed form", "Fortran fixed form source file", "f77"},
    {"baanc", "BaanC", "BaanC File", "baan"},
    {"srec", "S-Record", "Motorola S-Record binary data", "srec"},
    {"ihex", "Intel HEX", "Intel HEX binary data", "ihex"},
    {"tehex", "Tektronix extended HEX", "Tektronix extended HEX binary data", "tehex"},
    {"swift", "Swift", "Swift file", "cpp"},
    {"asn1", "ASN.1", "Abstract Syntax Notation One file", "asn1"},
    {"avs", "AviSynth", "AviSynth scripts files", "avs"},
    {"blitzbasic", "BlitzBasic", "BlitzBasic file", "blitzbasic"},
    {"purebasic", "PureBasic", "PureBasic file", "purebasic"},
    {"freebasic", "FreeBasic", "FreeBasic file", "freebasic"},
    {"csound", "Csound", "Csound file", "csound"},
    {"erlang", "Erlang", "Erlang file", "erlang"},
    {"escript", "ESCRIPT", "ESCRIPT file", "escript"},
    {"forth", "Forth", "Forth file", "forth"},
    {"latex", "LaTeX", "LaTeX file", "latex"},
    {"mmixal", "MMIXAL", "MMIXAL file", "mmixal"},
    {"nim", "Nim", "Nim file", "nimrod"},
    {"nncrontab", "Nncrontab", "extended crontab file", "nncrontab"},
    {"oscript", "OScript", "OScript source file", "oscript"},
    {"rebol", "REBOL", "REBOL file", "rebol"},
    {"registry", "registry", "registry file", "registry"},
    {"rust", "Rust", "Rust file", "rust"},
    {"spice", "Spice", "spice file", "spice"},
    {"txt2tags", "txt2tags", "txt2tags file", "txt2tags"},
    {"visualprolog", "Visual Prolog", "Visual Prolog file", "visualprolog"},
    {"typescript", "TypeScript", "TypeScript file", "cpp"},
    {"json5", "json5", "JSON5 file", "json"},
    {"mssql", "mssql", "Microsoft Transact-SQL (SQL Server) file", "mssql"},
    {"gdscript", "GDScript", "GDScript file", "gdscript"},
    {"hollywood", "Hollywood", "Hollywood script", "hollywood"},
    {"go", "Go", "Go source file", "cpp"},
    {"raku", "Raku", "Raku source file", "raku"},
    {"toml", "TOML", "Tom's Obvious Minimal Language file", "toml"},
    {"sas", "SAS", "SAS file", "sas"},
    {"errorlist", "ErrorList", "ErrorList file", "errorlist"},
    {"escseq", "EscapeSequence (ANSI)", "Escape Sequence (ANSI) file", "escseq"},
};

// N++ default indicator colours (used only when the theme lacks the WidgetStyle). BGR.
static long bgr(unsigned r, unsigned g, unsigned b) { return (long)(r | (g << 8) | (b << 16)); }

// Default Style background luminance < 0.5 (ScintillaEditView's dark-theme test).
static BOOL isDarkBg(long c) {
    if (c < 0) return NO;
    return (0.299 * (c & 0xFF) + 0.587 * ((c >> 8) & 0xFF) + 0.114 * ((c >> 16) & 0xFF)) / 255.0 < 0.5;
}

#pragma mark - Dark Mode tones (NppDarkMode.cpp)

// NppDarkMode::Colors, in its own order. A colour here is a 0xBBGGRR long — the same layout as the Win32 COLORREF
// NppDarkMode works in — so its constants and its plain integer arithmetic transcribe unchanged.
enum { kDMBackground, kDMSofterBackground, kDMHotBackground, kDMPureBackground, kDMErrorBackground,
       kDMText, kDMDarkerText, kDMDisabledText, kDMLinkText, kDMEdge, kDMHotEdge, kDMDisabledEdge, kDMCount };

// The derived palette is published as global styles, so a tone colour reads back through the same
// -globalStyleNamed: / -globalBackgroundColorNamed: the chrome already uses for the theme's own colours. Each
// carries its slot colour in both fg and bg (one colour, either accessor) and keeps styleID -1, so
// -applyGlobalStylesToEditor / -applyStyle: never push one into Scintilla.
static NSString *const kDMStyleNames[kDMCount] = {
    @"Dark mode background", @"Dark mode softer background", @"Dark mode hot background", @"Dark mode pure background",
    @"Dark mode error background", @"Dark mode text", @"Dark mode darker text", @"Dark mode disabled text",
    @"Dark mode link text", @"Dark mode edge", @"Dark mode hot edge", @"Dark mode disabled edge",
};

static long hexrgb(unsigned rrggbb) { return bgr((rrggbb >> 16) & 0xFF, (rrggbb >> 8) & 0xFF, rrggbb & 0xFF); }  // NppDarkMode HEXRGB

// NppDarkMode::darkColors (the black tone) and offsetRed/Green/Blue/Purple/Cyan/Olive, indexed by NPPDarkModeTone.
static const unsigned kDMDarkColors[kDMCount] = {
    0x202020, 0x383838, 0x454545, 0x202020, 0xB00000, 0xE0E0E0, 0xC0C0C0, 0x808080, 0xFFFF00, 0x646464, 0x9B9B9B, 0x484848 };
static const unsigned kDMToneOffset[7] = { 0x000000, 0x100000, 0x001000, 0x000020, 0x100020, 0x001020, 0x101000 };
static const unsigned kDMOffsetEdge = 0x1C1C1C;   // the edge slot alone takes this on top of the tone offset
// Backgrounds and edges take the tone; errorBackground and the four text colours never do.
static BOOL dmSlotTakesTone(int slot) { return slot <= kDMPureBackground || slot >= kDMEdge; }

// The tone read as a tint: how far its background sits from the stock dark background, per channel. Black is
// (0,0,0), so with the default tone every theme keeps exactly the colours it was parsed with.
struct NPPToneTint { int r, g, b; };
static NPPToneTint toneTint(long toneBackground) {
    long base = hexrgb(kDMDarkColors[kDMBackground]);
    return NPPToneTint{ (int)(toneBackground & 0xFF) - (int)(base & 0xFF),
                        (int)((toneBackground >> 8) & 0xFF) - (int)((base >> 8) & 0xFF),
                        (int)((toneBackground >> 16) & 0xFF) - (int)((base >> 16) & 0xFF) };
}
static unsigned clamp8(int v) { return (unsigned)(v < 0 ? 0 : (v > 255 ? 255 : v)); }

// What the tone may move: the theme's own surfaces. A colour qualifies two ways — it is a near-neutral dark grey
// (3F3F3F, 2A2A2A, 101010, 0C0C0C…), or it sits within 0x20 of the theme's *own* Default Style background in every
// channel, which is what the shades derived from it do (current line, selection, line-number and fold margins).
// Neutrality alone is not enough: five of the bundled dark themes have a background with a hue — Solarized 002B36,
// Ruby Blue 112435, vim Dark Blue 000040, HotFudgeSundae 2B0F01, MossyLawn 58693D — and on those the tone would
// otherwise be a live control that changes nothing at all. A marker, indicator or syntax colour (FF0080, 400000,
// 00FF00, C0C0C0) is neither neutral-dark nor near the background, so it keeps its own hue, the way NppDarkMode
// leaves errorBackground alone.
// ponytail: two constants (0x18 chroma, 0x20 distance) stand in for "is this a surface"; checked by hand against
// all 22 bundled themes — no marker, mark style or change-history colour is inside either. A theme that paints a
// surface further than 0x20 from its own background would need the styles named instead of a distance test.
static BOOL isThemeSurface(long c, long themeBg) {
    int r = c & 0xFF, g = (c >> 8) & 0xFF, b = (c >> 16) & 0xFF;
    int mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
    if (mx < 0x80 && mx - mn <= 0x18) return YES;
    return ABS(r - (int)(themeBg & 0xFF)) <= 0x20 && ABS(g - (int)((themeBg >> 8) & 0xFF)) <= 0x20 &&
           ABS(b - (int)((themeBg >> 16) & 0xFF)) <= 0x20;
}

// Backgrounds only — a foreground is text, and NppDarkMode never tints text. An unchanged style is shared rather
// than copied (nothing here mutates a parsed style), which makes the default tone a no-op over ~1500 lexer styles.
static NPPStyle *tintedStyle(NPPStyle *s, NPPToneTint t, long themeBg) {
    long bg = s.bgColor;
    if (bg < 0 || !isThemeSurface(bg, themeBg)) return s;
    NPPStyle *c = [NPPStyle new];
    c.name = s.name; c.styleID = s.styleID; c.fgColor = s.fgColor; c.fontName = s.fontName;
    c.fontStyle = s.fontStyle; c.fontSize = s.fontSize; c.keywordClass = s.keywordClass;
    c.bgColor = bgr(clamp8((int)(bg & 0xFF) + t.r), clamp8((int)((bg >> 8) & 0xFF) + t.g), clamp8((int)((bg >> 16) & 0xFF) + t.b));
    return c;
}

#pragma mark - NPPLanguage / NPPStyle

@interface NPPLanguage () {
@public
    std::vector<std::string> _kw;   // UTF-8 keyword lists by class index; empty string when absent
}
@property (nonatomic, readwrite, copy) NSString *name, *shortName, *longName, *lexerName;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *extensions;
@property (nonatomic, readwrite, copy, nullable) NSString *commentLine, *commentStart, *commentEnd;
@property (nonatomic, readwrite, copy) NSDictionary<NSString *, NSString *> *keywords;
@end

@implementation NPPLanguage
- (instancetype)init {
    if ((self = [super init])) {
        _kw.assign(kNumKwClasses, std::string());
        _extensions = @[]; _keywords = @{};
        _name = _shortName = _longName = @""; _lexerName = @"null";
    }
    return self;
}
- (NSString *)description { return [NSString stringWithFormat:@"<NPPLanguage %@ (%@) lexer=%@>", _name, _shortName, _lexerName]; }
@end

@implementation NPPStyle
- (instancetype)init {
    if ((self = [super init])) { _name = @""; _styleID = -1; _fgColor = _bgColor = -1; _fontStyle = _fontSize = -1; }
    return self;
}
@end

#pragma mark - NPPLanguageManager

@interface NPPLanguageManager () {
    NSMutableDictionary<NSString *, NPPLanguage *> *_langsByName;
    NSArray<NPPLanguage *> *_languages;
    NSDictionary<NSString *, NPPLanguage *> *_extMap;           // lowercase ext -> language (first wins, like N++)
    NSDictionary<NSString *, NSArray<NPPStyle *> *> *_lexerStyles;   // LexerType name -> WordsStyles (tone applied)
    NSDictionary<NSString *, NPPStyle *> *_globalByName;              // theme (tone applied) + the 12 palette styles
    NSDictionary<NSString *, NSArray<NPPStyle *> *> *_rawLexerStyles; // exactly as parsed; the tone is re-derived from these
    NSDictionary<NSString *, NPPStyle *> *_rawGlobalByName;
    NSURL *_stylersURL;         // "Default (stylers.xml)"
    NSURL *_themesDir;          // the bundled Resources/themes
    NSMutableArray<NSURL *> *_extraThemeDirs;   // -addThemeSearchDirectory:, searched before the bundled one
    NSString *_currentThemeName;
}
@end

@implementation NPPLanguageManager
@synthesize currentThemeName = _currentThemeName;

+ (instancetype)shared {
    static NPPLanguageManager *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NPPLanguageManager new];
        // Only the shared manager bridges the preference: a throwaway instance must not post a second time.
        [NSNotificationCenter.defaultCenter addObserver:s selector:@selector(preferencesDidChange:)
                                                   name:NPPPreferencesDidChangeNotification object:nil];
    });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _langsByName = [NSMutableDictionary new];
        _extraThemeDirs = [NSMutableArray new];
        _languages = @[]; _extMap = @{}; _lexerStyles = _rawLexerStyles = @{}; _globalByName = _rawGlobalByName = @{};
        _currentThemeName = @"Default (stylers.xml)";
        [self buildLanguageTableFromXML:nil];   // usable (all languages, no keywords) even before any XML is loaded
    }
    return self;
}

// N++ pushes sql.backslash.escapes into every open SQL buffer the moment the checkbox moves. The port has one
// re-style seam, and every document already listens on it, so the checkbox rides that instead of growing its own.
// ponytail: a whole re-style for one lexer property; per-buffer SCI_SETPROPERTY is the upgrade if it ever shows.
// The Dark Mode tone rides the same seam: it changes what the theme's colours are, so the whole UI has to re-read.
- (void)preferencesDidChange:(NSNotification *)n {
    NSString *key = n.userInfo[@"key"];
    // "darkModeTone", the twelve "darkModeCustom…" colours, and "darkModeCustomColors" from -resetDarkModeCustomColors.
    BOOL tone = [key hasPrefix:@"darkMode"];
    if (!tone && ![key isEqual:@"sqlBackslashIsEscape"]) return;
    if (tone) [self rebuildThemeForDarkModeTone];
    [NSNotificationCenter.defaultCenter postNotificationName:NPPThemeDidChangeNotification object:self];
}

#pragma mark Loading

- (BOOL)loadDefaultsFromBundle:(NSBundle *)bundle error:(NSError **)error {
    NSURL *langs = [bundle URLForResource:@"langs.model" withExtension:@"xml"];
    NSURL *stylers = [bundle URLForResource:@"stylers.model" withExtension:@"xml"];
    if (!langs || !stylers) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError
                                            userInfo:@{NSLocalizedDescriptionKey: @"langs.model.xml / stylers.model.xml missing from bundle"}];
        return NO;
    }
    _themesDir = [NSURL fileURLWithPath:[bundle.resourcePath stringByAppendingPathComponent:@"themes"] isDirectory:YES];
    return [self loadLangsXML:langs stylersXML:stylers error:error];
}

- (BOOL)loadLangsXML:(NSURL *)langsURL stylersXML:(NSURL *)stylersURL error:(NSError **)error {
    NSXMLDocument *ldoc = [[NSXMLDocument alloc] initWithContentsOfURL:langsURL options:NSXMLNodePreserveWhitespace error:error];
    if (!ldoc) return NO;
    NSXMLDocument *sdoc = [[NSXMLDocument alloc] initWithContentsOfURL:stylersURL options:0 error:error];
    if (!sdoc) return NO;
    [self buildLanguageTableFromXML:ldoc];
    [self loadStylersFromDocument:sdoc];
    _stylersURL = stylersURL;
    _currentThemeName = @"Default (stylers.xml)";
    if (!_themesDir) {
        NSURL *d = [[stylersURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"themes" isDirectory:YES];
        if ([d checkResourceIsReachableAndReturnError:nil]) _themesDir = d;
    }
    return YES;
}

static NSString *attr(NSXMLElement *e, NSString *name) {
    NSString *v = [e attributeForName:name].stringValue;
    return v.length ? v : nil;
}

- (void)buildLanguageTableFromXML:(NSXMLDocument *)doc {
    NSMutableDictionary<NSString *, NPPLanguage *> *byName = [NSMutableDictionary new];
    NSMutableArray<NPPLanguage *> *ordered = [NSMutableArray new];   // XML order, for first-wins extension matching
    for (const LangInfo &li : kLangTable) {
        NPPLanguage *l = [NPPLanguage new];
        l.name = @(li.name); l.shortName = @(li.shortName); l.longName = @(li.longName); l.lexerName = @(li.lexer);
        byName[l.name] = l;
    }
    for (NSXMLElement *e in [doc.rootElement elementsForName:@"Languages"].firstObject.children) {
        if (![e isKindOfClass:NSXMLElement.class] || ![e.name isEqualToString:@"Language"]) continue;
        NSString *name = attr(e, @"name");
        if (!name) continue;
        NPPLanguage *l = byName[name];
        if (!l) {   // in langs.model.xml but not in N++'s table
            l = [NPPLanguage new];
            l.name = l.shortName = l.longName = l.lexerName = name;
            byName[name] = l;
        }
        NSMutableArray *exts = [NSMutableArray new];
        for (NSString *x in [attr(e, @"ext") componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
            if (x.length) [exts addObject:x.lowercaseString];
        l.extensions = exts;
        l.commentLine = attr(e, @"commentLine"); l.commentStart = attr(e, @"commentStart"); l.commentEnd = attr(e, @"commentEnd");
        NSMutableDictionary *kw = [NSMutableDictionary new];
        for (NSXMLElement *k in [e elementsForName:@"Keywords"]) {
            NSString *cls = attr(k, @"name");
            if (!cls) continue;
            NSString *words = k.stringValue ?: @"";
            kw[cls] = words;
            int idx = kwClassIndex(cls);
            if (idx >= 0 && idx < kNumKwClasses) l->_kw[idx] = words.UTF8String;
        }
        l.keywords = kw;
        [ordered addObject:l];
    }
    NSMutableDictionary<NSString *, NPPLanguage *> *ext = [NSMutableDictionary new];
    for (NPPLanguage *l in ordered)
        for (NSString *x in l.extensions)
            if (!ext[x]) ext[x] = l;
    NPPLanguage *normal = byName[@"normal"];
    NSMutableArray<NPPLanguage *> *rest = [byName.allValues mutableCopy];
    [rest removeObject:normal];
    [rest sortUsingComparator:^NSComparisonResult(NPPLanguage *a, NPPLanguage *b) {
        NSComparisonResult r = [a.shortName caseInsensitiveCompare:b.shortName];
        return r != NSOrderedSame ? r : [a.name compare:b.name];
    }];
    _langsByName = byName;
    _extMap = ext;
    _languages = [@[normal] arrayByAddingObjectsFromArray:rest];
}

static NPPStyle *styleFromElement(NSXMLElement *e) {
    NPPStyle *s = [NPPStyle new];
    s.name = attr(e, @"name") ?: @"";
    NSString *v;
    if ((v = attr(e, @"styleID"))) s.styleID = v.integerValue;
    if ((v = attr(e, @"fgColor"))) s.fgColor = NPPColorFromHex(v);
    if ((v = attr(e, @"bgColor"))) s.bgColor = NPPColorFromHex(v);
    s.fontName = attr(e, @"fontName");
    if ((v = attr(e, @"fontStyle"))) s.fontStyle = v.integerValue;
    if ((v = attr(e, @"fontSize"))) s.fontSize = v.integerValue;
    s.keywordClass = attr(e, @"keywordClass");
    return s;
}

- (void)loadStylersFromDocument:(NSXMLDocument *)doc {
    NSMutableDictionary *lexers = [NSMutableDictionary new];
    for (NSXMLElement *lt in [[doc.rootElement elementsForName:@"LexerStyles"].firstObject elementsForName:@"LexerType"]) {
        NSString *name = attr(lt, @"name");
        if (!name) continue;
        NSMutableArray *styles = [NSMutableArray new];
        for (NSXMLElement *ws in [lt elementsForName:@"WordsStyle"]) [styles addObject:styleFromElement(ws)];
        lexers[name] = styles;
    }
    NSMutableDictionary *globals = [NSMutableDictionary new];
    for (NSXMLElement *ws in [[doc.rootElement elementsForName:@"GlobalStyles"].firstObject elementsForName:@"WidgetStyle"]) {
        NPPStyle *s = styleFromElement(ws);
        if (s.name.length && !globals[s.name]) globals[s.name] = s;
    }
    _rawLexerStyles = lexers;
    _rawGlobalByName = globals;
    [self rebuildThemeForDarkModeTone];
}

// NppDarkMode::getDarkModeDefaultColors + the tCustom.change of configuredOptions(): derive the tone's 12 colours,
// publish them as global styles, and tint the theme's own dark surfaces by the same amount so the tone is visible
// everywhere the theme is — editor, tab bar, status bar, panels — off one NPPThemeDidChangeNotification.
// Called from -loadStylersFromDocument: (never from -init: NPPPreferences -registerDefaults calls back into
// +shared, and reading a preference there would re-enter its dispatch_once).
- (void)rebuildThemeForDarkModeTone {
    NPPPreferences *p = NPPPreferences.shared;
    NPPDarkModeTone tone = p.darkModeTone;
    long palette[kDMCount];
    if (tone == NPPDarkModeToneCustomized) {
        // The 12 customised colours override the derived ones outright, exactly as tCustom does upstream.
        NSString *custom[kDMCount] = {
            p.darkModeCustomBackground, p.darkModeCustomSofterBackground, p.darkModeCustomHotBackground,
            p.darkModeCustomPureBackground, p.darkModeCustomErrorBackground, p.darkModeCustomText,
            p.darkModeCustomDarkerText, p.darkModeCustomDisabledText, p.darkModeCustomLinkText,
            p.darkModeCustomEdge, p.darkModeCustomHotEdge, p.darkModeCustomDisabledEdge };
        for (int i = 0; i < kDMCount; i++) {
            long c = NPPColorFromHex(custom[i]);
            palette[i] = c >= 0 ? c : hexrgb(kDMDarkColors[i]);   // a malformed stored colour falls back to the slot default
        }
    } else {
        // Black is darkColors verbatim — upstream adds offsetEdge only in the six toned palettes.
        long off = hexrgb(kDMToneOffset[(tone >= 0 && tone < 7) ? tone : 0]);
        for (int i = 0; i < kDMCount; i++) {
            palette[i] = hexrgb(kDMDarkColors[i]);
            if (off && dmSlotTakesTone(i)) palette[i] += off + (i == kDMEdge ? hexrgb(kDMOffsetEdge) : 0);
        }
    }

    NSMutableDictionary<NSString *, NPPStyle *> *globals = [_rawGlobalByName mutableCopy];
    NPPToneTint t = toneTint(palette[kDMBackground]);
    // Nothing to tint for the default tone, and a light theme is not what a Dark Mode tone is about. A theme with
    // no "Default Style" has no surface to anchor on either: -1 is not dark, so it is left alone.
    NPPStyle *ds = _rawGlobalByName[@"Default Style"];
    long themeBg = ds ? ds.bgColor : -1;
    if ((t.r || t.g || t.b) && isDarkBg(themeBg)) {
        for (NSString *k in _rawGlobalByName) globals[k] = tintedStyle(_rawGlobalByName[k], t, themeBg);
        NSMutableDictionary *lexers = [NSMutableDictionary dictionaryWithCapacity:_rawLexerStyles.count];
        for (NSString *k in _rawLexerStyles) {
            NSArray<NPPStyle *> *in = _rawLexerStyles[k];
            NSMutableArray<NPPStyle *> *out = [NSMutableArray arrayWithCapacity:in.count];
            for (NPPStyle *s in in) [out addObject:tintedStyle(s, t, themeBg)];
            lexers[k] = out;
        }
        _lexerStyles = lexers;
    } else {
        _lexerStyles = _rawLexerStyles;
    }
    for (int i = 0; i < kDMCount; i++) {
        NPPStyle *s = [NPPStyle new];
        s.name = kDMStyleNames[i];
        s.fgColor = s.bgColor = palette[i];
        globals[s.name] = s;
    }
    _globalByName = globals;
}

#pragma mark Themes

// Registered folders first, so a user theme shadows the bundled one it was imported over.
- (NSArray<NSURL *> *)themeSearchDirectories {
    NSMutableArray<NSURL *> *dirs = [_extraThemeDirs mutableCopy] ?: [NSMutableArray new];
    if (_themesDir) [dirs addObject:_themesDir];
    return dirs;
}

- (void)addThemeSearchDirectory:(NSURL *)directory {
    if (!directory.isFileURL) return;
    for (NSURL *u in [self themeSearchDirectories]) if ([u.URLByStandardizingPath isEqual:directory.URLByStandardizingPath]) return;
    [_extraThemeDirs insertObject:directory atIndex:0];   // newest wins
}

- (NSArray<NSString *> *)availableThemeNames {
    NSMutableArray *names = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSURL *dir in [self themeSearchDirectories]) {
        NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil];
        for (NSURL *u in files) {
            if ([u.pathExtension caseInsensitiveCompare:@"xml"] != NSOrderedSame) continue;
            NSString *n = u.URLByDeletingPathExtension.lastPathComponent;
            if (n.length && ![seen containsObject:n]) { [seen addObject:n]; [names addObject:n]; }
        }
    }
    [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return [@[@"Default (stylers.xml)"] arrayByAddingObjectsFromArray:names];
}

- (NSURL *)themeFileURLNamed:(NSString *)name {
    NSString *file = [name stringByAppendingPathExtension:@"xml"];
    NSURL *first = nil;
    for (NSURL *dir in [self themeSearchDirectories]) {
        NSURL *u = [dir URLByAppendingPathComponent:file];
        if (!first) first = u;
        if ([u checkResourceIsReachableAndReturnError:nil]) return u;
    }
    return first;   // nothing on disk: hand back the first candidate so the error names a real path
}

- (BOOL)selectThemeNamed:(NSString *)name error:(NSError **)error {
    NSURL *url = [name isEqualToString:@"Default (stylers.xml)"] ? _stylersURL : [self themeFileURLNamed:name];
    if (!url) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Theme \"%@\" not found", name]}];
        return NO;
    }
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:error];
    if (!doc) return NO;
    [self loadStylersFromDocument:doc];
    _currentThemeName = [name copy];
    [NSNotificationCenter.defaultCenter postNotificationName:NPPThemeDidChangeNotification object:self];
    return YES;
}

- (BOOL)currentThemeIsDark { return isDarkBg(_globalByName[@"Default Style"].bgColor); }

- (NPPStyle *)globalStyleNamed:(NSString *)name { return name ? _globalByName[name] : nil; }
- (NSColor *)globalForegroundColorNamed:(NSString *)name { return NPPNSColorFromSci([self globalStyleNamed:name].fgColor); }
- (NSColor *)globalBackgroundColorNamed:(NSString *)name { return NPPNSColorFromSci([self globalStyleNamed:name].bgColor); }

#pragma mark Languages

- (NSArray<NPPLanguage *> *)languages { return _languages; }
- (NPPLanguage *)languageNamed:(NSString *)name { return name ? _langsByName[name] : nil; }
- (NPPLanguage *)normalTextLanguage { return _langsByName[@"normal"]; }

- (NPPLanguage *)languageForFileURL:(NSURL *)url {
    NSString *file = url.lastPathComponent;
    if (!file.length) return nil;
    // Filenames N++ maps by name rather than by extension (Buffer::setFileName, Buffer.cpp:330). Upstream
    // compares them with _wcsicmp, so the keys here are lowercase and the filename is folded before the lookup —
    // one row covers "makefile", "Makefile" and "MAKEFILE". Upstream only reaches this table when the extension
    // resolved to plain text; here it comes first, which is the same answer for every name in it (none of them
    // carries an extension the language list knows — "CMakeLists.txt" included, since no language claims "txt").
    // The last five rows have no upstream twin: dot-files and Dockerfile are the first thing a macOS user opens.
    static NSDictionary<NSString *, NSString *> *exact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exact = @{@"makefile": @"makefile", @"gnumakefile": @"makefile", @"cmakelists.txt": @"cmake",
                  @"sconstruct": @"python", @"sconscript": @"python", @"wscript": @"python",
                  @"rakefile": @"ruby", @"vagrantfile": @"ruby",
                  @"crontab": @"bash", @"pkgbuild": @"bash", @"apkbuild": @"bash",
                  @".bashrc": @"bash", @".bash_profile": @"bash", @".profile": @"bash", @".zshrc": @"bash",
                  @"dockerfile": @"bash", @".gitignore": @"normal"};
    });
    NSString *byName = exact[file.lowercaseString];
    if (byName) return _langsByName[byName];
    NSString *ext = url.pathExtension.lowercaseString;
    return ext.length ? _extMap[ext] : nil;
}

- (NPPLanguage *)languageForFirstLine:(NSData *)head {
    // Port of FileManager::detectLanguageFromTextBeginning.
    const unsigned char *d = (const unsigned char *)head.bytes;
    size_t n = head.length;
    if (!d || n <= 3) return nil;
    size_t i = 0;
    if ((d[0] == 0xEF && d[1] == 0xBB && d[2] == 0xBF) || (d[0] == 0xFE && d[1] == 0xFF && d[2] == 0x00) ||
        (d[0] == 0xFF && d[1] == 0xFE && d[2] == 0x00)) i = 3;
    for (; i < n; ++i) if (d[i] != ' ' && d[i] != '\t' && d[i] != '\n' && d[i] != '\r') break;
    if (i == n) return nil;
    std::string line((const char *)d + i, std::min<size_t>(40, n - i));
    size_t eol = line.find_first_of("\r\n");
    if (eol != std::string::npos) line.resize(eol);
    if (line.compare(0, 2, "#!") == 0) {
        static const struct { const char *pat, *lang; } shebangs[] = {
            {"sh", "bash"}, {"python", "python"}, {"perl", "perl"}, {"php", "php"}, {"ruby", "ruby"}, {"node", "javascript.js"}};
        for (auto &s : shebangs) if (line.find(s.pat) != std::string::npos) return _langsByName[@(s.lang)];
        return nil;
    }
    static const struct { const char *pat, *lang; } firsts[] = {
        {"<?xml", "xml"}, {"<?php", "php"}, {"<html", "html"}, {"<!DOCTYPE html", "html"}, {"<svg", "xml"}, {"<?", "php"}};
    for (auto &f : firsts) if (line.compare(0, strlen(f.pat), f.pat) == 0) return _langsByName[@(f.lang)];
    return nil;
}

#pragma mark Apply — helpers

// Font policy: preference override wins; Windows defaults / uninstalled fonts fall back to the Mac monospace default.
- (NSString *)resolvedFontName:(NSString *)xmlName {
    if (self.overrideFontName.length) return self.overrideFontName;
    if (!xmlName.length) return nil;
    if ([xmlName isEqualToString:@"Courier New"] || [xmlName isEqualToString:@"Consolas"] || !NPPFontIsAvailable(xmlName))
        return NPPDefaultMonospaceFontName();
    return xmlName;
}
static int macPointSize(NSInteger xmlSize) { return (int)lround(xmlSize * 96.0 / 72.0); }

static inline void setProp(ScintillaView *ed, const char *key, const char *val) { NPPSci(ed, SCI_SETPROPERTY, (uptr_t)key, (sptr_t)val); }

// ScintillaEditView::setSpecialStyle.
- (void)applyStyle:(NPPStyle *)st toEditor:(ScintillaView *)ed {
    if (!st || st.styleID < 0 || st.styleID > STYLE_MAX) return;
    uptr_t id = (uptr_t)st.styleID;
    if (st.fgColor != -1) NPPSci(ed, SCI_STYLESETFORE, id, st.fgColor);
    if (st.bgColor != -1) NPPSci(ed, SCI_STYLESETBACK, id, st.bgColor);
    NSString *font = st.fontName.length ? [self resolvedFontName:st.fontName] : nil;
    if (font) NPPSciStr(ed, SCI_STYLESETFONT, id, font.UTF8String);
    if (st.fontStyle != -1) {
        NPPSci(ed, SCI_STYLESETBOLD, id, (st.fontStyle & 1) != 0);
        NPPSci(ed, SCI_STYLESETITALIC, id, (st.fontStyle & 2) != 0);
        NPPSci(ed, SCI_STYLESETUNDERLINE, id, (st.fontStyle & 4) != 0);
    }
    if (st.fontSize > 0) NPPSci(ed, SCI_STYLESETSIZE, id, macPointSize(st.fontSize));
}

// (a) STYLE_DEFAULT from "Default Style" (font policy + override), then STYLECLEARALL.
- (void)applyDefaultStyleToEditor:(ScintillaView *)ed clearAll:(BOOL)clearAll {
    NPPStyle *ds = _globalByName[@"Default Style"];
    long fg = ds && ds.fgColor != -1 ? ds.fgColor : 0x000000;
    long bg = ds && ds.bgColor != -1 ? ds.bgColor : 0xFFFFFF;
    NPPSci(ed, SCI_STYLESETFORE, STYLE_DEFAULT, fg);
    NPPSci(ed, SCI_STYLESETBACK, STYLE_DEFAULT, bg);
    // Scintilla Cocoa sizes its content view to the scroll width, so the NSScrollView background shows to the right of the
    // longest line and below the last line: paint it with the default background so dark themes don't get a darker band.
    ed.scrollView.drawsBackground = YES;
    ed.scrollView.backgroundColor = NPPNSColorFromSci(bg) ?: NSColor.textBackgroundColor;
    NSString *font = [self resolvedFontName:ds.fontName] ?: NPPDefaultMonospaceFontName();
    NPPSciStr(ed, SCI_STYLESETFONT, STYLE_DEFAULT, font.UTF8String);
    int size = self.overrideFontSize > 0 ? (int)lround(self.overrideFontSize) : (ds.fontSize > 0 ? macPointSize(ds.fontSize) : 13);
    NPPSci(ed, SCI_STYLESETSIZE, STYLE_DEFAULT, size);
    if (ds && ds.fontStyle != -1) {
        NPPSci(ed, SCI_STYLESETBOLD, STYLE_DEFAULT, (ds.fontStyle & 1) != 0);
        NPPSci(ed, SCI_STYLESETITALIC, STYLE_DEFAULT, (ds.fontStyle & 2) != 0);
        NPPSci(ed, SCI_STYLESETUNDERLINE, STYLE_DEFAULT, (ds.fontStyle & 4) != 0);
    }
    if (clearAll) NPPSci(ed, SCI_STYLECLEARALL);
}

// setLexerFromLangID: Scintilla owns the ILexer5 after SCI_SETILEXER.
static void setLexer(ScintillaView *ed, const char *lexerName) {
    Scintilla::ILexer5 *lx = CreateLexer(lexerName);
    if (!lx) lx = CreateLexer("null");
    NPPSci(ed, SCI_SETILEXER, 0, (sptr_t)lx);
}

typedef const char *KwArray[kNumKwClasses];

// ScintillaEditView::makeStyle: apply every WordsStyle of LexerType `name`, and collect keyword lists (from Language `name`)
// for every style that declares a keywordClass. Missing Keywords element => "".
- (void)makeStyle:(NSString *)name editor:(ScintillaView *)ed keywords:(KwArray *)kw {
    NPPLanguage *lang = _langsByName[name];
    for (NPPStyle *st in _lexerStyles[name]) {
        [self applyStyle:st toEditor:ed];
        int idx = kwClassIndex(st.keywordClass);
        if (kw && idx >= 0 && idx < kNumKwClasses) (*kw)[idx] = lang ? lang->_kw[idx].c_str() : "";
    }
}
// ponytail: N++ concatToBuildKeywordList also appends the user's extra keywords from stylers.xml; we have no per-user stylers.
static inline void setKeywords(ScintillaView *ed, int sciIndex, const char *words) {
    NPPSciStr(ed, SCI_SETKEYWORDS, (uptr_t)sciIndex, words ?: "");
}
static void populateSubStyles(ScintillaView *ed, int baseStyle, int nSub, int firstClass, const KwArray &kw) {
    int first = (int)(NPPSci(ed, SCI_ALLOCATESUBSTYLES, (uptr_t)baseStyle, nSub) & 0xFF);
    if (first < 0) return;
    for (int i = 0; i < nSub; i++) {
        int cls = firstClass + i;
        NPPSciStr(ed, SCI_SETIDENTIFIERS, (uptr_t)(first + i), cls < kNumKwClasses && kw[cls] ? kw[cls] : "");
    }
}
static void foldProps(ScintillaView *ed) {
    setProp(ed, "fold", "1"); setProp(ed, "fold.compact", "0"); setProp(ed, "fold.comment", "1");
}
static void cppProps(ScintillaView *ed) {
    foldProps(ed); setProp(ed, "fold.cpp.comment.explicit", "0"); setProp(ed, "fold.preprocessor", "1");
    setProp(ed, "lexer.cpp.track.preprocessor", "0");
}

// ScintillaEditView::setLexer(langType, whichList, baseStyleID, numSubStyles). listMask bit i => SCI_SETKEYWORDS(i, kw[i]).
- (void)genericLexer:(NPPLanguage *)lang editor:(ScintillaView *)ed lists:(unsigned)listMask subBase:(int)base subCount:(int)nSub {
    setLexer(ed, lang.lexerName.UTF8String);
    KwArray kw = {};
    [self makeStyle:lang.name editor:ed keywords:&kw];
    for (int i = 0; i <= 8; i++) if (listMask & (1u << i)) setKeywords(ed, i, kw[i]);
    if (base >= 0) populateSubStyles(ed, base, nSub, kSubstyle1, kw);
    foldProps(ed);
}

#pragma mark Apply — defineDocType

- (void)applyLanguage:(NPPLanguage *)language toEditor:(ScintillaView *)ed {
    if (!ed) return;
    NPPLanguage *lang = language ?: self.normalTextLanguage;
    NSString *n = lang.name;
    auto lists = [](int upto) { return (1u << (upto + 1)) - 1; };   // bits 0..upto

    [self applyDefaultStyleToEditor:ed clearAll:YES];
    NPPSci(ed, SCI_SETCHARSDEFAULT);   // some lexers below customise word chars; never leak them into the next language

    if ([n isEqualToString:@"normal"]) {
        setLexer(ed, "null");
    } else if ([n isEqualToString:@"nfo"]) {
        // N++ L_ASCII: null lexer, STYLE_DEFAULT colours from the "nfo" LexerType's DEFAULT (font policy handles Lucida Console).
        setLexer(ed, "null");
        for (NPPStyle *st in _lexerStyles[@"nfo"]) {
            if (![st.name isEqualToString:@"DEFAULT"]) continue;
            NPPStyle *d = [NPPStyle new];
            d.styleID = STYLE_DEFAULT; d.fgColor = st.fgColor; d.bgColor = st.bgColor;
            d.fontName = st.fontName; d.fontSize = st.fontSize; d.fontStyle = st.fontStyle;
            [self applyStyle:d toEditor:ed];
        }
        NPPSci(ed, SCI_STYLECLEARALL);
    } else if ([@[@"c", @"cpp", @"java", @"rc", @"cs", @"actionscript", @"swift", @"go"] containsObject:n]) {
        setLexer(ed, "cpp");
        if ([n isEqualToString:@"go"]) setProp(ed, "lexer.cpp.backquoted.strings", "1");
        if (![n isEqualToString:@"rc"]) setKeywords(ed, 2, [self doxygenKeywords]);
        KwArray kw = {};
        [self makeStyle:n editor:ed keywords:&kw];
        setKeywords(ed, 0, kw[0]); setKeywords(ed, 1, kw[2]); setKeywords(ed, 3, kw[1]);
        populateSubStyles(ed, SCE_C_IDENTIFIER, 8, kSubstyle1, kw);
        cppProps(ed);
    } else if ([n isEqualToString:@"javascript.js"] || [n isEqualToString:@"javascript"]) {
        setLexer(ed, "cpp");
        KwArray kw = {};
        [self makeStyle:@"javascript.js" editor:ed keywords:&kw];
        setKeywords(ed, 2, [self doxygenKeywords]);
        setKeywords(ed, 0, kw[0]); setKeywords(ed, 1, kw[2]); setKeywords(ed, 3, kw[1]);
        populateSubStyles(ed, SCE_C_IDENTIFIER, 8, kSubstyle1, kw);
        cppProps(ed);
        setProp(ed, "lexer.cpp.backquoted.strings", "2");
    } else if ([n isEqualToString:@"typescript"]) {
        setLexer(ed, "cpp");
        setKeywords(ed, 2, [self doxygenKeywords]);
        KwArray kw = {};
        [self makeStyle:n editor:ed keywords:&kw];
        setKeywords(ed, 0, kw[0]); setKeywords(ed, 1, kw[2]);
        populateSubStyles(ed, SCE_C_IDENTIFIER, 8, kSubstyle1, kw);
        cppProps(ed);
        setProp(ed, "lexer.cpp.backquoted.strings", "1");
    } else if ([n isEqualToString:@"objc"]) {
        setLexer(ed, "objc");
        KwArray kw = {};
        [self makeStyle:n editor:ed keywords:&kw];
        setKeywords(ed, 0, kw[0]); setKeywords(ed, 1, kw[2]); setKeywords(ed, 2, [self doxygenKeywords]);
        setKeywords(ed, 3, kw[1]); setKeywords(ed, 4, kw[3]);
        foldProps(ed); setProp(ed, "fold.cpp.comment.explicit", "0"); setProp(ed, "fold.preprocessor", "1");
    } else if ([n isEqualToString:@"tcl"]) {
        setLexer(ed, "tcl");
        KwArray kw = {};
        [self makeStyle:n editor:ed keywords:&kw];
        static const int order[9] = {0, 2, 1, 3, 4, 5, 6, 7, 8};   // TCL_KW, iTCL_KW, TK_KW, TK_CMD, EXPAND, USER1..4
        for (int i = 0; i < 9; i++) setKeywords(ed, i, kw[order[i]]);
        setProp(ed, "fold", "1");
    } else if ([n isEqualToString:@"xml"]) {
        setLexer(ed, "xml");
        KwArray kw = {};
        [self makeStyle:n editor:ed keywords:&kw];
        setKeywords(ed, 5, kw[0]);
        populateSubStyles(ed, SCE_H_ATTRIBUTE, 8, kSubstyle1, kw);
        setProp(ed, "lexer.xml.allow.scripts", "0");
        setProp(ed, "fold", "1"); setProp(ed, "fold.compact", "0"); setProp(ed, "fold.html", "1"); setProp(ed, "fold.hypertext.comment", "1");
    } else if ([@[@"html", @"php", @"asp", @"jsp"] containsObject:n]) {
        setLexer(ed, "hypertext");
        KwArray kw = {};
        [self makeStyle:@"html" editor:ed keywords:&kw];           // setHTMLLexer
        setKeywords(ed, 0, kw[0]); setKeywords(ed, 5, kw[1]);
        populateSubStyles(ed, SCE_H_TAG, 4, kSubstyle1, kw);
        populateSubStyles(ed, SCE_H_ATTRIBUTE, 4, kSubstyle1 + 4, kw);
        KwArray js = {};
        [self makeStyle:@"javascript" editor:ed keywords:&js];     // setEmbeddedJSLexer
        setKeywords(ed, 1, js[0]);
        populateSubStyles(ed, SCE_HJ_WORD, 8, kSubstyle1, js);
        for (int st : {SCE_HJ_DEFAULT, SCE_HJ_COMMENT, SCE_HJ_COMMENTDOC, SCE_HJ_TEMPLATELITERAL, SCE_HJA_TEMPLATELITERAL})
            NPPSci(ed, SCI_STYLESETEOLFILLED, (uptr_t)st, 1);
        KwArray php = {};
        [self makeStyle:@"php" editor:ed keywords:&php];           // setEmbeddedPhpLexer
        setKeywords(ed, 4, php[0]);
        populateSubStyles(ed, SCE_HPHP_WORD, 8, kSubstyle1, php);
        NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_HPHP_DEFAULT, 1); NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_HPHP_COMMENT, 1);
        KwArray asp = {};
        [self makeStyle:@"asp" editor:ed keywords:&asp];           // setEmbeddedAspLexer
        setProp(ed, "asp.default.language", "2");
        setKeywords(ed, 2, asp[0]);
        populateSubStyles(ed, SCE_HB_WORD, 8, kSubstyle1, asp);
        NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_HBA_DEFAULT, 1);
        setProp(ed, "fold", "1"); setProp(ed, "fold.compact", "0"); setProp(ed, "fold.html", "1"); setProp(ed, "fold.hypertext.comment", "1");
    } else if ([n isEqualToString:@"json"] || [n isEqualToString:@"json5"]) {
        setLexer(ed, "json");
        KwArray kw = {};
        [self makeStyle:@"json" editor:ed keywords:&kw];
        setKeywords(ed, 0, kw[0]); setKeywords(ed, 1, kw[1]);
        setProp(ed, "fold", "1"); setProp(ed, "fold.compact", "0"); setProp(ed, "lexer.json.escape.sequence", "1");
        if ([n isEqualToString:@"json5"]) setProp(ed, "lexer.json.allow.comments", "1");
    } else if ([n isEqualToString:@"bash"]) {
        setLexer(ed, "bash");
        KwArray kw = {};
        [self makeStyle:n editor:ed keywords:&kw];
        setKeywords(ed, 0, kw[0]);
        populateSubStyles(ed, SCE_SH_IDENTIFIER, 4, kSubstyle1, kw);
        populateSubStyles(ed, SCE_SH_SCALAR, 4, kSubstyle1 + 4, kw);
        foldProps(ed);
    }
    // ---- generic setLexer(lang, LIST mask, baseStyle, nSub) family (ScintillaEditView.h) ----
    else if ([n isEqualToString:@"css"]) { [self genericLexer:lang editor:ed lists:1|2|16|64 subBase:-1 subCount:0]; }
    else if ([n isEqualToString:@"lua"]) { [self genericLexer:lang editor:ed lists:lists(7) subBase:SCE_LUA_IDENTIFIER subCount:4]; }
    else if ([n isEqualToString:@"makefile"] || [n isEqualToString:@"diff"] || [n isEqualToString:@"srec"] || [n isEqualToString:@"ihex"] ||
             [n isEqualToString:@"tehex"] || [n isEqualToString:@"latex"] || [n isEqualToString:@"registry"] || [n isEqualToString:@"txt2tags"]) {
        [self genericLexer:lang editor:ed lists:0 subBase:-1 subCount:0];
    }
    else if ([n isEqualToString:@"ini"] || [n isEqualToString:@"props"]) {
        [self genericLexer:lang editor:ed lists:0 subBase:-1 subCount:0];
        NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_PROPS_SECTION, 1);
    }
    // setSqlLexer(): the escape property follows the preference, and is re-read on every re-style (N++ pushes it to
    // the open SQL buffers as soon as the checkbox changes; here the preference change re-applies the language).
    else if ([n isEqualToString:@"sql"]) {
        [self genericLexer:lang editor:ed lists:1|2|16 subBase:-1 subCount:0];
        setProp(ed, "sql.backslash.escapes", NPPPreferences.shared.sqlBackslashIsEscape ? "1" : "0");
    }
    else if ([n isEqualToString:@"mssql"]) { [self genericLexer:lang editor:ed lists:lists(5) subBase:-1 subCount:0]; }
    else if ([n isEqualToString:@"vb"] || [n isEqualToString:@"perl"] || [n isEqualToString:@"batch"] || [n isEqualToString:@"smalltalk"] ||
             [n isEqualToString:@"ada"] || [n isEqualToString:@"matlab"] || [n isEqualToString:@"haskell"] || [n isEqualToString:@"yaml"] ||
             [n isEqualToString:@"nim"] || [n isEqualToString:@"toml"]) {
        [self genericLexer:lang editor:ed lists:1 subBase:-1 subCount:0];
    }
    else if ([n isEqualToString:@"ruby"]) { [self genericLexer:lang editor:ed lists:1 subBase:-1 subCount:0]; NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_RB_POD, 1); }
    else if ([n isEqualToString:@"pascal"] || [n isEqualToString:@"verilog"]) {
        [self genericLexer:lang editor:ed lists:[n isEqualToString:@"pascal"] ? 1 : 3 subBase:-1 subCount:0];
        setProp(ed, "fold.preprocessor", "1");
    }
    else if ([n isEqualToString:@"python"]) {
        [self genericLexer:lang editor:ed lists:3 subBase:SCE_P_IDENTIFIER subCount:8];
        setProp(ed, "fold.quotes.python", "1"); setProp(ed, "lexer.python.decorator.attributes", "1"); setProp(ed, "lexer.python.identifier.attributes", "1");
    }
    else if ([n isEqualToString:@"gdscript"]) {
        [self genericLexer:lang editor:ed lists:3 subBase:SCE_GD_IDENTIFIER subCount:8];
        setProp(ed, "lexer.gdscript.keywords2.no.sub.identifiers", "1"); setProp(ed, "lexer.gdscript.whinge.level", "1");
    }
    else if ([n isEqualToString:@"tex"]) {
        for (int i = 0; i < 4; i++) setKeywords(ed, i, "");
        [self genericLexer:lang editor:ed lists:0 subBase:-1 subCount:0];
    }
    else if ([n isEqualToString:@"nsis"] || [n isEqualToString:@"postscript"] || [n isEqualToString:@"asn1"] || [n isEqualToString:@"blitzbasic"] ||
             [n isEqualToString:@"purebasic"] || [n isEqualToString:@"freebasic"] || [n isEqualToString:@"visualprolog"] ||
             [n isEqualToString:@"hollywood"] || [n isEqualToString:@"sas"] || [n isEqualToString:@"coffeescript"]) {
        [self genericLexer:lang editor:ed lists:lists(3) subBase:-1 subCount:0];
    }
    else if ([n isEqualToString:@"fortran"] || [n isEqualToString:@"fortran77"] || [n isEqualToString:@"kix"] || [n isEqualToString:@"caml"] ||
             [n isEqualToString:@"cmake"] || [n isEqualToString:@"cobol"] || [n isEqualToString:@"r"] || [n isEqualToString:@"escript"] ||
             [n isEqualToString:@"mmixal"] || [n isEqualToString:@"spice"]) {
        [self genericLexer:lang editor:ed lists:lists(2) subBase:-1 subCount:0];
    }
    else if ([n isEqualToString:@"csound"]) { [self genericLexer:lang editor:ed lists:lists(2) subBase:-1 subCount:0]; NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_CSOUND_STRINGEOL, 1); }
    else if ([n isEqualToString:@"nncrontab"]) {
        [self genericLexer:lang editor:ed lists:lists(2) subBase:-1 subCount:0];
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%-");
    }
    else if ([n isEqualToString:@"lisp"] || [n isEqualToString:@"scheme"]) { [self genericLexer:lang editor:ed lists:3 subBase:-1 subCount:0]; }
    else if ([n isEqualToString:@"asm"]) {
        [self genericLexer:lang editor:ed lists:lists(7) subBase:-1 subCount:0];
        setProp(ed, "fold.asm.syntax.based", "1"); setProp(ed, "fold.asm.comment.multiline", "1"); setProp(ed, "fold.asm.comment.explicit", "1");
    }
    else if ([n isEqualToString:@"vhdl"] || [n isEqualToString:@"d"]) { [self genericLexer:lang editor:ed lists:lists(6) subBase:-1 subCount:0]; }
    else if ([n isEqualToString:@"autoit"]) { [self genericLexer:lang editor:ed lists:lists(6) subBase:-1 subCount:0]; setProp(ed, "fold.preprocessor", "1"); }
    else if ([n isEqualToString:@"inno"] || [n isEqualToString:@"powershell"] || [n isEqualToString:@"erlang"]) {
        [self genericLexer:lang editor:ed lists:lists(5) subBase:-1 subCount:0];
    }
    else if ([n isEqualToString:@"gui4cli"]) { [self genericLexer:lang editor:ed lists:lists(4) subBase:-1 subCount:0]; }
    else if ([n isEqualToString:@"baanc"]) {
        [self genericLexer:lang editor:ed lists:lists(8) subBase:-1 subCount:0];
        setProp(ed, "lexer.baan.styling.within.preprocessor", "1");
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$:");
        setProp(ed, "fold.preprocessor", "1"); setProp(ed, "fold.baan.syntax.based", "1"); setProp(ed, "fold.baan.keywords.based", "1");
        setProp(ed, "fold.baan.sections", "1"); setProp(ed, "fold.baan.inner.level", "1");
        NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_BAAN_STRINGEOL, 1);
    }
    else if ([n isEqualToString:@"avs"]) {
        [self genericLexer:lang editor:ed lists:lists(5) subBase:-1 subCount:0];
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_#");
    }
    else if ([n isEqualToString:@"forth"]) {
        [self genericLexer:lang editor:ed lists:lists(5) subBase:-1 subCount:0];
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%-");
    }
    else if ([n isEqualToString:@"oscript"]) {
        [self genericLexer:lang editor:ed lists:lists(5) subBase:-1 subCount:0];
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$");
    }
    else if ([n isEqualToString:@"rebol"]) {
        [self genericLexer:lang editor:ed lists:lists(6) subBase:-1 subCount:0];
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789?!.'+-*&|=_~");
    }
    else if ([n isEqualToString:@"rust"]) {
        [self genericLexer:lang editor:ed lists:lists(6) subBase:-1 subCount:0];
        NPPSciStr(ed, SCI_SETWORDCHARS, 0, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_#");
    }
    else if ([n isEqualToString:@"raku"]) {
        [self genericLexer:lang editor:ed lists:lists(6) subBase:-1 subCount:0];
        setProp(ed, "fold.raku.comment.multiline", "1"); setProp(ed, "fold.raku.comment.pod", "1");
    }
    else if ([n isEqualToString:@"errorlist"]) {
        [self genericLexer:lang editor:ed lists:0 subBase:-1 subCount:0];
        setProp(ed, "lexer.errorlist.value.separate", "0"); setProp(ed, "lexer.errorlist.escape.sequences", "1");
    }
    else if ([n isEqualToString:@"escseq"]) {
        [self genericLexer:lang editor:ed lists:0 subBase:-1 subCount:0];
        setProp(ed, "lexer.escseq.colour.text", "1");
    }
    else if ([n isEqualToString:@"searchResult"]) {
        NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_SEARCHRESULT_FILE_HEADER, 1); NPPSci(ed, SCI_STYLESETEOLFILLED, SCE_SEARCHRESULT_SEARCH_HEADER, 1);
        [self genericLexer:lang editor:ed lists:0 subBase:-1 subCount:0];
    }
    else {
        // Language known to langs.model.xml/stylers but not to N++'s dispatch: best effort = generic lexer, keyword lists on their
        // LANG_INDEX slot, no substyles. (ponytail: N++ would use the null lexer here.)
        [self genericLexer:lang editor:ed lists:lists(8) subBase:-1 subCount:0];
    }

    [self applyGlobalStylesToEditor:ed];
}

// getWordList(L_CPP, LANG_INDEX_TYPE2): doxygen keywords shared by every cpp-lexer language.
- (const char *)doxygenKeywords {
    NPPLanguage *cpp = _langsByName[@"cpp"];
    return cpp ? cpp->_kw[3].c_str() : "";
}

#pragma mark Apply — global styles (performGlobalStyles + the STYLE_* tail of defineDocType + init-time indicators/markers)

- (void)applyGlobalStylesToEditor:(ScintillaView *)ed {
    if (!ed) return;
    NSDictionary<NSString *, NPPStyle *> *g = _globalByName;
    auto fg = [&](NSString *name, long dflt) { NPPStyle *s = g[name]; return s && s.fgColor != -1 ? s.fgColor : dflt; };
    auto bg = [&](NSString *name, long dflt) { NPPStyle *s = g[name]; return s && s.bgColor != -1 ? s.bgColor : dflt; };
    auto element = [&](int el, long c) { NPPSci(ed, SCI_SETELEMENTCOLOUR, (uptr_t)el, c | 0xFF000000L); };

    [self applyDefaultStyleToEditor:ed clearAll:NO];

    // STYLE_INDENTGUIDE / BRACELIGHT / BRACEBAD / LINENUMBER — by name, since themes are keyed by name (styleIDs are fixed anyway).
    for (NSString *name in @[@"Indent guideline style", @"Brace highlight style", @"Bad brace colour", @"Line number margin"])
        [self applyStyle:g[name] toEditor:ed];

    element(SC_ELEMENT_CARET_LINE_BACK, bg(@"Current line background colour", 0xFFE8E8));
    long selBack = bg(@"Selected text colour", 0xC0C0C0);
    element(SC_ELEMENT_SELECTION_BACK, selBack);
    element(SC_ELEMENT_SELECTION_INACTIVE_BACK, selBack);    // N++ locks the selection fg (enableSelectFgColor.xml); we don't set it either
    element(SC_ELEMENT_SELECTION_ADDITIONAL_BACK, bg(@"Multi-selected text color", 0xC0C0C0));
    element(SC_ELEMENT_CARET, fg(@"Caret colour", 0x000000));
    element(SC_ELEMENT_CARET_ADDITIONAL, fg(@"Multi-edit carets color", 0x404040));
    NPPSci(ed, SCI_SETEDGECOLOUR, (uptr_t)fg(@"Edge colour", 0xC0C0C0));
    element(SC_ELEMENT_WHITE_SPACE, fg(@"White space symbol", 0x000000));
    // ponytail: "EOL custom color" (N++ setCRLF representation colours) and "Non-printing characters custom color" belong to the
    // show-symbol feature (NPPSearchViewCommands); skipped here.

    // Margins: types + masks only (widths/visibility are NPPDocument.applyPreferences).
    long lineBg = bg(@"Line number margin", 0xE4E4E4);
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginLineNumber, SC_MARGIN_NUMBER);
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginSymbol, SC_MARGIN_COLOUR);
    NPPSci(ed, SCI_SETMARGINBACKN, NPPMarginSymbol, bg(@"Bookmark margin", lineBg));
    NPPSci(ed, SCI_SETMARGINMASKN, NPPMarginSymbol, (1 << NPPMarkerBookmark) | (1 << NPPMarkerHideLinesBegin) | (1 << NPPMarkerHideLinesEnd) | (1 << NPPMarkerHideLinesUnderline));
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginFolder, SC_MARGIN_SYMBOL);
    NPPSci(ed, SCI_SETMARGINMASKN, NPPMarginFolder, SC_MASK_FOLDERS);
    NPPSci(ed, SCI_SETMARGINSENSITIVEN, NPPMarginFolder, 1);
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginChangeHistory, SC_MARGIN_COLOUR);
    NPPSci(ed, SCI_SETMARGINBACKN, NPPMarginChangeHistory, bg(@"Change History margin", lineBg));
    NPPSci(ed, SCI_SETMARGINMASKN, NPPMarginChangeHistory, SC_MASK_HISTORY);

    // Change history markers (fore = fg, back = bg like N++).
    struct { NSString *name; int marker; long dflt; } hist[] = {
        {@"Change History modified", SC_MARKNUM_HISTORY_MODIFIED, bgr(0xFF, 0x80, 0)},
        {@"Change History revert modified", SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED, bgr(0xA0, 0xC0, 0)},
        {@"Change History revert origin", SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN, bgr(0x40, 0xA0, 0xBF)},
        {@"Change History saved", SC_MARKNUM_HISTORY_SAVED, bgr(0, 0xA0, 0)},
    };
    for (auto &h : hist) {
        NPPSci(ed, SCI_MARKERSETFORE, (uptr_t)h.marker, fg(h.name, h.dflt));
        NPPSci(ed, SCI_MARKERSETBACK, (uptr_t)h.marker, bg(h.name, h.dflt));
    }

    // Fold markers: box tree (N++ default FOLDER_STYLE_BOX). N++ swaps fg/bg of the "Fold" style.
    long foldFore = bg(@"Fold", 0xF3F3F3), foldBack = fg(@"Fold", 0x808080), foldActive = fg(@"Fold active", 0x0000FF);
    struct { int marker, shape; } folds[] = {
        {SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS}, {SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS}, {SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE},
        {SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER}, {SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED},
        {SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED}, {SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER},
    };
    for (auto &f : folds) {
        NPPSci(ed, SCI_MARKERDEFINE, (uptr_t)f.marker, f.shape);
        NPPSci(ed, SCI_MARKERSETFORE, (uptr_t)f.marker, foldFore);
        NPPSci(ed, SCI_MARKERSETBACK, (uptr_t)f.marker, foldBack);
        NPPSci(ed, SCI_MARKERSETBACKSELECTED, (uptr_t)f.marker, foldActive);
    }
    NPPSci(ed, SCI_MARKERENABLEHIGHLIGHT, 1);
    NPPSci(ed, SCI_SETFOLDMARGINCOLOUR, 1, bg(@"Fold margin", 0xE9E9E9));
    NPPSci(ed, SCI_SETFOLDMARGINHICOLOUR, 1, fg(@"Fold margin", 0xFFFFFF));
    NPPSci(ed, SCI_SETFOLDFLAGS, SC_FOLDFLAG_LINEAFTER_CONTRACTED);
    NPPSci(ed, SCI_SETAUTOMATICFOLD, SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE);

    // Bookmark marker. ponytail: N++ draws an RGBA bookmark image; we use Scintilla's built-in bookmark glyph.
    long bm = fg(@"Bookmark margin", bgr(0x4D, 0x9B, 0xFF));
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkerBookmark, SC_MARK_BOOKMARK);
    NPPSci(ed, SCI_MARKERSETFORE, NPPMarkerBookmark, bm);
    NPPSci(ed, SCI_MARKERSETBACK, NPPMarkerBookmark, bm);
    NPPSci(ed, SCI_MARKERSETALPHA, NPPMarkerBookmark, 255);
    // Hide-lines markers (N++ MARK_HIDELINESBEGIN/END): small grey arrows in the symbol margin; clicking them unhides (NPPDocument).
    long hl = 0x808080;
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkerHideLinesBegin, SC_MARK_ARROWDOWN);
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkerHideLinesEnd, SC_MARK_ARROW);
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkerHideLinesUnderline, SC_MARK_UNDERLINE);
    for (int m : {NPPMarkerHideLinesBegin, NPPMarkerHideLinesEnd, NPPMarkerHideLinesUnderline}) {
        NPPSci(ed, SCI_MARKERSETFORE, m, hl);
        NPPSci(ed, SCI_MARKERSETBACK, m, hl);
    }

    // Indicators (setSpecialIndicator + init-time style/alpha/under). Defaults are N++'s hard-coded colours.
    struct { NSString *name; int indic; long dflt; } indics[] = {
        {@"Find Mark Style", NPPIndicatorFindMark, bgr(0xFF, 0, 0)},
        {@"Smart Highlighting", NPPIndicatorSmartHighlight, bgr(0, 0xFF, 0)},
        {@"Incremental highlight all", NPPIndicatorIncremental, bgr(0, 0, 0xFF)},
        {@"Tags match highlighting", NPPIndicatorTagMatch, bgr(0x80, 0, 0xFF)},
        {@"Tags attribute", NPPIndicatorTagAttr, bgr(0xFF, 0xFF, 0)},
        {@"Mark Style 1", NPPIndicatorMarkExt1, bgr(0, 0xFF, 0xFF)},
        {@"Mark Style 2", NPPIndicatorMarkExt2, bgr(0xFF, 0x80, 0)},
        {@"Mark Style 3", NPPIndicatorMarkExt3, bgr(0xFF, 0xFF, 0)},
        {@"Mark Style 4", NPPIndicatorMarkExt4, bgr(0x80, 0, 0xFF)},
        {@"Mark Style 5", NPPIndicatorMarkExt5, bgr(0, 0x80, 0)},
    };
    for (auto &i : indics) {
        NPPSci(ed, SCI_INDICSETSTYLE, (uptr_t)i.indic, INDIC_ROUNDBOX);
        NPPSci(ed, SCI_INDICSETALPHA, (uptr_t)i.indic, 100);
        NPPSci(ed, SCI_INDICSETOUTLINEALPHA, (uptr_t)i.indic, 100);
        NPPSci(ed, SCI_INDICSETUNDER, (uptr_t)i.indic, 1);
        NPPSci(ed, SCI_INDICSETFORE, (uptr_t)i.indic, bg(i.name, i.dflt));
    }
    NPPSci(ed, SCI_INDICSETHOVERFORE, 8 /* N++ URL_INDIC */, fg(@"URL hovered", 0x0000FF));
}

#pragma mark - Self checks

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *f = [NSMutableArray array];

    // Theme search path. A private instance, because registering a directory on the shared manager would leave it
    // in the Theme menu for the rest of the run.
    NPPLanguageManager *m = [NPPLanguageManager new];
    NSURL *a = [NSURL fileURLWithPath:@"/npp-selfcheck-themes-a" isDirectory:YES];
    NSURL *b = [NSURL fileURLWithPath:@"/npp-selfcheck-themes-b" isDirectory:YES];
    [m addThemeSearchDirectory:a];
    [m addThemeSearchDirectory:b];
    [m addThemeSearchDirectory:a];                                                  // already registered
    [m addThemeSearchDirectory:[NSURL URLWithString:@"https://example.com/x"]];      // not a file URL
    NSArray<NSURL *> *dirs = [m themeSearchDirectories];
    if (dirs.count != 2)
        [f addObject:[NSString stringWithFormat:@"theme search path holds %lu directories, not 2: %@",
                      (unsigned long)dirs.count, dirs]];
    else if (![dirs.firstObject.path isEqualToString:b.path])
        [f addObject:[NSString stringWithFormat:@"the newest theme directory is not searched first: %@", dirs]];

    // The SQL escape checkbox has to reach the documents that are already open; NPPThemeDidChangeNotification is
    // the seam every one of them listens on, and only the shared manager bridges the preference onto it.
    [NPPLanguageManager shared];
    NPPPreferences *prefs = NPPPreferences.shared;
    prefs.tabSize = prefs.tabSize;   // settle first: the app delegate corrects a mismatched theme on any change
    __block NSInteger posts = 0;
    id obs = [NSNotificationCenter.defaultCenter addObserverForName:NPPThemeDidChangeNotification object:nil queue:nil
                                                         usingBlock:^(NSNotification *n) { posts++; }];
    BOOL was = prefs.sqlBackslashIsEscape;
    prefs.sqlBackslashIsEscape = !was;
    NSInteger afterFlip = posts;
    prefs.tabSize = prefs.tabSize;                     // an unrelated key must not force a re-style
    NSInteger afterOther = posts;
    prefs.sqlBackslashIsEscape = was;
    [NSNotificationCenter.defaultCenter removeObserver:obs];
    if (afterFlip < 1) [f addObject:@"changing sqlBackslashIsEscape did not re-style the open documents"];
    if (afterOther != afterFlip) [f addObject:@"an unrelated preference re-styled every open document"];

    // ---- Dark Mode tones. A private instance and a two-style dark theme, so the expected colours are arithmetic
    // anyone can redo by hand: blue tone = +0x20 blue, and the edge slot also takes NppDarkMode's 0x1C1C1C.
    NPPDarkModeTone savedTone = prefs.darkModeTone;
    NSString *savedCustomBg = prefs.darkModeCustomBackground;
    NPPLanguageManager *tm = [NPPLanguageManager new];
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:
        @"<NotepadPlus><LexerStyles><LexerType name=\"cpp\" desc=\"C++\">"
         "<WordsStyle name=\"COMMENT\" styleID=\"1\" fgColor=\"7F9F7F\" bgColor=\"3F3F3F\" keywordClass=\"instre1\""
         " fontName=\"Consolas\" fontStyle=\"2\" fontSize=\"10\"/>"
         "</LexerType></LexerStyles><GlobalStyles>"
         "<WidgetStyle name=\"Default Style\" styleID=\"32\" fgColor=\"DCDCCC\" bgColor=\"3F3F3F\"/>"
         "<WidgetStyle name=\"Find Mark Style\" styleID=\"31\" bgColor=\"FF0080\"/>"
         "</GlobalStyles></NotepadPlus>" options:0 error:nil];
    if (!doc) {
        [f addObject:@"the dark-tone self-check theme did not parse"];
    } else {
        auto styleBg = [&](NSString *name) { return [tm globalStyleNamed:name].bgColor; };
        auto lexerBg = [&] { return tm->_lexerStyles[@"cpp"].firstObject.bgColor; };
        long plain = NPPColorFromHex(@"3F3F3F");

        prefs.darkModeTone = NPPDarkModeToneBlack;
        [tm loadStylersFromDocument:doc];
        if (styleBg(@"Default Style") != plain || lexerBg() != plain)
            [f addObject:@"the default Dark Mode tone changed a theme's colours"];
        if (styleBg(@"Dark mode edge") != NPPColorFromHex(@"646464"))
            [f addObject:@"the black tone's edge is not darkColors.edge (offsetEdge belongs to the toned palettes only)"];

        prefs.darkModeTone = NPPDarkModeToneBlue;
        [tm rebuildThemeForDarkModeTone];
        long tintedBg = NPPColorFromHex(@"3F3F5F");
        if (styleBg(@"Default Style") != tintedBg) [f addObject:@"the blue tone did not tint the theme's background"];
        if (lexerBg() != tintedBg) [f addObject:@"the blue tone did not reach the lexer styles (patchy editor background)"];
        if (styleBg(@"Find Mark Style") != NPPColorFromHex(@"FF0080"))
            [f addObject:@"the tone tinted a marker colour, which has a hue of its own"];
        if ([tm globalStyleNamed:@"Default Style"].fgColor != NPPColorFromHex(@"DCDCCC"))
            [f addObject:@"the tone tinted a foreground; NppDarkMode never tints text"];
        if (styleBg(@"Dark mode background") != NPPColorFromHex(@"202040"))
            [f addObject:@"the blue tone's derived background is not NppDarkMode's darkBlueColors.background"];
        if (styleBg(@"Dark mode edge") != NPPColorFromHex(@"8080A0"))
            [f addObject:@"the derived edge colour is missing NppDarkMode's offsetEdge"];
        if (styleBg(@"Dark mode text") != NPPColorFromHex(@"E0E0E0"))
            [f addObject:@"the tone shifted a palette text colour"];
        NPPStyle *hot = [tm globalStyleNamed:@"Dark mode hot background"];   // darkColors.hotBackground + offsetBlue
        if (hot.bgColor != NPPColorFromHex(@"454565") || hot.fgColor != hot.bgColor ||
            ![tm globalBackgroundColorNamed:@"Dark mode hot background"])
            [f addObject:@"a tone palette slot is not published as a global style carrying its colour in both fg and bg"];
        // Every field tintedStyle copies by hand: dropping one silently unstyles or re-fonts that lexer style.
        NPPStyle *tintedComment = tm->_lexerStyles[@"cpp"].firstObject;   // the tinted copy, not the parsed style
        if (![tintedComment.keywordClass isEqual:@"instre1"] || tintedComment.styleID != 1 ||
            ![tintedComment.name isEqual:@"COMMENT"] || tintedComment.fgColor != NPPColorFromHex(@"7F9F7F") ||
            ![tintedComment.fontName isEqual:@"Consolas"] || tintedComment.fontStyle != 2 || tintedComment.fontSize != 10)
            [f addObject:@"tinting a lexer style lost part of it (styleID/name/keywordClass/fg/font), so keywords, fonts or styles would stop being applied"];

        // A dark theme whose background has a hue of its own — Solarized 002B36, Ruby Blue 112435, vim Dark Blue
        // 000040, HotFudgeSundae 2B0F01, MossyLawn 58693D: five of the seventeen bundled dark themes. A tone that
        // only moves near-neutral greys leaves every one of them exactly as parsed, i.e. a live control that does
        // nothing. The shades derived from that background have to follow it, and the markers still must not.
        NPPLanguageManager *hm = [NPPLanguageManager new];
        NSXMLDocument *hued = [[NSXMLDocument alloc] initWithXMLString:
            @"<NotepadPlus><LexerStyles/><GlobalStyles>"
             "<WidgetStyle name=\"Default Style\" styleID=\"32\" fgColor=\"839496\" bgColor=\"002B36\"/>"
             "<WidgetStyle name=\"Current line background colour\" bgColor=\"073642\"/>"
             "<WidgetStyle name=\"Find Mark Style\" styleID=\"31\" bgColor=\"FF0080\"/>"
             "</GlobalStyles></NotepadPlus>" options:0 error:nil];
        [hm loadStylersFromDocument:hued];                                  // tone is still Blue here
        if ([hm globalStyleNamed:@"Default Style"].bgColor != NPPColorFromHex(@"002B56"))
            [f addObject:@"the tone never reaches a dark theme whose background is not grey (Solarized, Ruby Blue, vim Dark Blue…)"];
        if ([hm globalStyleNamed:@"Current line background colour"].bgColor != NPPColorFromHex(@"073662"))
            [f addObject:@"the tone moved a hued theme's background but not the surfaces shaded from it"];
        if ([hm globalStyleNamed:@"Find Mark Style"].bgColor != NPPColorFromHex(@"FF0080"))
            [f addObject:@"the tone tinted a marker on a hued dark theme"];

        // …and the same rule must not let the tone into a light theme: FDF6E3 is within 0x20 of itself, so only
        // the dark-theme gate keeps Solarized-light from being tinted (its blue channel would clamp to FF).
        [hm loadStylersFromDocument:[[NSXMLDocument alloc] initWithXMLString:
            @"<NotepadPlus><LexerStyles/><GlobalStyles>"
             "<WidgetStyle name=\"Default Style\" styleID=\"32\" fgColor=\"586E75\" bgColor=\"FDF6E3\"/>"
             "</GlobalStyles></NotepadPlus>" options:0 error:nil]];
        if ([hm globalStyleNamed:@"Default Style"].bgColor != NPPColorFromHex(@"FDF6E3"))
            [f addObject:@"a Dark Mode tone was applied to a light theme"];

        // Customized: the 12 stored colours replace the derived palette, and tint by their own distance from black.
        prefs.darkModeTone = NPPDarkModeToneCustomized;
        prefs.darkModeCustomBackground = @"301818";
        [tm rebuildThemeForDarkModeTone];
        if (styleBg(@"Dark mode background") != NPPColorFromHex(@"301818"))
            [f addObject:@"the customised colours did not override the derived tone"];
        if (styleBg(@"Default Style") != NPPColorFromHex(@"4F3737"))   // 3F3F3F + (+0x10, -0x08, -0x08)
            [f addObject:@"the customised background did not tint the theme"];

        prefs.darkModeCustomBackground = savedCustomBg;
        prefs.darkModeTone = NPPDarkModeToneBlack;
        [tm rebuildThemeForDarkModeTone];
        if (styleBg(@"Default Style") != plain || lexerBg() != plain)
            [f addObject:@"returning to the default tone did not restore the theme's own colours"];
    }

    // The tone has to reach the running UI, not just a freshly loaded theme: the shared manager observes the
    // preference, and every consumer re-reads on NPPThemeDidChangeNotification.
    __block NSInteger tonePosts = 0;
    id tobs = [NSNotificationCenter.defaultCenter addObserverForName:NPPThemeDidChangeNotification object:NPPLanguageManager.shared
                                                               queue:nil usingBlock:^(NSNotification *n) { tonePosts++; }];
    prefs.darkModeTone = NPPDarkModeToneBlue;
    BOOL live = [NPPLanguageManager.shared globalStyleNamed:@"Dark mode background"].bgColor == NPPColorFromHex(@"202040");
    NSInteger posted = tonePosts;
    prefs.darkModeTone = savedTone;
    [NSNotificationCenter.defaultCenter removeObserver:tobs];
    if (!live) [f addObject:@"changing the Dark Mode tone did not re-derive the shared manager's palette"];
    if (posted < 1) [f addObject:@"changing the Dark Mode tone did not post NPPThemeDidChangeNotification"];

    // ---- filenames that carry no usable extension (Buffer.cpp:330). The shared manager is the loaded one; when
    // it is not (a caller that never read langs.model.xml) say so rather than passing eleven silent nil == nil.
    NPPLanguageManager *loaded = NPPLanguageManager.shared;
    if (loaded.languages.count == 0) {
        [f addObject:@"the shared language manager has no languages, so the filename map could not be checked"];
    } else {
        NSDictionary<NSString *, NSString *> *byFilename =
            @{@"makefile": @"makefile", @"Makefile": @"makefile", @"GNUmakefile": @"makefile",
              @"CMakeLists.txt": @"cmake", @"SConstruct": @"python", @"SConscript": @"python", @"wscript": @"python",
              @"Rakefile": @"ruby", @"Vagrantfile": @"ruby",
              @"crontab": @"bash", @"PKGBUILD": @"bash", @"APKBUILD": @"bash",
              // upstream folds case, so the capitalisation nobody types has to resolve too
              @"MAKEFILE": @"makefile", @"cmakelists.txt": @"cmake", @"rakefile": @"ruby"};
        for (NSString *name in byFilename) {
            NSURL *url = [NSURL fileURLWithPath:[@"/npp-selfcheck" stringByAppendingPathComponent:name]];
            NSString *got = [loaded languageForFileURL:url].name;
            if (![got isEqualToString:byFilename[name]])
                [f addObject:[NSString stringWithFormat:@"%@ opens as %@, want %@", name, got ?: @"(no language)", byFilename[name]]];
        }
        // …and the table must not swallow a name that only starts like one of its keys.
        if ([[loaded languageForFileURL:[NSURL fileURLWithPath:@"/npp-selfcheck/Makefile.md"]].name isEqualToString:@"makefile"])
            [f addObject:@"Makefile.md was matched by the extension-less filename table instead of its extension"];
    }

    return f;
}

@end
