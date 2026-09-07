// NPPTabBarView.mm — Notepad++-style document tab strip, custom drawn.
#import "NPPTabBarView.h"
#import "NPPPreferences.h"   // ponytail: the tab bar reads one preference directly (double-click closes) rather than growing an API for it
#import "NPPLanguageManager.h"   // Dark Mode tone palette + NPPThemeDidChangeNotification
#import "NPPStatusBarView.h"     // its +selfCheckFailures runs from ours (see the self-check section)
#import <algorithm>
#import <vector>

@implementation NPPTabItem
@end

static const CGFloat kTabMinWidth   = 90;
static const CGFloat kTabMaxWidth   = 240;
// N++ g_TabHeight / g_TabHeightLarge (22 / 25 px, NppConstants.h) — "Reduce" is the short strip, and it is on by
// default. Same ratio at this port's row height, and the taller strip carries the heavier label upstream draws with
// it (TabBar::setFont's _hLargeFont is FW_HEAVY).
static const CGFloat kTabHeight     = 28;
static const CGFloat kTabHeightLarge = 32;
static const CGFloat kIndicatorH    = 3;
static const CGFloat kDotSize       = 8;
static const CGFloat kCloseSize     = 14;   // hit/draw box; glyph is 10pt
static const CGFloat kPadX          = 8;
static const CGFloat kDragThreshold = 6;
static const CGFloat kPlusWidth     = 30;   // "+" button; kept out of the tab area so tabs never run under it
static const CGFloat kListWidth     = 24;   // document drop-down, parked at the end of the bar
static const CGFloat kVerticalWidth = 180;  // width the strip asks for when the vertical preference is on
static const CGFloat kPinSize       = kCloseSize;   // the pin box matches the close box so pinning never re-flows a tab
static const NSTimeInterval kPeekDelay = 0.5;       // hover dwell before the Document Peeker pops (N++ uses the system hover time)
static const NSInteger kPeekLines   = 24;
static const NSUInteger kPeekMaxChars = 4000;       // the delegate may hand back a whole document; only the head is ever shown
static const CGFloat kPeekWidth     = 300;
static const CGFloat kPeekHeight    = 180;
static NSString *const kPeekDefaultsKey = @"NPPTabPeekOnTab";   // N++ NppGUI::_isDocPeekOnTab, off by default

// The Dark Mode tone colours the strip paints with (NPPLanguageManager publishes all twelve; these six are the
// ones a tab strip has a use for). Keyed by the manager's own style names so the palette travels as one dictionary.
static NSString *const kDMBarBg     = @"Dark mode background";
static NSString *const kDMBarSofter = @"Dark mode softer background";
static NSString *const kDMBarHot    = @"Dark mode hot background";
static NSString *const kDMBarText   = @"Dark mode text";
static NSString *const kDMBarDarker = @"Dark mode darker text";
static NSString *const kDMBarEdge   = @"Dark mode edge";

@interface NPPTabBarView () <NSDraggingDestination>
// nil (or a nil slot) = light theme: the strip keeps every colour the host gave it. Its own step so the
// self-check can hand the strip a palette without repainting the user's actual theme.
- (void)applyDarkPalette:(nullable NSDictionary<NSString *, NSColor *> *)palette;
@end

// Delegate stub for +selfCheckFailures: records what the window controller would have to persist.
@interface NPPTabBarPinProbe : NSObject <NPPTabBarDelegate>
@property (nonatomic) NSInteger pinIndex;
@property (nonatomic) NSInteger pinCalls;
@property (nonatomic) BOOL pinned;
@property (nonatomic) NSInteger selIndex;
@property (nonatomic) NSInteger selCalls;
@property (nonatomic) NSInteger sizeCalls;
@property (nonatomic) NSInteger closeIndex;
@property (nonatomic) NSInteger closeCalls;
@property (nonatomic) NSInteger dropOutIndex;
@property (nonatomic) NSInteger dropOutCalls;
@end
@implementation NPPTabBarPinProbe
- (void)tabBar:(NPPTabBarView *)b didSelectTabAtIndex:(NSInteger)i { _selCalls++; _selIndex = i; }
- (void)tabBar:(NPPTabBarView *)b didRequestCloseTabAtIndex:(NSInteger)i { _closeCalls++; _closeIndex = i; }
- (void)tabBar:(NPPTabBarView *)b didMoveTabFromIndex:(NSInteger)f toIndex:(NSInteger)t {}
- (void)tabBar:(NPPTabBarView *)b didDropTabAtIndex:(NSInteger)i outsideAtScreenPoint:(NSPoint)p { _dropOutCalls++; _dropOutIndex = i; }
- (void)tabBarDidChangePreferredSize:(NPPTabBarView *)b { _sizeCalls++; }
- (void)tabBar:(NPPTabBarView *)b didSetPinned:(BOOL)p forTabAtIndex:(NSInteger)i { _pinCalls++; _pinned = p; _pinIndex = i; }
@end

// ...and one that also offers preview text, so the Document Peeker's gate can be checked both ways.
@interface NPPTabBarPeekProbe : NPPTabBarPinProbe
@end
@implementation NPPTabBarPeekProbe
- (NSString *)tabBar:(NPPTabBarView *)b previewTextForTabAtIndex:(NSInteger)i { return @"line 1\nline 2"; }
@end

// ...and one that writes tooltips the way the window controller does for an untitled buffer: only tab 1 gets one.
@interface NPPTabBarTipProbe : NPPTabBarPinProbe
@end
@implementation NPPTabBarTipProbe
- (NSString *)tabBar:(NPPTabBarView *)b toolTipForTabAtIndex:(NSInteger)i {
    return i == 1 ? @"new 1\n2026-09-07 10:11:12" : nil;
}
@end

@implementation NPPTabBarView {
    NSArray<NPPTabItem *> *_items;
    std::vector<NSRect> _frames;       // per-tab frame in content coords (scroll not applied); laid out per mode
    NSRect    _plusContent;            // "+" box in the same content coords
    CGFloat   _contentExtent;          // content size along the scrolling axis
    NSInteger _rows;                   // multi-line row count (1 otherwise)
    NSInteger _notifiedRows;           // last row count the delegate was told about
    BOOL      _notifyingSize;          // re-entrancy guard: the delegate resizes us, which lays out again
    BOOL      _vertical, _multiLine, _locked, _peekOn;   // cached preferences, refreshed on any defaults change
    // …and the six "look and feel" ones (N++ NppGUI::_tabStatus: TAB_REDUCE, TAB_ALTICONS, TAB_DRAWINACTIVETAB,
    // TAB_DRAWTOPBAR, TAB_SHOWONLYPINNEDBUTTON, TAB_INACTIVETABSHOWBUTTON).
    BOOL      _reduce, _altIcons, _drawInactiveTab, _drawTopBar, _onlyPinnedButton, _inactiveTabButtons;
    CGFloat _scrollOffset;             // >= 0, content pixels scrolled off the leading edge
    NSInteger _hoverIndex;
    NSInteger _hoverClose;             // index whose close box is hovered
    NSInteger _hoverPin;               // index whose pin box is hovered
    BOOL      _hoverPlus;
    BOOL      _hoverList;
    NSTrackingArea *_tracking;
    // Document Peeker (hover preview)
    NSTimer  *_peekTimer;
    NSPanel  *_peekWindow;
    NSTextField *_peekLabel;
    // mouse-down / drag state
    NSInteger _pressIndex;
    NSPoint   _pressPoint;
    BOOL      _pressOnClose;
    BOOL      _pressOnPin;
    BOOL      _dragging;
    CGFloat   _dragDX, _dragDY;        // visual offset of dragged tab
    // explicit theme colours (nil = system default)
    NSColor *_activeBg, *_activeFg, *_indicator, *_inactiveBg, *_inactiveFg, *_barBg;
    // …and the Dark Mode tone's palette, which wins over them (all nil under a light theme, so light mode is a
    // strict no-op — see -applyDarkPalette:).
    NSColor *_dmBg, *_dmSofter, *_dmHot, *_dmText, *_dmDarkerText, *_dmEdge;
}

@synthesize delegate = _delegate;
@synthesize selectedIndex = _selectedIndex;
@synthesize showCloseButtons = _showCloseButtons;

#pragma mark - Init

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _items = @[];
    _selectedIndex = -1;
    _hoverIndex = _hoverClose = _hoverPin = _pressIndex = -1;
    _showCloseButtons = YES;
    _rows = _notifiedRows = 1;
    [self readDefaults];
    // One observer for all four keys: NPPPreferences writes them through NSUserDefaults, and the Document Peeker's
    // NPPTabPeekOnTab has no checkbox at all, so watching the store itself is what reacts to every one of them.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsDidChange:)
                                               name:NSUserDefaultsDidChangeNotification object:nil];
    // Theme *and* Dark Mode tone arrive on one notification (NPPLanguageManager re-derives both and posts once).
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeDidChange:)
                                               name:NPPThemeDidChangeNotification object:nil];
    [self readDarkPalette];
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [self setAccessibilityRole:NSAccessibilityTabGroupRole]; // ponytail: no per-tab a11y children
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)wantsUpdateLayer { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, self.preferredHeight); }

#pragma mark - Modes (preferences the strip reads itself)

// The vertical strip needs a frame its host has actually made into a column — the preference alone cannot move the
// view. Until the host honours -preferredWidth the strip stays what it is today rather than stacking tabs inside a
// band. "Taller than it is wide" is the test, not "tall enough": a two-row multi-line band is 56pt tall and would
// pass a height-only check, then draw a column of window-wide tabs until the next layout.
// ponytail: the aspect test is the whole handshake; a "did you place me as a column" call would be one more
// protocol method for the same answer.
// N++ TAB_REDUCE: the short strip (on by default). Everything that measures a row goes through this, so turning
// Reduce off makes every mode — one row, wrapped rows, a column — taller by the same amount.
- (CGFloat)rowHeight { return _reduce ? kTabHeight : kTabHeightLarge; }
- (NSFont *)labelFont { return _reduce ? [NSFont systemFontOfSize:12] : [NSFont boldSystemFontOfSize:13]; }

- (BOOL)vertical {
    NSSize b = self.bounds.size;
    return _vertical && b.height > b.width && b.height >= [self rowHeight] * 2;
}
- (BOOL)isMultiLine { return !self.vertical && _multiLine; }
- (BOOL)scrollsVertically { return self.vertical || self.isMultiLine; }   // rows scroll, a single row slides sideways
- (CGFloat)preferredWidth { return _vertical ? kVerticalWidth : 0; }
- (CGFloat)preferredHeight { return [self rowHeight] * (_vertical ? 1 : (CGFloat)MAX(1, _rows)); }

- (void)readDefaults {
    NPPPreferences *p = NPPPreferences.shared;
    _vertical = p.tabBarVertical;
    _multiLine = p.tabBarMultiLine;
    _locked = p.tabBarLocked;
    _peekOn = self.peekEnabled;
    _reduce = p.tabBarReduce;
    _altIcons = p.tabBarAlternateIcons;
    _drawInactiveTab = p.tabBarDrawInactiveTab;
    _drawTopBar = p.tabBarDrawTopBar;
    _onlyPinnedButton = p.tabBarShowOnlyPinnedButton;
    _inactiveTabButtons = p.tabBarInactiveTabShowButton;
}

- (void)defaultsDidChange:(NSNotification *)n {
    // Any thread may write a default; everything below this line is AppKit.
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self defaultsDidChange:nil]; }); return; }
    BOOL wasVertical = _vertical, wasMulti = _multiLine, wasPeek = _peekOn, wasReduce = _reduce;
    NSUInteger wasLook = [self lookBits];
    [self readDefaults];
    if (_peekOn != wasPeek) {
        if (!_peekOn) [self hidePeek];
        else if (_hoverIndex >= 0) [self schedulePeekForTab:_hoverIndex];
    }
    // Reduce joins the two orientation switches: all three change the size the host has to grant us.
    if (_vertical != wasVertical || _multiLine != wasMulti || _reduce != wasReduce) {
        _scrollOffset = 0;
        _notifiedRows = -1;            // orientation changed: the host has to be told even if the row count did not
        [self layoutTabs];
    } else if (wasLook != [self lookBits]) {
        // The other five leave every rectangle where it was. Two of them also decide which trailing buttons are
        // clickable, but hit-testing reads the flag at the moment of the click, so a repaint is the whole debt.
        [self setNeedsDisplay:YES];
    }
}

// The five flags that cost nothing but a repaint, packed so one comparison covers all of them.
- (NSUInteger)lookBits {
    return (_altIcons ? 1u : 0) | (_drawInactiveTab ? 2u : 0) | (_drawTopBar ? 4u : 0) |
           (_onlyPinnedButton ? 8u : 0) | (_inactiveTabButtons ? 16u : 0);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self layoutTabs]; }
- (void)viewDidChangeEffectiveAppearance { [self setNeedsDisplay:YES]; }

#pragma mark - Colours (the Dark Mode tone, else explicit, else system default)

// N++ paints its whole chrome from the Dark Mode tone and ignores the styler colours while it does
// (TabBar.cpp: `if (!NppDarkMode::useTabTheme() && isDarkMode)` replaces inactive background, active text and
// inactive text outright; the strip itself is filled with getBackgroundColor() and the active tab with
// getCtrlBackgroundColor()). So the tone wins over what the host pushed in — same colours as before with the
// default Black tone, re-tinted the moment the tone changes — and a light theme takes nothing from it at all.
// ponytail: the active tab keeps the host's colour (this port merges it with the editor background, which the
// tone already tints); the tone's softer background is only its fallback. Drop the `_activeBg ?:` to follow
// upstream exactly if the merged look ever has to go.
- (NSColor *)activeTabBackgroundColor   { return _activeBg ?: _dmSofter ?: NSColor.textBackgroundColor; }
- (NSColor *)activeTabTextColor         { return _dmText ?: _activeFg ?: NSColor.labelColor; }
- (NSColor *)activeIndicatorColor       { return _indicator  ?: [NSColor colorWithSRGBRed:0xFA/255.0 green:0xAA/255.0 blue:0x3C/255.0 alpha:1]; }
- (NSColor *)inactiveTabBackgroundColor { return _dmBg ?: _inactiveBg ?: NSColor.windowBackgroundColor; }
- (NSColor *)inactiveTabTextColor       { return _dmDarkerText ?: _inactiveFg ?: NSColor.secondaryLabelColor; }
- (NSColor *)barBackgroundColor         { return _dmBg ?: _barBg ?: NSColor.windowBackgroundColor; }
// Hairlines and tab dividers: NppDarkMode's edge colour, which takes the tone plus its own offset.
- (NSColor *)edgeColor                  { return _dmEdge ?: NSColor.separatorColor; }
// Hover tint: the tone's hot background, or a nudge toward the label colour when there is no tone.
- (NSColor *)hoverColorOver:(NSColor *)base fraction:(CGFloat)f {
    return _dmHot ?: [base blendedColorWithFraction:f ofColor:NSColor.labelColor] ?: base;
}

- (void)applyDarkPalette:(NSDictionary<NSString *, NSColor *> *)p {
    _dmBg         = p[kDMBarBg];
    _dmSofter     = p[kDMBarSofter];
    _dmHot        = p[kDMBarHot];
    _dmText       = p[kDMBarText];
    _dmDarkerText = p[kDMBarDarker];
    _dmEdge       = p[kDMBarEdge];
    [self setNeedsDisplay:YES];
}

- (void)readDarkPalette {
    NPPLanguageManager *m = NPPLanguageManager.shared;
    if (!m.currentThemeIsDark) { [self applyDarkPalette:nil]; return; }
    NSMutableDictionary<NSString *, NSColor *> *p = [NSMutableDictionary dictionary];
    for (NSString *name in @[kDMBarBg, kDMBarSofter, kDMBarHot, kDMBarText, kDMBarDarker, kDMBarEdge]) {
        NSColor *c = [m globalBackgroundColorNamed:name];   // each dark-mode style carries its one colour in fg and bg alike
        if (c) p[name] = c;
    }
    [self applyDarkPalette:p];
}

- (void)themeDidChange:(NSNotification *)n { [self readDarkPalette]; }

- (void)setActiveTabBackgroundColor:(NSColor *)c   { _activeBg = c;   [self setNeedsDisplay:YES]; }
- (void)setActiveTabTextColor:(NSColor *)c         { _activeFg = c;   [self setNeedsDisplay:YES]; }
- (void)setActiveIndicatorColor:(NSColor *)c       { _indicator = c;  [self setNeedsDisplay:YES]; }
- (void)setInactiveTabBackgroundColor:(NSColor *)c { _inactiveBg = c; [self setNeedsDisplay:YES]; }
- (void)setInactiveTabTextColor:(NSColor *)c       { _inactiveFg = c; [self setNeedsDisplay:YES]; }
- (void)setBarBackgroundColor:(NSColor *)c         { _barBg = c;      [self setNeedsDisplay:YES]; }
- (void)setShowCloseButtons:(BOOL)v { _showCloseButtons = v; [self layoutTabs]; }

#pragma mark - Model

- (NSArray<NPPTabItem *> *)items { return _items; }
- (void)setItems:(NSArray<NPPTabItem *> *)items {
    _items = [items copy] ?: @[];
    if (_selectedIndex >= (NSInteger)_items.count) _selectedIndex = (NSInteger)_items.count - 1;
    if (_items.count == 0) _selectedIndex = -1;
    _hoverIndex = _hoverClose = _hoverPin = -1;
    [self hidePeek];
    [self layoutTabs];
}
- (void)setSelectedIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_items.count) i = _items.count ? 0 : -1;
    if (i != _selectedIndex) [self hidePeek];    // N++ never peeks the document you just switched to
    _selectedIndex = i;
    [self scrollTabToVisible:i];
    [self setNeedsDisplay:YES];
}
- (void)reloadData { [self layoutTabs]; }

#pragma mark - Layout

- (NSDictionary *)textAttrsActive:(BOOL)active {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return @{ NSFontAttributeName: [self labelFont],
              NSForegroundColorAttributeName: active ? self.activeTabTextColor : self.inactiveTabTextColor,
              NSParagraphStyleAttributeName: ps };
}

// Where the tabs themselves may go. The drop-down is always outside it; the "+" is too, except in multi-line where
// it takes a slot after the last tab and wraps with them.
- (NSRect)tabAreaRect {
    NSRect b = self.bounds;
    if (self.vertical) return NSMakeRect(0, 0, NSWidth(b), std::max<CGFloat>(0, NSHeight(b) - kPlusWidth - kListWidth));
    if (self.isMultiLine) return NSMakeRect(0, 0, std::max<CGFloat>(0, NSWidth(b) - kListWidth), NSHeight(b));
    return NSMakeRect(0, 0, std::max<CGFloat>(0, NSWidth(b) - kPlusWidth - kListWidth), NSHeight(b));
}
- (CGFloat)tabAreaWidth { return NSWidth([self tabAreaRect]); }
- (CGFloat)visibleExtent {
    NSRect area = [self tabAreaRect];
    return [self scrollsVertically] ? NSHeight(area) : NSWidth(area);
}
- (CGFloat)maxScroll { return std::max<CGFloat>(0, _contentExtent - [self visibleExtent]); }

// "+" sits right after the last tab. A single row and a column keep it inside the strip once the tabs fill the bar;
// in multi-line it belongs to a row and travels with it, off the strip included (⌘N is the way in from there).
- (NSRect)newTabButtonRect { return [self plusRect]; }
- (NSRect)plusRect {
    NSRect r = _plusContent;
    if (self.vertical)                      // a column: park it above the drop-down instead of letting it scroll off
        r.origin.y = std::clamp<CGFloat>(r.origin.y - _scrollOffset, 0, NSHeight([self tabAreaRect]));
    else if (self.isMultiLine)
        r.origin.y -= _scrollOffset;        // it took a slot after the last tab: it wraps and scrolls with that row
    else
        r.origin.x = std::clamp<CGFloat>(r.origin.x - _scrollOffset, 0, [self tabAreaWidth]);
    return r;
}
// The drop-down never moves: N++ keeps its tab list button at the end of the strip, past the tabs and the "+".
- (NSRect)tabListButtonRect {
    NSRect b = self.bounds;
    if (self.vertical) return NSMakeRect(0, std::max<CGFloat>(0, NSHeight(b) - kListWidth), NSWidth(b), kListWidth);
    CGFloat h = self.isMultiLine ? [self rowHeight] : NSHeight(b) - 1;   // multi-line: top-right, above the first row
    return NSMakeRect(std::max<CGFloat>(0, NSWidth(b) - kListWidth), 0, kListWidth, h);
}

// Trailing button zone of every tab: the pin box plus the close box. Reserved on pinned and unpinned tabs
// alike so toggling the pin (which swaps one for the other) never re-flows the strip.
- (CGFloat)buttonZoneWidth { return kPinSize + 4 + (_showCloseButtons ? kCloseSize + 6 : 0); }

// One pass over the items per mode: a single sliding row, wrapped rows, or a column of full-width tabs.
- (void)layoutTabs {
    _frames.clear();
    NSDictionary *attrs = [self textAttrsActive:YES];
    CGFloat fixed = kPadX + kDotSize + 6 + [self buttonZoneWidth] + kPadX;
    BOOL vert = self.vertical, multi = self.isMultiLine;
    NSRect area = [self tabAreaRect];
    CGFloat rowW = std::max<CGFloat>(kTabMinWidth, NSWidth(area));   // multi-line wraps inside the tab area
    CGFloat rowH = [self rowHeight];
    CGFloat x = 0, y = 0;
    for (NPPTabItem *it in _items) {
        CGFloat w = vert ? NSWidth(self.bounds)
                         : std::clamp<CGFloat>(ceil([(it.title ?: @"") sizeWithAttributes:attrs].width) + fixed, kTabMinWidth, kTabMaxWidth);
        if (vert) {
            _frames.push_back(NSMakeRect(0, y, w, rowH));
            y += rowH;
        } else if (multi) {
            if (x > 0 && x + w > rowW) { x = 0; y += rowH; }
            _frames.push_back(NSMakeRect(x, y, w, rowH));
            x += w;
        } else {
            _frames.push_back(NSMakeRect(x, 0, w, NSHeight(self.bounds)));
            x += w;
        }
    }
    if (vert) {
        _plusContent = NSMakeRect(0, y, NSWidth(self.bounds), kPlusWidth);
        _contentExtent = y;
    } else if (multi) {
        if (x + kPlusWidth > rowW && x > 0) { x = 0; y += rowH; }   // the "+" wraps like any other tab
        _plusContent = NSMakeRect(x, y, kPlusWidth, rowH);
        _contentExtent = y + rowH;
    } else {
        _plusContent = NSMakeRect(x, 0, kPlusWidth, NSHeight(self.bounds) - 1);
        _contentExtent = x;
    }
    _rows = multi ? (NSInteger)lround(_contentExtent / rowH) : 1;
    _scrollOffset = std::clamp<CGFloat>(_scrollOffset, 0, [self maxScroll]);
    [self rebuildToolTips];
    [self setNeedsDisplay:YES];
    // The host owns the frame: it has to be told when the strip needs more (or fewer) rows than it granted. Its
    // answer is a new frame, which lands back here — hence the guard, and hence not recording a row count reached
    // from inside one (the next layout notices it and asks again).
    if (_rows != _notifiedRows && !_notifyingSize) {
        _notifiedRows = _rows;
        if ([_delegate respondsToSelector:@selector(tabBarDidChangePreferredSize:)]) {
            _notifyingSize = YES;
            [_delegate tabBarDidChangePreferredSize:self];
            _notifyingSize = NO;
        }
    }
}

// Frame in view coords (scroll applied; drag offset NOT applied).
- (NSRect)frameForTab:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_frames.size()) return NSZeroRect;
    NSRect f = _frames[(size_t)i];
    if ([self scrollsVertically]) f.origin.y -= _scrollOffset; else f.origin.x -= _scrollOffset;
    return f;
}
- (NSRect)closeRectForTab:(NSInteger)i {
    NSRect f = [self frameForTab:i];
    return NSMakeRect(NSMaxX(f) - kPadX - kCloseSize, floor(NSMidY(f) - kCloseSize / 2), kCloseSize, kCloseSize);
}
// A pinned tab shows the pin where the close box would be (N++ hides the X on pinned tabs); an unpinned one
// shows it just left of the close box, and only while the tab is hovered.
- (NSRect)pinRectInTabFrame:(NSRect)f pinned:(BOOL)pinned {
    CGFloat x = NSMaxX(f) - kPadX - kPinSize;
    if (!pinned && _showCloseButtons) x -= kCloseSize + 4;
    return NSMakeRect(x, floor(NSMidY(f) - kPinSize / 2), kPinSize, kPinSize);
}
- (NSRect)pinRectForTab:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_items.count) return NSZeroRect;
    return [self pinRectInTabFrame:[self frameForTab:i] pinned:_items[i].pinned];
}
- (BOOL)closeBoxVisibleForTab:(NSInteger)i {
    return _showCloseButtons && i >= 0 && i < (NSInteger)_items.count && !_items[i].pinned;
}

// Which trailing buttons are on screen — and therefore clickable. Upstream draws an *empty* button image where a
// button is suppressed (TabBarPlus::setCloseBtnImageList / setPinBtnImageList pick IDR_..._INACT_EMPTY) and refuses
// the matching hit (the `(isPinSimplest && buf->isPinned()) || !isPinSimplest` guard in WM_LBUTTONDOWN/UP), so
// drawing and hit-testing have to read the same predicate or a button becomes invisible but live, or the reverse.
//   * TAB_INACTIVETABSHOWBUTTON — buttons on inactive tabs, not just the active or hovered one.
//   * TAB_SHOWONLYPINNEDBUTTON  — the pin shows only on tabs that are already pinned (View ▸ Pin Tab still works).
- (BOOL)buttonsShownForTab:(NSInteger)i {
    return i == _selectedIndex || (i == _hoverIndex && !_dragging) || _inactiveTabButtons;
}
- (BOOL)closeBoxShownForTab:(NSInteger)i {
    return [self closeBoxVisibleForTab:i] && [self buttonsShownForTab:i];
}
- (BOOL)pinBoxShownForTab:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_items.count) return NO;
    if (_items[i].pinned) return YES;              // a pinned tab always shows its pin: it is the unpin affordance
    return !_onlyPinnedButton && [self buttonsShownForTab:i];
}
- (NSInteger)tabAtPoint:(NSPoint)p {
    if (!NSPointInRect(p, [self tabAreaRect]) || NSPointInRect(p, [self plusRect])) return -1;
    for (NSInteger i = 0; i < (NSInteger)_frames.size(); i++)
        if (NSPointInRect(p, [self frameForTab:i])) return i;
    return -1;
}

- (void)rebuildToolTips {
    [self removeAllToolTips];
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        NSRect f = [self frameForTab:i];
        if (!NSIntersectsRect(f, self.bounds)) continue;
        [self addToolTipRect:f owner:self userData:(void *)(intptr_t)i];
    }
    [self addToolTipRect:[self plusRect] owner:self userData:(void *)(intptr_t)-1];
    [self addToolTipRect:[self tabListButtonRect] owner:self userData:(void *)(intptr_t)-2];
}
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    NSInteger i = (NSInteger)(intptr_t)data;
    if (i == -2) return NSLocalizedString(@"Document list", nil);
    if (i == -1) return NSLocalizedString(@"New file", nil);   // the "+" button; File ▸ New (⌘N) does the same
    if (i < 0 || i >= (NSInteger)_items.count) return @"";
    if ([_delegate respondsToSelector:@selector(tabBar:toolTipForTabAtIndex:)]) {
        NSString *tip = [_delegate tabBar:self toolTipForTabAtIndex:i];
        if (tip.length) return tip;
    }
    return _items[i].toolTip ?: _items[i].title ?: @"";
}

- (void)scrollTabToVisible:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_frames.size()) return;
    NSRect f = [self frameForTab:i];
    BOOL vert = [self scrollsVertically];
    CGFloat lo = vert ? NSMinY(f) : NSMinX(f), hi = vert ? NSMaxY(f) : NSMaxX(f), limit = [self visibleExtent];
    if (lo < 0) _scrollOffset += lo;
    else if (hi > limit) _scrollOffset += hi - limit;
    _scrollOffset = std::clamp<CGFloat>(_scrollOffset, 0, [self maxScroll]);
    [self rebuildToolTips];
    [self setNeedsDisplay:YES];
}

#pragma mark - Pinning

// N++ refuses a drag swap whose two tabs differ in pinned state (TabBarPlus::exchangeTabItemData returns
// false). That single rule is what keeps the pinned block on the left: drags stop at the boundary.
- (BOOL)canSwapTabAtIndex:(NSInteger)a withIndex:(NSInteger)b {
    if (a < 0 || b < 0 || a >= (NSInteger)_items.count || b >= (NSInteger)_items.count) return NO;
    return _items[a].pinned == _items[b].pinned;
}

// Reorder one tab in the view's own model and tell the delegate (which reorders the documents to match).
- (void)moveTabFrom:(NSInteger)from to:(NSInteger)to {
    if (from == to || from < 0 || to < 0 || from >= (NSInteger)_items.count || to >= (NSInteger)_items.count) return;
    NSMutableArray *m = [_items mutableCopy];
    NPPTabItem *it = m[from];
    [m removeObjectAtIndex:from];
    [m insertObject:it atIndex:to];
    _items = [m copy];
    [self layoutTabs];                 // wrapped rows and a column both re-flow, so recompute rather than shuffle
    if (_selectedIndex == from) _selectedIndex = to;
    else if (from < _selectedIndex && _selectedIndex <= to) _selectedIndex--;
    else if (to <= _selectedIndex && _selectedIndex < from) _selectedIndex++;
    [_delegate tabBar:self didMoveTabFromIndex:from toIndex:to];
}

// N++ slides the tab through its like-pinned neighbours and stops at the pin boundary (tabToStart when
// pinning, tabToEnd when unpinning), then flips the flag. So a newly pinned tab lands at the end of the
// pinned block, an unpinned one at the head of the rest, and neither disturbs the order of the others.
- (void)togglePinnedAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    BOOL pin = !_items[index].pinned;
    NSInteger dest = index;
    if (pin) { while (dest > 0 && !_items[dest - 1].pinned) dest--; }
    else     { while (dest + 1 < (NSInteger)_items.count && _items[dest + 1].pinned) dest++; }

    [self hidePeek];
    [self moveTabFrom:index to:dest];
    // The delegate may have rebuilt `items` from its own model during the move; `dest` still names the tab.
    if (dest < (NSInteger)_items.count) _items[dest].pinned = pin;
    if ([_delegate respondsToSelector:@selector(tabBar:didSetPinned:forTabAtIndex:)])
        [_delegate tabBar:self didSetPinned:pin forTabAtIndex:dest];
    [self layoutTabs];
}

#pragma mark - Document drop-down

- (NSMenu *)tabListMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Documents", nil)];
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        NPPTabItem *it = _items[i];
        // "*name" is how the port marks a dirty document in a list (see the Document List panel).
        NSMenuItem *mi = [menu addItemWithTitle:[NSString stringWithFormat:@"%@%@", it.dirty ? @"*" : @"", it.title ?: @""]
                                         action:@selector(pickTabFromList:) keyEquivalent:@""];
        mi.target = self;
        mi.tag = i;
        mi.state = (i == _selectedIndex) ? NSControlStateValueOn : NSControlStateValueOff;
        if (it.pinned) mi.image = [self symbol:@"pin.fill" size:9 color:NSColor.secondaryLabelColor];
    }
    if (!_items.count) [menu addItemWithTitle:NSLocalizedString(@"No documents", nil) action:NULL keyEquivalent:@""];
    return menu;
}

- (void)pickTabFromList:(NSMenuItem *)sender {
    NSInteger i = sender.tag;
    if (i < 0 || i >= (NSInteger)_items.count) return;
    self.selectedIndex = i;
    [_delegate tabBar:self didSelectTabAtIndex:i];
}

- (void)showTabListMenu {
    NSRect r = [self tabListButtonRect];
    [self hidePeek];
    [[self tabListMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(r), NSMaxY(r)) inView:self];
}

#pragma mark - Document Peeker

// N++ shows a shrunken Scintilla snapshot next to the hovered tab (documentSnapshot.cpp / NppGUI::_isDocPeekOnTab).
// ponytail: the port pops the head of the document as plain text instead — no second editor, no styling.
// Upgrade path: swap the label for a read-only ScintillaView if the syntax colours turn out to matter.
- (BOOL)peekEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:kPeekDefaultsKey]; }

// Every reason to refuse a peek except "the view is not in a window", which only the live path can have an
// opinion about. Kept as its own predicate so the gate is testable headless — and so -showPeekForTab: re-checks
// it before calling the @optional delegate method, which is not safe to send blind if the delegate changed
// between the hover and the timer firing.
- (BOOL)peekAllowedForTab:(NSInteger)i {
    // N++ never peeks the active tab: you are already looking at that document.
    return i >= 0 && i < (NSInteger)_items.count && i != _selectedIndex && self.peekEnabled &&
           [_delegate respondsToSelector:@selector(tabBar:previewTextForTabAtIndex:)];
}

- (void)hidePeek {
    [_peekTimer invalidate];
    _peekTimer = nil;
    if (!_peekWindow) return;
    [_peekWindow.parentWindow removeChildWindow:_peekWindow];
    [_peekWindow orderOut:nil];
}

- (void)schedulePeekForTab:(NSInteger)i {
    [_peekTimer invalidate];
    _peekTimer = nil;
    if (!self.window || ![self peekAllowedForTab:i]) { [self hidePeek]; return; }
    __weak NPPTabBarView *weak = self;
    _peekTimer = [NSTimer scheduledTimerWithTimeInterval:kPeekDelay repeats:NO block:^(NSTimer *t) {
        [weak showPeekForTab:i];
    }];
}

- (void)showPeekForTab:(NSInteger)i {
    _peekTimer = nil;
    if (i != _hoverIndex || !self.window || ![self peekAllowedForTab:i]) return;
    NSString *text = [_delegate tabBar:self previewTextForTabAtIndex:i];
    if (!text.length) { [self hidePeek]; return; }
    // The delegate is free to hand back the whole buffer; splitting a 100 MB document into lines on the main
    // thread for a 300x180 preview is not. Cut on a character boundary so a surrogate pair never splits.
    if (text.length > kPeekMaxChars)
        text = [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kPeekMaxChars)]];

    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if (lines.count > kPeekLines) lines = [lines subarrayWithRange:NSMakeRange(0, kPeekLines)];

    if (!_peekWindow) {
        _peekWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kPeekWidth, kPeekHeight)
                                                 styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                   backing:NSBackingStoreBuffered defer:YES];
        _peekWindow.opaque = NO;
        _peekWindow.backgroundColor = NSColor.clearColor;
        _peekWindow.hasShadow = YES;
        _peekWindow.level = NSPopUpMenuWindowLevel;
        _peekWindow.ignoresMouseEvents = YES;
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
    _peekLabel.stringValue = [lines componentsJoinedByString:@"\n"];
    _peekLabel.textColor = _dmDarkerText ?: NSColor.secondaryLabelColor;   // the peeker is chrome too

    // Anchored under the tab's left edge, like N++ (rect.left / rect.bottom of the tab item).
    NSRect f = [self frameForTab:i];
    NSPoint inWindow = [self convertPoint:NSMakePoint(NSMinX(f), NSMaxY(f)) toView:nil];
    NSRect onScreen = [self.window convertRectToScreen:NSMakeRect(inWindow.x, inWindow.y, 1, 1)];
    CGFloat x = NSMinX(onScreen), y = NSMinY(onScreen) - kPeekHeight - 2;
    NSRect visible = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    x = std::clamp<CGFloat>(x, NSMinX(visible), std::max<CGFloat>(NSMinX(visible), NSMaxX(visible) - kPeekWidth));
    if (y < NSMinY(visible)) y = NSMinY(onScreen) + 2;   // no room below the tab (window at the screen edge): flip above it
    [_peekWindow setFrame:NSMakeRect(x, y, kPeekWidth, kPeekHeight) display:YES];
    if (_peekWindow.parentWindow != self.window) {
        [_peekWindow.parentWindow removeChildWindow:_peekWindow];
        [self.window addChildWindow:_peekWindow ordered:NSWindowAbove];
    }
    [_peekWindow orderFront:nil];
}

// The peek panel is a child of whatever window we were in, and a parent window retains its children: leaving it
// attached when the bar goes away (or moves windows) would strand a floating panel on screen forever.
- (void)viewDidMoveToWindow { [self hidePeek]; }
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];   // defaults + theme
    [self hidePeek];
}

#pragma mark - Drawing

- (NSImage *)symbol:(NSString *)name size:(CGFloat)pt color:(NSColor *)color {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightMedium]];
    if (@available(macOS 12.0, *)) {
        img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    }
    return img;
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [self.barBackgroundColor setFill];
    NSRectFill(b);

    // hairline along the editor-facing edge (skipped under the active tab so it merges with the editor)
    [self.edgeColor setFill];
    NSRectFill(self.vertical ? NSMakeRect(NSWidth(b) - 1, 0, 1, NSHeight(b)) : NSMakeRect(0, NSHeight(b) - 1, NSWidth(b), 1));

    NSInteger n = (NSInteger)_items.count;
    // Clip to the tab area so a scrolled strip never draws under the "+" or the drop-down.
    [NSGraphicsContext saveGraphicsState];
    NSRectClip([self tabAreaRect]);
    // draw inactive first, dragged/active last so it sits on top
    for (NSInteger pass = 0; pass < 2; pass++) {
        for (NSInteger i = 0; i < n; i++) {
            BOOL top = (i == _selectedIndex) || (_dragging && i == _pressIndex);
            if ((pass == 1) != top) continue;
            NSRect f = [self frameForTab:i];
            if (_dragging && i == _pressIndex) { f.origin.x += _dragDX; f.origin.y += _dragDY; }
            if (!NSIntersectsRect(f, dirty)) continue;
            [self drawTab:i inRect:f];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    [self drawStripButton:[self plusRect] symbol:@"plus" size:11 hovered:_hoverPlus];
    [self drawStripButton:[self tabListButtonRect] symbol:@"chevron.down" size:10 hovered:_hoverList];
}

// The two buttons at the end of the strip: "+" (new file) and the document drop-down.
- (void)drawStripButton:(NSRect)r symbol:(NSString *)name size:(CGFloat)pt hovered:(BOOL)hovered {
    if (hovered) {
        [[self hoverColorOver:self.inactiveTabBackgroundColor fraction:0.18] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 4, 4) xRadius:4 yRadius:4] fill];
    }
    NSImage *img = [self symbol:name size:pt color:self.inactiveTabTextColor];
    NSSize sz = img.size;
    [img drawInRect:NSMakeRect(floor(NSMidX(r) - sz.width / 2), floor(NSMidY(r) - sz.height / 2), sz.width, sz.height)
           fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
     respectFlipped:YES hints:nil];   // the bar is flipped; a chevron must not point the wrong way
}

- (void)drawTab:(NSInteger)i inRect:(NSRect)f {
    NPPTabItem *it = _items[i];
    BOOL active = (i == _selectedIndex);
    BOOL hover  = (i == _hoverIndex) && !_dragging;

    // N++ TAB_DRAWINACTIVETAB ("Change inactive tab color"): with it off, an inactive tab is painted in the *active*
    // background, so the strip reads as one surface (TabBarPlus::drawItem falls back to colorActiveBg). An individual
    // tab colour still wins over both, exactly as upstream's individualColourId does.
    NSColor *bg = (active || !_drawInactiveTab) ? self.activeTabBackgroundColor : self.inactiveTabBackgroundColor;
    if (it.color) bg = active ? it.color : [self.inactiveTabBackgroundColor blendedColorWithFraction:0.35 ofColor:it.color] ?: it.color;
    // Upstream only lightens a tab on hover when it is drawn "darker" than the active one; with the setting off an
    // inactive tab is already the active colour, so there is nothing to lighten.
    else if (hover && !active && _drawInactiveTab) bg = [self hoverColorOver:bg fraction:0.08];
    // An inactive tab stops one point short of the strip's edge so the hairline shows through; which edge that is
    // depends on the orientation, and in a column the active indicator runs down the leading side instead.
    BOOL vert = self.vertical;
    [bg setFill];
    NSRectFill(active ? f : (vert ? NSMakeRect(NSMinX(f), NSMinY(f), NSWidth(f) - 1, NSHeight(f))
                                  : NSMakeRect(NSMinX(f), NSMinY(f), NSWidth(f), NSHeight(f) - 1)));

    if (active) {
        // N++ TAB_DRAWTOPBAR ("Draw a coloured bar on active tab"): off means no bar at all, and the tab is told
        // apart by its background alone.
        if (_drawTopBar) {
            [self.activeIndicatorColor setFill];
            NSRectFill(vert ? NSMakeRect(NSMinX(f), NSMinY(f), kIndicatorH, NSHeight(f))
                            : NSMakeRect(NSMinX(f), NSMinY(f), NSWidth(f), kIndicatorH));
        }
    } else {
        [self.edgeColor setFill];
        NSRectFill(vert ? NSMakeRect(NSMinX(f) + 4, NSMaxY(f) - 1, NSWidth(f) - 9, 1)
                        : NSMakeRect(NSMaxX(f) - 1, NSMinY(f) + 4, 1, NSHeight(f) - 9));
    }

    // state indicator
    CGFloat midY = NSMidY(f);
    NSRect dot = NSMakeRect(f.origin.x + kPadX, floor(midY - kDotSize / 2), kDotSize, kDotSize);
    NSColor *fg = active ? self.activeTabTextColor : self.inactiveTabTextColor;
    // N++ TAB_ALTICONS picks docTabIconIDs_alt over docTabIconIDs (ScintillaComponent/DocTabView.cpp): the standard
    // set marks saved/unsaved with a blue/red floppy, the alternate one with a green tick and a pencil. The
    // monitoring eye is literally the same resource in both.
    // ponytail: upstream's alternate set also redraws the two read-only padlocks (IDI_READONLY_ALT_ICON); here the
    // padlock is shared, so the setting changes the saved/unsaved marker only. Give it its own glyph if the
    // read-only tabs ever need to look different between the sets.
    if (it.readOnly) {
        [[self symbol:@"lock.fill" size:9 color:NSColor.systemGrayColor] drawInRect:NSInsetRect(dot, -2, -2) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    } else if (it.monitoring) {
        [[self symbol:@"eye" size:9 color:fg] drawInRect:NSInsetRect(dot, -3, -3) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    } else if (_altIcons) {
        NSImage *glyph = [self symbol:(it.dirty ? @"pencil" : @"checkmark") size:10
                                color:(it.dirty ? NSColor.systemOrangeColor : NSColor.systemGreenColor)];
        [glyph drawInRect:NSInsetRect(dot, -2, -2) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                 fraction:1 respectFlipped:YES hints:nil];
    } else {
        [(it.dirty ? [NSColor colorWithSRGBRed:0xE5/255.0 green:0x39/255.0 blue:0x35/255.0 alpha:1]
                   : [NSColor colorWithSRGBRed:0x2F/255.0 green:0x80/255.0 blue:0xED/255.0 alpha:1]) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }

    // pin box: always on a pinned tab (it replaces the close box, as in N++), a faint hint on the others while
    // hovered — or on every tab with "Show buttons on inactive tabs", none with "Show only pinned button".
    if ([self pinBoxShownForTab:i]) {
        NSRect pr = [self pinRectInTabFrame:f pinned:it.pinned];
        if (i == _hoverPin) {
            [[fg colorWithAlphaComponent:0.18] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pr xRadius:3 yRadius:3] fill];
        }
        NSImage *pin = [self symbol:(it.pinned ? @"pin.fill" : @"pin") size:10 color:fg];
        [pin drawInRect:NSMakeRect(NSMidX(pr) - 5, NSMidY(pr) - 5, 10, 10) fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver fraction:(it.pinned || i == _hoverPin) ? 1 : 0.5 respectFlipped:YES hints:nil];
    }

    // close button (a pinned tab shows its pin there instead)
    if ([self closeBoxShownForTab:i]) {
        // From `f`, not -closeRectForTab:, so a dragged tab carries its close box along.
        NSRect cr = NSMakeRect(NSMaxX(f) - kPadX - kCloseSize, floor(NSMidY(f) - kCloseSize / 2), kCloseSize, kCloseSize);
        if (i == _hoverClose) {
            [[fg colorWithAlphaComponent:0.18] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:cr xRadius:3 yRadius:3] fill];
        }
        NSImage *x = [self symbol:@"xmark" size:10 color:fg];
        NSRect xr = NSMakeRect(NSMidX(cr) - 5, NSMidY(cr) - 5, 10, 10);
        [x drawInRect:xr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }

    // title
    CGFloat tx = NSMaxX(dot) + 6;
    CGFloat tr = NSMaxX(f) - kPadX - [self buttonZoneWidth];
    NSDictionary *attrs = [self textAttrsActive:active];
    NSString *title = it.title ?: @"";
    CGFloat h = ceil([title sizeWithAttributes:attrs].height);
    NSRect tRect = NSMakeRect(tx, floor(midY - h / 2), std::max<CGFloat>(0, tr - tx), h);
    [title drawWithRect:tRect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:attrs];
}

#pragma mark - Mouse

- (void)mouseEntered:(NSEvent *)e { [self mouseMoved:e]; }
- (void)mouseExited:(NSEvent *)e {
    _hoverIndex = _hoverClose = _hoverPin = -1; _hoverPlus = _hoverList = NO;
    [self hidePeek];
    [self setNeedsDisplay:YES];
}
- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = [self tabAtPoint:p], wasHover = _hoverIndex;
    // The button predicates ask whether *this* tab is the hovered one, and it is about to be: move the hover first,
    // or a tab whose buttons only appear on hover could never report a hit on them.
    _hoverIndex = i;
    NSInteger pin = (i >= 0 && [self pinBoxShownForTab:i] && NSPointInRect(p, [self pinRectForTab:i])) ? i : -1;
    NSInteger c = (i >= 0 && pin != i && [self closeBoxShownForTab:i] && NSPointInRect(p, [self closeRectForTab:i])) ? i : -1;
    BOOL plus = NSPointInRect(p, [self plusRect]);
    BOOL list = NSPointInRect(p, [self tabListButtonRect]);
    if (i != wasHover || c != _hoverClose || pin != _hoverPin || plus != _hoverPlus || list != _hoverList) {
        _hoverClose = c; _hoverPin = pin; _hoverPlus = plus; _hoverList = list;
        if (i != wasHover) [self schedulePeekForTab:i];
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _pressPoint = p;
    _pressIndex = [self tabAtPoint:p];
    _dragging = NO; _dragDX = _dragDY = 0;
    [self hidePeek];
    if (NSPointInRect(p, [self tabListButtonRect])) {
        _pressIndex = -1;
        [self showTabListMenu];
        return;
    }
    if (NSPointInRect(p, [self plusRect])) {
        if ([_delegate respondsToSelector:@selector(tabBarDidClickNewTab:)]) [_delegate tabBarDidClickNewTab:self];
        _pressIndex = -1;
        return;
    }
    if (_pressIndex < 0) {
        if (e.clickCount == 2 && [_delegate respondsToSelector:@selector(tabBar:didDoubleClickEmptyArea:)])
            [_delegate tabBar:self didDoubleClickEmptyArea:p];
        return;
    }
    if (e.modifierFlags & NSEventModifierFlagCommand) {          // Cmd-click closes (header contract)
        [_delegate tabBar:self didRequestCloseTabAtIndex:_pressIndex];
        _pressIndex = -1;
        return;
    }
    if (e.clickCount == 2 && NPPPreferences.shared.tabBarDoubleClickToClose) {
        NSInteger idx = _pressIndex;
        _pressIndex = -1;
        [_delegate tabBar:self didRequestCloseTabAtIndex:idx];
        return;
    }
    // Only a button that is actually on screen can be pressed — the same predicate -drawTab: paints from.
    _pressOnPin = [self pinBoxShownForTab:_pressIndex] && NSPointInRect(p, [self pinRectForTab:_pressIndex]);
    _pressOnClose = !_pressOnPin && [self closeBoxShownForTab:_pressIndex] &&
                    NSPointInRect(p, [self closeRectForTab:_pressIndex]);
    if (_pressOnClose || _pressOnPin) return;                      // decide on mouseUp, as N++ does
    if (_pressIndex != _selectedIndex) {
        _selectedIndex = _pressIndex;
        [self scrollTabToVisible:_pressIndex];
        [_delegate tabBar:self didSelectTabAtIndex:_pressIndex];
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)e {
    if (_pressIndex < 0 || _pressOnClose || _pressOnPin) return;
    if (_locked) return;               // N++ TAB_DRAGNDROP off: the order is frozen (dropping files still works)
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (!_dragging) {
        if (hypot(p.x - _pressPoint.x, p.y - _pressPoint.y) < kDragThreshold) return;
        _dragging = YES;
    }
    BOOL vert = [self scrollsVertically];
    _dragDX = self.vertical ? 0 : p.x - _pressPoint.x;   // a column only slides up and down
    _dragDY = vert ? p.y - _pressPoint.y : 0;
    // N++ (TabBarPlus::exchangeTabItemData) swaps with whatever tab the cursor is over. One step at a time, so the
    // pin boundary stops the slide exactly where a neighbour-by-neighbour drag would.
    NSRect f = [self frameForTab:_pressIndex];
    CGFloat left = NSMinX(f) + _dragDX, top = NSMinY(f) + _dragDY;
    NSInteger over = [self tabAtPoint:p];
    while (over >= 0 && over != _pressIndex) {
        NSInteger step = _pressIndex + (over > _pressIndex ? 1 : -1);
        if (![self canSwapTabAtIndex:_pressIndex withIndex:step]) break;   // never across the pin boundary
        [self moveTabFrom:_pressIndex to:step];
        _pressIndex = step;
    }
    // keep the tab visually under the cursor: re-anchor so the offset is relative to the new slot
    NSRect nf = [self frameForTab:_pressIndex];
    if (!NSEqualRects(nf, f)) {
        _pressPoint.x = p.x - (left - NSMinX(nf));
        _pressPoint.y = p.y - (top - NSMinY(nf));
        _dragDX = self.vertical ? 0 : p.x - _pressPoint.x;
        _dragDY = vert ? p.y - _pressPoint.y : 0;
    }
    // autoscroll when dragging past the edges
    CGFloat pos = vert ? p.y : p.x, limit = vert ? NSHeight(self.bounds) : NSWidth(self.bounds);
    if (pos < 0 || pos > limit)
        _scrollOffset = std::clamp<CGFloat>(_scrollOffset + (pos < 0 ? -8 : 8), 0, [self maxScroll]);
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (_pressOnPin && _pressIndex >= 0 && NSPointInRect(p, [self pinRectForTab:_pressIndex])) {
        NSInteger idx = _pressIndex;
        _pressIndex = -1; _pressOnPin = NO;
        [self togglePinnedAtIndex:idx];
        [self rebuildToolTips];
        [self setNeedsDisplay:YES];
        return;
    }
    if (_pressOnClose && _pressIndex >= 0 && NSPointInRect(p, [self closeRectForTab:_pressIndex])) {
        NSInteger idx = _pressIndex;
        _pressIndex = -1; _pressOnClose = NO;
        [_delegate tabBar:self didRequestCloseTabAtIndex:idx];
        return;
    }
    // N++ TCN_TABDROPPEDOUTSIDE: the drag let go away from the strip. Say where in screen coordinates and let the
    // host decide — this view has no idea what a tab holds. Read before the state is cleared, sent after, so the
    // delegate is free to rebuild -items from under us.
    NSInteger droppedOut = (_dragging && _pressIndex >= 0 && !NSPointInRect(p, self.bounds)) ? _pressIndex : -1;
    _pressOnClose = _pressOnPin = NO;
    _dragging = NO; _dragDX = _dragDY = 0; _pressIndex = -1;
    [self rebuildToolTips];
    [self mouseMoved:e];
    [self setNeedsDisplay:YES];
    if (droppedOut >= 0 && [_delegate respondsToSelector:@selector(tabBar:didDropTabAtIndex:outsideAtScreenPoint:)])
        [_delegate tabBar:self didDropTabAtIndex:droppedOut
     outsideAtScreenPoint:self.window ? [self.window convertPointToScreen:e.locationInWindow]
                                      : e.locationInWindow];   // headless (self-check): no window to convert through
}

- (void)otherMouseDown:(NSEvent *)e {
    if (e.buttonNumber != 2) { [super otherMouseDown:e]; return; }
    NSInteger i = [self tabAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0) [_delegate tabBar:self didRequestCloseTabAtIndex:i];
}

- (NSMenu *)menuForEvent:(NSEvent *)e {
    NSInteger i = [self tabAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i < 0 || ![_delegate respondsToSelector:@selector(tabBar:contextMenuForTabAtIndex:)]) return nil;
    if (i != _selectedIndex) {                                     // N++ activates the tab under the right-click
        _selectedIndex = i;
        [_delegate tabBar:self didSelectTabAtIndex:i];
        [self setNeedsDisplay:YES];
    }
    return [_delegate tabBar:self contextMenuForTabAtIndex:i];
}

- (void)scrollWheel:(NSEvent *)e {
    [self hidePeek];                                  // the tabs slide out from under the preview
    if ([self maxScroll] <= 0) return;
    CGFloat d = fabs(e.scrollingDeltaX) > fabs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY;
    if (!e.hasPreciseScrollingDeltas) d *= 10;
    _scrollOffset = std::clamp<CGFloat>(_scrollOffset - d, 0, [self maxScroll]);
    [self rebuildToolTips];
    [self setNeedsDisplay:YES];
}

#pragma mark - File drop

- (NSArray<NSURL *> *)fileURLsFromPasteboard:(NSPasteboard *)pb {
    NSArray *urls = [pb readObjectsForClasses:@[NSURL.class] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    return urls ?: @[];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (![_delegate respondsToSelector:@selector(tabBar:didDropFileURLs:)]) return NSDragOperationNone;
    return [self fileURLsFromPasteboard:sender.draggingPasteboard].count ? NSDragOperationCopy : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self draggingEntered:sender]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [self fileURLsFromPasteboard:sender.draggingPasteboard];
    if (!urls.count || ![_delegate respondsToSelector:@selector(tabBar:didDropFileURLs:)]) return NO;
    [_delegate tabBar:self didDropFileURLs:urls];
    return YES;
}

#pragma mark - Self checks

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) { if (!ok) [fails addObject:msg]; };

    // Every mode the strip has is a defaults key it watches for itself, so each is flipped the way the Preferences
    // window flips it: write the key, let the change notification arrive.
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    void (^setMode)(NSString *, BOOL) = ^(NSString *key, BOOL on) {
        [ud setBool:on forKey:key];
        [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:ud];
    };
    // The six "Look and feel" settings move row heights, fonts and button hit boxes, so everything below would
    // otherwise measure whatever the user happens to have set. Pin them to the upstream defaults first; the
    // originals go back at the end, together with the layout modes.
    NSDictionary<NSString *, NSNumber *> *lookDefaults = @{
        @"NPPTabBarReduce": @YES, @"NPPTabBarAlternateIcons": @NO, @"NPPTabBarDrawInactiveTab": @YES,
        @"NPPTabBarDrawTopBar": @YES, @"NPPTabBarShowOnlyPinnedButton": @NO, @"NPPTabBarInactiveTabShowButton": @NO,
    };
    NSMutableDictionary<NSString *, id> *savedLook = [NSMutableDictionary dictionary];
    for (NSString *key in lookDefaults) {
        id v = [ud objectForKey:key];
        if (v) savedLook[key] = v;
        [ud setBool:lookDefaults[key].boolValue forKey:key];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:ud];

    NPPTabBarView *bar = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
    NPPTabBarPinProbe *probe = [NPPTabBarPinProbe new];
    bar.delegate = probe;
    NSMutableArray<NPPTabItem *> *items = [NSMutableArray array];
    for (NSString *n in @[@"a", @"b", @"c", @"d"]) {
        NPPTabItem *it = [NPPTabItem new];
        it.title = n;
        [items addObject:it];
    }
    items[2].dirty = YES;
    bar.items = items;
    bar.selectedIndex = 0;
    NSString *(^order)(void) = ^{ return [[bar.items valueForKey:@"title"] componentsJoinedByString:@""]; };

    // Pinning slides the tab to the end of the pinned block and leaves the rest in order (N++ tabToStart).
    [bar togglePinnedAtIndex:1];
    expect([order() isEqualToString:@"bacd"], [@"pin b: " stringByAppendingString:order()]);
    expect(bar.items[0].pinned, @"pin b: flag not set");
    expect(probe.pinCalls == 1 && probe.pinned && probe.pinIndex == 0,
           [NSString stringWithFormat:@"pin b: delegate got %ld/%d/%ld", (long)probe.pinCalls, probe.pinned, (long)probe.pinIndex]);
    // The selection follows the tab it was on ("a" was index 0, now 1).
    expect(bar.selectedIndex == 1, [NSString stringWithFormat:@"pin b: selection moved to %ld", (long)bar.selectedIndex]);

    [bar togglePinnedAtIndex:2];                       // pin "c": lands after "b", pinned order = pin order
    expect([order() isEqualToString:@"bcad"], [@"pin c: " stringByAppendingString:order()]);

    [bar togglePinnedAtIndex:0];                       // unpin "b": head of the unpinned block (N++ tabToEnd)
    expect([order() isEqualToString:@"cbad"], [@"unpin b: " stringByAppendingString:order()]);
    expect(!bar.items[1].pinned && bar.items[0].pinned, @"unpin b: pinned block broken");

    // A drag may not cross the pin boundary, which is what keeps the pinned tabs on the left.
    expect(![bar canSwapTabAtIndex:0 withIndex:1], @"drag crossed the pin boundary");
    expect([bar canSwapTabAtIndex:1 withIndex:2], @"drag blocked between two unpinned tabs");

    // ...and the drag itself has to honour it: "cbad" with only "c" pinned, tabs 90pt wide.
    NSEvent *(^ev)(NSEventType, CGFloat) = ^(NSEventType type, CGFloat x) {
        return [NSEvent mouseEventWithType:type location:NSMakePoint(x, 14) modifierFlags:0 timestamp:0
                              windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
    };
    [bar mouseDown:ev(NSEventTypeLeftMouseDown, 100)];      // grab "b", the first unpinned tab
    [bar mouseDragged:ev(NSEventTypeLeftMouseDragged, 20)]; // ...and shove it at the pinned block
    [bar mouseUp:ev(NSEventTypeLeftMouseUp, 20)];
    expect([order() isEqualToString:@"cbad"], [@"drag past a pinned tab reordered the strip: " stringByAppendingString:order()]);
    [bar mouseDown:ev(NSEventTypeLeftMouseDown, 190)];      // "a" over "b": both unpinned, so this one must take
    [bar mouseDragged:ev(NSEventTypeLeftMouseDragged, 110)];
    [bar mouseUp:ev(NSEventTypeLeftMouseUp, 110)];
    expect([order() isEqualToString:@"cabd"], [@"drag inside the unpinned block did not reorder: " stringByAppendingString:order()]);
    expect(probe.dropOutCalls == 0, @"an ordinary reorder was reported as a drop outside the strip");

    // ...and a drag that lets go past the end of the strip is the drop-out gesture instead (N++
    // TCN_TABDROPPEDOUTSIDE): the order is untouched and the delegate is told which tab, at 190 that is "b".
    NSString *beforeDrop = order();
    [bar mouseDown:ev(NSEventTypeLeftMouseDown, 190)];
    [bar mouseDragged:ev(NSEventTypeLeftMouseDragged, 900)];
    [bar mouseUp:ev(NSEventTypeLeftMouseUp, 900)];
    expect(probe.dropOutCalls == 1 && probe.dropOutIndex == 2,
           [NSString stringWithFormat:@"drop outside told the delegate %ld time(s), tab %ld (want 1, 2)",
            (long)probe.dropOutCalls, (long)probe.dropOutIndex]);
    expect([order() isEqualToString:beforeDrop], [@"dropping a tab off the strip reordered it: " stringByAppendingString:order()]);

    // Drop-down: one item per tab, dirty marked "*", pinned/active flagged, and it never covers the "+".
    NSMenu *menu = [bar tabListMenu];
    expect(menu.numberOfItems == (NSInteger)bar.items.count,
           [NSString stringWithFormat:@"drop-down lists %ld of %lu tabs", (long)menu.numberOfItems, (unsigned long)bar.items.count]);
    NSInteger cIdx = (NSInteger)[order() rangeOfString:@"c"].location;
    expect(cIdx >= 0 && cIdx < menu.numberOfItems && [[menu itemAtIndex:cIdx].title isEqualToString:@"*c"],
           @"drop-down misses the dirty marker");
    // Picking from the drop-down must go through didSelectTabAtIndex:, the seam the window controller listens on.
    NSInteger pick = menu.numberOfItems - 1;
    probe.selCalls = 0;
    [bar pickTabFromList:[menu itemAtIndex:pick]];
    expect(probe.selCalls == 1 && probe.selIndex == pick && bar.selectedIndex == pick,
           [NSString stringWithFormat:@"drop-down pick told the delegate %ld/%ld, selection %ld",
            (long)probe.selCalls, (long)probe.selIndex, (long)bar.selectedIndex]);

    NSMutableArray<NPPTabItem *> *many = [NSMutableArray array];
    for (int i = 0; i < 30; i++) {
        NPPTabItem *it = [NPPTabItem new];
        it.title = [NSString stringWithFormat:@"file-%d.cpp", i];
        [many addObject:it];
    }
    bar.items = many;
    expect(NSMaxX(bar.tabListButtonRect) <= 400 && NSWidth(bar.tabListButtonRect) > 0,
           [NSString stringWithFormat:@"drop-down at %@", NSStringFromRect(bar.tabListButtonRect)]);
    expect(NSMaxX(bar.newTabButtonRect) <= NSMinX(bar.tabListButtonRect),
           [NSString stringWithFormat:@"+ %@ overlaps drop-down %@", NSStringFromRect(bar.newTabButtonRect), NSStringFromRect(bar.tabListButtonRect)]);
    expect([bar tabAtPoint:NSMakePoint(NSMidX(bar.tabListButtonRect), 14)] == -1, @"drop-down button hit-tests as a tab");

    // Document Peeker gate. -schedulePeekForTab: also wants a window, which a headless bar never has, so the
    // rest of the gate lives in -peekAllowedForTab: where it can actually be exercised both ways.
    id savedPeek = [ud objectForKey:kPeekDefaultsKey];
    bar.selectedIndex = 3;
    [ud setBool:YES forKey:kPeekDefaultsKey];                 // each check below isolates one clause of the gate
    expect(![bar peekAllowedForTab:1], @"peek armed for a delegate with no previewTextForTabAtIndex:");
    NPPTabBarPeekProbe *peeker = [NPPTabBarPeekProbe new];    // the delegate is weak: keep it alive here
    bar.delegate = peeker;
    expect([bar peekAllowedForTab:1], @"peek refused although the delegate offers preview text");
    expect(![bar peekAllowedForTab:bar.selectedIndex], @"peek armed over the active tab");
    expect(![bar peekAllowedForTab:(NSInteger)bar.items.count], @"peek armed past the last tab");
    [ud setBool:NO forKey:kPeekDefaultsKey];
    expect(![bar peekAllowedForTab:1], @"peek armed with NPPTabPeekOnTab off");
    if (savedPeek) [ud setObject:savedPeek forKey:kPeekDefaultsKey]; else [ud removeObjectForKey:kPeekDefaultsKey];
    bar.delegate = probe;

    // An empty strip still has a drop-down button: an empty NSMenu pops as nothing at all and reads as broken.
    bar.items = @[];
    NSMenu *empty = [bar tabListMenu];   // no action = greyed out once AppKit validates it
    expect(empty.numberOfItems == 1 && empty.itemArray.firstObject.action == NULL,
           @"drop-down on an empty strip is not a single inert placeholder");

    // ---- Layout modes.
    id savedVert = [ud objectForKey:@"NPPTabBarVertical"], savedMulti = [ud objectForKey:@"NPPTabBarMultiLine"],
       savedLock = [ud objectForKey:@"NPPTabBarLocked"];
    NSMutableArray<NPPTabItem *> *six = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        NPPTabItem *it = [NPPTabItem new];
        it.title = [NSString stringWithFormat:@"%d", i];   // short titles => every tab is exactly kTabMinWidth wide
        [six addObject:it];
    }

    // Multi-line: 6 x 90pt tabs in a 400pt bar wrap after the fourth (the drop-down keeps kListWidth of the right).
    setMode(@"NPPTabBarMultiLine", YES);
    NPPTabBarPinProbe *modeProbe = [NPPTabBarPinProbe new];
    NPPTabBarView *ml = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
    ml.delegate = modeProbe;
    ml.items = six;
    expect(ml.preferredHeight == 2 * kTabHeight,
           [NSString stringWithFormat:@"multi-line: 6 tabs ask for %g pt, not two rows", ml.preferredHeight]);
    expect(modeProbe.sizeCalls > 0, @"multi-line: the host was never told the strip needs a second row");
    // Until the host answers, the second row is off the strip. The "+" belongs to that row, so it goes off with it
    // (⌘N still works) — clamping it back into view would drop it on top of a tab and make that tab unclickable.
    expect(NSMinY(ml.newTabButtonRect) >= NSHeight(ml.bounds),
           [NSString stringWithFormat:@"multi-line: the ungranted + sits at %@ inside a %g pt strip",
            NSStringFromRect(ml.newTabButtonRect), NSHeight(ml.bounds)]);
    for (NSInteger i = 0; i < 4; i++)
        expect(!NSIntersectsRect(ml.newTabButtonRect, [ml frameForTab:i]),
               [NSString stringWithFormat:@"multi-line: ungranted + at %@ covers tab %ld %@",
                NSStringFromRect(ml.newTabButtonRect), (long)i, NSStringFromRect([ml frameForTab:i])]);
    ml.frame = NSMakeRect(0, 0, 400, ml.preferredHeight);   // ...what the host does when it is told
    NSRect r3 = [ml frameForTab:3], r4 = [ml frameForTab:4], r5 = [ml frameForTab:5];
    expect(NSMinY([ml frameForTab:0]) == 0 && NSMinY(r3) == 0 && NSHeight(r3) == kTabHeight,
           [NSString stringWithFormat:@"multi-line: first row at %@", NSStringFromRect(r3)]);
    expect(NSMinX(r4) == 0 && NSMinY(r4) == kTabHeight,
           [NSString stringWithFormat:@"multi-line: the fifth tab did not start a second row (%@)", NSStringFromRect(r4)]);
    expect(NSMaxX(r3) <= NSMinX(ml.tabListButtonRect), @"multi-line: a tab runs under the drop-down");
    expect(!NSIntersectsRect(ml.newTabButtonRect, r5) && !NSIntersectsRect(ml.newTabButtonRect, ml.tabListButtonRect),
           [NSString stringWithFormat:@"multi-line: + at %@ collides", NSStringFromRect(ml.newTabButtonRect)]);
    expect([ml tabAtPoint:NSMakePoint(NSMidX(r5), NSMidY(r5))] == 5, @"multi-line: the second row does not hit-test");
    expect([ml maxScroll] == 0, @"multi-line: the rows still scroll once the host granted them");

    // Vertical: a column of full-width tabs, the drop-down parked at the bottom, the "+" between them.
    setMode(@"NPPTabBarMultiLine", NO);
    setMode(@"NPPTabBarVertical", YES);
    NPPTabBarView *col = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, kVerticalWidth, 300)];
    col.delegate = modeProbe;
    col.items = six;
    expect(col.preferredWidth == kVerticalWidth && col.vertical, @"vertical: the strip did not become a column");
    for (NSInteger i = 0; i < (NSInteger)col.items.count; i++) {
        NSRect f = [col frameForTab:i];
        if (NSMinX(f) == 0 && NSWidth(f) == kVerticalWidth && NSMinY(f) == i * kTabHeight && NSHeight(f) == kTabHeight) continue;
        expect(NO, [NSString stringWithFormat:@"vertical: tab %ld at %@", (long)i, NSStringFromRect(f)]);
        break;
    }
    NSRect vPlus = col.newTabButtonRect, vList = col.tabListButtonRect;
    expect(NSMinY(vPlus) >= NSMaxY([col frameForTab:5]) && NSMaxY(vPlus) <= NSMinY(vList) && NSMaxY(vList) <= 300,
           [NSString stringWithFormat:@"vertical: + at %@, drop-down at %@", NSStringFromRect(vPlus), NSStringFromRect(vList)]);
    expect([col tabAtPoint:NSMakePoint(NSMidX(vList), NSMidY([col frameForTab:2]))] == 2, @"vertical: a tab does not hit-test");
    expect([col tabAtPoint:NSMakePoint(NSMidX(vList), NSMidY(vList))] == -1, @"vertical: the drop-down hit-tests as a tab");

    // Dragging in a column slides tabs up and down, which is the one branch the horizontal drags above never take.
    // The event locations are converted out of the view so the check does not assume how a windowless flipped view
    // maps window coordinates back.
    NSPoint (^at)(NSInteger) = ^(NSInteger i) { return [col convertPoint:NSMakePoint(NSMidX([col frameForTab:i]), NSMidY([col frameForTab:i])) toView:nil]; };
    NSEvent *(^evAt)(NSEventType, NSPoint) = ^(NSEventType type, NSPoint p) {
        return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:0
                              windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
    };
    // First a drag that stays inside its own tab, so nothing is reordered and the offsets are still readable (a
    // drag that swaps re-anchors them back to zero): a column tab follows the cursor down the strip, never sideways.
    // The resulting order, checked below, comes from hit-testing and says nothing about which axis moved.
    NSRect f2 = [col frameForTab:2];
    NSPoint nudge = [col convertPoint:NSMakePoint(NSMidX(f2) + 60, NSMidY(f2) + 10) toView:nil];
    [col mouseDown:evAt(NSEventTypeLeftMouseDown, at(2))];
    [col mouseDragged:evAt(NSEventTypeLeftMouseDragged, nudge)];
    expect(col->_dragging && col->_dragDX == 0 && col->_dragDY == 10,
           [NSString stringWithFormat:@"vertical: drag offset (%g, %g), dragging=%d", col->_dragDX, col->_dragDY, col->_dragging]);
    [col mouseUp:evAt(NSEventTypeLeftMouseUp, nudge)];

    NSPoint from = at(2), to = at(0);
    [col mouseDown:evAt(NSEventTypeLeftMouseDown, from)];
    [col mouseDragged:evAt(NSEventTypeLeftMouseDragged, to)];
    [col mouseUp:evAt(NSEventTypeLeftMouseUp, to)];
    NSString *colOrder = [[col.items valueForKey:@"title"] componentsJoinedByString:@""];
    expect([colOrder isEqualToString:@"201345"], [@"vertical: dragging the third tab to the top gave " stringByAppendingString:colOrder]);

    col.items = many;                                     // 30 tabs: taller than the strip, so the column scrolls
    [col scrollTabToVisible:29];
    NSRect vLast = [col frameForTab:29];
    expect(NSMinY(vLast) >= 0 && NSMaxY(vLast) <= NSHeight([col tabAreaRect]),
           [NSString stringWithFormat:@"vertical: the last tab is off-strip at %@", NSStringFromRect(vLast)]);
    expect(NSMaxY(col.newTabButtonRect) <= NSMinY(col.tabListButtonRect), @"vertical: the + overran the drop-down");
    // The preference alone must not stack tabs inside a strip the host still lays out as a band — neither a 28pt
    // one nor a two-row multi-line one, which is tall enough that "tall enough" is not the test. A band is wider
    // than it is tall; that is the only thing that tells a granted column apart from one the host never made.
    bar.items = items;
    expect(!bar.vertical && NSMinY([bar frameForTab:1]) == 0 && NSMinX([bar frameForTab:1]) > 0,
           @"a 28pt band turned itself into a column instead of waiting for its host");
    NPPTabBarView *band = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, 2 * kTabHeight)];
    band.delegate = modeProbe;
    band.items = six;
    expect(!band.vertical && NSMinX([band frameForTab:1]) > 0 && NSWidth([band frameForTab:1]) <= kTabMaxWidth,
           [NSString stringWithFormat:@"a %g pt band turned itself into a column: tab 1 at %@",
            NSHeight(band.bounds), NSStringFromRect([band frameForTab:1])]);

    // Locked: the same drag that reordered the strip above must now do nothing at all.
    setMode(@"NPPTabBarVertical", NO);
    setMode(@"NPPTabBarLocked", YES);
    NPPTabBarView *frozen = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
    frozen.delegate = modeProbe;
    frozen.items = six;
    [frozen mouseDown:ev(NSEventTypeLeftMouseDown, 190)];
    [frozen mouseDragged:ev(NSEventTypeLeftMouseDragged, 110)];
    [frozen mouseUp:ev(NSEventTypeLeftMouseUp, 110)];
    NSString *frozenOrder = [[frozen.items valueForKey:@"title"] componentsJoinedByString:@""];
    expect([frozenOrder isEqualToString:@"012345"], [@"locked: a drag reordered the strip: " stringByAppendingString:frozenOrder]);
    // Locked means no dragging at all, so it cannot be a way into the drop-out gesture either.
    modeProbe.dropOutCalls = 0;
    [frozen mouseDown:ev(NSEventTypeLeftMouseDown, 190)];
    [frozen mouseDragged:ev(NSEventTypeLeftMouseDragged, 900)];
    [frozen mouseUp:ev(NSEventTypeLeftMouseUp, 900)];
    expect(modeProbe.dropOutCalls == 0, @"locked: a drag off the strip still reported a drop outside");

    // The Document Peeker's defaults key has no checkbox anywhere: the strip has to notice it changing by itself.
    BOOL peekWas = [ud boolForKey:kPeekDefaultsKey];
    [ud setBool:!peekWas forKey:kPeekDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:ud];
    expect(frozen->_peekOn == !peekWas, @"the strip did not pick up NPPTabPeekOnTab changing under it");

    // ---- "Look and feel" (N++ NppGUI::_tabStatus). Six checkboxes on the Tab Bar page, so six things that must
    // actually reach the strip; all of them are read live, the way the layout modes above are.
    setMode(@"NPPTabBarLocked", NO);
    NPPTabBarPinProbe *lookProbe = [NPPTabBarPinProbe new];
    NPPTabBarView *look = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
    look.delegate = lookProbe;
    // The snapshots below compare explicit colours, and under a dark theme the Dark Mode tone would win over
    // them — so this strip is pinned to "light" and the tone gets its own checks at the end.
    [look applyDarkPalette:nil];
    NSMutableArray<NPPTabItem *> *lookItems = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        NPPTabItem *it = [NPPTabItem new];
        it.title = [NSString stringWithFormat:@"t%d", i];   // short: every tab is exactly kTabMinWidth wide
        [lookItems addObject:it];
    }
    lookItems[2].dirty = YES;                               // so the saved/unsaved icons are both on screen
    look.items = lookItems;
    look.selectedIndex = 0;

    // Reduce: the whole strip gets taller and the label heavier, and the host has to be told — it owns the frame,
    // so a row height nobody asks it for is a row height that gets clipped.
    NSFont *reducedFont = [look textAttrsActive:YES][NSFontAttributeName];
    expect(look.preferredHeight == kTabHeight,
           [NSString stringWithFormat:@"reduce on: the strip asks for %g pt, not %g", look.preferredHeight, kTabHeight]);
    lookProbe.sizeCalls = 0;
    setMode(@"NPPTabBarReduce", NO);
    expect(look.preferredHeight == kTabHeightLarge,
           [NSString stringWithFormat:@"reduce off: the strip asks for %g pt, not %g", look.preferredHeight, kTabHeightLarge]);
    expect(lookProbe.sizeCalls > 0, @"reduce: the host was never asked for the taller strip");
    expect(![[look textAttrsActive:YES][NSFontAttributeName] isEqual:reducedFont],
           @"reduce off: the tab label font did not change with the row height");
    // …and the taller row has to carry the wrapped rows and the end-of-strip buttons with it.
    setMode(@"NPPTabBarMultiLine", YES);
    NPPTabBarView *tall = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeightLarge)];
    tall.delegate = lookProbe;
    tall.items = six;
    expect(tall.preferredHeight == 2 * kTabHeightLarge,
           [NSString stringWithFormat:@"reduce off + multi-line: %g pt, not two large rows", tall.preferredHeight]);
    tall.frame = NSMakeRect(0, 0, 400, tall.preferredHeight);
    expect(NSMinY([tall frameForTab:4]) == kTabHeightLarge && NSHeight([tall frameForTab:4]) == kTabHeightLarge,
           [NSString stringWithFormat:@"reduce off + multi-line: the second row is at %@", NSStringFromRect([tall frameForTab:4])]);
    setMode(@"NPPTabBarMultiLine", NO);
    look.items = many;                                      // overflowing, so the "+" is pushed against the clamp
    expect(NSMaxX(look.newTabButtonRect) <= NSMinX(look.tabListButtonRect) && NSMinX(look.newTabButtonRect) >= 0,
           [NSString stringWithFormat:@"reduce off: + at %@, drop-down at %@",
            NSStringFromRect(look.newTabButtonRect), NSStringFromRect(look.tabListButtonRect)]);
    setMode(@"NPPTabBarReduce", YES);
    look.items = lookItems;
    look.selectedIndex = 0;

    // The other four only change what gets painted, so the only honest check is the pixels. Explicit colours,
    // because two system colours that happen to coincide would make "inactive tabs look different" untestable.
    look.barBackgroundColor = NSColor.blueColor;
    look.activeTabBackgroundColor = NSColor.whiteColor;
    look.inactiveTabBackgroundColor = NSColor.blackColor;
    look.activeIndicatorColor = NSColor.redColor;
    NSData *(^snapshot)(NPPTabBarView *) = ^(NPPTabBarView *v) {
        NSRect r = v.bounds;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:(NSInteger)NSWidth(r) pixelsHigh:(NSInteger)NSHeight(r) bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        if (!ctx) return (NSData *)nil;
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = ctx;
        [v drawRect:r];
        [NSGraphicsContext restoreGraphicsState];
        return [NSData dataWithBytes:rep.bitmapData length:(NSUInteger)(rep.bytesPerRow * rep.pixelsHigh)];
    };
    NSData *base = snapshot(look);
    // If the strip never drew, every comparison below would fail for the same wrong reason. Say so once instead.
    BOOL painted = NO;
    for (NSUInteger i = 0; i < base.length && !painted; i++) painted = ((const unsigned char *)base.bytes)[i] != 0;
    expect(painted, @"self-check bug: the strip snapshot came out blank, so the four painted settings are untested");

    struct { const char *key; BOOL on; const char *complaint; } paints[] = {
        {"NPPTabBarAlternateIcons",       YES, "Alternate icons draws the same saved/unsaved markers"},
        {"NPPTabBarDrawTopBar",           NO,  "the coloured bar on the active tab is drawn either way"},
        {"NPPTabBarDrawInactiveTab",      NO,  "inactive tabs keep their own colour either way"},
        {"NPPTabBarInactiveTabShowButton", YES, "buttons on inactive tabs are drawn either way"},
    };
    for (size_t i = 0; i < sizeof(paints) / sizeof(paints[0]); ++i) {
        NSString *key = @(paints[i].key);
        setMode(key, paints[i].on);
        expect(![snapshot(look) isEqual:base], @(paints[i].complaint));
        setMode(key, !paints[i].on);
        expect([snapshot(look) isEqual:base],
               [NSString stringWithFormat:@"%@ back at its default did not restore the strip", key]);
    }

    // Show only pinned button / Show buttons on inactive tabs decide which trailing buttons exist, and a button
    // that is not drawn must not be clickable either. Every gesture below aims at the box the strip itself reports
    // (-pinRectForTab: / -closeRectForTab: give the geometry whether or not the button is drawn, which is exactly
    // what "not drawn, not clickable" has to be aimed at). A hard-coded x cannot: selecting a tab near the end
    // scrolls the strip, and the point then lands on the neighbouring box and quietly tests something else.
    NSPoint (^inBar)(NPPTabBarView *, NSRect) = ^(NPPTabBarView *v, NSRect r) {
        return [v convertPoint:NSMakePoint(NSMidX(r), NSMidY(r)) toView:nil];
    };
    void (^hoverClick)(NPPTabBarView *, NSPoint) = ^(NPPTabBarView *v, NSPoint p) {
        [v mouseMoved:evAt(NSEventTypeMouseMoved, p)];
        [v mouseDown:evAt(NSEventTypeLeftMouseDown, p)];
        [v mouseUp:evAt(NSEventTypeLeftMouseUp, p)];
    };
    lookProbe.pinCalls = 0;
    hoverClick(look, inBar(look, [look pinRectForTab:1]));
    expect(lookProbe.pinCalls == 1 && lookProbe.pinned, @"the pin box on a hovered unpinned tab did not pin it");

    setMode(@"NPPTabBarShowOnlyPinnedButton", YES);
    NPPTabBarPinProbe *pinnedOnlyProbe = [NPPTabBarPinProbe new];
    NPPTabBarView *simplest = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
    simplest.delegate = pinnedOnlyProbe;
    NSMutableArray<NPPTabItem *> *simplestItems = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        NPPTabItem *it = [NPPTabItem new];
        it.title = [NSString stringWithFormat:@"s%d", i];
        [simplestItems addObject:it];
    }
    simplestItems[0].pinned = YES;
    simplest.items = simplestItems;
    simplest.selectedIndex = 3;                      // so neither tab 0 nor tab 1 is the selected one
    hoverClick(simplest, inBar(simplest, [simplest pinRectForTab:1]));
    expect(pinnedOnlyProbe.pinCalls == 0, @"show-only-pinned: an unpinned tab still has a live pin button");
    expect(pinnedOnlyProbe.closeCalls == 0,
           @"self-check bug: the press meant for the hidden pin box landed on the close box instead");
    expect(simplest.selectedIndex == 1, @"show-only-pinned: the click did not fall through to selecting the tab");
    // …while a pinned tab keeps its pin, because that is the only way back off the pinned block. Its box sits where
    // the close box would be, since a pinned tab has no close box.
    hoverClick(simplest, inBar(simplest, [simplest pinRectForTab:0]));
    expect(pinnedOnlyProbe.pinCalls == 1 && !pinnedOnlyProbe.pinned && pinnedOnlyProbe.pinIndex == 0,
           [NSString stringWithFormat:@"show-only-pinned: unpinning a pinned tab gave %ld/%d/%ld",
            (long)pinnedOnlyProbe.pinCalls, pinnedOnlyProbe.pinned, (long)pinnedOnlyProbe.pinIndex]);
    // View ▸ Pin Tab has to keep working where the affordance is hidden — hiding the button is not "no pinning",
    // and gating -togglePinnedAtIndex: itself is the tempting wrong way to hide it.
    [simplest togglePinnedAtIndex:2];
    expect(pinnedOnlyProbe.pinCalls == 2 && pinnedOnlyProbe.pinned && pinnedOnlyProbe.pinIndex == 0 &&
           simplest.items.firstObject.pinned,
           [NSString stringWithFormat:@"show-only-pinned: View ▸ Pin Tab gave %ld/%d/%ld",
            (long)pinnedOnlyProbe.pinCalls, pinnedOnlyProbe.pinned, (long)pinnedOnlyProbe.pinIndex]);
    setMode(@"NPPTabBarShowOnlyPinnedButton", NO);

    // Show buttons on inactive tabs: with it off, the close box of a tab that is neither selected nor hovered is
    // not there, so pressing where it would be selects the tab; with it on, the same press closes it.
    for (int on = 0; on < 2; on++) {
        setMode(@"NPPTabBarInactiveTabShowButton", on == 1);
        NPPTabBarPinProbe *closeProbe = [NPPTabBarPinProbe new];
        NPPTabBarView *strip = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
        strip.delegate = closeProbe;
        NSMutableArray<NPPTabItem *> *stripItems = [NSMutableArray array];
        for (int i = 0; i < 4; i++) {
            NPPTabItem *it = [NPPTabItem new];
            it.title = [NSString stringWithFormat:@"c%d", i];
            [stripItems addObject:it];
        }
        strip.items = stripItems;
        strip.selectedIndex = 0;                     // tab 1 is inactive and, with no mouseMoved, unhovered
        NSPoint onCloseBox = inBar(strip, [strip closeRectForTab:1]);
        [strip mouseDown:evAt(NSEventTypeLeftMouseDown, onCloseBox)];
        [strip mouseUp:evAt(NSEventTypeLeftMouseUp, onCloseBox)];
        expect(closeProbe.closeCalls == (on ? 1 : 0) && (!on || closeProbe.closeIndex == 1),
               [NSString stringWithFormat:@"inactive-tab buttons %s: %ld close calls",
                on ? "on" : "off", (long)closeProbe.closeCalls]);
        if (!on) expect(strip.selectedIndex == 1, @"inactive-tab buttons off: the press did not select the tab instead");
    }

    // ---- Dark Mode tone. The twelve NppDarkMode colours are the chrome's colours in dark mode, so each slot has
    // to land on the right thing (a synthetic palette, one colour per slot: a swap between two of them would
    // otherwise look identical to a real one), and a light theme has to keep taking none of them.
    NPPTabBarView *tone = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
    tone.barBackgroundColor = NSColor.blueColor;
    tone.inactiveTabBackgroundColor = NSColor.blueColor;
    tone.activeTabTextColor = NSColor.blueColor;
    tone.inactiveTabTextColor = NSColor.blueColor;
    [tone applyDarkPalette:nil];
    expect([tone.barBackgroundColor isEqual:NSColor.blueColor] && [tone.inactiveTabBackgroundColor isEqual:NSColor.blueColor] &&
           [tone.activeTabTextColor isEqual:NSColor.blueColor] && [tone.inactiveTabTextColor isEqual:NSColor.blueColor] &&
           [tone.edgeColor isEqual:NSColor.separatorColor],
           @"light theme: the strip stopped using the colours the host gave it");
    NSDictionary<NSString *, NSColor *> *fake = @{ kDMBarBg: NSColor.redColor, kDMBarSofter: NSColor.greenColor,
                                                   kDMBarHot: NSColor.yellowColor, kDMBarText: NSColor.cyanColor,
                                                   kDMBarDarker: NSColor.magentaColor, kDMBarEdge: NSColor.orangeColor };
    [tone applyDarkPalette:fake];
    expect([tone.barBackgroundColor isEqual:NSColor.redColor], @"dark: the strip is not painted in the tone's background");
    expect([tone.inactiveTabBackgroundColor isEqual:NSColor.redColor], @"dark: inactive tabs are not the tone's background");
    expect([tone.activeTabTextColor isEqual:NSColor.cyanColor], @"dark: active tab text is not the tone's text");
    expect([tone.inactiveTabTextColor isEqual:NSColor.magentaColor], @"dark: inactive tab text is not the tone's darker text");
    expect([tone.edgeColor isEqual:NSColor.orangeColor], @"dark: hairlines and dividers are not the tone's edge");
    expect([[tone hoverColorOver:NSColor.blackColor fraction:0.18] isEqual:NSColor.yellowColor],
           @"dark: hover highlights are not the tone's hot background");
    // The active tab keeps the editor background the host hands it; the tone only fills that slot in.
    expect([tone.activeTabBackgroundColor isEqual:NSColor.greenColor],
           @"dark: an unset active tab background did not fall back to the tone's softer background");
    tone.activeTabBackgroundColor = NSColor.whiteColor;
    expect([tone.activeTabBackgroundColor isEqual:NSColor.whiteColor],
           @"dark: the tone overrode the active tab background the host set from the editor");
    // Every mode still has to work with the tone on: the "+", the drop-down and the tabs keep their geometry,
    // and a strip in a tone paints (a nil colour reaching -setFill would throw and take the whole strip out).
    tone.items = lookItems;
    tone.selectedIndex = 0;
    [tone mouseMoved:evAt(NSEventTypeMouseMoved, [tone convertPoint:NSMakePoint(NSMidX([tone frameForTab:1]), 14) toView:nil])];
    expect(NSMaxX(tone.newTabButtonRect) <= NSMinX(tone.tabListButtonRect) && !NSIsEmptyRect([tone frameForTab:0]),
           @"dark: the tone moved the + or the drop-down");
    NSData *toned = snapshot(tone);
    BOOL tonePainted = NO;
    for (NSUInteger i = 0; i < toned.length && !tonePainted; i++) tonePainted = ((const unsigned char *)toned.bytes)[i] != 0;
    expect(tonePainted, @"dark: the toned strip drew nothing");

    // …and the tone is re-read on NPPThemeDidChangeNotification, which is the only thing that tells the strip a
    // tone (or a theme) changed: without that observer the synthetic palette above would survive the post.
    [NSNotificationCenter.defaultCenter postNotificationName:NPPThemeDidChangeNotification object:nil];
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NSColor *want = lm.currentThemeIsDark ? [lm globalBackgroundColorNamed:kDMBarBg] : NSColor.blueColor;
    expect(want && [tone.barBackgroundColor isEqual:want],
           [NSString stringWithFormat:@"the strip did not re-read the palette on NPPThemeDidChangeNotification (got %@, want %@)",
            tone.barBackgroundColor, want]);

    // Tooltips. The strip's own text is the item's, but a delegate that offers one wins: that is the only way an
    // untitled tab's creation time (N++ Buffer.h:296-306, NppNotification.cpp:1285-1293) can reach a strip that
    // knows nothing about documents. A delegate with nothing to say for a tab falls back instead of blanking it.
    NPPTabBarView *tips = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, kTabHeight)];
    tips.delegate = probe;                                  // NPPTabBarPinProbe: no tooltip method at all
    NPPTabItem *named = [NPPTabItem new]; named.title = @"a.cpp"; named.toolTip = @"/tmp/a.cpp";
    NPPTabItem *fresh = [NPPTabItem new]; fresh.title = @"new 1";   // untitled: no path, so no item tooltip
    tips.items = @[named, fresh];
    NSString *(^tipFor)(NSInteger) = ^(NSInteger i) {
        return [tips view:tips stringForToolTip:0 point:NSZeroPoint userData:(void *)(intptr_t)i];
    };
    expect([tipFor(0) isEqualToString:@"/tmp/a.cpp"], [@"no delegate tooltip: tab 0 says " stringByAppendingString:tipFor(0)]);
    expect([tipFor(1) isEqualToString:@"new 1"], [@"no delegate tooltip: tab 1 says " stringByAppendingString:tipFor(1)]);
    NPPTabBarTipProbe *tipProbe = [NPPTabBarTipProbe new];   // held: -delegate is weak
    tips.delegate = tipProbe;
    expect([tipFor(1) isEqualToString:@"new 1\n2026-09-07 10:11:12"],
           [@"the delegate's tooltip never reached the untitled tab: " stringByAppendingString:tipFor(1)]);
    expect([tipFor(0) isEqualToString:@"/tmp/a.cpp"],
           [@"a delegate with no tooltip for a tab blanked the item's own: " stringByAppendingString:tipFor(0)]);

    // The status bar is the other half of this chrome. It has its own checks; the self-test runner's module list
    // is not a file this port's chrome owns, so they run from here.
    // ponytail: delete this line once "NPPStatusBarView" is on that list.
    [fails addObjectsFromArray:[NPPStatusBarView selfCheckFailures]];

    void (^restore)(NSString *, id) = ^(NSString *key, id v) {
        if (v) [ud setObject:v forKey:key]; else [ud removeObjectForKey:key];
    };
    restore(@"NPPTabBarVertical", savedVert);
    restore(@"NPPTabBarMultiLine", savedMulti);
    restore(@"NPPTabBarLocked", savedLock);
    restore(kPeekDefaultsKey, savedPeek);
    for (NSString *key in lookDefaults) restore(key, savedLook[key]);
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:ud];

    return fails;
}

@end
