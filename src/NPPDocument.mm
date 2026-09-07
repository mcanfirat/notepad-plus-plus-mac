// NPPDocument.mm — one open buffer: owns its ScintillaView, does file I/O (N++ Buffer.cpp / FileManager),
// and the per-buffer editor behaviours N++ hangs off Scintilla notifications.
#import "NPPDocument.h"
#import "NPPSearchViewCommands.h"
#import "NPPUtils.h"
#import "NPPPreferences.h"

NSNotificationName const NPPDocumentWillSaveNotification = @"NPPDocumentWillSave";
#include <uchardet.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <SciLexer.h>
#include <algorithm>
#include <set>
#include <string>
#include <vector>

// Marker / margin / indicator ids come from NPPSearchViewCommands.h (shared with NPPLanguageManager); local aliases only.
enum { NPPMarkBookmark = NPPMarkerBookmark, NPPMarkHideUnderline = NPPMarkerHideLinesUnderline, NPPMarkHideBegin = NPPMarkerHideLinesBegin, NPPMarkHideEnd = NPPMarkerHideLinesEnd };
enum { NPPMarginFold = NPPMarginFolder };
// N++ URL_INDIC (ScintillaEditView.h). Not in the NPPIndicator… enum because that header is not ours to edit;
// NPPLanguageManager already gives indicator 8 its "URL hovered" colour, so only style/flags are set here.
enum { NPPIndicatorURL = 8 };

static NSString *const NPPDocumentErrorDomain = @"NPPDocument";

// The delegate is the window controller, which knows how to close a buffer. Asked for by selector so this file
// keeps no build dependency on it, and so "the file is gone — keep it?" only offers Close when it can do something.
@protocol NPPDocumentCloser <NSObject>
- (BOOL)closeDocument:(NPPDocument *)doc;
@end

// The same delegate, asked for the three things N++'s activateNextDoc needs. Declared here rather than imported so
// this file keeps no build dependency on the window controller; every selector is checked before it is sent.
@protocol NPPDocumentSwitcher <NSObject>
- (NSArray<NPPDocument *> *)documents;
- (nullable NPPDocument *)currentDocument;
- (void)selectDocument:(NPPDocument *)doc;
@end

#pragma mark - Settings NPPPreferences does not expose yet

// Read straight from NSUserDefaults, using the key a preferences page would ("NPP" + PropertyName, the convention
// NPPPreferences' property macros follow). Adding the matching property there later is a no-op for this file.
// Defaults mirror N++'s (NppGUI / MatchedPairConf / LargeFileRestriction).
static NSString *const kKeyStyleURL         = @"NPPStyleURL";          // urlMode below; N++ NppGUI::_styleURL
static NSString *const kKeyUriSchemes       = @"NPPUriSchemes";        // space separated, added to the built-in set
// N++ NppGUI::_uriSchemes default.
static NSString *const kDefaultUriSchemes = @"svn:// cvs:// git:// imap:// irc:// irc6:// ircs:// ldap:// ldaps:// "
                                             "news: telnet:// gopher:// ssh:// sftp:// smb:// skype: snmp:// "
                                             "spotify: steam:// sms: slack:// chrome:// bitcoin:";
static NSString *const kKeyTagAttrHighlight = @"NPPTagAttrHighlight";  // N++ _enableTagAttrsHilite
static NSString *const kKeyPairParentheses  = @"NPPMatchedPairParentheses";
static NSString *const kKeyPairBrackets     = @"NPPMatchedPairBrackets";
static NSString *const kKeyPairCurly        = @"NPPMatchedPairCurlyBrackets";
static NSString *const kKeyPairQuotes       = @"NPPMatchedPairQuotes";
static NSString *const kKeyPairDoubleQuotes = @"NPPMatchedPairDoubleQuotes";
static NSString *const kKeyPairsUserDefined = @"NPPMatchedPairsUserDefined";   // array of 2-character strings, e.g. @[@"<>"]
static NSString *const kKeyLargeFileEnabled = @"NPPLargeFileRestrictionEnabled";
static NSString *const kKeyLargeFileSizeMB  = @"NPPLargeFileSizeMB";
static NSString *const kKeyLargeNoWrap      = @"NPPLargeFileDeactivateWordWrap";
static NSString *const kKeyLargeBraceMatch  = @"NPPLargeFileAllowBraceMatch";
static NSString *const kKeyLargeSmartHilite = @"NPPLargeFileAllowSmartHilite";
static NSString *const kKeyLargeLinks       = @"NPPLargeFileAllowClickableLink";
static NSString *const kKeyLargeNo2GBWarn   = @"NPPLargeFileSuppress2GBWarning";
// The Find dialog's own switches (NPPFindPanelController owns these two keys, with the same defaults). Read here
// for NPPSmartHighlightUseFindSettings — N++ SmartHighlighter reads FindHistory for exactly these two.
static NSString *const kKeyFindMatchCase    = @"NPPFindMatchCase";
static NSString *const kKeyFindWholeWord    = @"NPPFindWholeWord";

// N++ urlMode (NppConstants.h)
enum { NPPUrlDisable = 0, NPPUrlNoUnderLineFg, NPPUrlUnderLineFg, NPPUrlNoUnderLineBg, NPPUrlUnderLineBg };

static BOOL NPPPrefBool(NSString *key, BOOL fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static NSInteger NPPPrefInt(NSString *key, NSInteger fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v integerValue] : fallback;
}
static NSString *NPPPrefString(NSString *key, NSString *fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [v isKindOfClass:NSString.class] ? v : fallback;
}

// N++ LargeFileRestriction: over the limit, the buffer is opened without a lexer and the allow* keys decide what
// else stays on. 200 MB is NPP_STYLING_FILESIZE_LIMIT_DEFAULT.
static BOOL NPPFileIsLargeFile(long long bytes) {
    if (!NPPPrefBool(kKeyLargeFileEnabled, YES)) return NO;
    long long limitMB = MAX((NSInteger)1, NPPPrefInt(kKeyLargeFileSizeMB, 200));
    return bytes >= limitMB * 1024 * 1024;   // N++ Buffer.cpp: fileSize >= _largeFileSizeDefInByte
}

// N++ asks before opening a file whose buffer would not fit in 2 GB ("could take several minutes"). NO = don't open.
static BOOL NPPWantsToOpenHugeFile(NSURL *url, long long bytes) {
    if (bytes + MIN(1LL << 20, bytes / 6) <= INT32_MAX) return YES;
    if (NPPPrefBool(kKeyLargeNo2GBWarn, NO)) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Opening huge file warning";
    alert.informativeText = [NSString stringWithFormat:@"Opening a huge file of 2GB+ (\"%@\") could take several minutes.\nDo you want to open it?",
                             url.lastPathComponent ?: url.path ?: @""];
    [alert addButtonWithTitle:@"Open"];
    [alert addButtonWithTitle:@"Cancel"];
    return [alert runModal] == NSAlertFirstButtonReturn;
}

static NSError *NPPError(NSInteger code, NSString *msg, NSError *underlying) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: msg} mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:NPPDocumentErrorDomain code:code userInfo:info];
}

#pragma mark - The two code pages CoreFoundation does not have

// N++'s character-set menu has two OEM code pages CF cannot convert: 720 (Arabic) and 858 (Western European).
// kCFStringEncodingDOSArabic is *864*, not 720, and there is no 858 at all — CFStringConvertIANACharSetNameToEncoding
// and CFStringConvertWindowsCodepageToEncoding both answer kCFStringEncodingInvalidId for the pair. Both are plain
// ASCII below 0x80, so one 128-entry high half each is the entire codec.
// These two ids are private to this port and only ever travel through -codepage / NPPCharset.cfEncoding. Code
// outside this file that hands one to CF (the ASCII panel's CFStringConvertEncodingToNSStringEncoding) gets
// kCFStringEncodingInvalidId and takes its existing Latin-1 fallback, which is why they are numbered far away
// from CF's own range instead of stealing an unused CF value.
enum : CFStringEncoding { NPPCodePageOEM720 = 0x4E500000 + 720, NPPCodePageOEM858 = 0x4E500000 + 858 };

// Code page 720 (Microsoft's "Arabic (Transparent ASCII)"), bytes 0x80-0xFF. The eight positions Microsoft leaves
// undefined (0x80, 0x81, 0x84, 0x86, 0x8D-0x90) map to the C1 control of the same value: nothing else in the table
// uses those code points, so a byte the file happens to contain still survives a load/save round trip.
static const UTF16Char kNPPCodePage720High[128] = {
    0x0080, 0x0081, 0x00E9, 0x00E2, 0x0084, 0x00E0, 0x0086, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x008D, 0x008E, 0x008F,
    0x0090, 0x0651, 0x0652, 0x00F4, 0x00A4, 0x0640, 0x00FB, 0x00F9, 0x0621, 0x0622, 0x0623, 0x0624, 0x00A3, 0x0625, 0x0626, 0x0627,
    0x0628, 0x0629, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E, 0x062F, 0x0630, 0x0631, 0x0632, 0x0633, 0x0634, 0x0635, 0x00AB, 0x00BB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x0636, 0x0637, 0x0638, 0x0639, 0x063A, 0x0641, 0x00B5, 0x0642, 0x0643, 0x0644, 0x0645, 0x0646, 0x0647, 0x0648, 0x0649, 0x064A,
    0x2261, 0x064B, 0x064C, 0x064D, 0x064E, 0x064F, 0x0650, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
};

// One 8-bit code page: the high half both ways. `sorted` is (code point << 8 | byte) ascending, so the save path
// finds a byte with a binary search instead of scanning 128 entries per character of a 72 MB buffer.
struct NPPCodePage8Bit {
    UTF16Char toUnicode[128];
    uint32_t sorted[128];
};

static void NPPBuildCodePageReverse(NPPCodePage8Bit *cp) {
    for (int i = 0; i < 128; i++) cp->sorted[i] = ((uint32_t)cp->toUnicode[i] << 8) | (uint32_t)(0x80 + i);
    std::sort(cp->sorted, cp->sorted + 128);
}

// NULL for every encoding CF can handle itself — two integer compares before anything is built.
static const NPPCodePage8Bit *NPPCustomCodePage(CFStringEncoding enc) {
    if (enc != NPPCodePageOEM720 && enc != NPPCodePageOEM858) return NULL;
    static NPPCodePage8Bit cp720, cp858;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        memcpy(cp720.toUnicode, kNPPCodePage720High, sizeof kNPPCodePage720High);
        NPPBuildCodePageReverse(&cp720);
        // 858 *is* 850 with the euro sign where 850 has a dotless i, so let CF spell 850 out rather than hand-copy it.
        for (int i = 0; i < 128; i++) {
            UInt8 b = (UInt8)(0x80 + i);
            CFStringRef s = CFStringCreateWithBytes(kCFAllocatorDefault, &b, 1, kCFStringEncodingDOSLatin1, false);
            cp858.toUnicode[i] = (s && CFStringGetLength(s) == 1) ? CFStringGetCharacterAtIndex(s, 0) : (UTF16Char)b;
            if (s) CFRelease(s);
        }
        cp858.toUnicode[0xD5 - 0x80] = 0x20AC;   // EURO SIGN: the single byte 858 does not share with 850
        NPPBuildCodePageReverse(&cp858);
    });
    return enc == NPPCodePageOEM720 ? &cp720 : &cp858;
}

static void NPPAppendUTF8(std::string &out, uint32_t cp) {   // BMP only: no table entry is a surrogate
    if (cp < 0x80) { out.push_back((char)cp); }
    else if (cp < 0x800) { out.push_back((char)(0xC0 | (cp >> 6))); out.push_back((char)(0x80 | (cp & 0x3F))); }
    else { out.push_back((char)(0xE0 | (cp >> 12))); out.push_back((char)(0x80 | ((cp >> 6) & 0x3F))); out.push_back((char)(0x80 | (cp & 0x3F))); }
}

// The save half. One byte per UTF-16 unit, '?' for anything the code page has no room for — the same substitution
// Windows' WideCharToMultiByte makes for N++.
// ponytail: a character outside the BMP costs two '?' instead of one, because the surrogate pair is never joined.
// Join them if a lossy ANSI save of astral text ever has to look tidy.
static NSData *NPPEncodeWithCodePage(NSString *s, const NPPCodePage8Bit *cp) {
    const NSUInteger len = s.length;
    NSMutableData *out = [NSMutableData dataWithLength:len];
    uint8_t *dst = (uint8_t *)out.mutableBytes;
    unichar buf[512];
    for (NSUInteger i = 0; i < len; i += 512) {
        const NSUInteger chunk = MIN((NSUInteger)512, len - i);
        [s getCharacters:buf range:NSMakeRange(i, chunk)];
        for (NSUInteger k = 0; k < chunk; k++) {
            const unichar u = buf[k];
            if (u < 0x80) { dst[i + k] = (uint8_t)u; continue; }
            const uint32_t key = (uint32_t)u << 8;
            const uint32_t *hit = std::lower_bound(cp->sorted, cp->sorted + 128, key);
            dst[i + k] = (hit != cp->sorted + 128 && (*hit >> 8) == u) ? (uint8_t)(*hit & 0xFF) : (uint8_t)'?';
        }
    }
    return out;
}

#pragma mark - NPPCharset

@interface NPPCharset ()
@property (nonatomic, readwrite, copy) NSString *ianaName, *displayName, *groupName;
@property (nonatomic, readwrite) CFStringEncoding cfEncoding;
@end

@implementation NPPCharset
+ (NSArray<NPPCharset *> *)allCharsets {
    static NSArray<NPPCharset *> *all; static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Port of Notepad_plus.rc "Character sets" submenus (group, display, IANA). Entries CF can't map are dropped,
        // except cp720 / cp858, which this file converts itself (see NPPCustomCodePage).
        static const char *table[][3] = {
            {"Arabic", "ISO 8859-6", "iso-8859-6"}, {"Arabic", "OEM 720", "cp720"}, {"Arabic", "Windows-1256", "windows-1256"},
            {"Baltic", "ISO 8859-4", "iso-8859-4"}, {"Baltic", "ISO 8859-13", "iso-8859-13"}, {"Baltic", "OEM 775", "cp775"}, {"Baltic", "Windows-1257", "windows-1257"},
            {"Celtic", "ISO 8859-14", "iso-8859-14"},
            {"Cyrillic", "ISO 8859-5", "iso-8859-5"}, {"Cyrillic", "KOI8-R", "koi8-r"}, {"Cyrillic", "KOI8-U", "koi8-u"}, {"Cyrillic", "Macintosh", "x-mac-cyrillic"},
            {"Cyrillic", "OEM 855", "cp855"}, {"Cyrillic", "OEM 866", "cp866"}, {"Cyrillic", "Windows-1251", "windows-1251"},
            {"Central European", "OEM 852", "cp852"}, {"Central European", "Windows-1250", "windows-1250"},
            {"Chinese", "Big5 (Traditional)", "big5"}, {"Chinese", "GB2312 (Simplified)", "gb2312"},
            {"Eastern European", "ISO 8859-2", "iso-8859-2"},
            {"Greek", "ISO 8859-7", "iso-8859-7"}, {"Greek", "OEM 737", "cp737"}, {"Greek", "OEM 869", "cp869"}, {"Greek", "Windows-1253", "windows-1253"},
            {"Hebrew", "ISO 8859-8", "iso-8859-8"}, {"Hebrew", "OEM 862", "cp862"}, {"Hebrew", "Windows-1255", "windows-1255"},
            {"Japanese", "Shift-JIS", "shift_jis"},
            {"Korean", "Windows 949", "cp949"}, {"Korean", "EUC-KR", "euc-kr"},
            {"North European", "OEM 861 : Icelandic", "cp861"}, {"North European", "OEM 865 : Nordic", "cp865"},
            {"Thai", "ISO 8859-11", "iso-8859-11"}, {"Thai", "TIS-620", "tis-620"},
            {"Turkish", "ISO 8859-3", "iso-8859-3"}, {"Turkish", "ISO 8859-9", "iso-8859-9"}, {"Turkish", "OEM 857", "cp857"}, {"Turkish", "Windows-1254", "windows-1254"},
            {"Western European", "ISO 8859-1", "iso-8859-1"}, {"Western European", "ISO 8859-15", "iso-8859-15"}, {"Western European", "OEM 850", "cp850"},
            {"Western European", "OEM 858", "cp858"}, {"Western European", "OEM 860 : Portuguese", "cp860"}, {"Western European", "OEM 863 : French", "cp863"},
            {"Western European", "OEM-US : CP437", "cp437"}, {"Western European", "Windows-1252", "windows-1252"},
            {"Vietnamese", "Windows-1258", "windows-1258"},
        };
        NSMutableArray *a = [NSMutableArray array];
        for (auto &row : table) {
            CFStringEncoding enc = strcmp(row[2], "cp720") == 0 ? NPPCodePageOEM720
                                 : strcmp(row[2], "cp858") == 0 ? NPPCodePageOEM858
                                 : CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)@(row[2]));
            if (enc == kCFStringEncodingInvalidId) continue;
            NPPCharset *c = [NPPCharset new];
            c.groupName = @(row[0]); c.displayName = @(row[1]); c.ianaName = @(row[2]); c.cfEncoding = enc;
            [a addObject:c];
        }
        all = [a copy];
    });
    return all;
}
+ (NPPCharset *)charsetForIANAName:(NSString *)name {
    for (NPPCharset *c in self.allCharsets)
        if ([c.ianaName caseInsensitiveCompare:name] == NSOrderedSame) return c;
    // Aliases ("ibm866", "windows-949", ...) resolve through CF.
    CFStringEncoding enc = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)name);
    return enc == kCFStringEncodingInvalidId ? nil : [self charsetForCFEncoding:enc];
}
+ (NPPCharset *)charsetForCFEncoding:(CFStringEncoding)enc {
    for (NPPCharset *c in self.allCharsets) if (c.cfEncoding == enc) return c;
    return nil;
}
@end

#pragma mark - Byte helpers

// Strict UTF-8 validation (RFC 3629: no overlongs, no surrogates, <= U+10FFFF). *ascii7 reports "all bytes < 0x80".
static bool NPPIsValidUTF8(const uint8_t *p, size_t n, bool *ascii7) {
    bool ascii = true;
    size_t i = 0;
    while (i < n) {
        uint8_t c = p[i];
        if (c < 0x80) { i++; continue; }
        ascii = false;
        size_t len; uint32_t cp;
        if ((c & 0xE0) == 0xC0) { len = 2; cp = c & 0x1F; if (c < 0xC2) return false; }
        else if ((c & 0xF0) == 0xE0) { len = 3; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { len = 4; cp = c & 0x07; if (c > 0xF4) return false; }
        else return false;
        if (i + len > n) return false;
        for (size_t k = 1; k < len; k++) {
            if ((p[i + k] & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (p[i + k] & 0x3F);
        }
        if ((len == 3 && cp < 0x800) || (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += len;
    }
    if (ascii7) *ascii7 = ascii;
    return true;
}

// CFString -> UTF-8 std::string (avoids NSString round trips; handles embedded NULs).
static std::string NPPUTF8FromCFString(CFStringRef s) {
    std::string out;
    if (!s) return out;
    CFIndex len = CFStringGetLength(s);
    if (len == 0) return out;
    CFIndex maxBytes = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8);
    out.resize((size_t)maxBytes);
    CFIndex used = 0;
    CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, '?', false, (UInt8 *)out.data(), maxBytes, &used);
    out.resize((size_t)used);
    return out;
}

// Decode bytes in `enc` to UTF-8. Returns false when the bytes are not valid for that encoding.
static bool NPPDecodeBytes(const uint8_t *p, size_t n, CFStringEncoding enc, std::string &out) {
    if (n == 0) { out.clear(); return true; }
    if (const NPPCodePage8Bit *cp = NPPCustomCodePage(enc)) {   // OEM 720 / 858: every byte has a meaning, so this never fails
        out.clear();
        out.reserve(n);
        for (size_t i = 0; i < n; i++) {
            if (p[i] < 0x80) out.push_back((char)p[i]);
            else NPPAppendUTF8(out, cp->toUnicode[p[i] - 0x80]);
        }
        return true;
    }
    CFStringRef s = CFStringCreateWithBytes(kCFAllocatorDefault, p, (CFIndex)n, enc, false);
    if (!s) return false;
    out = NPPUTF8FromCFString(s);
    CFRelease(s);
    return true;
}

static CFStringEncoding NPPDetectWithUchardet(const uint8_t *p, size_t n) {
    uchardet_t ud = uchardet_new();
    if (!ud) return kCFStringEncodingInvalidId;
    CFStringEncoding result = kCFStringEncodingInvalidId;
    if (uchardet_handle_data(ud, (const char *)p, std::min<size_t>(n, 1024 * 1024)) == 0) {
        uchardet_data_end(ud);
        const char *cs = uchardet_get_charset(ud);
        // N++ (Buffer.cpp detectCodepage) ignores TIS-620 (false positives) and empty/ASCII results.
        if (cs && *cs && strcmp(cs, "TIS-620") != 0 && strcasecmp(cs, "ASCII") != 0)
            result = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)@(cs));
    }
    uchardet_delete(ud);
    return result;
}

// N++ falls back to the Windows system code page (CP_ACP) when charset detection fails, which is why an ANSI file
// opens correctly on a machine whose region matches it (a cp1254 file on a Turkish Windows). macOS has no ANSI code
// page, so derive the closest one from the user's locale — language first, then region.
static CFStringEncoding NPPSystemANSICodepage(void) {
    static CFStringEncoding cached = kCFStringEncodingInvalidId;
    if (cached != kCFStringEncodingInvalidId) return cached;
    NSLocale *loc = NSLocale.currentLocale;
    NSString *lang = (loc.languageCode ?: @"en").lowercaseString;
    NSString *region = (loc.countryCode ?: @"").uppercaseString;
    NSString *script = loc.scriptCode ?: @"";
    struct { NSString *key; CFStringEncoding enc; } table[] = {
        {@"tr", kCFStringEncodingWindowsLatin5},   {@"az", kCFStringEncodingWindowsLatin5},
        {@"ru", kCFStringEncodingWindowsCyrillic}, {@"uk", kCFStringEncodingWindowsCyrillic},
        {@"be", kCFStringEncodingWindowsCyrillic}, {@"bg", kCFStringEncodingWindowsCyrillic},
        {@"sr", kCFStringEncodingWindowsCyrillic}, {@"mk", kCFStringEncodingWindowsCyrillic},
        {@"pl", kCFStringEncodingWindowsLatin2},   {@"cs", kCFStringEncodingWindowsLatin2},
        {@"sk", kCFStringEncodingWindowsLatin2},   {@"hu", kCFStringEncodingWindowsLatin2},
        {@"sl", kCFStringEncodingWindowsLatin2},   {@"hr", kCFStringEncodingWindowsLatin2},
        {@"ro", kCFStringEncodingWindowsLatin2},   {@"sq", kCFStringEncodingWindowsLatin2},
        {@"bs", kCFStringEncodingWindowsLatin2},
        {@"el", kCFStringEncodingWindowsGreek},    {@"he", kCFStringEncodingWindowsHebrew},
        {@"iw", kCFStringEncodingWindowsHebrew},   {@"yi", kCFStringEncodingWindowsHebrew},
        {@"ar", kCFStringEncodingWindowsArabic},   {@"fa", kCFStringEncodingWindowsArabic},
        {@"ur", kCFStringEncodingWindowsArabic},
        {@"lt", kCFStringEncodingWindowsBalticRim}, {@"lv", kCFStringEncodingWindowsBalticRim},
        {@"et", kCFStringEncodingWindowsBalticRim},
        {@"th", kCFStringEncodingDOSThai},         {@"vi", kCFStringEncodingWindowsVietnamese},
        {@"ja", kCFStringEncodingDOSJapanese},     {@"ko", kCFStringEncodingDOSKorean},
        // regions, for locales like "en_TR" where the language says nothing about the files on disk
        {@"TR", kCFStringEncodingWindowsLatin5},   {@"RU", kCFStringEncodingWindowsCyrillic},
        {@"UA", kCFStringEncodingWindowsCyrillic}, {@"BY", kCFStringEncodingWindowsCyrillic},
        {@"BG", kCFStringEncodingWindowsCyrillic}, {@"RS", kCFStringEncodingWindowsCyrillic},
        {@"MK", kCFStringEncodingWindowsCyrillic}, {@"KZ", kCFStringEncodingWindowsCyrillic},
        {@"PL", kCFStringEncodingWindowsLatin2},   {@"CZ", kCFStringEncodingWindowsLatin2},
        {@"SK", kCFStringEncodingWindowsLatin2},   {@"HU", kCFStringEncodingWindowsLatin2},
        {@"SI", kCFStringEncodingWindowsLatin2},   {@"HR", kCFStringEncodingWindowsLatin2},
        {@"RO", kCFStringEncodingWindowsLatin2},   {@"AL", kCFStringEncodingWindowsLatin2},
        {@"BA", kCFStringEncodingWindowsLatin2},
        {@"GR", kCFStringEncodingWindowsGreek},    {@"CY", kCFStringEncodingWindowsGreek},
        {@"IL", kCFStringEncodingWindowsHebrew},
        {@"SA", kCFStringEncodingWindowsArabic},   {@"AE", kCFStringEncodingWindowsArabic},
        {@"EG", kCFStringEncodingWindowsArabic},   {@"IR", kCFStringEncodingWindowsArabic},
        {@"IQ", kCFStringEncodingWindowsArabic},   {@"PK", kCFStringEncodingWindowsArabic},
        {@"LT", kCFStringEncodingWindowsBalticRim}, {@"LV", kCFStringEncodingWindowsBalticRim},
        {@"EE", kCFStringEncodingWindowsBalticRim},
        {@"TH", kCFStringEncodingDOSThai},         {@"VN", kCFStringEncodingWindowsVietnamese},
        {@"JP", kCFStringEncodingDOSJapanese},     {@"KR", kCFStringEncodingDOSKorean},
    };
    cached = kCFStringEncodingWindowsLatin1;
    for (auto &e : table) {
        if ([e.key isEqualToString:lang]) { cached = e.enc; return cached; }
    }
    if ([lang isEqualToString:@"zh"]) {
        cached = ([script isEqualToString:@"Hant"] || [region isEqualToString:@"TW"] || [region isEqualToString:@"HK"] || [region isEqualToString:@"MO"])
                 ? kCFStringEncodingDOSChineseTrad : kCFStringEncodingDOSChineseSimplif;
        return cached;
    }
    for (auto &e : table) {
        if ([e.key isEqualToString:region]) { cached = e.enc; return cached; }
    }
    if ([region isEqualToString:@"TW"] || [region isEqualToString:@"HK"]) cached = kCFStringEncodingDOSChineseTrad;
    else if ([region isEqualToString:@"CN"] || [region isEqualToString:@"SG"]) cached = kCFStringEncodingDOSChineseSimplif;
    return cached;
}

#pragma mark - The charset an HTML / XML file declares about itself

// N++ Notepad_plus::getHtmlXmlEncoding: for a file whose *extension* says XML or HTML, the first kilobyte is
// searched for the charset the document declares, and that beats detection. Precedence comes from
// Buffer.cpp loadFileData, which is where the value lands: a BOM erases it outright ("if file contains any BOM,
// then encoding will be erased"), and uchardet is only consulted when nothing was declared. So:
//     BOM  >  declared charset  >  valid-UTF-8 / uchardet  >  the default code page.
// kCFStringEncodingInvalidId means "nothing usable declared"; kCFStringEncodingUTF8 means the file said UTF-8.
static const size_t kNPPHeaderScanBytes = 1024;   // upstream's blockSize, "long enough to capture the encoding in html"

// The charset table is N++'s EncodingMapper alias list, so resolve through it first and only then ask
// CoreFoundation. UTF-16/32 declarations are dropped: without a BOM they cannot be read as an 8-bit code page,
// and upstream's mapper has no entry for them either.
static CFStringEncoding NPPCharsetNamed(NSString *name) {
    if (name.length == 0) return kCFStringEncodingInvalidId;
    NSString *lower = name.lowercaseString;
    if ([lower isEqualToString:@"utf-8"] || [lower isEqualToString:@"utf8"]) return kCFStringEncodingUTF8;
    NPPCharset *cs = [NPPCharset charsetForIANAName:name];
    CFStringEncoding enc = cs ? cs.cfEncoding : CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)name);
    switch (enc) {
        case kCFStringEncodingInvalidId: case kCFStringEncodingUnicode: case kCFStringEncodingUTF16BE:
        case kCFStringEncodingUTF16LE:   case kCFStringEncodingUTF32:   case kCFStringEncodingUTF32BE:
        case kCFStringEncodingUTF32LE:   case kCFStringEncodingUTF7:
            return kCFStringEncodingInvalidId;
        default: return enc;
    }
}

// `xml` picks the declaration form: <?xml version="1.0" encoding="X"?> for XML, <meta ... charset=X> for HTML.
// Upstream's two HTML patterns both hang the charset off an http-equiv Content-Type meta; one pattern covers those
// and the HTML5 <meta charset="X"> short form that upstream predates and every modern page uses.
static CFStringEncoding NPPDeclaredCharset(const uint8_t *p, size_t n, BOOL xml) {
    if (!p || n == 0) return kCFStringEncodingInvalidId;
    // Latin-1 keeps every byte, so a header in an 8-bit code page still reads as ASCII where it matters.
    NSString *head = [[NSString alloc] initWithBytes:p length:MIN(n, kNPPHeaderScanBytes) encoding:NSISOLatin1StringEncoding];
    if (!head) return kCFStringEncodingInvalidId;
    static NSRegularExpression *xmlRE, *htmlRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSRegularExpressionOptions o = NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators;
        xmlRE = [NSRegularExpression regularExpressionWithPattern:
                 @"<\\?xml\\s[^>]*?encoding\\s*=\\s*[\"']([A-Za-z0-9_.:+-]+)[\"']" options:o error:nil];
        htmlRE = [NSRegularExpression regularExpressionWithPattern:
                  @"<meta\\s[^>]*?charset\\s*=\\s*[\"']?\\s*([A-Za-z0-9_.:+-]+)" options:o error:nil];
    });
    NSRegularExpression *re = xml ? xmlRE : htmlRE;
    NSTextCheckingResult *m = [re firstMatchInString:head options:0 range:NSMakeRange(0, head.length)];
    if (!m || m.numberOfRanges < 2) return kCFStringEncodingInvalidId;
    return NPPCharsetNamed([head substringWithRange:[m rangeAtIndex:1]]);
}

static NPPEOL NPPDetectEOL(const char *p, size_t n, NPPEOL fallback) {
    size_t limit = std::min<size_t>(n, 64 * 1024);
    for (size_t i = 0; i < limit; i++) {
        if (p[i] == '\n') return NPPEOLUnix;
        if (p[i] == '\r') return (i + 1 < n && p[i + 1] == '\n') ? NPPEOLWindows : NPPEOLMac;
    }
    return fallback;
}

static int NPPSciEOLMode(NPPEOL eol) {
    switch (eol) { case NPPEOLWindows: return SC_EOL_CRLF; case NPPEOLMac: return SC_EOL_CR; default: return SC_EOL_LF; }
}

static bool NPPFileModTime(NSURL *url, struct timespec *ts) {
    struct stat st;
    if (!url.path || stat(url.path.fileSystemRepresentation, &st) != 0) return false;
    *ts = st.st_mtimespec;
    return true;
}

static int NPPDigits(sptr_t n) { int d = 1; while (n >= 10) { n /= 10; d++; } return d; }

// N++ ScintillaEditView WM_CHAR (_npcNoInputC0): a control character never becomes text. Tab / CR / LF are how the
// editor works and are never filtered — upstream's comment says as much ("don't need to be concerned about Tab...").
static bool NPPIsFilteredC0Char(int ch) {
    if (ch == '\t' || ch == '\n' || ch == '\r') return false;
    return (ch >= 0 && ch < 32) || ch == 127;
}

// N++ Buffer::normalizeTabName: trim, drop the characters a file name cannot hold, cap at langNameLenMax - 1, trim
// again. Bytes in, so a UTF-8 name is cut on a character boundary rather than in the middle of one.
static NSString *NPPTabNameFromFirstLine(const std::string &line) {
    static const char *invalid = "\\/:*?\"<>|\t\r\n";
    std::string s;
    s.reserve(line.size());
    for (char c : line) if (c != '\0' && !strchr(invalid, c)) s += c;
    NSString *name = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (name.length > 63) name = [name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 63)]];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return name.length ? name : nil;
}

// N++ NppNotification SCN_DOUBLECLICK with Ctrl held: the range *between* the two delimiters around the click.
// Same delimiter on both sides -> nearest one each way, skipping \" escapes; different -> the innermost balanced
// pair that contains the click. Returns the delimiter positions themselves (caller selects openPos + open.size() .. closePos).
// Whole UTF-8 strings rather than upstream's single `char`: the preferences page hands out one composed character,
// which is two bytes for something like "«", and matching only its lead byte would hit every other Latin-1 character.
static bool NPPFindDelimiterRange(const std::string &text, size_t click, const std::string &open, const std::string &close,
                                  long *openPos, long *closePos) {
    long left = -1, right = -1;
    if (text.empty() || open.empty() || close.empty() || click > text.size()) return false;
    // Upstream honours the backslash escape for the quotation mark and for nothing else.
    auto at = [&text](size_t i, const std::string &d) {
        return text.compare(i, d.size(), d) == 0 && !(d == "\"" && i > 0 && text[i - 1] == '\\');
    };
    if (open == close) {
        for (long i = (long)MIN(click, text.size() - 1); i >= 0; --i)
            if (at((size_t)i, open)) { left = i; break; }
        if (left < 0) return false;
        for (size_t i = click; i < text.size(); ++i)
            if (at(i, close)) { right = (long)i; break; }
    } else {
        std::vector<size_t> opens;
        for (size_t i = 0; i < text.size(); ++i) {
            if (at(i, open)) { opens.push_back(i); i += open.size() - 1; continue; }
            if (!at(i, close) || opens.empty()) continue;
            const size_t matching = opens.back();
            opens.pop_back();
            if (matching <= click && i >= click && (left == -1 || matching > (size_t)left)) {
                left = (long)matching;
                right = (long)i;
            }
        }
    }
    if (left < 0 || right < 0 || right < left + (long)open.size()) return false;
    *openPos = left;
    *closePos = right;
    return true;
}

// The "comment/php/asp zone" of N++'s HTML lexer: the HTML comment, the ASP/PI markers and every embedded-script
// style (SCE_HJ_/SCE_HB_/SCE_HP_/SCE_HPHP_ all live at 40 and above). NppGUI::_enableHiliteNonHTMLZone decides
// whether tag matching runs while the caret sits in one of them.
static bool NPPStyleIsNonHTMLZone(int style) {
    return style == SCE_H_COMMENT || style == SCE_H_ASP || style == SCE_H_ASPAT ||
           style == SCE_H_QUESTION || style == SCE_H_XCCOMMENT || style >= SCE_HJ_START;
}

#pragma mark - URL scanning (N++ Notepad_plus.cpp isUrl / scanToUrlStart / scanToUrlEnd)

// Upstream scans wchar_t, which is why the Unicode space characters below terminate a URL. Scintilla hands us UTF-8,
// so the visible range is decoded to code points once and the code-point index is mapped back to a byte offset.
struct NPPCodePoints {
    std::u32string cp;
    std::vector<size_t> byteOffset;   // cp.size() + 1 entries; the last one is the byte length
};

static NPPCodePoints NPPDecodeUTF8(const char *p, size_t n) {
    NPPCodePoints out;
    out.cp.reserve(n);
    out.byteOffset.reserve(n + 1);
    size_t i = 0;
    while (i < n) {
        const uint8_t c = (uint8_t)p[i];
        size_t len = 1;
        char32_t v = c;
        if (c >= 0xC2 && c <= 0xDF) { len = 2; v = c & 0x1F; }
        else if (c >= 0xE0 && c <= 0xEF) { len = 3; v = c & 0x0F; }
        else if (c >= 0xF0 && c <= 0xF4) { len = 4; v = c & 0x07; }
        if (i + len > n) len = 1;
        if (len > 1) {
            for (size_t k = 1; k < len; k++) {
                if (((uint8_t)p[i + k] & 0xC0) != 0x80) { len = 1; v = c; break; }
                v = (v << 6) | ((uint8_t)p[i + k] & 0x3F);
            }
        }
        out.byteOffset.push_back(i);
        out.cp.push_back(len > 1 ? v : (char32_t)c);   // a malformed byte passes through as its own code point
        i += len;
    }
    out.byteOffset.push_back(n);
    return out;
}

static bool NPPUrlSchemeStartChar(char32_t c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
static bool NPPUrlSchemeDelimiter(char32_t c) {   // allowed immediately before a scheme
    return !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_');
}
static bool NPPUrlTextChar(char32_t c) {
    if (c <= ' ') return false;
    switch (c) {   // Unicode whitespace equivalents
        case 0x00A0: case 0x2002: case 0x2003: case 0x3000: case 0x2004: case 0x2005: case 0x2006:
        case 0x2007: case 0x2008: case 0x2009: case 0x200A: case 0x200B: case 0x202F: case 0x205F:
        case 0xFEFF: return false;
        default: break;
    }
    switch (c) { case '"': case '#': case '<': case '>': case '{': case '}': case '?': case 0x7F: return false; default: break; }
    return true;
}
static bool NPPUrlQueryDelimiter(char32_t c) { return c == '&' || c == '+' || c == '=' || c == ';'; }

// The built-in schemes plus NppGUI::_uriSchemes, split on whitespace and lowercased.
static std::vector<std::u32string> NPPUrlSchemes(NSString *extra) {
    NSString *all = [@"ftp:// http:// https:// mailto: file:// " stringByAppendingString:extra ?: @""];
    std::vector<std::u32string> out;
    for (NSString *word in [all componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (word.length == 0) continue;
        std::string utf8 = word.lowercaseString.UTF8String ?: "";
        NPPCodePoints d = NPPDecodeUTF8(utf8.data(), utf8.size());
        if (!d.cp.empty()) out.push_back(d.cp);
    }
    return out;
}

static char32_t NPPLower(char32_t c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

static bool NPPUrlSchemeSupported(const std::u32string &t, size_t p0, const std::vector<std::u32string> &schemes) {
    for (const std::u32string &s : schemes) {
        if (s.size() > t.size() - p0) continue;
        bool same = true;
        for (size_t i = 0; i < s.size() && same; i++) same = NPPLower(t[p0 + i]) == s[i];
        if (same) return true;
    }
    return false;
}

// True when a supported scheme starts at *distance* code points after `start`; *schemeLength* covers "scheme:".
static bool NPPScanToUrlStart(const std::u32string &t, size_t start, size_t *distance, size_t *schemeLength,
                              const std::vector<std::u32string> &schemes) {
    size_t p = start, p0 = 0;
    enum { sUnknown, sScheme } s = sUnknown;
    while (p < t.size()) {
        if (s == sUnknown) {
            if (NPPUrlSchemeStartChar(t[p]) && (p == 0 || NPPUrlSchemeDelimiter(t[p - 1]))) { p0 = p; s = sScheme; }
        } else {
            if (t[p] == ':' && NPPUrlSchemeSupported(t, p0, schemes)) {
                *distance = p0 - start;
                *schemeLength = p - p0 + 1;
                return true;
            }
            if (!NPPUrlSchemeStartChar(t[p])) s = sUnknown;
        }
        p++;
    }
    *schemeLength = 0;
    *distance = p - start;
    return false;
}

// Coarse host/path + query + fragment parse; *distance* is the length of the URL body after the scheme.
static void NPPScanToUrlEnd(const std::u32string &t, size_t start, size_t *distance) {
    size_t p = start;
    char32_t q = 0;
    enum { sHostAndPath, sQuery, sQueryAfterDelimiter, sQueryQuotes, sQueryAfterQuotes, sFragment } s = sHostAndPath;
    while (p < t.size()) {
        const char32_t c = t[p];
        switch (s) {
            case sHostAndPath:
                if (c == '?') s = sQuery;
                else if (c == '#') s = sFragment;
                else if (!NPPUrlTextChar(c)) { *distance = p - start; return; }
                break;
            case sQuery:
                if (c == '#') s = sFragment;
                else if (NPPUrlQueryDelimiter(c)) s = sQueryAfterDelimiter;
                else if (!NPPUrlTextChar(c)) { *distance = p - start; return; }
                break;
            case sQueryAfterDelimiter:
                if (c == '\'' || c == '"' || c == '`') { q = c; s = sQueryQuotes; }
                else if (c == '(') { q = ')'; s = sQueryQuotes; }
                else if (c == '[') { q = ']'; s = sQueryQuotes; }
                else if (c == '{') { q = '}'; s = sQueryQuotes; }
                else if (NPPUrlTextChar(c)) s = sQuery;
                else { *distance = p - start; return; }
                break;
            case sQueryQuotes:
                if (c < ' ') { *distance = p - start; return; }
                if (c == q) s = sQueryAfterQuotes;
                break;
            case sQueryAfterQuotes:
                if (NPPUrlQueryDelimiter(c)) s = sQueryAfterDelimiter;
                else { *distance = p - start; return; }
                break;
            case sFragment:
                if (c != '?' && !NPPUrlTextChar(c)) { *distance = p - start; return; }
                break;
        }
        p++;
    }
    *distance = p - start;
}

// One unwanted trailing character; call until it returns false. `text` starts at the URL.
static bool NPPTrimTrailingUrlChar(const char32_t *text, size_t *length) {
    if (*length <= 1) return false;
    const size_t l = *length - 1;
    for (const char32_t *s = U".,:;?!#"; *s; s++)
        if (text[l] == *s) { *length = l; return true; }
    static const char32_t closing[] = {')', ']'}, opening[] = {'(', '['};
    for (int i = 0; i < 2; i++) {
        if (text[l] != closing[i]) continue;
        int count = 0;
        for (size_t j = l; j-- > 0; ) {
            if (text[j] == closing[i]) count++;
            if (text[j] == opening[i]) { if (count > 0) count--; else return false; }
        }
        if (count != 0) return false;
        *length = l;
        return true;
    }
    return false;
}

// A URL wrapped in '…' or `…` keeps the wrapper out.
static void NPPTrimEnclosedUrl(const std::u32string &t, size_t start, size_t *length) {
    if (start == 0 || *length == 0) return;
    const char32_t before = t[start - 1], last = t[start + *length - 1];
    if ((before == '\'' && last == '\'') || (before == '`' && last == '`')) *length -= 1;
}

// ponytail: upstream hands the candidate to InternetCrackUrl; the only thing that really rejects in practice is a
// scheme with nothing after it ("http://"). Upgrade path: a real RFC 3986 authority/path parse if false positives show up.
static bool NPPUrlHasBody(const std::u32string &t, size_t start, size_t len, size_t schemeLen) {
    size_t i = start + schemeLen, end = start + len;
    if (i + 1 < end && t[i] == '/' && t[i + 1] == '/') i += 2;
    return i < end;
}

// N++ isUrl: true when a URL starts at `start`; *segmentLen* is its length, or the distance to the next candidate.
static bool NPPIsUrlAt(const std::u32string &t, size_t start, size_t *segmentLen,
                       const std::vector<std::u32string> &schemes) {
    *segmentLen = 0;
    if (start >= t.size()) return false;
    size_t dist = 0, schemeLen = 0;
    if (NPPScanToUrlStart(t, start, &dist, &schemeLen, schemes)) {
        if (dist) { *segmentLen = dist; return false; }
        size_t len = 0;
        NPPScanToUrlEnd(t, start + schemeLen, &len);
        if (len) {
            len += schemeLen;
            if (NPPUrlHasBody(t, start, len, schemeLen)) {
                NPPTrimEnclosedUrl(t, start, &len);
                while (NPPTrimTrailingUrlChar(&t[start], &len)) {}
                *segmentLen = len;
                return true;
            }
            *segmentLen = len;   // skip what looked like a URL rather than rescanning inside it
            return false;
        }
        len = 1;
        while (start + len < t.size() && NPPUrlSchemeStartChar(t[start + len])) len++;
        *segmentLen = len;
        return false;
    }
    *segmentLen = dist ? dist : 1;
    return false;
}

// Rebuilt only when NPPUriSchemes changes; the scan itself runs on every scroll. Main thread only, like everything here.
static const std::vector<std::u32string> &NPPCachedUrlSchemes(NSString *extra) {
    static NSString *cachedKey = nil;
    static std::vector<std::u32string> cached;
    if (!cachedKey || ![cachedKey isEqualToString:extra]) {
        cached = NPPUrlSchemes(extra);
        cachedKey = [extra copy];
    }
    return cached;
}

#pragma mark - Matched HTML/XML tags (N++ ScintillaComponent/xmlMatchedTagsHighlighter.cpp)

// Byte offsets into the scanned window. closeStart/closeEnd are -1 for a self-closing tag.
struct NPPXmlTags { long openStart = -1, nameEnd = -1, openEnd = -1, closeStart = -1, closeEnd = -1; };

struct NPPTagToken { long start = 0, nameStart = 0, nameEnd = 0, end = 0; bool isClose = false, isSelfClose = false; };

static bool NPPTagNameChar(char c, bool first) {
    if (isalpha((unsigned char)c) || c == '_' || c == ':' || (unsigned char)c >= 0x80) return true;
    return !first && (isdigit((unsigned char)c) || c == '-' || c == '.');
}

// Parses the markup construct starting at t[i] == '<'. Returns false for comments / PIs / doctypes (which are still
// consumed: *skipTo lands past them), true for an element tag.
static bool NPPParseTag(const std::string &t, long i, NPPTagToken &tok, long *skipTo) {
    const long n = (long)t.size();
    *skipTo = i + 1;
    if (i < 0 || i >= n || t[i] != '<') return false;
    if (i + 1 < n && t[i + 1] == '!') {
        size_t end = t.compare(i, 4, "<!--") == 0 ? t.find("-->", i + 4) : t.find('>', i + 2);
        *skipTo = end == std::string::npos ? n : (long)end + (t.compare(i, 4, "<!--") == 0 ? 3 : 1);
        return false;
    }
    if (i + 1 < n && t[i + 1] == '?') {
        size_t end = t.find("?>", i + 2);
        *skipTo = end == std::string::npos ? n : (long)end + 2;
        return false;
    }
    tok = NPPTagToken();
    tok.start = i;
    tok.isClose = i + 1 < n && t[i + 1] == '/';
    tok.nameStart = i + (tok.isClose ? 2 : 1);
    if (tok.nameStart >= n || !NPPTagNameChar(t[tok.nameStart], true)) return false;
    tok.nameEnd = tok.nameStart;
    while (tok.nameEnd < n && NPPTagNameChar(t[tok.nameEnd], false)) tok.nameEnd++;
    long p = tok.nameEnd;
    char quote = 0;
    while (p < n) {
        const char c = t[p];
        if (quote) { if (c == quote) quote = 0; }
        else if (c == '"' || c == '\'') quote = c;
        else if (c == '>') break;
        else if (c == '<') return false;   // unterminated tag
        p++;
    }
    if (p >= n) return false;
    tok.end = p + 1;
    tok.isSelfClose = !tok.isClose && p > tok.nameEnd && t[p - 1] == '/';
    *skipTo = tok.end;
    return true;
}

static bool NPPTagNamesEqual(const std::string &t, const NPPTagToken &a, const NPPTagToken &b) {
    if (a.nameEnd - a.nameStart != b.nameEnd - b.nameStart) return false;
    for (long k = 0; k < a.nameEnd - a.nameStart; k++)
        if (tolower((unsigned char)t[a.nameStart + k]) != tolower((unsigned char)t[b.nameStart + k])) return false;
    return true;
}

// N++ getXmlMatchedTagsPos, narrowed to the window `t`. `caret` is a byte offset into it.
// ponytail: a plain tag walk (comments, PIs and quoted attribute values are skipped, nothing else is). Upstream also
// understands <?php … ?> code zones and CDATA; the upgrade is teaching NPPParseTag those two constructs.
static bool NPPFindMatchedTags(const std::string &t, long caret, NPPXmlTags &out) {
    const long n = (long)t.size();
    if (n == 0) return false;
    caret = std::min(std::max(caret, 0L), n);
    if (caret > 0 && caret <= n && t[caret - 1] == '>') caret--;   // caret just past '>' still means "in this tag"

    // Upstream looks back for "<", rejects when a ">" comes first, and asks the lexer to ignore both when they are
    // styled as part of an attribute value or a comment. Parsing the tags gets that right without needing styles:
    // the caret is in a tag when a parsed tag spans it (strictly — upstream's backward search cannot match a "<" at
    // the caret, and a ">" before the caret ends the tag). The same pass finds the partner.
    std::vector<NPPTagToken> tags;
    long caretIndex = -1;
    for (long i = 0; i < n; ) {
        if (caretIndex < 0 && i >= caret) return false;   // every tag from here on starts at or after the caret
        if (t[i] != '<') { i++; continue; }
        NPPTagToken tok;
        long next = 0;
        if (NPPParseTag(t, i, tok, &next)) {
            if (tok.start < caret && caret < tok.end) caretIndex = (long)tags.size();
            tags.push_back(tok);
        }
        i = next > i ? next : i + 1;
    }
    if (caretIndex < 0) return false;
    const NPPTagToken &me = tags[(size_t)caretIndex];

    if (me.isSelfClose) {
        out.openStart = me.start; out.nameEnd = me.nameEnd; out.openEnd = me.end;
        return true;
    }
    if (!me.isClose) {
        int depth = 1;
        for (size_t k = (size_t)caretIndex + 1; k < tags.size(); k++) {
            if (tags[k].isSelfClose || !NPPTagNamesEqual(t, me, tags[k])) continue;
            depth += tags[k].isClose ? -1 : 1;
            if (depth == 0) {
                out.openStart = me.start; out.nameEnd = me.nameEnd; out.openEnd = me.end;
                out.closeStart = tags[k].start; out.closeEnd = tags[k].end;
                return true;
            }
        }
        return false;
    }
    int depth = 1;
    for (size_t k = (size_t)caretIndex; k-- > 0; ) {
        if (tags[k].isSelfClose || !NPPTagNamesEqual(t, me, tags[k])) continue;
        depth += tags[k].isClose ? 1 : -1;
        if (depth == 0) {
            out.openStart = tags[k].start; out.nameEnd = tags[k].nameEnd; out.openEnd = tags[k].end;
            out.closeStart = me.start; out.closeEnd = me.end;
            return true;
        }
    }
    return false;
}

// N++ getAttributesPos: the `name="value"` runs between the tag name and the tag's tail, byte offsets into `t`.
static std::vector<std::pair<long, long>> NPPTagAttributePositions(const std::string &t, long start, long end) {
    std::vector<std::pair<long, long>> attrs;
    if (start < 0 || end > (long)t.size() || end <= start) return attrs;
    enum { invalid, key, preAssign, assign, dquote, squote, value, valid } state = invalid;
    long startPos = -1, oneMore = 1, i = start;
    for (; i < end; ++i) {
        switch (t[i]) {
            case ' ': case '\t': case '\n': case '\r':
                if (state == key) state = preAssign;
                else if (state == value) { state = valid; oneMore = 0; }
                break;
            case '=':
                if (state == key || state == preAssign) state = assign;
                else if (state == assign || state == value) state = invalid;
                break;
            case '"':
                if (state == dquote) { state = valid; oneMore = 1; }
                else if (state == key || state == preAssign || state == value) state = invalid;
                else if (state == assign) state = dquote;
                break;
            case '\'':
                if (state == squote) { state = valid; oneMore = 1; }
                else if (state == key || state == preAssign || state == value) state = invalid;
                else if (state == assign) state = squote;
                break;
            default:
                if (state == invalid) { state = key; startPos = i; }
                else if (state == preAssign) state = invalid;
                else if (state == assign) state = value;
                break;
        }
        if (state == valid) { attrs.emplace_back(startPos, i + oneMore); state = invalid; }
    }
    if (state == value) attrs.emplace_back(startPos, i);
    return attrs;
}

#pragma mark - Advanced auto-indent (N++ Notepad_plus::maintainIndentation)

typedef NS_ENUM(NSInteger, NPPIndentFamily) { NPPIndentFamilyOther = 0, NPPIndentFamilyCLike, NPPIndentFamilyPython };

// N++ keys these off LangType; here off the langs.model.xml name.
static NPPIndentFamily NPPIndentFamilyForLanguage(NSString *name, BOOL *noSingleLineControl) {
    static NSSet *cLike, *noSingle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cLike = [NSSet setWithArray:@[@"c", @"cpp", @"cs", @"objc", @"java", @"php", @"javascript", @"javascript.js",
                                      @"jsp", @"css", @"perl", @"rust", @"powershell", @"json", @"json5",
                                      @"typescript", @"go", @"swift"]];
        noSingle = [NSSet setWithArray:@[@"perl", @"rust", @"powershell", @"json", @"json5"]];
    });
    NSString *n = name ?: @"";
    if (noSingleLineControl) *noSingleLineControl = [noSingle containsObject:n];
    if ([cLike containsObject:n]) return NPPIndentFamilyCLike;
    if ([n isEqualToString:@"python"]) return NPPIndentFamilyPython;
    return NPPIndentFamilyOther;
}

// N++ ScintillaEditView::isPythonStyleIndentation, which decides SC_IV_LOOKFORWARD vs SC_IV_LOOKBOTH for the
// indent guides. Upstream's name is narrower than its list: every language here has blocks whose guide should stop
// at the block, not be dragged back up by the line below it. Keyed off the langs.model.xml name, as elsewhere here.
static BOOL NPPUsesLookForwardIndentGuides(NSString *name) {
    static NSSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"python", @"coffeescript", @"haskell", @"c", @"cpp", @"objc", @"cs", @"java",
                                    @"php", @"javascript", @"javascript.js", @"makefile", @"asn1", @"gdscript"]];
    });
    return [set containsObject:name ?: @""];
}

static BOOL NPPLanguageIsMarkupForTags(NSString *name) {
    static NSSet *markup; static dispatch_once_t once;
    dispatch_once(&once, ^{ markup = [NSSet setWithArray:@[@"xml", @"html", @"php", @"asp", @"jsp"]]; });
    return [markup containsObject:name ?: @""];
}

// N++ isConditionExprLine: an if/for/while/else that runs to the end of the line.
// A word boundary is required at the front; upstream's unanchored search calls "myelse" a condition line.
static BOOL NPPIsConditionExprLine(const std::string &line) {
    if (line.empty()) return NO;
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"\\b((else[ \\t]+)?if|for|while)[ \\t]*\\(.*\\)[ \\t]*$|\\belse[ \\t]*$" options:0 error:nil];
    });
    NSString *s = [[NSString alloc] initWithBytes:line.data() length:line.size() encoding:NSUTF8StringEncoding];
    if (!s) return NO;
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}

// N++ maintainIndentation, C-like branch, newline case. Returns the new line's indentation in columns;
// *insertClosingLine is set for the "{|}" case, where N++ pushes the "}" onto a line of its own.
static long NPPAdvancedNewlineIndent(char prevChar, char nextChar, BOOL noSingleLineControl,
                                     const std::string &prevLine, const std::string &prevPrevLine,
                                     long prevIndent, long tabWidth, BOOL *insertClosingLine) {
    if (insertClosingLine) *insertClosingLine = NO;
    if (prevChar == '{') {
        if (nextChar == '}' && insertClosingLine) *insertClosingLine = YES;
        return prevIndent + tabWidth;
    }
    if (nextChar == '{') return prevIndent;
    if (noSingleLineControl) return prevIndent;
    if (NPPIsConditionExprLine(prevLine)) return prevIndent + tabWidth;
    if (prevIndent > 0 && NPPIsConditionExprLine(prevPrevLine)) return MAX(0L, prevIndent - tabWidth);
    return prevIndent;
}

// N++ maintainIndentation, Python branch: byte offset of a ':' that ends the line (a trailing comment is allowed),
// or -1. The caller still has to check the colon is styled as an operator, i.e. not inside a string.
static long NPPPythonBlockColonOffset(const std::string &line) {
    for (size_t i = 0; i < line.size(); ++i) {
        if (line[i] != ':') continue;
        size_t j = i + 1;
        while (j < line.size() && (line[j] == ' ' || line[j] == '\t')) j++;
        if (j >= line.size() || line[j] == '#') return (long)i;
    }
    return -1;
}

#pragma mark - Matched-character insertion (N++ AutoCompletion::insertMatchedChars + MatchedPairConf)

struct NPPMatchedPairConf {
    bool parentheses = true, brackets = true, curly = true, quotes = true, doubleQuotes = true;
    std::vector<std::pair<char, char>> userPairs;
    bool any() const { return parentheses || brackets || curly || quotes || doubleQuotes || !userPairs.empty(); }
};

static NPPMatchedPairConf NPPCurrentMatchedPairConf(void) {
    NPPMatchedPairConf c;
    c.parentheses  = NPPPrefBool(kKeyPairParentheses, YES);
    c.brackets     = NPPPrefBool(kKeyPairBrackets, YES);
    c.curly        = NPPPrefBool(kKeyPairCurly, YES);
    c.quotes       = NPPPrefBool(kKeyPairQuotes, YES);
    c.doubleQuotes = NPPPrefBool(kKeyPairDoubleQuotes, YES);
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:kKeyPairsUserDefined];
    if ([raw isKindOfClass:NSArray.class]) {
        for (id entry in (NSArray *)raw) {
            // "<>" — open then close, both single-byte (Scintilla reports the added character as a byte).
            if (![entry isKindOfClass:NSString.class] || [entry length] != 2) continue;
            unichar o = [entry characterAtIndex:0], cl = [entry characterAtIndex:1];
            if (o == 0 || o > 0x7F || cl == 0 || cl > 0x7F) continue;
            c.userPairs.emplace_back((char)o, (char)cl);
        }
    }
    return c;
}

#pragma mark - Untitled numbering

static std::set<NSInteger> &NPPUntitledNumbers() { static std::set<NSInteger> s; return s; }

#pragma mark - Live documents

// Three settings need to see past one buffer: "Highlight another view" paints into (and clears) the other view's
// editor, "use content as tab name" has to avoid a name another buffer already shows, and the right-click hook has
// to map a click back to the document that owns the editor under it. Weak, so a closed document drops out by itself.
static NSHashTable<NPPDocument *> *NPPLiveDocuments(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

#pragma mark - NPPDocument

@interface NPPDocument () {
    ScintillaView *_editor;
    NSInteger _untitledNumber;
    struct timespec _mtime;
    BOOL _hasMTime;
    BOOL _forcedDirty;             // "Convert to X" makes the buffer dirty without a text change (N++ isDirty=true)
    BOOL _languageChosenByUser;
    NSString *_userDefinedLanguageName;   // set when a UDL is applied instead of a built-in language
    BOOL _readOnlyBeforeMonitoring;
    BOOL _isLargeFile;             // N++ LargeFileRestriction: no styling, and the allow* keys decide the rest
    BOOL _tagMatchActive;          // tag indicators currently carry marks; avoids a document-wide clear per keystroke
    int _lineNumberDigits;
    sptr_t _urlScanFirstLine, _urlScanLength;   // last range fed to the URL scanner; SCN_UPDATEUI fires per keystroke
    dispatch_source_t _monitorSource;
    BOOL _monitorReloadPending;
    NPPLanguage *_language;
    NSString *_contentTabName;     // NPPUseContentAsTabName: first line of an untitled buffer, normalised
    BOOL _askedAboutRemoval;       // the "keep this file in editor?" question is asked once per disappearance
    BOOL _wasFileReadOnlyOnDisk;   // last seen read-only attribute, so a change to it can be noticed and reported
}
@end

@implementation NPPDocument {
    NSDate *_createdDate;
}

- (NSDate *)createdDate { return _createdDate ?: (_createdDate = NSDate.date); }
@synthesize editor = _editor;
@synthesize language = _language;

// One byte of an 8-bit code page as text (the Character panel). Lives here rather than next to the tables above
// because the header declares it on the class itself, and a category implementing a primary-class method is a
// warning (and, with a category loaded twice, a coin toss).
+ (NSString *)stringForByte:(unsigned char)byte codepage:(CFStringEncoding)codepage {
    if (byte < 0x80) return [NSString stringWithFormat:@"%c", byte];
    const NPPCodePage8Bit *cp = NPPCustomCodePage(codepage);
    if (cp) {
        UTF16Char u = cp->toUnicode[byte - 0x80];
        return u ? [NSString stringWithCharacters:&u length:1] : nil;
    }
    NSStringEncoding ns = CFStringConvertEncodingToNSStringEncoding(codepage);
    if (ns == kCFStringEncodingInvalidId) return nil;
    return [[NSString alloc] initWithBytes:&byte length:1 encoding:ns];
}

#pragma mark Untitled numbering
+ (NSInteger)claimUntitledNumber {
    NSInteger n = 1;
    while (NPPUntitledNumbers().count(n)) n++;
    NPPUntitledNumbers().insert(n);
    return n;
}
+ (void)releaseUntitledNumber:(NSInteger)n { NPPUntitledNumbers().erase(n); }

#pragma mark Init / dealloc
- (instancetype)initUntitled {
    if (!(self = [self initCommon])) return nil;
    NPPPreferences *p = NPPPreferences.shared;
    _untitledNumber = [NPPDocument claimUntitledNumber];
    _encoding = p.defaultEncoding;
    _eolMode = p.defaultEOL;
    NPPSci(_editor, SCI_SETEOLMODE, NPPSciEOLMode(_eolMode));
    NPPSci(_editor, SCI_SETSAVEPOINT);
    NPPSci(_editor, SCI_EMPTYUNDOBUFFER);
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error {
    if (!(self = [self initCommon])) return nil;
    if (![self loadFromURL:url error:error]) return nil;
    return self;
}

- (instancetype)initCommon {
    if (!(self = [super init])) return nil;
    _codepage = NPPSystemANSICodepage();
    _encoding = NPPEncodingUTF8;
    _eolMode = NPPEOLUnix;

    _editor = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    _editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _editor.delegate = self;
    [self setupEditor];

    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NPPLanguage *lang = [lm languageNamed:NPPPreferences.shared.defaultLanguageName] ?: lm.normalTextLanguage;
    [self applyLanguageInternal:lang];
    [self applyPreferences];

    [NPPLiveDocuments() addObject:self];
    [NPPDocument installEditorHooks];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(preferencesDidChange:) name:NPPPreferencesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(themeDidChange:) name:NPPThemeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(appDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:nil];
    // Scintilla Cocoa sizes its content view to the scroll width; with N++'s "scroll width tracking + width 1" the view is only as
    // wide as the longest line and clicks right of short lines never reach Scintilla. Keep the scroll width >= the visible width.
    NSClipView *clip = _editor.scrollView.contentView;
    clip.postsFrameChangedNotifications = YES;
    [nc addObserver:self selector:@selector(clipViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:clip];
    return self;
}

- (void)clipViewFrameDidChange:(NSNotification *)n {
    CGFloat w = NSWidth(_editor.scrollView.contentView.bounds);
    if (w > 0) NPPSci(_editor, SCI_SETSCROLLWIDTH, (uptr_t)w);   // tracking re-grows it to the longest line when needed
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopMonitoring];
    _editor.delegate = nil;
    if (_untitledNumber > 0) [NPPDocument releaseUntitledNumber:_untitledNumber];
}

- (void)preferencesDidChange:(NSNotification *)n { [self applyPreferences]; }
- (void)themeDidChange:(NSNotification *)n { [self applyThemeAndLanguage]; }

// Port of ScintillaEditView::init(): everything a fresh N++ editor gets before a language is applied.
- (void)setupEditor {
    ScintillaView *ed = _editor;
    NPPSci(ed, SCI_SETCODEPAGE, SC_CP_UTF8);
    NPPSci(ed, SCI_SETMODEVENTMASK, SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT | SC_PERFORMED_UNDO | SC_PERFORMED_REDO | SC_MOD_CHANGEFOLD);
    NPPSci(ed, SCI_SETSCROLLWIDTHTRACKING, 1);
    NPPSci(ed, SCI_SETSCROLLWIDTH, 600);   // raised to the visible width by clipViewFrameDidChange:
    NPPSci(ed, SCI_SETADDITIONALSELECTIONTYPING, 1);
    NPPSci(ed, SCI_SETMULTIPASTE, SC_MULTIPASTE_EACH);
    NPPSci(ed, SCI_SETVIRTUALSPACEOPTIONS, SCVS_RECTANGULARSELECTION);
    NPPSci(ed, SCI_SETPASTECONVERTENDINGS, 1);
    NPPSci(ed, SCI_SETBACKSPACEUNINDENTS, 1);
    NPPSci(ed, SCI_SETTABINDENTS, 1);
    NPPSci(ed, SCI_SETINDENT, 0);
    NPPSci(ed, SCI_SETLAYOUTCACHE, SC_CACHE_PAGE);
    NPPSci(ed, SCI_SETIDLESTYLING, SC_IDLESTYLING_TOVISIBLE);
    NPPSci(ed, SCI_USEPOPUP, SC_POPUP_TEXT);

    NPPSci(ed, SCI_SETMARGINS, 4);
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginLineNumber, SC_MARGIN_NUMBER);
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginSymbol, SC_MARGIN_SYMBOL);
    NPPSci(ed, SCI_SETMARGINMASKN, NPPMarginSymbol, (1 << NPPMarkBookmark) | (1 << NPPMarkHideUnderline) | (1 << NPPMarkHideBegin) | (1 << NPPMarkHideEnd));
    NPPSci(ed, SCI_SETMARGINSENSITIVEN, NPPMarginSymbol, 1);
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginFold, SC_MARGIN_SYMBOL);
    NPPSci(ed, SCI_SETMARGINMASKN, NPPMarginFold, (sptr_t)SC_MASK_FOLDERS);
    NPPSci(ed, SCI_SETMARGINSENSITIVEN, NPPMarginFold, 1);
    NPPSci(ed, SCI_SETMARGINTYPEN, NPPMarginChangeHistory, SC_MARGIN_SYMBOL);
    NPPSci(ed, SCI_SETMARGINMASKN, NPPMarginChangeHistory, SC_MASK_HISTORY);

    // Fold margin: box tree (N++ default), Scintilla handles clicks itself.
    NPPSci(ed, SCI_SETFOLDFLAGS, SC_FOLDFLAG_LINEAFTER_CONTRACTED);
    NPPSci(ed, SCI_SETAUTOMATICFOLD, SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER);

    // Bookmark / hide-lines markers. ponytail: Scintilla built-in shapes instead of N++'s RGBA images.
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkBookmark, SC_MARK_BOOKMARK);
    NPPSci(ed, SCI_MARKERSETFORE, NPPMarkBookmark, 0x00FFFFFF);   // BGR: white outline
    NPPSci(ed, SCI_MARKERSETBACK, NPPMarkBookmark, 0x00FF8000);   // BGR: blue fill like N++'s bookmark icon
    NPPSci(ed, SCI_MARKERSETALPHA, NPPMarkBookmark, 70);
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkHideUnderline, SC_MARK_UNDERLINE);
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkHideBegin, SC_MARK_ARROWDOWN);
    NPPSci(ed, SCI_MARKERDEFINE, NPPMarkHideEnd, SC_MARK_ARROW);

    // Smart highlight indicator (colors come from the theme's "Smart HighLighting" style via NPPLanguageManager).
    NPPSci(ed, SCI_INDICSETSTYLE, NPPIndicatorSmartHighlight, INDIC_ROUNDBOX);
    NPPSci(ed, SCI_INDICSETALPHA, NPPIndicatorSmartHighlight, 100);
    NPPSci(ed, SCI_INDICSETUNDER, NPPIndicatorSmartHighlight, 1);

    if (NPPPreferences.shared.showChangeHistoryMargin)
        NPPSci(ed, SCI_SETCHANGEHISTORY, SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS);
}

#pragma mark Preferences / theme
- (void)applyPreferences {
    NPPPreferences *p = NPPPreferences.shared;
    ScintillaView *ed = _editor;
    NPPSci(ed, SCI_SETTABWIDTH, (uptr_t)MAX(1, p.tabSize));
    NPPSci(ed, SCI_SETUSETABS, !p.replaceTabsBySpaces);
    // N++ LargeFileRestriction::_deactivateWordWrap — wrapping a huge buffer is what makes it unusable.
    BOOL wrap = p.wordWrap && !(self.restrictedAsLargeFile && NPPPrefBool(kKeyLargeNoWrap, YES));
    NPPSci(ed, SCI_SETWRAPMODE, wrap ? SC_WRAP_WORD : SC_WRAP_NONE);
    NPPSci(ed, SCI_SETWRAPVISUALFLAGS, p.showWrapSymbol ? SC_WRAPVISUALFLAG_END : SC_WRAPVISUALFLAG_NONE);
    NPPSci(ed, SCI_SETVIEWWS, p.showWhitespace ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE);
    NPPSci(ed, SCI_SETVIEWEOL, p.showEOL);
    [self applyIndentationGuides];
    NPPSci(ed, SCI_SETCARETLINEVISIBLE, p.highlightCurrentLine);
    NPPSci(ed, SCI_SETCARETLINEVISIBLEALWAYS, p.highlightCurrentLine);
    NPPSci(ed, SCI_SETCARETWIDTH, (uptr_t)MAX(1, MIN(20, p.caretWidth)));
    NPPSci(ed, SCI_SETCARETPERIOD, p.caretBlink ? 600 : 0);
    NPPSci(ed, SCI_SETEDGEMODE, p.showEdgeLine ? EDGE_LINE : EDGE_NONE);
    NPPSci(ed, SCI_SETEDGECOLUMN, (uptr_t)MAX(1, p.edgeColumn));
    NPPSci(ed, SCI_SETMULTIPLESELECTION, p.multiSelection);
    NPPSci(ed, SCI_SETENDATLASTLINE, !p.scrollBeyondLastLine);
    // ponytail: non-printing chars use Scintilla's default control-char mnemonics ([NUL] etc.) whether or not
    // "show non-printing" is on; N++'s extra C0/C1 representation set (SCI_SETREPRESENTATION) is the upgrade.
    NPPSci(ed, SCI_SETCONTROLCHARSYMBOL, 0);
    // N++ Notepad_plus.cpp: _doSmoothFont picks the LCD-optimised renderer, otherwise Scintilla's default.
    NPPSci(ed, SCI_SETFONTQUALITY, p.smoothFont ? SC_EFF_QUALITY_LCD_OPTIMIZED : SC_EFF_QUALITY_DEFAULT);
    // N++ NppBigSwitch NPPM_INTERNAL_SETDRAGDROP.
    NPPSci(ed, SCI_SETDRAGDROPENABLED, !p.disableSelectedTextDragDrop);
    [self applySelectionForeground];
    // "Disable advanced scrolling features (if you have touchpad problem)". Upstream's advanced scrolling is a
    // Win32 hack that forwards the wheel to whatever window is under the pointer; AppKit does that natively, so
    // what is left to switch off are the two trackpad heuristics that make a touchpad feel wrong in a code editor:
    // axis locking and rubber-band overscroll. ponytail: if a touchpad still misbehaves, the next knob is
    // NSScrollView.scrollsDynamically / the line-snapping in Scintilla's own -adjustScroll:.
    NSScrollView *sv = ed.scrollView;
    sv.usesPredominantAxisScrolling = !p.disableAdvancedScrolling;
    sv.horizontalScrollElasticity = p.disableAdvancedScrolling ? NSScrollElasticityNone : NSScrollElasticityAutomatic;
    sv.verticalScrollElasticity = p.disableAdvancedScrolling ? NSScrollElasticityNone : NSScrollElasticityAutomatic;

    NPPSci(ed, SCI_SETMARGINWIDTHN, NPPMarginSymbol, p.showBookmarkMargin ? 14 : 0);
    NPPSci(ed, SCI_SETMARGINWIDTHN, NPPMarginFold, p.showFoldMargin ? 14 : 0);
    NPPSci(ed, SCI_SETMARGINWIDTHN, NPPMarginChangeHistory, p.showChangeHistoryMargin ? 9 : 0);
    int wantHistory = p.showChangeHistoryMargin ? (SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS) : SC_CHANGE_HISTORY_DISABLED;
    if (NPPSci(ed, SCI_GETCHANGEHISTORY) != wantHistory) {
        // Scintilla only accepts a change-history switch while the undo buffer is empty; otherwise keep current state.
        if (NPPSci(ed, SCI_CANUNDO) == 0 && NPPSci(ed, SCI_CANREDO) == 0) NPPSci(ed, SCI_SETCHANGEHISTORY, wantHistory);
    }
    [self updateLineNumberMarginWidthForced:YES];
    [self rescanClickableLinks];   // NPPStyleURL / NPPUriSchemes may have changed
    [self tagMatch];               // so does NPPTagMatchHighlight: clear at once instead of on the next caret move
    [self updateContentTabName];   // NPPUseContentAsTabName may have just been switched on or off
}

// N++ ScintillaEditView::performGlobalStyles: the three selection *text* elements are only coloured when
// _selectedTextForegroundSingleColor is on — otherwise selected text keeps its own syntax colours. Applying a
// language or a theme resets element colours, so this runs again from -applyLanguageInternal / -applyThemeAndLanguage.
- (void)applySelectionForeground {
    ScintillaView *ed = _editor;
    // Upstream starts from black and only overwrites it when the theme carries a colour, so a theme that leaves the
    // attribute out still gets a visible effect instead of a checkbox that does nothing.
    NPPStyle *style = [NPPLanguageManager.shared globalStyleNamed:@"Selected text colour"];
    const long fore = (style && style.fgColor != -1) ? style.fgColor : 0;
    const BOOL on = NPPPreferences.shared.selectedTextForegroundSingleColor;
    for (int element : {SC_ELEMENT_SELECTION_TEXT, SC_ELEMENT_SELECTION_INACTIVE_TEXT, SC_ELEMENT_SELECTION_ADDITIONAL_TEXT}) {
        if (on) NPPSci(ed, SCI_SETELEMENTCOLOUR, (uptr_t)element, fore | 0xFF000000L);
        else NPPSci(ed, SCI_RESETELEMENTCOLOUR, (uptr_t)element);
    }
}

// The scan is cached on (first visible line, document length), so anything else that changes the answer — the
// scheme list, the URL style, the theme colour the indicator carries — has to drop the cache by hand.
- (void)rescanClickableLinks {
    _urlScanFirstLine = _urlScanLength = -1;
    [self updateClickableLinks];
}

- (BOOL)isLargeFile { return _isLargeFile; }

// User-defined languages live in an optional feature module; look it up by name so this file has no build dependency on it.
- (nullable NSString *)userDefinedLanguageNameForURL:(NSURL *)url {
    id mgr = [NSClassFromString(@"NPPUserDefinedLanguages") respondsToSelector:@selector(shared)]
             ? [NSClassFromString(@"NPPUserDefinedLanguages") performSelector:@selector(shared)] : nil;
    if (![mgr respondsToSelector:@selector(userLanguageNameForFileURL:)]) return nil;
    return [mgr performSelector:@selector(userLanguageNameForFileURL:) withObject:url];
}

- (BOOL)applyUserDefinedLanguageNamed:(NSString *)name {
    id mgr = [NSClassFromString(@"NPPUserDefinedLanguages") respondsToSelector:@selector(shared)]
             ? [NSClassFromString(@"NPPUserDefinedLanguages") performSelector:@selector(shared)] : nil;
    if (![mgr respondsToSelector:@selector(applyUserLanguageNamed:toEditor:)]) return NO;
    NSMethodSignature *sig = [mgr methodSignatureForSelector:@selector(applyUserLanguageNamed:toEditor:)];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = mgr;
    inv.selector = @selector(applyUserLanguageNamed:toEditor:);
    ScintillaView *ed = _editor;
    [inv setArgument:&name atIndex:2];
    [inv setArgument:&ed atIndex:3];
    [inv invoke];
    BOOL ok = NO;
    [inv getReturnValue:&ok];
    if (ok) {
        _userDefinedLanguageName = [name copy];
        [self applyIndentationGuides];
        [self updateLineNumberMarginWidthForced:NO];
        [self reapplyLanguageSensitivePreferences];
        [self notifyMetadata];
    }
    return ok;
}

- (nullable NSString *)userDefinedLanguageName { return _userDefinedLanguageName; }

- (void)applyThemeAndLanguage {
    [NPPLanguageManager.shared applyLanguage:(_language ?: NPPLanguageManager.shared.normalTextLanguage) toEditor:_editor];
    [self updateLineNumberMarginWidthForced:YES];
    [self applySelectionForeground];   // the new theme just moved "Selected text colour"
    // The URL indicator paints in STYLE_DEFAULT's foreground (SC_INDICFLAG_VALUEFORE), which the new theme just moved;
    // already-filled ranges keep the old value, so they have to be laid down again.
    [self rescanClickableLinks];
}

// N++ ScintillaEditView::updateLineNumberWidth: width of (digits+1) '9's in STYLE_LINENUMBER. "Dynamic" counts the
// digits of the last *visible* line (min 3), so the margin grows as you scroll into five-digit territory;
// "constant" counts the whole document's lines (min 4) and never moves while scrolling.
- (void)updateLineNumberMarginWidthForced:(BOOL)forced {
    if (!NPPPreferences.shared.showLineNumbers) {
        NPPSci(_editor, SCI_SETMARGINWIDTHN, NPPMarginLineNumber, 0);
        _lineNumberDigits = 0;
        return;
    }
    int digits;
    if (NPPPreferences.shared.lineNumberDynamicWidth) {
        sptr_t lastVisible = NPPSci(_editor, SCI_GETFIRSTVISIBLELINE) + NPPSci(_editor, SCI_LINESONSCREEN) + 1;
        digits = MAX(3, NPPDigits(NPPSci(_editor, SCI_DOCLINEFROMVISIBLE, (uptr_t)lastVisible) + 1));
    } else {
        digits = MAX(4, NPPDigits(NPPSci(_editor, SCI_GETLINECOUNT)));
    }
    if (!forced && digits == _lineNumberDigits) return;
    _lineNumberDigits = digits;
    std::string nines((size_t)digits + 1, '9');
    sptr_t w = NPPSciStr(_editor, SCI_TEXTWIDTH, STYLE_LINENUMBER, nines.c_str());
    NPPSci(_editor, SCI_SETMARGINWIDTHN, NPPMarginLineNumber, (sptr_t)w);
}

#pragma mark Properties
- (BOOL)isUntitled { return _fileURL == nil; }
- (NSString *)displayName {
    if (_fileURL) return _fileURL.lastPathComponent;
    return _contentTabName ?: [NSString stringWithFormat:@"new %ld", (long)_untitledNumber];
}
- (NSString *)contentDerivedTabName { return _contentTabName; }

// N++ Notepad_plus::useFirstLineAsTabName. Only line 0 of an untitled buffer, and only when no other open buffer
// already shows that name (upstream refuses the rename in that case, so the previous name stays).
- (void)updateContentTabName {
    NSString *name = nil;
    if (!_fileURL && NPPPreferences.shared.useContentAsTabName) {
        // Capped: a minified file's "first line" can be the whole 72 MB, and a tab can only show ~60 characters.
        const sptr_t end = MIN(NPPSci(_editor, SCI_GETLINEENDPOSITION, 0), (sptr_t)512);
        name = NPPTabNameFromFirstLine(NPPSciGetRange(_editor, 0, MAX((sptr_t)0, end)));
        for (NPPDocument *d in NPPLiveDocuments())
            if (d != self && [d.displayName isEqualToString:name]) { name = _contentTabName; break; }
    }
    if (name == _contentTabName || [name isEqualToString:_contentTabName]) return;
    _contentTabName = [name copy];
    [self notifyMetadata];   // the tab bar and the window title read -displayName
}
- (BOOL)isDirty { return _forcedDirty || NPPSci(_editor, SCI_GETMODIFY) != 0; }
- (BOOL)isFileReadOnlyOnDisk {
    NSString *path = _fileURL.path;
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) return NO;
    return ![NSFileManager.defaultManager isWritableFileAtPath:path];
}
- (NSDate *)lastKnownModificationDate {
    if (!_hasMTime) return nil;
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)_mtime.tv_sec + _mtime.tv_nsec / 1e9];
}

- (void)setFileURL:(NSURL *)fileURL {
    _fileURL = [fileURL copy];
    if (_fileURL && _untitledNumber > 0) { [NPPDocument releaseUntitledNumber:_untitledNumber]; _untitledNumber = 0; }
    else if (!_fileURL && _untitledNumber == 0) _untitledNumber = [NPPDocument claimUntitledNumber];
    _contentTabName = nil;      // a saved buffer is named by its file; a fresh untitled one starts over
    _askedAboutRemoval = NO;
}

- (void)notifyMetadata { [self.delegate documentDidChangeMetadata:self]; }
- (void)notifyDirty { [self.delegate documentDidChangeDirtyState:self]; }

- (void)updateReadOnlyState {
    _wasFileReadOnlyOnDisk = self.isFileReadOnlyOnDisk;
    NPPSci(_editor, SCI_SETREADONLY, _isReadOnly || _isMonitoring || _wasFileReadOnlyOnDisk);
}

// N++ Buffer::checkFileState re-reads the file's attributes while the buffer is open, so a file that is made
// read-only under you locks the editor instead of taking edits it can never write back (and one that is unlocked
// frees it again). The port checked once, at load. ponytail: upstream polls on a timer; here the re-check rides
// the event that already re-examines every open file — the app coming to the front — plus every save. A shared
// timer is the upgrade if the change has to be noticed while the app just sits there.
- (void)recheckFileReadOnlyState {
    if (!_fileURL) return;
    BOOL was = _wasFileReadOnlyOnDisk;
    [self updateReadOnlyState];
    if (was != _wasFileReadOnlyOnDisk) [self notifyMetadata];   // status bar, and the Edit menu's read-only mark
}
- (void)setIsReadOnly:(BOOL)ro {
    _isReadOnly = ro;
    [self updateReadOnlyState];
    [self notifyMetadata];
}

- (void)setEncoding:(NPPEncoding)encoding {
    if (encoding == _encoding) return;
    _encoding = encoding;
    _forcedDirty = YES;   // N++: "Convert to" marks the buffer dirty
    [self notifyDirty];
    [self notifyMetadata];
}
- (void)setCodepage:(CFStringEncoding)codepage {
    if (codepage == _codepage) return;
    _codepage = codepage;
    if (_encoding == NPPEncodingANSI) { _forcedDirty = YES; [self notifyDirty]; }
    [self notifyMetadata];
}
- (void)setEolMode:(NPPEOL)eolMode {
    _eolMode = eolMode;
    NPPSci(_editor, SCI_SETEOLMODE, NPPSciEOLMode(eolMode));
    [self notifyMetadata];
}
- (void)convertEOLTo:(NPPEOL)eol {
    NPPSci(_editor, SCI_BEGINUNDOACTION);
    NPPSci(_editor, SCI_CONVERTEOLS, NPPSciEOLMode(eol));
    NPPSci(_editor, SCI_ENDUNDOACTION);
    self.eolMode = eol;
}

- (void)setLanguage:(NPPLanguage *)language {
    if (!language) language = NPPLanguageManager.shared.normalTextLanguage;
    if (language != _language) _languageChosenByUser = YES;
    _userDefinedLanguageName = nil;
    [self applyLanguageInternal:language];
    [self notifyMetadata];
}
// The guide mode is per language, so it is re-applied wherever the language can change, not only from -applyPreferences.
- (void)applyIndentationGuides {
    // A user-defined language is not one of upstream's LangTypes, so it takes the general mode.
    NSString *name = _userDefinedLanguageName ? nil : _language.name;
    int mode = NPPUsesLookForwardIndentGuides(name) ? SC_IV_LOOKFORWARD : SC_IV_LOOKBOTH;
    NPPSci(_editor, SCI_SETINDENTATIONGUIDES, NPPPreferences.shared.showIndentGuides ? mode : SC_IV_NONE);
}

- (void)applyLanguageInternal:(NPPLanguage *)language {
    _language = language;
    [NPPLanguageManager.shared applyLanguage:language toEditor:_editor];
    [self applyIndentationGuides];
    [self updateLineNumberMarginWidthForced:YES];
    [self reapplyLanguageSensitivePreferences];
    [self applySelectionForeground];
}

// Preferences > Delimiter (NppGUI::_isWordCharDefault / _customWordChars) feeds SCI_SETWORDCHARS, but applying a
// language resets the lexer's word-character set, so the custom characters have to go back on afterwards.
// NPPPreferences owns that (it has to remember the lexer's own set to restore it when "use default" comes back);
// duplicating the bookkeeping here would make it remember an already-augmented set. Same call it makes on a tab switch.
- (void)reapplyLanguageSensitivePreferences {
    SEL sel = NSSelectorFromString(@"applyLanguageSensitiveSettingsToEditor:languageName:");
    NPPPreferences *p = NPPPreferences.shared;
    if (![p respondsToSelector:sel]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [p performSelector:sel withObject:_editor withObject:(_userDefinedLanguageName ?: _language.name)];
#pragma clang diagnostic pop
}

- (void)setTabColor:(NSColor *)tabColor {
    _tabColor = tabColor;
    [self notifyMetadata];
}

- (NSString *)encodingDisplayName {
    switch (_encoding) {
        case NPPEncodingUTF8: return @"UTF-8";
        case NPPEncodingUTF8BOM: return @"UTF-8-BOM";
        case NPPEncodingUTF16LE: return @"UTF-16 LE BOM";
        case NPPEncodingUTF16BE: return @"UTF-16 BE BOM";
        case NPPEncodingANSI: {
            if (_codepage == NPPSystemANSICodepage()) return @"ANSI";
            NPPCharset *cs = [NPPCharset charsetForCFEncoding:_codepage];
            return cs ? cs.displayName : @"ANSI";
        }
    }
    return @"ANSI";
}
- (NSString *)eolDisplayName {
    switch (_eolMode) {
        case NPPEOLWindows: return @"Windows (CR LF)";
        case NPPEOLMac: return @"Macintosh (CR)";
        default: return @"Unix (LF)";
    }
}

#pragma mark Loading
// Decodes `data` per BOM / declared charset / UTF-8 validity / uchardet, filling encoding+codepage. Returns UTF-8
// bytes for Scintilla. `declared` is what an HTML/XML header said about itself (kCFStringEncodingInvalidId = nothing).
- (std::string)decodeData:(NSData *)data declared:(CFStringEncoding)declared
                 encoding:(NPPEncoding *)encOut codepage:(CFStringEncoding *)cpOut {
    const uint8_t *p = (const uint8_t *)data.bytes;
    size_t n = data.length;
    std::string utf8;
    if (n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) {
        *encOut = NPPEncodingUTF8BOM;
        utf8.assign((const char *)p + 3, n - 3);
        return utf8;
    }
    if (n >= 2 && ((p[0] == 0xFF && p[1] == 0xFE) || (p[0] == 0xFE && p[1] == 0xFF))) {
        BOOL le = p[0] == 0xFF;
        *encOut = le ? NPPEncodingUTF16LE : NPPEncodingUTF16BE;
        size_t body = (n - 2) & ~(size_t)1;   // drop a dangling odd byte rather than fail
        if (!NPPDecodeBytes(p + 2, body, le ? kCFStringEncodingUTF16LE : kCFStringEncodingUTF16BE, utf8)) {
            // Invalid surrogates: fall back to Latin-1 so the user still sees something (N++ shows garbage too).
            NPPDecodeBytes(p + 2, n - 2, kCFStringEncodingISOLatin1, utf8);
        }
        return utf8;
    }
    // No BOM: what the file declares about itself wins over both detectors (upstream only runs them when the
    // declared encoding is still -1). A declaration the bytes then refuse to decode is dropped, not forced.
    if (declared != kCFStringEncodingInvalidId) {
        if (declared == kCFStringEncodingUTF8) {
            *encOut = NPPEncodingUTF8;
            utf8.assign((const char *)p, n);
            return utf8;
        }
        if (NPPDecodeBytes(p, n, declared, utf8)) {
            *encOut = NPPEncodingANSI;
            *cpOut = declared;
            return utf8;
        }
        utf8.clear();
    }
    bool ascii7 = false;
    if (NPPIsValidUTF8(p, n, &ascii7)) {
        // N++: pure 7-bit files open as UTF-8 only if "Apply to opened ANSI files" is on, else ANSI.
        if (ascii7 && !NPPPreferences.shared.openAnsiAsUTF8) *encOut = NPPEncodingANSI;
        else *encOut = NPPEncodingUTF8;
        utf8.assign((const char *)p, n);
        return utf8;
    }
    // 8-bit: uchardet, else the default code page.
    *encOut = NPPEncodingANSI;
    CFStringEncoding cp = kCFStringEncodingInvalidId;
    if (NPPPreferences.shared.detectEncodingWithUchardet) cp = NPPDetectWithUchardet(p, n);
    if (cp == kCFStringEncodingInvalidId || cp == kCFStringEncodingUTF8) cp = NPPSystemANSICodepage();
    if (!NPPDecodeBytes(p, n, cp, utf8)) {
        cp = NPPSystemANSICodepage();
        if (!NPPDecodeBytes(p, n, cp, utf8)) NPPDecodeBytes(p, n, kCFStringEncodingISOLatin1, utf8);   // lossless 8-bit
    }
    *cpOut = cp;
    return utf8;
}

// Replace the whole buffer without polluting undo/change history.
- (void)replaceAllText:(const std::string &)utf8 {
    ScintillaView *ed = _editor;
    sptr_t history = NPPSci(ed, SCI_GETCHANGEHISTORY);
    NPPSci(ed, SCI_SETREADONLY, 0);
    NPPSci(ed, SCI_SETUNDOCOLLECTION, 0);
    NPPSci(ed, SCI_SETCHANGEHISTORY, SC_CHANGE_HISTORY_DISABLED);
    NPPSci(ed, SCI_CLEARALL);
    if (!utf8.empty()) {
        NPPSci(ed, SCI_ALLOCATE, (uptr_t)utf8.size() + 1000);
        NPPSci(ed, SCI_APPENDTEXT, (uptr_t)utf8.size(), (sptr_t)utf8.data());
    }
    NPPSci(ed, SCI_SETUNDOCOLLECTION, 1);
    NPPSci(ed, SCI_EMPTYUNDOBUFFER);
    NPPSci(ed, SCI_SETSAVEPOINT);
    NPPSci(ed, SCI_SETCHANGEHISTORY, history);
}

- (BOOL)loadFromURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) {
        if (error) *error = NPPError(1, [NSString stringWithFormat:@"\"%@\" is not a file.", url], nil);
        return NO;
    }
    BOOL isDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDir] && isDir) {
        if (error) *error = NPPError(2, [NSString stringWithFormat:@"\"%@\" is a folder.", url.path], nil);
        return NO;
    }
    // N++ (Buffer.cpp loadFileData) asks before spending minutes on a 2 GB+ file. The size is taken from the
    // directory entry, before the read, so declining costs nothing.
    struct stat st;
    if (stat(url.path.fileSystemRepresentation, &st) == 0 && !NPPWantsToOpenHugeFile(url, (long long)st.st_size)) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        return NO;
    }
    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readErr];
    if (!data) {
        if (error) *error = NPPError(3, [NSString stringWithFormat:@"Cannot open file \"%@\".\n%@", url.path, readErr.localizedDescription ?: @""], readErr);
        return NO;
    }

    // N++ doOpen: the charset an .html / .xml file declares in its own header is read before the file is loaded,
    // and the language it is keyed off is the one the *extension* gives (getHtmlXmlEncoding takes no other input).
    NPPLanguage *extLang = [NPPLanguageManager.shared languageForFileURL:url];
    CFStringEncoding declared = kCFStringEncodingInvalidId;
    BOOL isXml = [extLang.name isEqualToString:@"xml"];
    if (isXml || [extLang.name isEqualToString:@"html"])
        declared = NPPDeclaredCharset((const uint8_t *)data.bytes, data.length, isXml);

    NPPEncoding enc = NPPEncodingUTF8;
    CFStringEncoding cp = _codepage;
    std::string utf8 = [self decodeData:data declared:declared encoding:&enc codepage:&cp];
    _encoding = enc;
    _codepage = cp;
    _eolMode = NPPDetectEOL(utf8.data(), utf8.size(), NPPPreferences.shared.defaultEOL);
    _isLargeFile = NPPFileIsLargeFile((long long)data.length);
    _urlScanFirstLine = _urlScanLength = -1;

    ScintillaView *ed = _editor;
    NPPSci(ed, SCI_SETMODEVENTMASK, 0);
    NPPSci(ed, SCI_SETEOLMODE, NPPSciEOLMode(_eolMode));
    [self replaceAllText:utf8];
    NPPSci(ed, SCI_SETMODEVENTMASK, SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT | SC_PERFORMED_UNDO | SC_PERFORMED_REDO | SC_MOD_CHANGEFOLD);
    NPPSci(ed, SCI_GOTOPOS, 0);

    self.fileURL = url;
    _forcedDirty = NO;
    _languageChosenByUser = NO;
    _hasMTime = NPPFileModTime(url, &_mtime);
    // _isLargeFile only just became known and the switch it gates (word wrap) lives in -applyPreferences.
    // Before the language, so the per-language indent override re-applied there still wins.
    [self applyPreferences];

    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NPPLanguage *lang = lm.normalTextLanguage;
    NSString *udlName = nil;
    if (!_isLargeFile) {
        udlName = [self userDefinedLanguageNameForURL:url];   // a UDL extension wins, as in N++
        lang = extLang;
        if (!lang && !utf8.empty()) lang = [lm languageForFirstLine:[NSData dataWithBytes:utf8.data() length:MIN(utf8.size(), (size_t)1024)]];
        if (!lang) lang = lm.normalTextLanguage;
    }
    [self applyLanguageInternal:lang];
    if (udlName) [self applyUserDefinedLanguageNamed:udlName];
    [self updateReadOnlyState];
    [self notifyDirty];
    [self notifyMetadata];
    return YES;
}

- (BOOL)reloadFromDisk:(NSError **)error {
    if (!_fileURL) {
        if (error) *error = NPPError(4, @"This document has never been saved.", nil);
        return NO;
    }
    ScintillaView *ed = _editor;
    sptr_t firstVisible = NPPSci(ed, SCI_GETFIRSTVISIBLELINE);
    sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    BOOL userChosen = _languageChosenByUser;
    NPPLanguage *lang = _language;
    if (![self loadFromURL:_fileURL error:error]) return NO;
    if (userChosen && lang && lang != _language && !_isLargeFile) { _languageChosenByUser = YES; [self applyLanguageInternal:lang]; }
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)MIN(caret, NPPSci(ed, SCI_GETLENGTH)));
    NPPSci(ed, SCI_SETFIRSTVISIBLELINE, (uptr_t)MAX((sptr_t)0, MIN(firstVisible, NPPSci(ed, SCI_GETLINECOUNT) - 1)));
    return YES;
}

- (BOOL)fileChangedOnDiskSinceLoad {
    if (!_fileURL || !_hasMTime) return NO;
    struct timespec now;
    if (!NPPFileModTime(_fileURL, &now)) return YES;   // vanished / renamed
    return now.tv_sec != _mtime.tv_sec || now.tv_nsec != _mtime.tv_nsec;
}

#pragma mark Saving
- (void)trimTrailingWhitespace {
    ScintillaView *ed = _editor;
    sptr_t lines = NPPSci(ed, SCI_GETLINECOUNT);
    NPPSci(ed, SCI_BEGINUNDOACTION);
    for (sptr_t line = lines - 1; line >= 0; line--) {
        sptr_t start = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)line);
        sptr_t end = NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)line);
        sptr_t i = end;
        while (i > start) {
            int c = (int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)(i - 1));
            if (c == ' ' || c == '\t') i--; else break;
        }
        if (i < end) {
            NPPSci(ed, SCI_SETTARGETRANGE, (uptr_t)i, end);
            NPPSciStr(ed, SCI_REPLACETARGET, 0, "");
        }
    }
    NPPSci(ed, SCI_ENDUNDOACTION);
}

- (NSData *)encodedDataForSave {
    std::string utf8 = NPPSciGetText(_editor);
    switch (_encoding) {
        case NPPEncodingUTF8:
            return [NSData dataWithBytes:utf8.data() length:utf8.size()];
        case NPPEncodingUTF8BOM: {
            NSMutableData *d = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
            [d appendBytes:utf8.data() length:utf8.size()];
            return d;
        }
        case NPPEncodingUTF16LE:
        case NPPEncodingUTF16BE: {
            BOOL le = _encoding == NPPEncodingUTF16LE;
            NSMutableData *d = [NSMutableData dataWithBytes:(le ? "\xFF\xFE" : "\xFE\xFF") length:2];
            NSString *s = [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding]
                          ?: [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSISOLatin1StringEncoding];
            NSData *body = [s dataUsingEncoding:(le ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding) allowLossyConversion:YES];
            if (body) [d appendData:body];
            return d;
        }
        case NPPEncodingANSI: {
            NSString *s = [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding]
                          ?: [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSISOLatin1StringEncoding];
            if (const NPPCodePage8Bit *cp = NPPCustomCodePage(_codepage)) return NPPEncodeWithCodePage(s, cp);
            NSStringEncoding nsEnc = CFStringConvertEncodingToNSStringEncoding(_codepage);
            NSData *body = nsEnc ? [s dataUsingEncoding:nsEnc allowLossyConversion:YES] : nil;
            if (!body) body = [s dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:YES];
            return body ?: [NSData data];
        }
    }
    return [NSData dataWithBytes:utf8.data() length:utf8.size()];
}

// A symlink is a path *to* the user's file, not the file: N++ opens and rewrites whatever the name resolves to.
// Writing the link itself would either flatten it into a regular file (what -writeToURL:NSDataWritingAtomic does)
// or fail outright (-replaceItemAtURL: answers "the file doesn't exist"), so the destination is resolved first.
// Only a link is resolved — a plain name is handed back untouched — so an ordinary save never reports a path the
// user did not type, and the buffer keeps the link as its fileURL either way.
static NSURL *NPPResolveSymlink(NSURL *url) {
    NSString *path = url.path;
    if (!path) return url;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISLNK(st.st_mode)) return url;
    char resolved[PATH_MAX] = {0};
    if (!realpath(path.fileSystemRepresentation, resolved)) return url;
    return [NSURL fileURLWithPath:[NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved
                                                                                           length:strlen(resolved)]];
}

// N++ (NppIO.cpp fileSave) refuses to save a file that carries the read-only attribute and tells the user to remove
// it first. On macOS the same state is a mode without a write bit or a Finder "Locked" flag, both of which the
// owner can clear, so the port offers to do it instead of only saying no. Declining leaves the file untouched.
// The self-check drives this decision headlessly; nothing else ever changes it.
typedef NS_ENUM(NSInteger, NPPReadOnlySavePolicy) {
    NPPReadOnlySaveAsk = 0, NPPReadOnlySaveAlwaysDecline, NPPReadOnlySaveAlwaysAccept
};
static NPPReadOnlySavePolicy NPPReadOnlySavePolicyForSave = NPPReadOnlySaveAsk;

// Clears the read-only attribute the way the alert promises: the immutable ("Locked") flag first, then a write bit
// for the owner. Returns whether the file is writable afterwards — an ACL or another user's file still says no.
static BOOL NPPMakeFileWritable(NSURL *url) {
    const char *path = url.path.fileSystemRepresentation;
    if (!path) return NO;
    struct stat st;
    if (stat(path, &st) != 0) return NO;
    if (st.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE))
        chflags(path, st.st_flags & ~(unsigned int)(UF_IMMUTABLE | SF_IMMUTABLE));   // SF_ needs root; try anyway
    chmod(path, (st.st_mode & 07777) | S_IWUSR);
    return access(path, W_OK) == 0;
}

- (BOOL)confirmWritableDestination:(NSURL *)url error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:url.path] || [fm isWritableFileAtPath:url.path]) return YES;
    BOOL declined = NPPReadOnlySavePolicyForSave != NPPReadOnlySaveAlwaysAccept;
    if (NPPReadOnlySavePolicyForSave == NPPReadOnlySaveAsk) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"The file is read-only";
        alert.informativeText = [NSString stringWithFormat:
            @"\"%@\" is read-only.\nRemove the read-only attribute and save anyway?", url.path];
        [alert addButtonWithTitle:@"Remove Read-Only and Save"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) declined = NO;
    }
    if (declined) {
        // Cancelled, not broken — but the caller reports any failure, so say which one this is instead of
        // letting it read as the generic "the operation couldn't be completed".
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"\"%@\" is read-only and was left as it is.", url.path]}];
        return NO;
    }
    if (NPPMakeFileWritable(url)) return YES;
    if (error) *error = NPPError(6, [NSString stringWithFormat:
        @"Cannot save file \"%@\".\nThe read-only attribute could not be removed.", url.path], nil);
    return NO;
}

// Writes the file the way N++ does — through the identity of the file that is already there — while keeping the
// crash safety of an atomic write. -[NSData writeToURL:options:NSDataWritingAtomic] gives only the second half: it
// leaves a *brand new* inode, so the creation date becomes now and every extended attribute (Finder tags, "where
// from", quarantine, provenance) is gone.
//
// -replaceItemAtURL: is the atomic swap that carries the original's creation date, extended attributes and ACL onto
// the replacement. The POSIX mode it only carries when it can also set the group — i.e. never for a file whose group
// is not one of yours, which is everything in /tmp and most shared directories — and the mode then comes back as the
// staging file's 0600. So the mode is put on the staged file by hand, after its content is written and before it is
// swapped in. Returns NO with *swapRefused set when the data reached the staging file and only the exchange was
// turned down: that is the one failure it is safe to retry in place. A failure to write the *data* (a full disk) is
// not — retrying that in place is how a clean "save failed" becomes a truncated file.
static BOOL NPPAtomicReplace(NSData *data, NSURL *dest, const struct stat *st, BOOL *swapRefused, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    // The staging file has to share the destination's volume for the exchange to be atomic; that is what
    // NSItemReplacementDirectory is for. It is a directory of its own, so it is taken away again afterwards.
    NSURL *stagingDir = [fm URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                          appropriateForURL:dest create:YES error:err];
    if (!stagingDir) { *swapRefused = YES; return NO; }   // nowhere to stage: the file itself is the only way left
    NSURL *staged = [stagingDir URLByAppendingPathComponent:dest.lastPathComponent];
    BOOL ok = [data writeToURL:staged options:0 error:err];
    if (ok) {
        const char *sp = staged.path.fileSystemRepresentation;
        if (sp) {
            chmod(sp, st->st_mode & 07777);
            chown(sp, (uid_t)-1, st->st_gid);   // best effort: a group that is not ours is not ours to hand over
        }
        *swapRefused = ![fm replaceItemAtURL:dest withItemAtURL:staged backupItemName:nil options:0
                             resultingItemURL:NULL error:err];
        ok = !*swapRefused;
    }
    [fm removeItemAtURL:stagingDir error:NULL];
    return ok;
}

// N++'s own answer, and the only one left when the swap above is impossible or wrong: open the file and rewrite it.
// The swap is refused by a volume that cannot do it (network, FAT), by an ACL that forbids deleting the file and by
// an unwritable directory holding a writable file — and it is the wrong answer for a file with a second hard link,
// which it would silently detach from its other name, leaving that name on the old content.
// NSFileHandle opens without truncating and the truncate comes last, so a crash leaves the new text plus the tail
// of the old, never an empty file.
// ponytail: that is still not atomic — a full disk in the middle leaves the file half new, half old. Nothing on
// macOS is both in-place and atomic; where a choice has to be made the hard link and the metadata win, because the
// alternative quietly detaches the file the user is editing from its other name. Writing to a copy on the same
// volume and cloning it back (clonefile) would narrow the window if it ever matters.
static BOOL NPPRewriteInPlace(NSData *data, NSURL *dest, NSError **err) {
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:dest error:err];
    if (!fh) return NO;
    return [fh writeData:data error:err] && [fh truncateAtOffset:data.length error:err] && [fh closeAndReturnError:err];
}

- (BOOL)writeData:(NSData *)data toURL:(NSURL *)url error:(NSError **)error {
    NSURL *dest = NPPResolveSymlink(url);
    if (![self confirmWritableDestination:dest error:error]) return NO;   // may clear the attribute, so stat after

    struct stat st;
    const char *path = dest.path.fileSystemRepresentation;
    const BOOL exists = path && stat(path, &st) == 0;
    NSError *writeErr = nil;
    BOOL swapRefused = exists;   // a hard link, a fifo or a device is rewritten, never exchanged
    BOOL ok = NO;
    if (exists && S_ISREG(st.st_mode) && st.st_nlink == 1) {
        swapRefused = NO;
        ok = NPPAtomicReplace(data, dest, &st, &swapRefused, &writeErr);
    }
    if (!ok && swapRefused) ok = NPPRewriteInPlace(data, dest, &writeErr);
    if (!ok && !exists) ok = [data writeToURL:dest options:NSDataWritingAtomic error:&writeErr];   // no metadata to keep
    if (!ok) {
        if (error) *error = NPPError(5, [NSString stringWithFormat:@"Cannot save file \"%@\".\n%@", dest.path,
                                         writeErr.localizedDescription ?: @""], writeErr);
        return NO;
    }
    return YES;
}

- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error {
    // Before anything else changes: a declined save must leave the buffer exactly as it was, and "trim trailing
    // space on save" below edits it. -writeData: asks again, and by then the answer costs nothing (the file is
    // writable) or never gets there (the user said no).
    if (![self confirmWritableDestination:NPPResolveSymlink(url) error:error]) return NO;
    [NSNotificationCenter.defaultCenter postNotificationName:NPPDocumentWillSaveNotification object:self
                                                    userInfo:url ? @{@"url": url} : @{}];
    if (NPPPreferences.shared.trimTrailingSpaceOnSave) {
        BOOL wasRO = NPPSci(_editor, SCI_GETREADONLY) != 0;
        if (wasRO) NPPSci(_editor, SCI_SETREADONLY, 0);
        [self trimTrailingWhitespace];
        if (wasRO) NPPSci(_editor, SCI_SETREADONLY, 1);
    }
    if (![self writeData:[self encodedDataForSave] toURL:url error:error]) return NO;

    BOOL wasUntitled = self.isUntitled;
    NSString *oldExt = _fileURL.pathExtension.lowercaseString ?: @"";
    self.fileURL = url;
    NPPSci(_editor, SCI_SETSAVEPOINT);
    _forcedDirty = NO;
    _hasMTime = NPPFileModTime(url, &_mtime);

    NPPLanguageManager *lm = NPPLanguageManager.shared;
    BOOL extChanged = ![oldExt isEqualToString:url.pathExtension.lowercaseString ?: @""];
    if (!_isLargeFile && !_languageChosenByUser && (wasUntitled || extChanged || _language == lm.normalTextLanguage)) {
        NPPLanguage *lang = [lm languageForFileURL:url];
        if (!lang && wasUntitled) {
            std::string head = NPPSciGetRange(_editor, 0, 1024);
            lang = [lm languageForFirstLine:[NSData dataWithBytes:head.data() length:head.size()]];
        }
        if (lang && lang != _language) [self applyLanguageInternal:lang];
    }
    [self updateReadOnlyState];
    [self notifyDirty];
    [self notifyMetadata];
    return YES;
}

- (BOOL)saveCopyToURL:(NSURL *)url error:(NSError **)error {
    return [self writeData:[self encodedDataForSave] toURL:url error:error];
}

#pragma mark Encoding reinterpretation
- (void)reinterpretAsEncoding:(NPPEncoding)encoding codepage:(CFStringEncoding)codepage {
    // N++ (NppCommands.cpp IDM_FORMAT_*): the bytes on disk are re-read only when a code page is involved — the buffer
    // currently uses one (originalEncoding != -1), or the user picked one from Encoding > Character sets. Switching
    // between Unicode modes just changes how the buffer will be written and marks it dirty; the text is not touched.
    BOOL codepageInvolved = (_encoding == NPPEncodingANSI) ||
                            (encoding == NPPEncodingANSI && codepage != _codepage);
    NSData *data = nil;
    if (codepageInvolved && !self.isDirty && _fileURL) data = [NSData dataWithContentsOfURL:_fileURL options:NSDataReadingMappedIfSafe error:nil];
    if (!data) {   // behaves like "Convert to"
        if (encoding == _encoding && (encoding != NPPEncodingANSI || codepage == _codepage)) return;
        _codepage = codepage;
        if (encoding == _encoding) { _forcedDirty = YES; [self notifyDirty]; [self notifyMetadata]; }
        else self.encoding = encoding;
        return;
    }
    const uint8_t *p = (const uint8_t *)data.bytes;
    size_t n = data.length;
    std::string utf8;
    switch (encoding) {
        case NPPEncodingUTF8:
        case NPPEncodingUTF8BOM:
            if (n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) { p += 3; n -= 3; }
            if (!NPPDecodeBytes(p, n, kCFStringEncodingUTF8, utf8)) NPPDecodeBytes(p, n, kCFStringEncodingISOLatin1, utf8);
            break;
        case NPPEncodingUTF16LE:
        case NPPEncodingUTF16BE: {
            BOOL le = encoding == NPPEncodingUTF16LE;
            if (n >= 2 && ((le && p[0] == 0xFF && p[1] == 0xFE) || (!le && p[0] == 0xFE && p[1] == 0xFF))) { p += 2; n -= 2; }
            if (!NPPDecodeBytes(p, n & ~(size_t)1, le ? kCFStringEncodingUTF16LE : kCFStringEncodingUTF16BE, utf8))
                NPPDecodeBytes(p, n, kCFStringEncodingISOLatin1, utf8);
            break;
        }
        case NPPEncodingANSI:
            if (!NPPDecodeBytes(p, n, codepage, utf8)) NPPDecodeBytes(p, n, kCFStringEncodingISOLatin1, utf8);
            break;
    }
    ScintillaView *ed = _editor;
    sptr_t firstVisible = NPPSci(ed, SCI_GETFIRSTVISIBLELINE);
    NPPSci(ed, SCI_SETMODEVENTMASK, 0);
    [self replaceAllText:utf8];
    NPPSci(ed, SCI_SETMODEVENTMASK, SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT | SC_PERFORMED_UNDO | SC_PERFORMED_REDO | SC_MOD_CHANGEFOLD);
    NPPSci(ed, SCI_GOTOPOS, 0);
    NPPSci(ed, SCI_SETFIRSTVISIBLELINE, (uptr_t)MAX((sptr_t)0, MIN(firstVisible, NPPSci(ed, SCI_GETLINECOUNT) - 1)));
    _encoding = encoding;
    _codepage = codepage;
    _forcedDirty = NO;
    [self updateReadOnlyState];
    [self updateLineNumberMarginWidthForced:NO];
    [self notifyDirty];
    [self notifyMetadata];
}

#pragma mark Monitoring (tail -f)
- (void)setIsMonitoring:(BOOL)monitoring {
    if (monitoring == _isMonitoring) return;
    if (monitoring) {
        if (!_fileURL || ![self startMonitorSource]) return;   // nothing to watch; stays off (menu validation should disable)
        _isMonitoring = YES;
        _readOnlyBeforeMonitoring = _isReadOnly;
        [self updateReadOnlyState];
        NPPSci(_editor, SCI_GOTOPOS, (uptr_t)NPPSci(_editor, SCI_GETLENGTH));
        NPPSci(_editor, SCI_SCROLLCARET);
    } else {
        [self stopMonitoring];
        _isMonitoring = NO;
        _isReadOnly = _readOnlyBeforeMonitoring;
        [self updateReadOnlyState];
    }
    [self notifyMetadata];
}

- (BOOL)startMonitorSource {
    int fd = open(_fileURL.path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return NO;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_ATTRIB,
        dispatch_get_main_queue());
    if (!src) { close(fd); return NO; }
    __weak NPPDocument *weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        NPPDocument *me = weakSelf;
        if (!me) return;
        unsigned long flags = dispatch_source_get_data(src);
        [me monitorEventWithFlags:flags];
    });
    dispatch_source_set_cancel_handler(src, ^{ close(fd); });
    _monitorSource = src;
    dispatch_resume(src);
    return YES;
}

- (void)stopMonitoring {
    if (_monitorSource) { dispatch_source_cancel(_monitorSource); _monitorSource = nil; }
    _monitorReloadPending = NO;
}

- (void)monitorEventWithFlags:(unsigned long)flags {
    if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME)) {
        // Log rotation: the inode we watch is gone; re-arm on the path once the reload has run.
        if (_monitorSource) { dispatch_source_cancel(_monitorSource); _monitorSource = nil; }
    }
    if (_monitorReloadPending) return;
    _monitorReloadPending = YES;
    __weak NPPDocument *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NPPDocument *me = weakSelf;
        if (me) [me monitorReload];
    });
}

- (void)monitorReload {
    _monitorReloadPending = NO;
    if (!_isMonitoring) return;
    if ([NSFileManager.defaultManager fileExistsAtPath:_fileURL.path ?: @""]) {
        [self reloadFromDisk:nil];
        NPPSci(_editor, SCI_GOTOPOS, (uptr_t)NPPSci(_editor, SCI_GETLENGTH));
        NPPSci(_editor, SCI_SCROLLCARET);
        if (!_monitorSource) [self startMonitorSource];
    } else if (!_monitorSource) {
        // File is gone and not (yet) recreated: retry re-arming a few times over ~2s, then give up monitoring.
        static const int kRetryMs = 500;
        __weak NPPDocument *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kRetryMs * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NPPDocument *me = weakSelf;
            if (!me || !me->_isMonitoring || me->_monitorSource) return;
            if ([me startMonitorSource]) [me monitorReload];
            else me.isMonitoring = NO;   // ponytail: single retry; N++ keeps polling. Add a retry counter if rotation is slower.
        });
    }
    [self.delegate documentFileDidChangeOnDisk:self];
    [self notifyMetadata];
}

#pragma mark Scintilla notifications
- (void)notification:(SCNotification *)n {
    switch (n->nmhdr.code) {
        case SCN_SAVEPOINTREACHED:
        case SCN_SAVEPOINTLEFT:
            [self notifyDirty];
            break;
        case SCN_MODIFIED:
            // The URL scan is cached on (first visible line, document length); a same-length replacement, or a fold
            // that pulls new lines into the window, would otherwise leave the old links styled until the next scroll.
            if (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT | SC_MOD_CHANGEFOLD)) _urlScanLength = -1;
            if (n->linesAdded != 0) [self updateLineNumberMarginWidthForced:NO];
            // N++ NppNotification SCN_MODIFIED: an untitled buffer named after its content only cares about line 0.
            if ((n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) && !_fileURL &&
                NPPPreferences.shared.useContentAsTabName &&
                NPPSci(_editor, SCI_LINEFROMPOSITION, (uptr_t)n->position) == 0)
                [self updateContentTabName];
            break;
        case SCN_UPDATEUI:
            // N++ NppNotification.cpp SCN_UPDATEUI: hot spots on scroll, then brace match, tag match, smart highlight.
            if (n->updated & (SC_UPDATE_V_SCROLL | SC_UPDATE_CONTENT)) [self updateClickableLinks];
            if (n->updated & SC_UPDATE_V_SCROLL) [self updateLineNumberMarginWidthForced:NO];   // dynamic margin width
            if (NPPPreferences.shared.braceHighlighting && [self allowsBraceMatch]) [self braceMatch];
            [self tagMatch];        // reads tagMatchHighlight itself, so turning it off clears what is on screen
            [self smartHighlight];
            [self.delegate documentDidUpdateUI:self];
            break;
        case SCN_CHARADDED:
            [self charAdded:n->ch];
            break;
        case SCN_DOUBLECLICK:
            // N++ SCN_DOUBLECLICK: plain opens a URL, Ctrl selects between the delimiters. The Cocoa backend maps
            // ⌘ to SCMOD_CTRL and ⌃ to SCMOD_META, and ⌃-click is the secondary click on macOS anyway, so both
            // stand in for upstream's Ctrl.
            if (n->modifiers == 0) [self openClickedURLAtPosition:n->position];
            else if (n->modifiers == SCMOD_CTRL || n->modifiers == SCMOD_META)
                [self selectBetweenDelimitersAtPosition:n->position];
            break;
        case SCN_MARGINCLICK:
            if (n->margin == NPPMarginSymbol) [self symbolMarginClickedAtPosition:n->position];
            break;
        // SCN_MARGINRIGHTCLICK never arrives: the margin's right-click is taken before Scintilla sees it, in
        // -popUpMarginMenuAtX:forEvent: — which explains itself.
        case SCN_ZOOM:
            [self updateLineNumberMarginWidthForced:YES];
            [self.delegate documentDidZoom:self];
            break;
        case SCN_URIDROPPED:
            [self uriDropped:n->text];
            break;
        default:
            break;
    }
}

// N++ LargeFileRestriction: each of these is off for a large file unless its allow* key says otherwise.
// Largeness is decided once, at load; switching the restriction off afterwards lifts it again without a reload
// (N++ Buffer::allowBraceMatch et al. all end in "|| !_largeFileRestriction._isEnabled").
- (BOOL)restrictedAsLargeFile { return _isLargeFile && NPPPrefBool(kKeyLargeFileEnabled, YES); }
- (BOOL)allowsBraceMatch  { return !self.restrictedAsLargeFile || NPPPrefBool(kKeyLargeBraceMatch, NO); }
- (BOOL)allowsSmartHilite { return !self.restrictedAsLargeFile || NPPPrefBool(kKeyLargeSmartHilite, NO); }
- (BOOL)allowsClickableLinks { return !self.restrictedAsLargeFile || NPPPrefBool(kKeyLargeLinks, NO); }

// The window smart highlighting, tag matching and URL styling all work over: the visible lines plus one screen of
// slack either side, so scrolling a line does not immediately need a rescan.
static const sptr_t kMaxVisibleWindow = 256 * 1024;

// Free function so "Highlight another view" can ask it about the *other* view's editor, which is not this object's.
static void NPPVisibleRange(ScintillaView *ed, sptr_t *startOut, sptr_t *endOut) {
    sptr_t linesOnScreen = NPPSci(ed, SCI_LINESONSCREEN);
    sptr_t firstVis = NPPSci(ed, SCI_GETFIRSTVISIBLELINE);
    sptr_t startLine = NPPSci(ed, SCI_DOCLINEFROMVISIBLE, (uptr_t)MAX((sptr_t)0, firstVis - linesOnScreen));
    sptr_t endLine = NPPSci(ed, SCI_DOCLINEFROMVISIBLE, (uptr_t)(firstVis + 2 * linesOnScreen + 1));
    sptr_t start = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)startLine);
    sptr_t end = endLine >= NPPSci(ed, SCI_GETLINECOUNT) - 1 ? NPPSci(ed, SCI_GETLENGTH)
                                                             : NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)endLine);
    // Whole lines, so a minified 72 MB JSON on four lines would otherwise hand the URL scanner the entire buffer
    // (which decodes it to UTF-32: 12 bytes per byte) on every scroll. Only a screenful of such a line is ever on
    // screen, so re-anchor on the first character actually showing — always a character boundary — and cap.
    if (end - start > kMaxVisibleWindow) {
        start = MIN(end, MAX(start, NPPSci(ed, SCI_POSITIONFROMPOINT, 0, 0)));   // never past `end`, whatever it answers
        end = MIN(end, start + kMaxVisibleWindow);
    }
    *startOut = start;
    *endOut = end;
}

- (void)visibleRangeStart:(sptr_t *)startOut end:(sptr_t *)endOut { NPPVisibleRange(_editor, startOut, endOut); }

#pragma mark Clickable links (N++ Notepad_plus::addHotSpot)

- (void)updateClickableLinks {
    ScintillaView *ed = _editor;
    const NSInteger urlAction = NPPPrefInt(kKeyStyleURL, NPPUrlUnderLineFg);
    const sptr_t indicStyle = (urlAction == NPPUrlNoUnderLineFg || urlAction == NPPUrlNoUnderLineBg) ? INDIC_HIDDEN : INDIC_PLAIN;
    const sptr_t hoverStyle = (urlAction == NPPUrlNoUnderLineBg || urlAction == NPPUrlUnderLineBg) ? INDIC_FULLBOX : INDIC_EXPLORERLINK;
    if (NPPSci(ed, SCI_INDICGETSTYLE, NPPIndicatorURL) != indicStyle ||
        NPPSci(ed, SCI_INDICGETHOVERSTYLE, NPPIndicatorURL) != hoverStyle) {
        NPPSci(ed, SCI_INDICSETSTYLE, NPPIndicatorURL, indicStyle);
        NPPSci(ed, SCI_INDICSETHOVERSTYLE, NPPIndicatorURL, hoverStyle);
        NPPSci(ed, SCI_INDICSETALPHA, NPPIndicatorURL, 70);
        NPPSci(ed, SCI_INDICSETFLAGS, NPPIndicatorURL, SC_INDICFLAG_VALUEFORE);
    }
    sptr_t start = 0, end = 0;
    [self visibleRangeStart:&start end:&end];
    if (start >= end) return;
    NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorURL);
    if (urlAction == NPPUrlDisable || ![self allowsClickableLinks]) {
        NPPSci(ed, SCI_INDICATORCLEARRANGE, (uptr_t)start, end - start);
        _urlScanFirstLine = _urlScanLength = -1;
        return;
    }
    // SCN_UPDATEUI arrives on every keystroke; only the scanned window and the document length decide the answer.
    sptr_t firstVis = NPPSci(ed, SCI_GETFIRSTVISIBLELINE), length = NPPSci(ed, SCI_GETLENGTH);
    if (firstVis == _urlScanFirstLine && length == _urlScanLength) return;
    _urlScanFirstLine = firstVis;
    _urlScanLength = length;

    NPPSci(ed, SCI_SETINDICATORVALUE, NPPSci(ed, SCI_STYLEGETFORE, STYLE_DEFAULT));
    const std::string bytes = NPPSciGetRange(ed, start, end);
    const NPPCodePoints text = NPPDecodeUTF8(bytes.data(), bytes.size());
    const std::vector<std::u32string> &schemes = NPPCachedUrlSchemes(NPPPrefString(kKeyUriSchemes, kDefaultUriSchemes));
    size_t i = 0;
    while (i < text.cp.size()) {
        size_t len = 0;
        const bool isUrl = NPPIsUrlAt(text.cp, i, &len, schemes);
        if (len == 0) break;
        const sptr_t from = start + (sptr_t)text.byteOffset[i];
        const sptr_t to = start + (sptr_t)text.byteOffset[MIN(i + len, text.cp.size())];
        NPPSci(ed, isUrl ? SCI_INDICATORFILLRANGE : SCI_INDICATORCLEARRANGE, (uptr_t)from, to - from);
        i += len;
    }
}

// N++ opens the link on a plain double-click inside the URL indicator (SCN_DOUBLECLICK, no modifiers).
- (void)openClickedURLAtPosition:(sptr_t)pos {
    ScintillaView *ed = _editor;
    if (![self allowsClickableLinks] || NPPPrefInt(kKeyStyleURL, NPPUrlUnderLineFg) == NPPUrlDisable) return;
    if (pos < 0 || !(NPPSci(ed, SCI_INDICATORALLONFOR, (uptr_t)pos) & (1 << NPPIndicatorURL))) return;
    sptr_t from = NPPSci(ed, SCI_INDICATORSTART, NPPIndicatorURL, pos);
    sptr_t to = NPPSci(ed, SCI_INDICATOREND, NPPIndicatorURL, pos);
    if (to <= from || pos < from || pos > to) return;
    std::string raw = NPPSciGetRange(ed, from, to);
    NSString *s = [[NSString alloc] initWithBytes:raw.data() length:raw.size() encoding:NSUTF8StringEncoding];
    // ponytail: no percent-escaping pass; the scanner only marks what the scheme list allows, and NSURL takes those
    // as they are. Upgrade path: re-encode the path/query if links with raw spaces or non-ASCII ever need to work.
    NSURL *url = s.length ? [NSURL URLWithString:s] : nil;
    if (!url.scheme) return;
    NPPSci(ed, SCI_SETSEL, (uptr_t)pos, pos);   // N++ drops the word selection the double-click made
    [NSWorkspace.sharedWorkspace openURL:url];
}

#pragma mark Delimiter selection (N++ NppNotification SCN_DOUBLECLICK, Preferences > Delimiter)

// Selects what sits between NPPDelimiterOpen and NPPDelimiterClose around the click. The search runs over the
// clicked line, or — with "allow on several lines" — over the document.
- (void)selectBetweenDelimitersAtPosition:(sptr_t)clickPos {
    ScintillaView *ed = _editor;
    NPPPreferences *p = NPPPreferences.shared;
    // One composed character each (that is all the preferences page stores), which is more than one byte for "«" —
    // hence the whole-string match in NPPFindDelimiterRange rather than upstream's single `char`.
    const std::string open = p.delimiterOpen.UTF8String ?: "", close = p.delimiterClose.UTF8String ?: "";
    if (open.empty() || close.empty()) return;

    sptr_t pos = clickPos;
    if (pos < 0) pos = NPPSci(ed, SCI_GETCURRENTPOS);   // N++: an empty line reports position -1
    sptr_t from, to;
    if (p.delimiterSelectionOnEntireDocument) {
        // ponytail: upstream copies the whole document here; a window around the click keeps a 72 MB buffer out of
        // it. Upgrade path: SCI_SEARCHINTARGET outwards from the caret instead of a copy.
        static const sptr_t kWindow = 64 * 1024;
        from = MAX((sptr_t)0, pos - kWindow);
        to = MIN(NPPSci(ed, SCI_GETLENGTH), pos + kWindow);
    } else {
        sptr_t line = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)pos);
        from = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)line);
        to = NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)line);
    }
    if (to <= from || pos < from || pos > to) return;

    long openAt = 0, closeAt = 0;
    if (!NPPFindDelimiterRange(NPPSciGetRange(ed, from, to), (size_t)(pos - from), open, close, &openAt, &closeAt)) return;
    NPPSci(ed, SCI_SETCURRENTPOS, (uptr_t)(from + closeAt));
    NPPSci(ed, SCI_SETANCHOR, (uptr_t)(from + openAt + (long)open.size()));
}

#pragma mark Matched tag highlighting (N++ XmlMatchedTagsHighlighter::tagMatch)

- (void)tagMatch {
    ScintillaView *ed = _editor;
    BOOL markup = NPPPreferences.shared.tagMatchHighlight && ![self restrictedAsLargeFile]
                  && NPPLanguageIsMarkupForTags(_userDefinedLanguageName ?: _language.name);
    // "Highlight comment/php/asp zone" (NppGUI::_enableHiliteNonHTMLZone), a sub-option of "Highlight matching tags".
    // Upstream still saves and shows the setting but no longer reads it anywhere, so this is our reading of the label:
    // with it off, tag matching stays out of the HTML lexer's comment / ASP / PHP / embedded-script styles.
    // ponytail: one style lookup at the caret; per-tag zone checks while searching would be the finer version.
    if (markup && !NPPPreferences.shared.highlightNonHTMLZone &&
        NPPStyleIsNonHTMLZone((int)NPPSci(ed, SCI_GETSTYLEAT, (uptr_t)NPPSci(ed, SCI_GETCURRENTPOS))))
        markup = NO;
    if (!markup && !_tagMatchActive) return;   // nothing marked and nothing to mark: don't touch the document
    for (int indic : {NPPIndicatorTagMatch, NPPIndicatorTagAttr}) {
        NPPSci(ed, SCI_SETINDICATORCURRENT, (uptr_t)indic);
        NPPSci(ed, SCI_INDICATORCLEARRANGE, 0, NPPSci(ed, SCI_GETLENGTH));
    }
    _tagMatchActive = NO;
    if (!markup) return;

    // ponytail: the partner tag is looked for in a window around the caret, not the whole document — this runs on
    // every caret move and a 72 MB buffer must not be copied for it. Upgrade path: SCI_SEARCHINTARGET over the
    // real document, the way upstream does it.
    static const sptr_t kWindow = 64 * 1024;
    const sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    const sptr_t from = MAX((sptr_t)0, caret - kWindow);
    const sptr_t to = MIN(NPPSci(ed, SCI_GETLENGTH), caret + kWindow);
    if (to <= from) return;
    const std::string window = NPPSciGetRange(ed, from, to);

    NPPXmlTags tags;
    if (!NPPFindMatchedTags(window, (long)(caret - from), tags)) return;

    NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorTagMatch);
    long openTagTailLen = 2;                        // "/>" for a single tag, ">" once there is a close tag
    if (tags.closeStart >= 0 && tags.closeEnd >= 0) {
        NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)(from + tags.closeStart), tags.closeEnd - tags.closeStart);
        openTagTailLen = 1;
    }
    NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)(from + tags.openStart), tags.nameEnd - tags.openStart);
    NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)(from + tags.openEnd - openTagTailLen), openTagTailLen);
    _tagMatchActive = YES;

    if (NPPPrefBool(kKeyTagAttrHighlight, YES)) {
        NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorTagAttr);
        for (auto &a : NPPTagAttributePositions(window, tags.nameEnd, tags.openEnd - openTagTailLen))
            NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)(from + a.first), a.second - a.first);
    }
    if (tags.closeStart >= 0 && NPPPreferences.shared.showIndentGuides) {
        const sptr_t openPos = from + tags.openStart, closePos = from + tags.closeStart;
        if (NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)openPos) != NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)closePos)) {
            NPPSci(ed, SCI_BRACEHIGHLIGHT, (uptr_t)openPos, from + tags.closeEnd - 1);
            NPPSci(ed, SCI_SETHIGHLIGHTGUIDE, (uptr_t)MIN(NPPSci(ed, SCI_GETCOLUMN, (uptr_t)openPos),
                                                          NPPSci(ed, SCI_GETCOLUMN, (uptr_t)closePos)));
        }
    }
}

// N++ findMatchingBracePos + braceMatch: char before caret first, then char at caret.
- (void)braceMatch {
    ScintillaView *ed = _editor;
    sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    sptr_t braceAtCaret = -1, braceOpposite = -1;
    auto isBrace = [](int c) { return c && strchr("[](){}", c) != nullptr; };   // N++ findMatchingBracePos: no <>
    if (caret > 0 && isBrace((int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)(caret - 1)))) braceAtCaret = caret - 1;
    if (braceAtCaret < 0 && isBrace((int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)caret))) braceAtCaret = caret;
    if (braceAtCaret >= 0) braceOpposite = NPPSci(ed, SCI_BRACEMATCH, (uptr_t)braceAtCaret, 0);
    if (braceAtCaret != -1 && braceOpposite == -1) {
        NPPSci(ed, SCI_BRACEBADLIGHT, (uptr_t)braceAtCaret);
        NPPSci(ed, SCI_SETHIGHLIGHTGUIDE, 0);
    } else {
        NPPSci(ed, SCI_BRACEHIGHLIGHT, (uptr_t)braceAtCaret, braceOpposite);
        if (braceAtCaret != -1 && NPPPreferences.shared.showIndentGuides) {
            sptr_t c1 = NPPSci(ed, SCI_GETCOLUMN, (uptr_t)braceAtCaret), c2 = NPPSci(ed, SCI_GETCOLUMN, (uptr_t)braceOpposite);
            NPPSci(ed, SCI_SETHIGHLIGHTGUIDE, (uptr_t)MIN(c1, c2));
        } else if (braceAtCaret == -1) {
            NPPSci(ed, SCI_SETHIGHLIGHTGUIDE, 0);
        }
    }
}

// N++ markSelectedTextInc: highlight whole-word occurrences of a single-word selection, visible range only.
// With "Highlight another view" on, the buffer the notification came from drives every other on-screen buffer:
// they get its word, or — when it has no selection — they are cleared too, because an unfocused view gets no
// SCN_UPDATEUI of its own and would otherwise keep a highlight for a selection that is long gone
// (N++ SmartHighlighter::highlightView clears `unfocusView` in both branches for exactly that reason).
- (void)smartHighlight {
    [self clearSmartHighlight];
    std::string word;
    const BOOL mine = [self smartHighlightWord:word];
    if (mine) [self fillSmartHighlightWord:word inEditor:_editor];
    if (!NPPPreferences.shared.smartHighlightAnotherView) return;
    for (NPPDocument *other in [NPPDocument onScreenDocumentsExcept:self]) {
        [other clearSmartHighlight];
        if (mine && [other allowsSmartHilite]) [self fillSmartHighlightWord:word inEditor:other->_editor];
    }
}

- (void)clearSmartHighlight {
    NPPSci(_editor, SCI_SETINDICATORCURRENT, NPPIndicatorSmartHighlight);
    NPPSci(_editor, SCI_INDICATORCLEARRANGE, 0, NPPSci(_editor, SCI_GETLENGTH));
}

// The selection this buffer would smart-highlight, if any. Pure query: paints nothing, so another view can ask.
- (BOOL)smartHighlightWord:(std::string &)out {
    ScintillaView *ed = _editor;
    if (!NPPPreferences.shared.smartHighlighting || ![self allowsSmartHilite]) return NO;
    if (NPPSci(ed, SCI_GETSELECTIONS) != 1) return NO;
    sptr_t a = NPPSci(ed, SCI_GETSELECTIONSTART), b = NPPSci(ed, SCI_GETSELECTIONEND);
    if (a == b || b - a > 256) return NO;
    if (NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)a) != NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)b)) return NO;
    out = NPPSciGetRange(ed, a, b);
    for (unsigned char c : out) if (isspace(c)) return NO;
    return !out.empty();
}

// "Use Find dialog settings" replaces the two smart-highlight switches with the Find panel's own (N++
// SmartHighlighter reads FindHistory::_isMatchCase / _isMatchWord instead of NppGUI's pair).
- (void)fillSmartHighlightWord:(const std::string &)word inEditor:(ScintillaView *)ed {
    NPPPreferences *p = NPPPreferences.shared;
    const BOOL useFind = p.smartHighlightUseFindSettings;
    const BOOL wholeWord = useFind ? NPPPrefBool(kKeyFindWholeWord, NO) : p.smartHighlightWholeWord;
    const BOOL matchCase = useFind ? NPPPrefBool(kKeyFindMatchCase, NO) : p.smartHighlightMatchCase;
    sptr_t start = 0, end = 0;
    NPPVisibleRange(ed, &start, &end);
    NPPSci(ed, SCI_SETINDICATORCURRENT, NPPIndicatorSmartHighlight);
    NPPSci(ed, SCI_SETSEARCHFLAGS, (wholeWord ? SCFIND_WHOLEWORD : 0) | (matchCase ? SCFIND_MATCHCASE : 0));
    while (start < end) {
        NPPSci(ed, SCI_SETTARGETRANGE, (uptr_t)start, end);
        sptr_t found = NPPSciStr(ed, SCI_SEARCHINTARGET, word.size(), word.data());
        if (found < 0) break;
        sptr_t fend = NPPSci(ed, SCI_GETTARGETEND);
        if (fend <= found) break;
        NPPSci(ed, SCI_INDICATORFILLRANGE, (uptr_t)found, fend - found);
        start = fend;
    }
}

#pragma mark Documents on screen (N++'s two views)

// A buffer is on screen when its editor is installed in a window — the window controller keeps only the current
// document of each view in a container, so this is exactly N++'s "the other visible view".
+ (NSArray<NPPDocument *> *)onScreenDocumentsExcept:(NPPDocument *)skip {
    NSMutableArray<NPPDocument *> *a = [NSMutableArray array];
    for (NPPDocument *d in NPPLiveDocuments())
        if (d != skip && d->_editor.superview && d->_editor.window) [a addObject:d];
    return a;
}

// N++ maintainIndentation + AutoCompletion::insertMatchedChars.
- (void)charAdded:(int)ch {
    ScintillaView *ed = _editor;
    NPPPreferences *p = NPPPreferences.shared;
    // N++ ScintillaEditView WM_CHAR (_npcNoInputC0) drops the keystroke before Scintilla sees it. The Cocoa backend
    // has no such hook, so the character is taken back out here — before auto-indent or a matched pair reacts to it.
    // ponytail: this leaves an undo step Windows would not have; a real pre-insert filter needs a SCIContentView
    // subclass, which is Scintilla's to provide.
    if (p.preventC0Input && NPPIsFilteredC0Char(ch)) {
        NPPSci(ed, SCI_DELETEBACK);
        return;
    }
    if (p.autoIndent) [self maintainIndentation:ch];
    if (!p.autoCloseBrackets || NPPSci(ed, SCI_GETSELECTIONS) != 1) return;
    [self insertMatchedCharFor:ch conf:NPPCurrentMatchedPairConf()];
}

- (std::string)textOfLine:(sptr_t)line {
    if (line < 0 || line >= NPPSci(_editor, SCI_GETLINECOUNT)) return std::string();
    return NPPSciGetRange(_editor, NPPSci(_editor, SCI_POSITIONFROMLINE, (uptr_t)line),
                          NPPSci(_editor, SCI_GETLINEENDPOSITION, (uptr_t)line));
}

- (void)setIndentOfLine:(sptr_t)line to:(long)columns moveCaret:(BOOL)moveCaret {
    NPPSci(_editor, SCI_SETLINEINDENTATION, (uptr_t)line, (sptr_t)MAX(0L, columns));
    if (moveCaret) NPPSci(_editor, SCI_GOTOPOS, (uptr_t)NPPSci(_editor, SCI_GETLINEINDENTPOSITION, (uptr_t)line));
}

// N++ Notepad_plus::maintainIndentation. Basic carries the previous line's indentation over; advanced
// (NPPAutoIndentMode == 2) also opens a level after "{" / a condition line and lines "}" up with its "{".
- (void)maintainIndentation:(int)ch {
    ScintillaView *ed = _editor;
    const sptr_t eolMode = NPPSci(ed, SCI_GETEOLMODE);
    const BOOL isNewline = ((eolMode == SC_EOL_CRLF || eolMode == SC_EOL_LF) && ch == '\n') || (eolMode == SC_EOL_CR && ch == '\r');
    const sptr_t curLine = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(ed, SCI_GETCURRENTPOS));
    const sptr_t prevLine = curLine - 1;
    // "Enter at the beginning of a line leaves the indentation alone" — N++ checks the previous line is not empty.
    if (isNewline && prevLine >= 0 &&
        NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)prevLine) == NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)prevLine)) return;

    const long prevIndent = prevLine >= 0 ? (long)NPPSci(ed, SCI_GETLINEINDENTATION, (uptr_t)prevLine) : 0;
    const long tabWidth = (long)MAX((sptr_t)1, NPPSci(ed, SCI_GETTABWIDTH));
    BOOL noSingleLineControl = NO;
    const NPPIndentFamily family = NPPPrefInt(@"NPPAutoIndentMode", NPPAutoIndentBasic) >= NPPAutoIndentAdvanced
                                   ? NPPIndentFamilyForLanguage(_userDefinedLanguageName ?: _language.name, &noSingleLineControl)
                                   : NPPIndentFamilyOther;

    if (family == NPPIndentFamilyCLike && !isNewline) {
        if (ch == '{') [self advancedIndentAfterOpeningBraceOnLine:curLine tabWidth:tabWidth];
        else if (ch == '}') [self advancedIndentAfterClosingBraceOnLine:curLine];
        return;
    }
    if (!isNewline) return;

    if (family == NPPIndentFamilyCLike) {
        const sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
        const char prevChar = (char)NPPSci(ed, SCI_GETCHARAT, (uptr_t)(caret - (eolMode == SC_EOL_CRLF ? 3 : 2)));
        const char nextChar = (char)NPPSci(ed, SCI_GETCHARAT, (uptr_t)caret);
        BOOL insertClosingLine = NO;
        const long indent = NPPAdvancedNewlineIndent(prevChar, nextChar, noSingleLineControl,
                                                     [self textOfLine:prevLine], [self textOfLine:prevLine - 1],
                                                     prevIndent, tabWidth, &insertClosingLine);
        if (insertClosingLine) {   // "{|}" -> put the "}" on its own line, lined up with the "{"
            const char *eol = eolMode == SC_EOL_CRLF ? "\r\n" : (eolMode == SC_EOL_LF ? "\n" : "\r");
            NPPSciStr(ed, SCI_INSERTTEXT, (uptr_t)NPPSci(ed, SCI_GETCURRENTPOS), eol);
            [self setIndentOfLine:curLine + 1 to:prevIndent moveCaret:NO];
        }
        [self setIndentOfLine:curLine to:indent moveCaret:YES];
        return;
    }
    if (family == NPPIndentFamilyPython) {
        const std::string prev = [self textOfLine:prevLine];
        const long colon = NPPPythonBlockColonOffset(prev);
        const sptr_t colonPos = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)prevLine) + colon;
        const BOOL opensBlock = colon >= 0 && NPPSci(ed, SCI_GETSTYLEINDEXAT, (uptr_t)colonPos) == SCE_P_OPERATOR;
        if (opensBlock) [self setIndentOfLine:curLine to:prevIndent + tabWidth moveCaret:YES];
        else if (prevIndent > 0) [self setIndentOfLine:curLine to:prevIndent moveCaret:YES];
        return;
    }
    if (prevIndent > 0) [self setIndentOfLine:curLine to:prevIndent moveCaret:YES];
}

// A "{" typed on an otherwise blank line lines up with the previous line, one level deeper if that line opened a block.
- (void)advancedIndentAfterOpeningBraceOnLine:(sptr_t)curLine tabWidth:(long)tabWidth {
    ScintillaView *ed = _editor;
    const sptr_t lineStart = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)curLine);
    for (sptr_t i = NPPSci(ed, SCI_GETCURRENTPOS) - 2; i >= lineStart; --i) {
        const char c = (char)NPPSci(ed, SCI_GETCHARAT, (uptr_t)i);
        if (c != ' ' && c != '\t') return;
    }
    sptr_t prevLine = curLine - 1;
    while (prevLine >= 0 && NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)prevLine) == NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)prevLine)) prevLine--;
    if (prevLine < 0) return;
    long indent = (long)NPPSci(ed, SCI_GETLINEINDENTATION, (uptr_t)prevLine);
    // N++ matches "[ \t]*\{.*" against the whole previous line, which is "does it contain a {".
    if ([self textOfLine:prevLine].find('{') != std::string::npos) indent += tabWidth;
    [self setIndentOfLine:curLine to:indent moveCaret:NO];
}

// A "}" lines up with the line its "{" is on. SCI_BRACEMATCH is style-aware, so braces in comments and strings
// are skipped for free (N++ scans the text itself).
- (void)advancedIndentAfterClosingBraceOnLine:(sptr_t)curLine {
    ScintillaView *ed = _editor;
    const sptr_t bracePos = NPPSci(ed, SCI_GETCURRENTPOS) - 1;
    if (bracePos < 0 || (char)NPPSci(ed, SCI_GETCHARAT, (uptr_t)bracePos) != '}') return;
    const sptr_t match = NPPSci(ed, SCI_BRACEMATCH, (uptr_t)bracePos, 0);
    if (match < 0) return;
    const sptr_t matchLine = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)match);
    if (matchLine == curLine) return;
    [self setIndentOfLine:curLine to:(long)NPPSci(ed, SCI_GETLINEINDENTATION, (uptr_t)matchLine) moveCaret:NO];
}

// N++ AutoCompletion::insertMatchedChars. The ">" close-tag half lives in NPPAutoCompletion and is not repeated here.
// ponytail: no _insertedMatchedChars ledger, so a closing character is only swallowed when it is already at the caret,
// not "only when we are the ones who put it there". Upgrade path: keep the same per-insertion stack N++ does.
- (void)insertMatchedCharFor:(int)ch conf:(const NPPMatchedPairConf &)conf {
    if (ch <= 0 || ch > 0x7F || !conf.any()) return;
    ScintillaView *ed = _editor;
    const sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
    const char charPrev = caret >= 2 ? (char)NPPSci(ed, SCI_GETCHARAT, (uptr_t)(caret - 2)) : '\0';
    const char charNext = (char)NPPSci(ed, SCI_GETCHARAT, (uptr_t)caret);
    const BOOL prevBlank = charPrev == ' ' || charPrev == '\t' || charPrev == '\n' || charPrev == '\r' || charPrev == '\0';
    const BOOL nextBlank = charNext == ' ' || charNext == '\t' || charNext == '\n' || charNext == '\r'
                           || caret == NPPSci(ed, SCI_GETLENGTH);
    const BOOL nextIsClose = charNext == ')' || charNext == ']' || charNext == '}';
    const BOOL inSandwich = (charPrev == '(' && charNext == ')') || (charPrev == '[' && charNext == ']')
                            || (charPrev == '{' && charNext == '}');
    // A quote pairs in the same places N++ allows: between blanks, inside an empty bracket pair, or against one.
    const BOOL quoteFits = (prevBlank && nextBlank) || inSandwich
                           || (charPrev == '(' && nextBlank) || (prevBlank && charNext == ')')
                           || (charPrev == '[' && nextBlank) || (prevBlank && charNext == ']')
                           || (charPrev == '{' && nextBlank) || (prevBlank && charNext == '}');

    // User-defined pairs are checked first, as upstream does.
    for (auto &pair : conf.userPairs) {
        if (pair.first != (char)ch || !nextBlank) continue;
        const char closing[2] = {pair.second, '\0'};
        NPPSciStr(ed, SCI_INSERTTEXT, (uptr_t)caret, closing);
        NPPSci(ed, SCI_GOTOPOS, (uptr_t)caret);   // stay in front of the character we just added
        return;
    }

    const char *matched = nullptr;
    switch (ch) {
        case '(': if (conf.parentheses && (nextBlank || nextIsClose)) matched = ")"; break;
        case '[': if (conf.brackets && (nextBlank || nextIsClose)) matched = "]"; break;
        case '{': if (conf.curly && (nextBlank || nextIsClose)) matched = "}"; break;
        case '"': if (conf.doubleQuotes) { if (charNext == '"') { NPPSci(ed, SCI_DELETERANGE, (uptr_t)caret, 1); return; }
                                           if (quoteFits) matched = "\""; } break;
        case '\'': if (conf.quotes) { if (charNext == '\'') { NPPSci(ed, SCI_DELETERANGE, (uptr_t)caret, 1); return; }
                                      if (quoteFits) matched = "'"; } break;
        case ')': if (conf.parentheses && charNext == ')') NPPSci(ed, SCI_DELETERANGE, (uptr_t)caret, 1); return;
        case ']': if (conf.brackets && charNext == ']') NPPSci(ed, SCI_DELETERANGE, (uptr_t)caret, 1); return;
        case '}': if (conf.curly && charNext == '}') NPPSci(ed, SCI_DELETERANGE, (uptr_t)caret, 1); return;
        default: return;
    }
    if (!matched) return;
    NPPSciStr(ed, SCI_INSERTTEXT, (uptr_t)caret, matched);
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)caret);
}

// Symbol margin: bookmark toggle, or reveal hidden lines when the line carries a hide-lines marker.
- (void)symbolMarginClickedAtPosition:(sptr_t)pos {
    ScintillaView *ed = _editor;
    sptr_t line = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)pos);
    sptr_t state = NPPSci(ed, SCI_MARKERGET, (uptr_t)line);
    BOOL beginHere = (state & (1 << NPPMarkHideBegin)) != 0, endHere = (state & (1 << NPPMarkHideEnd)) != 0;
    if (beginHere || endHere) {
        sptr_t begin = line, end = line;
        if (beginHere) {
            end = NPPSci(ed, SCI_MARKERNEXT, (uptr_t)(line + 1), 1 << NPPMarkHideEnd);
        } else {
            begin = NPPSci(ed, SCI_MARKERPREVIOUS, (uptr_t)(line - 1), 1 << NPPMarkHideBegin);
        }
        if (begin < 0 || end < 0 || end <= begin) {   // orphan marker: just drop it (N++ does the same)
            NPPSci(ed, SCI_MARKERDELETE, (uptr_t)line, beginHere ? NPPMarkHideBegin : NPPMarkHideEnd);
            return;
        }
        NPPSci(ed, SCI_SHOWLINES, (uptr_t)(begin + 1), end - 1);
        for (sptr_t l = begin; l <= end; l++) {
            NPPSci(ed, SCI_MARKERDELETE, (uptr_t)l, NPPMarkHideUnderline);
            NPPSci(ed, SCI_MARKERDELETE, (uptr_t)l, NPPMarkHideBegin);
            NPPSci(ed, SCI_MARKERDELETE, (uptr_t)l, NPPMarkHideEnd);
        }
        return;
    }
    if (state & (1 << NPPMarkBookmark)) NPPSci(ed, SCI_MARKERDELETE, (uptr_t)line, NPPMarkBookmark);
    else NPPSci(ed, SCI_MARKERADD, (uptr_t)line, NPPMarkBookmark);
}

- (void)uriDropped:(const char *)text {
    if (!text) return;
    NSString *s = @(text);
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *raw in [s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0) continue;
        NSURL *u = [line hasPrefix:@"file:"] ? [NSURL URLWithString:line] : [NSURL fileURLWithPath:line.stringByExpandingTildeInPath];
        if (u.isFileURL && u.path.length) [urls addObject:u];
    }
    if (urls.count) [self.delegate document:self didReceiveDroppedFileURLs:urls];
}

#pragma mark Editor hooks (right-click, multi-caret paste and delete, the extra mouse buttons)

// The document whose editor has the keyboard focus in `window`, or nil. Two buffers can share a window (the split
// view), so a keyboard or button event always has to be attributed to one of them before it is acted on.
+ (nullable NPPDocument *)documentFocusedIn:(nullable NSWindow *)window {
    NSResponder *r = window.firstResponder;
    if (![r isKindOfClass:NSView.class]) return nil;
    for (NPPDocument *d in NPPLiveDocuments())
        if ([(NSView *)r isDescendantOf:d.editor]) return d;
    return nil;
}

// N++ NppBigSwitch: WM_APPCOMMAND / APPCOMMAND_BROWSER_BACKWARD runs activateNextDoc(dirUp), i.e. the *previous*
// document, and _FORWARD the next one. AppKit numbers the two extra mouse buttons 3 (back) and 4 (forward).
static NSInteger NPPDocSwitchDeltaForButton(NSInteger buttonNumber) {
    return buttonNumber == 3 ? -1 : buttonNumber == 4 ? 1 : 0;
}

// Which document to activate, or -1 when there is nothing to switch to (one buffer, or no current one).
static NSInteger NPPNeighbourIndex(NSInteger current, NSInteger count, NSInteger delta) {
    if (count < 2 || current < 0 || current >= count) return -1;
    return ((current + delta) % count + count) % count;
}

- (BOOL)switchDocumentBy:(NSInteger)delta {
    id<NPPDocumentSwitcher> s = (id<NPPDocumentSwitcher>)self.delegate;
    if (![s respondsToSelector:@selector(documents)] || ![s respondsToSelector:@selector(currentDocument)] ||
        ![s respondsToSelector:@selector(selectDocument:)]) return NO;
    // -documents is the main view's buffers then the sub view's, so walking off the end of one lands in the other —
    // which is what upstream's activateNextDoc does when its index runs past the tab strip.
    NSArray<NPPDocument *> *docs = s.documents;
    NSInteger idx = NPPNeighbourIndex((NSInteger)[docs indexOfObjectIdenticalTo:s.currentDocument],
                                      (NSInteger)docs.count, delta);   // NSNotFound casts to -1: nothing to switch from
    if (idx < 0) return NO;
    [s selectDocument:docs[(NSUInteger)idx]];
    return YES;
}

// N++ ScintillaEditView::pasteToMultiSelection: with more than one caret the clipboard is split on its own line
// ending and handed out a line per caret, instead of every caret getting the whole clipboard (SC_MULTIPASTE_EACH).
// Upstream only reaches this for a clipboard written by a column copy — it tests for the "MSDEVColumnSelect"
// format, whose text always ends with an EOL, and unconditionally drops the last split. macOS has no such flag, so
// the trailing empty piece is dropped only when it is really there; otherwise the last line would be thrown away.
// NO = leave it to Scintilla.
- (BOOL)distributeMultiCaretPaste:(NSString *)clipboard {
    ScintillaView *ed = _editor;
    const sptr_t nbSel = NPPSci(ed, SCI_GETSELECTIONS);
    if (nbSel <= 1 || NPPSci(ed, SCI_GETSELECTIONMODE) != SC_SEL_STREAM || NPPSci(ed, SCI_GETREADONLY)) return NO;
    NSString *eol = [clipboard containsString:@"\r\n"] ? @"\r\n"
                  : [clipboard containsString:@"\n"] ? @"\n"
                  : [clipboard containsString:@"\r"] ? @"\r" : nil;
    if (!eol) return NO;   // a single line already goes to every caret, which is what SC_MULTIPASTE_EACH does
    NSMutableArray<NSString *> *lines = [[clipboard componentsSeparatedByString:eol] mutableCopy];
    if (lines.lastObject.length == 0) [lines removeLastObject];
    if (lines.count < 2) return NO;

    NSString *docEol = _eolMode == NPPEOLWindows ? @"\r\n" : _eolMode == NPPEOLMac ? @"\r" : @"\n";
    NSArray<NSString *> *chunks = lines;
    if ((sptr_t)lines.count > nbSel) {
        // Not enough carets: each takes an equal share, upstream's integer division and all (a remainder is dropped).
        const NSUInteger per = lines.count / (NSUInteger)nbSel;
        NSMutableArray<NSString *> *grouped = [NSMutableArray array];
        NSUInteger j = 0;
        for (sptr_t i = 0; i < nbSel; i++) {
            NSMutableArray<NSString *> *take = [NSMutableArray array];
            for (NSUInteger k = 0; k < per && j < lines.count; k++) [take addObject:lines[j++]];
            [grouped addObject:[take componentsJoinedByString:docEol]];
        }
        chunks = grouped;
    }

    NPPSci(ed, SCI_BEGINUNDOACTION);
    for (NSUInteger i = 0; i < chunks.count; i++) {
        // Filling one caret moves the ones after it, so every position is read back just before it is used.
        const sptr_t start = NPPSci(ed, SCI_GETSELECTIONNSTART, (uptr_t)i);
        const sptr_t end = NPPSci(ed, SCI_GETSELECTIONNEND, (uptr_t)i);
        std::string utf8 = chunks[i].UTF8String ?: "";
        NPPSci(ed, SCI_SETTARGETRANGE, (uptr_t)start, end);
        NPPSciStr(ed, SCI_REPLACETARGET, (uptr_t)utf8.size(), utf8.c_str());
        const sptr_t after = start + (sptr_t)utf8.size();
        NPPSci(ed, SCI_SETSELECTIONNSTART, (uptr_t)i, after);
        NPPSci(ed, SCI_SETSELECTIONNEND, (uptr_t)i, after);
    }
    NPPSci(ed, SCI_ENDUNDOACTION);
    return YES;
}

// N++ ScintillaEditView WM_KEYDOWN / VK_DELETE with more than one caret: Scintilla's forward-delete does nothing
// at the end of a line, so upstream removes the line ending itself and joins the lines. Taken over only when at
// least one caret really is at an EOL — otherwise Scintilla's own handling is left completely alone, which is also
// how upstream keeps out of a rectangular selection. NO = leave it to Scintilla.
- (BOOL)deleteForwardAtMultipleCarets {
    ScintillaView *ed = _editor;
    const sptr_t nbSel = NPPSci(ed, SCI_GETSELECTIONS);
    if (nbSel <= 1 || NPPSci(ed, SCI_GETSELECTIONMODE) != SC_SEL_STREAM || NPPSci(ed, SCI_GETREADONLY)) return NO;
    BOOL anyAtEol = NO;
    for (sptr_t i = 0; i < nbSel && !anyAtEol; i++) {
        const sptr_t pos = NPPSci(ed, SCI_GETSELECTIONNSTART, (uptr_t)i);
        if (pos != NPPSci(ed, SCI_GETSELECTIONNEND, (uptr_t)i) || pos >= NPPSci(ed, SCI_GETLENGTH)) continue;
        const int c = (int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)pos);
        anyAtEol = (c == '\r' || c == '\n');
    }
    if (!anyAtEol) return NO;

    NPPSci(ed, SCI_BEGINUNDOACTION);
    for (sptr_t i = 0; i < nbSel; i++) {
        const sptr_t start = NPPSci(ed, SCI_GETSELECTIONNSTART, (uptr_t)i);
        sptr_t end = NPPSci(ed, SCI_GETSELECTIONNEND, (uptr_t)i);
        if (start == end) {
            const sptr_t len = NPPSci(ed, SCI_GETLENGTH);
            if (start >= len) continue;
            const int c = (int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)start);
            if (c == '\r' && start + 1 < len && (int)NPPSci(ed, SCI_GETCHARAT, (uptr_t)(start + 1)) == '\n') end = start + 2;
            else if (c == '\r' || c == '\n') end = start + 1;
            else end = NPPSci(ed, SCI_POSITIONAFTER, (uptr_t)start);   // exactly what Scintilla's own DEL removes
        }
        NPPSci(ed, SCI_SETTARGETRANGE, (uptr_t)start, end);
        NPPSciStr(ed, SCI_REPLACETARGET, 0, "");
        NPPSci(ed, SCI_SETSELECTIONNSTART, (uptr_t)i, start);
        NPPSci(ed, SCI_SETSELECTIONNEND, (uptr_t)i, start);
    }
    NPPSci(ed, SCI_ENDUNDOACTION);
    return YES;
}

// Paste is implemented by Scintilla's own content view, so no responder above it ever sees the message and there is
// no notification to hang this off: the method is exchanged once, for the process, and the replacement calls the
// original for everything it does not distribute (a ScintillaView that is not one of these buffers included).
// ponytail: the seam a Scintilla build could offer instead is a "will paste" delegate callback; until it does,
// -paste: is the only place the message passes.
static IMP NPPOriginalPasteIMP;
static void NPPPasteDistributingToCarets(id content, SEL cmd, id sender) {
    for (NPPDocument *d in NPPLiveDocuments()) {
        if (d.editor.content != content) continue;
        NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
        if (text.length && [d distributeMultiCaretPaste:text]) return;
        break;
    }
    if (NPPOriginalPasteIMP) ((void (*)(id, SEL, id))NPPOriginalPasteIMP)(content, cmd, sender);
}

// YES when the event landed in this document's text area — the same hit test the right-click hook does, because
// anything sitting on top of the editor (an autocompletion list, an overlay) owns its own events.
- (BOOL)eventIsInEditor:(NSEvent *)e {
    NSView *content = _editor.scrollView.documentView;
    if (!content.window || content.window != e.window) return NO;
    NSView *hit = [e.window.contentView hitTest:e.locationInWindow];
    return hit && [hit isDescendantOf:content];
}

// One set of application-wide hooks, installed with the first document and held for the life of the process. All
// of them cover behaviour the Cocoa backend gives no seam for: a right-click it never forwards to the Editor, a
// paste it implements on its content view, a Delete key it swallows, and mouse buttons nothing listens to. A
// monitor is per application, not per view, so each one first asks which live document the event belongs to and
// returns the event untouched when the answer is none.
//
// ponytail: N++'s other document-switching gesture, the wheel with the right button held (NppBigSwitch
// WM_MOUSEWHEEL / MK_RBUTTON), is not here. AppKit pops a view's context menu on right-mouse-*down* where Windows
// pops it on up, so the menu is already tracking — in its own event loop, which local monitors do not see — before
// any wheel event could arrive. Making it reachable means swallowing the right-mouse-down and popping
// [content menuForEvent:] on right-mouse-up instead; that is the upgrade, and it changes how every right-click in
// the editor feels on macOS, which is why it is not taken here.
+ (void)installEditorHooks {
    static NSMutableArray *hooks;   // held for the life of the process; dropping one un-hooks every editor
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hooks = [NSMutableArray array];
        void (^watch)(NSEventMask, NSEvent *(^)(NSEvent *)) = ^(NSEventMask mask, NSEvent *(^handler)(NSEvent *)) {
            id m = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:handler];
            if (m) [hooks addObject:m];
        };

        // On Windows the right-click reaches Scintilla, which moves the caret unless the click is inside the
        // selection; "Right-click keeps the selection" is what stops it doing that outside the selection too. The
        // Cocoa backend never forwards a right-click in the text area to the Editor at all, so *both* halves live
        // here: without this the port would behave as though the box were permanently ticked.
        watch(NSEventMaskRightMouseDown, ^NSEvent *(NSEvent *e) {
            for (NPPDocument *d in NPPLiveDocuments())
                if ([d handleRightMouseDown:e]) return (NSEvent *)nil;   // bookmark margin: it showed its own menu
            return e;
        });

        // Plain Delete only, as upstream (it bails out on Shift / Ctrl / Alt).
        watch(NSEventMaskKeyDown, ^NSEvent *(NSEvent *e) {
            const NSEventModifierFlags mods = NSEventModifierFlagShift | NSEventModifierFlagControl |
                                              NSEventModifierFlagOption | NSEventModifierFlagCommand;
            if (e.keyCode != 117 /* forward delete */ || (e.modifierFlags & mods) != 0) return e;
            NPPDocument *d = [NPPDocument documentFocusedIn:e.window];
            return (d && [d deleteForwardAtMultipleCarets]) ? (NSEvent *)nil : e;
        });

        watch(NSEventMaskOtherMouseUp, ^NSEvent *(NSEvent *e) {
            const NSInteger delta = NPPDocSwitchDeltaForButton(e.buttonNumber);
            if (delta == 0) return e;
            NPPDocument *d = [NPPDocument documentFocusedIn:e.window];
            if (!d) for (NPPDocument *c in NPPLiveDocuments()) if ([c eventIsInEditor:e]) { d = c; break; }
            return (d && [d switchDocumentBy:delta]) ? (NSEvent *)nil : e;
        });

        Method paste = class_getInstanceMethod([ScintillaView contentViewClass], @selector(paste:));
        if (paste) NPPOriginalPasteIMP = method_setImplementation(paste, (IMP)NPPPasteDistributingToCarets);
    });
}

// YES when the event was consumed and must not reach Scintilla.
- (BOOL)handleRightMouseDown:(NSEvent *)e {
    ScintillaView *ed = _editor;
    NSView *content = ed.scrollView.documentView;
    if (!content.window || content.window != e.window) return NO;
    // Hit test, not a frame check: anything sitting on top of the editor (an overlay, an autocompletion list) owns
    // its own clicks, and the clip view already rejects a point scrolled out of sight.
    NSView *hit = [e.window.contentView hitTest:e.locationInWindow];
    NSView *marginView = ed.scrollView.verticalRulerView;   // the Cocoa backend draws every margin in the ruler view
    BOOL onMargin = marginView && [hit isDescendantOf:marginView];
    if (!onMargin && ![hit isDescendantOf:content]) return NO;
    NSPoint local = [content convertPoint:e.locationInWindow fromView:nil];
    // Scintilla's own coordinate space: view coordinates less the scroll offset (ScintillaCocoa::ConvertPoint).
    NSPoint origin = ed.scrollView.contentView.bounds.origin;
    const sptr_t x = (sptr_t)(local.x - origin.x), y = (sptr_t)(local.y - origin.y);
    if (onMargin) return [self popUpMarginMenuAtX:x forEvent:e];
    // The margins are Scintilla's business (N++ compares against the same edge before swallowing the click).
    if (x < NPPSci(ed, SCI_POINTXFROMPOSITION, 0, 0) + NPPSci(ed, SCI_GETXOFFSET)) return NO;
    sptr_t pos = [self caretPositionForRightClickAtPosition:NPPSci(ed, SCI_POSITIONFROMPOINT, (uptr_t)x, y)];
    if (pos >= 0) NPPSci(ed, SCI_SETEMPTYSELECTION, (uptr_t)pos);
    return NO;
}

// ViewStyle::MarginFromLocation with marginInside == false (what ScintillaCocoa sets): the margins are their own
// view, sitting left of the text, so in Scintilla's coordinates they run from -(total width) up to 0. -1 = not a margin.
static sptr_t NPPMarginAtX(ScintillaView *ed, sptr_t x) {
    const sptr_t count = MIN((sptr_t)SC_MAX_MARGIN + 1, MAX((sptr_t)0, NPPSci(ed, SCI_GETMARGINS)));
    sptr_t widths[SC_MAX_MARGIN + 1] = {0}, left = 0;
    for (sptr_t i = 0; i < count; i++) { widths[i] = NPPSci(ed, SCI_GETMARGINWIDTHN, (uptr_t)i); left -= widths[i]; }
    for (sptr_t i = 0; i < count; i++) {
        if (x >= left && x < left + widths[i]) return i;
        left += widths[i];
    }
    return -1;
}

// The live Search > Bookmark submenu, found by one of its commands rather than by its title, so it cannot drift
// from the main menu and still works in a translated build. nil before the menus are built (--selftest).
static NSMenu *NPPBookmarkMenu(NSMenu *root) {
    for (NSMenuItem *item in root.itemArray) {
        if (item.submenu) { NSMenu *found = NPPBookmarkMenu(item.submenu); if (found) return found; }
        else if (item.tag == NPPCmdSearchToggleBookmark) return item.menu;
    }
    return nil;
}

// N++ NppNotification.cpp SCN_MARGINRIGHTCLICK: a plain right-click on the bookmark margin pops the Search >
// Bookmark submenu. It cannot be driven from that notification here — SCIMarginView pops the editor's context menu
// *before* it hands the click to Scintilla, so by the time SCN_MARGINRIGHTCLICK arrived the wrong menu would
// already have been and gone. So the click is taken here, ahead of both, and swallowed. Every other margin is left
// exactly as it was, editor context menu included; upstream's rule is only about the symbol margin.
- (BOOL)popUpMarginMenuAtX:(sptr_t)x forEvent:(NSEvent *)e {
    const NSEventModifierFlags mods = NSEventModifierFlagShift | NSEventModifierFlagControl |
                                      NSEventModifierFlagOption | NSEventModifierFlagCommand;
    if ((e.modifierFlags & mods) || NPPMarginAtX(_editor, x) != NPPMarginSymbol) return NO;
    NSMenu *bookmarks = NPPBookmarkMenu(NSApp.mainMenu);
    if (!bookmarks) return NO;
    [NSMenu popUpContextMenu:bookmarks withEvent:e forView:_editor.scrollView.verticalRulerView];
    return YES;
}

// The position the caret should move to, or -1 to leave the selection alone: inside an existing selection it never
// moves (Scintilla's own PointInSelection rule), and NPPRightClickKeepsSelection extends that to the whole view.
- (sptr_t)caretPositionForRightClickAtPosition:(sptr_t)pos {
    if (NPPPreferences.shared.rightClickKeepsSelection) return -1;
    ScintillaView *ed = _editor;
    if (pos < 0) return -1;
    for (sptr_t i = 0, n = NPPSci(ed, SCI_GETSELECTIONS); i < n; i++)
        if (pos >= NPPSci(ed, SCI_GETSELECTIONNSTART, (uptr_t)i) && pos < NPPSci(ed, SCI_GETSELECTIONNEND, (uptr_t)i))
            return -1;
    return pos;
}

#pragma mark File removed from disk (N++ checkModifiedDocument, DOC_DELETED)

- (BOOL)fileWasRemovedFromDisk {
    if (!_fileURL || !_hasMTime || _isMonitoring) return NO;   // monitoring (tail -f) handles rotation itself
    return ![_fileURL checkResourceIsReachableAndReturnError:NULL];
}

// The reload sweep skips a vanished file (it can never reload); this is the other half of N++'s answer to it.
- (void)appDidBecomeActive:(NSNotification *)n {
    [self recheckFileReadOnlyState];   // it may have been locked (or unlocked) while another app had the front
    if (![self fileWasRemovedFromDisk]) { _askedAboutRemoval = NO; return; }   // back on disk: ask again if it goes again
    if (_askedAboutRemoval || !NPPPreferences.shared.checkFileChangesOnActivation) return;
    _askedAboutRemoval = YES;
    // Off the notification, so the modal does not run inside the activation broadcast (other observers still have
    // to see it) and so two vanished buffers queue their alerts instead of nesting them.
    __weak NPPDocument *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf askWhetherToKeepRemovedFile]; });
}

- (void)askWhetherToKeepRemovedFile {
    if (!self.delegate || ![self fileWasRemovedFromDisk]) return;   // closed, or it came back while we were queued
    id<NPPDocumentCloser> closer = (id<NPPDocumentCloser>)self.delegate;
    const BOOL canClose = [closer respondsToSelector:@selector(closeDocument:)];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Keep non existing file";
    alert.informativeText = [NSString stringWithFormat:@"The file \"%@\" doesn't exist anymore.\nKeep this file in editor?",
                             _fileURL.path ?: self.displayName];
    [alert addButtonWithTitle:@"Keep"];
    if (canClose) [alert addButtonWithTitle:@"Close"];
    if ([alert runModal] != NSAlertFirstButtonReturn && canClose) { [closer closeDocument:self]; return; }
    // N++ setUnsync(true): the buffer no longer matches anything on disk, so it counts as unsaved work.
    if (!_forcedDirty) { _forcedDirty = YES; [self notifyDirty]; }
}

// ---------------------------------------------------------------------------------------------------------------
// Headless checks (NPPSelfTest calls +selfCheckFailures on every module that has one)
// ---------------------------------------------------------------------------------------------------------------

// The URL scanner, tag matcher and indent decision are pure functions on text, so they are checked directly.
// The word-character table is the one thing that only shows up on a live editor (applying a language resets it),
// so that one borrows a hidden window the way NPPEditCommands' checks do.
static NSView *NPPScratchHost(void) {
    static NSWindow *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
        host.releasedWhenClosed = NO;
    });
    return host.contentView;
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(NSString *, BOOL, NSString *) = ^(NSString *what, BOOL ok, NSString *detail) {
        if (!ok) [fails addObject:[NSString stringWithFormat:@"%@: %@", what, detail ?: @""]];
    };

    // ---- URL scanner (N++ isUrl). The first URL in the text, and where it ends. ----
    // The list the scanner is given at runtime: the five built-ins plus NPPUriSchemes, whose default is N++'s.
    const std::vector<std::u32string> schemes = NPPUrlSchemes(kDefaultUriSchemes);
    NSString *(^firstURL)(NSString *) = ^NSString *(NSString *s) {
        std::string utf8 = s.UTF8String ?: "";
        NPPCodePoints t = NPPDecodeUTF8(utf8.data(), utf8.size());
        for (size_t i = 0; i < t.cp.size(); ) {
            size_t len = 0;
            bool isUrl = NPPIsUrlAt(t.cp, i, &len, schemes);
            if (len == 0) break;
            if (isUrl)
                return [[NSString alloc] initWithBytes:utf8.data() + t.byteOffset[i]
                                                length:t.byteOffset[i + len] - t.byteOffset[i] encoding:NSUTF8StringEncoding];
            i += len;
        }
        return nil;
    };
    void (^url)(NSString *, NSString *, NSString *) = ^(NSString *what, NSString *text, NSString *want) {
        NSString *got = firstURL(text);
        if (![(got ?: @"(none)") isEqualToString:(want ?: @"(none)")])
            [fails addObject:[NSString stringWithFormat:@"url.%@: got %@, want %@", what, got ?: @"(none)", want ?: @"(none)"]];
    };
    url(@"plain", @"see http://a.com/x now", @"http://a.com/x");
    url(@"trailing-period", @"see http://a.com/x.", @"http://a.com/x");
    url(@"trailing-punctuation", @"http://a.com/x?!,", @"http://a.com/x");
    url(@"unbalanced-paren", @"(http://a.com/x)", @"http://a.com/x");
    url(@"balanced-paren", @"see http://a.com/x(y) now", @"http://a.com/x(y)");
    url(@"query", @"http://a.com/s?q=1&r=2 tail", @"http://a.com/s?q=1&r=2");
    url(@"query-brackets-keep-spaces", @"http://a.com/s?q=(a b) end", @"http://a.com/s?q=(a b)");
    url(@"fragment", @"see http://a.com/x#frag now", @"http://a.com/x#frag");
    url(@"uppercase-scheme", @"see HTTP://A.com/x now", @"HTTP://A.com/x");
    url(@"scheme-not-in-list", @"look at foo://a.com/x", nil);
    url(@"scheme-in-default-list", @"look at svn://a.com/x", @"svn://a.com/x");
    url(@"scheme-needs-a-body", @"http:// nothing", nil);
    url(@"scheme-glued-to-a-word", @"nothttp://a.com/x", nil);
    url(@"scheme-glued-to-a-digit", @"3http://a.com/x", nil);   // isUrlSchemeDelimiter: no scheme starts after [0-9A-Za-z_]
    url(@"mailto", @"write to mailto:a@b.com, please", @"mailto:a@b.com");
    url(@"no-url", @"nothing to see here", nil);
    url(@"apostrophe-enclosed", @"'http://a.com/x'", @"http://a.com/x");
    url(@"non-breaking-space-ends-it", @"http://a.com/x y", @"http://a.com/x");
    {   // the configured scheme list is honoured
        const std::vector<std::u32string> custom = NPPUrlSchemes([kDefaultUriSchemes stringByAppendingString:@" zoom://"]);
        std::string utf8 = "join zoom://a/b now";
        NPPCodePoints t = NPPDecodeUTF8(utf8.data(), utf8.size());
        size_t len = 0;
        bool found = false;
        for (size_t i = 0; i < t.cp.size() && !found; ) {
            found = NPPIsUrlAt(t.cp, i, &len, custom);
            if (len == 0) break;
            if (!found) i += len;
        }
        expect(@"url.custom-scheme", found && len == strlen("zoom://a/b"), @"zoom:// from NPPUriSchemes was not recognised");
    }

    // ---- Matched HTML/XML tags (N++ getXmlMatchedTagsPos / getAttributesPos) ----
    void (^tag)(NSString *, const char *, long, long, long, long, long, long) =
        ^(NSString *what, const char *text, long caret, long openStart, long nameEnd, long openEnd, long closeStart, long closeEnd) {
        NPPXmlTags t;
        std::string s(text);
        BOOL ok = NPPFindMatchedTags(s, caret, t);
        BOOL want = openStart >= 0;
        if (ok != want || (want && (t.openStart != openStart || t.nameEnd != nameEnd || t.openEnd != openEnd ||
                                    t.closeStart != closeStart || t.closeEnd != closeEnd)))
            [fails addObject:[NSString stringWithFormat:@"tag.%@: got %d (%ld,%ld,%ld,%ld,%ld), want (%ld,%ld,%ld,%ld,%ld)",
                              what, (int)ok, t.openStart, t.nameEnd, t.openEnd, t.closeStart, t.closeEnd,
                              openStart, nameEnd, openEnd, closeStart, closeEnd]];
    };
    tag(@"open-tag", "<div id=\"a\">x</div>", 2, 0, 4, 12, 13, 19);
    tag(@"close-tag", "<div id=\"a\">x</div>", 15, 0, 4, 12, 13, 19);
    tag(@"caret-just-past-gt", "<div>x</div>", 5, 0, 4, 5, 6, 12);
    tag(@"self-closing", "<br/>", 2, 0, 3, 5, -1, -1);
    tag(@"nested-same-name", "<a><a></a></a>", 1, 0, 2, 3, 10, 14);
    tag(@"inner-of-nested", "<a><a></a></a>", 4, 3, 5, 6, 6, 10);
    tag(@"caret-in-text", "<div>x</div>", 5 + 1, -1, 0, 0, 0, 0);
    tag(@"caret-at-tag-start", "<div>x</div>", 0, -1, 0, 0, 0, 0);
    tag(@"gt-inside-attribute-value", "<div a=\"b>c\">x</div>", 10, 0, 4, 13, 14, 20);
    tag(@"case-insensitive-name", "<DIV>x</div>", 2, 0, 4, 5, 6, 12);   // HTML tag names do not have to match in case
    tag(@"comment-is-not-a-tag", "<!-- <div> -->", 6, -1, 0, 0, 0, 0);
    tag(@"unmatched-open", "<div>x", 2, -1, 0, 0, 0, 0);
    {
        auto attrs = NPPTagAttributePositions(std::string("<div id=\"a\" x='y'>"), 4, 17);
        expect(@"tag.attributes", attrs.size() == 2 && attrs[0].first == 5 && attrs[0].second == 11
                                  && attrs[1].first == 12 && attrs[1].second == 17,
               [NSString stringWithFormat:@"%zu attribute run(s)", attrs.size()]);
    }
    expect(@"tag.markup-languages", NPPLanguageIsMarkupForTags(@"xml") && NPPLanguageIsMarkupForTags(@"html")
                                    && !NPPLanguageIsMarkupForTags(@"cpp"), @"the language set the matcher runs for is wrong");

    // ---- Advanced auto-indent decision (N++ maintainIndentation, C-like branch) ----
    void (^indent)(NSString *, char, char, BOOL, const char *, const char *, long, long, BOOL) =
        ^(NSString *what, char prev, char next, BOOL noSingle, const char *prevLine, const char *prevPrev,
          long prevIndent, long want, BOOL wantSplit) {
        BOOL split = NO;
        long got = NPPAdvancedNewlineIndent(prev, next, noSingle, std::string(prevLine), std::string(prevPrev),
                                            prevIndent, 4, &split);
        if (got != want || split != wantSplit)
            [fails addObject:[NSString stringWithFormat:@"indent.%@: got %ld/split %d, want %ld/split %d",
                              what, got, (int)split, want, (int)wantSplit]];
    };
    indent(@"after-open-brace", '{', 'x', NO, "if (a) {", "", 4, 8, NO);
    indent(@"brace-sandwich-splits", '{', '}', NO, "if (a) {", "", 4, 8, YES);
    indent(@"before-open-brace", ';', '{', NO, "if (a)", "", 4, 4, NO);
    indent(@"condition-line-adds-a-level", ')', 'x', NO, "  if (a > b)", "", 2, 6, NO);
    indent(@"else-adds-a-level", 'e', 'x', NO, "  else", "", 2, 6, NO);
    indent(@"body-of-a-condition-unindents", ';', 'x', NO, "      doIt();", "  if (a > b)", 6, 2, NO);
    indent(@"plain-line-carries-over", ';', 'x', NO, "  a = 1;", "  b = 2;", 2, 2, NO);
    indent(@"no-single-line-control", ')', 'x', YES, "  if (a > b)", "", 2, 2, NO);
    indent(@"word-boundary-on-else", ';', 'x', NO, "  myelse", "", 2, 2, NO);
    expect(@"indent.python-colon", NPPPythonBlockColonOffset("def f(a):") == 8, @"colon at end of a def not found");
    expect(@"indent.python-colon-comment", NPPPythonBlockColonOffset("if x:  # go") == 4, @"colon before a comment not found");
    expect(@"indent.python-no-colon", NPPPythonBlockColonOffset("x = {1: 2}") == -1, @"a dict colon opened a block");
    expect(@"indent.family-cpp", NPPIndentFamilyForLanguage(@"cpp", NULL) == NPPIndentFamilyCLike, @"cpp is not C-like");
    expect(@"indent.family-python", NPPIndentFamilyForLanguage(@"python", NULL) == NPPIndentFamilyPython, @"python is not Python");
    expect(@"indent.family-text", NPPIndentFamilyForLanguage(@"normal", NULL) == NPPIndentFamilyOther, @"normal text is not Other");
    {   // the table behind the noSingleLineControl flag the checks above pass in by hand
        BOOL nsPerl = NO, nsCpp = YES;
        NPPIndentFamilyForLanguage(@"perl", &nsPerl);
        NPPIndentFamilyForLanguage(@"cpp", &nsCpp);
        expect(@"indent.no-single-line-control-table", nsPerl && !nsCpp, @"perl/cpp are on the wrong side of it");
    }

    // ---- Matched-pair configuration: each toggle has to be independent ----
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    id savedBrackets = [d objectForKey:kKeyPairBrackets], savedPairs = [d objectForKey:kKeyPairsUserDefined];
    [d setBool:NO forKey:kKeyPairBrackets];
    [d setObject:@[@"<>", @"bad", @"«»"] forKey:kKeyPairsUserDefined];
    {
        NPPMatchedPairConf conf = NPPCurrentMatchedPairConf();
        expect(@"pairs.independent-toggle", !conf.brackets && conf.parentheses && conf.curly && conf.quotes && conf.doubleQuotes,
               @"turning [ ] off changed another pair");
        expect(@"pairs.user-defined", conf.userPairs.size() == 1 && conf.userPairs[0].first == '<' && conf.userPairs[0].second == '>',
               [NSString stringWithFormat:@"%zu user pair(s); non-ASCII and malformed entries must be dropped", conf.userPairs.size()]);
    }
    savedBrackets ? [d setObject:savedBrackets forKey:kKeyPairBrackets] : [d removeObjectForKey:kKeyPairBrackets];
    savedPairs ? [d setObject:savedPairs forKey:kKeyPairsUserDefined] : [d removeObjectForKey:kKeyPairsUserDefined];

    // ---- Large-file restriction thresholds ----
    id savedMB = [d objectForKey:kKeyLargeFileSizeMB], savedOn = [d objectForKey:kKeyLargeFileEnabled];
    [d setInteger:10 forKey:kKeyLargeFileSizeMB];
    [d setBool:YES forKey:kKeyLargeFileEnabled];
    expect(@"largefile.over-the-limit", NPPFileIsLargeFile(11LL * 1024 * 1024), @"11 MB is not large at a 10 MB limit");
    expect(@"largefile.under-the-limit", !NPPFileIsLargeFile(9LL * 1024 * 1024), @"9 MB is large at a 10 MB limit");
    // N++ compares with >=, so the limit itself is already large and one byte under is not.
    expect(@"largefile.at-the-limit", NPPFileIsLargeFile(10LL * 1024 * 1024), @"exactly 10 MB is not large at a 10 MB limit");
    expect(@"largefile.one-byte-under", !NPPFileIsLargeFile(10LL * 1024 * 1024 - 1), @"one byte under the limit is large");
    [d setBool:NO forKey:kKeyLargeFileEnabled];
    expect(@"largefile.restriction-off", !NPPFileIsLargeFile(1000LL * 1024 * 1024), @"the limit applied while disabled");
    savedMB ? [d setObject:savedMB forKey:kKeyLargeFileSizeMB] : [d removeObjectForKey:kKeyLargeFileSizeMB];
    savedOn ? [d setObject:savedOn forKey:kKeyLargeFileEnabled] : [d removeObjectForKey:kKeyLargeFileEnabled];

    // ---- Prevented C0 input (N++ _npcNoInputC0): the exclusions are the whole point ----
    expect(@"c0.control-characters", NPPIsFilteredC0Char(0) && NPPIsFilteredC0Char(1) && NPPIsFilteredC0Char(31)
                                     && NPPIsFilteredC0Char(127), @"a control character was let through");
    expect(@"c0.editing-characters", !NPPIsFilteredC0Char('\t') && !NPPIsFilteredC0Char('\n') && !NPPIsFilteredC0Char('\r')
                                     && !NPPIsFilteredC0Char(' ') && !NPPIsFilteredC0Char('a'),
           @"tab / newline / ordinary text must never be filtered");

    // ---- Tab name derived from the first line (N++ Buffer::normalizeTabName) ----
    void (^tabname)(NSString *, const char *, NSString *) = ^(NSString *what, const char *line, NSString *want) {
        NSString *got = NPPTabNameFromFirstLine(std::string(line));
        if (![(got ?: @"(nil)") isEqualToString:(want ?: @"(nil)")])
            [fails addObject:[NSString stringWithFormat:@"tabname.%@: got %@, want %@", what, got ?: @"(nil)", want ?: @"(nil)"]];
    };
    tabname(@"plain", "hello world", @"hello world");
    tabname(@"trims-and-strips-invalid", "  My Notes: a/b  ", @"My Notes ab");
    tabname(@"nothing-usable", " \t / ", nil);
    tabname(@"empty-line", "", nil);
    tabname(@"length-cap", std::string(70, 'x').c_str(), [@"" stringByPaddingToLength:63 withString:@"x" startingAtIndex:0]);

    // ---- Delimiter selection (N++ SCN_DOUBLECLICK with Ctrl) ----
    void (^delim)(NSString *, const char *, size_t, const char *, const char *, long, long) =
        ^(NSString *what, const char *text, size_t click, const char *open, const char *close, long wantOpen, long wantClose) {
        long gotOpen = -1, gotClose = -1;
        BOOL ok = NPPFindDelimiterRange(std::string(text), click, std::string(open), std::string(close), &gotOpen, &gotClose);
        if (!ok) gotOpen = gotClose = -1;
        if (gotOpen != wantOpen || gotClose != wantClose)
            [fails addObject:[NSString stringWithFormat:@"delimiter.%@: got (%ld,%ld), want (%ld,%ld)",
                              what, gotOpen, gotClose, wantOpen, wantClose]];
    };
    delim(@"parentheses", "a (b c) d", 4, "(", ")", 2, 6);
    delim(@"innermost-pair-wins", "(a (b) c)", 4, "(", ")", 3, 5);
    delim(@"outer-pair-when-click-is-outside-the-inner", "((a) b)", 5, "(", ")", 0, 6);
    delim(@"click-outside-any-pair", "(a) b", 4, "(", ")", -1, -1);
    delim(@"same-delimiter-nearest-each-way", "x \"a b\" y", 4, "\"", "\"", 2, 6);
    delim(@"escaped-quote-is-not-a-delimiter", "\"a\\\"b\"", 4, "\"", "\"", 0, 5);
    delim(@"nothing-to-find", "abc", 1, "(", ")", -1, -1);
    delim(@"empty-text", "", 0, "(", ")", -1, -1);
    // A delimiter the preferences page accepts but that is more than one byte: matched whole, so its lead byte does
    // not stand in for every other two-byte character (0xC2 is shared by "«", "»" and everything in U+0080..U+00BF).
    delim(@"multi-byte-pair", "a «b c» d", 5, "«", "»", 2, 7);
    delim(@"multi-byte-lead-byte-is-not-a-match", "a ©b© c", 4, "«", "»", -1, -1);
    delim(@"multi-byte-same-delimiter", "x «a b« y", 5, "«", "«", 2, 7);

    // ---- The comment/PHP/ASP zone tag matching stays out of (N++ _enableHiliteNonHTMLZone) ----
    expect(@"zone.non-html", NPPStyleIsNonHTMLZone(SCE_H_COMMENT) && NPPStyleIsNonHTMLZone(SCE_H_ASP)
                             && NPPStyleIsNonHTMLZone(SCE_H_QUESTION) && NPPStyleIsNonHTMLZone(SCE_HPHP_DEFAULT)
                             && NPPStyleIsNonHTMLZone(SCE_HJ_KEYWORD), @"a comment / ASP / PHP / script style was called HTML");
    expect(@"zone.html", !NPPStyleIsNonHTMLZone(SCE_H_DEFAULT) && !NPPStyleIsNonHTMLZone(SCE_H_TAG)
                         && !NPPStyleIsNonHTMLZone(SCE_H_ATTRIBUTE) && !NPPStyleIsNonHTMLZone(SCE_H_DOUBLESTRING),
           @"a plain HTML style was called a non-HTML zone");

    // ---- A file that has gone from disk (N++ checkModifiedDocument / DOC_DELETED) ----
    {
        NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"npp-selfcheck-vanish.txt"]];
        [@"x" writeToURL:tmp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NPPDocument *doc = [[NPPDocument alloc] initWithContentsOfURL:tmp error:NULL];
        expect(@"removed.file-is-there", doc && ![doc fileWasRemovedFromDisk], @"an existing file reported itself removed");
        [NSFileManager.defaultManager removeItemAtURL:tmp error:NULL];
        expect(@"removed.file-is-gone", doc && [doc fileWasRemovedFromDisk], @"a deleted file went unnoticed");
        expect(@"removed.untitled-never-counts", ![[[NPPDocument alloc] initUntitled] fileWasRemovedFromDisk],
               @"an untitled buffer looked like a removed file");
    }

    // ---- OEM 720 and OEM 858: the two N++ code pages CoreFoundation cannot convert ----
    {
        NPPCharset *c720 = [NPPCharset charsetForIANAName:@"cp720"], *c858 = [NPPCharset charsetForIANAName:@"cp858"];
        expect(@"codepage.720-is-in-the-table", c720 != nil && c720.cfEncoding == NPPCodePageOEM720,
               @"OEM 720 is not in the character-set table, so its Encoding menu item cannot exist");
        expect(@"codepage.858-is-in-the-table", c858 != nil && c858.cfEncoding == NPPCodePageOEM858,
               @"OEM 858 is not in the character-set table, so its Encoding menu item cannot exist");

        // Both are lossless 8-bit code pages: all 256 bytes decode, and encode straight back to themselves. This
        // is also what proves the 128 high entries are distinct — a duplicate would come back as another byte.
        void (^roundTrip)(NSString *, CFStringEncoding) = ^(NSString *name, CFStringEncoding enc) {
            uint8_t all[256];
            for (int i = 0; i < 256; i++) all[i] = (uint8_t)i;
            std::string utf8;
            const NPPCodePage8Bit *cp = NPPCustomCodePage(enc);
            NSString *text = NPPDecodeBytes(all, sizeof all, enc, utf8)
                             ? [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding] : nil;
            NSData *back = (cp && text) ? NPPEncodeWithCodePage(text, cp) : nil;
            if (back.length == sizeof all && memcmp(back.bytes, all, sizeof all) == 0) return;
            [fails addObject:[NSString stringWithFormat:@"codepage.%@-round-trip: the 256 bytes came back as %lu bytes%@",
                              name, (unsigned long)back.length, text ? @"" : @" (they would not even decode)"]];
        };
        roundTrip(@"720", NPPCodePageOEM720);
        roundTrip(@"858", NPPCodePageOEM858);

        // 858 is built from CoreFoundation's 850, so it has to be 850 everywhere but the euro sign at 0xD5.
        uint8_t high[128];
        for (int i = 0; i < 128; i++) high[i] = (uint8_t)(0x80 + i);
        std::string u850, u858;
        NPPDecodeBytes(high, sizeof high, kCFStringEncodingDOSLatin1, u850);
        NPPDecodeBytes(high, sizeof high, NPPCodePageOEM858, u858);
        NSString *s850 = [[NSString alloc] initWithBytes:u850.data() length:u850.size() encoding:NSUTF8StringEncoding];
        NSString *s858 = [[NSString alloc] initWithBytes:u858.data() length:u858.size() encoding:NSUTF8StringEncoding];
        BOOL comparable = s850.length == 128 && s858.length == 128;
        int diffs = 0, lastDiff = -1;
        for (NSUInteger i = 0; comparable && i < 128; i++)
            if ([s850 characterAtIndex:i] != [s858 characterAtIndex:i]) { diffs++; lastDiff = (int)(0x80 + i); }
        expect(@"codepage.858-is-850-with-the-euro-at-D5",
               comparable && diffs == 1 && lastDiff == 0xD5 && [s858 characterAtIndex:0xD5 - 0x80] == 0x20AC,
               [NSString stringWithFormat:@"858 differs from CoreFoundation's 850 in %d byte(s) (last 0x%02X); "
                @"want exactly one: the euro sign at 0xD5", diffs, lastDiff]);

        // Three fixed points of the hand-written 720 table (Microsoft's cp720): a letter, a Latin leftover, NBSP.
        std::string alef;
        const uint8_t arabic[] = {0x9F, 0x82, 0xFF};
        NPPDecodeBytes(arabic, sizeof arabic, NPPCodePageOEM720, alef);
        expect(@"codepage.720-decodes-arabic", alef == "\xD8\xA7\xC3\xA9\xC2\xA0",   // U+0627 alef, U+00E9, U+00A0
               [NSString stringWithFormat:@"9F 82 FF decoded to \"%s\", want alef + e-acute + no-break space", alef.c_str()]);
    }

    // ---- The two code pages as the buffer sees them: "Convert to" and the save path ----
    {
        NPPDocument *doc = [[NPPDocument alloc] initUntitled];
        doc.editor.frame = NSMakeRect(0, 0, 400, 300);
        [NPPScratchHost() addSubview:doc.editor];
        doc.encoding = NPPEncodingANSI;
        doc.codepage = NPPCodePageOEM858;
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, "A\xE2\x82\xAC" "B");   // "A€B" (split so \xAC does not swallow the B)
        NSData *saved858 = [doc encodedDataForSave];
        const uint8_t want858[] = {'A', 0xD5, 'B'};
        expect(@"codepage.858-saves-the-euro-as-D5",
               saved858.length == sizeof want858 && memcmp(saved858.bytes, want858, sizeof want858) == 0,
               [NSString stringWithFormat:@"\"A€B\" saved as %@, want 41 D5 42", saved858]);

        doc.codepage = NPPCodePageOEM720;
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, "\xD8\xA7\xE2\x82\xAC");   // alef, then a euro sign 720 has no room for
        NSData *saved720 = [doc encodedDataForSave];
        const uint8_t want720[] = {0x9F, '?'};
        expect(@"codepage.720-saves-what-it-can-and-substitutes",
               saved720.length == sizeof want720 && memcmp(saved720.bytes, want720, sizeof want720) == 0,
               [NSString stringWithFormat:@"\"ا€\" saved as %@, want 9F 3F", saved720]);
        expect(@"codepage.720-names-itself", [[doc encodingDisplayName] isEqualToString:@"OEM 720"],
               [doc encodingDisplayName]);
        [doc.editor removeFromSuperview];
    }

    // ---- Right-click on the bookmark margin (N++ NppNotification SCN_MARGINRIGHTCLICK) ----
    {
        // The walk that finds Search > Bookmark in the live main menu. --selftest runs before any menu is built,
        // so it gets the shape the app builds, decoy submenu included.
        NSMenu *main = [[NSMenu alloc] initWithTitle:@"main"];
        NSMenu *search = [[NSMenu alloc] initWithTitle:@"Search"], *bookmark = [[NSMenu alloc] initWithTitle:@"Bookmark"];
        [main addItemWithTitle:@"Search" action:NULL keyEquivalent:@""].submenu = search;
        [search addItemWithTitle:@"Find…" action:NULL keyEquivalent:@""].tag = NPPCmdSearchFind;
        NSMenuItem *bookmarkItem = [search addItemWithTitle:@"Bookmark" action:NULL keyEquivalent:@""];
        bookmarkItem.submenu = bookmark;
        [bookmark addItemWithTitle:@"Toggle Bookmark" action:NULL keyEquivalent:@""].tag = NPPCmdSearchToggleBookmark;
        expect(@"marginmenu.finds-the-live-bookmark-submenu", NPPBookmarkMenu(main) == bookmark,
               @"the Bookmark submenu was not found by its Toggle Bookmark command");
        [search removeItem:bookmarkItem];
        expect(@"marginmenu.no-bookmark-command-means-no-menu", NPPBookmarkMenu(main) == nil && NPPBookmarkMenu(nil) == nil,
               @"a main menu without a Toggle Bookmark command still answered with some menu");
    }
    {
        NPPDocument *doc = [[NPPDocument alloc] initUntitled];
        ScintillaView *ed = doc.editor;
        ed.frame = NSMakeRect(0, 0, 400, 300);
        [NPPScratchHost() addSubview:ed];
        // Known widths, so the expected boundaries below are arithmetic and not a copy of the code being tested.
        // 10 + 20 + 30 + 0 = 60 px of margin, which in Scintilla's coordinates ends at the text, i.e. spans -60..0.
        const sptr_t widths[] = {10, 20, 30, 0};
        NPPSci(ed, SCI_SETMARGINS, 4);
        for (uptr_t i = 0; i < 4; i++) NPPSci(ed, SCI_SETMARGINWIDTHN, i, widths[i]);
        expect(@"margin.hit-line-numbers", NPPMarginAtX(ed, -60) == NPPMarginLineNumber && NPPMarginAtX(ed, -51) == NPPMarginLineNumber,
               @"the leftmost 10 px are not the line-number margin");
        expect(@"margin.hit-bookmarks", NPPMarginAtX(ed, -50) == NPPMarginSymbol && NPPMarginAtX(ed, -31) == NPPMarginSymbol,
               @"the bookmark margin is not where the right-click menu looks for it");
        expect(@"margin.hit-fold", NPPMarginAtX(ed, -30) == NPPMarginFolder && NPPMarginAtX(ed, -1) == NPPMarginFolder,
               @"the 30 px next to the text are not the fold margin");
        expect(@"margin.text-is-not-a-margin", NPPMarginAtX(ed, 0) == -1 && NPPMarginAtX(ed, 5) == -1 && NPPMarginAtX(ed, -61) == -1,
               @"a point in the text (or left of every margin) was called a margin");
        [ed removeFromSuperview];
    }

    // ---- Custom word characters survive a language being applied (Preferences > Delimiter) ----
    NPPPreferences *p = NPPPreferences.shared;
    BOOL savedUseDefault = p.useDefaultWordChars;
    NSString *savedCustom = p.customWordChars;
    p.useDefaultWordChars = NO;
    p.customWordChars = @"$";
    {
        NPPDocument *doc = [[NPPDocument alloc] initUntitled];   // the only initialiser that builds the editor
        doc.editor.frame = NSMakeRect(0, 0, 400, 300);
        [NPPScratchHost() addSubview:doc.editor];                // a hosted view, so Scintilla is happy to answer
        doc.language = NPPLanguageManager.shared.normalTextLanguage;
        sptr_t n = NPPSci(doc.editor, SCI_GETWORDCHARS, 0, 0);
        std::string chars((size_t)MAX((sptr_t)0, n), '\0');
        if (n > 0) NPPSci(doc.editor, SCI_GETWORDCHARS, 0, (sptr_t)&chars[0]);
        expect(@"wordchars.custom-survives-language-apply", chars.find('$') != std::string::npos,
               @"'$' was dropped from SCI_SETWORDCHARS when the language was applied");
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, "a$b c");
        expect(@"wordchars.word-boundary", NPPSci(doc.editor, SCI_WORDENDPOSITION, 0, 1) == 3,
               @"'a$b' is not one word although '$' is a word character");

        // ---- The window the URL scanner and the smart highlight get is capped (a minified file is one long line) ----
        std::string oneLongLine(3 * (size_t)kMaxVisibleWindow, 'x');
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, oneLongLine.c_str());
        sptr_t from = 0, to = 0;
        [doc visibleRangeStart:&from end:&to];
        expect(@"largefile.visible-window-is-capped", to - from <= kMaxVisibleWindow && to >= from,
               [NSString stringWithFormat:@"a %zu-byte single line gave a %ld-byte window", oneLongLine.size(), (long)(to - from)]);
        [doc.editor removeFromSuperview];
    }
    p.useDefaultWordChars = savedUseDefault;
    p.customWordChars = savedCustom;

    // ---- The settings that only exist on a live editor ----
    {
        NPPDocument *doc = [[NPPDocument alloc] initUntitled];
        ScintillaView *ed = doc.editor;
        ed.frame = NSMakeRect(0, 0, 400, 300);
        [NPPScratchHost() addSubview:ed];

        BOOL savedC0 = p.preventC0Input;
        p.preventC0Input = YES;
        NPPSciStr(ed, SCI_SETTEXT, 0, "ab");
        NPPSci(ed, SCI_GOTOPOS, 2);
        NPPSciStr(ed, SCI_REPLACESEL, 0, "\x01");
        [doc charAdded:1];
        expect(@"c0.typed-control-character-is-removed", NPPSciGetText(ed) == "ab", @(NPPSciGetText(ed).c_str()));
        NPPSciStr(ed, SCI_REPLACESEL, 0, "\t");
        [doc charAdded:'\t'];
        expect(@"c0.typed-tab-survives", NPPSciGetText(ed) == "ab\t", @(NPPSciGetText(ed).c_str()));
        p.preventC0Input = savedC0;

        // Right-click: outside the selection the caret follows, inside it never does, and the preference pins it.
        BOOL savedKeep = p.rightClickKeepsSelection;
        NPPSciStr(ed, SCI_SETTEXT, 0, "hello world");
        NPPSci(ed, SCI_SETSEL, 0, 5);
        p.rightClickKeepsSelection = NO;
        expect(@"rightclick.outside-moves-the-caret", [doc caretPositionForRightClickAtPosition:8] == 8,
               @"a right-click past the selection did not move the caret");
        expect(@"rightclick.inside-keeps-the-selection", [doc caretPositionForRightClickAtPosition:2] == -1,
               @"a right-click inside the selection cleared it");
        p.rightClickKeepsSelection = YES;
        expect(@"rightclick.preference-keeps-the-selection", [doc caretPositionForRightClickAtPosition:8] == -1,
               @"the preference did not stop the caret moving");
        p.rightClickKeepsSelection = savedKeep;

        // Delimiter selection end to end: the text between the delimiters, not including them.
        NSString *savedOpen = p.delimiterOpen, *savedClose = p.delimiterClose;
        BOOL savedSeveral = p.delimiterSelectionOnEntireDocument;
        p.delimiterOpen = @"("; p.delimiterClose = @")"; p.delimiterSelectionOnEntireDocument = NO;
        NPPSciStr(ed, SCI_SETTEXT, 0, "a (b c) d");
        [doc selectBetweenDelimitersAtPosition:4];
        expect(@"delimiter.live-selection", NPPSci(ed, SCI_GETSELECTIONSTART) == 3 && NPPSci(ed, SCI_GETSELECTIONEND) == 6,
               [NSString stringWithFormat:@"selected %ld..%ld, want 3..6",
                (long)NPPSci(ed, SCI_GETSELECTIONSTART), (long)NPPSci(ed, SCI_GETSELECTIONEND)]);
        // "Allow on several lines" is the only thing that lets the match cross an EOL.
        NPPSciStr(ed, SCI_SETTEXT, 0, "a (b\nc) d");
        NPPSci(ed, SCI_SETEMPTYSELECTION, 3);
        [doc selectBetweenDelimitersAtPosition:3];
        expect(@"delimiter.one-line-only", NPPSci(ed, SCI_GETSELECTIONSTART) == NPPSci(ed, SCI_GETSELECTIONEND),
               @"a delimited range spanning an EOL was selected although several lines are off");
        p.delimiterSelectionOnEntireDocument = YES;
        [doc selectBetweenDelimitersAtPosition:3];
        expect(@"delimiter.several-lines", NPPSci(ed, SCI_GETSELECTIONSTART) == 3 && NPPSci(ed, SCI_GETSELECTIONEND) == 6,
               [NSString stringWithFormat:@"selected %ld..%ld, want 3..6",
                (long)NPPSci(ed, SCI_GETSELECTIONSTART), (long)NPPSci(ed, SCI_GETSELECTIONEND)]);
        // A delimiter that is not one byte still selects the right range, and does not cut a character in half.
        p.delimiterOpen = @"«"; p.delimiterClose = @"»"; p.delimiterSelectionOnEntireDocument = NO;
        NPPSciStr(ed, SCI_SETTEXT, 0, "a «b c» d");
        [doc selectBetweenDelimitersAtPosition:5];
        expect(@"delimiter.live-multi-byte", NPPSciGetRange(ed, NPPSci(ed, SCI_GETSELECTIONSTART), NPPSci(ed, SCI_GETSELECTIONEND)) == "b c",
               @(NPPSciGetRange(ed, NPPSci(ed, SCI_GETSELECTIONSTART), NPPSci(ed, SCI_GETSELECTIONEND)).c_str()));
        p.delimiterOpen = savedOpen; p.delimiterClose = savedClose; p.delimiterSelectionOnEntireDocument = savedSeveral;

        // ---- The switches -applyPreferences hands to Scintilla / the scroll view. Each one is read back, so a
        //      preference that is fetched into a local and then dropped shows up here rather than in a bug report. ----
        BOOL savedSmooth = p.smoothFont, savedNoDrag = p.disableSelectedTextDragDrop;
        BOOL savedSelFg = p.selectedTextForegroundSingleColor, savedNoScroll = p.disableAdvancedScrolling;
        p.smoothFont = YES; p.disableSelectedTextDragDrop = YES;
        p.selectedTextForegroundSingleColor = YES; p.disableAdvancedScrolling = YES;
        [doc applyPreferences];
        expect(@"prefs.smooth-font-on", NPPSci(ed, SCI_GETFONTQUALITY) == SC_EFF_QUALITY_LCD_OPTIMIZED,
               @"SCI_SETFONTQUALITY did not follow \"Enable smooth font\"");
        expect(@"prefs.drag-drop-off", NPPSci(ed, SCI_GETDRAGDROPENABLED) == 0,
               @"selected-text drag and drop stayed on");
        expect(@"prefs.selection-foreground-on", NPPSci(ed, SCI_GETELEMENTISSET, SC_ELEMENT_SELECTION_TEXT) != 0,
               @"no colour was put on the selected text");
        expect(@"prefs.advanced-scrolling-off", ed.scrollView.verticalScrollElasticity == NSScrollElasticityNone
                                                && !ed.scrollView.usesPredominantAxisScrolling,
               @"the scroll view kept its trackpad behaviour");
        p.smoothFont = NO; p.disableSelectedTextDragDrop = NO;
        p.selectedTextForegroundSingleColor = NO; p.disableAdvancedScrolling = NO;
        [doc applyPreferences];
        expect(@"prefs.smooth-font-off", NPPSci(ed, SCI_GETFONTQUALITY) == SC_EFF_QUALITY_DEFAULT,
               @"the font quality stayed on the LCD renderer");
        expect(@"prefs.drag-drop-on", NPPSci(ed, SCI_GETDRAGDROPENABLED) != 0, @"drag and drop stayed off");
        expect(@"prefs.selection-foreground-off", NPPSci(ed, SCI_GETELEMENTISSET, SC_ELEMENT_SELECTION_TEXT) == 0,
               @"the selected-text colour was not taken back off");
        expect(@"prefs.advanced-scrolling-on", ed.scrollView.verticalScrollElasticity != NSScrollElasticityNone
                                               && ed.scrollView.usesPredominantAxisScrolling,
               @"the trackpad heuristics did not come back");
        p.smoothFont = savedSmooth; p.disableSelectedTextDragDrop = savedNoDrag;
        p.selectedTextForegroundSingleColor = savedSelFg; p.disableAdvancedScrolling = savedNoScroll;
        [doc applyPreferences];

        // An untitled tab named from its content, and the fall-back when the preference is off.
        BOOL savedContentName = p.useContentAsTabName;
        NPPSciStr(ed, SCI_SETTEXT, 0, "  My Notes: draft  \nsecond line");
        p.useContentAsTabName = YES;
        [doc updateContentTabName];
        expect(@"tabname.live-first-line", [doc.displayName isEqualToString:@"My Notes draft"], doc.displayName);
        p.useContentAsTabName = NO;
        [doc updateContentTabName];
        expect(@"tabname.live-falls-back-to-new-n", [doc.displayName hasPrefix:@"new "] && !doc.contentDerivedTabName,
               doc.displayName);
        p.useContentAsTabName = savedContentName;

        // "Highlight another view": the notifying buffer drives the other on-screen ones — they get its word, and
        // they lose it again when its selection goes (nothing else would ever tell them).
        BOOL savedAnotherView = p.smartHighlightAnotherView, savedSmartOn = p.smartHighlighting;
        p.smartHighlighting = YES;
        p.smartHighlightAnotherView = YES;
        NPPDocument *otherDoc = [[NPPDocument alloc] initUntitled];
        otherDoc.editor.frame = NSMakeRect(0, 0, 400, 300);
        [NPPScratchHost() addSubview:otherDoc.editor];
        NPPSciStr(ed, SCI_SETTEXT, 0, "alpha beta");
        NPPSciStr(otherDoc.editor, SCI_SETTEXT, 0, "beta alpha");
        NPPSci(ed, SCI_SETSEL, 6, 10);              // "beta" in this buffer
        [doc smartHighlight];
        const uptr_t smartBit = 1 << NPPIndicatorSmartHighlight;
        expect(@"smarthilite.another-view-is-painted",
               (NPPSci(otherDoc.editor, SCI_INDICATORALLONFOR, 0) & smartBit) != 0,
               @"the selected word was not painted into the other on-screen buffer");
        NPPSci(ed, SCI_SETEMPTYSELECTION, 0);
        [doc smartHighlight];
        expect(@"smarthilite.another-view-is-cleared",
               (NPPSci(otherDoc.editor, SCI_INDICATORALLONFOR, 0) & smartBit) == 0,
               @"the other buffer kept the highlight after the selection that produced it was dropped");
        [otherDoc.editor removeFromSuperview];
        p.smartHighlightAnotherView = savedAnotherView;
        p.smartHighlighting = savedSmartOn;

        // Two untitled buffers must not both take the same name from their first line (upstream refuses the rename
        // and the buffer keeps the one it had); otherDoc is still a live buffer even with its editor unhosted.
        BOOL savedDupName = p.useContentAsTabName;
        p.useContentAsTabName = YES;
        NPPSciStr(ed, SCI_SETTEXT, 0, "Shared Title");
        NPPSciStr(otherDoc.editor, SCI_SETTEXT, 0, "Shared Title");
        [doc updateContentTabName];
        [otherDoc updateContentTabName];
        expect(@"tabname.duplicate-is-refused",
               [doc.displayName isEqualToString:@"Shared Title"] && !otherDoc.contentDerivedTabName,
               [NSString stringWithFormat:@"%@ / %@", doc.displayName, otherDoc.displayName]);
        p.useContentAsTabName = savedDupName;
        [doc updateContentTabName];
        [otherDoc updateContentTabName];

        // "Use Find dialog settings" has to replace the smart-highlight switches, not sit next to them.
        id savedFindWholeWord = [d objectForKey:kKeyFindWholeWord];
        BOOL savedSmartWholeWord = p.smartHighlightWholeWord, savedUseFind = p.smartHighlightUseFindSettings;
        [d setBool:YES forKey:kKeyFindWholeWord];
        p.smartHighlightWholeWord = NO;
        std::string word("b");
        p.smartHighlightUseFindSettings = NO;
        [doc fillSmartHighlightWord:word inEditor:ed];
        BOOL ownFlag = (NPPSci(ed, SCI_GETSEARCHFLAGS) & SCFIND_WHOLEWORD) != 0;
        p.smartHighlightUseFindSettings = YES;
        [doc fillSmartHighlightWord:word inEditor:ed];
        BOOL findFlag = (NPPSci(ed, SCI_GETSEARCHFLAGS) & SCFIND_WHOLEWORD) != 0;
        expect(@"smarthilite.use-find-dialog-settings", !ownFlag && findFlag,
               @"the Find dialog's whole-word switch did not take over the smart highlight");
        p.smartHighlightWholeWord = savedSmartWholeWord;
        p.smartHighlightUseFindSettings = savedUseFind;
        savedFindWholeWord ? [d setObject:savedFindWholeWord forKey:kKeyFindWholeWord] : [d removeObjectForKey:kKeyFindWholeWord];

        // Line-number margin: dynamic counts the last *visible* line (min 3 digits), constant the whole document
        // (min 4). Driven on a 12 000-line document on purpose: a handful of lines cannot tell the two apart,
        // because both MAX() floors swallow the digit count and either branch computed the other way still passes.
        // Here the viewport is ~20 lines (3 digits) while the document needs 5, so each assertion below fails if
        // its branch starts measuring the wrong thing.
        BOOL savedDynamic = p.lineNumberDynamicWidth, savedShowNumbers = p.showLineNumbers;
        p.showLineNumbers = YES;
        std::string manyLines;
        manyLines.reserve(24000);
        for (int i = 0; i < 12000; i++) manyLines += "x\n";
        NPPSciStr(ed, SCI_SETTEXT, 0, manyLines.c_str());
        NPPSci(ed, SCI_SETFIRSTVISIBLELINE, 0);
        p.lineNumberDynamicWidth = YES;
        [doc updateLineNumberMarginWidthForced:YES];
        sptr_t dynamicWidth = NPPSci(ed, SCI_GETMARGINWIDTHN, NPPMarginLineNumber);
        // Scrolling into five-digit territory is the whole point of "dynamic": the margin has to grow.
        NPPSci(ed, SCI_SETFIRSTVISIBLELINE, (uptr_t)NPPSci(ed, SCI_GETLINECOUNT));
        sptr_t scrolledTo = NPPSci(ed, SCI_GETFIRSTVISIBLELINE);
        [doc updateLineNumberMarginWidthForced:NO];
        sptr_t dynamicAtEnd = NPPSci(ed, SCI_GETMARGINWIDTHN, NPPMarginLineNumber);
        p.lineNumberDynamicWidth = NO;
        [doc updateLineNumberMarginWidthForced:YES];
        sptr_t constantWidth = NPPSci(ed, SCI_GETMARGINWIDTHN, NPPMarginLineNumber);
        expect(@"linenumber.dynamic-is-narrower-than-constant", dynamicWidth > 0 && constantWidth > dynamicWidth,
               [NSString stringWithFormat:@"at the top of a 12 000-line file the dynamic margin was %ld px and the "
                @"constant one %ld px: dynamic is not measuring the visible lines", (long)dynamicWidth, (long)constantWidth]);
        // The growth assertion is only worth anything if the editor really scrolled; say so rather than pass quietly.
        expect(@"linenumber.dynamic-grows-when-scrolled", scrolledTo > 0 && dynamicAtEnd == constantWidth,
               scrolledTo > 0 ? [NSString stringWithFormat:@"scrolled to the last line the dynamic margin was %ld px, "
                                 @"want the five-digit %ld px", (long)dynamicAtEnd, (long)constantWidth]
                              : @"the self-check editor would not scroll, so nothing was proved about the growing margin");
        p.lineNumberDynamicWidth = savedDynamic;
        p.showLineNumbers = savedShowNumbers;
        NPPSciStr(ed, SCI_SETTEXT, 0, "");

        [ed removeFromSuperview];
    }


    // ---- The charset an HTML / XML file declares in its own header (N++ getHtmlXmlEncoding) ----
    {
        void (^declared)(NSString *, const char *, BOOL, CFStringEncoding) =
            ^(NSString *what, const char *header, BOOL xml, CFStringEncoding want) {
            CFStringEncoding got = NPPDeclaredCharset((const uint8_t *)header, strlen(header), xml);
            if (got != want)
                [fails addObject:[NSString stringWithFormat:@"charset.%@: got 0x%08X, want 0x%08X",
                                  what, (unsigned)got, (unsigned)want]];
        };
        declared(@"xml-header", "<?xml version=\"1.0\" encoding=\"windows-1254\"?><a/>", YES, kCFStringEncodingWindowsLatin5);
        declared(@"xml-single-quotes", "<?xml version='1.0' encoding='UTF-8' ?>", YES, kCFStringEncodingUTF8);
        declared(@"xml-without-encoding", "<?xml version=\"1.0\"?><a/>", YES, kCFStringEncodingInvalidId);
        declared(@"html5-meta-charset", "<html><head><meta charset=\"windows-1253\">", NO, kCFStringEncodingWindowsGreek);
        declared(@"html-http-equiv-first",
                 "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1254\" />", NO, kCFStringEncodingWindowsLatin5);
        declared(@"html-content-first",
                 "<meta content='text/html; charset=windows-1254' http-equiv='Content-Type'>", NO, kCFStringEncodingWindowsLatin5);
        declared(@"html-without-charset", "<html><head><title>x</title></head>", NO, kCFStringEncodingInvalidId);
        declared(@"unknown-charset-name", "<?xml version=\"1.0\" encoding=\"not-a-charset\"?>", YES, kCFStringEncodingInvalidId);
        // UTF-16 cannot be honoured without a BOM, and upstream's EncodingMapper has no entry for it either.
        declared(@"utf-16-is-refused", "<?xml version=\"1.0\" encoding=\"UTF-16\"?>", YES, kCFStringEncodingInvalidId);
        // The two forms are not interchangeable: which one is looked for comes from the file's extension.
        declared(@"xml-header-is-not-an-html-one", "<?xml version=\"1.0\" encoding=\"windows-1254\"?>", NO, kCFStringEncodingInvalidId);
        std::string late(kNPPHeaderScanBytes, ' ');
        late += "<?xml version=\"1.0\" encoding=\"windows-1254\"?>";
        expect(@"charset.scan-window-is-one-kilobyte",
               NPPDeclaredCharset((const uint8_t *)late.data(), late.size(), YES) == kCFStringEncodingInvalidId,
               @"a declaration past the first kilobyte was still honoured");
    }

    // ---- ... and where it sits against the BOM and the detectors, on real files ----
    {
        // KOI8-R on purpose: it is never what NPPSystemANSICodepage() answers, so seeing it can only mean the
        // header was read. The body is plain ASCII, i.e. valid UTF-8 — which is exactly the case upstream decides
        // in favour of the declaration (detection only runs when nothing was declared).
        const char *xml = "<?xml version=\"1.0\" encoding=\"koi8-r\"?>\n<a>hello</a>\n";
        NSData *body = [NSData dataWithBytes:xml length:strlen(xml)];
        NSMutableData *withBOM = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
        [withBOM appendData:body];
        const char *html = "<html><head><meta charset=\"koi8-r\"></head><body>hi</body></html>\n";

        NSString *dir = NSTemporaryDirectory();
        NPPDocument *(^openDoc)(NSString *, NSData *) = ^NPPDocument *(NSString *name, NSData *bytes) {
            NSURL *u = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
            [bytes writeToURL:u options:NSDataWritingAtomic error:NULL];
            NPPDocument *d = [[NPPDocument alloc] initWithContentsOfURL:u error:NULL];
            [NSFileManager.defaultManager removeItemAtURL:u error:NULL];
            return d;
        };
        NPPDocument *asXml = openDoc(@"npp-selfcheck-declared.xml", body);
        expect(@"charset.declared-beats-detection",
               asXml.encoding == NPPEncodingANSI && asXml.codepage == kCFStringEncodingKOI8_R,
               [NSString stringWithFormat:@"an .xml file declaring koi8-r opened as %@", asXml.encodingDisplayName]);
        NPPDocument *asHtml = openDoc(@"npp-selfcheck-declared.html", [NSData dataWithBytes:html length:strlen(html)]);
        expect(@"charset.declared-in-html",
               asHtml.encoding == NPPEncodingANSI && asHtml.codepage == kCFStringEncodingKOI8_R,
               [NSString stringWithFormat:@"an .html file declaring koi8-r opened as %@", asHtml.encodingDisplayName]);
        NPPDocument *asText = openDoc(@"npp-selfcheck-declared.txt", body);
        expect(@"charset.only-xml-and-html-declare",
               asText.codepage != kCFStringEncodingKOI8_R,
               @"a .txt file had its <?xml ... encoding?> honoured; upstream only reads XML and HTML headers");
        NPPDocument *bomWins = openDoc(@"npp-selfcheck-declared-bom.xml", withBOM);
        expect(@"charset.bom-beats-the-declaration", bomWins.encoding == NPPEncodingUTF8BOM,
               [NSString stringWithFormat:@"a BOM'd .xml file declaring koi8-r opened as %@", bomWins.encodingDisplayName]);
    }

    // ---- Saving keeps the file it replaces (N++ rewrites it; an atomic write alone leaves a new empty-metadata inode) ----
    {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"npp-selfcheck-save"];
        [fm removeItemAtPath:dir error:NULL];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *file = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"keep.txt"]];
        [@"original" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSDate *born = [NSDate dateWithTimeIntervalSince1970:1000000000];   // 2001: "now" can never look like it
        [fm setAttributes:@{NSFileCreationDate: born, NSFilePosixPermissions: @(0640)} ofItemAtPath:file.path error:NULL];
        const char *kWhereFrom = "com.apple.metadata:kMDItemWhereFroms";
        setxattr(file.path.fileSystemRepresentation, kWhereFrom, "x", 1, 0, 0);

        NPPDocument *doc = [[NPPDocument alloc] initWithContentsOfURL:file error:NULL];
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, "rewritten");
        NSError *saveErr = nil;
        BOOL saved = [doc saveToURL:file error:&saveErr];
        NSDictionary *attrs = [fm attributesOfItemAtPath:file.path error:NULL];
        NSString *onDisk = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL];
        expect(@"save.writes-the-text", saved && [onDisk isEqualToString:@"rewritten"],
               saveErr.localizedDescription ?: [NSString stringWithFormat:@"the file holds \"%@\"", onDisk]);
        expect(@"save.keeps-the-creation-date",
               fabs([attrs[NSFileCreationDate] timeIntervalSinceDate:born]) < 1.0,
               [NSString stringWithFormat:@"the creation date became %@, want %@", attrs[NSFileCreationDate], born]);
        expect(@"save.keeps-extended-attributes",
               getxattr(file.path.fileSystemRepresentation, kWhereFrom, NULL, 0, 0, 0) == 1,
               @"the \"where from\" attribute was wiped by the save, and with it Finder tags and quarantine");
        expect(@"save.keeps-permissions", [attrs[NSFilePosixPermissions] unsignedShortValue] == 0640,
               [NSString stringWithFormat:@"the mode became %04o, want 0640",
                [attrs[NSFilePosixPermissions] unsignedShortValue]]);

        // A symlink is a path to the file, not the file: saving through one must not flatten it.
        NSURL *link = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"link.txt"]];
        [fm createSymbolicLinkAtURL:link withDestinationURL:file error:NULL];
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, "through the link");
        [doc saveToURL:link error:NULL];
        expect(@"save.follows-a-symlink",
               [[fm attributesOfItemAtPath:link.path error:NULL][NSFileType] isEqual:NSFileTypeSymbolicLink] &&
               [[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"through the link"],
               @"saving through a symlink replaced the link with a regular file instead of writing its target");

        // A second name for the same file. N++ rewrites the file, so both names see the save; an atomic exchange
        // would leave the other name holding the old text, which is why a linked file takes the in-place path.
        NSURL *hard = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"hard.txt"]];
        [fm linkItemAtURL:file toURL:hard error:NULL];
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, "both names");
        [doc saveToURL:file error:NULL];
        struct stat hardStat = {};
        stat(hard.path.fileSystemRepresentation, &hardStat);
        expect(@"save.keeps-the-hard-link",
               hardStat.st_nlink == 2 &&
               [[NSString stringWithContentsOfURL:hard encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"both names"],
               @"saving a file with a second hard link detached it; the other name kept the old text");
        [fm removeItemAtURL:hard error:NULL];

        // The exchange is not always available: an unwritable directory refuses it, and so do network volumes and
        // an ACL that forbids deleting the file. The file itself is still writable, so the save has to go through
        // anyway — and until it does, the original has to be the thing still on disk.
        NSString *roDir = [dir stringByAppendingPathComponent:@"locked-dir"];
        [fm createDirectoryAtPath:roDir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *inRoDir = [NSURL fileURLWithPath:[roDir stringByAppendingPathComponent:@"in.txt"]];
        [@"original" writeToURL:inRoDir atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        chmod(roDir.fileSystemRepresentation, 0500);
        NPPSciStr(doc.editor, SCI_SETTEXT, 0, "rewritten in place");
        BOOL savedInRoDir = [doc saveToURL:inRoDir error:NULL];
        chmod(roDir.fileSystemRepresentation, 0700);
        expect(@"save.survives-a-directory-it-cannot-write",
               savedInRoDir &&
               [[NSString stringWithContentsOfURL:inRoDir encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"rewritten in place"],
               @"a writable file in an unwritable directory could not be saved: the atomic exchange has no fallback");

        // ---- A file that is read-only on disk (N++ NppIO fileSave) ----
        NSURL *ro = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"readonly.txt"]];
        [@"locked" writeToURL:ro atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        chmod(ro.path.fileSystemRepresentation, 0444);
        NPPDocument *roDoc = [[NPPDocument alloc] initWithContentsOfURL:ro error:NULL];
        expect(@"readonly.mode-is-noticed", roDoc.isFileReadOnlyOnDisk, @"a 0444 file did not report itself read-only");
        expect(@"readonly.editor-is-locked", NPPSci(roDoc.editor, SCI_GETREADONLY) != 0,
               @"the buffer of a read-only file still took edits");
        NPPSci(roDoc.editor, SCI_SETREADONLY, 0);                       // so the buffer really differs from the disk
        NPPSciStr(roDoc.editor, SCI_SETTEXT, 0, "overwritten");
        NPPReadOnlySavePolicyForSave = NPPReadOnlySaveAlwaysDecline;    // "the user said no"
        NSError *roErr = nil;
        BOOL wrote = [roDoc saveToURL:ro error:&roErr];
        NPPReadOnlySavePolicyForSave = NPPReadOnlySaveAsk;
        expect(@"readonly.declining-writes-nothing",
               !wrote && roErr.code == NSUserCancelledError && roDoc.isDirty &&
               [[NSString stringWithContentsOfURL:ro encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"locked"],
               @"a declined save either wrote the read-only file anyway or left the buffer looking saved");

        expect(@"readonly.mode-can-be-cleared", NPPMakeFileWritable(ro) && !roDoc.isFileReadOnlyOnDisk,
               @"clearing the read-only attribute left a 0444 file unwritable");
        chflags(ro.path.fileSystemRepresentation, UF_IMMUTABLE);        // Finder's "Locked"
        expect(@"readonly.locked-flag-is-noticed", roDoc.isFileReadOnlyOnDisk,
               @"a Finder-locked (uchg) file reported itself writable");
        expect(@"readonly.locked-flag-can-be-cleared", NPPMakeFileWritable(ro) && !roDoc.isFileReadOnlyOnDisk,
               @"the immutable flag survived clearing the read-only attribute");

        // And agreeing to it has to get the file written — the whole point of offering.
        chmod(ro.path.fileSystemRepresentation, 0444);
        NPPSciStr(roDoc.editor, SCI_SETTEXT, 0, "allowed");
        NPPReadOnlySavePolicyForSave = NPPReadOnlySaveAlwaysAccept;
        BOOL allowed = [roDoc saveToURL:ro error:NULL];
        NPPReadOnlySavePolicyForSave = NPPReadOnlySaveAsk;
        expect(@"readonly.accepting-clears-it-and-saves",
               allowed && [[NSString stringWithContentsOfURL:ro encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"allowed"],
               @"agreeing to remove the read-only attribute still did not get the file written");

        // The attribute changing under an open buffer has to reach Scintilla (N++ Buffer::checkFileState).
        [roDoc recheckFileReadOnlyState];
        chmod(ro.path.fileSystemRepresentation, 0444);
        [roDoc recheckFileReadOnlyState];
        expect(@"readonly.recheck-locks-the-editor", NPPSci(roDoc.editor, SCI_GETREADONLY) != 0,
               @"a file made read-only while it was open left the buffer editable");
        chmod(ro.path.fileSystemRepresentation, 0644);
        [roDoc recheckFileReadOnlyState];
        expect(@"readonly.recheck-unlocks-the-editor", NPPSci(roDoc.editor, SCI_GETREADONLY) == 0,
               @"a file made writable again while it was open left the buffer locked");
        [fm removeItemAtPath:dir error:NULL];
    }

    // ---- Which document the extra mouse buttons go to (N++ WM_APPCOMMAND / activateNextDoc) ----
    expect(@"mouse.back-is-the-previous-document",
           NPPDocSwitchDeltaForButton(3) == -1 && NPPDocSwitchDeltaForButton(4) == 1
           && NPPDocSwitchDeltaForButton(2) == 0 && NPPDocSwitchDeltaForButton(0) == 0,
           @"back / forward are not mapped to the previous / next document");
    expect(@"mouse.neighbour-wraps-both-ways",
           NPPNeighbourIndex(0, 3, -1) == 2 && NPPNeighbourIndex(2, 3, 1) == 0 &&
           NPPNeighbourIndex(1, 3, 1) == 2 && NPPNeighbourIndex(1, 3, -1) == 0,
           @"the neighbour of the first / last document is not the one at the other end");
    expect(@"mouse.nothing-to-switch-to",
           NPPNeighbourIndex(0, 1, 1) == -1 && NPPNeighbourIndex(-1, 3, 1) == -1 && NPPNeighbourIndex(3, 3, 1) == -1,
           @"a single document, or no current one, still answered with something to switch to");

    // ---- Multi-caret paste and delete, and the per-language indent guides ----
    {
        NPPDocument *doc = [[NPPDocument alloc] initUntitled];
        ScintillaView *ed = doc.editor;
        ed.frame = NSMakeRect(0, 0, 400, 300);
        [NPPScratchHost() addSubview:ed];
        doc.eolMode = NPPEOLUnix;

        void (^threeCarets)(const char *) = ^(const char *text) {
            NPPSciStr(ed, SCI_SETTEXT, 0, text);
            NPPSci(ed, SCI_SETSELECTION, 1, 1);
            NPPSci(ed, SCI_ADDSELECTION, 4, 4);
            NPPSci(ed, SCI_ADDSELECTION, 7, 7);
        };
        // The result is read out before it is judged: the failure message has to describe what actually happened.
        void (^pasted)(NSString *, NSString *, const char *) = ^(NSString *what, NSString *clip, const char *want) {
            BOOL took = [doc distributeMultiCaretPaste:clip];
            std::string got = NPPSciGetText(ed);
            if (took && got == want) return;
            [fails addObject:[NSString stringWithFormat:@"multipaste.%@: %@\"%s\", want \"%s\"", what,
                              took ? @"" : @"the paste was not distributed; buffer ", got.c_str(), want]];
        };
        threeCarets("AB\nAB\nAB");
        pasted(@"one-line-per-caret", @"x\ny\nz", "AxB\nAyB\nAzB");
        // More lines than carets: each caret takes an equal share, joined with the document's line ending.
        NPPSciStr(ed, SCI_SETTEXT, 0, "AB\nAB");
        NPPSci(ed, SCI_SETSELECTION, 1, 1);
        NPPSci(ed, SCI_ADDSELECTION, 4, 4);
        pasted(@"shares-out-the-extra-lines", @"1\n2\n3\n4", "A1\n2B\nA3\n4B");
        // A trailing line ending is a separator, not an empty last line — dropping it unconditionally (as upstream
        // can, because its clipboard always ends with one) would throw the last line away.
        threeCarets("AB\nAB\nAB");
        pasted(@"trailing-eol-is-not-a-line", @"x\ny\nz\n", "AxB\nAyB\nAzB");
        threeCarets("AB\nAB\nAB");
        expect(@"multipaste.single-line-is-left-to-scintilla", ![doc distributeMultiCaretPaste:@"x"],
               @"a one-line clipboard was distributed instead of going to every caret");
        NPPSciStr(ed, SCI_SETTEXT, 0, "AB");
        NPPSci(ed, SCI_SETSELECTION, 1, 1);
        expect(@"multipaste.single-caret-is-left-to-scintilla", ![doc distributeMultiCaretPaste:@"x\ny"],
               @"a plain paste at one caret was taken over");

        // Forward-delete at several carets: Scintilla alone does nothing at the end of a line.
        void (^deleted)(NSString *, const char *, sptr_t, sptr_t, BOOL, const char *) =
            ^(NSString *what, const char *text, sptr_t a, sptr_t b, BOOL wantTaken, const char *want) {
            NPPSciStr(ed, SCI_SETTEXT, 0, text);
            NPPSci(ed, SCI_SETSELECTION, (uptr_t)a, a);
            NPPSci(ed, SCI_ADDSELECTION, (uptr_t)b, b);
            BOOL took = [doc deleteForwardAtMultipleCarets];
            std::string got = NPPSciGetText(ed);
            if (took == wantTaken && got == want) return;
            [fails addObject:[NSString stringWithFormat:@"multidelete.%@: taken=%d, buffer \"%s\", want taken=%d \"%s\"",
                              what, (int)took, got.c_str(), (int)wantTaken, want]];
        };
        deleted(@"joins-lines", "ab\ncd\nef", 2, 5, YES, "abcdef");
        deleted(@"crlf-goes-whole", "ab\r\ncd\r\nef", 2, 6, YES, "abcdef");
        // Carets away from a line end are Scintilla's business; taking those over is how virtual space and
        // rectangular selections would start behaving differently from every other Scintilla build.
        deleted(@"mid-line-is-left-to-scintilla", "ab\ncd", 0, 3, NO, "ab\ncd");

        // Indent guides: SC_IV_LOOKFORWARD for N++'s "Python style indentation" languages, SC_IV_LOOKBOTH elsewhere.
        NPPPreferences *pr = NPPPreferences.shared;
        BOOL savedGuides = pr.showIndentGuides;
        pr.showIndentGuides = YES;
        NPPLanguageManager *lm = NPPLanguageManager.shared;
        // Named explicitly rather than defaulted: a missing language would otherwise make the check pass or fail
        // for a reason that has nothing to do with the guide mode.
        NPPLanguage *python = [lm languageNamed:@"python"], *lua = [lm languageNamed:@"lua"];
        doc.language = python ?: lm.normalTextLanguage;
        expect(@"guides.python-style-looks-forward", python && NPPSci(ed, SCI_GETINDENTATIONGUIDES) == SC_IV_LOOKFORWARD,
               python ? [NSString stringWithFormat:@"python got guide mode %ld", (long)NPPSci(ed, SCI_GETINDENTATIONGUIDES)]
                      : @"the python language is not loaded, so nothing was proved");
        doc.language = lua ?: lm.normalTextLanguage;
        expect(@"guides.other-languages-look-both-ways", lua && NPPSci(ed, SCI_GETINDENTATIONGUIDES) == SC_IV_LOOKBOTH,
               lua ? [NSString stringWithFormat:@"lua got guide mode %ld", (long)NPPSci(ed, SCI_GETINDENTATIONGUIDES)]
                   : @"the lua language is not loaded, so nothing was proved");
        pr.showIndentGuides = NO;
        [doc applyPreferences];
        expect(@"guides.switch-still-turns-them-off", NPPSci(ed, SCI_GETINDENTATIONGUIDES) == SC_IV_NONE,
               @"\"Show indent guide\" no longer turns the guides off");
        pr.showIndentGuides = savedGuides;
        [doc applyPreferences];
        [ed removeFromSuperview];
    }

    return fails;
}

@end
