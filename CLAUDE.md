# Bluefold — agent guide

macOS + iOS PDF reader. All logic lives in the root SwiftPM package; the app
targets are thin shells. Read [CONTRIBUTING.md](CONTRIBUTING.md) once — it has
the dev setup, code conventions, and the design constraints that must not be
violated (Calibre stays read-only; the pbxproj is hand-authored — never let
Xcode regenerate it).

## Commands

```sh
swift test                                  # unit tests (most work needs only this)
./scripts/verify.sh                         # the merge gate: tests + both app builds + launch smoke
./scripts/logs.sh mac setup                 # once per machine: persist .debug logs for our subsystem
./scripts/logs.sh mac show 5 layout         # read app logs AFTER a run (no relaunch needed)
./scripts/probe-layout.sh <pdf> <mode>      # headless launch + geometry log dump
./scripts/merge-pr.sh <pr-number>           # THE ONLY way to merge a PR (runs local-only tests first)
```

Build the macOS app (from the worktree you are editing — building the main
checkout silently runs stale code):

```sh
xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold \
    -configuration Debug -derivedDataPath .build/DerivedData -quiet build
```

## The four disciplines (each has teeth — hooks enforce 1 and 2)

1. **TDD for geometry/layout/algorithmic code.** A failing test that encodes
   the expected numbers comes FIRST; only then the implementation. The Probity
   hook blocks production-code writes in the layout/geometry paths until it has
   seen a failing test. Never tune constants against the running app.
2. **Tests must pass to finish.** A Stop hook runs the affected module's tests
   when you try to end a turn; red tests block you.
3. **Search first, don't guess.** On any mysterious bug or framework quirk
   (PDFKit especially), use the systematic-debugging skill and WebSearch the
   symptom verbatim + framework name (Apple Developer Forums, Stack Overflow,
   OpenRadar) BEFORE writing a fix. After 2 failed fix attempts you MUST stop
   and search with new terms. PDFKit facts already verified live are in
   [docs/PDFKIT-FACTS.md](docs/PDFKIT-FACTS.md) — check there first.
4. **Instrument, don't rebuild-relaunch.** The app logs through `AppLogger`
   (subsystem `com.cable729.bluefold`, categories: layout, viewmode, trim, nav,
   session) at .debug/.info. Those levels are NOT persisted by default — run
   `./scripts/logs.sh mac setup` once (or keep `logs.sh mac stream` running)
   BEFORE launching the app, then read logs after the run with
   `logs.sh mac show`. Add instrumentation freely; verify fixes from logged
   numbers, not from "it looks right". (If `logs.sh mac show` is empty right
   after a real launch, your shell may be sandboxed away from the unified log
   — run it from an unsandboxed terminal, or use `logs.sh mac stream`.) See
   the bluefold-pdfkit skill for the full workflow, including reproducing any
   view state headlessly by editing session.json.

## Testing policy (summary — full policy in docs/TESTING.md)

Real implementation → fake → stub → mock, in that order of preference. Inject
dependencies (swift-dependencies; the TestClock in AutosaveObserverTests is the
house pattern). Fakes only at non-hermetic boundaries (clock, filesystem, PDF
rendering); every fake gets contract tests against the live implementation.
Assert state, not call counts. Tests never touch real user data
(`AppStores.isTestProcess` fences the app's stores — keep it that way).

## Specs

Behavioral requirements carry IDs (M-1, VM-2, SW-3, …). The test IS the spec:
the ID lives in the test name, the GIVEN/WHEN/THEN in the test body.
[docs/specs/view-modes.md](docs/specs/view-modes.md) is only an index;
`scripts/check-spec-ids.sh` fails CI if index and tests drift.

## Backlog

GitHub Issues is the backlog (`gh issue list --label ready` for work that's
speced). One issue = one PR = one reviewable diff; PR bodies say `Fixes #N`.
File new ideas as issues with `needs-spec`; don't grow markdown TODO lists.

## Sessions & launching

It is OK to launch the app against the real user session (session persistence
is solid now). For a clean, reproducible state (probes, tests) set
`BLUEFOLD_SESSION_DIR` to a temp dir via `launchctl setenv` — `open` does not
pass plain env vars. Use open-license demo books (Active Calculus, Judson,
OpenStax, Alice) for anything shared or screenshotted.

## Known platform pathologies (read before touching these areas)

- PDFKit navigation/destination quirks: "PDFKit destination pathologies" in
  [docs/PROGRESS.md](docs/PROGRESS.md); verified geometry facts in
  [docs/PDFKIT-FACTS.md](docs/PDFKIT-FACTS.md).
- macOS 26: SwiftUI resets window appearance; overlay-provider timing; PDFView
  autoScales ignores safe-area insets. Details in docs/PROGRESS.md.
- Only on-screen tabs hold `PDFView`s (memory model) — see CONTRIBUTING.md.
