#import "NPPUtils.h"

long NPPColorFromHex(NSString *hex) {
    if (hex.length < 6) return -1;
    unsigned int rgb = 0;
    NSScanner *sc = [NSScanner scannerWithString:[hex substringToIndex:6]];
    if (![sc scanHexInt:&rgb]) return -1;
    unsigned r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
    return (long)(r | (g << 8) | (b << 16));
}

NSColor *NPPNSColorFromSci(long c) {
    if (c < 0) return nil;
    return [NSColor colorWithSRGBRed:((c) & 0xFF) / 255.0 green:((c >> 8) & 0xFF) / 255.0 blue:((c >> 16) & 0xFF) / 255.0 alpha:1.0];
}

long NPPSciColorFromNSColor(NSColor *color) {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!c) return -1;
    int r = (int)lround(c.redComponent * 255), g = (int)lround(c.greenComponent * 255), b = (int)lround(c.blueComponent * 255);
    return (long)(r | (g << 8) | (b << 16));
}

std::string NPPSciGetText(ScintillaView *ed) {
    sptr_t len = NPPSci(ed, SCI_GETLENGTH);
    std::string s((size_t)len, '\0');
    if (len > 0) NPPSci(ed, SCI_GETTEXT, (uptr_t)len, (sptr_t)s.data());
    return s;
}

std::string NPPSciGetRange(ScintillaView *ed, sptr_t start, sptr_t end) {
    if (end < start) std::swap(start, end);
    sptr_t docLen = NPPSci(ed, SCI_GETLENGTH);
    if (start < 0) start = 0;
    if (end > docLen) end = docLen;
    std::string s((size_t)(end - start), '\0');
    if (end > start) {
        Sci_TextRangeFull tr{{start, end}, s.data()};
        NPPSci(ed, SCI_GETTEXTRANGEFULL, 0, (sptr_t)&tr);
    }
    return s;
}

NSString *NPPSciSelectedString(ScintillaView *ed) {
    sptr_t a = NPPSci(ed, SCI_GETSELECTIONSTART), b = NPPSci(ed, SCI_GETSELECTIONEND);
    std::string s = NPPSciGetRange(ed, a, b);
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *NPPSciWordAtCaret(ScintillaView *ed) {
    sptr_t pos = NPPSci(ed, SCI_GETCURRENTPOS);
    sptr_t a = NPPSci(ed, SCI_WORDSTARTPOSITION, (uptr_t)pos, 1), b = NPPSci(ed, SCI_WORDENDPOSITION, (uptr_t)pos, 1);
    std::string s = NPPSciGetRange(ed, a, b);
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *NPPFormatGroupedInteger(long long n) {
    static NSNumberFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSNumberFormatter new]; f.numberStyle = NSNumberFormatterDecimalStyle; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"]; });
    return [f stringFromNumber:@(n)];
}

BOOL NPPFontIsAvailable(NSString *fontName) {
    if (fontName.length == 0) return NO;
    NSFont *f = [NSFont fontWithName:fontName size:12];
    return f != nil && [f.fontName caseInsensitiveCompare:fontName] == NSOrderedSame ? YES : (f != nil && [f.familyName caseInsensitiveCompare:fontName] == NSOrderedSame);
}

NSString *NPPDefaultMonospaceFontName(void) { return @"Menlo"; }

void NPPRemoveScintillaForwarder(ScintillaView *view, id<NPPScintillaForwarder> forwarder) {
    if (!view || !forwarder) return;
    id<ScintillaNotificationProtocol> next = forwarder.previousDelegate;
    if (view.delegate == forwarder) { view.delegate = next; return; }
    // Somewhere below the top: find whoever points at us and let it point past us instead.
    id cur = view.delegate;
    while ([cur conformsToProtocol:@protocol(NPPScintillaForwarder)]) {
        id<NPPScintillaForwarder> f = (id<NPPScintillaForwarder>)cur;
        if (f.previousDelegate == forwarder) { f.previousDelegate = next; return; }
        cur = f.previousDelegate;
    }
}

NSString *NPPUpstreamPath(NSString *subpath) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if (const char *env = getenv("NPP")) [roots addObject:@(env)];
    // The Makefile's own default: a clone sitting next to this project. From build/Notepad++ that is ../..,
    // from dist/Notepad++.app/Contents/MacOS it is five levels up; try both rather than guess which build it is.
    NSString *exe = NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
    for (int up = 2; up <= 6 && exe.length; up++) {
        NSString *dir = exe;
        for (int i = 0; i < up; i++) dir = dir.stringByDeletingLastPathComponent;
        [roots addObject:[dir stringByAppendingPathComponent:@"notepad-plus-plus"]];
    }
    for (NSString *root in roots) {
        NSString *path = subpath.length ? [root stringByAppendingPathComponent:subpath] : root;
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}
