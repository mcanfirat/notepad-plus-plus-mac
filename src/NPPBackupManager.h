// NPPBackupManager.h — periodic snapshots of unsaved work, crash recovery, and backup-on-save.
// Mirrors N++ Parameters.h (NppGUI::isSnapshotMode, _snapshotBackupTiming = 7000 ms, _backup with
// bak_none/bak_simple/bak_verbose, _backupDir), ScintillaComponent/Buffer.cpp FileManager::backupCurrentBuffer
// and NppIO.cpp Notepad_plus::fileSave.
//
// SNAPSHOTS — every `snapshotInterval` seconds (and on every tab switch, throttled) each dirty buffer is written to
//     ~/Library/Application Support/Notepad++/backup/<name>@<yyyy-MM-dd_HHmmss>
// and an index (backup/index.plist) records per snapshot: the original file path (absent = untitled), the buffer
// name, and when it was written.
// A snapshot file is removed only when its buffer was saved, closed, or restored — never otherwise; a buffer that
// grows past 64 MB simply stops being re-snapshotted and keeps the last one (N++ stops at its 200 MB large-file mark).
//
// SNAPSHOT MODE (-snapshotModeInForce, N++ NppGUI::isSnapshotMode: the preference AND "remember the last session"
// AND no -nosession) is what decides how a quit ends, and there are exactly two endings:
//   * in force — the quit does not ask about anything (NPPEditorWindowController skips its prompt, upstream does the
//     same). Every dirty buffer, untitled ones included, is snapshotted one last time and the index is left on disk
//     marked `cleanQuit`; the next launch restores them silently, as part of the session. This is what makes an
//     unsaved "new 1" still be there tomorrow morning.
//   * off, or a snapshot that could not be written — the quit prompts per file as it always did, and *this run's*
//     snapshots are spent: they and their index entries are deleted on the way out. Entries an earlier quit left
//     behind and this run never consumed are written back with the marker they arrived with, so passing through
//     with snapshots off (or under -nosession) cannot make the launch after it claim a crash.
// So the index tells the next launch which of three things happened: no index = a quit with nothing to keep;
// `cleanQuit` = the buffers below were kept on purpose, restore them without a word; no marker (which is also the
// shape older versions wrote) = the run died, ask once before re-opening anything.
//
// INDEX FILE (backup/index.plist), version 2:  { "cleanQuit": <bool>, "entries": [ <entry>, … ] }
//   version 1 — a bare array of entries — is still read, and still means "the previous run crashed".
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
@property (nonatomic, readonly) NSUInteger pendingRestoreCount;           // buffers the previous run left behind
// N++ NppGUI::isSnapshotMode(): snapshotEnabled && NPPPreferences.rememberLastSession && no -nosession this run.
// The one copy of the predicate — the window controller asks it rather than keeping a second one that could drift.
@property (nonatomic, readonly) BOOL snapshotModeInForce;

- (void)takeSnapshotsNow;                                                 // one snapshot pass (what the timer does)
// The quit gate. YES = snapshot mode is in force AND every dirty buffer in `documents` is on disk, byte for byte,
// so the caller must NOT prompt: the buffers come back at the next launch. NO = ask about them as before, and the
// snapshots stop counting as the surviving copy (they are deleted at termination, as they always were).
- (BOOL)snapshotDocumentsBeforeQuit:(NSArray<NPPDocument *> *)documents;
- (NSInteger)restorePendingWithContext:(id<NPPCommandContext>)context;    // re-opens the previous run's buffers; returns how many

// Handled: NPPCmdBackupOpenFolder (always available), NPPCmdBackupRestoreNow (disabled with nothing to restore).
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (nullable NSString *)dynamicTitleForCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (NSArray<NSString *> *)selfCheckFailures;

@end

NS_ASSUME_NONNULL_END
