// NPPFunctionListPanel.h — Notepad++ "Function List" (View > Function List).
// Port of PowerEditor/src/WinControls/FunctionList/{functionParser,functionListPanel}.cpp.
//
// The parser (NPPFunctionListParser) is a pure Foundation object: it takes the document text as an
// NSString and returns entries; the panel (NPPFunctionListPanel) owns the docked outline view and the
// NPPCmdViewFunctionList toggle.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// One hit: a function (leaf) optionally attached to a class/namespace (node).
@interface NPPFunctionListEntry : NSObject
@property (nonatomic, copy) NSString *name;                  // display name (N++ foundInfo::_data)
@property (nonatomic, copy, nullable) NSString *className;   // owning class/namespace or nil (foundInfo::_data2)
@property (nonatomic) NSInteger position;                    // UTF-16 index into the parsed string
@property (nonatomic) NSInteger bytePosition;                // UTF-8 byte offset (Scintilla position); -1 until resolved
@end

// One functionList/<lang>.xml rule set. Regexes are ICU (NSRegularExpression); N++ uses Boost PCRE, so a
// handful of rules (recursion "(?R)", subroutine calls "(?1)") do not compile — +parserWithContentsOfURL:
// then returns nil with an error instead of throwing.
@interface NPPFunctionListParser : NSObject
+ (nullable instancetype)parserWithContentsOfURL:(NSURL *)url error:(NSError **)error;
@property (nonatomic, readonly, copy) NSString *displayName;   // <parser displayName>
@property (nonatomic, readonly, copy) NSString *parserID;      // <parser id>
// Blanks out commentExpr matches, then runs the class/function expressions. `cancelled` (may be nil) is polled
// between matches; when it returns YES parsing stops and whatever was found so far is returned.
- (NSArray<NPPFunctionListEntry *> *)parseText:(NSString *)text cancelled:(BOOL (^ _Nullable)(void))cancelled;
@end

@interface NPPFunctionListPanel : NSObject <NPPPanel, NPPCommandHandler>
+ (instancetype)shared;

// The window controller sets this implicitly through +performCommand:context:; kept weak.
@property (nonatomic, weak, nullable) id<NPPCommandContext> context;

- (void)reload;   // force a re-parse of the current document (also the action menu's "Reload")

// Directory holding the *.xml parser rules: <bundle>/Contents/Resources/functionList, falling back to the
// Notepad++ source tree when running from build/.
+ (nullable NSURL *)functionListDirectoryURL;

// Self-check helper: loads every rule file and reports "<file>: ok (<displayName>)" or "<file>: SKIPPED <reason>".
+ (NSArray<NSString *> *)diagnoseAllParsers;
@end

NS_ASSUME_NONNULL_END
