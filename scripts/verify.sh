#!/bin/sh
# The one-command verification gate.
#
# Run this before merging anything. It is deliberately the SAME entry point
# for humans, CI, and AI agents of any capability — if this passes, the
# build is sound on both platforms and the app actually launches.
#
# (Unit tests alone do not guarantee the app works — see docs/BACKLOG.md
# "Testing / CI" for the XCUITest smoke suite that extends this gate.)
set -eu
cd "$(dirname "$0")/.."

echo "== 1/4 swift test (unit + integration) =="
swift test

echo "== 2/4 macOS app build =="
xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold \
    -configuration Debug -derivedDataPath .build/DerivedData \
    -quiet build

echo "== 3/4 iOS app build (simulator) =="
xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold-iOS \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/DerivedData-iOS \
    -quiet build CODE_SIGNING_ALLOWED=NO

if [ -z "${CI:-}" ]; then
    echo "== 4/4 macOS launch smoke =="
    # Launch through LaunchServices (`open`), not direct exec, and assert a
    # real window: a pid-alive check alone can pass while the app comes up
    # windowless (seen on macOS 26 with direct-exec launches).
    SDIR=$(mktemp -d)
    APP_BUNDLE=.build/DerivedData/Build/Products/Debug/Bluefold.app
    launchctl setenv BLUEFOLD_SESSION_DIR "$SDIR"
    open -n "$APP_BUNDLE"
    sleep 6
    launchctl unsetenv BLUEFOLD_SESSION_DIR
    APP_PID=$(pgrep -n -f "$APP_BUNDLE/Contents/MacOS/Bluefold" || true)
    [ -n "$APP_PID" ] || { echo "FAIL: app not running after launch"; exit 1; }
    WINDOWS=$(APP_PID="$APP_PID" swift - <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1
let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
let count = wins.filter {
    ($0["kCGWindowOwnerPID"] as? Int) == pid && ($0["kCGWindowLayer"] as? Int) == 0
}.count
print(count)
SWIFT
)
    if [ "${WINDOWS:-0}" -lt 1 ]; then
        echo "FAIL: app is running but opened no window (pid $APP_PID)"
        kill "$APP_PID" 2>/dev/null || true
        exit 1
    fi
    # Quit gracefully: an unclean kill can make later launches of the same
    # bundle ID flaky (macOS 26 quirk).
    osascript -e 'tell application "Bluefold" to quit' >/dev/null 2>&1 || kill "$APP_PID"
    rm -rf "$SDIR"
else
    echo "== 4/4 launch smoke skipped on CI (XCUITest will cover this — M17) =="
fi

if [ -n "${VERIFY_UITESTS:-}" ]; then
    echo "== 5/5 macOS XCUITest smoke (VERIFY_UITESTS set) =="
    # The same suite CI job B runs. Opt-in because it drives real windows
    # for several minutes; full-suite local runs can be flaky — spot-check
    # single tests locally and leave full passes to CI. The timestamp gives
    # every run a fresh BLUEFOLD_BUNDLE_ID_SUFFIX, avoiding stale-bundle-ID
    # launch issues (macOS 26 quirk).
    xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold \
        -configuration Debug -derivedDataPath .build/DerivedData-UITest \
        test "BLUEFOLD_BUNDLE_ID_SUFFIX=.uitest$(date +%s)" 2>&1 | tail -30
fi

echo ""
echo "ALL VERIFY STEPS PASSED"
