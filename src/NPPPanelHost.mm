#import "NPPPanelHost.h"
#import "NPPDocument.h"
#import "NPPCommands.h"

// One docked edge: a header (title tabs + close button) plus the selected panel's view.
@interface NPPPanelArea : NSView
@property (nonatomic) NPPPanelEdge edge;
@property (nonatomic, copy) NSArray<id<NPPPanel>> *panels;
@property (nonatomic) NSInteger selected;
@property (nonatomic, copy, nullable) void (^onClose)(id<NPPPanel>);
@property (nonatomic, strong, nullable) NSColor *headerBackground;
@property (nonatomic, strong, nullable) NSColor *headerText;
- (void)reload;
@end

static const CGFloat kHeaderH = 24;

@implementation NPPPanelArea {
    NSMutableArray<NSButton *> *_tabs;
    NSButton *_close;
    NSButton *_gear;
    id<NPPPanel> _frontPanel;   // the panel currently on top of this edge's tab stack
}

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _panels = @[];
    _selected = 0;
    _tabs = [NSMutableArray array];
    _close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close panel"]
                                target:self action:@selector(closeClicked:)];
    _close.bordered = NO;
    _close.imagePosition = NSImageOnly;
    [self addSubview:_close];
    _gear = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Panel actions"]
                               target:self action:@selector(gearClicked:)];
    _gear.bordered = NO;
    _gear.imagePosition = NSImageOnly;
    [self addSubview:_gear];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)reload {
    for (NSButton *b in _tabs) [b removeFromSuperview];
    [_tabs removeAllObjects];
    if (_selected >= (NSInteger)_panels.count) _selected = MAX(0, (NSInteger)_panels.count - 1);
    NSInteger i = 0;
    for (id<NPPPanel> p in _panels) {
        NSButton *b = [NSButton buttonWithTitle:p.panelTitle target:self action:@selector(tabClicked:)];
        b.bordered = NO;
        b.tag = i;
        b.font = [NSFont systemFontOfSize:11 weight:(i == _selected ? NSFontWeightSemibold : NSFontWeightRegular)];
        if (_headerText) b.contentTintColor = _headerText;
        [self addSubview:b];
        [_tabs addObject:b];
        i++;
    }
    for (NSInteger j = 0; j < (NSInteger)_panels.count; j++) {
        NSView *v = _panels[j].panelView;
        if (j == _selected) {
            if (v.superview != self) [self addSubview:v];
            v.hidden = NO;
        } else {
            v.hidden = YES;
        }
    }
    id<NPPPanel> sel = _selected < (NSInteger)_panels.count ? _panels[_selected] : nil;
    // Several panels can share an edge as tabs. A panel that goes behind another must be told it is hidden, or its
    // timers and file watchers keep running while it is off screen; the one that comes forward must be told it is
    // visible, or it stays frozen. The host's showPanel:/hidePanel: only cover docking, not this tab switch.
    if (sel != _frontPanel) {
        if ([_frontPanel respondsToSelector:@selector(panelWillHide)]) [_frontPanel panelWillHide];
        _frontPanel = sel;
        if ([sel respondsToSelector:@selector(panelDidBecomeVisible)]) [sel panelDidBecomeVisible];
    }
    _gear.hidden = !([sel respondsToSelector:@selector(panelActionMenu)] && [sel panelActionMenu] != nil);
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
    [self layout];
}

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    // Share the header width between the tabs (several panels can dock at the same edge) and truncate their titles.
    CGFloat avail = MAX(40, NSWidth(b) - 52);   // leave room for the gear and close buttons
    CGFloat gap = 6;
    CGFloat total = 0;
    for (NSButton *t in _tabs) total += t.intrinsicContentSize.width + gap;
    CGFloat scale = (total > avail && total > 0) ? avail / total : 1.0;
    CGFloat x = 6;
    for (NSButton *t in _tabs) {
        CGFloat w = MAX(28, (t.intrinsicContentSize.width) * scale);
        t.frame = NSMakeRect(x, 3, w, kHeaderH - 6);
        t.lineBreakMode = NSLineBreakByTruncatingTail;
        t.toolTip = t.title;
        x += w + gap * scale;
    }
    _close.frame = NSMakeRect(NSWidth(b) - 22, 4, 16, 16);
    _gear.frame = NSMakeRect(NSWidth(b) - 44, 4, 16, 16);
    for (NSInteger j = 0; j < (NSInteger)_panels.count; j++) {
        if (j != _selected) continue;
        NSView *v = _panels[j].panelView;
        v.frame = NSMakeRect(0, kHeaderH, NSWidth(b), MAX(0, NSHeight(b) - kHeaderH));
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
}

- (void)drawRect:(NSRect)dirty {
    [(_headerBackground ?: NSColor.windowBackgroundColor) setFill];
    NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), kHeaderH));
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, kHeaderH - 1, NSWidth(self.bounds), 1));
}

- (void)tabClicked:(NSButton *)sender { _selected = sender.tag; [self reload]; }
- (void)closeClicked:(id)sender {
    if (_selected < (NSInteger)_panels.count && _onClose) _onClose(_panels[_selected]);
}
- (void)gearClicked:(NSButton *)sender {
    id<NPPPanel> sel = _selected < (NSInteger)_panels.count ? _panels[_selected] : nil;
    NSMenu *m = [sel respondsToSelector:@selector(panelActionMenu)] ? [sel panelActionMenu] : nil;
    if (m) [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}
@end

// ---------------------------------------------------------------------------------------------------------------

@implementation NPPPanelHost {
    NSView *_center, *_secondary;
    NPPPanelArea *_left, *_right, *_bottom;
    CGFloat _leftW, _rightW, _bottomH;
    NSMutableArray<NSView *> *_dividers;   // 4 thin drag handles: left, right, bottom, split
    NSInteger _dragEdge;                   // -1 none, else NPPPanelEdge or kDragSplit
}

static NSString *const kLeftKey = @"NPPPanelLeftWidth", *const kRightKey = @"NPPPanelRightWidth", *const kBottomKey = @"NPPPanelBottomHeight";
static NSString *const kSplitVerticalKey = @"NPPSplitVertical", *const kSplitPositionKey = @"NPPSplitPosition";
static const NSInteger kDragSplit = 100;   // outside the NPPPanelEdge range
static const CGFloat kSplitMin = 0.15, kSplitMax = 0.85;

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _center = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_center];
    _secondary = [[NSView alloc] initWithFrame:NSZeroRect];
    _secondary.hidden = YES;
    [self addSubview:_secondary];
    _left = [[NPPPanelArea alloc] initWithFrame:NSZeroRect];   _left.edge = NPPPanelEdgeLeft;
    _right = [[NPPPanelArea alloc] initWithFrame:NSZeroRect];  _right.edge = NPPPanelEdgeRight;
    _bottom = [[NPPPanelArea alloc] initWithFrame:NSZeroRect]; _bottom.edge = NPPPanelEdgeBottom;
    __weak NPPPanelHost *weakSelf = self;
    for (NPPPanelArea *a in @[_left, _right, _bottom]) {
        a.hidden = YES;
        a.onClose = ^(id<NPPPanel> p) { [weakSelf hidePanel:p]; };
        [self addSubview:a];
    }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    _leftW = [d doubleForKey:kLeftKey] ?: 240;
    _rightW = [d doubleForKey:kRightKey] ?: 160;
    _bottomH = [d doubleForKey:kBottomKey] ?: 200;
    _splitVertical = [d objectForKey:kSplitVerticalKey] ? [d boolForKey:kSplitVerticalKey] : YES;
    _splitPosition = [d doubleForKey:kSplitPositionKey] ?: 0.5;
    _dividers = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
        v.hidden = YES;
        [self addSubview:v];
        [_dividers addObject:v];
    }
    // Right-clicking the split bar is how a Notepad++ user turns side-by-side into stacked: upstream builds this
    // popup once and keeps it (SplitterContainer.cpp WM_DOPOPUPMENU), and it is the only path to Rotate that is not
    // buried in the View menu. Rotate-to-right first, as upstream inserts them. Hanging it off the divider view is
    // enough — AppKit pops up a view's -menu on right-click, and a hidden divider is not hit-tested, so the menu
    // cannot appear when there is no second view. No target, exactly like the View-menu items: -nppCommand: rides
    // the responder chain to the window controller, which also greys the items out through -validateMenuItem:.
    NSMenu *splitMenu = [[NSMenu alloc] initWithTitle:@"Splitter"];
    for (NSArray *pair in @[@[@"Rotate to Right", @(NPPCmdViewRotateRight)],
                            @[@"Rotate to Left", @(NPPCmdViewRotateLeft)]]) {
        NSMenuItem *it = [splitMenu addItemWithTitle:pair[0] action:@selector(nppCommand:) keyEquivalent:@""];
        it.tag = [pair[1] integerValue];
    }
    _dividers[3].menu = splitMenu;
    _dragEdge = -1;
    return self;
}

- (NSMenu *)splitDividerMenu { return _dividers[3].isHidden ? nil : _dividers[3].menu; }
- (NSRect)splitDividerFrame { return _dividers[3].isHidden ? NSZeroRect : _dividers[3].frame; }

- (BOOL)isFlipped { return YES; }
- (NSView *)centerView { return _center; }
- (NSView *)secondaryCenterView { return _secondary; }

- (void)setSplitEnabled:(BOOL)on {
    if (on == _splitEnabled) return;
    _splitEnabled = on;
    _secondary.hidden = !on;
    [self setNeedsLayout:YES];
    [self layout];
    [self.window invalidateCursorRectsForView:self];
}

- (void)setSplitVertical:(BOOL)vertical {
    if (vertical == _splitVertical) return;
    _splitVertical = vertical;
    [NSUserDefaults.standardUserDefaults setBool:vertical forKey:kSplitVerticalKey];
    [self setNeedsLayout:YES];
    [self layout];
    [self.window invalidateCursorRectsForView:self];
    if (_splitDidResize) _splitDidResize();
}

- (void)setSplitPosition:(CGFloat)position {
    position = MAX(kSplitMin, MIN(kSplitMax, position));
    if (position == _splitPosition) return;
    _splitPosition = position;
    [NSUserDefaults.standardUserDefaults setDouble:position forKey:kSplitPositionKey];
    [self setNeedsLayout:YES];
    [self layout];
    if (_splitDidResize) _splitDidResize();
}

- (NPPPanelArea *)areaForEdge:(NPPPanelEdge)e {
    switch (e) { case NPPPanelEdgeLeft: return _left; case NPPPanelEdgeRight: return _right; default: return _bottom; }
}

- (CGFloat)sizeForPanel:(id<NPPPanel>)p {
    if ([p respondsToSelector:@selector(panelPreferredSize)]) {
        CGFloat s = p.panelPreferredSize;
        if (s > 0) return s;
    }
    return p.panelPreferredEdge == NPPPanelEdgeBottom ? 200 : 240;
}

- (void)showPanel:(id<NPPPanel>)panel {
    NPPPanelArea *area = [self areaForEdge:panel.panelPreferredEdge];
    NSInteger idx = [area.panels indexOfObject:panel];
    if (idx == NSNotFound) {
        area.panels = [area.panels arrayByAddingObject:panel];
        idx = (NSInteger)area.panels.count - 1;
        if (area.hidden) {
            CGFloat want = [self sizeForPanel:panel];
            switch (panel.panelPreferredEdge) {
                case NPPPanelEdgeLeft: if (_leftW < 80) _leftW = want; break;
                case NPPPanelEdgeRight: if (_rightW < 80) _rightW = want; break;
                default: if (_bottomH < 60) _bottomH = want; break;
            }
        }
    }
    area.selected = idx;
    area.hidden = NO;
    [area reload];   // reload owns the panelDidBecomeVisible / panelWillHide transitions for this edge
    [self setNeedsLayout:YES];
    [self layout];
}

- (void)hidePanel:(id<NPPPanel>)panel {
    NPPPanelArea *area = [self areaForEdge:panel.panelPreferredEdge];
    NSInteger idx = [area.panels indexOfObject:panel];
    if (idx == NSNotFound) return;
    [panel.panelView removeFromSuperview];   // reload sends panelWillHide once the panel is out of the tab stack
    NSMutableArray *m = [area.panels mutableCopy];
    [m removeObjectAtIndex:(NSUInteger)idx];
    area.panels = m;
    area.hidden = m.count == 0;
    [area reload];
    [self setNeedsLayout:YES];
    [self layout];
}

- (void)togglePanel:(id<NPPPanel>)panel {
    if ([self isPanelVisible:panel]) [self hidePanel:panel]; else [self showPanel:panel];
}

- (BOOL)isPanelVisible:(id<NPPPanel>)panel {
    NPPPanelArea *area = [self areaForEdge:panel.panelPreferredEdge];
    return !area.hidden && [area.panels containsObject:panel] && area.panels[area.selected] == panel;
}

- (NSArray<id<NPPPanel>> *)visiblePanels {
    NSMutableArray *r = [NSMutableArray array];
    for (NPPPanelArea *a in @[_left, _right, _bottom]) if (!a.hidden) [r addObjectsFromArray:a.panels];
    return r;
}

- (void)broadcastCurrentDocument:(NPPDocument *)doc {
    for (NPPPanelArea *a in @[_left, _right, _bottom])
        for (id<NPPPanel> p in a.panels)
            if ([p respondsToSelector:@selector(panelDidChangeCurrentDocument:)]) [p panelDidChangeCurrentDocument:doc];
}

- (void)applyThemeBackground:(NSColor *)background text:(NSColor *)text {
    for (NPPPanelArea *a in @[_left, _right, _bottom]) {
        a.headerBackground = background;
        a.headerText = text;
        [a reload];
    }
}

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    const CGFloat divider = 5;
    CGFloat lw = _left.hidden ? 0 : MAX(120, MIN(_leftW, NSWidth(b) * 0.6));
    CGFloat rw = _right.hidden ? 0 : MAX(80, MIN(_rightW, NSWidth(b) * 0.6));
    CGFloat bh = _bottom.hidden ? 0 : MAX(60, MIN(_bottomH, NSHeight(b) * 0.7));
    CGFloat lDiv = _left.hidden ? 0 : divider, rDiv = _right.hidden ? 0 : divider, bDiv = _bottom.hidden ? 0 : divider;

    CGFloat topH = NSHeight(b) - bh - bDiv;
    _left.frame = NSMakeRect(0, 0, lw, topH);
    _center.frame = NSMakeRect(lw + lDiv, 0, MAX(0, NSWidth(b) - lw - lDiv - rw - rDiv), topH);
    _right.frame = NSMakeRect(NSWidth(b) - rw, 0, rw, topH);
    _bottom.frame = NSMakeRect(0, NSHeight(b) - bh, NSWidth(b), bh);

    _dividers[0].frame = NSMakeRect(lw, 0, lDiv, topH);
    _dividers[1].frame = NSMakeRect(NSWidth(b) - rw - rDiv, 0, rDiv, topH);
    _dividers[2].frame = NSMakeRect(0, NSHeight(b) - bh - bDiv, NSWidth(b), bDiv);

    // The editor area itself splits into the main and the sub view, with the same kind of drag handle.
    NSRect editor = _center.frame;
    if (_splitEnabled) {
        if (_splitVertical) {
            CGFloat first = MAX(0, (NSWidth(editor) - divider) * _splitPosition);
            _center.frame = NSMakeRect(NSMinX(editor), NSMinY(editor), first, NSHeight(editor));
            _secondary.frame = NSMakeRect(NSMinX(editor) + first + divider, NSMinY(editor),
                                          MAX(0, NSWidth(editor) - first - divider), NSHeight(editor));
            _dividers[3].frame = NSMakeRect(NSMinX(editor) + first, NSMinY(editor), divider, NSHeight(editor));
        } else {
            CGFloat first = MAX(0, (NSHeight(editor) - divider) * _splitPosition);
            _center.frame = NSMakeRect(NSMinX(editor), NSMinY(editor), NSWidth(editor), first);
            _secondary.frame = NSMakeRect(NSMinX(editor), NSMinY(editor) + first + divider,
                                          NSWidth(editor), MAX(0, NSHeight(editor) - first - divider));
            _dividers[3].frame = NSMakeRect(NSMinX(editor), NSMinY(editor) + first, NSWidth(editor), divider);
        }
    } else {
        _secondary.frame = NSZeroRect;
        _dividers[3].frame = NSZeroRect;
    }

    for (int i = 0; i < 4; i++) _dividers[i].hidden = NSIsEmptyRect(_dividers[i].frame);
    [_left layout]; [_right layout]; [_bottom layout];
    [self setNeedsDisplay:YES];   // the split bar is drawn below the (transparent) divider views, at their frame
    // Opening a docked panel moves the bars without resizing the window, which does not invalidate cursor rects
    // on its own — without this the resize cursor stays on the bar's old position and the hint lies.
    [self.window invalidateCursorRectsForView:self];
}

// Upstream draws the splitter as a bar with a grip, which is what says "drag me" — and, once you have tried it,
// "right-click me". Only the split bar gets it: the panel edges read as edges already.
// ponytail: a flat bar and three dots. Upstream's hover arrows that snap the split all the way open are a
// separate gesture; add them here (and in -mouseDown:) if anyone asks for them.
- (void)drawRect:(NSRect)dirty {
    NSRect bar = self.splitDividerFrame;
    if (NSIsEmptyRect(bar)) return;
    [NSColor.separatorColor setFill];
    NSRectFill(bar);
    [NSColor.tertiaryLabelColor setFill];
    for (int i = -1; i <= 1; i++) {
        NSRect dot = _splitVertical ? NSMakeRect(NSMidX(bar) - 1, NSMidY(bar) + i * 6 - 1, 2, 2)
                                    : NSMakeRect(NSMidX(bar) + i * 6 - 1, NSMidY(bar) - 1, 2, 2);
        NSRectFill(dot);
    }
}

// ---- divider dragging ----
- (void)resetCursorRects {
    [super resetCursorRects];
    if (!_dividers[0].isHidden) [self addCursorRect:_dividers[0].frame cursor:NSCursor.resizeLeftRightCursor];
    if (!_dividers[1].isHidden) [self addCursorRect:_dividers[1].frame cursor:NSCursor.resizeLeftRightCursor];
    if (!_dividers[2].isHidden) [self addCursorRect:_dividers[2].frame cursor:NSCursor.resizeUpDownCursor];
    if (!_dividers[3].isHidden)
        [self addCursorRect:_dividers[3].frame cursor:(_splitVertical ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor)];
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _dragEdge = -1;
    if (!_dividers[0].isHidden && NSPointInRect(p, _dividers[0].frame)) _dragEdge = NPPPanelEdgeLeft;
    else if (!_dividers[1].isHidden && NSPointInRect(p, _dividers[1].frame)) _dragEdge = NPPPanelEdgeRight;
    else if (!_dividers[2].isHidden && NSPointInRect(p, _dividers[2].frame)) _dragEdge = NPPPanelEdgeBottom;
    else if (!_dividers[3].isHidden && NSPointInRect(p, _dividers[3].frame)) _dragEdge = kDragSplit;
    // Upstream puts the two halves back to equal on a double-click of the splitter; nothing else in the app does.
    if (_dragEdge == kDragSplit && e.clickCount == 2) {
        _dragEdge = -1;
        self.splitPosition = 0.5;
        return;
    }
    if (_dragEdge < 0) [super mouseDown:e];
}

- (void)mouseDragged:(NSEvent *)e {
    if (_dragEdge < 0) { [super mouseDragged:e]; return; }
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    switch (_dragEdge) {
        case NPPPanelEdgeLeft: _leftW = MAX(120, p.x); break;
        case NPPPanelEdgeRight: _rightW = MAX(80, NSWidth(self.bounds) - p.x); break;
        case kDragSplit: {
            NSRect editor = NSUnionRect(_center.frame, _secondary.frame);   // both halves plus the divider gap
            CGFloat span = _splitVertical ? NSWidth(editor) : NSHeight(editor);
            CGFloat offset = _splitVertical ? p.x - NSMinX(editor) : p.y - NSMinY(editor);
            if (span > 0) self.splitPosition = offset / span;
            break;
        }
        default: _bottomH = MAX(60, NSHeight(self.bounds) - p.y); break;
    }
    [self setNeedsLayout:YES];
    [self layout];
}

- (void)mouseUp:(NSEvent *)e {
    if (_dragEdge >= 0) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setDouble:_leftW forKey:kLeftKey];
        [d setDouble:_rightW forKey:kRightKey];
        [d setDouble:_bottomH forKey:kBottomKey];
        [self.window invalidateCursorRectsForView:self];
    }
    _dragEdge = -1;
    [super mouseUp:e];
}

// ---------------------------------------------------------------------------------------------------------------
// Headless checks. A feature nobody can reach is exactly what these are for, so they assert the divider's menu
// ITEMS, not just that Rotate works — Rotate has a View-menu path, the right-click is the one people use.
// ---------------------------------------------------------------------------------------------------------------
+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *f = [NSMutableArray array];
    NPPPanelHost *host = [[NPPPanelHost alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    CGFloat savedPosition = host.splitPosition;   // -setSplitPosition: persists; leave the user's split alone
    [host layout];
    if (host.splitDividerMenu || !NSIsEmptyRect(host.splitDividerFrame))
        [f addObject:@"the split divider is live with only one view"];

    host.splitEnabled = YES;
    [host layout];
    if (NSIsEmptyRect(host.splitDividerFrame))
        [f addObject:@"a split editor has no divider to click on"];

    NSMenu *menu = host.splitDividerMenu;
    NSArray<NSString *> *wantTitles = @[@"Rotate to Right", @"Rotate to Left"];
    NSArray<NSNumber *> *wantTags = @[@(NPPCmdViewRotateRight), @(NPPCmdViewRotateLeft)];
    if (menu.numberOfItems != (NSInteger)wantTitles.count) {
        [f addObject:[NSString stringWithFormat:@"right-clicking the split divider offers %ld items, not the 2 rotate ones",
                                                (long)menu.numberOfItems]];
    } else {
        for (NSUInteger i = 0; i < wantTitles.count; i++) {
            NSMenuItem *it = [menu itemAtIndex:(NSInteger)i];
            if (![it.title isEqualToString:wantTitles[i]] || it.tag != wantTags[i].integerValue
                || it.action != @selector(nppCommand:))
                [f addObject:[NSString stringWithFormat:@"split divider menu item %lu is \"%@\" (tag %ld, action %@), not \"%@\" (tag %ld, nppCommand:)",
                                                        (unsigned long)i, it.title, (long)it.tag,
                                                        it.action ? NSStringFromSelector(it.action) : @"(none)",
                                                        wantTitles[i], (long)wantTags[i].integerValue]];
        }
    }

    // Double-click back to 50/50 needs a real window: -mouseDown: reads the point out of window coordinates.
    static NSWindow *scratch;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scratch = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
        scratch.releasedWhenClosed = NO;
    });
    [scratch.contentView addSubview:host];
    host.frame = NSMakeRect(0, 0, 800, 600);
    [host layout];
    host.splitPosition = 0.8;
    NSRect bar = host.splitDividerFrame;
    NSPoint inWindow = [host convertPoint:NSMakePoint(NSMidX(bar), NSMidY(bar)) toView:nil];
    [host mouseDown:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:inWindow modifierFlags:0
                                      timestamp:0 windowNumber:scratch.windowNumber context:nil
                                    eventNumber:0 clickCount:2 pressure:1]];
    if (fabs(host.splitPosition - 0.5) > 0.001)
        [f addObject:[NSString stringWithFormat:@"double-clicking the split divider left the split at %.2f, not 50/50",
                                                host.splitPosition]];
    [host removeFromSuperview];
    host.splitPosition = savedPosition;
    return f;
}
@end
