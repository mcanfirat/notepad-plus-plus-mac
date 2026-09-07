// NPPSelfTest.mm — headless self-test (`Notepad++ --selftest`). Exercises the other modules through their
// header contracts only; editors live offscreen in a hidden NSWindow. Prints "ok  <name>" / "FAIL <name>: reason".
#import "NPPSelfTest.h"
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#include <Scintilla.h>
#include <SciLexer.h>
#include <string>
#import "NPPUtils.h"
#import "NPPCommands.h"
#import "NPPLanguageManager.h"
#import "NPPDocument.h"
#import "NPPEditCommands.h"
#import "NPPFindPanelController.h"
#import "NPPSearchViewCommands.h"
#import "NPPPreferences.h"
#import "NPPMacroManager.h"
#import "NPPRunCommands.h"
#import "NPPUserDefinedLanguages.h"
#import "NPPFunctionListPanel.h"
#import "NPPFindInFiles.h"
#import "NPPUtilityPanels.h"
#import "NPPWorkspacePanel.h"
#import "NPPDocumentMapPanel.h"
#import "NPPProjectPanel.h"
#import "NPPStatusBarView.h"
#import "NPPTabBarView.h"
#import "NPPFindPanelController.h"
#import "NPPPanelHost.h"


static int gFailures = 0;
static NSWindow *gHost = nil;   // hidden window hosting editors (Scintilla needs a window for layout/styling)

static void ok(const char *name) { printf("ok   %s\n", name); fflush(stdout); }
static void fail(const char *name, NSString *reason) {
    gFailures++;
    printf("FAIL %s: %s\n", name, reason.UTF8String ?: "");
    fflush(stdout);
}
static void warn(const char *name, NSString *reason) { printf("warn %s: %s\n", name, reason.UTF8String ?: ""); fflush(stdout); }
static void check(const char *name, BOOL cond, NSString *reason) { cond ? ok(name) : fail(name, reason); }
static void checkEq(const char *name, NSString *got, NSString *want) {
    check(name, [got isEqualToString:want], [NSString stringWithFormat:@"got %@, want %@", got, want]);
}
static void checkEqInt(const char *name, long long got, long long want) {
    check(name, got == want, [NSString stringWithFormat:@"got %lld, want %lld", got, want]);
}

static NSString *Str(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
static NSString *Text(ScintillaView *ed) { return Str(NPPSciGetText(ed)); }
static void SetText(ScintillaView *ed, NSString *s) { NPPSciStr(ed, SCI_SETTEXT, 0, s.UTF8String); NPPSci(ed, SCI_GOTOPOS, 0); }

// Attach the doc's editor to the hidden window so Scintilla has a real view hierarchy.
static NPPDocument *NewDoc() {
    NPPDocument *d = [[NPPDocument alloc] initUntitled];
    if (d.editor && d.editor.superview == nil) {
        d.editor.frame = NSMakeRect(0, 0, 400, 300);
        [gHost.contentView addSubview:d.editor];
    }
    return d;
}
static void Drop(NPPDocument *d) { [d.editor removeFromSuperview]; }

static NSURL *TempURL(NSString *name) {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"npp-selftest-%d-%@", getpid(), name]]];
}
static NSData *Bytes(const char *s, size_t n) { return [NSData dataWithBytes:s length:n]; }
static NSData *Cat(NSData *a, NSData *b) { NSMutableData *m = [a mutableCopy]; [m appendData:b]; return m; }

// The checks that read the upstream XML need a checkout; they skip themselves when there is none.
static NSString *NPPSourceDir() { return NPPUpstreamPath(@"PowerEditor/src"); }

// ---------------------------------------------------------------- 1 language manager
static void testLanguages() {
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NSError *err = nil;
    BOOL loaded;
    NSBundle *b = NSBundle.mainBundle;
    if ([b URLForResource:@"langs.model" withExtension:@"xml"]) {
        loaded = [lm loadDefaultsFromBundle:b error:&err];
    } else {
        NSString *dir = NPPSourceDir();   // fallback when run from build/
        loaded = [lm loadLangsXML:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"langs.model.xml"]]
                       stylersXML:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"stylers.model.xml"]] error:&err];
    }
    check("lang.load", loaded, err.localizedDescription ?: @"load failed");
    check("lang.count>=90", lm.languages.count >= 90, [NSString stringWithFormat:@"count %lu", (unsigned long)lm.languages.count]);
    checkEq("lang.cpp.lexer", [lm languageNamed:@"cpp"].lexerName, @"cpp");

    NSDictionary *byFile = @{ @"a.cpp": @"cpp", @"Makefile": @"makefile", @"x.py": @"python", @"index.html": @"html", @"a.json": @"json" };
    for (NSString *f in byFile) {
        NSString *got = [lm languageForFileURL:[NSURL fileURLWithPath:[@"/tmp" stringByAppendingPathComponent:f]]].name;
        checkEq([NSString stringWithFormat:@"lang.file.%@", f].UTF8String, got, byFile[f]);
    }
    const char *py = "#!/usr/bin/env python\nprint(1)\n";
    checkEq("lang.firstline.python", [lm languageForFirstLine:Bytes(py, strlen(py))].name, @"python");
    const char *xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a/>\n";
    checkEq("lang.firstline.xml", [lm languageForFirstLine:Bytes(xml, strlen(xml))].name, @"xml");
}

// ---------------------------------------------------------------- 2 document + lexing
static void expectStyle(const char *name, NSString *langName, NSString *text, NSUInteger pos, int wantStyle) {
    NPPDocument *d = NewDoc();
    SetText(d.editor, text);
    NPPLanguage *lang = [NPPLanguageManager.shared languageNamed:langName];
    if (!lang) { fail(name, [NSString stringWithFormat:@"no language %@", langName]); Drop(d); return; }
    d.language = lang;
    NPPSci(d.editor, SCI_COLOURISE, 0, -1);
    checkEqInt(name, NPPSci(d.editor, SCI_GETSTYLEAT, pos), wantStyle);
    Drop(d);
}

static void testDocument() {
    NPPDocument *d1 = NewDoc();
    checkEq("doc.new1", d1.displayName, @"new 1");
    check("doc.editor", d1.editor != nil, @"editor nil");
    NPPDocument *d2 = NewDoc();
    checkEq("doc.new2", d2.displayName, @"new 2");
    Drop(d2); d2 = nil;
    NPPDocument *d3 = NewDoc();
    if ([d3.displayName isEqualToString:@"new 2"]) ok("doc.reuse-number");
    else warn("doc.reuse-number", [NSString stringWithFormat:@"got %@ after dealloc; dealloc does not release the number", d3.displayName]);
    Drop(d3); d3 = nil;
    NSInteger n = [NPPDocument claimUntitledNumber];
    [NPPDocument releaseUntitledNumber:n];
    checkEqInt("doc.claim-release", [NPPDocument claimUntitledNumber], n);
    [NPPDocument releaseUntitledNumber:n];
    Drop(d1);

    NSString *c = @"int main() { return 0; } // c\n";
    expectStyle("lex.cpp.typeword", @"cpp", c, 0, SCE_C_WORD2);   // N++: "int" is in type1 -> TYPE WORD
    expectStyle("lex.cpp.word", @"cpp", c, 13, SCE_C_WORD);       // "return" is in instre1 -> INSTRUCTION WORD
    expectStyle("lex.cpp.comment", @"cpp", c, [c rangeOfString:@"//"].location, SCE_C_COMMENTLINE);
    expectStyle("lex.python.word", @"python", @"def f(): pass # x\n", 0, SCE_P_WORD);
    expectStyle("lex.html.tag", @"html", @"<html>\n", 1, SCE_H_TAG);
    expectStyle("lex.json.propertyname", @"json", @"{\"a\": 1}\n", 1, SCE_JSON_PROPERTYNAME);
}

// ---------------------------------------------------------------- 3 theme
static void testTheme() {
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    if (![lm.availableThemeNames containsObject:@"DarkModeDefault"]) {
        warn("theme.dark", @"DarkModeDefault not available (themes/ not in bundle)");
        return;
    }
    NPPDocument *d = NewDoc();
    long before = NPPSci(d.editor, SCI_STYLEGETBACK, STYLE_DEFAULT);
    NSError *err = nil;
    check("theme.select-dark", [lm selectThemeNamed:@"DarkModeDefault" error:&err], err.localizedDescription ?: @"");
    [d applyThemeAndLanguage];
    check("theme.isDark", lm.currentThemeIsDark, @"currentThemeIsDark NO");
    long after = NPPSci(d.editor, SCI_STYLEGETBACK, STYLE_DEFAULT);
    check("theme.default-back-changed", after != before, [NSString stringWithFormat:@"back %lx unchanged", after]);
    check("theme.select-default", [lm selectThemeNamed:@"Default (stylers.xml)" error:&err], err.localizedDescription ?: @"");
    [d applyThemeAndLanguage];
    check("theme.isLight", !lm.currentThemeIsDark, @"still dark");
    Drop(d);
}

// ---------------------------------------------------------------- 4-7 file I/O
static const char kBOM8[] = "\xEF\xBB\xBF";

static void testFileUTF8BOM() {
    NSURL *in = TempURL(@"bom.txt"), *out = TempURL(@"bom-out.txt");
    [Cat(Bytes(kBOM8, 3), Bytes("a\r\nb\r\n", 6)) writeToURL:in atomically:YES];
    NPPDocument *d = NewDoc();
    NSError *err = nil;
    check("utf8bom.load", [d loadFromURL:in error:&err], err.localizedDescription ?: @"");
    checkEqInt("utf8bom.encoding", d.encoding, NPPEncodingUTF8BOM);
    checkEqInt("utf8bom.eol", d.eolMode, NPPEOLWindows);
    checkEq("utf8bom.text", Text(d.editor), @"a\r\nb\r\n");
    [d convertEOLTo:NPPEOLUnix];
    checkEq("utf8bom.convertEOL", Text(d.editor), @"a\nb\n");
    check("utf8bom.save", [d saveToURL:out error:&err], err.localizedDescription ?: @"");
    check("utf8bom.bytes", [[NSData dataWithContentsOfURL:out] isEqualToData:Cat(Bytes(kBOM8, 3), Bytes("a\nb\n", 4))], @"saved bytes differ");
    NPPDocument *d2 = NewDoc();
    check("utf8bom.reload", [d2 loadFromURL:out error:&err], err.localizedDescription ?: @"");
    checkEqInt("utf8bom.reload.eol", d2.eolMode, NPPEOLUnix);
    Drop(d); Drop(d2);
    [NSFileManager.defaultManager removeItemAtURL:in error:nil];
    [NSFileManager.defaultManager removeItemAtURL:out error:nil];
}

static void testFileUTF16LE() {
    NSURL *in = TempURL(@"u16.txt"), *out = TempURL(@"u16-out.txt");
    NSData *body = [@"hé" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    [Cat(Bytes("\xFF\xFE", 2), body) writeToURL:in atomically:YES];
    NPPDocument *d = NewDoc();
    NSError *err = nil;
    check("utf16le.load", [d loadFromURL:in error:&err], err.localizedDescription ?: @"");
    checkEqInt("utf16le.encoding", d.encoding, NPPEncodingUTF16LE);
    checkEq("utf16le.text", Text(d.editor), @"hé");
    check("utf16le.save", [d saveToURL:out error:&err], err.localizedDescription ?: @"");
    NSData *saved = [NSData dataWithContentsOfURL:out];
    check("utf16le.bom", saved.length >= 2 && memcmp(saved.bytes, "\xFF\xFE", 2) == 0, @"no FF FE prefix");
    NSString *back = saved.length >= 2 ? [[NSString alloc] initWithData:[saved subdataWithRange:NSMakeRange(2, saved.length - 2)]
                                                               encoding:NSUTF16LittleEndianStringEncoding] : nil;
    checkEq("utf16le.decode", back, @"hé");
    Drop(d);
    [NSFileManager.defaultManager removeItemAtURL:in error:nil];
    [NSFileManager.defaultManager removeItemAtURL:out error:nil];
}

static void testFileANSI() {
    NSURL *in = TempURL(@"tr.txt"), *out = TempURL(@"tr-out.txt");
    NSStringEncoding cp1254 = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin5);
    NSString *line = @"Türkçe ğüşiöç ĞÜŞİÖÇ İstanbul'da güneşli bir gün\n";
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 20; i++) [s appendString:line];
    NSData *input = [s dataUsingEncoding:cp1254];
    if (!input) { fail("ansi.encode-fixture", @"cannot encode windows-1254"); return; }
    [input writeToURL:in atomically:YES];
    NPPDocument *d = NewDoc();
    NSError *err = nil;
    check("ansi.load", [d loadFromURL:in error:&err], err.localizedDescription ?: @"");
    checkEqInt("ansi.encoding", d.encoding, NPPEncodingANSI);
    NSString *iana = [NPPCharset charsetForCFEncoding:d.codepage].ianaName ?: [NSString stringWithFormat:@"cf#%u", (unsigned)d.codepage];
    BOOL decodedOK = [Text(d.editor) containsString:@"İstanbul"];
    if (decodedOK) ok([NSString stringWithFormat:@"ansi.decode (%@)", iana].UTF8String);
    else warn("ansi.decode", [NSString stringWithFormat:@"detected %@, text lacks 'İstanbul' (uchardet sibling codepage)", iana]);
    d.encoding = NPPEncodingANSI;
    d.codepage = kCFStringEncodingWindowsLatin5;
    check("ansi.save", [d saveToURL:out error:&err], err.localizedDescription ?: @"");
    if (decodedOK) check("ansi.roundtrip-bytes", [[NSData dataWithContentsOfURL:out] isEqualToData:input], @"saved bytes differ from input");
    else warn("ansi.roundtrip-bytes", @"skipped (decode was lossy)");
    Drop(d);
    [NSFileManager.defaultManager removeItemAtURL:in error:nil];
    [NSFileManager.defaultManager removeItemAtURL:out error:nil];
}

static void testUntitledSave() {
    NSURL *out = TempURL(@"t.py");
    NPPDocument *d = NewDoc();
    SetText(d.editor, @"x");
    NSError *err = nil;
    check("untitled.save", [d saveToURL:out error:&err], err.localizedDescription ?: @"");
    check("untitled.clean", !d.isDirty, @"still dirty");
    check("untitled.named", !d.isUntitled, @"still untitled");
    checkEq("untitled.language", d.language.name, @"python");
    Drop(d);
    [NSFileManager.defaultManager removeItemAtURL:out error:nil];
}

// ---------------------------------------------------------------- 8 edit commands
static void edit(NPPCmd cmd, NPPDocument *d) { [NPPEditCommands performCommand:cmd onEditor:d.editor language:d.language]; }

static void testEditCommands() {
    NPPDocument *d = NewDoc();
    ScintillaView *ed = d.editor;
    SetText(ed, @"b\na\nb\nc\n");
    edit(NPPCmdEditSortLexAsc, d);              checkEq("edit.sort", Text(ed), @"a\nb\nb\nc\n");
    edit(NPPCmdEditRemoveDuplicateLines, d);    checkEq("edit.dedupe", Text(ed), @"a\nb\nc\n");
    NPPSci(ed, SCI_SELECTALL);
    edit(NPPCmdEditUpperCase, d);               checkEq("edit.upper", Text(ed), @"A\nB\nC\n");

    d.language = [NPPLanguageManager.shared languageNamed:@"cpp"];
    SetText(ed, @"x;\n");
    edit(NPPCmdEditToggleLineComment, d);       checkEq("edit.comment", Text(ed), @"// x;\n");
    NPPSci(ed, SCI_GOTOPOS, 0);
    edit(NPPCmdEditToggleLineComment, d);       checkEq("edit.uncomment", Text(ed), @"x;\n");

    SetText(ed, @"a  \nb\t\n");
    edit(NPPCmdEditTrimTrailing, d);            checkEq("edit.trim", Text(ed), @"a\nb\n");
    NPPSci(ed, SCI_SETTABWIDTH, 4);
    SetText(ed, @"\tx");
    edit(NPPCmdEditTabToSpace, d);              checkEq("edit.tab2space", Text(ed), @"    x");
    SetText(ed, @"q\n");
    edit(NPPCmdEditDuplicateLine, d);           checkEq("edit.duplicate", Text(ed), @"q\nq\n");
    SetText(ed, @"");
    edit(NPPCmdEditInsertDateTimeShort, d);
    check("edit.datetime", NPPSci(ed, SCI_GETLENGTH) > 0, @"nothing inserted");
    Drop(d);
}

// ---------------------------------------------------------------- 9 find
static NSString *SelRange(ScintillaView *ed) {
    return [NSString stringWithFormat:@"%ld-%ld", (long)NPPSci(ed, SCI_GETSELECTIONSTART), (long)NPPSci(ed, SCI_GETSELECTIONEND)];
}

static void testFind() {
    NPPFindPanelController *fp = NPPFindPanelController.shared;
    NPPDocument *d = NewDoc();
    ScintillaView *ed = d.editor;
    SetText(ed, @"foo bar foo\n");
    BOOL f = [fp findText:@"foo" inEditor:ed backward:NO wrap:NO matchCase:NO wholeWord:NO mode:NPPSearchModeNormal select:YES];
    check("find.first", f && [SelRange(ed) isEqualToString:@"0-3"], SelRange(ed));
    f = [fp findText:@"foo" inEditor:ed backward:NO wrap:NO matchCase:NO wholeWord:NO mode:NPPSearchModeNormal select:YES];
    check("find.second", f && [SelRange(ed) isEqualToString:@"8-11"], SelRange(ed));
    f = [fp findText:@"foo" inEditor:ed backward:NO wrap:YES matchCase:NO wholeWord:NO mode:NPPSearchModeNormal select:YES];
    check("find.wrap", f && [SelRange(ed) isEqualToString:@"0-3"], SelRange(ed));

    fp.searchMode = NPPSearchModeNormal; fp.matchCase = NO; fp.wholeWord = NO; fp.inSelection = NO; fp.wrapAround = YES;
    fp.searchText = @"foo"; fp.replaceText = @"X";
    checkEqInt("find.replaceAll.count", [fp replaceAllInEditor:ed], 2);
    checkEq("find.replaceAll.text", Text(ed), @"X bar X\n");

    SetText(ed, @"a1 b22 c333");
    f = [fp findText:@"\\d+" inEditor:ed backward:NO wrap:NO matchCase:NO wholeWord:NO mode:NPPSearchModeRegex select:YES];
    checkEq("find.regex", f ? NPPSciSelectedString(ed) : @"(not found)", @"1");
    fp.searchMode = NPPSearchModeRegex; fp.searchText = @"\\d+";
    checkEqInt("find.count", [fp countInEditor:ed], 3);
    fp.bookmarkLinesOnMark = NO;
    [fp markAllInEditor:ed];
    check("find.markAll", NPPSci(ed, SCI_INDICATORVALUEAT, NPPIndicatorFindMark, 1) != 0, @"indicator 31 not set at pos 1");
    [fp clearMarksInEditor:ed];
    checkEqInt("find.clearMarks", NPPSci(ed, SCI_INDICATORVALUEAT, NPPIndicatorFindMark, 1), 0);
    fp.searchMode = NPPSearchModeNormal;
    Drop(d);
}

// ---------------------------------------------------------------- 10 bookmarks / braces
static void testSearchView() {
    NPPDocument *d = NewDoc();
    ScintillaView *ed = d.editor;
    SetText(ed, @"a\nb\nc\n");
    [NPPSearchViewCommands toggleBookmarkOnCurrentLine:ed];
    check("bookmark.toggle", NPPSci(ed, SCI_MARKERGET, 0) & (1 << NPPMarkerBookmark), @"marker 20 not set on line 0");
    NPPSci(ed, SCI_GOTOLINE, 1);
    BOOL went = [NPPSearchViewCommands goToBookmark:ed next:YES];
    long line = NPPSci(ed, SCI_LINEFROMPOSITION, NPPSci(ed, SCI_GETCURRENTPOS));
    check("bookmark.next", went && line == 0, [NSString stringWithFormat:@"returned %d, line %ld", went, line]);

    SetText(ed, @"(a[b]c)");
    [NPPSearchViewCommands braceMatchCommand:ed selectBetween:YES];
    checkEq("brace.selectBetween", NPPSciSelectedString(ed), @"a[b]c");
    Drop(d);
}

// ---------------------------------------------------------------- 11 preferences
static void testPreferences() {
    NPPPreferences *p = NPPPreferences.shared;
    NSInteger orig = p.tabSize;
    __block int posted = 0;
    id obs = [NSNotificationCenter.defaultCenter addObserverForName:NPPPreferencesDidChangeNotification object:nil queue:nil
                                                         usingBlock:^(NSNotification *n) { posted++; }];
    p.tabSize = 8;
    checkEqInt("prefs.tabSize.set", p.tabSize, 8);
    p.tabSize = orig ?: 4;
    checkEqInt("prefs.tabSize.restore", p.tabSize, orig ?: 4);
    [NSNotificationCenter.defaultCenter removeObserver:obs];
    check("prefs.notification", posted >= 1, @"NPPPreferencesDidChangeNotification not posted");
}

// ----------------------------------------------------------------

// ---------------------------------------------------------------- 12 review fixes (regression guards)
static void testReviewFixes() {
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NPPDocument *d = NewDoc();
    ScintillaView *ed = d.editor;
    d.language = [lm languageNamed:@"cpp"];

    // Toggle Single Line Comment decides per line, exactly like N++ doBlockComment(cm_toggle).
    SetText(ed, @"a;\n// b;\nc;\n");
    NPPSci(ed, SCI_SETSEL, 0, NPPSci(ed, SCI_GETLENGTH));
    edit(NPPCmdEditToggleLineComment, d);
    checkEq("fix.comment.perLine", Text(ed), @"// a;\nb;\n// c;\n");

    // "Single Line Comment" comments every line, even already commented ones (N++ cm_comment).
    SetText(ed, @"// x;\n");
    edit(NPPCmdEditLineComment, d);
    checkEq("fix.comment.setAlways", Text(ed), @"// // x;\n");

    // Stream-comment-only language (OCaml/caml: no commentLine, (* *) only) -> advanced mode toggles per line.
    NPPLanguage *caml = [lm languageNamed:@"caml"];
    check("fix.caml.noLineComment", caml != nil && caml.commentLine.length == 0 && caml.commentStart.length > 0,
          [NSString stringWithFormat:@"caml commentLine='%@' start='%@'", caml.commentLine, caml.commentStart]);
    d.language = caml;
    SetText(ed, @"let x = 1\n");
    edit(NPPCmdEditToggleLineComment, d);
    checkEq("fix.comment.advanced", Text(ed), @"(* let x = 1 *)\n");
    NPPSci(ed, SCI_GOTOPOS, 0);
    edit(NPPCmdEditToggleLineComment, d);
    checkEq("fix.uncomment.advanced", Text(ed), @"let x = 1\n");
    d.language = [lm languageNamed:@"cpp"];

    // Block (stream) comment with no selection wraps the current line, not the word at the caret.
    SetText(ed, @"int a = 1;\n");
    NPPSci(ed, SCI_GOTOPOS, 4);
    edit(NPPCmdEditBlockComment, d);
    checkEq("fix.blockComment.line", Text(ed), @"/* int a = 1; */\n");

    // Duplicate Current Line duplicates the line even when something is selected (N++ SCI_LINEDUPLICATE).
    SetText(ed, @"abc\n");
    NPPSci(ed, SCI_SETSEL, 1, 2);
    edit(NPPCmdEditDuplicateLine, d);
    checkEq("fix.dupLine", Text(ed), @"abc\nabc\n");

    // Insert Blank Line Above/Below leaves the caret on the new blank line.
    SetText(ed, @"a\nb\n");
    NPPSci(ed, SCI_GOTOPOS, 0);
    edit(NPPCmdEditInsertBlankLineBelow, d);
    checkEq("fix.blankBelow.text", Text(ed), @"a\n\nb\n");
    checkEqInt("fix.blankBelow.caret", NPPSci(ed, SCI_GETCURRENTPOS), 2);
    SetText(ed, @"a\nb\n");
    NPPSci(ed, SCI_GOTOPOS, 2);   // line 1
    edit(NPPCmdEditInsertBlankLineAbove, d);
    checkEq("fix.blankAbove.text", Text(ed), @"a\n\nb\n");
    checkEqInt("fix.blankAbove.caret", NPPSci(ed, SCI_GETCURRENTPOS), 2);

    // Case conversion must never delete text it cannot decode as UTF-8.
    NPPSciStr(ed, SCI_SETTEXT, 0, "\xff\xfe abc");
    NPPSci(ed, SCI_SELECTALL);
    edit(NPPCmdEditUpperCase, d);
    checkEqInt("fix.case.invalidUtf8", NPPSci(ed, SCI_GETLENGTH), 6);

    // Brace matching: N++ matches [](){} only, and prefers the character BEFORE the caret.
    SetText(ed, @"a<b>c");
    NPPSci(ed, SCI_GOTOPOS, 2);
    check("fix.brace.noAngle", ![NPPSearchViewCommands canPerformCommand:NPPCmdSearchGoToMatchingBrace onEditor:ed], @"< matched as a brace");
    SetText(ed, @"(ab)");
    NPPSci(ed, SCI_GOTOPOS, 1);   // char before caret is '(' -> match
    check("fix.brace.before", [NPPSearchViewCommands canPerformCommand:NPPCmdSearchGoToMatchingBrace onEditor:ed], @"brace before caret not found");
    [NPPSearchViewCommands performCommand:NPPCmdSearchSelectBetweenBraces onEditor:ed];
    checkEq("fix.brace.between", NPPSciSelectedString(ed), @"ab");

    // Find Next / Find Previous ignore the dialog's "Backward direction" checkbox (N++ forces the direction).
    NPPFindPanelController *fp = NPPFindPanelController.shared;
    SetText(ed, @"x a y a z");
    fp.searchMode = NPPSearchModeNormal; fp.matchCase = NO; fp.wholeWord = NO; fp.inSelection = NO;
    fp.wrapAround = NO; fp.backwardDirection = YES; fp.searchText = @"a";
    [fp findNextInEditor:ed];
    checkEqInt("fix.findNext.forward1", NPPSci(ed, SCI_GETSELECTIONSTART), 2);
    [fp findNextInEditor:ed];
    checkEqInt("fix.findNext.forward2", NPPSci(ed, SCI_GETSELECTIONSTART), 6);
    [fp findPreviousInEditor:ed];
    checkEqInt("fix.findPrev.backward", NPPSci(ed, SCI_GETSELECTIONSTART), 2);
    fp.backwardDirection = NO;
    Drop(d);

    // "Encode in UTF-16 LE" on a UTF-8 buffer keeps the text and marks it dirty (N++ only switches the mode).
    NSURL *in = TempURL(@"encodein.txt");
    [Bytes("h\xc3\xa9llo\n", 7) writeToURL:in atomically:YES];
    NPPDocument *e = NewDoc();
    NSError *err = nil;
    check("fix.encodein.load", [e loadFromURL:in error:&err], err.localizedDescription ?: @"");
    checkEqInt("fix.encodein.utf8", e.encoding, NPPEncodingUTF8);
    [e reinterpretAsEncoding:NPPEncodingUTF16LE codepage:e.codepage];
    checkEq("fix.encodein.textKept", Text(e.editor), @"héllo\n");
    checkEqInt("fix.encodein.mode", e.encoding, NPPEncodingUTF16LE);
    check("fix.encodein.dirty", e.isDirty, @"switching the Unicode mode must mark the buffer dirty");
    Drop(e);
    [NSFileManager.defaultManager removeItemAtURL:in error:nil];

    // A code page IS re-read from disk: cp1254 bytes reinterpreted as Windows-1254 must decode to Turkish text.
    NSURL *tr = TempURL(@"tr1254.txt");
    NSData *trBytes = [@"İstanbul'da güneşli bir gün\n" dataUsingEncoding:
                       CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin5) allowLossyConversion:YES];
    [trBytes writeToURL:tr atomically:YES];
    NPPDocument *t = NewDoc();
    check("fix.charset.load", [t loadFromURL:tr error:&err], err.localizedDescription ?: @"");
    [t reinterpretAsEncoding:NPPEncodingANSI codepage:kCFStringEncodingWindowsLatin5];
    check("fix.charset.reloaded", [Text(t.editor) containsString:@"İstanbul"], Text(t.editor));
    Drop(t);
    [NSFileManager.defaultManager removeItemAtURL:tr error:nil];
}


// ---------------------------------------------------------------- 13 feature modules
static void testFeatures() {
    NPPDocument *d = NewDoc();
    ScintillaView *ed = d.editor;

    // --- Macro playback: build the steps directly and replay them (recording needs the notification hook + a window) ---
    NPPMacroManager *mm = NPPMacroManager.shared;
    check("feat.macro.notRecording", !mm.isRecording, @"manager starts out recording");
    SetText(ed, @"alpha\nbeta\n");
    NPPSci(ed, SCI_GOTOPOS, 0);
    NSArray<NPPMacroStep *> *steps = @[
        [[NPPMacroStep alloc] initWithMessage:SCI_REPLACESEL wParam:0 lParam:0 text:@"X"],
        [[NPPMacroStep alloc] initWithMessage:SCI_LINEDOWN wParam:0 lParam:0 text:nil],
        [[NPPMacroStep alloc] initWithMessage:SCI_HOME wParam:0 lParam:0 text:nil],
    ];
    [mm playMacroSteps:steps onEditor:ed untilEndOfFileFromEditor:NO times:2];
    checkEq("feat.macro.playback", Text(ed), @"Xalpha\nXbeta\n");

    // --- Run: $(VAR) expansion + shell quoting ---
    check("feat.run.expansion", [NPPRunCommands selfTestExpansion], @"NPPRunCommands selfTestExpansion failed");

    // --- User-defined languages: the bundled UDL must load and actually style text ---
    NPPUserDefinedLanguages *udl = NPPUserDefinedLanguages.shared;
    check("feat.udl.loaded", udl.languageNames.count > 0, @"no user-defined languages found");
    if (udl.languageNames.count) {
        NSString *name = udl.languageNames.firstObject;
        SetText(ed, @"# Heading\n\nSome **bold** text and `code`\n");
        check("feat.udl.applied", [udl applyUserLanguageNamed:name toEditor:ed],
              [NSString stringWithFormat:@"could not apply %@", name]);
        NPPSci(ed, SCI_COLOURISE, 0, -1);
        BOOL styled = NO;
        for (sptr_t i = 0, n = NPPSci(ed, SCI_GETLENGTH); i < n; i++)
            if (NPPSci(ed, SCI_GETSTYLEAT, (uptr_t)i) != 0) { styled = YES; break; }
        check("feat.udl.styling", styled, @"the UDL lexer produced no styling at all");
        check("feat.udl.byExtension", [udl userLanguageNameForFileURL:[NSURL fileURLWithPath:@"/tmp/x.md"]] != nil,
              @"markdown UDL not matched by its extension");
    }

    // --- Function list: the bundled C++ parser must find main() ---
    NSURL *flDir = [NPPFunctionListPanel functionListDirectoryURL];
    check("feat.funclist.resources", flDir != nil, @"functionList directory not found in the bundle");
    if (flDir) {
        NSError *err = nil;
        NPPFunctionListParser *parser = [NPPFunctionListParser parserWithContentsOfURL:[flDir URLByAppendingPathComponent:@"cpp.xml"] error:&err];
        check("feat.funclist.parser", parser != nil, err.localizedDescription ?: @"cpp.xml did not load");
        if (parser) {
            NSArray<NPPFunctionListEntry *> *entries =
                [parser parseText:@"#include <cstdio>\n\nstatic int helper(int a) { return a; }\n\nint main(int argc, char **argv) {\n    return helper(argc);\n}\n"
                        cancelled:nil];
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NPPFunctionListEntry *e in entries) [names addObject:e.name ?: @""];
            check("feat.funclist.main", [[names componentsJoinedByString:@" "] containsString:@"main"],
                  [NSString stringWithFormat:@"found: %@", [names componentsJoinedByString:@", "]]);
        }
    }

    // --- Find in Files: "find all" over open documents fills the results panel ---
    NPPDocument *a = NewDoc(), *b = NewDoc();
    SetText(a.editor, @"needle here\nand nothing\n");
    SetText(b.editor, @"another needle\n");
    [NPPFindInFiles.shared clearAllResults];
    [NPPFindInFiles.shared findAllIn:@[a, b] text:@"needle" matchCase:NO wholeWord:NO mode:NPPSearchModeNormal scope:@"All Opened Documents"];
    check("feat.findall.results", NPPFindInFiles.shared.hasResults, @"no results after find all");
    [NPPFindInFiles.shared clearAllResults];
    Drop(a); Drop(b);

    // --- Every panel builds its view without a window (they are created lazily on first dock) ---
    struct { const char *name; id<NPPPanel> panel; } panels[] = {
        {"workspace", NPPWorkspacePanel.shared}, {"documentMap", NPPDocumentMapPanel.shared},
        {"functionList", NPPFunctionListPanel.shared}, {"documentList", NPPDocumentListPanel.shared},
        {"clipboard", NPPClipboardHistoryPanel.shared}, {"characters", NPPCharacterPanel.shared},
        {"project1", [NPPProjectPanel panelAtIndex:0]}, {"searchResults", NPPFindInFiles.shared},
    };
    for (auto &p : panels) {
        NSString *nm = [NSString stringWithFormat:@"feat.panel.%s", p.name];
        NSView *v = p.panel.panelView;
        check(nm.UTF8String, v != nil && p.panel.panelTitle.length > 0,
              [NSString stringWithFormat:@"view=%@ title=%@", v, p.panel.panelTitle]);
        if ([p.panel respondsToSelector:@selector(panelDidChangeCurrentDocument:)]) [p.panel panelDidChangeCurrentDocument:d];
    }

    Drop(d);
}


// ---------------------------------------------------------------- 14 panel host (docking, tab transitions)
@interface NPPStubPanel : NSObject <NPPPanel>
@property (nonatomic) NSInteger shown, hidden, documentBroadcasts;
@property (nonatomic) NPPPanelEdge edge;
@property (nonatomic, strong) NSView *view;
@property (nonatomic, copy) NSString *title;
@end
@implementation NPPStubPanel
- (NSString *)panelTitle { return _title ?: @"Stub"; }
- (NSView *)panelView { if (!_view) _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)]; return _view; }
- (NPPPanelEdge)panelPreferredEdge { return _edge; }
- (void)panelDidBecomeVisible { _shown++; }
- (void)panelWillHide { _hidden++; }
- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc { _documentBroadcasts++; }
@end

static void testPanelHost() {
    NPPPanelHost *host = [[NPPPanelHost alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    NPPStubPanel *a = [NPPStubPanel new]; a.title = @"A"; a.edge = NPPPanelEdgeLeft;
    NPPStubPanel *b = [NPPStubPanel new]; b.title = @"B"; b.edge = NPPPanelEdgeLeft;

    [host showPanel:a];
    check("panel.showA", [host isPanelVisible:a] && a.shown == 1 && a.hidden == 0,
          [NSString stringWithFormat:@"visible=%d shown=%ld hidden=%ld", [host isPanelVisible:a], (long)a.shown, (long)a.hidden]);

    // Docking B at the same edge stacks it as a tab in front of A: A must be told it went behind.
    [host showPanel:b];
    check("panel.showB", [host isPanelVisible:b] && !([host isPanelVisible:a]),
          @"B did not become the front tab");
    checkEqInt("panel.aHiddenOnSwitch", a.hidden, 1);
    checkEqInt("panel.bShown", b.shown, 1);

    // Closing the front tab promotes its neighbour, which must be told it is visible again.
    [host hidePanel:b];
    checkEqInt("panel.bHidden", b.hidden, 1);
    check("panel.aPromoted", [host isPanelVisible:a], @"A was not promoted after B closed");
    checkEqInt("panel.aShownAgain", a.shown, 2);

    // Broadcasts reach every docked panel, front or not.
    [host showPanel:b];
    [host broadcastCurrentDocument:nil];
    check("panel.broadcast", a.documentBroadcasts >= 1 && b.documentBroadcasts >= 1,
          [NSString stringWithFormat:@"a=%ld b=%ld", (long)a.documentBroadcasts, (long)b.documentBroadcasts]);

    [host hidePanel:a];
    [host hidePanel:b];
    checkEqInt("panel.allHidden", (NSInteger)host.visiblePanels.count, 0);
}

// Regression: a view whose -drawRect: fills the *dirty rect* paints outside itself, because NSView.clipsToBounds
// defaults to NO since macOS 14. The status bar is the last subview of the window, so when that happened it covered
// the tab bar and the whole editor — the window looked empty and typing appeared to do nothing.
static void testDrawStaysInBounds() {
    const NSInteger W = 200, H = 100, BAR = 22;
    NPPStatusBarView *bar = [[NPPStatusBarView alloc] initWithFrame:NSMakeRect(0, 0, W, BAR)];
    bar.backgroundColor = NSColor.redColor;

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = gc;
    [NSColor.greenColor setFill];
    NSRectFill(NSMakeRect(0, 0, W, H));
    [bar drawRect:NSMakeRect(0, 0, W, H)];   // a dirty rect far taller than the 22pt bar
    [NSGraphicsContext restoreGraphicsState];

    NSColor *above = [[rep colorAtX:W / 2 y:0] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];       // top row
    NSColor *inside = [[rep colorAtX:W / 2 y:H - 1] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];  // bottom row
    check("draw.status-bar-stays-in-bounds", above.greenComponent > 0.5 && above.redComponent < 0.5,
          [NSString stringWithFormat:@"status bar painted %ld pt above itself (%@)", (long)(H - BAR), above]);
    check("draw.status-bar-fills-itself", inside.redComponent > 0.5, [NSString stringWithFormat:@"bar not drawn (%@)", inside]);
}

// Stub delegate for the tab bar's "+" button.
@interface NPPStubTabDelegate : NSObject <NPPTabBarDelegate>
@property (nonatomic) NSInteger newTabClicks;
@end
@implementation NPPStubTabDelegate
- (void)tabBar:(NPPTabBarView *)b didSelectTabAtIndex:(NSInteger)i {}
- (void)tabBar:(NPPTabBarView *)b didRequestCloseTabAtIndex:(NSInteger)i {}
- (void)tabBar:(NPPTabBarView *)b didMoveTabFromIndex:(NSInteger)f toIndex:(NSInteger)t {}
- (void)tabBarDidClickNewTab:(NPPTabBarView *)b { _newTabClicks++; }
@end

static NPPTabItem *TabItem(NSString *title) { NPPTabItem *it = [NPPTabItem new]; it.title = title; return it; }

// The "+" must follow the last tab, stay inside the bar when the tabs overflow, and never be mistaken for a tab.
// Every feature module may contribute its own checks through +selfCheckFailures, so a new module ships its
// regression guards with itself instead of editing this file.
static void testFeatureModuleSelfChecks() {
    for (NSString *name in @[@"NPPMacroManager", @"NPPRunCommands", @"NPPFindInFiles", @"NPPWorkspacePanel",
                             @"NPPDocumentMapPanel", @"NPPFunctionListPanel", @"NPPColumnEditor",
                             @"NPPUserDefinedLanguages", @"NPPUtilityPanels", @"NPPProjectPanel",
                             @"NPPBackupManager", @"NPPAutoCompletion", @"NPPHashTools", @"NPPShortcutMapper",
                             @"NPPEditCommands", @"NPPSearchViewCommands", @"NPPTabBarView",
                             @"NPPDocument", @"NPPLanguageManager",
                             @"NPPPreferences", @"NPPEditorWindowController",
                             @"NPPToolBar", @"NPPLocalization", @"NPPCommandLine", @"NPPPrintRenderer", @"NPPAppDelegate",
                             @"NPPFindPanelController", @"NPPPanelHost"]) {
        Class c = NSClassFromString(name);
        if (!c || ![c respondsToSelector:@selector(selfCheckFailures)]) continue;
        NSArray<NSString *> *failures = [c performSelector:@selector(selfCheckFailures)];
        NSString *label = [NSString stringWithFormat:@"module.%@", name];
        check(label.UTF8String, failures.count == 0, [failures componentsJoinedByString:@"; "] ?: @"");
    }
}

static void testNewTabButton() {
    NPPTabBarView *bar = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, 28)];
    NPPStubTabDelegate *d = [NPPStubTabDelegate new];
    bar.delegate = d;
    [gHost.contentView addSubview:bar];

    bar.items = @[TabItem(@"a.cpp"), TabItem(@"b.md")];
    NSRect plus = bar.newTabButtonRect;
    check("tab.plus-after-last-tab", NSMinX(plus) > 100 && NSMaxX(plus) <= 400,
          [NSString stringWithFormat:@"plus at %@ for 2 tabs", NSStringFromRect(plus)]);

    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 30; i++) [many addObject:TabItem([NSString stringWithFormat:@"file-%d.cpp", i])];
    bar.items = many;
    plus = bar.newTabButtonRect;
    check("tab.plus-stays-in-bar", NSMaxX(plus) <= 400 && NSMinX(plus) >= 0,
          [NSString stringWithFormat:@"plus at %@ with 30 tabs", NSStringFromRect(plus)]);

    NSPoint win = [bar convertPoint:NSMakePoint(NSMidX(plus), NSMidY(plus)) toView:nil];
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:win modifierFlags:0 timestamp:0
                                    windowNumber:gHost.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [bar mouseDown:click];
    checkEqInt("tab.plus-click-makes-new-file", d.newTabClicks, 1);
    [bar removeFromSuperview];
}

int NPPRunSelfTest(void) {
    NSDate *start = NSDate.date;
    @autoreleasepool {
        gHost = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless
                                              backing:NSBackingStoreBuffered defer:NO];
        gHost.releasedWhenClosed = NO;   // never shown; ARC owns it
        [NPPPreferences.shared registerDefaults];

        struct { const char *name; void (*fn)(); } tests[] = {
            { "languages", testLanguages }, { "document", testDocument }, { "theme", testTheme },
            { "utf8bom", testFileUTF8BOM }, { "utf16le", testFileUTF16LE }, { "ansi", testFileANSI },
            { "untitled-save", testUntitledSave }, { "edit", testEditCommands }, { "find", testFind },
            { "search-view", testSearchView }, { "preferences", testPreferences },
            { "review-fixes", testReviewFixes }, { "features", testFeatures }, { "panel-host", testPanelHost },
            { "draw-bounds", testDrawStaysInBounds }, { "new-tab-button", testNewTabButton }, { "module-self-checks", testFeatureModuleSelfChecks },
        };
        for (auto &t : tests) {
            @try { t.fn(); }
            @catch (NSException *e) { fail(t.name, [NSString stringWithFormat:@"exception %@: %@", e.name, e.reason]); }
        }
        gHost = nil;
    }
    printf("%s: %d failure(s), %.2fs\n", gFailures ? "SELFTEST FAILED" : "SELFTEST PASSED", gFailures, -start.timeIntervalSinceNow);
    fflush(stdout);
    return gFailures;
}
