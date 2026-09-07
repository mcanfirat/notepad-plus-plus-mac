// NPPPrintRenderer.h — syntax-coloured printing (N++ ScintillaComponent/Printer.cpp).
//
// Renders through Scintilla itself (SCI_FORMATRANGEFULL straight into the print CGContext), so the page
// looks like the editor: lexer colours, the current theme, optional line-number margin. A print-panel
// accessory mirrors N++'s print settings (colour mode, line numbers, header/footer with $(…) variables,
// magnification); they persist in NSUserDefaults under "NPPPrint…". The rest of N++'s Print page — form feed
// as a page break, the four millimetre margins, and independent header/footer fonts (family, size, bold,
// italic) — lives on Preferences ▸ Print and is read from the same keys.
//
// The editor is borrowed, not copied: every Scintilla setting touched (print colour mode, print
// magnification, line-number margin width) is restored when the operation ends.
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPPrintRenderer : NSObject <NPPCommandHandler>

// Prints the whole document. `name` is used as the print job title and to expand the header/footer
// variables: pass the document's full path when it has one (doc.fileURL.path), otherwise its display
// name — $(FILE_NAME) is derived from it with -lastPathComponent.
// `window` gets the print panel as a sheet; pass nil to run it application-modal.
+ (void)printEditor:(ScintillaView *)editor documentName:(NSString *)name window:(nullable NSWindow *)window;
// showPanel:NO is File ▸ Print Now — the same syntax-coloured path, straight to the default printer.
+ (void)printEditor:(ScintillaView *)editor documentName:(NSString *)name window:(nullable NSWindow *)window showPanel:(BOOL)showPanel;

// Prints the primary selection (falls back to the whole document when the selection is empty).
+ (void)printSelectionOfEditor:(ScintillaView *)editor documentName:(NSString *)name window:(nullable NSWindow *)window;

// <NPPCommandHandler>: NPPCmdFilePrint (whole document, or the selection when there is one — N++ offers
// "Selection" in its print dialog; here a non-empty selection simply wins).
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;

// Regression guards (NPPSelfTest's module-self-checks): margin/page-break/font arithmetic, plus editor-backed
// checks that every Print setting actually reaches Scintilla or the page instead of being read and dropped.
+ (NSArray<NSString *> *)selfCheckFailures;

@end

NS_ASSUME_NONNULL_END
