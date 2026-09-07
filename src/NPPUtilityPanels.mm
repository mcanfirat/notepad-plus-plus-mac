// NPPUtilityPanels.mm — Document List, Clipboard History and Character Panel.
// See NPPUtilityPanels.h. Ported from Notepad++ WinControls/DocumentListPanel,
// WinControls/ClipboardHistory and WinControls/AnsiCharPanel.

#import "NPPUtilityPanels.h"
#import "NPPDocument.h"
#import "NPPTabBarView.h"      // the Document List row menu is the tab strip's own context menu
#import "NPPUtils.h"
#import <Scintilla/ScintillaView.h>

#pragma mark - shared bits

// What a panel table hands back to its panel, on top of NSTableViewDelegate. Both optional: only the Document
// List wants them, and it is the only list whose rows are documents.
@protocol NPPPanelTableActions <NSObject>
@optional
- (nullable NSMenu *)panelTableContextMenu;             // right-click: the panel picks the menu for the clicked row
- (BOOL)panelTableMiddleClickAtRow:(NSInteger)row;      // middle click: YES when the panel consumed it
@end

// A one-off table cell: a label, optionally monospaced.
static NSTableCellView *NPPMakeCell(NSTableView *tv, NSString *ident, BOOL mono) {
    NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:nil];
    if (cell) return cell;
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 120, 17)];
    cell.identifier = ident;
    NSTextField *tf = [NSTextField labelWithString:@""];
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    tf.font = mono ? [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
                   : [NSFont systemFontOfSize:11];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:tf];
    cell.textField = tf;
    [NSLayoutConstraint activateConstraints:@[
        [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:3],
        [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-3],
        [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

static NSTableColumn *NPPMakeColumn(NSString *ident, NSString *title, CGFloat width) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = title;
    col.width = width;
    col.minWidth = 28;
    return col;
}

// Return fires the table's double-click action (N++ binds Enter to "use this entry").
@interface NPPPanelTableView : NSTableView @end
@implementation NPPPanelTableView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 || event.keyCode == 76) {   // Return / Enter
        if (self.target && self.doubleAction) [NSApp sendAction:self.doubleAction to:self.target from:self];
        return;
    }
    [super keyDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *fallback = [super menuForEvent:event];      // NSTableView sets -clickedRow in here, which the panel reads
    id<NPPPanelTableActions> panel = (id<NPPPanelTableActions>)self.delegate;
    return [panel respondsToSelector:@selector(panelTableContextMenu)] ? [panel panelTableContextMenu] : fallback;
}

- (void)otherMouseDown:(NSEvent *)event {
    id<NPPPanelTableActions> panel = (id<NPPPanelTableActions>)self.delegate;
    if (event.buttonNumber == 2 && [panel respondsToSelector:@selector(panelTableMiddleClickAtRow:)] &&
        [panel panelTableMiddleClickAtRow:[self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]])
        return;
    [super otherMouseDown:event];
}
@end

// scroll view + table, plain, no XIB.
static NSTableView *NPPMakeTable(id owner) {
    NSTableView *tv = [[NPPPanelTableView alloc] initWithFrame:NSMakeRect(0, 0, 240, 200)];
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    tv.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    tv.allowsMultipleSelection = NO;
    tv.dataSource = (id<NSTableViewDataSource>)owner;
    tv.delegate = (id<NSTableViewDelegate>)owner;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 240, 200)];
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.drawsBackground = NO;
    sv.documentView = tv;
    return tv;
}

// Insert text at the caret of the current document (SCI_REPLACESEL, UTF-8).
static BOOL NPPInsertIntoCurrentEditor(id<NPPCommandContext> ctx, NSString *text) {
    NPPDocument *doc = [ctx contextCurrentDocument];
    if (!doc || text.length == 0) { NSBeep(); return NO; }
    if (doc.isReadOnly) {
        [ctx contextReportStatus:@"The document is read-only." isError:YES];
        return NO;
    }
    ScintillaView *ed = doc.editor;
    if (!ed) { NSBeep(); return NO; }
    NPPSciStr(ed, SCI_REPLACESEL, 0, text.UTF8String);
    [ed.window makeFirstResponder:[ed content]];
    return YES;
}

#pragma mark - Document List

// The three list options, N++ NppGUI::_fileSwitcherWithoutExtColumn / _fileSwitcherWithoutPathColumn /
// _fileSwitcherDisableListViewGroups. All three are on when the key has never been written, which is how those
// three "without/disable" flags default upstream.
static NSString *const kDocListExtKey   = @"NPPDocumentListShowExt";
static NSString *const kDocListPathKey  = @"NPPDocumentListShowPath";
static NSString *const kDocListGroupKey = @"NPPDocumentListGroupByView";

static BOOL NPPDocListFlag(NSString *key) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : YES;
}

// The window controller already answers both; NPPCommandContext has neither accessor.
// ponytail: informal, because one panel wanting them is not a reason to widen the protocol every module implements —
// promote them into NPPCommandContext the day a second module needs the view of a document or the tab strip.
@interface NSObject (NPPDocumentListHostViews)
- (NSInteger)viewOfDocument:(NPPDocument *)doc;
- (nullable NPPTabBarView *)tabBar;      // the focused view's strip; its delegate builds the tab context menu
@end

@interface NPPDocumentListPanel () <NSTableViewDataSource, NSTableViewDelegate, NPPPanelTableActions>
@property (nonatomic, weak) id<NPPCommandContext> ctx;
// Self-check seams (see +[NPPUtilityPanels selfCheckFailures]).
- (void)reload;
- (NSMenu *)optionsMenu;
- (NSArray<NPPDocument *> *)targetDocuments;
- (nullable NPPDocument *)docAtRow:(NSInteger)row;
@end

@implementation NPPDocumentListPanel {
    NSView *_view;
    NSTableView *_table;
    NSMutableArray *_rows;               // NPPDocument, plus an NSString header per view when grouping
    BOOL _programmaticSelection;
}

+ (instancetype)shared {
    static NPPDocumentListPanel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPDocumentListPanel alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) _rows = [NSMutableArray array];
    return self;
}

- (NSString *)panelTitle { return @"Document List"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeLeft; }
- (CGFloat)panelPreferredSize { return 260; }

- (NSView *)panelView {
    if (_view) return _view;
    _table = NPPMakeTable(self);
    NSScrollView *sv = _table.enclosingScrollView;
    NSTableColumn *name = NPPMakeColumn(@"name", @"Name", 120);
    NSTableColumn *ext  = NPPMakeColumn(@"ext",  @"Ext",  44);
    NSTableColumn *path = NPPMakeColumn(@"path", @"Path", 200);
    name.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
    ext.sortDescriptorPrototype  = [NSSortDescriptor sortDescriptorWithKey:@"ext"  ascending:YES];
    path.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"path" ascending:YES];
    for (NSTableColumn *c in @[name, ext, path]) [_table addTableColumn:c];
    _table.doubleAction = @selector(rowDoubleClicked:);
    _table.target = self;
    _table.allowsMultipleSelection = YES;      // N++: the row menu acts on every selected file

    // N++ _fileSwitcherMultiFilePopupMenu (NppNotification.cpp:1063-1073): what a *multi-row* right-click gets.
    // One row gets the whole tab context menu instead — see -panelTableContextMenu.
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Document List"];
    [[menu addItemWithTitle:@"Close Selected files" action:@selector(menuClose:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Close Other files" action:@selector(menuCloseOthers:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Copy Selected Names" action:@selector(menuCopyNames:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Copy Selected Pathnames" action:@selector(menuCopyPath:) keyEquivalent:@""] setTarget:self];
    _table.menu = menu;
    _table.headerView.menu = [self optionsMenu];   // N++ puts these on the column header's right-click

    // Restore the sort the user last used.
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *key = [ud stringForKey:@"NPPDocumentListSortKey"];
    if (key.length) {
        BOOL asc = [ud boolForKey:@"NPPDocumentListSortAscending"];
        _table.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:key ascending:asc]];
    }
    _view = sv;
    [self applyOptions];
    return _view;
}

#pragma mark options (N++ VerticalFileSwitcher::initPopupMenus)

- (NSMenu *)optionsMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Document List"];
    [[m addItemWithTitle:@"Ext." action:@selector(toggleExtColumn:) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Path" action:@selector(togglePathColumn:) keyEquivalent:@""] setTarget:self];
    [m addItem:[NSMenuItem separatorItem]];
    [[m addItemWithTitle:@"Group by View" action:@selector(toggleGroupByView:) keyEquivalent:@""] setTarget:self];
    return m;
}
- (NSMenu *)panelActionMenu { return [self optionsMenu]; }   // …and behind the panel's ⚙, where this port keeps options

- (void)toggleFlag:(NSString *)key {
    [NSUserDefaults.standardUserDefaults setBool:!NPPDocListFlag(key) forKey:key];
    [self applyOptions];
}
- (void)toggleExtColumn:(id)sender   { [self toggleFlag:kDocListExtKey]; }
- (void)togglePathColumn:(id)sender  { [self toggleFlag:kDocListPathKey]; }
- (void)toggleGroupByView:(id)sender { [self toggleFlag:kDocListGroupKey]; }

- (void)applyOptions {
    [_table tableColumnWithIdentifier:@"ext"].hidden = !NPPDocListFlag(kDocListExtKey);
    [_table tableColumnWithIdentifier:@"path"].hidden = !NPPDocListFlag(kDocListPathKey);
    [self reload];
}

- (void)panelDidBecomeVisible { [self reload]; }
- (void)panelWillHide { }
- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc { [self reload]; }

- (NSString *)sortValueFor:(NPPDocument *)doc key:(NSString *)key {
    if ([key isEqualToString:@"ext"]) return doc.fileURL.pathExtension ?: @"";
    if ([key isEqualToString:@"path"]) return doc.fileURL.URLByDeletingLastPathComponent.path ?: @"";
    return doc.displayName ?: @"";
}

// "Group by View": one section per editor view, the way N++ groups its list. nil when the option is off, when the
// host cannot say which view a document is in, or when they all sit in one view — a lone header is just noise.
- (NSArray<NSArray<NPPDocument *> *> *)groupDocuments:(NSArray<NPPDocument *> *)docs {
    id host = self.ctx;
    if (!NPPDocListFlag(kDocListGroupKey) || ![host respondsToSelector:@selector(viewOfDocument:)]) return nil;
    NSMutableArray<NPPDocument *> *main = [NSMutableArray array], *sub = [NSMutableArray array];
    for (NPPDocument *d in docs) [([host viewOfDocument:d] == 1 ? sub : main) addObject:d];
    return (main.count && sub.count) ? @[main, sub] : nil;
}

- (void)reload {
    if (!_table) return;
    NSArray<NPPDocument *> *docs = [self.ctx contextOpenDocuments] ?: @[];

    NSSortDescriptor *sd = _table.sortDescriptors.firstObject;
    if (sd.key) {
        BOOL asc = sd.ascending;
        NSString *key = sd.key;
        docs = [docs sortedArrayUsingComparator:^NSComparisonResult(NPPDocument *a, NPPDocument *b) {
            NSComparisonResult r = [[self sortValueFor:a key:key] localizedStandardCompare:[self sortValueFor:b key:key]];
            return asc ? r : (NSComparisonResult)(-(NSInteger)r);
        }];
    }
    [_rows removeAllObjects];
    NSArray<NSArray<NPPDocument *> *> *groups = [self groupDocuments:docs];
    if (groups) {
        for (NSUInteger i = 0; i < groups.count; i++) {
            [_rows addObject:[NSString stringWithFormat:@"View %lu", (unsigned long)(i + 1)]];
            [_rows addObjectsFromArray:groups[i]];
        }
    } else {
        [_rows addObjectsFromArray:docs];
    }
    [_table reloadData];

    NPPDocument *cur = [self.ctx contextCurrentDocument];
    NSUInteger idx = cur ? [_rows indexOfObjectIdenticalTo:cur] : NSNotFound;
    _programmaticSelection = YES;
    if (idx == NSNotFound) [_table deselectAll:nil];
    else {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
        [_table scrollRowToVisible:(NSInteger)idx];
    }
    _programmaticSelection = NO;
}

- (nullable NPPDocument *)docAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_rows.count) return nil;
    id r = _rows[(NSUInteger)row];
    return [r isKindOfClass:NPPDocument.class] ? r : nil;    // a "View N" header is not a document
}

// What the row menu acts on: the selection, or the row that was right-clicked outside it (macOS convention).
// Either way it may be several files — N++ redirects its NM_RCLICK to the main window whenever one or more rows
// are selected, and the command then runs over all of them.
- (NSArray<NPPDocument *> *)targetDocuments {
    NSIndexSet *sel = _table.selectedRowIndexes;
    NSInteger clicked = _table.clickedRow;
    if (clicked >= 0 && ![sel containsIndex:(NSUInteger)clicked]) {
        NPPDocument *d = [self docAtRow:clicked];
        return d ? @[d] : @[];
    }
    NSMutableArray<NPPDocument *> *docs = [NSMutableArray array];
    [sel enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        NPPDocument *d = [self docAtRow:(NSInteger)i];
        if (d) [docs addObject:d];
    }];
    return docs;
}

#pragma mark table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_rows.count; }

- (BOOL)isGroupRowIndex:(NSInteger)row {
    return row >= 0 && row < (NSInteger)_rows.count && [_rows[(NSUInteger)row] isKindOfClass:NSString.class];
}
- (BOOL)tableView:(NSTableView *)tv isGroupRow:(NSInteger)row { return [self isGroupRowIndex:row]; }
- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row { return ![self isGroupRowIndex:row]; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if ([self isGroupRowIndex:row]) {
        // A group row spans the table, so only the first column carries the header text.
        if (col && col != tv.tableColumns.firstObject) return nil;
        NSTableCellView *header = NPPMakeCell(tv, @"group", NO);
        header.textField.stringValue = _rows[(NSUInteger)row];
        header.textField.font = [NSFont boldSystemFontOfSize:11];
        header.textField.textColor = NSColor.secondaryLabelColor;
        return header;
    }
    NPPDocument *doc = [self docAtRow:row];
    if (!doc) return nil;
    NSString *ident = col.identifier;
    NSTableCellView *cell = NPPMakeCell(tv, ident, NO);
    NSString *text;
    if ([ident isEqualToString:@"name"]) {
        // N++ marks modified buffers; here with a leading "*" and red text.
        text = [NSString stringWithFormat:@"%@%@", doc.isDirty ? @"*" : @"", doc.displayName ?: @""];
    } else if ([ident isEqualToString:@"ext"]) {
        text = doc.fileURL.pathExtension ?: @"";
    } else {
        text = doc.fileURL ? (doc.fileURL.URLByDeletingLastPathComponent.path ?: @"") : @"";
    }
    cell.textField.stringValue = text;
    cell.textField.textColor = doc.isDirty ? NSColor.systemRedColor : NSColor.labelColor;
    cell.textField.toolTip = doc.fileURL.path ?: doc.displayName;
    return cell;
}

- (void)tableView:(NSTableView *)tv sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
    NSSortDescriptor *sd = tv.sortDescriptors.firstObject;
    if (sd.key) {
        [NSUserDefaults.standardUserDefaults setObject:sd.key forKey:@"NPPDocumentListSortKey"];
        [NSUserDefaults.standardUserDefaults setBool:sd.ascending forKey:@"NPPDocumentListSortAscending"];
    }
    [self reload];
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    if (_programmaticSelection) return;
    // N++ NM_CLICK ignores a click with Ctrl or Shift held: extending the selection picks files for the menu,
    // it does not switch document.
    if (_table.selectedRowIndexes.count != 1) return;
    NPPDocument *doc = [self docAtRow:_table.selectedRow];
    if (doc) [self.ctx contextSelectDocument:doc];
}

- (void)rowDoubleClicked:(id)sender {
    NPPDocument *doc = [self docAtRow:_table.clickedRow];
    if (doc) [self.ctx contextSelectDocument:doc];
}

#pragma mark context menu

// Commands route to -nppCommand: so the window controller keeps owning the dirty-state prompts (this module never
// edits it). The host that owns this panel is the target when it takes commands; otherwise the responder chain.
- (void)sendCommand:(NPPCmd)cmd forDocument:(NPPDocument *)doc {
    if (!doc) { NSBeep(); return; }
    [self.ctx contextSelectDocument:doc];
    NSMenuItem *proxy = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(nppCommand:) keyEquivalent:@""];
    proxy.tag = cmd;
    id host = [self.ctx respondsToSelector:@selector(nppCommand:)] ? self.ctx : nil;
    if (![NSApp sendAction:@selector(nppCommand:) to:host from:proxy]) NSBeep();
    [self reload];
}

- (void)sendCommand:(NPPCmd)cmd forDocuments:(NSArray<NPPDocument *> *)docs {
    if (docs.count == 0) { NSBeep(); return; }
    for (NPPDocument *doc in docs) [self sendCommand:cmd forDocument:doc];
}

// Right-clicking one row is right-clicking its tab: N++ activates the document and shows the tab context menu
// itself (NppNotification.cpp:1056-1090), so everything you can do to a tab you can do to a row. Several rows get
// the multi-file menu instead — that is the one menu this panel builds.
- (nullable NSMenu *)panelTableContextMenu {
    NSArray<NPPDocument *> *docs = [self targetDocuments];
    if (docs.count == 0) return nil;
    NSMenu *tabMenu = docs.count == 1 ? [self tabContextMenuForDocument:docs.firstObject] : nil;
    return tabMenu ?: _table.menu;      // a host with no tab strip still gets the multi-file items
}

// Borrowed, not rebuilt: the strip's delegate owns that menu and every item in it acts on the current buffer, so
// the row's document is activated first (N++ activateDoc, then the popup).
- (nullable NSMenu *)tabContextMenuForDocument:(NPPDocument *)doc {
    id host = self.ctx;
    if (![host respondsToSelector:@selector(tabBar)]) return nil;
    [self.ctx contextSelectDocument:doc];
    NPPTabBarView *bar = [host tabBar];
    id<NPPTabBarDelegate> owner = bar.delegate;
    if (![owner respondsToSelector:@selector(tabBar:contextMenuForTabAtIndex:)]) return nil;
    return [owner tabBar:bar contextMenuForTabAtIndex:bar.selectedIndex];
}

// A middle click closes the row's document, exactly as it closes its tab (N++ VerticalFileSwitcher.cpp:303-336).
// NO when there is no document under the pointer — a "View N" header or empty space keeps the default behaviour.
- (BOOL)panelTableMiddleClickAtRow:(NSInteger)row {
    NPPDocument *doc = [self docAtRow:row];
    if (!doc) return NO;
    [self sendCommand:NPPCmdFileClose forDocument:doc];
    return YES;
}

- (void)menuClose:(id)sender { [self sendCommand:NPPCmdFileClose forDocuments:[self targetDocuments]]; }

// N++ getSelectedFiles(true): the files that are *not* selected, then back to the one the user is looking at.
- (void)menuCloseOthers:(id)sender {
    NSArray<NPPDocument *> *keep = [self targetDocuments];
    NSMutableArray<NPPDocument *> *others = [NSMutableArray array];
    for (NPPDocument *doc in [self.ctx contextOpenDocuments] ?: @[])
        if ([keep indexOfObjectIdenticalTo:doc] == NSNotFound) [others addObject:doc];
    [self sendCommand:NPPCmdFileClose forDocuments:others];
    if (keep.firstObject) [self.ctx contextSelectDocument:keep.firstObject];
}

// N++ buf2Clipboard: one line per selected file, names or full paths.
- (void)copySelectedFullPaths:(BOOL)fullPaths {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NPPDocument *doc in [self targetDocuments]) {
        NSString *line = fullPaths ? doc.fileURL.path : (doc.fileURL.lastPathComponent ?: doc.displayName);
        if (line.length) [lines addObject:line];
    }
    if (lines.count == 0) { [self.ctx contextReportStatus:@"This document has no path yet." isError:YES]; return; }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (void)menuCopyPath:(id)sender  { [self copySelectedFullPaths:YES]; }
- (void)menuCopyNames:(id)sender { [self copySelectedFullPaths:NO]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    // The three options are checkmarks, and always available.
    NSString *flag = item.action == @selector(toggleExtColumn:)   ? kDocListExtKey
                   : item.action == @selector(togglePathColumn:)  ? kDocListPathKey
                   : item.action == @selector(toggleGroupByView:) ? kDocListGroupKey : nil;
    if (flag) { item.state = NPPDocListFlag(flag) ? NSControlStateValueOn : NSControlStateValueOff; return YES; }

    NSArray<NPPDocument *> *docs = [self targetDocuments];
    if (docs.count == 0) return NO;
    if (item.action == @selector(menuCopyPath:))
        for (NPPDocument *d in docs) { if (d.fileURL) return YES; }
    else if (item.action == @selector(menuCloseOthers:))
        return docs.count < [self.ctx contextOpenDocuments].count;
    else
        return YES;
    return NO;
}

@end

#pragma mark - Clipboard History

static const NSUInteger kNPPClipMaxEntries = 50;
static const NSUInteger kNPPClipMaxBytes = 64 * 1024;

@interface NPPClipboardHistoryPanel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak) id<NPPCommandContext> ctx;
@end

@implementation NPPClipboardHistoryPanel {
    NSView *_view;
    NSTableView *_table;
    NSMutableArray<NSString *> *_entries;
    NSTimer *_timer;
    NSInteger _lastChangeCount;
}

+ (instancetype)shared {
    static NPPClipboardHistoryPanel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPClipboardHistoryPanel alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _entries = [NSMutableArray array];
        _lastChangeCount = NSPasteboard.generalPasteboard.changeCount;
    }
    return self;
}

- (void)dealloc { [_timer invalidate]; }

- (NSString *)panelTitle { return @"Clipboard History"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeBottom; }
- (CGFloat)panelPreferredSize { return 180; }

- (NSView *)panelView {
    if (_view) return _view;
    _table = NPPMakeTable(self);
    NSScrollView *sv = _table.enclosingScrollView;
    [_table addTableColumn:NPPMakeColumn(@"text", @"Content", 420)];
    [_table addTableColumn:NPPMakeColumn(@"len", @"Length", 70)];
    _table.doubleAction = @selector(pasteSelected:);
    _table.target = self;
    _view = sv;
    return _view;
}

- (NSMenu *)panelActionMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Clipboard History"];
    [[menu addItemWithTitle:@"Delete" action:@selector(deleteSelected:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Clear all" action:@selector(clearAll:) keyEquivalent:@""] setTarget:self];
    return menu;
}

- (void)panelDidBecomeVisible {
    (void)self.panelView;
    [self poll];
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(poll)
                                            userInfo:nil repeats:YES];
    _timer.tolerance = 0.2;
}

- (void)panelWillHide {
    [_timer invalidate];
    _timer = nil;
}

- (void)poll {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    if (pb.changeCount == _lastChangeCount) return;
    _lastChangeCount = pb.changeCount;
    NSString *s = [pb stringForType:NSPasteboardTypeString];
    if (s.length == 0) return;

    // Cap at 64 KB of UTF-8, cutting on a character boundary.
    if ([s lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kNPPClipMaxBytes) {
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        NSString *cut = nil;
        for (NSUInteger n = kNPPClipMaxBytes; n > 0 && !cut; --n)
            cut = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, n)] encoding:NSUTF8StringEncoding];
        if (!cut) return;
        s = cut;
    }
    [_entries removeObject:s];                    // distinct: an old copy moves back to the top
    [_entries insertObject:s atIndex:0];
    while (_entries.count > kNPPClipMaxEntries) [_entries removeLastObject];
    [_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_entries.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_entries.count) return nil;
    NSString *s = _entries[(NSUInteger)row];
    BOOL isText = [col.identifier isEqualToString:@"text"];
    NSTableCellView *cell = NPPMakeCell(tv, col.identifier, isText);
    if (isText) {
        NSString *preview = [[[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"¶ "]
                                stringByReplacingOccurrencesOfString:@"\n" withString:@"¶ "]
                                stringByReplacingOccurrencesOfString:@"\r" withString:@"¶ "];
        preview = [preview stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
        if (preview.length > 400) preview = [preview substringToIndex:400];
        cell.textField.stringValue = preview;
    } else {
        cell.textField.stringValue = NPPFormatGroupedInteger((long long)s.length);
    }
    return cell;
}

- (void)pasteSelected:(id)sender {
    NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_entries.count) { NSBeep(); return; }
    NPPInsertIntoCurrentEditor(self.ctx, _entries[(NSUInteger)row]);
}

- (void)deleteSelected:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_entries.count) { NSBeep(); return; }
    [_entries removeObjectAtIndex:(NSUInteger)row];
    [_table reloadData];
}

- (void)clearAll:(id)sender {
    [_entries removeAllObjects];
    [_table reloadData];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(deleteSelected:)) return _table.selectedRow >= 0;
    if (item.action == @selector(clearAll:)) return _entries.count > 0;
    return YES;
}

@end

#pragma mark - Character Panel

typedef struct { unsigned char value; const char *html; } NPPHtmlName;

static const NPPHtmlName kNPPHtmlNames[] = {
    {33,"&excl;"},{34,"&quot;"},{35,"&num;"},{36,"&dollar;"},{37,"&percnt;"},{38,"&amp;"},{39,"&apos;"},
    {40,"&lpar;"},{41,"&rpar;"},{42,"&ast;"},{43,"&plus;"},{44,"&comma;"},{45,"&minus;"},{46,"&period;"},
    {47,"&sol;"},{58,"&colon;"},{59,"&semi;"},{60,"&lt;"},{61,"&equals;"},{62,"&gt;"},{63,"&quest;"},
    {64,"&commat;"},{91,"&lbrack;"},{92,"&bsol;"},{93,"&rbrack;"},{94,"&Hat;"},{95,"&lowbar;"},{96,"&grave;"},
    {123,"&lbrace;"},{124,"&vert;"},{125,"&rbrace;"},
    {128,"&euro;"},{130,"&sbquo;"},{131,"&fnof;"},{132,"&bdquo;"},{133,"&hellip;"},{134,"&dagger;"},
    {135,"&Dagger;"},{136,"&circ;"},{137,"&permil;"},{138,"&Scaron;"},{139,"&lsaquo;"},{140,"&OElig;"},
    {142,"&Zcaron;"},{145,"&lsquo;"},{146,"&rsquo;"},{147,"&ldquo;"},{148,"&rdquo;"},{149,"&bull;"},
    {150,"&ndash;"},{151,"&mdash;"},{152,"&tilde;"},{153,"&trade;"},{154,"&scaron;"},{155,"&rsaquo;"},
    {156,"&oelig;"},{158,"&zcaron;"},{159,"&Yuml;"},
    {160,"&nbsp;"},{161,"&iexcl;"},{162,"&cent;"},{163,"&pound;"},{164,"&curren;"},{165,"&yen;"},
    {166,"&brvbar;"},{167,"&sect;"},{168,"&uml;"},{169,"&copy;"},{170,"&ordf;"},{171,"&laquo;"},{172,"&not;"},
    {173,"&shy;"},{174,"&reg;"},{175,"&macr;"},{176,"&deg;"},{177,"&plusmn;"},{178,"&sup2;"},{179,"&sup3;"},
    {180,"&acute;"},{181,"&micro;"},{182,"&para;"},{183,"&middot;"},{184,"&cedil;"},{185,"&sup1;"},
    {186,"&ordm;"},{187,"&raquo;"},{188,"&frac14;"},{189,"&frac12;"},{190,"&frac34;"},{191,"&iquest;"},
    {192,"&Agrave;"},{193,"&Aacute;"},{194,"&Acirc;"},{195,"&Atilde;"},{196,"&Auml;"},{197,"&Aring;"},
    {198,"&AElig;"},{199,"&Ccedil;"},{200,"&Egrave;"},{201,"&Eacute;"},{202,"&Ecirc;"},{203,"&Euml;"},
    {204,"&Igrave;"},{205,"&Iacute;"},{206,"&Icirc;"},{207,"&Iuml;"},{208,"&ETH;"},{209,"&Ntilde;"},
    {210,"&Ograve;"},{211,"&Oacute;"},{212,"&Ocirc;"},{213,"&Otilde;"},{214,"&Ouml;"},{215,"&times;"},
    {216,"&Oslash;"},{217,"&Ugrave;"},{218,"&Uacute;"},{219,"&Ucirc;"},{220,"&Uuml;"},{221,"&Yacute;"},
    {222,"&THORN;"},{223,"&szlig;"},{224,"&agrave;"},{225,"&aacute;"},{226,"&acirc;"},{227,"&atilde;"},
    {228,"&auml;"},{229,"&aring;"},{230,"&aelig;"},{231,"&ccedil;"},{232,"&egrave;"},{233,"&eacute;"},
    {234,"&ecirc;"},{235,"&euml;"},{236,"&igrave;"},{237,"&iacute;"},{238,"&icirc;"},{239,"&iuml;"},
    {240,"&eth;"},{241,"&ntilde;"},{242,"&ograve;"},{243,"&oacute;"},{244,"&ocirc;"},{245,"&otilde;"},
    {246,"&ouml;"},{247,"&divide;"},{248,"&oslash;"},{249,"&ugrave;"},{250,"&uacute;"},{251,"&ucirc;"},
    {252,"&uuml;"},{253,"&yacute;"},{254,"&thorn;"},{255,"&yuml;"},
};

static NSString *NPPHtmlNameFor(unsigned char v) {
    for (size_t i = 0; i < sizeof(kNPPHtmlNames) / sizeof(kNPPHtmlNames[0]); ++i)
        if (kNPPHtmlNames[i].value == v) return @(kNPPHtmlNames[i].html);
    return @"";
}

static NSString *const kNPPControlNames[] = {
    @"NUL", @"SOH", @"STX", @"ETX", @"EOT", @"ENQ", @"ACK", @"BEL",
    @"BS",  @"TAB", @"LF",  @"VT",  @"FF",  @"CR",  @"SO",  @"SI",
    @"DLE", @"DC1", @"DC2", @"DC3", @"DC4", @"NAK", @"SYN", @"ETB",
    @"CAN", @"EM",  @"SUB", @"ESC", @"FS",  @"GS",  @"RS",  @"US",
};

typedef struct { const char *name; uint32_t first; uint32_t last; } NPPUnicodeBlock;

// ponytail: a fixed shortlist, not the Unicode database. Full block/name lookup (UCD or
// CFStringTransform-based naming) is out of scope; add a UCD table here if it is ever wanted.
static const NPPUnicodeBlock kNPPBlocks[] = {
    {"Latin-1 Supplement",     0x00A0, 0x00FF},
    {"Latin Extended-A",       0x0100, 0x017F},
    {"Greek and Coptic",       0x0370, 0x03FF},
    {"Cyrillic",               0x0400, 0x04FF},
    {"Arrows",                 0x2190, 0x21FF},
    {"Mathematical Operators", 0x2200, 0x22FF},
    {"Box Drawing",            0x2500, 0x257F},
    {"Emoticons",              0x1F600, 0x1F64F},
};
static const NSUInteger kNPPBlockCount = sizeof(kNPPBlocks) / sizeof(kNPPBlocks[0]);

@interface NPPCharacterPanel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak) id<NPPCommandContext> ctx;
// One source of truth for what a cell shows and what double-clicking it inserts; also the self-check seams.
- (NSString *)textForColumn:(NSString *)ident row:(NSInteger)row;
- (NSString *)insertionForColumn:(nullable NSString *)ident row:(NSInteger)row;
- (void)modeChanged:(nullable id)sender;
@end

@implementation NPPCharacterPanel {
    NSView *_view;
    NSTableView *_table;
    NSSegmentedControl *_mode;      // 0 = ASCII/ANSI table, 1 = Unicode block
    NSPopUpButton *_blockPopup;
    CFStringEncoding _encoding;     // encoding the 0-255 table is interpreted in
}

+ (instancetype)shared {
    static NPPCharacterPanel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NPPCharacterPanel alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) _encoding = kCFStringEncodingWindowsLatin1;
    return self;
}

- (NSString *)panelTitle { return @"Character Panel"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeRight; }
- (CGFloat)panelPreferredSize { return 280; }

- (NSView *)panelView {
    if (_view) return _view;
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 400)];

    _mode = [NSSegmentedControl segmentedControlWithLabels:@[@"ASCII", @"Unicode"]
                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                    target:self action:@selector(modeChanged:)];
    _mode.translatesAutoresizingMaskIntoConstraints = NO;
    _mode.controlSize = NSControlSizeSmall;

    _blockPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _blockPopup.translatesAutoresizingMaskIntoConstraints = NO;
    _blockPopup.controlSize = NSControlSizeSmall;
    _blockPopup.font = [NSFont systemFontOfSize:11];
    for (NSUInteger i = 0; i < kNPPBlockCount; ++i) [_blockPopup addItemWithTitle:@(kNPPBlocks[i].name)];
    _blockPopup.target = self;
    _blockPopup.action = @selector(blockChanged:);

    _table = NPPMakeTable(self);
    NSScrollView *sv = _table.enclosingScrollView;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [_table addTableColumn:NPPMakeColumn(@"value", @"Value", 62)];
    [_table addTableColumn:NPPMakeColumn(@"char", @"Character", 70)];
    [_table addTableColumn:NPPMakeColumn(@"html", @"HTML Name", 96)];
    [_table addTableColumn:NPPMakeColumn(@"htmldec", @"HTML Decimal", 96)];
    [_table addTableColumn:NPPMakeColumn(@"htmlhex", @"HTML Hexadecimal", 116)];
    sv.hasHorizontalScroller = YES;    // five columns need more than the panel is wide
    _table.doubleAction = @selector(insertSelected:);
    _table.target = self;

    [root addSubview:_mode];
    [root addSubview:_blockPopup];
    [root addSubview:sv];
    [NSLayoutConstraint activateConstraints:@[
        [_mode.topAnchor constraintEqualToAnchor:root.topAnchor constant:6],
        [_mode.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:6],
        [_blockPopup.centerYAnchor constraintEqualToAnchor:_mode.centerYAnchor],
        [_blockPopup.leadingAnchor constraintEqualToAnchor:_mode.trailingAnchor constant:6],
        [_blockPopup.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-6],
        [sv.topAnchor constraintEqualToAnchor:_mode.bottomAnchor constant:6],
        [sv.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    _mode.selectedSegment = MIN(1, MAX(0, [ud integerForKey:@"NPPCharacterPanelMode"]));
    NSInteger blk = [ud integerForKey:@"NPPCharacterPanelBlock"];
    if (blk >= 0 && blk < (NSInteger)kNPPBlockCount) [_blockPopup selectItemAtIndex:blk];

    _view = root;
    [self syncControls];
    return _view;
}

- (BOOL)unicodeMode { return _mode.selectedSegment == 1; }

- (void)syncControls {
    _blockPopup.hidden = ![self unicodeMode];
    [_table reloadData];
}

- (void)modeChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setInteger:_mode.selectedSegment forKey:@"NPPCharacterPanelMode"];
    [self syncControls];
}

- (void)blockChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setInteger:_blockPopup.indexOfSelectedItem forKey:@"NPPCharacterPanelBlock"];
    [_table reloadData];
}

- (void)panelDidBecomeVisible { [_table reloadData]; }
- (void)panelWillHide { }

- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc {
    // N++ re-reads the buffer's code page; anything but ANSI shows the Latin-1 view.
    CFStringEncoding enc = (doc && doc.encoding == NPPEncodingANSI) ? doc.codepage : kCFStringEncodingWindowsLatin1;
    if (enc != _encoding) {
        _encoding = enc;
        [_table reloadData];
    }
}

- (const NPPUnicodeBlock *)currentBlock {
    NSInteger i = _blockPopup.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)kNPPBlockCount) i = 0;
    return &kNPPBlocks[i];
}

// The code point a row stands for: the byte itself in the ANSI table, the block's nth character in Unicode mode.
- (uint32_t)codePointForRow:(NSInteger)row {
    if (row < 0) return 0;
    return [self unicodeMode] ? [self currentBlock]->first + (uint32_t)row : (uint32_t)row;
}

// The string a row inserts; empty for values with no representation in the current code page.
- (NSString *)characterForRow:(NSInteger)row {
    if ([self unicodeMode]) {
        const NPPUnicodeBlock *b = [self currentBlock];
        uint32_t cp = [self codePointForRow:row];
        if (cp > b->last) return @"";
        if (cp <= 0xFFFF) {
            unichar u = (unichar)cp;
            return [NSString stringWithCharacters:&u length:1];
        }
        uint32_t v = cp - 0x10000;
        unichar pair[2] = { (unichar)(0xD800 + (v >> 10)), (unichar)(0xDC00 + (v & 0x3FF)) };
        return [NSString stringWithCharacters:pair length:2];
    }
    if (row < 0 || row > 255) return @"";
    if (row < 32 || row == 127) return @"";          // control characters are not insertable
    unsigned char byte = (unsigned char)row;
    // NPPDocument owns the two code pages CoreFoundation cannot convert (OEM 720, OEM 858), so ask it rather
    // than CFStringConvertEncodingToNSStringEncoding, which answers kCFStringEncodingInvalidId for both.
    NSString *s = [NPPDocument stringForByte:byte codepage:_encoding];
    if (!s) s = [[NSString alloc] initWithBytes:&byte length:1 encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    if ([self unicodeMode]) {
        const NPPUnicodeBlock *b = [self currentBlock];
        return (NSInteger)(b->last - b->first + 1);
    }
    return 256;
}

// N++ only fills the HTML columns for the ANSI / Windows-1252 view (asciiListView.cpp:508-548).
- (BOOL)htmlColumnsApply {
    return [self unicodeMode] || _encoding == kCFStringEncodingWindowsLatin1 || _encoding == kCFStringEncodingISOLatin1;
}

// The code point the entity columns name, 0 where upstream leaves them blank. Upstream's 30-case number table
// (asciiListView.cpp:441) is just the cp1252 high range, which decoding the byte already gives us; its one
// deliberate exception is 45, written as the real minus sign rather than the hyphen it decodes to.
- (uint32_t)htmlCodePointForRow:(NSInteger)row {
    if (![self htmlColumnsApply]) return 0;
    if ([self unicodeMode]) return [self codePointForRow:row];
    if (row == 45) return 8722;
    NSString *s = [self characterForRow:row];
    if (s.length == 0) return 0;
    uint32_t cp = [s characterAtIndex:0];        // an 8-bit code page never decodes outside the BMP
    // C0/C1 controls and the bytes cp1252 leaves undefined get no entity, as upstream's table does not either.
    return ((cp >= 32 && cp <= 126) || cp >= 0xA0) ? cp : 0;
}

- (NSString *)textForColumn:(NSString *)ident row:(NSInteger)row {
    uint32_t cp = [self codePointForRow:row];
    if ([ident isEqualToString:@"value"])
        return [self unicodeMode] ? [NSString stringWithFormat:@"U+%04X", cp]
                                  : [NSString stringWithFormat:@"%3ld  %02lX", (long)row, (long)row];
    if ([ident isEqualToString:@"char"]) {
        if (![self unicodeMode]) {
            if (row < 32) return kNPPControlNames[row];
            if (row == 32) return @"Space";
            if (row == 127) return @"DEL";
        }
        return [self characterForRow:row];
    }
    if ([ident isEqualToString:@"html"])
        return [self htmlColumnsApply] && cp <= 0xFF ? NPPHtmlNameFor((unsigned char)cp) : @"";
    uint32_t h = [self htmlCodePointForRow:row];
    if (h == 0) return @"";
    return [ident isEqualToString:@"htmldec"] ? [NSString stringWithFormat:@"&#%u;", h]
                                              : [NSString stringWithFormat:@"&#x%x;", h];
}

// Double-clicking inserts the text of the column that was clicked, except the Character column, which inserts the
// character itself (N++ ansiCharPanel.cpp:82-108) — and Enter, which always inserts the character (its LVN_KEYDOWN
// branch), and arrives here with no clicked column. Our Value column merges upstream's decimal and hexadecimal
// columns, so it inserts the decimal half.
- (NSString *)insertionForColumn:(NSString *)ident row:(NSInteger)row {
    if (!ident || [ident isEqualToString:@"char"]) return [self characterForRow:row];
    if ([ident isEqualToString:@"value"]) return [NSString stringWithFormat:@"%u", [self codePointForRow:row]];
    return [self textForColumn:ident row:row];
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSString *ident = col.identifier;
    NSTableCellView *cell = NPPMakeCell(tv, ident, ![ident hasPrefix:@"html"]);
    cell.textField.stringValue = [self textForColumn:ident row:row] ?: @"";
    return cell;
}

- (void)insertSelected:(id)sender {
    NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
    NSInteger col = _table.clickedRow >= 0 ? _table.clickedColumn : -1;   // -1 = the Return key, not a click
    NSString *ident = (col >= 0 && col < (NSInteger)_table.tableColumns.count) ? _table.tableColumns[(NSUInteger)col].identifier : nil;
    NSString *s = [self insertionForColumn:ident row:row];
    if (s.length == 0) { NSBeep(); return; }
    NPPInsertIntoCurrentEditor(self.ctx, s);
}

@end

#pragma mark - command handler

// A stand-in window controller for +selfCheckFailures: enough of NPPCommandContext for these panels, plus the two
// informal accessors the Document List asks the host about — -viewOfDocument: when it groups by view, and -tabBar
// (whose delegate this stub also is) for the tab context menu a right-clicked row shows.
@interface NPPUtilityPanelsStubContext : NSObject <NPPCommandContext, NPPTabBarDelegate>
@property (nonatomic, copy) NSArray<NPPDocument *> *docs;
@property (nonatomic, copy) NSArray<NPPDocument *> *subViewDocs;
@property (nonatomic, strong) NSMutableArray<NPPDocument *> *selected;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *commands;   // NPPCmd tags sent through -nppCommand:
@property (nonatomic, strong) NPPTabBarView *bar;
@property (nonatomic, strong) NSMenu *tabMenu;                        // what the strip's delegate would show
@property (nonatomic) NSInteger tabMenuIndex;                         // ...and the tab it was asked for
@end

@implementation NPPUtilityPanelsStubContext
- (instancetype)init {
    if ((self = [super init])) {
        _docs = @[]; _subViewDocs = @[];
        _selected = [NSMutableArray array];
        _commands = [NSMutableArray array];
        _tabMenuIndex = NSNotFound;
        _bar = [[NPPTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 300, 28)];
        _bar.delegate = self;
        _tabMenu = [[NSMenu alloc] initWithTitle:@"Tab"];
        for (NSString *t in @[@"Close", @"Close All BUT This", @"Rename…", @"Move to Other View", @"Copy Full File Path"])
            [_tabMenu addItemWithTitle:t action:@selector(nppCommand:) keyEquivalent:@""];
    }
    return self;
}
- (NPPTabBarView *)tabBar { return _bar; }
- (void)nppCommand:(NSMenuItem *)sender { [_commands addObject:@(sender.tag)]; }
- (void)tabBar:(NPPTabBarView *)bar didSelectTabAtIndex:(NSInteger)index {}
- (void)tabBar:(NPPTabBarView *)bar didRequestCloseTabAtIndex:(NSInteger)index {}
- (void)tabBar:(NPPTabBarView *)bar didMoveTabFromIndex:(NSInteger)from toIndex:(NSInteger)to {}
- (NSMenu *)tabBar:(NPPTabBarView *)bar contextMenuForTabAtIndex:(NSInteger)index {
    _tabMenuIndex = index;
    return _tabMenu;
}
- (NPPDocument *)contextCurrentDocument { return _selected.lastObject; }
- (NSArray<NPPDocument *> *)contextOpenDocuments { return _docs; }
- (NSWindow *)contextWindow { NSWindow *none = nil; return none; }   // these three panels never ask
- (NPPDocument *)contextOpenFileURL:(NSURL *)url { return nil; }
- (void)contextRevealFileURL:(NSURL *)url line:(NSInteger)line {}
- (void)setDocs:(NSArray<NPPDocument *> *)docs {
    _docs = [docs copy];
    NSMutableArray<NPPTabItem *> *items = [NSMutableArray array];
    for (NPPDocument *doc in _docs) {
        NPPTabItem *item = [NPPTabItem new];
        item.title = doc.displayName ?: @"";
        [items addObject:item];
    }
    _bar.items = items;                       // the strip has to hold tabs for -selectedIndex to stick
}
// The real host selects the document *and* moves its strip to that tab; the row menu is asked for that index.
- (void)contextSelectDocument:(NPPDocument *)doc {
    [_selected addObject:doc];
    _bar.selectedIndex = (NSInteger)[_docs indexOfObjectIdenticalTo:doc];
}
- (void)contextTogglePanel:(id<NPPPanel>)panel {}
- (void)contextShowPanel:(id<NPPPanel>)panel {}
- (BOOL)contextPanelIsVisible:(id<NPPPanel>)panel { return NO; }
- (void)contextRefreshUI {}
- (void)contextReportStatus:(NSString *)message isError:(BOOL)isError {}
- (NSInteger)viewOfDocument:(NPPDocument *)doc { return [_subViewDocs containsObject:doc] ? 1 : 0; }
@end

@implementation NPPUtilityPanels

+ (nullable id<NPPPanel>)panelForCommand:(NPPCmd)cmd {
    switch (cmd) {
        case NPPCmdViewDocumentList:      return NPPDocumentListPanel.shared;
        case NPPCmdViewClipboardHistory:  return NPPClipboardHistoryPanel.shared;
        case NPPCmdViewCharacterPanel:    return NPPCharacterPanel.shared;
        default: return nil;
    }
}

+ (void)bindContext:(id<NPPCommandContext>)ctx {
    NPPDocumentListPanel.shared.ctx = ctx;
    NPPClipboardHistoryPanel.shared.ctx = ctx;
    NPPCharacterPanel.shared.ctx = ctx;
}

+ (BOOL)handlesCommand:(NPPCmd)cmd { return [self panelForCommand:cmd] != nil; }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    if (![self handlesCommand:cmd] || !context) return NO;
    [self bindContext:context];
    return YES;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    id<NPPPanel> panel = [self panelForCommand:cmd];
    if (!panel || !context) return NO;
    [self bindContext:context];
    [context contextTogglePanel:panel];
    return YES;
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    id<NPPPanel> panel = [self panelForCommand:cmd];
    return panel && context ? [context contextPanelIsVisible:panel] : NO;
}

#pragma mark - self checks

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) { if (!ok) [fails addObject:msg]; };
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *touched = @[@"NPPCharacterPanelMode", @"NPPCharacterPanelBlock",
                                     kDocListExtKey, kDocListPathKey, kDocListGroupKey];
    NSMutableDictionary<NSString *, id> *saved = [NSMutableDictionary dictionary];
    for (NSString *k in touched) if ([ud objectForKey:k]) saved[k] = [ud objectForKey:k];

    // ---- Character Panel. Every column has to say something different, and double-clicking one has to insert
    // that column's text rather than always the character (N++ ansiCharPanel.cpp:82-108).
    NPPCharacterPanel *chars = [[NPPCharacterPanel alloc] init];
    NSView *charsView = chars.panelView;
    NSSegmentedControl *mode = nil;
    NSPopUpButton *blocks = nil;
    for (NSView *v in charsView.subviews) {
        if ([v isKindOfClass:NSSegmentedControl.class]) mode = (NSSegmentedControl *)v;
        if ([v isKindOfClass:NSPopUpButton.class]) blocks = (NSPopUpButton *)v;
    }
    NSTableView *charTable = nil;
    for (NSView *v in charsView.subviews)
        if ([v isKindOfClass:NSScrollView.class]) charTable = (NSTableView *)((NSScrollView *)v).documentView;
    NSArray<NSString *> *idents = [charTable.tableColumns valueForKey:@"identifier"];
    expect([idents isEqual:(@[@"value", @"char", @"html", @"htmldec", @"htmlhex"])],
           [@"the Character Panel's columns are " stringByAppendingString:[idents componentsJoinedByString:@", "] ?: @"gone"]);

    if (!mode || !blocks) {
        [fails addObject:@"self-check bug: the Character Panel's mode switch is not where the checks look for it"];
    } else {
        mode.selectedSegment = 0;                       // the ANSI table, in the panel's default Windows-1252
        [chars modeChanged:mode];
        NSString *(^cell)(NSString *, NSInteger) = ^(NSString *ident, NSInteger row) {
            return [chars textForColumn:ident row:row] ?: @"";
        };
        expect([cell(@"char", 65) isEqualToString:@"A"] && [cell(@"htmldec", 65) isEqualToString:@"&#65;"] &&
               [cell(@"htmlhex", 65) isEqualToString:@"&#x41;"],
               [NSString stringWithFormat:@"'A' reads %@ / %@ / %@", cell(@"char", 65), cell(@"htmldec", 65), cell(@"htmlhex", 65)]);
        expect([cell(@"html", 38) isEqualToString:@"&amp;"] && [cell(@"htmldec", 38) isEqualToString:@"&#38;"] &&
               [cell(@"htmlhex", 38) isEqualToString:@"&#x26;"],
               [NSString stringWithFormat:@"'&' reads %@ / %@ / %@", cell(@"html", 38), cell(@"htmldec", 38), cell(@"htmlhex", 38)]);
        // The cp1252 high range and the hyphen are upstream's hand-written numbers (asciiListView.cpp:441).
        expect([cell(@"htmldec", 128) isEqualToString:@"&#8364;"] && [cell(@"htmlhex", 128) isEqualToString:@"&#x20ac;"],
               [NSString stringWithFormat:@"byte 128 (euro) reads %@ / %@", cell(@"htmldec", 128), cell(@"htmlhex", 128)]);
        expect([cell(@"htmldec", 45) isEqualToString:@"&#8722;"],
               [@"byte 45 is not upstream's minus sign: " stringByAppendingString:cell(@"htmldec", 45)]);
        // …and the values with no entity keep both columns empty rather than printing a control character's number.
        expect(cell(@"htmldec", 10).length == 0 && cell(@"htmlhex", 129).length == 0,
               [NSString stringWithFormat:@"LF / byte 129 got entities %@ / %@", cell(@"htmldec", 10), cell(@"htmlhex", 129)]);

        expect([[chars insertionForColumn:@"char" row:65] isEqualToString:@"A"] &&
               [[chars insertionForColumn:@"value" row:65] isEqualToString:@"65"] &&
               [[chars insertionForColumn:@"html" row:38] isEqualToString:@"&amp;"] &&
               [[chars insertionForColumn:@"htmldec" row:38] isEqualToString:@"&#38;"] &&
               [[chars insertionForColumn:@"htmlhex" row:38] isEqualToString:@"&#x26;"],
               @"double-clicking a Character Panel column does not insert that column");
        expect([[chars insertionForColumn:nil row:38] isEqualToString:@"&"],
               @"Return in the Character Panel stopped inserting the character itself");

        mode.selectedSegment = 1;                       // Unicode, first block = Latin-1 Supplement
        [chars modeChanged:mode];
        [blocks selectItemAtIndex:0];
        expect([cell(@"value", 1) isEqualToString:@"U+00A1"] && [cell(@"html", 1) isEqualToString:@"&iexcl;"] &&
               [cell(@"htmldec", 1) isEqualToString:@"&#161;"] && [cell(@"htmlhex", 1) isEqualToString:@"&#xa1;"],
               [NSString stringWithFormat:@"U+00A1 reads %@ / %@ / %@ / %@", cell(@"value", 1), cell(@"html", 1),
                cell(@"htmldec", 1), cell(@"htmlhex", 1)]);
    }

    // ---- Document List. Three fixed columns and one row at a time was the port's shape; N++ has the two column
    // toggles, "Group by View", and a menu that acts on every selected file.
    for (NSString *k in @[kDocListExtKey, kDocListPathKey, kDocListGroupKey]) [ud setBool:YES forKey:k];
    NPPDocumentListPanel *list = [[NPPDocumentListPanel alloc] init];
    NPPUtilityPanelsStubContext *ctx = [NPPUtilityPanelsStubContext new];
    NPPDocument *a = [[NPPDocument alloc] initUntitled];
    NPPDocument *b = [[NPPDocument alloc] initUntitled];
    NPPDocument *c = [[NPPDocument alloc] initUntitled];
    ctx.docs = @[a, b, c];
    ctx.subViewDocs = @[c];                              // c lives in the second view
    list.ctx = ctx;
    NSTableView *table = (NSTableView *)((NSScrollView *)list.panelView).documentView;
    table.sortDescriptors = @[];                         // ignore whatever sort the user last left behind
    [list reload];

    // "View 1", a, b, "View 2", c — the headers are rows too, and no header is selectable.
    expect(table.numberOfRows == 5 && [list tableView:table isGroupRow:0] && [list tableView:table isGroupRow:3] &&
           ![list tableView:table shouldSelectRow:0] && [list tableView:table shouldSelectRow:1],
           [NSString stringWithFormat:@"group by view: %ld rows for 2 views over 3 files", (long)table.numberOfRows]);
    [list toggleGroupByView:nil];
    expect(table.numberOfRows == 3 && ![list tableView:table isGroupRow:0],
           [NSString stringWithFormat:@"group by view off: %ld rows", (long)table.numberOfRows]);

    NSTableColumn *ext = [table tableColumnWithIdentifier:@"ext"], *path = [table tableColumnWithIdentifier:@"path"];
    expect(ext && path && !ext.hidden && !path.hidden, @"the Ext / Path columns start hidden");
    [list toggleExtColumn:nil];
    [list togglePathColumn:nil];
    expect(ext.hidden && path.hidden, @"the Ext / Path menu items do not hide their columns");
    [list toggleExtColumn:nil];
    [list togglePathColumn:nil];
    expect(!ext.hidden && !path.hidden, @"the Ext / Path menu items do not bring their columns back");
    // …and the menu says which of the three are on, or a user cannot tell what they toggled.
    NSMenu *options = [list optionsMenu];
    for (NSMenuItem *item in options.itemArray) if (item.action) [list validateMenuItem:item];
    expect(options.itemArray.firstObject.state == NSControlStateValueOn &&
           options.itemArray.lastObject.state == NSControlStateValueOff,   // grouping is off at this point
           @"the options menu does not show which of its settings are on");
    [list toggleGroupByView:nil];
    [list validateMenuItem:options.itemArray.lastObject];
    expect(options.itemArray.lastObject.state == NSControlStateValueOn && table.numberOfRows == 5,
           @"'Group by View' does not follow its own setting");
    [list toggleGroupByView:nil];                        // off again: the rows below are counted without headers

    NSNotification *selChanged = [NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:table];
    expect(table.allowsMultipleSelection, @"the Document List is still single-selection");
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [list tableViewSelectionDidChange:selChanged];
    expect(ctx.selected.lastObject == b, @"selecting one row no longer switches to that document");
    NSUInteger switches = ctx.selected.count;
    [table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];
    [list tableViewSelectionDidChange:selChanged];
    expect(ctx.selected.count == switches, @"extending the selection switched document (N++ NM_CLICK does not)");
    NSArray<NPPDocument *> *targets = [list targetDocuments];
    expect(targets.count == 2 && targets[0] == a && targets[1] == b,
           [NSString stringWithFormat:@"the row menu acts on %lu of 2 selected files", (unsigned long)targets.count]);

    // ---- Right-clicking a row is right-clicking its tab (N++ NppNotification.cpp:1056-1090). Two rows selected,
    // so this is the multi-file menu: the four items N++ shows, and no fewer.
    NSMenu *multi = [list panelTableContextMenu];
    NSArray<NSString *> *want = @[@"Close Selected files", @"Close Other files",
                                  @"Copy Selected Names", @"Copy Selected Pathnames"];
    NSArray<NSString *> *got = [multi.itemArray valueForKey:@"title"] ?: @[];
    expect([got isEqual:want],
           [@"the multi-row menu offers " stringByAppendingString:got.count ? [got componentsJoinedByString:@" / "] : @"nothing"]);
    for (NSMenuItem *item in multi.itemArray)
        expect(item.target == list && item.action && [list respondsToSelector:item.action],
               [@"the multi-row menu item does nothing: " stringByAppendingString:item.title]);

    // ...and one row gets the tab context menu itself, whole, for the tab that row's document sits on.
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    [list tableViewSelectionDidChange:selChanged];
    NSMenu *rowMenu = [list panelTableContextMenu];
    expect(rowMenu == ctx.tabMenu,
           [NSString stringWithFormat:@"a right-clicked row gets %ld items of its own instead of the %ld-item tab menu",
            (long)rowMenu.numberOfItems, (long)ctx.tabMenu.numberOfItems]);
    expect(ctx.selected.lastObject == c && ctx.tabMenuIndex == 2,
           [NSString stringWithFormat:@"the row menu was built for tab %ld, not the right-clicked row's", (long)ctx.tabMenuIndex]);
    // The host it borrows that menu from has to keep answering both selectors, or every row falls back to four items.
    Class hostClass = NSClassFromString(@"NPPEditorWindowController");
    expect(!hostClass || ([hostClass instancesRespondToSelector:@selector(tabBar)] &&
                          [hostClass instancesRespondToSelector:@selector(tabBar:contextMenuForTabAtIndex:)]),
           @"the window controller no longer exposes -tabBar / its context menu: rows lose the tab menu silently");

    // ---- Middle click closes the row, like a middle click on its tab (N++ VerticalFileSwitcher.cpp:303-336).
    NSUInteger before = ctx.commands.count;
    expect([list panelTableMiddleClickAtRow:1] && ctx.commands.count == before + 1 &&
           ctx.commands.lastObject.integerValue == NPPCmdFileClose && ctx.selected.lastObject == b,
           @"a middle click on a Document List row does not close that document");
    expect(![list panelTableMiddleClickAtRow:-1] && ctx.commands.count == before + 1,
           @"a middle click below the last row closed something");
    expect([NPPPanelTableView instanceMethodForSelector:@selector(otherMouseDown:)] !=
           [NSTableView instanceMethodForSelector:@selector(otherMouseDown:)] &&
           [NPPPanelTableView instanceMethodForSelector:@selector(menuForEvent:)] !=
           [NSTableView instanceMethodForSelector:@selector(menuForEvent:)],
           @"the Document List table stopped intercepting middle clicks / right clicks, so neither reaches the panel");

    for (NSString *k in touched) { if (saved[k]) [ud setObject:saved[k] forKey:k]; else [ud removeObjectForKey:k]; }
    return fails;
}

@end
