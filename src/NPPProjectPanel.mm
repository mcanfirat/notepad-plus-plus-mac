// NPPProjectPanel.mm — the three Project Panels, the macOS counterpart of N++ WinControls/ProjectPanel.
#import "NPPProjectPanel.h"
#import "NPPDocument.h"
#import "NPPWorkspacePanel.h"   // +launchFindInFilesForFolderPath: — one route to the Find in Files sheet for both panels

static NSString *const kWorkspacePathKeyFmt = @"NPPProjectPanel%ldWorkspacePath";
static NSString *const kNodeDragType        = @"com.notepad-plus-plus.mac.projectnode";

typedef NS_ENUM(NSInteger, NPPProjKind) {
    NPPProjKindRoot = 0,     // the workspace itself (single tree root)
    NPPProjKindProject,
    NPPProjKindFolder,
    NPPProjKindFile,
};

// What the user typed into "Modify File Path", turned into an absolute path the same way a workspace file's
// <File name="…"> is: backslashes flipped (workspaces written on Windows), ~ expanded, and a relative path taken
// as relative to where the entry used to point — a moved file is usually still near its old neighbours.
// nil for an empty entry, i.e. "leave it alone".
static NSString *NPPProjRelocalizedPath(NSString *entered, NSString *oldPath) {
    NSString *p = [[entered ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                   stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (!p.length) return nil;
    // -isAbsolutePath counts a leading ~ as absolute and -stringByStandardizingPath expands it, so there is no
    // separate tilde step here.
    if (!p.isAbsolutePath) p = [oldPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:p];
    return p.stringByStandardizingPath;
}

// Deepest folder holding every one of `paths`; nil when they share nothing but the volume root, because
// "Find in Projects" over "/" is not a search anybody asked for.
static NSString *NPPProjCommonFolder(NSArray<NSString *> *paths) {
    NSArray<NSString *> *common = nil;
    for (NSString *p in paths) {
        if (!p.isAbsolutePath) continue;
        NSArray<NSString *> *comps = p.stringByDeletingLastPathComponent.pathComponents;
        if (!common) { common = comps; continue; }
        NSUInteger n = MIN(common.count, comps.count), i = 0;
        while (i < n && [common[i] isEqualToString:comps[i]]) i++;
        common = [common subarrayWithRange:NSMakeRange(0, i)];
    }
    return common.count >= 2 ? [NSString pathWithComponents:common] : nil;   // ["/"] alone is not a folder to search
}

#pragma mark - node

@interface NPPProjNode : NSObject
@property (nonatomic) NPPProjKind kind;
@property (nonatomic, copy) NSString *name;                              // display label
@property (nonatomic, copy, nullable) NSString *path;                    // absolute path, files only
@property (nonatomic, strong) NSMutableArray<NPPProjNode *> *children;
@property (nonatomic, weak, nullable) NPPProjNode *parent;
@property (nonatomic, copy) NSString *uid;
@end

@implementation NPPProjNode
+ (instancetype)nodeOfKind:(NPPProjKind)kind name:(NSString *)name {
    NPPProjNode *n = [NPPProjNode new];
    n.kind = kind;
    n.name = name.length ? name : @"";
    n.children = [NSMutableArray array];
    n.uid = NSUUID.UUID.UUIDString;
    return n;
}
- (BOOL)isContainer { return self.kind != NPPProjKindFile; }
- (void)addChild:(NPPProjNode *)child { child.parent = self; [self.children addObject:child]; }
- (void)insertChild:(NPPProjNode *)child at:(NSInteger)index {
    child.parent = self;
    NSInteger i = MAX(0, MIN(index, (NSInteger)self.children.count));
    [self.children insertObject:child atIndex:(NSUInteger)i];
}
- (BOOL)isDescendantOf:(NPPProjNode *)other {
    for (NPPProjNode *p = self.parent; p; p = p.parent) if (p == other) return YES;
    return NO;
}
// Still reachable from root? A removed node keeps its parent pointer, so walk the
// child arrays too; a node of a replaced tree has a nil (weak) parent chain instead.
- (BOOL)isAttachedTo:(NPPProjNode *)root {
    for (NPPProjNode *c = self; c != root; c = c.parent) {
        NPPProjNode *p = c.parent;
        if (!p || ![p.children containsObject:c]) return NO;
    }
    return YES;
}
@end

#pragma mark - outline view (Return opens, Delete removes)

@protocol NPPProjKeyTarget <NSObject>
- (void)projOpenSelection;
@end

@interface NPPProjOutlineView : NSOutlineView
@property (nonatomic, weak) id<NPPProjKeyTarget> keyTarget;
@end

@implementation NPPProjOutlineView
- (void)keyDown:(NSEvent *)event {
    unichar c = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (c == NSCarriageReturnCharacter || c == NSEnterCharacter) { [self.keyTarget projOpenSelection]; return; }
    [super keyDown:event];
}
@end

#pragma mark - panel

@interface NPPProjectPanel () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NPPProjKeyTarget>
@end

@implementation NPPProjectPanel {
    NSInteger _index;
    NSView *_view;
    NPPProjOutlineView *_outline;
    NPPProjNode *_root;
    NSString *_workspacePath;          // nil == never saved
    BOOL _dirty;
    NSArray<NPPProjNode *> *_dragNodes;
    NSUInteger _scanToken;             // cancels an in-flight "Add Files from Directory" walk
}

+ (instancetype)panelAtIndex:(NSInteger)index {
    static NSMutableDictionary<NSNumber *, NPPProjectPanel *> *panels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ panels = [NSMutableDictionary dictionary]; });
    NSInteger i = (index < 0 || index > 2) ? 0 : index;
    NPPProjectPanel *p = panels[@(i)];
    if (!p) {
        p = [[NPPProjectPanel alloc] initWithIndex:i];
        panels[@(i)] = p;
    }
    return p;
}

- (instancetype)initWithIndex:(NSInteger)index {
    if (!(self = [super init])) return nil;
    _index = index;
    [self resetToEmptyWorkspace];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:[self defaultsKey]];
    if (saved.length && [NSFileManager.defaultManager fileExistsAtPath:saved])
        [self loadWorkspaceAtPath:saved];
    return self;
}

- (NSString *)defaultsKey { return [NSString stringWithFormat:kWorkspacePathKeyFmt, (long)_index]; }

#pragma mark NPPPanel

- (NSString *)panelTitle { return [NSString stringWithFormat:@"Project Panel %ld", (long)(_index + 1)]; }
- (NPPPanelEdge)panelPreferredEdge { return NPPPanelEdgeLeft; }
- (CGFloat)panelPreferredSize { return 260; }

- (NSView *)panelView {
    if (_view) return _view;
    _outline = [[NPPProjOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 260, 400)];
    _outline.keyTarget = self;
    _outline.headerView = nil;
    _outline.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    _outline.indentationPerLevel = 14;
    _outline.autoresizesOutlineColumn = NO;
    _outline.allowsMultipleSelection = YES;
    _outline.dataSource = self;
    _outline.delegate = self;
    _outline.target = self;
    _outline.doubleAction = @selector(projOpenSelection);
    _outline.backgroundColor = NSColor.controlBackgroundColor;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outline addTableColumn:col];
    _outline.outlineTableColumn = col;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;
    _outline.menu = menu;

    [_outline registerForDraggedTypes:@[kNodeDragType, NSPasteboardTypeFileURL]];
    [_outline setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:_outline.frame];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = _outline;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _view = scroll;
    [_outline reloadData];
    [_outline expandItem:_root];
    return _view;
}

- (void)panelDidBecomeVisible { [_outline reloadData]; }
- (void)panelWillHide {}

- (void)panelDidChangeCurrentDocument:(NPPDocument *)doc {
    NSString *path = doc.fileURL.URLByStandardizingPath.path;
    if (!path.length || !_outline) return;
    NPPProjNode *hit = [self findFileNodeWithPath:path under:_root];
    if (!hit) return;
    NSInteger row = [_outline rowForItem:hit];   // -1 while a parent is collapsed: never force-expand
    if (row < 0) return;
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_outline scrollRowToVisible:row];
}

- (NPPProjNode *)findFileNodeWithPath:(NSString *)path under:(NPPProjNode *)node {
    for (NPPProjNode *c in node.children) {
        if (c.kind == NPPProjKindFile) {
            if ([c.path isEqualToString:path]) return c;
        } else {
            NPPProjNode *hit = [self findFileNodeWithPath:path under:c];
            if (hit) return hit;
        }
    }
    return nil;
}

- (NSMenu *)panelActionMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    void (^add)(NSString *, SEL) = ^(NSString *title, SEL sel) {
        [[m addItemWithTitle:title action:sel keyEquivalent:@""] setTarget:self];
    };
    add(@"New Workspace", @selector(actionNewWorkspace:));
    add(@"Open Workspace…", @selector(actionOpenWorkspace:));
    add(@"Save Workspace", @selector(actionSaveWorkspace:));
    add(@"Save Workspace As…", @selector(actionSaveWorkspaceAs:));
    [m addItem:NSMenuItem.separatorItem];
    add(@"Add New Project", @selector(actionAddNewProject:));
    if ([self findInProjectsFolder]) add(@"Find in Projects…", @selector(actionFindInProjects:));
    return m;
}

#pragma mark workspace model

- (void)resetToEmptyWorkspace {
    _root = [NPPProjNode nodeOfKind:NPPProjKindRoot name:@"Workspace"];
    _workspacePath = nil;
    _dirty = NO;
}

- (BOOL)hasUnsavedChanges { return _dirty; }

- (void)setDirty:(BOOL)dirty {
    _dirty = dirty;
    _root.name = _workspacePath.length ? _workspacePath.lastPathComponent : @"Workspace";
    if (dirty) _root.name = [_root.name stringByAppendingString:@" *"];
    [_outline reloadItem:_root];
}

- (void)markDirty { [self setDirty:YES]; }

#pragma mark XML I/O (N++ format)

- (BOOL)openWorkspaceURL:(NSURL *)url {
    if (!url.isFileURL) return NO;
    if (![self confirmDiscardChanges]) return NO;
    return [self loadWorkspaceAtPath:url.URLByStandardizingPath.path];
}

- (BOOL)loadWorkspaceAtPath:(NSString *)path {
    if (!path.length) return NO;
    NSError *err = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                             options:NSXMLNodeOptionsNone error:&err];
    NSXMLElement *rootEl = doc.rootElement;
    if (!rootEl || ![rootEl.name isEqualToString:@"NotepadPlus"]) return NO;

    NPPProjNode *newRoot = [NPPProjNode nodeOfKind:NPPProjKindRoot name:path.lastPathComponent];
    NSString *base = path.stringByDeletingLastPathComponent;
    for (NSXMLElement *projEl in [rootEl elementsForName:@"Project"]) {
        NPPProjNode *proj = [NPPProjNode nodeOfKind:NPPProjKindProject
                                               name:[projEl attributeForName:@"name"].stringValue ?: @"Project"];
        [newRoot addChild:proj];
        [self buildTreeFrom:projEl into:proj base:base];
    }
    _root = newRoot;
    _workspacePath = path;
    [NSUserDefaults.standardUserDefaults setObject:path forKey:[self defaultsKey]];
    [self setDirty:NO];
    [_outline reloadData];
    [_outline expandItem:_root];
    for (NPPProjNode *p in _root.children) [_outline expandItem:p];
    return YES;
}

- (void)buildTreeFrom:(NSXMLElement *)el into:(NPPProjNode *)parent base:(NSString *)base {
    for (NSXMLNode *child in el.children) {
        if (child.kind != NSXMLElementKind) continue;
        NSXMLElement *ce = (NSXMLElement *)child;
        NSString *name = [ce attributeForName:@"name"].stringValue ?: @"";
        if ([ce.name isEqualToString:@"Folder"]) {
            NPPProjNode *folder = [NPPProjNode nodeOfKind:NPPProjKindFolder name:name.length ? name : @"Folder"];
            [parent addChild:folder];
            [self buildTreeFrom:ce into:folder base:base];
        } else if ([ce.name isEqualToString:@"File"] && name.length) {
            NPPProjNode *file = [NPPProjNode nodeOfKind:NPPProjKindFile name:name.lastPathComponent];
            file.path = [self absolutePathFor:name base:base];
            [parent addChild:file];
        }
    }
}

- (NSString *)absolutePathFor:(NSString *)stored base:(NSString *)base {
    NSString *p = [stored stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];   // workspaces written on Windows
    if (p.isAbsolutePath || (p.length > 1 && [p characterAtIndex:1] == ':')) return p;
    return [[base stringByAppendingPathComponent:p] stringByStandardizingPath];
}

// N++ getRelativePath: relative only when the file lives under the workspace file's directory.
- (NSString *)storedPathFor:(NSString *)absolute relativeTo:(NSString *)workspaceFile {
    NSString *dir = workspaceFile.stringByDeletingLastPathComponent;
    if (!dir.length || !absolute.length) return absolute ?: @"";
    NSString *prefix = [dir hasSuffix:@"/"] ? dir : [dir stringByAppendingString:@"/"];
    if (![absolute hasPrefix:prefix]) return absolute;
    return [absolute substringFromIndex:prefix.length];
}

static NSString *NPPProjXmlEscape(NSString *s) {
    NSMutableString *m = [(s ?: @"") mutableCopy];
    [m replaceOccurrencesOfString:@"&"  withString:@"&amp;"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<"  withString:@"&lt;"   options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">"  withString:@"&gt;"   options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

- (NSString *)xmlForWorkspaceFile:(NSString *)workspaceFile {
    NSMutableString *out = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<NotepadPlus>\n"];
    for (NPPProjNode *proj in _root.children) {
        [out appendFormat:@"    <Project name=\"%@\">\n", NPPProjXmlEscape(proj.name)];
        [self appendXmlFor:proj into:out indent:@"        " workspaceFile:workspaceFile];
        [out appendString:@"    </Project>\n"];
    }
    [out appendString:@"</NotepadPlus>\n"];
    return out;
}

- (void)appendXmlFor:(NPPProjNode *)node into:(NSMutableString *)out indent:(NSString *)indent workspaceFile:(NSString *)wsFile {
    for (NPPProjNode *c in node.children) {
        if (c.kind == NPPProjKindFile) {
            [out appendFormat:@"%@<File name=\"%@\" />\n", indent,
                 NPPProjXmlEscape([self storedPathFor:c.path relativeTo:wsFile])];
        } else {
            [out appendFormat:@"%@<Folder name=\"%@\">\n", indent, NPPProjXmlEscape(c.name)];
            [self appendXmlFor:c into:out indent:[indent stringByAppendingString:@"    "] workspaceFile:wsFile];
            [out appendFormat:@"%@</Folder>\n", indent];
        }
    }
}

- (BOOL)writeWorkspaceToPath:(NSString *)path {
    NSError *err = nil;
    NSString *xml = [self xmlForWorkspaceFile:path];
    if (![xml writeToURL:[NSURL fileURLWithPath:path] atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        [self report:err.localizedDescription ?: @"An error occurred while writing your workspace file." error:YES];
        return NO;
    }
    _workspacePath = path;
    [NSUserDefaults.standardUserDefaults setObject:path forKey:[self defaultsKey]];
    [self setDirty:NO];
    return YES;
}

- (BOOL)saveWorkspace {
    if (!_workspacePath.length) return [self saveWorkspaceAs];
    return [self writeWorkspaceToPath:_workspacePath];
}

- (BOOL)saveWorkspaceAs {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"xml"];
    panel.nameFieldStringValue = _workspacePath.lastPathComponent ?: @"workspace.xml";
    panel.prompt = @"Save";
    panel.message = @"Save workspace";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return NO;
    return [self writeWorkspaceToPath:panel.URL.path];
}

// Returns NO when the user cancels out of replacing an unsaved workspace.
- (BOOL)confirmDiscardChanges {
    if (!_dirty) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"The workspace was modified. Do you want to save it?";
    alert.informativeText = _workspacePath ?: @"Workspace";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Don't Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse r = [alert runModal];
    if (r == NSAlertFirstButtonReturn) return [self saveWorkspace];
    if (r == NSAlertSecondButtonReturn) return YES;
    return NO;
}

#pragma mark workspace actions

- (void)actionNewWorkspace:(id)sender {
    if (![self confirmDiscardChanges]) return;
    [self resetToEmptyWorkspace];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[self defaultsKey]];
    [_outline reloadData];
    [_outline expandItem:_root];
}

- (void)actionOpenWorkspace:(id)sender {
    if (![self confirmDiscardChanges]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedFileTypes = @[@"xml"];
    panel.prompt = @"Open";
    panel.message = @"Open workspace";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    if (![self loadWorkspaceAtPath:panel.URL.path])
        [self report:@"The workspace file is not valid." error:YES];
}

- (void)actionSaveWorkspace:(id)sender   { [self saveWorkspace]; }
- (void)actionSaveWorkspaceAs:(id)sender { [self saveWorkspaceAs]; }

#pragma mark tree actions

- (NPPProjNode *)targetNode {
    NSInteger row = (_outline.clickedRow >= 0) ? _outline.clickedRow : _outline.selectedRow;
    return (row >= 0) ? [_outline itemAtRow:row] : _root;
}

- (void)refreshItem:(NPPProjNode *)node {
    [_outline reloadItem:(node == _root ? nil : node) reloadChildren:YES];
    if (node && node != _root) [_outline expandItem:node];
}

- (void)actionAddNewProject:(id)sender {
    NSString *name = [self promptWithTitle:@"Add New Project" message:@"Project name" defaultValue:@"Project Name"];
    if (!name) return;
    [_root addChild:[NPPProjNode nodeOfKind:NPPProjKindProject name:name]];
    [self markDirty];
    [_outline reloadData];
    [_outline expandItem:_root];
}

- (void)actionRename:(id)sender {
    NPPProjNode *n = [self targetNode];
    if (!n || n.kind == NPPProjKindRoot) return;
    NSString *name = [self promptWithTitle:@"Rename" message:(n.path ?: n.name) defaultValue:n.name];
    if (!name) return;
    n.name = name;   // ponytail: on a file this renames the label only, like N++ (the XML stores the path).
    [self markDirty];
    [_outline reloadItem:n];
}

- (void)actionAddFolder:(id)sender {
    NPPProjNode *n = [self containerTarget];
    if (!n || n.kind == NPPProjKindRoot) return;
    NSString *name = [self promptWithTitle:@"Add Folder" message:@"Folder name" defaultValue:@"Folder Name"];
    if (!name) return;
    [n addChild:[NPPProjNode nodeOfKind:NPPProjKindFolder name:name]];
    [self markDirty];
    [self refreshItem:n];
}

- (NPPProjNode *)containerTarget {
    NPPProjNode *n = [self targetNode];
    if (!n) return nil;
    return n.isContainer ? n : n.parent;
}

- (void)addFileURLs:(NSArray<NSURL *> *)urls to:(NPPProjNode *)parent atIndex:(NSInteger)index {
    if (!parent || parent.kind == NPPProjKindRoot) return;
    NSInteger at = (index < 0) ? (NSInteger)parent.children.count : index;
    for (NSURL *u in urls) {
        if (!u.isFileURL) continue;
        NSString *p = u.URLByStandardizingPath.path;
        if (!p.length) continue;
        NPPProjNode *f = [NPPProjNode nodeOfKind:NPPProjKindFile name:p.lastPathComponent];
        f.path = p;
        [parent insertChild:f at:at++];
    }
    [self markDirty];
    [self refreshItem:parent];
}

- (void)actionAddFiles:(id)sender {
    NPPProjNode *n = [self containerTarget];
    if (!n || n.kind == NPPProjKindRoot) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Add";
    panel.message = @"Add files";
    if ([panel runModal] != NSModalResponseOK) return;
    [self addFileURLs:panel.URLs to:n atIndex:-1];
}

- (void)actionAddFilesFromDirectory:(id)sender {
    NPPProjNode *n = [self containerTarget];
    if (!n || n.kind == NPPProjKindRoot) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Add";
    panel.message = @"Add files from directory (recursively)";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;

    NSURL *dir = panel.URL.URLByStandardizingPath;
    NSUInteger token = ++_scanToken;
    __weak NPPProjectPanel *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSURL *> *files = [NPPProjectPanel filesUnderDirectory:dir cancelIf:^BOOL{
            NPPProjectPanel *s = weakSelf;
            return !s || s->_scanToken != token;
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            NPPProjectPanel *s = weakSelf;
            if (!s || s->_scanToken != token || files.count == 0) return;
            // The tree may have been replaced (New/Open Workspace) or the target removed
            // while we walked the directory — don't commit into a discarded node.
            if (![n isAttachedTo:s->_root]) return;
            NPPProjNode *top = [NPPProjNode nodeOfKind:NPPProjKindFolder name:dir.lastPathComponent ?: @"Folder"];
            [n addChild:top];
            NSString *base = dir.path;
            for (NSURL *u in files) {
                NSString *p = u.path;
                NSString *rel = [p hasPrefix:[base stringByAppendingString:@"/"]]
                              ? [p substringFromIndex:base.length + 1] : p.lastPathComponent;
                NPPProjNode *parent = top;
                NSArray<NSString *> *comps = rel.pathComponents;
                for (NSUInteger i = 0; i + 1 < comps.count; i++)
                    parent = [s folderNamed:comps[i] under:parent];
                NPPProjNode *f = [NPPProjNode nodeOfKind:NPPProjKindFile name:p.lastPathComponent];
                f.path = p;
                [parent addChild:f];
            }
            [s markDirty];
            [s refreshItem:n];
        });
    });
}

- (NPPProjNode *)folderNamed:(NSString *)name under:(NPPProjNode *)parent {
    for (NPPProjNode *c in parent.children)
        if (c.kind == NPPProjKindFolder && [c.name isEqualToString:name]) return c;
    NPPProjNode *f = [NPPProjNode nodeOfKind:NPPProjKindFolder name:name];
    [parent addChild:f];
    return f;
}

// ponytail: hidden files skipped, no extension filter — N++'s dialog has one; add a filter field if asked.
+ (NSArray<NSURL *> *)filesUnderDirectory:(NSURL *)dir cancelIf:(BOOL (^)(void))cancelled {
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:dir
                                                 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                    options:NSDirectoryEnumerationSkipsHiddenFiles |
                                                                            NSDirectoryEnumerationSkipsPackageDescendants
                                                               errorHandler:nil];
    for (NSURL *u in e) {
        if (cancelled && cancelled()) return @[];
        NSNumber *isDir = nil;
        [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
        if (!isDir.boolValue) [out addObject:u.URLByStandardizingPath];
    }
    [out sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.path localizedStandardCompare:b.path];
    }];
    return out;
}

- (void)actionRemoveNode:(id)sender {
    NPPProjNode *n = [self targetNode];
    if (!n || n.kind == NPPProjKindRoot || !n.parent) return;
    if (n.isContainer) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"All the sub-items will be removed.\nAre you sure you want to remove \"%@\" from the project?", n.name];
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"Remove"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    NPPProjNode *parent = n.parent;
    [parent.children removeObject:n];
    [self markDirty];
    [_outline reloadItem:(parent == _root ? nil : parent) reloadChildren:YES];
}

- (void)moveTargetBy:(NSInteger)delta {
    NPPProjNode *n = [self targetNode];
    NPPProjNode *parent = n.parent;
    if (!parent) return;
    NSUInteger i = [parent.children indexOfObject:n];
    if (i == NSNotFound) return;
    NSInteger j = (NSInteger)i + delta;
    if (j < 0 || j >= (NSInteger)parent.children.count) return;
    [parent.children removeObjectAtIndex:i];
    [parent.children insertObject:n atIndex:(NSUInteger)j];
    [self markDirty];
    [_outline reloadItem:(parent == _root ? nil : parent) reloadChildren:YES];
    NSInteger row = [_outline rowForItem:n];
    if (row >= 0) [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)actionMoveUp:(id)sender   { [self moveTargetBy:-1]; }
- (void)actionMoveDown:(id)sender { [self moveTargetBy:1]; }

// N++ IDM_PROJECT_MODIFYFILEPATH (FileRelocalizerDlg): point an entry at the file's new place. The label follows
// the new file name, and the red "missing file" colouring re-evaluates when the row is redrawn.
- (void)actionModifyFilePath:(id)sender {
    NPPProjNode *n = [self targetNode];
    if (n.kind != NPPProjKindFile) return;
    NSString *entered = [self promptWithTitle:@"Modify File Path" message:(n.path ?: n.name)
                                 defaultValue:(n.path ?: @"")];
    NSString *path = NPPProjRelocalizedPath(entered, n.path);
    if (!path || [path isEqualToString:n.path]) return;
    n.path = path;
    n.name = path.lastPathComponent;
    [self markDirty];
    [_outline reloadItem:n];
}

- (void)collectFilePathsUnder:(NPPProjNode *)node into:(NSMutableArray<NSString *> *)out {
    for (NPPProjNode *c in node.children) {
        if (c.kind == NPPProjKindFile) { if (c.path.length) [out addObject:c.path]; }
        else [self collectFilePathsUnder:c into:out];
    }
}

// nil when this workspace has no files, when they share no folder, or when that folder is gone — the menu item
// is then not offered at all, rather than offered and then refused.
- (NSString *)findInProjectsFolder {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [self collectFilePathsUnder:_root into:paths];
    NSString *dir = NPPProjCommonFolder(paths);
    BOOL isDir = NO;
    return (dir && [NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir] && isDir) ? dir : nil;
}

// N++ IDM_PROJECT_FINDINPROJECTSWS opens the Find dialog in its "Find in Projects" mode, which searches the files
// listed in the ticked project panels. NPPFindInFiles can only search a directory, so this scopes the search to
// the deepest folder holding every file of this workspace; the sheet's Directory field shows exactly that.
// ponytail: that folder is a superset of the workspace's files. Upgrade path: a file-list entry point in
// NPPFindInFiles — its findInFiles loop differs from what this needs only in where the file list comes from.
- (void)actionFindInProjects:(id)sender {
    NSString *dir = [self findInProjectsFolder];
    if (!dir) return;
    if (![NPPWorkspacePanel launchFindInFilesForFolderPath:dir])
        [self report:@"Find in Files is unavailable." error:YES];
}

- (void)actionShowInFinder:(id)sender {
    NPPProjNode *n = [self targetNode];
    if (n.path.length) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:n.path]]];
}

- (void)projOpenSelection {
    NSInteger row = (_outline.clickedRow >= 0) ? _outline.clickedRow : _outline.selectedRow;
    NPPProjNode *n = (row >= 0) ? [_outline itemAtRow:row] : nil;
    if (!n) return;
    if (n.isContainer) {
        if ([_outline isItemExpanded:n]) [_outline collapseItem:n]; else [_outline expandItem:n];
        return;
    }
    if (!n.path.length) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:n.path]) {
        [self report:[NSString stringWithFormat:@"The file \"%@\" doesn't exist.", n.path] error:YES];
        return;
    }
    [self.commandContext contextOpenFileURL:[NSURL fileURLWithPath:n.path]];
}

- (void)actionOpen:(id)sender { [self projOpenSelection]; }

- (void)report:(NSString *)message error:(BOOL)isError {
    id<NPPCommandContext> ctx = self.commandContext;
    if (ctx) { [ctx contextReportStatus:message isError:isError]; return; }
    if (!isError) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = message ?: @"";
    [alert runModal];
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

#pragma mark NSOutlineView data source

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return 1;                                  // the workspace root
    return (NSInteger)((NPPProjNode *)item).children.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return _root;
    NSArray *kids = ((NPPProjNode *)item).children;
    return (index >= 0 && index < (NSInteger)kids.count) ? kids[(NSUInteger)index]
                                                         : [NPPProjNode nodeOfKind:NPPProjKindFile name:@""];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return ((NPPProjNode *)item).isContainer;
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    NPPProjNode *n = item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"npp.proj.cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 18)];
        cell.identifier = @"npp.proj.cell";
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 1, 16, 16)];
        iv.autoresizingMask = NSViewMaxXMargin;
        iv.imageScaling = NSImageScaleProportionallyDown;
        [cell addSubview:iv];
        cell.imageView = iv;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(22, 0, 178, 17);
        tf.autoresizingMask = NSViewWidthSizable;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:tf];
        cell.textField = tf;
    }
    BOOL missing = (n.kind == NPPProjKindFile) && (!n.path.length || ![NSFileManager.defaultManager fileExistsAtPath:n.path]);
    CGFloat size = NSFont.smallSystemFontSize + 1;
    cell.textField.stringValue = n.name ?: @"";
    cell.textField.font = (n.kind == NPPProjKindRoot || n.kind == NPPProjKindProject)
                        ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    cell.textField.textColor = missing ? NSColor.systemRedColor : NSColor.labelColor;
    NSString *symbol = @"doc.text";
    switch (n.kind) {
        case NPPProjKindRoot:    symbol = @"square.stack.3d.up"; break;
        case NPPProjKindProject: symbol = @"shippingbox"; break;
        case NPPProjKindFolder:  symbol = @"folder"; break;
        case NPPProjKindFile:    symbol = missing ? @"exclamationmark.triangle" : @"doc.text"; break;
    }
    NSImage *img = (n.kind == NPPProjKindFile && !missing && n.path.length)
                 ? [NSWorkspace.sharedWorkspace iconForFile:n.path]
                 : [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    cell.imageView.image = img;
    return cell;
}

- (NSString *)outlineView:(NSOutlineView *)ov toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect
              tableColumn:(NSTableColumn *)col item:(id)item mouseLocation:(NSPoint)pt {
    NPPProjNode *n = item;
    if (n.kind == NPPProjKindFile) {
        if (!n.path.length || ![NSFileManager.defaultManager fileExistsAtPath:n.path])
            return [NSString stringWithFormat:@"missing: %@", n.path ?: n.name];
        return n.path;
    }
    if (n.kind == NPPProjKindRoot) return _workspacePath ?: @"Workspace (not saved)";
    return n.name;
}

#pragma mark drag & drop

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(id)item {
    NPPProjNode *n = item;
    if (n.kind == NPPProjKindRoot) return nil;
    NSPasteboardItem *pbItem = [NSPasteboardItem new];
    [pbItem setString:n.uid forType:kNodeDragType];
    return pbItem;
}

- (void)outlineView:(NSOutlineView *)ov draggingSession:(NSDraggingSession *)session
   willBeginAtPoint:(NSPoint)pt forItems:(NSArray *)items {
    _dragNodes = [items copy];
}

- (void)outlineView:(NSOutlineView *)ov draggingSession:(NSDraggingSession *)session
       endedAtPoint:(NSPoint)pt operation:(NSDragOperation)op {
    _dragNodes = nil;
}

- (NSDragOperation)outlineView:(NSOutlineView *)ov validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item proposedChildIndex:(NSInteger)index {
    NPPProjNode *target = item ?: _root;
    if (!target.isContainer) return NSDragOperationNone;

    if (_dragNodes.count && info.draggingSource == ov) {
        for (NPPProjNode *n in _dragNodes) {
            if (n == target || [target isDescendantOf:n]) return NSDragOperationNone;
            BOOL intoRoot = (target.kind == NPPProjKindRoot);
            if (intoRoot != (n.kind == NPPProjKindProject)) return NSDragOperationNone;   // projects only at root, others only inside
        }
        return NSDragOperationMove;
    }
    if (target.kind == NPPProjKindRoot) return NSDragOperationNone;                      // files need a project or folder
    return [info.draggingPasteboard canReadObjectForClasses:@[NSURL.class]
                                                    options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]
           ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)ov acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item childIndex:(NSInteger)index {
    NPPProjNode *target = item ?: _root;
    if (!target.isContainer) return NO;

    if (_dragNodes.count && info.draggingSource == ov) {
        NSInteger at = (index < 0) ? (NSInteger)target.children.count : index;
        NSMutableSet *touched = [NSMutableSet setWithObject:target];
        for (NPPProjNode *n in _dragNodes) {
            NPPProjNode *old = n.parent;
            if (!old) continue;
            NSUInteger i = [old.children indexOfObject:n];
            if (i == NSNotFound) continue;
            if (old == target && (NSInteger)i < at) at--;
            [old.children removeObjectAtIndex:i];
            [touched addObject:old];
            [target insertChild:n at:at++];
        }
        _dragNodes = nil;
        [self markDirty];
        [_outline reloadData];
        [_outline expandItem:_root];
        [_outline expandItem:target];
        return YES;
    }

    NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                                   options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count || target.kind == NPPProjKindRoot) return NO;
    [self addFileURLs:urls to:target atIndex:index];
    return YES;
}

#pragma mark context menu (mirrors N++'s workspace/project/folder/file menus)

- (void)menuNeedsUpdate:(NSMenu *)menu { [self buildContextMenu:menu forNode:([self targetNode] ?: _root)]; }

// Split out from -menuNeedsUpdate: so the self-check can build the menu of a node it made up: an offered item
// must have a target that answers for it, and one that cannot act (Find in Projects over nothing) is not offered.
- (void)buildContextMenu:(NSMenu *)menu forNode:(NPPProjNode *)n {
    [menu removeAllItems];
    __weak NPPProjectPanel *weakSelf = self;
    void (^add)(NSString *, SEL) = ^(NSString *title, SEL sel) {
        [[menu addItemWithTitle:title action:sel keyEquivalent:@""] setTarget:weakSelf];
    };
    switch (n.kind) {
        case NPPProjKindRoot:
            add(@"Add New Project", @selector(actionAddNewProject:));
            if ([self findInProjectsFolder]) add(@"Find in Projects…", @selector(actionFindInProjects:));
            [menu addItem:NSMenuItem.separatorItem];
            add(@"New Workspace", @selector(actionNewWorkspace:));
            add(@"Open Workspace…", @selector(actionOpenWorkspace:));
            add(@"Save Workspace", @selector(actionSaveWorkspace:));
            add(@"Save Workspace As…", @selector(actionSaveWorkspaceAs:));
            break;
        case NPPProjKindProject:
        case NPPProjKindFolder:
            add(@"Move Up", @selector(actionMoveUp:));
            add(@"Move Down", @selector(actionMoveDown:));
            [menu addItem:NSMenuItem.separatorItem];
            add(@"Rename…", @selector(actionRename:));
            add(@"Add Folder…", @selector(actionAddFolder:));
            add(@"Add Files…", @selector(actionAddFiles:));
            add(@"Add Files from Directory…", @selector(actionAddFilesFromDirectory:));
            add(n.kind == NPPProjKindProject ? @"Remove Project" : @"Remove Folder", @selector(actionRemoveNode:));
            break;
        case NPPProjKindFile:
            add(@"Open", @selector(actionOpen:));
            [menu addItem:NSMenuItem.separatorItem];
            add(@"Move Up", @selector(actionMoveUp:));
            add(@"Move Down", @selector(actionMoveDown:));
            [menu addItem:NSMenuItem.separatorItem];
            add(@"Rename…", @selector(actionRename:));
            add(@"Modify File Path…", @selector(actionModifyFilePath:));
            add(@"Remove File", @selector(actionRemoveNode:));
            add(@"Show in Finder", @selector(actionShowInFinder:));
            break;
    }
}

#pragma mark NPPCommandHandler

+ (NSInteger)indexForCommand:(NPPCmd)cmd {
    switch (cmd) {
        case NPPCmdViewProjectPanel1: return 0;
        case NPPCmdViewProjectPanel2: return 1;
        case NPPCmdViewProjectPanel3: return 2;
        default: return -1;
    }
}

+ (BOOL)handlesCommand:(NPPCmd)cmd { return [self indexForCommand:cmd] >= 0; }

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    return [self handlesCommand:cmd] && context != nil;
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NSInteger i = [self indexForCommand:cmd];
    if (i < 0 || !context) return NO;
    NPPProjectPanel *panel = [self panelAtIndex:i];
    panel.commandContext = context;
    [context contextTogglePanel:panel];
    return YES;
}

+ (BOOL)commandIsChecked:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
    NSInteger i = [self indexForCommand:cmd];
    return (i >= 0 && context) ? [context contextPanelIsVisible:[self panelAtIndex:i]] : NO;
}

#pragma mark - Headless checks (NPPSelfTest calls +selfCheckFailures)

// A panel built with plain +new, never -initWithIndex:, so nothing here reads, loads or rewrites the workspace
// the user has open in Project Panel 1.
+ (NPPProjectPanel *)scratchPanelWithFilePaths:(NSArray<NSString *> *)paths {
    NPPProjectPanel *p = [NPPProjectPanel new];
    p->_root = [NPPProjNode nodeOfKind:NPPProjKindRoot name:@"Workspace"];
    NPPProjNode *project = [NPPProjNode nodeOfKind:NPPProjKindProject name:@"Project"];
    [p->_root addChild:project];
    for (NSString *path in paths) {
        NPPProjNode *f = [NPPProjNode nodeOfKind:NPPProjKindFile name:path.lastPathComponent];
        f.path = path;
        [project addChild:f];
    }
    return p;
}

+ (NSArray<NSString *> *)titlesOfMenuFor:(NPPProjNode *)node panel:(NPPProjectPanel *)panel
                            unanswerable:(NSMutableArray<NSString *> *)unanswerable {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [panel buildContextMenu:menu forNode:node];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSMenuItem *it in menu.itemArray) {
        if (it.isSeparatorItem) continue;
        [titles addObject:it.title];
        if (!it.target || ![it.target respondsToSelector:it.action]) [unanswerable addObject:it.title];
    }
    return titles;
}

+ (NSArray<NSString *> *)selfCheckFailures {
    NSMutableArray<NSString *> *fails = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL ok, NSString *what) { if (!ok) [fails addObject:what]; };
    void (^expectStr)(NSString *, NSString *, NSString *) = ^(NSString *what, NSString *got, NSString *want) {
        if (got != want && ![got isEqualToString:want])
            [fails addObject:[NSString stringWithFormat:@"%@: got %@, want %@", what, got ?: @"(nil)", want ?: @"(nil)"]];
    };

    // ---- Modify File Path: what the user types becomes an absolute path the same way the XML's does.
    expectStr(@"Modify File Path keeps an absolute path", NPPProjRelocalizedPath(@"/tmp/moved/x.txt", @"/old/x.txt"),
              @"/tmp/moved/x.txt");
    expectStr(@"Modify File Path resolves a relative path against the entry's old folder",
              NPPProjRelocalizedPath(@"sub/b.txt", @"/a/x.txt"), @"/a/sub/b.txt");
    expectStr(@"Modify File Path does not flip a Windows workspace's backslashes",
              NPPProjRelocalizedPath(@"sub\\b.txt", @"/a/x.txt"), @"/a/sub/b.txt");
    expectStr(@"Modify File Path does not expand ~", NPPProjRelocalizedPath(@"~/b.txt", @"/a/x.txt"),
              [NSHomeDirectory() stringByAppendingPathComponent:@"b.txt"]);
    expect(NPPProjRelocalizedPath(@"   ", @"/a/x.txt") == nil, @"Modify File Path accepts a blank path");

    // ---- Find in Projects scope.
    expectStr(@"Find in Projects scope for files in one folder",
              NPPProjCommonFolder(@[@"/a/b/x.c", @"/a/b/y.c"]), @"/a/b");
    expectStr(@"Find in Projects scope for files in sibling folders",
              NPPProjCommonFolder(@[@"/a/b/x.c", @"/a/c/y.c"]), @"/a");
    expectStr(@"Find in Projects scope for a single file", NPPProjCommonFolder(@[@"/a/b/x.c"]), @"/a/b");
    expect(NPPProjCommonFolder(@[@"/a/x.c", @"/b/y.c"]) == nil,
           @"Find in Projects would search \"/\" for files that share no folder");
    expect(NPPProjCommonFolder(@[]) == nil, @"Find in Projects offers a scope for a workspace with no files");

    // ---- Every context-menu item must have a target that answers for it, and an item that cannot act
    // (Find in Projects with nothing to scope to) must not be offered at all.
    NSMutableArray<NSString *> *unanswerable = [NSMutableArray array];
    // Real folder, files that need not exist: the scope has to be a folder that is still there.
    NSString *tmp = NSTemporaryDirectory();
    NPPProjectPanel *panel = [self scratchPanelWithFilePaths:@[[tmp stringByAppendingPathComponent:@"x.c"],
                                                               [tmp stringByAppendingPathComponent:@"y.c"]]];
    NPPProjNode *fileNode = panel->_root.children.firstObject.children.firstObject;
    NSArray<NSString *> *fileTitles = [self titlesOfMenuFor:fileNode panel:panel unanswerable:unanswerable];
    expect([fileTitles containsObject:@"Modify File Path…"], @"the file context menu has no \"Modify File Path…\"");
    expect([[self titlesOfMenuFor:panel->_root panel:panel unanswerable:unanswerable] containsObject:@"Find in Projects…"],
           @"the workspace context menu has no \"Find in Projects…\"");
    NPPProjectPanel *empty = [self scratchPanelWithFilePaths:@[]];
    expect(![[self titlesOfMenuFor:empty->_root panel:empty unanswerable:unanswerable] containsObject:@"Find in Projects…"],
           @"\"Find in Projects…\" is offered for a workspace with no files to search");
    NPPProjectPanel *gone = [self scratchPanelWithFilePaths:@[@"/no/such/folder/x.c", @"/no/such/folder/y.c"]];
    expect(![[self titlesOfMenuFor:gone->_root panel:gone unanswerable:unanswerable] containsObject:@"Find in Projects…"],
           @"\"Find in Projects…\" is offered although the folder its files lived in is gone");
    if (unanswerable.count)
        [fails addObject:[NSString stringWithFormat:@"context menu items with no target that answers them: %@",
                          [unanswerable componentsJoinedByString:@", "]]];

    return fails;
}

@end
