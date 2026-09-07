// NPPWorkspacePanel.h — "Folder as Workspace" (N++ WinControls/FileBrowser).
// A left-edge docked NSOutlineView with one root per added folder, lazily populated, watched for changes.
// Symbolic links are listed always and descended into only when NPPPreferences.fawAllowSymlink is on
// (N++ NppGUI::_isFawSymlinkAllowed), never into a link that points back up the branch being walked.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPWorkspacePanel : NSObject <NPPPanel, NPPCommandHandler>

+ (instancetype)shared;

// Handled: NPPCmdViewWorkspacePanel (toggle, checked when visible), NPPCmdFileOpenFolderAsWorkspace.
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (NSArray<NSString *> *)selfCheckFailures;   // headless regression checks (NPPSelfTest picks these up)

// Programmatic entry points (drag & drop of a folder, "Open Folder as Workspace" from elsewhere).
- (void)addRootFolderURL:(NSURL *)url;
- (void)removeAllRoots;

// N++ FileBrowser IDM_FILEBROWSER_FINDINFILES: open NPPFindInFiles' sheet scoped to a folder
// (NPPM_LAUNCHFINDINFILESDLG). Shared with the Project Panel's "Find in Projects", so there is one
// place to change when NPPFindInFiles grows a real "open with this directory" entry point.
// NO when the folder is unusable or the command could not be delivered.
+ (BOOL)launchFindInFilesForFolderPath:(NSString *)folderPath;

@end

NS_ASSUME_NONNULL_END
