#!/bin/sh
# Headless PDF-layout probe: launch a throwaway Bluefold instance on a given
# PDF in a given display mode, capture the app's layout/viewmode
# instrumentation, and print it — so real PDFKit numbers can be checked
# against on-paper math without clicking through the UI.
#
#   probe-layout.sh <pdf-path> [displayModeRaw] [pageIndex] [seconds]
#
#   displayModeRaw: 0 single-page  1 single-continuous  2 two-up  3 two-up-continuous
#   pageIndex:      0-based page to restore on (default 0)
#   seconds:        how long to let the app run (default 8)
#
# Output: the captured unified-log lines (subsystem com.cable729.bluefold,
# categories layout/viewmode) between launch and quit. LOGS_STYLE=ndjson for
# machine parsing.
#
# How it works: fresh BLUEFOLD_SESSION_DIR → first launch with --open writes a
# valid session.json → quit → session.json is edited (displayModeRaw,
# pageIndex, autoScales=false when a mode is forced) → relaunch WITHOUT --open
# restores the edited state through the exact same code path the toolbar
# buttons use. The owner's real session is untouched.
#
# Prereq: the app instrumentation rides at .debug — run `logs.sh mac setup`
# once, or this script's log capture comes back empty.
set -eu
cd "$(dirname "$0")/.."

PDF="${1:?usage: probe-layout.sh <pdf-path> [displayModeRaw] [pageIndex] [seconds]}"
MODE="${2:-}"
PAGE="${3:-}"
SECS="${4:-8}"
APP=".build/DerivedData/Build/Products/Debug/Bluefold.app"
BIN="$APP/Contents/MacOS/Bluefold"

[ -d "$APP" ] || {
    echo "error: $APP not built. Run:" >&2
    echo "  xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold -configuration Debug -derivedDataPath .build/DerivedData -quiet build" >&2
    exit 1
}

SESS="$(mktemp -d)"
trap 'launchctl unsetenv BLUEFOLD_SESSION_DIR 2>/dev/null || true' EXIT

launch() {
    launchctl setenv BLUEFOLD_SESSION_DIR "$SESS"
    open -n "$APP" ${1:+--args --open "$1"}
    sleep "$SECS"
    launchctl unsetenv BLUEFOLD_SESSION_DIR
}

quit_app() {
    osascript -e 'tell application "Bluefold" to quit' >/dev/null 2>&1 || true
    sleep 2
    pkill -f "$BIN" 2>/dev/null || true
    sleep 1
}

# Pass 1 — generate a valid session.json for this PDF.
launch "$PDF"
quit_app
[ -f "$SESS/session.json" ] || { echo "error: no session.json written to $SESS" >&2; exit 1; }

# Edit the restored state (same fields the app persists; autoScales off so a
# forced mode is applied verbatim, not re-fit by restore).
if [ -n "$MODE$PAGE" ]; then
    MODE="$MODE" PAGE="$PAGE" SESS="$SESS" python3 - <<'PY'
import json, os
path = os.path.join(os.environ["SESS"], "session.json")
with open(path) as f:
    session = json.load(f)

def patch(tab):
    if os.environ.get("MODE"):
        tab["displayModeRaw"] = int(os.environ["MODE"])
    if os.environ.get("PAGE"):
        tab["pageIndex"] = int(os.environ["PAGE"])
        for entry in ("currentNavEntry", "navEntry"):
            if isinstance(tab.get(entry), dict):
                tab[entry]["pageIndex"] = int(os.environ["PAGE"])

def walk(node):
    if isinstance(node, dict):
        if "displayModeRaw" in node:
            patch(node)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)

walk(session)
with open(path, "w") as f:
    json.dump(session, f)
print("patched", path)
PY
fi

# Pass 2 — restore the edited session and capture the instrumentation.
START="$(date '+%Y-%m-%d %H:%M:%S')"
launch ""
quit_app

log show --start "$START" --info --debug --style "${LOGS_STYLE:-compact}" \
    --predicate 'subsystem == "com.cable729.bluefold" && (category == "layout" || category == "viewmode")'
