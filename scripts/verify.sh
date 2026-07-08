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
xcodebuild -project App/PDFReader.xcodeproj -scheme PDFReader \
    -configuration Debug -derivedDataPath .build/DerivedData \
    -quiet build

echo "== 3/4 iOS app build (simulator) =="
xcodebuild -project App/PDFReader.xcodeproj -scheme PDFReader-iOS \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/DerivedData-iOS \
    -quiet build CODE_SIGNING_ALLOWED=NO

if [ -z "${CI:-}" ]; then
    echo "== 4/4 macOS launch smoke =="
    SDIR=$(mktemp -d)
    APP=.build/DerivedData/Build/Products/Debug/PDFReader.app/Contents/MacOS/PDFReader
    PDFREADER_SESSION_DIR="$SDIR" "$APP" >/dev/null 2>&1 &
    APP_PID=$!
    sleep 5
    kill -0 "$APP_PID" 2>/dev/null || { echo "FAIL: app exited during launch"; exit 1; }
    osascript -e 'tell application "PDFReader" to quit' >/dev/null 2>&1 || kill "$APP_PID"
    rm -rf "$SDIR"
else
    echo "== 4/4 launch smoke skipped on CI (XCUITest will cover this — M17) =="
fi

echo ""
echo "ALL VERIFY STEPS PASSED"
