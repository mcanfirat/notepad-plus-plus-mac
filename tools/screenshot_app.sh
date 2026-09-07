#!/bin/bash
# Launch dist/Notepad++.app with the given files, wait, screenshot the main window to $OUT (default build/screenshot.png).
# Uses CGWindowList via a tiny Swift snippet to find the window id (no Accessibility permission needed).
set -e
cd "$(dirname "$0")/.."
OUT="${OUT:-build/screenshot.png}"
APP="dist/Notepad++.app"
pkill -x "Notepad++" 2>/dev/null || true
sleep 0.5
open -n "$APP" --args "$@"
sleep "${WAIT:-3}"
WID=$(swift - <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
    if let owner = w[kCGWindowOwnerName as String] as? String, owner == "Notepad++",
       let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
       let wid = w[kCGWindowNumber as String] as? Int,
       let bounds = w[kCGWindowBounds as String] as? [String: Any], (bounds["Height"] as? Double ?? 0) > 100 {
        print(wid); break
    }
}
SWIFT
)
if [ -z "$WID" ]; then echo "no Notepad++ window found"; exit 1; fi
osascript -e 'tell application "Notepad++" to activate' 2>/dev/null || true
sleep 0.5
screencapture -x -o -l "$WID" "$OUT"
echo "screenshot -> $OUT (window $WID)"
