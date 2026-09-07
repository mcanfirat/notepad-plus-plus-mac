// NPPColumnEditor.h — Notepad++ "Edit > Column Editor..." (N++ ColumnEditorDlg).
//
// A sheet on the host window with N++'s two modes ("Text to Insert" / "Number to Insert"); on OK the text or the
// generated number sequence is inserted at one column of every target line. Target lines are the lines of a
// rectangular selection, or — with no/stream selection — every line from the caret line to the end of the document
// (N++ behaviour). Short lines are padded with spaces up to the target column.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPPColumnEditor : NSObject <NPPCommandHandler>
// Handles NPPCmdEditColumnEditor. canPerformCommand: is NO without a document or when it is read-only.
// Settings persist in NSUserDefaults under NPPColumnEditor*.
@end

NS_ASSUME_NONNULL_END
