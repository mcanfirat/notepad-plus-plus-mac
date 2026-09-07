// NPPRunCommands.h — Notepad++'s Run menu: the Run dialog, saved commands, and the "Run output" panel.
// Port of PowerEditor/src/WinControls/StaticDialog/RunDlg (Command::run + the $(VARIABLE) expansion).
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@class NPPDocument;

// Singleton: owns the run history, the saved commands, the running NSTask and the bottom-docked output panel.
// Commands owned: NPPCmdRunDialog, NPPCmdRunModifyCommands, NPPCmdRunSavedBase + index (< NPPCmdRunSavedBase + 100).
@interface NPPRunCommands : NSObject <NPPPanel, NPPCommandHandler>
+ (instancetype)shared;

// Saved commands, in Run-menu order (NSUserDefaults key "NPPRunSavedCommands": [{name, command}]).
@property (nonatomic, readonly) NSArray<NSString *> *savedCommandNames;
- (nullable NSString *)savedCommandAtIndex:(NSInteger)index;    // the command line, nil if out of range

// Command history for the Run dialog combo box (NSUserDefaults key "NPPRunHistory", newest first, max 20).
@property (nonatomic, readonly) NSArray<NSString *> *commandHistory;

// Run one command line (variables not yet expanded). Never blocks: shell commands stream into the output panel.
- (void)runCommandLine:(NSString *)commandLine context:(id<NPPCommandContext>)context;
- (void)showRunDialogWithContext:(id<NPPCommandContext>)context;
- (void)showModifyCommandsWithContext:(id<NPPCommandContext>)context;

// $(FULL_CURRENT_PATH) & co. `shellQuote` makes each substituted value a single /bin/sh literal so a path
// with spaces or quotes can neither break nor extend the command. It respects quoting the user already
// typed: a $(VAR) inside "..." or '...' is escaped for that context, not wrapped in another pair of quotes,
// so N++'s usual `python3 "$(FULL_CURRENT_PATH)"` idiom works.
+ (NSString *)expandVariablesIn:(NSString *)source document:(nullable NPPDocument *)doc shellQuote:(BOOL)shellQuote;
+ (NSArray<NSString *> *)variableNames;   // without the "$( )" wrapper, in N++ order

// Output panel plumbing (also reachable through panelActionMenu).
- (void)clearOutput;
- (void)stopRunningTask;
@property (nonatomic, readonly) BOOL isRunning;

+ (BOOL)selfTestExpansion;   // asserts the $(VAR) parser + shell quoting; no document needed
@end

NS_ASSUME_NONNULL_END
