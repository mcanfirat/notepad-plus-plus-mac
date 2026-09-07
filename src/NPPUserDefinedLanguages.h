// NPPUserDefinedLanguages.h — User Defined Languages (UDL).
// Port of Notepad++ UserLangContainer (Parameters.cpp feedUserLang/insertUserLang2Tree),
// ScintillaEditView::setUserLexer() and WinControls/.../UserDefineDialog.
//
// Registry:  bundled read-only samples from <bundle>/Contents/Resources/userDefineLangs/*.xml
//            plus the user's own ~/Library/Application Support/Notepad++/userDefineLangs/*.xml.
// Apply:     -applyUserLanguageNamed:toEditor: reproduces setUserLexer() exactly (Lexilla "user" lexer,
//            userDefine.* properties, 15 SCI_SETKEYWORDS lists, per-style nesting + colours/font).
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#import "NPPCommands.h"
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@class NPPDocument;

// SCE_USER_KWLIST_* count / SCE_USER_TOTAL_KEYWORD_GROUPS / SCE_USER_STYLE_TOTAL_STYLES (SciLexer.h).
enum { NPPUDLKeywordListCount = 28, NPPUDLKeywordGroupCount = 8, NPPUDLStyleCount = 24 };

// N++ Style, restricted to what a <WordsStyle> of a UDL carries. -1 == "not set" (STYLE_NOT_USED).
@interface NPPUserStyle : NSObject <NSCopying>
@property (nonatomic) NSInteger styleID;                       // SCE_USER_STYLE_*
@property (nonatomic, copy) NSString *name;                    // "KEYWORDS1", "DELIMITERS3", ...
@property (nonatomic) long fgColor;                            // Scintilla BGR long
@property (nonatomic) long bgColor;
@property (nonatomic) NSInteger colorStyle;                    // 0 none, 1 fg, 2 bg, 3 both (default 3)
@property (nonatomic, copy, nullable) NSString *fontName;      // empty/nil = inherit
@property (nonatomic) NSInteger fontStyle;                     // bitmask 1=bold 2=italic 4=underline, -1 = unset
@property (nonatomic) NSInteger fontSize;                      // XML point size (Windows 96dpi), -1 = unset
@property (nonatomic) NSInteger nesting;                       // SCE_USER_MASK_NESTING_* bitmask
@end

// One <UserLang>.
@interface NPPUserLanguage : NSObject <NSCopying>
@property (nonatomic, copy) NSString *name;                    // unique; shown in the Language menu
@property (nonatomic, copy) NSString *ext;                     // space-separated, no dots ("md markdown")
@property (nonatomic, copy) NSString *udlVersion;              // "2.1"
@property (nonatomic) BOOL isDarkModeTheme;
@property (nonatomic) BOOL isCaseIgnored;
@property (nonatomic) BOOL allowFoldOfComments;
@property (nonatomic) BOOL foldCompact;
@property (nonatomic) NSInteger forcePureLC;                   // 0 = anywhere, 1 = at BOL, 2 = preceding whitespace
@property (nonatomic) NSInteger decimalSeparator;              // 0 = dot, 1 = comma, 2 = both
@property (nonatomic, readonly, nullable) NSURL *sourceURL;    // file it was read from
@property (nonatomic, readonly) BOOL isEditable;               // NO for the bundled samples

- (NSString *)keywordListAtIndex:(NSInteger)index;             // SCE_USER_KWLIST_*; "" when unset
- (void)setKeywordList:(nullable NSString *)list atIndex:(NSInteger)index;
- (BOOL)isPrefixForKeywordGroup:(NSInteger)group;              // 0..7 == Keywords1..8
- (void)setPrefix:(BOOL)prefix forKeywordGroup:(NSInteger)group;
- (NPPUserStyle *)styleForID:(NSInteger)styleID;               // never nil; created with defaults on demand
- (NSArray<NPPUserStyle *> *)styles;                           // ordered by styleID
- (NSArray<NSString *> *)extensions;                           // lowercase, no dots
@end

@interface NPPUserDefinedLanguages : NSObject <NPPCommandHandler>
+ (instancetype)shared;

// Menu order == the NPPCmdLangUserDefinedBase offset (sorted case-insensitively by name).
@property (nonatomic, readonly) NSArray<NSString *> *languageNames;
@property (nonatomic, readonly) NSArray<NPPUserLanguage *> *userLanguages;
- (nullable NPPUserLanguage *)userLanguageNamed:(NSString *)name;
- (void)reload;                                                 // re-scan bundle + Application Support

// The port of ScintillaEditView::setUserLexer(). NO when `name` is unknown or `ed` is nil.
- (BOOL)applyUserLanguageNamed:(NSString *)name toEditor:(nullable ScintillaView *)ed;

// Language auto-detection by extension (case-insensitive), for the window controller's open path.
- (nullable NSString *)userLanguageNameForFileURL:(nullable NSURL *)url;

// Which UDL a buffer is currently displaying (nil = none). The assignment is dropped as soon as the
// document's NPPLanguage changes under us (i.e. the user picked a built-in language).
- (nullable NSString *)userLanguageNameForDocument:(nullable NPPDocument *)doc;
- (BOOL)assignUserLanguageNamed:(nullable NSString *)name toDocument:(nullable NPPDocument *)doc; // applies + remembers
- (BOOL)reapplyUserLanguageToDocument:(nullable NPPDocument *)doc;   // after a theme/preferences re-style; NO if none assigned

// Import/export (NSOpenPanel/NSSavePanel wrappers live in the command handler).
- (BOOL)importUDLFromURL:(NSURL *)url error:(NSError **)error;                       // validates + copies into Application Support
- (BOOL)exportUserLanguageNamed:(NSString *)name toURL:(NSURL *)url error:(NSError **)error;
- (BOOL)saveUserLanguage:(NPPUserLanguage *)lang error:(NSError **)error;            // writes N++-compatible XML back
// Deletes it (and its file, if it was alone). Open buffers displaying it fall back to their built-in language:
// a buffer holds its UDL by name, so leaving them on a deleted one would leave live syntax colouring with nothing
// behind it. Renaming (the define dialog) moves them to the new name instead.
- (BOOL)removeUserLanguageNamed:(NSString *)name error:(NSError **)error;
- (NSURL *)userLanguageDirectory;                                                     // ~/Library/Application Support/Notepad++/userDefineLangs

// Modeless "Define your language..." window (NPPCmdLangDefineDialog).
- (void)showDefineDialogWithContext:(nullable id<NPPCommandContext>)context;
@end

NS_ASSUME_NONNULL_END
