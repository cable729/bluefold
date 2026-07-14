# Backlog → GitHub Issues

The backlog lives in [GitHub Issues](https://github.com/cable729/bluefold/issues)
(migrated 2026-07-13). This file is a pointer, not a list — do not add items
here.

- Work that's speced and ready: `gh issue list --label ready`
- Ideas awaiting a spec: `gh issue list --label needs-spec`
- Release scoping: milestones (`gh issue list --milestone "View modes v1"`)
- New idea? `gh issue create` with the **Spec** template (Context / Desired
  behavior / Acceptance criteria / Out of scope / How to verify), label
  `needs-spec` until the criteria are real.
- One issue = one PR = one reviewable diff; PR bodies say `Fixes #N`.
  Merge via `./scripts/merge-pr.sh <pr>` only.

The pre-migration backlog (including the shipped-milestone history) is
preserved in this file's git history: `git log --follow -p docs/BACKLOG.md`.
Milestone/quirk history lives on in [PROGRESS.md](PROGRESS.md).
