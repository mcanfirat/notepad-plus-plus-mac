// NPPLanguageManager.h — port of Notepad++ language/styler machinery (Parameters.cpp + ScintillaEditView::defineDocType).
// Loads langs.model.xml (keywords, extensions, comment tokens) and stylers.model.xml / themes/*.xml (styles),
// and applies a language to a ScintillaView exactly the way N++ does (lexer, keyword lists, substyles, properties).
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const NPPThemeDidChangeNotification;

@interface NPPLanguage : NSObject
@property (nonatomic, readonly, copy) NSString *name;        // langs.model.xml name: "cpp", "javascript.js", "normal"
@property (nonatomic, readonly, copy) NSString *shortName;   // "C++"  (from N++ _langNameInfoArray)
@property (nonatomic, readonly, copy) NSString *longName;    // "C++ source file"
@property (nonatomic, readonly, copy) NSString *lexerName;   // Lexilla id: "cpp", "hypertext", "null", ...
@property (nonatomic, readonly, copy) NSArray<NSString *> *extensions;   // lowercase, no dot
@property (nonatomic, readonly, copy, nullable) NSString *commentLine;   // "//" or nil
@property (nonatomic, readonly, copy, nullable) NSString *commentStart;  // "/*" or nil
@property (nonatomic, readonly, copy, nullable) NSString *commentEnd;    // "*/" or nil
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *keywords; // "instre1"... -> words
@end

// One <WordsStyle>/<WidgetStyle>. -1 means "not set" for numeric fields (N++ STYLE_NOT_USED).
@interface NPPStyle : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger styleID;
@property (nonatomic) long fgColor;           // Scintilla BGR long or -1
@property (nonatomic) long bgColor;           // Scintilla BGR long or -1
@property (nonatomic, copy, nullable) NSString *fontName;
@property (nonatomic) NSInteger fontStyle;    // bitmask 1=bold 2=italic 4=underline, or -1
@property (nonatomic) NSInteger fontSize;     // XML point size (Windows 96dpi) or -1
@property (nonatomic, copy, nullable) NSString *keywordClass; // "instre1", "type1", "substyle3"... or nil
@end

@interface NPPLanguageManager : NSObject
+ (instancetype)shared;

// Loads Resources/langs.model.xml + stylers.model.xml from the main bundle; called once by the app delegate.
- (BOOL)loadDefaultsFromBundle:(NSBundle *)bundle error:(NSError **)error;
- (BOOL)loadLangsXML:(NSURL *)langsURL stylersXML:(NSURL *)stylersURL error:(NSError **)error;

// Themes. Names: "Default (stylers.xml)" plus the basenames of Resources/themes/*.xml (e.g. "DarkModeDefault", "Monokai").
@property (nonatomic, readonly) NSArray<NSString *> *availableThemeNames;
@property (nonatomic, readonly, copy) NSString *currentThemeName;
- (BOOL)selectThemeNamed:(NSString *)name error:(NSError **)error;  // reloads styler set; posts NPPThemeDidChangeNotification
- (BOOL)currentThemeIsDark;                                            // Default Style background luminance < 0.5
// Another folder to look for <name>.xml themes in — the user's writable themes directory, which the bundle's
// read-only Resources/themes cannot be. Added folders are searched first, so an imported theme shadows a bundled
// one of the same name. Registering the same folder twice does nothing.
- (void)addThemeSearchDirectory:(NSURL *)directory;

// Languages, in N++ "Language" menu order: "normal" first, then the rest sorted by shortName (case-insensitive).
@property (nonatomic, readonly) NSArray<NPPLanguage *> *languages;
- (nullable NPPLanguage *)languageNamed:(NSString *)name;        // by langs.model.xml name
- (NPPLanguage *)normalTextLanguage;
- (nullable NPPLanguage *)languageForFileURL:(NSURL *)url;       // by extension (case-insensitive); also exact-filename matches like "makefile", "CMakeLists.txt"
- (nullable NPPLanguage *)languageForFirstLine:(NSData *)head;   // port of FileManager::detectLanguageFromTextBeginning (shebang: sh/python/perl/php/ruby/node; "<?xml", "<?php", "<html", "<!DOCTYPE html", "<svg")

// Apply. Does exactly what N++ defineDocType does for this language: Default Style + STYLECLEARALL, global styles,
// SCI_SETILEXER via Lexilla CreateLexer(lexerName), every WordsStyle of the LexerType, keyword lists on the right
// SCI_SETKEYWORDS indexes (per-language mapping from ScintillaEditView set*Lexer), substyles via SCI_ALLOCATESUBSTYLES /
// SCI_SETIDENTIFIERS, and the per-lexer SCI_SETPROPERTY calls ("fold", "fold.compact", "lexer.cpp.track.preprocessor", ...).
// Font: XML fontName is used if installed, else NPPDefaultMonospaceFontName(); XML size is converted 96dpi->72dpi (x1.333, rounded).
// If overrideFontName/overrideFontSize (from preferences) are set (non-nil / >0) they replace the Default Style font.
- (void)applyLanguage:(NPPLanguage *)language toEditor:(ScintillaView *)editor;
- (void)applyGlobalStylesToEditor:(ScintillaView *)editor;  // everything in <GlobalStyles>: default style, line numbers, current line, caret, selection, edge, indent guides, brace styles, fold margin/markers, whitespace color, mark styles 1-5 (indicators 21-25), find mark (31), smart highlight (29), incremental (28), tag match (27/26), bookmark margin, URL hover, EOL color
@property (nonatomic, copy, nullable) NSString *overrideFontName;
@property (nonatomic) CGFloat overrideFontSize;

// Accessors used by the UI for theming (tab bar, status bar). Return nil when the theme has no such style/color.
//
// Dark Mode tones (preferences: darkModeTone + the 12 darkModeCustom* colours; N++ NppDarkMode.cpp). The tone's
// palette is derived the way NppDarkMode derives it — the black base plus the tone's RGB offset, the customised
// colours replacing it outright — and published here as twelve extra global styles, each carrying its one colour
// in both fg and bg:
//     "Dark mode background"        "Dark mode softer background"  "Dark mode hot background"
//     "Dark mode pure background"   "Dark mode error background"   "Dark mode text"
//     "Dark mode darker text"       "Dark mode disabled text"      "Dark mode link text"
//     "Dark mode edge"              "Dark mode hot edge"           "Dark mode disabled edge"
// The same tone is also applied as a tint to a dark theme's own surfaces — its near-neutral dark greys plus every
// shade within 0x20 a channel of its Default Style background, which is what carries the hued dark themes
// (Solarized, Ruby Blue, vim Dark Blue) — so the tone shows up in everything already reading "Default Style" /
// "Inactive tabs" / a lexer style. Markers, indicators, syntax colours and every foreground are left alone; a
// light theme is never toned at all. Changing any of those preferences
// re-derives both and posts NPPThemeDidChangeNotification; the default (Black) tone is a strict no-op, so every
// theme keeps exactly the colours it was parsed with.
- (nullable NPPStyle *)globalStyleNamed:(NSString *)name;    // e.g. "Default Style", "Inactive tabs", "Active tab focused indicator"
- (nullable NSColor *)globalForegroundColorNamed:(NSString *)name;
- (nullable NSColor *)globalBackgroundColorNamed:(NSString *)name;

+ (NSArray<NSString *> *)selfCheckFailures;   // headless regression checks (NPPSelfTest picks it up)
@end

NS_ASSUME_NONNULL_END
