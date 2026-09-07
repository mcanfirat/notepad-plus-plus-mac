// NPPHashTools.h — Tools menu hash generators (N++ MISC/md5/md5Dlgs.cpp: HashFromTextDlg / HashFromFilesDlg).
//
// Three actions per algorithm, exactly like N++: a live "Generate…" sheet (type text, watch the digest, copy it),
// "Generate from files…" (open panel, one digest per chosen file) and "from selection into clipboard".
// Digests are lowercase hex of the UTF-8 bytes of the text / the raw bytes of the file, as N++ produces them.
#pragma once
#import <Cocoa/Cocoa.h>
#import "NPPFeatureProtocols.h"

NS_ASSUME_NONNULL_BEGIN

// Order matters: it is the algo index encoded in NPPCmdToolHashBase + algo * 3 + action, and the Tools menu order.
typedef NS_ENUM(NSInteger, NPPHashAlgorithm) {
    NPPHashMD5 = 0,
    NPPHashSHA1,
    NPPHashSHA256,
    NPPHashSHA512,
};

@interface NPPHashTools : NSObject <NPPCommandHandler>

+ (instancetype)shared;

// Digest helpers — pure, no UI, safe to call from any thread (the self-checks and the sheets share them).
+ (NSString *)hexDigestOfData:(NSData *)data algorithm:(NPPHashAlgorithm)algo;
+ (NSString *)hexDigestOfString:(NSString *)text algorithm:(NPPHashAlgorithm)algo;      // UTF-8 bytes of the text
+ (nullable NSString *)hexDigestOfFileURL:(NSURL *)url algorithm:(NPPHashAlgorithm)algo; // streamed; nil = unreadable
// One digest per URL in the same order; an unreadable file keeps its line as "(unreadable)".
+ (NSArray<NSString *> *)hexDigestsOfFileURLs:(NSArray<NSURL *> *)urls algorithm:(NPPHashAlgorithm)algo;
// N++'s "Treat each line as a separate string": one digest per line, blank lines stay blank, LF-joined.
+ (NSString *)hexDigestPerLineOfString:(NSString *)text algorithm:(NPPHashAlgorithm)algo;
+ (NSString *)displayNameForAlgorithm:(NPPHashAlgorithm)algo;                            // "MD5", "SHA-1", …

// Handles NPPCmdToolHashBase + algo * 3 + action for algo 0..3, action 0..2.
// canPerformCommand: is NO for the two dialogs without a host window, and NO for "from selection" without a
// non-empty selection in the current document.
+ (BOOL)handlesCommand:(NPPCmd)cmd;
+ (BOOL)canPerformCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (BOOL)performCommand:(NPPCmd)cmd context:(id<NPPCommandContext>)context;
+ (NSArray<NSString *> *)selfCheckFailures;

@end

NS_ASSUME_NONNULL_END
