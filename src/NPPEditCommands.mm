// NPPEditCommands.mm — Notepad++ Edit-menu text transforms on a ScintillaView (port of NppCommands.cpp IDM_EDIT_*,
// Notepad_plus.cpp doBlockComment/doStreamComment/convertCase/doTrim/wsTabConvert/removeDuplicateLines, Sorters.h).
#import "NPPEditCommands.h"
#import "NPPDocument.h"
#import "NPPFeatureProtocols.h"
#import "NPPPreferences.h"
#import "NPPSearchViewCommands.h"   // the shared indicator numbers (NPPIndicatorBeginEndSelect)
#import "NPPUtils.h"
#import <objc/runtime.h>
#include <algorithm>
#include <random>
#include <set>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

// The two private Cut/Copy tags must stay clear of every range NPPCommands.h declares; this catches the shared enum
// growing up into them. It cannot catch a *new* range declared above 13000 — that one is on whoever adds it.
static_assert(NPPCmdEditClipboardCut > NPPCmdSettingsUILanguageBase + 200,
              "NPPCmdEditClipboard* collides with a command range in NPPCommands.h");

// ---------------------------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------------------------

static NSString *NSStr(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
// Strict variant: nil when the bytes are not valid UTF-8, so callers that would otherwise write "" back into the
// document (deleting the user's text) can bail out instead.
static NSString *NSStrOrNil(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}
static std::string Utf8(NSString *s) { const char *c = s.UTF8String; return c ? std::string(c) : std::string(); }

static std::string EOLString(ScintillaView *ed) {
    switch (NPPSci(ed, SCI_GETEOLMODE)) {
        case SC_EOL_CRLF: return "\r\n";
        case SC_EOL_CR:   return "\r";
        default:          return "\n";
    }
}

static void ReplaceRange(ScintillaView *ed, sptr_t start, sptr_t end, const std::string &text) {
    NPPSci(ed, SCI_SETTARGETRANGE, (uptr_t)start, end);
    NPPSci(ed, SCI_REPLACETARGET, (uptr_t)text.size(), (sptr_t)text.data());
}

// Lines touched by the main selection, extended to whole lines. Selection ending at column 0 excludes that line.
// wholeDocIfEmpty: no selection -> whole document, else current line only.
struct LineBlock { sptr_t first, last, start, end; bool hadSelection; };
static LineBlock BlockForSelection(ScintillaView *ed, bool wholeDocIfEmpty) {
    LineBlock b{};
    sptr_t selStart = NPPSci(ed, SCI_GETSELECTIONSTART), selEnd = NPPSci(ed, SCI_GETSELECTIONEND);
    sptr_t lineCount = NPPSci(ed, SCI_GETLINECOUNT), docLen = NPPSci(ed, SCI_GETLENGTH);
    b.hadSelection = selStart != selEnd;
    if (!b.hadSelection && wholeDocIfEmpty) { b.first = 0; b.last = lineCount - 1; }
    else {
        b.first = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)selStart);
        b.last  = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)selEnd);
        if (b.hadSelection && b.last > b.first && selEnd == NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)b.last)) b.last--;
    }
    b.start = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)b.first);
    b.end = (b.last + 1 < lineCount) ? NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)(b.last + 1)) : docLen;
    return b;
}

// Split block text into lines (without EOLs). trailingEOL = text ended with an EOL.
static std::vector<std::string> SplitLines(const std::string &text, bool &trailingEOL) {
    std::vector<std::string> lines;
    size_t i = 0, n = text.size();
    trailingEOL = false;
    while (i < n) {
        size_t j = i;
        while (j < n && text[j] != '\n' && text[j] != '\r') j++;
        lines.emplace_back(text, i, j - i);
        if (j >= n) return lines;
        if (text[j] == '\r' && j + 1 < n && text[j + 1] == '\n') j++;
        i = j + 1;
        trailingEOL = (i >= n);
    }
    if (lines.empty()) lines.emplace_back();  // empty block = one empty line
    return lines;
}
static std::string JoinLines(const std::vector<std::string> &lines, const std::string &eol, bool trailingEOL) {
    size_t total = 0;
    for (auto &l : lines) total += l.size() + eol.size();
    std::string out; out.reserve(total);
    for (size_t i = 0; i < lines.size(); i++) {
        out += lines[i];
        if (i + 1 < lines.size() || trailingEOL) out += eol;
    }
    return out;
}

// Apply a per-block transform: fetch text of the touched lines, transform, write back, restore a sensible selection.
// ponytail: mixed EOLs inside the block are normalised to the document EOL mode (N++ sort does the same).
static void RewriteBlock(ScintillaView *ed, bool wholeDocIfEmpty,
                         void (^transform)(std::vector<std::string> &lines, bool &trailingEOL)) {
    LineBlock b = BlockForSelection(ed, wholeDocIfEmpty);
    std::string text = NPPSciGetRange(ed, b.start, b.end);
    bool trailingEOL = false;
    std::vector<std::string> lines = SplitLines(text, trailingEOL);
    transform(lines, trailingEOL);
    std::string out = JoinLines(lines, EOLString(ed), trailingEOL);
    if (out == text) return;
    sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    NPPSci(ed, SCI_BEGINUNDOACTION);
    ReplaceRange(ed, b.start, b.end, out);
    NPPSci(ed, SCI_ENDUNDOACTION);
    if (b.hadSelection) NPPSci(ed, SCI_SETSEL, (uptr_t)b.start, b.start + (sptr_t)out.size());
    else NPPSci(ed, SCI_GOTOPOS, (uptr_t)std::min(caret, (sptr_t)NPPSci(ed, SCI_GETLENGTH)));
}

static bool IsBlank(const std::string &s) { return s.find_first_not_of(" \t") == std::string::npos; }

// ---------------------------------------------------------------------------------------------------------------
// Edit-menu commands that need more than the editor: the file on disk, the tab set, a host window for a sheet.
// This module is dispatched as +performCommand:onEditor:language: (no context argument), so it picks the context up
// from the documented NPPCommandContextReadyNotification seam and keeps a weak reference.
// ---------------------------------------------------------------------------------------------------------------

static NSPasteboardType const kBinaryPasteboardType = @"org.notepad-plus-plus.mac.binary-content";
// N++ names its Preferences pages and jumps straight to one; IDM_EDIT_CHANGESEARCHENGINE is exactly that jump.
static NSString *const kSearchEnginePage = @"Search Engine";

static __weak id<NPPCommandContext> gContext = nil;

static NPPDocument *DocumentForEditor(ScintillaView *editor) {
    for (NPPDocument *d in [gContext contextOpenDocuments]) if (d.editor == editor) return d;
    return nil;
}

// The edit view holding the keyboard focus, or nil for anything else. Scintilla's first responder is its inner
// content view, so walk up to the ScintillaView; a Scintilla that is not an open document's editor (document map,
// search results) is not "the editor" either — N++ hands those to their own WM_COPY too.
static ScintillaView *FocusedEditView(void) {
    NSResponder *r = NSApp.keyWindow.firstResponder;
    NSView *v = [r isKindOfClass:NSView.class] ? (NSView *)r : nil;
    while (v && ![v isKindOfClass:ScintillaView.class]) v = v.superview;
    ScintillaView *sv = (ScintillaView *)v;
    return (sv && DocumentForEditor(sv)) ? sv : nil;
}

// Whether the responder chain would enable a standard Cut/Copy right now — asked with a throwaway item carrying the
// standard selector, because a text field answers for cut:/copy: and would wave through the unknown -nppCommand:.
// Order is AppKit's own: a menu item asks validateMenuItem: first and only falls back to validateUserInterfaceItem:,
// so a responder that implements both is asked the same question the real menu would have asked it.
static BOOL ResponderCanPerformStandard(SEL sel) {
    NSMenuItem *probe = [[NSMenuItem alloc] initWithTitle:@"" action:sel keyEquivalent:@""];
    id target = [NSApp targetForAction:sel to:nil from:probe];
    if (!target) return NO;
    if ([target respondsToSelector:@selector(validateMenuItem:)]) return [target validateMenuItem:probe];
    if ([target respondsToSelector:@selector(validateUserInterfaceItem:)]) return [target validateUserInterfaceItem:probe];
    return YES;
}

// The clipboard flavours N++ pastes as text (CF_HTML/CF_RTF) are byte blobs, not necessarily UTF-8.
static NSString *DecodeClipboardText(NSData *data) {
    if (!data.length) return nil;
    NSString *s = nil;
    [NSString stringEncodingForData:data encodingOptions:nil convertedString:&s usedLossyConversion:NULL];
    return s ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

// N++ IDM_EDIT_REDACT_SELECTION: one mask symbol per *character*, CR/LF kept so the selection keeps its shape.
static std::string RedactMask(const std::string &src, const std::string &symbol, bool utf8) {
    std::string out;
    out.reserve(src.size() * symbol.size());
    for (unsigned char c : src) {
        if (c == '\r' || c == '\n') { out += (char)c; continue; }
        if (utf8 && (c & 0xC0) == 0x80) continue;   // continuation byte: its character is already masked
        out += symbol;
    }
    return out;
}

// Non-empty selection ranges, highest position first, so replacing one never moves the next.
static std::vector<std::pair<sptr_t, sptr_t>> SelectionRanges(ScintillaView *ed) {
    std::vector<std::pair<sptr_t, sptr_t>> ranges;
    sptr_t n = NPPSci(ed, SCI_GETSELECTIONS);
    for (sptr_t i = 0; i < n; i++) {
        sptr_t a = NPPSci(ed, SCI_GETSELECTIONNSTART, (uptr_t)i), b = NPPSci(ed, SCI_GETSELECTIONNEND, (uptr_t)i);
        if (a != b) ranges.emplace_back(std::min(a, b), std::max(a, b));
    }
    std::sort(ranges.begin(), ranges.end(), [](auto &x, auto &y) { return x.first > y.first; });
    return ranges;
}

// The one selection "Open Selected File" / "Search on Internet" read, or nil when it cannot be either: a
// multi-selection or column mode (N++ returns early on SCI_GETSELECTIONS != 1), an empty selection, bytes that are not
// text at all, or something longer than a path or a search term ever is (N++ caps both at CURRENTWORD_MAXLENGTH 2048).
// The cap is what keeps -canPerformCommand: cheap: it runs for every Edit-menu item every time the menu opens, so
// without it selecting a 100 MB log would copy that log three times per menu click.
static NSString *SingleSelectionForLookup(ScintillaView *ed) {
    if (NPPSci(ed, SCI_GETSELECTIONS) != 1) return nil;
    sptr_t a = NPPSci(ed, SCI_GETSELECTIONSTART), b = NPPSci(ed, SCI_GETSELECTIONEND);
    if (a == b || b - a > 2048) return nil;
    return NSStrOrNil(NPPSciGetRange(ed, a, b));
}

// Run an alert as a sheet on the host window when there is one (an automated run must never block on runModal).
static void RunAlert(NSAlert *alert, void (^done)(NSModalResponse)) {
    NSWindow *host = [gContext contextWindow];
    if (host) [alert beginSheetModalForWindow:host completionHandler:done];
    else done([alert runModal]);
}

// ---------------------------------------------------------------------------------------------------------------
// Case conversion (Notepad_plus::convertCase / doProperCase), Unicode aware via NSString
// ---------------------------------------------------------------------------------------------------------------

static UTF32Char FirstScalar(NSString *s) {
    unichar c = [s characterAtIndex:0];
    if (CFStringIsSurrogateHighCharacter(c) && s.length > 1) return CFStringGetLongCharacterForSurrogatePair(c, [s characterAtIndex:1]);
    return c;
}
static bool IsLetter(NSString *g) { return [NSCharacterSet.letterCharacterSet longCharacterIsMember:FirstScalar(g)]; }
static bool IsAlnum(NSString *g) { return [NSCharacterSet.alphanumericCharacterSet longCharacterIsMember:FirstScalar(g)]; }

static NSString *ConvertCaseString(NPPCmd cmd, NSString *in) {
    switch (cmd) {
        case NPPCmdEditUpperCase: return in.uppercaseString;
        case NPPCmdEditLowerCase: return in.lowercaseString;
        default: break;
    }
    NSMutableString *out = [NSMutableString stringWithCapacity:in.length];
    __block bool wordStart = true, sentenceStart = true;
    static std::mt19937 rng{std::random_device{}()};
    [in enumerateSubstringsInRange:NSMakeRange(0, in.length) options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString *g, NSRange, NSRange, BOOL *) {
        bool letter = IsLetter(g), alnum = IsAlnum(g);
        NSString *r = g;
        switch (cmd) {
            case NPPCmdEditProperCase:
            case NPPCmdEditProperCaseBlend:
                if (letter && wordStart) r = g.uppercaseString;
                else if (letter && cmd == NPPCmdEditProperCase) r = g.lowercaseString;
                wordStart = !alnum;
                break;
            case NPPCmdEditSentenceCase:
            case NPPCmdEditSentenceCaseBlend:
                if (letter && sentenceStart) r = g.uppercaseString;
                else if (letter && cmd == NPPCmdEditSentenceCase) r = g.lowercaseString;
                if (alnum) sentenceStart = false;
                else if ([g isEqualToString:@"."] || [g isEqualToString:@"!"] || [g isEqualToString:@"?"]) sentenceStart = true;
                break;
            case NPPCmdEditInvertCase:
                if (letter) {
                    NSString *up = g.uppercaseString;
                    r = [g isEqualToString:up] ? g.lowercaseString : up;
                }
                break;
            case NPPCmdEditRandomCase:
                if (letter) r = (rng() & 1) ? g.uppercaseString : g.lowercaseString;
                break;
            default: break;
        }
        [out appendString:r];
    }];
    return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Sorting (MISC/Common/Sorters.h)
// ---------------------------------------------------------------------------------------------------------------

struct SortKey {
    std::string s;
    NSString *ns;
    bool hasNum = false;
    long long ival = 0;
    double dval = 0;
};

static void ParseNumber(SortKey &k, bool integer, char decimalSep) {
    std::string_view v(k.s);
    size_t i = v.find_first_not_of(" \t");
    if (i == std::string_view::npos) return;
    v.remove_prefix(i);
    std::string num;
    size_t j = 0;
    if (j < v.size() && (v[j] == '-' || v[j] == '+')) num += v[j++];
    size_t digitsStart = num.size();
    while (j < v.size() && isdigit((unsigned char)v[j])) num += v[j++];
    if (!integer && j < v.size() && v[j] == decimalSep) {
        num += '.'; j++;
        while (j < v.size() && isdigit((unsigned char)v[j])) num += v[j++];
    }
    if (num.size() == digitsStart || (num.size() == digitsStart + 1 && num.back() == '.')) return;  // no digits
    k.hasNum = true;
    if (integer) k.ival = strtoll(num.c_str(), nullptr, 10);
    else k.dval = NSStr(num).doubleValue;  // locale independent
}

static void SortLineVector(std::vector<std::string> &lines, NPPCmd cmd) {
    bool desc = cmd >= NPPCmdEditSortLexDesc;
    NPPCmd kind = desc ? (NPPCmd)(cmd - (NPPCmdEditSortLexDesc - NPPCmdEditSortLexAsc)) : cmd;
    std::vector<SortKey> keys(lines.size());
    for (size_t i = 0; i < lines.size(); i++) {
        keys[i].s = std::move(lines[i]);
        switch (kind) {
            case NPPCmdEditSortLexCaseInsAsc:
            case NPPCmdEditSortLocaleAsc: keys[i].ns = NSStr(keys[i].s); break;
            case NPPCmdEditSortIntAsc: ParseNumber(keys[i], true, 0); break;
            case NPPCmdEditSortDecCommaAsc: ParseNumber(keys[i], false, ','); break;
            case NPPCmdEditSortDecDotAsc: ParseNumber(keys[i], false, '.'); break;
            default: break;
        }
    }
    auto less = [kind](const SortKey &a, const SortKey &b) -> bool {
        switch (kind) {
            case NPPCmdEditSortLexCaseInsAsc: {
                NSComparisonResult r = [a.ns caseInsensitiveCompare:b.ns];
                return r != NSOrderedSame ? r == NSOrderedAscending : a.s < b.s;
            }
            case NPPCmdEditSortLocaleAsc: {
                NSComparisonResult r = [a.ns localizedStandardCompare:b.ns];
                return r != NSOrderedSame ? r == NSOrderedAscending : a.s < b.s;
            }
            case NPPCmdEditSortIntAsc:
                if (a.hasNum != b.hasNum) return a.hasNum;      // lines without a number sort after numbers
                return a.hasNum ? a.ival < b.ival : false;      // keep original order among non-numeric (stable)
            case NPPCmdEditSortDecCommaAsc:
            case NPPCmdEditSortDecDotAsc:
                if (a.hasNum != b.hasNum) return a.hasNum;
                return a.hasNum ? a.dval < b.dval : false;
            case NPPCmdEditSortLengthAsc:
                return a.s.size() != b.s.size() ? a.s.size() < b.s.size() : a.s < b.s;
            default: return a.s < b.s;
        }
    };
    // Descending reverses the comparator, but non-numeric lines still go after the numbers (N++ NumericSorter).
    if (desc) std::stable_sort(keys.begin(), keys.end(), [&](const SortKey &a, const SortKey &b) {
        if (a.hasNum != b.hasNum) return a.hasNum;
        return less(b, a);
    });
    else std::stable_sort(keys.begin(), keys.end(), less);
    for (size_t i = 0; i < lines.size(); i++) lines[i] = std::move(keys[i].s);
}

// ---------------------------------------------------------------------------------------------------------------
// Whitespace (doTrim / wsTabConvert)
// ---------------------------------------------------------------------------------------------------------------

static void TrimLine(std::string &l, bool leading, bool trailing) {
    if (trailing) { size_t e = l.find_last_not_of(" \t"); l.erase(e == std::string::npos ? 0 : e + 1); }
    if (leading) { size_t s = l.find_first_not_of(" \t"); l.erase(0, s == std::string::npos ? l.size() : s); }
}

static std::string TabsToSpaces(const std::string &l, int tabWidth) {
    std::string out; out.reserve(l.size() + 8);
    long col = 0;
    for (unsigned char c : l) {
        if (c == '\t') { int n = tabWidth - (int)(col % tabWidth); out.append((size_t)n, ' '); col += n; }
        else { out += (char)c; if ((c & 0xC0) != 0x80) col++; }  // count UTF-8 code points as one column
    }
    return out;
}

// Runs of spaces that reach a tab stop become one tab. leadingOnly: stop at the first non-blank character.
static std::string SpacesToTabs(const std::string &l, int tabWidth, bool leadingOnly) {
    std::string out; out.reserve(l.size());
    long col = 0; size_t pendingSpaces = 0; bool inIndent = true;
    auto flushSpaces = [&] { out.append(pendingSpaces, ' '); pendingSpaces = 0; };
    for (size_t i = 0; i < l.size(); i++) {
        unsigned char c = (unsigned char)l[i];
        if (c == ' ' && (inIndent || !leadingOnly)) {
            pendingSpaces++; col++;
            if (col % tabWidth == 0) { out += '\t'; pendingSpaces = 0; }
            continue;
        }
        flushSpaces();
        if (c == '\t') { col += tabWidth - (col % tabWidth); out += '\t'; continue; }
        inIndent = false;
        if (leadingOnly) { out.append(l, i, std::string::npos); return out; }
        out += (char)c;
        if ((c & 0xC0) != 0x80) col++;
    }
    flushSpaces();
    return out;
}

// ---------------------------------------------------------------------------------------------------------------
// NPPEditCommands
// ---------------------------------------------------------------------------------------------------------------

@interface NPPEditCommands ()
+ (NSURL *)selectedFileURLForEditor:(ScintillaView *)editor;
+ (BOOL)pasteFlavour:(NSPasteboardType)type fromPasteboard:(NSPasteboard *)pasteboard intoEditor:(ScintillaView *)editor;
+ (void)searchSelectionOnInternet:(ScintillaView *)editor;
+ (void)insertCustomDateTime:(ScintillaView *)editor;
+ (void)showColumnModeTip;
+ (BOOL)toggleFileReadOnlyAttributeForEditor:(ScintillaView *)editor;
@end

static const void *kBeginSelectKey = &kBeginSelectKey;      // NSNumber anchor position; nil = not started
static const void *kBeginSelectCmdKey = &kBeginSelectCmdKey; // which of the two Begin/End Select variants started it

static void InstallColumnSelectionKeyMonitor(void);         // defined beside the command it belongs to, below

@implementation NPPEditCommands

+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NPPCommandContextReadyNotification object:nil queue:nil
                                               usingBlock:^(NSNotification *note) {
        gContext = (id<NPPCommandContext>)note.object;
        InstallColumnSelectionKeyMonitor();
    }];
}

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    switch (cmd) {
        case (NPPCmd)NPPCmdEditClipboardCut: case (NPPCmd)NPPCmdEditClipboardCopy:
        case NPPCmdEditDelete: case NPPCmdEditBeginEndSelect:
        case NPPCmdEditInsertDateTimeShort: case NPPCmdEditInsertDateTimeLong:
        case NPPCmdEditIndent: case NPPCmdEditUnindent:
        case NPPCmdEditAutoCompleteWord:
            return YES;
        default:
            return (cmd >= NPPCmdEditUpperCase && cmd <= NPPCmdEditBlockUncomment)
                || (cmd >= NPPCmdEditTrimTrailing && cmd <= NPPCmdEditMultiSelectSkip)
                || (cmd >= NPPCmdEditPasteHTML && cmd <= NPPCmdEditToggleFileReadOnlyAttribute);
    }
}

static BOOL IsMutating(NPPCmd cmd) {
    switch (cmd) {
        case NPPCmdEditCopyBinary: case NPPCmdEditOpenSelectedFile: case NPPCmdEditOpenSelectedFileFolder:
        case NPPCmdEditSearchOnInternet: case NPPCmdEditChangeSearchEngine: case NPPCmdEditColumnModeTip:
        case NPPCmdEditBeginEndSelectColumn:
        case NPPCmdEditToggleFileReadOnlyAttribute:   // changes the file's permissions, not the buffer
        case NPPCmdEditBeginEndSelect: case NPPCmdEditAutoCompleteWord:
        case NPPCmdEditMultiSelectAll: case NPPCmdEditMultiSelectAllMatchCase: case NPPCmdEditMultiSelectAllWholeWord:
        case NPPCmdEditMultiSelectAllMatchCaseWholeWord: case NPPCmdEditMultiSelectNext: case NPPCmdEditMultiSelectNextMatchCase:
        case NPPCmdEditMultiSelectNextWholeWord: case NPPCmdEditMultiSelectNextMatchCaseWholeWord:
        case NPPCmdEditMultiSelectUndo: case NPPCmdEditMultiSelectSkip:
            return NO;
        default: return YES;
    }
}
static BOOL IsCommentCmd(NPPCmd cmd) { return cmd >= NPPCmdEditToggleLineComment && cmd <= NPPCmdEditBlockUncomment; }
static BOOL IsCaseCmd(NPPCmd cmd) { return cmd >= NPPCmdEditUpperCase && cmd <= NPPCmdEditRandomCase; }
static BOOL IsSortCmd(NPPCmd cmd) { return cmd >= NPPCmdEditSortLexAsc && cmd <= NPPCmdEditSortLengthDesc; }
static BOOL IsMultiSelectCmd(NPPCmd cmd) { return cmd >= NPPCmdEditMultiSelectAll && cmd <= NPPCmdEditMultiSelectSkip; }

+ (BOOL)canPerformCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor language:(NPPLanguage *)language {
    // Cut/Copy answer for whatever holds the focus, which is often not this editor — and Copy stays live on a
    // read-only buffer — so they run before the !editor and IsMutating guards below.
    if (cmd == (NPPCmd)NPPCmdEditClipboardCut || cmd == (NPPCmd)NPPCmdEditClipboardCopy)
        return [self canPerformClipboardCommand:cmd];
    if (![self handlesCommand:cmd] || !editor) return NO;
    if (IsMutating(cmd) && NPPSci(editor, SCI_GETREADONLY)) return NO;
    if (IsCommentCmd(cmd)) {
        BOOL hasLine = language.commentLine.length > 0, hasBlock = language.commentStart.length > 0 && language.commentEnd.length > 0;
        if (cmd == NPPCmdEditBlockComment || cmd == NPPCmdEditBlockUncomment) return hasBlock;
        return hasLine || hasBlock;
    }
    if (cmd == NPPCmdEditMultiSelectUndo || cmd == NPPCmdEditMultiSelectSkip) return NPPSci(editor, SCI_GETSELECTIONS) > 1 || cmd == NPPCmdEditMultiSelectSkip;

    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    switch (cmd) {
        // ---- Paste Special ----
        case NPPCmdEditPasteHTML: return [pb availableTypeFromArray:@[NSPasteboardTypeHTML]] != nil;
        case NPPCmdEditPasteRTF:  return [pb availableTypeFromArray:@[NSPasteboardTypeRTF]] != nil;
        case NPPCmdEditCopyBinary:
        case NPPCmdEditCutBinary: return !NPPSci(editor, SCI_GETSELECTIONEMPTY);
        case NPPCmdEditPasteBinary:
            return [pb availableTypeFromArray:@[kBinaryPasteboardType, NSPasteboardTypeString]] != nil;

        // ---- On Selection ----
        case NPPCmdEditOpenSelectedFile:
        case NPPCmdEditOpenSelectedFileFolder: {
            NSURL *url = [self selectedFileURLForEditor:editor];
            if (!url) return NO;
            // "Open File" needs a file; "Open Containing Folder" is happy to reveal a directory too.
            NSNumber *isDir = nil;
            if (![url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil]) return NO;   // does not exist
            return cmd == NPPCmdEditOpenSelectedFileFolder || !isDir.boolValue;
        }
        case NPPCmdEditRedactSelection: return !NPPSci(editor, SCI_GETSELECTIONEMPTY);
        // A custom engine URL that cannot be turned into a link leaves the item disabled rather than beeping.
        case NPPCmdEditSearchOnInternet: {
            NSString *term = SingleSelectionForLookup(editor);
            return term != nil && [NPPPreferences.shared searchEngineURLForTerm:term] != nil;
        }
        // Same for an unusable date format: disabled, never a menu item that inserts nothing.
        case NPPCmdEditInsertDateTimeCustom: return [NPPPreferences.shared formattedDateTimeNowCustom].length > 0;
        case NPPCmdEditChangeSearchEngine: case NPPCmdEditColumnModeTip: return YES;

        // ---- Begin/End Select ----
        // N++ greys out the other variant while one of the two is waiting for its second invocation, so a selection
        // started in stream mode cannot be finished in column mode.
        case NPPCmdEditBeginEndSelect:
        case NPPCmdEditBeginEndSelectColumn: {
            NSNumber *started = objc_getAssociatedObject(editor, kBeginSelectCmdKey);
            return started == nil || started.integerValue == cmd;
        }

        // ---- Read-only attribute of the file on disk ----
        case NPPCmdEditToggleFileReadOnlyAttribute: {
            NSString *path = DocumentForEditor(editor).fileURL.path;
            return path != nil && [NSFileManager.defaultManager fileExistsAtPath:path];
        }
        default: return YES;
    }
}

+ (BOOL)performCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor language:(NPPLanguage *)language {
    if (cmd == (NPPCmd)NPPCmdEditClipboardCut || cmd == (NPPCmd)NPPCmdEditClipboardCopy) {
        [self performClipboardCommand:cmd sender:nil];   // reads the focus itself; `editor` may not be the focused one
        return YES;
    }
    if (![self handlesCommand:cmd]) return NO;
    if (!editor) return YES;
    if (IsMutating(cmd) && NPPSci(editor, SCI_GETREADONLY)) { NSBeep(); return YES; }

    if (IsCaseCmd(cmd)) { [self convertCase:cmd onEditor:editor]; return YES; }
    if (IsSortCmd(cmd)) { [self sortLines:cmd onEditor:editor]; return YES; }
    if (IsMultiSelectCmd(cmd)) { [self multiSelect:cmd onEditor:editor]; return YES; }

    switch (cmd) {
        case NPPCmdEditDelete: NPPSci(editor, SCI_CLEAR); break;
        case NPPCmdEditIndent: NPPSci(editor, SCI_TAB); break;
        case NPPCmdEditUnindent: NPPSci(editor, SCI_BACKTAB); break;
        case NPPCmdEditInsertDateTimeShort: [self insertDateTime:editor longFormat:NO]; break;
        case NPPCmdEditInsertDateTimeLong: [self insertDateTime:editor longFormat:YES]; break;
        case NPPCmdEditAutoCompleteWord: [self wordCompletion:editor]; break;

        case NPPCmdEditBeginEndSelect: [self beginOrEndSelect:editor column:NO]; break;
        case NPPCmdEditBeginEndSelectColumn: [self beginOrEndSelect:editor column:YES]; break;

        // ---- Paste Special (NppCommands.cpp IDM_EDIT_PASTE_AS_HTML/_RTF, _COPY/_CUT/_PASTE_BINARY) ----
        case NPPCmdEditPasteHTML:
            [self pasteFlavour:NSPasteboardTypeHTML fromPasteboard:NSPasteboard.generalPasteboard intoEditor:editor]; break;
        case NPPCmdEditPasteRTF:
            [self pasteFlavour:NSPasteboardTypeRTF fromPasteboard:NSPasteboard.generalPasteboard intoEditor:editor]; break;
        case NPPCmdEditCopyBinary:
        case NPPCmdEditCutBinary:
            [self copyBinaryFromEditor:editor toPasteboard:NSPasteboard.generalPasteboard cut:cmd == NPPCmdEditCutBinary];
            break;
        case NPPCmdEditPasteBinary:
            [self pasteBinaryIntoEditor:editor fromPasteboard:NSPasteboard.generalPasteboard];
            break;

        // ---- On Selection ----
        case NPPCmdEditOpenSelectedFile:
        case NPPCmdEditOpenSelectedFileFolder: {
            NSURL *url = [self selectedFileURLForEditor:editor];
            if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) { NSBeep(); break; }
            if (cmd == NPPCmdEditOpenSelectedFileFolder) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
            else [gContext contextOpenFileURL:url];
            break;
        }
        case NPPCmdEditRedactSelection: {
            // N++ picks the bullet instead of the block while Shift is held (upstream reads GetKeyState(VK_SHIFT)).
            BOOL bullet = (NSEvent.modifierFlags & NSEventModifierFlagShift) != 0;
            BOOL utf8 = NPPSci(editor, SCI_GETCODEPAGE) == SC_CP_UTF8;
            NSString *symbol = utf8 ? (bullet ? @"●" : @"█") : (bullet ? @"." : @"#");
            [self redactSelectionsOnEditor:editor symbol:symbol];
            break;
        }
        case NPPCmdEditSearchOnInternet: [self searchSelectionOnInternet:editor]; break;
        // N++: command(IDM_SETTING_PREFERENCE) + showDialogByName("SearchEngine") — the page *is* the dialog.
        case NPPCmdEditChangeSearchEngine: [NPPPreferences showPreferencesPageNamed:kSearchEnginePage]; break;

        case NPPCmdEditInsertDateTimeCustom: [self insertCustomDateTime:editor]; break;
        case NPPCmdEditColumnModeTip: [self showColumnModeTip]; break;
        case NPPCmdEditToggleFileReadOnlyAttribute: [self toggleFileReadOnlyAttributeForEditor:editor]; break;

        // ---- line operations ----
        case NPPCmdEditDuplicateLine: NPPSci(editor, SCI_LINEDUPLICATE); break;   // N++ duplicates the line, never the selection
        case NPPCmdEditMoveLineUp: NPPSci(editor, SCI_MOVESELECTEDLINESUP); break;
        case NPPCmdEditMoveLineDown: NPPSci(editor, SCI_MOVESELECTEDLINESDOWN); break;
        case NPPCmdEditJoinLines:
        case NPPCmdEditSplitLines: {
            NPPSci(editor, SCI_BEGINUNDOACTION);
            if (NPPSci(editor, SCI_GETSELECTIONEMPTY)) {
                sptr_t line = NPPSci(editor, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(editor, SCI_GETCURRENTPOS));
                sptr_t endLine = (cmd == NPPCmdEditJoinLines && line + 1 < NPPSci(editor, SCI_GETLINECOUNT)) ? line + 1 : line;
                NPPSci(editor, SCI_SETTARGETRANGE, (uptr_t)NPPSci(editor, SCI_POSITIONFROMLINE, (uptr_t)line),
                       NPPSci(editor, SCI_GETLINEENDPOSITION, (uptr_t)endLine));
            } else {
                LineBlock b = BlockForSelection(editor, false);
                NPPSci(editor, SCI_SETTARGETRANGE, (uptr_t)b.start, NPPSci(editor, SCI_GETLINEENDPOSITION, (uptr_t)b.last));
            }
            // ponytail: split uses pixel width 0 = current window width (N++ does the same).
            NPPSci(editor, cmd == NPPCmdEditJoinLines ? SCI_LINESJOIN : SCI_LINESSPLIT, 0);
            NPPSci(editor, SCI_ENDUNDOACTION);
            break;
        }
        case NPPCmdEditInsertBlankLineAbove:
        case NPPCmdEditInsertBlankLineBelow: {
            sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
            sptr_t line = NPPSci(editor, SCI_LINEFROMPOSITION, (uptr_t)caret);
            std::string eol = EOLString(editor);
            sptr_t at = cmd == NPPCmdEditInsertBlankLineAbove ? NPPSci(editor, SCI_POSITIONFROMLINE, (uptr_t)line)
                                                              : NPPSci(editor, SCI_GETLINEENDPOSITION, (uptr_t)line);
            NPPSci(editor, SCI_BEGINUNDOACTION);
            NPPSciStr(editor, SCI_INSERTTEXT, (uptr_t)at, eol.c_str());
            NPPSci(editor, SCI_ENDUNDOACTION);
            // N++ insertNewLineAbove/BelowCurrentLine: the caret lands on the new blank line.
            sptr_t newLine = cmd == NPPCmdEditInsertBlankLineAbove ? line : line + 1;
            NPPSci(editor, SCI_SETEMPTYSELECTION, (uptr_t)NPPSci(editor, SCI_POSITIONFROMLINE, (uptr_t)newLine));
            break;
        }
        case NPPCmdEditRemoveDuplicateLines:
            RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &) {
                std::unordered_set<std::string> seen;   // owning copies: a string_view into a moved-from SSO string dangles
                std::vector<std::string> out; out.reserve(lines.size());
                for (auto &l : lines) if (seen.insert(l).second) out.push_back(l);
                lines = std::move(out);
            });
            break;
        case NPPCmdEditRemoveConsecutiveDuplicateLines:
            RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &) {
                lines.erase(std::unique(lines.begin(), lines.end()), lines.end());
            });
            break;
        case NPPCmdEditRemoveEmptyLines:
        case NPPCmdEditRemoveEmptyLinesWithBlank: {
            BOOL blank = cmd == NPPCmdEditRemoveEmptyLinesWithBlank;
            RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &) {
                lines.erase(std::remove_if(lines.begin(), lines.end(), [blank](const std::string &l) {
                    return blank ? IsBlank(l) : l.empty();
                }), lines.end());
                if (lines.empty()) lines.emplace_back();
            });
            break;
        }
        case NPPCmdEditReverseLineOrder:
            RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &) { std::reverse(lines.begin(), lines.end()); });
            break;
        case NPPCmdEditRandomizeLineOrder:
            RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &) {
                std::shuffle(lines.begin(), lines.end(), std::mt19937{std::random_device{}()});
            });
            break;

        // ---- comments ----
        case NPPCmdEditToggleLineComment: [self toggleLineComment:editor language:language set:0]; break;
        case NPPCmdEditLineComment: [self toggleLineComment:editor language:language set:1]; break;
        case NPPCmdEditLineUncomment: [self toggleLineComment:editor language:language set:-1]; break;
        case NPPCmdEditBlockComment: [self blockComment:editor language:language uncomment:NO]; break;
        case NPPCmdEditBlockUncomment: [self blockComment:editor language:language uncomment:YES]; break;

        // ---- whitespace ----
        case NPPCmdEditTrimTrailing: case NPPCmdEditTrimLeading: case NPPCmdEditTrimBoth:
        case NPPCmdEditEOLToSpace: case NPPCmdEditTrimAll: {
            bool leading = cmd == NPPCmdEditTrimLeading || cmd == NPPCmdEditTrimBoth || cmd == NPPCmdEditTrimAll;
            bool trailing = cmd == NPPCmdEditTrimTrailing || cmd == NPPCmdEditTrimBoth || cmd == NPPCmdEditTrimAll;
            bool eolToSpace = cmd == NPPCmdEditEOLToSpace || cmd == NPPCmdEditTrimAll;
            RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &trailingEOL) {
                for (auto &l : lines) TrimLine(l, leading, trailing);
                if (eolToSpace) {
                    std::string joined; size_t total = 0;
                    for (auto &l : lines) total += l.size() + 1;
                    joined.reserve(total);
                    for (size_t i = 0; i < lines.size(); i++) { joined += lines[i]; if (i + 1 < lines.size() || trailingEOL) joined += ' '; }
                    lines.assign(1, std::move(joined));
                    trailingEOL = false;
                }
            });
            break;
        }
        case NPPCmdEditTabToSpace:
        case NPPCmdEditSpaceToTabAll:
        case NPPCmdEditSpaceToTabLeading: {
            int tabWidth = (int)std::max<sptr_t>(1, NPPSci(editor, SCI_GETTABWIDTH));
            RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &) {
                for (auto &l : lines)
                    l = cmd == NPPCmdEditTabToSpace ? TabsToSpaces(l, tabWidth) : SpacesToTabs(l, tabWidth, cmd == NPPCmdEditSpaceToTabLeading);
            });
            break;
        }
        default: return NO;
    }
    return YES;
}

// ---------------------------------------------------------------------------------------------------------------

+ (void)convertCase:(NPPCmd)cmd onEditor:(ScintillaView *)editor {
    if (!editor || NPPSci(editor, SCI_GETREADONLY)) { NSBeep(); return; }
    std::vector<std::pair<sptr_t, sptr_t>> ranges = SelectionRanges(editor);   // already back to front: no drift
    sptr_t n = NPPSci(editor, SCI_GETSELECTIONS);
    bool wordMode = ranges.empty();
    if (wordMode) {  // N++: no selection -> word under caret
        sptr_t pos = NPPSci(editor, SCI_GETCURRENTPOS);
        sptr_t a = NPPSci(editor, SCI_WORDSTARTPOSITION, (uptr_t)pos, 1), b = NPPSci(editor, SCI_WORDENDPOSITION, (uptr_t)pos, 1);
        if (a == b) return;
        ranges.emplace_back(a, b);
    }
    sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
    NPPSci(editor, SCI_BEGINUNDOACTION);
    sptr_t newEnd = 0;
    for (auto &r : ranges) {
        std::string src = NPPSciGetRange(editor, r.first, r.second);
        NSString *srcStr = NSStrOrNil(src);
        // Bytes that are not valid UTF-8 (a mis-detected ANSI file, a binary blob) give a nil NSString; converting it
        // would replace the range with "" and silently delete the user's text. Leave such a range untouched.
        std::string dst = srcStr ? Utf8(ConvertCaseString(cmd, srcStr)) : src;
        if (dst != src) ReplaceRange(editor, r.first, r.second, dst);
        newEnd = r.first + (sptr_t)dst.size();
    }
    NPPSci(editor, SCI_ENDUNDOACTION);
    if (n == 1) {
        if (wordMode) NPPSci(editor, SCI_GOTOPOS, (uptr_t)std::min(caret, newEnd));
        else NPPSci(editor, SCI_SETSEL, (uptr_t)ranges[0].first, newEnd);
    }
    // ponytail: with multiple selections we rely on Scintilla adjusting selection positions around each replacement.
}

+ (void)sortLines:(NPPCmd)cmd onEditor:(ScintillaView *)editor {
    if (!editor || NPPSci(editor, SCI_GETREADONLY)) { NSBeep(); return; }
    RewriteBlock(editor, true, ^(std::vector<std::string> &lines, bool &) { SortLineVector(lines, cmd); });
}

+ (void)toggleLineComment:(ScintillaView *)editor language:(NPPLanguage *)lang set:(NSInteger)mode {
    if (!editor || NPPSci(editor, SCI_GETREADONLY)) { NSBeep(); return; }
    std::string token = lang.commentLine.length ? Utf8(lang.commentLine) : std::string();
    // N++ doBlockComment "advanced mode": a language with no line-comment symbol comments each line with the
    // stream symbols instead (/* line */). Uncommenting in that mode is delegated to undoStreamComment.
    bool advanced = token.empty();
    std::string advStart, advEnd;
    if (advanced) {
        if (lang.commentStart.length == 0 || lang.commentEnd.length == 0) { NSBeep(); return; }
        if (mode < 0) { [self blockComment:editor language:lang uncomment:YES]; return; }
        advStart = Utf8(lang.commentStart) + " ";
        advEnd = std::string(" ") + Utf8(lang.commentEnd);
    }
    LineBlock b = BlockForSelection(editor, false);
    sptr_t anchor = NPPSci(editor, SCI_GETANCHOR), caret = NPPSci(editor, SCI_GETCURRENTPOS);
    std::string insert = token + " ";
    sptr_t startLen = advanced ? (sptr_t)advStart.size() - 1 : 0;   // symbol length without the trailing space
    sptr_t endLen = advanced ? (sptr_t)advEnd.size() - 1 : 0;

    NPPSci(editor, SCI_BEGINUNDOACTION);
    for (sptr_t l = b.first; l <= b.last; l++) {   // positions are re-queried per line so earlier edits don't matter
        sptr_t ip = NPPSci(editor, SCI_GETLINEINDENTPOSITION, (uptr_t)l);
        sptr_t le = NPPSci(editor, SCI_GETLINEENDPOSITION, (uptr_t)l);
        if (ip >= le) continue;   // N++ never comments empty lines

        // Already commented? Case-insensitive like N++ (_strnicmp), so "REM"/"rem" both match in Batch files.
        bool commented = false;
        sptr_t headEnd = ip, tailStart = le;
        if (!advanced) {
            std::string head = NPPSciGetRange(editor, ip, std::min(le, ip + (sptr_t)token.size()));
            commented = head.size() == token.size() && strncasecmp(head.c_str(), token.c_str(), token.size()) == 0;
            if (commented) {
                headEnd = ip + (sptr_t)token.size();
                if (headEnd < le && NPPSci(editor, SCI_GETCHARAT, (uptr_t)headEnd) == ' ') headEnd++;   // one following space
            }
        } else if (le - ip >= startLen + endLen) {
            std::string head = NPPSciGetRange(editor, ip, ip + startLen);
            std::string tail = NPPSciGetRange(editor, le - endLen, le);
            commented = strncasecmp(head.c_str(), advStart.c_str(), (size_t)startLen) == 0 &&
                        strncasecmp(tail.c_str(), advEnd.c_str() + 1, (size_t)endLen) == 0;
            if (commented) {
                headEnd = ip + startLen;
                if (headEnd < le && NPPSci(editor, SCI_GETCHARAT, (uptr_t)headEnd) == ' ') headEnd++;
                tailStart = le - endLen;
                if (tailStart > headEnd && NPPSci(editor, SCI_GETCHARAT, (uptr_t)(tailStart - 1)) == ' ') tailStart--;
            }
        }

        if (mode < 0 && !commented) continue;               // "Single Line Uncomment": nothing to do here
        if (mode <= 0 && commented) {                       // toggle decides per line, exactly like N++
            if (tailStart < le) ReplaceRange(editor, tailStart, le, "");   // back to front: head offsets stay valid
            ReplaceRange(editor, ip, headEnd, "");
        } else {                                            // comment (mode > 0 always, toggle when not commented)
            if (advanced) NPPSciStr(editor, SCI_INSERTTEXT, (uptr_t)le, advEnd.c_str());
            NPPSciStr(editor, SCI_INSERTTEXT, (uptr_t)ip, advanced ? advStart.c_str() : insert.c_str());
        }
    }
    NPPSci(editor, SCI_ENDUNDOACTION);
    if (anchor != caret) {   // re-cover the whole block; with no selection Scintilla already moved the caret
        sptr_t newEnd = (b.last + 1 < NPPSci(editor, SCI_GETLINECOUNT)) ? NPPSci(editor, SCI_POSITIONFROMLINE, (uptr_t)(b.last + 1)) : NPPSci(editor, SCI_GETLENGTH);
        if (anchor < caret) NPPSci(editor, SCI_SETSEL, (uptr_t)b.start, newEnd); else NPPSci(editor, SCI_SETSEL, (uptr_t)newEnd, b.start);
    }
}

+ (void)blockComment:(ScintillaView *)editor language:(NPPLanguage *)lang uncomment:(BOOL)uncomment {
    if (!editor || NPPSci(editor, SCI_GETREADONLY)) { NSBeep(); return; }
    if (lang.commentStart.length == 0 || lang.commentEnd.length == 0) { NSBeep(); return; }
    std::string start = Utf8(lang.commentStart), end = Utf8(lang.commentEnd);
    sptr_t selStart = NPPSci(editor, SCI_GETSELECTIONSTART), selEnd = NPPSci(editor, SCI_GETSELECTIONEND);
    sptr_t docLen = NPPSci(editor, SCI_GETLENGTH);

    if (!uncomment) {  // doStreamComment
        if (selStart == selEnd) {   // N++ wraps the current line from its indentation to its end, not the word at the caret
            sptr_t line = NPPSci(editor, SCI_LINEFROMPOSITION, (uptr_t)selStart);
            selStart = NPPSci(editor, SCI_GETLINEINDENTPOSITION, (uptr_t)line);
            selEnd = NPPSci(editor, SCI_GETLINEENDPOSITION, (uptr_t)line);
            if (selStart >= selEnd) { NSBeep(); return; }
        }
        std::string s = start + " ", e = " " + end;
        NPPSci(editor, SCI_BEGINUNDOACTION);
        NPPSciStr(editor, SCI_INSERTTEXT, (uptr_t)selEnd, e.c_str());
        NPPSciStr(editor, SCI_INSERTTEXT, (uptr_t)selStart, s.c_str());
        NPPSci(editor, SCI_ENDUNDOACTION);
        NPPSci(editor, SCI_SETSEL, (uptr_t)(selStart + (sptr_t)s.size()), selEnd + (sptr_t)s.size());
        return;
    }

    // undoStreamComment — ponytail: nearest start token at/before the selection end, nearest end token after it.
    // N++ additionally handles several comment blocks partially inside the selection; the ceiling here is one block.
    NPPSci(editor, SCI_SETSEARCHFLAGS, 0);
    NPPSci(editor, SCI_SETTARGETRANGE, (uptr_t)std::min(docLen, selEnd + (sptr_t)start.size()), 0);  // reversed = search backwards
    sptr_t sPos = NPPSci(editor, SCI_SEARCHINTARGET, (uptr_t)start.size(), (sptr_t)start.data());
    if (sPos < 0) { NSBeep(); return; }
    sptr_t after = sPos + (sptr_t)start.size();
    NPPSci(editor, SCI_SETTARGETRANGE, (uptr_t)std::max(after, selStart), docLen);
    sptr_t ePos = NPPSci(editor, SCI_SEARCHINTARGET, (uptr_t)end.size(), (sptr_t)end.data());
    if (ePos < after) {
        NPPSci(editor, SCI_SETTARGETRANGE, (uptr_t)after, docLen);
        ePos = NPPSci(editor, SCI_SEARCHINTARGET, (uptr_t)end.size(), (sptr_t)end.data());
    }
    if (ePos < 0) { NSBeep(); return; }
    sptr_t eStart = ePos, eEnd = ePos + (sptr_t)end.size();
    if (eStart > after && NPPSci(editor, SCI_GETCHARAT, (uptr_t)(eStart - 1)) == ' ') eStart--;   // " */"
    sptr_t sEnd = after;
    if (sEnd < eStart && NPPSci(editor, SCI_GETCHARAT, (uptr_t)sEnd) == ' ') sEnd++;               // "/* "
    NPPSci(editor, SCI_BEGINUNDOACTION);
    ReplaceRange(editor, eStart, eEnd, "");
    ReplaceRange(editor, sPos, sEnd, "");
    NPPSci(editor, SCI_ENDUNDOACTION);
    NPPSci(editor, SCI_SETSEL, (uptr_t)sPos, eStart - (sEnd - sPos));
}

+ (void)insertDateTime:(ScintillaView *)editor longFormat:(BOOL)longFormat {
    if (!editor || NPPSci(editor, SCI_GETREADONLY)) { NSBeep(); return; }
    // N++ formats the two halves separately and concatenates them, so the order is its own choice rather than the
    // locale's: time then date (Microsoft Notepad's order), reversed to date then time by Preferences ▸
    // Multi-Instance & Date "Reverse the default date-time order".
    NSDate *now = [NSDate date];
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = NSLocale.currentLocale;
    f.dateStyle = longFormat ? NSDateFormatterLongStyle : NSDateFormatterShortStyle;
    f.timeStyle = NSDateFormatterNoStyle;
    NSString *date = [f stringFromDate:now];
    f.dateStyle = NSDateFormatterNoStyle;
    f.timeStyle = longFormat ? NSDateFormatterMediumStyle : NSDateFormatterShortStyle;
    NSString *time = [f stringFromDate:now];
    NSString *s = NPPPreferences.shared.dateTimeReverseDefaultOrder
        ? [NSString stringWithFormat:@"%@ %@", date, time]
        : [NSString stringWithFormat:@"%@ %@", time, date];
    NPPSci(editor, SCI_BEGINUNDOACTION);
    NPPSciStr(editor, SCI_REPLACESEL, 0, s.UTF8String);
    NPPSci(editor, SCI_ENDUNDOACTION);
}

// ---------------------------------------------------------------------------------------------------------------
// Cut / Copy (NppCommands.cpp IDM_EDIT_CUT / IDM_EDIT_COPY)
// ---------------------------------------------------------------------------------------------------------------

+ (NPPClipboardAction)clipboardActionForFocusedEditor:(ScintillaView *)editor {
    if (!editor) return NPPClipboardForward;
    if (!NPPSci(editor, SCI_GETSELECTIONEMPTY)) return NPPClipboardSelection;
    // Empty selection with the preference off: N++ does nothing at all, and so does SCI_COPY / SCI_CUT here.
    return NPPPreferences.shared.lineCopyCutWithoutSelection ? NPPClipboardWholeLine : NPPClipboardSelection;
}

// The messages each branch issues, split out from the focus lookup so the self-check can drive all three headlessly.
static void PerformClipboard(NPPClipboardAction action, BOOL cut, ScintillaView *ed, id sender) {
    switch (action) {
        case NPPClipboardForward:
            [NSApp sendAction:(cut ? @selector(cut:) : @selector(copy:)) to:nil from:sender];
            return;
        // Literally NppCommands.cpp's pair: SCI_COPYALLOWLINE puts the caret's line on the clipboard with its EOL,
        // SCI_LINEDELETE takes it out in one undo step. Not SCI_LINECUT, which selects the line *before* its
        // read-only check and so would leave a read-only buffer with the line selected and nothing copied.
        case NPPClipboardWholeLine:
            NPPSci(ed, SCI_COPYALLOWLINE);
            if (cut) NPPSci(ed, SCI_LINEDELETE);
            return;
        case NPPClipboardSelection: NPPSci(ed, cut ? SCI_CUT : SCI_COPY); return;
    }
}

+ (void)performClipboardCommand:(NPPCmd)cmd sender:(id)sender {
    BOOL cut = (cmd == (NPPCmd)NPPCmdEditClipboardCut);
    ScintillaView *ed = FocusedEditView();
    PerformClipboard([self clipboardActionForFocusedEditor:ed], cut, ed, sender);
}

+ (BOOL)canPerformClipboardCommand:(NPPCmd)cmd {
    BOOL cut = (cmd == (NPPCmd)NPPCmdEditClipboardCut);
    ScintillaView *ed = FocusedEditView();
    switch ([self clipboardActionForFocusedEditor:ed]) {
        // Exactly what the item's enablement was before it stopped using cut:/copy:: whatever the responder chain
        // says, and Scintilla's own HasSelection() when the editor is focused.
        case NPPClipboardForward:   return ResponderCanPerformStandard(cut ? @selector(cut:) : @selector(copy:));
        case NPPClipboardSelection: return !NPPSci(ed, SCI_GETSELECTIONEMPTY);
        case NPPClipboardWholeLine: return YES;   // the one case that is newly enabled: the line the caret is on
    }
}

+ (void)wordCompletion:(ScintillaView *)editor {
    if (!editor) return;
    sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
    sptr_t wordStart = NPPSci(editor, SCI_WORDSTARTPOSITION, (uptr_t)caret, 1);
    if (wordStart >= caret) return;
    std::string prefix = NPPSciGetRange(editor, wordStart, caret);
    // ponytail: word chars = ASCII alnum/_ plus any non-ASCII byte; single linear scan instead of std::regex (100MB safe).
    auto isWord = [](unsigned char c) { return isalnum(c) || c == '_' || c >= 0x80; };
    // ponytail: scan a 4 MB window around the caret rather than copying the whole buffer — a 100 MB log would
    // otherwise be duplicated in memory on every ⌃Space. Upgrade: SCI_GETCHARACTERPOINTER to scan in place.
    const sptr_t kWindow = 2 * 1024 * 1024;
    sptr_t length = NPPSci(editor, SCI_GETLENGTH);
    sptr_t from = MAX((sptr_t)0, caret - kWindow), to = MIN(length, caret + kWindow);
    std::string doc = NPPSciGetRange(editor, from, to);
    std::set<std::string> words;
    size_t i = 0, n = doc.size();
    while (i < n && words.size() < 1000) {
        if (!isWord((unsigned char)doc[i])) { i++; continue; }
        size_t j = i;
        while (j < n && isWord((unsigned char)doc[j])) j++;
        std::string_view w(doc.data() + i, j - i);
        if (w.size() > prefix.size() && w.compare(0, prefix.size(), prefix) == 0) words.emplace(w);
        i = j;
    }
    if (words.empty()) return;
    std::string list;
    for (auto &w : words) { if (!list.empty()) list += ' '; list += w; }
    NPPSci(editor, SCI_AUTOCSETSEPARATOR, ' ');
    NPPSci(editor, SCI_AUTOCSETIGNORECASE, 0);
    NPPSciStr(editor, SCI_AUTOCSHOW, (uptr_t)prefix.size(), list.c_str());
}

+ (void)multiSelect:(NPPCmd)cmd onEditor:(ScintillaView *)editor {
    if (!editor) return;
    sptr_t n = NPPSci(editor, SCI_GETSELECTIONS);
    if (cmd == NPPCmdEditMultiSelectUndo) {
        if (n > 1) NPPSci(editor, SCI_DROPSELECTIONN, (uptr_t)(n - 1));
        return;
    }
    if (cmd == NPPCmdEditMultiSelectSkip) {
        // N++: add next, then drop the previous main selection so the skipped occurrence is left unselected.
        NPPSci(editor, SCI_MULTIPLESELECTADDNEXT);
        sptr_t m = NPPSci(editor, SCI_GETSELECTIONS);
        if (m > n && m >= 2) NPPSci(editor, SCI_DROPSELECTIONN, (uptr_t)(m - 2));
        return;
    }
    int flags = 0;
    switch (cmd) {
        case NPPCmdEditMultiSelectAllMatchCase: case NPPCmdEditMultiSelectNextMatchCase: flags = SCFIND_MATCHCASE; break;
        case NPPCmdEditMultiSelectAllWholeWord: case NPPCmdEditMultiSelectNextWholeWord: flags = SCFIND_WHOLEWORD; break;
        case NPPCmdEditMultiSelectAllMatchCaseWholeWord: case NPPCmdEditMultiSelectNextMatchCaseWholeWord: flags = SCFIND_MATCHCASE | SCFIND_WHOLEWORD; break;
        default: break;
    }
    if (NPPSci(editor, SCI_GETSELECTIONEMPTY)) {
        sptr_t pos = NPPSci(editor, SCI_GETCURRENTPOS);
        sptr_t a = NPPSci(editor, SCI_WORDSTARTPOSITION, (uptr_t)pos, 1), b = NPPSci(editor, SCI_WORDENDPOSITION, (uptr_t)pos, 1);
        if (a == b) return;
        NPPSci(editor, SCI_SETSEL, (uptr_t)a, b);
    }
    NPPSci(editor, SCI_SETSEARCHFLAGS, (uptr_t)flags);
    NPPSci(editor, SCI_TARGETWHOLEDOCUMENT);
    BOOL all = cmd >= NPPCmdEditMultiSelectAll && cmd <= NPPCmdEditMultiSelectAllMatchCaseWholeWord;
    NPPSci(editor, all ? SCI_MULTIPLESELECTADDEACH : SCI_MULTIPLESELECTADDNEXT);
}

// ---------------------------------------------------------------------------------------------------------------
// Column selection -> multi-carets (N++ ScintillaEditView.cpp:795-833, the WM_KEYDOWN half of
// Preferences ▸ Editing 2 ▸ "Enable column selection to multi-editing" — the other half, typing into every
// selection, is NPPPreferences' SCI_SETADDITIONALSELECTIONTYPING).
// ---------------------------------------------------------------------------------------------------------------

// NSEvent hardware key codes (Carbon kVK_*), spelled out rather than importing Carbon for five constants.
enum : unsigned short {
    kKeyReturn = 0x24, kKeyEscape = 0x35, kKeyBackspace = 0x33, kKeypadEnter = 0x4C,
    kKeyHome = 0x73, kKeyEnd = 0x77,
    kKeyLeft = 0x7B, kKeyRight = 0x7C, kKeyDown = 0x7D, kKeyUp = 0x7E,
};

+ (BOOL)columnSelectionToMultiCaretsForKeyCode:(unsigned short)keyCode onEditor:(ScintillaView *)editor {
    if (!editor) return NO;
    NPPPreferences *p = NPPPreferences.shared;
    // Upstream gates on _columnSel2MultiEdit alone, but only offers it while multi-editing is on
    // (Parameters.cpp:7281); the port's Preferences page greys the checkbox the same way.
    if (!p.multiSelection || !p.columnSelectionToMultiEditing) return NO;
    sptr_t mode = NPPSci(editor, SCI_GETSELECTIONMODE);
    if (mode != SC_SEL_RECTANGLE && mode != SC_SEL_THIN) return NO;

    switch (keyCode) {
        case kKeyLeft: case kKeyRight: case kKeyUp: case kKeyDown:
        case kKeyHome: case kKeyEnd: case kKeyReturn: case kKeypadEnter: case kKeyBackspace:
            // Twice, deliberately: SCI_SETSELECTIONMODE also toggles "moving extends the selection", so the second
            // call is what drops the rectangle's selection as the carets move. Neil Hodgson's answer to Scintilla
            // bug 2412, which upstream quotes at ScintillaEditView.cpp:816.
            NPPSci(editor, SCI_SETSELECTIONMODE, SC_SEL_STREAM);
            NPPSci(editor, SCI_SETSELECTIONMODE, SC_SEL_STREAM);
            return YES;
        case kKeyEscape: {
            sptr_t main = NPPSci(editor, SCI_GETMAINSELECTION);
            sptr_t caret = NPPSci(editor, SCI_GETSELECTIONNCARET, (uptr_t)main);
            NPPSci(editor, SCI_SETSELECTION, (uptr_t)caret, caret);
            NPPSci(editor, SCI_SETSELECTIONMODE, SC_SEL_STREAM);
            return YES;
        }
        default:
            return NO;
    }
}

// Scintilla handles keys inside itself and NPPDocument owns the one delegate this port gives it, so the only seam
// left for upstream's WM_KEYDOWN subclass is AppKit's own: a local monitor sees the key first and hands it straight
// on. Installed once, when the window controller publishes its context (there is no editor to watch before that).
static void InstallColumnSelectionKeyMonitor(void) {
    static id monitor;
    if (monitor) return;
    monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        [NPPEditCommands columnSelectionToMultiCaretsForKeyCode:e.keyCode onEditor:FocusedEditView()];
        return e;
    }];
}

// ---------------------------------------------------------------------------------------------------------------
// Begin/End Select (ScintillaEditView::beginOrEndSelect) — one anchor shared by the stream and column variants.
// ---------------------------------------------------------------------------------------------------------------

// The mark cannot be a plain position: text typed or deleted ahead of it while it is pending would leave it
// pointing at a different character, and the second invocation would select the wrong range. Upstream corrects it
// by hand on every edit (ScintillaEditView::updateBeginEndSelectPosition, ScintillaEditView.cpp:3060, driven from
// NppNotification's SCN_MODIFIED). NPPDocument owns the one Scintilla delegate this port has, so this module never
// sees SCN_MODIFIED — but it does not need to: Scintilla already moves indicator ranges through every insert and
// delete, so the mark is kept as a hidden one-character indicator over the character *before* it, and the mark is
// that run's end. Position 0 gets no indicator (nothing can be inserted ahead of position 0), which is also why
// the plain NSNumber stays: it is the answer for 0, and the fallback if the whole document is deleted under us.
static void setBeginSelectAnchor(ScintillaView *ed, sptr_t position) {
    NPPSci(ed, SCI_INDICSETSTYLE, NPPIndicatorBeginEndSelect, INDIC_HIDDEN);
    NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorBeginEndSelect);
    NPPSci(ed, SCI_INDICATORCLEARRANGE, 0, NPPSci(ed, SCI_GETLENGTH));
    if (position <= 0) return;
    NPPSci(ed, SCI_SETINDICATORVALUE, 1);
    NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)(position - 1), 1);
}

static sptr_t beginSelectAnchor(ScintillaView *ed, NSNumber *fallback) {
    sptr_t length = NPPSci(ed, SCI_GETLENGTH);
    // On at 0 only when the mark was at 1; otherwise the first "off" run ends where the marked one begins.
    BOOL onAtZero = NPPSci(ed, SCI_INDICATORVALUEAT, NPPIndicatorBeginEndSelect, 0) != 0;
    sptr_t runStart = onAtZero ? 0 : NPPSci(ed, SCI_INDICATOREND, NPPIndicatorBeginEndSelect, 0);
    // Scintilla drops a decoration as soon as nothing carries it and then answers 0 to every question about that
    // indicator, which is how "no mark on record" reads here: the mark that sat at position 0 (it needs no
    // indicator, nothing can be inserted ahead of 0) and the mark whose one marked character was deleted outright.
    // The stored position is the answer to both — and for the second it is also upstream's, which leaves the mark
    // alone for an edit at exactly position - 1 (ScintillaEditView.cpp:3062).
    if (!onAtZero && runStart == 0) return std::min<sptr_t>(fallback.longLongValue, length);
    return std::min<sptr_t>(NPPSci(ed, SCI_INDICATOREND, NPPIndicatorBeginEndSelect, (uptr_t)runStart), length);
}

+ (void)beginOrEndSelect:(ScintillaView *)editor column:(BOOL)column {
    if (!editor) return;
    NPPCmd cmd = column ? NPPCmdEditBeginEndSelectColumn : NPPCmdEditBeginEndSelect;
    NSNumber *anchor = objc_getAssociatedObject(editor, kBeginSelectKey);
    sptr_t caret = NPPSci(editor, SCI_GETCURRENTPOS);
    if (!anchor) {
        objc_setAssociatedObject(editor, kBeginSelectKey, @(caret), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(editor, kBeginSelectCmdKey, @(cmd), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setBeginSelectAnchor(editor, caret);
        return;
    }
    sptr_t a = beginSelectAnchor(editor, anchor);
    NPPSci(editor, SCI_CHANGESELECTIONMODE, (uptr_t)(column ? SC_SEL_RECTANGLE : SC_SEL_STREAM));
    // Column mode moves only the anchor: the rectangle stretches from it to wherever the caret already is.
    if (column) NPPSci(editor, SCI_SETANCHOR, (uptr_t)a);
    else NPPSci(editor, SCI_SETSEL, (uptr_t)a, caret);
    setBeginSelectAnchor(editor, 0);   // clears the indicator
    objc_setAssociatedObject(editor, kBeginSelectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(editor, kBeginSelectCmdKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ---------------------------------------------------------------------------------------------------------------
// Paste Special
// ---------------------------------------------------------------------------------------------------------------

// N++ pastes the *source* of the clipboard's HTML/RTF flavour as plain text, markup and all.
// Pasteboard is a parameter so the self-check can use a scratch one instead of the user's clipboard.
+ (BOOL)pasteFlavour:(NSPasteboardType)type fromPasteboard:(NSPasteboard *)pasteboard intoEditor:(ScintillaView *)editor {
    NSString *s = DecodeClipboardText([pasteboard dataForType:type]);
    if (!s.length) { NSBeep(); return NO; }
    NPPSci(editor, SCI_BEGINUNDOACTION);
    NPPSciStr(editor, SCI_REPLACESEL, 0, s.UTF8String);
    NPPSci(editor, SCI_ENDUNDOACTION);
    return YES;
}

+ (BOOL)copyBinaryFromEditor:(ScintillaView *)editor toPasteboard:(NSPasteboard *)pasteboard cut:(BOOL)cut {
    if (!editor || !pasteboard) return NO;
    // N++ copies SCI_GETSELTEXT — what is actually selected. Taking SCI_GETSELECTIONSTART..END instead would drag in
    // the text *between* the ranges of a column or multi-selection, which the user never selected.
    std::vector<std::pair<sptr_t, sptr_t>> ranges = SelectionRanges(editor);
    if (ranges.empty()) return NO;
    std::string bytes;
    for (auto it = ranges.rbegin(); it != ranges.rend(); ++it)   // SelectionRanges is back to front; copy in document order
        bytes += NPPSciGetRange(editor, it->first, it->second);
    [pasteboard clearContents];
    [pasteboard setData:[NSData dataWithBytes:bytes.data() length:bytes.size()] forType:kBinaryPasteboardType];
    // The text flavour stops at the first NUL, exactly as N++'s CF_TEXT does; the private flavour above keeps the rest.
    // Latin-1 fallback for the prefix so a non-UTF-8 blob still reaches other apps as bytes instead of as nothing.
    NSData *prefix = [NSData dataWithBytesNoCopy:(void *)bytes.data()
                                          length:(NSUInteger)strnlen(bytes.data(), bytes.size()) freeWhenDone:NO];
    NSString *text = [[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding] ?: DecodeClipboardText(prefix);
    [pasteboard setString:text ?: @"" forType:NSPasteboardTypeString];
    if (cut && !NPPSci(editor, SCI_GETREADONLY)) NPPSciStr(editor, SCI_REPLACESEL, 0, "");
    return YES;
}

+ (BOOL)pasteBinaryIntoEditor:(ScintillaView *)editor fromPasteboard:(NSPasteboard *)pasteboard {
    if (!editor || !pasteboard || NPPSci(editor, SCI_GETREADONLY)) return NO;
    NSData *raw = [pasteboard dataForType:kBinaryPasteboardType];
    if (!raw.length) raw = nil;   // an empty flavour must not make this a "delete the selection" command
    NSString *text = raw ? nil : [pasteboard stringForType:NSPasteboardTypeString];
    if (!raw && !text) { NSBeep(); return NO; }
    NPPSci(editor, SCI_BEGINUNDOACTION);
    NPPSciStr(editor, SCI_REPLACESEL, 0, "");    // drop the selection; the caret is now where the bytes go
    // SCI_ADDTEXT takes an explicit length, so embedded NULs survive where a NUL-terminated paste would truncate.
    if (raw) NPPSci(editor, SCI_ADDTEXT, (uptr_t)raw.length, (sptr_t)raw.bytes);
    else NPPSciStr(editor, SCI_REPLACESEL, 0, text.UTF8String);
    NPPSci(editor, SCI_ENDUNDOACTION);
    return YES;
}

// ---------------------------------------------------------------------------------------------------------------
// On Selection
// ---------------------------------------------------------------------------------------------------------------

+ (void)redactSelectionsOnEditor:(ScintillaView *)editor symbol:(NSString *)symbol {
    if (!editor || NPPSci(editor, SCI_GETREADONLY)) { NSBeep(); return; }
    std::string mark = Utf8(symbol);
    if (mark.empty()) return;
    bool utf8 = NPPSci(editor, SCI_GETCODEPAGE) == SC_CP_UTF8;
    NPPSci(editor, SCI_BEGINUNDOACTION);
    for (auto &r : SelectionRanges(editor))   // back to front: a mask is wider than the text it replaces
        ReplaceRange(editor, r.first, r.second, RedactMask(NPPSciGetRange(editor, r.first, r.second), mark, utf8));
    NPPSci(editor, SCI_ENDUNDOACTION);
}

// N++ NPPM_GETFILENAMEATCURSOR + doesPathExist: the selection is a path, absolute or relative to the current file.
+ (NSURL *)fileURLForSelectionText:(NSString *)text relativeToFileURL:(NSURL *)base {
    NSString *s = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // One layer of the quoting a path is usually selected inside: #include "foo.h", <foo.h>, 'foo.h'.
    static NSDictionary<NSString *, NSString *> *closers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ closers = @{@"\"": @"\"", @"'": @"'", @"<": @">", @"`": @"`"}; });
    if (s.length >= 2 && [closers[[s substringToIndex:1]] isEqualToString:[s substringFromIndex:s.length - 1]])
        s = [s substringWithRange:NSMakeRange(1, s.length - 2)];
    if (s.length == 0 || [s rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return nil;
    // ponytail: ~ only. N++ also expands %ENVVAR%; upgrade path is a pass over NSProcessInfo.environment here.
    s = s.stringByExpandingTildeInPath;
    NSString *dir = base.URLByDeletingLastPathComponent.path;
    NSString *full = s.isAbsolutePath ? s : (dir ? [dir stringByAppendingPathComponent:s] : nil);
    return full ? [NSURL fileURLWithPath:full.stringByStandardizingPath] : nil;
}

+ (NSURL *)selectedFileURLForEditor:(ScintillaView *)editor {
    NSString *sel = SingleSelectionForLookup(editor);
    return sel ? [self fileURLForSelectionText:sel relativeToFileURL:DocumentForEditor(editor).fileURL] : nil;
}

// The engine, the custom URL and the $(CURRENT_WORD) substitution belong to NPPPreferences' Search Engine page.
+ (void)searchSelectionOnInternet:(ScintillaView *)editor {
    NSString *term = SingleSelectionForLookup(editor);
    NSURL *url = term ? [NPPPreferences.shared searchEngineURLForTerm:term] : nil;
    if (url) [NSWorkspace.sharedWorkspace openURL:url]; else NSBeep();
}

// ---------------------------------------------------------------------------------------------------------------
// Customised date/time (N++ NppGUI::_dateTimeFormat, Preferences > Multi-Instance & Date)
// ---------------------------------------------------------------------------------------------------------------

// N++ IDM_EDIT_INSERT_DATETIME_CUSTOMIZED formats "now" with NppGUI::_dateTimeFormat; the port keeps that format and
// its editor on NPPPreferences' "Multi-Instance & Date" page, so this command is only the insertion.
+ (void)insertCustomDateTime:(ScintillaView *)editor {
    NSString *s = [NPPPreferences.shared formattedDateTimeNowCustom];
    if (s.length == 0) { NSBeep(); return; }
    NPPSci(editor, SCI_BEGINUNDOACTION);
    NPPSciStr(editor, SCI_REPLACESEL, 0, s.UTF8String);
    NPPSci(editor, SCI_ENDUNDOACTION);
}

// ---------------------------------------------------------------------------------------------------------------
// Column mode tip / read-only attribute of the file
// ---------------------------------------------------------------------------------------------------------------

+ (void)showColumnModeTip {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"Column Mode", nil);
    // Same three routes as N++, with the macOS modifier: Option, not Alt.
    alert.informativeText = NSLocalizedString(
        @"There are 3 ways to make a column selection:\n\n"
        @"1. (Keyboard and mouse)  Hold ⌥ while dragging with the left button.\n\n"
        @"2. (Keyboard only)  Hold ⌥⇧ while using the arrow keys.\n\n"
        @"3. (Keyboard or mouse)  Put the caret where the column block starts and choose "
        @"\"Begin/End Select in Column Mode\"; move the caret to where it ends and choose that command again.", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    RunAlert(alert, ^(NSModalResponse response) {});
}

// N++ IDM_EDIT_TOGGLESYSTEMREADONLY flips FILE_ATTRIBUTE_READONLY on the file itself. This is *not* the buffer-level
// Edit > Read-Only flag (NPPDocument.isReadOnly); the two are separate, and the buffer is read-only if either says so.
+ (BOOL)toggleFileReadOnlyAttributeForEditor:(ScintillaView *)editor {
    NPPDocument *doc = DocumentForEditor(editor);
    NSString *path = doc.fileURL.path;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = path ? [fm attributesOfItemAtPath:path error:nil] : nil;
    if (!attrs) { NSBeep(); return NO; }
    short mode = (short)[attrs[NSFilePosixPermissions] unsignedShortValue];
    // Clearing the attribute restores the owner's write bit only; group/other stay wherever the umask left them.
    short wanted = doc.isFileReadOnlyOnDisk ? (short)(mode | 0200) : (short)(mode & ~0222);
    NSError *err = nil;
    if (![fm setAttributes:@{NSFilePosixPermissions: @(wanted)} ofItemAtPath:path error:&err]) {
        [gContext contextReportStatus:err.localizedDescription ?: NSLocalizedString(@"Cannot change the file's permissions.", nil)
                              isError:YES];
        return NO;
    }
    // Re-assigning the user's own flag is the public way to make the document re-read -isFileReadOnlyOnDisk,
    // re-apply SCI_SETREADONLY and tell the window controller, without changing what the user chose.
    [doc setIsReadOnly:doc.isReadOnly];
    [gContext contextRefreshUI];
    return YES;
}

// ---------------------------------------------------------------------------------------------------------------
// Headless checks (NPPSelfTest calls +selfCheckFailures on every module that has one)
// ---------------------------------------------------------------------------------------------------------------

// Scintilla wants a real view hierarchy, so the two editor-backed checks borrow a hidden window like NPPSelfTest does.
static ScintillaView *ScratchEditor(void) {
    static NSWindow *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
        host.releasedWhenClosed = NO;
    });
    ScintillaView *ed = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    [host.contentView addSubview:ed];
    return ed;
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(NSString *, NSString *, NSString *) = ^(NSString *what, NSString *got, NSString *want) {
        if (![(got ?: @"(nil)") isEqualToString:(want ?: @"(nil)")])
            [fails addObject:[NSString stringWithFormat:@"%@: got %@, want %@", what, got ?: @"(nil)", want ?: @"(nil)"]];
    };

    // ---- path resolution from a selection (paths that do not exist, so no symlink is ever resolved under us) ----
    NSURL *base = [NSURL fileURLWithPath:@"/npp-selfcheck/proj/main.cpp"];
    NSString *(^resolve)(NSString *, NSURL *) = ^(NSString *sel, NSURL *b) {
        return [self fileURLForSelectionText:sel relativeToFileURL:b].path;
    };
    expect(@"path.absolute", resolve(@"/npp-selfcheck/x.h", nil), @"/npp-selfcheck/x.h");
    expect(@"path.relative", resolve(@"util.h", base), @"/npp-selfcheck/proj/util.h");
    expect(@"path.relative.parent", resolve(@"../inc/util.h", base), @"/npp-selfcheck/inc/util.h");
    expect(@"path.quoted", resolve(@"  \"util.h\" ", base), @"/npp-selfcheck/proj/util.h");
    expect(@"path.angle-bracketed", resolve(@"<util.h>", base), @"/npp-selfcheck/proj/util.h");
    expect(@"path.relative-without-base", resolve(@"util.h", nil), nil);
    expect(@"path.multiline-is-not-a-path", resolve(@"a.h\nb.h", base), nil);
    expect(@"path.empty", resolve(@"   ", base), nil);

    // ---- the tag range this module claims. A tag added to the Edit-menu gap block without extending the range would
    // ---- otherwise fall through to "unhandled" and leave a live menu item doing nothing.
    if (![self handlesCommand:NPPCmdEditPasteHTML] || ![self handlesCommand:NPPCmdEditToggleFileReadOnlyAttribute]
        || [self handlesCommand:(NPPCmd)(NPPCmdEditPasteHTML - 1)]
        || [self handlesCommand:(NPPCmd)(NPPCmdEditToggleFileReadOnlyAttribute + 1)])
        [fails addObject:@"handlesCommand: does not claim exactly the Edit-menu gap tags"];

    // ---- the seam into NPPPreferences "Search on Internet" rides on. Not that module's own logic (it checks its
    // ---- engine list itself), only that the configured engine yields a link this command can hand to the browser.
    NSURL *search = [NPPPreferences.shared searchEngineURLForTerm:@"a b&c"];
    if (!search) [fails addObject:@"searchEngineURLForTerm: returned nil for a plain term"];
    else if ([search.absoluteString containsString:@" "] ||
             !([search.scheme isEqualToString:@"https"] || [search.scheme isEqualToString:@"http"]))
        [fails addObject:[NSString stringWithFormat:@"search URL is not an escaped http(s) link: %@", search]];

    // ---- redaction over a multi-selection, including a multi-byte character and a kept EOL ----
    ScintillaView *ed = ScratchEditor();
    NPPSci(ed, SCI_SETCODEPAGE, SC_CP_UTF8);
    NPPSci(ed, SCI_SETMULTIPLESELECTION, 1);
    NPPSciStr(ed, SCI_SETTEXT, 0, "héllo\nworld\n");
    NPPSci(ed, SCI_SETSELECTION, 0, 6);              // bytes 0..5 = "héllo": 6 bytes, 5 characters
    NPPSci(ed, SCI_ADDSELECTION, (uptr_t)7, 12);     // bytes 7..11 = "world"
    [self redactSelectionsOnEditor:ed symbol:@"█"];
    expect(@"redact.multi-selection", NSStr(NPPSciGetText(ed)), @"█████\n█████\n");

    NPPSciStr(ed, SCI_SETTEXT, 0, "ab\r\ncd");
    NPPSci(ed, SCI_SETSELECTION, 0, NPPSci(ed, SCI_GETLENGTH));
    [self redactSelectionsOnEditor:ed symbol:@"#"];
    expect(@"redact.keeps-line-breaks", NSStr(NPPSciGetText(ed)), @"##\r\n##");

    // ---- the customised date/time itself is NPPPreferences' ("Multi-Instance & Date"); what this module owes is that
    // ---- the command inserts it. Comparing the text would race the clock, so this only asserts something landed.
    NPPSciStr(ed, SCI_SETTEXT, 0, "");
    [self insertCustomDateTime:ed];
    if (NPPSci(ed, SCI_GETLENGTH) == 0)
        [fails addObject:@"Insert Date Time (customized) inserted nothing (empty NPPPreferences.dateTimeFormat?)"];

    // ---- Begin/End Select: one anchor shared by the two variants, and the other one disabled while it is pending ----
    NPPSciStr(ed, SCI_SETTEXT, 0, "0123456789");
    NPPSci(ed, SCI_GOTOPOS, 2);
    [self beginOrEndSelect:ed column:NO];
    if ([self canPerformCommand:NPPCmdEditBeginEndSelectColumn onEditor:ed language:nil])
        [fails addObject:@"Begin/End Select in Column Mode stays enabled while the stream variant is pending"];
    NPPSci(ed, SCI_GOTOPOS, 7);
    [self beginOrEndSelect:ed column:NO];
    expect(@"beginEndSelect.second-call-selects-from-the-anchor",
           NSStr(NPPSciGetRange(ed, NPPSci(ed, SCI_GETSELECTIONSTART), NPPSci(ed, SCI_GETSELECTIONEND))), @"23456");
    if (![self canPerformCommand:NPPCmdEditBeginEndSelectColumn onEditor:ed language:nil])
        [fails addObject:@"Begin/End Select in Column Mode is still disabled after the stream variant finished"];

    // ---- …and the mark must not drift while it is pending: an insert or a delete ahead of it moves it with the
    // ---- text, the way upstream moves it by hand on every SCN_MODIFIED (ScintillaEditView.cpp:3060).
    NSString *(^markedRange)(NSString *, void (^)(void)) = ^(NSString *text, void (^edit)(void)) {
        NPPSciStr(ed, SCI_SETTEXT, 0, text.UTF8String);
        NPPSci(ed, SCI_GOTOPOS, 5);
        [self beginOrEndSelect:ed column:NO];       // mark at 5
        edit();
        [self beginOrEndSelect:ed column:NO];       // …select from the mark to wherever the caret is now
        return NSStr(NPPSciGetRange(ed, NPPSci(ed, SCI_GETSELECTIONSTART), NPPSci(ed, SCI_GETSELECTIONEND)));
    };
    expect(@"beginEndSelect.insert-before-the-mark", markedRange(@"0123456789", ^{
        NPPSci(ed, SCI_SETTARGETRANGE, 0, 0);
        NPPSciStr(ed, SCI_REPLACETARGET, 3, "xyz");   // "xyz0123456789": the mark's "5" is now at 8
        NPPSci(ed, SCI_GOTOPOS, 11);
    }), @"567");
    expect(@"beginEndSelect.delete-before-the-mark", markedRange(@"0123456789", ^{
        NPPSci(ed, SCI_DELETERANGE, 0, 2);            // "23456789": the mark's "5" is now at 3
        NPPSci(ed, SCI_GOTOPOS, 6);
    }), @"567");
    expect(@"beginEndSelect.edit-after-the-mark-leaves-it-alone", markedRange(@"0123456789", ^{
        NPPSci(ed, SCI_SETTARGETRANGE, 8, 8);
        NPPSciStr(ed, SCI_REPLACETARGET, 3, "xyz");   // "01234567xyz89": everything before 5 is untouched
        NPPSci(ed, SCI_GOTOPOS, 8);
    }), @"567");
    // A mark at 0 carries no indicator at all (nothing can be inserted ahead of position 0), so it has its own path.
    NPPSciStr(ed, SCI_SETTEXT, 0, "0123456789");
    NPPSci(ed, SCI_GOTOPOS, 0);
    [self beginOrEndSelect:ed column:NO];
    NPPSci(ed, SCI_GOTOPOS, 4);
    [self beginOrEndSelect:ed column:NO];
    expect(@"beginEndSelect.mark-at-position-zero",
           NSStr(NPPSciGetRange(ed, NPPSci(ed, SCI_GETSELECTIONSTART), NPPSci(ed, SCI_GETSELECTIONEND))), @"0123");
    // Finishing has to leave nothing behind, or the next mark would read the stale one.
    if (NPPSci(ed, SCI_INDICATOREND, NPPIndicatorBeginEndSelect, 0) != 0)
        [fails addObject:@"Begin/End Select left its tracking indicator in the document"];

    // ---- column selection -> multi-carets (upstream's WM_KEYDOWN hook) ----
    BOOL multiWas = NPPPreferences.shared.multiSelection, col2multiWas = NPPPreferences.shared.columnSelectionToMultiEditing;
    NPPPreferences.shared.multiSelection = YES;
    NPPPreferences.shared.columnSelectionToMultiEditing = YES;
    void (^makeColumnSelection)(void) = ^{
        NPPSciStr(ed, SCI_SETTEXT, 0, "abcd\nefgh\nijkl\n");
        NPPSci(ed, SCI_SETSELECTION, 1, 1);
        NPPSci(ed, SCI_CHANGESELECTIONMODE, SC_SEL_RECTANGLE);
        NPPSci(ed, SCI_SETANCHOR, 1);
        NPPSci(ed, SCI_SETCURRENTPOS, 13);            // a 1-column rectangle down three lines
    };
    makeColumnSelection();
    if (NPPSci(ed, SCI_GETSELECTIONS) < 2)
        [fails addObject:@"column2multi: the self-check could not build a rectangular selection"];
    if (![self columnSelectionToMultiCaretsForKeyCode:kKeyDown onEditor:ed])
        [fails addObject:@"column2multi: Down did not convert a rectangular selection"];
    if (NPPSci(ed, SCI_GETSELECTIONMODE) != SC_SEL_STREAM)
        [fails addObject:@"column2multi: the selection is still rectangular, so the carets stay locked in a column"];
    if (NPPSci(ed, SCI_GETSELECTIONS) < 2)
        [fails addObject:@"column2multi: the conversion dropped the extra carets instead of freeing them"];

    makeColumnSelection();
    if ([self columnSelectionToMultiCaretsForKeyCode:0x0B /* 'b' */ onEditor:ed])
        [fails addObject:@"column2multi: an ordinary character key converted the selection"];
    if (NPPSci(ed, SCI_GETSELECTIONMODE) == SC_SEL_STREAM)
        [fails addObject:@"column2multi: an ordinary character key dropped column mode"];
    if ([self columnSelectionToMultiCaretsForKeyCode:kKeyDown onEditor:nil])
        [fails addObject:@"column2multi: answered YES with no editor"];

    // Escape is the other half: one caret, no rectangle (upstream ScintillaEditView.cpp:821).
    makeColumnSelection();
    if (![self columnSelectionToMultiCaretsForKeyCode:kKeyEscape onEditor:ed])
        [fails addObject:@"column2multi: Escape did not clear the rectangular selection"];
    if (NPPSci(ed, SCI_GETSELECTIONS) != 1 || !NPPSci(ed, SCI_GETSELECTIONEMPTY))
        [fails addObject:@"column2multi: Escape left more than one caret, or left it selecting"];

    // …and the preference has to actually gate it, or the checkbox is a control that does nothing.
    NPPPreferences.shared.columnSelectionToMultiEditing = NO;
    makeColumnSelection();
    if ([self columnSelectionToMultiCaretsForKeyCode:kKeyDown onEditor:ed])
        [fails addObject:@"column2multi: converted with \"column selection to multi-editing\" turned off"];
    NPPPreferences.shared.multiSelection = multiWas;
    NPPPreferences.shared.columnSelectionToMultiEditing = col2multiWas;

    // ---- binary round trip: a NUL in the middle must survive copy and paste ----
    NSPasteboard *scratch = [NSPasteboard pasteboardWithUniqueName];   // never the user's clipboard
    NPPSciStr(ed, SCI_SETTEXT, 0, "");
    NPPSci(ed, SCI_ADDTEXT, 5, (sptr_t)"a\0b\0c");
    NPPSci(ed, SCI_SETSELECTION, 0, 5);
    [self copyBinaryFromEditor:ed toPasteboard:scratch cut:YES];
    if (NPPSci(ed, SCI_GETLENGTH) != 0) [fails addObject:@"binary.cut left text behind"];
    [self pasteBinaryIntoEditor:ed fromPasteboard:scratch];
    std::string back = NPPSciGetRange(ed, 0, NPPSci(ed, SCI_GETLENGTH));
    if (back != std::string("a\0b\0c", 5))
        [fails addObject:[NSString stringWithFormat:@"binary.round-trip: got %lu bytes, want 5 with NULs intact",
                          (unsigned long)back.size()]];
    // The plain-text flavour is the NUL-truncated prefix, exactly like N++'s CF_TEXT.
    expect(@"binary.text-flavour-truncates-at-nul", [scratch stringForType:NSPasteboardTypeString], @"a");

    // Copy Binary takes what is selected, not the span between the first and the last range: the "b" between the two
    // ranges below must not come along (N++ copies SCI_GETSELTEXT).
    NPPSciStr(ed, SCI_SETTEXT, 0, "abc");
    NPPSci(ed, SCI_SETSELECTION, 0, 1);
    NPPSci(ed, SCI_ADDSELECTION, (uptr_t)2, 3);
    [self copyBinaryFromEditor:ed toPasteboard:scratch cut:NO];
    expect(@"binary.multi-selection-skips-the-gap", [scratch stringForType:NSPasteboardTypeString], @"ac");

    // ---- Paste as HTML/RTF: the flavour's source lands in the buffer as text, markup and all ----
    [scratch clearContents];
    [scratch setData:[@"<b>hi</b>" dataUsingEncoding:NSUTF8StringEncoding] forType:NSPasteboardTypeHTML];
    NPPSciStr(ed, SCI_SETTEXT, 0, "");
    NPPSci(ed, SCI_SETEMPTYSELECTION, 0);
    [self pasteFlavour:NSPasteboardTypeHTML fromPasteboard:scratch intoEditor:ed];
    expect(@"paste.html-flavour-pasted-as-source", NSStr(NPPSciGetText(ed)), @"<b>hi</b>");

    // ---- Cut/Copy: the two tags have to be claimed, or the window controller drops them on the floor and both
    // ---- menu items go dead. They are not in the range the block above walks.
    if (![self handlesCommand:(NPPCmd)NPPCmdEditClipboardCut] || ![self handlesCommand:(NPPCmd)NPPCmdEditClipboardCopy])
        [fails addObject:@"handlesCommand: does not claim the private Cut/Copy tags"];

    // ---- Cut/Copy: the decision table Preferences ▸ "Enable Copy/Cut line without selection" drives. Pure, so it
    // ---- runs without a key window; the three branches are the whole of the feature.
    BOOL savedLineCopyCut = NPPPreferences.shared.lineCopyCutWithoutSelection;
    NPPSciStr(ed, SCI_SETTEXT, 0, "one\ntwo\nthree\n");
    NSString *(^actionName)(NPPClipboardAction) = ^(NPPClipboardAction a) {
        return a == NPPClipboardForward ? @"forward" : (a == NPPClipboardWholeLine ? @"whole-line" : @"selection");
    };
    for (NSNumber *on in @[@NO, @YES]) {
        NPPPreferences.shared.lineCopyCutWithoutSelection = on.boolValue;
        expect([NSString stringWithFormat:@"clipboard.no-focused-editor(setting=%@)", on],
               actionName([self clipboardActionForFocusedEditor:nil]), @"forward");
        NPPSci(ed, SCI_SETSELECTION, 0, 3);
        expect([NSString stringWithFormat:@"clipboard.with-selection(setting=%@)", on],
               actionName([self clipboardActionForFocusedEditor:ed]), @"selection");
        NPPSci(ed, SCI_SETEMPTYSELECTION, 5);
        expect([NSString stringWithFormat:@"clipboard.empty-selection(setting=%@)", on],
               actionName([self clipboardActionForFocusedEditor:ed]), on.boolValue ? @"whole-line" : @"selection");
    }

    // ---- and what each branch actually issues: the decision above is only half the feature, the Scintilla messages
    // ---- are the other half, and a swapped pair (SCI_CUT where SCI_LINEDELETE belongs, or the two branches
    // ---- exchanged) would leave the table right and the editing wrong. Driven through the same function the menu
    // ---- goes through, with the editor passed in, so no key window is needed.
    // ponytail: Scintilla always copies to the general pasteboard, so this saves and restores the string flavour —
    // enough for a headless --selftest run, where nothing else owns the clipboard. Upgrade path if that stops being
    // true: a Scintilla build that takes a pasteboard, which upstream does not offer.
    NSPasteboard *general = NSPasteboard.generalPasteboard;
    NSString *savedClipboard = [general stringForType:NSPasteboardTypeString];

    NPPSciStr(ed, SCI_SETTEXT, 0, "one\ntwo\nthree\n");
    NPPSci(ed, SCI_SETEMPTYSELECTION, 5);            // inside "two"
    PerformClipboard(NPPClipboardWholeLine, NO, ed, nil);
    expect(@"clipboard.whole-line-copy-keeps-the-text", NSStr(NPPSciGetText(ed)), @"one\ntwo\nthree\n");
    expect(@"clipboard.whole-line-copy-takes-the-caret-line-with-its-eol",
           [general stringForType:NSPasteboardTypeString], @"two\n");

    NPPSci(ed, SCI_SETEMPTYSELECTION, 5);
    PerformClipboard(NPPClipboardWholeLine, YES, ed, nil);
    expect(@"clipboard.whole-line-cut-removes-the-caret-line", NSStr(NPPSciGetText(ed)), @"one\nthree\n");
    expect(@"clipboard.whole-line-cut-takes-the-caret-line-with-its-eol",
           [general stringForType:NSPasteboardTypeString], @"two\n");

    // The selection branch must cut the selection and nothing more — that is the branch every Cut with a selection
    // takes, i.e. the overwhelming majority of them.
    NPPSciStr(ed, SCI_SETTEXT, 0, "one\ntwo\nthree\n");
    NPPSci(ed, SCI_SETSELECTION, 4, 7);              // "two", without its EOL
    PerformClipboard(NPPClipboardSelection, YES, ed, nil);
    expect(@"clipboard.selection-cut-takes-only-the-selection", NSStr(NPPSciGetText(ed)), @"one\n\nthree\n");
    expect(@"clipboard.selection-cut-clipboard", [general stringForType:NSPasteboardTypeString], @"two");

    if (savedClipboard) { [general clearContents]; [general setString:savedClipboard forType:NSPasteboardTypeString]; }
    NPPPreferences.shared.lineCopyCutWithoutSelection = savedLineCopyCut;

    // ---- Insert Date Time: which half comes first is the whole of "Reverse the default date-time order". Compare
    // ---- the two orders against each other rather than against a clock-dependent string.
    BOOL savedReverse = NPPPreferences.shared.dateTimeReverseDefaultOrder;
    NSString *(^inserted)(BOOL) = ^(BOOL reverse) {
        NPPPreferences.shared.dateTimeReverseDefaultOrder = reverse;
        NPPSciStr(ed, SCI_SETTEXT, 0, "");
        [self insertDateTime:ed longFormat:NO];
        return NSStr(NPPSciGetText(ed));
    };
    NSString *normal = inserted(NO), *reversed = inserted(YES);
    NPPPreferences.shared.dateTimeReverseDefaultOrder = savedReverse;
    // A locale's time can itself contain a space ("3:04 PM"), so look for *a* split of the default text whose two
    // halves, swapped, give the reversed one — that is the whole contract, without assuming where the seam is.
    BOOL swapped = NO;
    for (NSUInteger i = 0; i < normal.length && !swapped; i++) {
        if ([normal characterAtIndex:i] != ' ') continue;
        swapped = [reversed isEqualToString:[NSString stringWithFormat:@"%@ %@", [normal substringFromIndex:i + 1],
                                                                                [normal substringToIndex:i]]];
    }
    if (normal.length == 0 || [normal isEqualToString:reversed])
        [fails addObject:[NSString stringWithFormat:@"Insert Date Time ignores dateTimeReverseDefaultOrder: \"%@\" both ways", normal]];
    else if (!swapped)
        [fails addObject:[NSString stringWithFormat:@"Insert Date Time reversed to \"%@\", which is not \"%@\" with its halves swapped",
                          reversed, normal]];

    [scratch releaseGlobally];
    [ed removeFromSuperview];

    return fails;
}

@end
