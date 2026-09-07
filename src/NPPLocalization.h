// NPPLocalization.h — the UI language of the main menu, from Notepad++'s own translations.
//
// Notepad++ ships ~90 XML translations in PowerEditor/installer/nativeLang. Each one keys every menu string
// by the Win32 resource id of the item (IDM_FILE_NEW = 41001, …), plus symbolic ids for the twelve top-level
// menus (<Entries menuId="file">) and the submenus (<SubEntries subMenuId="edit-insert">).
//
// This port's NPPCmd tags are not those IDM_ ids and never will be, so the two sides are joined the only way
// that survives either of them changing: by menu STRUCTURE (a submenu is looked up among <SubEntries>, a leaf
// among <Commands>) and by the English title, matched against english.xml. NPPLocalization.mm keeps the
// exception table for the handful of titles the port words differently. Anything that cannot be matched keeps
// its English title — a menu item is never blanked.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// One entry of the Settings ▸ UI Language submenu.
@interface NPPUILanguage : NSObject
@property (nonatomic, copy, readonly) NSString *fileName;      // "french.xml"; @"" is the built-in English
@property (nonatomic, copy, readonly) NSString *displayName;   // what the translation calls itself: "Français"
@end

// <NPPCommandHandler> for NPPCmdSettingsUILanguageBase + index into -availableLanguages.
@interface NPPLocalization : NSObject <NPPCommandHandler>
+ (instancetype)shared;

// Index 0 is always English (no translation file); the rest are the bundled nativeLang XMLs, by native name.
@property (nonatomic, readonly) NSArray<NPPUILanguage *> *availableLanguages;
// The chosen translation's file name, @"" for English. Persisted under "NPPUILanguageFileName";
// setting it re-titles the live main menu.
@property (nonatomic, copy) NSString *currentFileName;

// menu id -> translated title, for one nativeLang file. Keys are the raw XML ids: "41001" for a command,
// "file" for a top-level menu, "edit-insert" for a submenu. Values are ready for display (Win32 "&"
// accelerator markers removed, "&&" folded back to "&"). nil when the file cannot be read.
- (nullable NSDictionary<NSString *, NSString *> *)stringsForFileNamed:(NSString *)fileName;
// Re-titles `menu` and its submenus in place. nil strings restores the English titles.
- (void)applyStrings:(nullable NSDictionary<NSString *, NSString *> *)strings toMenu:(NSMenu *)menu;
@end

NS_ASSUME_NONNULL_END
