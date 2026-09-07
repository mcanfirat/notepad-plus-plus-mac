// NPPShortcutMapper.h — Notepad++ "Settings > Shortcut Mapper…" (N++ WinControls/Grid/ShortcutMapper +
// WinControls/shortcut/shortcut.cpp, persisted by Parameters.cpp as shortcuts.xml).
//
// The port has no accelerator table of its own: every shortcut IS the key equivalent of an NSMenuItem built by
// NPPAppDelegate. So this module works on the menu directly — it walks NSApp.mainMenu for the command list
// (tag + title + current key equivalent), remembers what the menu was built with, and writes user overrides back
// onto the items. Nothing else in the app has to know it exists, and macros / Run commands become bindable for
// free because their menu items carry tags like every other command.
//
// The window is upstream's: a tab per command family, the command list, Modify / Clear / Restore, and the filter
// box over the list (upstream's IDC_BABYGRID_FILTER — every whitespace-separated word has to match, else six
// hundred commands are only reachable by scrolling).
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// Singleton: owns the mapper window and the override table.
// Command owned: NPPCmdSettingsShortcutMapper. Overrides persist in NSUserDefaults under "NPPShortcutOverrides"
// as { "<command tag>": "<shortcut>" }, where "" means "this command deliberately has no shortcut".
@interface NPPShortcutMapper : NSObject <NPPCommandHandler>
+ (instancetype)shared;
- (void)showWindowWithContext:(nullable id<NPPCommandContext>)context;

// ---- shortcut strings (pure, no UI, no menu) ------------------------------------------------------------------
// Portable form is upstream's, plus Cmd: "Ctrl+Alt+Shift+Cmd+K", "Cmd+F5", "" for "no shortcut". That is what is
// persisted. Glyph form is the same thing in macOS notation: "⇧⌘K". Named keys ("F5", "Tab", "Left") stay spelled
// out in both forms.
+ (NSString *)stringForKey:(NSString *)key modifiers:(NSEventModifierFlags)mods glyphs:(BOOL)glyphs;
// Parses either form; NO for a malformed string (unknown key name, modifiers with no key, two keys).
// An empty/blank string parses as the empty key with no modifiers ("no shortcut").
+ (BOOL)parseShortcut:(NSString *)string
                  key:(NSString *_Nullable *_Nullable)outKey
            modifiers:(nullable NSEventModifierFlags *)outMods;
// Same binding, however it is spelled ("⌘K" vs "Cmd+K"). Two "no shortcut"s never conflict.
+ (BOOL)shortcut:(NSString *)a conflictsWithShortcut:(NSString *)b;
// Upstream's Shortcut::isValid(): a letter/digit/Space/Backspace/Return needs Ctrl or Alt, because a bare one is a
// character the editor has to be able to type. Same rule here over Cmd/Ctrl/Option (Shift alone is not a modifier —
// ⇧K is just K), extended to every single character and to Tab. Returns nil when the shortcut is bindable, else the
// reason it is not, ready to show. "" (no shortcut) is always bindable; a malformed string never is.
+ (nullable NSString *)problemWithShortcut:(NSString *)shortcut;

// ---- overrides ------------------------------------------------------------------------------------------------
- (nullable NSString *)overrideForTag:(NSInteger)tag;      // nil = none, @"" = cleared on purpose
- (void)setOverride:(nullable NSString *)shortcut forTag:(NSInteger)tag;   // nil removes the override
// Captures the key equivalents the menu was built with the first time it sees each tag, then puts every command's
// effective shortcut (override, else built-in default) back on its item. Idempotent; safe to call on any menu.
- (void)applyOverridesToMenu:(NSMenu *)menu;
@end

NS_ASSUME_NONNULL_END
