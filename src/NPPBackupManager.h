// NPPBackupManager.h — periodic snapshots of unsaved work, crash recovery, and backup-on-save.
// Mirrors N++ Parameters.h (NppGUI::isSnapshotMode, _snapshotBackupTiming = 7000 ms, _backup with
// bak_none/bak_simple/bak_verbose, _backupDir), ScintillaComponent/Buffer.cpp FileManager::backupCurrentBuffer
// and NppIO.cpp Notepad_plus::fileSave.
//
// SNAPSHOTS — every `snapshotInterval` seconds (and on every tab switch, throttled) each dirty buffer is written to
//     ~/Library/Application Support/Notepad++/backup/<name>@<yyyy-MM-dd_HHmmss>
// and an index (backup/index.plist) records per snapshot: the original file path (absent = untitled), the buffer
// name, and when it was written. The index is cleared when the app terminates normally, so an index still present
// at the next launch means the previous run died — the user is asked once and those buffers are re-opened with
// their snapshot text (file-backed: open the file, then re-apply the snapshot; untitled: a new buffer).
// A snapshot file is removed only when its buffer was saved, closed, or restored — never otherwise; a buffer that
// grows past 64 MB simply stops being re-snapshotted and keeps the last one (N++ stops at its 200 MB large-file mark).
//
// BACKUP ON SAVE (off by default, like N++) copies the *previous* version of the file before it is overwritten:
//   simple  -> <file>.bak next to the file
//   verbose -> <name>.<yyyy-MM-dd_HHmmss>.bak in the custom backup directory, or in nppBackup/ next to the file
//
// INACCESSIBLE SESSION FILES — Preferences ▸ Backup ▸ "Remember inaccessible files from a past session"
// (NPPKeepSessionAbsentFileEntries, N++ NppGUI::_keepSessionAbsentFileEntries, default off). The window controller
// and the app delegate drop a session entry whose file has gone; with this on, each one is re-added after they are
// done as an empty read-only buffer carrying the path, so the next quit writes the entry out again.
//
// SETTINGS live in NSUserDefaults:
//   NPPBackupSnapshotEnabled   BOOL      default YES
//   NPPBackupSnapshotInterval  seconds   default 7      (N++ _snapshotBackupTiming = 7000 ms)
//   NPPBackupMode              0/1/2     default 0      (none / simple / verbose)
//   NPPBackupDirectory         path      default ""     ("" = beside the saved file)
// ponytail: no preferences pane — there is no menu command for one, and NPPPreferences is not ours to edit.
// The properties below are the seam a pane would bind to; `defaults write com.notepad-plus-plus.mac NPPBackupMode 1`
// works meanwhile.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// N++ BackupFeature (Parameters.h).
typedef NS_ENUM(NSInteger, NPPBackupMode) {
    NPPBackupModeNone = 0,     // bak_none
    NPPBackupModeSimple,       // bak_simple
    NPPBackupModeVerbose,      // bak_verbose
};

@interface NPPBackupManager : NSObject <NPPCommandHandler>

+ (instancetype)shared;

// Settings (NSUserDefaults-backed; setting snapshotEnabled/snapshotInterval reschedules the timer).
@property (nonatomic) BOOL snapshotEnabled;
@property (nonatomic) NSTimeInterval snapshotInterval;                    // clamped to 1 s … 1 h
@property (nonatomic) NPPBackupMode backupMode;
@property (nonatomic, copy, nullable) NSString *customBackupDirectory;    // nil/"" = next to the saved file

@property (nonatomic, readonly) NSURL *snapshotDirectory;                 // …/Notepad++/backup (created by the first write)
@property (nonatomic, readonly) NSUInteger pendingRestoreCount;           // > 0 == the previous run did not shut down cleanly

- (void)takeSnapshotsNow;                                                 // one snapshot pass (what the timer does)
- (NSInteger)restorePendingWithContext:(id<NPPCommandContext>)context;    // re-opens the crashed run's buffers; returns how many

// Handled: NPPCmdBackupOpenFolder (always available), NPPCmdBackupRestoreNow (disabled with nothing to restore).
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (nullable NSString *)dynamicTitleForCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (NSArray<NSString *> *)selfCheckFailures;

@end

NS_ASSUME_NONNULL_END
