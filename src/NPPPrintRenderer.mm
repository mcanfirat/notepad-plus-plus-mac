// NPPPrintRenderer.mm — see header. Port of N++ ScintillaComponent/Printer.cpp onto NSPrintOperation.
//
// The whole trick: on Cocoa a Scintilla "hdc" is a CGContextRef, so SCI_FORMATRANGEFULL renders straight
// into the print context. An isFlipped NSView matches Scintilla's own y-down content view, so no extra
// transform is needed. knowsPageRange: walks the document with draw=0 (into a 1x1 bitmap context, which
// measures identically to the print context) to build the page table; drawRect: replays one page with
// draw=1 and paints the header/footer bands itself.
#import "NPPPrintRenderer.h"
#import "NPPDocument.h"

// ---------------------------------------------------------------------------------------------------
// Settings (NSUserDefaults, N++ NppGUI::_printSettings)

static NSString *const kColourMode   = @"NPPPrintColourMode";     // SC_PRINT_* constant
static NSString *const kLineNumbers  = @"NPPPrintLineNumbers";
static NSString *const kMagnify      = @"NPPPrintMagnification";  // SCI_SETPRINTMAGNIFICATION
static NSString *const kHeaderLeft   = @"NPPPrintHeaderLeft";
static NSString *const kHeaderMiddle = @"NPPPrintHeaderMiddle";
static NSString *const kHeaderRight  = @"NPPPrintHeaderRight";
static NSString *const kFooterLeft   = @"NPPPrintFooterLeft";
static NSString *const kFooterMiddle = @"NPPPrintFooterMiddle";
static NSString *const kFooterRight  = @"NPPPrintFooterRight";
// The rest of N++ PrintSettings. NPPPreferences registers these (Print page); the renderer never registers them
// because every one of them defaults to the zero NSUserDefaults already returns for a missing key.
static NSString *const kFormFeed         = @"NPPPrintFormFeedPageBreak";
static NSString *const kMarginTop        = @"NPPPrintMarginTop";     // millimetres, 0..100
static NSString *const kMarginLeft       = @"NPPPrintMarginLeft";
static NSString *const kMarginRight      = @"NPPPrintMarginRight";
static NSString *const kMarginBottom     = @"NPPPrintMarginBottom";
static NSString *const kHeaderFontName   = @"NPPPrintHeaderFontName";    // "" = the renderer's own band font
static NSString *const kHeaderFontSize   = @"NPPPrintHeaderFontSize";    // 0  = the renderer's own size
static NSString *const kHeaderFontBold   = @"NPPPrintHeaderFontBold";
static NSString *const kHeaderFontItalic = @"NPPPrintHeaderFontItalic";
static NSString *const kFooterFontName   = @"NPPPrintFooterFontName";
static NSString *const kFooterFontSize   = @"NPPPrintFooterFontSize";
static NSString *const kFooterFontBold   = @"NPPPrintFooterFontBold";
static NSString *const kFooterFontItalic = @"NPPPrintFooterFontItalic";

static void NPPPrintRegisterDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ponytail: N++ ships every header/footer part empty; a path + page number out of the box is more
        // useful than a blank margin and the accessory can clear them.
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            kColourMode:   @(SC_PRINT_COLOURONWHITE),
            kLineNumbers:  @NO,
            kMagnify:      @0,
            kHeaderLeft:   @"$(FULL_CURRENT_PATH)",
            kHeaderMiddle: @"",
            kHeaderRight:  @"",
            kFooterLeft:   @"",
            kFooterMiddle: @"$(CURRENT_PAGE)",
            kFooterRight:  @"",
        }];
    });
}

static NSString *NPPPrintStr(NSString *key) {
    NSString *s = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return s ?: @"";
}

// Header and footer carry independent fonts (N++ PrintSettings::_headerFont* / _footerFont*). An empty family or a
// size of 0 means "the renderer's own", which is 9pt Helvetica — N++ falls back to 9pt Arial.
static NSFont *NPPPrintFont(NSString *family, NSInteger size, BOOL bold, BOOL italic) {
    CGFloat pt = (size > 0 && size <= 72) ? (CGFloat)size : 9.0;

    NSFont *font = nil;
    if (family.length)
        font = [NSFont fontWithDescriptor:[NSFontDescriptor fontDescriptorWithFontAttributes:@{ NSFontFamilyAttribute: family }]
                                     size:pt];
    if (!font) font = [NSFont fontWithName:@"Helvetica" size:pt];
    if (!font) font = [NSFont systemFontOfSize:pt];

    NSFontTraitMask traits = (bold ? NSBoldFontMask : 0) | (italic ? NSItalicFontMask : 0);
    // ponytail: a family with no bold/italic face keeps its regular one (convertFont: is a no-op then) instead of
    // being synthetically emboldened/slanted; add an NSAffineTransform descriptor if that ever matters.
    if (traits) font = [NSFontManager.sharedFontManager convertFont:font toHaveTrait:traits];
    return font;
}

static NSFont *NPPPrintBandFont(BOOL header) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return NPPPrintFont(NPPPrintStr(header ? kHeaderFontName : kFooterFontName),
                        [d integerForKey:(header ? kHeaderFontSize : kFooterFontSize)],
                        [d boolForKey:(header ? kHeaderFontBold : kFooterFontBold)],
                        [d boolForKey:(header ? kHeaderFontItalic : kFooterFontItalic)]);
}

static CGFloat NPPPrintLineHeight(NSFont *f) {
    return ceil(f.ascender - f.descender + f.leading);
}

// -- margins (N++ PrintSettings::_marge, millimetres) -----------------------------------------------

static CGFloat NPPPrintPointsFromMM(NSInteger mm) {
    if (mm < 0) mm = 0;
    if (mm > 100) mm = 100;             // the Print page's own range
    return (CGFloat)mm * 72.0 / 25.4;
}

// N++ PrintSettings::isUserMargePresent(): one non-zero side switches all four to the millimetre settings; all
// four at 0 leaves the margins to the macOS print panel.
static NSEdgeInsets NPPPrintMarginsFromMM(NSInteger top, NSInteger left, NSInteger right, NSInteger bottom,
                                          NSEdgeInsets fromPanel) {
    if (top <= 0 && left <= 0 && right <= 0 && bottom <= 0) return fromPanel;
    return NSEdgeInsetsMake(NPPPrintPointsFromMM(top), NPPPrintPointsFromMM(left),
                            NPPPrintPointsFromMM(bottom), NPPPrintPointsFromMM(right));
}

static NSEdgeInsets NPPPrintRequestedMargins(NSEdgeInsets fromPanel) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return NPPPrintMarginsFromMM([d integerForKey:kMarginTop], [d integerForKey:kMarginLeft],
                                 [d integerForKey:kMarginRight], [d integerForKey:kMarginBottom], fromPanel);
}

// N++'s IDC_EDIT_PRINTZOOM and the print accessory's stepper both stop at ±10; a hand-edited plist must not be
// able to paginate a document into thousands of unreadable pages.
static sptr_t NPPPrintMagnification(NSInteger v) { return (sptr_t)MAX((NSInteger)-10, MIN((NSInteger)10, v)); }

// -- form feed as page break (N++ Printer::doPrint) -------------------------------------------------

// Where the page that starts at `pageStart` must stop: just before the form feed N++ found, or the end of the
// printed range when there is none. (N++ writes ff-1 with a special case for ff==0; the clamp covers both and
// cannot hand Scintilla an inverted range.)
static sptr_t NPPPrintPageEnd(sptr_t pageStart, sptr_t rangeEnd, sptr_t formFeedPos) {
    if (formFeedPos < 0) return rangeEnd;
    return MAX(pageStart, formFeedPos - 1);
}

// Where the next page starts, given what SCI_FORMATRANGEFULL consumed. Stepping over the form feed is what stops
// it being printed forever — but only once the page actually reached it: N++ steps over it unconditionally and so
// drops the text of any page that filled up before the form feed.
static sptr_t NPPPrintAdvance(sptr_t formatted, sptr_t pageEnd, sptr_t formFeedPos) {
    if (formFeedPos >= 0 && formatted >= pageEnd) return MAX(formatted, formFeedPos + 1);
    return formatted;
}

// SCI_FINDTEXTFULL for the next 0x0C in [from, to), or -1 when the setting is off / there is none.
static sptr_t NPPPrintFindFormFeed(ScintillaView *ed, sptr_t from, sptr_t to) {
    if (!ed || ![NSUserDefaults.standardUserDefaults boolForKey:kFormFeed]) return -1;
    struct Sci_TextToFindFull ttf = {};
    ttf.chrg.cpMin = from;
    ttf.chrg.cpMax = to;
    ttf.lpstrText = "\f";
    return [ed message:SCI_FINDTEXTFULL wParam:(uptr_t)SCFIND_NONE lParam:(sptr_t)&ttf];
}

// $(…) expansion. N++ spells the page variable $(CURRENT_PRINTING_PAGE) and the clock ones
// $(SHORT_DATE)/$(LONG_DATE)/$(TIME); both spellings are accepted.
static NSString *NPPPrintExpand(NSString *tmpl, NSString *docName, NSInteger page) {
    if (tmpl.length == 0) return @"";
    NSString *path = docName.length ? docName : @"";
    NSDate *now = NSDate.date;
    NSString *shortDate = [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle];
    NSString *longDate = [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterLongStyle timeStyle:NSDateFormatterNoStyle];
    NSString *time = [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
    NSDictionary<NSString *, NSString *> *vars = @{
        @"$(FULL_CURRENT_PATH)":        path,
        @"$(FILE_NAME)":                path.lastPathComponent ?: path,
        @"$(CURRENT_DIRECTORY)":        [path stringByDeletingLastPathComponent] ?: @"",
        @"$(NAME_PART)":                [path.lastPathComponent stringByDeletingPathExtension] ?: @"",
        @"$(EXT_PART)":                 path.pathExtension ?: @"",
        @"$(CURRENT_DATE)":             shortDate,
        @"$(SHORT_DATE)":               shortDate,
        @"$(LONG_DATE)":                longDate,
        @"$(CURRENT_TIME)":             time,
        @"$(TIME)":                     time,
        @"$(CURRENT_PAGE)":             [@(page) stringValue],
        @"$(CURRENT_PRINTING_PAGE)":    [@(page) stringValue],
    };
    NSMutableString *out = [tmpl mutableCopy];
    for (NSString *key in vars)
        [out replaceOccurrencesOfString:key withString:vars[key] options:0 range:NSMakeRange(0, out.length)];
    return out;
}

// ---------------------------------------------------------------------------------------------------
// Print panel accessory (N++ Preferences > Print)

@interface NPPPrintAccessory : NSViewController <NSPrintPanelAccessorizing, NSTextFieldDelegate>
@property (nonatomic) NSInteger colourMode;
@property (nonatomic) BOOL printLineNumbers;
@property (nonatomic) NSInteger magnification;
@property (nonatomic, copy) NSString *headerLeft, *headerMiddle, *headerRight;
@property (nonatomic, copy) NSString *footerLeft, *footerMiddle, *footerRight;
@end

@implementation NPPPrintAccessory {
    NSTextField *_magField;
}

// Order matches the Scintilla constants so the popup index is the stored value.
static const int kColourModes[] = { SC_PRINT_NORMAL, SC_PRINT_INVERTLIGHT, SC_PRINT_BLACKONWHITE,
                                    SC_PRINT_COLOURONWHITE, SC_PRINT_COLOURONWHITEDEFAULTBG };

- (instancetype)init {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    NPPPrintRegisterDefaults();
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    _colourMode = [d integerForKey:kColourMode];
    _printLineNumbers = [d boolForKey:kLineNumbers];
    _magnification = [d integerForKey:kMagnify];
    _headerLeft = NPPPrintStr(kHeaderLeft);   _headerMiddle = NPPPrintStr(kHeaderMiddle);   _headerRight = NPPPrintStr(kHeaderRight);
    _footerLeft = NPPPrintStr(kFooterLeft);   _footerMiddle = NPPPrintStr(kFooterMiddle);   _footerRight = NPPPrintStr(kFooterRight);
    self.title = NSLocalizedString(@"Notepad++", nil);
    return self;
}

- (NSTextField *)fieldWithString:(NSString *)s tag:(NSInteger)tag placeholder:(NSString *)ph {
    NSTextField *tf = [NSTextField textFieldWithString:s ?: @""];
    tf.tag = tag;
    tf.placeholderString = ph;
    tf.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    tf.target = self;
    tf.action = @selector(textChanged:);
    tf.delegate = self;
    [tf.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
    return tf;
}

- (NSTextField *)label:(NSString *)s {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    l.alignment = NSTextAlignmentRight;
    return l;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 250)];

    NSPopUpButton *colour = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [colour addItemsWithTitles:@[ NSLocalizedString(@"WYSIWYG", nil),
                                  NSLocalizedString(@"Invert", nil),
                                  NSLocalizedString(@"Black on white", nil),
                                  NSLocalizedString(@"No background colour", nil),
                                  NSLocalizedString(@"No background colour (default)", nil) ]];
    NSInteger sel = 0;
    for (NSInteger i = 0; i < (NSInteger)(sizeof(kColourModes) / sizeof(kColourModes[0])); i++)
        if (kColourModes[i] == self.colourMode) sel = i;
    [colour selectItemAtIndex:sel];
    colour.target = self;
    colour.action = @selector(colourChanged:);

    NSButton *lineNums = [NSButton checkboxWithTitle:NSLocalizedString(@"Print line numbers", nil)
                                              target:self action:@selector(lineNumbersChanged:)];
    lineNums.state = self.printLineNumbers ? NSControlStateValueOn : NSControlStateValueOff;

    _magField = [NSTextField labelWithString:[NSString stringWithFormat:@"%+ld", (long)self.magnification]];
    _magField.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
    NSStepper *stepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    stepper.minValue = -10; stepper.maxValue = 10; stepper.increment = 1; stepper.valueWraps = NO;  // the Print page's range
    stepper.integerValue = self.magnification;
    stepper.target = self;
    stepper.action = @selector(magnificationChanged:);
    NSStackView *mag = [NSStackView stackViewWithViews:@[ _magField, stepper ]];
    mag.spacing = 4;

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [self label:NSLocalizedString(@"Colour options:", nil)], colour ],
        @[ [NSGridCell emptyContentView], lineNums ],
        @[ [self label:NSLocalizedString(@"Zoom:", nil)], mag ],
        @[ [self label:NSLocalizedString(@"Header:", nil)],
           [NSStackView stackViewWithViews:@[ [self fieldWithString:self.headerLeft tag:1 placeholder:NSLocalizedString(@"left", nil)],
                                              [self fieldWithString:self.headerMiddle tag:2 placeholder:NSLocalizedString(@"middle", nil)],
                                              [self fieldWithString:self.headerRight tag:3 placeholder:NSLocalizedString(@"right", nil)] ]] ],
        @[ [self label:NSLocalizedString(@"Footer:", nil)],
           [NSStackView stackViewWithViews:@[ [self fieldWithString:self.footerLeft tag:4 placeholder:NSLocalizedString(@"left", nil)],
                                              [self fieldWithString:self.footerMiddle tag:5 placeholder:NSLocalizedString(@"middle", nil)],
                                              [self fieldWithString:self.footerRight tag:6 placeholder:NSLocalizedString(@"right", nil)] ]] ],
    ]];
    grid.columnSpacing = 8;
    grid.rowSpacing = 8;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *hint = [NSTextField wrappingLabelWithString:
        NSLocalizedString(@"Variables: $(FULL_CURRENT_PATH)  $(FILE_NAME)  $(CURRENT_DIRECTORY)  $(NAME_PART)  $(EXT_PART)  "
                          @"$(CURRENT_PRINTING_PAGE)  $(SHORT_DATE)  $(LONG_DATE)  $(TIME). "
                          @"Margins, fonts and “formfeed as page break” live in Preferences ▸ Print.", nil)];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    [root addSubview:grid];
    [root addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        [grid.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14],
        [grid.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-14],
        [hint.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:10],
        [hint.leadingAnchor constraintEqualToAnchor:grid.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14],
        [hint.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor constant:-14],
    ]];
    self.view = root;
    self.preferredContentSize = NSMakeSize(520, 210);
}

// -- actions ---------------------------------------------------------------------------------------

- (void)colourChanged:(NSPopUpButton *)sender {
    NSInteger i = sender.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)(sizeof(kColourModes) / sizeof(kColourModes[0]))) return;
    self.colourMode = kColourModes[i];
}

- (void)lineNumbersChanged:(NSButton *)sender { self.printLineNumbers = (sender.state == NSControlStateValueOn); }

- (void)magnificationChanged:(NSStepper *)sender {
    self.magnification = sender.integerValue;
    _magField.stringValue = [NSString stringWithFormat:@"%+ld", (long)self.magnification];
}

- (void)textChanged:(NSTextField *)tf { [self applyField:tf]; }
- (void)controlTextDidEndEditing:(NSNotification *)note {
    if ([note.object isKindOfClass:NSTextField.class]) [self applyField:note.object];
}

- (void)applyField:(NSTextField *)tf {
    NSString *v = tf.stringValue ?: @"";
    switch (tf.tag) {
        case 1: self.headerLeft = v; break;
        case 2: self.headerMiddle = v; break;
        case 3: self.headerRight = v; break;
        case 4: self.footerLeft = v; break;
        case 5: self.footerMiddle = v; break;
        case 6: self.footerRight = v; break;
        default: break;
    }
}

// -- persistence (setters double as the KVO hooks that refresh the preview) --------------------------

- (void)setColourMode:(NSInteger)v { _colourMode = v; [NSUserDefaults.standardUserDefaults setInteger:v forKey:kColourMode]; }
- (void)setPrintLineNumbers:(BOOL)v { _printLineNumbers = v; [NSUserDefaults.standardUserDefaults setBool:v forKey:kLineNumbers]; }
- (void)setMagnification:(NSInteger)v { _magnification = v; [NSUserDefaults.standardUserDefaults setInteger:v forKey:kMagnify]; }
- (void)setHeaderLeft:(NSString *)v   { _headerLeft = [v copy];   [NSUserDefaults.standardUserDefaults setObject:_headerLeft forKey:kHeaderLeft]; }
- (void)setHeaderMiddle:(NSString *)v { _headerMiddle = [v copy]; [NSUserDefaults.standardUserDefaults setObject:_headerMiddle forKey:kHeaderMiddle]; }
- (void)setHeaderRight:(NSString *)v  { _headerRight = [v copy];  [NSUserDefaults.standardUserDefaults setObject:_headerRight forKey:kHeaderRight]; }
- (void)setFooterLeft:(NSString *)v   { _footerLeft = [v copy];   [NSUserDefaults.standardUserDefaults setObject:_footerLeft forKey:kFooterLeft]; }
- (void)setFooterMiddle:(NSString *)v { _footerMiddle = [v copy]; [NSUserDefaults.standardUserDefaults setObject:_footerMiddle forKey:kFooterMiddle]; }
- (void)setFooterRight:(NSString *)v  { _footerRight = [v copy];  [NSUserDefaults.standardUserDefaults setObject:_footerRight forKey:kFooterRight]; }

// -- NSPrintPanelAccessorizing ---------------------------------------------------------------------

- (NSSet<NSString *> *)keyPathsForValuesAffectingPreview {
    return [NSSet setWithArray:@[ @"colourMode", @"printLineNumbers", @"magnification",
                                  @"headerLeft", @"headerMiddle", @"headerRight",
                                  @"footerLeft", @"footerMiddle", @"footerRight" ]];
}

- (NSArray<NSDictionary<NSPrintPanelAccessorySummaryKey, NSString *> *> *)localizedSummaryItems {
    NSArray *names = @[ NSLocalizedString(@"WYSIWYG", nil), NSLocalizedString(@"Invert", nil),
                        NSLocalizedString(@"Black on white", nil), NSLocalizedString(@"No background colour", nil),
                        NSLocalizedString(@"No background colour (default)", nil) ];
    NSString *mode = NSLocalizedString(@"WYSIWYG", nil);
    for (NSInteger i = 0; i < (NSInteger)(sizeof(kColourModes) / sizeof(kColourModes[0])); i++)
        if (kColourModes[i] == self.colourMode) mode = names[i];
    return @[
        @{ NSPrintPanelAccessorySummaryItemNameKey: NSLocalizedString(@"Colour options", nil),
           NSPrintPanelAccessorySummaryItemDescriptionKey: mode },
        @{ NSPrintPanelAccessorySummaryItemNameKey: NSLocalizedString(@"Line numbers", nil),
           NSPrintPanelAccessorySummaryItemDescriptionKey: self.printLineNumbers ? NSLocalizedString(@"Yes", nil) : NSLocalizedString(@"No", nil) },
        @{ NSPrintPanelAccessorySummaryItemNameKey: NSLocalizedString(@"Zoom", nil),
           NSPrintPanelAccessorySummaryItemDescriptionKey: [NSString stringWithFormat:@"%+ld", (long)self.magnification] },
    ];
}

@end

// ---------------------------------------------------------------------------------------------------
// The paginating view

@interface NPPPrintView : NSView
@property (nonatomic, strong) ScintillaView *editor;
@property (nonatomic, copy) NSString *docName;
@property (nonatomic) sptr_t rangeStart, rangeEnd;
@end

@implementation NPPPrintView {
    // One entry per page: {first position, length}. The length is what a form feed cut the page down to, so
    // drawing hands Scintilla the same range pagination measured.
    NSMutableArray<NSValue *> *_pageRanges;
    CGFloat _contentW, _contentH;              // one page's drawable box, in points
    CGFloat _headerBand, _footerBand;
    int _textTop, _textHeight;                 // text box inside the page box, integral so measure == draw
    // saved editor state
    BOOL _saved;
    sptr_t _savedColourMode, _savedMagnification, _savedLineNumberWidth;
    int _lineNumberMargin;
    NSEdgeInsets _userMargins;                 // captured once, so re-paginating cannot ratchet them up
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }

- (instancetype)initWithEditor:(ScintillaView *)editor name:(NSString *)name start:(sptr_t)start end:(sptr_t)end {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 612, 792)])) return nil;
    NPPPrintRegisterDefaults();
    _editor = editor;
    _docName = [name copy] ?: @"";
    _rangeStart = start;
    _rangeEnd = end;
    _pageRanges = [NSMutableArray array];
    _lineNumberMargin = -1;
    NSPrintInfo *shared = NSPrintInfo.sharedPrintInfo;
    _userMargins = NSEdgeInsetsMake(shared.topMargin, shared.leftMargin, shared.bottomMargin, shared.rightMargin);
    return self;
}

// -- editor state ----------------------------------------------------------------------------------

- (int)lineNumberMarginIndex {
    if (_lineNumberMargin >= 0) return _lineNumberMargin;
    ScintillaView *ed = self.editor;
    sptr_t count = ed ? [ed message:SCI_GETMARGINS wParam:0 lParam:0] : 0;
    for (sptr_t i = 0; i < count; i++)
        if ([ed message:SCI_GETMARGINTYPEN wParam:(uptr_t)i lParam:0] == SC_MARGIN_NUMBER) { _lineNumberMargin = (int)i; break; }
    if (_lineNumberMargin < 0) _lineNumberMargin = 0;   // N++ keeps line numbers in margin 0
    return _lineNumberMargin;
}

// Applies the print settings to the borrowed editor, remembering the originals on the first call.
- (void)applySettings {
    ScintillaView *ed = self.editor;
    if (!ed) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    const int marginIdx = [self lineNumberMarginIndex];
    if (!_saved) {
        _savedColourMode = [ed message:SCI_GETPRINTCOLOURMODE wParam:0 lParam:0];
        _savedMagnification = [ed message:SCI_GETPRINTMAGNIFICATION wParam:0 lParam:0];
        _savedLineNumberWidth = [ed message:SCI_GETMARGINWIDTHN wParam:(uptr_t)marginIdx lParam:0];
        _saved = YES;
    }
    [ed message:SCI_SETPRINTCOLOURMODE wParam:(uptr_t)[d integerForKey:kColourMode] lParam:0];
    // SCI_SETPRINTMAGNIFICATION takes its value in wParam (Editor.cxx: printParameters.magnification = wParam);
    // passing it in lParam is a silent no-op — the Zoom stepper and the Print page then look live and do nothing.
    [ed message:SCI_SETPRINTMAGNIFICATION wParam:(uptr_t)NPPPrintMagnification([d integerForKey:kMagnify]) lParam:0];
    // Scintilla prints the line-number margin only when it is a Number margin with a non-zero width.
    sptr_t width = [d boolForKey:kLineNumbers] ? (_savedLineNumberWidth > 0 ? _savedLineNumberWidth : 32) : 0;
    [ed message:SCI_SETMARGINWIDTHN wParam:(uptr_t)marginIdx lParam:width];
}

- (void)restoreEditorState {
    ScintillaView *ed = self.editor;
    if (!ed || !_saved) return;
    [ed message:SCI_FORMATRANGEFULL wParam:0 lParam:0];      // release Scintilla's print-formatting state (N++ does this)
    [ed message:SCI_SETPRINTCOLOURMODE wParam:(uptr_t)_savedColourMode lParam:0];
    [ed message:SCI_SETPRINTMAGNIFICATION wParam:(uptr_t)_savedMagnification lParam:0];
    [ed message:SCI_SETMARGINWIDTHN wParam:(uptr_t)[self lineNumberMarginIndex] lParam:_savedLineNumberWidth];
    _saved = NO;
}

- (void)dealloc { [self restoreEditorState]; }

// -- geometry --------------------------------------------------------------------------------------

- (BOOL)headerPresent {
    return NPPPrintStr(kHeaderLeft).length || NPPPrintStr(kHeaderMiddle).length || NPPPrintStr(kHeaderRight).length;
}
- (BOOL)footerPresent {
    return NPPPrintStr(kFooterLeft).length || NPPPrintStr(kFooterMiddle).length || NPPPrintStr(kFooterRight).length;
}

- (void)computeGeometryForPrintInfo:(NSPrintInfo *)pi {
    NSSize paper = pi.paperSize;
    NSRect imageable = pi.imageablePageBounds;
    if (imageable.size.width <= 0 || imageable.size.height <= 0) imageable = NSMakeRect(0, 0, paper.width, paper.height);

    // Never draw outside what the printer can reach (N++ clamps user margins to the physical ones).
    NSEdgeInsets want = NPPPrintRequestedMargins(_userMargins);
    CGFloat left   = MAX(want.left,   NSMinX(imageable));
    CGFloat right  = MAX(want.right,  paper.width  - NSMaxX(imageable));
    CGFloat top    = MAX(want.top,    paper.height - NSMaxY(imageable));
    CGFloat bottom = MAX(want.bottom, NSMinY(imageable));
    pi.leftMargin = left; pi.rightMargin = right; pi.topMargin = top; pi.bottomMargin = bottom;

    _contentW = MAX(72.0, paper.width - left - right);
    _contentH = MAX(72.0, paper.height - top - bottom);

    CGFloat headerLH = NPPPrintLineHeight(NPPPrintBandFont(YES));
    CGFloat footerLH = NPPPrintLineHeight(NPPPrintBandFont(NO));
    // N++ reserves 1.5 line heights; 2 leaves room for descenders inside AppKit's page clip.
    _headerBand = [self headerPresent] ? ceil(headerLH * 2.0) : 0;
    _footerBand = [self footerPresent] ? ceil(footerLH * 2.0) : 0;

    _textTop = (int)_headerBand;
    _textHeight = (int)floor(_contentH - _headerBand - _footerBand);
    if (_textHeight < 16) _textHeight = 16;
}

- (int)pageTopForPage:(NSInteger)page { return (int)lround((page - 1) * _contentH); }

// -- pagination ------------------------------------------------------------------------------------

- (BOOL)knowsPageRange:(NSRangePointer)range {
    NSPrintOperation *op = NSPrintOperation.currentOperation;
    NSPrintInfo *pi = op.printInfo ?: NSPrintInfo.sharedPrintInfo;
    [self computeGeometryForPrintInfo:pi];
    [self applySettings];

    [_pageRanges removeAllObjects];

    ScintillaView *ed = self.editor;
    sptr_t docLen = ed ? [ed message:SCI_GETLENGTH wParam:0 lParam:0] : 0;
    sptr_t start = MAX((sptr_t)0, MIN(_rangeStart, docLen));
    sptr_t end = MAX(start, MIN(_rangeEnd, docLen));

    if (ed && end > start) {
        // A 1x1 bitmap is enough to measure with: CoreText metrics do not depend on the destination
        // surface, so these page breaks match the ones the print context produces (verified).
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef measure = CGBitmapContextCreate(NULL, 1, 1, 8, 0, cs,
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
        CGColorSpaceRelease(cs);
        if (measure) {
            Sci_RangeToFormatFull fr = {};
            fr.hdc = (Sci_SurfaceID)measure;
            fr.hdcTarget = (Sci_SurfaceID)measure;
            fr.rc = (Sci_Rectangle){ 0, 0, (int)_contentW, _textHeight };
            fr.rcPage = (Sci_Rectangle){ 0, 0, (int)_contentW, (int)_contentH };
            sptr_t pos = start;
            // ponytail: 5000-page ceiling; also the loop bails the moment Scintilla stops advancing, so a
            // pathological page box can never hang the print panel.
            while (pos < end && _pageRanges.count < 5000) {
                sptr_t formFeed = NPPPrintFindFormFeed(ed, pos, end);
                sptr_t pageEnd = NPPPrintPageEnd(pos, end, formFeed);
                fr.chrg.cpMin = pos;
                fr.chrg.cpMax = pageEnd;
                // A form feed sitting on the page break gives an empty range: no text, but still a page.
                sptr_t next = (pageEnd > pos) ? [ed message:SCI_FORMATRANGEFULL wParam:0 lParam:(sptr_t)&fr] : pos;
                next = NPPPrintAdvance(next, pageEnd, formFeed);
                sptr_t drawnEnd = MAX(pos, MIN(next, pageEnd));   // never an inverted range, even if Scintilla stalls
                [_pageRanges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)pos, (NSUInteger)(drawnEnd - pos))]];
                if (next <= pos) break;
                pos = next;
            }
            [ed message:SCI_FORMATRANGEFULL wParam:0 lParam:0];
            CGContextRelease(measure);
        }
    }
    // Empty document (or empty selection) still prints one blank page.
    if (_pageRanges.count == 0) [_pageRanges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)start, 0)]];

    [self setFrameSize:NSMakeSize(_contentW, _contentH * _pageRanges.count)];
    if (range) *range = NSMakeRange(1, _pageRanges.count);
    return YES;
}

- (NSRect)rectForPage:(NSInteger)page {
    if (page < 1) page = 1;
    return NSMakeRect(0, (page - 1) * _contentH, _contentW, _contentH);
}

// -- drawing ---------------------------------------------------------------------------------------

- (void)drawBand:(BOOL)header page:(NSInteger)page top:(CGFloat)bandTop {
    NSFont *font = NPPPrintBandFont(header);
    CGFloat lh = NPPPrintLineHeight(font);
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor };
    NSString *parts[3] = { NPPPrintStr(header ? kHeaderLeft : kFooterLeft),
                           NPPPrintStr(header ? kHeaderMiddle : kFooterMiddle),
                           NPPPrintStr(header ? kHeaderRight : kFooterRight) };
    CGFloat textY = bandTop + lh * (header ? 0.4 : 0.6);
    for (int i = 0; i < 3; i++) {
        NSString *s = NPPPrintExpand(parts[i], self.docName, page);
        if (s.length == 0) continue;
        NSSize sz = [s sizeWithAttributes:attrs];
        CGFloat x = (i == 0) ? 5.0
                  : (i == 1) ? (_contentW - sz.width) / 2.0
                             : (_contentW - sz.width);
        if (x < 0) x = 0;
        [s drawAtPoint:NSMakePoint(x, textY) withAttributes:attrs];
    }
    // The rule N++ draws under the header / above the footer.
    CGFloat ruleY = bandTop + lh * (header ? 1.7 : 0.3);
    NSBezierPath *rule = [NSBezierPath bezierPath];
    [rule moveToPoint:NSMakePoint(0, ruleY)];
    [rule lineToPoint:NSMakePoint(_contentW, ruleY)];
    rule.lineWidth = 0.5;
    [NSColor.blackColor setStroke];
    [rule stroke];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSPrintOperation *op = NSPrintOperation.currentOperation;
    if (!op) return;   // only ever drawn while printing

    NSInteger page = op.currentPage;
    if (page < 1) page = 1;
    if ((NSUInteger)page > _pageRanges.count) return;

    ScintillaView *ed = self.editor;
    if (!ed) return;
    [self applySettings];

    // The stored range is what pagination measured for this page — a form feed already cut it short there.
    NSRange pageRange = _pageRanges[page - 1].rangeValue;
    sptr_t docLen = [ed message:SCI_GETLENGTH wParam:0 lParam:0];
    sptr_t start = MAX((sptr_t)0, MIN((sptr_t)pageRange.location, docLen));
    sptr_t end = MAX(start, MIN((sptr_t)NSMaxRange(pageRange), docLen));

    const int pageTop = [self pageTopForPage:page];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    if (end > start) {
        Sci_RangeToFormatFull fr = {};
        fr.hdc = (Sci_SurfaceID)ctx;
        fr.hdcTarget = (Sci_SurfaceID)ctx;
        fr.rc = (Sci_Rectangle){ 0, pageTop + _textTop, (int)_contentW, pageTop + _textTop + _textHeight };
        fr.rcPage = (Sci_Rectangle){ 0, pageTop, (int)_contentW, pageTop + (int)_contentH };
        fr.chrg.cpMin = start;
        fr.chrg.cpMax = end;
        CGContextSaveGState(ctx);
        [ed message:SCI_FORMATRANGEFULL wParam:1 lParam:(sptr_t)&fr];
        CGContextRestoreGState(ctx);
    }

    if (_headerBand > 0) {
        CGContextSaveGState(ctx);
        [self drawBand:YES page:page top:pageTop];
        CGContextRestoreGState(ctx);
    }
    if (_footerBand > 0) {
        CGContextSaveGState(ctx);
        [self drawBand:NO page:page top:pageTop + _contentH - _footerBand];
        CGContextRestoreGState(ctx);
    }
}

@end

// ---------------------------------------------------------------------------------------------------

@implementation NPPPrintRenderer

+ (void)runForEditor:(ScintillaView *)editor name:(NSString *)name
               start:(sptr_t)start end:(sptr_t)end window:(NSWindow *)window showPanel:(BOOL)showPanel {
    if (!editor) return;
    NPPPrintRegisterDefaults();

    NPPPrintView *view = [[NPPPrintView alloc] initWithEditor:editor name:(name ?: @"") start:start end:end];

    NSPrintInfo *pi = [NSPrintInfo.sharedPrintInfo copy];
    pi.horizontalPagination = NSPrintingPaginationModeClip;
    pi.verticalPagination = NSPrintingPaginationModeClip;
    pi.horizontallyCentered = NO;
    pi.verticallyCentered = NO;

    NSPrintOperation *op = [NSPrintOperation printOperationWithView:view printInfo:pi];
    op.jobTitle = name.length ? name.lastPathComponent : NSLocalizedString(@"Untitled", nil);
    op.showsPrintPanel = showPanel;
    op.showsProgressPanel = YES;
    op.printPanel.options |= NSPrintPanelShowsPreview | NSPrintPanelShowsPaperSize | NSPrintPanelShowsOrientation;
    [op.printPanel addAccessoryController:[[NPPPrintAccessory alloc] init]];

    if (window) {
        // contextInfo owns the view for the length of the sheet; the didRun callback hands it back.
        [op runOperationModalForWindow:window delegate:self
                        didRunSelector:@selector(printOperationDidRun:success:contextInfo:)
                           contextInfo:(__bridge_retained void *)view];
    } else {
        [op runOperation];
        [view restoreEditorState];
    }
}

+ (void)printOperationDidRun:(NSPrintOperation *)op success:(BOOL)success contextInfo:(void *)contextInfo {
    NPPPrintView *view = (__bridge_transfer NPPPrintView *)contextInfo;
    [view restoreEditorState];
}

+ (void)printEditor:(ScintillaView *)editor documentName:(NSString *)name window:(NSWindow *)window {
    [self printEditor:editor documentName:name window:window showPanel:YES];
}

+ (void)printEditor:(ScintillaView *)editor documentName:(NSString *)name window:(NSWindow *)window showPanel:(BOOL)showPanel {
    if (!editor) return;
    sptr_t len = [editor message:SCI_GETLENGTH wParam:0 lParam:0];
    [self runForEditor:editor name:name start:0 end:len window:window showPanel:showPanel];
}

+ (void)printSelectionOfEditor:(ScintillaView *)editor documentName:(NSString *)name window:(NSWindow *)window {
    if (!editor) return;
    sptr_t len = [editor message:SCI_GETLENGTH wParam:0 lParam:0];
    sptr_t a = [editor message:SCI_GETSELECTIONSTART wParam:0 lParam:0];
    sptr_t b = [editor message:SCI_GETSELECTIONEND wParam:0 lParam:0];
    if (a > b) { sptr_t t = a; a = b; b = t; }
    if (b <= a) { a = 0; b = len; }                      // nothing selected -> whole document, like N++
    [self runForEditor:editor name:name start:a end:MIN(b, len) window:window showPanel:YES];
}

// -- <NPPCommandHandler> ---------------------------------------------------------------------------

+ (BOOL)handlesCommand:(NPPCmd)cmd { return cmd == NPPCmdFilePrint; }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdFilePrint) return NO;
    return [context contextCurrentDocument].editor != nil;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (cmd != NPPCmdFilePrint) return NO;
    NPPDocument *doc = [context contextCurrentDocument];
    if (!doc.editor) return NO;
    NSString *name = doc.fileURL.path ?: doc.displayName;
    [self printSelectionOfEditor:doc.editor documentName:name window:[context contextWindow]];
    return YES;
}

// -- self checks -----------------------------------------------------------------------------------

// Scintilla wants a real view hierarchy, so the settings check borrows a hidden window (as NPPEditCommands does).
static ScintillaView *NPPPrintScratchEditor(void) {
    static NSWindow *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
        host.releasedWhenClosed = NO;
    });
    ScintillaView *ed = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    [host.contentView addSubview:ed];
    return ed;
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(NSString *, BOOL, NSString *) = ^(NSString *what, BOOL ok, NSString *detail) {
        if (!ok) [fails addObject:[NSString stringWithFormat:@"%@: %@", what, detail ?: @""]];
    };

    // ---- margins (N++ PrintSettings::_marge, millimetres) ----
    expect(@"print.mm-to-points", fabs(NPPPrintPointsFromMM(100) - 283.4646) < 0.01,
           [NSString stringWithFormat:@"100 mm is %g pt", NPPPrintPointsFromMM(100)]);
    expect(@"print.mm-zero", NPPPrintPointsFromMM(0) == 0.0, @"0 mm is not 0 pt");
    expect(@"print.mm-clamped", NPPPrintPointsFromMM(1000) == NPPPrintPointsFromMM(100),
           @"a plist-sized margin is not clamped to the page's 100 mm maximum");

    const NSEdgeInsets panel = NSEdgeInsetsMake(11, 22, 33, 44);   // distinctive, so a wrong side shows up
    NSEdgeInsets got = NPPPrintMarginsFromMM(0, 0, 0, 0, panel);
    expect(@"print.margins-all-zero-uses-panel",
           got.top == panel.top && got.left == panel.left && got.bottom == panel.bottom && got.right == panel.right,
           @"0 mm on every side did not fall back to the print panel's margins");
    got = NPPPrintMarginsFromMM(10, 20, 30, 40, panel);
    expect(@"print.margins-mm-win",
           fabs(got.top - NPPPrintPointsFromMM(10)) < 0.01 && fabs(got.left - NPPPrintPointsFromMM(20)) < 0.01 &&
           fabs(got.right - NPPPrintPointsFromMM(30)) < 0.01 && fabs(got.bottom - NPPPrintPointsFromMM(40)) < 0.01,
           [NSString stringWithFormat:@"got t%g l%g b%g r%g", got.top, got.left, got.bottom, got.right]);
    got = NPPPrintMarginsFromMM(10, 0, 0, 0, panel);   // isUserMargePresent(): one side switches all four
    expect(@"print.margins-one-side-switches-all", got.left == 0 && got.right == 0 && got.bottom == 0,
           [NSString stringWithFormat:@"top-only margins left the panel's other sides: l%g b%g r%g", got.left, got.bottom, got.right]);

    // ---- form feed as page break (N++ Printer::doPrint) ----
    expect(@"print.ff-absent", NPPPrintPageEnd(100, 900, -1) == 900 && NPPPrintAdvance(400, 900, -1) == 400,
           @"a document without a form feed does not page normally");
    expect(@"print.ff-stops-page", NPPPrintPageEnd(100, 900, 500) == 499,
           [NSString stringWithFormat:@"page ends at %lld, want 499", (long long)NPPPrintPageEnd(100, 900, 500)]);
    expect(@"print.ff-page-starts-after-it", NPPPrintAdvance(499, 499, 500) == 501,
           [NSString stringWithFormat:@"next page starts at %lld, want 501", (long long)NPPPrintAdvance(499, 499, 500)]);
    expect(@"print.ff-at-page-start", NPPPrintPageEnd(500, 900, 500) == 500 && NPPPrintAdvance(500, 500, 500) == 501,
           @"a form feed on the page break neither ends the page nor steps past itself (would loop forever)");
    expect(@"print.ff-at-document-start", NPPPrintPageEnd(0, 900, 0) == 0 && NPPPrintAdvance(0, 0, 0) == 1,
           @"a leading form feed does not resolve to an empty first page");
    // The page filled up before reaching the form feed: it must resume where it stopped, not jump past the feed
    // (N++ jumps unconditionally and loses everything in between).
    expect(@"print.ff-full-page-keeps-its-text", NPPPrintAdvance(300, 499, 500) == 300,
           [NSString stringWithFormat:@"resumed at %lld, want 300", (long long)NPPPrintAdvance(300, 499, 500)]);

    // ---- header/footer fonts (independent name, size, bold, italic) ----
    NSFontManager *fm = NSFontManager.sharedFontManager;
    NSFont *plain = NPPPrintFont(@"", 0, NO, NO);
    expect(@"print.font-default-size", plain && fabs(plain.pointSize - 9.0) < 0.01,
           [NSString stringWithFormat:@"default band font is %g pt, want 9", plain.pointSize]);
    NSFont *sized = NPPPrintFont(@"Helvetica", 14, NO, NO);
    expect(@"print.font-size", fabs(sized.pointSize - 14.0) < 0.01,
           [NSString stringWithFormat:@"size 14 gave %g pt", sized.pointSize]);
    expect(@"print.font-size-clamped", fabs(NPPPrintFont(@"", 500, NO, NO).pointSize - 9.0) < 0.01,
           @"an out-of-range size is not rejected");
    expect(@"print.font-family", [NPPPrintFont(@"Courier", 12, NO, NO).familyName isEqualToString:@"Courier"],
           [NSString stringWithFormat:@"asked for Courier, got %@", NPPPrintFont(@"Courier", 12, NO, NO).familyName]);
    NSFont *fallback = NPPPrintFont(@"No Such Family At All", 12, NO, NO);
    expect(@"print.font-unknown-family-falls-back", fallback != nil && fabs(fallback.pointSize - 12.0) < 0.01,
           fallback ? [NSString stringWithFormat:@"the fallback font is %g pt, want 12", fallback.pointSize]
                    : @"an unknown family did not fall back to a usable font (nil would take the band down with it)");
    expect(@"print.font-bold", ([fm traitsOfFont:NPPPrintFont(@"Helvetica", 9, YES, NO)] & NSBoldFontMask) != 0,
           @"bold was not applied");
    expect(@"print.font-italic", ([fm traitsOfFont:NPPPrintFont(@"Helvetica", 9, NO, YES)] & NSItalicFontMask) != 0,
           @"italic was not applied");
    expect(@"print.font-plain-has-no-traits",
           ([fm traitsOfFont:NPPPrintFont(@"Helvetica", 9, NO, NO)] & (NSBoldFontMask | NSItalicFontMask)) == 0,
           @"the band font is bold or italic without being asked");

    // Header and footer read their own keys: set them differently and check both come back right. Restoring the
    // captured value (rather than the key's absence) is enough — every consumer only ever reads the value.
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *keys = @[kHeaderFontName, kHeaderFontSize, kHeaderFontBold, kHeaderFontItalic,
                                  kFooterFontName, kFooterFontSize, kFooterFontBold, kFooterFontItalic];
    NSMutableDictionary<NSString *, id> *before = [NSMutableDictionary dictionary];
    for (NSString *k in keys) { id v = [d objectForKey:k]; if (v) before[k] = v; }
    [d setObject:@"Courier" forKey:kHeaderFontName];
    [d setInteger:16 forKey:kHeaderFontSize]; [d setBool:YES forKey:kHeaderFontBold]; [d setBool:NO forKey:kHeaderFontItalic];
    [d setObject:@"Times" forKey:kFooterFontName];
    [d setInteger:11 forKey:kFooterFontSize]; [d setBool:NO forKey:kFooterFontBold];  [d setBool:YES forKey:kFooterFontItalic];
    NSFont *header = NPPPrintBandFont(YES), *footer = NPPPrintBandFont(NO);
    expect(@"print.header-font-wired", [header.familyName isEqualToString:@"Courier"] && fabs(header.pointSize - 16.0) < 0.01 &&
           ([fm traitsOfFont:header] & NSBoldFontMask) != 0 && ([fm traitsOfFont:header] & NSItalicFontMask) == 0,
           [NSString stringWithFormat:@"header font is %@ %g pt, want Courier 16 bold", header.fontName, header.pointSize]);
    expect(@"print.footer-font-wired", [footer.familyName isEqualToString:@"Times"] && fabs(footer.pointSize - 11.0) < 0.01 &&
           ([fm traitsOfFont:footer] & NSBoldFontMask) == 0 && ([fm traitsOfFont:footer] & NSItalicFontMask) != 0,
           [NSString stringWithFormat:@"footer font is %@ %g pt, want Times 11 italic", footer.fontName, footer.pointSize]);
    for (NSString *k in keys) { if (before[k]) [d setObject:before[k] forKey:k]; else [d removeObjectForKey:k]; }

    // ---- the settings that have to reach Scintilla itself ----
    // Colour mode, zoom and the line-number margin only exist as SCI_SET* calls, so the only honest check is on a
    // real editor: a preference that never lands (wrong parameter, forgotten call) leaves a live control doing
    // nothing. Also covers the restore path — the editor is borrowed, not copied.
    expect(@"print.magnification-clamped", NPPPrintMagnification(99) == 10 && NPPPrintMagnification(-99) == -10 &&
           NPPPrintMagnification(-4) == -4, @"the zoom range is not the Print page's -10..10");
    NSArray<NSString *> *applyKeys = @[kColourMode, kMagnify, kLineNumbers];
    NSMutableDictionary<NSString *, id> *savedApply = [NSMutableDictionary dictionary];
    for (NSString *k in applyKeys) { id v = [d objectForKey:k]; if (v) savedApply[k] = v; }
    ScintillaView *ed = NPPPrintScratchEditor();
    [ed message:SCI_SETPRINTCOLOURMODE wParam:(uptr_t)SC_PRINT_NORMAL lParam:0];
    [ed message:SCI_SETPRINTMAGNIFICATION wParam:(uptr_t)3 lParam:0];   // distinctive "before", to prove the restore
    NPPPrintView *pv = [[NPPPrintView alloc] initWithEditor:ed name:@"x" start:0 end:0];
    const uptr_t marginIdx = (uptr_t)[pv lineNumberMarginIndex];
    [d setInteger:SC_PRINT_BLACKONWHITE forKey:kColourMode];
    [d setInteger:-4 forKey:kMagnify];
    [d setBool:YES forKey:kLineNumbers];
    [pv applySettings];
    sptr_t gotMode = [ed message:SCI_GETPRINTCOLOURMODE wParam:0 lParam:0];
    sptr_t gotMag = [ed message:SCI_GETPRINTMAGNIFICATION wParam:0 lParam:0];
    sptr_t gotWidth = [ed message:SCI_GETMARGINWIDTHN wParam:marginIdx lParam:0];
    expect(@"print.applies-colour-mode", gotMode == SC_PRINT_BLACKONWHITE,
           [NSString stringWithFormat:@"editor print colour mode is %lld, want %d", (long long)gotMode, SC_PRINT_BLACKONWHITE]);
    expect(@"print.applies-magnification", gotMag == -4,
           [NSString stringWithFormat:@"editor print magnification is %lld, want -4 (wrong parameter?)", (long long)gotMag]);
    expect(@"print.applies-line-numbers", gotWidth > 0,
           @"“Print line numbers” left the number margin at zero width, so Scintilla prints none");
    [d setInteger:500 forKey:kMagnify];
    [pv applySettings];
    expect(@"print.applies-clamped-magnification", [ed message:SCI_GETPRINTMAGNIFICATION wParam:0 lParam:0] == 10,
           @"an out-of-range stored zoom reached Scintilla unclamped");
    [d setBool:NO forKey:kLineNumbers];
    [pv applySettings];
    expect(@"print.line-numbers-off", [ed message:SCI_GETMARGINWIDTHN wParam:marginIdx lParam:0] == 0,
           @"the number margin stayed wide with “Print line numbers” off");
    [pv restoreEditorState];
    expect(@"print.restores-editor-state",
           [ed message:SCI_GETPRINTCOLOURMODE wParam:0 lParam:0] == SC_PRINT_NORMAL &&
           [ed message:SCI_GETPRINTMAGNIFICATION wParam:0 lParam:0] == 3 &&
           [ed message:SCI_GETMARGINWIDTHN wParam:marginIdx lParam:0] == 0,
           @"the borrowed editor did not get its own print settings back");
    for (NSString *k in applyKeys) { if (savedApply[k]) [d setObject:savedApply[k] forKey:k]; else [d removeObjectForKey:k]; }

    // The millimetre margins have to reach the page, not just NPPPrintMarginsFromMM: -computeGeometryForPrintInfo:
    // writes them back onto the NSPrintInfo, which is what AppKit lays the page out with. 50 mm is far larger than
    // any printer's physical margin, so the MAX() clamp cannot mask a setting that was never read.
    NSArray<NSString *> *mmKeys = @[kMarginTop, kMarginLeft, kMarginRight, kMarginBottom];
    NSMutableDictionary<NSString *, id> *savedMM = [NSMutableDictionary dictionary];
    for (NSString *k in mmKeys) { id v = [d objectForKey:k]; if (v) savedMM[k] = v; }
    for (NSString *k in mmKeys) [d setInteger:50 forKey:k];
    NSPrintInfo *pi = [NSPrintInfo.sharedPrintInfo copy];
    [[[NPPPrintView alloc] initWithEditor:ed name:@"x" start:0 end:0] computeGeometryForPrintInfo:pi];
    const CGFloat want50 = NPPPrintPointsFromMM(50);
    expect(@"print.mm-margins-reach-the-page",
           fabs(pi.topMargin - want50) < 0.01 && fabs(pi.leftMargin - want50) < 0.01 &&
           fabs(pi.rightMargin - want50) < 0.01 && fabs(pi.bottomMargin - want50) < 0.01,
           [NSString stringWithFormat:@"50 mm on every side gave t%g l%g b%g r%g, want %g",
                                      pi.topMargin, pi.leftMargin, pi.bottomMargin, pi.rightMargin, want50]);
    for (NSString *k in mmKeys) { if (savedMM[k]) [d setObject:savedMM[k] forKey:k]; else [d removeObjectForKey:k]; }

    // "Print formfeed as page break" has to reach pagination, which is the only place it is read. Same document,
    // setting off then on: three form-feed-separated lines are one page, then three.
    id savedFF = [d objectForKey:kFormFeed];
    // -knowsPageRange: falls back to +sharedPrintInfo outside a print operation and -computeGeometryForPrintInfo:
    // writes the margins back onto it, so put the user's own page setup back afterwards.
    NSPrintInfo *shared = NSPrintInfo.sharedPrintInfo;
    const NSEdgeInsets sharedMargins = NSEdgeInsetsMake(shared.topMargin, shared.leftMargin,
                                                        shared.bottomMargin, shared.rightMargin);
    ScintillaView *ffEd = NPPPrintScratchEditor();
    ffEd.string = @"alpha\n\fbeta\n\fgamma\n";
    sptr_t ffLen = [ffEd message:SCI_GETLENGTH wParam:0 lParam:0];
    NSUInteger (^pageCount)(BOOL) = ^NSUInteger(BOOL on) {
        [d setBool:on forKey:kFormFeed];
        NPPPrintView *v = [[NPPPrintView alloc] initWithEditor:ffEd name:@"x" start:0 end:ffLen];
        NSRange r = NSMakeRange(0, 0);
        [v knowsPageRange:&r];
        [v restoreEditorState];
        return r.length;
    };
    NSUInteger off = pageCount(NO), on = pageCount(YES);
    expect(@"print.formfeed-off-is-one-page", off == 1,
           [NSString stringWithFormat:@"three short lines paginated to %lu pages with the setting off", (unsigned long)off]);
    expect(@"print.formfeed-breaks-pages", on == 3,
           [NSString stringWithFormat:@"two form feeds gave %lu pages, want 3", (unsigned long)on]);
    if (savedFF) [d setObject:savedFF forKey:kFormFeed]; else [d removeObjectForKey:kFormFeed];
    shared.topMargin = sharedMargins.top;   shared.leftMargin = sharedMargins.left;
    shared.bottomMargin = sharedMargins.bottom; shared.rightMargin = sharedMargins.right;

    // ---- header/footer variables (N++ IDC_COMBO_VARLIST, plus the aliases the print accessory shows) ----
    NSString *doc = @"/Users/x/Documents/report.txt";
    expect(@"print.var-page", [NPPPrintExpand(@"page $(CURRENT_PRINTING_PAGE)", doc, 7) isEqualToString:@"page 7"],
           NPPPrintExpand(@"page $(CURRENT_PRINTING_PAGE)", doc, 7));
    expect(@"print.var-page-alias", [NPPPrintExpand(@"$(CURRENT_PAGE)", doc, 7) isEqualToString:@"7"],
           NPPPrintExpand(@"$(CURRENT_PAGE)", doc, 7));
    expect(@"print.var-file-name", [NPPPrintExpand(@"$(FILE_NAME)", doc, 1) isEqualToString:@"report.txt"],
           NPPPrintExpand(@"$(FILE_NAME)", doc, 1));
    expect(@"print.var-name-and-ext", [NPPPrintExpand(@"$(NAME_PART).$(EXT_PART)", doc, 1) isEqualToString:@"report.txt"],
           NPPPrintExpand(@"$(NAME_PART).$(EXT_PART)", doc, 1));
    expect(@"print.var-directory", [NPPPrintExpand(@"$(CURRENT_DIRECTORY)", doc, 1) isEqualToString:@"/Users/x/Documents"],
           NPPPrintExpand(@"$(CURRENT_DIRECTORY)", doc, 1));
    // Every token the Print page offers must be expanded — a leftover "$(" is a variable the page lists and the
    // renderer would print verbatim.
    NSString *all = NPPPrintExpand(@"$(FULL_CURRENT_PATH)|$(FILE_NAME)|$(CURRENT_DIRECTORY)|$(NAME_PART)|$(EXT_PART)|"
                                   @"$(CURRENT_PAGE)|$(CURRENT_PRINTING_PAGE)|$(SHORT_DATE)|$(LONG_DATE)|$(TIME)|"
                                   @"$(CURRENT_DATE)|$(CURRENT_TIME)", doc, 3);
    expect(@"print.var-list-fully-expanded", [all rangeOfString:@"$("].location == NSNotFound, all);
    expect(@"print.var-empty-template", NPPPrintExpand(@"", doc, 1).length == 0, @"an empty part expanded to something");

    return fails;
}

@end
