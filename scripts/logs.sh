#!/bin/sh
# Read Bluefold's unified-log instrumentation — the "launch once, read the
# logs after" workflow (no relaunch, no debugger).
#
#   logs.sh [mac|sim] [setup|show|stream] [minutes] [category]
#
#   setup   one-time: persist .debug/.info for our subsystem so `show` can
#           read them AFTER a run (macOS needs sudo; simulator does not).
#           Without setup, .debug is memory-only — run `stream` DURING the
#           run instead, or you lose the messages.
#   show    dump the last N minutes (default 5). Set LOGS_STYLE=ndjson for
#           machine-parseable output.
#   stream  follow live (Ctrl-C to stop).
#
# Categories: layout viewmode trim nav session (see AppLogger.Category).
set -eu

SUBSYSTEM="com.cable729.bluefold"
PLATFORM="${1:-mac}"
MODE="${2:-show}"
MINUTES="${3:-5}"
CATEGORY="${4:-}"
STYLE="${LOGS_STYLE:-compact}"

PREDICATE="subsystem == \"$SUBSYSTEM\""
if [ -n "$CATEGORY" ]; then
    PREDICATE="$PREDICATE && category == \"$CATEGORY\""
fi

case "$PLATFORM" in
    mac) LOG="log"; SUDO="sudo" ;;
    sim) LOG="xcrun simctl spawn booted log"; SUDO="" ;;
    *) echo "usage: logs.sh [mac|sim] [setup|show|stream] [minutes] [category]" >&2; exit 2 ;;
esac

case "$MODE" in
    setup)
        # Persist .debug/.info to disk for this subsystem (survives reboots;
        # undo with: log config --subsystem $SUBSYSTEM --reset).
        $SUDO $LOG config --mode "level:debug,persist:debug" --subsystem "$SUBSYSTEM"
        echo "OK: .debug/.info now persisted for $SUBSYSTEM ($PLATFORM)."
        ;;
    show)
        $LOG show --last "${MINUTES}m" --info --debug \
            --style "$STYLE" --predicate "$PREDICATE"
        ;;
    stream)
        $LOG stream --level debug --style "$STYLE" --predicate "$PREDICATE"
        ;;
    *)
        echo "usage: logs.sh [mac|sim] [setup|show|stream] [minutes] [category]" >&2
        exit 2
        ;;
esac
