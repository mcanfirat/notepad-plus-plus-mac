// NPPWorkspacePanel.mm — Folder as Workspace, the macOS counterpart of N++ WinControls/FileBrowser.
#import "NPPWorkspacePanel.h"
#import "NPPDocument.h"
#import "NPPPreferences.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <stdlib.h>
#import <limits.h>

static NSString *const kRootsKey  = @"NPPWorkspaceRootPaths";
static NSString *const kHiddenKey = @"NPPWorkspaceShowHiddenFiles";

// NPPFindInFiles' own directory-history key: the head of that list is the directory its sheet opens on.
// This is the only seam that module offers today — see +launchFindInFilesForFolderPath:.
static NSString *const kFIFDirHistoryKey = @"NPPFindInFilesDirectoryHistory";

// "Expand All" materialises folders that were never scanned, so it is capped: the tree is read lazily and a root
// like ~/ would otherwise be a full recursive readdir on the main thread.
// ponytail: a fixed cap with a status line when it bites. Upgrade path: walk on a queue and stream rows in.
static const NSUInteger kExpandAllBudget = 5000;

// N++ FileBrowser's "CMD here" / "PowerShell here" — the same Terminal.app the File menu's Open in Terminal uses.
static NSURL *NPPWsTerminalURL(void) {
    static NSURL *url;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Terminal"]; });
    return url;
}

// Same shape NPPFindInFiles writes its histories in (most recent first, no duplicate, ten entries kept), so
// promoting a folder here leaves a list that module is happy to keep using.
static NSArray<NSString *> *NPPWsHistoryByPromoting(NSString *path, NSArray *history) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id entry in history) if ([entry isKindOfClass:NSString.class] && ![entry isEqualToString:path]) [out addObject:entry];
    [out insertObject:path atIndex:0];
    while (out.count > 10) [out removeLastObject];
    return out;
}

#pragma mark - node

@interface NPPWsNode : NSObject
@property (nonatomic, copy) NSURL *url;
@property (nonatomic) BOOL isDir;
@property (nonatomic) BOOL isRoot;
@property (nonatomic, strong, nullable) NSMutableArray<NPPWsNode *> *children;  // nil == not loaded yet
@property (nonatomic, weak, nullable) NPPWsNode *parent;
@end

@implementation NPPWsNode
+ (instancetype)nodeWithURL:(NSURL *)url isDir:(BOOL)isDir {
    NPPWsNode *n = [NPPWsNode new];
    n.url = url.URLByStandardizingPath;
    n.isDir = isDir;
    return n;
}
- (NSString *)name { return self.url.lastPathComponent ?: self.url.path; }
@end

#pragma mark - outline view (Return opens)

@protocol NPPWsKeyTarget <NSObject>
- (void)wsOpenSelection;
@end

@interface NPPWsOutlineView : NSOutlineView
@property (nonatomic, weak) id<NPPWsKeyTarget> keyTarget;
@end

@implementation NPPWsOutlineView
- (void)keyDown:(NSEvent *)event {
    unichar c = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (c == NSCarriageReturnCharacter || c == NSEnterCharacter) { [self.keyTarget wsOpenSelection]; return; }
    [super keyDown:event];
}
@end

#pragma mark - panel

@interface NPPWorkspacePanel () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
@end

@implementation NPPWorkspacePanel {
    NSView *_view;
    NPPWsOutlineView *_outline;
    NSMutableArray<NPPWsNode *> *_roots;
    NSMutableDictionary<NSString *, id> *_watchers;      // root path -> dispatch_source_t
    NSMutableSet<NSString *> *_pendingRefresh;           // root paths waiting for the coalesced refresh
    __weak id<NPPCommandContext> _context;
    BOOL _showHidden;
    BOOL _followSymlinks;                                // last seen fawAllowSymlink, to spot the flip
    BOOL _bulkExpanding;                                 // Expand All: the folder was scanned a moment ago
}

+ (instancetype)shared {
    static NPPWorkspacePanel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NPPWorkspacePanel new]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _roots = [NSMutableArray array];
    _watchers = [NSMutableDictionary dictionary];
    _pendingRefresh = [NSMutableSet set];
    _showHidden = [[NSUserDefaults standardUserDefaults] boolForKey:kHiddenKey];
    _followSymlinks = NPPPreferences.shared.fawAllowSymlink;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesDidChange:)
                                               name:NPPPreferencesDidChangeNotification object:nil];
    for (NSString *p in [[NSUserDefaults standardUserDefaults] arrayForKey:kRootsKey]) {
        if (![p isKindOfClass:NSString.class]) continue;
        [self addRootPath:p persist:NO];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

// That notification fires after every setter, so re-walk only when this one setting actually flipped:
// following symlinks changes what the walk produces, and the loaded part of the tree is now wrong.
- (void)preferencesDidChange:(NSNotification *)note {
    BOOL follow = NPPPreferences.shared.fawAllowSymlink;
    if (follow == _followSymlinks) return;
    _followSymlinks = follow;
    [self refreshAllRoots];
}

#pragma mark NPPPanel

- (NSString *)panelTitle { return @"Folder as Workspace"; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeLeft; }
- (CGFloat)panelPreferredSize { return 260; }

- (NSView *)panelView {
    if (_view) return _view;
    _outline = [[NPPWsOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 260, 400)];
    _outline.keyTarget = (id<NPPWsKeyTarget>)self;
    _outline.headerView = nil;
    _outline.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    _outline.indentationPerLevel = 14;
    _outline.autoresizesOutlineColumn = NO;
    _outline.floatsGroupRows = NO;
    _outline.allowsMultipleSelection = NO;
    _outline.dataSource = self;
    _outline.delegate = self;
    _outline.target = self;
    _outline.doubleAction = @selector(wsOpenSelection);
    _outline.backgroundColor = NSColor.controlBackgroundColor;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outline addTableColumn:col];
    _outline.outlineTableColumn = col;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;
    _outline.menu = menu;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:_outline.frame];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = _outline;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _view = scroll;
    [_outline reloadData];
    return _view;
}

- (void)panelDidBecomeVisible { [self refreshAllRoots]; }
- (void)panelWillHide {}

- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc {
    NSURL *url = doc.fileURL;
    if (!url || !_outline) return;
    NPPWsNode *node = [self loadedNodeForURL:url.URLByStandardizingPath];
    if (!node) return;
    NSInteger row = [_outline rowForItem:node];   // -1 when a parent is still collapsed: never force-expand
    if (row < 0) return;
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_outline scrollRowToVisible:row];
}

- (NSMenu *)panelActionMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    [[m addItemWithTitle:@"Add folder…" action:@selector(actionAddFolder:) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Remove all" action:@selector(actionRemoveAll:) keyEquivalent:@""] setTarget:self];
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *hid = [m addItemWithTitle:@"Show hidden files" action:@selector(actionToggleHidden:) keyEquivalent:@""];
    hid.target = self;
    hid.state = _showHidden ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];
    // The ⚙ menu stands in for N++'s FileBrowser toolbar (locate current file / fold all / expand all).
    [[m addItemWithTitle:@"Refresh" action:@selector(actionRefresh:) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Expand all" action:@selector(actionExpandAll:) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Collapse all" action:@selector(actionCollapseAll:) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Locate current document" action:@selector(actionLocateCurrentFile:) keyEquivalent:@""] setTarget:self];
    return m;
}

#pragma mark roots

- (void)addRootFolderURL:(NSURL *)url { if (url.isFileURL) [self addRootPath:url.path persist:YES]; }

- (void)addRootPath:(NSString *)path persist:(BOOL)persist {
    if (path.length == 0) return;
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) return;
    NSString *std = [[NSURL fileURLWithPath:path] URLByStandardizingPath].path;
    for (NPPWsNode *r in _roots) if ([r.url.path isEqualToString:std]) return;   // already there (N++ refuses duplicates)

    NPPWsNode *root = [NPPWsNode nodeWithURL:[NSURL fileURLWithPath:std] isDir:YES];
    root.isRoot = YES;
    [_roots addObject:root];
    [self startWatching:root];
    if (persist) [self persistRoots];
    [_outline reloadData];
}

- (void)removeRoot:(NPPWsNode *)root {
    [self stopWatchingPath:root.url.path];
    [_roots removeObject:root];
    [self persistRoots];
    [_outline reloadData];
}

- (void)removeAllRoots {
    for (NPPWsNode *r in [_roots copy]) [self stopWatchingPath:r.url.path];
    [_roots removeAllObjects];
    [self persistRoots];
    [_outline reloadData];
}

- (void)persistRoots {
    NSMutableArray *paths = [NSMutableArray array];
    for (NPPWsNode *r in _roots) if (r.url.path) [paths addObject:r.url.path];
    [[NSUserDefaults standardUserDefaults] setObject:paths forKey:kRootsKey];
}

#pragma mark children

// realpath(3), not -URLByResolvingSymlinksInPath: the latter leaves /tmp and /var alone, so two spellings of
// one directory would not compare equal in the loop guard below. nil when the link dangles or eats itself.
static NSString *NPPWsRealPath(NSString *path) {
    char buf[PATH_MAX];
    if (path.length == 0 || !realpath(path.fileSystemRepresentation, buf)) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:buf length:strlen(buf)];
}

// A symlink whose target sits at or above a folder already on this branch walks forever (upstream never hits
// this: the Win32 walker does not follow links at all). Compare resolved paths up the ancestor chain.
static BOOL NPPWsWouldLoop(NPPWsNode *parent, NSString *target) {
    if (target.length == 0) return YES;
    NSString *inside = [target hasSuffix:@"/"] ? target : [target stringByAppendingString:@"/"];
    for (NPPWsNode *a = parent; a; a = a.parent) {
        NSString *ap = NPPWsRealPath(a.url.path);
        if (!ap) continue;
        if ([ap isEqualToString:target] || [ap hasPrefix:inside]) return YES;   // the branch is at/under the target
    }
    return NO;
}

// ponytail: one directory level is read synchronously — it is a single readdir, not a tree walk.
// followSymlinks is N++ NppGUI::_isFawSymlinkAllowed. Off: a link is listed but stays a leaf (NSURLIsDirectoryKey
// is lstat-shaped, so that is already what happens). On: a link to a folder becomes a folder node, unless
// descending into it would re-enter the branch we are standing on.
static NSMutableArray<NPPWsNode *> *NPPWsScanChildren(NPPWsNode *node, BOOL showHidden, BOOL followSymlinks) {
    NSMutableArray<NPPWsNode *> *out = [NSMutableArray array];
    if (!node.isDir || !node.url) return out;
    NSDirectoryEnumerationOptions opts = NSDirectoryEnumerationSkipsSubdirectoryDescendants |
                                         NSDirectoryEnumerationSkipsPackageDescendants;
    if (!showHidden) opts |= NSDirectoryEnumerationSkipsHiddenFiles;
    // Read through the resolved path — -contentsOfDirectoryAtURL: fails with ENOTDIR on a URL whose last
    // component is a link — but hand the children the path the user sees, so a followed link keeps its own
    // name and Copy Path / Show in Finder / the current-document highlight all stay on the link's spelling.
    NSString *resolved = NPPWsRealPath(node.url.path);
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:
                                   (resolved ? [NSURL fileURLWithPath:resolved isDirectory:YES] : node.url)
                                                         includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                                                                            options:opts
                                                                              error:NULL];
    for (NSURL *u in items) {
        NSNumber *dir = nil, *link = nil;
        [u getResourceValue:&dir forKey:NSURLIsDirectoryKey error:NULL];
        [u getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:NULL];
        BOOL isDir = dir.boolValue;
        struct stat st;   // stat(2) follows the link; a dangling one fails here and stays a leaf
        if (!isDir && followSymlinks && link.boolValue &&
            stat(u.path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode))
            isDir = !NPPWsWouldLoop(node, NPPWsRealPath(u.path));
        NPPWsNode *child = [NPPWsNode nodeWithURL:[node.url URLByAppendingPathComponent:u.lastPathComponent
                                                                           isDirectory:isDir]   // no extra stat
                                            isDir:isDir];
        child.parent = node;
        [out addObject:child];
    }
    [out sortUsingComparator:^NSComparisonResult(NPPWsNode *a, NPPWsNode *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

// Breadth-first list of the folders "Expand All" should open, parents before their children (NSOutlineView can
// only expand a node once its parent is a row) and never more than `budget` of them. Loads children as it goes,
// exactly like -childrenOf:, so a folder that was never opened still expands.
static NSArray<NPPWsNode *> *NPPWsFoldersToExpand(NSArray<NPPWsNode *> *roots, NSUInteger budget,
                                                  BOOL showHidden, BOOL followSymlinks) {
    NSMutableArray<NPPWsNode *> *out = [NSMutableArray array], *queue = [roots mutableCopy];
    while (queue.count && out.count < budget) {
        NPPWsNode *n = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!n.isDir) continue;
        if (!n.children) n.children = NPPWsScanChildren(n, showHidden, followSymlinks);
        [out addObject:n];
        [queue addObjectsFromArray:n.children];
    }
    return out;
}

- (NSMutableArray<NPPWsNode *> *)freshChildrenOf:(NPPWsNode *)node {
    return NPPWsScanChildren(node, _showHidden, NPPPreferences.shared.fawAllowSymlink);
}

- (NSArray<NPPWsNode *> *)childrenOf:(NPPWsNode *)node {
    if (!node.children) node.children = [self freshChildrenOf:node];
    return node.children;
}

// Rebuilds a loaded subtree, reusing existing node objects for surviving paths so the
// outline view keeps its expansion and selection state.
- (void)reloadSubtree:(NPPWsNode *)node {
    if (!node.children) return;
    NSMutableDictionary<NSString *, NPPWsNode *> *old = [NSMutableDictionary dictionary];
    for (NPPWsNode *c in node.children) if (c.url.path) old[c.url.path] = c;
    NSMutableArray<NPPWsNode *> *fresh = [self freshChildrenOf:node];
    for (NSUInteger i = 0; i < fresh.count; i++) {
        NPPWsNode *n = fresh[i];
        NPPWsNode *prev = n.url.path ? old[n.url.path] : nil;
        if (prev && prev.isDir == n.isDir) {
            prev.parent = node;
            fresh[i] = prev;
            [self reloadSubtree:prev];
        }
    }
    node.children = fresh;
}

- (NPPWsNode *)loadedNodeForURL:(NSURL *)url { return [self nodeForURL:url loadingChildren:NO]; }

// loadingChildren: NO for the passive follow (a collapsed branch stays collapsed), YES for "Locate Current
// Document", which is the user asking for the folders on the way to be opened.
- (NPPWsNode *)nodeForURL:(NSURL *)url loadingChildren:(BOOL)load {
    NSString *path = url.path;
    if (path.length == 0) return nil;
    for (NPPWsNode *root in _roots) {
        NSString *rp = root.url.path;
        if (!rp) continue;
        if ([path isEqualToString:rp]) return root;
        if (![path hasPrefix:[rp hasSuffix:@"/"] ? rp : [rp stringByAppendingString:@"/"]]) continue;
        NPPWsNode *cur = root;
        for (NSString *comp in [[path substringFromIndex:rp.length] pathComponents]) {
            if ([comp isEqualToString:@"/"] || comp.length == 0) continue;
            if (!cur.children && load) [self childrenOf:cur];
            if (!cur.children) return nil;   // parent never expanded — nothing to select
            NPPWsNode *next = nil;
            for (NPPWsNode *c in cur.children) if ([c.name isEqualToString:comp]) { next = c; break; }
            if (!next) return nil;
            cur = next;
        }
        return cur;
    }
    return nil;
}

#pragma mark watching

// ponytail: one VNODE source per root folder only; changes deeper in the tree show up on
// the next expand/Refresh. Recursive watching would need one fd per directory (or FSEvents).
- (void)startWatching:(NPPWsNode *)root {
    NSString *path = root.url.path;
    if (path.length == 0 || _watchers[path]) return;
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                                   DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
                                                   dispatch_get_main_queue());
    if (!src) { close(fd); return; }
    __weak NPPWorkspacePanel *weakSelf = self;
    dispatch_source_set_event_handler(src, ^{ [weakSelf scheduleRefreshOfPath:path]; });
    dispatch_source_set_cancel_handler(src, ^{ close(fd); });
    _watchers[path] = src;
    dispatch_resume(src);
}

- (void)stopWatchingPath:(NSString *)path {
    dispatch_source_t src = path ? _watchers[path] : nil;
    if (!src) return;
    dispatch_source_cancel(src);
    [_watchers removeObjectForKey:path];
}

- (void)scheduleRefreshOfPath:(NSString *)path {
    if ([_pendingRefresh containsObject:path]) return;
    [_pendingRefresh addObject:path];
    __weak NPPWorkspacePanel *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NPPWorkspacePanel *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_pendingRefresh removeObject:path];
        for (NPPWsNode *r in strongSelf->_roots) {
            if ([r.url.path isEqualToString:path]) { [strongSelf refreshNode:r]; break; }
        }
    });
}

- (void)refreshNode:(NPPWsNode *)node {
    if (!node) return;
    [self reloadSubtree:node];
    [_outline reloadItem:node reloadChildren:YES];
}

- (void)refreshAllRoots {
    for (NPPWsNode *r in _roots) [self reloadSubtree:r];
    [_outline reloadData];
}

#pragma mark NSOutlineView data source / delegate

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return (NSInteger)_roots.count;
    NPPWsNode *n = item;
    return n.isDir ? (NSInteger)[self childrenOf:n].count : 0;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    NSArray *kids = item ? [self childrenOf:(NPPWsNode *)item] : _roots;
    return (index >= 0 && index < (NSInteger)kids.count) ? kids[(NSUInteger)index] : [NPPWsNode new];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item { return ((NPPWsNode *)item).isDir; }

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    NPPWsNode *node = item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"npp.ws.cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 18)];
        cell.identifier = @"npp.ws.cell";
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 1, 16, 16)];
        iv.autoresizingMask = NSViewMaxXMargin;
        iv.imageScaling = NSImageScaleProportionallyDown;
        [cell addSubview:iv];
        cell.imageView = iv;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(22, 0, 178, 17);
        tf.autoresizingMask = NSViewWidthSizable;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        tf.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
        [cell addSubview:tf];
        cell.textField = tf;
    }
    cell.textField.stringValue = node.isRoot ? (node.url.path.lastPathComponent ?: node.name) : node.name;
    cell.textField.font = node.isRoot ? [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize + 1]
                                      : [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
    cell.imageView.image = node.url.path ? [NSWorkspace.sharedWorkspace iconForFile:node.url.path]
                                         : [NSImage imageWithSystemSymbolName:@"doc.text" accessibilityDescription:nil];
    return cell;
}

- (void)outlineViewItemWillExpand:(NSNotification *)note {
    // Expand All scanned the whole run a moment ago; refreshing here would re-walk each folder's loaded subtree
    // once per folder — quadratic disk work for one click.
    if (_bulkExpanding) return;
    NPPWsNode *n = note.userInfo[@"NSObject"];
    if (n.isDir && n.children) [self reloadSubtree:n];   // freshen just before it becomes visible
}

#pragma mark actions

- (NPPWsNode *)targetNode {
    NSInteger row = (_outline.clickedRow >= 0) ? _outline.clickedRow : _outline.selectedRow;
    return (row >= 0) ? [_outline itemAtRow:row] : nil;
}

- (void)wsOpenSelection {
    NSInteger row = (_outline.clickedRow >= 0) ? _outline.clickedRow : _outline.selectedRow;
    NPPWsNode *node = (row >= 0) ? [_outline itemAtRow:row] : nil;
    if (!node) return;
    if (node.isDir) {
        if ([_outline isItemExpanded:node]) [_outline collapseItem:node]; else [_outline expandItem:node];
        return;
    }
    [_context contextOpenFileURL:node.url];
}

- (void)actionOpen:(id)sender { [self wsOpenSelection]; }

- (void)actionShowInFinder:(id)sender {
    NPPWsNode *n = [self targetNode];
    if (n.url) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[n.url]];
}

- (void)actionCopyPath:(id)sender {
    NPPWsNode *n = [self targetNode];
    if (!n.url.path) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:n.url.path forType:NSPasteboardTypeString];
}

- (NSString *)promptWithTitle:(NSString *)title message:(NSString *)message defaultValue:(NSString *)value {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message ?: @"";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.stringValue = value ?: @"";
    alert.accessoryView = field;
    [alert.window setInitialFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    NSString *out = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return out.length ? out : nil;
}

- (void)actionRename:(id)sender {
    NPPWsNode *n = [self targetNode];
    if (!n.url) return;
    NSString *name = [self promptWithTitle:@"Rename" message:n.url.path defaultValue:n.name];
    if (!name || [name isEqualToString:n.name]) return;
    if ([name containsString:@"/"]) { [_context contextReportStatus:@"Invalid name." isError:YES]; return; }
    NSURL *dst = [n.url.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
    NSError *err = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:n.url toURL:dst error:&err]) {
        [_context contextReportStatus:err.localizedDescription ?: @"Rename failed." isError:YES];
        return;
    }
    // _watchers is keyed by path: cancel under the OLD path before re-pointing the node, else the
    // old source + its O_EVTONLY fd leak and the stale key blocks a future watcher on that path.
    if (n.isRoot) { [self stopWatchingPath:n.url.path]; n.url = dst; [self startWatching:n]; [self persistRoots]; }
    [self refreshNode:n.isRoot ? n : (n.parent ?: n)];
}

- (void)actionDelete:(id)sender {
    NPPWsNode *n = [self targetNode];
    if (!n.url) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Move \"%@\" to the Trash?", n.name];
    alert.informativeText = n.url.path ?: @"";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Move to Trash"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NPPWsNode *parent = n.parent;
    BOOL wasRoot = n.isRoot;
    NSError *err = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:n.url resultingItemURL:NULL error:&err]) {
        [_context contextReportStatus:err.localizedDescription ?: @"Delete failed." isError:YES];
        return;
    }
    if (wasRoot) [self removeRoot:n]; else [self refreshNode:parent];
}

- (void)createChildNamed:(NSString *)name directory:(BOOL)directory in:(NPPWsNode *)folder {
    NSURL *dst = [folder.url URLByAppendingPathComponent:name];
    NSError *err = nil;
    BOOL ok = directory ? [NSFileManager.defaultManager createDirectoryAtURL:dst withIntermediateDirectories:NO attributes:nil error:&err]
                        : [NSData.data writeToURL:dst options:NSDataWritingWithoutOverwriting error:&err];
    if (!ok) { [_context contextReportStatus:err.localizedDescription ?: @"Create failed." isError:YES]; return; }
    [self refreshNode:folder];
    if (!directory) [_context contextOpenFileURL:dst];
}

- (NPPWsNode *)targetFolder {
    NPPWsNode *n = [self targetNode];
    if (!n) return _roots.firstObject;
    return n.isDir ? n : n.parent;
}

- (void)actionNewFile:(id)sender {
    NPPWsNode *folder = [self targetFolder];
    if (!folder) return;
    NSString *name = [self promptWithTitle:@"New File" message:folder.url.path defaultValue:@""];
    if (name) [self createChildNamed:name directory:NO in:folder];
}

- (void)actionNewFolder:(id)sender {
    NPPWsNode *folder = [self targetFolder];
    if (!folder) return;
    NSString *name = [self promptWithTitle:@"New Folder" message:folder.url.path defaultValue:@""];
    if (name) [self createChildNamed:name directory:YES in:folder];
}

- (void)actionRefreshItem:(id)sender {
    NPPWsNode *n = [self targetNode];
    [self refreshNode:(n.isDir ? n : n.parent)];
}

- (void)actionRemoveFromWorkspace:(id)sender {
    NPPWsNode *n = [self targetNode];
    if (n.isRoot) [self removeRoot:n];
}

- (void)actionAddFolder:(id)sender { [self runAddFolderPanel]; }
- (void)actionRemoveAll:(id)sender { [self removeAllRoots]; }
- (void)actionRefresh:(id)sender { [self refreshAllRoots]; }
- (void)actionCollapseAll:(id)sender { for (NPPWsNode *r in _roots) [_outline collapseItem:r collapseChildren:YES]; }

// N++ FileBrowser's FB_CMD_EXPANDALL / FB_CMD_FOLDALL toolbar buttons.
- (void)actionExpandAll:(id)sender {
    NSArray<NPPWsNode *> *folders = NPPWsFoldersToExpand(_roots, kExpandAllBudget, _showHidden,
                                                         NPPPreferences.shared.fawAllowSymlink);
    _bulkExpanding = YES;
    for (NPPWsNode *n in folders) [_outline expandItem:n];
    _bulkExpanding = NO;
    if (folders.count >= kExpandAllBudget)
        [_context contextReportStatus:[NSString stringWithFormat:@"Expand All stopped after %lu folders.",
                                       (unsigned long)kExpandAllBudget] isError:NO];
}

// FB_CMD_AIMFILE / FileBrowser::selectCurrentEditingFile: unlike the passive follow in
// -panelDidChangeCurrentDocument:, this one opens the folders on the way.
- (void)actionLocateCurrentFile:(id)sender {
    NSURL *url = [_context contextCurrentDocument].fileURL.URLByStandardizingPath;
    if (!url) { [_context contextReportStatus:@"The current document has no file on disk." isError:YES]; return; }
    NPPWsNode *node = [self nodeForURL:url loadingChildren:YES];
    if (!node) {
        [_context contextReportStatus:[NSString stringWithFormat:@"\"%@\" is not in any workspace folder.",
                                       url.lastPathComponent] isError:YES];
        return;
    }
    // Top down: NSOutlineView only knows a node once its parent is expanded, so a deepest-first pass would
    // expand nothing at all.
    NSMutableArray<NPPWsNode *> *ancestors = [NSMutableArray array];
    for (NPPWsNode *a = node.parent; a; a = a.parent) [ancestors insertObject:a atIndex:0];
    for (NPPWsNode *a in ancestors) [_outline expandItem:a];
    NSInteger row = [_outline rowForItem:node];
    if (row < 0) return;
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_outline scrollRowToVisible:row];
    [_outline.window makeFirstResponder:_outline];
}

// N++ FileBrowser IDM_FILEBROWSER_FINDINFILES (root and folder menus only).
- (void)actionFindInFiles:(id)sender {
    NPPWsNode *folder = [self targetFolder];
    if (![NPPWorkspacePanel launchFindInFilesForFolderPath:folder.url.path])
        [_context contextReportStatus:@"Find in Files is unavailable." isError:YES];
}

// N++ FileBrowser IDM_FILEBROWSER_CMDHERE: a shell sitting in the clicked folder (a file's folder for a file).
- (void)actionOpenInTerminal:(id)sender {
    NPPWsNode *folder = [self targetFolder];
    NSURL *dir = folder.url, *term = NPPWsTerminalURL();
    if (!dir || !term) return;
    __weak NPPWorkspacePanel *weakSelf = self;
    [NSWorkspace.sharedWorkspace openURLs:@[dir] withApplicationAtURL:term
                            configuration:[NSWorkspaceOpenConfiguration configuration]
                        completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (!error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NPPWorkspacePanel *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_context contextReportStatus:[NSString stringWithFormat:@"Open in Terminal failed: %@",
                                                       error.localizedDescription] isError:YES];
        });
    }];
}

- (void)actionToggleHidden:(id)sender {
    _showHidden = !_showHidden;
    [[NSUserDefaults standardUserDefaults] setBool:_showHidden forKey:kHiddenKey];
    [self refreshAllRoots];
}

// N++ sends NPPM_LAUNCHFINDINFILESDLG with the folder and Notepad_plus::setFindReplaceFolderFilter drops it into
// the dialog's Directory field. NPPFindInFiles has no such entry point, so the folder is promoted to the head of
// the directory history that its sheet reads, and the sheet itself is asked for through the tag the Search menu
// already uses — that module keeps owning the dialog.
// ponytail: with Preferences ▸ Searching "Fill Find in Files Directory field based on the active document" on
// (off by default, as in N++), the sheet still prefers the active document's folder; the Directory field shows
// which folder it will search either way. Upgrade path: -showFindInFilesSheetWithContext:directory: over there.
+ (BOOL)launchFindInFilesForFolderPath:(NSString *)folderPath {
    BOOL isDir = NO;
    if (!folderPath.length || ![NSFileManager.defaultManager fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir)
        return NO;
    // Asked by name, like every other cross-module call here: a build without NPPFindInFiles says so instead of
    // promoting a directory nothing will ever read.
    Class fif = NSClassFromString(@"NPPFindInFiles");
    if (![fif respondsToSelector:@selector(handlesCommand:)] ||
        ![(Class<NPPCommandHandler>)fif handlesCommand:NPPCmdSearchFindInFiles]) return NO;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setObject:NPPWsHistoryByPromoting(folderPath, [ud arrayForKey:kFIFDirHistoryKey]) forKey:kFIFDirHistoryKey];
    NSMenuItem *proxy = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(nppCommand:) keyEquivalent:@""];
    proxy.tag = NPPCmdSearchFindInFiles;
    return [NSApp sendAction:@selector(nppCommand:) to:nil from:proxy];
}

- (void)runAddFolderPanel {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.canCreateDirectories = NO;
    panel.prompt = @"Add";
    panel.message = @"Select a folder to add in Folder as Workspace panel";
    if ([panel runModal] != NSModalResponseOK) return;
    for (NSURL *u in panel.URLs) [self addRootFolderURL:u];
}

#pragma mark context menu

- (void)menuNeedsUpdate:(NSMenu *)menu { [self buildContextMenu:menu forNode:[self targetNode]]; }

// Split out from -menuNeedsUpdate: so the self-check can build the menu of a node it made up: an item that is
// offered must have a target that answers for it, or the panel is back to controls that do nothing.
- (void)buildContextMenu:(NSMenu *)menu forNode:(NPPWsNode *)n {
    [menu removeAllItems];
    void (^add)(NSString *, SEL) = ^(NSString *title, SEL sel) {
        [[menu addItemWithTitle:title action:sel keyEquivalent:@""] setTarget:self];
    };
    if (!n) {
        add(@"Add folder…", @selector(actionAddFolder:));
        return;
    }
    if (!n.isDir) add(@"Open", @selector(actionOpen:));
    add(@"Show in Finder", @selector(actionShowInFinder:));
    add(@"Copy Path", @selector(actionCopyPath:));
    if (n.isDir) add(@"Find in Files…", @selector(actionFindInFiles:));       // N++ offers it on folders only
    if (NPPWsTerminalURL()) add(@"Open in Terminal", @selector(actionOpenInTerminal:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Rename…", @selector(actionRename:));
    add(@"Delete", @selector(actionDelete:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"New File…", @selector(actionNewFile:));
    add(@"New Folder…", @selector(actionNewFolder:));
    add(@"Refresh", @selector(actionRefreshItem:));
    if (n.isRoot) {
        [menu addItem:NSMenuItem.separatorItem];
        add(@"Remove from workspace", @selector(actionRemoveFromWorkspace:));
    }
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Expand All", @selector(actionExpandAll:));
    add(@"Collapse All", @selector(actionCollapseAll:));
    add(@"Locate Current Document", @selector(actionLocateCurrentFile:));
}

#pragma mark NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
    return cmd == NPPCmdViewWorkspacePanel || cmd == NPPCmdFileOpenFolderAsWorkspace;
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return [self handlesCommand:cmd] && context != nil;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NPPWorkspacePanel *panel = [self shared];
    panel->_context = context;
    switch (cmd) {
        case NPPCmdViewWorkspacePanel:
            [context contextTogglePanel:panel];
            return YES;
        case NPPCmdFileOpenFolderAsWorkspace: {
            NSUInteger before = panel->_roots.count;
            [panel runAddFolderPanel];
            if (panel->_roots.count > before) [context contextShowPanel:panel];
            return YES;
        }
        default: return NO;
    }
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return cmd == NPPCmdViewWorkspacePanel && [context contextPanelIsVisible:[self shared]];
}

#pragma mark - Headless checks (NPPSelfTest calls +selfCheckFailures)

static NPPWsNode *NPPWsChildNamed(NSArray<NPPWsNode *> *nodes, NSString *name) {
    for (NPPWsNode *n in nodes) if ([n.name isEqualToString:name]) return n;
    return nil;
}

// Walks the whole tree eagerly (the panel itself only ever walks what the user expands) against a node budget
// and nothing else, so a broken loop guard shows up as an exhausted budget instead of a hung test. The budget
// is also what bounds the recursion depth here.
static NSUInteger NPPWsWalkTree(NPPWsNode *node, NSUInteger *budget) {
    NSUInteger seen = 0;
    for (NPPWsNode *c in NPPWsScanChildren(node, YES, YES)) {
        if (*budget == 0) return seen;
        (*budget)--;
        seen++;
        if (c.isDir) seen += NPPWsWalkTree(c, budget);
    }
    return seen;
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *what) { if (!ok) [fails addObject:what]; };

    // base/real/target.txt and base/top/{plain.txt, link -> base/real, loop -> base, dangling -> nowhere}
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                   URLByAppendingPathComponent:[@"npp-ws-symlink-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSURL *real = [base URLByAppendingPathComponent:@"real"], *top = [base URLByAppendingPathComponent:@"top"];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:real withIntermediateDirectories:YES attributes:nil error:&err] ||
        ![fm createDirectoryAtURL:top withIntermediateDirectories:YES attributes:nil error:&err] ||
        ![@"x" writeToURL:[real URLByAppendingPathComponent:@"target.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&err] ||
        ![@"x" writeToURL:[top URLByAppendingPathComponent:@"plain.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&err] ||
        ![fm createSymbolicLinkAtURL:[top URLByAppendingPathComponent:@"link"] withDestinationURL:real error:&err] ||
        ![fm createSymbolicLinkAtURL:[top URLByAppendingPathComponent:@"loop"] withDestinationURL:base error:&err] ||
        ![fm createSymbolicLinkAtURL:[top URLByAppendingPathComponent:@"dangling"]
                 withDestinationURL:[base URLByAppendingPathComponent:@"gone"] error:&err]) {
        [fm removeItemAtURL:base error:NULL];
        return @[[NSString stringWithFormat:@"could not build the symlink fixture: %@", err.localizedDescription]];
    }

    NPPWsNode *root = [NPPWsNode nodeWithURL:top isDir:YES];

    // fawAllowSymlink off: every link is listed, none of them is a folder to descend into
    NSArray<NPPWsNode *> *off = NPPWsScanChildren(root, NO, NO);
    expect(NPPWsChildNamed(off, @"link") != nil, @"symlink is hidden from the tree when following is off");
    expect(!NPPWsChildNamed(off, @"link").isDir, @"symlink to a folder is descendable with fawAllowSymlink off");
    expect(NPPWsScanChildren(NPPWsChildNamed(off, @"link"), NO, NO).count == 0,
           @"symlink to a folder still yields children with fawAllowSymlink off");

    // on: a link to a folder becomes a folder, but not one that re-enters this branch
    NSArray<NPPWsNode *> *on = NPPWsScanChildren(root, NO, YES);
    NPPWsNode *linked = NPPWsChildNamed(on, @"link");
    expect(linked.isDir, @"symlink to a folder is not followed with fawAllowSymlink on");
    expect(NPPWsChildNamed(NPPWsScanChildren(linked, NO, YES), @"target.txt") != nil,
           @"followed symlink does not list the target folder's contents");
    expect(!NPPWsChildNamed(on, @"loop").isDir, @"symlink pointing at an ancestor is followed: the walk loops");
    expect(!NPPWsChildNamed(on, @"dangling").isDir, @"dangling symlink is treated as a folder");
    expect(NPPWsChildNamed(on, @"plain.txt") != nil && !NPPWsChildNamed(on, @"plain.txt").isDir,
           @"plain file lost or turned into a folder");

    // and walking the whole fixture stays the size of the fixture: 8 nodes. Without the guard the branch is
    // re-walked until the kernel's own symlink-resolution limit stops it — 135 nodes here, and a multiple of
    // that in any real folder — so the budget has to sit between the two, not merely be finite.
    NSUInteger budget = 24;
    NSUInteger seen = NPPWsWalkTree([NPPWsNode nodeWithURL:base isDir:YES], &budget);
    expect(budget > 0, [NSString stringWithFormat:@"walking a symlink cycle never ended (%lu nodes)", (unsigned long)seen]);

    // ---- Expand All: the folders of this fixture are base, real, top and the followed link, parents first.
    NSArray<NPPWsNode *> *all = NPPWsFoldersToExpand(@[[NPPWsNode nodeWithURL:base isDir:YES]], 100, YES, YES);
    expect(all.count == 4, [NSString stringWithFormat:@"Expand All found %lu folders, the fixture has 4",
                            (unsigned long)all.count]);
    expect(all.firstObject.url.path.length && [all.firstObject.url.path isEqualToString:base.URLByStandardizingPath.path],
           @"Expand All does not start at the root");
    for (NSUInteger i = 0; i < all.count; i++) {
        NPPWsNode *p = all[i].parent;
        expect(!p || [[all subarrayWithRange:NSMakeRange(0, i)] containsObject:p],
               [NSString stringWithFormat:@"Expand All lists \"%@\" before its parent: NSOutlineView cannot expand it",
                all[i].name]);
    }
    expect(NPPWsFoldersToExpand(@[[NPPWsNode nodeWithURL:base isDir:YES]], 2, YES, YES).count == 2,
           @"Expand All ignores its budget: a huge root would be walked whole on the main thread");

    // Refused before anything is written: only a folder that exists may become the sheet's directory.
    expect(![NPPWorkspacePanel launchFindInFilesForFolderPath:[top URLByAppendingPathComponent:@"plain.txt"].path],
           @"Find in Files accepted a file as its directory");
    expect(![NPPWorkspacePanel launchFindInFilesForFolderPath:[base URLByAppendingPathComponent:@"gone"].path],
           @"Find in Files accepted a folder that does not exist");

    [fm removeItemAtURL:base error:NULL];   // removefile(3) unlinks the links, it does not follow them

    // ---- Find in Files scoping: the folder must end up at the head of the history NPPFindInFiles reads,
    // once, without dropping what was there and without growing past the ten entries that module keeps.
    NSArray<NSString *> *hist = NPPWsHistoryByPromoting(@"/tmp/b", (@[@"/tmp/a", @"/tmp/b", @"/tmp/c"]));
    expect([hist.firstObject isEqualToString:@"/tmp/b"], @"Find in Files: the clicked folder is not the directory the sheet opens on");
    expect(hist.count == 3, [NSString stringWithFormat:@"Find in Files: history kept %lu entries, want 3 (duplicate not removed?)",
                             (unsigned long)hist.count]);
    expect([hist[1] isEqualToString:@"/tmp/a"] && [hist[2] isEqualToString:@"/tmp/c"],
           @"Find in Files: promoting a folder reordered the rest of the history");
    NSMutableArray *long12 = [NSMutableArray array];
    for (int i = 0; i < 12; i++) [long12 addObject:[NSString stringWithFormat:@"/tmp/%d", i]];
    expect(NPPWsHistoryByPromoting(@"/tmp/new", long12).count == 10, @"Find in Files: directory history grew past ten entries");

    // ---- Every context-menu item must have a target that answers for it (the panel's first rule), and
    // "Find in Files…" is a folder-only item, as in N++.
    NPPWorkspacePanel *panel = [NPPWorkspacePanel shared];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NPPWsNode *folderNode = [NPPWsNode nodeWithURL:[NSURL fileURLWithPath:NSTemporaryDirectory()] isDir:YES];
    folderNode.isRoot = YES;
    [panel buildContextMenu:menu forNode:folderNode];
    NSMutableSet<NSString *> *titles = [NSMutableSet set];
    for (NSMenuItem *it in menu.itemArray) {
        if (it.isSeparatorItem) continue;
        [titles addObject:it.title];
        if (!it.target || ![it.target respondsToSelector:it.action])
            [fails addObject:[NSString stringWithFormat:@"context menu item \"%@\" has no target that answers it", it.title]];
    }
    for (NSString *want in @[@"Find in Files…", @"Expand All", @"Collapse All", @"Locate Current Document"])
        expect([titles containsObject:want], [NSString stringWithFormat:@"folder context menu has no \"%@\"", want]);
    NPPWsNode *fileNode = [NPPWsNode nodeWithURL:[[NSURL fileURLWithPath:NSTemporaryDirectory()]
                                                  URLByAppendingPathComponent:@"x.txt"] isDir:NO];
    [panel buildContextMenu:menu forNode:fileNode];
    for (NSMenuItem *it in menu.itemArray)
        if ([it.title isEqualToString:@"Find in Files…"])
            [fails addObject:@"Find in Files… is offered on a file (N++ offers it on folders only)"];

    return fails;
}

@end
