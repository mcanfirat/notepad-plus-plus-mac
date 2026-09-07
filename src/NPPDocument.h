// NPPDocument.h — one open buffer (N++ Buffer + file I/O). Owns its ScintillaView.
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#import "NPPLanguageManager.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NPPEncoding) {
    NPPEncodingANSI = 0,   // 8-bit code page; see -codepage (N++ uni8Bit)
    NPPEncodingUTF8,       // UTF-8 without BOM (N++ uniCookie)
    NPPEncodingUTF8BOM,    // UTF-8 with BOM (N++ uniUTF8)
    NPPEncodingUTF16LE,    // with BOM
    NPPEncodingUTF16BE,    // with BOM
};

typedef NS_ENUM(NSInteger, NPPEOL) {
    NPPEOLWindows = 0,     // SC_EOL_CRLF
    NPPEOLMac = 1,         // SC_EOL_CR
    NPPEOLUnix = 2,        // SC_EOL_LF
};

@class NPPDocument;
@protocol NPPDocumentDelegate <NSObject>
- (void)documentDidChangeDirtyState:(NPPDocument *)doc;          // SCN_SAVEPOINTREACHED/LEFT
- (void)documentDidUpdateUI:(NPPDocument *)doc;                  // SCN_UPDATEUI (caret/selection/scroll) -> status bar
- (void)documentDidChangeMetadata:(NPPDocument *)doc;            // language / encoding / EOL / path / read-only changed
- (void)documentFileDidChangeOnDisk:(NPPDocument *)doc;          // monitoring or modification detected on activation
- (void)documentDidZoom:(NPPDocument *)doc;                      // SCN_ZOOM
- (void)document:(NPPDocument *)doc didReceiveDroppedFileURLs:(NSArray<NSURL *> *)urls;   // SCN_URIDROPPED (files dropped on the editor)
@end

// Charset table used by Encoding > Character sets (menu) and for ANSI decoding. Every entry N++ has is here:
// the two CoreFoundation cannot convert (OEM 720 Arabic, OEM 858 = 850 + euro — CF's kCFStringEncodingDOSArabic
// is code page *864*) carry an id private to NPPDocument.mm, which converts those two itself. Handing such an id
// to CFStringConvertEncodingToNSStringEncoding gives kCFStringEncodingInvalidId, so anything outside this pair
// of files that converts bytes by hand should keep its "CF does not know this one" fallback.
@interface NPPCharset : NSObject
@property (nonatomic, readonly, copy) NSString *ianaName;       // "windows-1254"
@property (nonatomic, readonly, copy) NSString *displayName;    // "Windows-1254"
@property (nonatomic, readonly, copy) NSString *groupName;      // "Turkish"
@property (nonatomic, readonly) CFStringEncoding cfEncoding;
+ (NSArray<NPPCharset *> *)allCharsets;                         // ordered by group then name; index == NPPCmdEncodingCharsetBase offset
+ (nullable NPPCharset *)charsetForIANAName:(NSString *)name;   // case-insensitive
+ (nullable NPPCharset *)charsetForCFEncoding:(CFStringEncoding)enc;
@end

// Posted just before the buffer is written to disk; the object is the NPPDocument and userInfo[@"url"] the
// destination. Feature modules (the backup manager) hook saving through this instead of swizzling.
extern NSNotificationName const NPPDocumentWillSaveNotification;

@interface NPPDocument : NSObject <ScintillaNotificationProtocol>

// One byte of an 8-bit code page as text, for anything that shows a code page byte by byte (the Character
// panel). Handles the two code pages CoreFoundation has no converter for (OEM 720, OEM 858) and falls
// back to CF for the rest; nil when the byte has no character in that code page.
+ (nullable NSString *)stringForByte:(unsigned char)byte codepage:(CFStringEncoding)codepage;

// When this buffer was created. Untitled tabs all read "new N", so their tooltip shows this to tell them
// apart (upstream Buffer::_tabCreatedTimeString).
@property (nonatomic, readonly) NSDate *createdDate;
@property (nonatomic, readonly, strong) ScintillaView *editor;
@property (nonatomic, weak) id<NPPDocumentDelegate> delegate;

@property (nonatomic, copy, nullable) NSURL *fileURL;            // nil for untitled
@property (nonatomic, readonly, copy) NSString *displayName;    // last path component, else -contentDerivedTabName, else "new 1"
// N++ NewDocDefaultSettings::_useContentAsTabName (Preferences > New Document): while that is on, an untitled
// buffer is named after the first line of its content, recomputed from SCN_MODIFIED. nil when the preference is
// off, the buffer has a file, or the first line normalises away; when another open buffer already shows the name
// the rename is refused and the buffer keeps the one it had (upstream does the same).
// -displayName prefers it, so the tab bar and the window title pick it up without asking.
@property (nonatomic, readonly, copy, nullable) NSString *contentDerivedTabName;
@property (nonatomic, readonly) BOOL isUntitled;
@property (nonatomic, readonly) BOOL isDirty;                    // SCI_GETMODIFY
@property (nonatomic) BOOL isReadOnly;                           // user toggled; applies SCI_SETREADONLY
// Live: the file's writability is asked of the filesystem, not remembered from load time. N++ re-checks it while
// the buffer is open (Buffer::checkFileState) so a file that turns read-only under you locks the editor; the port
// re-checks whenever the app comes to the front and before every save.
@property (nonatomic, readonly) BOOL isFileReadOnlyOnDisk;
@property (nonatomic) NPPEncoding encoding;                       // setter = "Convert to" (keeps text, changes how it is saved)
@property (nonatomic) CFStringEncoding codepage;                  // for NPPEncodingANSI; any NPPCharset.cfEncoding (see the note there)
@property (nonatomic) NPPEOL eolMode;                             // setter = SCI_SETEOLMODE only; use -convertEOLTo: to rewrite
@property (nonatomic, strong) NPPLanguage *language;              // setter applies via NPPLanguageManager
@property (nonatomic, strong, nullable) NSColor *tabColor;        // View > Tab > Apply Color N (nil = none)
@property (nonatomic) BOOL isMonitoring;                          // View > Monitoring (tail -f)
@property (nonatomic, readonly, nullable) NSDate *lastKnownModificationDate;

- (instancetype)initUntitled;                                     // "new N" with prefs' default EOL/encoding/language
- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error;

// File I/O — encoding detection: BOM (UTF-8/16LE/16BE) -> the charset an .html/.xml file declares in its own header
// (N++ getHtmlXmlEncoding: <?xml ... encoding="..."?> / <meta ... charset=...>) -> valid UTF-8 -> uchardet
// (libuchardet, skip "TIS-620") -> codepage. A BOM erases the declared charset, and the declared charset stops the
// detectors running at all, which is upstream's order (Buffer.cpp loadFileData).
// EOL detection: first EOL found in the text (CRLF/CR/LF), else prefs default. Language: by extension, then first line, else normal.
// After load: SCI_SETSAVEPOINT, SCI_EMPTYUNDOBUFFER, caret at 0. A file over the large-file limit (NPPLargeFileSizeMB,
// 200 MB) is opened without styling and with the other restrictions of N++'s LargeFileRestriction; see -isLargeFile.
- (BOOL)loadFromURL:(NSURL *)url error:(NSError **)error;
// Encodes per -encoding (+BOM), sets fileURL + savepoint, re-detects language if the extension changed.
// The write is atomic *and* keeps the file it replaces: creation date, extended attributes (Finder tags, "where
// from", quarantine), POSIX mode and any ACL all survive, and a symlink is followed instead of being flattened
// into a regular file. A file with a second hard link, and a file the atomic exchange cannot be done on (a network
// or FAT volume, an ACL that forbids deleting it, an unwritable directory), is rewritten in place instead — see
// NPPRewriteInPlace for what that costs. A destination that is read-only on disk is never overwritten silently —
// the user is asked whether to clear the read-only attribute first, and NSUserCancelledError comes back if they
// decline, with the buffer left dirty and the file untouched.
- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error;
- (BOOL)saveCopyToURL:(NSURL *)url error:(NSError **)error;      // like save but leaves fileURL/dirty state untouched
- (BOOL)reloadFromDisk:(NSError **)error;                        // keeps caret/scroll position when possible
- (BOOL)fileChangedOnDiskSinceLoad;                              // compares mtime
// N++ checkModifiedDocument / DOC_DELETED: the buffer had a file and it is no longer there. When the app comes
// forward the document asks "keep this file in editor?" itself — keeping marks the buffer dirty (upstream's
// setUnsync) so it can be written back, the other answer closes it through the delegate.
- (BOOL)fileWasRemovedFromDisk;
- (void)convertEOLTo:(NPPEOL)eol;                                // SCI_CONVERTEOLS + SCI_SETEOLMODE
- (void)reinterpretAsEncoding:(NPPEncoding)encoding codepage:(CFStringEncoding)codepage; // Encoding > "Encode in X": re-decode the raw bytes of the file on disk (only when not dirty and file exists; otherwise behaves like convert)

// Display strings for the status bar / menus
- (NSString *)encodingDisplayName;   // "ANSI", "UTF-8", "UTF-8-BOM", "UTF-16 LE BOM", "UTF-16 BE BOM", or charset displayName (e.g. "Windows-1254")
- (NSString *)eolDisplayName;        // "Windows (CR LF)", "Unix (LF)", "Macintosh (CR)"

// Editor behaviours N++ has that live with the buffer, all driven off Scintilla notifications and settings (no menu items):
//   - auto-indent on newline (SCN_CHARADDED), basic or advanced per NPPAutoIndentMode (0 none / 1 basic / 2 advanced)
//   - matched-character insertion, per pair (NPPMatchedPair*) plus user-defined pairs (NPPMatchedPairsUserDefined);
//     the ">" close-tag half belongs to NPPAutoCompletion and is not duplicated here
//   - brace highlighting (SCI_BRACEHIGHLIGHT/BADLIGHT on SCN_UPDATEUI)
//   - smart highlighting of the selected word (indicator 29)
//   - clickable URLs (indicator 8 = N++ URL_INDIC, NPPStyleURL / NPPUriSchemes; double-click opens)
//   - HTML/XML matched tag + attribute highlighting (indicators 27/26, NPPTagMatchHighlight / NPPTagAttrHighlight),
//     skipped inside comment / PHP / ASP zones unless NPPPreferences.highlightNonHTMLZone
//   - fold margin click, symbol margin bookmarks
//   - a plain right-click on the bookmark margin pops the live Search ▸ Bookmark submenu (N++ SCN_MARGINRIGHTCLICK);
//     the other margins are left alone
//   - ⌘/⌃ double-click selects between NPPPreferences.delimiterOpen and .delimiterClose (N++ "On Selection")
//   - a right-click outside the selection moves the caret there, unless NPPPreferences.rightClickKeepsSelection
//   - a C0 control character that reaches the buffer is taken straight back out (NPPPreferences.preventC0Input)
//   - paste with several carets hands out one clipboard line per caret (N++ pasteToMultiSelection)
//   - forward-delete with several carets joins lines at the carets sitting on an EOL, where Scintilla alone does
//     nothing (N++ ScintillaEditView WM_KEYDOWN / VK_DELETE)
//   - the mouse's back / forward buttons switch to the previous / next document (N++ WM_APPCOMMAND
//     APPCOMMAND_BROWSER_BACKWARD / _FORWARD) — through the delegate, which has to answer -documents /
//     -currentDocument / -selectDocument:. Upstream's other switching gesture, the wheel with the right button
//     held, is NOT here: AppKit pops the context menu on right-mouse-down, so the wheel never arrives. See the
//     ponytail note on +installEditorHooks.
//   - indent guides look forward only in the languages N++ calls Python-style, and both ways everywhere else
- (void)applyPreferences;            // re-read NPPPreferences (tab size, wrap, margins, whitespace, caret, current line, etc.)
- (void)applyThemeAndLanguage;       // re-apply after theme change

// N++ LargeFileRestriction: YES once a file of NPPLargeFileSizeMB or more has been loaded. Styling, word wrap, brace
// matching, smart highlighting and clickable links are then off unless the matching NPPLargeFileAllow* key says
// otherwise — or NPPLargeFileRestrictionEnabled is switched off afterwards, which lifts all of them without a reload.
@property (nonatomic, readonly) BOOL isLargeFile;

// User-defined languages (the optional NPPUserDefinedLanguages module). Applying one replaces the built-in lexer for
// this buffer; setting .language again clears it. userDefinedLanguageName is nil unless a UDL is active.
- (BOOL)applyUserDefinedLanguageNamed:(NSString *)name;
@property (nonatomic, readonly, copy, nullable) NSString *userDefinedLanguageName;

// Untitled numbering, like N++ ("new 1", "new 2", ...). Numbers of closed untitled docs are reused.
+ (NSInteger)claimUntitledNumber;
+ (void)releaseUntitledNumber:(NSInteger)n;

// Headless regression checks (URL scanner, tag matcher, advanced-indent decision, word characters, matched pairs,
// large-file thresholds, the cap on the window the scanners get, the OEM 720 / 858 code pages both ways, and the
// margin hit test and menu walk behind the bookmark-margin right-click, the charset declared in an HTML/XML
// header, metadata-preserving saving, the read-only guard, multi-caret paste and delete, and the document-switch
// direction of the extra mouse buttons). Run by NPPSelfTest's module pass.
+ (NSArray<NSString *> *)selfCheckFailures;
@end

NS_ASSUME_NONNULL_END
