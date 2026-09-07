// NPPFindPanelController.mm — Find / Replace / Mark panel, Go To Line sheet, incremental search bar.
// Mirrors PowerEditor/src/ScintillaComponent/FindReplaceDlg.cpp (processFindNext / processReplace / processAll /
// convertExtendedToString / FindIncrementDlg / GoToLineDlg) on top of SCI_SEARCHINTARGET.
#import "NPPFindPanelController.h"
#import "NPPUtils.h"
#import "NPPPreferences.h"          // Preferences > Searching
#import "NPPSearchViewCommands.h"   // indicator / marker numbers only
#import "NPPFindInFiles.h"          // "Find All in Current Document" lists its hits in the Search results panel
#include <string>
#include <objc/runtime.h>

NSNotificationName const NPPIncrementalSearchShouldShowNotification = @"NPPIncrementalSearchShouldShowNotification";
NSNotificationName const NPPIncrementalSearchShouldHideNotification = @"NPPIncrementalSearchShouldHideNotification";

static NSString *const kFindHistoryKey = @"NPPFindHistory";
static NSString *const kReplaceHistoryKey = @"NPPReplaceHistory";
static const NSUInteger kHistoryMax = 10;

// Two Preferences > Searching settings with no NPPPreferences property yet, read under the key a Searching page
// would bind its checkbox to (NPP + the NppGUI field name) and defaulting to N++'s own value.
static NSString *const kFillFindFieldWithSelectedKey = @"NPPFillFindFieldWithSelected";  // NppGUI::_fillFindFieldWithSelected, default on
static NSString *const kFillFindFieldSelectCaretKey  = @"NPPFillFindFieldSelectCaret";   // NppGUI::_fillFindFieldSelectCaret, default on

// "Find All in Current Document" hands its hits to NPPFindInFiles, which needs an id<NPPCommandContext> (the
// document to scan, and the host that docks the results panel). This controller is not a command handler, so it
// takes the context from the documented NPPCommandContextReadyNotification seam, as NPPEditCommands does.
static __weak id<NPPCommandContext> gContext = nil;

static BOOL NPPFindPrefBool(NSString *key, BOOL fallback) {
    NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return n ? n.boolValue : fallback;
}

typedef NS_ENUM(int, NPPFindStatus) { NPPFSFound, NPPFSNotFound, NPPFSEndReached, NPPFSTopReached, NPPFSInvalidRegex };
typedef NS_ENUM(int, NPPProcessOp) { NPPOpCount, NPPOpReplace, NPPOpMark };

// ---------------------------------------------------------------------------------------------------------------------
#pragma mark - String helpers (UTF-8)

static std::string U8(NSString *s) { const char *c = s.UTF8String; return c ? std::string(c) : std::string(); }

static void AppendUTF8(std::string &out, unsigned cp) {
    if (cp < 0x80) out += (char)cp;
    else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}

// Searching::readBase — exactly `size` digits in `base`.
static bool ReadBase(const std::string &s, size_t at, int base, int size, unsigned &value) {
    if (at + size > s.size()) return false;
    unsigned v = 0;
    for (int i = 0; i < size; i++) {
        int c = (unsigned char)s[at + i], d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
        else return false;
        if (d >= base) return false;
        v = v * base + d;
    }
    value = v;
    return true;
}

// Searching::convertExtendedToString: \n \r \t \0 \\ \bNNNNNNNN \oNNN \dNNN \xHH \uHHHH (numeric escapes -> UTF-8 code point).
static std::string NPPUnescapeExtended(const std::string &q) {
    std::string out; out.reserve(q.size());
    for (size_t i = 0; i < q.size(); i++) {
        char c = q[i];
        if (c != '\\' || i + 1 >= q.size()) { out += c; continue; }
        char e = q[++i];
        switch (e) {
            case 'r': out += '\r'; break;
            case 'n': out += '\n'; break;
            case '0': out += '\0'; break;
            case 't': out += '\t'; break;
            case '\\': out += '\\'; break;
            case 'b': case 'o': case 'd': case 'x': case 'u': {
                int size = 0, base = 0;
                if (e == 'b') { size = 8; base = 2; } else if (e == 'o') { size = 3; base = 8; } else if (e == 'd') { size = 3; base = 10; }
                else if (e == 'x') { size = 2; base = 16; } else { size = 4; base = 16; }
                unsigned v;
                if (ReadBase(q, i + 1, base, size, v)) { AppendUTF8(out, v); i += size; break; }
                out += '\\'; out += e; break;   // not enough digits: literal
            }
            default: out += '\\'; out += e; break;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------------------------
#pragma mark - Small view helpers

@interface NPPFlippedView : NSView @end
@implementation NPPFlippedView
- (BOOL)isFlipped { return YES; }
@end

// Esc / Cmd+W close the panel (menu Cmd+W would otherwise close the document).
@interface NPPFindPanel : NSPanel @end
@implementation NPPFindPanel
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand &&
        [event.charactersIgnoringModifiers isEqualToString:@"w"]) { [self performClose:nil]; return YES; }
    return [super performKeyEquivalent:event];
}
- (void)cancelOperation:(id)sender { [self performClose:sender]; }
@end

// Block-backed target for one-off sheet buttons.
@interface NPPBlockTarget : NSObject
@property (nonatomic, copy) void (^block)(id);
+ (instancetype)targetWithBlock:(void (^)(id))block;
- (void)fire:(id)sender;
@end
@implementation NPPBlockTarget
+ (instancetype)targetWithBlock:(void (^)(id))block { NPPBlockTarget *t = [self new]; t.block = block; return t; }
- (void)fire:(id)sender { if (self.block) self.block(sender); }
@end

static NSTextField *Label(NSString *text, NSRect r, NSView *parent) {
    NSTextField *l = [NSTextField labelWithString:text]; l.frame = r; l.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
    [parent addSubview:l]; return l;
}
static NSButton *Button(NSString *title, NSRect r, id target, SEL action, NSView *parent) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action]; b.frame = r; b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
    [parent addSubview:b]; return b;
}
static NSButton *Check(NSString *title, NSRect r, NSView *parent) {
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil]; b.frame = r; b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
    [parent addSubview:b]; return b;
}

// ---------------------------------------------------------------------------------------------------------------------
#pragma mark - Incremental search bar

@class NPPFindPanelController;
@interface NPPIncrementalSearchBar : NPPFlippedView <NSTextFieldDelegate>
@property (nonatomic, weak) NPPFindPanelController *owner;
@property (nonatomic, weak) id<NPPFindTargetProvider> provider;
@property (nonatomic, strong) NSTextField *field, *status;
@property (nonatomic, strong) NSButton *closeButton, *prevButton, *nextButton, *highlightAll, *matchCase;
@property (nonatomic, copy) NSString *lastText;
@end

@interface NPPFindPanelController () <NSWindowDelegate, NSTabViewDelegate>
// internal engine
- (NPPFindStatus)runFind:(NSString *)text editor:(ScintillaView *)ed backward:(BOOL)backward wrap:(BOOL)wrap
               matchCase:(BOOL)mc wholeWord:(BOOL)ww mode:(NPPSearchMode)mode startAt:(sptr_t)startPos
              foundStart:(sptr_t *)outStart foundEnd:(sptr_t *)outEnd;
- (void)selectRange:(sptr_t)start to:(sptr_t)end backward:(BOOL)backward inEditor:(ScintillaView *)ed;
- (NSInteger)processAll:(NPPProcessOp)op editor:(ScintillaView *)ed text:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww
                   mode:(NPPSearchMode)mode replacement:(NSString *)rep indicator:(int)indicator bookmark:(BOOL)bookmark
              rangeStart:(sptr_t)rs rangeEnd:(sptr_t)re;
- (void)ensureIndicatorStyle:(int)indicator color:(long)bgr onEditor:(ScintillaView *)ed;
@end

@implementation NPPIncrementalSearchBar

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    CGFloat y = 3, h = 20;
    _closeButton = Button(@"✕", NSMakeRect(4, y, 22, h), self, @selector(hide:), self);
    _closeButton.bezelStyle = NSBezelStyleInline; _closeButton.bordered = NO;
    Label(@"Find :", NSMakeRect(30, y + 2, 42, h - 2), self);
    _field = [[NSTextField alloc] initWithFrame:NSMakeRect(74, y, 220, h)];
    _field.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1]; _field.delegate = self;
    _field.placeholderString = @"";
    [self addSubview:_field];
    _prevButton = Button(@"◀", NSMakeRect(300, y, 26, h), self, @selector(previous:), self);
    _nextButton = Button(@"▶", NSMakeRect(328, y, 26, h), self, @selector(next:), self);
    _prevButton.bezelStyle = _nextButton.bezelStyle = NSBezelStyleRoundRect;
    _highlightAll = Check(@"Highlight all", NSMakeRect(362, y, 110, h), self);
    _highlightAll.target = self; _highlightAll.action = @selector(optionChanged:);
    _matchCase = Check(@"Match case", NSMakeRect(474, y, 100, h), self);
    _matchCase.target = self; _matchCase.action = @selector(optionChanged:);
    _status = Label(@"", NSMakeRect(584, y + 2, MAX(60, NSWidth(frame) - 590), h - 2), self);
    _status.autoresizingMask = NSViewWidthSizable;
    _status.textColor = NSColor.systemRedColor;
    _lastText = @"";
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    // NSIntersectionRect, not dirtyRect: clipsToBounds is NO by default since macOS 14 (see NPPStatusBarView).
    [NSColor.windowBackgroundColor setFill]; NSRectFill(NSIntersectionRect(dirtyRect, self.bounds));
    [NSColor.separatorColor setFill]; NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1));
}

- (ScintillaView *)editor { return [self.provider currentEditorForFind]; }

// FindIncrementDlg: first search from the selection start (text changed), next/prev from the selection edge.
- (void)searchFromSelectionStart:(BOOL)fromStart backward:(BOOL)backward {
    ScintillaView *ed = self.editor; NSString *text = self.field.stringValue ?: @"";
    if (!ed) return;
    [self applyHighlight];
    if (text.length == 0) { self.field.textColor = NSColor.textColor; self.status.stringValue = @""; return; }
    sptr_t selStart = NPPSci(ed, SCI_GETSELECTIONSTART), selEnd = NPPSci(ed, SCI_GETSELECTIONEND);
    sptr_t startAt;
    if (fromStart) startAt = self.lastText.length == 0 ? 0 : selStart;           // typing: re-search at the current match
    else startAt = backward ? selStart : (selStart == selEnd ? selStart : selStart + 1);   // NextIncremental: cpMin + 1
    sptr_t s = 0, e = 0;
    NPPFindStatus st = [self.owner runFind:text editor:ed backward:backward wrap:YES matchCase:self.matchCase.state == NSControlStateValueOn
                                  wholeWord:NO mode:NPPSearchModeNormal startAt:startAt foundStart:&s foundEnd:&e];
    if (st == NPPFSNotFound || st == NPPFSInvalidRegex) {
        self.field.textColor = NSColor.systemRedColor; self.status.stringValue = @"Not found";
        NPPSci(ed, SCI_SETSEL, (uptr_t)selStart, selStart);   // N++ collapses the selection when nothing matches
        return;
    }
    self.field.textColor = NSColor.textColor;
    self.status.stringValue = st == NPPFSEndReached ? @"Reached document end" : st == NPPFSTopReached ? @"Reached document beginning" : @"";
    [self.owner selectRange:s to:e backward:backward inEditor:ed];
}

- (void)applyHighlight {
    ScintillaView *ed = self.editor; if (!ed) return;
    NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorIncremental);
    NPPSci(ed, SCI_INDICATORCLEARRANGE, 0, NPPSci(ed, SCI_GETLENGTH));
    NSString *text = self.field.stringValue ?: @"";
    if (self.highlightAll.state != NSControlStateValueOn || text.length == 0 || self.hidden || !self.window) return;
    [self.owner ensureIndicatorStyle:NPPIndicatorIncremental color:0x00FF00 onEditor:ed];   // N++ incremental highlight: green
    [self.owner processAll:NPPOpMark editor:ed text:text matchCase:self.matchCase.state == NSControlStateValueOn wholeWord:NO
                      mode:NPPSearchModeNormal replacement:@"" indicator:NPPIndicatorIncremental bookmark:NO rangeStart:0 rangeEnd:NPPSci(ed, SCI_GETLENGTH)];
}

- (void)clearHighlight {
    ScintillaView *ed = self.editor; if (!ed) return;
    NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorIncremental);
    NPPSci(ed, SCI_INDICATORCLEARRANGE, 0, NPPSci(ed, SCI_GETLENGTH));
}

- (void)controlTextDidChange:(NSNotification *)n {
    [self searchFromSelectionStart:YES backward:NO];
    self.lastText = self.field.stringValue ?: @"";
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:)) {
        BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
        [self searchFromSelectionStart:NO backward:shift]; return YES;
    }
    if (sel == @selector(cancelOperation:)) { [self hide:nil]; return YES; }
    return NO;
}
- (void)next:(id)sender { [self searchFromSelectionStart:NO backward:NO]; }
- (void)previous:(id)sender { [self searchFromSelectionStart:NO backward:YES]; }
- (void)optionChanged:(id)sender { [self searchFromSelectionStart:YES backward:NO]; }
- (void)hide:(id)sender {
    [self clearHighlight];
    ScintillaView *ed = self.editor;
    [NSNotificationCenter.defaultCenter postNotificationName:NPPIncrementalSearchShouldHideNotification object:nil];
    if (ed) [ed.window makeFirstResponder:ed];
}
- (void)focus {
    [self.window makeFirstResponder:self.field];
    [self.field selectText:nil];
}
@end

// ---------------------------------------------------------------------------------------------------------------------
#pragma mark - NPPFindPanelController

@implementation NPPFindPanelController {
    NSTabView *_tabs;
    NSTextField *_statusLabel;
    NSMutableArray<NSComboBox *> *_findCombos, *_replaceCombos;
    NSMutableArray<NSButton *> *_modeRadios;      // tag = NPPSearchMode
    NSMutableArray<NSButton *> *_dotChecks;
    NPPIncrementalSearchBar *_incBar;
    NSString *_searchText, *_replaceText;
    BOOL _uiBuilt;
}
@dynamic matchCase, wholeWord, wrapAround, backwardDirection, inSelection, dotMatchesNewline, purgeMarksBeforeMark, bookmarkLinesOnMark, searchMode;

+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NPPCommandContextReadyNotification object:nil queue:nil
                                               usingBlock:^(NSNotification *note) { gContext = (id<NPPCommandContext>)note.object; }];
}

+ (instancetype)shared {
    static NPPFindPanelController *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPFindPanelController alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super initWithWindow:nil])) return nil;
    _findCombos = [NSMutableArray new]; _replaceCombos = [NSMutableArray new]; _modeRadios = [NSMutableArray new]; _dotChecks = [NSMutableArray new];
    _searchText = self.searchHistory.firstObject ?: @"";
    _replaceText = [[NSUserDefaults.standardUserDefaults arrayForKey:kReplaceHistoryKey] firstObject] ?: @"";
    return self;
}

#pragma mark Options (NSUserDefaults-backed; manual setters keep automatic KVO so the checkboxes can bind to them)

#define NPP_BOOL_OPTION(getter, setter, key, def) \
- (BOOL)getter { NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:key]; return n ? n.boolValue : (def); } \
- (void)setter:(BOOL)v { [NSUserDefaults.standardUserDefaults setBool:v forKey:key]; [self syncModeUI]; }
NPP_BOOL_OPTION(matchCase, setMatchCase, @"NPPFindMatchCase", NO)
NPP_BOOL_OPTION(wholeWord, setWholeWord, @"NPPFindWholeWord", NO)
NPP_BOOL_OPTION(wrapAround, setWrapAround, @"NPPFindWrapAround", YES)
NPP_BOOL_OPTION(backwardDirection, setBackwardDirection, @"NPPFindBackward", NO)
NPP_BOOL_OPTION(inSelection, setInSelection, @"NPPFindInSelection", NO)
NPP_BOOL_OPTION(dotMatchesNewline, setDotMatchesNewline, @"NPPFindDotMatchesNewline", NO)
NPP_BOOL_OPTION(purgeMarksBeforeMark, setPurgeMarksBeforeMark, @"NPPFindPurgeMarks", NO)
NPP_BOOL_OPTION(bookmarkLinesOnMark, setBookmarkLinesOnMark, @"NPPFindBookmarkLines", NO)
#undef NPP_BOOL_OPTION

- (NPPSearchMode)searchMode {
    NSInteger m = [NSUserDefaults.standardUserDefaults integerForKey:@"NPPFindSearchMode"];
    return (m >= 0 && m <= NPPSearchModeRegex) ? (NPPSearchMode)m : NPPSearchModeNormal;
}
- (void)setSearchMode:(NPPSearchMode)m { [NSUserDefaults.standardUserDefaults setInteger:m forKey:@"NPPFindSearchMode"]; [self syncModeUI]; }

- (NSString *)searchText { return _searchText ?: @""; }
- (void)setSearchText:(NSString *)t { _searchText = [t copy] ?: @""; }
- (NSString *)replaceText { return _replaceText ?: @""; }
- (void)setReplaceText:(NSString *)t { _replaceText = [t copy] ?: @""; }

- (NSArray<NSString *> *)searchHistory { return [NSUserDefaults.standardUserDefaults arrayForKey:kFindHistoryKey] ?: @[]; }

- (void)pushHistory:(NSString *)text key:(NSString *)key {
    if (text.length == 0) return;
    NSMutableArray *h = [([NSUserDefaults.standardUserDefaults arrayForKey:key] ?: @[]) mutableCopy];
    [h removeObject:text]; [h insertObject:text atIndex:0];
    while (h.count > kHistoryMax) [h removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:h forKey:key];
    [self refreshCombos];
}

- (void)refreshCombos {
    NSArray *fh = self.searchHistory, *rh = [NSUserDefaults.standardUserDefaults arrayForKey:kReplaceHistoryKey] ?: @[];
    for (NSComboBox *c in _findCombos) { [c removeAllItems]; [c addItemsWithObjectValues:fh]; }
    for (NSComboBox *c in _replaceCombos) { [c removeAllItems]; [c addItemsWithObjectValues:rh]; }
}

- (void)syncModeUI {
    if (!_uiBuilt) return;
    NPPSearchMode m = self.searchMode;
    for (NSButton *r in _modeRadios) r.state = r.tag == m ? NSControlStateValueOn : NSControlStateValueOff;
    // ponytail: stock Scintilla regexes never match across line ends, so ". matches newline" cannot be honoured;
    // the checkbox stays visible (N++ layout) but disabled. Ceiling: needs N++'s Boost regex backend.
    for (NSButton *d in _dotChecks) { d.enabled = NO; d.toolTip = @"Not available: Scintilla regular expressions match within a single line only."; }
}

#pragma mark Editor lookup / status

- (ScintillaView *)editorOr:(ScintillaView *)ed { return ed ?: [self.targetProvider currentEditorForFind]; }

- (void)reportStatus:(NSString *)msg color:(NSColor *)color isError:(BOOL)err {
    _statusLabel.stringValue = msg ?: @""; _statusLabel.textColor = color;
    [self.targetProvider findPanelDidReportStatus:msg ?: @"" isError:err];
}
- (void)reportNotFound:(NSString *)text prefix:(NSString *)prefix {
    [self reportStatus:[NSString stringWithFormat:@"%@: Can't find the text \"%@\"", prefix, text] color:NSColor.systemRedColor isError:YES];
}
- (void)reportWrap:(NPPFindStatus)st prefix:(NSString *)prefix {
    if (st == NPPFSEndReached)
        [self reportStatus:[prefix stringByAppendingString:@": Found the 1st occurrence from the top. The end of the document has been reached."] color:NSColor.systemGreenColor isError:NO];
    else if (st == NPPFSTopReached)
        [self reportStatus:[prefix stringByAppendingString:@": Found the 1st occurrence from the bottom. The beginning of the document has been reached."] color:NSColor.systemGreenColor isError:NO];
    else if (st == NPPFSInvalidRegex)
        [self reportStatus:[prefix stringByAppendingString:@": Invalid Regular Expression"] color:NSColor.systemRedColor isError:YES];
    else [self reportStatus:@"" color:NSColor.labelColor isError:NO];
}

#pragma mark Engine

static int NPPSearchFlags(BOOL mc, BOOL ww, NPPSearchMode mode) {
    int f = (mc ? SCFIND_MATCHCASE : 0) | (ww ? SCFIND_WHOLEWORD : 0);
    if (mode == NPPSearchModeRegex) f |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
    return f;
}
static std::string NPPQuery(NSString *text, NPPSearchMode mode) {
    std::string q = U8(text);
    return mode == NPPSearchModeExtended ? NPPUnescapeExtended(q) : q;
}

// Target search; -1 not found, -2 invalid regex. Target range is left on the match.
static sptr_t NPPSearchTarget(ScintillaView *ed, const std::string &q, sptr_t start, sptr_t end, int flags) {
    NPPSci(ed, SCI_SETSEARCHFLAGS, (uptr_t)flags);
    NPPSci(ed, SCI_SETTARGETRANGE, (uptr_t)start, end);
    sptr_t r = NPPSci(ed, SCI_SEARCHINTARGET, (uptr_t)q.size(), (sptr_t)q.data());
    if (r < 0 && NPPSci(ed, SCI_GETSTATUS) == SC_STATUS_WARN_REGEX) { NPPSci(ed, SCI_SETSTATUS, 0); return -2; }
    return r < 0 ? -1 : r;
}

// processFindNext core. startPos: forward = selection end, backward = selection start (callers decide).
- (NPPFindStatus)runFind:(NSString *)text editor:(ScintillaView *)ed backward:(BOOL)backward wrap:(BOOL)wrap
               matchCase:(BOOL)mc wholeWord:(BOOL)ww mode:(NPPSearchMode)mode startAt:(sptr_t)startPos
              foundStart:(sptr_t *)outStart foundEnd:(sptr_t *)outEnd {
    if (!ed || text.length == 0) return NPPFSNotFound;
    std::string q = NPPQuery(text, mode);
    if (q.empty()) return NPPFSNotFound;
    int flags = NPPSearchFlags(mc, ww, mode);
    sptr_t docLen = NPPSci(ed, SCI_GETLENGTH);
    startPos = MAX((sptr_t)0, MIN(startPos, docLen));
    NPPSci(ed, SCI_CALLTIPCANCEL);

    NPPFindStatus status = NPPFSFound;
    sptr_t pos = NPPSearchTarget(ed, q, startPos, backward ? 0 : docLen, flags);
    // ponytail: regex zero-length match sitting exactly at the start position would never advance (N++ uses its
    // EMPTYMATCH_* Boost flags); step one character and retry.
    if (pos == startPos && NPPSci(ed, SCI_GETTARGETEND) == pos && mode == NPPSearchModeRegex &&
        NPPSci(ed, SCI_GETSELECTIONSTART) == NPPSci(ed, SCI_GETSELECTIONEND) && NPPSci(ed, SCI_GETSELECTIONSTART) == pos) {
        if (backward) pos = startPos > 0 ? NPPSearchTarget(ed, q, startPos - 1, 0, flags) : -1;
        else pos = startPos < docLen ? NPPSearchTarget(ed, q, NPPSci(ed, SCI_POSITIONAFTER, (uptr_t)startPos), docLen, flags) : -1;
    }
    if (pos == -2) return NPPFSInvalidRegex;
    if (pos < 0 && wrap) {
        status = backward ? NPPFSTopReached : NPPFSEndReached;
        pos = backward ? NPPSearchTarget(ed, q, docLen, 0, flags) : NPPSearchTarget(ed, q, 0, docLen, flags);
        if (pos == -2) return NPPFSInvalidRegex;
    }
    if (pos < 0) return NPPFSNotFound;
    if (outStart) *outStart = pos;
    if (outEnd) *outEnd = NPPSci(ed, SCI_GETTARGETEND);
    return status;
}

- (void)selectRange:(sptr_t)start to:(sptr_t)end backward:(BOOL)backward inEditor:(ScintillaView *)ed {
    NPPSci(ed, SCI_ENSUREVISIBLE, (uptr_t)NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)start));
    NPPSci(ed, SCI_ENSUREVISIBLE, (uptr_t)NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)end));
    if (backward) NPPSci(ed, SCI_SETSEL, (uptr_t)end, start); else NPPSci(ed, SCI_SETSEL, (uptr_t)start, end);
    NPPSci(ed, SCI_SCROLLCARET);
}

- (void)ensureIndicatorStyle:(int)indicator color:(long)bgr onEditor:(ScintillaView *)ed {
    // Theme module normally styles these; only fill in a default when nobody did (INDIC_PLAIN is Scintilla's default).
    if (NPPSci(ed, SCI_INDICGETSTYLE, (uptr_t)indicator) != INDIC_PLAIN) return;
    NPPSci(ed, SCI_INDICSETSTYLE, (uptr_t)indicator, INDIC_ROUNDBOX);
    NPPSci(ed, SCI_INDICSETFORE, (uptr_t)indicator, bgr);
    NPPSci(ed, SCI_INDICSETALPHA, (uptr_t)indicator, 100);
    NPPSci(ed, SCI_INDICSETOUTLINEALPHA, (uptr_t)indicator, 100);
    NPPSci(ed, SCI_INDICSETUNDER, (uptr_t)indicator, 1);
}

// Regex replacement: \0-\9 / $0-$9 groups (via SCI_GETTAG), \n \r \t \\ literals. Applied with SCI_REPLACETARGET so the
// group semantics do not depend on Scintilla's own \d handling.
static std::string NPPExpandRegexReplacement(ScintillaView *ed, const std::string &rep) {
    std::string out; out.reserve(rep.size());
    for (size_t i = 0; i < rep.size(); i++) {
        char c = rep[i];
        if ((c == '\\' || c == '$') && i + 1 < rep.size()) {
            char e = rep[i + 1];
            if (e >= '0' && e <= '9') {
                int tag = e - '0'; i++;
                if (tag == 0) out += NPPSciGetRange(ed, NPPSci(ed, SCI_GETTARGETSTART), NPPSci(ed, SCI_GETTARGETEND));
                else {
                    sptr_t len = NPPSci(ed, SCI_GETTAG, (uptr_t)tag, 0);
                    if (len > 0) { std::string t((size_t)len + 1, '\0'); NPPSci(ed, SCI_GETTAG, (uptr_t)tag, (sptr_t)t.data()); t.resize((size_t)len); out += t; }
                }
                continue;
            }
            if (c == '\\') {
                i++;
                switch (e) { case 'n': out += '\n'; break; case 'r': out += '\r'; break; case 't': out += '\t'; break;
                             case '\\': out += '\\'; break; default: out += '\\'; out += e; break; }
                continue;
            }
        }
        out += c;
    }
    return out;
}

// Replaces the current target (after a successful search); returns the replacement length.
static sptr_t NPPReplaceTarget(ScintillaView *ed, NSString *rep, NPPSearchMode mode) {
    std::string r = U8(rep);
    if (mode == NPPSearchModeExtended) r = NPPUnescapeExtended(r);
    else if (mode == NPPSearchModeRegex) r = NPPExpandRegexReplacement(ed, r);
    return NPPSci(ed, SCI_REPLACETARGET, (uptr_t)r.size(), (sptr_t)r.data());
}

// processAll: Count / Replace All / Mark All over [rs, re).
- (NSInteger)processAll:(NPPProcessOp)op editor:(ScintillaView *)ed text:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww
                   mode:(NPPSearchMode)mode replacement:(NSString *)rep indicator:(int)indicator bookmark:(BOOL)bookmark
              rangeStart:(sptr_t)rs rangeEnd:(sptr_t)re {
    if (!ed || text.length == 0) return 0;
    std::string q = NPPQuery(text, mode);
    if (q.empty()) return 0;
    int flags = NPPSearchFlags(mc, ww, mode);
    sptr_t docLen = NPPSci(ed, SCI_GETLENGTH);
    if (re < rs) std::swap(rs, re);
    rs = MAX((sptr_t)0, rs); re = MIN(re, docLen);
    NSInteger count = 0;
    sptr_t start = rs, end = re;
    if (op == NPPOpReplace) NPPSci(ed, SCI_BEGINUNDOACTION);
    if (op == NPPOpMark) NPPSci(ed, SCI_SETINDICATORCURRENT, (uptr_t)indicator);
    while (start <= end) {
        sptr_t pos = NPPSearchTarget(ed, q, start, end, flags);
        if (pos == -2) { [self reportStatus:@"Find: Invalid Regular Expression" color:NSColor.systemRedColor isError:YES]; count = -1; break; }
        if (pos < 0) break;
        sptr_t tEnd = NPPSci(ed, SCI_GETTARGETEND), matchLen = tEnd - pos;
        count++;
        sptr_t next;
        if (op == NPPOpReplace) {
            sptr_t replaced = NPPReplaceTarget(ed, rep, mode);
            end += replaced - matchLen;
            next = pos + replaced;
        } else {
            if (op == NPPOpMark) {
                if (matchLen > 0) NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)pos, matchLen);
                if (bookmark) {
                    sptr_t line = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)pos);
                    if (!(NPPSci(ed, SCI_MARKERGET, (uptr_t)line) & (1 << NPPMarkerBookmark))) NPPSci(ed, SCI_MARKERADD, (uptr_t)line, NPPMarkerBookmark);
                }
            }
            next = tEnd;
        }
        if (matchLen == 0) {   // zero-length match: step one character or we loop forever
            if (next >= NPPSci(ed, SCI_GETLENGTH)) break;
            next = NPPSci(ed, SCI_POSITIONAFTER, (uptr_t)next);
        }
        start = next;
    }
    if (op == NPPOpReplace) NPPSci(ed, SCI_ENDUNDOACTION);
    return count;
}

- (void)currentRangeForEditor:(ScintillaView *)ed start:(sptr_t *)s end:(sptr_t *)e {
    if (self.inSelection && NPPSci(ed, SCI_GETSELECTIONSTART) != NPPSci(ed, SCI_GETSELECTIONEND)) {
        *s = NPPSci(ed, SCI_GETSELECTIONSTART); *e = NPPSci(ed, SCI_GETSELECTIONEND);
    } else { *s = 0; *e = NPPSci(ed, SCI_GETLENGTH); }
}

#pragma mark Public engine API

- (BOOL)findText:(NSString *)text inEditor:(ScintillaView *)ed backward:(BOOL)backward wrap:(BOOL)wrap
       matchCase:(BOOL)mc wholeWord:(BOOL)ww mode:(NPPSearchMode)mode select:(BOOL)select {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return NO; }
    if (text.length == 0) return NO;
    sptr_t startPos = backward ? NPPSci(ed, SCI_GETSELECTIONSTART) : NPPSci(ed, SCI_GETSELECTIONEND);
    sptr_t s = 0, e = 0;
    NPPFindStatus st = [self runFind:text editor:ed backward:backward wrap:wrap matchCase:mc wholeWord:ww mode:mode startAt:startPos foundStart:&s foundEnd:&e];
    if (st == NPPFSNotFound) { [self reportNotFound:text prefix:@"Find"]; return NO; }
    if (st == NPPFSInvalidRegex) { [self reportWrap:st prefix:@"Find"]; return NO; }
    if (select) [self selectRange:s to:e backward:backward inEditor:ed];
    [self reportWrap:st prefix:@"Find"];
    return YES;
}

- (BOOL)findInEditor:(ScintillaView *)ed backward:(BOOL)backward {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return NO; }
    if (self.searchText.length == 0) { [self showFindWithInitialText:nil]; return NO; }
    [self pushHistory:self.searchText key:kFindHistoryKey];
    return [self findText:self.searchText inEditor:ed backward:backward wrap:self.wrapAround matchCase:self.matchCase
                wholeWord:self.wholeWord mode:self.searchMode select:YES];
}
// N++ sets op._whichDirection = DIR_DOWN/DIR_UP for these commands: the menu items ignore the dialog's direction checkbox.
- (BOOL)findNextInEditor:(ScintillaView *)ed { return [self findInEditor:ed backward:NO]; }
- (BOOL)findPreviousInEditor:(ScintillaView *)ed { return [self findInEditor:ed backward:YES]; }

// processReplace: replace the selection when it is the current match, then find the next one.
- (BOOL)replaceCurrentInEditor:(ScintillaView *)ed {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return NO; }
    if (self.searchText.length == 0) { [self showReplaceWithInitialText:nil]; return NO; }
    if (NPPSci(ed, SCI_GETREADONLY)) {
        [self reportStatus:@"Replace: Cannot replace text. The current document is read only." color:NSColor.systemRedColor isError:YES]; return NO;
    }
    [self pushHistory:self.searchText key:kFindHistoryKey];
    [self pushHistory:self.replaceText key:kReplaceHistoryKey];
    NSString *text = self.searchText; NPPSearchMode mode = self.searchMode;
    std::string q = NPPQuery(text, mode);
    int flags = NPPSearchFlags(self.matchCase, self.wholeWord, mode);
    sptr_t selStart = NPPSci(ed, SCI_GETSELECTIONSTART), selEnd = NPPSci(ed, SCI_GETSELECTIONEND);
    BOOL replaced = NO;
    if (!q.empty()) {
        sptr_t pos = NPPSearchTarget(ed, q, selStart, NPPSci(ed, SCI_GETLENGTH), flags);
        if (pos == -2) { [self reportWrap:NPPFSInvalidRegex prefix:@"Replace"]; return NO; }
        if (pos == selStart && NPPSci(ed, SCI_GETTARGETEND) == selEnd && (selEnd > selStart || mode == NPPSearchModeRegex)) {
            NPPSci(ed, SCI_BEGINUNDOACTION);
            sptr_t len = NPPReplaceTarget(ed, self.replaceText, mode);
            NPPSci(ed, SCI_ENDUNDOACTION);
            NPPSci(ed, SCI_SETSEL, (uptr_t)(selStart + len), selStart + len);
            replaced = YES;
        }
    }
    // Preferences > Searching "Replace: don't move to the following occurrence".
    if (replaced && NPPPreferences.shared.replaceStopsWithoutFindingNext) {
        [self reportStatus:@"Replace: 1 occurrence was replaced." color:NSColor.systemBlueColor isError:NO];
        return YES;
    }
    sptr_t s = 0, e = 0;
    BOOL backward = self.backwardDirection;
    sptr_t startPos = backward ? NPPSci(ed, SCI_GETSELECTIONSTART) : NPPSci(ed, SCI_GETSELECTIONEND);
    NPPFindStatus st = [self runFind:text editor:ed backward:backward wrap:self.wrapAround matchCase:self.matchCase wholeWord:self.wholeWord
                                mode:mode startAt:startPos foundStart:&s foundEnd:&e];
    BOOL found = st == NPPFSFound || st == NPPFSEndReached || st == NPPFSTopReached;
    if (found) [self selectRange:s to:e backward:backward inEditor:ed];
    if (st == NPPFSInvalidRegex) { [self reportWrap:st prefix:@"Replace"]; return NO; }
    if (replaced) {
        if (st == NPPFSEndReached) [self reportStatus:@"Replace: Replaced the 1st occurrence from the top. The end of the document has been reached." color:NSColor.systemGreenColor isError:NO];
        else if (st == NPPFSTopReached) [self reportStatus:@"Replace: Replaced the 1st occurrence from the bottom. The beginning of the document has been reached." color:NSColor.systemGreenColor isError:NO];
        else if (found) [self reportStatus:@"Replace: 1 occurrence was replaced. The next occurrence found." color:NSColor.systemBlueColor isError:NO];
        else [self reportStatus:@"Replace: 1 occurrence was replaced. No more occurrences were found." color:NSColor.systemBlueColor isError:NO];
    } else if (!found) {
        [self reportStatus:@"Replace: no occurrence was found" color:NSColor.systemRedColor isError:YES];
    } else [self reportWrap:st prefix:@"Replace"];
    return found;
}

- (NSInteger)replaceAllInEditor:(ScintillaView *)ed {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return 0; }
    if (self.searchText.length == 0) { [self showReplaceWithInitialText:nil]; return 0; }
    if (NPPSci(ed, SCI_GETREADONLY)) {
        [self reportStatus:@"Replace All: Cannot replace text. The current document is read only." color:NSColor.systemRedColor isError:YES]; return 0;
    }
    [self pushHistory:self.searchText key:kFindHistoryKey];
    [self pushHistory:self.replaceText key:kReplaceHistoryKey];
    sptr_t rs, re; [self currentRangeForEditor:ed start:&rs end:&re];
    sptr_t anchor = NPPSci(ed, SCI_GETANCHOR), caret = NPPSci(ed, SCI_GETCURRENTPOS), oldLen = NPPSci(ed, SCI_GETLENGTH);
    NSInteger n = [self processAll:NPPOpReplace editor:ed text:self.searchText matchCase:self.matchCase wholeWord:self.wholeWord mode:self.searchMode
                       replacement:self.replaceText indicator:0 bookmark:NO rangeStart:rs rangeEnd:re];
    if (n < 0) return 0;
    // ponytail: restore selection clamped to the new length (N++ re-selects the replaced range when "In selection").
    sptr_t newLen = NPPSci(ed, SCI_GETLENGTH), delta = newLen - oldLen;
    if (self.inSelection && rs != re) { NPPSci(ed, SCI_SETSEL, (uptr_t)rs, re + delta); }
    else NPPSci(ed, SCI_SETSEL, (uptr_t)MIN(anchor, newLen), MIN(caret, newLen));
    if (n == 0) [self reportNotFound:self.searchText prefix:@"Replace All"];
    else [self reportStatus:[NSString stringWithFormat:n == 1 ? @"Replace All: %ld occurrence was replaced" : @"Replace All: %ld occurrences were replaced", (long)n]
                      color:NSColor.systemBlueColor isError:NO];
    return n;
}

- (NSInteger)countInEditor:(ScintillaView *)ed {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return 0; }
    if (self.searchText.length == 0) { [self showFindWithInitialText:nil]; return 0; }
    [self pushHistory:self.searchText key:kFindHistoryKey];
    sptr_t rs, re; [self currentRangeForEditor:ed start:&rs end:&re];
    NSInteger n = [self processAll:NPPOpCount editor:ed text:self.searchText matchCase:self.matchCase wholeWord:self.wholeWord mode:self.searchMode
                       replacement:@"" indicator:0 bookmark:NO rangeStart:rs rangeEnd:re];
    if (n < 0) return 0;
    if (n == 0) [self reportNotFound:self.searchText prefix:@"Count"];
    else [self reportStatus:[NSString stringWithFormat:n == 1 ? @"Count: %ld match" : @"Count: %ld matches", (long)n] color:NSColor.systemBlueColor isError:NO];
    return n;
}

- (NSInteger)markAllInEditor:(ScintillaView *)ed {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return 0; }
    if (self.searchText.length == 0) { [self showMarkWithInitialText:nil]; return 0; }
    [self pushHistory:self.searchText key:kFindHistoryKey];
    if (self.purgeMarksBeforeMark) {
        [self clearMarksInEditor:ed];
        if (self.bookmarkLinesOnMark) NPPSci(ed, SCI_MARKERDELETEALL, NPPMarkerBookmark);
    }
    [self ensureIndicatorStyle:NPPIndicatorFindMark color:0x0000FF onEditor:ed];   // N++ default Find Mark Style: red
    sptr_t rs, re; [self currentRangeForEditor:ed start:&rs end:&re];
    NSInteger n = [self processAll:NPPOpMark editor:ed text:self.searchText matchCase:self.matchCase wholeWord:self.wholeWord mode:self.searchMode
                       replacement:@"" indicator:NPPIndicatorFindMark bookmark:self.bookmarkLinesOnMark rangeStart:rs rangeEnd:re];
    if (n < 0) return 0;
    if (n == 0) [self reportNotFound:self.searchText prefix:@"Mark"];
    else [self reportStatus:[NSString stringWithFormat:n == 1 ? @"Mark: %ld match" : @"Mark: %ld matches", (long)n] color:NSColor.systemBlueColor isError:NO];
    return n;
}

- (void)clearMarksInEditor:(ScintillaView *)ed {
    ed = [self editorOr:ed];
    if (!ed) return;
    NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorFindMark);
    NPPSci(ed, SCI_INDICATORCLEARRANGE, 0, NPPSci(ed, SCI_GETLENGTH));
}

// The selection when it may go in the Find field at all: one line, and within Preferences > Searching
// "Maximum number of characters" (FindReplaceDlg::setSearchText's fillFindWhatThreshold test).
- (NSString *)fillableSelectionInEditor:(ScintillaView *)ed {
    NSString *sel = NPPSciSelectedString(ed);
    return (sel.length && [sel rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound &&
            (NSInteger)sel.length <= NPPPreferences.shared.fillFindWhatThreshold) ? sel : nil;
}

// FindReplaceDlg::setSearchText — Select and Find Next / Find (Volatile). N++ passes expand = true here and reads
// no setting, so these two commands keep working with both Searching checkboxes off.
- (NSString *)selectionOrWordInEditor:(ScintillaView *)ed {
    // ponytail: over the threshold N++ leaves the field untouched; the word at the caret keeps Select and Find
    // Next working instead of silently doing nothing. Upgrade path: return @"" and have the callers bail.
    return [self fillableSelectionInEditor:ed] ?: NPPSciWordAtCaret(ed);
}

// FindReplaceDlg::setSearchTextWithSettings — what opening Find / Replace / Mark / Find in Files puts in the Find
// field. Empty means "leave the field as it was". Two Preferences > Searching settings apply, both on by default:
// "Fill Find field with selected text", and "Select word under caret when nothing is selected" beneath it.
- (NSString *)dialogFillTextInEditor:(ScintillaView *)ed {
    if (!ed || !NPPFindPrefBool(kFillFindFieldWithSelectedKey, YES)) return @"";
    NSString *sel = [self fillableSelectionInEditor:ed];
    if (sel) return sel;
    return NPPFindPrefBool(kFillFindFieldSelectCaretKey, YES) ? NPPSciWordAtCaret(ed) : @"";
}

+ (NSFont *)dialogFont {
    CGFloat size = NSFont.smallSystemFontSize + 1;
    return NPPPreferences.shared.monospacedFontFindDlg ? [NSFont userFixedPitchFontOfSize:size]
                                                       : [NSFont systemFontOfSize:size];
}

// N++ recreates the dialog's font from _monospacedFontFindDlg on every doDialog(); we restyle the text entries
// each time the panel is shown, so a change in Preferences shows up without a relaunch.
- (void)applyDialogFont {
    NSFont *f = [NPPFindPanelController dialogFont];
    for (NSComboBox *c in _findCombos) c.font = f;
    for (NSComboBox *c in _replaceCombos) c.font = f;
}

// WM_ACTIVATE in FindReplaceDlg: a selection at least `inSelectionAutocheckThreshold` characters long ticks
// "In selection" by itself; 0 disables the whole mechanism and leaves the checkbox to the user.
- (void)autoCheckInSelectionForEditor:(ScintillaView *)ed {
    NSInteger threshold = NPPPreferences.shared.inSelectionAutocheckThreshold;
    if (!ed || threshold == 0) return;
    sptr_t selStart = NPPSci(ed, SCI_GETSELECTIONSTART), selEnd = NPPSci(ed, SCI_GETSELECTIONEND);
    sptr_t nbSelected = NPPSci(ed, SCI_COUNTCHARACTERS, (uptr_t)selStart, selEnd);
    // Searching in a rectangular or multiple selection is not supported, so it can never auto-check there.
    BOOL enabled = nbSelected != 0 && NPPSci(ed, SCI_GETSELECTIONMODE) != SC_SEL_RECTANGLE &&
                   NPPSci(ed, SCI_GETSELECTIONS) <= 1;
    BOOL checked = enabled && nbSelected >= (sptr_t)threshold;
    if (checked != self.inSelection) self.inSelection = checked;
}

- (void)selectAndFindNextInEditor:(ScintillaView *)ed backward:(BOOL)backward {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return; }
    NSString *str = [self selectionOrWordInEditor:ed];
    if (str.length == 0) { NSBeep(); return; }
    self.searchText = str;
    [self pushHistory:str key:kFindHistoryKey];
    // N++: current options but Normal search mode, direction from the command.
    [self findText:str inEditor:ed backward:backward wrap:self.wrapAround matchCase:self.matchCase wholeWord:self.wholeWord mode:NPPSearchModeNormal select:YES];
}

- (void)volatileFindInEditor:(ScintillaView *)ed backward:(BOOL)backward {
    ed = [self editorOr:ed];
    if (!ed) { NSBeep(); return; }
    NSString *str = [self selectionOrWordInEditor:ed];
    if (str.length == 0) { NSBeep(); return; }
    [self findText:str inEditor:ed backward:backward wrap:YES matchCase:NO wholeWord:YES mode:NPPSearchModeNormal select:YES];
}

#pragma mark Panel UI

- (void)buildWindow {
    if (_uiBuilt) return;
    _uiBuilt = YES;
    NSRect content = NSMakeRect(0, 0, 580, 356);
    NPPFindPanel *panel = [[NPPFindPanel alloc] initWithContentRect:content
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Find"; panel.floatingPanel = YES; panel.hidesOnDeactivate = NO; panel.becomesKeyOnlyIfNeeded = NO;
    panel.delegate = self; panel.releasedWhenClosed = NO;
    [panel setFrameAutosaveName:@"NPPFindPanel"];
    self.window = panel;

    _tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(8, 30, 564, 320)];
    _tabs.delegate = self;
    for (NSString *name in @[@"Find", @"Replace", @"Mark"]) {
        NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:name]; item.label = name; item.identifier = name;
        item.view = [self buildTab:name];
        [_tabs addTabViewItem:item];
    }
    [panel.contentView addSubview:_tabs];
    _statusLabel = Label(@"", NSMakeRect(14, 8, 552, 18), panel.contentView);
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self refreshCombos];
    [self syncModeUI];
}

- (NSComboBox *)comboIn:(NPPFlippedView *)v y:(CGFloat)y bindTo:(NSString *)key history:(NSMutableArray *)store {
    NSComboBox *c = [[NSComboBox alloc] initWithFrame:NSMakeRect(110, y, 280, 24)];
    c.usesDataSource = NO; c.completes = YES; c.numberOfVisibleItems = (NSInteger)kHistoryMax;
    c.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
    [c bind:NSValueBinding toObject:self withKeyPath:key options:@{NSContinuouslyUpdatesValueBindingOption: @YES, NSNullPlaceholderBindingOption: @""}];
    [v addSubview:c]; [store addObject:c];
    return c;
}

- (NSView *)buildTab:(NSString *)name {
    BOOL isReplace = [name isEqualToString:@"Replace"], isMark = [name isEqualToString:@"Mark"];
    NPPFlippedView *v = [[NPPFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 544, 280)];
    Label(@"Find what:", NSMakeRect(12, 16, 96, 18), v);
    NSComboBox *findCombo = [self comboIn:v y:12 bindTo:@"searchText" history:_findCombos];
    CGFloat y = 44;
    if (isReplace) {
        Label(@"Replace with:", NSMakeRect(12, y + 4, 96, 18), v);
        NSComboBox *replaceCombo = [self comboIn:v y:y bindTo:@"replaceText" history:_replaceCombos];
        // FindReplaceDlg.rc:34 IDD_FINDREPLACE_SWAP_BUTTON, between the two fields. The combos give up the width.
        for (NSComboBox *c in @[findCombo, replaceCombo]) { NSRect f = c.frame; f.size.width = 250; c.frame = f; }
        // ponytail: upstream's is a split button whose menu also offers copy-down and copy-up; the plain button is
        // the gesture people use. Ceiling: an NSButton with a pull-down menu of the same three items.
        // 26pt is what the incremental bar's arrow buttons need for a glyph inside a rounded bezel; 22 clips.
        // Centred on the gap between the two fields (12..36 and 44..68), right edge flush with the Search Mode box.
        NSButton *swap = Button(@"⇅", NSMakeRect(364, 28, 26, 24), self, @selector(swapFindReplaceAction:), v);
        swap.toolTip = @"Swap Find with Replace";
        y += 32;
    }

    // Option checkboxes (bound to the persisted properties, shared across tabs)
    y += 8;
    NSArray *opts = @[@[@"Match whole word only", @"wholeWord"], @[@"Match case", @"matchCase"], @[@"Wrap around", @"wrapAround"],
                      @[@"Backward direction", @"backwardDirection"], @[@"In selection", @"inSelection"]];
    for (NSArray *o in opts) {
        NSButton *b = Check(o[0], NSMakeRect(12, y, 180, 20), v);
        [b bind:NSValueBinding toObject:self withKeyPath:o[1] options:nil];
        y += 24;
    }
    if (isMark) {
        for (NSArray *o in @[@[@"Bookmark line", @"bookmarkLinesOnMark"], @[@"Purge for each search", @"purgeMarksBeforeMark"]]) {
            NSButton *b = Check(o[0], NSMakeRect(12, y, 180, 20), v);
            [b bind:NSValueBinding toObject:self withKeyPath:o[1] options:nil];
            y += 24;
        }
    }

    // Search mode box
    CGFloat boxY = isReplace ? 84 : 52;
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(204, boxY, 186, 130)];
    box.title = @"Search Mode"; box.titleFont = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
    NPPFlippedView *bv = [[NPPFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 170, 100)];
    box.contentView = bv;
    CGFloat ry = 4;
    NSArray *modes = @[@"Normal", @"Extended (\\n, \\r, \\t, \\0, \\x...)", @"Regular expression"];
    for (NSInteger i = 0; i < 3; i++) {
        NSButton *r = [NSButton radioButtonWithTitle:modes[i] target:self action:@selector(modeRadioChanged:)];
        r.frame = NSMakeRect(6, ry, 160, 20); r.tag = i; r.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
        [bv addSubview:r]; [_modeRadios addObject:r]; ry += 22;
    }
    NSButton *dot = Check(@". matches newline", NSMakeRect(24, ry, 140, 20), bv);
    [dot bind:NSValueBinding toObject:self withKeyPath:@"dotMatchesNewline" options:nil];
    [_dotChecks addObject:dot];
    [v addSubview:box];

    // Buttons
    CGFloat bx = 404, bw = 132, by = 10;
    NSButton *primary;
    if (isMark) {
        primary = Button(@"Mark All", NSMakeRect(bx, by, bw, 26), self, @selector(markAllAction:), v); by += 30;
        Button(@"Clear all marks", NSMakeRect(bx, by, bw, 26), self, @selector(clearMarksAction:), v); by += 30;
    } else if (isReplace) {
        primary = Button(@"Find Next", NSMakeRect(bx, by, bw, 26), self, @selector(findNextAction:), v); by += 30;
        Button(@"Replace", NSMakeRect(bx, by, bw, 26), self, @selector(replaceAction:), v); by += 30;
        Button(@"Replace All", NSMakeRect(bx, by, bw, 26), self, @selector(replaceAllAction:), v); by += 30;
        NSButton *all = Button(@"Replace All in All Opened Documents", NSMakeRect(bx, by, bw, 40), self, @selector(replaceAllOpenAction:), v); by += 44;
        all.lineBreakMode = NSLineBreakByWordWrapping;
    } else {
        primary = Button(@"Find Next", NSMakeRect(bx, by, bw, 26), self, @selector(findNextAction:), v); by += 30;
        Button(@"Count", NSMakeRect(bx, by, bw, 26), self, @selector(countAction:), v); by += 30;
        NSButton *findAll = Button(@"Find All in Current Document", NSMakeRect(bx, by, bw, 40), self, @selector(findAllCurrentDocAction:), v); by += 44;
        findAll.lineBreakMode = NSLineBreakByWordWrapping;
    }
    primary.keyEquivalent = @"\r";
    NSButton *close = Button(@"Close", NSMakeRect(bx, by, bw, 26), self, @selector(closeAction:), v);
    close.keyEquivalent = @"\e";
    return v;
}

- (void)modeRadioChanged:(NSButton *)sender { self.searchMode = (NPPSearchMode)sender.tag; }

- (NSComboBox *)currentFindCombo {
    NSInteger idx = [_tabs indexOfTabViewItem:_tabs.selectedTabViewItem];
    return idx >= 0 && idx < (NSInteger)_findCombos.count ? _findCombos[idx] : nil;
}

- (void)showTab:(NSInteger)index initialText:(NSString *)text {
    [self buildWindow];
    ScintillaView *editor = [self.targetProvider currentEditorForFind];
    // N++ calls setSearchTextWithSettings() right after doDialog(): a usable selection (or, with the second
    // checkbox on, the word at the caret) replaces whatever the field held; nothing usable leaves it alone.
    if (text) self.searchText = text;
    else if (editor) {
        NSString *fill = [self dialogFillTextInEditor:editor];
        if (fill.length) self.searchText = fill;
    }
    [self applyDialogFont];
    [self autoCheckInSelectionForEditor:editor];
    [_tabs selectTabViewItemAtIndex:index];
    self.window.title = _tabs.selectedTabViewItem.label;
    [self reportStatus:@"" color:NSColor.labelColor isError:NO];
    [self.window makeKeyAndOrderFront:nil];
    NSComboBox *combo = self.currentFindCombo;
    [self.window makeFirstResponder:combo];
    [combo selectText:nil];
}
- (void)showFindWithInitialText:(NSString *)text { [self showTab:0 initialText:text]; }
- (void)showReplaceWithInitialText:(NSString *)text { [self showTab:1 initialText:text]; }
- (void)showMarkWithInitialText:(NSString *)text { [self showTab:2 initialText:text]; }

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item {
    self.window.title = item.label;
    NSComboBox *combo = self.currentFindCombo;
    [self.window makeFirstResponder:combo]; [combo selectText:nil];
}

- (void)flushComboEditing {
    // Bindings are continuous, but flush the field editor in case a completion is pending.
    [self.window makeFirstResponder:self.window.firstResponder];
    id fr = self.window.firstResponder;
    if ([fr isKindOfClass:NSTextView.class]) {
        NSTextView *tv = fr; NSComboBox *c = (NSComboBox *)tv.delegate;
        if ([c isKindOfClass:NSComboBox.class]) {
            if ([_findCombos containsObject:c]) self.searchText = c.stringValue;
            else if ([_replaceCombos containsObject:c]) self.replaceText = c.stringValue;
        }
    }
}

- (ScintillaView *)panelEditor {
    ScintillaView *ed = [self.targetProvider currentEditorForFind];
    if (!ed) NSBeep();
    return ed;
}

- (void)findNextAction:(id)sender { [self flushComboEditing]; ScintillaView *ed = self.panelEditor; if (ed) [self findNextInEditor:ed]; }
- (void)countAction:(id)sender { [self flushComboEditing]; ScintillaView *ed = self.panelEditor; if (ed) [self countInEditor:ed]; }
- (void)replaceAction:(id)sender { [self flushComboEditing]; ScintillaView *ed = self.panelEditor; if (ed) [self replaceCurrentInEditor:ed]; }
- (void)replaceAllAction:(id)sender { [self flushComboEditing]; ScintillaView *ed = self.panelEditor; if (ed) [self replaceAllInEditor:ed]; }
- (void)markAllAction:(id)sender { [self flushComboEditing]; ScintillaView *ed = self.panelEditor; if (ed) [self markAllInEditor:ed]; }
- (void)clearMarksAction:(id)sender { ScintillaView *ed = self.panelEditor; if (ed) { [self clearMarksInEditor:ed]; [self reportStatus:@"" color:NSColor.labelColor isError:NO]; } }
- (void)closeAction:(id)sender { [self.window performClose:sender]; }

// FindReplaceDlg.cpp:2352 (IDC_FINDALL_CURRENTFILE): read the Find combo, then list every hit in the results
// panel. It does not mark anything — Mark All lives on the Mark tab.
- (void)findAllCurrentDocAction:(id)sender {
    [self flushComboEditing];
    if (self.searchText.length == 0) { [self showFindWithInitialText:nil]; return; }
    NPPDocument *doc = [gContext contextCurrentDocument];
    if (!doc) { NSBeep(); [self reportStatus:@"Find All: no document." color:NSColor.systemRedColor isError:YES]; return; }
    [self pushHistory:self.searchText key:kFindHistoryKey];
    [self reportStatus:@"" color:NSColor.labelColor isError:NO];
    NPPFindInFiles *finder = NPPFindInFiles.shared;
    finder.context = gContext;
    // ponytail: N++ narrows to CURR_DOC_SELECTION when "In selection" is ticked; -findAllIn: always scans the whole
    // document. Ceiling: a range argument on NPPFindInFiles' -findAllIn:.
    [finder findAllIn:@[doc] text:self.searchText matchCase:self.matchCase wholeWord:self.wholeWord
                 mode:self.searchMode scope:@"Current Document"];
}

// IDD_FINDREPLACE_SWAP_BUTTON: exchange the two fields. The combos are bound to these properties, so they follow.
- (void)swapFindReplaceAction:(id)sender {
    [self flushComboEditing];
    // A combo being edited still owns a field editor holding the pre-swap string; the binding pushes the new value
    // into the cell, but the field editor writes its stale copy back the moment it commits. End editing first.
    [self.window makeFirstResponder:self.window];
    NSString *find = self.searchText;
    self.searchText = self.replaceText;
    self.replaceText = find;
    NSComboBox *combo = self.currentFindCombo;
    [self.window makeFirstResponder:combo];
    [combo selectText:nil];
}

// FindReplaceDlg::replaceInOpenDocsConfirmCheck — MB_OKCANCEL | MB_DEFBUTTON2, so Return cancels.
- (BOOL)confirmReplaceInAllOpenDocs {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Are you sure?";
    alert.informativeText = @"Are you sure you want to replace all occurrences in all open documents?";
    NSButton *ok = [alert addButtonWithTitle:@"Replace All"];
    NSButton *cancel = [alert addButtonWithTitle:@"Cancel"];
    ok.keyEquivalent = @"";
    cancel.keyEquivalent = @"\r";
    return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)replaceAllOpenAction:(id)sender {
    [self flushComboEditing];
    if (self.searchText.length == 0) { NSBeep(); return; }
    NSArray<ScintillaView *> *editors = [self.targetProvider allOpenEditorsForFind];
    if (editors.count == 0) { NSBeep(); return; }
    if (NPPPreferences.shared.confirmReplaceInAllOpenDocs && ![self confirmReplaceInAllOpenDocs]) return;
    [self pushHistory:self.searchText key:kFindHistoryKey];
    [self pushHistory:self.replaceText key:kReplaceHistoryKey];
    NSInteger total = 0;
    for (ScintillaView *ed in editors) {
        if (NPPSci(ed, SCI_GETREADONLY)) continue;
        sptr_t anchor = NPPSci(ed, SCI_GETANCHOR), caret = NPPSci(ed, SCI_GETCURRENTPOS);
        NSInteger n = [self processAll:NPPOpReplace editor:ed text:self.searchText matchCase:self.matchCase wholeWord:self.wholeWord mode:self.searchMode
                           replacement:self.replaceText indicator:0 bookmark:NO rangeStart:0 rangeEnd:NPPSci(ed, SCI_GETLENGTH)];
        if (n < 0) return;   // regex error already reported
        sptr_t len = NPPSci(ed, SCI_GETLENGTH);
        NPPSci(ed, SCI_SETSEL, (uptr_t)MIN(anchor, len), MIN(caret, len));
        total += n;
    }
    if (total == 0) [self reportNotFound:self.searchText prefix:@"Replace All in Opened Files"];
    else [self reportStatus:[NSString stringWithFormat:total == 1 ? @"Replace All in Opened Files: %ld occurrence was replaced" : @"Replace All in Opened Files: %ld occurrences were replaced", (long)total]
                      color:NSColor.systemBlueColor isError:NO];
}

#pragma mark Go To Line sheet

- (void)showGoToLineForEditor:(ScintillaView *)editor {
    ScintillaView *ed = [self editorOr:editor];
    if (!ed || !ed.window) { NSBeep(); return; }
    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 190) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    sheet.title = @"Go To...";
    NPPFlippedView *v = [[NPPFlippedView alloc] initWithFrame:sheet.contentView.bounds];
    sheet.contentView = v;

    sptr_t curPos = NPPSci(ed, SCI_GETCURRENTPOS);
    sptr_t curLine = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)curPos) + 1;
    sptr_t maxLine = NPPSci(ed, SCI_GETLINECOUNT), maxPos = NPPSci(ed, SCI_GETLENGTH);

    NSButton *lineRadio = [NSButton radioButtonWithTitle:@"Line" target:nil action:nil];
    NSButton *offsetRadio = [NSButton radioButtonWithTitle:@"Offset" target:nil action:nil];
    lineRadio.frame = NSMakeRect(20, 16, 80, 20); offsetRadio.frame = NSMakeRect(110, 16, 80, 20);
    lineRadio.state = NSControlStateValueOn;
    [v addSubview:lineRadio]; [v addSubview:offsetRadio];

    NSTextField *here = Label([NSString stringWithFormat:@"You are here : %ld", (long)curLine], NSMakeRect(20, 48, 320, 18), v);
    Label(@"You want to go to :", NSMakeRect(20, 76, 150, 18), v);
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(170, 73, 100, 22)];
    field.formatter = ({ NSNumberFormatter *f = [NSNumberFormatter new]; f.numberStyle = NSNumberFormatterNoStyle; f.minimum = @0; f; });
    [v addSubview:field];
    NSTextField *maxLabel = Label([NSString stringWithFormat:@"You can't go further than : %ld", (long)maxLine], NSMakeRect(20, 104, 320, 18), v);

    __block BOOL byOffset = NO;
    NSButton *go = Button(@"Go", NSMakeRect(250, 145, 90, 28), nil, nil, v);
    NSButton *cancel = Button(@"Cancel", NSMakeRect(150, 145, 90, 28), nil, nil, v);
    go.keyEquivalent = @"\r"; cancel.keyEquivalent = @"\e";

    void (^refresh)(void) = ^{
        byOffset = offsetRadio.state == NSControlStateValueOn;
        here.stringValue = [NSString stringWithFormat:@"You are here : %ld", (long)(byOffset ? curPos : curLine)];
        maxLabel.stringValue = [NSString stringWithFormat:@"You can't go further than : %ld", (long)(byOffset ? maxPos : maxLine)];
    };
    NPPBlockTarget *radioT = [NPPBlockTarget targetWithBlock:^(id s) { refresh(); }];
    lineRadio.target = radioT; lineRadio.action = @selector(fire:); offsetRadio.target = radioT; offsetRadio.action = @selector(fire:);
    NPPBlockTarget *goT = [NPPBlockTarget targetWithBlock:^(id s) {
        NSString *txt = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        long long n = 0;
        if (txt.length == 0 || ![[NSScanner scannerWithString:txt] scanLongLong:&n] || n < 0) { NSBeep(); return; }
        if (byOffset) {
            if (n > maxPos) { NSBeep(); return; }
            NPPSci(ed, SCI_ENSUREVISIBLE, (uptr_t)NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)n));
            NPPSci(ed, SCI_GOTOPOS, (uptr_t)n);
        } else {
            if (n < 1 || n > maxLine) { NSBeep(); return; }
            NPPSci(ed, SCI_ENSUREVISIBLE, (uptr_t)(n - 1));
            NPPSci(ed, SCI_GOTOLINE, (uptr_t)(n - 1));
        }
        NPPSci(ed, SCI_SCROLLCARET);
        [ed.window endSheet:sheet returnCode:NSModalResponseOK];
    }];
    NPPBlockTarget *cancelT = [NPPBlockTarget targetWithBlock:^(id s) { [ed.window endSheet:sheet returnCode:NSModalResponseCancel]; }];
    go.target = goT; go.action = @selector(fire:); cancel.target = cancelT; cancel.action = @selector(fire:);
    objc_setAssociatedObject(sheet, "targets", @[radioT, goT, cancelT], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [ed.window beginSheet:sheet completionHandler:^(NSModalResponse rc) { [ed.window makeFirstResponder:ed]; }];
    [sheet makeFirstResponder:field];
}

#pragma mark Incremental search bar

- (NSView *)incrementalSearchBarForEditorProvider:(id<NPPFindTargetProvider>)provider {
    if (!_incBar) { _incBar = [[NPPIncrementalSearchBar alloc] initWithFrame:NSMakeRect(0, 0, 800, 26)]; _incBar.owner = self; }
    _incBar.provider = provider ?: self.targetProvider;
    return _incBar;
}

- (void)showIncrementalSearch {
    if (!_incBar) [self incrementalSearchBarForEditorProvider:self.targetProvider];
    ScintillaView *ed = [_incBar.provider currentEditorForFind];
    if (!ed) { NSBeep(); return; }
    NSString *sel = NPPSciSelectedString(ed);
    if (sel.length && [sel rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) {
        _incBar.field.stringValue = sel; _incBar.lastText = sel;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:NPPIncrementalSearchShouldShowNotification object:nil];
    [_incBar focus];
    if (_incBar.field.stringValue.length) [_incBar applyHighlight];
}

#pragma mark NSWindowDelegate

// N++ re-evaluates the "In selection" auto-check on WM_ACTIVATE, i.e. every time the user comes back to the
// dialog after changing the selection.
- (void)windowDidBecomeKey:(NSNotification *)n {
    [self autoCheckInSelectionForEditor:[self.targetProvider currentEditorForFind]];
}

- (void)windowWillClose:(NSNotification *)n {
    [self flushComboEditing];
    ScintillaView *ed = [self.targetProvider currentEditorForFind];
    if (ed) [ed.window makeFirstResponder:ed];
}

#pragma mark - Self-checks

// By title where the caption is the access path (N++ taught the user to look for those words), by action where the
// control is a glyph (⇅) whose gesture — not its exact character — is what has to survive.
static NSButton *NPPFindButton(NSView *v, NSString *title, SEL action) {
    for (NSView *sub in v.subviews) {
        if ([sub isKindOfClass:NSButton.class]) {
            NSButton *b = (NSButton *)sub;
            if (title ? [b.title isEqualToString:title] : (b.action == action)) return b;
        }
        NSButton *b = NPPFindButton(sub, title, action);
        if (b) return b;
    }
    return nil;
}

static void NPPCheckClickable(NSMutableArray<NSString *> *fails, NSButton *b, NSString *what, id target) {
    if (b.isHidden || !b.isEnabled || b.target != target) [fails addObject:[what stringByAppendingString:@" is not clickable"]];
}

// The buttons are the access path: a working -findAllCurrentDocAction: nobody can click is still a missing feature,
// so these assert the controls exist on the right tab and are wired to the right selector.
+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    NPPFindPanelController *find = NPPFindPanelController.shared;
    // -buildWindow claims the panel's frame autosave name, overwriting the user's remembered position (the same
    // dance NPPFindInFiles' self-check does).
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *frameKey = @"NSWindow Frame NPPFindPanel";
    id oldFrame = [ud objectForKey:frameKey];
    [find buildWindow];

    NSView *findTab = [find->_tabs tabViewItemAtIndex:0].view, *replaceTab = [find->_tabs tabViewItemAtIndex:1].view;
    NSView *markTab = [find->_tabs tabViewItemAtIndex:2].view;

    NSButton *findAll = NPPFindButton(findTab, @"Find All in Current Document", NULL);
    if (!findAll) [fails addObject:@"Find tab has no \"Find All in Current Document\" button"];
    else if (findAll.action != @selector(findAllCurrentDocAction:))
        [fails addObject:[NSString stringWithFormat:@"\"Find All in Current Document\" runs %@, not the results-panel listing",
                          NSStringFromSelector(findAll.action)]];
    else NPPCheckClickable(fails, findAll, @"\"Find All in Current Document\"", find);

    // Rewiring that button is what broke it last time; Mark All is the feature it used to run, so check it survived.
    NSButton *markAll = NPPFindButton(markTab, @"Mark All", NULL);
    if (!markAll || markAll.action != @selector(markAllAction:))
        [fails addObject:@"Mark tab has no \"Mark All\" button running -markAllAction:"];

    NSButton *swap = NPPFindButton(replaceTab, nil, @selector(swapFindReplaceAction:));
    if (!swap) [fails addObject:@"Replace tab has no swap control between Find and Replace"];
    else {
        NPPCheckClickable(fails, swap, @"the Replace tab's swap control", find);
        NSString *oldSearch = find.searchText, *oldReplace = find.replaceText;
        find.searchText = @"npp-selfcheck-find"; find.replaceText = @"npp-selfcheck-replace";
        [NSApp sendAction:swap.action to:swap.target from:swap];
        if (![find.searchText isEqualToString:@"npp-selfcheck-replace"] || ![find.replaceText isEqualToString:@"npp-selfcheck-find"])
            [fails addObject:[NSString stringWithFormat:@"swap did not exchange the fields (find=%@, replace=%@)",
                              find.searchText, find.replaceText]];
        find.searchText = oldSearch; find.replaceText = oldReplace;
        // The swap re-focused a combo, so a field editor is live holding the probe text; drop it or it writes back.
        [find.window makeFirstResponder:find.window];
    }

    if (oldFrame) [ud setObject:oldFrame forKey:frameKey]; else [ud removeObjectForKey:frameKey];
    return fails;
}
@end
