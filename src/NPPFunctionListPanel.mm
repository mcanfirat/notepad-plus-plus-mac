// NPPFunctionListPanel.mm — Notepad++ Function List.
// Parser: port of FunctionParsersManager / FunctionParser / FunctionZoneParser / FunctionUnitParser /
// FunctionMixParser (PowerEditor/src/WinControls/FunctionList/functionParser.cpp).
// Panel:  port of FunctionListPanel (functionListPanel.cpp) as a docked AppKit outline view.
#import "NPPFunctionListPanel.h"
#import "NPPDocument.h"
#import "NPPLanguageManager.h"
#import "NPPUtils.h"

#include <string>

// ---------------------------------------------------------------------------------------------------
// Regex plumbing
// ---------------------------------------------------------------------------------------------------
// N++ searches with Scintilla/Boost (SCFIND_REGEXP | SCFIND_POSIX | SCFIND_REGEXP_DOTMATCHESNL), i.e. dot
// matches newlines and ^/$ match at line boundaries. ICU is close enough with these two options; the rest of
// the differences are handled here:
//   * "\K" (Boost "keep out") has no ICU equivalent, so every occurrence is rewritten to an empty named group
//     and the effective match start is taken from the last group that participated.
//   * "(?R)" / "(?1)" recursion (haskell.xml, pascal.xml, nim.xml) simply does not compile — those parsers are
//     skipped with a one-time log, exactly as the brief requires.
// ponytail: no timeout guard around a match — ICU/NSRegularExpression has none. A pathological document can
// make one parse run long; it runs on a background queue and is superseded by the next one, so the UI never
// blocks. Upgrade path: chunk the document by function-sized windows if it ever bites.

static NSString *NPPFLCleanName(NSString *s);
static void NPPFLAssignBytePositions(NSArray<NPPFunctionListEntry *> *entries, NSString *text, BOOL identity);

@interface NPPFLRegex : NSObject
@property (nonatomic, strong) NSRegularExpression *re;
@property (nonatomic, copy) NSArray<NSString *> *kNames;
@end

// --- Boost/PCRE -> ICU pattern rewriting ------------------------------------------------------------
// The rule files are written for Boost's Perl syntax. These four differences are mechanical, so they are
// translated rather than costing us the parser; anything left over (conditionals "(?(1)...)", recursion
// "(?R)") makes the compile fail and the parser is skipped.

// Index of the ')' closing the group whose '(' is at openIdx, or NSNotFound.
static NSUInteger NPPFLMatchingParen(NSString *s, NSUInteger openIdx) {
    NSUInteger n = s.length, depth = 0;
    BOOL inClass = NO;
    for (NSUInteger i = openIdx; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\') { i++; continue; }
        if (inClass) { if (c == ']') inClass = NO; continue; }
        if (c == '[') { inClass = YES; continue; }
        if (c == '(') depth++;
        else if (c == ')') { if (--depth == 0) return i; }
    }
    return NSNotFound;
}

// Index just past a well-formed "{n}", "{n,}" or "{n,m}" starting at braceIdx, else NSNotFound.
static NSUInteger NPPFLQuantifierBraceEnd(NSString *s, NSUInteger braceIdx) {
    NSUInteger n = s.length, i = braceIdx + 1;
    BOOL digits = NO;
    while (i < n && [s characterAtIndex:i] >= '0' && [s characterAtIndex:i] <= '9') { i++; digits = YES; }
    if (!digits) return NSNotFound;
    if (i < n && [s characterAtIndex:i] == ',') { i++; while (i < n && [s characterAtIndex:i] >= '0' && [s characterAtIndex:i] <= '9') i++; }
    return (i < n && [s characterAtIndex:i] == '}') ? i + 1 : NSNotFound;
}

// ICU only accepts [A-Za-z0-9] in a group name; Boost allows "_" (VALID_ID, PACKAGE_HEADER, ...).
static NSString *NPPFLSanitizeGroupName(NSString *name) {
    NSMutableString *out = [NSMutableString stringWithCapacity:name.length];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [out appendFormat:@"%C", c];
    }
    if (out.length == 0 || ([out characterAtIndex:0] >= '0' && [out characterAtIndex:0] <= '9')) [out insertString:@"g" atIndex:0];
    return out;
}

// Pass 1: "\K" -> named empty group, "(?'x'" -> "(?<x>", "\k'x'" -> "\k<x>", bare "{" -> "\{",
// and inside a character class "[" -> "\[" and "#" -> "\#" (ICU would read the latter as a free-spacing comment).
static NSString *NPPFLRewriteSyntax(NSString *pattern, NSMutableArray<NSString *> *kNames) {
    NSUInteger n = pattern.length;
    NSMutableString *out = [NSMutableString stringWithCapacity:n + 64];
    BOOL inClass = NO;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [pattern characterAtIndex:i];
        if (c == '\\' && i + 1 < n) {
            unichar d = [pattern characterAtIndex:i + 1];
            if (d == 'K' && !inClass) {
                NSString *name = [NSString stringWithFormat:@"nppK%lu", (unsigned long)kNames.count];
                [kNames addObject:name];
                [out appendFormat:@"(?<%@>)", name];
                i++;
                continue;
            }
            if (d == 'k' && !inClass && i + 2 < n && ([pattern characterAtIndex:i + 2] == '\'' || [pattern characterAtIndex:i + 2] == '<')) {
                NSString *terminator = ([pattern characterAtIndex:i + 2] == '\'') ? @"'" : @">";
                NSUInteger close = [pattern rangeOfString:terminator options:0 range:NSMakeRange(i + 3, n - i - 3)].location;
                if (close != NSNotFound) {
                    [out appendFormat:@"\\k<%@>", NPPFLSanitizeGroupName([pattern substringWithRange:NSMakeRange(i + 3, close - i - 3)])];
                    i = close;
                    continue;
                }
            }
            [out appendFormat:@"%C%C", c, d];
            i++;
            continue;
        }
        if (inClass) {
            if (c == ']') inClass = NO;
            else if (c == '[' || c == '#') { [out appendFormat:@"\\%C", c]; continue; }
            [out appendFormat:@"%C", c];
            continue;
        }
        if (c == '[') { inClass = YES; [out appendString:@"["]; continue; }
        if (c == '{') {
            NSUInteger qEnd = NPPFLQuantifierBraceEnd(pattern, i);
            if (qEnd == NSNotFound) { [out appendString:@"\\{"]; continue; }
            [out appendString:[pattern substringWithRange:NSMakeRange(i, qEnd - i)]];
            i = qEnd - 1;
            continue;
        }
        if (c == '}') { [out appendString:@"\\}"]; continue; }   // ICU rejects a bare '}'; Boost takes it literally
        if (c == '(' && i + 3 < n && [pattern characterAtIndex:i + 1] == '?') {
            unichar k = [pattern characterAtIndex:i + 2];
            unichar after = [pattern characterAtIndex:i + 3];
            if (k == '&') {                               // subroutine call: sanitise to match the definition
                NSUInteger close = [pattern rangeOfString:@")" options:0 range:NSMakeRange(i + 3, n - i - 3)].location;
                if (close != NSNotFound) {
                    [out appendFormat:@"(?&%@)", NPPFLSanitizeGroupName([pattern substringWithRange:NSMakeRange(i + 3, close - i - 3)])];
                    i = close;
                    continue;
                }
            }
            if (k == '\'' || (k == '<' && after != '=' && after != '!')) {
                NSString *terminator = (k == '\'') ? @"'" : @">";
                NSUInteger close = [pattern rangeOfString:terminator options:0 range:NSMakeRange(i + 3, n - i - 3)].location;
                if (close != NSNotFound) {
                    [out appendFormat:@"(?<%@>", NPPFLSanitizeGroupName([pattern substringWithRange:NSMakeRange(i + 3, close - i - 3)])];
                    i = close;
                    continue;
                }
            }
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

// Pass 2: Boost subroutine calls. "(?(DEFINE)(?<X>…))" only declares patterns, and "(?&X)" calls them; ICU has
// neither, so the definitions are harvested, the DEFINE block dropped and each call textually expanded.
static NSString *NPPFLExpandSubroutines(NSString *pattern) {
    if ([pattern rangeOfString:@"(?&"].location == NSNotFound) return pattern;

    NSMutableDictionary<NSString *, NSString *> *defs = [NSMutableDictionary dictionary];
    NSUInteger searchFrom = 0;
    while (searchFrom < pattern.length) {
        NSRange r = [pattern rangeOfString:@"(?<" options:0 range:NSMakeRange(searchFrom, pattern.length - searchFrom)];
        if (r.location == NSNotFound) break;
        searchFrom = NSMaxRange(r);
        NSRange gt = [pattern rangeOfString:@">" options:0 range:NSMakeRange(searchFrom, pattern.length - searchFrom)];
        NSUInteger close = NPPFLMatchingParen(pattern, r.location);
        if (gt.location == NSNotFound || close == NSNotFound || gt.location > close) continue;
        NSString *name = [pattern substringWithRange:NSMakeRange(searchFrom, gt.location - searchFrom)];
        static NSCharacterSet *notWord;
        if (!notWord) {
            NSMutableCharacterSet *w = [NSMutableCharacterSet alphanumericCharacterSet];
            [w addCharactersInString:@"_"];
            notWord = [w invertedSet];
        }
        if (name.length && [name rangeOfCharacterFromSet:notWord].location == NSNotFound)
            defs[name] = [pattern substringWithRange:NSMakeRange(NSMaxRange(gt), close - NSMaxRange(gt))];
    }

    NSMutableString *work = [pattern mutableCopy];
    for (;;) {
        NSRange d = [work rangeOfString:@"(?(DEFINE)"];
        if (d.location == NSNotFound) break;
        NSUInteger close = NPPFLMatchingParen(work, d.location);
        if (close == NSNotFound) break;
        [work replaceCharactersInRange:NSMakeRange(d.location, close - d.location + 1) withString:@"(?:)"];
    }

    // Expand in rounds so recursive definitions (c.xml, java.xml wrap balanced-bracket matchers in themselves)
    // are unrolled to a fixed depth instead of forever; whatever is still recursive at the last round can never
    // match, which is what a depth-limited unroll means. Each expanded copy gets its own group names so ICU does
    // not see duplicates, and "\k<name>" backreferences inside the copy are renamed with it.
    NSUInteger copyID = 0;
    for (int round = 0; round < 3 && work.length < 300000; round++) {
        NSMutableArray<NSValue *> *calls = [NSMutableArray array];
        NSUInteger from = 0;
        while (from < work.length) {
            NSRange call = [work rangeOfString:@"(?&" options:0 range:NSMakeRange(from, work.length - from)];
            if (call.location == NSNotFound) break;
            NSRange endParen = [work rangeOfString:@")" options:0 range:NSMakeRange(NSMaxRange(call), work.length - NSMaxRange(call))];
            if (endParen.location == NSNotFound) break;
            [calls addObject:[NSValue valueWithRange:NSMakeRange(call.location, NSMaxRange(endParen) - call.location)]];
            from = NSMaxRange(endParen);
        }
        if (calls.count == 0) break;
        for (NSInteger i = (NSInteger)calls.count - 1; i >= 0; i--) {
            NSRange r = calls[(NSUInteger)i].rangeValue;
            NSString *name = [work substringWithRange:NSMakeRange(r.location + 3, r.length - 4)];
            NSString *body = defs[name];
            if (!body) continue;                          // unknown subroutine: leave it, the compile will fail
            NSMutableString *copy = [body mutableCopy];
            NSString *suffix = [NSString stringWithFormat:@"r%lu", (unsigned long)(++copyID)];
            for (NSString *known in defs.allKeys) {
                [copy replaceOccurrencesOfString:[NSString stringWithFormat:@"(?<%@>", known]
                                      withString:[NSString stringWithFormat:@"(?<%@%@>", known, suffix]
                                         options:0 range:NSMakeRange(0, copy.length)];
                [copy replaceOccurrencesOfString:[NSString stringWithFormat:@"\\k<%@>", known]
                                      withString:[NSString stringWithFormat:@"\\k<%@%@>", known, suffix]
                                         options:0 range:NSMakeRange(0, copy.length)];
            }
            [work replaceCharactersInRange:r withString:[NSString stringWithFormat:@"(?:%@)", copy]];
        }
    }
    // Depth limit reached: a still-unexpanded call to a *known* definition can simply never match.
    for (NSString *known in defs.allKeys)
        [work replaceOccurrencesOfString:[NSString stringWithFormat:@"(?&%@)", known] withString:@"(?!)"
                                 options:0 range:NSMakeRange(0, work.length)];
    return work;
}

@implementation NPPFLRegex

+ (nullable instancetype)regexWithPattern:(NSString *)pattern error:(NSError **)error {
    if (pattern.length == 0) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *translated = NPPFLExpandSubroutines(NPPFLRewriteSyntax(pattern, names));
    NSRegularExpressionOptions opts = NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionAnchorsMatchLines;
    if ([pattern rangeOfString:@"(?x)"].location != NSNotFound) opts |= NSRegularExpressionAllowCommentsAndWhitespace;
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:translated options:opts error:&err];
    if (!re) { if (error) *error = err; return nil; }
    NPPFLRegex *r = [[NPPFLRegex alloc] init];
    r.re = re;
    r.kNames = names;
    return r;
}

// The range N++ would have reported for this match ("\K" moves the start forward).
- (NSRange)effectiveRange:(NSTextCheckingResult *)m {
    NSRange full = m.range;
    if (_kNames.count == 0) return full;
    NSUInteger best = NSNotFound;
    for (NSString *name in _kNames) {
        NSRange r = [m rangeWithName:name];
        if (r.location == NSNotFound) continue;      // that branch (or that (?x) comment) never ran
        NSUInteger e = r.location + r.length;
        if (best == NSNotFound || e > best) best = e;
    }
    if (best == NSNotFound || best < full.location || best > NSMaxRange(full)) return full;
    return NSMakeRange(best, NSMaxRange(full) - best);
}

// First match at/after `range.location`, restricted to `range`. Returns NSNotFound location when none.
- (nullable NSTextCheckingResult *)firstMatchIn:(NSString *)text range:(NSRange)range {
    if (range.length == 0 || NSMaxRange(range) > text.length) {
        if (range.location > text.length) return nil;
        range.length = MIN(range.length, text.length - range.location);
        if (range.length == 0) return nil;
    }
    return [_re firstMatchInString:text options:0 range:range];
}
@end

// ---------------------------------------------------------------------------------------------------
// NPPFunctionListEntry
// ---------------------------------------------------------------------------------------------------
@implementation NPPFunctionListEntry
- (instancetype)init { if ((self = [super init])) { _position = -1; _bytePosition = -1; _name = @""; } return self; }
@end

// ---------------------------------------------------------------------------------------------------
// NPPFunctionListParser
// ---------------------------------------------------------------------------------------------------
@implementation NPPFunctionListParser {
    NPPFLRegex *_commentRe;
    NPPFLRegex *_classRangeRe;              // <classRange mainExpr>
    NSString *_openSymbol, *_closeSymbol;
    NPPFLRegex *_bodySymbolRe, *_bodyOpenRe; // "(open|close)" and "open"
    NSArray<NPPFLRegex *> *_classNameRes;   // <classRange><className><nameExpr>
    NPPFLRegex *_zoneFuncRe;                // <classRange><function mainExpr>
    NSArray<NPPFLRegex *> *_zoneFuncNameRes;
    NPPFLRegex *_unitFuncRe;                // <parser><function mainExpr>
    NSArray<NPPFLRegex *> *_unitFuncNameRes;
    NSArray<NPPFLRegex *> *_unitClassNameRes;
}


// N++ reads these rule files with TinyXML, which (against the XML spec) keeps literal newlines and tabs inside
// attribute values. NSXMLDocument normalises them to spaces, which collapses every multi-line "(?x)" pattern
// into a single line — where the first "# comment" then swallows the whole expression. Re-encoding those
// characters as character references before parsing restores the N++ behaviour.
static NSXMLDocument *NPPFLLoadRuleXML(NSURL *url, NSError **error) {
    NSString *raw = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:error];
    if (!raw) return nil;
    NSUInteger n = raw.length;
    NSMutableString *out = [NSMutableString stringWithCapacity:n + 4096];
    NSUInteger runStart = 0;
    BOOL inTag = NO, inComment = NO;
    unichar quote = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [raw characterAtIndex:i];
        if (inComment) {
            if (c == '-' && i + 2 < n && [raw characterAtIndex:i + 1] == '-' && [raw characterAtIndex:i + 2] == '>') { inComment = NO; i += 2; }
            continue;
        }
        if (!inTag) {
            if (c == '<') {
                if (i + 3 < n && [raw characterAtIndex:i + 1] == '!' && [raw characterAtIndex:i + 2] == '-' && [raw characterAtIndex:i + 3] == '-') { inComment = YES; i += 3; }
                else inTag = YES;
            }
            continue;
        }
        if (quote) {
            if (c == quote) { quote = 0; continue; }
            NSString *rep = nil;
            NSUInteger skip = 0;
            if (c == '\r') { rep = @"&#10;"; skip = (i + 1 < n && [raw characterAtIndex:i + 1] == '\n') ? 1 : 0; }
            else if (c == '\n') rep = @"&#10;";
            else if (c == '\t') rep = @"&#9;";
            if (rep) {
                [out appendString:[raw substringWithRange:NSMakeRange(runStart, i - runStart)]];
                [out appendString:rep];
                i += skip;
                runStart = i + 1;
            }
            continue;
        }
        if (c == '"' || c == '\'') { quote = c; continue; }
        if (c == '>') inTag = NO;
    }
    [out appendString:[raw substringFromIndex:runStart]];
    return [[NSXMLDocument alloc] initWithXMLString:out options:NSXMLNodeOptionsNone error:error];
}

static NSString *NPPFLAttr(NSXMLElement *e, NSString *name) {
    NSString *v = [[e attributeForName:name] stringValue];
    return v ?: @"";
}

// Collects <container><nameExpr expr/> and <funcNameExpr expr/> children (N++ uses one or the other
// depending on the nesting level; accept both so every shipped rule file loads).
static BOOL NPPFLCollectExprs(NSXMLElement *container, NSMutableArray<NPPFLRegex *> *out, NSError **error) {
    if (!container) return YES;
    for (NSXMLElement *child in [container elementsForName:@"nameExpr"]) {
        NPPFLRegex *r = [NPPFLRegex regexWithPattern:NPPFLAttr(child, @"expr") error:error];
        if (!r) return NO;
        [out addObject:r];
    }
    for (NSXMLElement *child in [container elementsForName:@"funcNameExpr"]) {
        NPPFLRegex *r = [NPPFLRegex regexWithPattern:NPPFLAttr(child, @"expr") error:error];
        if (!r) return NO;
        [out addObject:r];
    }
    return YES;
}

static NSError *NPPFLError(NSString *msg) {
    return [NSError errorWithDomain:@"NPPFunctionList" code:1 userInfo:@{NSLocalizedDescriptionKey: msg ?: @"?"}];
}

+ (nullable instancetype)parserWithContentsOfURL:(NSURL *)url error:(NSError **)error {
    if (!url) { if (error) *error = NPPFLError(@"no rule file"); return nil; }
    NSError *xmlErr = nil;
    NSXMLDocument *xml = NPPFLLoadRuleXML(url, &xmlErr);
    if (!xml) { if (error) *error = xmlErr ?: NPPFLError(@"unreadable XML"); return nil; }

    NSXMLElement *root = xml.rootElement;                                       // <NotepadPlus>
    NSXMLElement *list = [[root elementsForName:@"functionList"] firstObject];
    NSXMLElement *parser = [[list elementsForName:@"parser"] firstObject];
    if (!parser) { if (error) *error = NPPFLError(@"no <parser> element"); return nil; }

    NPPFunctionListParser *p = [[NPPFunctionListParser alloc] init];
    p->_displayName = [NPPFLAttr(parser, @"displayName") copy];
    p->_parserID = [NPPFLAttr(parser, @"id") copy];

    NSError *reErr = nil;
    NSString *commentExpr = NPPFLAttr(parser, @"commentExpr");
    if (commentExpr.length) {
        p->_commentRe = [NPPFLRegex regexWithPattern:commentExpr error:&reErr];
        if (!p->_commentRe) { if (error) *error = reErr; return nil; }
    }

    NSXMLElement *classRange = [[parser elementsForName:@"classRange"] firstObject];
    if (classRange) {
        p->_classRangeRe = [NPPFLRegex regexWithPattern:NPPFLAttr(classRange, @"mainExpr") error:&reErr];
        if (!p->_classRangeRe) { if (error) *error = reErr; return nil; }
        p->_openSymbol = [NPPFLAttr(classRange, @"openSymbole") copy];
        p->_closeSymbol = [NPPFLAttr(classRange, @"closeSymbole") copy];
        if (p->_openSymbol.length && p->_closeSymbol.length) {
            p->_bodySymbolRe = [NPPFLRegex regexWithPattern:[NSString stringWithFormat:@"(%@|%@)", p->_openSymbol, p->_closeSymbol] error:&reErr];
            p->_bodyOpenRe = [NPPFLRegex regexWithPattern:p->_openSymbol error:&reErr];
            if (!p->_bodySymbolRe || !p->_bodyOpenRe) { if (error) *error = reErr; return nil; }
        }
        NSMutableArray *cn = [NSMutableArray array];
        if (!NPPFLCollectExprs([[classRange elementsForName:@"className"] firstObject], cn, &reErr)) { if (error) *error = reErr; return nil; }
        p->_classNameRes = cn;

        NSXMLElement *zoneFunc = [[classRange elementsForName:@"function"] firstObject];
        if (zoneFunc) {
            p->_zoneFuncRe = [NPPFLRegex regexWithPattern:NPPFLAttr(zoneFunc, @"mainExpr") error:&reErr];
            if (!p->_zoneFuncRe) { if (error) *error = reErr; return nil; }
            NSMutableArray *fn = [NSMutableArray array];
            if (!NPPFLCollectExprs([[zoneFunc elementsForName:@"functionName"] firstObject], fn, &reErr)) { if (error) *error = reErr; return nil; }
            p->_zoneFuncNameRes = fn;
        }
    }

    NSXMLElement *unitFunc = [[parser elementsForName:@"function"] firstObject];
    if (unitFunc) {
        p->_unitFuncRe = [NPPFLRegex regexWithPattern:NPPFLAttr(unitFunc, @"mainExpr") error:&reErr];
        if (!p->_unitFuncRe) { if (error) *error = reErr; return nil; }
        NSMutableArray *fn = [NSMutableArray array], *cn = [NSMutableArray array];
        if (!NPPFLCollectExprs([[unitFunc elementsForName:@"functionName"] firstObject], fn, &reErr)) { if (error) *error = reErr; return nil; }
        if (!NPPFLCollectExprs([[unitFunc elementsForName:@"className"] firstObject], cn, &reErr)) { if (error) *error = reErr; return nil; }
        p->_unitFuncNameRes = fn;
        p->_unitClassNameRes = cn;
    }

    if (!p->_classRangeRe && !p->_unitFuncRe) { if (error) *error = NPPFLError(@"parser has neither <classRange> nor <function>"); return nil; }
    return p;
}

#pragma mark - parsing

// N++ collects comment zones and searches the complement. Blanking each comment with spaces (newlines kept, so
// line anchors and every offset stay valid) is the same thing in one pass.
- (NSString *)blankComments:(NSString *)text {
    if (!_commentRe || text.length == 0) return text;
    NSUInteger n = text.length;
    unichar *buf = (unichar *)malloc(n * sizeof(unichar));
    if (!buf) return text;
    [text getCharacters:buf range:NSMakeRange(0, n)];
    [_commentRe.re enumerateMatchesInString:text options:0 range:NSMakeRange(0, n)
                                 usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSRange r = m.range;
        for (NSUInteger i = r.location; i < NSMaxRange(r) && i < n; i++)
            if (buf[i] != '\n' && buf[i] != '\r') buf[i] = ' ';
    }];
    NSString *out = [NSString stringWithCharacters:buf length:n];
    free(buf);
    return out;
}

// FunctionParser::parseSubLevel — run the expressions in sequence, each inside the previous match's range.
- (NSString *)parseSubLevel:(NSArray<NPPFLRegex *> *)exprs
                    inRange:(NSRange)range
                    blanked:(NSString *)blanked
                       orig:(NSString *)orig
                   foundPos:(NSInteger *)foundPos {
    *foundPos = -1;
    if (exprs.count == 0 || range.length == 0) return @"";
    NSRange cur = range;
    for (NSUInteger i = 0; i < exprs.count; i++) {
        NPPFLRegex *re = exprs[i];
        NSTextCheckingResult *m = [re firstMatchIn:blanked range:cur];
        if (!m) return @"";
        cur = [re effectiveRange:m];
        if (cur.length == 0 && i + 1 < exprs.count) return @"";
    }
    *foundPos = (NSInteger)cur.location;
    NSString *s = [orig substringWithRange:cur];
    if (s.length > 1024) s = [s substringToIndex:1024];   // N++ caps found data at 1024
    return s;
}

// FunctionParser::funcParse
- (void)funcParse:(NPPFLRegex *)funcRe
        nameExprs:(NSArray<NPPFLRegex *> *)nameExprs
   classNameExprs:(NSArray<NPPFLRegex *> *)classNameExprs
        className:(NSString *)classStructName
          inRange:(NSRange)range
          blanked:(NSString *)blanked
             orig:(NSString *)orig
             into:(NSMutableArray<NPPFunctionListEntry *> *)out
        cancelled:(BOOL (^)(void))cancelled {
    if (!funcRe || range.length == 0) return;
    NSUInteger end = NSMaxRange(range);
    NSUInteger pos = range.location;
    while (pos < end) {
        if (cancelled && cancelled()) return;
        NSTextCheckingResult *m = [funcRe firstMatchIn:blanked range:NSMakeRange(pos, end - pos)];
        if (!m) return;
        NSRange full = m.range;
        NSRange eff = [funcRe effectiveRange:m];
        if (NSMaxRange(eff) > end) return;
        if (NSMaxRange(eff) == end) return;              // N++ guard: a hit that fills the zone is dropped

        NSString *name = @"", *cls = nil;
        NSInteger p1 = -1, p2 = -1;
        if (nameExprs.count == 0 && classNameExprs.count == 0) {
            name = [orig substringWithRange:eff];
            p1 = (NSInteger)eff.location;
        } else {
            if (nameExprs.count) name = [self parseSubLevel:nameExprs inRange:eff blanked:blanked orig:orig foundPos:&p1];
            if (classStructName.length) {
                cls = classStructName;
                p2 = -1;                                  // N++ marks data2 as validated with -1
            } else if (classNameExprs.count) {
                cls = [self parseSubLevel:classNameExprs inRange:eff blanked:blanked orig:orig foundPos:&p2];
                if (p2 < 0) cls = nil;
            }
        }
        if (p1 != -1 || cls.length) {
            NPPFunctionListEntry *e = [[NPPFunctionListEntry alloc] init];
            e.name = NPPFLCleanName(name.length ? name : [orig substringWithRange:eff]);
            e.className = cls.length ? NPPFLCleanName(cls) : nil;
            e.position = (p1 >= 0) ? p1 : (NSInteger)eff.location;
            [out addObject:e];
        }
        NSUInteger next = MAX(NSMaxRange(full), NSMaxRange(eff));
        pos = (next > pos) ? next : pos + 1;
    }
}

// FunctionZoneParser::getBodyClosePos
- (NSUInteger)bodyClosePosFrom:(NSUInteger)begin blanked:(NSString *)blanked {
    NSUInteger docLen = blanked.length;
    if (!_bodySymbolRe || begin >= docLen) return docLen;
    NSInteger open = 1;
    NSUInteger pos = begin, lastEnd = begin;
    while (open > 0 && pos < docLen) {
        NSTextCheckingResult *m = [_bodySymbolRe firstMatchIn:blanked range:NSMakeRange(pos, docLen - pos)];
        if (!m) return docLen;
        NSRange r = m.range;
        lastEnd = NSMaxRange(r);
        NSTextCheckingResult *isOpen = [_bodyOpenRe firstMatchIn:blanked range:r];
        open += isOpen ? 1 : -1;
        pos = (lastEnd > pos) ? lastEnd : pos + 1;
    }
    return lastEnd;
}

// FunctionZoneParser::classParse
- (void)classParseInRange:(NSRange)range
                  blanked:(NSString *)blanked
                     orig:(NSString *)orig
                     into:(NSMutableArray<NPPFunctionListEntry *> *)out
                    zones:(NSMutableArray<NSValue *> *)zones
                cancelled:(BOOL (^)(void))cancelled {
    if (!_classRangeRe || range.length == 0) return;
    NSUInteger end = NSMaxRange(range);
    NSUInteger pos = range.location;
    while (pos < end) {
        if (cancelled && cancelled()) return;
        NSTextCheckingResult *m = [_classRangeRe firstMatchIn:blanked range:NSMakeRange(pos, end - pos)];
        if (!m) return;
        NSRange eff = [_classRangeRe effectiveRange:m];
        NSUInteger targetStart = eff.location, targetEnd = NSMaxRange(eff);

        NSInteger dummy = -1;
        NSString *className = [self parseSubLevel:_classNameRes inRange:eff blanked:blanked orig:orig foundPos:&dummy];

        if (_bodySymbolRe) targetEnd = [self bodyClosePosFrom:targetEnd blanked:blanked];
        if (targetEnd > end) return;
        if (targetEnd <= targetStart) { pos = MAX(NSMaxRange(m.range), pos + 1); continue; }

        [zones addObject:[NSValue valueWithRange:NSMakeRange(targetStart, targetEnd - targetStart)]];
        if (targetEnd == end) return;                    // N++ guard (also what stops the nested Mix pass looping)

        [self funcParse:_zoneFuncRe nameExprs:_zoneFuncNameRes classNameExprs:@[]
              className:className inRange:NSMakeRange(targetStart, targetEnd - targetStart)
                blanked:blanked orig:orig into:out cancelled:cancelled];
        pos = targetEnd;
    }
}

static NSArray<NSValue *> *NPPFLInvertZones(NSArray<NSValue *> *zones, NSRange whole) {
    NSMutableArray<NSValue *> *out = [NSMutableArray array];
    NSArray<NSValue *> *sorted = [zones sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        NSUInteger x = a.rangeValue.location, y = b.rangeValue.location;
        return (x < y) ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
    }];
    NSUInteger cursor = whole.location, end = NSMaxRange(whole);
    for (NSValue *v in sorted) {
        NSRange z = v.rangeValue;
        if (z.location > cursor) [out addObject:[NSValue valueWithRange:NSMakeRange(cursor, z.location - cursor)]];
        cursor = MAX(cursor, NSMaxRange(z));
    }
    if (cursor < end) [out addObject:[NSValue valueWithRange:NSMakeRange(cursor, end - cursor)]];
    return out;
}

- (NSArray<NPPFunctionListEntry *> *)parseText:(NSString *)text cancelled:(BOOL (^)(void))cancelled {
    NSMutableArray<NPPFunctionListEntry *> *out = [NSMutableArray array];
    if (text.length == 0) return out;
    NSString *blanked = [self blankComments:text];
    NSRange whole = NSMakeRange(0, text.length);

    if (_classRangeRe) {
        NSMutableArray<NSValue *> *scanned = [NSMutableArray array];
        [self classParseInRange:whole blanked:blanked orig:text into:out zones:scanned cancelled:cancelled];
        if (_unitFuncRe) {                                // FunctionMixParser
            NSArray<NSValue *> *firstLevel = [scanned copy];
            for (NSValue *v in firstLevel) {
                if (cancelled && cancelled()) return out;
                NSMutableArray<NSValue *> *tmp = [NSMutableArray array];
                [self classParseInRange:v.rangeValue blanked:blanked orig:text into:out zones:tmp cancelled:cancelled];
            }
            for (NSValue *v in NPPFLInvertZones(scanned, whole)) {
                if (cancelled && cancelled()) return out;
                [self funcParse:_unitFuncRe nameExprs:_unitFuncNameRes classNameExprs:_unitClassNameRes
                      className:@"" inRange:v.rangeValue blanked:blanked orig:text into:out cancelled:cancelled];
            }
        }
    } else {                                              // FunctionUnitParser
        [self funcParse:_unitFuncRe nameExprs:_unitFuncNameRes classNameExprs:_unitClassNameRes
              className:@"" inRange:whole blanked:blanked orig:text into:out cancelled:cancelled];
    }
    return out;
}
@end

// Function names are matched across several lines in some rules; the tree wants one line.
static NSString *NPPFLCleanName(NSString *s) {
    if (!s.length) return @"";
    NSArray *parts = [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [kept addObject:p];
    NSString *joined = [kept componentsJoinedByString:@" "];
    return joined.length > 256 ? [joined substringToIndex:256] : joined;
}

// ---------------------------------------------------------------------------------------------------
// Tree nodes
// ---------------------------------------------------------------------------------------------------
@interface NPPFLNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger position;                       // byte offset, -1 for the file root
@property (nonatomic) BOOL isContainer;                         // file root or class node
@property (nonatomic, strong, nullable) NSMutableArray<NPPFLNode *> *children;
@end
@implementation NPPFLNode
- (instancetype)init { if ((self = [super init])) { _name = @""; _position = -1; } return self; }
@end

// ---------------------------------------------------------------------------------------------------
// NPPFunctionListPanel
// ---------------------------------------------------------------------------------------------------
static NSString *const kSortKey = @"NPPFunctionListSortAlphabetically";

@interface NPPFunctionListPanel () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate>
@end

@implementation NPPFunctionListPanel {
    NSView *_view;
    NSSearchField *_search;
    NSOutlineView *_outline;
    NSScrollView *_scroll;
    NSTextField *_status;

    NPPFLNode *_root;                          // full tree (unfiltered, document order)
    NPPFLNode *_displayRoot;                   // what the outline shows
    NSArray<NPPFLNode *> *_leavesByPosition;   // flattened, ascending position, for caret tracking

    NSMutableDictionary<NSString *, NPPFunctionListParser *> *_parserCache;
    NSMutableSet<NSString *> *_badParserFiles;
    NSDictionary<NSString *, NSString *> *_udlOverrides;   // lowercase UDL name -> rule file name
    BOOL _overridesLoaded;

    dispatch_queue_t _parseQueue;
    uint64_t _generation;

    __weak NPPDocument *_doc;
    NSTimer *_timer;
    sptr_t _lastUndo, _lastLength, _lastCaret;
    CFAbsoluteTime _pendingReloadAt;
    BOOL _visible;
    BOOL _selectingProgrammatically;
    NSColor *_textColor;
}

+ (instancetype)shared {
    static NPPFunctionListPanel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPFunctionListPanel alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _parserCache = [NSMutableDictionary dictionary];
        _badParserFiles = [NSMutableSet set];
        _parseQueue = dispatch_queue_create("npp.functionlist.parse", DISPATCH_QUEUE_SERIAL);
        _lastUndo = _lastLength = _lastCaret = -1;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:)
                                                     name:NPPThemeDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [_timer invalidate]; }

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd { return cmd == NPPCmdViewFunctionList; }
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context { return cmd == NPPCmdViewFunctionList; }

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdViewFunctionList) return NO;
    NPPFunctionListPanel *panel = [self shared];
    panel.context = context;
    [context contextTogglePanel:panel];
    return YES;
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return cmd == NPPCmdViewFunctionList && [context contextPanelIsVisible:[self shared]];
}

#pragma mark - NPPPanel

- (NSString *)panelTitle { return @"Function List"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeLeft; }
- (CGFloat)panelPreferredSize { return 260; }

- (NSView *)panelView {
    if (_view) return _view;

    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 400)];

    _search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _search.placeholderString = @"Filter";
    _search.controlSize = NSControlSizeSmall;
    _search.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    _search.delegate = self;
    _search.target = self;
    _search.action = @selector(searchChanged:);
    ((NSSearchFieldCell *)_search.cell).sendsWholeSearchString = NO;
    [_view addSubview:_search];

    _outline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    _outline.headerView = nil;
    _outline.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    _outline.indentationPerLevel = 12;
    _outline.autoresizesOutlineColumn = NO;
    _outline.floatsGroupRows = NO;
    _outline.allowsEmptySelection = YES;
    _outline.dataSource = self;
    _outline.delegate = self;
    _outline.target = self;
    _outline.doubleAction = @selector(rowDoubleClicked:);
    if (@available(macOS 11.0, *)) _outline.style = NSTableViewStyleFullWidth;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outline addTableColumn:col];
    _outline.outlineTableColumn = col;

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.drawsBackground = YES;
    _scroll.documentView = _outline;
    [_view addSubview:_scroll];

    _status = [NSTextField labelWithString:@""];
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    _status.alignment = NSTextAlignmentCenter;
    _status.textColor = [NSColor secondaryLabelColor];
    _status.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    _status.lineBreakMode = NSLineBreakByWordWrapping;
    _status.maximumNumberOfLines = 3;
    [_view addSubview:_status];

    [NSLayoutConstraint activateConstraints:@[
        [_search.topAnchor constraintEqualToAnchor:_view.topAnchor constant:4],
        [_search.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:4],
        [_search.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:4],
        [_scroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:4],
        [_scroll.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],
        [_status.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
        [_status.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor],
        [_status.leadingAnchor constraintGreaterThanOrEqualToAnchor:_view.leadingAnchor constant:8],
        [_status.trailingAnchor constraintLessThanOrEqualToAnchor:_view.trailingAnchor constant:-8],
    ]];

    [self applyTheme];
    return _view;
}

- (void)panelDidBecomeVisible {
    _visible = YES;
    [self startTimer];
    [self reload];
}

- (void)panelWillHide {
    _visible = NO;
    [_timer invalidate];
    _timer = nil;
    _generation++;                      // cancel any in-flight parse
}

- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc {
    _doc = doc;
    _lastUndo = _lastLength = _lastCaret = -1;
    _pendingReloadAt = 0;
    if (_visible) [self reload];
}

- (NSMenu *)panelActionMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Function List"];
    NSMenuItem *sort = [m addItemWithTitle:@"Sort (A to Z)" action:@selector(toggleSort:) keyEquivalent:@""];
    sort.target = self;
    sort.state = [self sortAlphabetically] ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:[NSMenuItem separatorItem]];
    [[m addItemWithTitle:@"Expand All" action:@selector(expandAll:) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Collapse All" action:@selector(collapseAll:) keyEquivalent:@""] setTarget:self];
    [m addItem:[NSMenuItem separatorItem]];
    [[m addItemWithTitle:@"Reload" action:@selector(reloadAction:) keyEquivalent:@""] setTarget:self];
    return m;
}

#pragma mark - actions

- (BOOL)sortAlphabetically { return [[NSUserDefaults standardUserDefaults] boolForKey:kSortKey]; }
- (void)toggleSort:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:![self sortAlphabetically] forKey:kSortKey];
    [self rebuildDisplayTree];
}
- (void)expandAll:(id)sender { [_outline expandItem:nil expandChildren:YES]; }
- (void)collapseAll:(id)sender { [_outline collapseItem:nil collapseChildren:YES]; if (_displayRoot) [_outline expandItem:_displayRoot]; }
- (void)reloadAction:(id)sender { [self reload]; }
- (void)searchChanged:(id)sender { [self rebuildDisplayTree]; }
- (void)controlTextDidChange:(NSNotification *)note { [self searchChanged:nil]; }
- (void)rowDoubleClicked:(id)sender { [self jumpToSelection]; }

#pragma mark - rule files

+ (nullable NSURL *)functionListDirectoryURL {
    NSURL *bundled = [[NSBundle mainBundle] URLForResource:@"functionList" withExtension:nil];
    if (bundled && [[NSFileManager defaultManager] fileExistsAtPath:bundled.path]) return bundled;
    // ponytail: dev fallback so `make run` from build/ still finds the rules; the bundled copy wins in dist/.
    NSString *src = NPPUpstreamPath(@"PowerEditor/installer/functionList");
    return src ? [NSURL fileURLWithPath:src] : nil;
}

- (void)loadOverridesIfNeeded {
    if (_overridesLoaded) return;
    _overridesLoaded = YES;
    NSURL *dir = [[self class] functionListDirectoryURL];
    NSURL *url = [dir URLByAppendingPathComponent:@"overrideMap.xml"];
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return;
    NSXMLDocument *xml = NPPFLLoadRuleXML(url, NULL);
    NSXMLElement *list = [[xml.rootElement elementsForName:@"functionList"] firstObject];
    NSXMLElement *map = [[list elementsForName:@"associationMap"] firstObject];
    NSMutableDictionary *udl = [NSMutableDictionary dictionary];
    for (NSXMLElement *a in [map elementsForName:@"association"]) {
        NSString *ident = NPPFLAttr(a, @"id"), *udlName = NPPFLAttr(a, @"userDefinedLangName");
        if (ident.length && udlName.length) udl[udlName.lowercaseString] = ident;
        // ponytail: langID="" associations are all commented out in the shipped overrideMap, and mapping the
        // Win32 LangType enum onto NPPLanguage would be dead code. Add the table if a user ever needs it.
    }
    _udlOverrides = udl;
}

- (nullable NPPFunctionListParser *)parserForDocument:(NPPDocument *)doc {
    NPPLanguage *lang = doc.language;
    if (!lang) return nil;
    [self loadOverridesIfNeeded];
    NSURL *dir = [[self class] functionListDirectoryURL];
    if (!dir) return nil;

    NSString *name = lang.name.lowercaseString ?: @"";
    // Same aliases N++ ships (its rule files are named after the langs.model.xml language names).
    static NSDictionary *aliases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ aliases = @{@"javascript": @"javascript.js.xml", @"jsp": @"javascript.js.xml",
                                        @"html": @"xml.xml", @"objc": @"cpp.xml"}; });

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *udlName = doc.userDefinedLanguageName.lowercaseString;
    NSString *fromUDL = (udlName.length ? _udlOverrides[udlName] : nil) ?: _udlOverrides[name];
    if (fromUDL.length) [candidates addObject:fromUDL];
    if (name.length) [candidates addObject:[name stringByAppendingPathExtension:@"xml"]];
    if (aliases[name]) [candidates addObject:aliases[name]];

    for (NSString *file in candidates) {
        if ([_badParserFiles containsObject:file]) continue;
        NPPFunctionListParser *cached = _parserCache[file];
        if (cached) return cached;
        NSURL *url = [dir URLByAppendingPathComponent:file];
        if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) continue;
        NSError *err = nil;
        NPPFunctionListParser *p = [NPPFunctionListParser parserWithContentsOfURL:url error:&err];
        if (!p) {
            [_badParserFiles addObject:file];   // log once, never crash
            NSLog(@"[FunctionList] %@ skipped: %@", file, err.localizedDescription);
            continue;
        }
        _parserCache[file] = p;
        return p;
    }
    return nil;
}

+ (NSArray<NSString *> *)diagnoseAllParsers {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSURL *dir = [self functionListDirectoryURL];
    if (!dir) return @[@"functionList directory not found"];
    NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir.path error:NULL]
                      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *f in files) {
        if (![f.pathExtension isEqualToString:@"xml"] || [f isEqualToString:@"overrideMap.xml"]) continue;
        NSError *err = nil;
        NPPFunctionListParser *p = [NPPFunctionListParser parserWithContentsOfURL:[dir URLByAppendingPathComponent:f] error:&err];
        [out addObject:p ? [NSString stringWithFormat:@"%@: ok (%@)", f, p.displayName]
                         : [NSString stringWithFormat:@"%@: SKIPPED %@", f, err.localizedDescription]];
    }
    return out;
}

#pragma mark - parse driving

- (void)reload {
    if (!_view) (void)[self panelView];
    NPPDocument *doc = [_context contextCurrentDocument];
    _doc = doc;
    _pendingReloadAt = 0;
    _generation++;

    if (!doc) { [self showEmptyWithStatus:@"No open document"]; return; }
    ScintillaView *ed = doc.editor;
    if (!ed) { [self showEmptyWithStatus:@"No open document"]; return; }
    _lastUndo = NPPSci(ed, SCI_GETUNDOCURRENT);
    _lastLength = NPPSci(ed, SCI_GETLENGTH);
    _lastCaret = NPPSci(ed, SCI_GETCURRENTPOS);

    NPPFunctionListParser *parser = [self parserForDocument:doc];
    if (!parser) {
        NSString *lang = doc.userDefinedLanguageName ?: doc.language.shortName ?: doc.language.name ?: @"this language";
        [self showEmptyWithStatus:[NSString stringWithFormat:@"Unsupported language (%@)", lang]];
        return;
    }

    // ponytail: 8 MB ceiling. The heavy C++/PHP rules are backtracking-happy and ICU offers no match timeout;
    // above this the parse would run for minutes on a background thread for no benefit.
    if (_lastLength > 8 * 1024 * 1024) { [self showEmptyWithStatus:@"File too large to parse"]; return; }

    std::string utf8 = NPPSciGetText(ed);
    NSString *text = [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding];
    BOOL identityBytes = NO;
    if (!text) {                                  // not valid UTF-8: 1 byte == 1 character in Latin-1
        text = [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSISOLatin1StringEncoding] ?: @"";
        identityBytes = YES;
    }
    NSString *title = doc.displayName ?: @"";

    if (text.length == 0) { [self showEmptyWithStatus:@"No function found"]; return; }
    [self showStatus:@"Parsing…"];

    uint64_t gen = _generation;
    __weak NPPFunctionListPanel *weakSelf = self;
    dispatch_async(_parseQueue, ^{
        NPPFunctionListPanel *strong = weakSelf;
        if (!strong) return;
        BOOL (^cancelled)(void) = ^BOOL{
            NPPFunctionListPanel *s = weakSelf;
            return !s || s->_generation != gen;
        };
        NSArray<NPPFunctionListEntry *> *entries = [parser parseText:text cancelled:cancelled];
        if (cancelled()) return;
        NPPFLAssignBytePositions(entries, text, identityBytes);
        dispatch_async(dispatch_get_main_queue(), ^{
            NPPFunctionListPanel *s = weakSelf;
            if (!s || s->_generation != gen) return;
            [s applyEntries:entries fileName:title];
        });
    });
}

// UTF-16 index -> Scintilla byte position. Source files are overwhelmingly ASCII, in which case the mapping is
// the identity; otherwise one 4-byte table for the document.
static void NPPFLAssignBytePositions(NSArray<NPPFunctionListEntry *> *entries, NSString *text, BOOL identity) {
    if (identity || [text canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        for (NPPFunctionListEntry *e in entries) e.bytePosition = e.position;
        return;
    }
    NSUInteger n = text.length;
    unichar *buf = (unichar *)malloc(n * sizeof(unichar));
    uint32_t *map = (uint32_t *)malloc((n + 1) * sizeof(uint32_t));
    if (!buf || !map) {
        free(buf); free(map);
        for (NPPFunctionListEntry *e in entries) e.bytePosition = e.position;
        return;
    }
    [text getCharacters:buf range:NSMakeRange(0, n)];
    uint32_t acc = 0;
    for (NSUInteger i = 0; i < n; i++) {
        map[i] = acc;
        unichar c = buf[i];
        if (c < 0x80) acc += 1;
        else if (c < 0x800) acc += 2;
        else if (c >= 0xD800 && c < 0xDC00) acc += 4;      // high surrogate carries the whole pair
        else if (c >= 0xDC00 && c < 0xE000) acc += 0;      // low surrogate already counted
        else acc += 3;
    }
    map[n] = acc;
    for (NPPFunctionListEntry *e in entries) {
        NSUInteger p = (e.position >= 0 && (NSUInteger)e.position <= n) ? (NSUInteger)e.position : 0;
        e.bytePosition = (NSInteger)map[p];
    }
    free(buf); free(map);
}

#pragma mark - tree

- (void)applyEntries:(NSArray<NPPFunctionListEntry *> *)entries fileName:(NSString *)fileName {
    NPPFLNode *root = [[NPPFLNode alloc] init];
    root.name = fileName.length ? fileName : @"(untitled)";
    root.isContainer = YES;
    root.children = [NSMutableArray array];

    NSMutableDictionary<NSString *, NPPFLNode *> *classes = [NSMutableDictionary dictionary];
    for (NPPFunctionListEntry *e in entries) {
        NPPFLNode *leaf = [[NPPFLNode alloc] init];
        leaf.name = e.name.length ? e.name : @"?";
        leaf.position = e.bytePosition;
        if (e.className.length) {
            NPPFLNode *node = classes[e.className];
            if (!node) {
                node = [[NPPFLNode alloc] init];
                node.name = e.className;
                node.isContainer = YES;
                node.children = [NSMutableArray array];
                node.position = leaf.position;
                classes[e.className] = node;
                [root.children addObject:node];
            }
            if (leaf.position >= 0 && (node.position < 0 || leaf.position < node.position)) node.position = leaf.position;
            [node.children addObject:leaf];
        } else {
            [root.children addObject:leaf];
        }
    }
    _root = root;
    [self rebuildDisplayTree];
}

- (void)showEmptyWithStatus:(NSString *)status {
    _root = nil;
    [self rebuildDisplayTree];
    [self showStatus:status];
}

- (void)showStatus:(NSString *)status {
    if (!_status) return;
    _status.stringValue = status ?: @"";
    _status.hidden = (status.length == 0);
}

- (NPPFLNode *)filteredCopyOf:(NPPFLNode *)node matching:(NSString *)needle {
    if (!node.isContainer) {
        if (needle.length && [node.name rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound) return nil;
        return node;
    }
    NSMutableArray<NPPFLNode *> *kids = [NSMutableArray array];
    for (NPPFLNode *c in node.children) {
        NPPFLNode *f = [self filteredCopyOf:c matching:needle];
        if (f) [kids addObject:f];
    }
    if (needle.length && kids.count == 0 && node != _root) return nil;
    NPPFLNode *copy = [[NPPFLNode alloc] init];
    copy.name = node.name;
    copy.position = node.position;
    copy.isContainer = YES;
    copy.children = kids;
    return copy;
}

- (void)sortNode:(NPPFLNode *)node alphabetically:(BOOL)alpha {
    if (!node.children) return;
    [node.children sortUsingComparator:^NSComparisonResult(NPPFLNode *a, NPPFLNode *b) {
        if (alpha) {
            // Classes first, then functions — N++'s categorySortFunc keeps the two groups apart.
            if (a.isContainer != b.isContainer) return a.isContainer ? NSOrderedAscending : NSOrderedDescending;
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }
        if (a.position == b.position) return NSOrderedSame;
        return (a.position < b.position) ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (NPPFLNode *c in node.children) [self sortNode:c alphabetically:alpha];
}

- (void)collectLeaves:(NPPFLNode *)node into:(NSMutableArray<NPPFLNode *> *)out {
    if (!node) return;
    if (!node.isContainer) { if (node.position >= 0) [out addObject:node]; return; }
    for (NPPFLNode *c in node.children) [self collectLeaves:c into:out];
}

- (void)rebuildDisplayTree {
    if (!_outline) return;
    NSString *needle = _search.stringValue ?: @"";
    _displayRoot = _root ? [self filteredCopyOf:_root matching:needle] : nil;
    [self sortNode:_displayRoot alphabetically:[self sortAlphabetically]];

    NSMutableArray<NPPFLNode *> *leaves = [NSMutableArray array];
    [self collectLeaves:_displayRoot into:leaves];
    [leaves sortUsingComparator:^NSComparisonResult(NPPFLNode *a, NPPFLNode *b) {
        if (a.position == b.position) return NSOrderedSame;
        return (a.position < b.position) ? NSOrderedAscending : NSOrderedDescending;
    }];
    _leavesByPosition = leaves;

    [_outline reloadData];
    if (_displayRoot) [_outline expandItem:_displayRoot expandChildren:YES];

    if (!_root) return;                     // caller already put a status up
    if (leaves.count == 0)
        [self showStatus:(needle.length ? @"No match" : @"No function found")];
    else
        [self showStatus:@""];
    _lastCaret = -1;                        // force the caret highlight to re-run
}

#pragma mark - outline view

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return _displayRoot ? 1 : 0;
    NPPFLNode *n = item;
    return n.children.count;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return _displayRoot;
    NPPFLNode *n = item;
    return n.children[index];
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item { return ((NPPFLNode *)item).children.count > 0; }

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    NPPFLNode *n = item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 18)];
        cell.identifier = @"cell";
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iv];
        cell.imageView = iv;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        [cell addSubview:tf];
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:14],
            [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = n.name ?: @"";
    cell.textField.textColor = _textColor ?: [NSColor labelColor];
    if (@available(macOS 11.0, *)) {
        NSString *symbol = (n == _displayRoot) ? @"doc.text" : (n.isContainer ? @"shippingbox" : @"function");
        cell.imageView.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        cell.imageView.contentTintColor = n.isContainer ? [NSColor secondaryLabelColor] : [NSColor systemBlueColor];
    }
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)note {
    if (_selectingProgrammatically) return;
    [self jumpToSelection];
}

- (void)jumpToSelection {
    NSInteger row = _outline.selectedRow;
    if (row < 0) return;
    NPPFLNode *n = [_outline itemAtRow:row];
    if (!n || n.position < 0) return;
    NPPDocument *doc = [_context contextCurrentDocument];
    ScintillaView *ed = doc.editor;
    if (!ed) return;
    sptr_t pos = MIN((sptr_t)n.position, NPPSci(ed, SCI_GETLENGTH));
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)pos);
    sptr_t line = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)pos);
    NPPSci(ed, SCI_ENSUREVISIBLEENFORCEPOLICY, (uptr_t)line);
    sptr_t visible = NPPSci(ed, SCI_VISIBLEFROMDOCLINE, (uptr_t)line);
    sptr_t onScreen = NPPSci(ed, SCI_LINESONSCREEN);
    NPPSci(ed, SCI_SETFIRSTVISIBLELINE, (uptr_t)MAX((sptr_t)0, visible - onScreen / 2));
    _lastCaret = NPPSci(ed, SCI_GETCURRENTPOS);
}

// Highlight the entry the caret currently sits in (N++ highlights the enclosing node on SCN_UPDATEUI).
- (void)highlightPosition:(sptr_t)caret {
    if (_leavesByPosition.count == 0 || !_outline) return;
    NSInteger lo = 0, hi = (NSInteger)_leavesByPosition.count - 1, best = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if (_leavesByPosition[mid].position <= caret) { best = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    if (best < 0) return;
    NPPFLNode *node = _leavesByPosition[best];
    NSInteger row = [_outline rowForItem:node];
    if (row < 0) return;
    if (row == _outline.selectedRow) return;
    _selectingProgrammatically = YES;
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_outline scrollRowToVisible:row];
    _selectingProgrammatically = NO;
}

#pragma mark - polling

// ponytail: NPPDocument has a single delegate (the window controller), so there is no SCN_UPDATEUI /
// SCN_MODIFIED hook a module can attach to without editing another file. A 400 ms poll of two Scintilla
// getters while the panel is visible costs nothing and covers both caret tracking and edit detection.
// Upgrade path: a document-changed NSNotification from NPPDocument would replace this wholesale.
- (void)startTimer {
    if (_timer) return;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        [[NPPFunctionListPanel shared] poll];
    }];
    _timer.tolerance = 0.15;
}

- (void)poll {
    if (!_visible) return;
    NPPDocument *doc = [_context contextCurrentDocument];
    if (doc != _doc) { [self panelDidChangeCurrentDocument:doc]; return; }
    ScintillaView *ed = doc.editor;
    if (!ed) return;

    sptr_t undo = NPPSci(ed, SCI_GETUNDOCURRENT);
    sptr_t len = NPPSci(ed, SCI_GETLENGTH);
    if (undo != _lastUndo || len != _lastLength) {
        _lastUndo = undo;
        _lastLength = len;
        _pendingReloadAt = CFAbsoluteTimeGetCurrent() + 0.5;      // coalesce bursts of typing
    } else if (_pendingReloadAt > 0 && CFAbsoluteTimeGetCurrent() >= _pendingReloadAt) {
        _pendingReloadAt = 0;
        [self reload];
        return;
    }

    sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    if (caret != _lastCaret) { _lastCaret = caret; [self highlightPosition:caret]; }
}

#pragma mark - theme

- (void)themeDidChange:(NSNotification *)note { [self applyTheme]; }

- (void)applyTheme {
    if (!_outline) return;
    NPPLanguageManager *lm = [NPPLanguageManager shared];
    NSColor *bg = [lm globalBackgroundColorNamed:@"Default Style"];
    NSColor *fg = [lm globalForegroundColorNamed:@"Default Style"];
    _textColor = fg;
    _outline.backgroundColor = bg ?: [NSColor controlBackgroundColor];
    _scroll.backgroundColor = bg ?: [NSColor controlBackgroundColor];
    if (_view) _view.appearance = [lm currentThemeIsDark] ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
                                                          : [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [_outline reloadData];
}
@end
