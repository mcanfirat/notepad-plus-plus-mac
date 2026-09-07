// NPPMacroManager.h — Notepad++'s Macro menu: record / stop / playback / save / run-multiple / modify-delete.
// Mirrors N++ Notepad_plus::macroPlayback, recordedMacroStep (WinControls/shortcut/shortcut.h) and RunMacroDlg.
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// One recorded Scintilla command (N++ recordedMacroStep). `text` non-nil == N++ mtUseSParameter:
// lParam is a C string and is passed as text.UTF8String at playback.
@interface NPPMacroStep : NSObject
@property (nonatomic, readonly) int message;
@property (nonatomic, readonly) uptr_t wParam;
@property (nonatomic, readonly) sptr_t lParam;
@property (nonatomic, readonly, copy, nullable) NSString *text;
- (instancetype)initWithMessage:(int)message wParam:(uptr_t)w lParam:(sptr_t)l text:(nullable NSString *)text;
- (void)playOnEditor:(ScintillaView *)editor;
@end

@interface NPPMacroManager : NSObject <NPPCommandHandler>

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) BOOL hasRecordedMacro;                       // "current recorded macro" exists
@property (nonatomic, readonly, copy) NSArray<NSString *> *savedMacroNames;  // index == NPPCmdMacroSavedBase offset

// Playback. `times` < 1 is treated as 1. Returns NO on a bad index / nil editor.
- (BOOL)playSavedMacroAtIndex:(NSInteger)i onEditor:(ScintillaView *)ed times:(NSInteger)n;
- (BOOL)playCurrentMacroOnEditor:(ScintillaView *)ed times:(NSInteger)n;
- (BOOL)playMacroSteps:(NSArray<NPPMacroStep *> *)steps onEditor:(ScintillaView *)ed untilEndOfFileFromEditor:(BOOL)untilEOF times:(NSInteger)n;

// Handled: NPPCmdMacroStartRecording, NPPCmdMacroStopRecording, NPPCmdMacroPlayback, NPPCmdMacroSaveCurrent,
// NPPCmdMacroRunMultiple, NPPCmdMacroModifyShortcuts, and NPPCmdMacroSavedBase + index (< NPPCmdMacroSavedBase + 100).
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (nullable NSString *)dynamicTitleForCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;   // saved macro name

@end

NS_ASSUME_NONNULL_END
