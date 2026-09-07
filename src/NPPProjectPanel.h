// NPPProjectPanel.h — N++'s three Project Panels (WinControls/ProjectPanel).
// Each panel is an independent workspace: one .xml workspace file holding projects > folders > files,
// written in Notepad++'s exact format so a workspace made here opens on Windows.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPProjectPanel : NSObject <NPPPanel, NPPCommandHandler>

// index 0..2 -> "Project Panel 1/2/3". Out-of-range returns panel 0.
+ (instancetype)panelAtIndex:(NSInteger)index;

// Set by performCommand:; the integrator may also set it directly right after -panelAtIndex:
// so a panel restored at launch can open files before any command runs.
@property (nonatomic, weak, nullable) id<NPPCommandContext> commandContext;

// Handled: NPPCmdViewProjectPanel1/2/3 (toggle, checked when visible).
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context;

// Programmatic entry points.
- (BOOL)openWorkspaceURL:(NSURL *)url;      // NO if it is not a valid N++ workspace file
- (BOOL)saveWorkspace;                       // asks for a path when the workspace has none
- (BOOL)hasUnsavedChanges;

@end

NS_ASSUME_NONNULL_END
