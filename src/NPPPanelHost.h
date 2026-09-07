// NPPPanelHost.h — the docking area around the editor, like Notepad++'s docked panels.
// Left / right / bottom edges; several panels per edge are stacked as tabs. Sizes persist in NSUserDefaults.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPPanelHost : NSView
// The editor area. The window controller puts its document container in here.
@property (nonatomic, readonly) NSView *centerView;

// Notepad++'s second edit view. The editor area splits in two with a draggable divider; the host owns the
// geometry (and persists orientation + position next to the panel sizes), the window controller owns what goes
// inside each half. Off by default: -secondaryCenterView is hidden and -centerView fills the whole area, so a
// window with one view looks exactly as it did before the split existed.
@property (nonatomic, readonly) NSView *secondaryCenterView;
@property (nonatomic) BOOL splitEnabled;
@property (nonatomic) BOOL splitVertical;                      // YES = side by side (default), NO = one above the other
@property (nonatomic) CGFloat splitPosition;                   // 0.15..0.85, the first half's share of the editor area
@property (nonatomic, copy, nullable) void (^splitDidResize)(void);   // divider dragged: re-lay out the halves' contents

// The split divider is a control, not a gap: dragging resizes, double-clicking goes back to 50/50, and
// right-clicking rotates the split — the last is the only place Notepad++ offers Rotate outside the View menu
// (SplitterContainer.cpp WM_DOPOPUPMENU). Both are readonly views onto that bar so the checks can assert it is
// really there to click on; there is no divider to reach when the editor is not split.
@property (nonatomic, readonly, nullable) NSMenu *splitDividerMenu;   // nil unless the split divider is on screen
@property (nonatomic, readonly) NSRect splitDividerFrame;             // NSZeroRect unless it is on screen

- (void)showPanel:(id<NPPPanel>)panel;      // docks (or re-selects) the panel at its preferred edge
- (void)hidePanel:(id<NPPPanel>)panel;
- (void)togglePanel:(id<NPPPanel>)panel;
- (BOOL)isPanelVisible:(id<NPPPanel>)panel;
- (NSArray<id<NPPPanel>> *)visiblePanels;
- (void)broadcastCurrentDocument:(nullable NPPDocument *)doc;   // forwards panelDidChangeCurrentDocument:
- (void)applyThemeBackground:(nullable NSColor *)background text:(nullable NSColor *)text;

+ (NSArray<NSString *> *)selfCheckFailures;   // headless regression checks, one string per failure
@end

NS_ASSUME_NONNULL_END
