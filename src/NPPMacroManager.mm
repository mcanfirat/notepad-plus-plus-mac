// NPPMacroManager.mm — the Macro menu (N++ Notepad_plus::macroPlayback / _macro / _recordingMacro,
// NppCommands.cpp IDM_MACRO_*, WinControls/shortcut/RunMacroDlg).
//
// HOW RECORDING IS HOOKED UP
// SCI_STARTRECORD makes Scintilla emit SCN_MACRORECORD notifications carrying {message, wParam, lParam}.
// ScintillaView has exactly ONE delegate (id<ScintillaNotificationProtocol>) and NPPDocument already owns it,
// and this module may not edit NPPDocument. So we install a *forwarder*: NPPMacroRecordForwarder remembers the
// view's current delegate, becomes the delegate for the duration of the recording, forwards every notification
// to the remembered delegate unchanged, and additionally captures the ones with nmhdr.code == SCN_MACRORECORD.
// The previous delegate is restored when recording stops, when the recorded document changes, and in dealloc.
// (ScintillaView.delegate is unsafe_unretained, so the manager holds the forwarder strongly for its lifetime.)
#import "NPPMacroManager.h"
#import "NPPDocument.h"
#import "NPPUtils.h"

static NSString *const kSavedMacrosDefaultsKey = @"NPPMacroSavedMacros";
static const NSInteger kMaxSavedMacros = 100;   // NPPCmdMacroSavedBase .. +99 (see NPPCommands.h)

#pragma mark - Step

// N++ recordedMacroStep::isMacroable() special-cases these: their lParam is a C string (mtUseSParameter).
static BOOL NPPMacroMessageTakesString(int message) {
	switch (message) {
		case SCI_REPLACESEL: case SCI_ADDTEXT: case SCI_INSERTTEXT: case SCI_APPENDTEXT:
		case SCI_SEARCHNEXT: case SCI_SEARCHPREV: case SCI_SETTEXT:
			return YES;
		default:
			return NO;
	}
}

@interface NPPMacroStep (NPPPersistence)
- (NSDictionary *)npp_plist;
+ (nullable NPPMacroStep *)npp_stepFromPlist:(id)obj;
@end

@implementation NPPMacroStep

- (instancetype)initWithMessage:(int)message wParam:(uptr_t)w lParam:(sptr_t)l text:(NSString *)text {
	if ((self = [super init])) {
		_message = message; _wParam = w; _lParam = l; _text = [text copy];
	}
	return self;
}

- (void)playOnEditor:(ScintillaView *)editor {
	if (!editor) return;
	if (NPPMacroMessageTakesString(_message)) {
		// N++ refuses a string message recorded without its string (isMacroable() -> false).
		if (!_text) return;
		NPPSciStr(editor, (unsigned int)_message, _wParam, _text.UTF8String);
	} else {
		NPPSci(editor, (unsigned int)_message, _wParam, _lParam);
	}
}

- (NSDictionary *)npp_plist {
	NSMutableDictionary *d = [@{@"m": @(_message), @"w": @((long long)_wParam), @"l": @((long long)_lParam)} mutableCopy];
	if (_text) d[@"t"] = _text;
	return d;
}

+ (nullable NPPMacroStep *)npp_stepFromPlist:(id)obj {
	if (![obj isKindOfClass:NSDictionary.class]) return nil;
	NSDictionary *d = obj;
	NSNumber *m = d[@"m"];
	if (![m isKindOfClass:NSNumber.class]) return nil;
	id t = d[@"t"];
	return [[NPPMacroStep alloc] initWithMessage:m.intValue
										  wParam:(uptr_t)[d[@"w"] longLongValue]
										  lParam:(sptr_t)[d[@"l"] longLongValue]
											text:[t isKindOfClass:NSString.class] ? t : nil];
}

@end

#pragma mark - Delegate forwarder

@class NPPMacroManager;

@interface NPPMacroRecordForwarder : NSObject <NPPScintillaForwarder>
@property (nonatomic, weak) id<ScintillaNotificationProtocol> previousDelegate;
@property (nonatomic, weak) ScintillaView *view;
@property (nonatomic, weak) NPPMacroManager *owner;
- (void)uninstall;
@end

@interface NPPMacroManager (Forwarding)
- (void)recordedNotification:(SCNotification *)n;
@end

@implementation NPPMacroRecordForwarder

- (void)notification:(SCNotification *)n {
	if (n && n->nmhdr.code == SCN_MACRORECORD) [self.owner recordedNotification:n];
	[self.previousDelegate notification:n];   // forward unchanged
}

- (void)uninstall {
	ScintillaView *v = self.view;
	NPPRemoveScintillaForwarder(v, self);   // splices out of the middle of the chain too
	self.view = nil;
	self.previousDelegate = nil;
}

- (void)dealloc { [self uninstall]; }

@end

#pragma mark - Manager

@interface NPPMacroManager () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation NPPMacroManager {
	NSMutableArray<NPPMacroStep *> *_macro;             // "current recorded macro"
	NSMutableArray<NSDictionary *> *_saved;             // {@"name": NSString, @"steps": [plist]}
	NPPMacroRecordForwarder *_forwarder;
	ScintillaView *__weak _recordingEditor;
	BOOL _recording;
	BOOL _recordingSaved;                                // N++ _recordingSaved: disables "Save Current" once saved
}

+ (instancetype)shared {
	static NPPMacroManager *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[NPPMacroManager alloc] init]; });
	return s;
}

- (instancetype)init {
	if ((self = [super init])) {
		_macro = [NSMutableArray array];
		_saved = [NSMutableArray array];
		NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:kSavedMacrosDefaultsKey];
		for (id item in stored) {
			if (![item isKindOfClass:NSDictionary.class]) continue;
			NSString *name = ((NSDictionary *)item)[@"name"];
			NSArray *steps = ((NSDictionary *)item)[@"steps"];
			if ([name isKindOfClass:NSString.class] && name.length && [steps isKindOfClass:NSArray.class])
				[_saved addObject:@{@"name": name, @"steps": steps}];
			if (_saved.count >= kMaxSavedMacros) break;
		}
	}
	return self;
}

- (void)dealloc { [_forwarder uninstall]; }

#pragma mark State

- (BOOL)isRecording { return _recording; }
- (BOOL)hasRecordedMacro { return _macro.count > 0; }

- (NSArray<NSString *> *)savedMacroNames {
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:_saved.count];
	for (NSDictionary *d in _saved) [names addObject:d[@"name"]];
	return names;
}

- (NSArray<NPPMacroStep *> *)stepsOfSavedMacroAtIndex:(NSInteger)i {
	if (i < 0 || i >= (NSInteger)_saved.count) return nil;
	NSMutableArray *steps = [NSMutableArray array];
	for (id o in (NSArray *)_saved[(NSUInteger)i][@"steps"]) {
		NPPMacroStep *s = [NPPMacroStep npp_stepFromPlist:o];
		if (s) [steps addObject:s];
	}
	return steps;
}

- (void)persist {
	NSMutableArray *out = [NSMutableArray arrayWithCapacity:_saved.count];
	for (NSDictionary *d in _saved) [out addObject:d];
	[NSUserDefaults.standardUserDefaults setObject:out forKey:kSavedMacrosDefaultsKey];
}

#pragma mark Recording

- (void)recordedNotification:(SCNotification *)n {
	if (!_recording || !n) return;
	int message = n->message;
	NSString *text = nil;
	if (NPPMacroMessageTakesString(message) && n->lParam)
		text = [NSString stringWithUTF8String:(const char *)n->lParam];

	// N++ NppNotification.cpp: a SCI_REPLACESEL of a single "\n"/"\r" is normalised to SCI_NEWLINE so playback
	// inserts the document's own EOL; a CR step immediately followed by LF (CRLF documents) collapses into one.
	if (message == SCI_REPLACESEL && text.length == 1 &&
		([text isEqualToString:@"\n"] || [text isEqualToString:@"\r"])) {
		// Only a CRLF buffer emits ReplaceSel("\r") then ReplaceSel("\n") for one Enter; in an LF buffer each
		// Enter is a single ReplaceSel("\n") and collapsing would swallow consecutive newlines.
		if ([text isEqualToString:@"\n"] && _macro.lastObject.message == SCI_NEWLINE &&
			NPPSci(_recordingEditor, SCI_GETEOLMODE) == SC_EOL_CRLF) [_macro removeLastObject];
		[_macro addObject:[[NPPMacroStep alloc] initWithMessage:SCI_NEWLINE wParam:0 lParam:0 text:nil]];
		return;
	}
	[_macro addObject:[[NPPMacroStep alloc] initWithMessage:message wParam:n->wParam lParam:n->lParam text:text]];
}

- (void)startRecordingOnEditor:(ScintillaView *)ed {
	if (!ed || _recording) return;
	[_macro removeAllObjects];
	_recordingSaved = NO;
	_forwarder = [[NPPMacroRecordForwarder alloc] init];
	_forwarder.owner = self;
	_forwarder.view = ed;
	_forwarder.previousDelegate = ed.delegate;
	ed.delegate = _forwarder;
	_recordingEditor = ed;
	_recording = YES;
	NPPSci(ed, SCI_STARTRECORD);
}

- (void)stopRecording {
	if (!_recording) return;
	ScintillaView *ed = _recordingEditor;
	if (ed) NPPSci(ed, SCI_STOPRECORD);
	[_forwarder uninstall];
	_forwarder = nil;
	_recordingEditor = nil;
	_recording = NO;
}

// The current document can change under us (tab switch) while recording. We have no document-change callback
// (this module is not an NPPPanel), so we re-check whenever a Macro command is validated or run and move the
// recorder to the new editor. ponytail: a tab switch with the Macro menu never opened keeps recording the old
// view until the next macro command; a real fix needs a document-change hook in NPPDocument/the controller.
- (void)syncRecordingWithContext:(id<NPPCommandContext>)context {
	if (!_recording) return;
	ScintillaView *ed = [context contextCurrentDocument].editor;
	if (!ed || ed == _recordingEditor) return;
	ScintillaView *old = _recordingEditor;
	if (old) NPPSci(old, SCI_STOPRECORD);
	[_forwarder uninstall];
	_forwarder = [[NPPMacroRecordForwarder alloc] init];
	_forwarder.owner = self;
	_forwarder.view = ed;
	_forwarder.previousDelegate = ed.delegate;
	ed.delegate = _forwarder;
	_recordingEditor = ed;
	NPPSci(ed, SCI_STARTRECORD);
}

#pragma mark Playback

- (BOOL)playMacroSteps:(NSArray<NPPMacroStep *> *)steps onEditor:(ScintillaView *)ed
	untilEndOfFileFromEditor:(BOOL)untilEOF times:(NSInteger)n {
	if (!ed || steps.count == 0) return NO;
	if (n < 1) n = 1;

	NPPSci(ed, SCI_BEGINUNDOACTION);   // one playback run == one undo step, like N++
	if (!untilEOF) {
		for (NSInteger i = 0; i < n; ++i)
			for (NPPMacroStep *s in steps) [s playOnEditor:ed];
	} else {
		// N++ NppBigSwitch.cpp "run until the end of file": stop as soon as the caret line stops moving
		// monotonically or the document runs out. The counter cap is our own safety net.
		sptr_t lastLine = NPPSci(ed, SCI_GETLINECOUNT) - 1;
		sptr_t currLine = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(ed, SCI_GETCURRENTPOS));
		sptr_t deltaLastLine = 0, deltaCurrLine = 0;
		BOOL cursorMovedUp = NO;
		NSInteger counter = 0;
		const NSInteger kSafetyCap = 1000000;   // ponytail: hard stop so a pathological macro cannot hang the UI
		for (;;) {
			for (NPPMacroStep *s in steps) [s playOnEditor:ed];
			if (++counter >= kSafetyCap) break;
			if (counter > 2 && cursorMovedUp != (deltaCurrLine < 0) && deltaLastLine >= 0) break;
			cursorMovedUp = deltaCurrLine < 0;
			deltaLastLine = NPPSci(ed, SCI_GETLINECOUNT) - 1 - lastLine;
			deltaCurrLine = NPPSci(ed, SCI_LINEFROMPOSITION, (uptr_t)NPPSci(ed, SCI_GETCURRENTPOS)) - currLine;
			if (deltaCurrLine == 0 && deltaLastLine >= 0) break;
			if (deltaLastLine < deltaCurrLine) lastLine += deltaLastLine;
			currLine += deltaCurrLine;
			if (currLine > lastLine || currLine < 0 ||
				(deltaCurrLine == 0 && currLine == 0 && (deltaLastLine >= 0 || cursorMovedUp))) break;
		}
	}
	NPPSci(ed, SCI_ENDUNDOACTION);
	return YES;
}

- (BOOL)playSavedMacroAtIndex:(NSInteger)i onEditor:(ScintillaView *)ed times:(NSInteger)n {
	NSArray<NPPMacroStep *> *steps = [self stepsOfSavedMacroAtIndex:i];
	return [self playMacroSteps:steps onEditor:ed untilEndOfFileFromEditor:NO times:n];
}

- (BOOL)playCurrentMacroOnEditor:(ScintillaView *)ed times:(NSInteger)n {
	return [self playMacroSteps:[_macro copy] onEditor:ed untilEndOfFileFromEditor:NO times:n];
}

#pragma mark Sheets

// "Save Current Recorded Macro": name sheet, rejecting empty and duplicate names (N++ MacroShortcut dialog).
- (void)runSaveCurrentSheetOnWindow:(NSWindow *)window context:(id<NPPCommandContext>)context error:(NSString *)error {
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = NSLocalizedString(@"Save Current Recorded Macro", nil);
	alert.informativeText = error ?: NSLocalizedString(@"Name this macro. It is added to the Macro menu.", nil);
	[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
	NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
	field.placeholderString = NSLocalizedString(@"Macro name", nil);
	alert.accessoryView = field;
	alert.window.initialFirstResponder = field;

	__weak __typeof__(self) weakSelf = self;
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		__typeof__(self) self_ = weakSelf;
		if (!self_ || response != NSAlertFirstButtonReturn) return;
		NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		NSString *problem = nil;
		if (name.length == 0) problem = NSLocalizedString(@"The macro name cannot be empty.", nil);
		else if ([[self_ savedMacroNames] containsObject:name]) problem = NSLocalizedString(@"A macro with this name already exists.", nil);
		else if (self_->_saved.count >= kMaxSavedMacros) problem = NSLocalizedString(@"The macro list is full.", nil);
		if (problem) {
			// Re-present rather than losing the recording.
			dispatch_async(dispatch_get_main_queue(), ^{ [self_ runSaveCurrentSheetOnWindow:window context:context error:problem]; });
			return;
		}
		NSMutableArray *steps = [NSMutableArray arrayWithCapacity:self_->_macro.count];
		for (NPPMacroStep *s in self_->_macro) [steps addObject:[s npp_plist]];
		[self_->_saved addObject:@{@"name": name, @"steps": steps}];
		[self_ persist];
		self_->_recordingSaved = YES;
		[context contextRefreshUI];
		[context contextReportStatus:[NSString stringWithFormat:NSLocalizedString(@"Macro \"%@\" saved", nil), name] isError:NO];
	}];
}

// "Run a Macro Multiple Times" (N++ RunMacroDlg).
- (void)runMultipleSheetOnWindow:(NSWindow *)window context:(id<NPPCommandContext>)context {
	BOOL hasCurrent = _macro.count > 0 && !_recording;
	NSMutableArray<NSString *> *titles = [NSMutableArray array];
	if (hasCurrent) [titles addObject:NSLocalizedString(@"Current recorded macro", nil)];
	[titles addObjectsFromArray:self.savedMacroNames];
	if (titles.count == 0) return;

	NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 104)];
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 76, 300, 25) pullsDown:NO];
	[popup addItemsWithTitles:titles];
	NSButton *multi = [NSButton radioButtonWithTitle:NSLocalizedString(@"Run", nil) target:nil action:nil];
	multi.frame = NSMakeRect(0, 44, 60, 20);
	NSTextField *times = [[NSTextField alloc] initWithFrame:NSMakeRect(62, 42, 60, 22)];
	times.stringValue = @"1";
	NSTextField *label = [NSTextField labelWithString:NSLocalizedString(@"times", nil)];
	label.frame = NSMakeRect(128, 45, 100, 17);
	NSButton *eof = [NSButton radioButtonWithTitle:NSLocalizedString(@"Run until the end of file", nil) target:nil action:nil];
	eof.frame = NSMakeRect(0, 14, 300, 20);
	multi.state = NSControlStateValueOn;
	// One radio group: same target/action makes AppKit deselect the sibling.
	multi.target = eof.target = self;
	multi.action = eof.action = @selector(npp_runModeChanged:);
	multi.tag = 1; eof.tag = 2;
	for (NSView *v in @[popup, multi, times, label, eof]) [box addSubview:v];

	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = NSLocalizedString(@"Run a Macro Multiple Times", nil);
	alert.informativeText = NSLocalizedString(@"Macro to run:", nil);
	alert.accessoryView = box;
	[alert addButtonWithTitle:NSLocalizedString(@"Run", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

	__weak __typeof__(self) weakSelf = self;
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		__typeof__(self) self_ = weakSelf;
		if (!self_ || response != NSAlertFirstButtonReturn) return;
		ScintillaView *ed = [context contextCurrentDocument].editor;
		if (!ed) return;
		NSInteger idx = popup.indexOfSelectedItem;
		NSArray<NPPMacroStep *> *steps = (hasCurrent && idx == 0)
			? [self_->_macro copy]
			: [self_ stepsOfSavedMacroAtIndex:hasCurrent ? idx - 1 : idx];
		BOOL untilEOF = eof.state == NSControlStateValueOn;
		NSInteger n = MAX(1, (NSInteger)times.integerValue);
		if (![self_ playMacroSteps:steps onEditor:ed untilEndOfFileFromEditor:untilEOF times:n])
			[context contextReportStatus:NSLocalizedString(@"The macro is empty", nil) isError:YES];
		[context contextRefreshUI];
	}];
}

- (void)npp_runModeChanged:(NSButton *)sender {
	for (NSView *v in sender.superview.subviews) {
		if (v != sender && v.tag != 0 && [v isKindOfClass:NSButton.class])
			((NSButton *)v).state = NSControlStateValueOff;                       // the other radio
		if ([v isKindOfClass:NSTextField.class] && [(NSTextField *)v isEditable])
			((NSTextField *)v).enabled = (sender.tag == 1);                       // times field follows "Run n times"
	}
	sender.state = NSControlStateValueOn;
}

// "Modify Shortcut / Delete Macro" — rename and delete only.
// ponytail: assigning key equivalents to saved macros is out of scope (it needs the app's accelerator table,
// which lives in the window controller / app delegate, files this module may not touch).
- (void)runModifySheetOnWindow:(NSWindow *)window context:(id<NPPCommandContext>)context {
	if (_saved.count == 0) return;
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 320, 160)];
	NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
	NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
	col.title = NSLocalizedString(@"Macro", nil);
	col.width = 300;
	[table addTableColumn:col];
	table.dataSource = self;
	table.delegate = self;
	table.headerView = nil;
	table.allowsEmptySelection = NO;
	scroll.documentView = table;
	scroll.hasVerticalScroller = YES;
	scroll.borderType = NSBezelBorder;
	[table reloadData];
	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = NSLocalizedString(@"Modify or Delete Macro", nil);
	alert.informativeText = NSLocalizedString(@"Select a macro to rename or delete.", nil);
	alert.accessoryView = scroll;
	[alert addButtonWithTitle:NSLocalizedString(@"Rename…", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Close", nil)];

	__weak __typeof__(self) weakSelf = self;
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		__typeof__(self) self_ = weakSelf;
		if (!self_) return;
		NSInteger row = table.selectedRow;
		if (row < 0 || row >= (NSInteger)self_->_saved.count) return;
		if (response == NSAlertFirstButtonReturn) {
			dispatch_async(dispatch_get_main_queue(), ^{ [self_ runRenameSheetOnWindow:window context:context index:row error:nil]; });
		} else if (response == NSAlertSecondButtonReturn) {
			dispatch_async(dispatch_get_main_queue(), ^{ [self_ confirmDeleteOnWindow:window context:context index:row]; });
		}
	}];
}

- (void)confirmDeleteOnWindow:(NSWindow *)window context:(id<NPPCommandContext>)context index:(NSInteger)index {
	if (index < 0 || index >= (NSInteger)_saved.count) return;
	NSString *name = _saved[(NSUInteger)index][@"name"];
	NSAlert *alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"Delete the macro \"%@\"?", nil), name];
	alert.informativeText = NSLocalizedString(@"This cannot be undone.", nil);
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
	__weak __typeof__(self) weakSelf = self;
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		__typeof__(self) self_ = weakSelf;
		if (!self_ || response != NSAlertFirstButtonReturn) return;
		if (index < (NSInteger)self_->_saved.count) {
			[self_->_saved removeObjectAtIndex:(NSUInteger)index];
			[self_ persist];
			[context contextRefreshUI];
		}
		if (self_->_saved.count)
			dispatch_async(dispatch_get_main_queue(), ^{ [self_ runModifySheetOnWindow:window context:context]; });
	}];
}

- (void)runRenameSheetOnWindow:(NSWindow *)window context:(id<NPPCommandContext>)context index:(NSInteger)index error:(NSString *)error {
	if (index < 0 || index >= (NSInteger)_saved.count) return;
	NSString *old = _saved[(NSUInteger)index][@"name"];
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = NSLocalizedString(@"Rename Macro", nil);
	alert.informativeText = error ?: NSLocalizedString(@"Enter a new name for this macro.", nil);
	[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
	NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
	field.stringValue = old;
	alert.accessoryView = field;
	alert.window.initialFirstResponder = field;

	__weak __typeof__(self) weakSelf = self;
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		__typeof__(self) self_ = weakSelf;
		if (!self_ || response != NSAlertFirstButtonReturn) return;
		NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		NSString *problem = nil;
		if (name.length == 0) problem = NSLocalizedString(@"The macro name cannot be empty.", nil);
		else if (![name isEqualToString:old] && [[self_ savedMacroNames] containsObject:name])
			problem = NSLocalizedString(@"A macro with this name already exists.", nil);
		if (problem) {
			dispatch_async(dispatch_get_main_queue(), ^{ [self_ runRenameSheetOnWindow:window context:context index:index error:problem]; });
			return;
		}
		if (index < (NSInteger)self_->_saved.count) {
			NSMutableDictionary *d = [self_->_saved[(NSUInteger)index] mutableCopy];
			d[@"name"] = name;
			self_->_saved[(NSUInteger)index] = d;
			[self_ persist];
			[context contextRefreshUI];
		}
		dispatch_async(dispatch_get_main_queue(), ^{ [self_ runModifySheetOnWindow:window context:context]; });
	}];
}

#pragma mark NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_saved.count; }

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	if (row < 0 || row >= (NSInteger)_saved.count) return @"";
	NSString *name = _saved[(NSUInteger)row][@"name"];
	NSArray *steps = _saved[(NSUInteger)row][@"steps"];
	return [NSString stringWithFormat:@"%@  (%lu)", name, (unsigned long)steps.count];
}

#pragma mark - NPPCommandHandler

+ (BOOL)handlesCommand:(NPPCmd)cmd {
	switch (cmd) {
		case NPPCmdMacroStartRecording: case NPPCmdMacroStopRecording: case NPPCmdMacroPlayback:
		case NPPCmdMacroSaveCurrent: case NPPCmdMacroRunMultiple: case NPPCmdMacroModifyShortcuts:
			return YES;
		default:
			return cmd >= NPPCmdMacroSavedBase && cmd < NPPCmdMacroSavedBase + kMaxSavedMacros;
	}
}

+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
	NPPMacroManager *m = [self shared];
	[m syncRecordingWithContext:context];
	BOOL hasDoc = [context contextCurrentDocument].editor != nil;
	switch (cmd) {
		case NPPCmdMacroStartRecording:   return hasDoc && !m.isRecording;
		case NPPCmdMacroStopRecording:    return m.isRecording;
		case NPPCmdMacroPlayback:         return hasDoc && !m.isRecording && m.hasRecordedMacro;
		case NPPCmdMacroSaveCurrent:      return !m.isRecording && m.hasRecordedMacro && !m->_recordingSaved;
		case NPPCmdMacroRunMultiple:      return hasDoc && !m.isRecording && (m.hasRecordedMacro || m->_saved.count > 0);
		case NPPCmdMacroModifyShortcuts:  return m->_saved.count > 0;
		default:
			if (![self handlesCommand:cmd]) return NO;
			return hasDoc && !m.isRecording && (NSInteger)(cmd - NPPCmdMacroSavedBase) < (NSInteger)m->_saved.count;
	}
}

+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
	if (![self handlesCommand:cmd]) return NO;
	NPPMacroManager *m = [self shared];
	[m syncRecordingWithContext:context];
	if (![self canPerformCommand:cmd context:context]) return NO;

	ScintillaView *ed = [context contextCurrentDocument].editor;
	NSWindow *window = [context contextWindow];

	switch (cmd) {
		case NPPCmdMacroStartRecording:
			[m startRecordingOnEditor:ed];
			[context contextReportStatus:NSLocalizedString(@"Recording macro…", nil) isError:NO];
			break;
		case NPPCmdMacroStopRecording:
			[m stopRecording];
			[context contextReportStatus:[NSString stringWithFormat:NSLocalizedString(@"Macro recorded (%lu steps)", nil),
										 (unsigned long)m->_macro.count] isError:NO];
			break;
		case NPPCmdMacroPlayback:
			[m playCurrentMacroOnEditor:ed times:1];
			break;
		case NPPCmdMacroSaveCurrent:
			if (window) [m runSaveCurrentSheetOnWindow:window context:context error:nil];
			break;
		case NPPCmdMacroRunMultiple:
			if (window) [m runMultipleSheetOnWindow:window context:context];
			break;
		case NPPCmdMacroModifyShortcuts:
			if (window) [m runModifySheetOnWindow:window context:context];
			break;
		default:
			[m playSavedMacroAtIndex:(NSInteger)(cmd - NPPCmdMacroSavedBase) onEditor:ed times:1];
			break;
	}
	[context contextRefreshUI];
	return YES;
}

+ (NSString *)dynamicTitleForCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context {
	if (cmd < NPPCmdMacroSavedBase || cmd >= NPPCmdMacroSavedBase + kMaxSavedMacros) return nil;
	NSArray<NSString *> *names = [self shared].savedMacroNames;
	NSInteger i = (NSInteger)(cmd - NPPCmdMacroSavedBase);
	return i < (NSInteger)names.count ? names[(NSUInteger)i] : nil;
}

@end
