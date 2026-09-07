// NPPStatusBarView.mm — Notepad++ status bar: docType | docSize | cursor | eol | encoding | INS/OVR
#import "NPPStatusBarView.h"
#import "NPPLanguageManager.h"   // Dark Mode tone palette + NPPThemeDidChangeNotification
#import "NPPCommands.h"          // the two commands the double-clickable fields fire

enum { kDocType, kDocSize, kCursor, kEol, kEncoding, kInsertMode, kFieldCount };

// N++ widths (StatusBar::init in Notepad_plus.cpp): docType is the flexible one.
static const CGFloat kFixedWidths[kFieldCount] = { 0, 200, 260, 110, 110, 40 };
static const CGFloat kPad = 6;

// The three Dark Mode tone colours a status bar has a use for, under NPPLanguageManager's own style names.
// Upstream fills the bar with getBackgroundBrush(), writes with getTextColor() and rules the dividers with
// getEdgePen() (WinControls/StatusBar/StatusBar.cpp), so those are the three.
static NSString *const kDMStatusBg   = @"Dark mode background";
static NSString *const kDMStatusText = @"Dark mode text";
static NSString *const kDMStatusEdge = @"Dark mode edge";

@interface NPPStatusBarView ()
// nil (or a nil slot) = light theme: the bar keeps the colours the host gave it. Its own step so the self-check
// can hand the bar a palette without repainting the user's actual theme.
- (void)applyDarkPalette:(nullable NSDictionary<NSString *, NSColor *> *)palette;
// Fires a menu command down the responder chain. Its own method so the self-check can watch it without a window
// controller; returns NO when nothing in the chain took it.
- (BOOL)sendCommand:(NPPCmd)cmd;
- (NSRect)frameOfField:(int)i;
@end

// Self-check probe: records what the double-clickable fields fire, since headless there is no responder chain
// to take the command.
@interface NPPStatusBarProbe : NPPStatusBarView
@property (nonatomic, readonly) NSMutableArray<NSNumber *> *sent;
@end

@implementation NPPStatusBarView {
    NSTextField *_labels[kFieldCount];
    NSColor *_dmBg, *_dmText, *_dmEdge;   // the tone's palette; wins over _backgroundColor / _textColor
}

@synthesize backgroundColor = _backgroundColor;
@synthesize textColor = _textColor;

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return self;
    _backgroundColor = NSColor.windowBackgroundColor;
    _textColor = NSColor.labelColor;
    for (int i = 0; i < kFieldCount; i++) {
        NSTextField *l = [NSTextField labelWithString:@""];
        l.font = [NSFont systemFontOfSize:11];
        l.textColor = _textColor;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.usesSingleLineMode = YES;
        l.alignment = (i == kInsertMode) ? NSTextAlignmentCenter : NSTextAlignmentLeft;
        [self addSubview:l];
        _labels[i] = l;
    }
    _labels[kInsertMode].stringValue = @"INS";
    // Theme *and* Dark Mode tone arrive on one notification (NPPLanguageManager re-derives both and posts once).
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeDidChange:)
                                               name:NPPThemeDidChangeNotification object:nil];
    [self readDarkPalette];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (CGFloat)preferredHeight { return 22; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, self.preferredHeight); }

// Field i occupies [x, x+w) of our bounds.
- (NSRect)frameOfField:(int)i {
    CGFloat fixed = 0;
    for (int k = 1; k < kFieldCount; k++) fixed += kFixedWidths[k];
    CGFloat x = 0, W = NSWidth(self.bounds);
    for (int k = 0; k < i; k++) x += (k == kDocType) ? MAX(0, W - fixed) : kFixedWidths[k];
    CGFloat w = (i == kDocType) ? MAX(0, W - fixed) : kFixedWidths[i];
    return NSMakeRect(x, 0, w, NSHeight(self.bounds));
}

- (void)layout {
    [super layout];
    for (int i = 0; i < kFieldCount; i++) {
        NSRect f = NSInsetRect([self frameOfField:i], kPad, 0);
        CGFloat h = ceil(_labels[i].font.pointSize * 1.4);
        f.origin.y = floor((NSHeight(self.bounds) - h) / 2);
        f.size.height = h;
        _labels[i].frame = f;
    }
}

- (void)drawRect:(NSRect)dirty {
    [self.backgroundColor setFill];
    // Fill our own bounds, never `dirty`: since macOS 14 clipsToBounds defaults to NO, so a dirty rect bigger than
    // this 22pt strip would paint the whole window — this view is the last subview, so it covered tab bar and editor.
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
    [(_dmEdge ?: NSColor.separatorColor) setFill];
    for (int i = 1; i < kFieldCount; i++) {
        CGFloat x = NSMinX([self frameOfField:i]);
        NSRectFill(NSMakeRect(x, 3, 1, NSHeight(self.bounds) - 6));
    }
}

- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; self.needsLayout = YES; self.needsDisplay = YES; }

#pragma mark - Clicks

// Labels swallow mouse events otherwise; route every click to us.
- (NSView *)hitTest:(NSPoint)p { return NSPointInRect([self convertPoint:p fromView:self.superview], self.bounds) ? self : nil; }

- (void)mouseDown:(NSEvent *)e {
    // N++ NppNotification.cpp:976-984: double-clicking Ln:Col opens Go To Line and double-clicking
    // length:lines opens Summary. Both are ordinary menu commands, so they leave the same way the panels'
    // context menus do — a proxy item down the responder chain — and the window controller keeps owning them.
    if (e.clickCount == 2) {
        int field = [self fieldAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
        if (field == kCursor || field == kDocSize) {
            if (![self sendCommand:(field == kCursor ? NPPCmdSearchGoToLine : NPPCmdViewSummary)]) NSBeep();
            return;
        }
    }
    [self handleClick:e];
}
- (void)rightMouseDown:(NSEvent *)e { [self handleClick:e]; }

- (BOOL)sendCommand:(NPPCmd)cmd {
    NSMenuItem *proxy = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(nppCommand:) keyEquivalent:@""];
    proxy.tag = cmd;
    return [NSApp sendAction:@selector(nppCommand:) to:nil from:proxy];
}

- (int)fieldAtPoint:(NSPoint)p {
    for (int i = 0; i < kFieldCount; i++) if (NSPointInRect(p, [self frameOfField:i])) return i;
    return -1;
}

- (void)handleClick:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    int field = [self fieldAtPoint:p];
    NSMenu *menu = nil;
    switch (field) {
        case kDocType:    menu = _docTypeMenu; break;
        case kEol:        menu = _eolMenu; break;
        case kEncoding:   menu = _encodingMenu; break;
        case kInsertMode: if (_insertModeClicked) _insertModeClicked(); return;
        default: return;
    }
    // ponytail: N++ only reacts to right-click; we accept both buttons (macOS status-bar convention).
    if (menu) [menu popUpMenuPositioningItem:nil atLocation:p inView:self];
}

#pragma mark - Text properties (only touch stringValue when changed to avoid flicker)

- (void)setField:(int)i text:(NSString *)t {
    t = t ?: @"";
    if (![_labels[i].stringValue isEqualToString:t]) _labels[i].stringValue = t;
}
- (void)setDocTypeText:(NSString *)t    { [self setField:kDocType text:t]; }
- (void)setDocSizeText:(NSString *)t    { [self setField:kDocSize text:t]; }
- (void)setCursorText:(NSString *)t     { [self setField:kCursor text:t]; }
- (void)setEolText:(NSString *)t        { [self setField:kEol text:t]; }
- (void)setEncodingText:(NSString *)t   { [self setField:kEncoding text:t]; }
- (void)setInsertModeText:(NSString *)t { [self setField:kInsertMode text:t]; }
- (NSString *)docTypeText    { return _labels[kDocType].stringValue; }
- (NSString *)docSizeText    { return _labels[kDocSize].stringValue; }
- (NSString *)cursorText     { return _labels[kCursor].stringValue; }
- (NSString *)eolText        { return _labels[kEol].stringValue; }
- (NSString *)encodingText   { return _labels[kEncoding].stringValue; }
- (NSString *)insertModeText { return _labels[kInsertMode].stringValue; }

#pragma mark - Theming

// The Dark Mode tone wins over what the host set: in dark mode N++ paints the status bar from NppDarkMode and
// ignores the styler colours entirely. A light theme leaves both of these exactly as the host gave them.
- (NSColor *)backgroundColor { return _dmBg ?: _backgroundColor; }
- (NSColor *)textColor       { return _dmText ?: _textColor; }
- (void)setBackgroundColor:(NSColor *)c { _backgroundColor = c ?: NSColor.windowBackgroundColor; self.needsDisplay = YES; }
- (void)setTextColor:(NSColor *)c { _textColor = c ?: NSColor.labelColor; [self applyTextColor]; }
- (void)applyTextColor { for (int i = 0; i < kFieldCount; i++) _labels[i].textColor = self.textColor; }

- (void)applyDarkPalette:(NSDictionary<NSString *, NSColor *> *)p {
    _dmBg   = p[kDMStatusBg];
    _dmText = p[kDMStatusText];
    _dmEdge = p[kDMStatusEdge];
    [self applyTextColor];
    self.needsDisplay = YES;
}

- (void)readDarkPalette {
    NPPLanguageManager *m = NPPLanguageManager.shared;
    if (!m.currentThemeIsDark) { [self applyDarkPalette:nil]; return; }
    NSMutableDictionary<NSString *, NSColor *> *p = [NSMutableDictionary dictionary];
    for (NSString *name in @[kDMStatusBg, kDMStatusText, kDMStatusEdge]) {
        NSColor *c = [m globalBackgroundColorNamed:name];   // each dark-mode style carries its one colour in fg and bg alike
        if (c) p[name] = c;
    }
    [self applyDarkPalette:p];
}

- (void)themeDidChange:(NSNotification *)n { [self readDarkPalette]; }

#pragma mark - Self checks

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) { if (!ok) [fails addObject:msg]; };

    // Wide enough that the flexible docType field has room, so the first field divider lands at a known x.
    const CGFloat W = 1000, H = 22;
    NPPStatusBarView *bar = [[NPPStatusBarView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    bar.backgroundColor = NSColor.blueColor;
    bar.textColor = NSColor.blueColor;

    // Light theme: the bar keeps the colours the window controller gave it, down to the labels.
    [bar applyDarkPalette:nil];
    expect([bar.backgroundColor isEqual:NSColor.blueColor] && [bar.textColor isEqual:NSColor.blueColor] &&
           [bar->_labels[kDocType].textColor isEqual:NSColor.blueColor],
           @"light theme: the status bar stopped using the colours the host gave it");

    // Dark: each slot has to land on the right thing — one colour per slot, so a swap cannot pass.
    [bar applyDarkPalette:@{ kDMStatusBg: NSColor.redColor, kDMStatusText: NSColor.cyanColor,
                             kDMStatusEdge: NSColor.orangeColor }];
    expect([bar.backgroundColor isEqual:NSColor.redColor], @"dark: the status bar is not the tone's background");
    expect([bar.textColor isEqual:NSColor.cyanColor], @"dark: status bar text is not the tone's text");
    // …and the labels are real NSTextFields: a palette that never reaches them leaves the old colour on screen.
    expect([bar->_labels[kCursor].textColor isEqual:NSColor.cyanColor],
           @"dark: the tone's text colour never reached the status bar labels");

    // The fill and the dividers are the things only pixels can prove: -drawRect: reading the ivar instead of the
    // getter would pass every check above and still paint the light colours.
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)W pixelsHigh:(NSInteger)H
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!ctx) {
        [fails addObject:@"self-check bug: no bitmap context, so the status bar fill is untested"];
    } else {
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = ctx;
        [bar drawRect:bar.bounds];
        [NSGraphicsContext restoreGraphicsState];
        NSColor *(^px)(NSInteger) = ^(NSInteger x) {
            return [[rep colorAtX:x y:(NSInteger)H / 2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        };
        NSColor *fill = px(5);
        expect(fill.redComponent > 0.9 && fill.greenComponent < 0.1 && fill.blueComponent < 0.1,
               [NSString stringWithFormat:@"dark: the status bar painted %@, not the tone's background", fill]);
        NSColor *divider = px((NSInteger)NSMinX([bar frameOfField:kDocSize]));   // the first field divider
        expect(divider.redComponent > 0.9 && divider.greenComponent > 0.4 && divider.blueComponent < 0.2,
               [NSString stringWithFormat:@"dark: the field dividers are %@, not the tone's edge", divider]);
    }

    // …and it re-reads on NPPThemeDidChangeNotification: without that observer the synthetic palette survives.
    [NSNotificationCenter.defaultCenter postNotificationName:NPPThemeDidChangeNotification object:nil];
    NPPLanguageManager *m = NPPLanguageManager.shared;
    NSColor *want = m.currentThemeIsDark ? [m globalBackgroundColorNamed:kDMStatusBg] : NSColor.blueColor;
    expect(want && [bar.backgroundColor isEqual:want],
           [NSString stringWithFormat:@"the status bar did not re-read the palette on NPPThemeDidChangeNotification (got %@, want %@)",
            bar.backgroundColor, want]);

    // Double-clicking Ln:Col opens Go To Line and double-clicking length:lines opens Summary — and nothing else
    // on the bar fires a command, least of all a single click on those two fields.
    NPPStatusBarProbe *probe = [[NPPStatusBarProbe alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    void (^click)(int, NSInteger) = ^(int field, NSInteger clicks) {
        NSRect f = [probe frameOfField:field];
        NSPoint p = [probe convertPoint:NSMakePoint(NSMidX(f), NSMidY(f)) toView:nil];
        [probe mouseDown:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0
                                           timestamp:0 windowNumber:0 context:nil eventNumber:0
                                          clickCount:clicks pressure:1]];
    };
    click(kCursor, 2);
    click(kDocSize, 2);
    expect(probe.sent.count == 2 && probe.sent[0].integerValue == NPPCmdSearchGoToLine &&
           probe.sent[1].integerValue == NPPCmdViewSummary,
           [NSString stringWithFormat:@"double-clicking Ln:Col then length:lines fired %@", probe.sent]);
    [probe.sent removeAllObjects];
    click(kCursor, 1); click(kDocSize, 1);              // one click on the same two fields: nothing opens
    click(kDocType, 2); click(kEol, 2); click(kEncoding, 2);   // the menu fields never open a dialog
    expect(probe.sent.count == 0,
           [NSString stringWithFormat:@"a status bar click that opens nothing upstream fired %@", probe.sent]);
    return fails;
}

@end

@implementation NPPStatusBarProbe
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) _sent = [NSMutableArray array];
    return self;
}
- (BOOL)sendCommand:(NPPCmd)cmd { [_sent addObject:@(cmd)]; return YES; }
@end
