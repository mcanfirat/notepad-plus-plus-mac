// NPPStatusBarView.h — Notepad++ status bar: doc type | length/lines | Ln/Col/Pos/Sel | EOL | encoding | INS/OVR
#pragma once
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NPPStatusBarView : NSView
@property (nonatomic, copy) NSString *docTypeText;      // "C++ source file"
@property (nonatomic, copy) NSString *docSizeText;      // "length : 1,234    lines : 56"
@property (nonatomic, copy) NSString *cursorText;       // "Ln : 12    Col : 4    Pos : 345    Sel : 0 | 0" (N++ format)
@property (nonatomic, copy) NSString *eolText;          // "Unix (LF)"
@property (nonatomic, copy) NSString *encodingText;     // "UTF-8"
@property (nonatomic, copy) NSString *insertModeText;   // "INS" / "OVR"

// Clicking a field pops up its menu (N++: right-click on EOL/encoding/language fields). Menus are owned by the window controller.
@property (nonatomic, strong, nullable) NSMenu *docTypeMenu;   // Language menu
@property (nonatomic, strong, nullable) NSMenu *eolMenu;
@property (nonatomic, strong, nullable) NSMenu *encodingMenu;
@property (nonatomic, copy, nullable) void (^insertModeClicked)(void);   // toggles overtype

// Theming. Under a dark theme the Dark Mode tone's palette (NPPLanguageManager's "Dark mode background" / "…text"
// / "…edge") wins over both of these and the bar re-reads it on NPPThemeDidChangeNotification, the way N++ paints
// its status bar from NppDarkMode rather than from the styler colours. A light theme uses them as given.
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *textColor;
@property (nonatomic, readonly) CGFloat preferredHeight;   // ~22pt

+ (NSArray<NSString *> *)selfCheckFailures;   // headless regression checks (run from NPPTabBarView's, which NPPSelfTest knows about)
@end

NS_ASSUME_NONNULL_END
