import CoreGraphics

/// The output of the planner: the concrete PDFView settings that realize a
/// mode's *standard fit* with uniform on-screen margins. PURE data — no PDFKit
/// view instances are touched to compute it (see `ViewModePlanner`).
///
/// Later phases will grow this (scroll target, `displaysAsBook`, per-page box
/// overrides); the fields here are the phase-2 minimum.
public struct LayoutPlan: Equatable, Sendable {
    /// `PDFDisplayMode` raw value (== `ViewMode.displayModeRaw`).
    public var displayMode: Int
    /// Symmetric per-side `pageBreakMargins` inset, in PAGE POINTS. On screen a
    /// between-page gap renders as `2 · inset · scaleFactor` (the two adjacent
    /// per-page insets sum — docs/PDFKIT-FACTS.md Fact 1/2).
    public var pageBreakMarginInset: CGFloat
    /// The explicit `scaleFactor` to set (with `autoScales = false`).
    public var scaleFactor: CGFloat

    public init(displayMode: Int, pageBreakMarginInset: CGFloat, scaleFactor: CGFloat) {
        self.displayMode = displayMode
        self.pageBreakMarginInset = pageBreakMarginInset
        self.scaleFactor = scaleFactor
    }
}

/// Where a `ModeTransition` parks the reading position after the switch. The
/// applier resolves this into a concrete clip origin from live documentView
/// geometry (docs/PDFKIT-FACTS.md: non-flipped documentView, page-point scroll
/// offset) — the pure planner only names the intent.
public enum ScrollAnchor: Equatable, Sendable {
    /// Scroll so `pageIndex`'s top edge sits exactly `ReaderLayout.margin` below
    /// the viewport top. In a fixed mode where the page fits, PDFKit's own
    /// centering wins (there is no scroll slack), so this reads as "centered".
    case pageTopMargin(pageIndex: Int)
    /// Keep the current clip-origin y — the reading position must not jump
    /// (VM-2/VM-4 continuous entry, SW-4 too-wide single→double).
    case preserveY
}

/// The decision a mode switch resolves to: the destination PDFView settings PLUS
/// where to land the reading position. PURE data (like `LayoutPlan`) — computed
/// with no live view, so the transition math is unit-testable to the number.
///
/// `pageBreakMarginInset` renders the between-page gap as `ReaderLayout.margin`
/// at `scaleFactor` (see `ViewModePlanner.marginInset`); `targetPageIndex` is
/// the page PDFKit should make current; `scrollAnchor` is the post-relayout
/// scroll intent the applier realizes with the rewind pattern.
public struct ModeTransition: Equatable, Sendable {
    /// `PDFDisplayMode` raw value (== destination `ViewMode.displayModeRaw`).
    public var displayMode: Int
    /// The explicit `scaleFactor` to set (with `autoScales = false`).
    public var scaleFactor: CGFloat
    /// Symmetric per-side `pageBreakMargins` inset, in PAGE POINTS.
    public var pageBreakMarginInset: CGFloat
    /// The page to land on (fixed mode makes it current; continuous scrolls to
    /// its row) — the pair's top-left index for cross-family switches.
    public var targetPageIndex: Int
    /// Where to park the reading position after relayout.
    public var scrollAnchor: ScrollAnchor
    /// The destination's even/odd pairing, so the applier can set
    /// `displaysAsBook` / `displaysRTL` when entering a two-up mode.
    public var bookLayout: BookLayout

    public init(
        displayMode: Int, scaleFactor: CGFloat, pageBreakMarginInset: CGFloat,
        targetPageIndex: Int, scrollAnchor: ScrollAnchor,
        bookLayout: BookLayout = .default
    ) {
        self.displayMode = displayMode
        self.scaleFactor = scaleFactor
        self.pageBreakMarginInset = pageBreakMarginInset
        self.targetPageIndex = targetPageIndex
        self.scrollAnchor = scrollAnchor
        self.bookLayout = bookLayout
    }
}

/// Pure margin/fit arithmetic for the four view modes. No PDFKit — every value
/// is derived from `ReaderLayout.margin` (the one on-screen margin) and the
/// viewport/page geometry, so the math is unit-testable without a live view.
///
/// Key identity (docs/PDFKIT-FACTS.md): `pageBreakMargins` insets live in PAGE
/// POINTS, and the on-screen gap between two adjacent pages is the SUM of the
/// two adjacent insets times the scale = `2 · inset · scale`. To render a
/// target on-screen gap `M`, use a per-side inset of `M / (2 · scale)`.
public enum ViewModePlanner {
    /// Page-space per-side inset that renders as `onScreenGap` at `scale`:
    /// `onScreenGap / (2 · scale)` (so `2 · inset · scale == onScreenGap`).
    /// Guards `scale > 0` — a non-positive scale yields `0` (no gap) rather
    /// than a divide-by-zero or negative inset.
    public static func marginInset(onScreenGap: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 0 }
        return onScreenGap / (2 * scale)
    }

    /// Scale that fills the viewport width leaving exactly `margin` on the left
    /// and right: `(viewportWidth - 2·margin) / pageWidth`.
    public static func widthFitScale(
        viewportWidth: CGFloat, pageWidth: CGFloat, margin: CGFloat
    ) -> CGFloat {
        guard pageWidth > 0 else { return 1 }
        return (viewportWidth - 2 * margin) / pageWidth
    }

    /// Scale that fills the viewport height leaving exactly `margin` on the top
    /// and bottom: `(viewportHeight - 2·margin) / pageHeight`.
    public static func heightFitScale(
        viewportHeight: CGFloat, pageHeight: CGFloat, margin: CGFloat
    ) -> CGFloat {
        guard pageHeight > 0 else { return 1 }
        return (viewportHeight - 2 * margin) / pageHeight
    }

    /// Scale that fits a two-up SPREAD across the viewport width: two pages,
    /// two outer margins, and one inner gutter — all `margin` on screen — so
    /// `(viewportWidth - 3·margin) / (2·pageWidth)`.
    public static func twoUpWidthFitScale(
        viewportWidth: CGFloat, pageWidth: CGFloat, margin: CGFloat
    ) -> CGFloat {
        guard pageWidth > 0 else { return 1 }
        return (viewportWidth - 3 * margin) / (2 * pageWidth)
    }

    /// Single-fixed fit: `min(widthFit, heightFit)` so the whole page shows
    /// with at least `margin` all around (the constraining axis lands exactly
    /// at `margin`, the other gets more).
    public static func fixedFitScale(
        viewport: CGSize, pageSize: CGSize, margin: CGFloat
    ) -> CGFloat {
        min(
            widthFitScale(viewportWidth: viewport.width, pageWidth: pageSize.width, margin: margin),
            heightFitScale(viewportHeight: viewport.height, pageHeight: pageSize.height, margin: margin)
        )
    }

    /// Double-fixed fit: `min(twoUpWidthFit, heightFit)` so the whole spread
    /// shows with at least `margin` all around and between.
    public static func twoUpFixedFitScale(
        viewport: CGSize, pageSize: CGSize, margin: CGFloat
    ) -> CGFloat {
        min(
            twoUpWidthFitScale(viewportWidth: viewport.width, pageWidth: pageSize.width, margin: margin),
            heightFitScale(viewportHeight: viewport.height, pageHeight: pageSize.height, margin: margin)
        )
    }

    /// The standard-fit plan for `mode` at this viewport/page size. The scale
    /// is the mode's documented fit; the inset is whatever renders the
    /// between-page gap as `ReaderLayout.margin` at that scale.
    public static func standardPlan(
        mode: ViewMode, viewport: CGSize, pageSize: CGSize
    ) -> LayoutPlan {
        let margin = ReaderLayout.margin
        let scale: CGFloat
        switch mode {
        case .singleFixed:
            scale = fixedFitScale(viewport: viewport, pageSize: pageSize, margin: margin)
        case .singleContinuous:
            scale = widthFitScale(
                viewportWidth: viewport.width, pageWidth: pageSize.width, margin: margin)
        case .doubleFixed:
            scale = twoUpFixedFitScale(viewport: viewport, pageSize: pageSize, margin: margin)
        case .doubleContinuous:
            scale = twoUpWidthFitScale(
                viewportWidth: viewport.width, pageWidth: pageSize.width, margin: margin)
        }
        return LayoutPlan(
            displayMode: mode.displayModeRaw,
            pageBreakMarginInset: marginInset(onScreenGap: margin, scale: scale),
            scaleFactor: scale
        )
    }

    /// The spread that contains `index`, as its (left, right) page indices under
    /// `layout` (docs/PDFKIT-FACTS.md §3, the Skim rule "index i starts a pair
    /// when (i % 2 == 1) == displaysAsBook"). Either slot may be `nil`:
    /// `displaysAsBook` leaves page 0 alone (one slot empty), and the returned
    /// `right` for the last pair of an odd-length document is the CALLER's to
    /// null out — this pure math has no page count. `rtl` swaps the slots.
    ///
    /// - `displaysAsBook == false`: pairs (0,1),(2,3)… — `start = (i/2)·2`,
    ///   left = start, right = start+1.
    /// - `displaysAsBook == true`: index 0 is a lone page on the RIGHT
    ///   (left = nil, right = 0); for i ≥ 1, `start = ((i-1)/2)·2 + 1`,
    ///   left = start, right = start+1.
    static func pair(containing index: Int, layout: BookLayout) -> (left: Int?, right: Int?) {
        let i = max(0, index)
        // Slots in LTR reading order first, then swap for RTL.
        var leftContent: Int?
        var rightContent: Int?
        if layout.displaysAsBook {
            if i == 0 {
                leftContent = nil                 // lone recto sits on the right
                rightContent = 0
            } else {
                let start = ((i - 1) / 2) * 2 + 1
                leftContent = start
                rightContent = start + 1
            }
        } else {
            let start = (i / 2) * 2
            leftContent = start
            rightContent = start + 1
        }
        if layout.rtl { swap(&leftContent, &rightContent) }
        return (left: leftContent, right: rightContent)
    }

    /// The spread ANCHOR index the transitions land on: the top-left slot's
    /// page, or the lone page when the left slot is empty (book index 0). Under
    /// `.default` this equals the old `(i/2)·2` rule so phase-4 behavior holds.
    static func spreadLeftIndex(of index: Int, layout: BookLayout) -> Int {
        let p = pair(containing: index, layout: layout)
        return p.left ?? p.right ?? max(0, index)
    }

    /// Maps a PDF catalog `/PageLayout` name to a `BookLayout`. The "…Right"
    /// variants (`TwoColumnRight` / `TwoPageRight`) place 1-based odd pages on
    /// the right — i.e. page index 0 stands alone — so they mean
    /// `displaysAsBook = true`. Every other value (and a missing key) → the
    /// default. `/PageLayout` carries no reading direction, so no RTL is
    /// inferred here.
    static func bookLayout(pageLayoutName name: String?) -> BookLayout {
        switch name {
        case "TwoColumnRight", "TwoPageRight":
            return BookLayout(displaysAsBook: true, rtl: false)
        default:
            return .default
        }
    }

    /// The decision table for a mode-button press or mode switch (VM-1..4,
    /// SW-1..5). PURE: the destination scale/anchor are derived only from the
    /// standard-fit rules and the geometry — a non-standard LIVE zoom must NOT
    /// leak through (SW-5), so `currentScale` is intentionally NOT read; it is
    /// accepted only for call-site symmetry with the live view's state.
    ///
    /// Three branches:
    /// - **same single/double family** (fixed↔continuous flip): the
    ///   destination's `standardPlan` scale, the SAME page; continuous
    ///   destinations preserve y (VM-2/VM-4), fixed destinations anchor the
    ///   page top at M (VM-1/VM-3, centered when it fits).
    /// - **double→single** (SW-2): `newScale = 2·oldScale + M/pageW`, where
    ///   `oldScale` is the FROM mode's two-up STANDARD fit (not the live zoom),
    ///   so the single page's on-screen width equals the spread's former width.
    ///   Lands on the pair's top-left index, top anchored at M.
    /// - **single→double** (SW-3/SW-4): the destination two-up standard fit,
    ///   land on the pair's top-left index; anchor the row top at M UNLESS the
    ///   viewport is too wide to show a full page height (`pageH·scale >
    ///   viewportH`), in which case keep y (SW-4).
    public static func transition(
        from: ViewMode, to: ViewMode,
        currentPageIndex: Int, currentScale: CGFloat,
        viewport: CGSize, pageSize: CGSize,
        layout: BookLayout = .default
    ) -> ModeTransition {
        _ = currentScale                       // SW-5: live zoom must not leak.
        let margin = ReaderLayout.margin
        let pageW = pageSize.width
        let pageH = pageSize.height

        let scale: CGFloat
        let targetPageIndex: Int
        let anchor: ScrollAnchor

        switch (from.isTwoUp, to.isTwoUp) {
        case (false, true):
            // single → double (SW-3 / SW-4). The current page takes its book
            // pair's top-left slot (VM-5) — the pair anchor, not (i/2)·2.
            scale = standardPlan(mode: to, viewport: viewport, pageSize: pageSize)
                .scaleFactor
            targetPageIndex = spreadLeftIndex(of: currentPageIndex, layout: layout)
            // Too wide to show a full page height → keep the reading position.
            anchor = (pageH * scale > viewport.height)
                ? .preserveY
                : .pageTopMargin(pageIndex: targetPageIndex)

        case (true, false):
            // double → single (SW-2): match the spread's FORMER on-screen width.
            // oldScale is the FROM mode's two-up STANDARD fit (SW-5: not the
            // live zoom) — 2·oldScale·pageW + M == newScale·pageW. Lands on the
            // former book pair's top-left page (VM-5).
            let oldScale = standardPlan(mode: from, viewport: viewport, pageSize: pageSize)
                .scaleFactor
            scale = pageW > 0 ? 2 * oldScale + margin / pageW : 2 * oldScale
            targetPageIndex = spreadLeftIndex(of: currentPageIndex, layout: layout)
            anchor = .pageTopMargin(pageIndex: targetPageIndex)

        case (false, false), (true, true):
            // Same single/double family — a fixed↔continuous flip (VM-1..4).
            scale = standardPlan(mode: to, viewport: viewport, pageSize: pageSize)
                .scaleFactor
            targetPageIndex = currentPageIndex
            anchor = to.isContinuous
                ? .preserveY
                : .pageTopMargin(pageIndex: currentPageIndex)
        }

        return ModeTransition(
            displayMode: to.displayModeRaw,
            scaleFactor: scale,
            pageBreakMarginInset: marginInset(onScreenGap: margin, scale: scale),
            targetPageIndex: targetPageIndex,
            scrollAnchor: anchor,
            // Carry the destination pairing so the applier can set the live
            // view's displaysAsBook/displaysRTL when it is a two-up mode.
            bookLayout: to.isTwoUp ? layout : .default
        )
    }

    // MARK: SIZE-1..SIZE-5 — different-size pages

    /// Which slot of a two-up spread a page occupies. The GEOMETRIC side is what
    /// matters for alignment (independent of `rtl`, which only swaps which
    /// content page lands in which slot): the `.left` slot's spine is on its
    /// RIGHT, the `.right` slot's spine on its LEFT.
    public enum SpreadSide: Sendable { case left, right }

    /// Vertical alignment of a page's content within its uniform two-up cell.
    ///
    /// OWNER-CONFIRM: SIZE-3 and SIZE-4 both use `.center` for now — the safe,
    /// symmetric reading of "aligned toward the middle". The vertical choice is
    /// ISOLATED here so switching SIZE-3 (double fixed) to `.bottom`/`.top`
    /// later, once the owner confirms the exact alignment against a diagram, is a
    /// one-line change at the `twoUpBoxOverrides` / applier call site.
    public enum CellVAlign: Sendable { case center, bottom, top }

    /// SIZE-3/4/5 — the enlarged page box that makes a mixed-size page fill a
    /// uniform two-up `cell` by BLANK PADDING (docs/PDFKIT-FACTS.md Fact 3),
    /// keeping the content at natural size (never scaled — SIZE-5), flush toward
    /// the spine horizontally and per `vAlign` vertically. PURE rect arithmetic.
    ///
    /// Horizontal (spine-ward): `.left` slot ⇒ content flush RIGHT
    /// (`box.minX = content.maxX − cell.w`); `.right` slot ⇒ content flush LEFT
    /// (`box.minX = content.minX`). Vertical: `.center` splits the slack;
    /// `.bottom` pins the content's bottom edge; `.top` pins its top edge. The
    /// box keeps `cell`'s size; the content sits inside as an off-center sub-rect.
    ///
    /// Enlarge-only: callers pass `cell` ≥ `content` (the spread/document max),
    /// so the box always CONTAINS the content — nothing is clipped. `PageBoxStore`
    /// enforces this again as a cover guard.
    public static func cellBox(
        content: CGRect, cell: CGSize, side: SpreadSide, vAlign: CellVAlign
    ) -> CGRect {
        let minX: CGFloat
        switch side {
        case .left:  minX = content.maxX - cell.width      // content flush right
        case .right: minX = content.minX                   // content flush left
        }
        let minY: CGFloat
        switch vAlign {
        case .center: minY = content.minY - (cell.height - content.height) / 2
        case .bottom: minY = content.minY                  // content flush bottom
        case .top:    minY = content.maxY - cell.height    // content flush top
        }
        return CGRect(x: minX, y: minY, width: cell.width, height: cell.height)
    }

    /// SIZE-3/4 — the in-memory box overrides that align an entire document's
    /// pages for two-up. Every cell is the DOCUMENT-wide max content size
    /// (`spreadCell`) so every column is identical and every spread abuts its
    /// central gutter regardless of per-page size; each page's content is placed
    /// spine-ward + per `vAlign`. `pageContents[i]` is page i's ORIGINAL box (page
    /// space); `layout` decides each page's slot (which side of its spread).
    /// PURE — the caller applies the result through `PageBoxStore`.
    public static func twoUpBoxOverrides(
        pageContents: [CGRect], layout: BookLayout, vAlign: CellVAlign
    ) -> [Int: CGRect] {
        guard !pageContents.isEmpty else { return [:] }
        let cell = spreadCell(contents: pageContents)
        var map: [Int: CGRect] = [:]
        for index in pageContents.indices {
            let p = pair(containing: index, layout: layout)
            let side: SpreadSide = (p.left == index) ? .left : .right
            map[index] = cellBox(
                content: pageContents[index], cell: cell, side: side, vAlign: vAlign)
        }
        return map
    }

    /// The uniform cell size for a set of pages: the max content width and height
    /// (enlarge-only — the cell is never smaller than any page in either axis).
    public static func spreadCell(contents: [CGRect]) -> CGSize {
        var w: CGFloat = 0
        var h: CGFloat = 0
        for c in contents {
            w = max(w, c.width)
            h = max(h, c.height)
        }
        return CGSize(width: w, height: h)
    }

    /// SIZE-1/2 — the fit scale for a SINGLE mode comes from the CURRENT page
    /// only, NEVER the document-widest page (regression against the autoScales
    /// "fit the widest page" bug): `.singleFixed` → whole-page fit;
    /// `.singleContinuous` → width fit. Two-up modes don't use this (they fit the
    /// uniform cell, not a single page).
    public static func singlePageScale(
        mode: ViewMode, viewport: CGSize, currentPageSize: CGSize
    ) -> CGFloat {
        switch mode {
        case .singleFixed:
            return fixedFitScale(
                viewport: viewport, pageSize: currentPageSize, margin: ReaderLayout.margin)
        case .singleContinuous:
            return widthFitScale(
                viewportWidth: viewport.width, pageWidth: currentPageSize.width,
                margin: ReaderLayout.margin)
        case .doubleFixed, .doubleContinuous:
            // Two-up fit uses the uniform cell width, not a lone page.
            return twoUpWidthFitScale(
                viewportWidth: viewport.width, pageWidth: currentPageSize.width,
                margin: ReaderLayout.margin)
        }
    }

    /// Which axis a fit button fills. `width` fills the viewport width leaving
    /// M left/right (FIT-1); `height` fits `pageH·scale + 2M == viewportH`
    /// (FIT-2).
    public enum FitAxis: Sendable { case width, height }

    /// The fit-button plan (FIT-1/FIT-2). A fit changes ONLY the scale (and the
    /// derived margin inset) WITHIN the current `mode` — the `displayMode` is
    /// carried through unchanged, and the scroll behavior (preserve y for
    /// width; re-fit in place for height) is the applier's job, not the plan's.
    ///
    /// - `.width`: single → `widthFitScale`, two-up → `twoUpWidthFitScale`
    ///   (fill the viewport width leaving M on each side / 3·M across a spread).
    /// - `.height`: `heightFitScale` in every mode (`pageH·scale + 2M ==
    ///   viewportH`).
    public static func fitPlan(
        mode: ViewMode, axis: FitAxis, viewport: CGSize, pageSize: CGSize
    ) -> LayoutPlan {
        let margin = ReaderLayout.margin
        let scale: CGFloat
        switch axis {
        case .width:
            scale = mode.isTwoUp
                ? twoUpWidthFitScale(
                    viewportWidth: viewport.width, pageWidth: pageSize.width, margin: margin)
                : widthFitScale(
                    viewportWidth: viewport.width, pageWidth: pageSize.width, margin: margin)
        case .height:
            scale = heightFitScale(
                viewportHeight: viewport.height, pageHeight: pageSize.height, margin: margin)
        }
        return LayoutPlan(
            displayMode: mode.displayModeRaw,
            pageBreakMarginInset: marginInset(onScreenGap: margin, scale: scale),
            scaleFactor: scale
        )
    }
}
