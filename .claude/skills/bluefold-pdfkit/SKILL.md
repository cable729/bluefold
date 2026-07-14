---
name: bluefold-pdfkit
description: >
  Bluefold PDFKit layout/zoom/scroll expert. ALWAYS invoke this skill when
  working on fit, trim, margins, two-up, display modes, scroll position, zoom,
  page geometry, or any PDFView behavior in Bluefold — and any time a layout
  change is about to be verified by "launching and looking". Do not guess at
  PDFKit behavior or rebuild-relaunch in a loop — use this skill's
  instrument-and-read-logs workflow first.
---

# Debugging and verifying PDFKit layout in Bluefold

PDFKit's coordinate and relayout behavior is subtle, under-documented, and
version-specific. Every past regression in this area came from guessing. The
loop that works: **instrument → launch once → read the log → check the math on
paper → change one thing.**

## The workflow

1. **Instrument.** Log through the injected `AppLogger`
   (`@Dependency(\.appLogger) var log`; categories: layout, viewmode, trim,
   nav, session). Print real inputs AND computed outputs — viewport size, page
   box, computed scale, scroll origin. One log line replaces three guesses.
2. **Arm log persistence once per machine** (instrumentation rides at .debug,
   which is NOT persisted by default):
   ```sh
   ./scripts/logs.sh mac setup        # sudo; sim variant needs no sudo
   ```
   Alternative: keep `./scripts/logs.sh mac stream` running during the repro.
3. **Build the worktree you edited** (building another checkout runs stale
   code — this has burned whole sessions):
   ```sh
   xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold \
       -configuration Debug -derivedDataPath .build/DerivedData -quiet build
   ```
4. **Launch once, drive it, read the logs after:**
   ```sh
   open -n .build/DerivedData/Build/Products/Debug/Bluefold.app
   # …interact (or let the restore path run)…
   ./scripts/logs.sh mac show 5 layout
   ```
   Launching against the real user session is fine (session persistence is
   solid). For a clean reproducible state use `scripts/probe-layout.sh`.
5. **Verify numbers, not pixels.** Write the expected value
   (e.g. `scale = viewportW / (pageW + 2·margin)`) and compare with the logged
   one. A fix is done when logged == predicted, and a failing-first test pins it.

## Reproduce any view state headlessly

```sh
./scripts/probe-layout.sh <pdf> <displayModeRaw> [pageIndex]
# displayModeRaw: 0 single  1 single-continuous  2 two-up  3 two-up-continuous
```

It generates a session, edits `displayModeRaw`/`pageIndex` in session.json,
relaunches without `--open` (restore runs the SAME apply path the toolbar
buttons use), and prints the captured geometry log. Use open-license books
(Active Calculus, Judson, OpenStax, Alice) for anything shared.

## Verified PDFKit facts (do not re-learn these by guessing)

Full, evolving list with logged numbers: [docs/PDFKIT-FACTS.md](../../../docs/PDFKIT-FACTS.md).
The load-bearing ones:

- `PDFView`'s internal scroll view is **magnified** by `scaleFactor`: the
  documentView coordinate space is **page points** (its frame does not change
  with zoom); the viewport is `view.bounds` in **view points**; the scroll
  offset (clip bounds origin) is in page points and therefore
  scale-independent. Never use `clip.bounds.width` as the viewport — that is
  `viewport / scale` (this exact mistake halved the zoom once).
- The documentView is **non-flipped**: content TOP = **maximum** scroll
  offset; `origin.y = 0` is the bottom. "Anchor the page top" = scroll to max.
- **Relayout settles asynchronously** — after setting `scaleFactor`,
  `autoScales`, or `displayMode`, geometry reads and repositioning must be
  deferred (`DispatchQueue.main.async`), and a large `go(to:)` can need a
  second deferred pass. Mode changes lose scroll position; wrap them in
  capture(page, point) → restore after relayout → re-check ~0.25s later
  (Skim's battle-tested "rewind" pattern).
- `autoScales` ≠ fit-width: it is fit-width only in continuous modes, best-fit
  in fixed modes, and in mixed-size docs it fits the **widest page in the
  document**. `scaleFactorForSizeToFit` has the same semantics. Compute fits
  explicitly from the current page's `bounds(for: displayBox)`.
- `currentDestination` lies in fixed modes (returns page top-left, not the
  visible area) — compute position from the clip view.
- Content smaller than the pane centers only in PDFView's own layout pass —
  force it with `view.layoutDocumentView()` after a fit. An `NSClipView`
  `constrainBoundsRect` override does NOT work (magnification ignores it).
- macOS 26: `autoScales` centering ignores safe-area insets (DTS-confirmed) —
  constrain the PDFView to `safeAreaLayoutGuide`.

## Where the code lives

| File | Role |
|---|---|
| `Sources/ReaderUI/ActivePDFView.swift` | Coordinator applying modes/fits to the live PDFView |
| `Sources/ReaderUI/Layout/` | Pure layout planner + margin/fit math (spec-ID tested) |
| `Sources/ReaderCore/AppLogger.swift` | The injectable instrumentation channel |
| `docs/PDFKIT-FACTS.md` | Probe-verified PDFKit behavior with logged numbers |
| `docs/specs/view-modes.md` | Spec-ID index (tests are the spec) |
