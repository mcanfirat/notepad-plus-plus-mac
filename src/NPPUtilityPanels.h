// NPPUtilityPanels.h — three small Notepad++ panels in one module:
//   * Document List      (N++ WinControls/DocumentListPanel)      — left edge
//   * Clipboard History  (N++ WinControls/ClipboardHistory)       — bottom edge
//   * Character Panel    (N++ WinControls/AnsiCharPanel)          — right edge
//
// Integration: each panel is a singleton conforming to <NPPPanel>; NPPUtilityPanels is the
// <NPPCommandHandler> owning NPPCmdViewDocumentList / NPPCmdViewClipboardHistory / NPPCmdViewCharacterPanel.
//
// The Document List borrows two things from its host (informally, by selector, so the protocol every module
// implements stays small): -viewOfDocument: for "Group by View", and -tabBar, whose delegate builds the tab
// context menu a right-clicked row shows. A host that answers neither still gets a working panel.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPDocumentListPanel : NSObject <NPPPanel>
+ (instancetype)shared;
@end

@interface NPPClipboardHistoryPanel : NSObject <NPPPanel>
+ (instancetype)shared;
@end

@interface NPPCharacterPanel : NSObject <NPPPanel>
+ (instancetype)shared;
@end

// Command dispatch for the three toggles. Register this class with the window controller.
@interface NPPUtilityPanels : NSObject <NPPCommandHandler>
@end

NS_ASSUME_NONNULL_END
