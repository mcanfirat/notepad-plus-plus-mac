// NPPDocumentMapPanel.mm — port of Notepad++'s Document Map (WinControls/DocumentMap/documentMap.cpp).
//
// N++ gives the map view the *same* Scintilla document pointer (SCI_SETDOCPOINTER) and overlays a
// transparent "viewzone" window. Here the map owns its own document and mirrors the text, because the
// Cocoa ScintillaView owns its document and NPPDocument owns the notification delegate.
#import "NPPDocumentMapPanel.h"
#import "NPPDocument.h"
#import "NPPLanguageManager.h"
#import "NPPUtils.h"
#import <Scintilla/ScintillaView.h>
#include <string>
#include <utility>
#include <vector>

static NSString *const kVisibleKey = @"NPPDocumentMapVisible";

static const NSUInteger kMaxMirroredBytes = 2u * 1024u * 1024u;   // ponytail: first 2 MB only; the map is a thumbnail, not a viewer
static const NSTimeInterval kPollInterval = 0.1;
static const NSTimeInterval kMinRefreshInterval = 0.5;
static const size_t kMaxMirroredFolds = 4096;     // ponytail: stop collecting there; N++ also stops treating fold lists one by one past a threshold

// Document Peeker on the map (N++ NppGUI::_isDocPeekOnMap / documentSnapshot.cpp). Same dwell, same borderless
// panel and the same dismissal rules as the tab strip's peeker in NPPTabBarView.mm — deliberately a second copy:
// that one is file-private there, and neither file may edit the other. If a third caller ever wants it, lift
// NPPDocMapPeek* out of this file as the shared helper.
static const NSTimeInterval kPeekDelay = 0.5;      // hover dwell before the peeker pops (matches the tab strip)
static const NSInteger kPeekLines   = 24;          // window of lines shown around the hovered one
static const CGFloat kPeekWidth     = 300;
static const CGFloat kPeekHeight    = 180;
static NSString *const kPeekDefaultsKey = @"NPPPeekOnDocumentMap";   // off by default, like upstream

@class NPPDocumentMapPanel;

#pragma mark - Overlay (viewport rectangle + all mouse handling)

@interface NPPDocMapOverlayView : NSView
@property (nonatomic, weak) NPPDocumentMapPanel *panel;
@property (nonatomic) NSRange visibleLines;      // location = first visible map line, length = lines on screen
@property (nonatomic) CGFloat lineHeight;
@property (nonatomic) NSInteger mapFirstLine;
@end

@interface NPPDocumentMapPanel ()
- (void)mapClickedAtY:(CGFloat)y inHeight:(CGFloat)h;
- (void)mapScrolledByLines:(NSInteger)lines;
- (void)mapHoveredAtPoint:(NSPoint)p;   // overlay coords
- (void)hidePeek;
@end

@implementation NPPDocMapOverlayView {
    NSTrackingArea *_tracking;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event { [self.panel hidePeek]; }
- (void)mouseMoved:(NSEvent *)event {
    [self.panel mapHoveredAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}
// The peek panel is a child of whatever window we were in, and a parent window retains its children: leaving it
// attached when the map is undocked would strand a floating panel on screen.
- (void)viewDidMoveToWindow { [self.panel hidePeek]; }

- (void)drawRect:(NSRect)dirty {
    if (self.lineHeight <= 0 || self.visibleLines.length == 0) return;
    CGFloat y = ((CGFloat)self.visibleLines.location - (CGFloat)self.mapFirstLine) * self.lineHeight;
    CGFloat h = MAX(2.0, (CGFloat)self.visibleLines.length * self.lineHeight);
    NSRect r = NSMakeRect(0.5, floor(y) + 0.5, NSWidth(self.bounds) - 1.0, floor(h));
    NSColor *tint = [NSColor selectedContentBackgroundColor];
    [[tint colorWithAlphaComponent:0.22] setFill];
    NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
    [[tint colorWithAlphaComponent:0.9] setStroke];
    NSBezierPath *p = [NSBezierPath bezierPathWithRect:r];
    p.lineWidth = 1.0;
    [p stroke];
}

- (void)mouseDown:(NSEvent *)event { [self.panel hidePeek]; [self track:event]; }
- (void)mouseDragged:(NSEvent *)event { [self track:event]; }

- (void)track:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [self.panel mapClickedAtY:p.y inHeight:NSHeight(self.bounds)];
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8.0 : event.scrollingDeltaY;
    NSInteger lines = (NSInteger)llround(-dy * 3.0);
    if (lines) { [self.panel hidePeek]; [self.panel mapScrolledByLines:lines]; }
}

@end

#pragma mark - Fold mirroring

// {header, last child} of every collapsed fold, in document lines (N++ ScintillaEditView::getCurrentFoldStates,
// which DocumentMap::reloadMap feeds to the map's syncFoldStateWith). SCI_CONTRACTEDFOLDNEXT walks only the
// collapsed headers, so this costs nothing on a document with no folds — which is why the tick can call it.
typedef std::vector<std::pair<sptr_t, sptr_t>> NPPFoldRanges;

static NPPFoldRanges NPPDocMapFoldRanges(ScintillaView *ed) {
    NPPFoldRanges ranges;
    if (!ed) return ranges;
    sptr_t lines = NPPSci(ed, SCI_GETLINECOUNT);
    for (sptr_t line = 0; line < lines && ranges.size() < kMaxMirroredFolds; ) {
        sptr_t header = NPPSci(ed, SCI_CONTRACTEDFOLDNEXT, (uptr_t)line);
        if (header < 0 || header >= lines) break;
        ranges.emplace_back(header, NPPSci(ed, SCI_GETLASTCHILD, (uptr_t)header, -1));
        line = header + 1;
    }
    return ranges;
}

#pragma mark - Panel

@implementation NPPDocumentMapPanel {
    NSView *_container;
    ScintillaView *_map;
    NPPDocMapOverlayView *_overlay;
    NSTimer *_timer;
    __weak NPPDocument *_doc;
    NSString *_mirroredLanguageName;
    sptr_t _mirroredLength, _mirroredLineCount;
    NPPFoldRanges _mirroredFolds;
    NSTimeInterval _lastRefresh;
    BOOL _visible;
    // Document Peeker (hover preview)
    NSTimer *_peekTimer;
    NSPanel *_peekWindow;
    NSTextField *_peekLabel;
}

+ (instancetype)shared {
    static NPPDocumentMapPanel *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPDocumentMapPanel alloc] init]; });
    return s;
}

#pragma mark NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd { return cmd == NPPCmdViewDocumentMap; }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return cmd == NPPCmdViewDocumentMap && context != nil;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdViewDocumentMap || !context) return NO;
    NPPDocumentMapPanel *panel = [self shared];
    [context contextTogglePanel:panel];
    BOOL nowVisible = [context contextPanelIsVisible:panel];
    [[NSUserDefaults standardUserDefaults] setBool:nowVisible forKey:kVisibleKey];
    return YES;
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdViewDocumentMap || !context) return NO;
    return [context contextPanelIsVisible:[self shared]];
}

#pragma mark NPPPanel

- (NSString *)panelTitle { return @"Document Map"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeRight; }
- (CGFloat)panelPreferredSize { return 140.0; }

- (NSView *)panelView {
    if (_container) return _container;

    _container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 140, 400)];
    _container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _map = [[ScintillaView alloc] initWithFrame:_container.bounds];
    _map.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_container addSubview:_map];

    // The map is a picture, not an editor (N++ documentMap.cpp DOCUMENTMAP init).
    NPPSci(_map, SCI_SETCODEPAGE, SC_CP_UTF8);
    NPPSci(_map, SCI_SETMODEVENTMASK, 0);
    NPPSci(_map, SCI_SETUNDOCOLLECTION, 0);
    NPPSci(_map, SCI_SETVSCROLLBAR, 0);
    NPPSci(_map, SCI_SETHSCROLLBAR, 0);
    // ponytail: the map never wraps, even when the editor does — N++ wraps it and resizes it to
    // editorWidth/zoomRatio so the wrap points line up, which we would have to re-derive for a 2 pt font in a
    // 140 pt dock. The viewport box and the click target stay right anyway because both cross over by document
    // line (syncViewportFrom:/mapLineAtY:). Upgrade path: SCI_SETWRAPMODE here plus a width computed from
    // SCI_TEXTWIDTH, if the thumbnail's shape under wrap ever matters.
    NPPSci(_map, SCI_SETWRAPMODE, SC_WRAP_NONE);
    NPPSci(_map, SCI_SETCARETSTYLE, CARETSTYLE_INVISIBLE);
    NPPSci(_map, SCI_SETMARGINS, 0);
    for (int m = 0; m < 5; ++m) NPPSci(_map, SCI_SETMARGINWIDTHN, m, 0);
    NPPSci(_map, SCI_SETMARGINLEFT, 0, 0);
    NPPSci(_map, SCI_SETMARGINRIGHT, 0, 0);
    NPPSci(_map, SCI_SETREADONLY, 1);

    _overlay = [[NPPDocMapOverlayView alloc] initWithFrame:_container.bounds];
    _overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _overlay.panel = self;
    [_container addSubview:_overlay];

    [self applyStyling];
    return _container;
}

- (void)panelDidBecomeVisible {
    _visible = YES;
    (void)[self panelView];
    [self refreshMirrorForced:YES];
    [self startTimer];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kVisibleKey];
}

- (void)panelWillHide {
    _visible = NO;
    [_timer invalidate]; _timer = nil;
    [self hidePeek];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kVisibleKey];
}

- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc {
    _doc = doc;
    [self hidePeek];                     // the popup is a slice of the old document
    if (!_container) return;
    [self refreshMirrorForced:YES];
    if (_visible) [self startTimer];
}

- (nullable NSMenu *)panelActionMenu { return nil; }

#pragma mark - Mirroring

- (void)applyStyling {
    if (!_map) return;
    NPPLanguageManager *lm = [NPPLanguageManager shared];
    NPPLanguage *lang = _doc.language ?: [lm normalTextLanguage];
    if (lang) [lm applyLanguage:lang toEditor:_map];
    _mirroredLanguageName = lang.name;

    // Shrink the whole thing the way N++ does with SCI_SETZOOM -10 on a normal-size view: set a 2 pt
    // default font first, then STYLECLEARALL so every lexical style inherits it.
    NPPSci(_map, SCI_STYLESETSIZE, STYLE_DEFAULT, 2);
    NPPSci(_map, SCI_STYLECLEARALL);
    NPPSci(_map, SCI_SETZOOM, 0);
    for (int m = 0; m < 5; ++m) NPPSci(_map, SCI_SETMARGINWIDTHN, m, 0);
    NPPSci(_map, SCI_SETVSCROLLBAR, 0);
    NPPSci(_map, SCI_SETHSCROLLBAR, 0);
    NPPSci(_map, SCI_SETCARETSTYLE, CARETSTYLE_INVISIBLE);
}

- (void)refreshMirrorForced:(BOOL)force {
    ScintillaView *src = _doc.editor;
    if (!_map) return;
    if (!src) {
        NPPSci(_map, SCI_SETREADONLY, 0);
        NPPSciStr(_map, SCI_SETTEXT, 0, "");
        NPPSci(_map, SCI_SETREADONLY, 1);
        _mirroredLength = _mirroredLineCount = 0;
        _mirroredFolds.clear();
        [_overlay setVisibleLines:NSMakeRange(0, 0)];
        [_overlay setNeedsDisplay:YES];
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - _lastRefresh < kMinRefreshInterval) return;

    // ponytail: length + line count as the change detector — NPPDocument owns the SCN_MODIFIED delegate, so
    // there is no notification to hook. Misses same-size edits until the next real change; good enough for a
    // thumbnail. Upgrade path: a change hook on NPPDocument.
    sptr_t len = NPPSci(src, SCI_GETLENGTH);
    sptr_t lines = NPPSci(src, SCI_GETLINECOUNT);
    NSString *langName = _doc.language.name;
    BOOL langChanged = !(langName == _mirroredLanguageName || [langName isEqualToString:_mirroredLanguageName]);
    if (!force && len == _mirroredLength && lines == _mirroredLineCount && !langChanged) return;

    _lastRefresh = now;
    if (force || langChanged) [self applyStyling];

    sptr_t end = MIN(len, (sptr_t)kMaxMirroredBytes);
    std::string text = end > 0 ? NPPSciGetRange(src, 0, end) : std::string();
    NPPSci(_map, SCI_SETREADONLY, 0);
    NPPSciStr(_map, SCI_SETTEXT, 0, text.c_str());
    NPPSci(_map, SCI_EMPTYUNDOBUFFER);
    NPPSci(_map, SCI_SETREADONLY, 1);
    _mirroredLength = len;
    _mirroredLineCount = lines;
    _mirroredFolds.clear();     // SCI_SETTEXT made every line visible again: the next tick re-folds the map
}

// Collapse in the map exactly what is collapsed in the editor (N++ folds the map from SCN_MARGINCLICK and
// SCN_FOLDINGSTATECHANGED, NppNotification.cpp). We hide the ranges rather than fold the map's own fold
// levels: hiding needs no lexer, and the map's 2 pt styling never draws a fold margin anyway.
// Returns YES when the map's visibility actually changed. ponytail: fold state is polled with everything else
// instead of hooked; upgrade path is the same change hook on NPPDocument the mirror wants.
- (BOOL)mirrorFoldsFrom:(ScintillaView *)src {
    if (!_map) return NO;
    NPPFoldRanges ranges = NPPDocMapFoldRanges(src);
    if (ranges == _mirroredFolds) return NO;
    _mirroredFolds = ranges;
    sptr_t last = MAX((sptr_t)0, NPPSci(_map, SCI_GETLINECOUNT) - 1);
    NPPSci(_map, SCI_SHOWLINES, 0, last);
    for (const auto &r : ranges) {
        sptr_t from = r.first + 1, to = MIN(r.second, last);       // the mirror is truncated: clamp, never wrap around
        if (from <= to) NPPSci(_map, SCI_HIDELINES, (uptr_t)from, to);
    }
    return YES;
}

#pragma mark - Viewport polling

- (void)startTimer {
    if (_timer) return;
    // ponytail: 100 ms polling instead of SCN_UPDATEUI because NPPDocument owns the Scintilla delegate.
    // Runs only while the panel is visible; each tick skips out when the window is not key.
    _timer = [NSTimer scheduledTimerWithTimeInterval:kPollInterval repeats:YES block:^(NSTimer *t) {
        [self tick];
    }];
    _timer.tolerance = kPollInterval / 2;
}

- (void)tick {
    if (!_visible || !_container.window.isKeyWindow) return;
    [self refreshMirrorForced:NO];
    [self mirrorFoldsFrom:_doc.editor];
    [self syncViewport];
}

// Everything below indexes the map by DISPLAY line and crosses over to the editor by DOCUMENT line, because the
// two views fold and wrap differently (the map never wraps, and its mirror can lag a fold by one tick). A display
// line on one side means nothing on the other; a document line means the same on both.

// Display lines the map holds: N++ reads the same thing off the map view in scrollMapWith().
- (NSInteger)mapDisplayLineCount {
    if (!_map) return 0;
    sptr_t last = NPPSci(_map, SCI_GETLINECOUNT) - 1;
    if (last < 0) return 0;
    // SCI_WRAPCOUNT lays the line out to count its rows, so ask only when wrapping could make it more than one:
    // the last mirrored line of a minified file is a megabyte long and this runs on every editor scroll.
    sptr_t rows = NPPSci(_map, SCI_GETWRAPMODE) == SC_WRAP_NONE ? 1 : NPPSci(_map, SCI_WRAPCOUNT, (uptr_t)last);
    return (NSInteger)MAX((sptr_t)1, NPPSci(_map, SCI_VISIBLEFROMDOCLINE, (uptr_t)last) + MAX((sptr_t)1, rows));
}

// Map display line showing a given document line, clamped to the truncated mirror. For a line a fold hid, this
// is where it went: the display line of the first visible line after it.
- (NSInteger)mapDisplayLineForDocLine:(sptr_t)docLine {
    sptr_t last = MAX((sptr_t)0, NPPSci(_map, SCI_GETLINECOUNT) - 1);
    sptr_t doc = MAX((sptr_t)0, MIN(docLine, last));
    return (NSInteger)NPPSci(_map, SCI_VISIBLEFROMDOCLINE, (uptr_t)doc);
}

// One past that, so a box built from a first and a last document line covers the last one too — and covers
// nothing at all of a last line the map has folded away. (+1 and not SCI_WRAPCOUNT: the map never wraps.)
- (NSInteger)mapDisplayEndForDocLine:(sptr_t)docLine {
    sptr_t last = MAX((sptr_t)0, NPPSci(_map, SCI_GETLINECOUNT) - 1);
    sptr_t doc = MAX((sptr_t)0, MIN(docLine, last));
    return [self mapDisplayLineForDocLine:doc] + (NPPSci(_map, SCI_GETLINEVISIBLE, (uptr_t)doc) ? 1 : 0);
}

- (void)syncViewport { [self syncViewportFrom:_doc.editor]; }

- (void)syncViewportFrom:(ScintillaView *)src {
    if (!src || !_map) {
        _overlay.visibleLines = NSMakeRange(0, 0);
        [_overlay setNeedsDisplay:YES];
        return;
    }
    // The editor's viewport in document lines, then the same lines in the map's display space.
    NSInteger editFirst = MAX((sptr_t)0, NPPSci(src, SCI_GETFIRSTVISIBLELINE));
    NSInteger onScreen = MAX((sptr_t)1, NPPSci(src, SCI_LINESONSCREEN));
    sptr_t firstDoc = NPPSci(src, SCI_DOCLINEFROMVISIBLE, (uptr_t)editFirst);
    sptr_t lastDoc = NPPSci(src, SCI_DOCLINEFROMVISIBLE, (uptr_t)(editFirst + onScreen - 1));
    NSInteger total = [self mapDisplayLineCount];
    NSInteger first = MIN([self mapDisplayLineForDocLine:firstDoc], MAX((NSInteger)0, total - 1));
    NSInteger len = MAX((NSInteger)1, MIN([self mapDisplayEndForDocLine:lastDoc], total) - first);

    CGFloat h = (CGFloat)NPPSci(_map, SCI_TEXTHEIGHT, 0);
    if (h < 1) h = 1;
    NSInteger mapOnScreen = MAX((sptr_t)1, NPPSci(_map, SCI_LINESONSCREEN));
    NSInteger mapFirst = (NSInteger)NPPSci(_map, SCI_GETFIRSTVISIBLELINE);

    // Keep the highlighted zone inside the map: scroll the map only when the editor's range falls outside it.
    if (first < mapFirst || first + len > mapFirst + mapOnScreen) {
        NSInteger want = first - (mapOnScreen - len) / 2;
        want = MAX(0, MIN(want, MAX(0, total - mapOnScreen)));
        NPPSci(_map, SCI_SETFIRSTVISIBLELINE, (uptr_t)want);
        mapFirst = (NSInteger)NPPSci(_map, SCI_GETFIRSTVISIBLELINE);
    }

    _overlay.lineHeight = h;
    _overlay.mapFirstLine = mapFirst;
    _overlay.visibleLines = NSMakeRange((NSUInteger)first, (NSUInteger)len);
    [_overlay setNeedsDisplay:YES];
}

#pragma mark - Interaction

// The DOCUMENT line under a point in the overlay: pixels give a map display line, which folds turn into a
// different document line. Both the click and the peeker route through this, so the two can never disagree
// about which line the pointer is on.
- (NSInteger)mapLineAtY:(CGFloat)y inHeight:(CGFloat)h {
    if (!_map) return -1;
    CGFloat lh = (CGFloat)NPPSci(_map, SCI_TEXTHEIGHT, 0);
    if (lh < 1) lh = 1;
    NSInteger display = (NSInteger)NPPSci(_map, SCI_GETFIRSTVISIBLELINE) + (NSInteger)floor(MAX(0.0, MIN(y, h)) / lh);
    display = MAX(0, MIN(display, MAX(0, [self mapDisplayLineCount] - 1)));
    return (NSInteger)NPPSci(_map, SCI_DOCLINEFROMVISIBLE, (uptr_t)display);
}

- (void)mapClickedAtY:(CGFloat)y inHeight:(CGFloat)h { [self scrollEditor:_doc.editor toMapY:y inHeight:h]; }

- (void)scrollEditor:(ScintillaView *)src toMapY:(CGFloat)y inHeight:(CGFloat)h {
    NSInteger line = [self mapLineAtY:y inHeight:h];
    if (!src || line < 0) return;
    // Back to the editor's own display space: the clicked document line may sit lower there (wrapped lines
    // above it) or higher (folds of its own), so SCI_SETFIRSTVISIBLELINE needs the conversion, not the raw line.
    sptr_t doc = MIN((sptr_t)line, MAX((sptr_t)0, NPPSci(src, SCI_GETLINECOUNT) - 1));
    NSInteger display = (NSInteger)NPPSci(src, SCI_VISIBLEFROMDOCLINE, (uptr_t)doc);
    NSInteger onScreen = MAX(1, (NSInteger)NPPSci(src, SCI_LINESONSCREEN));
    NSInteger target = MAX(0, display - onScreen / 2);         // centre the clicked line, like N++'s viewzone drag
    NPPSci(src, SCI_SETFIRSTVISIBLELINE, (uptr_t)target);
    [self syncViewportFrom:src];
}

- (void)mapScrolledByLines:(NSInteger)lines {
    ScintillaView *src = _doc.editor;
    if (!src || lines == 0) return;
    NPPSci(src, SCI_LINESCROLL, 0, (sptr_t)lines);
    [self syncViewport];
}

#pragma mark - Document Peeker (NppGUI::_isDocPeekOnMap)

// Hovering the map pops the lines under the pointer next to it; the editor does not move (that is what a click
// is for). N++ shows a second, zoomed ScintillaView (documentSnapshot.cpp DocumentPeeker).
// ponytail: plain text in a label, same as NPPTabBarView's peeker — no second editor, no syntax colours.
// Upgrade path: swap the label for a read-only ScintillaView if the colours turn out to matter.
//
// ponytail: the preference is read at hover time instead of observed. A popup already on screen when the user
// unticks the box stays until the pointer moves. Upgrade path: the NSUserDefaultsDidChange observer the tab
// strip keeps, if that ever bites.
- (BOOL)peekEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:kPeekDefaultsKey]; }

// Every reason to refuse a peek except "the view is in no window", which only the live path can judge.
// Its own predicate so the gate is testable headless.
- (BOOL)peekAllowedForLine:(NSInteger)line {
    if (!_map || line < 0) return NO;
    return NPPSci(_map, SCI_GETLENGTH) > 0 && line < (NSInteger)NPPSci(_map, SCI_GETLINECOUNT) && self.peekEnabled;
}

// Read from the mirror, not from the editor: the map's line numbering is what the pointer was over, and the
// text is already there. Empty for a refused line, so callers need no second check.
- (NSString *)peekTextForLine:(NSInteger)line {
    if (![self peekAllowedForLine:line]) return @"";
    NSInteger total = (NSInteger)NPPSci(_map, SCI_GETLINECOUNT);
    NSInteger first = MAX(0, MIN(line - kPeekLines / 2, total - kPeekLines));
    NSInteger last = MIN(total - 1, first + kPeekLines - 1);
    sptr_t start = NPPSci(_map, SCI_POSITIONFROMLINE, (uptr_t)first);
    sptr_t end = NPPSci(_map, SCI_GETLINEENDPOSITION, (uptr_t)last);
    if (start < 0 || end <= start) return @"";
    std::string s = NPPSciGetRange(_map, start, end);
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)hidePeek {
    [_peekTimer invalidate];
    _peekTimer = nil;
    if (!_peekWindow) return;
    [_peekWindow.parentWindow removeChildWindow:_peekWindow];
    [_peekWindow orderOut:nil];
}

- (void)mapHoveredAtPoint:(NSPoint)p {
    [_peekTimer invalidate];
    _peekTimer = nil;
    NSInteger line = [self mapLineAtY:p.y inHeight:NSHeight(_overlay.bounds)];
    if (!_overlay.window || ![self peekAllowedForLine:line]) { [self hidePeek]; return; }
    if (_peekWindow.isVisible) { [self showPeekForLine:line atPoint:p]; return; }   // already open: follow the pointer
    __weak NPPDocumentMapPanel *weak = self;
    _peekTimer = [NSTimer scheduledTimerWithTimeInterval:kPeekDelay repeats:NO block:^(NSTimer *t) {
        [weak showPeekForLine:line atPoint:p];
    }];
}

- (void)showPeekForLine:(NSInteger)line atPoint:(NSPoint)p {
    _peekTimer = nil;
    // Re-check the gate: the preference, the document and the window can all have changed during the dwell.
    if (!_overlay.window || ![self peekAllowedForLine:line]) { [self hidePeek]; return; }
    NSString *text = [self peekTextForLine:line];
    if (!text.length) { [self hidePeek]; return; }

    if (!_peekWindow) {
        _peekWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kPeekWidth, kPeekHeight)
                                                 styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                   backing:NSBackingStoreBuffered defer:YES];
        _peekWindow.opaque = NO;
        _peekWindow.backgroundColor = NSColor.clearColor;
        _peekWindow.hasShadow = YES;
        _peekWindow.level = NSPopUpMenuWindowLevel;
        _peekWindow.ignoresMouseEvents = YES;      // or the popup would steal the hover it was opened by
        NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kPeekWidth, kPeekHeight)];
        bg.material = NSVisualEffectMaterialPopover;
        bg.state = NSVisualEffectStateActive;
        bg.wantsLayer = YES;
        bg.layer.cornerRadius = 6;
        bg.layer.masksToBounds = YES;
        _peekLabel = [NSTextField labelWithString:@""];
        _peekLabel.frame = NSInsetRect(bg.bounds, 6, 6);
        _peekLabel.font = [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightRegular];
        _peekLabel.textColor = NSColor.secondaryLabelColor;
        _peekLabel.maximumNumberOfLines = kPeekLines;
        _peekLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [bg addSubview:_peekLabel];
        _peekWindow.contentView = bg;
    }
    _peekLabel.stringValue = text;

    // Beside the map rather than over it, centred on the pointer (the map is docked at a window edge, so the
    // popup goes on the map's inboard side and flips only when that lands off-screen).
    NSRect mapOnScreen = [_overlay.window convertRectToScreen:[_overlay convertRect:_overlay.bounds toView:nil]];
    NSPoint inWindow = [_overlay convertPoint:p toView:nil];
    NSRect pointer = [_overlay.window convertRectToScreen:NSMakeRect(inWindow.x, inWindow.y, 1, 1)];
    NSRect visible = (_overlay.window.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat x = NSMinX(mapOnScreen) - kPeekWidth - 2;
    if (x < NSMinX(visible)) x = NSMaxX(mapOnScreen) + 2;
    x = MAX(NSMinX(visible), MIN(x, NSMaxX(visible) - kPeekWidth));
    CGFloat y = MAX(NSMinY(visible), MIN(NSMinY(pointer) - kPeekHeight / 2, NSMaxY(visible) - kPeekHeight));
    [_peekWindow setFrame:NSMakeRect(x, y, kPeekWidth, kPeekHeight) display:YES];
    if (_peekWindow.parentWindow != _overlay.window) {
        [_peekWindow.parentWindow removeChildWindow:_peekWindow];
        [_overlay.window addChildWindow:_peekWindow ordered:NSWindowAbove];
    }
    [_peekWindow orderFront:nil];
}

- (void)dealloc { [_timer invalidate]; [self hidePeek]; }

#pragma mark - Self checks

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) { if (!ok) [fails addObject:msg]; };

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    id savedPeek = [ud objectForKey:kPeekDefaultsKey];
    [ud setBool:YES forKey:kPeekDefaultsKey];

    // Not +shared: this instance gets its mirror scribbled on, and it is never docked or timed.
    NPPDocumentMapPanel *panel = [[NPPDocumentMapPanel alloc] init];
    (void)[panel panelView];
    expect(![panel peekAllowedForLine:0], @"peek armed over an empty map");

    NSMutableArray<NSString *> *body = [NSMutableArray array];
    for (int i = 0; i < 100; i++) [body addObject:[NSString stringWithFormat:@"line%d", i]];
    NSString *mirrored = [body componentsJoinedByString:@"\n"];      // 100 lines, no trailing newline
    NPPSci(panel->_map, SCI_SETREADONLY, 0);
    NPPSciStr(panel->_map, SCI_SETTEXT, 0, mirrored.UTF8String);
    NPPSci(panel->_map, SCI_SETREADONLY, 1);
    expect((NSInteger)NPPSci(panel->_map, SCI_GETLINECOUNT) == 100, @"the mirror did not take the 100 test lines");

    // The gate, one clause at a time.
    expect([panel peekAllowedForLine:50], @"peek refused although the map has text and the preference is on");
    expect(![panel peekAllowedForLine:-1], @"peek armed above the first line");
    expect(![panel peekAllowedForLine:100], @"peek armed past the last mirrored line");
    [ud setBool:NO forKey:kPeekDefaultsKey];
    expect(![panel peekAllowedForLine:50], @"peek armed with NPPPeekOnDocumentMap off");
    expect([panel peekTextForLine:50].length == 0, @"peek text produced with NPPPeekOnDocumentMap off");
    [ud setBool:YES forKey:kPeekDefaultsKey];

    // The window of lines: centred on the hovered one, never longer than kPeekLines, never past either end.
    NSArray<NSString *> *mid = [[panel peekTextForLine:50] componentsSeparatedByString:@"\n"];
    expect(mid.count == (NSUInteger)kPeekLines, ([NSString stringWithFormat:@"peek showed %lu lines, want %ld", (unsigned long)mid.count, (long)kPeekLines]));
    expect([mid containsObject:@"line50"], @"peek text does not contain the hovered line");
    expect(![mid containsObject:@"line10"], @"peek text is not a window around the hovered line");
    NSArray<NSString *> *top = [[panel peekTextForLine:0] componentsSeparatedByString:@"\n"];
    expect([top.firstObject isEqualToString:@"line0"], @"peek at the first line does not start there");
    NSArray<NSString *> *bottom = [[panel peekTextForLine:99] componentsSeparatedByString:@"\n"];
    expect([bottom.lastObject isEqualToString:@"line99"], @"peek at the last line does not end there");
    expect(bottom.count == (NSUInteger)kPeekLines, @"peek at the last line ran short");
    expect([panel peekTextForLine:1000].length == 0, @"peek text produced for a line past the end");

    // The line under the pointer, shared with click-to-scroll.
    CGFloat h = 200;
    NSInteger firstVisible = (NSInteger)NPPSci(panel->_map, SCI_GETFIRSTVISIBLELINE);
    expect([panel mapLineAtY:0 inHeight:h] == firstVisible, @"the top pixel of the map is not the first visible line");
    expect([panel mapLineAtY:-50 inHeight:h] == firstVisible, @"a point above the map is not clamped to its top");
    expect([panel mapLineAtY:1e6 inHeight:1e6] == 99, @"a point far below the last line is not clamped to the mirror");

    // Headless: no window, so nothing may pop up.
    [panel showPeekForLine:50 atPoint:NSMakePoint(5, 5)];
    expect(!panel->_peekWindow.isVisible, @"the peeker showed itself for a map that is in no window");
    [panel hidePeek];

    // --- Folds: the map must collapse what the editor collapsed, and the box/click must index by display line ---
    // A stand-in editor with the same 100 lines and one collapsed fold over 10..19. No lexer here, so the fold
    // levels we set by hand survive.
    ScintillaView *src = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NPPSci(src, SCI_SETCODEPAGE, SC_CP_UTF8);
    NPPSciStr(src, SCI_SETTEXT, 0, mirrored.UTF8String);
    NPPSci(src, SCI_SETFOLDLEVEL, 10, SC_FOLDLEVELBASE | SC_FOLDLEVELHEADERFLAG);
    for (int l = 11; l <= 19; l++) NPPSci(src, SCI_SETFOLDLEVEL, (uptr_t)l, SC_FOLDLEVELBASE + 1);
    NPPSci(src, SCI_SETFOLDLEVEL, 20, SC_FOLDLEVELBASE);
    NPPSci(src, SCI_FOLDLINE, 10, SC_FOLDACTION_CONTRACT);
    expect(NPPSci(src, SCI_GETLINEVISIBLE, 15) == 0, @"the stand-in editor would not collapse the test fold");

    NPPFoldRanges ranges = NPPDocMapFoldRanges(src);
    expect(ranges.size() == 1 && ranges[0].first == 10 && ranges[0].second == 19, @"the collapsed fold range was read back wrong");
    expect([panel mirrorFoldsFrom:src], @"the map did not take the editor's collapsed fold");
    expect(NPPSci(panel->_map, SCI_GETLINEVISIBLE, 15) == 0, @"the map still shows a line the editor folded away");
    expect(NPPSci(panel->_map, SCI_GETLINEVISIBLE, 10) == 1, @"the map hid the fold header itself");
    expect(NPPSci(panel->_map, SCI_GETLINEVISIBLE, 20) == 1, @"the map hid a line outside the collapsed fold");
    // 100 mirrored lines with 11..19 hidden by the collapsed fold at 10: 91 display lines, not 90.
    expect([panel mapDisplayLineCount] == 91, ([NSString stringWithFormat:@"the folded map counts %ld display lines, not 91", (long)[panel mapDisplayLineCount]]));
    expect(![panel mirrorFoldsFrom:src], @"an unchanged fold state was re-applied to the map (every tick would redraw it)");

    // Display line 10 of the folded map is document line 20 — this is what the peeker and the click both need.
    CGFloat lh = (CGFloat)NPPSci(panel->_map, SCI_TEXTHEIGHT, 0);
    NPPSci(panel->_map, SCI_SETFIRSTVISIBLELINE, 0);
    // Display line 10 is still the fold header (document line 10); the line after it is document line 20, because
    // 11..19 are collapsed. Indexing by document line would answer 10 and 11 — this is the pair that catches it.
    CGFloat tenth = 10 * lh + lh / 2, eleventh = 11 * lh + lh / 2;
    expect([panel mapLineAtY:tenth inHeight:1000] == 10,
           ([NSString stringWithFormat:@"display line 10 maps to document line %ld, not the fold header 10",
             (long)[panel mapLineAtY:tenth inHeight:1000]]));
    expect([panel mapLineAtY:eleventh inHeight:1000] == 20,
           ([NSString stringWithFormat:@"display line 11 maps to document line %ld, not 20 — the map is still indexed by document line under a fold",
             (long)[panel mapLineAtY:eleventh inHeight:1000]]));
    expect([[panel peekTextForLine:[panel mapLineAtY:tenth inHeight:1000]] containsString:@"line20"], @"the peeker follows a different line than the pointer");

    NPPSci(src, SCI_FOLDLINE, 10, SC_FOLDACTION_EXPAND);
    expect([panel mirrorFoldsFrom:src], @"the map did not follow the editor unfolding");
    expect(NPPSci(panel->_map, SCI_GETLINEVISIBLE, 15) == 1, @"the map stayed folded after the editor expanded");

    // Now the other way round — map folded, editor not — which is what a tick of lag looks like. The box and the
    // click must still land on the right text, and the box must stay inside the map.
    NPPSci(panel->_map, SCI_HIDELINES, 10, 19);
    NPPSci(src, SCI_SETFIRSTVISIBLELINE, 20);
    expect(NPPSci(src, SCI_GETFIRSTVISIBLELINE) == 20, @"the stand-in editor would not scroll to line 20");
    [panel syncViewportFrom:src];
    expect(panel->_overlay.visibleLines.location == 10, @"the viewport box is placed by display line instead of document line");

    // Both ends of the box, counted independently: it must cover exactly the map lines that are still visible
    // and hold document lines the editor is showing. (Counting SCI_GETLINEVISIBLE, not SCI_VISIBLEFROMDOCLINE.)
    NPPSci(src, SCI_SETFIRSTVISIBLELINE, 5);
    [panel syncViewportFrom:src];
    NSRange box = panel->_overlay.visibleLines;
    sptr_t editFirst = NPPSci(src, SCI_GETFIRSTVISIBLELINE);
    sptr_t firstDoc = NPPSci(src, SCI_DOCLINEFROMVISIBLE, (uptr_t)editFirst);
    sptr_t lastDoc = NPPSci(src, SCI_DOCLINEFROMVISIBLE, (uptr_t)(editFirst + MAX((sptr_t)1, NPPSci(src, SCI_LINESONSCREEN)) - 1));
    NSUInteger before = 0, through = 0;
    for (sptr_t l = 0; l < 100; l++) {
        if (!NPPSci(panel->_map, SCI_GETLINEVISIBLE, (uptr_t)l)) continue;
        if (l < firstDoc) before++;
        if (l <= lastDoc) through++;
    }
    expect(box.location == before, @"the viewport box starts on the wrong map line");
    expect(box.location + box.length == through, @"the viewport box is as tall as the editor's screenful, ignoring what the map folded away");

    NPPSci(src, SCI_SETFIRSTVISIBLELINE, 0);
    NPPSci(panel->_map, SCI_SETFIRSTVISIBLELINE, 0);
    [panel scrollEditor:src toMapY:10 * lh + lh / 2 inHeight:1000];
    NSInteger onScreen = MAX(1, (NSInteger)NPPSci(src, SCI_LINESONSCREEN));
    expect(NPPSci(src, SCI_GETFIRSTVISIBLELINE) == MAX(0, 20 - onScreen / 2), @"clicking a folded map scrolled the editor to the wrong line");

    if (savedPeek) [ud setObject:savedPeek forKey:kPeekDefaultsKey]; else [ud removeObjectForKey:kPeekDefaultsKey];
    return fails;
}

@end
