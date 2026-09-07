// NPPColumnEditor.mm — see header.
#import "NPPColumnEditor.h"
#import "NPPDocument.h"
#import "NPPUtils.h"
#include <string>
#include <vector>

// ---- defaults keys -------------------------------------------------------------------------------------------
static NSString *const kMode     = @"NPPColumnEditorMode";       // 0 = text, 1 = number
static NSString *const kText     = @"NPPColumnEditorText";
static NSString *const kInitial  = @"NPPColumnEditorInitialNum";
static NSString *const kIncrease = @"NPPColumnEditorIncreaseNum";
static NSString *const kRepeat   = @"NPPColumnEditorRepeatNum";
static NSString *const kLeading  = @"NPPColumnEditorLeading";    // 0 none, 1 zeros, 2 spaces
static NSString *const kFormat   = @"NPPColumnEditorFormat";     // 0 dec, 1 hex, 2 oct, 3 bin

static int NPPBaseForFormat(NSInteger f) { return f == 1 ? 16 : f == 2 ? 8 : f == 3 ? 2 : 10; }

// Raw (unpadded) representation, uppercase hex like N++.
static NSString *NPPFormatNumber(long long v, int base) {
    BOOL neg = v < 0;
    unsigned long long u = neg ? (unsigned long long)(-(v + 1)) + 1ULL : (unsigned long long)v;
    static const char *digits = "0123456789ABCDEF";
    char buf[80];
    int n = 0;
    do { buf[n++] = digits[u % (unsigned)base]; u /= (unsigned)base; } while (u && n < 79);
    if (neg && n < 79) buf[n++] = '-';
    char out[81];
    for (int i = 0; i < n; ++i) out[i] = buf[n - 1 - i];
    out[n] = 0;
    return @(out);
}

// ponytail: zero-padding a negative value pads after the '-' ("-007"); N++ only deals in unsigned here.
static NSString *NPPPadNumber(NSString *s, NSInteger width, NSInteger leading) {
    if (leading == 0 || (NSInteger)s.length >= width) return s;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(width - (NSInteger)s.length)
                                      withString:(leading == 1 ? @"0" : @" ") startingAtIndex:0];
    if (leading == 1 && [s hasPrefix:@"-"])
        return [NSString stringWithFormat:@"-%@%@", pad, [s substringFromIndex:1]];
    return [pad stringByAppendingString:s];
}

// One insertion site: the range to replace (empty for a plain insert) on a given line.
struct NPPColTarget { sptr_t line; sptr_t start; sptr_t end; };

@implementation NPPColumnEditor {
    NSView *_accessory;
    NSButton *_textRadio, *_numRadio;
    NSTextField *_textField, *_initialField, *_increaseField, *_repeatField;
    NSArray<NSButton *> *_leadingRadios, *_formatRadios;
    BOOL _sheetOpen;
}

+ (instancetype)shared {
    static NPPColumnEditor *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPColumnEditor alloc] init]; });
    return s;
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd { return cmd == NPPCmdEditColumnEditor; }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdEditColumnEditor) return NO;
    NPPDocument *doc = [context contextCurrentDocument];
    if (!doc || !doc.editor) return NO;
    if (doc.isReadOnly || NPPSci(doc.editor, SCI_GETREADONLY)) return NO;
    return YES;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdEditColumnEditor) return NO;
    if (![self canPerformCommand:cmd context:context]) return NO;
    [[self shared] showSheetForContext:context];
    return YES;
}

#pragma mark - Sheet

- (void)showSheetForContext:(id<NPPCommandContext>)context {
    // ponytail: the accessory view (and its controls) is shared/cached, so only one sheet may own it at a time.
    // A document-modal sheet leaves the menu item enabled, so re-entry is reachable; just beep and keep the live one.
    if (_sheetOpen) { NSBeep(); return; }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSView *v = [self buildAccessoryView];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Column Editor", nil);
    alert.informativeText = NSLocalizedString(@"Insert text or a number sequence at the same column of every selected line.", nil);
    alert.accessoryView = v;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

    // restore last values
    _textField.stringValue     = [ud stringForKey:kText] ?: @"";
    _initialField.stringValue  = [NSString stringWithFormat:@"%ld", (long)[ud integerForKey:kInitial]];
    _increaseField.stringValue = [NSString stringWithFormat:@"%ld", (long)([ud objectForKey:kIncrease] ? [ud integerForKey:kIncrease] : 1)];
    _repeatField.stringValue   = [NSString stringWithFormat:@"%ld", (long)([ud objectForKey:kRepeat] ? MAX(1, [ud integerForKey:kRepeat]) : 1)];
    [self selectRadios:_leadingRadios index:[ud integerForKey:kLeading]];
    [self selectRadios:_formatRadios index:[ud integerForKey:kFormat]];
    BOOL numberMode = [ud integerForKey:kMode] == 1;
    _numRadio.state = numberMode ? NSControlStateValueOn : NSControlStateValueOff;
    _textRadio.state = numberMode ? NSControlStateValueOff : NSControlStateValueOn;
    [self syncEnabled];

    NSWindow *host = [context contextWindow];
    void (^done)(NSModalResponse) = ^(NSModalResponse response) {
        self->_sheetOpen = NO;
        if (response != NSAlertFirstButtonReturn) return;
        [self applyToContext:context];
    };
    _sheetOpen = YES;
    if (host) {
        [alert beginSheetModalForWindow:host completionHandler:done];
        [v.window makeFirstResponder:(numberMode ? _initialField : _textField)];
    } else {
        done([alert runModal]);
    }
}

- (void)selectRadios:(NSArray<NSButton *> *)radios index:(NSInteger)idx {
    [radios enumerateObjectsUsingBlock:^(NSButton *b, NSUInteger i, BOOL *stop) {
        b.state = ((NSInteger)i == idx) ? NSControlStateValueOn : NSControlStateValueOff;
    }];
}
- (NSInteger)selectedIndex:(NSArray<NSButton *> *)radios {
    for (NSUInteger i = 0; i < radios.count; ++i)
        if (radios[i].state == NSControlStateValueOn) return (NSInteger)i;
    return 0;
}

#pragma mark - UI construction

static NSTextField *NPPLabel(NSString *s, NSRect f) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.frame = f;
    l.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    return l;
}

- (NSButton *)radio:(NSString *)title frame:(NSRect)f action:(SEL)sel {
    NSButton *b = [NSButton radioButtonWithTitle:title target:self action:sel];
    b.frame = f;
    b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    return b;
}

- (NSView *)buildAccessoryView {
    if (_accessory) return _accessory;
    const CGFloat W = 400;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, 232)];

    // --- Number to Insert (bottom half) ---
    _formatRadios = @[[self radio:@"Dec"  frame:NSMakeRect(90, 6, 70, 20) action:@selector(radioChanged:)],
                      [self radio:@"Hex"  frame:NSMakeRect(160, 6, 70, 20) action:@selector(radioChanged:)],
                      [self radio:@"Oct"  frame:NSMakeRect(230, 6, 70, 20) action:@selector(radioChanged:)],
                      [self radio:@"Bin"  frame:NSMakeRect(300, 6, 70, 20) action:@selector(radioChanged:)]];
    [v addSubview:NPPLabel(NSLocalizedString(@"Format:", nil), NSMakeRect(20, 8, 66, 16))];
    for (NSButton *b in _formatRadios) [v addSubview:b];

    _leadingRadios = @[[self radio:@"None"   frame:NSMakeRect(90, 32, 70, 20) action:@selector(radioChanged:)],
                       [self radio:@"Zeros"  frame:NSMakeRect(160, 32, 70, 20) action:@selector(radioChanged:)],
                       [self radio:@"Spaces" frame:NSMakeRect(230, 32, 80, 20) action:@selector(radioChanged:)]];
    [v addSubview:NPPLabel(NSLocalizedString(@"Leading:", nil), NSMakeRect(20, 34, 66, 16))];
    for (NSButton *b in _leadingRadios) [v addSubview:b];

    _repeatField   = [[NSTextField alloc] initWithFrame:NSMakeRect(90, 58, 90, 22)];
    _increaseField = [[NSTextField alloc] initWithFrame:NSMakeRect(90, 86, 90, 22)];
    _initialField  = [[NSTextField alloc] initWithFrame:NSMakeRect(90, 114, 90, 22)];
    [v addSubview:NPPLabel(NSLocalizedString(@"Repeat:", nil), NSMakeRect(20, 61, 66, 16))];
    [v addSubview:NPPLabel(NSLocalizedString(@"Increase by:", nil), NSMakeRect(20, 89, 66, 16))];
    [v addSubview:NPPLabel(NSLocalizedString(@"Initial number:", nil), NSMakeRect(20, 117, 66, 16))];
    for (NSTextField *f in @[_repeatField, _increaseField, _initialField]) {
        f.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
        [v addSubview:f];
    }

    _numRadio = [self radio:NSLocalizedString(@"Number to Insert", nil) frame:NSMakeRect(14, 142, 220, 20)
                     action:@selector(modeChanged:)];
    _numRadio.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    [v addSubview:_numRadio];

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(14, 170, W - 28, 1)];
    sep.boxType = NSBoxSeparator;
    [v addSubview:sep];

    // --- Text to Insert (top) ---
    _textField = [[NSTextField alloc] initWithFrame:NSMakeRect(34, 182, W - 54, 22)];
    [v addSubview:_textField];
    _textRadio = [self radio:NSLocalizedString(@"Text to Insert", nil) frame:NSMakeRect(14, 208, 220, 20)
                      action:@selector(modeChanged:)];
    _textRadio.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    [v addSubview:_textRadio];

    _accessory = v;
    return v;
}

- (void)modeChanged:(NSButton *)sender {
    BOOL num = (sender == _numRadio);
    _numRadio.state  = num ? NSControlStateValueOn : NSControlStateValueOff;
    _textRadio.state = num ? NSControlStateValueOff : NSControlStateValueOn;
    [self syncEnabled];
    [_accessory.window makeFirstResponder:(num ? _initialField : _textField)];
}

// Typing in a field switches to that field's mode, like N++.
- (void)radioChanged:(NSButton *)sender {
    if ([_leadingRadios containsObject:sender]) [self selectRadios:_leadingRadios index:(NSInteger)[_leadingRadios indexOfObject:sender]];
    else [self selectRadios:_formatRadios index:(NSInteger)[_formatRadios indexOfObject:sender]];
}

- (void)syncEnabled {
    BOOL num = (_numRadio.state == NSControlStateValueOn);
    _textField.enabled = !num;
    for (NSTextField *f in @[_initialField, _increaseField, _repeatField]) f.enabled = num;
    for (NSButton *b in _leadingRadios) b.enabled = num;
    for (NSButton *b in _formatRadios) b.enabled = num;
}

#pragma mark - Insertion

// Target sites, in document order.
static std::vector<NPPColTarget> NPPColumnTargets(ScintillaView *ed, sptr_t *outColumn, BOOL *outRectangular) {
    std::vector<NPPColTarget> targets;
    sptr_t nSel = NPPSci(ed, SCI_GETSELECTIONS);
    BOOL rectangular = NPPSci(ed, SCI_SELECTIONISRECTANGLE) || nSel > 1;
    *outRectangular = rectangular;
    if (rectangular && nSel > 0) {
        for (sptr_t i = 0; i < nSel; ++i) {
            sptr_t s = NPPSci(ed, SCI_GETSELECTIONNSTART, (uptr_t)i);
            sptr_t e = NPPSci(ed, SCI_GETSELECTIONNEND, (uptr_t)i);
            if (e < s) std::swap(s, e);
            targets.push_back({NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)s), s, e});
        }
        std::sort(targets.begin(), targets.end(),
                  [](const NPPColTarget &a, const NPPColTarget &b) { return a.start < b.start; });
        sptr_t virt = NPPSci(ed, SCI_GETSELECTIONNANCHORVIRTUALSPACE, 0);
        *outColumn = NPPSci(ed, SCI_GETCOLUMN, (uptr_t)targets.front().start) + virt;
    } else {
        sptr_t caret = NPPSci(ed, SCI_GETCURRENTPOS);
        *outColumn = NPPSci(ed, SCI_GETCOLUMN, (uptr_t)caret) + NPPSci(ed, SCI_GETSELECTIONNCARETVIRTUALSPACE, 0);
        sptr_t first = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)caret);
        sptr_t last = NPPSci(ed, SCI_GETLINECOUNT) - 1;
        for (sptr_t l = first; l <= last; ++l) {
            sptr_t p = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)l);
            targets.push_back({l, p, p});   // start/end refined at insert time via SCI_FINDCOLUMN
        }
    }
    return targets;
}

- (void)applyToContext:(id<NPPCommandContext>)context {
    NPPDocument *doc = [context contextCurrentDocument];
    ScintillaView *ed = doc.editor;
    if (!ed || doc.isReadOnly || NPPSci(ed, SCI_GETREADONLY)) return;

    BOOL numberMode = (_numRadio.state == NSControlStateValueOn);
    NSInteger leading = [self selectedIndex:_leadingRadios];
    NSInteger format  = [self selectedIndex:_formatRadios];
    long long initial = _initialField.stringValue.longLongValue;
    long long incr    = _increaseField.stringValue.longLongValue;
    long long repeat  = _repeatField.stringValue.longLongValue;
    if (repeat < 1) repeat = 1;
    NSString *text = _textField.stringValue ?: @"";

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setInteger:(numberMode ? 1 : 0) forKey:kMode];
    [ud setObject:text forKey:kText];
    [ud setInteger:(NSInteger)initial forKey:kInitial];
    [ud setInteger:(NSInteger)incr forKey:kIncrease];
    [ud setInteger:(NSInteger)repeat forKey:kRepeat];
    [ud setInteger:leading forKey:kLeading];
    [ud setInteger:format forKey:kFormat];

    if (!numberMode && text.length == 0) return;

    sptr_t column = 0;
    BOOL rectangular = NO;
    std::vector<NPPColTarget> targets = NPPColumnTargets(ed, &column, &rectangular);
    if (targets.empty()) return;

    // Build the string for each target line.
    NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:targets.size()];
    if (numberMode) {
        int base = NPPBaseForFormat(format);
        long long cur = initial;
        NSInteger width = 0;
        long long countInRun = 0;
        for (size_t i = 0; i < targets.size(); ++i) {
            NSString *s = NPPFormatNumber(cur, base);
            width = MAX(width, (NSInteger)s.length);
            [values addObject:s];
            if (++countInRun >= repeat) { countInRun = 0; cur += incr; }
        }
        for (NSUInteger i = 0; i < values.count; ++i)
            values[i] = NPPPadNumber(values[i], width, leading);
    } else {
        for (size_t i = 0; i < targets.size(); ++i) [values addObject:text];
    }

    // ponytail: synchronous — a caret-to-EOF insert on a multi-million-line file will block; N++ blocks too.
    NPPSci(ed, SCI_BEGINUNDOACTION);
    // Work backwards so earlier positions stay valid.
    for (NSInteger i = (NSInteger)targets.size() - 1; i >= 0; --i) {
        const NPPColTarget &t = targets[(size_t)i];
        if (rectangular && t.end > t.start)
            NPPSci(ed, SCI_DELETERANGE, (uptr_t)t.start, t.end - t.start);
        sptr_t pos = NPPSci(ed, SCI_FINDCOLUMN, (uptr_t)t.line, column);
        sptr_t actual = NPPSci(ed, SCI_GETCOLUMN, (uptr_t)pos);
        if (actual < column) {   // line too short: pad with spaces up to the target column
            std::string pad((size_t)(column - actual), ' ');
            NPPSciStr(ed, SCI_INSERTTEXT, (uptr_t)pos, pad.c_str());
            pos += (sptr_t)pad.size();
        }
        NPPSciStr(ed, SCI_INSERTTEXT, (uptr_t)pos, values[(NSUInteger)i].UTF8String);
    }
    NPPSci(ed, SCI_ENDUNDOACTION);
    NPPSci(ed, SCI_SETEMPTYSELECTION, (uptr_t)NPPSci(ed, SCI_GETCURRENTPOS));
    [context contextReportStatus:[NSString stringWithFormat:NSLocalizedString(@"Column Editor: %lu line(s) modified", nil),
                                  (unsigned long)targets.size()] isError:NO];
}

@end
