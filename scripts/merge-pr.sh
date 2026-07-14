#!/bin/sh
# The ONLY sanctioned way to merge a PR. CI covers what GitHub runners can
# run; this gate runs the CI-blind class locally (windowed launch smoke,
# opt-in XCUITests needing a real display) on the PR's actual code, then
# merges. A Claude Code PreToolUse hook rejects bare `gh pr merge` and points
# here.
#
#   merge-pr.sh <pr-number> [--squash|--merge|--rebase] [--fast]
#
#   --fast   skip the XCUITest pass (verify.sh only). Default runs both.
set -eu
cd "$(dirname "$0")/.."

PR="${1:?usage: merge-pr.sh <pr-number> [--squash|--merge|--rebase] [--fast]}"
shift
STRATEGY="--squash"
FAST=""
for arg in "$@"; do
    case "$arg" in
        --squash|--merge|--rebase) STRATEGY="$arg" ;;
        --fast) FAST=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree dirty — stash or commit before merging a PR." >&2
    exit 1
fi

echo "== merge gate for PR #$PR =="
gh pr view "$PR" --json title,headRefName,statusCheckRollup \
    -q '"\(.title) [\(.headRefName)]"'

# CI must already be green — the local gate supplements, never replaces it.
if ! gh pr checks "$PR" --required 2>/dev/null; then
    echo "error: required CI checks are not green for PR #$PR." >&2
    exit 1
fi

ORIGINAL_REF="$(git rev-parse --abbrev-ref HEAD)"
restore() { git checkout -q "$ORIGINAL_REF" 2>/dev/null || true; }
trap restore EXIT

gh pr checkout "$PR"

if [ -n "$FAST" ]; then
    echo "== local gate: verify.sh (tests + builds + windowed launch smoke) =="
    ./scripts/verify.sh
else
    echo "== local gate: verify.sh + XCUITest suite (real display) =="
    VERIFY_UITESTS=1 ./scripts/verify.sh
fi

restore
trap - EXIT

echo "== all local gates green — merging =="
gh pr merge "$PR" "$STRATEGY" --delete-branch
