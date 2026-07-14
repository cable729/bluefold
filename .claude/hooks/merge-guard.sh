#!/bin/bash
# PreToolUse(Bash) hook: PRs merge only through scripts/merge-pr.sh, which
# runs the CI-blind local test class (windowed launch smoke, real-display
# XCUITests) before merging. A bare `gh pr merge` skips that gate — block it.
set -u

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# merge-pr.sh is the sanctioned path (it calls gh pr merge internally).
case "$COMMAND" in
    *scripts/merge-pr.sh*) exit 0 ;;
esac

# Block only when `gh pr merge` is an actual command verb — i.e. at the start
# of the command or right after a shell separator (&&, ||, ;, |, newline).
# Matching this way avoids false positives when the string merely appears
# inside a heredoc/quoted argument (e.g. a PR body that mentions the command).
if printf '%s' "$COMMAND" | grep -Eq '(^|[;&|]|&&|\|\|)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge\b'; then
    echo "Blocked: merge PRs with ./scripts/merge-pr.sh <pr-number> — it runs the local-only test gate (windowed smoke + XCUITests) that CI cannot, then merges." >&2
    exit 2
fi
exit 0
