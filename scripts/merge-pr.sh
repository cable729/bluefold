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
# Gate on our GitHub Actions jobs only. Advisory checks (codecov/*, which posts
# via the Checks API, so filtering by type is not enough — filter by name) can
# be red for reasons orthogonal to correctness (no coverage baseline yet, app
# not installed): they warn but never block. `gh pr checks --required` is NOT
# used — it exits non-zero when the repo has no branch protection, which is not
# a failure.
ADVISORY='codecov'   # extend as more advisory checks appear
CI_STATE="$(gh pr view "$PR" --json statusCheckRollup -q "
    [.statusCheckRollup[]
     | select(.__typename == \"CheckRun\")
     | select((.name // \"\") | test(\"$ADVISORY\"; \"i\") | not)
     | (.conclusion // \"PENDING\")] as \$c
    | if (\$c | length) == 0 then \"none\"
      elif (\$c | any(. != \"SUCCESS\" and . != \"NEUTRAL\" and . != \"SKIPPED\")) then \"notgreen\"
      else \"green\" end")"
case "$CI_STATE" in
    green) : ;;
    none)  echo "warning: no GitHub Actions jobs found for PR #$PR — relying on the local gate only." >&2 ;;
    *)     echo "error: CI (GitHub Actions) is not green for PR #$PR. Failing/pending jobs:" >&2
           gh pr checks "$PR" 2>/dev/null | grep -viE "$ADVISORY" | grep -iE 'fail|pending' >&2 || true
           exit 1 ;;
esac
# Surface any red advisory checks so skipping them is a conscious decision.
gh pr view "$PR" --json statusCheckRollup -q "
    .statusCheckRollup[]
    | select((.name // .context // \"\") | test(\"$ADVISORY\"; \"i\"))
    | select((.conclusion // .state // \"\") != \"SUCCESS\")
    | \"  advisory (not blocking): \(.name // .context) = \(.conclusion // .state)\"" 2>/dev/null || true

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
# --delete-branch is avoided: in a git worktree it makes gh switch the current
# worktree to the base branch, which fails when the base (main) is checked out
# in another worktree. Merge on the server, confirm MERGED, then delete the
# remote branch directly.
gh pr merge "$PR" "$STRATEGY"
if [ "$(gh pr view "$PR" --json state -q .state)" = "MERGED" ]; then
    HEAD_REF="$(gh pr view "$PR" --json headRefName -q .headRefName)"
    if gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$HEAD_REF" >/dev/null 2>&1; then
        echo "merged; deleted remote branch $HEAD_REF"
    else
        echo "merged; leave remote branch $HEAD_REF for manual cleanup"
    fi
else
    echo "error: PR #$PR did not reach MERGED state — check manually." >&2
    exit 1
fi
