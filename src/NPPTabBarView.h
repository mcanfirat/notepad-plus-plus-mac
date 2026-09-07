// NPPTabBarView.h — Notepad++-style document tab strip (custom drawn, no NSTabView).
#pragma once
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class NPPTabBarView;
@protocol NPPTabBarDelegate <NSObject>
- (void)tabBar:(NPPTabBarView *)bar didSelectTabAtIndex:(NSInteger)index;
- (void)tabBar:(NPPTabBarView *)bar didRequestCloseTabAtIndex:(NSInteger)index;   // close button, middle-click, Cmd-click
- (void)tabBar:(NPPTabBarView *)bar didMoveTabFromIndex:(NSInteger)from toIndex:(NSInteger)to; // drag reorder (model must reorder too)
@optional
- (nullable NSMenu *)tabBar:(NPPTabBarView *)bar contextMenuForTabAtIndex:(NSInteger)index;
- (void)tabBar:(NPPTabBarView *)bar didDoubleClickEmptyArea:(NSPoint)point;      // N++: double-click empty tab area = new document
- (void)tabBar:(NPPTabBarView *)bar didDropFileURLs:(NSArray<NSURL *> *)urls;      // files dragged onto the tab bar
- (void)tabBarDidClickNewTab:(NPPTabBarView *)bar;                                // "+" button at the end of the strip
// The strip wants a different amount of room: the multi-line row count changed, or the vertical preference was
// toggled. The host must re-run its layout (read -preferredWidth first, then -preferredHeight) and resize the strip.
- (void)tabBarDidChangePreferredSize:(NPPTabBarView *)bar;
// Pin toggled (pin affordance or NPPCmdTabPin). The tab has already moved to its side of the pin boundary
// (didMoveTabFromIndex:toIndex: was sent first unless it was already there), so `index` is where it ended up.
// Persist the flag here.
- (void)tabBar:(NPPTabBarView *)bar didSetPinned:(BOOL)pinned forTabAtIndex:(NSInteger)index;
// Document Peeker (NPPTabPeekOnTab): text to show in the hover preview. nil/empty = no preview for that tab.
- (nullable NSString *)tabBar:(NPPTabBarView *)bar previewTextForTabAtIndex:(NSInteger)index;
// The tab's tooltip, when the delegate wants a richer one than NPPTabItem.toolTip. nil falls back to that, then
// to the title. N++ shows the full path and, for an untitled buffer, the time the tab was created
// (Buffer.h:296-306) — which is how a user tells several "new N" scratch tabs apart. The strip knows nothing
// about documents or their creation times, so the delegate writes that line.
- (nullable NSString *)tabBar:(NPPTabBarView *)bar toolTipForTabAtIndex:(NSInteger)index;
// N++ TCN_TABDROPPEDOUTSIDE: a drag ended away from the strip. `point` is in screen coordinates and `index` is
// where the tab sits now (a drag that reordered on the way out already said so). What a drop there means is the
// host's business — the strip knows nothing about documents, views or windows. Not sent for a drag that ended on
// the strip (that is an ordinary reorder) nor when the strip is locked, which forbids dragging at all.
- (void)tabBar:(NPPTabBarView *)bar didDropTabAtIndex:(NSInteger)index outsideAtScreenPoint:(NSPoint)point;
@end

@interface NPPTabItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *toolTip;     // full path
@property (nonatomic) BOOL dirty;                            // red "unsaved" indicator vs blue "saved" (N++ icons)
@property (nonatomic) BOOL readOnly;                         // grey lock indicator
@property (nonatomic, strong, nullable) NSColor *color;      // N++ tab colour 1-5 (nil = none)
@property (nonatomic) BOOL monitoring;                       // eye indicator when tail -f is on
@property (nonatomic) BOOL pinned;                            // pinned tabs stay left of the others and survive Close All but Pinned
@end

@interface NPPTabBarView : NSView
@property (nonatomic, weak) id<NPPTabBarDelegate> delegate;
@property (nonatomic, copy) NSArray<NPPTabItem *> *items;    // assigning triggers layout + redraw
@property (nonatomic) NSInteger selectedIndex;               // -1 when empty
- (void)reloadData;                                          // call after mutating an item's properties in place
- (void)scrollTabToVisible:(NSInteger)index;                 // tab strip scrolls horizontally when overflowing
- (void)togglePinnedAtIndex:(NSInteger)index;                // pin box / NPPCmdTabPin: moves the tab across the pin boundary, then notifies
- (void)showTabListMenu;                                     // drop-down of every open document (NPPCmdTabDropDownList)

// Theme colours (set by the window controller from NPPLanguageManager global styles). Sensible defaults built in.
// Under a dark theme the Dark Mode tone's palette wins over all of these except the active tab's background and
// indicator — N++ paints its chrome from NppDarkMode and ignores the styler colours there — and the strip re-reads
// it on NPPThemeDidChangeNotification, so changing the tone re-tints live. A light theme uses them as given.
@property (nonatomic, strong) NSColor *activeTabBackgroundColor;     // Default Style bg
@property (nonatomic, strong) NSColor *activeTabTextColor;           // "Active tab text" fg
@property (nonatomic, strong) NSColor *activeIndicatorColor;         // "Active tab focused indicator" fg (orange FAAA3C)
@property (nonatomic, strong) NSColor *inactiveTabBackgroundColor;   // "Inactive tabs" bg
@property (nonatomic, strong) NSColor *inactiveTabTextColor;         // "Inactive tabs" fg
@property (nonatomic, strong) NSColor *barBackgroundColor;
@property (nonatomic) BOOL showCloseButtons;                         // default YES (N++ default)
// Layout modes, all three driven by preferences the view reads itself and re-reads live (NPPTabBarVertical /
// NPPTabBarMultiLine / NPPTabBarLocked, plus NPPTabPeekOnTab for the hover preview — the peeker has no checkbox yet,
// so that defaults key is its whole UI):
//   * vertical    — one tab per row, the strip is a column down the side of the window
//   * multi-line  — tabs wrap onto as many rows as they need instead of scrolling sideways
//   * locked      — tabs cannot be dragged into a new order (dropping *files* on the strip still opens them)
// …and the six "Look and feel" ones (N++ NppGUI::_tabStatus), read the same way and applied on the spot:
//   * NPPTabBarReduce (on)                  — the short strip; off makes every row taller and the label heavier,
//                                             so the host is asked for a new size the way multi-line asks
//   * NPPTabBarAlternateIcons               — tick/pencil instead of the blue/red saved/unsaved dot
//   * NPPTabBarDrawInactiveTab (on)         — off paints inactive tabs in the active background
//   * NPPTabBarDrawTopBar (on)              — the coloured bar along the active tab
//   * NPPTabBarShowOnlyPinnedButton         — the pin affordance only on tabs that are already pinned
//   * NPPTabBarInactiveTabShowButton        — pin and close boxes on every tab, not just the active/hovered one
// A button these last two hide is not clickable either: drawing and hit-testing read one predicate.
// Height and width are the host's to set, so the strip asks for them: give it -preferredWidth as a left-hand column
// when that is non-zero, otherwise a top band -preferredHeight tall, and re-run the layout on
// -tabBarDidChangePreferredSize:.
@property (nonatomic, readonly) CGFloat preferredHeight;             // 28pt per row (multi-line grows it)
@property (nonatomic, readonly) CGFloat preferredWidth;              // 0 = keep it a top band; >0 = make it a column this wide
@property (nonatomic, readonly) BOOL vertical;                       // laid out as a column right now (preference + a frame taller than it is wide)
@property (nonatomic, readonly) NSRect newTabButtonRect;              // the "+" hit box, after the last tab
@property (nonatomic, readonly) NSRect tabListButtonRect;            // the drop-down hit box, parked at the end of the bar

+ (NSArray<NSString *> *)selfCheckFailures;                          // headless regression checks (NPPSelfTest picks it up)
@end

NS_ASSUME_NONNULL_END
