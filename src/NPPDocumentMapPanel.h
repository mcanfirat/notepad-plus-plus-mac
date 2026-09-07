// NPPDocumentMapPanel.h — Notepad++'s Document Map (WinControls/DocumentMap/documentMap.cpp).
// A second, tiny-font ScintillaView mirroring the current buffer, with a translucent viewport rectangle
// showing what the real editor displays. Click/drag/scroll in the map scrolls the editor; hovering it peeks at
// the lines under the pointer without scrolling anything (NppGUI::_isDocPeekOnMap / NPPPeekOnDocumentMap).
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPDocumentMapPanel : NSObject <NPPPanel, NPPCommandHandler>
+ (instancetype)shared;          // the window controller docks this; NPPCmdViewDocumentMap toggles it
@end

NS_ASSUME_NONNULL_END
