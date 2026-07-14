# View-mode spec index

This is an INDEX, not the spec. **The tests are the spec**: each ID below
lives in a swift-testing test name (`M-1` → `func m1_…`), and the test body's
GIVEN/WHEN/THEN comment carries the full behavioral statement.
`scripts/check-spec-ids.sh` (run in CI) fails if this index and the tests
drift in either direction. Items marked `(PENDING)` are speced but not yet
implemented — each has a `ready` GitHub issue; remove the marker when the
test lands.

Shared definitions: **M** = `ReaderLayout.margin`, one fixed on-screen margin
(view points) used everywhere. **Pan rule**: no artificial pan lock — at a
mode's standard fit the content exactly fills the viewport width, so there is
no horizontal slack; zooming in past the fit gives normal panning. **Modes**:
single/double × fixed/continuous (PDFDisplayMode raw 0–3).

## Margin (uniform M)

- M-1 two-page continuous: vertical row gap == horizontal page gap == M
- M-2 two-page fixed: gap between the two pages == M
- M-3 fixed modes (1- and 2-page): margin above and below page == M
- M-4 fit width: left/right margins == M; fit height: top/bottom == M

## Mode buttons (entry behavior)

- VM-1 single fixed: page centered, M all around, same page as before
- VM-2 single continuous: zoom from current page (viewportW = pageW·s + 2M), centered, y-scroll unchanged
- VM-3 double fixed: spread centered, M around and between, same page kept, even/odd placement
- VM-4 double continuous: M between pages both axes, even/odd placement, y-scroll unchanged

## Mode switches

- SW-1 single→double→single (and inverse) returns the viewport to the same place after two switches
- SW-2 double→single: page's on-screen width = the spread's former on-screen width (2×page + M); lands on former top-left page
- SW-3 single→double: current page takes its even/odd slot top row; scroll to its top with margin M
- SW-4 single→double with viewport too wide for a full page: keep left page scrolled where the user was
- SW-5 mode switches reset non-standard zoom/pan to the target standard; pan/zoom never persisted per-mode

## Even/odd book layout

- VM-5 book pairing: `displaysAsBook` OFF pairs (0,1),(2,3)…; ON leaves page 0 alone (pairs 1,2 | 3,4 …); `displaysRTL` swaps the pair's left/right slots — the transitions anchor on the pair's top-left page
- VM-6 the PDF catalog `/PageLayout` is honored (read from CGPDF; not auto-applied by PDFKit): `TwoColumnRight`/`TwoPageRight` → `displaysAsBook`, others → default

## Fit buttons

- FIT-1 fit width: centered, M left/right, y-scroll unchanged
- FIT-2 fit height: no scroll; pageH·s + 2M == viewport height, centered

## Different-size pages

- SIZE-1 single fixed: every page centered both axes, margins ≥ M
- SIZE-2 single continuous: zoom from current page only; others keep it (overflow clips / smaller pages get bigger margins)
- SIZE-3 double fixed: pages align toward the middle (top-left page → bottom-right of its cell, etc.)
- SIZE-4 double continuous: same, vertically center-aligned (top-left page → right-center of cell)
- SIZE-5 double modes: pages full-size, small pages never over-zoomed

## Trim margins (a real crop, orthogonal to zoom)

- TRIM-1 single fixed: after trim, single-fixed standard again (M all around)
- TRIM-2 single continuous: same y-scroll; page keeps its viewport fraction
- TRIM-3 double fixed: TRIM-1 behavior for the spread
- TRIM-4 double continuous: TRIM-2 behavior
- TRIM-5 untrim reverses all four
- TRIM-6 mixed sizes: trim page-by-page; SIZE rules apply to cropped boxes
- TRIM-7 whole-doc detection cached once per page (measured ~1.4 ms/page); current page detected synchronously so trim appears at once

## Navigation

- NAV-1 single continuous arrows: page steps land like fixed mode (fit-height ⇒ equal top/bottom margins, else top margin M)
- NAV-2 double continuous arrows: one row per step, top margin M
