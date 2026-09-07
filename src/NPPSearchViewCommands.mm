// NPPSearchViewCommands.mm — bookmarks, mark styles 1-5, brace matching, folding, show-symbol toggles, zoom,
// change-history navigation, hide lines, summary. Mirrors N++ NppCommands.cpp / Notepad_plus.cpp / ScintillaEditView.cpp.
#import "NPPSearchViewCommands.h"
#import "NPPUtils.h"
#import "NPPPreferences.h"
#import "NPPFeatureProtocols.h"
#import "NPPDocument.h"
#import "NPPTabBarView.h"   // the pinned flag and the selected index of the strip Move to Start/End reorders
#include <string>
#include <vector>
#include <algorithm>
#include <utility>

static const int kBookmarkMask = 1 << NPPMarkerBookmark;
static const int kChangeHistoryMask = (1 << SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) | (1 << SC_MARKNUM_HISTORY_SAVED) |
                                      (1 << SC_MARKNUM_HISTORY_MODIFIED) | (1 << SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED);

static inline sptr_t lineOfCaret(ScintillaView *ed) { return NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(ed, SCI_GETCURRENTPOS)); }
static inline sptr_t lineCount(ScintillaView *ed) { return NPPSci(ed, SCI_GETLINECOUNT); }
static inline BOOL isReadOnly(ScintillaView *ed) { return NPPSci(ed, SCI_GETREADONLY) != 0; }
static inline BOOL hasBookmark(ScintillaView *ed, sptr_t line) { return (NPPSci(ed, SCI_MARKERGET, (uptr_t)line) & kBookmarkMask) != 0; }
static inline void gotoLineVisible(ScintillaView *ed, sptr_t line) {
    NPPSci(ed, SCI_ENSUREVISIBLEENFORCEPOLICY, (uptr_t)line);
    NPPSci(ed, SCI_GOTOLINE, (uptr_t)line);
}
static NSString *utf8String(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
static int indicatorForExt(NPPCmd cmd, NPPCmd base) { return NPPIndicatorMarkExt1 - (int)(cmd - base); }   // Ext1=25 ... Ext5=21

// Text N++ "Style token" uses: selection if any, else word at caret. wholeWord = the text is a single word.
static NSString *tokenText(ScintillaView *ed, BOOL *wholeWord) {
    NSString *text = NPPSciSelectedString(ed);
    if (text.length == 0) text = NPPSciWordAtCaret(ed);
    *wholeWord = NO;
    if (text.length) {
        NSCharacterSet *wordChars = [NSCharacterSet characterSetWithCharactersInString:@"_"];
        NSMutableCharacterSet *ws = [wordChars mutableCopy]; [ws formUnionWithCharacterSet:NSCharacterSet.alphanumericCharacterSet];
        *wholeWord = [text rangeOfCharacterFromSet:ws.invertedSet].location == NSNotFound;
    }
    return text;
}
static void fillIndicator(ScintillaView *ed, int indicator, sptr_t start, sptr_t end) {
    NPPSci(ed, SCI_SETINDICATORCURRENT, (uptr_t)indicator);
    NPPSci(ed, SCI_SETINDICATORVALUE, 1);
    NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)start, end - start);
}

// Bookmarked-line helpers (N++ getMarkedLine/deleteMarkedline/replaceMarkedline).
static std::vector<sptr_t> bookmarkedLines(ScintillaView *ed) {
    std::vector<sptr_t> lines;
    for (sptr_t l = NPPSci(ed, SCI_MARKERNEXT, 0, kBookmarkMask); l >= 0; l = NPPSci(ed, SCI_MARKERNEXT, (uptr_t)(l + 1), kBookmarkMask))
        lines.push_back(l);
    return lines;
}
static NSString *joinLines(ScintillaView *ed, const std::vector<sptr_t> &lines) {
    // Full lines including their EOL (N++ getMarkedLine uses SCI_LINELENGTH).
    std::string out;
    for (sptr_t l : lines) {
        sptr_t begin = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)l);
        out += NPPSciGetRange(ed, begin, begin + NPPSci(ed, SCI_LINELENGTH, (uptr_t)l));
    }
    return utf8String(out);
}
static void deleteLine(ScintillaView *ed, sptr_t l) {
    sptr_t begin = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)l);
    NPPSci(ed, SCI_MARKERDELETE, (uptr_t)l, NPPMarkerBookmark);
    NPPSci(ed, SCI_DELETERANGE, (uptr_t)begin, NPPSci(ed, SCI_LINELENGTH, (uptr_t)l));
}
static void deleteLinesWhere(ScintillaView *ed, BOOL marked) {
    NPPSci(ed, SCI_BEGINUNDOACTION);
    for (sptr_t l = lineCount(ed) - 1; l >= 0; l--)
        if (hasBookmark(ed, l) == marked) deleteLine(ed, l);
    NPPSci(ed, SCI_ENDUNDOACTION);
}
static void setPasteboard(NSString *s) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s ?: @"" forType:NSPasteboardTypeString];
}

// ---------------------------------------------------------------- long-lived context
// Post-It, the two tab moves and "View Current File in <browser>" act on the window and the tab strip, not on the
// editor, but this class is dispatched through +performCommand:onEditor: (it is not in the window controller's
// feature-handler list), so it keeps a context the way NPPShortcutMapper does instead of being handed one.
static __weak id<NPPCommandContext> gContext;

// The bits of NPPEditorWindowController that NPPCommandContext does not expose. Declared rather than imported so
// this file keeps no build dependency on the window controller, and every call is respondsToSelector-guarded —
// the same shape NPPPreferences uses to reach the tab bar and -layoutContent.
@protocol NPPHostWindow <NSObject>
- (NPPTabBarView *)tabBar;                                          // the focused view's strip
- (void)moveDocumentAtIndex:(NSInteger)from toIndex:(NSInteger)to;  // indices into that strip
- (void)layoutContent;                                              // private re-layout, run on every real resize
@end

static void relayoutHostWindow(void) {
    id ctx = gContext;
    if ([ctx respondsToSelector:@selector(layoutContent)]) [(id<NPPHostWindow>)ctx layoutContent];
}

// ---------------------------------------------------------------- Zoom (IDM_VIEW_ZOOMIN/OUT/RESTOREDEFAULT)
// Upstream zoom belongs to the VIEW, not to the buffer: it is set once on each edit view and every buffer shown
// there inherits it (Notepad_plus.cpp:349-351), and it is written to config.xml and read back next launch
// (Parameters.cpp:7260 / 6968). The port gives every document its own ScintillaView, so "the view's zoom" is one
// number pushed to all of them and kept in NSUserDefaults — otherwise zoom resets on every tab switch and dies
// with the process.
// ponytail: one zoom where upstream has zoom + zoom2, one per edit view. Which view a document sits in is not
// something NPPCommandContext answers; add the split's own zoom when it asks for it. So View ▸ Zoom ▸ Synchronize
// Across Views only still governs the immediate ⌘-wheel echo between the two visible views (the window
// controller's -syncZoomFromDocument:); the menu's own Zoom In/Out/Restore land on both either way.
static NSString *const kZoomDefaultsKey = @"NPPZoom";

static sptr_t storedZoom(void) { return (sptr_t)[NSUserDefaults.standardUserDefaults integerForKey:kZoomDefaultsKey]; }

// Remember `zoom` and put it on every open document, plus `extra` for the editor that has no document behind it
// (the self-check's scratch view, and a brand-new buffer that has not joined the tab strip yet). SCI_SETZOOM is a
// no-op when the value already matches, so this does not stir SCN_ZOOM across the other tabs. `docs` is passed in
// rather than read from gContext so the self-check can drive it on its own scratch buffers.
static void spreadZoom(sptr_t zoom, NSArray<NPPDocument *> *docs, ScintillaView *extra) {
    [NSUserDefaults.standardUserDefaults setInteger:zoom forKey:kZoomDefaultsKey];
    for (NPPDocument *doc in docs)
        if (doc.editor) NPPSci(doc.editor, SCI_SETZOOM, (uptr_t)zoom);
    if (extra) NPPSci(extra, SCI_SETZOOM, (uptr_t)zoom);
}

// The document the stored zoom was last pushed onto. ⌘-wheel zoom never passes through a command — Scintilla
// applies it and reports SCN_ZOOM to NPPDocument, whose delegate this module is not — so the outgoing document is
// read back on every tab switch: whatever the wheel left there is the view's zoom now, which is exactly what
// upstream's saveScintillasZoom() reads off the view before writing config.xml.
static __weak NPPDocument *gZoomWitness;

static void syncZoomOnDocumentChange(NPPDocument *current, NSArray<NPPDocument *> *docs) {
    NPPDocument *outgoing = gZoomWitness;
    spreadZoom(outgoing.editor ? NPPSci(outgoing.editor, SCI_GETZOOM) : storedZoom(), docs, nil);
    gZoomWitness = current;
}

// ---------------------------------------------------------------- Move to Start / Move to End
// N++ TabBarPlus::tabToStart / tabToEnd walk the tab towards the end one swap at a time and stop where
// exchangeTabItemData refuses: a pinned tab never crosses an unpinned one. So the destination is the far end of
// the pinned block the tab belongs to, not tab 0 / the last tab. Pure, so the self-check can drive it.
// NSNotFound = nowhere to go (empty strip, or the tab is already there).
static NSInteger tabMoveDestination(NSArray<NPPTabItem *> *items, NSInteger from, BOOL toEnd) {
    NSInteger n = (NSInteger)items.count;
    if (from < 0 || from >= n) return NSNotFound;
    BOOL pinned = items[(NSUInteger)from].pinned;
    NSInteger dest = from;
    if (toEnd) while (dest + 1 < n && items[(NSUInteger)(dest + 1)].pinned == pinned) dest++;
    else       while (dest > 0 && items[(NSUInteger)(dest - 1)].pinned == pinned) dest--;
    return dest == from ? NSNotFound : dest;
}

// The strip the window controller would reorder is its *focused view's*, and -moveDocumentAtIndex:toIndex: takes
// that view's indices — -contextOpenDocuments spans both views and must not be used here, or a document in the
// sub view would move the wrong tab (or, out of range, none at all).
static NSInteger tabMoveTarget(BOOL toEnd, NPPTabBarView *__strong *outBar) {
    id ctx = gContext;
    if (![ctx respondsToSelector:@selector(tabBar)] || ![ctx respondsToSelector:@selector(moveDocumentAtIndex:toIndex:)])
        return NSNotFound;
    NPPTabBarView *bar = [(id<NPPHostWindow>)ctx tabBar];
    if (outBar) *outBar = bar;
    return bar ? tabMoveDestination(bar.items, bar.selectedIndex, toEnd) : NSNotFound;
}

// ---------------------------------------------------------------- View Current File in <browser>
// N++ IDM_VIEW_IN_FIREFOX/CHROME/EDGE/IE looks each browser up in the registry's App Paths and disables the item
// when it is not installed; NSWorkspace is the same question. Index 0 is the user's default browser (N++ has no
// such entry, but on macOS "the browser" is a system setting worth honouring), then Safari, Chrome, Firefox,
// Edge. A browser that is not installed leaves its menu item disabled.
static NSURL *browserApplicationURL(NSInteger index) {
    NSWorkspace *ws = NSWorkspace.sharedWorkspace;
    if (index == 0) return [ws URLForApplicationToOpenURL:[NSURL URLWithString:@"https://notepad-plus-plus.org/"]];
    NSString *bundleIDs[] = {nil, @"com.apple.Safari", @"com.google.Chrome", @"org.mozilla.firefox",
                             @"com.microsoft.edgemac"};
    if (index < 1 || index > 3) return nil;
    return [ws URLForApplicationWithBundleIdentifier:bundleIDs[index]];
}
static NSURL *currentFileOnDisk(void) {
    NSURL *url = [gContext contextCurrentDocument].fileURL;   // N++: untitled/never-saved buffers disable the item
    return (url && [NSFileManager.defaultManager fileExistsAtPath:url.path]) ? url : nil;
}

// ---------------------------------------------------------------- non-printing characters
// N++ ScintillaEditView::showNpc / showCcUniEol: SCI_SETREPRESENTATION swaps the glyph of an invisible character
// for a short label, split over two menu items — "Show Non-Printing Characters" (IDM_VIEW_NPC: no-break spaces,
// the Unicode space separators and the invisible formatting marks) and "Show Control Characters and Unicode EOL"
// (IDM_VIEW_NPC_CCUNIEOL: C0, DEL, C1 and NEL/LS/PS).
//
// Only the first table lives here. The second one already exists: NPPPreferences
// -applyNonPrintingRepresentationsToEditor: writes C0/DEL/C1/NEL/LS/PS for every buffer from the "Show
// non-printing characters" + "Apply to C1 control characters and Unicode line separators" preferences. So
// IDM_VIEW_NPC_CCUNIEOL flips that preference instead of keeping a second copy — one state and one writer, so the
// menu item and the Preferences checkbox cannot disagree and cannot clear each other's representations.
// Tab, LF and CR are in neither table: they are Show Space and Tab / Show End of Line.
struct NPPRepr { const char *utf8; const char *label; uint32_t code; };

static const NPPRepr kNonPrintingChars[] = {
    {"\xC2\xA0",        "NBSP",   0x00A0},
    {"\xC2\xAD",        "SHY",    0x00AD},
    {"\xD8\x9C",        "ALM",    0x061C},
    {"\xDC\x8F",        "SAM",    0x070F},
    {"\xE1\x9A\x80",    "OSPM",   0x1680},
    {"\xE1\xA0\x8E",    "MVS",    0x180E},
    {"\xE2\x80\x80",    "NQSP",   0x2000},
    {"\xE2\x80\x81",    "MQSP",   0x2001},
    {"\xE2\x80\x82",    "ENSP",   0x2002},
    {"\xE2\x80\x83",    "EMSP",   0x2003},
    {"\xE2\x80\x84",    "3/MSP",  0x2004},
    {"\xE2\x80\x85",    "4/MSP",  0x2005},
    {"\xE2\x80\x86",    "6/MSP",  0x2006},
    {"\xE2\x80\x87",    "FSP",    0x2007},
    {"\xE2\x80\x88",    "PSP",    0x2008},
    {"\xE2\x80\x89",    "THSP",   0x2009},
    {"\xE2\x80\x8A",    "HSP",    0x200A},
    {"\xE2\x80\x8B",    "ZWSP",   0x200B},
    {"\xE2\x80\x8C",    "ZWNJ",   0x200C},
    {"\xE2\x80\x8D",    "ZWJ",    0x200D},
    {"\xE2\x80\x8E",    "LRM",    0x200E},
    {"\xE2\x80\x8F",    "RLM",    0x200F},
    {"\xE2\x80\xAA",    "LRE",    0x202A},
    {"\xE2\x80\xAB",    "RLE",    0x202B},
    {"\xE2\x80\xAC",    "PDF",    0x202C},
    {"\xE2\x80\xAD",    "LRO",    0x202D},
    {"\xE2\x80\xAE",    "RLO",    0x202E},
    {"\xE2\x80\xAF",    "NNBSP",  0x202F},
    {"\xE2\x81\x9F",    "MMSP",   0x205F},
    {"\xE2\x81\xA0",    "WJ",     0x2060},
    {"\xE2\x81\xA1",    "(FA)",   0x2061},
    {"\xE2\x81\xA2",    "(IT)",   0x2062},
    {"\xE2\x81\xA3",    "(IS)",   0x2063},
    {"\xE2\x81\xA4",    "(IP)",   0x2064},
    {"\xE2\x81\xA6",    "LRI",    0x2066},
    {"\xE2\x81\xA7",    "RLI",    0x2067},
    {"\xE2\x81\xA8",    "FSI",    0x2068},
    {"\xE2\x81\xA9",    "PDI",    0x2069},
    {"\xE2\x81\xAA",    "ISS",    0x206A},
    {"\xE2\x81\xAB",    "ASS",    0x206B},
    {"\xE2\x81\xAC",    "IAFS",   0x206C},
    {"\xE2\x81\xAD",    "AAFS",   0x206D},
    {"\xE2\x81\xAE",    "NADS",   0x206E},
    {"\xE2\x81\xAF",    "NODS",   0x206F},
    {"\xE3\x80\x80",    "IDSP",   0x3000},
    {"\xEF\xBB\xBF",    "ZWNBSP", 0xFEFF},
    {"\xEF\xBF\xB9",    "IAA",    0xFFF9},
    {"\xEF\xBF\xBA",    "IAS",    0xFFFA},
    {"\xEF\xBF\xBB",    "IAT",    0xFFFB},
};

// Same shape as NPPPreferences -applyNonPrintingRepresentationsToEditor:, so the two halves of N++'s non-printing
// set are drawn alike: the abbreviation/codepoint mode and the custom colour from the Preferences page apply to
// these characters too, instead of this half being stuck on abbreviations.
static void applyNonPrintingRepresentations(ScintillaView *ed) {
    if (!ed) return;
    NPPPreferences *p = NPPPreferences.shared;
    BOOL show = p.showNonPrintingChars;
    BOOL codepoint = p.nonPrintingMode == NPPNonPrintingCodepoint;
    BOOL colourise = show && p.nonPrintingCustomColorEnabled;
    sptr_t colour = (sptr_t)(NPPColorFromHex(p.nonPrintingCustomColor) | 0xFF000000);
    char rep[8];   // longest of "ZWNBSP" and "xFFFB"; the self-check holds every label under this
    for (const NPPRepr &r : kNonPrintingChars) {
        if (!show) { NPPSci(ed, SCI_CLEARREPRESENTATION, (uptr_t)r.utf8); continue; }
        if (codepoint) snprintf(rep, sizeof rep, "x%04X", r.code); else snprintf(rep, sizeof rep, "%s", r.label);
        NPPSciStr(ed, SCI_SETREPRESENTATION, (uptr_t)r.utf8, rep);
        NPPSci(ed, SCI_SETREPRESENTATIONAPPEARANCE, (uptr_t)r.utf8,
               SC_REPRESENTATION_BLOB | (colourise ? SC_REPRESENTATION_COLOUR : 0));
        if (colourise) NPPSci(ed, SCI_SETREPRESENTATIONCOLOUR, (uptr_t)r.utf8, colour);
    }
    // N++ redraws through showEOL(isShownEol()) because the first line is not repainted otherwise.
    NPPSci(ed, SCI_SETVIEWEOL, NPPSci(ed, SCI_GETVIEWEOL));
}

// ---------------------------------------------------------------- Post-It
// N++ Notepad_plus::postItToggle swaps the window to WS_POPUP + topmost and hides every piece of chrome; the macOS
// equivalent is a borderless floating window. NSWindowStyleMaskResizable stays in the mask because AppKit only
// lets a window become key when it has a title bar or a resize bar — drop it and the editor cannot take a key.
// ponytail: window chrome only. The tab bar cannot be hidden from here — -layoutContent recomputes its `hidden`
// flag from the window controller's own distraction-free state on every layout pass, so anything we set is undone
// by the next resize; the upgrade is that method learning about Post-It, which is that file's to add.
static struct {
    BOOL on;
    NSWindowStyleMask mask;
    NSInteger level;
    BOOL movableByBackground;
} gPostIt;

static BOOL postItToggle(NSWindow *w) {
    if (!w) return NO;
    NSResponder *responder = w.firstResponder;
    if (!gPostIt.on) {
        gPostIt.mask = w.styleMask;
        gPostIt.level = w.level;
        gPostIt.movableByBackground = w.movableByWindowBackground;
        w.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable;
        w.level = NSFloatingWindowLevel;
        w.movableByWindowBackground = YES;   // there is no title bar left to drag it by
        gPostIt.on = YES;
    } else {
        w.styleMask = gPostIt.mask;
        w.level = gPostIt.level;
        w.movableByWindowBackground = gPostIt.movableByBackground;
        gPostIt.on = NO;
    }
    // The frame is left where it is, as N++ leaves it (SetWindowPos SWP_NOMOVE|SWP_NOSIZE): the window does not
    // move and the content area gains or loses the title bar strip. Restoring the pre-Post-It frame would throw
    // away wherever the user parked the note, which is the whole point of the mode.
    [w makeKeyAndOrderFront:nil];
    // Changing the style mask rebuilds the window's frame view and can drop the first responder with it.
    if ([responder isKindOfClass:NSView.class] && ((NSView *)responder).window == w) [w makeFirstResponder:responder];
    relayoutHostWindow();   // the content view resized without the window doing so, so no windowDidResize: fires
    return YES;
}

// ---------------------------------------------------------------- Copy Styled Text (N++ markedTextToClipboard)
// The styled *ranges*, not the lines that carry them. Runs of one indicator are already in document order; the
// "All Styles" variant merges five indicators and sorts by start position.
// maxRuns stops the walk early: menu validation only asks "is anything styled?", and a Mark All over a large
// document can leave six figures of runs to collect on every menu open otherwise.
static std::vector<std::pair<sptr_t, sptr_t>> indicatorRuns(ScintillaView *ed, int indicator, size_t maxRuns = 0) {
    std::vector<std::pair<sptr_t, sptr_t>> runs;
    sptr_t len = NPPSci(ed, SCI_GETLENGTH), pos = 0;
    while (pos < len) {
        sptr_t end = NPPSci(ed, SCI_INDICATOREND, (uptr_t)indicator, pos);
        if (end <= pos) break;   // 0 when the indicator was never used in this document
        if (NPPSci(ed, SCI_INDICATORVALUEAT, (uptr_t)indicator, pos)) {
            runs.push_back({pos, end});
            if (maxRuns && runs.size() >= maxRuns) break;
        }
        pos = end;
    }
    return runs;
}

// N++ joins the pieces with an EOL, or with a "----" rule when a piece itself spans lines and there is more than
// one — otherwise a multi-line piece would be indistinguishable from the separator. Empty means "leave the
// clipboard alone" (N++ only calls str2Clipboard when something was styled).
// ponytail: "\n" where N++ writes "\r\n"; the port's clipboard is Unix-EOL like the rest of it.
static NSString *joinStyledPieces(std::vector<std::pair<sptr_t, std::string>> pieces, BOOL sortByPosition) {
    if (pieces.empty()) return nil;
    if (sortByPosition) std::sort(pieces.begin(), pieces.end());
    BOOL anySpansLines = NO;
    for (const auto &p : pieces)
        if (p.second.find('\r') != std::string::npos || p.second.find('\n') != std::string::npos) anySpansLines = YES;
    const std::string delim = (anySpansLines && pieces.size() > 1) ? "\n----\n" : "\n";
    std::string joined = pieces[0].second;
    for (size_t i = 1; i < pieces.size(); i++) joined += delim + pieces[i].second;
    if (pieces.size() > 1) joined += "\n";
    return utf8String(joined);
}

// Which indicators one "Copy Styled Text" item covers: one mark style, all five, or the Find Mark style.
static int styleClipIndicators(NPPCmd cmd, int *buf) {   // returns how many were written into buf (max 5)
    if (cmd == NPPCmdSearchMarkedToClip) { buf[0] = NPPIndicatorFindMark; return 1; }
    if (cmd == NPPCmdSearchAllStylesToClip) {
        for (int i = 0; i < 5; i++) buf[i] = NPPIndicatorMarkExt1 - i;
        return 5;
    }
    buf[0] = indicatorForExt(cmd, NPPCmdSearchStyleToClipBase);
    return 1;
}
static BOOL anyIndicatorRun(ScintillaView *ed, const int *indicators, int count) {
    for (int i = 0; i < count; i++)
        if (!indicatorRuns(ed, indicators[i], 1).empty()) return YES;
    return NO;
}

static NSString *markedTextForIndicators(ScintillaView *ed, const int *indicators, int count) {
    std::vector<std::pair<sptr_t, std::string>> pieces;
    for (int i = 0; i < count; i++)
        for (const auto &run : indicatorRuns(ed, indicators[i]))
            pieces.emplace_back(run.first, NPPSciGetRange(ed, run.first, run.second));
    return joinStyledPieces(std::move(pieces), count > 1);
}

// ---------------------------------------------------------------- Find characters in range
// N++ FindCharsInRangeDlg::findCharInRange scans the raw document *bytes* (the range is 0..255), so "non-ASCII"
// means any byte of a multi-byte UTF-8 character; Scintilla snaps the resulting selection to a character boundary.
// Returns the byte offset, or -1.
static sptr_t findCharInRange(const std::string &text, sptr_t startPos, int begin, int end, BOOL backward, BOOL wrap) {
    const sptr_t n = (sptr_t)text.size();
    if (startPos < 0) startPos = backward ? n - 1 : 0;
    if (startPos > n) return -1;
    auto inRange = [&](sptr_t i) {
        unsigned char c = (unsigned char)text[(size_t)i];
        return c >= (unsigned)begin && c <= (unsigned)end;
    };
    for (sptr_t i = startPos - (backward ? 1 : 0); backward ? i >= 0 : i < n; backward ? --i : ++i)
        if (inRange(i)) return i;
    if (!wrap) return -1;
    for (sptr_t i = backward ? n - 1 : 0; backward ? i >= 0 : i < n; backward ? --i : ++i)
        if (inRange(i)) return i;
    return -1;
}

static BOOL findCharInRangeInEditor(ScintillaView *ed, int begin, int end, BOOL backward, BOOL wrap) {
    std::string text = NPPSciGetText(ed);
    sptr_t found = findCharInRange(text, NPPSci(ed, SCI_GETCURRENTPOS), begin, end, backward, wrap);
    if (found < 0) return NO;
    NPPSci(ed, SCI_ENSUREVISIBLE, (uptr_t)NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)found));
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)found);
    NPPSci(ed, SCI_SETSEL, (uptr_t)(backward ? found + 1 : found), backward ? found : found + 1);
    return YES;
}

static void showFindCharsInRangeSheet(ScintillaView *ed);   // defined with its sheet class at the end of the file

// Brace matching (N++ findMatchingBracePos): brace at caret, else before caret.
static BOOL findBraces(ScintillaView *ed, sptr_t *atCaret, sptr_t *opposite) {
    sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    auto isBrace = [](int c) { return c && strchr("[](){}", c) != NULL; };   // N++ findMatchingBracePos: no <>
    *atCaret = -1; *opposite = -1;
    if (caret > 0 && isBrace((int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)(caret - 1)))) *atCaret = caret - 1;
    if (*atCaret < 0 && isBrace((int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)caret))) *atCaret = caret;   // N++ priority: char BEFORE the caret
    if (*atCaret < 0) return NO;
    *opposite = NPPSci(ed, SCI_BRACEMATCH, (uptr_t)*atCaret, 0);
    return *opposite >= 0;
}

// Fold header for a line: the line itself if it is a header, else its parent (-1 if none).
static sptr_t foldHeaderFor(ScintillaView *ed, sptr_t line) {
    if (NPPSci(ed, SCI_GETFOLDLEVEL, (uptr_t)line) & SC_FOLDLEVELHEADERFLAG) return line;
    return NPPSci(ed, SCI_GETFOLDPARENT, (uptr_t)line);
}
static void foldLevel(ScintillaView *ed, int level, BOOL contract) {
    sptr_t n = lineCount(ed);
    // ponytail: O(lines) SCI_GETFOLDLEVEL scan like N++; fine up to millions of lines (N++ disables redraw above 10k, we can't).
    for (sptr_t l = 0; l < n; l++) {
        sptr_t lv = NPPSci(ed, SCI_GETFOLDLEVEL, (uptr_t)l);
        if ((lv & SC_FOLDLEVELHEADERFLAG) && ((lv & SC_FOLDLEVELNUMBERMASK) - SC_FOLDLEVELBASE) == level) {
            BOOL expanded = NPPSci(ed, SCI_GETFOLDEXPANDED, (uptr_t)l) != 0;
            if (expanded == contract) NPPSci(ed, SCI_FOLDLINE, (uptr_t)l, contract ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND);
        }
    }
}

// Hide lines (N++ ScintillaEditView::hideLines, simplified).
static void hideLines(ScintillaView *ed) {
    sptr_t start = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(ed, SCI_GETSELECTIONSTART));
    sptr_t end = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(ed, SCI_GETSELECTIONEND));
    sptr_t n = lineCount(ed);
    if (n < 3) { NSBeep(); return; }
    if (start == 0) start++;
    if (end == n - 1) end--;
    if (start > end) { NSBeep(); return; }   // whole doc or an edge line: nothing hideable
    sptr_t startMarker = start - 1, endMarker = end + 1;
    // ponytail: N++ merges with adjacent hidden sections by walking marker scopes; we just drop stale markers inside the range.
    for (sptr_t l = startMarker; l <= endMarker; l++) {
        NPPSci(ed, SCI_MARKERDELETE, (uptr_t)l, NPPMarkerHideLinesBegin);
        NPPSci(ed, SCI_MARKERDELETE, (uptr_t)l, NPPMarkerHideLinesEnd);
        NPPSci(ed, SCI_MARKERDELETE, (uptr_t)l, NPPMarkerHideLinesUnderline);
    }
    NPPSci(ed, SCI_HIDELINES, (uptr_t)start, end);
    NPPSci(ed, SCI_MARKERADD, (uptr_t)startMarker, NPPMarkerHideLinesBegin);
    NPPSci(ed, SCI_MARKERADD, (uptr_t)startMarker, NPPMarkerHideLinesUnderline);
    NPPSci(ed, SCI_MARKERADD, (uptr_t)endMarker, NPPMarkerHideLinesEnd);
    NPPSci(ed, SCI_GOTOLINE, (uptr_t)startMarker);
}

// Change history navigation (N++ changedHistoryGoTo): skip the contiguous changed block the caret is in, wrap.
static void changedGoTo(ScintillaView *ed, BOOL next) {
    sptr_t cur = lineOfCaret(ed), n = lineCount(ed);
    sptr_t target = -1;
    if (next) {
        sptr_t l = cur;
        if (NPPSci(ed, SCI_MARKERGET, (uptr_t)l) & kChangeHistoryMask)   // leave the current block
            while (l < n && (NPPSci(ed, SCI_MARKERGET, (uptr_t)l) & kChangeHistoryMask)) l++;
        target = l < n ? NPPSci(ed, SCI_MARKERNEXT, (uptr_t)l, kChangeHistoryMask) : -1;
        if (target < 0) target = NPPSci(ed, SCI_MARKERNEXT, 0, kChangeHistoryMask);
    } else {
        sptr_t l = cur;
        if (NPPSci(ed, SCI_MARKERGET, (uptr_t)l) & kChangeHistoryMask)
            while (l >= 0 && (NPPSci(ed, SCI_MARKERGET, (uptr_t)l) & kChangeHistoryMask)) l--;
        target = l >= 0 ? NPPSci(ed, SCI_MARKERPREVIOUS, (uptr_t)l, kChangeHistoryMask) : -1;
        if (target < 0) target = NPPSci(ed, SCI_MARKERPREVIOUS, (uptr_t)(n - 1), kChangeHistoryMask);
        // Prev lands on the last line of a block; N++ goes to the block's first line.
        while (target > 0 && (NPPSci(ed, SCI_MARKERGET, (uptr_t)(target - 1)) & kChangeHistoryMask)) target--;
    }
    if (target < 0) { NSBeep(); return; }
    gotoLineVisible(ed, target);
}

static void clearChangeHistory(ScintillaView *ed) {
    sptr_t pos = NPPSci(ed, SCI_GETCURRENTPOS);
    sptr_t flags = NPPSci(ed, SCI_GETCHANGEHISTORY);
    if (!NPPSci(ed, SCI_GETMODIFY)) NPPSci(ed, SCI_EMPTYUNDOBUFFER);   // Scintilla requires an empty undo buffer to reset history
    NPPSci(ed, SCI_SETCHANGEHISTORY, SC_CHANGE_HISTORY_DISABLED);
    NPPSci(ed, SCI_SETCHANGEHISTORY, (uptr_t)flags);
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)pos);
}

// Counting for Summary: code points (excluding EOL bytes) and [[:alnum:]_]+ words, one pass over UTF-8.
static void countText(const std::string &s, long long *chars, long long *words) {
    long long c = 0, w = 0; bool inWord = false;
    for (unsigned char b : s) {
        if (b == '\r' || b == '\n') { inWord = false; continue; }
        if ((b & 0xC0) != 0x80) c++;   // count lead bytes only
        bool wc = isalnum(b) || b == '_' || b >= 0x80;   // ponytail: non-ASCII bytes count as word chars (no Unicode classes)
        if (wc && !inWord) w++;
        inWord = wc;
    }
    *chars = c; *words = w;
}

@implementation NPPSearchViewCommands

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    switch (cmd) {
        case NPPCmdSearchGoToMatchingBrace: case NPPCmdSearchSelectBetweenBraces:
        case NPPCmdSearchChangedNext: case NPPCmdSearchChangedPrev: case NPPCmdSearchClearChangeHistory:
        case NPPCmdSearchClearAllMarks:
        case NPPCmdSearchToggleBookmark: case NPPCmdSearchNextBookmark: case NPPCmdSearchPrevBookmark: case NPPCmdSearchClearBookmarks:
        case NPPCmdSearchCutBookmarkedLines: case NPPCmdSearchCopyBookmarkedLines: case NPPCmdSearchPasteToBookmarkedLines:
        case NPPCmdSearchRemoveBookmarkedLines: case NPPCmdSearchRemoveNonBookmarkedLines: case NPPCmdSearchInverseBookmarks:
        case NPPCmdViewShowSpaceTab: case NPPCmdViewShowEOL: case NPPCmdViewShowNonPrinting: case NPPCmdViewShowAllChars:
        case NPPCmdViewShowIndentGuide: case NPPCmdViewShowWrapSymbol: case NPPCmdViewWordWrap:
        case NPPCmdViewZoomIn: case NPPCmdViewZoomOut: case NPPCmdViewZoomRestore:
        case NPPCmdViewHideLines: case NPPCmdViewFoldAll: case NPPCmdViewUnfoldAll: case NPPCmdViewFoldCurrent: case NPPCmdViewUnfoldCurrent:
        case NPPCmdViewSummary: case NPPCmdViewTextDirectionRTL: case NPPCmdViewTextDirectionLTR:
        case NPPCmdSearchAllStylesToClip: case NPPCmdSearchMarkedToClip: case NPPCmdSearchFindCharsInRange:
        case NPPCmdViewNonPrintingChars: case NPPCmdViewNPCControlChars: case NPPCmdViewPostIt:
        case NPPCmdViewTabMoveToStart: case NPPCmdViewTabMoveToEnd:
            return YES;
        default:
            return (cmd >= NPPCmdSearchMarkAllExt1 && cmd <= NPPCmdSearchUnmarkAllExt5) ||
                   (cmd >= NPPCmdSearchGoPrevMarker1 && cmd <= NPPCmdSearchGoNextMarkerDef) ||
                   (cmd >= NPPCmdViewFoldLevel1 && cmd <= NPPCmdViewUnfoldLevel8) ||
                   (cmd >= NPPCmdSearchStyleToClipBase && cmd < NPPCmdSearchAllStylesToClip) ||
                   (cmd >= NPPCmdViewInBrowserBase && cmd <= NPPCmdViewInBrowserBase + 4);
    }
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor {
    if (![self handlesCommand:cmd]) return NO;
    if (cmd >= NPPCmdViewInBrowserBase && cmd <= NPPCmdViewInBrowserBase + 4)
        return currentFileOnDisk() != nil && browserApplicationURL(cmd - NPPCmdViewInBrowserBase) != nil;
    switch (cmd) {
        case NPPCmdViewTextDirectionRTL: case NPPCmdViewTextDirectionLTR: return NO;   // Scintilla Cocoa has no bidi
        case NPPCmdViewShowSpaceTab: case NPPCmdViewShowEOL: case NPPCmdViewShowNonPrinting: case NPPCmdViewShowAllChars:
        case NPPCmdViewShowIndentGuide: case NPPCmdViewShowWrapSymbol: case NPPCmdViewWordWrap:
        case NPPCmdViewNonPrintingChars: return YES;
        // The C1 / Unicode-EOL half rides on the non-printing preference — that is how NPPPreferences writes it,
        // and the Preferences page greys its own checkbox for the same reason — so it is dead while that is off.
        case NPPCmdViewNPCControlChars: return NPPPreferences.shared.showNonPrintingChars;
        case NPPCmdViewPostIt: {
            // Swapping the style mask of a full-screen window is not allowed; N++ refuses the same overlap.
            NSWindow *w = [gContext contextWindow];
            return w != nil && (w.styleMask & NSWindowStyleMaskFullScreen) == 0;
        }
        case NPPCmdViewTabMoveToStart: case NPPCmdViewTabMoveToEnd:
            return tabMoveTarget(cmd == NPPCmdViewTabMoveToEnd, NULL) != NSNotFound;
        default: break;
    }
    if (!editor) return NO;
    // Copy Styled Text: N++ leaves the clipboard untouched when nothing carries the style, which would be a menu
    // item that looks enabled and does nothing — so it is disabled instead.
    if (cmd >= NPPCmdSearchStyleToClipBase && cmd <= NPPCmdSearchMarkedToClip) {
        int indicators[5];
        return anyIndicatorRun(editor, indicators, styleClipIndicators(cmd, indicators));
    }
    switch (cmd) {
        case NPPCmdSearchFindCharsInRange: {   // needs a window to host the sheet, and only one sheet at a time
            NSWindow *w = [gContext contextWindow];
            return w != nil && w.attachedSheet == nil;
        }
        case NPPCmdSearchChangedNext: case NPPCmdSearchChangedPrev: case NPPCmdSearchClearChangeHistory:
            return NPPSci(editor, SCI_GETCHANGEHISTORY) != SC_CHANGE_HISTORY_DISABLED;
        case NPPCmdSearchCutBookmarkedLines: case NPPCmdSearchPasteToBookmarkedLines:
        case NPPCmdSearchRemoveBookmarkedLines: case NPPCmdSearchRemoveNonBookmarkedLines: case NPPCmdViewHideLines:
            return !isReadOnly(editor);
        case NPPCmdSearchGoToMatchingBrace: case NPPCmdSearchSelectBetweenBraces: {
            sptr_t a, b; return findBraces(editor, &a, &b);
        }
        default: return YES;
    }
}

// N++ Show All Characters is the four symbol toggles at once and is ticked only when all four are on.
static BOOL allCharactersShown(void) {
    NPPPreferences *p = NPPPreferences.shared;
    return p.showWhitespace && p.showEOL && p.showNonPrintingChars && p.nonPrintingIncludeC1AndUnicodeEOL;
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd onEditor:(ScintillaView *)editor {
    NPPPreferences *p = NPPPreferences.shared;
    switch (cmd) {
        case NPPCmdViewShowSpaceTab: return p.showWhitespace;
        case NPPCmdViewShowEOL: return p.showEOL;
        // The Show Symbol menu carries two items for the non-printing set (the port's original one and the one
        // that matches N++'s IDM_VIEW_NPC); they are the same state, so both tick and untick together.
        case NPPCmdViewShowNonPrinting: case NPPCmdViewNonPrintingChars: return p.showNonPrintingChars;
        case NPPCmdViewNPCControlChars: return p.nonPrintingIncludeC1AndUnicodeEOL;
        case NPPCmdViewShowAllChars: return allCharactersShown();
        case NPPCmdViewShowIndentGuide: return p.showIndentGuides;
        case NPPCmdViewShowWrapSymbol: return p.showWrapSymbol;
        case NPPCmdViewWordWrap: return p.wordWrap;
        case NPPCmdViewPostIt: return gPostIt.on;
        default: return NO;
    }
}

+ (BOOL)performCommand:(NPPCmd)cmd onEditor:(ScintillaView *)editor {
    if (![self handlesCommand:cmd]) return NO;
    NPPPreferences *p = NPPPreferences.shared;
    if (cmd >= NPPCmdViewInBrowserBase && cmd <= NPPCmdViewInBrowserBase + 4) {
        NSURL *file = currentFileOnDisk(), *app = browserApplicationURL(cmd - NPPCmdViewInBrowserBase);
        if (!file || !app) { NSBeep(); return YES; }
        [NSWorkspace.sharedWorkspace openURLs:@[file] withApplicationAtURL:app
                                configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
        return YES;
    }
    // Pref toggles work without an editor (documents re-apply on the prefs notification); so do the window and
    // tab-strip commands, which go through the context rather than the editor.
    switch (cmd) {
        case NPPCmdViewShowSpaceTab: p.showWhitespace = !p.showWhitespace; return YES;
        case NPPCmdViewShowEOL: p.showEOL = !p.showEOL; return YES;
        // Every preference setter posts NPPPreferencesDidChangeNotification, which is what re-applies the
        // representations to every open buffer: NPPPreferences' half through NPPDocument, this file's through
        // the observer in +load. Nothing to do here but flip the state.
        case NPPCmdViewShowNonPrinting: case NPPCmdViewNonPrintingChars:
            p.showNonPrintingChars = !p.showNonPrintingChars; return YES;
        case NPPCmdViewNPCControlChars:
            p.nonPrintingIncludeC1AndUnicodeEOL = !p.nonPrintingIncludeC1AndUnicodeEOL; return YES;
        case NPPCmdViewShowAllChars: {
            BOOL on = !allCharactersShown();
            p.showWhitespace = on; p.showEOL = on; p.showNonPrintingChars = on; p.nonPrintingIncludeC1AndUnicodeEOL = on;
            return YES;
        }
        case NPPCmdViewShowIndentGuide: p.showIndentGuides = !p.showIndentGuides; return YES;
        case NPPCmdViewShowWrapSymbol: p.showWrapSymbol = !p.showWrapSymbol; return YES;
        case NPPCmdViewWordWrap: p.wordWrap = !p.wordWrap; return YES;
        case NPPCmdViewTextDirectionRTL: case NPPCmdViewTextDirectionLTR: NSBeep(); return YES;
        case NPPCmdViewPostIt: if (!postItToggle([gContext contextWindow])) NSBeep(); return YES;
        case NPPCmdViewTabMoveToStart: case NPPCmdViewTabMoveToEnd: {
            NPPTabBarView *bar = nil;
            NSInteger dest = tabMoveTarget(cmd == NPPCmdViewTabMoveToEnd, &bar);
            if (dest == NSNotFound) NSBeep();
            else [(id<NPPHostWindow>)gContext moveDocumentAtIndex:bar.selectedIndex toIndex:dest];
            return YES;
        }
        default: break;
    }
    if (!editor) return NO;

    if (cmd >= NPPCmdSearchStyleToClipBase && cmd <= NPPCmdSearchMarkedToClip) {
        int indicators[5];
        NSString *styled = markedTextForIndicators(editor, indicators, styleClipIndicators(cmd, indicators));
        if (styled) setPasteboard(styled); else NSBeep();   // N++ leaves the clipboard alone when nothing is styled
        return YES;
    }
    if (cmd == NPPCmdSearchFindCharsInRange) { showFindCharsInRangeSheet(editor); return YES; }

    if (cmd >= NPPCmdSearchMarkAllExt1 && cmd <= NPPCmdSearchMarkAllExt5) { [self markAllOccurrencesOfSelection:editor indicator:indicatorForExt(cmd, NPPCmdSearchMarkAllExt1)]; return YES; }
    if (cmd >= NPPCmdSearchMarkOneExt1 && cmd <= NPPCmdSearchMarkOneExt5) { [self markOneOccurrence:editor indicator:indicatorForExt(cmd, NPPCmdSearchMarkOneExt1)]; return YES; }
    if (cmd >= NPPCmdSearchUnmarkAllExt1 && cmd <= NPPCmdSearchUnmarkAllExt5) { [self clearIndicator:indicatorForExt(cmd, NPPCmdSearchUnmarkAllExt1) onEditor:editor]; return YES; }
    if (cmd >= NPPCmdSearchGoPrevMarker1 && cmd <= NPPCmdSearchGoNextMarkerDef) {
        BOOL backward = cmd <= NPPCmdSearchGoPrevMarkerDef;
        NPPCmd base = backward ? NPPCmdSearchGoPrevMarker1 : NPPCmdSearchGoNextMarker1;
        int ind = (cmd == NPPCmdSearchGoPrevMarkerDef || cmd == NPPCmdSearchGoNextMarkerDef) ? NPPIndicatorFindMark : indicatorForExt(cmd, base);
        if (![self goToNextIndicator:ind onEditor:editor backward:backward wrap:YES]) NSBeep();
        return YES;
    }
    if (cmd >= NPPCmdViewFoldLevel1 && cmd <= NPPCmdViewFoldLevel8) { foldLevel(editor, (int)(cmd - NPPCmdViewFoldLevel1), YES); return YES; }
    if (cmd >= NPPCmdViewUnfoldLevel1 && cmd <= NPPCmdViewUnfoldLevel8) { foldLevel(editor, (int)(cmd - NPPCmdViewUnfoldLevel1), NO); return YES; }

    switch (cmd) {
        case NPPCmdSearchGoToMatchingBrace: [self braceMatchCommand:editor selectBetween:NO]; break;
        case NPPCmdSearchSelectBetweenBraces: [self braceMatchCommand:editor selectBetween:YES]; break;
        case NPPCmdSearchChangedNext: changedGoTo(editor, YES); break;
        case NPPCmdSearchChangedPrev: changedGoTo(editor, NO); break;
        case NPPCmdSearchClearChangeHistory: clearChangeHistory(editor); break;
        case NPPCmdSearchClearAllMarks:
            for (int ind = NPPIndicatorMarkExt5; ind <= NPPIndicatorMarkExt1; ind++) [self clearIndicator:ind onEditor:editor];
            [self clearIndicator:NPPIndicatorFindMark onEditor:editor];
            break;
        case NPPCmdSearchToggleBookmark: [self toggleBookmarkOnCurrentLine:editor]; break;
        case NPPCmdSearchNextBookmark: if (![self goToBookmark:editor next:YES]) NSBeep(); break;
        case NPPCmdSearchPrevBookmark: if (![self goToBookmark:editor next:NO]) NSBeep(); break;
        case NPPCmdSearchClearBookmarks: NPPSci(editor, SCI_MARKERDELETEALL, NPPMarkerBookmark); break;
        case NPPCmdSearchCopyBookmarkedLines: setPasteboard(joinLines(editor, bookmarkedLines(editor))); break;
        case NPPCmdSearchCutBookmarkedLines: {
            if (isReadOnly(editor)) { NSBeep(); break; }
            setPasteboard(joinLines(editor, bookmarkedLines(editor)));
            deleteLinesWhere(editor, YES);
            break;
        }
        case NPPCmdSearchPasteToBookmarkedLines: {
            if (isReadOnly(editor)) { NSBeep(); break; }
            NSString *clip = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            if (!clip) { NSBeep(); break; }
            // ponytail: i-th clipboard line -> i-th bookmarked line (spec); N++ itself pastes the whole clipboard into every bookmarked line.
            NSString *norm = [[clip stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
            NSMutableArray<NSString *> *clipLines = [[norm componentsSeparatedByString:@"\n"] mutableCopy];
            if (clipLines.count > 1 && clipLines.lastObject.length == 0) [clipLines removeLastObject];   // trailing EOL
            std::vector<sptr_t> lines = bookmarkedLines(editor);
            NPPSci(editor, SCI_BEGINUNDOACTION);
            for (size_t i = lines.size(); i-- > 0;) {   // bottom-up so positions above stay valid
                if (i >= clipLines.count) continue;
                sptr_t begin = NPPSci(editor, SCI_POSITIONFROMLINE, (uptr_t)lines[i]);
                sptr_t end = NPPSci(editor, SCI_GETLINEENDPOSITION, (uptr_t)lines[i]);
                NPPSci(editor, SCI_SETTARGETRANGE, (uptr_t)begin, end);
                NPPSciStr(editor, SCI_REPLACETARGET, (uptr_t)-1, clipLines[i].UTF8String);
            }
            NPPSci(editor, SCI_ENDUNDOACTION);
            break;
        }
        case NPPCmdSearchRemoveBookmarkedLines: if (isReadOnly(editor)) NSBeep(); else deleteLinesWhere(editor, YES); break;
        case NPPCmdSearchRemoveNonBookmarkedLines: if (isReadOnly(editor)) NSBeep(); else deleteLinesWhere(editor, NO); break;
        case NPPCmdSearchInverseBookmarks: {
            sptr_t n = lineCount(editor);
            for (sptr_t l = 0; l < n; l++) {
                if (hasBookmark(editor, l)) NPPSci(editor, SCI_MARKERDELETE, (uptr_t)l, NPPMarkerBookmark);
                else NPPSci(editor, SCI_MARKERADD, (uptr_t)l, NPPMarkerBookmark);
            }
            break;
        }
        // One step on this editor first, so Scintilla applies its own ±ceiling, then read back what it settled on
        // and give every other buffer (and the next launch) the same number.
        case NPPCmdViewZoomIn: case NPPCmdViewZoomOut: case NPPCmdViewZoomRestore:
            NPPSci(editor, cmd == NPPCmdViewZoomIn ? SCI_ZOOMIN : cmd == NPPCmdViewZoomOut ? SCI_ZOOMOUT : SCI_SETZOOM, 0);
            spreadZoom(NPPSci(editor, SCI_GETZOOM), [gContext contextOpenDocuments], editor);
            break;
        case NPPCmdViewHideLines: if (isReadOnly(editor)) NSBeep(); else hideLines(editor); break;
        case NPPCmdViewFoldAll: NPPSci(editor, SCI_FOLDALL, SC_FOLDACTION_CONTRACT | SC_FOLDACTION_CONTRACT_EVERY_LEVEL); break;
        case NPPCmdViewUnfoldAll: NPPSci(editor, SCI_FOLDALL, SC_FOLDACTION_EXPAND); NPPSci(editor, SCI_SCROLLCARET); break;
        case NPPCmdViewFoldCurrent: case NPPCmdViewUnfoldCurrent: {
            sptr_t header = foldHeaderFor(editor, lineOfCaret(editor));
            if (header < 0) { NSBeep(); break; }
            // "Make current level folding/unfolding commands toggleable": both items then act on the same fold,
            // so pressing either one twice folds and unfolds it (upstream NppGUI::_enableFoldCmdToggable).
            int action = NPPPreferences.shared.foldingCommandsToggleable
                       ? SC_FOLDACTION_TOGGLE
                       : (cmd == NPPCmdViewFoldCurrent ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND);
            NPPSci(editor, SCI_FOLDLINE, (uptr_t)header, action);
            if (action != SC_FOLDACTION_EXPAND && !NPPSci(editor, SCI_GETFOLDEXPANDED, (uptr_t)header))
                NPPSci(editor, SCI_GOTOLINE, (uptr_t)header);   // the caret must not stay inside a fold it can no longer see
            break;
        }
        case NPPCmdViewSummary: {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Summary";
            alert.informativeText = [self summaryText:editor];
            alert.alertStyle = NSAlertStyleInformational;
            [alert runModal];
            break;
        }
        default: return NO;
    }
    return YES;
}

#pragma mark - Reusable pieces

+ (void)markAllOccurrencesOfSelection:(ScintillaView *)editor indicator:(int)indicator {
    if (!editor) return;
    BOOL wholeWord = NO;
    NSString *text = tokenText(editor, &wholeWord);
    if (text.length == 0) { NSBeep(); return; }
    const char *utf8 = text.UTF8String;
    sptr_t len = (sptr_t)strlen(utf8), docLen = NPPSci(editor, SCI_GETLENGTH);
    // "Style All Occurrences of Token" is configurable upstream; the token itself still decides whether whole-word
    // is even meaningful (a symbol like "->" has no word boundary), so the preference can only narrow it.
    NPPPreferences *prefs = NPPPreferences.shared;
    int flags = (prefs.markAllMatchCase ? SCFIND_MATCHCASE : 0) | ((wholeWord && prefs.markAllWholeWord) ? SCFIND_WHOLEWORD : 0);
    NPPSci(editor, SCI_SETSEARCHFLAGS, flags);
    sptr_t pos = 0;
    while (pos < docLen) {
        NPPSci(editor, SCI_SETTARGETRANGE, (uptr_t)pos, docLen);
        sptr_t found = NPPSci(editor, SCI_SEARCHINTARGET, (uptr_t)len, (sptr_t)utf8);
        if (found < 0) break;
        sptr_t end = NPPSci(editor, SCI_GETTARGETEND);
        fillIndicator(editor, indicator, found, end);
        pos = end > found ? end : found + 1;
    }
}

+ (void)markOneOccurrence:(ScintillaView *)editor indicator:(int)indicator {
    if (!editor) return;
    sptr_t a = NPPSci(editor, SCI_GETSELECTIONSTART), b = NPPSci(editor, SCI_GETSELECTIONEND);
    if (a == b) {
        sptr_t pos = NPPSci(editor, SCI_GETCURRENTPOS);
        a = NPPSci(editor, SCI_WORDSTARTPOSITION, (uptr_t)pos, 1);
        b = NPPSci(editor, SCI_WORDENDPOSITION, (uptr_t)pos, 1);
    }
    if (a == b) { NSBeep(); return; }
    fillIndicator(editor, indicator, a, b);
}

+ (void)clearIndicator:(int)indicator onEditor:(ScintillaView *)editor {
    if (!editor) return;
    NPPSci(editor, SCI_SETINDICATORCURRENT, (uptr_t)indicator);
    NPPSci(editor, SCI_INDICATORCLEARRANGE, 0, NPPSci(editor, SCI_GETLENGTH));
}

+ (BOOL)goToNextIndicator:(int)indicator onEditor:(ScintillaView *)editor backward:(BOOL)backward wrap:(BOOL)wrap {
    if (!editor) return NO;
    sptr_t docLen = NPPSci(editor, SCI_GETLENGTH);
    if (docLen == 0) return NO;
    sptr_t selStart = NPPSci(editor, SCI_GETSELECTIONSTART), selEnd = NPPSci(editor, SCI_GETSELECTIONEND);
    auto valueAt = [&](sptr_t p) { return NPPSci(editor, SCI_INDICATORVALUEAT, (uptr_t)indicator, p) != 0; };
    // Runs are [SCI_INDICATORSTART, SCI_INDICATOREND) of alternating on/off; walk them, O(runs).
    auto forwardFrom = [&](sptr_t p, sptr_t limit) -> sptr_t {   // first marked run starting in [p, limit); a run already containing p is skipped
        if (p > 0 && valueAt(p) && valueAt(p - 1)) p = NPPSci(editor, SCI_INDICATOREND, (uptr_t)indicator, p);
        while (p < limit) {
            if (valueAt(p)) return p;
            sptr_t next = NPPSci(editor, SCI_INDICATOREND, (uptr_t)indicator, p);
            if (next <= p) break;
            p = next;
        }
        return -1;
    };
    auto backwardFrom = [&](sptr_t p, sptr_t limit) -> sptr_t {   // last marked run whose start is < p and >= limit
        while (p > limit) {
            sptr_t q = p - 1;
            if (valueAt(q)) {
                sptr_t s = NPPSci(editor, SCI_INDICATORSTART, (uptr_t)indicator, q);
                if (s >= limit) return s;
                return -1;
            }
            sptr_t prev = NPPSci(editor, SCI_INDICATORSTART, (uptr_t)indicator, q);   // start of this unmarked run
            if (prev >= p) break;
            p = prev;
        }
        return -1;
    };
    sptr_t start = -1;
    if (!backward) {
        start = forwardFrom(selEnd, docLen);
        if (start < 0 && wrap) start = forwardFrom(0, selEnd);
    } else {
        start = backwardFrom(selStart, 0);
        if (start < 0 && wrap) start = backwardFrom(docLen, selStart);
    }
    if (start < 0) return NO;
    sptr_t end = NPPSci(editor, SCI_INDICATOREND, (uptr_t)indicator, start);
    if (end <= start) end = start + 1;
    NPPSci(editor, SCI_SETSEL, (uptr_t)start, end);
    NPPSci(editor, SCI_SCROLLCARET);
    return YES;
}

+ (void)toggleBookmarkOnCurrentLine:(ScintillaView *)editor {
    if (!editor) return;
    sptr_t line = lineOfCaret(editor);
    if (hasBookmark(editor, line)) NPPSci(editor, SCI_MARKERDELETE, (uptr_t)line, NPPMarkerBookmark);
    else NPPSci(editor, SCI_MARKERADD, (uptr_t)line, NPPMarkerBookmark);
}

+ (BOOL)goToBookmark:(ScintillaView *)editor next:(BOOL)next {
    if (!editor) return NO;
    sptr_t line = lineOfCaret(editor);
    sptr_t found;
    if (next) {
        found = NPPSci(editor, SCI_MARKERNEXT, (uptr_t)(line + 1), kBookmarkMask);
        if (found < 0) found = NPPSci(editor, SCI_MARKERNEXT, 0, kBookmarkMask);
    } else {
        found = line > 0 ? NPPSci(editor, SCI_MARKERPREVIOUS, (uptr_t)(line - 1), kBookmarkMask) : -1;
        if (found < 0) found = NPPSci(editor, SCI_MARKERPREVIOUS, (uptr_t)(lineCount(editor) - 1), kBookmarkMask);
    }
    if (found < 0) return NO;
    gotoLineVisible(editor, found);
    return YES;
}

+ (void)braceMatchCommand:(ScintillaView *)editor selectBetween:(BOOL)selectBetween {
    if (!editor) return;
    sptr_t at, opp;
    if (!findBraces(editor, &at, &opp)) { NSBeep(); return; }
    if (selectBetween) NPPSci(editor, SCI_SETSEL, (uptr_t)(std::min(at, opp) + 1), std::max(at, opp));   // exclude the braces
    else NPPSci(editor, SCI_GOTOPOS, (uptr_t)opp);
    NPPSci(editor, SCI_CHOOSECARETX);
}

+ (NSString *)summaryText:(ScintillaView *)editor {
    if (!editor) return @"";
    long long chars = 0, words = 0;
    std::string all = NPPSciGetText(editor);
    countText(all, &chars, &words);
    sptr_t lines = lineCount(editor), docLen = NPPSci(editor, SCI_GETLENGTH);

    sptr_t nSel = NPPSci(editor, SCI_GETSELECTIONS);
    long long selChars = 0, selWords = 0, selLines = 0;
    for (sptr_t i = 0; i < nSel; i++) {
        sptr_t a = NPPSci(editor, SCI_GETSELECTIONNSTART, (uptr_t)i), b = NPPSci(editor, SCI_GETSELECTIONNEND, (uptr_t)i);
        if (a > b) std::swap(a, b);
        if (a == b) continue;
        long long c, w; countText(NPPSciGetRange(editor, a, b), &c, &w);
        selChars += c; selWords += w;
        selLines += NPPSci(editor, SCI_LINEFROMPOSITION, (uptr_t)b) - NPPSci(editor, SCI_LINEFROMPOSITION, (uptr_t)a) + 1;
    }
    return [NSString stringWithFormat:@"Characters (without line endings) : %@\nWords : %@\nLines : %@\nDocument length : %@\n\n"
                                      @"Current selection: Characters : %@  Words : %@  Lines : %@  Selections : %@",
            NPPFormatGroupedInteger(chars), NPPFormatGroupedInteger(words), NPPFormatGroupedInteger(lines), NPPFormatGroupedInteger(docLen),
            NPPFormatGroupedInteger(selChars), NPPFormatGroupedInteger(selWords), NPPFormatGroupedInteger(selLines), NPPFormatGroupedInteger(nSel)];
}

#pragma mark - Non-printing characters

+ (void)load {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NPPCommandContextReadyNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        gContext = n.object;
    }];
    // The toggle is global (N++ applies it to both edit views), so every open buffer follows. Driving it off the
    // preference notification rather than off the menu command means the Preferences page's own "Show non-printing
    // characters" checkbox moves these characters too — one writer, like NPPDocument does for its own settings.
    [nc addObserverForName:NPPPreferencesDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        for (NPPDocument *doc in [gContext contextOpenDocuments]) applyNonPrintingRepresentations(doc.editor);
    }];
    // A buffer created after the toggle (a new tab, a reopened file) gets them when it becomes current. With the
    // preference off there is nothing to clear — a fresh buffer never had them and turning it off already swept
    // every open one — so a tab switch costs nothing in the common case.
    [nc addObserverForName:NPPCurrentDocumentDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        // Zoom is the view's, so every buffer added, shown or reordered lands on the stored one. This is also the
        // "restore at launch" path (Notepad_plus.cpp:350): the first buffer to appear brings the whole set up.
        id<NPPCommandContext> ctx = n.object;
        syncZoomOnDocumentChange([ctx contextCurrentDocument], [ctx contextOpenDocuments]);
        if (!NPPPreferences.shared.showNonPrintingChars) return;
        applyNonPrintingRepresentations([(id<NPPCommandContext>)n.object contextCurrentDocument].editor);
    }];
    // …and the wheel zoom of the last buffer standing, which no tab switch will ever read back
    // (upstream calls saveScintillasZoom() on the way out, NppBigSwitch.cpp:2861).
    [nc addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        ScintillaView *ed = [gContext contextCurrentDocument].editor;
        if (ed) [NSUserDefaults.standardUserDefaults setInteger:NPPSci(ed, SCI_GETZOOM) forKey:kZoomDefaultsKey];
    }];
}

#pragma mark - Self-checks

// UTF-8 encoding of one code point, so each representation can be checked against the U+XXXX it claims to be —
// a mistyped byte in those two tables would otherwise label the wrong character (or no character at all).
static std::string utf8Encode(uint32_t cp) {
    std::string s;
    if (cp < 0x80) {
        s += (char)cp;
    } else if (cp < 0x800) {
        s += (char)(0xC0 | (cp >> 6)); s += (char)(0x80 | (cp & 0x3F));
    } else {
        s += (char)(0xE0 | (cp >> 12)); s += (char)(0x80 | ((cp >> 6) & 0x3F)); s += (char)(0x80 | (cp & 0x3F));
    }
    return s;   // nothing above the BMP is in either table
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(NSString *, BOOL) = ^(NSString *what, BOOL ok) { if (!ok) [fails addObject:what]; };
    void (^expectEq)(NSString *, long long, long long) = ^(NSString *what, long long got, long long want) {
        if (got != want) [fails addObject:[NSString stringWithFormat:@"%@: got %lld, want %lld", what, got, want]];
    };
    void (^expectStr)(NSString *, NSString *, NSString *) = ^(NSString *what, NSString *got, NSString *want) {
        if (![got isEqualToString:want]) [fails addObject:[NSString stringWithFormat:@"%@: got %@, want %@", what, got, want]];
    };

    // ---- every tag this module claims, so an off-by-one in the range arithmetic cannot leave one dead
    for (NPPCmd cmd : {NPPCmdSearchAllStylesToClip, NPPCmdSearchMarkedToClip, NPPCmdSearchFindCharsInRange,
                       NPPCmdViewNonPrintingChars, NPPCmdViewNPCControlChars, NPPCmdViewPostIt,
                       NPPCmdViewTabMoveToStart, NPPCmdViewTabMoveToEnd})
        expect([NSString stringWithFormat:@"handles: command %d is unclaimed", (int)cmd], [self handlesCommand:cmd]);
    for (int i = 0; i < 5; i++)
        expect([NSString stringWithFormat:@"handles: Copy Styled Text %d is unclaimed", i + 1],
               [self handlesCommand:(NPPCmd)(NPPCmdSearchStyleToClipBase + i)]);
    for (int i = 0; i < 5; i++)   // default browser, Safari, Chrome, Firefox, Edge
        expect([NSString stringWithFormat:@"handles: browser %d is unclaimed", i],
               [self handlesCommand:(NPPCmd)(NPPCmdViewInBrowserBase + i)]);
    expect(@"handles: claims a tag past the last browser item",
           ![self handlesCommand:(NPPCmd)(NPPCmdViewInBrowserBase + 5)]);
    expect(@"browser: an index outside 0-4 has no application", browserApplicationURL(5) == nil);

    // ---- which mark style a "Copy Styled Text" item reads, and how the styled ranges are glued together
    int ind[5];
    expectEq(@"clip: 1st Style is one indicator", styleClipIndicators(NPPCmdSearchStyleToClipBase, ind), 1);
    for (int i = 0; i < 5; i++) {   // 1st..5th Style -> Ext1..Ext5 (indicators 25 down to 21)
        styleClipIndicators((NPPCmd)(NPPCmdSearchStyleToClipBase + i), ind);
        expectEq([NSString stringWithFormat:@"clip: style %d reads its own indicator", i + 1],
                 ind[0], NPPIndicatorMarkExt1 - i);
    }
    expectEq(@"clip: All Styles reads five", styleClipIndicators(NPPCmdSearchAllStylesToClip, ind), 5);
    expectEq(@"clip: All Styles ends at Ext5", ind[4], NPPIndicatorMarkExt5);
    styleClipIndicators(NPPCmdSearchMarkedToClip, ind);
    expectEq(@"clip: Find Mark Style reads the find indicator", ind[0], NPPIndicatorFindMark);

    typedef std::vector<std::pair<sptr_t, std::string>> Pieces;
    expect(@"clip: nothing styled leaves the clipboard alone", joinStyledPieces(Pieces{}, NO) == nil);
    expectStr(@"clip: a single range is copied bare", joinStyledPieces(Pieces{{5, "foo"}}, NO), @"foo");
    expectStr(@"clip: ranges are newline joined and terminated",
              joinStyledPieces(Pieces{{5, "foo"}, {9, "bar"}}, NO), @"foo\nbar\n");
    expectStr(@"clip: a range spanning lines switches to the ---- rule",
              joinStyledPieces(Pieces{{5, "a\nb"}, {9, "c"}}, NO), @"a\nb\n----\nc\n");
    expectStr(@"clip: a lone multi-line range needs no rule", joinStyledPieces(Pieces{{5, "a\nb"}}, NO), @"a\nb");
    expectStr(@"clip: All Styles sorts by document position",
              joinStyledPieces(Pieces{{9, "second"}, {5, "first"}}, YES), @"first\nsecond\n");
    expectStr(@"clip: one style keeps the order the indicator runs came in",
              joinStyledPieces(Pieces{{9, "b"}, {5, "a"}}, NO), @"b\na\n");

    // ---- Find characters in range: the byte predicate, at both edges of every range
    const std::string abc = "abc";            // 'a' 97, 'b' 98, 'c' 99
    const std::string mixed = "a\xC3\xA9";    // 'a' then U+00E9, whose two bytes are both >= 128
    expectEq(@"range: ASCII (0-127) finds the ASCII byte", findCharInRange(mixed, 0, 0, 127, NO, NO), 0);
    expectEq(@"range: non-ASCII (128-255) finds the lead byte", findCharInRange(mixed, 0, 128, 255, NO, NO), 1);
    expectEq(@"range: non-ASCII skips a pure ASCII document", findCharInRange(abc, 0, 128, 255, NO, NO), -1);
    expectEq(@"range: low edge is included", findCharInRange(abc, 0, 97, 97, NO, NO), 0);
    expectEq(@"range: one below the low edge is excluded", findCharInRange(abc, 0, 0, 96, NO, NO), -1);
    expectEq(@"range: high edge is included", findCharInRange(abc, 0, 99, 255, NO, NO), 2);
    expectEq(@"range: one above the high edge is excluded", findCharInRange(abc, 0, 100, 255, NO, NO), -1);
    expectEq(@"range: forward starts at the caret", findCharInRange(abc, 1, 98, 98, NO, NO), 1);
    expectEq(@"range: forward past the only hit fails without wrap", findCharInRange(abc, 2, 98, 98, NO, NO), -1);
    expectEq(@"range: forward past the only hit wraps", findCharInRange(abc, 2, 98, 98, NO, YES), 1);
    expectEq(@"range: backward starts one before the caret", findCharInRange(abc, 2, 98, 98, YES, NO), 1);
    expectEq(@"range: backward does not match the caret itself", findCharInRange(abc, 1, 98, 98, YES, NO), -1);
    expectEq(@"range: backward wraps to the last hit", findCharInRange(abc, 0, 98, 98, YES, YES), 1);
    expectEq(@"range: an empty document finds nothing", findCharInRange(std::string(), 0, 0, 255, NO, YES), -1);
    expectEq(@"range: a caret past the end finds nothing", findCharInRange(abc, 99, 0, 255, NO, YES), -1);

    // ---- Move to Start / Move to End: the destination, including the pin boundary N++ stops at
    NPPTabItem *(^tab)(BOOL) = ^(BOOL pinned) { NPPTabItem *t = [NPPTabItem new]; t.pinned = pinned; return t; };
    NSArray<NPPTabItem *> *plain = @[tab(NO), tab(NO), tab(NO), tab(NO)];
    NSArray<NPPTabItem *> *withPins = @[tab(YES), tab(YES), tab(NO), tab(NO)];   // pinned block is always at the head
    expectEq(@"tab: Move to Start goes to tab 0", tabMoveDestination(plain, 2, NO), 0);
    expectEq(@"tab: Move to End goes to the last tab", tabMoveDestination(plain, 1, YES), 3);
    expectEq(@"tab: already first has nowhere to go", tabMoveDestination(plain, 0, NO), NSNotFound);
    expectEq(@"tab: already last has nowhere to go", tabMoveDestination(plain, 3, YES), NSNotFound);
    expectEq(@"tab: an unpinned tab stops at the pin boundary", tabMoveDestination(withPins, 3, NO), 2);
    expectEq(@"tab: the first unpinned tab cannot pass the pinned block", tabMoveDestination(withPins, 2, NO), NSNotFound);
    expectEq(@"tab: a pinned tab stays inside the pinned block", tabMoveDestination(withPins, 0, YES), 1);
    expectEq(@"tab: an empty strip has no destination", tabMoveDestination(@[], 0, NO), NSNotFound);
    expectEq(@"tab: no selection (-1) has no destination", tabMoveDestination(plain, -1, YES), NSNotFound);
    expectEq(@"tab: an index past the end has no destination", tabMoveDestination(plain, 9, NO), NSNotFound);

    // ---- the representation table
    const size_t nNpc = sizeof(kNonPrintingChars) / sizeof(kNonPrintingChars[0]);
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (const NPPRepr &r : kNonPrintingChars) {
        NSString *where = [NSString stringWithFormat:@"repr %s (U+%04X)", r.label, r.code];
        if (utf8Encode(r.code) != std::string(r.utf8))
            [fails addObject:[where stringByAppendingString:@": bytes are not that code point in UTF-8"]];
        if (r.label[0] == '\0' || strlen(r.label) > 6)   // must fit the rep[8] buffer beside "xFFFB"
            [fails addObject:[where stringByAppendingString:@": label is empty or longer than 6 characters"]];
        // The C0 / DEL / C1 / NEL / LS / PS half belongs to NPPPreferences; if the two writers ever overlapped
        // they would clear each other's representations on the next preference change.
        if (r.code < 0x00A0 || r.code == 0x2028 || r.code == 0x2029)
            [fails addObject:[where stringByAppendingString:@": that character is NPPPreferences' to represent"]];
        if (r.code == '\t' || r.code == '\n' || r.code == '\r')
            [fails addObject:[where stringByAppendingString:@": tab/CR/LF belong to Show Space and Tab / Show End of Line"]];
        if ([seen containsObject:@(r.code)]) [fails addObject:[where stringByAppendingString:@": listed twice"]];
        [seen addObject:@(r.code)];
    }
    expectEq(@"repr: non-printing table size", (long long)nNpc, 49);   // N++ g_nonPrintingChars, entry for entry
    expect(@"repr: the invisible spaces are in the table",
           [seen containsObject:@(0x00A0)] && [seen containsObject:@(0x200B)] && [seen containsObject:@(0xFEFF)]);

    // ---- Zoom belongs to the view: one level for every buffer, remembered across launches.
    // Two scratch buffers of its own, so a live app running the self-check never has its own tabs resized; the
    // stored level is the user's and is put back at the end.
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    NSInteger userZoom = [defs integerForKey:kZoomDefaultsKey];
    NPPDocument *zoomA = [[NPPDocument alloc] initUntitled], *zoomB = [[NPPDocument alloc] initUntitled];
    NPPDocument *witnessWas = gZoomWitness;
    if (!zoomA.editor || !zoomB.editor) {
        [fails addObject:@"zoom: could not make two scratch buffers"];
    } else {
        static NSWindow *zoomHost;
        static dispatch_once_t zoomOnce;
        dispatch_once(&zoomOnce, ^{
            zoomHost = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
            zoomHost.releasedWhenClosed = NO;
        });
        for (NPPDocument *d in @[zoomA, zoomB]) {
            d.editor.frame = NSMakeRect(0, 0, 400, 300);
            [zoomHost.contentView addSubview:d.editor];
            NPPSci(d.editor, SCI_SETZOOM, 0);
        }
        NSArray<NPPDocument *> *zoomDocs = @[zoomA, zoomB];

        gZoomWitness = nil;
        [defs setInteger:0 forKey:kZoomDefaultsKey];
        [self performCommand:NPPCmdViewZoomIn onEditor:zoomA.editor];
        sptr_t after1 = NPPSci(zoomA.editor, SCI_GETZOOM);
        expect(@"zoom: Zoom In did not move the editor", after1 > 0);
        expectEq(@"zoom: Zoom In was not persisted", [defs integerForKey:kZoomDefaultsKey], after1);

        // A buffer that has just been created or shown comes up at the view's level, not at 0.
        expectEq(@"zoom: a second buffer starts at its own zoom", NPPSci(zoomB.editor, SCI_GETZOOM), 0);
        syncZoomOnDocumentChange(zoomB, zoomDocs);
        expectEq(@"zoom: showing a buffer did not bring it to the view's level",
                 NPPSci(zoomB.editor, SCI_GETZOOM), after1);

        // ⌘-wheel zoom lands in Scintilla without passing through any command; the next tab switch has to pick it
        // up off the buffer that was current, or it is lost the moment the user changes tab.
        syncZoomOnDocumentChange(zoomA, zoomDocs);         // A is current now
        NPPSci(zoomA.editor, SCI_SETZOOM, 7);              // …and the wheel moves it behind our back
        syncZoomOnDocumentChange(zoomB, zoomDocs);         // switch to B
        expectEq(@"zoom: a wheel zoom was not carried to the next buffer", NPPSci(zoomB.editor, SCI_GETZOOM), 7);
        expectEq(@"zoom: a wheel zoom was not persisted", [defs integerForKey:kZoomDefaultsKey], 7);

        // Restore Default Zoom is 0 for the whole view, not just for the buffer it was invoked on. The witness is
        // cleared first so the tab switch below carries the stored level rather than the buffer left at 7.
        gZoomWitness = nil;
        [self performCommand:NPPCmdViewZoomRestore onEditor:zoomA.editor];
        expectEq(@"zoom: Restore Default did not reset the editor", NPPSci(zoomA.editor, SCI_GETZOOM), 0);
        expectEq(@"zoom: Restore Default was not persisted", [defs integerForKey:kZoomDefaultsKey], 0);
        syncZoomOnDocumentChange(zoomB, zoomDocs);
        expectEq(@"zoom: Restore Default left another buffer zoomed", NPPSci(zoomB.editor, SCI_GETZOOM), 0);

        // Scintilla owns the ceiling; what is stored has to be what it accepted, never an unclamped count.
        for (int i = 0; i < 60; i++) [self performCommand:NPPCmdViewZoomOut onEditor:zoomA.editor];
        expectEq(@"zoom: the stored level ran past Scintilla's floor",
                 [defs integerForKey:kZoomDefaultsKey], NPPSci(zoomA.editor, SCI_GETZOOM));
        [zoomA.editor removeFromSuperview];
        [zoomB.editor removeFromSuperview];
    }
    // Put the app back where it was: performCommand: above spread its zoom over the real buffers too, if there
    // are any (this runs headless, but selfCheckFailures is a public entry point and may not always).
    spreadZoom(userZoom, [gContext contextOpenDocuments], nil);
    gZoomWitness = witnessWas;

    return fails;
}

@end

#pragma mark - Find characters in range (N++ FindCharsInRangeDlg)

// N++'s dialog is modeless with a repeatable Find button; a sheet is the macOS shape for that — it does not block
// the run loop, and Find keeps acting on the editor behind it.
@interface NPPFindCharsInRangeSheet : NSObject
- (void)showForEditor:(ScintillaView *)editor host:(NSWindow *)host;
@end

@implementation NPPFindCharsInRangeSheet {
    __weak ScintillaView *_editor;
    NSWindow *_sheet;
    NSButton *_nonASCII, *_ascii, *_customRange, *_up, *_down, *_wrap;
    NSTextField *_from, *_to, *_status;
}

static NPPFindCharsInRangeSheet *gFindCharsSheet;   // one at a time, like N++'s single dialog instance

static NSTextField *SheetLabel(NSString *text, NSRect frame, NSView *parent) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.frame = frame;
    l.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
    [parent addSubview:l];
    return l;
}

- (void)showForEditor:(ScintillaView *)editor host:(NSWindow *)host {
    _editor = editor;
    const CGFloat W = 430, H = 214;
    _sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H) styleMask:NSWindowStyleMaskTitled
                                           backing:NSBackingStoreBuffered defer:NO];
    _sheet.title = @"Find Characters in Range...";
    NSView *v = _sheet.contentView;

    // AppKit groups radio buttons by (superview, action), so the range group and the direction group must not
    // share an action — picking a direction would otherwise clear the range choice.
    _nonASCII = [NSButton radioButtonWithTitle:@"Non-ASCII characters (128-255)" target:self action:@selector(rangeModeChanged:)];
    _ascii = [NSButton radioButtonWithTitle:@"ASCII characters (0-127)" target:self action:@selector(rangeModeChanged:)];
    _customRange = [NSButton radioButtonWithTitle:@"Custom range (0-255):" target:self action:@selector(rangeModeChanged:)];
    _nonASCII.frame = NSMakeRect(20, 176, 300, 20);
    _ascii.frame = NSMakeRect(20, 152, 300, 20);
    _customRange.frame = NSMakeRect(20, 128, 160, 20);
    for (NSButton *b in @[_nonASCII, _ascii, _customRange]) [v addSubview:b];
    _nonASCII.state = NSControlStateValueOn;   // N++ WM_INITDIALOG default

    _from = [[NSTextField alloc] initWithFrame:NSMakeRect(186, 127, 46, 22)];
    _to = [[NSTextField alloc] initWithFrame:NSMakeRect(254, 127, 46, 22)];
    _from.alignment = NSTextAlignmentCenter;
    _to.alignment = NSTextAlignmentCenter;
    _from.stringValue = @"0";
    _to.stringValue = @"255";
    [v addSubview:_from];
    [v addSubview:_to];
    SheetLabel(@"–", NSMakeRect(236, 130, 14, 17), v);

    SheetLabel(@"Direction:", NSMakeRect(20, 98, 70, 17), v);
    _up = [NSButton radioButtonWithTitle:@"Up" target:self action:@selector(directionChanged:)];
    _down = [NSButton radioButtonWithTitle:@"Down" target:self action:@selector(directionChanged:)];
    _up.frame = NSMakeRect(94, 96, 60, 20);
    _down.frame = NSMakeRect(158, 96, 74, 20);
    [v addSubview:_up];
    [v addSubview:_down];
    _down.state = NSControlStateValueOn;

    _wrap = [NSButton checkboxWithTitle:@"Wrap around" target:nil action:nil];
    _wrap.frame = NSMakeRect(244, 96, 150, 20);
    [v addSubview:_wrap];

    _status = SheetLabel(@"", NSMakeRect(20, 64, W - 40, 17), v);

    NSButton *find = [NSButton buttonWithTitle:@"Find" target:self action:@selector(find:)];
    find.frame = NSMakeRect(W - 20 - 90, 16, 90, 32);
    find.keyEquivalent = @"\r";
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeSheet:)];
    close.frame = NSMakeRect(W - 20 - 90 - 100, 16, 90, 32);
    close.keyEquivalent = @"\033";
    [v addSubview:find];
    [v addSubview:close];

    [self rangeModeChanged:nil];
    [host beginSheet:_sheet completionHandler:^(NSModalResponse rc) {
        [host makeFirstResponder:editor];
        gFindCharsSheet = nil;
    }];
}

- (void)rangeModeChanged:(id)sender {
    BOOL custom = _customRange.state == NSControlStateValueOn;
    _from.enabled = custom;
    _to.enabled = custom;
    _status.stringValue = @"";
}

- (void)directionChanged:(id)sender { _status.stringValue = @""; }

- (void)find:(id)sender {
    ScintillaView *ed = _editor;
    if (!ed) { NSBeep(); return; }
    int begin = 128, end = 255;                                  // N++ default: non-ASCII
    if (_ascii.state == NSControlStateValueOn) { begin = 0; end = 127; }
    else if (_customRange.state == NSControlStateValueOn) {
        NSCharacterSet *notDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
        NSString *a = _from.stringValue, *b = _to.stringValue;
        BOOL numeric = a.length && b.length && [a rangeOfCharacterFromSet:notDigits].location == NSNotFound &&
                                               [b rangeOfCharacterFromSet:notDigits].location == NSNotFound;
        // N++ rejects the same three cases with "You should type between 0 and 255."; the sheet says so in place
        // rather than stacking an alert on top of itself.
        if (!numeric || a.integerValue > 255 || b.integerValue > 255 || a.integerValue > b.integerValue) {
            _status.stringValue = @"Type two values between 0 and 255, the lower one first.";
            NSBeep();
            return;
        }
        begin = (int)a.integerValue;
        end = (int)b.integerValue;
    }
    BOOL found = findCharInRangeInEditor(ed, begin, end, _up.state == NSControlStateValueOn,
                                         _wrap.state == NSControlStateValueOn);
    _status.stringValue = found ? @"" : @"No character in that range.";
    if (!found) NSBeep();
}

- (void)closeSheet:(id)sender { [_sheet.sheetParent endSheet:_sheet]; }

@end

static void showFindCharsInRangeSheet(ScintillaView *ed) {
    NSWindow *host = [gContext contextWindow];
    if (!ed || !host || host.attachedSheet) { NSBeep(); return; }
    gFindCharsSheet = [NPPFindCharsInRangeSheet new];
    [gFindCharsSheet showForEditor:ed host:host];
}
