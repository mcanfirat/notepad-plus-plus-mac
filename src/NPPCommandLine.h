// NPPCommandLine.h — command line arguments (port of PowerEditor/src/winmain.cpp: parseCommandLine,
// stripIgnoredParams, convertParamsToNotepadStyle and the FLAG_* block) plus the two Help windows that
// document what the binary accepts (IDM_CMDLINEARGUMENTS, IDM_DEBUGINFO).
//
// The parser is pure and headless: +parseArguments: turns an argv-style array into an NPPCommandLineOptions
// and touches nothing else, which is what the self-checks exercise. +applyProcessArguments: is the one call
// main() makes; it parses, publishes the result as +current, and applies the subset of options this port can
// honour (window placement, always-on-top, read-only, monitoring, caret position, UDL/language, tab bar,
// workspace roots, quick print, ghost typing, --help).
//
// The rule that matters: EVERY switch Notepad++ documents is recognised here, including the ones the port
// cannot honour (-noPlugin, -systemtray, -pluginMessage=). A recognised switch
// is never a file name — opening a document called "-noPlugin" is the bug this file exists to prevent.
// Options recognised but not honoured land in -unsupportedNotes, one human-readable line each.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// Value of a numeric option that was not given (-n/-c/-p/-x/-y). N++ uses -1 + a "present" flag; a
// sentinel is used here instead because -x/-y are legitimately negative on a second monitor.
extern const NSInteger NPPCommandLineNoValue;

// Where the ghost typing text comes from (winmain.cpp getEasterEggNameFromParam's `type` out-parameter).
typedef NS_ENUM(NSInteger, NPPGhostTypingSource) {
    NPPGhostTypingNone = -1,    // no -qn=/-qt=/-qf= on the command line
    NPPGhostTypingBuiltIn = 0,  // -qn=<name>
    NPPGhostTypingText = 1,     // -qt=<text>
    NPPGhostTypingFile = 2,     // -qf=<path>
};

@interface NPPCommandLineOptions : NSObject

// Files to open, in command line order: the non-switch arguments, made absolute against the current directory,
// with "~" expanded, wildcards expanded when they contain one (recursively under -r) and session files
// expanded into their contents under -openSession. Duplicates are removed, order is kept.
@property (nonatomic, readonly, copy) NSArray<NSURL *> *fileURLs;
// The same arguments exactly as typed, before any expansion. Empty when only switches were given.
@property (nonatomic, readonly, copy) NSArray<NSString *> *fileArguments;
// Directories among the arguments — where -openFoldersAsWorkspace sends them. A directory is never a document,
// so these never appear in fileURLs.
@property (nonatomic, readonly, copy) NSArray<NSURL *> *folderURLs;

// ---- Flags (upstream FLAG_* constants) ----
@property (nonatomic, readonly) BOOL multiInstance;                  // -multiInst
@property (nonatomic, readonly) BOOL noSession;                      // -nosession
@property (nonatomic, readonly) BOOL noTabBar;                       // -notabbar
@property (nonatomic, readonly) BOOL readOnly;                       // -ro           (files from the command line)
@property (nonatomic, readonly) BOOL fullReadOnly;                   // -fullReadOnly (every buffer)
@property (nonatomic, readonly) BOOL savingForbidden;                // -fullReadOnlySavingForbidden
@property (nonatomic, readonly) BOOL alwaysOnTop;                    // -alwaysOnTop
@property (nonatomic, readonly) BOOL recursive;                      // -r
@property (nonatomic, readonly) BOOL openSession;                    // -openSession
@property (nonatomic, readonly) BOOL openFoldersAsWorkspace;         // -openFoldersAsWorkspace
@property (nonatomic, readonly) BOOL monitor;                        // -monitor
@property (nonatomic, readonly) BOOL monitoringMode;                 // -monitoringMode
@property (nonatomic, readonly) BOOL quickPrint;                     // -quickPrint  (also /p, /P under -notepadStyleCmdline)
@property (nonatomic, readonly) BOOL exportFunctionList;             // -export=functionList
@property (nonatomic, readonly) BOOL notepadStyleCmdline;            // -notepadStyleCmdline
@property (nonatomic, readonly) BOOL showLoadingTime;                // -loadingTime
@property (nonatomic, readonly) BOOL noPlugin;                       // -noPlugin     (recognised, not honoured)
@property (nonatomic, readonly) BOOL systemTray;                     // -systemtray   (recognised, not honoured)
@property (nonatomic, readonly) BOOL displayHelp;                    // --help

// ---- Values (nil when the switch was absent) ----
@property (nonatomic, readonly, copy, nullable) NSString *settingsDirectory;   // -settingsDir=
@property (nonatomic, readonly, copy, nullable) NSString *titleAdd;            // -titleAdd=
@property (nonatomic, readonly, copy, nullable) NSString *udlName;             // -udl=
@property (nonatomic, readonly, copy, nullable) NSString *languageName;        // -l<name>  (langs.model.xml name)
@property (nonatomic, readonly, copy, nullable) NSString *localizationCode;    // -L<code>
@property (nonatomic, readonly, copy, nullable) NSString *pluginMessage;       // -pluginMessage=

// ---- Ghost typing (-qn=, -qt=, -qf=, -qSpeed) ----
// Which of the three switches was given (the first one wins, as upstream), and its argument with the surrounding
// quotes stripped: a built-in script name, the text itself (escapes decoded), or an absolute file path.
@property (nonatomic, readonly) NPPGhostTypingSource ghostTypingSource;
@property (nonatomic, readonly, copy, nullable) NSString *ghostTypingArgument;
// 1 slow, 2 fast, 3 instant. Always one of those three: -qSpeed absent, out of range or not a number all mean 2,
// which is the speed threadTextPlayer() starts from.
@property (nonatomic, readonly) NSInteger ghostTypingSpeed;

// ---- Numbers (NPPCommandLineNoValue when absent) ----
@property (nonatomic, readonly) NSInteger line;       // -n, 1-based
@property (nonatomic, readonly) NSInteger column;     // -c, 1-based
@property (nonatomic, readonly) NSInteger position;   // -p, 0-based byte position
@property (nonatomic, readonly) NSInteger left;       // -x, screen point from the left
@property (nonatomic, readonly) NSInteger top;        // -y, screen point from the top

// ---- Diagnostics ----
// Switch-looking arguments this parser does not know. They are NOT opened as files; they land here so the
// caller can complain instead of silently creating a document named "-typo".
@property (nonatomic, readonly, copy) NSArray<NSString *> *unrecognisedArguments;
// One line per recognised-but-not-honoured option, ready to print or show in the status bar.
@property (nonatomic, readonly, copy) NSArray<NSString *> *unsupportedNotes;
// Arguments swallowed by -z (Notepad-replacement syntax) — kept for the Debug Info window, never opened.
@property (nonatomic, readonly, copy) NSArray<NSString *> *ignoredArguments;

@end


@interface NPPCommandLine : NSObject <NPPCommandHandler>

// Pure parser. `arguments` is the argument list WITHOUT argv[0] — the switches and paths only.
+ (NPPCommandLineOptions *)parseArguments:(NSArray<NSString *> *)arguments;

// What this process was launched with. Never nil; an all-defaults object until +applyProcessArguments: runs.
+ (NPPCommandLineOptions *)current;

// The single entry point for main(): pass NSProcessInfo.processInfo.arguments (argv[0] included, it is dropped).
// Parses, publishes +current, and applies what can be applied — some of it now, the rest once the main window
// exists and the command line's files are open.
+ (void)applyProcessArguments:(NSArray<NSString *> *)processArguments;

// ---- Settings directory (-settingsDir=, and Preferences ▸ Cloud & Link, which sets the same thing) ----
// N++ points its whole config folder (config.xml, session.xml, backup/) at the directory. This port's settings
// live in NSUserDefaults, so the directory holds one plist that IS the preference domain for the launch: it is
// loaded over the domain by +applyProcessArguments: before anything reads a setting, and every later change is
// mirrored back to it. The session travels with it — NPPBackupManager puts backup/ (and, through its parent,
// session.xml) inside the same directory.
//
// The directory in effect for this launch, or nil. Resolved once, at launch: a launch must not move the
// settings out from under the running app, which is also what N++ does (the cloud path takes effect at restart).
+ (nullable NSString *)effectiveSettingsDirectory;
// The rule +effectiveSettingsDirectory caches, exposed so it can be checked with real directories: -settingsDir=
// wins over the preference (as in N++, where it is the 1st priority and the cloud path the 2nd), and a path that
// is not an existing directory is ignored rather than silently created. Returns an absolute, standardised path.
+ (nullable NSString *)settingsDirectoryFromCommandLine:(nullable NSString *)commandLineValue
                                      preferenceEnabled:(BOOL)enabled
                                             preference:(nullable NSString *)preferenceValue;

// The two session decisions the app delegate follows. Both answer for this launch only (they read +current),
// and both live here so a switch that changes them is checked where the switches are parsed.
+ (BOOL)shouldRestoreSavedSession;   // NO under -nosession, and NO when the command line named files itself
+ (BOOL)shouldSaveSessionOnQuit;     // NO under -nosession (implied by -quickPrint and -export=functionList)

// -L<code>: the bundled nativeLang file a browser language code names — @"" for the built-in English,
// nil when the code matches none of them.
+ (nullable NSString *)localizationFileNameForCode:(NSString *)code;

// ---- Ghost typing (-qn=/-qt=/-qf=, at -qSpeed) ----
// The text those options resolve to, or nil with *why filled in: an unknown built-in name, an unreadable file.
// Pure — no editor, no window — which is what makes the parsing checkable headlessly.
+ (nullable NSString *)ghostTypingTextForOptions:(NPPCommandLineOptions *)options
                                          reason:(NSString *_Nullable *_Nullable)why;
// The names -qn= accepts, sorted. "random" is one of them and picks another.
+ (NSArray<NSString *> *)ghostTypingBuiltInNames;
// One delay in seconds per character of `text`, in typing order — the delay comes BEFORE its character, as in
// upstream's threadTextPlayer(). Random, like upstream: the check pins the bounds, not the draw.
+ (NSArray<NSNumber *> *)ghostTypingScheduleForText:(NSString *)text speed:(NSInteger)speed;
// Starts playing `text` into the context's current editor. NO when there is nothing to type, no editor, or a
// playback is already running — the replay must never be started twice into the same document.
+ (BOOL)startGhostTypingText:(NSString *)text speed:(NSInteger)speed context:(id<NPPCommandContext>)context;

// Help > Command Line Arguments… / Help > Debug Info… — the text and the windows that show it.
+ (NSString *)usageText;
+ (NSString *)debugInfoText;

+ (NSArray<NSString *> *)selfCheckFailures;

@end

NS_ASSUME_NONNULL_END
