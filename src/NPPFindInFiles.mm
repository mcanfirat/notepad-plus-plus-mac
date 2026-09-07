// NPPFindInFiles.mm — port of Notepad++'s Find in Files (FindReplaceDlg "Find in Files" tab,
// Notepad_plus::findInFiles / getMatchedFileNames / matchInList) and of the Finder docking panel
// (FindReplaceDlg.cpp Finder::addSearchLine / addFileNameTitle / foundLine, "searchResult" lexer).
//
// The results view is a read-only ScintillaView with the searchResult lexer; that lexer colourises the
// matched words through a pointer to a SearchResultMarkings struct passed as the "@MarkingsStruct"
// property (exactly like N++ does), so we keep one marking entry per displayed line.

#import "NPPFindInFiles.h"
#import "NPPDocument.h"
#import "NPPLanguageManager.h"
#import "NPPPreferences.h"          // Preferences > Searching
#import "NPPUtils.h"

#import <SciLexer.h>
#include <fnmatch.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------------------------------------------
// Defaults keys
// ---------------------------------------------------------------------------------------------------------------
static NSString *const kDefFindHistory    = @"NPPFindInFilesFindHistory";
static NSString *const kDefReplaceHistory = @"NPPFindInFilesReplaceHistory";
static NSString *const kDefDirHistory     = @"NPPFindInFilesDirectoryHistory";
static NSString *const kDefFilters        = @"NPPFindInFilesFilters";
static NSString *const kDefSubFolders     = @"NPPFindInFilesInSubFolders";
static NSString *const kDefHiddenFolders  = @"NPPFindInFilesInHiddenFolders";
static NSString *const kDefMatchCase      = @"NPPFindInFilesMatchCase";
static NSString *const kDefWholeWord      = @"NPPFindInFilesWholeWord";
static NSString *const kDefSearchMode     = @"NPPFindInFilesSearchMode";

// Two Preferences > Searching settings with no NPPPreferences property yet, read under the key a Searching page
// would bind its checkbox to (NPP + the NppGUI field name) and defaulting to N++'s own value.
static NSString *const kDefFillDirFromActiveDoc = @"NPPFillDirFieldFromActiveDoc";  // NppGUI::_fillDirFieldFromActiveDoc, default off
static NSString *const kDefFindDlgAlwaysVisible = @"NPPFindDlgAlwaysVisible";       // NppGUI::_findDlgAlwaysVisible, default off

// The two results-panel toggles at the bottom of the Finder's context menu. N++ keeps them in
// <GUIConfig name="FinderConfig" wrappedLines= purgeBeforeEverySearch=> (Parameters.cpp:6177); both default off.
static NSString *const kDefFinderWrapped = @"NPPFinderLinesAreWrapped";             // NppGUI::_finderLinesAreCurrentlyWrapped
static NSString *const kDefFinderPurge   = @"NPPFinderPurgeBeforeEverySearch";      // NppGUI::_finderPurgeBeforeEverySearch

static BOOL NPPFIFPrefBool(NSString *key, BOOL fallback) {
    NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return n ? n.boolValue : fallback;
}

static const unsigned long long kMaxFileSize = 32ULL * 1024 * 1024;   // N++ has no limit; skip huge files
static const NSInteger kMaxResultLines = 200000;                       // ponytail: N++ grows unbounded; we clear instead
static const NSUInteger kMaxDisplayedLineChars = 1024;                  // the lexer's line buffer is 2048 bytes

@class NPPFIFMatcher;
static NSString *NPPFIFReplaceInText(NSString *text, NPPFIFMatcher *m, NSString *templ, NSInteger *count);
static NSTextField *NPPFIFLabel(NSString *text, NSRect frame);

// Internals of the sibling module. -dialogFillTextInEditor: is the Find family's single "selection becomes the
// Find text when a search dialog opens" path and is used by the Find in Files sheet; the rest are needed only by
// +selfCheckFailures below, because NPPSelfTest probes registered command handlers and the Find panel is not one.
@interface NPPFindPanelController (NPPFindInFilesSelfCheck)
- (NSString *)dialogFillTextInEditor:(ScintillaView *)ed;
- (NSString *)selectionOrWordInEditor:(ScintillaView *)ed;
- (void)autoCheckInSelectionForEditor:(ScintillaView *)ed;
- (void)buildWindow;                    // idempotent; builds the panel without showing it
- (void)applyDialogFont;
- (NSComboBox *)currentFindCombo;
@end

static NSInteger NPPFIFDigits(NSInteger n) { NSInteger d = 1; while (n >= 10) { n /= 10; d++; } return d; }

// The Filters key held one string before that field grew its drop-down (and a hand-edited defaults entry can
// still be one), so a lone string reads as a one-entry history rather than as no history at all.
static NSArray<NSString *> *NPPFIFHistory(NSString *key) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if ([v isKindOfClass:NSArray.class]) return v;
    return [v isKindOfClass:NSString.class] && ((NSString *)v).length ? @[v] : @[];
}

static NSString *NPPFIFHistoryAdd(NSString *key, NSString *value) {
    if (!value.length) return value;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableArray *a = [NPPFIFHistory(key) mutableCopy];
    [a removeObject:value];
    [a insertObject:value atIndex:0];
    while (a.count > 10) [a removeLastObject];
    [ud setObject:a forKey:key];
    return value;
}

// ---------------------------------------------------------------------------------------------------------------
// Filters — N++ matchInList() / matchInExcludeDirList()
// ---------------------------------------------------------------------------------------------------------------
@interface NPPFIFFilters : NSObject
@property (nonatomic, copy) NSArray<NSString *> *include, *excludeFile, *excludeDirLevel1, *excludeDirAny;
+ (instancetype)filtersFromString:(nullable NSString *)s;
- (BOOL)matchesFileName:(NSString *)name;
- (BOOL)excludesDirectoryName:(NSString *)name atLevel:(NSInteger)level;   // level 1 = direct child of the root
@end

// Windows' PathMatchSpec treats "*.*" as "any file"; fnmatch would require a dot.
static BOOL NPPFIFGlob(NSString *pattern, NSString *name) {
    if (!pattern.length || !name.length) return NO;
    if ([pattern isEqualToString:@"*.*"] || [pattern isEqualToString:@"*"]) return YES;
    const char *p = pattern.UTF8String, *n = name.UTF8String;
    return p && n && fnmatch(p, n, FNM_CASEFOLD) == 0;
}

@implementation NPPFIFFilters

+ (instancetype)filtersFromString:(NSString *)s {
    NPPFIFFilters *f = [NPPFIFFilters new];
    NSMutableArray *inc = [NSMutableArray new], *exf = [NSMutableArray new];
    NSMutableArray *ed1 = [NSMutableArray new], *edn = [NSMutableArray new];
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@" \t;,\r\n"];
    for (NSString *p in [(s ?: @"") componentsSeparatedByCharactersInSet:sep]) {
        if (!p.length) continue;
        if (![p hasPrefix:@"!"]) { [inc addObject:p]; continue; }
        NSString *r = [p substringFromIndex:1];
        if ([r hasPrefix:@"+\\"] || [r hasPrefix:@"+/"]) {          // !+\folder — every level
            if (r.length > 2) [edn addObject:[r substringFromIndex:2]];
        } else if ([r hasPrefix:@"\\"] || [r hasPrefix:@"/"]) {     // !\folder — first level only
            if (r.length > 1) [ed1 addObject:[r substringFromIndex:1]];
        } else if (r.length) {
            [exf addObject:r];
        }
    }
    if (inc.count == 0) [inc addObject:@"*.*"];   // N++ allPatternsAreExclusion(): everything minus the exclusions
    f.include = inc; f.excludeFile = exf; f.excludeDirLevel1 = ed1; f.excludeDirAny = edn;
    return f;
}

- (BOOL)matchesFileName:(NSString *)name {
    for (NSString *p in _excludeFile) if (NPPFIFGlob(p, name)) return NO;
    for (NSString *p in _include) if (NPPFIFGlob(p, name)) return YES;
    return NO;
}

- (BOOL)excludesDirectoryName:(NSString *)name atLevel:(NSInteger)level {
    for (NSString *p in _excludeDirAny) if (NPPFIFGlob(p, name)) return YES;
    if (level == 1) for (NSString *p in _excludeDirLevel1) if (NPPFIFGlob(p, name)) return YES;
    return NO;
}
@end

// ---------------------------------------------------------------------------------------------------------------
// Matcher — Normal / Extended / Regular expression, per line
// ---------------------------------------------------------------------------------------------------------------
static BOOL NPPFIFIsWordChar(unichar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c > 127;
}
static BOOL NPPFIFWordBounded(NSString *line, NSRange r) {
    if (r.location > 0 && NPPFIFIsWordChar([line characterAtIndex:r.location - 1])) return NO;
    NSUInteger after = r.location + r.length;
    if (after < line.length && NPPFIFIsWordChar([line characterAtIndex:after])) return NO;
    return YES;
}

// Extended mode: \n \r \t \0 \\ \xHH (N++ FindReplaceDlg::stringReplace / Searching::convertExtendedToString).
static NSString *NPPFIFUnescape(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    NSUInteger i = 0, n = s.length;
    while (i < n) {
        unichar c = [s characterAtIndex:i++];
        if (c != '\\' || i >= n) { [out appendFormat:@"%C", c]; continue; }
        unichar e = [s characterAtIndex:i++];
        switch (e) {
            case 'n': [out appendString:@"\n"]; break;
            case 'r': [out appendString:@"\r"]; break;
            case 't': [out appendString:@"\t"]; break;
            case '0': [out appendFormat:@"%C", (unichar)0]; break;
            case '\\': [out appendString:@"\\"]; break;
            case 'x': case 'X': {
                unsigned v = 0; NSUInteger j = i, digits = 0;
                while (j < n && digits < 2) {
                    unichar h = [s characterAtIndex:j];
                    int d = (h >= '0' && h <= '9') ? h - '0' : (h >= 'a' && h <= 'f') ? h - 'a' + 10
                          : (h >= 'A' && h <= 'F') ? h - 'A' + 10 : -1;
                    if (d < 0) break;
                    v = v * 16 + (unsigned)d; j++; digits++;
                }
                if (digits) { [out appendFormat:@"%C", (unichar)v]; i = j; }
                else [out appendFormat:@"\\%C", e];
                break;
            }
            default: [out appendFormat:@"\\%C", e]; break;
        }
    }
    return out;
}

// N++ accepts both \1 and $1 for regex groups; NSRegularExpression templates only understand $1.
static NSString *NPPFIFRegexTemplate(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\' && i + 1 < s.length) {
            unichar d = [s characterAtIndex:i + 1];
            if (d >= '0' && d <= '9') { [out appendFormat:@"$%C", d]; i++; continue; }
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

@interface NPPFIFMatcher : NSObject
@property (nonatomic, copy) NSString *needle;
@property (nonatomic, strong) NSRegularExpression *regex;
@property (nonatomic) BOOL matchCase, wholeWord;
+ (nullable instancetype)matcherForText:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww
                                   mode:(NPPSearchMode)mode error:(NSString **)error;
// Ranges of every match in `text` (a whole file, not one line: N++ searches the whole buffer, so a pattern may
// span line breaks). When `templ` is non-nil the corresponding replacement strings are appended to `repl`.
- (NSArray<NSValue *> *)rangesIn:(NSString *)text template:(nullable NSString *)templ
                    replacements:(nullable NSMutableArray<NSString *> *)repl;
@end

@implementation NPPFIFMatcher

+ (instancetype)matcherForText:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww
                          mode:(NPPSearchMode)mode error:(NSString **)error {
    if (!text.length) { if (error) *error = @"Find in Files: no search text."; return nil; }
    NPPFIFMatcher *m = [NPPFIFMatcher new];
    m.matchCase = mc; m.wholeWord = ww;
    if (mode == NPPSearchModeRegex) {
        NSString *pattern = ww ? [NSString stringWithFormat:@"\\b(?:%@)\\b", text] : text;
        NSError *err = nil;
        // AnchorsMatchLines: the search runs over the whole file, but ^ and $ must still mean "line start/end"
        // like they do in N++ (Scintilla's Boost regex search).
        NSRegularExpressionOptions opts = NSRegularExpressionAnchorsMatchLines | (mc ? 0 : NSRegularExpressionCaseInsensitive);
        m.regex = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:&err];
        if (!m.regex) {
            if (error) *error = [NSString stringWithFormat:@"Find: Invalid regular expression (%@)",
                                 err.localizedDescription ?: @"?"];
            return nil;
        }
    } else {
        m.needle = (mode == NPPSearchModeExtended) ? NPPFIFUnescape(text) : text;
        if (!m.needle.length) { if (error) *error = @"Find in Files: no search text."; return nil; }
    }
    return m;
}

- (NSArray<NSValue *> *)rangesIn:(NSString *)line template:(NSString *)templ
                    replacements:(NSMutableArray<NSString *> *)repl {
    if (!line.length) return @[];
    NSMutableArray<NSValue *> *out = nil;
    if (_regex) {
        for (NSTextCheckingResult *r in [_regex matchesInString:line options:0 range:NSMakeRange(0, line.length)]) {
            if (r.range.length == 0) continue;   // ponytail: zero-width matches are skipped (they cannot be shown or replaced)
            if (!out) out = [NSMutableArray new];
            [out addObject:[NSValue valueWithRange:r.range]];
            if (templ) [repl addObject:[_regex replacementStringForResult:r inString:line offset:0 template:templ]];
        }
        return out ?: @[];
    }
    NSStringCompareOptions opt = NSLiteralSearch | (_matchCase ? 0 : NSCaseInsensitiveSearch);
    NSUInteger pos = 0;
    while (pos < line.length) {
        NSRange r = [line rangeOfString:_needle options:opt range:NSMakeRange(pos, line.length - pos)];
        if (r.location == NSNotFound) break;
        pos = r.location + MAX((NSUInteger)1, r.length);
        if (_wholeWord && !NPPFIFWordBounded(line, r)) continue;
        if (!out) out = [NSMutableArray new];
        [out addObject:[NSValue valueWithRange:r]];
        if (templ) [repl addObject:templ];
    }
    return out ?: @[];
}
@end

// ---------------------------------------------------------------------------------------------------------------
// Results model
// ---------------------------------------------------------------------------------------------------------------
@interface NPPFIFHit : NSObject
@property (nonatomic) NSInteger line;                  // 1-based
@property (nonatomic, copy) NSString *lineText;        // EOL stripped, truncated for display
@property (nonatomic) NSInteger startByte, endByte;    // UTF-8 offsets of the match inside lineText (-1 = not displayed)
@end
@implementation NPPFIFHit
@end

@interface NPPFIFFileHits : NSObject
@property (nonatomic, copy) NSURL *url;
@property (nonatomic, weak) NPPDocument *doc;          // set when the "file" is an open buffer
@property (nonatomic, copy) NSString *displayPath;
@property (nonatomic) NSInteger totalLines;
@property (nonatomic, strong) NSMutableArray<NPPFIFHit *> *hits;
@end
@implementation NPPFIFFileHits
@end

// One entry per line of the results view.
@interface NPPFIFLineInfo : NSObject
@property (nonatomic, copy, nullable) NSURL *url;
@property (nonatomic, weak) NPPDocument *doc;
@property (nonatomic) NSInteger line;                  // 0 = file header row (no line to go to)
@property (nonatomic) NSInteger startByte, endByte;
@end
@implementation NPPFIFLineInfo
@end

// ---------------------------------------------------------------------------------------------------------------
// File reading
// ---------------------------------------------------------------------------------------------------------------
// Key under which a walked file and an open document are "the same file" (/tmp and /private/tmp are one directory).
static NSString *NPPFIFPathKey(NSURL *url) {
    return url.isFileURL ? url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path : nil;
}

// Returns nil for binary/unreadable files. ponytail: only UTF-8 with a Latin-1 fallback, like the task asks;
// UTF-16 files contain NUL bytes and are therefore treated as binary (N++ would decode them).
static NSString *NPPFIFReadTextFile(NSURL *url, NSStringEncoding *usedEncoding) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL];
    if (!data) return nil;
    if (data.length == 0) { if (usedEncoding) *usedEncoding = NSUTF8StringEncoding; return @""; }
    const unsigned char *b = (const unsigned char *)data.bytes;
    NSUInteger probe = MIN((NSUInteger)4096, data.length);
    for (NSUInteger i = 0; i < probe; i++) if (b[i] == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) { if (usedEncoding) *usedEncoding = NSUTF8StringEncoding; return s; }
    s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (s && usedEncoding) *usedEncoding = NSISOLatin1StringEncoding;
    return s;
}

// ---------------------------------------------------------------------------------------------------------------

@interface NPPFindInFiles () <NSMenuDelegate>
@property (readwrite, getter=isSearching) BOOL searching;   // atomic: written from the search queue
@property (atomic) NSInteger cancelToken;
@property (atomic) NSInteger runToken;                      // token of the most recently *started* run
@end

@implementation NPPFindInFiles {
    // Panel
    NSView *_panelView;
    NSTextField *_headerLabel;
    ScintillaView *_results;
    NSMutableArray<id> *_lineInfos;                          // NSNull or NPPFIFLineInfo, one per results line
    std::vector<SearchResultMarkingLine> _markings;          // parallel to _lineInfos; consumed by the searchResult lexer
    SearchResultMarkings _markingsStruct;
    id _eventMonitor;
    NSMutableIndexSet *_headerLines;                         // "Search ..." rows still waiting for their summary
    NSTimeInterval _lastProgressUpdate;

    dispatch_queue_t _queue;

    // Find in Files sheet
    NSWindow *_sheet;
    NSComboBox *_findCombo, *_replaceCombo, *_filtersCombo, *_dirCombo;
    NSButton *_subFoldersBox, *_hiddenBox, *_wholeWordBox, *_matchCaseBox;
    NSButton *_modeNormal, *_modeExtended, *_modeRegex;

    // "Find in these search results…" — N++ keeps FindInFinderDlg's options in a member too, so they last for
    // the session and are not written to the config file.
    BOOL _finderOnlyFoundLines, _finderMatchCase, _finderWholeWord;
    NPPSearchMode _finderMode;
}

+ (instancetype)shared {
    static NPPFindInFiles *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NPPFindInFiles new]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lineInfos = [NSMutableArray new];
    _headerLines = [NSMutableIndexSet new];
    _finderOnlyFoundLines = YES;                            // FindInFinderDlg: _options._isMatchLineNumber = true
    _finderMode = NPPSearchModeNormal;
    _markingsStruct._length = 0;
    _markingsStruct._markings = nullptr;
    _queue = dispatch_queue_create("org.notepad-plus-plus.mac.findinfiles", DISPATCH_QUEUE_SERIAL);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeDidChange:)
                                               name:NPPThemeDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
}

#pragma mark - NPPPanel

- (NSString *)panelTitle { return @"Search results"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeBottom; }
- (CGFloat)panelPreferredSize { return 200; }
- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc { /* results are global, like N++'s Finder */ }

- (NSView *)panelView {
    if (_panelView) return _panelView;
    NSRect frame = NSMakeRect(0, 0, 640, 200);
    NSView *v = [[NSView alloc] initWithFrame:frame];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _headerLabel = [NSTextField labelWithString:@"No search yet."];
    _headerLabel.font = [NSFont systemFontOfSize:11];
    _headerLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _headerLabel.frame = NSMakeRect(6, NSHeight(frame) - 17, NSWidth(frame) - 12, 14);
    _headerLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [v addSubview:_headerLabel];

    _results = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame) - 20)];
    _results.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [v addSubview:_results];
    _panelView = v;
    [self setupResultsEditor];
    return v;
}

- (void)panelDidBecomeVisible {
    if (_eventMonitor || !_results) return;
    __weak NPPFindInFiles *weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskLeftMouseUp)
                                                          handler:^NSEvent *(NSEvent *e) {
        return [weakSelf handleMonitoredEvent:e] ? nil : e;
    }];
}

- (void)panelWillHide {
    if (_eventMonitor) { [NSEvent removeMonitor:_eventMonitor]; _eventMonitor = nil; }
}

// N++ builds this menu on the Finder's WM_CONTEXTMENU (FindReplaceDlg.cpp:6248); the port shows the same one
// behind the panel's ⚙ button, so both routes offer the same commands. Two upstream items are missing on
// purpose: "Close these search results" (the port has one panel, not N++'s per-search volatile Finders —
// ponytail: upgrade path is a tabbed results panel, one Finder per tab) and the Ctrl+C / Ctrl+A hints on Copy
// and Select All (a context-menu key equivalent is not in the main menu's key loop, so it would be a shortcut
// that is drawn but never fires).
- (NSMenu *)buildResultsMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Search results"];
    m.delegate = self;                                       // checkmarks + the right-click caret (menuNeedsUpdate:)
    void (^add)(NSString *, SEL) = ^(NSString *title, SEL action) {
        [[m addItemWithTitle:title action:action keyEquivalent:@""] setTarget:self];
    };
    add(@"Find in these search results…", @selector(menuFindInResults:));
    add(@"Stop", @selector(menuStop:));
    [m addItem:NSMenuItem.separatorItem];
    add(@"Collapse all", @selector(menuCollapseAll:));
    add(@"Expand all", @selector(menuExpandAll:));
    [m addItem:NSMenuItem.separatorItem];
    add(@"Copy", @selector(menuCopy:));
    add(@"Copy Selected Line(s)", @selector(menuCopySelectedLines:));
    add(@"Copy Selected Pathname(s)", @selector(menuCopyPaths:));
    add(@"Select All", @selector(menuSelectAll:));
    add(@"Clear all", @selector(menuClearAll:));
    [m addItem:NSMenuItem.separatorItem];
    add(@"Open Selected Pathname(s)", @selector(menuOpenPaths:));
    [m addItem:NSMenuItem.separatorItem];
    add(@"Word wrap long lines", @selector(menuToggleWrap:));
    add(@"Purge for every search", @selector(menuTogglePurge:));
    return m;
}

- (NSMenu *)panelActionMenu { return [self buildResultsMenu]; }

- (void)menuStop:(id)s { [self stopSearch]; }
- (void)menuCollapseAll:(id)s { [self foldAllResults:YES]; }
- (void)menuExpandAll:(id)s { [self foldAllResults:NO]; }
- (void)menuCopy:(id)s { [self copyResults]; }
- (void)menuCopySelectedLines:(id)s { [self copySelectedResultLines]; }
- (void)menuCopyPaths:(id)s { [self copySelectedPaths]; }
- (void)menuSelectAll:(id)s { if (_results) NPPSci(_results, SCI_SELECTALL); }
- (void)menuClearAll:(id)s { [self clearAllResults]; }
- (void)menuOpenPaths:(id)s { [self openSelectedPaths]; }
- (void)menuToggleWrap:(id)s { [self setLongLinesWrapped:![NPPFindInFiles longLinesAreWrapped]]; }
- (void)menuTogglePurge:(id)s {
    [NSUserDefaults.standardUserDefaults setBool:![NPPFindInFiles purgeBeforeEverySearch] forKey:kDefFinderPurge];
}
- (void)menuFindInResults:(id)s { [self showFindInResultsSheet]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    if (a == @selector(menuStop:)) return self.isSearching;
    // The two toggles are settings, not actions on the content: they stay usable with an empty panel.
    if (a == @selector(menuToggleWrap:) || a == @selector(menuTogglePurge:)) return YES;
    if (!self.hasResults) return NO;
    BOOL (^hasFile)(NPPFIFLineInfo *) = ^BOOL(NPPFIFLineInfo *i) { return i.url != nil; };
    if (a == @selector(menuCopyPaths:) || a == @selector(menuOpenPaths:))
        return [self anyRowIn:[self selectedResultLineRange] where:hasFile];
    if (a == @selector(menuCopySelectedLines:))
        return [self anyRowIn:[self selectedResultLineRange] where:^BOOL(NPPFIFLineInfo *i) { return i.line > 0; }];
    // A results panel holding nothing but unsaved untitled buffers names no file to search again.
    if (a == @selector(menuFindInResults:)) return [self anyRowIn:NSMakeRange(0, _lineInfos.count) where:hasFile];
    return YES;
}

// Validation only: is there a row of this kind in the range? Stops at the first one, so opening the menu over a
// Select All'd panel does not walk 200k rows.
- (BOOL)anyRowIn:(NSRange)r where:(BOOL (^)(NPPFIFLineInfo *))test {
    for (NSUInteger l = r.location; l < NSMaxRange(r); l++) {
        NPPFIFLineInfo *info = [self infoAtLine:(NSInteger)l];
        if (info && test(info)) return YES;
    }
    return NO;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self moveResultsCaretToRightClick];
    for (NSMenuItem *it in menu.itemArray) {
        if (it.action == @selector(menuToggleWrap:))
            it.state = [NPPFindInFiles longLinesAreWrapped] ? NSControlStateValueOn : NSControlStateValueOff;
        else if (it.action == @selector(menuTogglePurge:))
            it.state = [NPPFindInFiles purgeBeforeEverySearch] ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

// Scintilla Cocoa pops the context menu up *before* the backend moves the caret (ScintillaView.mm
// rightMouseDown: calls popUpContextMenu: first, then RightMouseDown), so every "Selected …" item here would act
// on wherever the caret happened to be rather than on the row under the pointer. Move it first.
// ponytail: a right-click while text is selected leaves the selection alone; N++ (Editor::RightButtonDownWithModifiers)
// only keeps it when the click lands inside it.
- (void)moveResultsCaretToRightClick {
    NSEvent *e = NSApp.currentEvent;
    BOOL isContextClick = e.type == NSEventTypeRightMouseDown ||
                          (e.type == NSEventTypeLeftMouseDown && (e.modifierFlags & NSEventModifierFlagControl));
    if (!_results || !isContextClick || e.window != _results.window) return;
    if (!NPPSci(_results, SCI_GETSELECTIONEMPTY)) return;
    sptr_t pos = [self resultsPositionAtWindowPoint:e.locationInWindow];
    if (pos >= 0) NPPSci(_results, SCI_GOTOPOS, (uptr_t)pos);
}

// ScintillaCocoa::ConvertPoint: coordinates of the (flipped) content view, minus the scroll offset.
- (sptr_t)resultsPositionAtWindowPoint:(NSPoint)windowPoint {
    NSView *content = (NSView *)_results.content;
    if (!content) return -1;
    NSPoint p = [content convertPoint:windowPoint fromView:nil];
    NSRect visible = _results.scrollView.contentView.bounds;
    return NPPSci(_results, SCI_POSITIONFROMPOINT, (uptr_t)(sptr_t)(p.x - NSMinX(visible)),
                  (sptr_t)(p.y - NSMinY(visible)));
}

#pragma mark - Results editor

- (void)setupResultsEditor {
    ScintillaView *ed = _results;
    NPPSci(ed, SCI_SETCODEPAGE, SC_CP_UTF8);
    NPPSci(ed, SCI_SETUNDOCOLLECTION, 0);
    NPPSci(ed, SCI_SETTABWIDTH, 4);
    NPPSci(ed, SCI_SETSCROLLWIDTHTRACKING, 1);
    NPPSci(ed, SCI_SETSCROLLWIDTH, 600);
    // Scintilla Cocoa sizes its content view to the scroll width, so a narrow result list would leave the scroll
    // view's own background showing to the right of the text. Keep the scroll width at least as wide as the panel.
    NSClipView *clip = ed.scrollView.contentView;
    clip.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification object:clip queue:nil
                                               usingBlock:^(NSNotification *note) {
        CGFloat w = NSWidth(((NSClipView *)note.object).bounds);
        if (w > 0) NPPSci(ed, SCI_SETSCROLLWIDTH, (uptr_t)w);
    }];
    // N++ turns Scintilla's own popup off and puts the Finder's menu there instead (FindReplaceDlg.cpp:3861).
    // SCIContentView asks its owner first (ScintillaView.mm:433 -> NSView's menuForEvent: -> the view's menu).
    NPPSci(ed, SCI_USEPOPUP, SC_POPUP_NEVER);
    ed.menu = [self buildResultsMenu];
    NPPSci(ed, SCI_SETWRAPINDENTMODE, SC_WRAPINDENT_INDENT);   // N++ LINEWRAP_INDENT + showWrapSymbol(true)
    NPPSci(ed, SCI_SETWRAPVISUALFLAGS, SC_WRAPVISUALFLAG_END);
    [self setLongLinesWrapped:[NPPFindInFiles longLinesAreWrapped]];
    NPPSci(ed, SCI_SETCARETLINEVISIBLE, 1);
    NPPSci(ed, SCI_SETCARETLINEVISIBLEALWAYS, 1);

    // Margins: no line numbers, no symbols, just the fold margin (N++ FOLDER_STYLE_SIMPLE).
    NPPSci(ed, SCI_SETMARGINS, 3);
    NPPSci(ed, SCI_SETMARGINWIDTHN, 0, 0);
    NPPSci(ed, SCI_SETMARGINWIDTHN, 1, 0);
    NPPSci(ed, SCI_SETMARGINTYPEN, 2, SC_MARGIN_SYMBOL);
    NPPSci(ed, SCI_SETMARGINMASKN, 2, (sptr_t)SC_MASK_FOLDERS);
    NPPSci(ed, SCI_SETMARGINSENSITIVEN, 2, 1);
    NPPSci(ed, SCI_SETMARGINWIDTHN, 2, 14);
    NPPSci(ed, SCI_SETAUTOMATICFOLD, SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDER, SC_MARK_PLUS);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPEN, SC_MARK_MINUS);
    for (int m : {SC_MARKNUM_FOLDERSUB, SC_MARKNUM_FOLDERTAIL, SC_MARKNUM_FOLDERMIDTAIL})
        NPPSci(ed, SCI_MARKERDEFINE, (uptr_t)m, SC_MARK_EMPTY);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEREND, SC_MARK_PLUS);
    NPPSci(ed, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPENMID, SC_MARK_MINUS);

    [self applyResultsStyles];
    NPPSci(ed, SCI_SETREADONLY, 1);
}

// The lexer instance is recreated by applyLanguage:, and SCI_SETPROPERTY lives on the lexer, so both the
// searchResult styles and the @MarkingsStruct pointer have to be (re)installed together.
- (void)applyResultsStyles {
    if (!_results) return;
    NPPLanguageManager *lm = NPPLanguageManager.shared;
    NPPLanguage *lang = [lm languageNamed:@"searchResult"];
    if (lang) [lm applyLanguage:lang toEditor:_results];
    else [lm applyGlobalStylesToEditor:_results];

    NPPSciStr(_results, SCI_SETPROPERTY, (uptr_t)"fold", "1");
    char ptr[sizeof(void *) * 2 + 3];
    snprintf(ptr, sizeof(ptr), "%p", (void *)&_markingsStruct);
    NPPSciStr(_results, SCI_SETPROPERTY, (uptr_t)"@MarkingsStruct", ptr);
    NPPSci(_results, SCI_COLOURISE, 0, -1);

    NSColor *bg = [lm globalBackgroundColorNamed:@"Default Style"];
    NSColor *fg = [lm globalForegroundColorNamed:@"Default Style"];
    _panelView.wantsLayer = YES;
    _panelView.layer.backgroundColor = (bg ?: NSColor.controlBackgroundColor).CGColor;
    _headerLabel.textColor = fg ?: NSColor.labelColor;
}

- (void)themeDidChange:(NSNotification *)n {
    if (_results) [self applyResultsStyles];
}

- (void)syncMarkings {
    _markingsStruct._length = (intptr_t)_markings.size();
    _markingsStruct._markings = _markings.empty() ? nullptr : _markings.data();
}

- (void)appendLine:(NSString *)line info:(id)info segment:(std::pair<intptr_t, intptr_t>)seg hasSegment:(BOOL)hasSeg {
    NSString *withEOL = [line stringByAppendingString:@"\n"];
    const char *utf8 = withEOL.UTF8String;
    if (!utf8) return;
    // strlen() would stop at an embedded NUL (matched text can contain one) and drop the trailing newline,
    // desyncing _lineInfos/_markings from the Scintilla lines.
    NSUInteger utf8Len = [withEOL lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NPPSci(_results, SCI_SETREADONLY, 0);
    NPPSciStr(_results, SCI_APPENDTEXT, (uptr_t)utf8Len, utf8);
    NPPSci(_results, SCI_SETREADONLY, 1);

    SearchResultMarkingLine ml;
    if (hasSeg) ml._segmentPostions.push_back(seg);
    _markings.push_back(std::move(ml));
    [_lineInfos addObject:info ?: (id)NSNull.null];
    [self syncMarkings];
}

- (void)replaceLine:(NSInteger)lineNo withText:(NSString *)text {
    if (lineNo < 0 || lineNo >= (NSInteger)NPPSci(_results, SCI_GETLINECOUNT)) return;
    const char *utf8 = text.UTF8String;
    if (!utf8) return;
    sptr_t start = NPPSci(_results, SCI_POSITIONFROMLINE, (uptr_t)lineNo);
    sptr_t end = NPPSci(_results, SCI_GETLINEENDPOSITION, (uptr_t)lineNo);
    NPPSci(_results, SCI_SETREADONLY, 0);
    NPPSci(_results, SCI_SETTARGETRANGE, (uptr_t)start, end);
    NPPSciStr(_results, SCI_REPLACETARGET,
              (uptr_t)[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding], utf8);
    NPPSci(_results, SCI_SETREADONLY, 1);
}

- (BOOL)hasResults { return _lineInfos.count > 0; }

- (void)clearAllResults {
    if (!_results) { [_lineInfos removeAllObjects]; _markings.clear(); [self syncMarkings]; return; }
    NPPSci(_results, SCI_SETREADONLY, 0);
    NPPSci(_results, SCI_CLEARALL);
    NPPSci(_results, SCI_SETREADONLY, 1);
    [_lineInfos removeAllObjects];
    _markings.clear();
    [self syncMarkings];
    [_headerLines removeAllIndexes];
    _headerLabel.stringValue = @"No search yet.";
}

// ponytail: N++ lets the Finder grow without limit; we drop everything once the panel passes 200k lines.
- (BOOL)makeRoomFor:(NSInteger)lines {
    if ((NSInteger)_lineInfos.count + lines <= kMaxResultLines) return YES;
    [self clearAllResults];
    return lines <= kMaxResultLines;
}

#pragma mark - Section building (Finder::addSearchLine / addFileNameTitle / foundLine)

// Returns the section's header line; the caller carries it until it can call finishSectionWithHits:…headerLine:
// (a background Find in Files run must not write its summary into a section started meanwhile).
- (NSInteger)beginSectionForText:(NSString *)what {
    (void)[self panelView];   // make sure the editor exists even if the panel was never docked
    // "Purge for every search": the panel keeps only the newest search (FindReplaceDlg.cpp:3901, removeAll()).
    if ([NPPFindInFiles purgeBeforeEverySearch]) [self clearAllResults];
    [self makeRoomFor:1];
    NSString *oneLine = [[what componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                         componentsJoinedByString:@""];
    NSInteger headerLine = (NSInteger)_lineInfos.count;
    [_headerLines addIndex:(NSUInteger)headerLine];
    std::pair<intptr_t, intptr_t> none{};
    [self appendLine:[NSString stringWithFormat:@"Search \"%@\" ", oneLine] info:nil segment:none hasSegment:NO];
    [self scrollResultsToEnd];
    return headerLine;
}

- (void)appendFileHits:(NPPFIFFileHits *)fh {
    if (!fh.hits.count) return;
    if (![self makeRoomFor:(NSInteger)fh.hits.count + 1]) return;

    NSString *hitsStr = fh.hits.count == 1 ? @"(1 hit)" : [NSString stringWithFormat:@"(%lu hits)",
                                                           (unsigned long)fh.hits.count];
    NPPFIFLineInfo *fileInfo = [NPPFIFLineInfo new];
    fileInfo.url = fh.url; fileInfo.doc = fh.doc; fileInfo.line = 0;
    std::pair<intptr_t, intptr_t> none{};
    [self appendLine:[NSString stringWithFormat:@"  %@ %@", fh.displayPath, hitsStr] info:fileInfo
             segment:none hasSegment:NO];

    // Preferences > Searching "Search Result window: show only one entry per found line" (Finder::foundLine).
    // Hits share a displayed line only when they sit on the same source line, so they share its "Line NN: "
    // prefix too and every extra match just becomes one more colourised segment on the line already appended.
    BOOL oneEntryPerLine = NPPPreferences.shared.finderShowOnlyOneEntryPerFoundLine;
    NSInteger previousLine = -1;

    NSInteger totalDigits = NPPFIFDigits(MAX((NSInteger)1, fh.totalLines));
    for (NPPFIFHit *hit in fh.hits) {
        NSInteger pad = MAX((NSInteger)0, totalDigits - NPPFIFDigits(hit.line));
        NSString *prefix = [NSString stringWithFormat:@"\tLine %@%ld: ",
                            [@"" stringByPaddingToLength:(NSUInteger)pad withString:@" " startingAtIndex:0],
                            (long)hit.line];
        NSInteger prefixBytes = (NSInteger)strlen(prefix.UTF8String ?: "");
        BOOL hasSeg = hit.startByte >= 0 && hit.endByte > hit.startByte;
        std::pair<intptr_t, intptr_t> seg{prefixBytes + hit.startByte, prefixBytes + hit.endByte};
        if (oneEntryPerLine && hit.line == previousLine) {
            // ponytail: a repeated hit whose match was cut off the displayed line adds no segment and no text,
            // so it is dropped; N++ gives it a duplicate entry instead. Ceiling: the truncated-line case only.
            if (hasSeg && !_markings.empty()) { _markings.back()._segmentPostions.push_back(seg); [self syncMarkings]; }
            continue;
        }
        previousLine = hit.line;
        NPPFIFLineInfo *info = [NPPFIFLineInfo new];
        info.url = fh.url; info.doc = fh.doc; info.line = hit.line;
        info.startByte = hit.startByte; info.endByte = hit.endByte;
        [self appendLine:[prefix stringByAppendingString:hit.lineText] info:info segment:seg hasSegment:hasSeg];
    }
    [self scrollResultsToEnd];
}

// N++ Finder::addSearchResultInfo — "(1 hit in 1 file of 1 searched)".
// ponytail: N++ also appends " [Normal: Case/Word]"; the panel header line here stays as the task spells it out.
- (void)finishSectionWithHits:(NSInteger)hits files:(NSInteger)files searched:(NSInteger)searched
                         text:(NSString *)what cancelled:(BOOL)cancelled headerLine:(NSInteger)headerLine {
    if (headerLine < 0 || ![_headerLines containsIndex:(NSUInteger)headerLine]) return;   // cleared meanwhile
    [_headerLines removeIndex:(NSUInteger)headerLine];
    NSString *info = [NSString stringWithFormat:@"(%@ %@ in %@ %@ of %@ searched)",
                      NPPFormatGroupedInteger(hits), hits == 1 ? @"hit" : @"hits",
                      NPPFormatGroupedInteger(files), files == 1 ? @"file" : @"files",
                      NPPFormatGroupedInteger(searched)];
    NSString *oneLine = [[what componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                         componentsJoinedByString:@""];
    NSString *header = [NSString stringWithFormat:@"Search \"%@\" %@%@", oneLine, info,
                        cancelled ? @" - stopped" : @""];
    [self replaceLine:headerLine withText:header];
    _headerLabel.stringValue = header;
}

- (void)scrollResultsToEnd {
    if (!_results) return;
    NPPSci(_results, SCI_GOTOPOS, (uptr_t)NPPSci(_results, SCI_GETLENGTH));
    NPPSci(_results, SCI_SCROLLCARET);
}

- (void)setProgress:(NSString *)text force:(BOOL)force {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (!force && now - _lastProgressUpdate < 0.1) return;
    _lastProgressUpdate = now;
    _headerLabel.stringValue = text ?: @"";
}

#pragma mark - Navigation

- (NPPFIFLineInfo *)infoAtLine:(NSInteger)line {
    if (line < 0 || line >= (NSInteger)_lineInfos.count) return nil;
    id o = _lineInfos[(NSUInteger)line];
    return [o isKindOfClass:NPPFIFLineInfo.class] ? o : nil;
}

- (void)revealInfo:(NPPFIFLineInfo *)info {
    id<NPPCommandContext> ctx = self.context;
    if (!info || !ctx) return;
    NPPDocument *target = info.doc;
    if (target) {
        [ctx contextSelectDocument:target];
    } else if (info.url) {
        [ctx contextRevealFileURL:info.url line:info.line];
        target = [ctx contextCurrentDocument];
    }
    if (!target || info.line <= 0) return;
    ScintillaView *ed = target.editor;
    if (!ed) return;
    sptr_t lineStart = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)(info.line - 1));
    if (lineStart < 0) return;
    sptr_t lineEnd = NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)(info.line - 1));
    sptr_t from = MIN(lineStart + MAX((sptr_t)0, (sptr_t)info.startByte), lineEnd);
    sptr_t to = MIN(lineStart + MAX((sptr_t)0, (sptr_t)info.endByte), lineEnd);
    NPPSci(ed, SCI_ENSUREVISIBLEENFORCEPOLICY, (uptr_t)(info.line - 1));
    NPPSci(ed, SCI_GOTOPOS, (uptr_t)from);
    if (to > from) NPPSci(ed, SCI_SETSEL, (uptr_t)from, to);
    NPPSci(ed, SCI_SCROLLCARET);
}

- (void)activateResultLine:(NSInteger)line doubleClick:(BOOL)doubleClick {
    NPPFIFLineInfo *info = [self infoAtLine:line];
    if (!info) return;
    if (info.line == 0) {                       // file header: only a double click opens it (like N++)
        if (!doubleClick) return;
        if (info.doc) [self.context contextSelectDocument:info.doc];
        else if (info.url) [self.context contextOpenFileURL:info.url];
        return;
    }
    [self revealInfo:info];
}

- (void)goToNextResult:(BOOL)next {
    if (!_results || !_lineInfos.count) { NSBeep(); return; }
    NSInteger count = (NSInteger)_lineInfos.count;
    NSInteger cur = (NSInteger)NPPSci(_results, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(_results, SCI_GETCURRENTPOS));
    for (NSInteger i = 1; i <= count; i++) {
        NSInteger l = next ? (cur + i) % count : ((cur - i) % count + count) % count;
        NPPFIFLineInfo *info = [self infoAtLine:l];
        if (!info || info.line == 0) continue;
        NPPSci(_results, SCI_ENSUREVISIBLEENFORCEPOLICY, (uptr_t)l);
        NPPSci(_results, SCI_GOTOLINE, (uptr_t)l);
        NPPSci(_results, SCI_SCROLLCARET);
        [self revealInfo:info];
        return;
    }
    NSBeep();
}

- (void)copyResults {
    if (!_results) return;
    sptr_t selStart = NPPSci(_results, SCI_GETSELECTIONSTART), selEnd = NPPSci(_results, SCI_GETSELECTIONEND);
    std::string text;
    if (selStart != selEnd) {
        sptr_t first = NPPSci(_results, SCI_LINEFROMPOSITION, (uptr_t)selStart);
        sptr_t last = NPPSci(_results, SCI_LINEFROMPOSITION, (uptr_t)selEnd);
        sptr_t from = NPPSci(_results, SCI_POSITIONFROMLINE, (uptr_t)first);
        sptr_t to = NPPSci(_results, SCI_GETLINEENDPOSITION, (uptr_t)last);
        text = NPPSciGetRange(_results, from, to);
    } else {
        text = NPPSciGetText(_results);
    }
    NSString *s = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    if (!s.length) { NSBeep(); return; }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
    [self.context contextReportStatus:@"Search results copied to the clipboard." isError:NO];
}

#pragma mark - Context-menu operations (Finder::getResultFilePaths / copy / copyPathnames / openAll)

// The lines the "Selected …" items act on: the lines the selection touches, and — when it is only a caret on a
// grouping row — every result row under it (N++ Finder::copy() walks to SCI_GETLASTCHILD; the fold levels this
// reproduces come from the searchResult lexer). Returns an empty range when there is nothing to act on.
- (NSRange)selectedResultLineRange {
    NSInteger count = (NSInteger)_lineInfos.count;
    if (!_results || count == 0) return NSMakeRange(0, 0);
    NSInteger first = (NSInteger)NPPSci(_results, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(_results, SCI_GETSELECTIONSTART));
    NSInteger last = (NSInteger)NPPSci(_results, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(_results, SCI_GETSELECTIONEND));
    if (first < 0 || first >= count) return NSMakeRange(0, 0);
    last = MIN(last, count - 1);
    if (first == last) {
        NPPFIFLineInfo *info = [self infoAtLine:first];      // nil = a "Search …" row, .line == 0 = a file row
        if (!info || info.line == 0) {
            NSInteger l = first + 1;
            for (; l < count; l++) {
                NPPFIFLineInfo *next = [self infoAtLine:l];
                if (!next) break;                            // the next section always ends the group
                if (info && next.line == 0) break;           // the next file row ends a file's group
            }
            last = l - 1;
        }
    }
    return NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1));
}

// Every distinct file the selection (or, with selectionOnly == NO, the whole panel) points at, in panel order.
// Rows for an unsaved untitled buffer carry no URL and are skipped, exactly like N++ skips an empty _fullPath.
- (NSArray<NSURL *> *)resultFileURLsInSelection:(BOOL)selectionOnly {
    NSRange r = selectionOnly ? [self selectedResultLineRange] : NSMakeRange(0, _lineInfos.count);
    NSMutableArray<NSURL *> *urls = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSUInteger l = r.location; l < NSMaxRange(r); l++) {
        NSURL *url = [self infoAtLine:(NSInteger)l].url;
        NSString *key = NPPFIFPathKey(url);
        if (!key || [seen containsObject:key]) continue;
        [seen addObject:key];
        [urls addObject:url];
    }
    return urls;
}

// N++ Finder::copy(): the found text of the selected result lines, without the "\tLine 12: " prefix and without
// the repeats "show only one entry per found line" would have produced.
- (NSString *)textOfSelectedResultLines {
    NSRange r = [self selectedResultLineRange];
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSUInteger l = r.location; l < NSMaxRange(r); l++) {
        NPPFIFLineInfo *info = [self infoAtLine:(NSInteger)l];
        if (!info || info.line == 0) continue;               // only actual result rows
        std::string raw = NPPSciGetRange(_results, NPPSci(_results, SCI_POSITIONFROMLINE, (uptr_t)l),
                                         NPPSci(_results, SCI_GETLINEENDPOSITION, (uptr_t)l));
        NSString *s = [[NSString alloc] initWithBytes:raw.data() length:raw.size() encoding:NSUTF8StringEncoding];
        NSRange colon = [(s ?: @"") rangeOfString:@": "];     // "\tLine 12: found text" -> "found text"
        if (colon.location == NSNotFound) continue;
        NSString *found = [s substringFromIndex:NSMaxRange(colon)];
        if (![found isEqualToString:lines.lastObject]) [lines addObject:found];
    }
    return lines.count ? [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";
}

- (BOOL)putOnPasteboard:(NSString *)text status:(NSString *)status {
    if (!text.length) { NSBeep(); return NO; }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    [self.context contextReportStatus:status isError:NO];
    return YES;
}

- (void)copySelectedResultLines {
    [self putOnPasteboard:[self textOfSelectedResultLines] status:@"Search results copied to the clipboard."];
}

- (void)copySelectedPaths {
    NSMutableString *out = [NSMutableString new];
    for (NSURL *url in [self resultFileURLsInSelection:YES]) [out appendFormat:@"%@\n", url.path];
    [self putOnPasteboard:out status:@"Pathnames copied to the clipboard."];
}

- (void)openSelectedPaths {
    NSArray<NSURL *> *urls = [self resultFileURLsInSelection:YES];
    if (!urls.count) { NSBeep(); return; }
    for (NSURL *url in urls) [self.context contextOpenFileURL:url];
}

// Finder::wrapLongLinesToggle() / purgeToggle(): both are remembered across runs (NppGUI, saved in config.xml).
+ (BOOL)longLinesAreWrapped { return NPPFIFPrefBool(kDefFinderWrapped, NO); }
+ (BOOL)purgeBeforeEverySearch { return NPPFIFPrefBool(kDefFinderPurge, NO); }

- (void)setLongLinesWrapped:(BOOL)wrapped {
    [NSUserDefaults.standardUserDefaults setBool:wrapped forKey:kDefFinderWrapped];
    if (_results) NPPSci(_results, SCI_SETWRAPMODE, wrapped ? SC_WRAP_WORD : SC_WRAP_NONE);
}

- (void)foldAllResults:(BOOL)collapse {
    if (!_results) return;
    NPPSci(_results, SCI_COLOURISE, 0, -1);   // fold levels come from the lexer; make sure they exist
    NPPSci(_results, SCI_FOLDALL, collapse ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND);
}

#pragma mark - Click / Return handling

- (BOOL)viewIsInResults:(NSView *)v {
    for (NSView *p = v; p; p = p.superview) if (p == _results) return YES;
    return NO;
}

- (BOOL)handleMonitoredEvent:(NSEvent *)e {
    if (!_results || !_results.window || e.window != _results.window) return NO;

    if (e.type == NSEventTypeKeyDown) {
        NSResponder *fr = e.window.firstResponder;
        if (![fr isKindOfClass:NSView.class] || ![self viewIsInResults:(NSView *)fr]) return NO;
        return [self performResultsKeyEvent:e];
    }

    // Left mouse up: Scintilla has already moved the caret, so just read it back.
    NSView *hit = [e.window.contentView hitTest:e.locationInWindow];
    if (![self viewIsInResults:hit]) return NO;
    NSPoint p = [_results convertPoint:e.locationInWindow fromView:nil];
    sptr_t margins = 0;
    for (int i = 0; i < 3; i++) margins += NPPSci(_results, SCI_GETMARGINWIDTHN, (uptr_t)i);
    if (p.x < margins) return NO;                                            // fold margin click
    if (NPPSci(_results, SCI_GETSELECTIONSTART) != NPPSci(_results, SCI_GETSELECTIONEND)) return NO;  // drag-select
    // Only a double click navigates (N++ Finder::notify acts on SCN_DOUBLECLICK): a single click must leave the
    // caret — and the first responder — in the results panel so the arrow keys and Return keep working there.
    if (e.clickCount < 2) return NO;
    NSInteger line = (NSInteger)NPPSci(_results, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(_results, SCI_GETCURRENTPOS));
    [self activateResultLine:line doubleClick:YES];
    return NO;                                                               // never swallow mouse events
}

// The keys N++'s Finder binds on its results view (FindReplaceDlg.cpp:4930 run_dlgProc): Return opens the row
// under the caret, Delete prunes it. Returns YES when the key was swallowed. Split out of the event monitor so
// the self-check can exercise the bindings without a key window to type into.
- (BOOL)performResultsKeyEvent:(NSEvent *)e {
    if (!_results) return NO;
    if (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return NO;
    switch (e.keyCode) {
        case 36: case 76: {                                                  // Return / keypad Enter
            NSInteger line = (NSInteger)NPPSci(_results, SCI_LINEFROMPOSITION,
                                               (uptr_t)NPPSci(_results, SCI_GETCURRENTPOS));
            [self activateResultLine:line doubleClick:YES];
            return YES;
        }
        // N++ binds VK_DELETE (⌦). On a Mac the key that removes the selected row is ⌫, and most keyboards have
        // no ⌦ at all, so the gesture is bound to both.
        case 51: case 117:
            [self deleteSelectedResults];
            return YES;
        default:
            return NO;
    }
}

// N++ Finder::deleteResult(): the Delete key drops the row under the caret, or the whole block when the caret
// sits on a grouping row — which is exactly the range -selectedResultLineRange already computes (and it extends
// the gesture to a multi-row selection, the "add handling deletion of multiple lines?" upstream left as a TODO).
- (void)deleteSelectedResults {
    NSRange r = [self selectedResultLineRange];
    if (!_results || !r.length) { NSBeep(); return; }
    sptr_t start = NPPSci(_results, SCI_POSITIONFROMLINE, (uptr_t)r.location);
    sptr_t end = NPPSci(_results, SCI_POSITIONFROMLINE, (uptr_t)NSMaxRange(r));   // every row carries its own EOL
    NPPSci(_results, SCI_SETREADONLY, 0);
    NPPSci(_results, SCI_DELETERANGE, (uptr_t)start, end - start);
    NPPSci(_results, SCI_SETREADONLY, 1);
    [_lineInfos removeObjectsInRange:r];
    _markings.erase(_markings.begin() + r.location, _markings.begin() + NSMaxRange(r));
    [self syncMarkings];
    // Pending "Search …" rows are addressed by line number, so they move with the rows below the deletion.
    // ponytail: a section whose search is still running holds the line number it started with, so pruning above
    // it costs that section its "(N hits …)" summary. Upgrade path: hand sections a token instead of a line.
    [_headerLines removeIndexesInRange:r];
    [_headerLines shiftIndexesStartingAtIndex:NSMaxRange(r) by:-(NSInteger)r.length];
    NPPSci(_results, SCI_COLOURISE, 0, -1);        // the lexer reads _markings by line: everything below moved up
    if (_lineInfos.count) NPPSci(_results, SCI_GOTOLINE, (uptr_t)MIN(r.location, _lineInfos.count - 1));
    else _headerLabel.stringValue = @"No search yet.";
}

#pragma mark - Scanning one text

// Collects hits of `m` in `text`. Returns the number of lines in the text.
// Lines are split exactly like Scintilla's SC_LINE_END_TYPE_DEFAULT (CR / LF / CRLF only): Foundation's
// NSStringEnumerationByLines also breaks on U+2028, U+2029 and U+0085, which would make hit.line — used as a
// Scintilla line index by revealInfo: / contextRevealFileURL:line: — drift past the first such character.
static NSInteger NPPFIFScanText(NSString *text, NPPFIFMatcher *m, NSMutableArray<NPPFIFHit *> *out) {
    static NSCharacterSet *eol;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ eol = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]; });

    // Line table first: content start, content length (EOL stripped) and the start of the next line.
    struct FIFLine { NSUInteger start, length, next; };
    std::vector<FIFLine> lines;
    NSUInteger n = text.length, pos = 0;
    while (pos < n) {
        NSRange br = [text rangeOfCharacterFromSet:eol options:NSLiteralSearch range:NSMakeRange(pos, n - pos)];
        NSUInteger end = br.location == NSNotFound ? n : br.location;
        NSUInteger next = end;
        if (br.location != NSNotFound) {
            next = end + 1;
            if ([text characterAtIndex:end] == '\r' && next < n && [text characterAtIndex:next] == '\n') next++;
        }
        lines.push_back({pos, end - pos, next});
        if (br.location == NSNotFound) break;
        pos = next;
    }
    if (lines.empty()) return 0;

    // The matcher runs over the whole text, not line by line, so patterns containing a line break match
    // (N++ searches the whole buffer). A hit is reported on the line its match starts on, highlighted up to
    // that line's end. Matches come back in ascending order, so one forward walk of the line table maps them.
    NSUInteger idx = 0;
    NSString *shown = nil;
    for (NSValue *v in [m rangesIn:text template:nil replacements:nil]) {
        NSRange r = v.rangeValue;
        while (idx + 1 < lines.size() && r.location >= lines[idx].next) { idx++; shown = nil; }
        const FIFLine &L = lines[idx];
        if (!shown) {
            NSString *line = [text substringWithRange:NSMakeRange(L.start, L.length)];
            shown = line.length > kMaxDisplayedLineChars ? [line substringToIndex:kMaxDisplayedLineChars] : line;
        }
        NSUInteger from = r.location > L.start ? MIN(r.location - L.start, L.length) : 0;
        NSUInteger to = NSMaxRange(r) > L.start ? MIN(NSMaxRange(r) - L.start, L.length) : 0;
        NPPFIFHit *hit = [NPPFIFHit new];
        hit.line = (NSInteger)idx + 1;
        hit.lineText = shown;
        if (to > from && to <= shown.length) {
            hit.startByte = (NSInteger)[[shown substringToIndex:from] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            hit.endByte = hit.startByte + (NSInteger)[[shown substringWithRange:NSMakeRange(from, to - from)]
                                                      lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        } else {
            hit.startByte = hit.endByte = -1;   // match sits past the displayed part of a very long line
        }
        [out addObject:hit];
    }
    return (NSInteger)lines.size();
}

#pragma mark - Find in Files (directory walk)

- (NSArray<NSURL *> *)filesUnder:(NSURL *)root filters:(NPPFIFFilters *)filters
                       recursive:(BOOL)recursive hidden:(BOOL)hidden token:(NSInteger)token {
    NSMutableArray<NSURL *> *files = [NSMutableArray new];
    NSFileManager *fm = NSFileManager.defaultManager;
    // ponytail: package directories (.app, .rtfd) are always skipped; N++ has no concept of them.
    NSDirectoryEnumerationOptions opts = NSDirectoryEnumerationSkipsPackageDescendants;
    if (!hidden) opts |= NSDirectoryEnumerationSkipsHiddenFiles;
    if (!recursive) opts |= NSDirectoryEnumerationSkipsSubdirectoryDescendants;
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLIsRegularFileKey, NSURLNameKey];
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:root includingPropertiesForKeys:keys options:opts
                                       errorHandler:^BOOL(NSURL *url, NSError *err) { return YES; }];
    NSUInteger rootDepth = root.pathComponents.count;
    for (NSURL *url in en) {
        if (self.cancelToken != token) break;
        NSNumber *isDir = nil, *isRegular = nil, *size = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
        if (isDir.boolValue) {
            NSInteger level = (NSInteger)url.pathComponents.count - (NSInteger)rootDepth;
            if ([filters excludesDirectoryName:url.lastPathComponent atLevel:level]) [en skipDescendants];
            continue;
        }
        [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:NULL];
        if (!isRegular.boolValue) continue;
        if (![filters matchesFileName:url.lastPathComponent]) continue;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        if (size && size.unsignedLongLongValue > kMaxFileSize) continue;
        [files addObject:url];
    }
    return files;
}

// N++ searches the in-memory buffer of files that are open (Notepad_plus::findInFilelist); the disk copy of a
// modified buffer gives stale text and stale line numbers. Only dirty buffers can differ from disk, so snapshot
// just those — on the main thread, since the editor must not be touched from the search queue.
// Preferences > Searching "Find in Files: use the file content on disk rather than the opened buffer"
// (NppGUI::_fif_ignoreunsavedChangesInOpenedFiles) leaves the snapshot empty: every file is then read from disk.
- (void)snapshotUnsavedBuffers:(NSArray<NPPDocument *> *)docs
                      intoDocs:(NSMutableDictionary<NSString *, NPPDocument *> *)openDocs
                          text:(NSMutableDictionary<NSString *, NSString *> *)openText {
    if (NPPPreferences.shared.findInFilesIgnoreOpenedFiles) return;
    for (NPPDocument *doc in docs ?: @[]) {
        NSString *key = NPPFIFPathKey(doc.fileURL);
        if (!key || !doc.isDirty || !doc.editor) continue;
        std::string raw = NPPSciGetText(doc.editor);
        NSString *body = [[NSString alloc] initWithBytes:raw.data() length:raw.size() encoding:NSUTF8StringEncoding];
        if (!body) continue;
        openDocs[key] = doc; openText[key] = body;
    }
}

- (void)runFindInFilesWithText:(NSString *)what directory:(NSURL *)dir filtersText:(NSString *)filtersText
                     recursive:(BOOL)recursive hidden:(BOOL)hidden matchCase:(BOOL)matchCase
                     wholeWord:(BOOL)wholeWord mode:(NPPSearchMode)mode {
    NSString *err = nil;
    NPPFIFMatcher *m = [NPPFIFMatcher matcherForText:what matchCase:matchCase wholeWord:wholeWord mode:mode error:&err];
    if (!m) { NSBeep(); [self.context contextReportStatus:err isError:YES]; return; }

    NPPFIFFilters *filters = [NPPFIFFilters filtersFromString:filtersText];
    __weak NPPFindInFiles *weakSelf2 = self;
    [self runSearchForText:what matcher:m prefix:@"Find in Files" onlyLines:nil filesBlock:^(NSInteger token) {
        return [weakSelf2 filesUnder:dir filters:filters recursive:recursive hidden:hidden token:token] ?: @[];
    }];
}

// The engine behind Find in Files and "Find in these search results…": `filesBlock` produces the files to search
// (a directory walk, or the paths already in the panel) on the search queue, and `onlyLines` — when non-nil —
// keeps only hits on lines the panel already lists (FindInFinderDlg's "Search only in found lines",
// FindReplaceDlg.cpp:3649 Finder::canFind).
- (void)runSearchForText:(NSString *)what matcher:(NPPFIFMatcher *)m prefix:(NSString *)prefix
               onlyLines:(NSDictionary<NSString *, NSIndexSet *> *)onlyLines
              filesBlock:(NSArray<NSURL *> *(^)(NSInteger token))filesBlock {
    [self.context contextShowPanel:self];
    NSInteger headerLine = [self beginSectionForText:what];
    [self setProgress:@"Searching…" force:YES];

    NSMutableDictionary<NSString *, NPPDocument *> *openDocs = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *openText = [NSMutableDictionary new];
    [self snapshotUnsavedBuffers:[self.context contextOpenDocuments] intoDocs:openDocs text:openText];

    NSInteger token = self.cancelToken + 1;
    self.cancelToken = token;
    self.runToken = token;
    self.searching = YES;
    __weak NPPFindInFiles *weakSelf = self;
    dispatch_async(_queue, ^{
        NPPFindInFiles *self2 = weakSelf;
        if (!self2) return;
        NSArray<NSURL *> *files = filesBlock(token);
        __block NSInteger totalHits = 0, filesWithHits = 0, searched = 0;
        for (NSURL *url in files) {
            if (self2.cancelToken != token) break;
            searched++;
            NSString *key = NPPFIFPathKey(url);
            NPPDocument *openDoc = key ? openDocs[key] : nil;
            NSStringEncoding enc = NSUTF8StringEncoding;
            NSString *text = openDoc ? openText[key] : NPPFIFReadTextFile(url, &enc);
            if (!text) continue;
            NPPFIFFileHits *fh = [NPPFIFFileHits new];
            fh.url = url; fh.doc = openDoc; fh.displayPath = url.path; fh.hits = [NSMutableArray new];
            fh.totalLines = NPPFIFScanText(text, m, fh.hits);
            if (onlyLines) fh.hits = [NPPFindInFiles hits:fh.hits onLines:onlyLines[key ?: @""]];
            NSInteger done = searched;
            if (fh.hits.count) {
                totalHits += (NSInteger)fh.hits.count;
                filesWithHits++;
                dispatch_async(dispatch_get_main_queue(), ^{ [self2 appendFileHits:fh]; });
            }
            NSInteger hitsSoFar = totalHits;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self2 setProgress:[NSString stringWithFormat:@"Searching… %@/%@ files, %@ hits",
                                    NPPFormatGroupedInteger(done), NPPFormatGroupedInteger((NSInteger)files.count),
                                    NPPFormatGroupedInteger(hitsSoFar)] force:NO];
            });
        }
        BOOL cancelled = self2.cancelToken != token;
        NSInteger hits = totalHits, nbFiles = filesWithHits, nbSearched = searched;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self2.runToken == token) self2.searching = NO;   // a newer run owns the flag now
            [self2 finishSectionWithHits:hits files:nbFiles searched:nbSearched text:what cancelled:cancelled
                              headerLine:headerLine];
            [self2 reportFindStatus:hits files:nbFiles searched:nbSearched prefix:prefix cancelled:cancelled];
        });
    });
}

- (void)reportFindStatus:(NSInteger)hits files:(NSInteger)files searched:(NSInteger)searched
                  prefix:(NSString *)prefix cancelled:(BOOL)cancelled {
    NSString *msg;
    if (hits == 0)
        msg = [NSString stringWithFormat:@"%@: no occurrence found (%@ searched)%@", prefix,
               NPPFormatGroupedInteger(searched), cancelled ? @", stopped" : @""];
    else
        msg = [NSString stringWithFormat:@"%@: %@ %@ in %@ %@ of %@ searched%@", prefix,
               NPPFormatGroupedInteger(hits), hits == 1 ? @"hit" : @"hits",
               NPPFormatGroupedInteger(files), files == 1 ? @"file" : @"files",
               NPPFormatGroupedInteger(searched), cancelled ? @", stopped" : @""];
    [self.context contextReportStatus:msg isError:(hits == 0)];
}

- (void)stopSearch {
    if (!self.isSearching) return;
    self.cancelToken = self.cancelToken + 1;
    [self.context contextReportStatus:@"Find in Files: stopping…" isError:NO];
}

#pragma mark - Find in these search results (FindInFinderDlg + WM_FINDALL_INCURRENTFINDER)

// The lines the panel already lists, per file: the filter behind "Search only in found lines"
// (FindReplaceDlg.cpp:3649 -> Finder::canFind).
- (NSDictionary<NSString *, NSIndexSet *> *)foundLinesByPath {
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *out = [NSMutableDictionary new];
    for (NSUInteger l = 0; l < _lineInfos.count; l++) {
        NPPFIFLineInfo *info = [self infoAtLine:(NSInteger)l];
        NSString *key = info.line > 0 ? NPPFIFPathKey(info.url) : nil;
        if (!key) continue;
        NSMutableIndexSet *set = out[key];
        if (!set) { set = [NSMutableIndexSet new]; out[key] = set; }
        [set addIndex:(NSUInteger)info.line];
    }
    return out;
}

+ (NSMutableArray<NPPFIFHit *> *)hits:(NSArray<NPPFIFHit *> *)hits onLines:(NSIndexSet *)lines {
    NSMutableArray<NPPFIFHit *> *kept = [NSMutableArray new];
    for (NPPFIFHit *h in hits) if (h.line > 0 && [lines containsIndex:(NSUInteger)h.line]) [kept addObject:h];
    return kept;
}

// N++'s "Find in search results" dialog (IDD_FINDINFINDER_DLG). ponytail: two simplifications against that
// dialog — Search Mode is one popup instead of three radio buttons (the native control for a 3-way choice), and
// ". matches newline" is left out because NPPFIFMatcher has no such option yet, exactly like the Find in Files
// sheet above. Upgrade path for the latter: NSRegularExpressionDotMatchesLineSeparators in +matcherForText:.
- (void)showFindInResultsSheet {
    NSArray<NSURL *> *files = [self resultFileURLsInSelection:NO];
    NSWindow *host = [self.context contextWindow] ?: _results.window;
    if (!files.count || !host) { NSBeep(); return; }

    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 122)];
    NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 98, 420, 24)];
    combo.completes = NO;
    combo.font = [NPPFindPanelController dialogFont];
    [combo addItemsWithObjectValues:[NSUserDefaults.standardUserDefaults arrayForKey:kDefFindHistory] ?: @[]];
    combo.stringValue = NPPFindPanelController.shared.searchText ?: @"";
    [acc addSubview:combo];

    NSButton *(^box)(NSString *, BOOL, CGFloat) = ^NSButton *(NSString *title, BOOL on, CGFloat y) {
        NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
        b.frame = NSMakeRect(0, y, 420, 20);
        b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        [acc addSubview:b];
        return b;
    };
    NSButton *onlyBox = box(@"Search only in found lines", _finderOnlyFoundLines, 72);
    NSButton *wordBox = box(@"Match whole word only", _finderWholeWord, 50);
    NSButton *caseBox = box(@"Match case", _finderMatchCase, 28);

    NSTextField *modeLabel = NPPFIFLabel(@"Search Mode :", NSMakeRect(0, 4, 96, 17));
    [acc addSubview:modeLabel];
    NSPopUpButton *modePopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(102, 0, 260, 25)];
    [modePopUp addItemsWithTitles:@[@"Normal", @"Extended (\\n, \\r, \\t, \\0, \\xHH)", @"Regular expression"]];
    [modePopUp selectItemAtIndex:(NSInteger)_finderMode];
    [acc addSubview:modePopUp];

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Find in these search results";
    alert.informativeText = [NSString stringWithFormat:@"Searches the %@ %@ listed in this panel again.",
                             NPPFormatGroupedInteger((NSInteger)files.count), files.count == 1 ? @"file" : @"files"];
    alert.accessoryView = acc;
    [alert addButtonWithTitle:@"Find All"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak NPPFindInFiles *weakSelf = self;
    [alert beginSheetModalForWindow:host completionHandler:^(NSModalResponse res) {
        NPPFindInFiles *self2 = weakSelf;
        if (res != NSAlertFirstButtonReturn || !self2) return;
        self2->_finderOnlyFoundLines = onlyBox.state == NSControlStateValueOn;
        self2->_finderWholeWord = wordBox.state == NSControlStateValueOn;
        self2->_finderMatchCase = caseBox.state == NSControlStateValueOn;
        self2->_finderMode = (NPPSearchMode)modePopUp.indexOfSelectedItem;
        [self2 findInResultFiles:files text:combo.stringValue];
    }];
    // The combo must own the keyboard before Return, or Return just fires the default button on an empty field.
    [alert.window makeFirstResponder:combo];
}

// Notepad_plus::findInFinderFiles: the files the result set names are searched again, into a fresh section.
// ponytail: N++ opens a second, volatile Finder for the narrowed hits; the port appends a section to its one
// panel — which is also why the source lines are read before the search starts (a "purge" would clear them).
- (void)findInResultFiles:(NSArray<NSURL *> *)files text:(NSString *)what {
    NSString *err = nil;
    NPPFIFMatcher *m = [NPPFIFMatcher matcherForText:what matchCase:_finderMatchCase wholeWord:_finderWholeWord
                                                mode:_finderMode error:&err];
    if (!m) { NSBeep(); [self.context contextReportStatus:err isError:YES]; return; }
    NSDictionary<NSString *, NSIndexSet *> *onlyLines = _finderOnlyFoundLines ? [self foundLinesByPath] : nil;
    NPPFIFHistoryAdd(kDefFindHistory, what);
    [self runSearchForText:what matcher:m prefix:@"Find in search results" onlyLines:onlyLines
                filesBlock:^NSArray<NSURL *> *(NSInteger token) { return files; }];
}

#pragma mark - Find All in open documents

- (void)findAllIn:(NSArray<NPPDocument *> *)docs text:(NSString *)text matchCase:(BOOL)matchCase
        wholeWord:(BOOL)wholeWord mode:(NPPSearchMode)mode scope:(NSString *)scope {
    NSString *err = nil;
    NPPFIFMatcher *m = [NPPFIFMatcher matcherForText:text matchCase:matchCase wholeWord:wholeWord mode:mode error:&err];
    if (!m) { NSBeep(); [self.context contextReportStatus:err isError:YES]; return; }

    [self.context contextShowPanel:self];
    NSInteger headerLine = [self beginSectionForText:text];

    NSInteger hits = 0, filesWithHits = 0, searched = 0;
    for (NPPDocument *doc in docs) {
        ScintillaView *ed = doc.editor;
        if (!ed) continue;
        searched++;
        std::string raw = NPPSciGetText(ed);
        NSString *body = [[NSString alloc] initWithBytes:raw.data() length:raw.size() encoding:NSUTF8StringEncoding];
        if (!body) continue;
        NPPFIFFileHits *fh = [NPPFIFFileHits new];
        fh.url = doc.fileURL; fh.doc = doc; fh.displayPath = doc.fileURL.path ?: doc.displayName;
        fh.hits = [NSMutableArray new];
        fh.totalLines = NPPFIFScanText(body, m, fh.hits);
        if (!fh.hits.count) continue;
        hits += (NSInteger)fh.hits.count;
        filesWithHits++;
        [self appendFileHits:fh];
    }
    [self finishSectionWithHits:hits files:filesWithHits searched:searched text:text cancelled:NO
                     headerLine:headerLine];
    [self reportFindStatus:hits files:filesWithHits searched:searched
                    prefix:scope.length ? [@"Find All in " stringByAppendingString:scope] : @"Find All"
                 cancelled:NO];
}

#pragma mark - Replace in Files

// Files with unsaved changes Replace in Files must not rewrite: the disk copy is stale, so replacing in it and
// then saving the buffer would silently undo the replacements. The exception is the user asking for the on-disk
// copy — N++ reads _fif_ignoreunsavedChangesInOpenedFiles in replaceInFiles just as in findInFiles
// (Notepad_plus.cpp:2014), and skipping here after searching the disk copy there would report hits in a file
// Replace in Files then refuses to touch. The buffer keeps its unsaved edits either way.
- (NSSet<NSString *> *)pathsToLeaveAlone:(NSArray<NPPDocument *> *)docs {
    if (NPPPreferences.shared.findInFilesIgnoreOpenedFiles) return [NSSet set];
    NSMutableSet<NSString *> *dirty = [NSMutableSet new];
    for (NPPDocument *doc in docs ?: @[]) {
        NSString *key = NPPFIFPathKey(doc.fileURL);
        if (doc.isDirty && key) [dirty addObject:key];
    }
    return dirty;
}

- (void)runReplaceInFilesWithText:(NSString *)what replacement:(NSString *)replacement directory:(NSURL *)dir
                      filtersText:(NSString *)filtersText recursive:(BOOL)recursive hidden:(BOOL)hidden
                        matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord mode:(NPPSearchMode)mode {
    NSString *err = nil;
    NPPFIFMatcher *m = [NPPFIFMatcher matcherForText:what matchCase:matchCase wholeWord:wholeWord mode:mode error:&err];
    if (!m) { NSBeep(); [self.context contextReportStatus:err isError:YES]; return; }

    NPPFIFFilters *filters = [NPPFIFFilters filtersFromString:filtersText];
    NSString *templ = (mode == NPPSearchModeRegex) ? NPPFIFRegexTemplate(replacement)
                    : (mode == NPPSearchModeExtended) ? NPPFIFUnescape(replacement) : replacement;

    NSSet<NSString *> *dirtyPaths = [self pathsToLeaveAlone:[self.context contextOpenDocuments]];

    NSInteger token = self.cancelToken + 1;
    self.cancelToken = token;
    self.runToken = token;
    self.searching = YES;
    [self setProgress:@"Replacing…" force:YES];
    __weak NPPFindInFiles *weakSelf = self;
    dispatch_async(_queue, ^{
        NPPFindInFiles *self2 = weakSelf;
        if (!self2) return;
        NSArray<NSURL *> *files = [self2 filesUnder:dir filters:filters recursive:recursive hidden:hidden token:token];
        NSInteger replaced = 0, changedFiles = 0, skipped = 0;
        NSMutableSet<NSString *> *changedKeys = [NSMutableSet new];
        for (NSURL *url in files) {
            if (self2.cancelToken != token) break;
            NSString *key = NPPFIFPathKey(url);
            if (key && [dirtyPaths containsObject:key]) { skipped++; continue; }
            NSStringEncoding enc = NSUTF8StringEncoding;
            NSString *text = NPPFIFReadTextFile(url, &enc);
            if (!text.length) continue;
            NSInteger n = 0;
            NSString *out = NPPFIFReplaceInText(text, m, templ, &n);
            if (!n) continue;
            NSError *werr = nil;
            if ([out writeToURL:url atomically:YES encoding:enc error:&werr]) {
                replaced += n;
                changedFiles++;
                if (key) [changedKeys addObject:key];
            } else {
                skipped++;
            }
        }
        BOOL cancelled = self2.cancelToken != token;
        NSInteger nb = replaced, nbFiles = changedFiles, nbSkipped = skipped;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self2.runToken == token) self2.searching = NO;   // a newer run owns the flag now
            // A file open in a clean tab was just rewritten behind that buffer's back: reload it, or the tab keeps
            // showing the old text and the next save writes it back over the replacements.
            // ponytail: N++ edits the buffer itself (so the replacement is undoable); a reload is the small version.
            for (NPPDocument *doc in [self2.context contextOpenDocuments] ?: @[]) {
                NSString *key = NPPFIFPathKey(doc.fileURL);
                if (key && !doc.isDirty && [changedKeys containsObject:key]) [doc reloadFromDisk:NULL];
            }
            NSString *msg;
            if (nb == 0) msg = @"Replace in Files: 0 occurrences were replaced.";
            else if (nb == 1) msg = [NSString stringWithFormat:@"Replace in Files: 1 occurrence was replaced in %@ %@.",
                                     NPPFormatGroupedInteger(nbFiles), nbFiles == 1 ? @"file" : @"files"];
            else msg = [NSString stringWithFormat:@"Replace in Files: %@ occurrences were replaced in %@ %@.",
                        NPPFormatGroupedInteger(nb), NPPFormatGroupedInteger(nbFiles), nbFiles == 1 ? @"file" : @"files"];
            if (nbSkipped) msg = [msg stringByAppendingFormat:@" %@ file(s) skipped (unsaved changes or not writable).",
                                  NPPFormatGroupedInteger(nbSkipped)];
            if (cancelled) msg = [msg stringByAppendingString:@" Stopped."];
            [self2 setProgress:msg force:YES];
            [self2.context contextReportStatus:msg isError:(nb == 0)];
        });
    });
}

// Replaces every match, preserving everything outside the matches. Like the search path this runs over the whole
// text rather than line by line, so a pattern containing a line break replaces correctly (N++ searches the buffer).
static NSString *NPPFIFReplaceInText(NSString *text, NPPFIFMatcher *m, NSString *templ, NSInteger *count) {
    NSMutableArray<NSString *> *repl = [NSMutableArray new];
    NSArray<NSValue *> *ranges = [m rangesIn:text template:templ replacements:repl];
    if (count) *count = (NSInteger)ranges.count;
    if (!ranges.count) return text;
    NSMutableString *out = [text mutableCopy];
    for (NSInteger i = (NSInteger)ranges.count - 1; i >= 0; i--) {   // back to front so earlier offsets stay valid
        NSString *with = (NSUInteger)i < repl.count ? repl[(NSUInteger)i] : templ;
        [out replaceCharactersInRange:ranges[(NSUInteger)i].rangeValue withString:with ?: @""];
    }
    return out;
}

#pragma mark - Find in Files sheet

static NSTextField *NPPFIFLabel(NSString *text, NSRect frame) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.frame = frame;
    l.alignment = NSTextAlignmentRight;
    l.font = [NSFont systemFontOfSize:12];
    return l;
}

- (void)showFindInFilesSheetWithContext:(id<NPPCommandContext>)context {
    self.context = context;
    NSWindow *host = [context contextWindow];
    if (!host) return;
    // The menu item stays live while the sheet is up, so re-invoking it must only refocus the sheet: a second
    // beginSheet: of the same window queues a phantom presentation that blocks every later sheet on the host.
    if (_sheet.sheetParent) { [_sheet makeKeyAndOrderFront:nil]; return; }
    [self buildSheet];
    [self loadSheetDefaults];
    [host beginSheet:_sheet completionHandler:nil];
}

// Idempotent; builds the sheet without showing it (the self-check inspects its drop-downs).
- (void)buildSheet {
    if (_sheet) return;
    NSRect r = NSMakeRect(0, 0, 560, 322);
    _sheet = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskTitled
                                           backing:NSBackingStoreBuffered defer:YES];
    _sheet.title = @"Find in Files";
    NSView *c = _sheet.contentView;
    const CGFloat labelW = 96, fieldX = 108, fieldW = 400;
    CGFloat y = NSHeight(r) - 42;

    [c addSubview:NPPFIFLabel(@"Find what :", NSMakeRect(4, y + 3, labelW, 17))];
    _findCombo = [[NSComboBox alloc] initWithFrame:NSMakeRect(fieldX, y, fieldW, 24)];
    _findCombo.completes = NO;
    [c addSubview:_findCombo];
    y -= 32;

    [c addSubview:NPPFIFLabel(@"Replace with :", NSMakeRect(4, y + 3, labelW, 17))];
    _replaceCombo = [[NSComboBox alloc] initWithFrame:NSMakeRect(fieldX, y, fieldW, 24)];
    _replaceCombo.completes = NO;
    [c addSubview:_replaceCombo];
    y -= 32;

    // Filters and Directory are combo boxes in N++ too (IDD_FINDINFILES_FILTERS_COMBO / _DIR_COMBO), and their
    // history is what makes a second search in the same tree one click.
    [c addSubview:NPPFIFLabel(@"Filters :", NSMakeRect(4, y + 3, labelW, 17))];
    _filtersCombo = [[NSComboBox alloc] initWithFrame:NSMakeRect(fieldX, y, fieldW, 24)];
    _filtersCombo.completes = NO;
    _filtersCombo.placeholderString = @"*.* !*.obj !\\build";
    _filtersCombo.toolTip = @"Space or semicolon separated. \"!\" excludes: !*.exe, !\\folder (first level), !+\\folder (any level).";
    [c addSubview:_filtersCombo];
    y -= 32;

    [c addSubview:NPPFIFLabel(@"Directory :", NSMakeRect(4, y + 3, labelW, 17))];
    _dirCombo = [[NSComboBox alloc] initWithFrame:NSMakeRect(fieldX, y, fieldW - 96, 24)];
    _dirCombo.completes = NO;
    [c addSubview:_dirCombo];
    NSButton *browse = [NSButton buttonWithTitle:@"Browse…" target:self action:@selector(browseDirectory:)];
    browse.frame = NSMakeRect(fieldX + fieldW - 92, y - 3, 92, 28);
    browse.bezelStyle = NSBezelStyleRounded;
    [c addSubview:browse];
    NSButton *curDir = [NSButton buttonWithTitle:@"Use current document's folder"
                                          target:self action:@selector(useCurrentDocumentFolder:)];
    curDir.frame = NSMakeRect(fieldX - 4, y - 30, 220, 24);
    curDir.bezelStyle = NSBezelStyleRounded;
    curDir.font = [NSFont systemFontOfSize:11];
    [c addSubview:curDir];
    y -= 62;

    _subFoldersBox = [NSButton checkboxWithTitle:@"In all sub-folders" target:nil action:nil];
    _subFoldersBox.frame = NSMakeRect(fieldX, y, 220, 20);
    [c addSubview:_subFoldersBox];
    _wholeWordBox = [NSButton checkboxWithTitle:@"Match whole word only" target:nil action:nil];
    _wholeWordBox.frame = NSMakeRect(fieldX + 232, y, 240, 20);
    [c addSubview:_wholeWordBox];
    y -= 24;
    _hiddenBox = [NSButton checkboxWithTitle:@"In hidden folders" target:nil action:nil];
    _hiddenBox.frame = NSMakeRect(fieldX, y, 220, 20);
    [c addSubview:_hiddenBox];
    _matchCaseBox = [NSButton checkboxWithTitle:@"Match case" target:nil action:nil];
    _matchCaseBox.frame = NSMakeRect(fieldX + 232, y, 240, 20);
    [c addSubview:_matchCaseBox];
    y -= 30;

    [c addSubview:NPPFIFLabel(@"Search Mode :", NSMakeRect(4, y + 1, labelW, 17))];
    _modeNormal = [NSButton radioButtonWithTitle:@"Normal" target:self action:@selector(modeChanged:)];
    _modeNormal.frame = NSMakeRect(fieldX, y, 90, 20);
    _modeExtended = [NSButton radioButtonWithTitle:@"Extended (\\n, \\r, \\t, \\0, \\xHH)"
                                            target:self action:@selector(modeChanged:)];
    _modeExtended.frame = NSMakeRect(fieldX + 92, y, 230, 20);
    _modeRegex = [NSButton radioButtonWithTitle:@"Regular expression" target:self action:@selector(modeChanged:)];
    _modeRegex.frame = NSMakeRect(fieldX, y - 22, 200, 20);
    for (NSButton *b in @[_modeNormal, _modeExtended, _modeRegex]) [c addSubview:b];

    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeSheet:)];
    close.frame = NSMakeRect(NSWidth(r) - 100, 14, 88, 30);
    close.keyEquivalent = @"\033";
    NSButton *replaceAll = [NSButton buttonWithTitle:@"Replace in Files" target:self action:@selector(replaceInFiles:)];
    replaceAll.frame = NSMakeRect(NSWidth(r) - 246, 14, 140, 30);
    NSButton *findAll = [NSButton buttonWithTitle:@"Find All" target:self action:@selector(findAllInFiles:)];
    findAll.frame = NSMakeRect(NSWidth(r) - 346, 14, 96, 30);
    findAll.keyEquivalent = @"\r";
    for (NSButton *b in @[close, replaceAll, findAll]) { b.bezelStyle = NSBezelStyleRounded; [c addSubview:b]; }

    _sheet.initialFirstResponder = _findCombo;
}

- (void)loadSheetDefaults {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NPPFindPanelController *find = NPPFindPanelController.shared;

    NSArray<NSString *> *dirHistory = NPPFIFHistory(kDefDirHistory), *filterHistory = NPPFIFHistory(kDefFilters);
    void (^fill)(NSComboBox *, NSArray<NSString *> *) = ^(NSComboBox *combo, NSArray<NSString *> *items) {
        [combo removeAllItems];
        [combo addItemsWithObjectValues:items];
    };
    fill(_findCombo, NPPFIFHistory(kDefFindHistory));
    fill(_replaceCombo, NPPFIFHistory(kDefReplaceHistory));
    fill(_filtersCombo, filterHistory);
    fill(_dirCombo, dirHistory);

    // Same text entries N++ restyles from _monospacedFontFindDlg (find / replace / filters / directory).
    NSFont *entryFont = [NPPFindPanelController dialogFont];
    _findCombo.font = _replaceCombo.font = _filtersCombo.font = _dirCombo.font = entryFont;

    NPPDocument *doc = [self.context contextCurrentDocument];
    // One "selection becomes the Find text" path for the whole Find family (FindReplaceDlg::setSearchTextWithSettings),
    // so fillFindWhatThreshold and the two "Fill Find field…" settings are applied here by the same code the Find
    // panel uses — not a second copy. Empty means "keep what the field had".
    NSString *initial = [find dialogFillTextInEditor:doc.editor];
    if (!initial.length) initial = find.searchText.length ? find.searchText : _findCombo.stringValue;
    _findCombo.stringValue = initial ?: @"";
    _replaceCombo.stringValue = find.replaceText ?: @"";

    _filtersCombo.stringValue = filterHistory.firstObject ?: @"*.*";
    _dirCombo.stringValue = [NPPFindInFiles directoryForDocumentFolder:doc.fileURL.URLByDeletingLastPathComponent.path
                                                             lastUsed:dirHistory.firstObject];

    _subFoldersBox.state = ([ud objectForKey:kDefSubFolders] == nil || [ud boolForKey:kDefSubFolders])
                         ? NSControlStateValueOn : NSControlStateValueOff;
    _hiddenBox.state = [ud boolForKey:kDefHiddenFolders] ? NSControlStateValueOn : NSControlStateValueOff;
    _matchCaseBox.state = ([ud objectForKey:kDefMatchCase] ? [ud boolForKey:kDefMatchCase] : find.matchCase)
                        ? NSControlStateValueOn : NSControlStateValueOff;
    _wholeWordBox.state = ([ud objectForKey:kDefWholeWord] ? [ud boolForKey:kDefWholeWord] : find.wholeWord)
                        ? NSControlStateValueOn : NSControlStateValueOff;

    NPPSearchMode mode = [ud objectForKey:kDefSearchMode] ? (NPPSearchMode)[ud integerForKey:kDefSearchMode] : find.searchMode;
    [self setSheetMode:mode];
}

// Notepad_plus::setFindReplaceFolderFilter(nullptr, …): the Directory field follows the active document only when
// Preferences > Searching "Fill Find in Files Directory field based on the active document" is on. Off (N++'s
// default) it keeps the directory of the last search — the home folder standing in for N++'s empty field.
+ (NSString *)directoryForDocumentFolder:(NSString *)docFolder lastUsed:(NSString *)lastUsed {
    if (docFolder.length && NPPFIFPrefBool(kDefFillDirFromActiveDoc, NO)) return docFolder;
    return lastUsed.length ? lastUsed : NSHomeDirectory();
}

// Notepad_plus::findInFiles: the dialog goes away once the hits are in the results window, unless
// Preferences > Searching "Find dialog remains open after a search that outputs to the results window".
// ponytail: two deliberate simplifications. N++ keeps the dialog up when the search found nothing — the search
// here is asynchronous and the sheet is dismissed before the count exists — and a sheet blocks its host window,
// so while it is held open the results panel behind it cannot be clicked. Upgrade path for both: make this dialog
// a floating panel like the Find panel and close it from the search's completion block.
+ (BOOL)shouldCloseSheetAfterSearch { return !NPPFIFPrefBool(kDefFindDlgAlwaysVisible, NO); }

- (void)closeSheetAfterSearch {
    if ([NPPFindInFiles shouldCloseSheetAfterSearch] && _sheet.sheetParent) [_sheet.sheetParent endSheet:_sheet];
}

- (void)setSheetMode:(NPPSearchMode)mode {
    _modeNormal.state = mode == NPPSearchModeNormal ? NSControlStateValueOn : NSControlStateValueOff;
    _modeExtended.state = mode == NPPSearchModeExtended ? NSControlStateValueOn : NSControlStateValueOff;
    _modeRegex.state = mode == NPPSearchModeRegex ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NPPSearchMode)sheetMode {
    if (_modeRegex.state == NSControlStateValueOn) return NPPSearchModeRegex;
    if (_modeExtended.state == NSControlStateValueOn) return NPPSearchModeExtended;
    return NPPSearchModeNormal;
}

- (void)modeChanged:(NSButton *)sender {
    [self setSheetMode:(sender == _modeRegex ? NPPSearchModeRegex
                      : sender == _modeExtended ? NPPSearchModeExtended : NPPSearchModeNormal)];
}

- (void)browseDirectory:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO; p.canChooseDirectories = YES; p.allowsMultipleSelection = NO;
    p.prompt = @"Select";
    NSString *cur = _dirCombo.stringValue;
    if (cur.length) p.directoryURL = [NSURL fileURLWithPath:cur.stringByExpandingTildeInPath isDirectory:YES];
    [p beginSheetModalForWindow:_sheet completionHandler:^(NSModalResponse res) {
        if (res == NSModalResponseOK && p.URL) self->_dirCombo.stringValue = p.URL.path;
    }];
}

- (void)useCurrentDocumentFolder:(id)sender {
    NSURL *url = [self.context contextCurrentDocument].fileURL.URLByDeletingLastPathComponent;
    if (!url.path.length) { NSBeep(); return; }
    _dirCombo.stringValue = url.path;
}

- (void)closeSheet:(id)sender {
    [self saveSheetDefaults];
    if (_sheet.sheetParent) [_sheet.sheetParent endSheet:_sheet];
}

- (void)saveSheetDefaults {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NPPFIFHistoryAdd(kDefFilters, _filtersCombo.stringValue);   // most recent first: also what the field reopens with
    [ud setBool:_subFoldersBox.state == NSControlStateValueOn forKey:kDefSubFolders];
    [ud setBool:_hiddenBox.state == NSControlStateValueOn forKey:kDefHiddenFolders];
    [ud setBool:_matchCaseBox.state == NSControlStateValueOn forKey:kDefMatchCase];
    [ud setBool:_wholeWordBox.state == NSControlStateValueOn forKey:kDefWholeWord];
    [ud setInteger:(NSInteger)[self sheetMode] forKey:kDefSearchMode];
}

// Returns nil (and complains) when the sheet does not describe a runnable search.
- (NSURL *)validatedDirectory {
    NSString *path = _dirCombo.stringValue.stringByExpandingTildeInPath;
    BOOL isDir = NO;
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        NSBeep();
        [self.context contextReportStatus:@"Find in Files: the directory doesn't exist." isError:YES];
        [_sheet makeFirstResponder:_dirCombo];
        return nil;
    }
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

- (void)findAllInFiles:(id)sender {
    NSString *what = _findCombo.stringValue;
    if (!what.length) { NSBeep(); return; }
    NSURL *dir = [self validatedDirectory];
    if (!dir) return;
    NPPFIFHistoryAdd(kDefFindHistory, what);
    NPPFIFHistoryAdd(kDefDirHistory, dir.path);
    [self saveSheetDefaults];
    NSString *filters = _filtersCombo.stringValue;
    BOOL sub = _subFoldersBox.state == NSControlStateValueOn, hidden = _hiddenBox.state == NSControlStateValueOn;
    BOOL mc = _matchCaseBox.state == NSControlStateValueOn, ww = _wholeWordBox.state == NSControlStateValueOn;
    NPPSearchMode mode = [self sheetMode];
    [self closeSheetAfterSearch];
    [self runFindInFilesWithText:what directory:dir filtersText:filters recursive:sub hidden:hidden
                       matchCase:mc wholeWord:ww mode:mode];
}

- (void)replaceInFiles:(id)sender {
    NSString *what = _findCombo.stringValue;
    if (!what.length) { NSBeep(); return; }
    NSURL *dir = [self validatedDirectory];
    if (!dir) return;
    NSString *filters = _filtersCombo.stringValue.length ? _filtersCombo.stringValue : @"*.*";

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Are you sure?";
    alert.informativeText = [NSString stringWithFormat:
        @"Are you sure you want to replace all occurrences in:\n\n%@\n\nFor file type:\n\n%@\n\n"
        @"The files are modified on disk. This operation cannot be undone.", dir.path, filters];
    [alert addButtonWithTitle:@"Cancel"];               // default, like N++ (MB_DEFBUTTON2)
    [alert addButtonWithTitle:@"Replace in Files"];
    NSString *replacement = _replaceCombo.stringValue ?: @"";
    BOOL sub = _subFoldersBox.state == NSControlStateValueOn, hidden = _hiddenBox.state == NSControlStateValueOn;
    BOOL mc = _matchCaseBox.state == NSControlStateValueOn, ww = _wholeWordBox.state == NSControlStateValueOn;
    NPPSearchMode mode = [self sheetMode];
    __weak NPPFindInFiles *weakSelf = self;
    [alert beginSheetModalForWindow:_sheet completionHandler:^(NSModalResponse res) {
        if (res != NSAlertSecondButtonReturn) return;
        NPPFindInFiles *self2 = weakSelf;
        if (!self2) return;
        NPPFIFHistoryAdd(kDefFindHistory, what);
        NPPFIFHistoryAdd(kDefReplaceHistory, replacement);
        NPPFIFHistoryAdd(kDefDirHistory, dir.path);
        [self2 saveSheetDefaults];
        [self2 closeSheetAfterSearch];
        [self2 runReplaceInFilesWithText:what replacement:replacement directory:dir filtersText:filters
                               recursive:sub hidden:hidden matchCase:mc wholeWord:ww mode:mode];
    }];
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    switch (cmd) {
        case NPPCmdSearchFindInFiles:
        case NPPCmdSearchFindAllInCurrent:
        case NPPCmdSearchFindAllInOpened:
        case NPPCmdSearchResultsPanel:
        case NPPCmdSearchResultsClear:
        case NPPCmdSearchResultsNext:
        case NPPCmdSearchResultsPrevious:
        case NPPCmdSearchResultsCopy:
        case NPPCmdSearchResultsCollapseAll:
        case NPPCmdSearchResultsExpandAll:
            return YES;
        default:
            return NO;
    }
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPFindInFiles *s = [self shared];
    switch (cmd) {
        case NPPCmdSearchFindInFiles:
        case NPPCmdSearchResultsPanel:
            return context != nil;
        case NPPCmdSearchFindAllInCurrent:
            return [context contextCurrentDocument] != nil;
        case NPPCmdSearchFindAllInOpened:
            return [context contextOpenDocuments].count > 0;
        case NPPCmdSearchResultsClear:
        case NPPCmdSearchResultsNext:
        case NPPCmdSearchResultsPrevious:
        case NPPCmdSearchResultsCopy:
        case NPPCmdSearchResultsCollapseAll:
        case NPPCmdSearchResultsExpandAll:
            return s.hasResults;
        default:
            return NO;
    }
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd == NPPCmdSearchResultsPanel) return [context contextPanelIsVisible:[self shared]];
    return NO;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPFindInFiles *s = [self shared];
    s.context = context;
    switch (cmd) {
        case NPPCmdSearchFindInFiles:      [s showFindInFilesSheetWithContext:context]; return YES;
        case NPPCmdSearchFindAllInCurrent: [s findAllInDocuments:@"Current Document" context:context]; return YES;
        case NPPCmdSearchFindAllInOpened:  [s findAllInDocuments:@"All Opened Documents" context:context]; return YES;
        case NPPCmdSearchResultsPanel:     [context contextTogglePanel:s]; return YES;
        case NPPCmdSearchResultsClear:     [s clearAllResults]; return YES;
        case NPPCmdSearchResultsNext:      [s goToNextResult:YES]; return YES;
        case NPPCmdSearchResultsPrevious:  [s goToNextResult:NO]; return YES;
        case NPPCmdSearchResultsCopy:      [s copyResults]; return YES;
        case NPPCmdSearchResultsCollapseAll: [s foldAllResults:YES]; return YES;
        case NPPCmdSearchResultsExpandAll: [s foldAllResults:NO]; return YES;
        default: return NO;
    }
}

// Search > Find All in Current Document / in All Opened Documents.
// The open Find panel wins: a user looking at a regex they just typed means that regex, and deriving the text from
// the caret instead made a pattern impossible to list at all. With the panel closed the selection, then the word at
// the caret, then the panel's last text — N++'s "Find (Volatile)" convenience.
- (void)findAllInDocuments:(NSString *)scope context:(id<NPPCommandContext>)context {
    self.context = context;
    NPPDocument *cur = [context contextCurrentDocument];
    NPPFindPanelController *panel = NPPFindPanelController.shared;
    BOOL panelShowing = panel.isWindowLoaded && panel.window.isVisible;
    NSString *text = panelShowing ? panel.searchText : nil;
    if (!text.length) {
        text = cur.editor ? NPPSciSelectedString(cur.editor) : nil;
        if ([text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) text = nil;
        if (!text.length && cur.editor) text = NPPSciWordAtCaret(cur.editor);
    }
    if (!text.length) text = panel.searchText;
    if (!text.length) {
        NSBeep();
        [context contextReportStatus:@"Find All: no search text — select something or use Find first." isError:YES];
        return;
    }
    NPPFindPanelController *find = panel;
    NSArray<NPPDocument *> *docs = [scope isEqualToString:@"Current Document"]
                                 ? (cur ? @[cur] : @[]) : ([context contextOpenDocuments] ?: @[]);
    [self findAllIn:docs text:text matchCase:find.matchCase wholeWord:find.wholeWord mode:find.searchMode scope:scope];
}

#pragma mark - Self-checks (NPPSelfTest calls this on every registered command handler)

// The Preferences > Searching settings are split across this module and NPPFindPanelController; both are checked
// from here, because NPPSelfTest only probes registered command handlers and the Find panel is not one.
+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(NSString *, BOOL) = ^(NSString *what, BOOL ok) { if (!ok) [fails addObject:what]; };
    void (^expectStr)(NSString *, NSString *, NSString *) = ^(NSString *what, NSString *got, NSString *want) {
        if (![got isEqualToString:want]) [fails addObject:[NSString stringWithFormat:@"%@: got %@, want %@", what, got, want]];
    };
    void (^expectEq)(NSString *, long long, long long) = ^(NSString *what, long long got, long long want) {
        if (got != want) [fails addObject:[NSString stringWithFormat:@"%@: got %lld, want %lld", what, got, want]];
    };

    NPPPreferences *prefs = NPPPreferences.shared;
    NPPFindPanelController *find = NPPFindPanelController.shared;
    // Everything below writes preferences and Find-panel state; put the user's values back at the end.
    NSInteger oldInSel = prefs.inSelectionAutocheckThreshold, oldFill = prefs.fillFindWhatThreshold;
    BOOL oldMono = prefs.monospacedFontFindDlg, oldStop = prefs.replaceStopsWithoutFindingNext;
    BOOL oldOneEntry = prefs.finderShowOnlyOneEntryPerFoundLine, oldIgnoreOpened = prefs.findInFilesIgnoreOpenedFiles;
    BOOL oldInSelection = find.inSelection, oldMatchCase = find.matchCase, oldWholeWord = find.wholeWord;
    BOOL oldBackward = find.backwardDirection, oldWrap = find.wrapAround;
    NPPSearchMode oldMode = find.searchMode;
    NSString *oldSearch = find.searchText, *oldReplace = find.replaceText;
    // -replaceCurrentInEditor: below pushes its search/replace text into the persisted history; a self-test
    // must not leave "foo"/"X" in the user's Find and Replace drop-downs.
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSArray *oldFindHist = [ud arrayForKey:@"NPPFindHistory"], *oldReplHist = [ud arrayForKey:@"NPPReplaceHistory"];
    // The four Searching settings that live in NSUserDefaults rather than in NPPPreferences (see the keys at the
    // top of this file and of NPPFindPanelController.mm); "unset" is a distinct, meaningful state for each.
    // …plus every key the Find in Files sheet reads and writes, because the checks below build that sheet and
    // save its state. "Unset" is a distinct, meaningful state for each: restoring means removing it again.
    NSArray<NSString *> *rawKeys = @[@"NPPFillFindFieldWithSelected", @"NPPFillFindFieldSelectCaret",
                                     kDefFillDirFromActiveDoc, kDefFindDlgAlwaysVisible,
                                     kDefFinderWrapped, kDefFinderPurge,
                                     kDefFilters, kDefDirHistory, kDefSubFolders, kDefHiddenFolders,
                                     kDefMatchCase, kDefWholeWord, kDefSearchMode];
    NSMutableDictionary<NSString *, id> *oldRaw = [NSMutableDictionary new];
    for (NSString *k in rawKeys) oldRaw[k] = [ud objectForKey:k] ?: NSNull.null;
    void (^setRaw)(NSString *, BOOL) = ^(NSString *k, BOOL v) { [ud setBool:v forKey:k]; };

    NSWindow *host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    host.releasedWhenClosed = NO;
    NPPDocument *doc = [[NPPDocument alloc] initUntitled];
    ScintillaView *ed = doc.editor;
    if (ed) { ed.frame = NSMakeRect(0, 0, 400, 300); [host.contentView addSubview:ed]; }

    // ---- "Use a monospaced font in the Find dialog": every glyph the same width, or not. Measured on the
    // panel's real Find field (built, not shown), so a +dialogFont that honours the pref but never reaches a
    // control fails here too.
    NSDictionary *(^attrs)(NSFont *) = ^(NSFont *f) { return @{NSFontAttributeName: f}; };
    BOOL (^sameWidth)(NSFont *) = ^BOOL(NSFont *f) {
        return fabs([@"iiii" sizeWithAttributes:attrs(f)].width - [@"WWWW" sizeWithAttributes:attrs(f)].width) < 0.5;
    };
    // -buildWindow claims the panel's frame autosave name, which writes the default frame over whatever
    // position the user had remembered. ponytail: restoring the raw AppKit key is enough; if AppKit ever
    // renames it the restore quietly does nothing and the only cost is a reset Find-panel position.
    NSString *frameKey = @"NSWindow Frame NPPFindPanel";
    id oldPanelFrame = [ud objectForKey:frameKey];
    [find buildWindow];
    NSComboBox *findField = [find currentFindCombo];
    expect(@"monospacedFontFindDlg: the Find panel has no Find field to restyle", findField != nil);
    prefs.monospacedFontFindDlg = YES;
    [find applyDialogFont];
    NSFont *mono = findField.font;
    prefs.monospacedFontFindDlg = NO;
    [find applyDialogFont];
    NSFont *prop = findField.font;
    expect(@"monospacedFontFindDlg: the Find field has no font at all", mono != nil && prop != nil);
    if (mono && prop) {
        expect(@"monospacedFontFindDlg: the ON font is not fixed pitch", sameWidth(mono));
        expect(@"monospacedFontFindDlg: the OFF font is fixed pitch too, so the setting is invisible", !sameWidth(prop));
    }

    if (ed) {
        // ---- "Maximum characters auto-filled into Find from the selection" (FindReplaceDlg::setSearchText).
        NPPSciStr(ed, SCI_SETTEXT, 0, "aaaaaaaa bbb");
        NPPSci(ed, SCI_SETSEL, 0, 12);                       // whole line selected: 12 characters
        prefs.fillFindWhatThreshold = 100;
        expectStr(@"fillFindWhatThreshold: a selection under the limit does not reach the Find field",
                  [find selectionOrWordInEditor:ed], @"aaaaaaaa bbb");
        prefs.fillFindWhatThreshold = 4;
        expectStr(@"fillFindWhatThreshold: a selection over the limit is still used",
                  [find selectionOrWordInEditor:ed], @"bbb");   // falls back to the word at the caret

        // ---- "Fill Find field with selected text" and, under it, "Select word under caret when nothing is
        // selected" (FindReplaceDlg::setSearchTextWithSettings). Both default to on, like N++.
        prefs.fillFindWhatThreshold = 100;
        NPPSci(ed, SCI_SETSEL, 0, 12);                       // "aaaaaaaa bbb" selected
        setRaw(@"NPPFillFindFieldWithSelected", YES);
        setRaw(@"NPPFillFindFieldSelectCaret", YES);
        expectStr(@"fillFindFieldWithSelected: ON must put the selection in the Find field",
                  [find dialogFillTextInEditor:ed], @"aaaaaaaa bbb");
        setRaw(@"NPPFillFindFieldWithSelected", NO);
        expectStr(@"fillFindFieldWithSelected: OFF still fills the Find field from the selection",
                  [find dialogFillTextInEditor:ed], @"");
        // N++ fills these two commands through setSearchText(), which reads no setting: turning the checkboxes
        // off must not leave Select and Find Next / Find (Volatile) with nothing to search for.
        expectStr(@"fillFindFieldWithSelected: OFF also disabled Select and Find Next",
                  [find selectionOrWordInEditor:ed], @"aaaaaaaa bbb");
        setRaw(@"NPPFillFindFieldWithSelected", YES);
        NPPSci(ed, SCI_SETSEL, 5, 5);                        // caret inside "aaaaaaaa", nothing selected
        expectStr(@"fillFindFieldSelectCaret: ON must fall back to the word under the caret",
                  [find dialogFillTextInEditor:ed], @"aaaaaaaa");
        setRaw(@"NPPFillFindFieldSelectCaret", NO);
        expectStr(@"fillFindFieldSelectCaret: OFF still grabs the word under the caret",
                  [find dialogFillTextInEditor:ed], @"");
        expectStr(@"fillFindFieldSelectCaret: OFF also disabled Select and Find Next",
                  [find selectionOrWordInEditor:ed], @"aaaaaaaa");
        setRaw(@"NPPFillFindFieldSelectCaret", YES);

        // ---- "Minimum selection size that auto-checks In selection" (FindReplaceDlg WM_ACTIVATE).
        prefs.inSelectionAutocheckThreshold = 5;
        find.inSelection = NO;
        NPPSci(ed, SCI_SETSEL, 0, 12);
        [find autoCheckInSelectionForEditor:ed];
        expect(@"inSelectionAutocheckThreshold: a selection at/over the threshold does not tick In selection",
               find.inSelection);
        NPPSci(ed, SCI_SETSEL, 0, 2);
        [find autoCheckInSelectionForEditor:ed];
        expect(@"inSelectionAutocheckThreshold: a selection under the threshold leaves In selection ticked",
               !find.inSelection);
        prefs.inSelectionAutocheckThreshold = 0;              // 0 = the user owns the checkbox
        find.inSelection = YES;
        NPPSci(ed, SCI_SETSEL, 0, 0);
        [find autoCheckInSelectionForEditor:ed];
        expect(@"inSelectionAutocheckThreshold: 0 still lets the code change the checkbox", find.inSelection);

        // ---- "Replace: do not move to the following occurrence" (FindReplaceDlg::processReplace).
        find.searchText = @"foo"; find.replaceText = @"X";
        find.matchCase = NO; find.wholeWord = NO; find.inSelection = NO; find.backwardDirection = NO;
        find.wrapAround = NO; find.searchMode = NPPSearchModeNormal;
        prefs.replaceStopsWithoutFindingNext = NO;
        NPPSciStr(ed, SCI_SETTEXT, 0, "foo foo");
        NPPSci(ed, SCI_SETSEL, 0, 3);
        [find replaceCurrentInEditor:ed];
        expectEq(@"replaceStopsWithoutFindingNext: OFF must select the next occurrence (start)",
                 NPPSci(ed, SCI_GETSELECTIONSTART), 2);
        expectEq(@"replaceStopsWithoutFindingNext: OFF must select the next occurrence (end)",
                 NPPSci(ed, SCI_GETSELECTIONEND), 5);
        prefs.replaceStopsWithoutFindingNext = YES;
        NPPSciStr(ed, SCI_SETTEXT, 0, "foo foo");
        NPPSci(ed, SCI_SETSEL, 0, 3);
        [find replaceCurrentInEditor:ed];
        expectEq(@"replaceStopsWithoutFindingNext: ON must leave the caret after the replacement (start)",
                 NPPSci(ed, SCI_GETSELECTIONSTART), 1);
        expectEq(@"replaceStopsWithoutFindingNext: ON must leave the caret after the replacement (end)",
                 NPPSci(ed, SCI_GETSELECTIONEND), 1);

        // ---- "Find in Files: prefer the file on disk over the opened buffer".
        doc.fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                              stringByAppendingPathComponent:@"npp-fif-selfcheck.txt"]];
        NPPSciStr(ed, SCI_SETTEXT, 0, "unsaved edit");        // SCI_SETTEXT leaves the buffer modified
        expect(@"findInFilesIgnoreOpenedFiles: precondition — the edited buffer does not read as unsaved",
               doc.isDirty);
        NPPFindInFiles *fif = [self shared];
        NSMutableDictionary *snapDocs = [NSMutableDictionary new], *snapText = [NSMutableDictionary new];
        prefs.findInFilesIgnoreOpenedFiles = NO;
        [fif snapshotUnsavedBuffers:@[doc] intoDocs:snapDocs text:snapText];
        expectEq(@"findInFilesIgnoreOpenedFiles: OFF must search the unsaved buffer",
                 (long long)snapDocs.count, 1);
        expectStr(@"findInFilesIgnoreOpenedFiles: OFF snapshots the wrong text",
                  snapText.allValues.firstObject ?: @"", @"unsaved edit");
        [snapDocs removeAllObjects]; [snapText removeAllObjects];
        prefs.findInFilesIgnoreOpenedFiles = YES;
        [fif snapshotUnsavedBuffers:@[doc] intoDocs:snapDocs text:snapText];
        expectEq(@"findInFilesIgnoreOpenedFiles: ON still reads the opened buffer instead of the disk file",
                 (long long)snapDocs.count, 0);
        // Replace in Files reads the same setting: OFF it must not rewrite a file whose buffer is unsaved,
        // ON the user asked for the disk copy and it goes ahead.
        expectEq(@"findInFilesIgnoreOpenedFiles: ON still refuses to replace in the unsaved file on disk",
                 (long long)[fif pathsToLeaveAlone:@[doc]].count, 0);
        prefs.findInFilesIgnoreOpenedFiles = NO;
        expectEq(@"findInFilesIgnoreOpenedFiles: OFF must skip the unsaved file in Replace in Files",
                 (long long)[fif pathsToLeaveAlone:@[doc]].count, 1);
        doc.fileURL = nil;
    } else {
        [fails addObject:@"self-check: no editor, the Find-panel settings were not exercised"];
    }

    // ---- "Search Result window: show only one entry per found line" (Finder::foundLine).
    NPPFindInFiles *panel = [self shared];
    (void)[panel panelView];
    NSInteger (^resultLinesForHitLines)(NSArray<NSNumber *> *) = ^NSInteger(NSArray<NSNumber *> *lines) {
        [panel clearAllResults];
        NPPFIFFileHits *fh = [NPPFIFFileHits new];
        fh.url = [NSURL fileURLWithPath:@"/tmp/npp-fif-selfcheck.txt"];
        fh.displayPath = fh.url.path; fh.totalLines = 20; fh.hits = [NSMutableArray new];
        for (NSNumber *n in lines) {
            NPPFIFHit *hit = [NPPFIFHit new];
            hit.line = n.integerValue; hit.lineText = @"aa foo bb foo";
            hit.startByte = 3; hit.endByte = 6;
            [fh.hits addObject:hit];
        }
        [panel appendFileHits:fh];
        return (NSInteger)panel->_lineInfos.count - 1;        // minus the file header row
    };
    NSArray<NSNumber *> *hitLines = @[@4, @4, @9];            // two hits on line 4, one on line 9
    prefs.finderShowOnlyOneEntryPerFoundLine = NO;
    expectEq(@"finderShowOnlyOneEntryPerFoundLine: OFF must keep one entry per hit",
             resultLinesForHitLines(hitLines), 3);
    prefs.finderShowOnlyOneEntryPerFoundLine = YES;
    expectEq(@"finderShowOnlyOneEntryPerFoundLine: ON must collapse the repeated line",
             resultLinesForHitLines(hitLines), 2);
    expect(@"finderShowOnlyOneEntryPerFoundLine: the collapsed hit loses its highlight",
           panel->_markings.size() >= 2 && panel->_markings[1]._segmentPostions.size() == 2);
    [panel clearAllResults];

    // ---- The results panel's context menu (Finder's WM_CONTEXTMENU, FindReplaceDlg.cpp:6248).
    // A section holding two files, so every "Selected …" item can be aimed at a row and checked:
    //   0 Search "foo"   1 file A   2 Line 4   3 Line 9   4 file B   5 Line 2
    prefs.finderShowOnlyOneEntryPerFoundLine = NO;
    [ud setBool:NO forKey:kDefFinderPurge];
    NSURL *fileA = [NSURL fileURLWithPath:@"/tmp/npp-fif-a.txt"], *fileB = [NSURL fileURLWithPath:@"/tmp/npp-fif-b.txt"];
    void (^addFile)(NSURL *, NSArray<NSNumber *> *) = ^(NSURL *url, NSArray<NSNumber *> *hitLines2) {
        NPPFIFFileHits *fh = [NPPFIFFileHits new];
        fh.url = url; fh.displayPath = url.path ?: @"new 1"; fh.totalLines = 20; fh.hits = [NSMutableArray new];
        for (NSNumber *n in hitLines2) {
            NPPFIFHit *hit = [NPPFIFHit new];
            hit.line = n.integerValue;
            hit.lineText = [NSString stringWithFormat:@"hit at %@", n];
            hit.startByte = 0; hit.endByte = 3;
            [fh.hits addObject:hit];
        }
        [panel appendFileHits:fh];
    };
    (void)[panel beginSectionForText:@"foo"];
    addFile(fileA, @[@4, @9]);
    addFile(fileB, @[@2]);
    ScintillaView *rv = panel->_results;
    expectEq(@"context menu: the six-row fixture was not built", (long long)panel->_lineInfos.count, 6);

    // Every item must resolve, and the ⚙ menu must offer exactly what the right-click menu offers.
    expect(@"the results view has no context menu at all", rv.menu.itemArray.count > 0);
    for (NSMenuItem *it in rv.menu.itemArray) {
        if (it.isSeparatorItem) continue;
        if (!it.target || ![it.target respondsToSelector:it.action])
            [fails addObject:[NSString stringWithFormat:@"results context menu: \"%@\" is wired to nothing", it.title]];
    }
    expectEq(@"the ⚙ menu and the context menu no longer offer the same items",
             (long long)[panel panelActionMenu].itemArray.count, (long long)rv.menu.itemArray.count);

    // N++ Finder::copy() / getResultFilePaths(): a caret on a grouping row stands for the rows under it.
    NPPSci(rv, SCI_GOTOLINE, 0);
    expectEq(@"context menu: a caret on the \"Search …\" row must cover its whole section",
             (long long)[panel selectedResultLineRange].length, 6);
    NPPSci(rv, SCI_GOTOLINE, 1);
    NSRange fileRange = [panel selectedResultLineRange];
    expectEq(@"context menu: a caret on a file row must cover that file's hits", (long long)fileRange.length, 3);
    expectEq(@"context menu: a caret on a file row starts on the wrong row", (long long)fileRange.location, 1);
    NPPSci(rv, SCI_GOTOLINE, 3);
    expectEq(@"context menu: a caret on a hit row must cover that row alone",
             (long long)[panel selectedResultLineRange].length, 1);

    NPPSci(rv, SCI_GOTOLINE, 1);
    NSArray<NSURL *> *selPaths = [panel resultFileURLsInSelection:YES];
    expectEq(@"Copy/Open Selected Pathname(s): a file row must name exactly one file", (long long)selPaths.count, 1);
    expectStr(@"Copy/Open Selected Pathname(s): the wrong file", selPaths.firstObject.path ?: @"", fileA.path);
    expectEq(@"Find in these search results: the panel must name each of its files once",
             (long long)[panel resultFileURLsInSelection:NO].count, 2);

    expectStr(@"Copy Selected Line(s): a file row must copy its hits without the \"Line N: \" prefix",
              [panel textOfSelectedResultLines], @"hit at 4\nhit at 9\n");
    NPPSci(rv, SCI_GOTOLINE, 5);
    expectStr(@"Copy Selected Line(s): a single hit row copies the wrong text",
              [panel textOfSelectedResultLines], @"hit at 2\n");
    NPPSci(rv, SCI_GOTOLINE, 1);
    expectStr(@"Copy Selected Line(s): a file row must not copy the file row itself",
              [panel textOfSelectedResultLines], @"hit at 4\nhit at 9\n");

    // ---- The Delete key prunes the results (N++ Finder::deleteResult, VK_DELETE in Finder's run_dlgProc).
    // The gesture is the whole point, so the check goes through the key binding, not through the method.
    BOOL hadMonitor = panel->_eventMonitor != nil;
    [panel panelDidBecomeVisible];
    expect(@"Delete/Return: the results panel installs no key monitor, so neither key ever reaches it",
           panel->_eventMonitor != nil);
    if (!hadMonitor) [panel panelWillHide];
    NSEvent *(^keyDown)(unsigned short) = ^NSEvent *(unsigned short code) {
        return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                            windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@""
                                 isARepeat:NO keyCode:code];
    };
    expect(@"Delete: an unrelated key is swallowed by the results panel", ![panel performResultsKeyEvent:keyDown(0)]);
    NPPSci(rv, SCI_GOTOLINE, 3);                             // file A's second hit
    expect(@"Delete: ⌫ in the search results is bound to nothing", [panel performResultsKeyEvent:keyDown(51)]);
    expectEq(@"Delete: ⌫ on a hit row must remove exactly that row", (long long)panel->_lineInfos.count, 5);
    expectEq(@"Delete: the markings no longer line up with the rows", (long long)panel->_markings.size(), 5);
    NPPSci(rv, SCI_GOTOLINE, 1);
    expectStr(@"Delete: ⌫ removed the wrong row", [panel textOfSelectedResultLines], @"hit at 4\n");
    expect(@"Delete: ⌦ in the search results is bound to nothing", [panel performResultsKeyEvent:keyDown(117)]);
    expectEq(@"Delete: on a file row it must take the file and its hits", (long long)panel->_lineInfos.count, 3);
    expectEq(@"Delete: the wrong file was pruned", (long long)[panel resultFileURLsInSelection:NO].count, 1);
    expectStr(@"Delete: the file left behind is the one that should have gone",
              [panel resultFileURLsInSelection:NO].firstObject.path ?: @"", fileB.path);
    NPPSci(rv, SCI_GOTOLINE, 0);
    (void)[panel performResultsKeyEvent:keyDown(51)];
    expect(@"Delete: on a \"Search …\" row it must take the whole section", !panel.hasResults);
    // Rebuild the fixture the checks below share.
    (void)[panel beginSectionForText:@"foo"];
    addFile(fileA, @[@4, @9]);
    addFile(fileB, @[@2]);

    // ---- "Search only in found lines" (FindInFinderDlg, Finder::canFind).
    NSIndexSet *foundInA = [panel foundLinesByPath][NPPFIFPathKey(fileA)];
    expect(@"searchOnlyInFoundLines: the panel's own hit lines are not collected",
           foundInA.count == 2 && [foundInA containsIndex:4] && [foundInA containsIndex:9]);
    NSMutableArray<NPPFIFHit *> *probe = [NSMutableArray new];
    for (NSInteger ln : {4, 5, 9}) { NPPFIFHit *h = [NPPFIFHit new]; h.line = ln; [probe addObject:h]; }
    expectEq(@"searchOnlyInFoundLines: a hit on a line that was not in the results is kept",
             (long long)[self hits:probe onLines:foundInA].count, 2);
    expectEq(@"searchOnlyInFoundLines: a file that was not in the results keeps its hits",
             (long long)[self hits:probe onLines:[panel foundLinesByPath][@"/tmp/npp-fif-never.txt"]].count, 0);

    // ---- "Purge for every search" (Finder::purgeToggle, removeAll() before every search).
    NSInteger linesBeforeNewSearch = (NSInteger)panel->_lineInfos.count;
    (void)[panel beginSectionForText:@"bar"];
    expectEq(@"purgeBeforeEverySearch: OFF must keep the previous search's results",
             (long long)panel->_lineInfos.count, linesBeforeNewSearch + 1);
    [ud setBool:YES forKey:kDefFinderPurge];
    (void)[panel beginSectionForText:@"bar"];
    expectEq(@"purgeBeforeEverySearch: ON must leave only the new search's header row",
             (long long)panel->_lineInfos.count, 1);

    // "Find in these search results…" needs a file to search: live with results, dead with an empty panel.
    NSMenuItem *findInResults = nil;
    for (NSMenuItem *it in rv.menu.itemArray)
        if (it.action == @selector(menuFindInResults:)) findInResults = it;
    expect(@"context menu: \"Find in these search results…\" is missing", findInResults != nil);
    [panel clearAllResults];
    expect(@"context menu: \"Find in these search results…\" stays live over an empty panel",
           findInResults && ![panel validateMenuItem:findInResults]);
    // Hits in an unsaved untitled buffer fill the panel but name no file to search again.
    (void)[panel beginSectionForText:@"foo"];
    addFile(nil, @[@1]);
    expect(@"context menu: results the fixture could not build", panel.hasResults);
    expect(@"context menu: \"Find in these search results…\" is live although no result names a file on disk",
           findInResults && ![panel validateMenuItem:findInResults]);
    [panel clearAllResults];
    (void)[panel beginSectionForText:@"foo"];
    addFile(fileA, @[@4]);
    expect(@"context menu: \"Find in these search results…\" is dead although the panel names a file",
           findInResults && [panel validateMenuItem:findInResults]);

    // A right-click has to land on the row under the pointer, so the window point -> Scintilla position
    // conversion must round-trip. Mixing the two views up (ScintillaView is not flipped, its content view is)
    // silently mirrors the y and aims the menu at the wrong row.
    NPPSci(rv, SCI_COLOURISE, 0, -1);
    sptr_t rowStart = NPPSci(rv, SCI_POSITIONFROMLINE, 2);
    NSRect visible = rv.scrollView.contentView.bounds;
    NSPoint inContent = NSMakePoint(NPPSci(rv, SCI_POINTXFROMPOSITION, 0, rowStart) + NSMinX(visible) + 2,
                                    NPPSci(rv, SCI_POINTYFROMPOSITION, 0, rowStart) + NSMinY(visible) + 2);
    NSPoint inWindow = [(NSView *)rv.content convertPoint:inContent toView:nil];
    expectEq(@"context menu: a click on a row does not land on that row",
             (long long)NPPSci(rv, SCI_LINEFROMPOSITION, (uptr_t)[panel resultsPositionAtWindowPoint:inWindow]), 2);

    // ---- "Word wrap long lines" (Finder::wrapLongLinesToggle) — remembered like N++'s FinderConfig.
    [panel setLongLinesWrapped:YES];
    expect(@"wrapLongLines: ON does not wrap the results view", NPPSci(rv, SCI_GETWRAPMODE) != SC_WRAP_NONE);
    expect(@"wrapLongLines: ON is not remembered", [NPPFindInFiles longLinesAreWrapped]);
    [panel setLongLinesWrapped:NO];
    expect(@"wrapLongLines: OFF still wraps the results view", NPPSci(rv, SCI_GETWRAPMODE) == SC_WRAP_NONE);
    expect(@"wrapLongLines: OFF is still remembered as ON", ![NPPFindInFiles longLinesAreWrapped]);

    [panel clearAllResults];

    // ---- "Fill Find in Files Directory field based on the active document" (setFindReplaceFolderFilter).
    NSString *docFolder = @"/tmp/npp-fif-doc", *lastUsed = @"/tmp/npp-fif-last";
    setRaw(kDefFillDirFromActiveDoc, NO);
    expectStr(@"fillDirFieldFromActiveDoc: OFF must keep the directory of the last search",
              [self directoryForDocumentFolder:docFolder lastUsed:lastUsed], lastUsed);
    setRaw(kDefFillDirFromActiveDoc, YES);
    expectStr(@"fillDirFieldFromActiveDoc: ON must follow the active document",
              [self directoryForDocumentFolder:docFolder lastUsed:lastUsed], docFolder);
    expectStr(@"fillDirFieldFromActiveDoc: ON with an unsaved document must keep the last search's directory",
              [self directoryForDocumentFolder:nil lastUsed:lastUsed], lastUsed);
    expectStr(@"fillDirFieldFromActiveDoc: nothing to fall back on must still give a real directory",
              [self directoryForDocumentFolder:nil lastUsed:nil], NSHomeDirectory());

    // ---- The Find in Files sheet's Directory and Filters drop-downs (IDD_FINDINFILES_DIR_COMBO / _FILTERS_COMBO).
    // Both histories are persisted and cleared from Preferences > Searching, which buys the user nothing unless
    // the sheet actually hangs them off an arrow — so the check reads the items out of the built controls.
    [ud setObject:@[@"/tmp/npp-fif-last", @"/tmp/npp-fif-older"] forKey:kDefDirHistory];
    [ud setObject:@[@"*.cpp *.h", @"*.txt"] forKey:kDefFilters];
    setRaw(kDefFillDirFromActiveDoc, NO);
    [panel buildSheet];
    [panel loadSheetDefaults];
    expectEq(@"Find in Files: the Directory field offers no history to pick from",
             (long long)panel->_dirCombo.numberOfItems, 2);
    expectEq(@"Find in Files: the Filters field offers no history to pick from",
             (long long)panel->_filtersCombo.numberOfItems, 2);
    expectStr(@"Find in Files: the Directory drop-down does not list the last directory searched",
              panel->_dirCombo.objectValues.firstObject ?: @"", @"/tmp/npp-fif-last");
    expectStr(@"Find in Files: the Directory field does not reopen on the last directory searched",
              panel->_dirCombo.stringValue, @"/tmp/npp-fif-last");
    expectStr(@"Find in Files: the Filters field does not reopen on the last filter used",
              panel->_filtersCombo.stringValue, @"*.cpp *.h");
    panel->_filtersCombo.stringValue = @"*.mm";
    [panel saveSheetDefaults];
    [panel loadSheetDefaults];
    expectStr(@"Find in Files: a filter that was used does not reach the drop-down",
              panel->_filtersCombo.objectValues.firstObject ?: @"", @"*.mm");
    expectEq(@"Find in Files: adding a filter to the history dropped one", (long long)panel->_filtersCombo.numberOfItems, 3);
    // Builds before the drop-down kept one string under that key; it has to read back as a one-entry history.
    [ud setObject:@"*.log" forKey:kDefFilters];
    [panel loadSheetDefaults];
    expectStr(@"Find in Files: the filter an older build saved is lost", panel->_filtersCombo.stringValue, @"*.log");

    // ---- "Find dialog remains open after a search that outputs to the results window" (Notepad_plus::findInFiles).
    [ud removeObjectForKey:kDefFindDlgAlwaysVisible];
    expect(@"findDlgAlwaysVisible: unset must behave like N++'s default and close the Find in Files sheet",
           [self shouldCloseSheetAfterSearch]);
    setRaw(kDefFindDlgAlwaysVisible, YES);
    expect(@"findDlgAlwaysVisible: ON still closes the Find in Files sheet after the search",
           ![self shouldCloseSheetAfterSearch]);

    for (NSString *k in rawKeys) {
        id v = oldRaw[k];
        v == NSNull.null ? [ud removeObjectForKey:k] : [ud setObject:v forKey:k];
    }
    prefs.inSelectionAutocheckThreshold = oldInSel; prefs.fillFindWhatThreshold = oldFill;
    prefs.monospacedFontFindDlg = oldMono; prefs.replaceStopsWithoutFindingNext = oldStop;
    prefs.finderShowOnlyOneEntryPerFoundLine = oldOneEntry; prefs.findInFilesIgnoreOpenedFiles = oldIgnoreOpened;
    find.inSelection = oldInSelection; find.searchText = oldSearch; find.replaceText = oldReplace;
    find.matchCase = oldMatchCase; find.wholeWord = oldWholeWord; find.backwardDirection = oldBackward;
    find.wrapAround = oldWrap; find.searchMode = oldMode;
    oldFindHist ? [ud setObject:oldFindHist forKey:@"NPPFindHistory"] : [ud removeObjectForKey:@"NPPFindHistory"];
    oldReplHist ? [ud setObject:oldReplHist forKey:@"NPPReplaceHistory"] : [ud removeObjectForKey:@"NPPReplaceHistory"];
    oldPanelFrame ? [ud setObject:oldPanelFrame forKey:frameKey] : [ud removeObjectForKey:frameKey];
    [ed removeFromSuperview];
    return fails;
}

@end

// ---------------------------------------------------------------------------------------------------------------
// Self-check for the pure logic (filters, extended unescape, matching, replacing). Compiled out of the app; run with
//   clang++ ... -DNPP_FIF_SELFTEST NPPFindInFiles.mm NPPUtils.mm <stubs> && ./a.out
// ---------------------------------------------------------------------------------------------------------------
#ifdef NPP_FIF_SELFTEST
#include <cassert>

int NPPFindInFilesSelfTest(void);
int NPPFindInFilesSelfTest(void) {
    @autoreleasepool {
        // Globs, N++ style: "*.*" means "every file", matching is case-insensitive.
        assert(NPPFIFGlob(@"*.cpp", @"main.cpp"));
        assert(NPPFIFGlob(@"*.CPP", @"main.cpp"));
        assert(NPPFIFGlob(@"*.*", @"Makefile"));
        assert(!NPPFIFGlob(@"*.cpp", @"main.h"));

        NPPFIFFilters *f = [NPPFIFFilters filtersFromString:@"*.cpp *.h !test*.cpp !\\build !+\\log*"];
        assert([f matchesFileName:@"a.cpp"]);
        assert([f matchesFileName:@"a.h"]);
        assert(![f matchesFileName:@"a.txt"]);
        assert(![f matchesFileName:@"test_a.cpp"]);
        assert([f excludesDirectoryName:@"build" atLevel:1]);
        assert(![f excludesDirectoryName:@"build" atLevel:2]);
        assert([f excludesDirectoryName:@"logs" atLevel:3]);

        // All-exclusion filter lists still search everything else (N++ allPatternsAreExclusion).
        NPPFIFFilters *only = [NPPFIFFilters filtersFromString:@"!*.o"];
        assert([only matchesFileName:@"a.cpp"] && ![only matchesFileName:@"a.o"]);

        // Extended mode unescaping.
        assert([NPPFIFUnescape(@"a\\tb\\x41\\n") isEqualToString:@"a\tbA\n"]);
        assert([NPPFIFUnescape(@"c:\\\\dir") isEqualToString:@"c:\\dir"]);
        assert([NPPFIFUnescape(@"\\q") isEqualToString:@"\\q"]);

        // Normal mode, whole word + case.
        NPPFIFMatcher *m = [NPPFIFMatcher matcherForText:@"foo" matchCase:YES wholeWord:YES
                                                    mode:NPPSearchModeNormal error:NULL];
        NSArray<NSValue *> *r = [m rangesIn:@"foobar foo Foo" template:nil replacements:nil];
        assert(r.count == 1 && r[0].rangeValue.location == 7);
        m = [NPPFIFMatcher matcherForText:@"foo" matchCase:NO wholeWord:NO mode:NPPSearchModeNormal error:NULL];
        assert([m rangesIn:@"foobar foo Foo" template:nil replacements:nil].count == 3);

        // Byte offsets of a match after a non-ASCII prefix (what the searchResult lexer colourises).
        NSMutableArray<NPPFIFHit *> *hits = [NSMutableArray new];
        NSInteger lines = NPPFIFScanText(@"one\néé foo\nthree\n", m, hits);
        assert(lines == 3 && hits.count == 1);
        assert(hits[0].line == 2 && hits[0].startByte == 5 && hits[0].endByte == 8);

        // Scintilla line semantics: U+2028/U+2029/U+0085 are NOT line ends (Foundation's ByLines thinks they are),
        // and a NUL keeps its full byte length so the appended results line still carries its newline.
        hits = [NSMutableArray new];
        NSString *sep = [NSString stringWithFormat:@"a%Cb%Cc\r\nfoo\rx", (unichar)0x2028, (unichar)0x0085];
        assert(NPPFIFScanText(sep, m, hits) == 3);   // ByLines would put "foo" on line 4
        assert(hits.count == 1 && hits[0].line == 2);
        const char nulLine[] = {'a', 0, 'b', '\n'};
        NSString *withNul = [[NSString alloc] initWithBytes:nulLine length:sizeof(nulLine)
                                                   encoding:NSUTF8StringEncoding];
        assert(strlen(withNul.UTF8String) == 1 &&
               [withNul lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == sizeof(nulLine));

        // Regex with groups, replaced through the whole text with the original EOLs kept.
        NPPFIFMatcher *re = [NPPFIFMatcher matcherForText:@"(a+)b" matchCase:YES wholeWord:NO
                                                     mode:NPPSearchModeRegex error:NULL];
        NSInteger n = 0;
        NSString *out = NPPFIFReplaceInText(@"aab x\r\naaab\n", re, NPPFIFRegexTemplate(@"[\\1]"), &n);
        assert(n == 2);
        assert([out isEqualToString:@"[aa] x\r\n[aaa]\n"]);

        // Patterns spanning a line break match (the whole text is searched, not each line on its own); the hit is
        // reported on the line it starts on and highlighted up to that line's end. ^ and $ still mean line ends.
        NPPFIFMatcher *multi = [NPPFIFMatcher matcherForText:@"};\\n\\nclass" matchCase:YES wholeWord:NO
                                                       mode:NPPSearchModeExtended error:NULL];
        hits = [NSMutableArray new];
        assert(NPPFIFScanText(@"};\n\nclass Foo {\n", multi, hits) == 3);
        assert(hits.count == 1 && hits[0].line == 1 && hits[0].startByte == 0 && hits[0].endByte == 2);
        NPPFIFMatcher *anchored = [NPPFIFMatcher matcherForText:@"^foo$" matchCase:YES wholeWord:NO
                                                           mode:NPPSearchModeRegex error:NULL];
        hits = [NSMutableArray new];
        assert(NPPFIFScanText(@"x\nfoo\ny\n", anchored, hits) == 3 && hits.count == 1 && hits[0].line == 2);
        NSInteger nMulti = 0;
        assert([NPPFIFReplaceInText(@"a\nb\n", multi, @"", &nMulti) isEqualToString:@"a\nb\n"] && nMulti == 0);
        NPPFIFMatcher *ab = [NPPFIFMatcher matcherForText:@"a\\nb" matchCase:YES wholeWord:NO
                                                     mode:NPPSearchModeExtended error:NULL];
        assert([NPPFIFReplaceInText(@"a\nb\n", ab, @"ab", &nMulti) isEqualToString:@"ab\n"] && nMulti == 1);

        // An invalid regular expression is reported, not crashed on.
        NSString *err = nil;
        assert([NPPFIFMatcher matcherForText:@"(" matchCase:NO wholeWord:NO mode:NPPSearchModeRegex error:&err] == nil);
        assert(err.length > 0);
    }
    printf("NPPFindInFiles self-test ok\n");
    return 0;
}

int main(void) { return NPPFindInFilesSelfTest(); }
#endif
