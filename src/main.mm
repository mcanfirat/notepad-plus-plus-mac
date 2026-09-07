#import <Cocoa/Cocoa.h>
#import "NPPAppDelegate.h"
#import "NPPSelfTest.h"
#import "NPPEditorWindowController.h"
#import "NPPUtils.h"
#import "NPPCommands.h"
#import "NPPLanguageManager.h"
#import "NPPFindPanelController.h"
#import "NPPCommandLine.h"
#pragma clang diagnostic ignored "-Warc-retain-cycles"   // debug hooks: recursive blocks, process exits right after

// Debug aid: NPP_SCREENSHOT=/path/out.png renders the main window's content to a PNG ~2.5 s after launch and quits.
// (Works without Screen Recording permission because it draws the view hierarchy in-process.)
static void NPPRenderWindow(NSWindow *win, NSString *out);

static void NPPScheduleScreenshot(const char *path) {
    NSString *out = [NSString stringWithUTF8String:path];
    // NPP_PANEL_ONLY=<tag> opens one panel first, in its own main-queue block: panels finish their work by queueing
    // blocks on the main queue, and the serial main queue cannot run them while the capture block is executing.
    if (const char *only = getenv("NPP_PANEL_ONLY")) {
        int tag = atoi(only);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (NSWindow *w in NSApp.windows) {
                NPPEditorWindowController *wc0 = (NPPEditorWindowController *)w.windowController;
                if (![wc0 isKindOfClass:NPPEditorWindowController.class]) continue;
                NSMenuItem *fake = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
                fake.tag = tag;
                if ([wc0 validateMenuItem:fake]) [wc0 nppCommand:fake];
                fprintf(stderr, "panel-only %d: visible=%lu\n", tag, (unsigned long)wc0.panelHost.visiblePanels.count);
                break;
            }
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSWindow *win = NSApp.mainWindow ?: NSApp.keyWindow;
        for (NSWindow *w in NSApp.windows) if (!win && w.isVisible && w.frame.size.height > 100) win = w;
        if (!win) { fprintf(stderr, "NPP_SCREENSHOT: no window\n"); exit(2); }
        [NSApp activateIgnoringOtherApps:YES];
        [win makeKeyAndOrderFront:nil];
        NSView *v = win.contentView;
        // Dump the view tree so layout problems are visible even when rendering is not.
        __block void (^dump)(NSView *, int); dump = ^(NSView *view, int depth) {
            fprintf(stderr, "%*s%s frame=(%.0f,%.0f %.0fx%.0f) hidden=%d layer=%d subviews=%lu\n", depth * 2, "", view.className.UTF8String,
                    view.frame.origin.x, view.frame.origin.y, view.frame.size.width, view.frame.size.height, view.isHidden, view.wantsLayer, (unsigned long)view.subviews.count);
            if (depth < 4) for (NSView *sv in view.subviews) dump(sv, depth + 1);
        };
        dump(v, 0);
        // State dump (tab bar + editor) so behaviour can be checked even when a pixel dump is inconclusive.
        NPPEditorWindowController *wc = (NPPEditorWindowController *)win.windowController;
        if ([wc isKindOfClass:NPPEditorWindowController.class]) {
            NSMutableArray *titles = [NSMutableArray array];
            for (NPPTabItem *it in wc.tabBar.items) [titles addObject:[NSString stringWithFormat:@"%@%@", it.dirty ? @"*" : @"", it.title]];
            fprintf(stderr, "tabs(%ld, selected %ld): %s\n", (long)wc.tabBar.items.count, (long)wc.tabBar.selectedIndex, [titles componentsJoinedByString:@" | "].UTF8String);
            ScintillaView *ed = wc.currentDocument.editor;
            if (ed) {
                long len = NPPSci(ed, SCI_GETLENGTH), lines = NPPSci(ed, SCI_GETLINECOUNT);
                char lex[64] = {0}; NPPSci(ed, SCI_GETLEXERLANGUAGE, 0, (sptr_t)lex);
                long fore = NPPSci(ed, SCI_STYLEGETFORE, STYLE_DEFAULT), back = NPPSci(ed, SCI_STYLEGETBACK, STYLE_DEFAULT);
                fprintf(stderr, "editor: len=%ld lines=%ld lexer=%s default fore=%06lX back=%06lX\n", len, lines, lex, fore, back);
            }
        }
        NPPRenderWindow(win, out);
        exit(0);
    });
}

// Debug aid: NPP_TYPETEST=1 sends real key events through NSApp and reports what reached the buffer.
// The self-test edits through SCI_* messages, which skip the whole responder/NSTextInputClient path — the one
// typing actually uses — so a keyboard regression is invisible to every other check here.
static void NPPScheduleTypeTest(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NPPEditorWindowController *wc = nil;
        for (NSWindow *w in NSApp.windows) if ([w.windowController isKindOfClass:NPPEditorWindowController.class]) { wc = (NPPEditorWindowController *)w.windowController; break; }
        if (!wc) { fprintf(stderr, "TYPETEST: no main window controller\n"); exit(10); }
        [NSApp activateIgnoringOtherApps:YES];
        [wc.window makeKeyAndOrderFront:nil];
        ScintillaView *ed = wc.currentDocument.editor;
        NPPSci(ed, SCI_SETTEXT, 0, (sptr_t)"");
        [wc.window makeFirstResponder:[ed content]];
        fprintf(stderr, "TYPETEST: firstResponder=%s keyWindow=%d active=%d\n",
                wc.window.firstResponder.className.UTF8String, wc.window.isKeyWindow, NSApp.isActive);
        const char *word = "Merhaba";
        for (const char *c = word; *c; c++) {
            NSString *ch = [NSString stringWithFormat:@"%c", *c];
            NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                            timestamp:0 windowNumber:wc.window.windowNumber context:nil
                                           characters:ch charactersIgnoringModifiers:ch isARepeat:NO keyCode:0];
            [NSApp sendEvent:down];
        }
        long len = NPPSci(ed, SCI_GETLENGTH);
        char buf[64] = {0};
        if (len > 0 && len < 60) NPPSci(ed, SCI_GETTEXT, (uptr_t)len + 1, (sptr_t)buf);
        BOOL ok = strcmp(buf, word) == 0;
        fprintf(stderr, "TYPETEST: %s — typed \"%s\", buffer holds \"%s\" (len %ld)\n", ok ? "OK" : "FAIL", word, buf, len);
        exit(ok ? 0 : 1);
    });
}

// Debug aid: NPP_EXERCISE=1 drives the running app through menu validation, every language, every theme and a batch of
// safe editor commands (no dialogs), prints a summary and exits. Exit code = number of failures.
static void NPPScheduleExercise(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __block int failures = 0;
        NPPEditorWindowController *wc = nil;
        for (NSWindow *w in NSApp.windows) if ([w.windowController isKindOfClass:NPPEditorWindowController.class]) { wc = (NPPEditorWindowController *)w.windowController; break; }
        if (!wc) { fprintf(stderr, "EXERCISE: no main window controller\n"); exit(10); }
        // 0. the tab bar and the status bar must agree about which document is current (they are updated separately)
        for (NSInteger i = 0; i < (NSInteger)wc.documents.count; i++) {
            [wc selectDocumentAtIndex:i];
            NSString *want = wc.currentDocument.userDefinedLanguageName.length
                ? [NSString stringWithFormat:@"%@ (User Defined)", wc.currentDocument.userDefinedLanguageName]
                : (wc.currentDocument.language.longName ?: @"");
            if (![wc.statusBar.docTypeText isEqualToString:want]) {
                failures++;
                fprintf(stderr, "FAIL status bar for tab %ld: shows \"%s\", document is \"%s\"\n",
                        (long)i, wc.statusBar.docTypeText.UTF8String, want.UTF8String);
            }
            if (wc.tabBar.selectedIndex != i) { failures++; fprintf(stderr, "FAIL tab bar selection %ld != %ld\n", (long)wc.tabBar.selectedIndex, (long)i); }
        }
        // 1. validate every menu item (recursively)
        __block NSInteger items = 0, enabled = 0, unresolved = 0;
        __block void (^walk)(NSMenu *); walk = ^(NSMenu *menu) {
            for (NSMenuItem *it in menu.itemArray) {
                if (it.submenu) { walk(it.submenu); continue; }
                if (it.isSeparatorItem || !it.action) continue;
                items++;
                @try {
                    // Resolve exactly like the menu does, but never let an unresolved target count as "enabled":
                    // nppCommand: items are validated by the window controller (which forwards app-level tags itself).
                    id target = it.target ?: [NSApp targetForAction:it.action to:nil from:it];
                    if (it.action == @selector(nppCommand:) && ![target respondsToSelector:@selector(validateMenuItem:)]) target = wc;
                    BOOL ok = YES;
                    if ([target respondsToSelector:@selector(validateMenuItem:)]) ok = [target validateMenuItem:it];
                    else if ([target respondsToSelector:@selector(validateUserInterfaceItem:)]) ok = [target validateUserInterfaceItem:it];
                    else if (it.action == @selector(nppCommand:)) { ok = NO; unresolved++; }
                    if (ok) enabled++; else fprintf(stderr, "  disabled: %s (tag %ld)\n", it.title.UTF8String, (long)it.tag);
                } @catch (NSException *e) { failures++; fprintf(stderr, "FAIL validate '%s': %s\n", it.title.UTF8String, e.reason.UTF8String); }
            }
        };
        walk(NSApp.mainMenu);
        fprintf(stderr, "menu: %ld items validated, %ld enabled, %ld unresolved\n", (long)items, (long)enabled, (long)unresolved);
        // 2. every language
        NPPDocument *doc = wc.currentDocument;
        NSInteger langs = 0;
        for (NPPLanguage *l in NPPLanguageManager.shared.languages) {
            @try { doc.language = l; NPPSci(doc.editor, SCI_COLOURISE, 0, -1); langs++; }
            @catch (NSException *e) { failures++; fprintf(stderr, "FAIL language %s: %s\n", l.name.UTF8String, e.reason.UTF8String); }
        }
        fprintf(stderr, "languages applied: %ld\n", (long)langs);
        doc.language = [NPPLanguageManager.shared languageNamed:@"cpp"];
        // 3. every theme
        NSString *before = NPPLanguageManager.shared.currentThemeName; NSInteger themes = 0;
        for (NSString *t in NPPLanguageManager.shared.availableThemeNames) {
            NSError *err = nil;
            @try { if ([NPPLanguageManager.shared selectThemeNamed:t error:&err]) themes++; else { failures++; fprintf(stderr, "FAIL theme %s: %s\n", t.UTF8String, err.localizedDescription.UTF8String); } }
            @catch (NSException *e) { failures++; fprintf(stderr, "FAIL theme %s: %s\n", t.UTF8String, e.reason.UTF8String); }
        }
        [NPPLanguageManager.shared selectThemeNamed:before error:nil];
        fprintf(stderr, "themes applied: %ld\n", (long)themes);
        // 4. safe commands (no dialogs)
        NSInteger cmds[] = {
            NPPCmdViewWordWrap, NPPCmdViewWordWrap, NPPCmdViewShowAllChars, NPPCmdViewShowAllChars, NPPCmdViewShowIndentGuide, NPPCmdViewShowIndentGuide,
            NPPCmdViewZoomIn, NPPCmdViewZoomOut, NPPCmdViewZoomRestore, NPPCmdViewFoldAll, NPPCmdViewUnfoldAll, NPPCmdViewFoldLevel1, NPPCmdViewUnfoldLevel1,
            NPPCmdSearchToggleBookmark, NPPCmdSearchNextBookmark, NPPCmdSearchPrevBookmark, NPPCmdSearchInverseBookmarks, NPPCmdSearchClearBookmarks,
            NPPCmdEditDuplicateLine, NPPCmdEditMoveLineDown, NPPCmdEditMoveLineUp, NPPCmdEditToggleLineComment, NPPCmdEditToggleLineComment,
            NPPCmdEditBlockComment, NPPCmdEditBlockUncomment, NPPCmdEditInsertBlankLineBelow, NPPCmdEditInsertBlankLineAbove, NPPCmdEditJoinLines,
            NPPCmdEditTrimTrailing, NPPCmdEditTabToSpace, NPPCmdEditSpaceToTabLeading, NPPCmdEditEOLToWindows, NPPCmdEditEOLToMac, NPPCmdEditEOLToUnix,
            NPPCmdEditSortLexAsc, NPPCmdEditSortLexDesc, NPPCmdEditSortIntAsc, NPPCmdEditSortLengthDesc, NPPCmdEditRemoveDuplicateLines, NPPCmdEditRemoveEmptyLines,
            NPPCmdEditReverseLineOrder, NPPCmdEditRandomizeLineOrder, NPPCmdEditUpperCase, NPPCmdEditLowerCase, NPPCmdEditProperCase, NPPCmdEditInvertCase,
            NPPCmdEditMultiSelectAll, NPPCmdEditMultiSelectUndo, NPPCmdSearchMarkAllExt1, NPPCmdSearchGoNextMarker1, NPPCmdSearchUnmarkAllExt1, NPPCmdSearchClearAllMarks,
            NPPCmdSearchGoToMatchingBrace, NPPCmdSearchSelectBetweenBraces, NPPCmdEditIndent, NPPCmdEditUnindent, NPPCmdEditInsertDateTimeShort, NPPCmdEditAutoCompleteWord,
            NPPCmdEditCopyFullPath, NPPCmdEditCopyAllNames, NPPCmdEncodingConvertToUTF8BOM, NPPCmdEncodingConvertToUTF8, NPPCmdEditToggleReadOnly, NPPCmdEditToggleReadOnly,
            NPPCmdViewTabColor1, NPPCmdViewTabColorNone, NPPCmdViewTabNext, NPPCmdViewTabPrev, NPPCmdViewTabLast, NPPCmdViewTabFirst, NPPCmdViewTabMoveForward, NPPCmdViewTabMoveBackward,
            NPPCmdSearchChangedNext, NPPCmdSearchChangedPrev, NPPCmdViewAlwaysOnTop, NPPCmdViewAlwaysOnTop, NPPCmdSearchSelectAndFindNext, NPPCmdSearchFindNext, NPPCmdSearchFindPrev,
            NPPCmdFileNew, NPPCmdFileClose, NPPCmdFileNew, NPPCmdFileCloseAllUnchanged,
            // feature commands that do not open a dialog
            NPPCmdSearchFindAllInCurrent, NPPCmdSearchFindAllInOpened, NPPCmdSearchResultsNext, NPPCmdSearchResultsPrevious,
            NPPCmdSearchResultsCollapseAll, NPPCmdSearchResultsExpandAll, NPPCmdSearchResultsCopy, NPPCmdSearchResultsClear,
            NPPCmdMacroStartRecording, NPPCmdMacroStopRecording, NPPCmdMacroPlayback,
        };
        NSInteger ran = 0;
        for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
            NSMenuItem *fake = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
            fake.tag = cmds[i];
            @try {
                if (![wc validateMenuItem:fake]) { fprintf(stderr, "skip (disabled) cmd %ld\n", (long)cmds[i]); continue; }
                [wc nppCommand:fake]; ran++;
            } @catch (NSException *e) { failures++; fprintf(stderr, "FAIL cmd %ld: %s\n", (long)cmds[i], e.reason.UTF8String); }
        }
        fprintf(stderr, "commands run: %ld; documents now: %lu; text length: %ld\n", (long)ran, (unsigned long)wc.documents.count, (long)NPPSci(wc.currentDocument.editor, SCI_GETLENGTH));
        // 4b. give Find in Files something to show, so the results panel is exercised with real content
        NPPFindPanelController.shared.searchText = @"int";
        NPPFindPanelController.shared.matchCase = NO;
        NPPFindPanelController.shared.wholeWord = NO;
        NPPFindPanelController.shared.searchMode = NPPSearchModeNormal;
        for (NSInteger tag : {(NSInteger)NPPCmdSearchFindAllInCurrent, (NSInteger)NPPCmdSearchFindAllInOpened}) {
            NSMenuItem *fake = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
            fake.tag = tag;
            @try { if ([wc validateMenuItem:fake]) [wc nppCommand:fake]; }
            @catch (NSException *e) { failures++; fprintf(stderr, "FAIL find-all %ld: %s\n", (long)tag, e.reason.UTF8String); }
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

        // 5. panels: open every one, then close them again
        NSInteger panelCmds[] = { NPPCmdViewWorkspacePanel, NPPCmdViewDocumentMap, NPPCmdViewFunctionList, NPPCmdViewDocumentList,
                                  NPPCmdViewClipboardHistory, NPPCmdViewCharacterPanel, NPPCmdViewProjectPanel1,
                                  NPPCmdSearchResultsPanel };
        NSInteger opened = 0;
        for (size_t i = 0; i < sizeof(panelCmds) / sizeof(panelCmds[0]); i++) {
            NSMenuItem *fake = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
            fake.tag = panelCmds[i];
            @try {
                if (![wc validateMenuItem:fake]) { fprintf(stderr, "panel unavailable: %ld\n", (long)panelCmds[i]); continue; }
                [wc nppCommand:fake];
                opened++;
            } @catch (NSException *e) { failures++; fprintf(stderr, "FAIL panel %ld: %s\n", (long)panelCmds[i], e.reason.UTF8String); }
        }
        [wc.window.contentView layoutSubtreeIfNeeded];
        fprintf(stderr, "panels opened: %ld, visible: %lu\n", (long)opened, (unsigned long)wc.panelHost.visiblePanels.count);
        for (id<NPPPanel> p in wc.panelHost.visiblePanels)
            fprintf(stderr, "  panel: %s view=%s frame=%.0fx%.0f\n", p.panelTitle.UTF8String, p.panelView.className.UTF8String,
                    p.panelView.frame.size.width, p.panelView.frame.size.height);
        // NPP_PANEL_ONLY=<tag> re-opens a single panel for a focused screenshot (all panels were just toggled open above).
        if (const char *only = getenv("NPP_PANEL_ONLY")) {
            for (id<NPPPanel> p in [wc.panelHost.visiblePanels copy]) [wc.panelHost hidePanel:p];
            NSMenuItem *fake = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
            fake.tag = atoi(only);
            if ([wc validateMenuItem:fake]) [wc nppCommand:fake];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];   // let async panels (function list) finish parsing
            fprintf(stderr, "panel-only %s: visible=%lu\n", only, (unsigned long)wc.panelHost.visiblePanels.count);
        }
        if (const char *shot = getenv("NPP_SCREENSHOT")) NPPRenderWindow(wc.window, @(shot));   // panels are open: capture them
        fprintf(stderr, failures ? "EXERCISE FAILED: %d\n" : "EXERCISE OK\n", failures);
        exit(failures);
    });
}


static void NPPRenderWindow(NSWindow *win, NSString *out) {
    if (!win) return;
    NSView *v = win.contentView;
    [v layoutSubtreeIfNeeded];
    [v displayIfNeeded];
    // Two captures, because they fail in different ways and only the pair tells the whole story:
    // the print path re-runs -drawRect: on every view (so it renders even the layer-backed ScintillaView, which
    // -bitmapImageRepForCachingDisplayInRect: returns blank for), while the window capture is the real composited
    // pixels — the only thing that shows a view painting over its siblings. Capturing our own window needs no
    // Screen Recording permission.
    NSData *pdf = [v dataWithPDFInsideRect:v.bounds];
    NSString *base = out.stringByDeletingPathExtension;
    [pdf writeToFile:[base stringByAppendingPathExtension:@"pdf"] atomically:YES];
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[[[NSImage alloc] initWithData:pdf] TIFFRepresentation]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
    fprintf(stderr, "NPP_SCREENSHOT: rendered %ldx%ld -> %s\n", (long)rep.pixelsWide, (long)rep.pixelsHigh, out.UTF8String);

    CGImageRef live = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
                                              (CGWindowID)win.windowNumber, kCGWindowImageBoundsIgnoreFraming);
    if (!live) { fprintf(stderr, "NPP_SCREENSHOT: on-screen capture unavailable\n"); return; }
    NSBitmapImageRep *lrep = [[NSBitmapImageRep alloc] initWithCGImage:live];
    NSString *lp = [NSString stringWithFormat:@"%@-onscreen.png", base];
    [[lrep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:lp atomically:YES];
    fprintf(stderr, "NPP_SCREENSHOT: onscreen %ldx%ld -> %s\n", (long)lrep.pixelsWide, (long)lrep.pixelsHigh, lp.UTF8String);
    CGImageRelease(live);
}


// NPP_EXERCISE_DIALOGS=1: open every dialog-based feature command in turn and dismiss whatever it puts on screen.
// A watchdog kills the process if a dialog blocks (a modal runModal: would hang an automated run), so a hang shows up
// as a failure instead of a stuck build.
static void NPPScheduleDialogExercise(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NPPEditorWindowController *wc = nil;
        for (NSWindow *w in NSApp.windows) if ([w.windowController isKindOfClass:NPPEditorWindowController.class]) { wc = (NPPEditorWindowController *)w.windowController; break; }
        if (!wc) { fprintf(stderr, "DIALOGS: no window\n"); exit(10); }
        struct { const char *name; NSInteger tag; } dialogs[] = {
            {"Find in Files", NPPCmdSearchFindInFiles},
            {"Column Mode tip", NPPCmdEditColumnModeTip}, {"Run", NPPCmdRunDialog}, {"Run: modify", NPPCmdRunModifyCommands},
            {"Column Editor", NPPCmdEditColumnEditor}, {"Macro: run multiple", NPPCmdMacroRunMultiple},
            {"Macro: modify", NPPCmdMacroModifyShortcuts}, {"UDL dialog", NPPCmdLangDefineDialog},
            {"Go to line", NPPCmdSearchGoToLine}, {"Find panel", NPPCmdSearchFind}, {"Replace panel", NPPCmdSearchReplace},
            {"Preferences", NPPCmdSettingsPreferences},
        };
        __block int failures = 0;
        for (auto &dlg : dialogs) {
            NSMenuItem *fake = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(nppCommand:) keyEquivalent:@""];
            fake.tag = dlg.tag;
            BOOL enabled = [wc validateMenuItem:fake];
            if (!enabled) { fprintf(stderr, "  dialog skipped (disabled): %s\n", dlg.name); continue; }
            NSUInteger before = NSApp.windows.count;
            @try {
                [wc nppCommand:fake];
            } @catch (NSException *e) { failures++; fprintf(stderr, "FAIL dialog %s: %s\n", dlg.name, e.reason.UTF8String); continue; }
            // let the sheet/window appear
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
            NSWindow *sheet = wc.window.attachedSheet;
            NSUInteger after = NSApp.windows.count;
            fprintf(stderr, "  dialog %-22s sheet=%s newWindows=%ld\n", dlg.name, sheet ? sheet.className.UTF8String : "-", (long)(after - before));
            if (sheet) [wc.window endSheet:sheet];
            for (NSWindow *w in [NSApp.windows copy])
                if (w != wc.window && w.isVisible && ![w isKindOfClass:NSPanel.class] && w.windowController != wc) [w close];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        }
        fprintf(stderr, failures ? "DIALOGS FAILED: %d\n" : "DIALOGS OK\n", failures);
        exit(failures);
    });
    // watchdog: a blocking modal dialog must not hang an automated run
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        fprintf(stderr, "DIALOGS TIMEOUT: a dialog blocked the main thread\n");
        exit(99);
    });
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--selftest") == 0) {
                [app finishLaunching];   // AppKit ready, no windows shown
                return NPPRunSelfTest();
            }
        }
        [NPPCommandLine applyProcessArguments:NSProcessInfo.processInfo.arguments];
        NPPAppDelegate *delegate = [NPPAppDelegate new];
        app.delegate = delegate;
        if (const char *shot = getenv("NPP_SCREENSHOT")) NPPScheduleScreenshot(shot);
        if (getenv("NPP_TYPETEST")) NPPScheduleTypeTest();
        if (getenv("NPP_EXERCISE")) NPPScheduleExercise();
        if (getenv("NPP_EXERCISE_DIALOGS")) NPPScheduleDialogExercise();
        [app run];
    }
    return 0;
}
