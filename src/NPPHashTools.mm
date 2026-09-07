// NPPHashTools.mm — see header.
#import "NPPHashTools.h"
#import "NPPDocument.h"
#import "NPPUtils.h"
#import <CommonCrypto/CommonDigest.h>

// ---- defaults key --------------------------------------------------------------------------------------------
static NSString *const kPerLine = @"NPPHashToolsPerLine";      // N++'s "Treat each line as a separate string"
// The typed text is remembered in an ivar for the session only and deliberately NOT in the defaults: people hash
// passwords and licence keys in this box, and NSUserDefaults is a plaintext plist in the user's home. N++ keeps it
// in its never-destroyed dialog, which dies with the process too.

static const NSInteger kHashActions = 3;                        // generate / from files / selection to clipboard
static const NSInteger kHashCommandCount = 4 * kHashActions;    // 4 algorithms
static const NSUInteger kFileChunk = 1u << 20;                  // 1 MiB per read: a DVD image never has to fit in RAM

// ---- digest engine -------------------------------------------------------------------------------------------
// One context for all four algorithms. CC_MD5_* and CC_SHA1_* (and their context types) are deprecated because
// they are broken *as signatures*; N++ offers them for checksums and users still need them to verify downloads,
// so keep them and silence the warning here rather than project-wide.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct {
    NPPHashAlgorithm algo;
    union {
        CC_MD5_CTX md5;
        CC_SHA1_CTX sha1;
        CC_SHA256_CTX sha256;
        CC_SHA512_CTX sha512;
    } ctx;
} NPPHashState;

static NSUInteger NPPDigestLength(NPPHashAlgorithm algo) {
    switch (algo) {
        case NPPHashMD5:    return CC_MD5_DIGEST_LENGTH;
        case NPPHashSHA1:   return CC_SHA1_DIGEST_LENGTH;
        case NPPHashSHA256: return CC_SHA256_DIGEST_LENGTH;
        case NPPHashSHA512: return CC_SHA512_DIGEST_LENGTH;
    }
    return 0;
}

static void NPPHashInit(NPPHashState *s, NPPHashAlgorithm algo) {
    s->algo = algo;
    switch (algo) {
        case NPPHashMD5:    CC_MD5_Init(&s->ctx.md5); break;
        case NPPHashSHA1:   CC_SHA1_Init(&s->ctx.sha1); break;
        case NPPHashSHA256: CC_SHA256_Init(&s->ctx.sha256); break;
        case NPPHashSHA512: CC_SHA512_Init(&s->ctx.sha512); break;
    }
}

// CC_LONG is 32-bit, so a single >4 GiB buffer has to be fed in slices.
static void NPPHashUpdate(NPPHashState *s, const void *bytes, size_t length) {
    const uint8_t *p = (const uint8_t *)bytes;
    while (length > 0) {
        CC_LONG n = (CC_LONG)MIN(length, (size_t)(1u << 30));
        switch (s->algo) {
            case NPPHashMD5:    CC_MD5_Update(&s->ctx.md5, p, n); break;
            case NPPHashSHA1:   CC_SHA1_Update(&s->ctx.sha1, p, n); break;
            case NPPHashSHA256: CC_SHA256_Update(&s->ctx.sha256, p, n); break;
            case NPPHashSHA512: CC_SHA512_Update(&s->ctx.sha512, p, n); break;
        }
        p += n;
        length -= n;
    }
}

static void NPPHashFinal(NPPHashState *s, unsigned char *out) {   // out must hold NPPDigestLength(algo) bytes
    switch (s->algo) {
        case NPPHashMD5:    CC_MD5_Final(out, &s->ctx.md5); break;
        case NPPHashSHA1:   CC_SHA1_Final(out, &s->ctx.sha1); break;
        case NPPHashSHA256: CC_SHA256_Final(out, &s->ctx.sha256); break;
        case NPPHashSHA512: CC_SHA512_Final(out, &s->ctx.sha512); break;
    }
}

#pragma clang diagnostic pop

static NSString *NPPHexString(const unsigned char *bytes, NSUInteger length) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (NSUInteger i = 0; i < length; ++i) [hex appendFormat:@"%02x", bytes[i]];   // lowercase, like N++
    return hex;
}

static void NPPHashCopyToClipboard(NSString *text) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:text ?: @"" forType:NSPasteboardTypeString];
}

// ---- command tag <-> (algorithm, action) ---------------------------------------------------------------------
static BOOL NPPHashDecodeCommand(NPPCmd cmd, NPPHashAlgorithm *outAlgo, NSInteger *outAction) {
    NSInteger offset = (NSInteger)cmd - (NSInteger)NPPCmdToolHashBase;
    if (offset < 0 || offset >= kHashCommandCount) return NO;
    if (outAlgo) *outAlgo = (NPPHashAlgorithm)(offset / kHashActions);
    if (outAction) *outAction = offset % kHashActions;
    return YES;
}

@interface NPPHashTools () <NSTextViewDelegate>
@end

@implementation NPPHashTools {
    // Only one hash sheet at a time: the sheet is document-modal but the menu item stays enabled behind it.
    NSWindow *_sheet;
    NSTextView *_inputView, *_resultView;
    NSButton *_perLineCheck;
    NPPHashAlgorithm _algo;
    NSString *_lastText;          // survives closing the sheet, dies with the process — see the note on kPerLine
}

+ (instancetype)shared {
    static NPPHashTools *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPHashTools alloc] init]; });
    return s;
}

#pragma mark - Digests

+ (NSString *)displayNameForAlgorithm:(NPPHashAlgorithm)algo {
    switch (algo) {
        case NPPHashMD5:    return @"MD5";
        case NPPHashSHA1:   return @"SHA-1";
        case NPPHashSHA256: return @"SHA-256";
        case NPPHashSHA512: return @"SHA-512";
    }
    return @"";
}

+ (NSString *)hexDigestOfData:(NSData *)data algorithm:(NPPHashAlgorithm)algo {
    __block NPPHashState state;   // __block: the enumeration block must update it, not a const copy
    NPPHashInit(&state, algo);
    // enumerateByteRanges…: an NSData built from mapped/concatenated chunks need not be one contiguous buffer.
    [data enumerateByteRangesUsingBlock:^(const void *bytes, NSRange range, BOOL *stop) {
        NPPHashUpdate(&state, bytes, range.length);
    }];
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    NPPHashFinal(&state, digest);
    return NPPHexString(digest, NPPDigestLength(algo));
}

+ (NSString *)hexDigestOfString:(NSString *)text algorithm:(NPPHashAlgorithm)algo {
    // N++ converts the dialog's UTF-16 text to UTF-8 before hashing, so non-ASCII text agrees across platforms.
    return [self hexDigestOfData:([text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]) algorithm:algo];
}

+ (NSString *)hexDigestOfFileURL:(NSURL *)url algorithm:(NPPHashAlgorithm)algo {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    if (!fh) return nil;
    __block NPPHashState state;
    NPPHashInit(&state, algo);
    BOOL failed = NO;
    while (1) {
        @autoreleasepool {
            NSError *err = nil;
            NSData *chunk = [fh readDataUpToLength:kFileChunk error:&err];
            // A short read must never be mistaken for EOF: that would print a confident digest of half a file.
            if (!chunk || err) { failed = YES; break; }
            if (chunk.length == 0) break;
            [chunk enumerateByteRangesUsingBlock:^(const void *bytes, NSRange range, BOOL *stop) {
                NPPHashUpdate(&state, bytes, range.length);
            }];
        }
    }
    [fh closeFile];
    if (failed) return nil;
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    NPPHashFinal(&state, digest);
    return NPPHexString(digest, NPPDigestLength(algo));
}

// One digest per URL, in the same order: line N of the result belongs to line N of the file list, whatever happens.
// N++ instead drops an unreadable file from both lists; keeping the line is what makes "same order" checkable.
+ (NSArray<NSString *> *)hexDigestsOfFileURLs:(NSArray<NSURL *> *)urls algorithm:(NPPHashAlgorithm)algo {
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls)
        [out addObject:([self hexDigestOfFileURL:url algorithm:algo] ?: @"(unreadable)")];
    return out;
}

+ (NSString *)hexDigestPerLineOfString:(NSString *)text algorithm:(NPPHashAlgorithm)algo {
    NSMutableString *normalized = [(text ?: @"") mutableCopy];
    for (NSString *eol in @[@"\r\n", @"\r"])   // CRLF and old-Mac CR both count as one line break
        [normalized replaceOccurrencesOfString:eol withString:@"\n" options:NSLiteralSearch
                                         range:NSMakeRange(0, normalized.length)];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"])
        [out addObject:(line.length ? [self hexDigestOfString:line algorithm:algo] : @"")];   // blank line stays blank
    return [out componentsJoinedByString:@"\n"];
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd { return NPPHashDecodeCommand(cmd, NULL, NULL); }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NSInteger action = 0;
    if (!NPPHashDecodeCommand(cmd, NULL, &action)) return NO;
    if (action != 2) return [context contextWindow] != nil;   // both dialogs are sheets on the host window
    ScintillaView *ed = [context contextCurrentDocument].editor;
    if (!ed) return NO;
    // N++ hashes the selection only when there is exactly one, non-empty.
    return NPPSci(ed, SCI_GETSELECTIONS) == 1 &&
           NPPSci(ed, SCI_GETSELECTIONSTART) != NPPSci(ed, SCI_GETSELECTIONEND);
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPHashAlgorithm algo = NPPHashMD5;
    NSInteger action = 0;
    if (!NPPHashDecodeCommand(cmd, &algo, &action)) return NO;
    if (![self canPerformCommand:cmd context:context]) return NO;

    switch (action) {
        case 0: [[self shared] showTextSheetForAlgorithm:algo context:context]; return YES;
        case 1: [[self shared] chooseFilesForAlgorithm:algo context:context]; return YES;
        default: {
            // The raw selected bytes, not NPPSciSelectedString: that decodes UTF-8 and yields @"" on a byte the
            // decoder rejects, which would put the digest of the empty string on the clipboard without a word.
            // N++ hashes the SCI_GETSELTEXT bytes as they are, so this also matches it byte for byte.
            ScintillaView *ed = [context contextCurrentDocument].editor;
            std::string sel = NPPSciGetRange(ed, NPPSci(ed, SCI_GETSELECTIONSTART), NPPSci(ed, SCI_GETSELECTIONEND));
            NSString *digest = [self hexDigestOfData:[NSData dataWithBytes:sel.data() length:sel.size()]
                                           algorithm:algo];
            NPPHashCopyToClipboard(digest);
            [context contextReportStatus:[NSString stringWithFormat:@"%@ of selection copied: %@",
                                          [self displayNameForAlgorithm:algo], digest] isError:NO];
            return YES;
        }
    }
}

#pragma mark - Shared sheet pieces

// A bordered, monospaced text area; the text view is returned through `outTextView`.
static NSScrollView *NPPHashTextArea(NSRect frame, BOOL editable, NSTextView **outTextView) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    tv.minSize = NSMakeSize(0, 0);
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    tv.editable = editable;
    tv.selectable = YES;
    tv.richText = NO;
    // Substitutions would silently change the bytes being hashed ("--" -> em dash, straight -> curly quotes).
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tv.drawsBackground = YES;
    tv.backgroundColor = NSColor.textBackgroundColor;
    tv.textColor = NSColor.textColor;

    scroll.documentView = tv;
    if (outTextView) *outTextView = tv;
    return scroll;
}

static NSTextField *NPPHashLabel(NSString *title, NSRect frame) {
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = frame;
    return label;
}

// "Copy to Clipboard" + "Close" in the bottom-right corner of a sheet `width` points wide.
- (void)addCopyAndCloseTo:(NSView *)content width:(CGFloat)width {
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeSheet:)];
    close.frame = NSMakeRect(width - 20 - 90, 12, 90, 32);
    close.keyEquivalent = @"\033";
    [content addSubview:close];

    NSButton *copy = [NSButton buttonWithTitle:@"Copy to Clipboard" target:self action:@selector(copyResult:)];
    copy.frame = NSMakeRect(width - 20 - 90 - 156, 12, 150, 32);
    [content addSubview:copy];
}

- (void)presentSheet:(NSWindow *)sheet onHost:(NSWindow *)host {
    _sheet = sheet;
    [host beginSheet:sheet completionHandler:^(NSModalResponse response) {
        (void)response;
        if (self->_inputView) self->_lastText = self->_inputView.string ?: @"";   // reopen where the user left off
        self->_sheet = nil;
        self->_inputView = nil;
        self->_resultView = nil;
        self->_perLineCheck = nil;
    }];
}

- (void)closeSheet:(id)sender {
    if (_sheet) [_sheet.sheetParent endSheet:_sheet returnCode:NSModalResponseCancel];
}

- (void)copyResult:(id)sender {
    NPPHashCopyToClipboard(_resultView.string ?: @"");
}

#pragma mark - "Generate…" (from text)

- (void)showTextSheetForAlgorithm:(NPPHashAlgorithm)algo context:(id<NPPCommandContext>)context {
    NSWindow *host = [context contextWindow];
    if (!host || _sheet) { if (_sheet) NSBeep(); return; }
    _algo = algo;

    const CGFloat W = 560, H = 340;
    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered defer:NO];
    NSString *name = [NPPHashTools displayNameForAlgorithm:algo];
    // A sheet's title bar is not drawn, so the algorithm has to be in the labels or the user cannot tell an MD5
    // sheet from a SHA-512 one (same trick as the Run sheet).
    sheet.title = [NSString stringWithFormat:@"Generate %@ digest", name];
    NSView *content = sheet.contentView;

    [content addSubview:NPPHashLabel([NSString stringWithFormat:@"Text to hash with %@:", name],
                                     NSMakeRect(20, 308, 300, 17))];
    NSTextView *input = nil;
    [content addSubview:NPPHashTextArea(NSMakeRect(20, 206, W - 40, 96), YES, &input)];
    input.delegate = self;
    _inputView = input;

    _perLineCheck = [NSButton checkboxWithTitle:@"Treat each line as a separate string"
                                         target:self action:@selector(perLineChanged:)];
    _perLineCheck.frame = NSMakeRect(20, 178, W - 40, 20);
    [content addSubview:_perLineCheck];

    [content addSubview:NPPHashLabel([NSString stringWithFormat:@"%@ digest:", name], NSMakeRect(20, 152, 300, 17))];
    NSTextView *result = nil;
    [content addSubview:NPPHashTextArea(NSMakeRect(20, 56, W - 40, 90), NO, &result)];
    _resultView = result;

    [self addCopyAndCloseTo:content width:W];

    _perLineCheck.state = [NSUserDefaults.standardUserDefaults boolForKey:kPerLine] ? NSControlStateValueOn
                                                                                   : NSControlStateValueOff;
    _inputView.string = _lastText ?: @"";
    [self refreshDigest];

    [self presentSheet:sheet onHost:host];
    [sheet makeFirstResponder:_inputView];
}

// Live update as the user types (N++ recomputes on EN_CHANGE).
- (void)textDidChange:(NSNotification *)note {
    if (note.object == _inputView) [self refreshDigest];
}

- (void)perLineChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:(_perLineCheck.state == NSControlStateValueOn) forKey:kPerLine];
    [self refreshDigest];
}

- (void)refreshDigest {
    NSString *text = _inputView.string ?: @"";
    // ponytail: hashed synchronously on every keystroke — fine for a text box; if someone pastes a 100 MB novel
    // into it, move this to a coalesced background block like the file sheet already uses.
    if (text.length == 0)
        _resultView.string = @"";
    else if (_perLineCheck.state == NSControlStateValueOn)
        _resultView.string = [NPPHashTools hexDigestPerLineOfString:text algorithm:_algo];
    else
        _resultView.string = [NPPHashTools hexDigestOfString:text algorithm:_algo];
}

#pragma mark - "Generate from files…"

- (void)chooseFilesForAlgorithm:(NPPHashAlgorithm)algo context:(id<NPPCommandContext>)context {
    NSWindow *host = [context contextWindow];
    if (!host || _sheet) { if (_sheet) NSBeep(); return; }
    NSString *name = [NPPHashTools displayNameForAlgorithm:algo];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.message = [NSString stringWithFormat:@"Choose files to generate %@…", name];
    panel.prompt = @"Generate";
    __weak id<NPPCommandContext> weakContext = context;
    __weak NSOpenPanel *weakPanel = panel;      // the panel's own handler must not keep the panel alive forever
    [panel beginSheetModalForWindow:host completionHandler:^(NSModalResponse response) {
        NSArray<NSURL *> *urls = weakPanel.URLs;
        if (response != NSModalResponseOK || urls.count == 0) return;
        // Hashing gigabytes must not freeze the window; the sheet goes up when the digests are ready.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
            for (NSURL *url in urls) [paths addObject:(url.path ?: url.absoluteString)];
            NSArray<NSString *> *digests = [NPPHashTools hexDigestsOfFileURLs:urls algorithm:algo];
            dispatch_async(dispatch_get_main_queue(), ^{
                id<NPPCommandContext> ctx = weakContext;   // the window may be gone by the time a huge file is done
                if (ctx) [self showFileResultsForAlgorithm:algo paths:paths digests:digests context:ctx];
            });
        });
    }];
}

- (void)showFileResultsForAlgorithm:(NPPHashAlgorithm)algo
                              paths:(NSArray<NSString *> *)paths
                            digests:(NSArray<NSString *> *)digests
                            context:(id<NPPCommandContext>)context {
    NSWindow *host = [context contextWindow];
    if (!host || _sheet) {
        // The digests are ready but there is nowhere to show them; say so instead of beeping into the void.
        if (_sheet) [context contextReportStatus:@"Close the open hash window to see the file digests" isError:YES];
        return;
    }
    _algo = algo;

    const CGFloat W = 620, H = 380;
    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered defer:NO];
    NSString *name = [NPPHashTools displayNameForAlgorithm:algo];
    sheet.title = [NSString stringWithFormat:@"Generate %@ digest from files", name];
    NSView *content = sheet.contentView;

    [content addSubview:NPPHashLabel(@"Files:", NSMakeRect(20, 332, 300, 17))];
    NSTextView *files = nil;
    [content addSubview:NPPHashTextArea(NSMakeRect(20, 206, W - 40, 120), NO, &files)];
    files.string = [paths componentsJoinedByString:@"\n"];

    [content addSubview:NPPHashLabel([NSString stringWithFormat:@"%@ digests (same order as the files):", name],
                                     NSMakeRect(20, 182, 400, 17))];
    NSTextView *result = nil;
    [content addSubview:NPPHashTextArea(NSMakeRect(20, 56, W - 40, 120), NO, &result)];
    // N++ writes "digest  filename" here; the port keeps the paths in their own pane so Copy yields digests alone.
    result.string = [digests componentsJoinedByString:@"\n"];
    _resultView = result;

    [self addCopyAndCloseTo:content width:W];
    [self presentSheet:sheet onHost:host];
}

#pragma mark - Self checks

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(NSString *, NSString *, NSString *) = ^(NSString *what, NSString *got, NSString *want) {
        if (![got isEqualToString:want])
            [fails addObject:[NSString stringWithFormat:@"%@: got %@, want %@", what, got, want]];
    };

    // Published vectors for the empty string and "abc", per algorithm (RFC 1321 / FIPS 180-4).
    NSArray<NSArray<NSString *> *> *vectors = @[
        @[@"MD5", @"d41d8cd98f00b204e9800998ecf8427e", @"900150983cd24fb0d6963f7d28e17f72"],
        @[@"SHA-1", @"da39a3ee5e6b4b0d3255bfef95601890afd80709", @"a9993e364706816aba3e25717850c26c9cd0d89d"],
        @[@"SHA-256", @"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                      @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"],
        @[@"SHA-512",
          @"cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
          @"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"],
    ];
    for (NSUInteger i = 0; i < vectors.count; ++i) {
        NPPHashAlgorithm algo = (NPPHashAlgorithm)i;
        NSString *name = vectors[i][0];
        expect([name stringByAppendingString:@"(\"\")"], [self hexDigestOfString:@"" algorithm:algo], vectors[i][1]);
        expect([name stringByAppendingString:@"(\"abc\")"], [self hexDigestOfString:@"abc" algorithm:algo], vectors[i][2]);
        if (![[self displayNameForAlgorithm:algo] isEqualToString:name])
            [fails addObject:[NSString stringWithFormat:@"display name %ld is %@, want %@",
                              (long)i, [self displayNameForAlgorithm:algo], name]];
    }

    // Text is hashed as UTF-8, not as UTF-16 or as the platform encoding.
    NSString *unicode = @"héllo → 漢字";
    expect(@"utf8 text == utf8 bytes",
           [self hexDigestOfString:unicode algorithm:NPPHashSHA256],
           [self hexDigestOfData:[unicode dataUsingEncoding:NSUTF8StringEncoding] algorithm:NPPHashSHA256]);

    // Per line: one digest per line, blank lines stay blank, CRLF/CR/LF all count as one break.
    NSString *abc = vectors[0][2];
    expect(@"per-line CRLF", [self hexDigestPerLineOfString:@"abc\r\nabc" algorithm:NPPHashMD5],
           ([NSString stringWithFormat:@"%@\n%@", abc, abc]));
    expect(@"per-line CR", [self hexDigestPerLineOfString:@"abc\rabc" algorithm:NPPHashMD5],
           ([NSString stringWithFormat:@"%@\n%@", abc, abc]));
    expect(@"per-line blank kept", [self hexDigestPerLineOfString:@"abc\n\nabc" algorithm:NPPHashMD5],
           ([NSString stringWithFormat:@"%@\n\n%@", abc, abc]));

    // File hashing: streamed in 1 MiB chunks, so a file spanning several chunks must equal the in-memory digest,
    // an empty file must equal the empty-string digest, a missing one must be nil, and a list must come back in
    // order. Own directory with a unique name: several self-tests may run at once and nothing of the user's in
    // /tmp may ever be overwritten.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [@"npp-hash-selfcheck-" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];
    NSString *big = [dir stringByAppendingPathComponent:@"multi-chunk.bin"];
    NSString *empty = [dir stringByAppendingPathComponent:@"empty.bin"];
    NSURL *missing = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"no-such-file.bin"]];
    const NSUInteger blobLen = kFileChunk * 2 + 1234;          // spans three reads, last one short
    NSMutableData *blob = [NSMutableData dataWithLength:blobLen];
    uint8_t *blobBytes = (uint8_t *)blob.mutableBytes;
    for (NSUInteger i = 0; i < blobLen; ++i) blobBytes[i] = (uint8_t)(i * 31 + (i >> 8));
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL] ||
        ![blob writeToFile:big atomically:YES] || ![NSData.data writeToFile:empty atomically:YES]) {
        [fails addObject:@"could not write the temporary files for the streaming check"];
    } else {
        expect(@"streamed multi-chunk file",
               [self hexDigestOfFileURL:[NSURL fileURLWithPath:big] algorithm:NPPHashSHA256] ?: @"(nil)",
               [self hexDigestOfData:blob algorithm:NPPHashSHA256]);
        expect(@"empty file", [self hexDigestOfFileURL:[NSURL fileURLWithPath:empty] algorithm:NPPHashMD5] ?: @"(nil)",
               vectors[0][1]);
        if ([self hexDigestOfFileURL:missing algorithm:NPPHashMD5] != nil)
            [fails addObject:@"a missing file must hash to nil"];
        // What the files sheet relies on: digest N belongs to path N, and an unreadable file keeps its line.
        NSArray<NSString *> *list = [self hexDigestsOfFileURLs:@[[NSURL fileURLWithPath:empty], missing,
                                                                 [NSURL fileURLWithPath:big]]
                                                    algorithm:NPPHashMD5];
        expect(@"file digests in file order", [list componentsJoinedByString:@"|"],
               ([NSString stringWithFormat:@"%@|(unreadable)|%@", vectors[0][1],
                                           [self hexDigestOfData:blob algorithm:NPPHashMD5]]));
    }
    [fm removeItemAtPath:dir error:NULL];

    // Command decoding: the 12 tags this module owns, and nothing outside them. The stride is spelt out as a
    // literal 3 rather than kHashActions because NPPAppDelegate builds the menu with a literal 3 — this check is
    // what would catch the two drifting apart.
    for (NSInteger a = 0; a < 4; ++a) {
        for (NSInteger k = 0; k < 3; ++k) {
            NPPCmd cmd = (NPPCmd)(NPPCmdToolHashBase + a * 3 + k);
            NPPHashAlgorithm algo = NPPHashMD5;
            NSInteger action = -1;
            if (![self handlesCommand:cmd] || !NPPHashDecodeCommand(cmd, &algo, &action) ||
                (NSInteger)algo != a || action != k)
                [fails addObject:[NSString stringWithFormat:@"command %ld decodes to (%ld,%ld), want (%ld,%ld)",
                                  (long)cmd, (long)algo, (long)action, (long)a, (long)k]];
        }
    }
    if ([self handlesCommand:(NPPCmd)(NPPCmdToolHashBase - 1)] ||
        ![self handlesCommand:(NPPCmd)(NPPCmdToolHashBase + 11)] ||
        [self handlesCommand:(NPPCmd)(NPPCmdToolHashBase + 12)])
        [fails addObject:@"handlesCommand: does not claim exactly the 12 hash tags"];

    return fails;
}

@end
