// NPPAutoCompletion.mm — see header.
//
// HOW TYPING IS HOOKED UP
// Automatic completion needs SCN_CHARADDED, and ScintillaView has exactly ONE delegate (NPPDocument owns it and this
// module may not edit it). So we install a *forwarder* — the same trick NPPMacroManager uses for SCN_MACRORECORD:
// NPPAutoCompleteForwarder remembers the view's current delegate, becomes the delegate, forwards every notification
// unchanged and additionally acts on SCN_CHARADDED / SCN_CALLTIPCLICK. One forwarder per editor, kept in a
// weak-to-strong map so it dies with its view (ScintillaView.delegate is unsafe_unretained).
#import "NPPAutoCompletion.h"
#import "NPPDocument.h"
#import "NPPPreferences.h"
#import "NPPUtils.h"
#include <SciLexer.h>
#include <set>
#include <string>
#include <vector>

// ---- defaults keys (all "NPPAutoComplete.*") ------------------------------------------------------------------
static NSString *const kEnabled       = @"NPPAutoComplete.Enabled";
static NSString *const kMode          = @"NPPAutoComplete.Mode";
static NSString *const kTriggerLength = @"NPPAutoComplete.TriggerLength";
static NSString *const kIgnoreNumbers = @"NPPAutoComplete.IgnoreNumbers";
static NSString *const kBrief         = @"NPPAutoComplete.Brief";
static NSString *const kFuncParams    = @"NPPAutoComplete.FunctionParameterHints";
static NSString *const kHtmlXmlTag    = @"NPPAutoComplete.InsertHTMLCloseTag";

static const size_t kMaxDocumentWords = 2000;    // N++ has no cap; a linear scan of a huge file must still end
static const size_t kMaxPathEntries   = 2000;    // N++ showPathCompletion: same cap, same reason (huge directories)
static const size_t kCloseTagLookback = 512;     // bytes of context read back for the close-tag scan
// Every one of these bounds a *per-keystroke* read out of Scintilla. N++ reads the document through
// SCI_SEARCHINTARGET and never copies it; NPPSciGetRange copies, so the copy has to be bounded or a 100 MB file
// allocates 100 MB on every character typed.
// ponytail: fixed windows around the caret. Words further than 512 KB away stop being offered and a call on a line
// longer than 512 bytes loses its outermost enclosing call. Upgrade path: a SCI_SEARCHINTARGET-based scanner, i.e.
// copy nothing, the way N++ does it.
static const sptr_t kMaxWordScanBytes   = 1 << 20;   // document words: 1 MB centred on the caret
static const sptr_t kMaxCallTipLookback = 512;       // call tip: bytes back from the caret (N++ gives up past 256)
static const sptr_t kMaxPathLookback    = 1024;      // path completion: N++ uses MAX_PATH (260)

// Scintilla splits the completion list on this character, so it must be one that cannot occur inside an entry.
// N++ uses ' ' and thereby mangles its own multi-word keywords ("Loop Until", "!DOCTYPE html", "using static" —
// 15 of them across the shipped API files). '\n' cannot occur in a keyword or in a scanned word. Pinned by a
// self-check against the real API files.
static const char kListSeparator = '\n';

#pragma mark - Pure helpers (everything here is testable without a window)

// std::string -> NSString, nil when the bytes are not valid UTF-8 (a Latin-1 file loaded raw). Used instead of
// @(s.c_str()), which is nil in exactly the same case but reads as if it cannot be — and -addObject:nil throws.
// Every caller here has to decide what to do with the nil; none may hand it straight to a collection.
static NSString *NPPStringFromUTF8(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}

// Port of AutoCompletion::getCloseTag. `text` is document text ending at or after the caret, `caretPos` the offset
// just past the ">" the user typed. Returns "" when nothing should be closed. `isHTML` additionally skips the HTML
// void elements; XML closes everything. The style check ("not inside embedded JS") stays at the call site.
static std::string NPPCloseTagForText(const std::string &text, size_t caretPos, bool isHTML) {
    if (caretPos < 3 || caretPos > text.size()) return "";
    if (text[caretPos - 1] != '>') return "";
    const char prev = text[caretPos - 2], prevprev = text[caretPos - 3];
    if (prevprev == '-' && prev == '-') return "";                 // "-->": closing a comment
    if (prev == '/') return "";                                     // "<toto/>" and "<toto arg="0" />"

    // N++ searches backwards for the regex "<[^\s>]*": the last "<" before the caret plus its run of tag-name
    // characters. An attribute value containing ">" is therefore harmless — the run stops at the first blank.
    const size_t open = text.rfind('<', caretPos - 1);
    if (open == std::string::npos) return "";
    size_t end = open + 1;
    while (end < caretPos && !isspace((unsigned char)text[end]) && text[end] != '>') ++end;
    const size_t len = end - open;
    if (len < 2) return "";                                         // "<>"
    if (text[open + 1] == '/') return "";                           // "</toto>"
    if (text[open + 1] == '?') return "";                           // "<?xml ... ?>", "<?php"
    if (text.compare(open, 4, "<!--") == 0) return "";              // comments

    const std::string name = text.substr(open + 1, len - 1);
    if (isHTML) {
        // https://www.w3.org/TR/html5/syntax.html#void-elements (plus "!doctype", as N++ does)
        static const char *const voidTags[] = {"area", "base", "br", "col", "embed", "hr", "img", "input",
                                               "keygen", "link", "meta", "param", "source", "track", "wbr",
                                               "!doctype"};
        // ponytail: whole-name compare, where N++ compares only the void tag's own length — so N++ also swallows
        // "<brx>". Upgrade path: none wanted, this is the bug-compatible-minus-the-bug version.
        for (const char *v : voidTags)
            if (name.size() == strlen(v) && strncasecmp(name.c_str(), v, name.size()) == 0) return "";
    }
    return "</" + name + ">";
}

// The filesystem path the user is typing, taken from the text before the caret. Inside an unclosed quote the whole
// quoted run is used (so a path may contain spaces); otherwise the trailing run of non-blank characters. "" when
// there is no "/" in it — i.e. when this is not a path at all.
// ponytail: N++ anchors on a Windows drive letter ("C:"); on macOS a "/" is the only thing that marks a path.
static std::string NPPRawPathBeforeCaret(const std::string &before) {
    char quote = 0;
    size_t quoteStart = std::string::npos;
    for (size_t i = 0; i < before.size(); ++i) {
        const char c = before[i];
        if (c == '\n' || c == '\r') { quote = 0; quoteStart = std::string::npos; continue; }
        if (c != '"' && c != '\'') continue;
        if (quote == 0) { quote = c; quoteStart = i + 1; }
        else if (quote == c) { quote = 0; quoteStart = std::string::npos; }
    }
    std::string raw;
    if (quote != 0 && quoteStart != std::string::npos) {
        raw = before.substr(quoteStart);
    } else {
        static const std::string stops = " \t\n\r()[]{}<>=,;:*?|\"'`";
        const size_t cut = before.find_last_of(stops);
        raw = cut == std::string::npos ? before : before.substr(cut + 1);
    }
    return raw.find('/') == std::string::npos ? "" : raw;
}

// A completion entry replaces the whole raw path, so it has to be spelled the way the user started it ("~/…" stays
// "~/…"). This is the part before the last "/", with no trailing slash, so that prefix + "/" + name never doubles
// the separator — at the filesystem root ("/a") that means the empty string, not "/".
static NSString *NPPPathEntryPrefix(NSString *rawPath) {
    NSString *prefix = [rawPath hasSuffix:@"/"] ? [rawPath substringToIndex:rawPath.length - 1]
                                                : rawPath.stringByDeletingLastPathComponent;
    return [prefix isEqualToString:@"/"] ? @"" : prefix;
}

// ---- Which key accepts the highlighted completion (N++ NppGUI::_autocInsertSelectedUseTAB / …UseENTER) --------
// Scintilla asks (SCN_AUTOCSELECTION) before it inserts, and cancelling the list inside that notification makes it
// insert nothing — so taking a key away means "cancel, then do what the key does with no list on screen".
// Returns 0 to let Scintilla insert the completion, else the SCI_* message the key should have produced instead.
// Pure so the rule can be checked without an editor; the notification handler is a two-line adapter over it.
static unsigned int NPPAutoCompleteOverrideMessage(int completionMethod, BOOL automaticPopup,
                                                   BOOL useTab, BOOL useEnter) {
    // N++: with the automatic popup off, the list can only be on screen because the user asked for it — and then
    // both keys insert, whatever the two settings say.
    if (!automaticPopup) return 0;
    if (completionMethod == SC_AC_NEWLINE && !useEnter) return SCI_NEWLINE;
    if (completionMethod == SC_AC_TAB && !useTab) return SCI_TAB;
    return 0;    // fill-up character, double click, single choice, SCI_AUTOCCOMPLETE: always inserts
}

// ---- Auto-completion colours (N++ AutoCompletion::setColour + Notepad_plus::drawAutocompleteColoursFromTheme) --
// Scintilla stores a colour as 0xBBGGRR. N++ shifts each component by ±20 to get the "darker"/"lighter" variants
// the list and the call tip are drawn in.
static long NPPShiftColour(long colour, int delta) {
    long out = 0;
    for (int shift = 0; shift <= 16; shift += 8) {
        int c = (int)((colour >> shift) & 0xFF) + delta;
        out |= (long)(c < 0 ? 0 : (c > 255 ? 255 : c)) << shift;
    }
    return out;
}

// The seven colours AutoCompletion::drawAutocomplete pushes, in its order. -1 means "put the platform's own back"
// (SCI_RESETELEMENTCOLOUR), which is what N++'s GetSysColor branch amounts to on macOS.
static const long kNPPElementDefault = -1;
struct NPPAutoCompleteColours { long list, listBack, selected, selectedBack, tipBack, tipFore, tipHighlight; };

// Pure, so the two branches can be checked without an editor. N++ drawAutocompleteColoursFromTheme.
static NPPAutoCompleteColours NPPAutoCompleteColoursForTheme(long fg, long bg) {
    // A plain-white background gets the platform's list colours and CallTip.cxx's own defaults back. It has to
    // WRITE them: this runs on a live view that a dark theme may already have been pushed into, and returning
    // early would leave the list dark on a white page for the rest of the session.
    if (bg == 0xFFFFFF)
        return { kNPPElementDefault, kNPPElementDefault, kNPPElementDefault, kNPPElementDefault,
                 0xFFFFFF, 0x808080, 0x800000 };
    const long bgDarker = (bg == 0) ? 0x141414 : NPPShiftColour(bg, -20);   // pure black would stay black
    const long fgDarker = NPPShiftColour(fg, -20);
    return { fgDarker, bgDarker, fg, bg, bgDarker, fgDarker, NPPShiftColour(fg, +20) };
}

// N++ derives these from the theme's Default Style once per theme change and pushes them into both views. There is
// no theme-changed hook in this module, so they are re-derived from the view's STYLE_DEFAULT just before the list
// or the tip is shown: same values, and they cannot go stale.
static void NPPApplyAutoCompleteColours(ScintillaView *editor) {
    const NPPAutoCompleteColours c =
        NPPAutoCompleteColoursForTheme(NPPSci(editor, SCI_STYLEGETFORE, STYLE_DEFAULT),
                                       NPPSci(editor, SCI_STYLEGETBACK, STYLE_DEFAULT));
    const int elements[4] = { SC_ELEMENT_LIST, SC_ELEMENT_LIST_BACK,
                              SC_ELEMENT_LIST_SELECTED, SC_ELEMENT_LIST_SELECTED_BACK };
    const long colours[4] = { c.list, c.listBack, c.selected, c.selectedBack };
    for (int i = 0; i < 4; ++i) {
        if (colours[i] == kNPPElementDefault) NPPSci(editor, SCI_RESETELEMENTCOLOUR, (uptr_t)elements[i]);
        // SCI_SETELEMENTCOLOUR takes 0xAABBGGRR: without the alpha byte the element is fully transparent.
        else NPPSci(editor, SCI_SETELEMENTCOLOUR, (uptr_t)elements[i], (sptr_t)(0xFF000000 | colours[i]));
    }
    NPPSci(editor, SCI_CALLTIPSETBACK, (uptr_t)c.tipBack);
    NPPSci(editor, SCI_CALLTIPSETFORE, (uptr_t)c.tipFore);
    NPPSci(editor, SCI_CALLTIPSETFOREHLT, (uptr_t)c.tipHighlight);
}

// One token of a source line: an identifier run, or a single significant character.
struct NPPCallTipToken { size_t offset; size_t length; bool isIdentifier; };
struct NPPCallTipTarget { std::string name; size_t param = 0; bool found = false; };

// Port of FunctionCallTip::getCursorFunction. `line` is the current line up to (not including) the caret; the result
// is the innermost function call the caret sits in and the index of the parameter it sits on.
static NPPCallTipTarget NPPFunctionAtCaret(const std::string &line, char start, char stop, char paramSep,
                                           char terminal, const std::string &extraWordChars) {
    NPPCallTipTarget target;
    if (line.size() < 2) return target;                             // needs at least a name and a separator

    auto isWordChar = [&](char c) {
        return isalnum((unsigned char)c) || c == '_' || (c && extraWordChars.find(c) != std::string::npos);
    };
    std::vector<NPPCallTipToken> tokens;
    for (size_t i = 0; i < line.size(); ++i) {
        const char ch = line[i];
        if (isWordChar(ch)) {
            const size_t begin = i;
            while (i < line.size() && isWordChar(line[i])) ++i;
            tokens.push_back({begin, i - begin, true});
            --i;                                                     // correct the while loop's overshoot
        } else if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r') {
            tokens.push_back({i, 1, false});
        }
    }

    // Nested calls ("a(x, b(), c)") need a stack: on "(" the current state is pushed, on ")" it is popped back.
    struct FV { long lastIdentifier = -1; long lastFunction = -1; long param = 0; };
    std::vector<FV> stack;
    FV cur;
    long scopeLevel = 0;
    for (size_t i = 0; i < tokens.size(); ++i) {
        if (tokens[i].isIdentifier) { cur.lastIdentifier = (long)i; continue; }
        const char c = line[tokens[i].offset];
        if (c == start) {
            ++scopeLevel;
            stack.push_back(cur);
            // The identifier must sit immediately before "(", else this is an expression like "( x + y() )".
            if (i > 0 && cur.lastIdentifier == (long)i - 1) { cur.lastFunction = cur.lastIdentifier; cur.param = 0; }
            else cur.lastFunction = -1;
        } else if (c == paramSep && cur.lastFunction > -1) {
            ++cur.param;
        } else if (c == stop) {
            if (scopeLevel) --scopeLevel;
            if (!stack.empty()) { cur = stack.back(); stack.pop_back(); } else cur = FV();
        } else if (c == terminal) {
            stack.clear();
            cur = FV();                                              // statement over: nothing is open any more
        }
    }
    while (cur.lastFunction == -1 && !stack.empty()) { cur = stack.back(); stack.pop_back(); }
    if (cur.lastFunction > -1) {
        const NPPCallTipToken &f = tokens[(size_t)cur.lastFunction];
        target.name = line.substr(f.offset, f.length);
        target.param = (size_t)cur.param;
        target.found = true;
    }
    return target;
}

// Words of the document starting with `prefix`, excluding the whole word the caret is inside (N++ excludeChars).
// `doc` is a window out of the document, not necessarily the whole of it: clippedStart/clippedEnd say whether the
// window was cut mid-file, in which case the runs touching those edges are half words ("pha" out of "alpha") and
// are dropped rather than offered.
// ponytail: word = ASCII alnum / "_" / any non-ASCII byte plus the API file's additionalWordChar, where N++ uses a
// regex with an exclusion list. One linear scan, no std::regex. Capped at kMaxDocumentWords.
static std::vector<std::string> NPPDocumentWords(const std::string &doc, const std::string &prefix,
                                                 const std::string &exclude, bool ignoreCase,
                                                 const std::string &extraWordChars,
                                                 bool clippedStart = false, bool clippedEnd = false) {
    auto isWord = [&](unsigned char c) {
        return isalnum(c) || c == '_' || c >= 0x80 || (c && extraWordChars.find((char)c) != std::string::npos);
    };
    auto matches = [&](const char *w, size_t n) {
        if (n <= prefix.size()) return false;
        return ignoreCase ? strncasecmp(w, prefix.c_str(), prefix.size()) == 0
                          : strncmp(w, prefix.c_str(), prefix.size()) == 0;
    };
    std::set<std::string> words;
    const size_t n = doc.size();
    size_t i = 0;
    if (clippedStart) while (i < n && isWord((unsigned char)doc[i])) ++i;   // the word the window cut in half
    while (i < n && words.size() < kMaxDocumentWords) {
        if (!isWord((unsigned char)doc[i])) { ++i; continue; }
        size_t j = i;
        while (j < n && isWord((unsigned char)doc[j])) ++j;
        if (!(clippedEnd && j == n) && matches(doc.data() + i, j - i)) {
            std::string w(doc.data() + i, j - i);
            if (w != exclude) words.insert(std::move(w));
        }
        i = j;
    }
    return std::vector<std::string>(words.begin(), words.end());
}

static BOOL NPPIsAllDigits(const std::string &s) {
    if (s.empty()) return NO;
    for (char c : s) if (!isdigit((unsigned char)c)) return NO;
    return YES;
}

// The markup languages that get an auto-inserted closing tag. N++ restricts this to HTML and XML; PHP/JSP/ASP files
// are HTML with islands, so they are in too. *isHTML tells the void-element rule apart from "close everything".
static BOOL NPPLanguageIsMarkup(NSString *name, BOOL *isHTML) {
    static NSSet *html, *xmlish;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        html = [NSSet setWithArray:@[@"html", @"php", @"jsp", @"asp"]];
        xmlish = [NSSet setWithArray:@[@"xml"]];
    });
    NSString *n = name.lowercaseString ?: @"";
    if ([html containsObject:n]) { if (isHTML) *isHTML = YES; return YES; }
    if ([xmlish containsObject:n]) { if (isHTML) *isHTML = NO; return YES; }
    return NO;
}

#pragma mark - API word list (APIs/<language>.xml)

// One <Overload> of a <KeyWord func="yes">.
@interface NPPAPIOverload : NSObject
@property (nonatomic, copy) NSString *retVal;
@property (nonatomic, copy) NSString *descr;
@property (nonatomic, copy) NSArray<NSString *> *params;
@end
@implementation NPPAPIOverload
@end

// One parsed APIs/<language>.xml: the <Environment> settings plus every <KeyWord>.
@interface NPPAPIWordList : NSObject
@property (nonatomic, readonly, copy) NSArray<NSString *> *keywords;       // sorted the way this list compares
@property (nonatomic, readonly, copy) NSString *joinedKeywords;            // -keywords ready for SCI_AUTOCSHOW
@property (nonatomic, readonly) BOOL ignoreCase;
@property (nonatomic, readonly) char startFunc, stopFunc, paramSeparator, terminal;
@property (nonatomic, readonly, copy) NSString *additionalWordChars;
+ (nullable instancetype)listWithXMLData:(NSData *)data error:(NSError **)error;
+ (nullable instancetype)listWithContentsOfURL:(NSURL *)url;
- (NSArray<NSString *> *)keywordsMatchingPrefix:(NSString *)prefix;
- (nullable NSArray<NPPAPIOverload *> *)overloadsForFunctionNamed:(NSString *)name;   // nil unless it is a function
@end

@implementation NPPAPIWordList {
    NSDictionary<NSString *, NSArray<NPPAPIOverload *> *> *_overloads;   // key lowercased when ignoreCase
}

+ (nullable instancetype)listWithContentsOfURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    NSError *err = nil;
    NPPAPIWordList *list = [self listWithXMLData:data error:&err];
    if (!list) NSLog(@"[AutoCompletion] %@ skipped: %@", url.lastPathComponent, err.localizedDescription);
    return list;
}

+ (nullable instancetype)listWithXMLData:(NSData *)data error:(NSError **)error {
    NSXMLDocument *xml = [[NSXMLDocument alloc] initWithData:data options:0 error:error];
    NSXMLElement *ac = [[xml.rootElement elementsForName:@"AutoComplete"] firstObject];
    if (!ac) return nil;

    NPPAPIWordList *list = [[NPPAPIWordList alloc] init];
    // N++ defaults, overridden by <Environment>.
    list->_ignoreCase = YES;
    list->_startFunc = '('; list->_stopFunc = ')'; list->_paramSeparator = ','; list->_terminal = ';';
    list->_additionalWordChars = @"";

    NSXMLElement *env = [[ac elementsForName:@"Environment"] firstObject];
    if (env) {
        NSString *(^attr)(NSString *) = ^(NSString *n) { return [env attributeForName:n].stringValue; };
        if ([attr(@"ignoreCase") isEqualToString:@"no"]) list->_ignoreCase = NO;
        NSString *s;
        if ((s = attr(@"startFunc")).length)      list->_startFunc = (char)[s characterAtIndex:0];
        if ((s = attr(@"stopFunc")).length)       list->_stopFunc = (char)[s characterAtIndex:0];
        if ((s = attr(@"paramSeparator")).length) list->_paramSeparator = (char)[s characterAtIndex:0];
        if ((s = attr(@"terminal")).length)       list->_terminal = (char)[s characterAtIndex:0];
        if ((s = attr(@"additionalWordChar")).length) list->_additionalWordChars = [s copy];
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSArray<NPPAPIOverload *> *> *overloads = [NSMutableDictionary dictionary];
    for (NSXMLElement *kw in [ac elementsForName:@"KeyWord"]) {
        NSString *name = [kw attributeForName:@"name"].stringValue;
        if (!name.length) continue;
        [names addObject:name];
        if (![[kw attributeForName:@"func"].stringValue isEqualToString:@"yes"]) continue;

        NSMutableArray<NPPAPIOverload *> *ovs = [NSMutableArray array];
        for (NSXMLElement *o in [kw elementsForName:@"Overload"]) {
            NSString *retVal = [o attributeForName:@"retVal"].stringValue;
            if (!retVal) continue;                                   // malformed node, as N++ has it
            NPPAPIOverload *ov = [[NPPAPIOverload alloc] init];
            ov.retVal = retVal;
            ov.descr = [o attributeForName:@"descr"].stringValue ?: @"";
            NSMutableArray<NSString *> *params = [NSMutableArray array];
            for (NSXMLElement *p in [o elementsForName:@"Param"]) {
                NSString *pn = [p attributeForName:@"name"].stringValue;
                if (pn) [params addObject:pn];
            }
            ov.params = params;
            [ovs addObject:ov];
        }
        // N++ treats a func="yes" keyword with no usable <Overload> as "no call tip available".
        if (ovs.count) overloads[list->_ignoreCase ? name.lowercaseString : name] = ovs;
    }
    if (!names.count) return nil;

    list->_keywords = [names sortedArrayUsingSelector:list->_ignoreCase ? @selector(caseInsensitiveCompare:)
                                                                        : @selector(compare:)];
    // Joined once here, not per keystroke: autoit.xml has ~10k keywords and function mode hands Scintilla the whole
    // list on every character typed (N++ keeps the same string in _keyWords for the same reason).
    list->_joinedKeywords = [list->_keywords componentsJoinedByString:[NSString stringWithFormat:@"%c", kListSeparator]];
    list->_overloads = overloads;
    return list;
}

- (NSArray<NSString *> *)keywordsMatchingPrefix:(NSString *)prefix {
    if (!prefix.length) return _keywords;
    NSStringCompareOptions opt = NSAnchoredSearch | (_ignoreCase ? NSCaseInsensitiveSearch : 0);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *k in _keywords)
        if ([k rangeOfString:prefix options:opt].location == 0) [out addObject:k];
    return out;
}

- (nullable NSArray<NPPAPIOverload *> *)overloadsForFunctionNamed:(NSString *)name {
    if (!name.length) return nil;
    return _overloads[_ignoreCase ? name.lowercaseString : name];
}

@end

#pragma mark - Delegate forwarder

@class NPPAutoCompletion;

@interface NPPAutoCompleteForwarder : NSObject <NPPScintillaForwarder>
@property (nonatomic, weak) id<ScintillaNotificationProtocol> previousDelegate;
@property (nonatomic, weak) ScintillaView *view;
@property (nonatomic, weak) NPPAutoCompletion *owner;
- (void)uninstall;
@end

@interface NPPAutoCompletion (Forwarding)
- (void)characterAdded:(int)ch inEditor:(ScintillaView *)editor;
- (void)callTipClicked:(sptr_t)direction inEditor:(ScintillaView *)editor;
- (void)completionSelectedBy:(int)completionMethod inEditor:(ScintillaView *)editor;
@end

@implementation NPPAutoCompleteForwarder

- (void)notification:(SCNotification *)n {
    [self.previousDelegate notification:n];        // the document's own handling (auto-indent, brace match) runs first
    if (!n) return;
    ScintillaView *v = self.view;
    if (!v) return;
    if (n->nmhdr.code == SCN_CHARADDED) [self.owner characterAdded:n->ch inEditor:v];
    else if (n->nmhdr.code == SCN_CALLTIPCLICK) [self.owner callTipClicked:n->position inEditor:v];
    // Sent while Scintilla is deciding whether to insert; see NPPAutoCompleteOverrideMessage.
    else if (n->nmhdr.code == SCN_AUTOCSELECTION) [self.owner completionSelectedBy:n->listCompletionMethod inEditor:v];
}

- (void)uninstall {
    ScintillaView *v = self.view;
    NPPRemoveScintillaForwarder(v, self);   // splices out of the middle of the chain too
    self.view = nil;
    self.previousDelegate = nil;
}

- (void)dealloc { [self uninstall]; }

@end

#pragma mark - NPPAutoCompletion

@implementation NPPAutoCompletion {
    id<NPPCommandContext> __weak _context;
    NSMapTable<ScintillaView *, NPPAutoCompleteForwarder *> *_forwarders;   // weak key -> strong forwarder
    NSMutableDictionary<NSString *, id> *_apiCache;                        // language name -> list, or NSNull
    // Current call tip (N++ FunctionCallTip state). N++ keeps one per view; this module is a singleton, so the tip
    // records the editor it belongs to and Previous/Next refuse to cycle a tip that belongs to another tab.
    ScintillaView *__weak _tipEditor;
    NSString *_tipFunction;
    NSArray<NPPAPIOverload *> *_tipOverloads;
    NSUInteger _tipOverload, _tipParam;
    sptr_t _tipStartPos;
    BOOL _tipSelfActivated;
}

+ (void)load {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kEnabled: @YES, kMode: @(NPPAutoCompleteModeBoth), kTriggerLength: @1,
        kIgnoreNumbers: @YES, kBrief: @NO, kFuncParams: @YES, kHtmlXmlTag: @YES,
    }];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:[self shared] selector:@selector(contextReady:)
               name:NPPCommandContextReadyNotification object:nil];
    [nc addObserver:[self shared] selector:@selector(currentDocumentChanged:)
               name:NPPCurrentDocumentDidChangeNotification object:nil];
}

+ (instancetype)shared {
    static NPPAutoCompletion *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPAutoCompletion alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _forwarders = [NSMapTable weakToStrongObjectsMapTable];
        _apiCache = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Settings

static NSInteger NPPDefaultsInt(NSString *key) { return [NSUserDefaults.standardUserDefaults integerForKey:key]; }
static BOOL NPPDefaultsBool(NSString *key) { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
static void NPPDefaultsSet(NSString *key, id value) { [NSUserDefaults.standardUserDefaults setObject:value forKey:key]; }

- (BOOL)enabled { return NPPDefaultsBool(kEnabled); }
- (void)setEnabled:(BOOL)v { NPPDefaultsSet(kEnabled, @(v)); }
- (NPPAutoCompleteMode)mode {
    NSInteger m = NPPDefaultsInt(kMode);
    return (m < NPPAutoCompleteModeNone || m > NPPAutoCompleteModeBoth) ? NPPAutoCompleteModeBoth
                                                                       : (NPPAutoCompleteMode)m;
}
- (void)setMode:(NPPAutoCompleteMode)v { NPPDefaultsSet(kMode, @(v)); }
- (NSInteger)triggerLength { return MAX((NSInteger)1, NPPDefaultsInt(kTriggerLength)); }
- (void)setTriggerLength:(NSInteger)v { NPPDefaultsSet(kTriggerLength, @(MAX((NSInteger)1, v))); }
- (BOOL)ignoreNumbers { return NPPDefaultsBool(kIgnoreNumbers); }
- (void)setIgnoreNumbers:(BOOL)v { NPPDefaultsSet(kIgnoreNumbers, @(v)); }
- (BOOL)briefMode { return NPPDefaultsBool(kBrief); }
- (void)setBriefMode:(BOOL)v { NPPDefaultsSet(kBrief, @(v)); }
- (BOOL)functionParameterHints { return NPPDefaultsBool(kFuncParams); }
- (void)setFunctionParameterHints:(BOOL)v { NPPDefaultsSet(kFuncParams, @(v)); }
- (BOOL)insertHTMLCloseTag { return NPPDefaultsBool(kHtmlXmlTag); }
- (void)setInsertHTMLCloseTag:(BOOL)v { NPPDefaultsSet(kHtmlXmlTag, @(v)); }

#pragma mark - Editor hookup

- (void)contextReady:(NSNotification *)note {
    _context = note.object;
    [self installForwarderOnCurrentEditor];
}

- (void)currentDocumentChanged:(NSNotification *)note {
    _context = note.object;
    [self installForwarderOnCurrentEditor];
}

- (void)installForwarderOnCurrentEditor {
    ScintillaView *v = [_context contextCurrentDocument].editor;
    if (!v || [_forwarders objectForKey:v]) return;                  // already hooked (the map dies with the view)
    // ponytail: last installer wins the delegate chain. We install as soon as a view is current (context-ready and
    // every document change) and NPPDocument only ever assigns .delegate in -init, so in practice we are always
    // *under* NPPMacroManager's forwarder: chain macro -> us -> document, and the macro's uninstall restores us.
    // The order that would break is us installing on top of the macro forwarder — its -uninstall only restores when
    // it is still the delegate, so it would silently drop the document's own notifications. Reachable only if a view
    // becomes current for the first time while a macro is already recording.
    // Upgrade path: a shared notification multiplexer in NPPDocument, which this module may not touch.
    NPPAutoCompleteForwarder *f = [[NPPAutoCompleteForwarder alloc] init];
    f.view = v;
    f.owner = self;
    f.previousDelegate = v.delegate;
    v.delegate = f;
    [_forwarders setObject:f forKey:v];
}

- (nullable NPPDocument *)documentForEditor:(ScintillaView *)editor {
    for (NPPDocument *d in [_context contextOpenDocuments]) if (d.editor == editor) return d;
    return nil;
}

#pragma mark - API files

// The directory holding APIs/<language>.xml.
// ponytail: the Makefile bundles functionList/ and themes/ but not APIs/, and this module may not edit it, so the
// upstream checkout is the fallback. Upgrade path: add
//     mkdir -p $(APP)/Contents/Resources/autoCompletion && cp $(NPP)/PowerEditor/installer/APIs/*.xml $(APP)/Contents/Resources/autoCompletion/
// to the bundle rule and the bundled copy wins automatically.
+ (nullable NSURL *)apiDirectoryURL {
    static NSURL *dir; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *name in @[@"autoCompletion", @"APIs"]) {
            NSURL *u = [NSBundle.mainBundle URLForResource:name withExtension:nil];
            if (u && [fm fileExistsAtPath:u.path]) { dir = u; return; }
        }
        NSString *path = NPPUpstreamPath(@"PowerEditor/installer/APIs");   // development fallback only
        if (path) dir = [NSURL fileURLWithPath:path];
    });
    return dir;
}

// langs.model.xml language name -> API file basename, for the handful that do not match.
+ (NSString *)apiFileBaseNameForLanguage:(NSString *)name {
    static NSDictionary *aliases; static dispatch_once_t once;
    dispatch_once(&once, ^{ aliases = @{@"javascript.js": @"javascript",     // N++ maps L_JAVASCRIPT -> L_JS_EMBEDDED
                                        @"coffeescript": @"coffee",
                                        @"latex": @"tex",
                                        @"objc": @"c"}; });
    return aliases[name] ?: name;
}

- (nullable NPPAPIWordList *)apiListForLanguageNamed:(NSString *)langName {
    NSString *name = langName.lowercaseString;
    if (!name.length || [name isEqualToString:@"normal"]) return nil;
    id cached = _apiCache[name];
    if (cached) return cached == NSNull.null ? nil : cached;

    NSURL *dir = [[self class] apiDirectoryURL];
    NPPAPIWordList *list = nil;
    if (dir) {
        NSString *base = [[self class] apiFileBaseNameForLanguage:name];
        // The shipped files are not all lowercase ("BaanC.xml"), so match the directory listing case-insensitively.
        static NSDictionary<NSString *, NSString *> *byLowercaseName;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.path error:NULL])
                if ([f.pathExtension.lowercaseString isEqualToString:@"xml"]) m[f.lowercaseString] = f;
            byLowercaseName = m;
        });
        NSString *file = byLowercaseName[[base stringByAppendingString:@".xml"]];
        if (file) list = [NPPAPIWordList listWithContentsOfURL:[dir URLByAppendingPathComponent:file]];
    }
    _apiCache[name] = list ?: (id)NSNull.null;
    return list;
}

- (nullable NPPAPIWordList *)apiListForEditor:(ScintillaView *)editor {
    return [self apiListForLanguageNamed:[self documentForEditor:editor].language.name ?: @""];
}

#pragma mark - Completion

// The word being typed, i.e. the text from SCI_WORDSTARTPOSITION to the caret.
static std::string NPPPrefixAtCaret(ScintillaView *ed, sptr_t *startOut) {
    const sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    const sptr_t start = NPPSci(ed, SCI_WORDSTARTPOSITION, (uptr_t)caret, 1);
    if (startOut) *startOut = start;
    return start >= caret ? std::string() : NPPSciGetRange(ed, start, caret);
}

- (void)showCompletionInEditor:(ScintillaView *)editor mode:(NPPAutoCompleteMode)mode brief:(BOOL)brief {
    sptr_t start = 0;
    const std::string prefix = NPPPrefixAtCaret(editor, &start);
    if (prefix.empty()) return;
    if (self.ignoreNumbers && NPPIsAllDigits(prefix)) return;

    NPPAPIWordList *api = [self apiListForEditor:editor];
    if (mode == NPPAutoCompleteModeFunction && !api) return;

    const BOOL ignoreCase = api ? api.ignoreCase : NO;
    NSString *listText = nil;

    if (mode == NPPAutoCompleteModeFunction && !brief) {
        // Non-brief function completion hands Scintilla the whole list and lets it filter (N++ autocFunc), so the
        // pre-joined string is exactly what is wanted — no per-keystroke copy, sort or join of ~10k keywords.
        if (!api.keywords.count) return;
        listText = api.joinedKeywords;
    } else {
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        if (mode != NPPAutoCompleteModeFunction) {
            const sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
            const sptr_t end = NPPSci(editor, SCI_WORDENDPOSITION, (uptr_t)caret, 1);
            const std::string exclude = end > start ? NPPSciGetRange(editor, start, end) : std::string();
            const std::string extra = api.additionalWordChars.UTF8String ?: "";
            // Bounded window around the caret — see kMaxWordScanBytes. This runs on every character typed.
            const sptr_t docLen = NPPSci(editor, SCI_GETLENGTH);
            const sptr_t from = MAX((sptr_t)0, caret - kMaxWordScanBytes / 2);
            const sptr_t to = MIN(docLen, from + kMaxWordScanBytes);
            const std::string window = NPPSciGetRange(editor, from, to);
            for (const std::string &w : NPPDocumentWords(window, prefix, exclude, ignoreCase, extra,
                                                         from > 0, to < docLen)) {
                // A word out of a file that is not valid UTF-8 has no NSString: skip it rather than throw.
                NSString *s = NPPStringFromUTF8(w);
                if (s) [candidates addObject:s];
            }
        }

        if (api && mode != NPPAutoCompleteModeWord) {
            NSString *nsPrefix = NPPStringFromUTF8(prefix);
            NSArray<NSString *> *kw = nsPrefix ? [api keywordsMatchingPrefix:nsPrefix] : @[];
            if (!candidates.count) {
                [candidates addObjectsFromArray:kw];        // autoit.xml has ~10k keywords: no O(n²) merge
            } else {
                NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:candidates];
                for (NSString *k in kw) if (![seen containsObject:k]) { [seen addObject:k]; [candidates addObject:k]; }
            }
        }
        if (!candidates.count) return;
        [candidates sortUsingSelector:ignoreCase ? @selector(caseInsensitiveCompare:) : @selector(compare:)];
        listText = [candidates componentsJoinedByString:[NSString stringWithFormat:@"%c", kListSeparator]];
    }

    // ponytail: no \x1E type separator / registered xpm icons, so a function and a plain keyword look alike in the
    // list. Upgrade path: SCI_REGISTERIMAGE two images and append "\x1E<id>" the way N++ does.
    NPPApplyAutoCompleteColours(editor);
    NPPSci(editor, SCI_AUTOCSETSEPARATOR, kListSeparator);
    NPPSci(editor, SCI_AUTOCSETIGNORECASE, ignoreCase);
    NPPSci(editor, SCI_AUTOCSETCASEINSENSITIVEBEHAVIOUR, ignoreCase ? SC_CASEINSENSITIVEBEHAVIOUR_IGNORECASE
                                                                    : SC_CASEINSENSITIVEBEHAVIOUR_RESPECTCASE);
    NPPSciStr(editor, SCI_AUTOCSHOW, (uptr_t)prefix.size(), listText.UTF8String);
}

#pragma mark - Path completion

- (void)showPathCompletionInEditor:(ScintillaView *)editor {
    const sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
    const sptr_t line = NPPSci(editor, SCI_LINEFROMPOSITION, (uptr_t)caret);
    const sptr_t lineStart = NPPSci(editor, SCI_POSITIONFROMLINE, (uptr_t)line);
    // Bounded look-back (kMaxPathLookback): a minified one-line file must not be copied whole. Clipping the start can
    // hide the opening quote of a very long quoted path, which then falls back to the whitespace-delimited run.
    const std::string before = NPPSciGetRange(editor, MAX(lineStart, caret - kMaxPathLookback), caret);
    const std::string raw = NPPRawPathBeforeCaret(before);
    if (raw.empty()) return;

    NSString *rawPath = NPPStringFromUTF8(raw);
    if (!rawPath) return;                                            // not valid UTF-8: not a path we can complete
    NSString *expanded = rawPath.stringByExpandingTildeInPath;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    NSString *dir, *base;
    if ([fm fileExistsAtPath:expanded isDirectory:&isDir] && isDir) { dir = expanded; base = @""; }
    else { dir = expanded.stringByDeletingLastPathComponent; base = expanded.lastPathComponent; }
    if (!dir.length) return;

    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
    if (!names) return;
    NSString *rawDir = NPPPathEntryPrefix(rawPath);
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    NSString *sep = [NSString stringWithFormat:@"%c", kListSeparator];
    for (NSString *n in names) {
        if (entries.count >= kMaxPathEntries) break;
        if (base.length && [n rangeOfString:base options:NSAnchoredSearch | NSCaseInsensitiveSearch].location != 0)
            continue;
        if ([n containsString:sep]) continue;      // a newline is legal in a file name and would split the list
        BOOL entryIsDir = NO;
        [fm fileExistsAtPath:[dir stringByAppendingPathComponent:n] isDirectory:&entryIsDir];
        NSString *e = [NSString stringWithFormat:@"%@/%@", rawDir, n];   // rawDir is "" at the filesystem root
        [entries addObject:entryIsDir ? [e stringByAppendingString:@"/"] : e];
    }
    if (!entries.count) return;

    [entries sortUsingSelector:@selector(caseInsensitiveCompare:)];
    NPPApplyAutoCompleteColours(editor);
    NPPSci(editor, SCI_AUTOCSETSEPARATOR, kListSeparator);
    NPPSci(editor, SCI_AUTOCSETIGNORECASE, 1);
    NPPSci(editor, SCI_AUTOCSETCASEINSENSITIVEBEHAVIOUR, SC_CASEINSENSITIVEBEHAVIOUR_IGNORECASE);
    NPPSciStr(editor, SCI_AUTOCSHOW, (uptr_t)raw.size(), [[entries componentsJoinedByString:sep] UTF8String]);
}

#pragma mark - Call tips (N++ FunctionCallTip)

- (BOOL)callTipIsVisible:(ScintillaView *)editor { return NPPSci(editor, SCI_CALLTIPACTIVE) != 0; }

- (void)closeCallTip:(ScintillaView *)editor {
    if (![self callTipIsVisible:editor] || !_tipSelfActivated) return;
    NPPSci(editor, SCI_CALLTIPCANCEL);
    _tipSelfActivated = NO;
    _tipOverload = 0;
    _tipOverloads = nil;                                             // N++ reset(): nothing left to cycle through
    _tipFunction = nil;
    _tipEditor = nil;
}

// N++ FunctionCallTip::updateCalltip. `ch` is the character just typed (0 when the caller asked for the tip).
- (BOOL)updateCallTipInEditor:(ScintillaView *)editor character:(int)ch needShown:(BOOL)needShown {
    NPPAPIWordList *api = [self apiListForEditor:editor];
    if (!api) return NO;
    if (!needShown && ch != api.startFunc && ch != api.paramSeparator && ![self callTipIsVisible:editor]) return NO;

    const sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
    const sptr_t line = NPPSci(editor, SCI_LINEFROMPOSITION, (uptr_t)caret);
    const sptr_t lineStart = NPPSci(editor, SCI_POSITIONFROMLINE, (uptr_t)line);
    // Bounded look-back (kMaxCallTipLookback): this runs on every character typed, and a minified file is one line.
    // N++ simply gives up on a line of 256 characters or more; taking the last 512 bytes keeps the inner call.
    const std::string before = NPPSciGetRange(editor, MAX(lineStart, caret - kMaxCallTipLookback), caret);
    const NPPCallTipTarget target = NPPFunctionAtCaret(before, api.startFunc, api.stopFunc, api.paramSeparator,
                                                       api.terminal, api.additionalWordChars.UTF8String ?: "");
    if (!target.found) { [self closeCallTip:editor]; return NO; }

    NSString *name = NPPStringFromUTF8(target.name);
    NSArray<NPPAPIOverload *> *overloads = name ? [api overloadsForFunctionNamed:name] : nil;
    if (!overloads.count) { [self closeCallTip:editor]; return NO; }

    const BOOL same = _tipFunction && (api.ignoreCase ? [_tipFunction caseInsensitiveCompare:name] == NSOrderedSame
                                                      : [_tipFunction isEqualToString:name]);
    if (!same) _tipOverload = 0;                                     // N++ reset() when a different function is hit
    _tipFunction = name;
    _tipOverloads = overloads;
    _tipParam = target.param;
    [self showCallTipInEditor:editor list:api];
    return YES;
}

- (void)showCallTipInEditor:(ScintillaView *)editor list:(NPPAPIWordList *)api {
    if (!_tipOverloads.count) return;
    // If the caret is past the end of the current overload's parameters, pick an overload that still has room.
    if (_tipParam >= _tipOverloads[_tipOverload].params.count + 1) {
        for (NSUInteger i = 0; i < _tipOverloads.count; ++i)
            if (_tipParam < _tipOverloads[i].params.count + 1) { _tipOverload = i; break; }
    }
    NPPAPIOverload *ov = _tipOverloads[_tipOverload];

    NSMutableString *text = [NSMutableString string];
    if (_tipOverloads.count > 1)                                     // \001 / \002 draw Scintilla's up/down arrows
        [text appendFormat:@"\001%lu of %lu\002", (unsigned long)(_tipOverload + 1), (unsigned long)_tipOverloads.count];
    [text appendFormat:@"%@ %@ %c", ov.retVal, _tipFunction, api.startFunc];

    NSInteger hlStart = 0, hlEnd = 0;
    for (NSUInteger i = 0; i < ov.params.count; ++i) {
        if (i == _tipParam) {
            hlStart = (NSInteger)[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            hlEnd = hlStart + (NSInteger)[ov.params[i] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        }
        [text appendString:ov.params[i]];
        if (i < ov.params.count - 1) [text appendFormat:@"%c ", api.paramSeparator];
    }
    [text appendFormat:@"%c", api.stopFunc];
    if (ov.descr.length) [text appendFormat:@"\n%@", ov.descr];

    NPPApplyAutoCompleteColours(editor);
    if ([self callTipIsVisible:editor]) NPPSci(editor, SCI_CALLTIPCANCEL);
    else _tipStartPos = NPPSci(editor, SCI_GETCURRENTPOS);
    NPPSciStr(editor, SCI_CALLTIPSHOW, (uptr_t)_tipStartPos, text.UTF8String);
    _tipSelfActivated = YES;
    _tipEditor = editor;
    if (hlStart != hlEnd) NPPSci(editor, SCI_CALLTIPSETHLT, (uptr_t)hlStart, hlEnd);
}

- (void)cycleCallTipInEditor:(ScintillaView *)editor forward:(BOOL)forward {
    NPPAPIWordList *api = [self apiListForEditor:editor];
    if (!api || _tipEditor != editor || ![self callTipIsVisible:editor] || _tipOverloads.count < 2) return;
    _tipOverload = forward ? (_tipOverload + 1) % _tipOverloads.count
                           : (_tipOverload > 0 ? _tipOverload - 1 : _tipOverloads.count - 1);
    [self showCallTipInEditor:editor list:api];
}

- (void)callTipClicked:(sptr_t)direction inEditor:(ScintillaView *)editor {
    if (direction == 1) [self cycleCallTipInEditor:editor forward:NO];        // up arrow
    else if (direction == 2) [self cycleCallTipInEditor:editor forward:YES];  // down arrow
}

#pragma mark - Close tag

- (void)insertCloseTagIfNeededInEditor:(ScintillaView *)editor document:(NPPDocument *)doc {
    BOOL isHTML = NO;
    if (!self.insertHTMLCloseTag || !NPPLanguageIsMarkup(doc.language.name, &isHTML)) return;
    const sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
    // N++ skips the whole thing inside an embedded scripting island (JS/VBS/PHP/Python inside HTML).
    if (isHTML && NPPSci(editor, SCI_GETSTYLEAT, (uptr_t)caret) >= SCE_HJ_START) return;

    // ponytail: a bounded look-back instead of N++'s whole-document regex search — a tag name longer than 512 bytes
    // is not a tag, and this runs on every ">" typed in a file that may be 100 MB.
    const sptr_t from = MAX((sptr_t)0, caret - (sptr_t)kCloseTagLookback);
    const std::string window = NPPSciGetRange(editor, from, caret);
    const std::string close = NPPCloseTagForText(window, window.size(), isHTML);
    if (close.empty()) return;
    NPPSciStr(editor, SCI_INSERTTEXT, (uptr_t)caret, close.c_str());
    NPPSci(editor, SCI_GOTOPOS, (uptr_t)caret);                      // caret stays between the two tags
}

#pragma mark - Typing hook (N++ AutoCompletion::update)

// N++ Buffer::allowAutoCompletion(): above the Performance page's large-file threshold the whole SCN_CHARADDED
// path — close tag, call tip and the list — is off unless "Allow Auto-Completion" says otherwise. The manual
// commands (Edit ▸ Completion) stay available on a large file, exactly as upstream: N++ asks this question only
// at the notification, never in NppCommands.cpp.
static BOOL NPPAutoCompletionAllowedInDocument(NPPDocument *doc) {
    if (!doc.isLargeFile) return YES;
    NPPPreferences *p = NPPPreferences.shared;
    return !p.largeFileRestrictionEnabled || p.largeFileAllowAutoCompletion;
}

// N++ NppNotification.cpp SCN_AUTOCSELECTION.
- (void)completionSelectedBy:(int)completionMethod inEditor:(ScintillaView *)editor {
    if (!editor) return;
    NPPPreferences *p = NPPPreferences.shared;
    const unsigned int msg = NPPAutoCompleteOverrideMessage(completionMethod,
                                                            self.enabled && self.mode != NPPAutoCompleteModeNone,
                                                            p.autoCompleteInsertWithTab, p.autoCompleteInsertWithEnter);
    if (!msg) return;
    NPPSci(editor, SCI_AUTOCCANCEL);      // Scintilla skips the insertion when the list is gone by the time we return
    NPPSci(editor, msg);
}

- (void)characterAdded:(int)ch inEditor:(ScintillaView *)editor {
    if (!ch || !editor || NPPSci(editor, SCI_GETREADONLY)) return;
    NPPDocument *doc = [self documentForEditor:editor];
    if (!doc) return;
    if (!NPPAutoCompletionAllowedInDocument(doc)) return;

    if (ch == '>') [self insertCloseTagIfNeededInEditor:editor document:doc];
    if (!self.enabled) return;

    const NPPAutoCompleteMode mode = self.mode;
    if (mode == NPPAutoCompleteModeNone) return;

    NPPAPIWordList *api = [self apiListForLanguageNamed:doc.language.name ?: @""];
    if (!api && mode == NPPAutoCompleteModeFunction) return;

    if (api && (self.functionParameterHints || [self callTipIsVisible:editor]))
        if ([self updateCallTipInEditor:editor character:ch needShown:NO]) return;   // a tip wins over a list

    const BOOL brief = self.briefMode;
    if (!brief && NPPSci(editor, SCI_AUTOCACTIVE)) return;           // already showing: let Scintilla filter it

    const std::string prefix = NPPPrefixAtCaret(editor, NULL);
    if ((NSInteger)prefix.size() < self.triggerLength) return;
    [self showCompletionInEditor:editor mode:mode brief:brief];
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    switch (cmd) {
        case NPPCmdEditCompleteFunction: case NPPCmdEditCompletePath:
        case NPPCmdEditFunctionCallTip: case NPPCmdEditFunctionCallTipPrevious: case NPPCmdEditFunctionCallTipNext:
            return YES;
        default:
            return NO;
    }
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (![self handlesCommand:cmd]) return NO;
    NPPDocument *doc = [context contextCurrentDocument];
    ScintillaView *ed = doc.editor;
    if (!ed) return NO;
    NPPAutoCompletion *me = [self shared];
    me->_context = context;
    switch (cmd) {
        case NPPCmdEditCompletePath:
            return !doc.isReadOnly && !NPPSci(ed, SCI_GETREADONLY);
        case NPPCmdEditCompleteFunction:
            // No API file for this language means there is nothing to complete from: disabled, not silent.
            return !doc.isReadOnly && !NPPSci(ed, SCI_GETREADONLY) && [me apiListForLanguageNamed:doc.language.name ?: @""] != nil;
        case NPPCmdEditFunctionCallTip:
            return [me apiListForLanguageNamed:doc.language.name ?: @""] != nil;
        case NPPCmdEditFunctionCallTipPrevious:
        case NPPCmdEditFunctionCallTipNext:
            return me->_tipEditor == ed && [me callTipIsVisible:ed] && me->_tipOverloads.count > 1;
        default:
            return NO;
    }
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (![self handlesCommand:cmd]) return NO;
    if (![self canPerformCommand:cmd context:context]) return NO;
    NPPAutoCompletion *me = [self shared];
    me->_context = context;
    ScintillaView *ed = [context contextCurrentDocument].editor;
    switch (cmd) {
        case NPPCmdEditCompleteFunction:
            [me showCompletionInEditor:ed mode:NPPAutoCompleteModeFunction brief:me.briefMode];
            break;
        case NPPCmdEditCompletePath:
            [me showPathCompletionInEditor:ed];
            break;
        case NPPCmdEditFunctionCallTip:
            if (![me updateCallTipInEditor:ed character:0 needShown:YES]) NSBeep();
            break;
        case NPPCmdEditFunctionCallTipPrevious:
            [me cycleCallTipInEditor:ed forward:NO];
            break;
        case NPPCmdEditFunctionCallTipNext:
            [me cycleCallTipInEditor:ed forward:YES];
            break;
        default:
            return NO;
    }
    return YES;
}

#pragma mark - Self checks (headless: no window, no editor)

static NSString *const kTestAPIXML =
    @"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"
    @"<NotepadPlus><AutoComplete language=\"Test\">\n"
    @"  <Environment ignoreCase=\"%@\" startFunc=\"(\" stopFunc=\")\" paramSeparator=\",\" terminal=\";\" additionalWordChar=\".\" />\n"
    @"  <KeyWord name=\"alpha\" />\n"
    @"  <KeyWord name=\"Alphabet\" />\n"
    @"  <KeyWord name=\"beta\" func=\"yes\">\n"
    @"    <Overload retVal=\"int\" descr=\"one param\"><Param name=\"int a\" /></Overload>\n"
    @"    <Overload descr=\"no retVal, malformed\"><Param name=\"int a\" /></Overload>\n"
    @"    <Overload retVal=\"int\"><Param name=\"int a\" /><Param name=\"int b\" /></Overload>\n"
    @"  </KeyWord>\n"
    @"  <KeyWord name=\"gamma\" func=\"yes\" />\n"
    @"  <KeyWord name=\"delta\"><Overload retVal=\"int\"><Param name=\"int a\" /></Overload></KeyWord>\n"
    @"</AutoComplete></NotepadPlus>";

+ (nullable NPPAPIWordList *)testListIgnoringCase:(BOOL)ignoreCase {
    NSString *xml = [NSString stringWithFormat:kTestAPIXML, ignoreCase ? @"yes" : @"no"];
    return [NPPAPIWordList listWithXMLData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) { if (!ok) [out addObject:msg]; };
    NSString *(^str)(const std::string &) = ^(const std::string &s) { return @(s.c_str()); };

    // ---- API XML parsing -------------------------------------------------------------------------------------
    NPPAPIWordList *cs = [self testListIgnoringCase:NO];
    if (!cs) {
        [out addObject:@"api.parse: case-sensitive test XML did not parse"];
    } else {
        expect(cs.keywords.count == 5, ([NSString stringWithFormat:@"api.keywords: %lu != 5", (unsigned long)cs.keywords.count]));
        expect(!cs.ignoreCase, @"api.env: ignoreCase=\"no\" not honoured");
        expect(cs.startFunc == '(' && cs.stopFunc == ')' && cs.paramSeparator == ',' && cs.terminal == ';',
               @"api.env: start/stop/separator/terminal not read");
        expect([cs.additionalWordChars isEqualToString:@"."], @"api.env: additionalWordChar not read");
        // Case-sensitive lists sort by byte, so "Alphabet" precedes "alpha".
        expect([cs.keywords.firstObject isEqualToString:@"Alphabet"],
               ([NSString stringWithFormat:@"api.sort: first is %@", cs.keywords.firstObject]));

        NSArray *sensitive = [cs keywordsMatchingPrefix:@"al"];
        expect(sensitive.count == 1 && [sensitive.firstObject isEqualToString:@"alpha"],
               ([NSString stringWithFormat:@"match.case-sensitive: %@", sensitive]));
        expect([cs keywordsMatchingPrefix:@"zz"].count == 0, @"match: unknown prefix matched something");
        expect([cs keywordsMatchingPrefix:@""].count == 5, @"match: empty prefix must yield the whole list");
        expect([cs keywordsMatchingPrefix:@"alphabetical"].count == 0, @"match: prefix longer than the keyword matched");

        NSArray<NPPAPIOverload *> *beta = [cs overloadsForFunctionNamed:@"beta"];
        // Three <Overload> nodes, the middle one without retVal: N++ skips a node like that, so two survive.
        expect(beta.count == 2, ([NSString stringWithFormat:@"api.overloads: beta has %lu, want 2 (retVal-less node kept?)",
                                  (unsigned long)beta.count]));
        expect(beta.count > 0 && beta[0].params.count == 1 && [beta[0].retVal isEqualToString:@"int"]
               && [beta[0].descr isEqualToString:@"one param"], @"api.overloads: beta overload 1 mis-parsed");
        expect(beta.count > 1 && beta[1].params.count == 2 && [beta[1].descr isEqualToString:@""],
               @"api.overloads: beta overload 2 mis-parsed");
        expect([cs overloadsForFunctionNamed:@"alpha"] == nil, @"api.overloads: a non-func keyword returned overloads");
        expect([cs overloadsForFunctionNamed:@"gamma"] == nil, @"api.overloads: func=\"yes\" with no <Overload> must be nil");
        // "delta" carries a usable <Overload> but no func="yes" — N++ refuses it, so the func attribute is what gates.
        expect([cs overloadsForFunctionNamed:@"delta"] == nil,
               @"api.overloads: <Overload> without func=\"yes\" must not produce a call tip");
        expect([cs overloadsForFunctionNamed:@"Beta"] == nil, @"api.overloads: case-sensitive list matched a wrong case");
    }

    NPPAPIWordList *ci = [self testListIgnoringCase:YES];
    if (!ci) {
        [out addObject:@"api.parse: case-insensitive test XML did not parse"];
    } else {
        expect(ci.ignoreCase, @"api.env: default ignoreCase lost");
        NSArray *both = [ci keywordsMatchingPrefix:@"al"];
        expect(both.count == 2, ([NSString stringWithFormat:@"match.case-insensitive: %@", both]));
        expect([ci overloadsForFunctionNamed:@"BETA"].count == 2, @"api.overloads: case-insensitive lookup failed");
    }

    // A real shipped file must parse too, when the APIs directory is reachable at all.
    NSURL *dir = [self apiDirectoryURL];
    if (dir) {
        NPPAPIWordList *cpp = [NPPAPIWordList listWithContentsOfURL:[dir URLByAppendingPathComponent:@"cpp.xml"]];
        expect(cpp.keywords.count > 100, @"api.bundled: cpp.xml did not parse into a keyword list");
        expect([cpp overloadsForFunctionNamed:@"printf"].count > 0, @"api.bundled: cpp.xml has no printf overload");

        // The completion list is one string split on kListSeparator, so no keyword may contain that character.
        // ' ' would fail here: 15 shipped keywords are multi-word ("Loop Until", "!DOCTYPE html", "using static").
        NSString *sep = [NSString stringWithFormat:@"%c", kListSeparator];
        NSUInteger split = 0, multiWord = 0;
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.path error:NULL]) {
            if (![f.pathExtension.lowercaseString isEqualToString:@"xml"]) continue;
            NPPAPIWordList *l = [NPPAPIWordList listWithContentsOfURL:[dir URLByAppendingPathComponent:f]];
            for (NSString *k in l.keywords) {
                if ([k containsString:sep]) ++split;
                if ([k containsString:@" "]) ++multiWord;
            }
            // The pre-joined string must round-trip back to the same list.
            if (l.keywords.count && [[l.joinedKeywords componentsSeparatedByString:sep] count] != l.keywords.count)
                [out addObject:[NSString stringWithFormat:@"api.joined: %@ does not round-trip", f]];
        }
        expect(split == 0, ([NSString stringWithFormat:@"list.separator: %lu shipped keywords contain the separator",
                             (unsigned long)split]));
        expect(multiWord > 0, @"list.separator: no multi-word keyword found, the ' ' regression is untestable");
    }

    // ---- getCloseTag -----------------------------------------------------------------------------------------
    struct { const char *text; bool isHTML; const char *want; } tags[] = {
        {"<div>",                      true,  "</div>"},
        {"<p>",                        false, "</p>"},
        {"<div class=\"a>b\">",        true,  "</div>"},   // ">" inside an attribute must not shorten the name
        {"<span id='x'>",              true,  "</span>"},
        {"<br/>",                      true,  ""},         // self-closing
        {"<img src=\"x\" />",          true,  ""},
        {"</div>",                     true,  ""},         // already a closing tag
        {"<!-- comment -->",           true,  ""},
        {"<!-- <b> -->",               false, ""},         // the "-->" guard, not the "<!--" one: last "<" is <b>
        {"<?xml version=\"1.0\"?>",    false, ""},         // processing instruction
        {"<!DOCTYPE html>",            true,  ""},         // void-ish: skipped for HTML
        {"<!DOCTYPE html>",            false, "</!DOCTYPE>"},   // ... but XML closes everything (N++ behaviour)
        {"<img src=\"a.png\">",        true,  ""},         // HTML void element
        {"<img src=\"a.png\">",        false, "</img>"},   // not void in XML
        {"<INPUT>",                    true,  ""},         // void elements are case-insensitive
        {"<brx>",                      true,  "</brx>"},   // must not be swallowed by the "br" void element
        {"<!--a>",                     false, ""},         // a ">" inside a comment, before the "-->"
        {"<>",                         false, ""},
        {"<a><>",                      false, ""},         // an empty tag after a real one: still nothing to close
        {"text without a tag>",        false, ""},
        {"<a href=\"x\"><b>",          true,  "</b>"},     // the *last* open tag wins
    };
    for (auto &t : tags) {
        const std::string text = t.text;
        const std::string got = NPPCloseTagForText(text, text.size(), t.isHTML);
        expect(got == t.want, ([NSString stringWithFormat:@"closeTag(%s,%@): \"%@\" want \"%s\"",
                                t.text, t.isHTML ? @"html" : @"xml", str(got), t.want]));
    }

    // ---- call tip: which function is the caret in, and on which parameter --------------------------------------
    struct { const char *line; const char *wantName; long wantParam; } calls[] = {
        {"printf(",                 "printf", 0},
        {"printf(\"%d\", ",         "printf", 1},
        {"foo(a, bar(",             "bar",    0},
        {"foo(a, bar(x), ",         "foo",    2},
        {"x = (a + b",              "",      -1},   // an expression, not a call
        {"f(); g(",                 "g",      0},   // a new call after a finished statement
        {"foo(a; ",                 "",      -1},   // the terminal invalidates a call left open
        {"outer(inner(a; ",         "",      -1},   // ... and the whole nesting stack with it
        {"outer(inner(1), 2, 3",    "outer",  2},   // a closed nested call pops back to the outer one
        {"done()",                  "",      -1},   // the call is closed again
        {"os.path.join(",           "os.path.join", 0},   // additionalWordChar "." makes this one identifier
        {"nothing",                 "",      -1},
    };
    for (auto &c : calls) {
        const NPPCallTipTarget got = NPPFunctionAtCaret(c.line, '(', ')', ',', ';', ".");
        const BOOL wantFound = c.wantParam >= 0;
        expect(got.found == (bool)wantFound && (!wantFound || (got.name == c.wantName && (long)got.param == c.wantParam)),
               ([NSString stringWithFormat:@"callTip(%s): %@/%lu want %s/%ld", c.line,
                 got.found ? str(got.name) : @"(none)", (unsigned long)got.param, c.wantName, c.wantParam]));
    }

    // ---- path completion: what the user is typing ---------------------------------------------------------------
    struct { const char *before; const char *want; } paths[] = {
        {"#include \"/usr/loc",     "/usr/loc"},
        {"open(\"~/Doc",            "~/Doc"},
        {"cat /tmp/a",              "/tmp/a"},
        {"\"/Users/me/My Doc",      "/Users/me/My Doc"},   // spaces survive inside an unclosed quote
        {"x = \"closed\" and /tmp/", "/tmp/"},              // the closed quote must not swallow the rest
        {"no path here",            ""},
        {"",                        ""},
        {"plain_identifier",        ""},
    };
    for (auto &p : paths) {
        const std::string got = NPPRawPathBeforeCaret(p.before);
        expect(got == p.want, ([NSString stringWithFormat:@"rawPath(%s): \"%@\" want \"%s\"", p.before, str(got), p.want]));
    }

    // The prefix a completion entry is rebuilt on. Never a trailing "/", or the entry comes out as "//name".
    struct { NSString *raw; NSString *want; } prefixes[] = {
        {@"/tmp/a",     @"/tmp"},
        {@"/tmp/",      @"/tmp"},
        {@"/a",         @""},          // filesystem root: "" + "/" + name, not "/" + "/" + name
        {@"/",          @""},
        {@"~/Doc",      @"~"},
        {@"~/",         @"~"},
        {@"rel/x",      @"rel"},
    };
    for (auto &p : prefixes) {
        NSString *got = NPPPathEntryPrefix(p.raw);
        expect([got isEqualToString:p.want],
               ([NSString stringWithFormat:@"pathPrefix(%@): \"%@\" want \"%@\"", p.raw, got, p.want]));
        expect(![[NSString stringWithFormat:@"%@/x", got] hasPrefix:@"//"],
               ([NSString stringWithFormat:@"pathPrefix(%@): entry starts with \"//\"", p.raw]));
    }

    // ---- document word scan ------------------------------------------------------------------------------------
    {
        // "alp" itself is in the document: a word equal to the prefix completes to nothing and must not be offered.
        const std::string doc = "alpha alp alphabet ALPHAX beta\nalpha_2 gamma";
        std::vector<std::string> got = NPPDocumentWords(doc, "alp", "alpha", false, "");
        expect(got.size() == 2, ([NSString stringWithFormat:@"words.case-sensitive: %lu != 2 (want alphabet, alpha_2)",
                                  (unsigned long)got.size()]));
        got = NPPDocumentWords(doc, "alp", "alpha", true, "");
        expect(got.size() == 3, ([NSString stringWithFormat:@"words.case-insensitive: %lu != 3", (unsigned long)got.size()]));
        expect(NPPDocumentWords(doc, "zzz", "", false, "").empty(), @"words: unknown prefix matched");

        // The cap is a memory bound, not a nicety: it is the only thing keeping a generated file from turning into
        // a completion list with a million entries.
        std::string many;
        for (size_t i = 0; i < kMaxDocumentWords * 2; ++i) many += "w" + std::to_string(i) + " ";
        const size_t capped = NPPDocumentWords(many, "w", "", false, "").size();
        expect(capped <= kMaxDocumentWords, ([NSString stringWithFormat:@"words.cap: %lu words survived a %lu cap",
                                              (unsigned long)capped, (unsigned long)kMaxDocumentWords]));
        expect(NPPIsAllDigits("123") && !NPPIsAllDigits("12a") && !NPPIsAllDigits(""), @"words: isAllDigits wrong");

        // The scan runs over a window, not the whole file: a word the window cut in half is not a word.
        // "…pha alphabet alpha_2 gam…" — "pha" and "gam" are fragments and must not be offered.
        const std::string win = "pha alphabet alpha_2 gam";
        std::vector<std::string> whole = NPPDocumentWords(win, "", "", false, "", false, false);
        expect(whole.size() == 4, ([NSString stringWithFormat:@"words.window: unclipped %lu != 4",
                                    (unsigned long)whole.size()]));
        std::vector<std::string> clipped = NPPDocumentWords(win, "", "", false, "", true, true);
        expect(clipped.size() == 2 && clipped[0] == "alpha_2" && clipped[1] == "alphabet",
               ([NSString stringWithFormat:@"words.window: clipped %lu != 2 (fragments kept)",
                 (unsigned long)clipped.size()]));
        expect(NPPDocumentWords(win, "ph", "", false, "", true, false).empty(),
               @"words.window: the half word at the start of the window was offered");
        expect(NPPDocumentWords(win, "ga", "", false, "", false, true).empty(),
               @"words.window: the half word at the end of the window was offered");
    }

    // ---- which languages get an auto-closed tag -------------------------------------------------------------------
    {
        BOOL isHTML = NO;
        expect(NPPLanguageIsMarkup(@"html", &isHTML) && isHTML, @"markup: html not recognised as HTML");
        expect(NPPLanguageIsMarkup(@"PHP", &isHTML) && isHTML, @"markup: php (any case) not recognised as HTML");
        expect(NPPLanguageIsMarkup(@"xml", &isHTML) && !isHTML, @"markup: xml must close void elements too");
        expect(!NPPLanguageIsMarkup(@"cpp", NULL) && !NPPLanguageIsMarkup(@"", NULL), @"markup: non-markup language accepted");
    }

    // ---- settings round-trip ------------------------------------------------------------------------------------
    {
        NPPAutoCompletion *me = [self shared];
        const NPPAutoCompleteMode savedMode = me.mode;
        const NSInteger savedLen = me.triggerLength;
        me.mode = NPPAutoCompleteModeWord;
        me.triggerLength = 3;
        expect(me.mode == NPPAutoCompleteModeWord && me.triggerLength == 3, @"settings: not persisted");
        me.triggerLength = 0;
        expect(me.triggerLength == 1, @"settings: triggerLength must clamp to >= 1");
        me.mode = savedMode;
        me.triggerLength = savedLen;
        for (NSString *key in @[kEnabled, kMode, kTriggerLength, kIgnoreNumbers, kBrief, kFuncParams, kHtmlXmlTag])
            expect([key hasPrefix:@"NPPAutoComplete."], ([NSString stringWithFormat:@"settings: %@ is not NPPAutoComplete-prefixed", key]));
    }

    // ---- TAB / ENTER accept the highlighted completion ----------------------------------------------------------
    // Both defaults are ON, so both keys insert; switching one off must take that ONE key away and leave the other
    // (and every other way of accepting an entry) alone. A version that confused the two, or that ignored the
    // "manually triggered" escape, fails here.
    {
        expect(NPPAutoCompleteOverrideMessage(SC_AC_TAB, YES, YES, YES) == 0 &&
               NPPAutoCompleteOverrideMessage(SC_AC_NEWLINE, YES, YES, YES) == 0,
               @"insertKey: the defaults must let both keys insert the completion");
        expect(NPPAutoCompleteOverrideMessage(SC_AC_TAB, YES, NO, YES) == SCI_TAB,
               @"insertKey: TAB off must indent instead of inserting");
        expect(NPPAutoCompleteOverrideMessage(SC_AC_NEWLINE, YES, NO, YES) == 0,
               @"insertKey: TAB off must not take ENTER away too");
        expect(NPPAutoCompleteOverrideMessage(SC_AC_NEWLINE, YES, YES, NO) == SCI_NEWLINE,
               @"insertKey: ENTER off must break the line instead of inserting");
        expect(NPPAutoCompleteOverrideMessage(SC_AC_TAB, YES, YES, NO) == 0,
               @"insertKey: ENTER off must not take TAB away too");
        for (int method : {SC_AC_FILLUP, SC_AC_DOUBLECLICK, SC_AC_COMMAND, SC_AC_SINGLE_CHOICE})
            expect(NPPAutoCompleteOverrideMessage(method, YES, NO, NO) == 0,
                   ([NSString stringWithFormat:@"insertKey: completion method %d must be untouched", method]));
        // N++: a list the user asked for is always accepted by both keys, whatever the two settings say.
        expect(NPPAutoCompleteOverrideMessage(SC_AC_TAB, NO, NO, NO) == 0 &&
               NPPAutoCompleteOverrideMessage(SC_AC_NEWLINE, NO, NO, NO) == 0,
               @"insertKey: with the automatic popup off both keys must still insert");
        NPPPreferences *p = NPPPreferences.shared;
        expect(p.autoCompleteInsertWithTab && p.autoCompleteInsertWithEnter,
               @"insertKey: NPPAutoCompleteInsertWithTab/Enter must default to ON, as N++ does");
    }

    // ---- auto-completion colours (N++ drawAutocompleteColoursFromTheme) -----------------------------------------
    // Components are shifted independently and clamped at both ends; a shift that overflowed into the next
    // component, or that clamped only one end, would make a dark theme's list unreadable rather than merely wrong.
    {
        expect(NPPShiftColour(0x646464, -20) == 0x505050, @"colour: -20 on a mid grey");
        expect(NPPShiftColour(0x000000, -20) == 0x000000, @"colour: -20 must clamp at 0, not wrap");
        expect(NPPShiftColour(0xFFFFFF, +20) == 0xFFFFFF, @"colour: +20 must clamp at 255, not wrap");
        expect(NPPShiftColour(0x0000FF, -20) == 0x0000EB, @"colour: a component must not borrow from its neighbour");
        expect(NPPShiftColour(0xFF0000, +20) == 0xFF1414, @"colour: a clamped component must not carry into the next");
        expect(NPPShiftColour(0x102030, +20) == 0x243444, @"colour: all three components shift");

        // The table itself. A dark theme: list = fgDarker on bgDarker, the highlighted row = the theme's own
        // fg/bg, the tip = bgDarker/fgDarker/fgLighter — N++'s mapping, and swapping the plain and highlighted
        // rows (the easy mistake) fails here.
        const NPPAutoCompleteColours dark = NPPAutoCompleteColoursForTheme(0xC0C0C0, 0x2A2A2A);
        expect(dark.list == 0xACACAC && dark.listBack == 0x161616 &&
               dark.selected == 0xC0C0C0 && dark.selectedBack == 0x2A2A2A,
               @"colour: a dark theme's list is not fgDarker on bgDarker with the theme's own colours selected");
        expect(dark.tipBack == 0x161616 && dark.tipFore == 0xACACAC && dark.tipHighlight == 0xD4D4D4,
               @"colour: the call tip is not bgDarker / fgDarker / fgLighter");
        expect(NPPAutoCompleteColoursForTheme(0xFFFFFF, 0x000000).listBack == 0x141414,
               @"colour: a pure black theme must lift the list background, or it is invisible against the page");
        // The white-background branch must WRITE the defaults back, not skip: the list is one live Scintilla view,
        // so a theme switched from dark to white would otherwise keep the dark theme's colours all session.
        const NPPAutoCompleteColours white = NPPAutoCompleteColoursForTheme(0x000000, 0xFFFFFF);
        expect(white.list == kNPPElementDefault && white.listBack == kNPPElementDefault &&
               white.selected == kNPPElementDefault && white.selectedBack == kNPPElementDefault,
               @"colour: a white theme must reset the list elements, not leave the previous theme's in place");
        expect(white.tipBack == 0xFFFFFF && white.tipFore == 0x808080 && white.tipHighlight == 0x800000,
               @"colour: a white theme must restore Scintilla's own call-tip colours");
    }

    return out;
}

@end
