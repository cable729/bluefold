# PDFKit layout facts (probe-verified)

Ground truth for the view-mode work — measured, not assumed. Every fact below
is pinned by a probe in `Tests/ReaderUITests/PDFKitFactsTests.swift`; if a
macOS/PDFKit update changes the behavior, that probe fails and this doc must be
re-derived. **Do not re-learn these by guessing** (that is what burned the two
prior sessions). To re-measure: `swift test --filter PDFKitFacts` and read the
`PROBE …` lines.

Measured on macOS 26 (Tahoe), Xcode 26 / Swift 6.3, arm64, 2026-07-13.

## Coordinate model (background — assumed by every fact below)

- The internal scroll view is **magnified** by `scaleFactor`. The
  `documentView` coordinate space is **page points** and its frame does NOT
  change with `scaleFactor` (Fact 1 confirms). The viewport is `view.bounds`
  in **view points**. A box `w` page-points wide displays at `w · scaleFactor`.
- The `documentView` is **non-flipped**: content TOP = maximum y; `y = 0` is
  the bottom. Page index `i`'s content top (below its inset) sits at
  `docHeight − i·(pageH + top + bottom) − topInset`.
- Relayout is **asynchronous** — read geometry / reposition after the next
  runloop turn(s); a large `go(to:)` can need a second pass.

## Fact 1 — `pageBreakMargins` are page-space and per-page

`pageBreakMargins` (default top/bottom 4.75, left/right 4.0; needs
`displaysPageBreaks == true`) inset **each page**, in **page points** (the gap
grows with zoom). Verified: 3 pages 400×600 with symmetric inset 10 →
`documentView` frame **420 × 1860**, identical at scaleFactor 1 and 2.

- Column width = `pageW + left + right`.
- Continuous row pitch = `pageH + top + bottom` per page — i.e. the visible
  gap between two stacked pages = `bottom + top` (the two adjacent insets sum).
- Outer edges (view edge → first/last page) get a single inset.

**Consequence for uniform on-screen margin M:** insets are page-space, so a
constant *screen* gap requires `inset = (M / scaleFactor) / 2` recomputed
whenever the scale changes, OR accept that the gap scales with zoom. The
planner owns this conversion — `ReaderLayout.margin` is the screen target;
`pageBreakMargins` is derived from it and the current scale.

## Fact 2 — two-up horizontal geometry ≈ 2·pageW + 4·inset (sub-pixel spine loss)

Two-up row width ≈ `2·pageW + 4·inset`; inner gap between the pair ≈
`2·inset` (the two adjacent per-page insets sum). There is a **sub-pixel spine
loss (~0.5–1 pt) that depends on the display backing scale** — it is not a real
design quantity. Measured (pages 400 wide, scale 1):

| inset | docWidth (2×/1×) | inner gap (2×/1×) |
|------:|-----------------:|------------------:|
| 0 | 799 / 800 | −1.0 / −0.5 |
| 10 | 859 / 860 | 19.0 / 19.5 |
| 20 | 919 / 920 | 39.0 / 39.5 |

(2× = local Retina, 1× = the headless CI runner. The probe asserts the clean
formulas within ~1.5 pt so it holds on both.)

**Consequence:** for a uniform on-screen gap **M** between the two pages, use
left/right inset **`M / 2`** — the sub-pixel spine loss is backing-scale-
dependent and not worth compensating. Outer edges get one inset each; row
height = `pageH + 2·inset`. There is no separate inner-gutter vs outer-margin
control — only the four per-page insets — so "uniform gap everywhere" =
symmetric insets plus (if needed) an outer compensation computed into the
scroll target (see Fact 5 before reaching for `contentInsets`).

**Lesson pinned here too:** absolute documentView dimensions carry a
backing-scale-dependent sub-pixel term; the planner must reason in terms of the
robust quantities (gaps = sums of insets) and tolerate ≤1 pt on totals, never
hard-code a per-machine pixel value.

## Fact 3 — enlarged page boxes ARE honored (mixed-size alignment is viable)

`page.setBounds(_:for: .mediaBox/.cropBox)` with a box **larger** than the
content is honored: `bounds(for:)` reports the set rect verbatim, and the added
area renders as **blank padding** with the original content untouched.
Verified: a 400×600 page enlarged to `(-100, 0, 500, 600)` renders a fully
blank left strip (brightness 1.0) and intact content (brightness 0.0).

**Consequence:** the phase-6 alignment mechanism (issue #17) is GO — enlarge
each page's boxes so every two-up cell is uniform and asymmetric padding pushes
content toward the spine/center. PageBoxStore applies/reverts these overrides
in memory (never touches the file). Shrinking is already proven by the ported
`PageContentCrop`; this shows growing works too, so trim (crop) and alignment
(pad) share one mechanism.

## Fact 4 — `goToNextPage` (continuous) anchors the page top one inset down

In single-page-continuous, `goToNextPage` makes the next page current and
scrolls so its **top sits exactly one `top` inset below the viewport top**
(measured gap 10 pt with inset 10, scale 1). Narrow content is horizontally
centered via a **negative clip-origin x**.

**Consequence (NAV-1/NAV-2, issue #19):** PDFKit's own paging already lands the
"standard top margin M" position if `pageBreakMargins.top` encodes M — but for
fit-height's equal top/bottom margins the planner must compute the scroll
target itself rather than lean on `goToNextPage`. Two-up paging advances one
row; confirm the row-step target the same way when phase 8 lands.

## Fact 5 — `contentInsets` stick but `go(to:)` doesn't cleanly honor them

The internal `NSScrollView` accepts `contentInsets` (with
`automaticallyAdjustsContentInsets = false`), but PDFKit's `go(to:)`
destination math does not cleanly compensate: a page-top destination with a
24 pt top inset landed at clip-origin y 754 — 14 pt off the naive no-inset
target (740) and NOT the fully-compensated position (764). Skim subtracts
`contentInsets.top` manually for exactly this reason.

**Consequence:** do NOT use `contentInsets` for outer margins and expect clean
scrolling — compute scroll targets explicitly in the planner/applier. Prefer
symmetric `pageBreakMargins` (Facts 1–2) for gaps; handle the missing outer
half-margin by computing the scroll origin, not by leaning on `contentInsets`.

## Still to probe (when the relevant phase lands)

- Two-up row VERTICAL alignment of unequal-height pages (short page centered?
  top-aligned?) — needed for SIZE-4. Add a probe in phase 6.
- `displaysAsBook` / `displaysRTL` exact pairing and side across an odd first
  page, and whether `/PageLayout` from the catalog is ever auto-applied
  (expected: never) — add probes in phase 5.
- `layoutDocumentView()` centering timing for content narrower than the pane
  after an explicit scaleFactor — confirm the single deferred call suffices in
  each mode (phase 2/3).

## Sources (external, cross-checked against the probes)

Apple PDFView.h header (SDK mirror), Apple Developer Forums threads on
`autoScales` fit semantics / mixed widths / Tahoe safe-area centering, and the
Skim reader source (`scris/skim-pdf`: `PDFView_SKExtensions.m`,
`SKPDFView.m` rewind). Full URL list is in the session research brief; the
probes are the authority for anything that conflicts.
