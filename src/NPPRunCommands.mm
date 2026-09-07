// NPPRunCommands.mm — Run menu: Run dialog, saved commands, "Run output" panel.
#import "NPPRunCommands.h"
#import "NPPDocument.h"
#import "NPPUtils.h"
#import <Scintilla/ScintillaView.h>
#import <Scintilla/Scintilla.h>

static NSString *const kHistoryKey = @"NPPRunHistory";
static NSString *const kSavedKey   = @"NPPRunSavedCommands";   // array of {NPPRunName, NPPRunCommand}
static NSString *const kNameKey    = @"NPPRunName";
static NSString *const kCmdKey     = @"NPPRunCommand";
static const NSUInteger kMaxHistory = 20;

@interface NPPRunCommands () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation NPPRunCommands {
    NSView *_panelView;
    NSTextView *_outputView;
    NSTask *_task;

    // Run dialog
    NSWindow *_runSheet;
    NSComboBox *_commandCombo;
    // Modify sheet
    NSWindow *_modifySheet;
    NSTableView *_savedTable;

    __weak id<NPPCommandContext> _context;
}

+ (instancetype)shared {
    static NPPRunCommands *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPRunCommands alloc] init]; });
    return s;
}

#pragma mark - Defaults-backed lists

- (NSArray<NSDictionary *> *)savedEntries {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:kSavedKey];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}

- (void)setSavedEntries:(NSArray<NSDictionary *> *)entries {
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:kSavedKey];
}

- (NSArray<NSString *> *)savedCommandNames {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *d in [self savedEntries]) {
        NSString *n = d[kNameKey];
        [names addObject:[n isKindOfClass:[NSString class]] ? n : @""];
    }
    return names;
}

- (NSString *)savedCommandAtIndex:(NSInteger)index {
    NSArray *entries = [self savedEntries];
    if (index < 0 || index >= (NSInteger)entries.count) return nil;
    NSString *c = entries[index][kCmdKey];
    return [c isKindOfClass:[NSString class]] ? c : nil;
}

- (NSArray<NSString *> *)commandHistory {
    NSArray *a = [[NSUserDefaults standardUserDefaults] stringArrayForKey:kHistoryKey];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}

- (void)rememberCommand:(NSString *)cmd {
    if (cmd.length == 0) return;
    NSMutableArray *h = [[self commandHistory] mutableCopy];
    [h removeObject:cmd];
    [h insertObject:cmd atIndex:0];
    while (h.count > kMaxHistory) [h removeLastObject];
    [[NSUserDefaults standardUserDefaults] setObject:h forKey:kHistoryKey];
}

#pragma mark - Variable expansion

+ (NSArray<NSString *> *)variableNames {
    return @[@"FULL_CURRENT_PATH", @"CURRENT_DIRECTORY", @"FILE_NAME", @"NAME_PART", @"EXT_PART",
             @"NPP_DIRECTORY", @"NPP_FULL_FILE_PATH", @"CURRENT_WORD", @"CURRENT_LINE",
             @"CURRENT_COLUMN", @"CURRENT_LINESTR", @"SELECTED_TEXT"];
}

static NSString *NPPShellQuote(NSString *s) {
    if (!s) s = @"";
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

// Which quote the next character sits inside, scanning the command line left to right.
typedef NS_ENUM(unsigned char, NPPQuoteState) { NPPQuoteNone = 0, NPPQuoteSingle, NPPQuoteDouble };

static NPPQuoteState NPPAdvanceQuoteState(NSString *s, NSRange range, NPPQuoteState state) {
    for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
        unichar c = [s characterAtIndex:i];
        if (state == NPPQuoteSingle) {          // nothing escapes inside single quotes
            if (c == '\'') state = NPPQuoteNone;
        } else if (state == NPPQuoteDouble) {
            if (c == '\\') i++;
            else if (c == '"') state = NPPQuoteNone;
        } else {
            if (c == '\\') i++;
            else if (c == '\'') state = NPPQuoteSingle;
            else if (c == '"') state = NPPQuoteDouble;
        }
    }
    return state;
}

// Substitute a value so /bin/sh sees it as one literal *whatever quoting the user already typed around it*:
// `python3 "$(FULL_CURRENT_PATH)"` (the shape every N++ tutorial uses) must not end up double-quoted.
static NSString *NPPShellSubstitute(NSString *value, NPPQuoteState state) {
    if (!value) value = @"";
    if (state == NPPQuoteNone) return NPPShellQuote(value);
    if (state == NPPQuoteSingle) return [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSMutableString *m = [value mutableCopy];   // only these four are special inside double quotes
    for (NSString *ch in @[@"\\", @"\"", @"$", @"`"])
        [m replaceOccurrencesOfString:ch withString:[@"\\" stringByAppendingString:ch]
                              options:NSLiteralSearch range:NSMakeRange(0, m.length)];
    return m;
}

// nil return = variable not recognised (N++ leaves the text untouched in that case).
+ (NSString *)valueForVariable:(NSString *)name document:(NPPDocument *)doc {
    NSString *path = doc.fileURL.path ?: @"";
    ScintillaView *ed = doc.editor;

    if ([name isEqualToString:@"FULL_CURRENT_PATH"]) return path;
    if ([name isEqualToString:@"CURRENT_DIRECTORY"]) return path.length ? path.stringByDeletingLastPathComponent : @"";
    if ([name isEqualToString:@"FILE_NAME"])         return path.lastPathComponent ?: @"";
    if ([name isEqualToString:@"NAME_PART"])         return path.lastPathComponent.stringByDeletingPathExtension ?: @"";
    if ([name isEqualToString:@"EXT_PART"])          return path.pathExtension ?: @"";
    if ([name isEqualToString:@"NPP_DIRECTORY"])     return [NSBundle mainBundle].bundlePath.stringByDeletingLastPathComponent ?: @"";
    if ([name isEqualToString:@"NPP_FULL_FILE_PATH"]) return [NSBundle mainBundle].bundlePath ?: @"";
    if (!ed) {
        if ([name isEqualToString:@"CURRENT_WORD"] || [name isEqualToString:@"CURRENT_LINESTR"] ||
            [name isEqualToString:@"SELECTED_TEXT"]) return @"";
        if ([name isEqualToString:@"CURRENT_LINE"] || [name isEqualToString:@"CURRENT_COLUMN"]) return @"0";
        return nil;
    }
    if ([name isEqualToString:@"CURRENT_WORD"])      return NPPSciWordAtCaret(ed) ?: @"";
    if ([name isEqualToString:@"SELECTED_TEXT"])     return NPPSciSelectedString(ed) ?: @"";

    sptr_t pos = NPPSci(ed, SCI_GETCURRENTPOS);
    sptr_t line = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)pos);
    // ponytail: N++ semantics — CURRENT_LINE/CURRENT_COLUMN are 0-based (getCurrentLineNumber/SCI_GETCOLUMN).
    if ([name isEqualToString:@"CURRENT_LINE"])   return [NSString stringWithFormat:@"%ld", (long)line];
    if ([name isEqualToString:@"CURRENT_COLUMN"]) return [NSString stringWithFormat:@"%ld", (long)NPPSci(ed, SCI_GETCOLUMN, (uptr_t)pos)];
    if ([name isEqualToString:@"CURRENT_LINESTR"]) {
        sptr_t start = NPPSci(ed, SCI_POSITIONFROMLINE, (uptr_t)line);
        sptr_t end = NPPSci(ed, SCI_GETLINEENDPOSITION, (uptr_t)line);
        std::string s = NPPSciGetRange(ed, start, end);
        return [NSString stringWithUTF8String:s.c_str()] ?: @"";
    }
    return nil;
}

+ (NSString *)expandVariablesIn:(NSString *)source document:(NPPDocument *)doc shellQuote:(BOOL)shellQuote {
    if (source.length == 0) return @"";
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0, len = source.length;
    NPPQuoteState state = NPPQuoteNone;
    while (i < len) {
        NSRange open = [source rangeOfString:@"$(" options:0 range:NSMakeRange(i, len - i)];
        if (open.location == NSNotFound) { [out appendString:[source substringFromIndex:i]]; break; }
        NSRange skipped = NSMakeRange(i, open.location - i);
        [out appendString:[source substringWithRange:skipped]];
        if (shellQuote) state = NPPAdvanceQuoteState(source, skipped, state);
        NSUInteger nameStart = NSMaxRange(open);
        NSRange close = [source rangeOfString:@")" options:0 range:NSMakeRange(nameStart, len - nameStart)];
        if (close.location == NSNotFound) { [out appendString:[source substringFromIndex:open.location]]; break; }
        NSString *name = [source substringWithRange:NSMakeRange(nameStart, close.location - nameStart)];
        NSString *value = [self valueForVariable:name document:doc];
        if (value == nil) [out appendString:[source substringWithRange:NSMakeRange(open.location, NSMaxRange(close) - open.location)]];
        else [out appendString:shellQuote ? NPPShellSubstitute(value, state) : value];
        i = NSMaxRange(close);
    }
    return out;
}

// First token of a command line, honouring double quotes (N++ Command::extractArgs).
static NSString *NPPFirstToken(NSString *cmd) {
    NSMutableString *tok = [NSMutableString string];
    BOOL quoted = NO;
    for (NSUInteger i = 0; i < cmd.length; i++) {
        unichar c = [cmd characterAtIndex:i];
        if (c == '"') { quoted = !quoted; continue; }
        if (c == ' ' && !quoted) break;
        [tok appendFormat:@"%C", c];
    }
    return tok;
}

#pragma mark - Running

- (BOOL)isRunning { return _task.isRunning; }

- (void)runCommandLine:(NSString *)commandLine context:(id<NPPCommandContext>)context {
    _context = context;
    NSString *trimmedSource = [commandLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedSource.length == 0) return;
    [self rememberCommand:trimmedSource];

    NPPDocument *doc = [context contextCurrentDocument];
    NSString *raw = [[self class] expandVariablesIn:trimmedSource document:doc shellQuote:NO];
    raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = raw.lowercaseString;

    // 1. URL scheme -> NSWorkspace
    for (NSString *scheme in @[@"http://", @"https://", @"mailto:"]) {
        if ([lower hasPrefix:scheme]) {
            NSURL *url = [NSURL URLWithString:raw] ?: [NSURL URLWithString:
                [raw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]]];
            if (url) [[NSWorkspace sharedWorkspace] openURL:url];
            else [context contextReportStatus:@"Run: invalid URL" isError:YES];
            return;
        }
    }

    // 2. .app bundle -> launch with the current file as document
    NSString *first = NPPFirstToken(raw);
    if ([first.pathExtension.lowercaseString isEqualToString:@"app"] &&
        [[NSFileManager defaultManager] fileExistsAtPath:first]) {
        NSURL *appURL = [NSURL fileURLWithPath:first];
        NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
        void (^done)(NSRunningApplication *, NSError *) = ^(NSRunningApplication *app, NSError *err) {
            if (err) dispatch_async(dispatch_get_main_queue(), ^{
                [context contextReportStatus:[NSString stringWithFormat:@"Run: %@", err.localizedDescription] isError:YES];
            });
        };
        if (doc.fileURL) [[NSWorkspace sharedWorkspace] openURLs:@[doc.fileURL] withApplicationAtURL:appURL configuration:cfg completionHandler:done];
        else [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL configuration:cfg completionHandler:done];
        return;
    }

    // 3. shell
    NSString *shellCmd = [[self class] expandVariablesIn:trimmedSource document:doc shellQuote:YES];
    [self runShellCommand:shellCmd workingDirectory:doc.fileURL.path.stringByDeletingLastPathComponent context:context];
}

- (void)runShellCommand:(NSString *)shellCmd workingDirectory:(NSString *)cwd context:(id<NPPCommandContext>)context {
    if (_task.isRunning) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"A command is already running";
        a.informativeText = @"Stop the running command before starting another one.";
        [a beginSheetModalForWindow:[context contextWindow] completionHandler:nil];
        return;
    }
    [context contextShowPanel:self];
    [self appendLine:[NSString stringWithFormat:@"> %@", shellCmd] isError:NO];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-lc", shellCmd];
    BOOL isDir = NO;
    if (cwd.length && [[NSFileManager defaultManager] fileExistsAtPath:cwd isDirectory:&isDir] && isDir)
        task.currentDirectoryURL = [NSURL fileURLWithPath:cwd];

    NSPipe *outPipe = [NSPipe pipe], *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    NPPRunCommands *__weak weakSelf = self;
    void (^install)(NSPipe *, BOOL) = ^(NSPipe *pipe, BOOL isErr) {
        pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
            NSData *data = fh.availableData;
            if (data.length == 0) { fh.readabilityHandler = nil; return; }
            NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!chunk) chunk = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            if (chunk.length) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf appendText:chunk isError:isErr]; });
        };
    };
    install(outPipe, NO);
    install(errPipe, YES);

    task.terminationHandler = ^(NSTask *t) {
        // ponytail: never touch the pipes here. A backgrounded grandchild (`cmd &`) keeps the write
        // ends open long after /bin/sh exits, so a readDataToEndOfFile would block for ever, and
        // nilling readabilityHandler from this thread races the handler's own read. The handlers
        // drain the rest themselves and clear at EOF; the trade-off is that a last chunk can land
        // just after the exit line.
        int code = t.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            NPPRunCommands *strong = weakSelf;
            if (!strong) return;
            [strong appendLine:[NSString stringWithFormat:@"[exit code %d]", code] isError:(code != 0)];
            if (strong->_task == t) strong->_task = nil;   // a newer command may already own _task
        });
    };

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        [self appendLine:[NSString stringWithFormat:@"[failed to run: %@]", err.localizedDescription] isError:YES];
        return;
    }
    _task = task;
}

- (void)stopRunningTask {
    if (_task.isRunning) {
        [_task terminate];
        [self appendLine:@"[stopped]" isError:YES];
    }
}

#pragma mark - Output panel

- (NSString *)panelTitle { return @"Run output"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeBottom; }
- (CGFloat)panelPreferredSize { return 180; }

- (NSView *)panelView {
    if (_panelView) return _panelView;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 180)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = YES;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    tv.editable = NO;
    tv.selectable = YES;
    tv.richText = NO;
    tv.drawsBackground = YES;
    tv.backgroundColor = [NSColor textBackgroundColor];
    tv.textColor = [NSColor textColor];
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tv.autoresizingMask = NSViewWidthSizable;
    tv.minSize = NSMakeSize(0, 0);
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.textContainer.widthTracksTextView = YES;
    scroll.documentView = tv;
    _outputView = tv;
    _panelView = scroll;
    return _panelView;
}

- (NSMenu *)panelActionMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Run output"];
    NSMenuItem *clear = [menu addItemWithTitle:@"Clear" action:@selector(actionClear:) keyEquivalent:@""];
    clear.target = self;
    NSMenuItem *stop = [menu addItemWithTitle:@"Stop" action:@selector(actionStop:) keyEquivalent:@""];
    stop.target = self;
    stop.enabled = self.isRunning;
    return menu;
}

- (void)actionClear:(id)sender { [self clearOutput]; }
- (void)actionStop:(id)sender { [self stopRunningTask]; }

- (void)clearOutput {
    (void)self.panelView;
    [_outputView setString:@""];
}

- (void)appendLine:(NSString *)line isError:(BOOL)isError {
    [self appendText:[line stringByAppendingString:@"\n"] isError:isError];
}

- (void)appendText:(NSString *)text isError:(BOOL)isError {
    if (text.length == 0) return;
    (void)self.panelView;   // make sure the text view exists even if the panel was never docked
    NSDictionary *attrs = @{ NSFontAttributeName: _outputView.font ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: isError ? [NSColor systemRedColor] : [NSColor textColor] };
    [_outputView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    [_outputView scrollRangeToVisible:NSMakeRange(_outputView.string.length, 0)];
}

#pragma mark - Run dialog

- (void)showRunDialogWithContext:(id<NPPCommandContext>)context {
    _context = context;
    NSWindow *host = [context contextWindow];
    if (!host || _runSheet) return;

    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 120)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered defer:NO];
    sheet.title = @"Run";
    NSView *content = sheet.contentView;

    NSTextField *label = [NSTextField labelWithString:@"The Program to Run"];
    label.frame = NSMakeRect(20, 84, 300, 17);
    [content addSubview:label];

    NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(20, 54, 380, 26)];
    combo.usesDataSource = NO;
    combo.completes = YES;
    [combo addItemsWithObjectValues:[self commandHistory]];
    if (combo.numberOfItems > 0) combo.stringValue = [self commandHistory].firstObject ?: @"";
    [content addSubview:combo];
    _commandCombo = combo;

    NSPopUpButton *vars = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(406, 54, 96, 26) pullsDown:YES];
    [vars addItemWithTitle:@"Variables"];
    for (NSString *name in [[self class] variableNames]) {
        NSMenuItem *it = [vars.menu addItemWithTitle:[NSString stringWithFormat:@"$(%@)", name]
                                              action:@selector(insertVariable:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = name;
    }
    [content addSubview:vars];

    CGFloat x = 520 - 20 - 90;
    NSButton *run = [NSButton buttonWithTitle:@"Run" target:self action:@selector(runSheetRun:)];
    run.frame = NSMakeRect(x, 12, 90, 32);
    run.keyEquivalent = @"\r";
    [content addSubview:run];

    NSButton *save = [NSButton buttonWithTitle:@"Save..." target:self action:@selector(runSheetSave:)];
    save.frame = NSMakeRect(x - 96, 12, 90, 32);
    [content addSubview:save];

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(runSheetCancel:)];
    cancel.frame = NSMakeRect(x - 192, 12, 90, 32);
    cancel.keyEquivalent = @"\033";
    [content addSubview:cancel];

    _runSheet = sheet;
    [host beginSheet:sheet completionHandler:^(NSModalResponse r) {
        (void)r;
        self->_runSheet = nil;
        self->_commandCombo = nil;
    }];
    [sheet makeFirstResponder:combo];
}

- (void)insertVariable:(NSMenuItem *)sender {
    NSString *var = [NSString stringWithFormat:@"$(%@)", sender.representedObject];
    // ponytail: appends at the end rather than at the text caret; good enough for building a command.
    _commandCombo.stringValue = [(_commandCombo.stringValue ?: @"") stringByAppendingString:var];
}

- (void)runSheetCancel:(id)sender {
    if (_runSheet) [_runSheet.sheetParent endSheet:_runSheet returnCode:NSModalResponseCancel];
}

- (void)runSheetRun:(id)sender {
    NSString *cmd = _commandCombo.stringValue ?: @"";
    id<NPPCommandContext> ctx = _context;
    [self runSheetCancel:sender];
    if (ctx) [self runCommandLine:cmd context:ctx];
}

- (void)runSheetSave:(id)sender {
    NSString *cmd = [(_commandCombo.stringValue ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cmd.length == 0) return;
    NSWindow *sheet = _runSheet;
    [self promptForName:cmd.lastPathComponent onWindow:sheet title:@"Save Command" completion:^(NSString *name) {
        if (name.length == 0) return;
        NSMutableArray *entries = [[self savedEntries] mutableCopy];
        [entries addObject:@{ kNameKey: name, kCmdKey: cmd }];
        [self setSavedEntries:entries];
        [self rememberCommand:cmd];
        id<NPPCommandContext> ctx = self->_context;
        [ctx contextRefreshUI];
        [ctx contextReportStatus:[NSString stringWithFormat:@"Run: saved \"%@\"", name] isError:NO];
    }];
}

- (void)promptForName:(NSString *)initial onWindow:(NSWindow *)window title:(NSString *)title
           completion:(void (^)(NSString *name))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = @"Name:";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.stringValue = initial ?: @"";
    alert.accessoryView = field;
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn)
            completion([field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    };
    if (window) [alert beginSheetModalForWindow:window completionHandler:handle];
    else handle([alert runModal]);
    [field selectText:nil];
}

#pragma mark - Modify saved commands

- (void)showModifyCommandsWithContext:(id<NPPCommandContext>)context {
    _context = context;
    NSWindow *host = [context contextWindow];
    if (!host || _modifySheet) return;

    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 300)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered defer:NO];
    sheet.title = @"Modify Run Commands";
    NSView *content = sheet.contentView;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 56, 380, 224)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"Name";
    nameCol.width = 140;
    [table addTableColumn:nameCol];
    NSTableColumn *cmdCol = [[NSTableColumn alloc] initWithIdentifier:@"command"];
    cmdCol.title = @"Command";
    cmdCol.width = 220;
    [table addTableColumn:cmdCol];
    table.dataSource = self;
    table.delegate = self;
    table.usesAlternatingRowBackgroundColors = YES;
    scroll.documentView = table;
    [content addSubview:scroll];
    _savedTable = table;

    NSButton *rename = [NSButton buttonWithTitle:@"Rename..." target:self action:@selector(modifyRename:)];
    rename.frame = NSMakeRect(20, 14, 100, 32);
    [content addSubview:rename];
    NSButton *del = [NSButton buttonWithTitle:@"Delete" target:self action:@selector(modifyDelete:)];
    del.frame = NSMakeRect(126, 14, 100, 32);
    [content addSubview:del];
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(modifyClose:)];
    close.frame = NSMakeRect(300, 14, 100, 32);
    close.keyEquivalent = @"\r";
    [content addSubview:close];

    _modifySheet = sheet;
    [host beginSheet:sheet completionHandler:^(NSModalResponse r) {
        (void)r;
        self->_modifySheet = nil;
        self->_savedTable = nil;
    }];
}

- (void)modifyClose:(id)sender {
    if (_modifySheet) [_modifySheet.sheetParent endSheet:_modifySheet returnCode:NSModalResponseOK];
    [_context contextRefreshUI];
}

- (void)modifyRename:(id)sender {
    NSInteger row = _savedTable.selectedRow;
    NSArray *entries = [self savedEntries];
    if (row < 0 || row >= (NSInteger)entries.count) return;
    [self promptForName:entries[row][kNameKey] onWindow:_modifySheet title:@"Rename Command" completion:^(NSString *name) {
        if (name.length == 0) return;
        NSMutableArray *m = [[self savedEntries] mutableCopy];
        if (row >= (NSInteger)m.count) return;
        NSMutableDictionary *d = [m[row] mutableCopy];
        d[kNameKey] = name;
        m[row] = d;
        [self setSavedEntries:m];
        [self->_savedTable reloadData];
    }];
}

- (void)modifyDelete:(id)sender {
    NSInteger row = _savedTable.selectedRow;
    NSMutableArray *m = [[self savedEntries] mutableCopy];
    if (row < 0 || row >= (NSInteger)m.count) return;
    [m removeObjectAtIndex:row];
    [self setSavedEntries:m];
    [_savedTable reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)[self savedEntries].count; }

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSArray *entries = [self savedEntries];
    if (row < 0 || row >= (NSInteger)entries.count) return @"";
    return entries[row][[col.identifier isEqualToString:@"name"] ? kNameKey : kCmdKey] ?: @"";
}

#pragma mark - Self test

+ (BOOL)selfTestExpansion {
    // No document: path variables expand to empty, unknown variables stay untouched, quotes are escaped.
    NSString *e = [self expandVariablesIn:@"echo $(FILE_NAME) $(NOPE) x" document:nil shellQuote:YES];
    if (![e isEqualToString:@"echo '' $(NOPE) x"]) return NO;
    if (![[self expandVariablesIn:@"a $(b" document:nil shellQuote:YES] isEqualToString:@"a $(b"]) return NO;
    if (![NPPShellQuote(@"it's a/b c") isEqualToString:@"'it'\\''s a/b c'"]) return NO;
    if (![NPPFirstToken(@"\"/Apps/My App.app\" foo") isEqualToString:@"/Apps/My App.app"]) return NO;
    // Quoting the user already typed is honoured instead of doubled (`python3 "$(FULL_CURRENT_PATH)"`).
    if (![[self expandVariablesIn:@"python3 \"$(FILE_NAME)\"" document:nil shellQuote:YES] isEqualToString:@"python3 \"\""]) return NO;
    if (![[self expandVariablesIn:@"echo '$(FILE_NAME)' $(FILE_NAME)" document:nil shellQuote:YES] isEqualToString:@"echo '' ''"]) return NO;
    if (![NPPShellSubstitute(@"a\"b$c`d\\e", NPPQuoteDouble) isEqualToString:@"a\\\"b\\$c\\`d\\\\e"]) return NO;
    if (![NPPShellSubstitute(@"it's", NPPQuoteSingle) isEqualToString:@"it'\\''s"]) return NO;
    if (NPPAdvanceQuoteState(@"a \\\" \"x", NSMakeRange(0, 6), NPPQuoteNone) != NPPQuoteDouble) return NO;
    return YES;
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    if (cmd == NPPCmdRunDialog || cmd == NPPCmdRunModifyCommands) return YES;
    return cmd >= NPPCmdRunSavedBase && cmd < NPPCmdRunSavedBase + 100;
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPRunCommands *me = [self shared];
    if (cmd == NPPCmdRunDialog) return YES;
    if (cmd == NPPCmdRunModifyCommands) return me.savedCommandNames.count > 0;
    if ([self handlesCommand:cmd]) return [me savedCommandAtIndex:cmd - NPPCmdRunSavedBase] != nil;
    return NO;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPRunCommands *me = [self shared];
    if (cmd == NPPCmdRunDialog) { [me showRunDialogWithContext:context]; return YES; }
    if (cmd == NPPCmdRunModifyCommands) { [me showModifyCommandsWithContext:context]; return YES; }
    if (![self handlesCommand:cmd]) return NO;
    NSString *line = [me savedCommandAtIndex:cmd - NPPCmdRunSavedBase];
    if (!line) return NO;
    [me runCommandLine:line context:context];
    return YES;
}

@end
