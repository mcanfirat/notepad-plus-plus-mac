// NPPUtils.h — tiny shared helpers (no state).
#pragma once
#import <Cocoa/Cocoa.h>
#import <Scintilla/ScintillaView.h>
#include <string>

NS_ASSUME_NONNULL_BEGIN

// Notepad++ stores colors in XML as "RRGGBB"; Scintilla wants 0x00BBGGRR. -1 = not set.
long NPPColorFromHex(NSString *rrggbb);              // "804000" -> 0x004080 (BGR)
NSColor *NPPNSColorFromSci(long sciColor);           // BGR long -> NSColor (sRGB)
long NPPSciColorFromNSColor(NSColor *color);

// A ScintillaView has exactly one delegate, so a feature that wants to see notifications inserts a *forwarder*
// that remembers the previous delegate and passes everything on. Two of them can be installed at once (the macro
// recorder and auto-completion), so removing one must splice it out of the middle of the chain, not just off the
// top — otherwise uninstalling the outer one drops the document's own delegate and the editor stops responding.
@protocol NPPScintillaForwarder <ScintillaNotificationProtocol>
@property (nonatomic, weak, nullable) id<ScintillaNotificationProtocol> previousDelegate;
@end
void NPPRemoveScintillaForwarder(ScintillaView *_Nullable view, id<NPPScintillaForwarder> forwarder);

// The Notepad++ checkout this port builds against. Everything it needs at runtime is bundled into Resources, so
// this is only the development fallback for running the binary straight out of build/: $NPP if set, else the
// sibling clone the Makefile defaults to (../notepad-plus-plus, relative to the executable). Returns nil when
// there is no checkout, which every caller must handle — a shipped app never has one.
NSString *_Nullable NPPUpstreamPath(NSString *subpath);

// Scintilla message helpers (avoid casting noise everywhere).
static inline sptr_t NPPSci(ScintillaView *ed, unsigned int msg, uptr_t w = 0, sptr_t l = 0) {
    return [ed message:msg wParam:w lParam:l];
}
static inline sptr_t NPPSciStr(ScintillaView *ed, unsigned int msg, uptr_t w, const char *s) {
    return [ed message:msg wParam:w lParam:(sptr_t)s];
}
// Fetch the whole document (UTF-8 bytes) / a range as std::string.
std::string NPPSciGetText(ScintillaView *ed);
std::string NPPSciGetRange(ScintillaView *ed, sptr_t start, sptr_t end);
NSString *NPPSciSelectedString(ScintillaView *ed);   // primary selection, UTF-8 decoded
NSString *NPPSciWordAtCaret(ScintillaView *ed);      // word under caret (SCI_WORDSTARTPOSITION/END), may be empty

// Display helpers
NSString *NPPFormatGroupedInteger(long long n);      // 1234567 -> "1,234,567"
BOOL NPPFontIsAvailable(NSString *fontName);
NSString *NPPDefaultMonospaceFontName(void);         // "Menlo"

NS_ASSUME_NONNULL_END
