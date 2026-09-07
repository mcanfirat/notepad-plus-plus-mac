// NPPFeatureProtocols.h — the seams between the main window and the optional feature modules
// (panels, macros, Run commands, Find in Files, user-defined languages).
//
// A feature module never talks to NPPEditorWindowController directly: it receives an id<NPPCommandContext>
// and, when it shows UI, publishes an id<NPPPanel> that the window controller docks.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPCommands.h"

NS_ASSUME_NONNULL_BEGIN

@class NPPDocument;
@class ScintillaView;

// Posted by the main window controller once it is usable; the object is the id<NPPCommandContext>.
// A feature module that needs a context outside command dispatch (a timer, a Scintilla notification hook)
// observes this from +load and keeps a weak reference.
extern NSNotificationName const NPPCommandContextReadyNotification;
// Posted (object = the same context) whenever the current document changes.
extern NSNotificationName const NPPCurrentDocumentDidChangeNotification;

typedef NS_ENUM(NSInteger, NPPPanelEdge) {
    NPPPanelEdgeLeft = 0,     // workspace, project panels, function list
    NPPPanelEdgeRight,        // document map, character panel
    NPPPanelEdgeBottom,       // search results, clipboard history, document list
};

// A dockable panel. The host owns placement, the panel owns its content.
@protocol NPPPanel <NSObject>
@property (nonatomic, readonly) NSString *panelTitle;          // shown in the panel's title bar / tab
@property (nonatomic, readonly) NSView *panelView;             // created lazily by the module; kept alive by it
@property (nonatomic, readonly) NPPPanelEdge panelPreferredEdge;
@optional
@property (nonatomic, readonly) CGFloat panelPreferredSize;    // width for left/right, height for bottom (default 240 / 180)
- (void)panelDidChangeCurrentDocument:(nullable NPPDocument *)doc;   // broadcast on every tab switch and metadata change
- (void)panelDidBecomeVisible;
- (void)panelWillHide;
- (nullable NSMenu *)panelActionMenu;                          // shown behind the ⚙ button in the panel header
@end

// Services a feature module may use. NPPEditorWindowController implements this.
@protocol NPPCommandContext <NSObject>
- (nullable NPPDocument *)contextCurrentDocument;
- (NSArray<NPPDocument *> *)contextOpenDocuments;
- (NSWindow *)contextWindow;
- (nullable NPPDocument *)contextOpenFileURL:(NSURL *)url;                       // opens or activates a tab
- (void)contextRevealFileURL:(NSURL *)url line:(NSInteger)line;                   // open + go to line (1-based; 0 = leave caret)
- (void)contextSelectDocument:(NPPDocument *)doc;
- (void)contextTogglePanel:(id<NPPPanel>)panel;                                   // show if hidden, hide if shown
- (void)contextShowPanel:(id<NPPPanel>)panel;
- (BOOL)contextPanelIsVisible:(id<NPPPanel>)panel;
- (void)contextRefreshUI;                                                          // status bar + window title + menus
- (void)contextReportStatus:(NSString *)message isError:(BOOL)isError;            // brief message in the status bar
@end

// Uniform command entry point. Modules that own NPPCmd tags implement these as class methods; the window
// controller asks each registered handler in turn. A handler must return NO from canPerform… (menu item is
// disabled) rather than silently ignoring a command it cannot run right now.
@protocol NPPCommandHandler <NSObject>
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
@optional
+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
// Headless checks contributed by a feature module: return one string per failure, empty when all pass.
// NPPSelfTest calls this on every registered handler, so a module can ship its own regression checks
// without every module editing the one shared test file.
+ (NSArray<NSString *> *)selfCheckFailures;
+ (nullable NSString *)dynamicTitleForCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;   // e.g. "Playback (3 steps)"
@end

NS_ASSUME_NONNULL_END
