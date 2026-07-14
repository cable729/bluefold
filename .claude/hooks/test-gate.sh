#!/bin/bash
# Stop hook: a turn that changed Swift code may not end with failing tests.
#
# Scope: runs `swift test --filter <Module>Tests` for each module with
# uncommitted Swift changes (Sources/<Module>/ or Tests/<Module>Tests/).
# Turns that touched no Swift code (docs, scripts, conversation) pass through
# untouched. Exit 2 + stderr feeds the failure back to Claude and blocks the
# turn from ending.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 0

INPUT=$(cat)
# Never loop: if this hook already blocked once and Claude is stopping again
# after addressing (or failing to address) it, let the harness decide.
if echo "$INPUT" | jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
    exit 0
fi

CHANGED=$( (git diff --name-only HEAD -- 'Sources/**/*.swift' 'Tests/**/*.swift'; \
            git ls-files --others --exclude-standard -- 'Sources/**/*.swift' 'Tests/**/*.swift') | sort -u)
[ -n "$CHANGED" ] || exit 0

MODULES=$(echo "$CHANGED" | sed -nE 's#^Sources/([^/]+)/.*#\1#p; s#^Tests/([^/]+)Tests/.*#\1#p' | sort -u)
[ -n "$MODULES" ] || exit 0

FAILED=""
for module in $MODULES; do
    # Modules without a test target (executables) are skipped.
    [ -d "Tests/${module}Tests" ] || continue
    if ! OUTPUT=$(swift test --filter "${module}Tests" 2>&1); then
        FAILED="$FAILED $module"
        echo "=== ${module}Tests FAILED ===" >&2
        echo "$OUTPUT" | tail -30 >&2
    fi
done

if [ -n "$FAILED" ]; then
    echo "" >&2
    echo "Tests are red for:$FAILED. Fix them before ending the turn (docs/TESTING.md)." >&2
    exit 2
fi
exit 0
