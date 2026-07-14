import CoreGraphics
import Testing
@testable import ReaderUI

/// PURE margin/fit math for the view-mode overhaul (phase 2). The numbers here
/// are computed on paper from `ReaderLayout.margin` and asserted exactly — the
/// planner is deliberately PDFKit-free so its arithmetic can be pinned without
/// a live view. The one live-view integration check (real inner gap ≈ margin)
/// lives in ViewModePlannerIntegrationTests (macOS only).
///
/// Model recap (docs/PDFKIT-FACTS.md): `pageBreakMargins` insets are PAGE
/// POINTS; the on-screen gap between two adjacent pages = (sum of the two
/// adjacent insets) × scale = 2·inset·scale. A symmetric per-side inset of
/// `margin / (2·scale)` therefore renders as exactly `margin` on screen.
@Suite struct ViewModePlannerTests {
    // MARK: ViewMode enum ↔ PDFDisplayMode raw values

    /// Raw values must match PDFDisplayMode (singlePage=0, singlePageContinuous=1,
    /// twoUp=2, twoUpContinuous=3) so `displayModeRaw` round-trips through PDFKit.
    @Test func viewModeMapsToDisplayModeRawValues() {
        #expect(ViewMode.singleFixed.rawValue == 0)
        #expect(ViewMode.singleContinuous.rawValue == 1)
        #expect(ViewMode.doubleFixed.rawValue == 2)
        #expect(ViewMode.doubleContinuous.rawValue == 3)

        #expect(ViewMode.singleFixed.isContinuous == false)
        #expect(ViewMode.singleContinuous.isContinuous == true)
        #expect(ViewMode.doubleFixed.isContinuous == false)
        #expect(ViewMode.doubleContinuous.isContinuous == true)

        #expect(ViewMode.singleFixed.isTwoUp == false)
        #expect(ViewMode.singleContinuous.isTwoUp == false)
        #expect(ViewMode.doubleFixed.isTwoUp == true)
        #expect(ViewMode.doubleContinuous.isTwoUp == true)

        for mode in ViewMode.allCases {
            #expect(mode.displayModeRaw == mode.rawValue)
            #expect(ViewMode(displayModeRaw: mode.rawValue) == mode)
        }
        #expect(ViewMode(displayModeRaw: 4) == nil)
        #expect(ViewMode(displayModeRaw: -1) == nil)
    }

    // MARK: helper math

    /// marginInset = onScreenGap / (2·scale). With gap = 8, scale = 1 → 4;
    /// scale = 2 → 2 (so 2·inset·scale = 8 at either scale).
    @Test func marginInsetConvertsScreenGapToPageInset() {
        #expect(ViewModePlanner.marginInset(onScreenGap: 8, scale: 1) == 4)
        #expect(ViewModePlanner.marginInset(onScreenGap: 8, scale: 2) == 2)
        #expect(ViewModePlanner.marginInset(onScreenGap: 8, scale: 0.5) == 8)
        // guard scale > 0 → 0 (no divide-by-zero / negative inset)
        #expect(ViewModePlanner.marginInset(onScreenGap: 8, scale: 0) == 0)
    }

    /// widthFitScale = (viewportWidth - 2·margin) / pageWidth.
    /// (816 - 16) / 400 = 2.0.
    @Test func widthFitScaleLeavesMarginLeftRight() {
        let s = ViewModePlanner.widthFitScale(
            viewportWidth: 816, pageWidth: 400, margin: 8)
        #expect(s == 2.0)
    }

    /// heightFitScale = (viewportHeight - 2·margin) / pageHeight.
    /// (1216 - 16) / 600 = 2.0.
    @Test func heightFitScaleLeavesMarginTopBottom() {
        let s = ViewModePlanner.heightFitScale(
            viewportHeight: 1216, pageHeight: 600, margin: 8)
        #expect(s == 2.0)
    }

    /// twoUpWidthFitScale = (viewportWidth - 3·margin) / (2·pageWidth):
    /// a spread is two pages + two outer margins + one inner gap = 3 margins.
    /// (824 - 24) / (2·400) = 800/800 = 1.0.
    @Test func twoUpWidthFitScaleAccountsForThreeMargins() {
        let s = ViewModePlanner.twoUpWidthFitScale(
            viewportWidth: 824, pageWidth: 400, margin: 8)
        #expect(s == 1.0)
    }

    /// fixed fit = min(width fit, height fit) so the whole page shows with ≥
    /// margin all around. Here height constrains: widthFit=(800-16)/400=1.96,
    /// heightFit=(616-16)/600=1.0 → min = 1.0.
    @Test func fixedFitScaleTakesTheSmallerOfWidthAndHeightFit() {
        let s = ViewModePlanner.fixedFitScale(
            viewport: CGSize(width: 800, height: 616),
            pageSize: CGSize(width: 400, height: 600), margin: 8)
        #expect(s == 1.0)
    }

    // MARK: M-1 .. M-4 (the spec: docs/specs/view-modes.md)

    /// M-1 — two-page continuous: the vertical row gap AND the horizontal
    /// spread gap both render as exactly M on screen.
    /// GIVEN viewport 824×1000, pages 400×600, mode .doubleContinuous.
    /// WHEN standardPlan is computed:
    ///   scale = twoUpWidthFit = (824 - 3·8)/(2·400) = 800/800 = 1.0.
    ///   inset = marginInset(gap: M=8, scale: 1) = 8/(2·1) = 4.
    /// THEN both gaps = 2·inset·scale = 2·4·1 = 8 == ReaderLayout.margin.
    @Test func m1_twoUpContinuous_rowGapEqualsPageGapEqualsMargin() {
        let plan = ViewModePlanner.standardPlan(
            mode: .doubleContinuous,
            viewport: CGSize(width: 824, height: 1000),
            pageSize: CGSize(width: 400, height: 600))

        #expect(plan.scaleFactor == 1.0)
        #expect(plan.pageBreakMarginInset == 4)

        let inset = plan.pageBreakMarginInset
        let scale = plan.scaleFactor
        let verticalRowGap = 2 * inset * scale       // stacked pages (top+bottom insets)
        let horizontalSpreadGap = 2 * inset * scale  // side-by-side pair (left+right insets)
        #expect(verticalRowGap == ReaderLayout.margin)
        #expect(horizontalSpreadGap == ReaderLayout.margin)
    }

    /// M-2 — two-page fixed: the gap between the two pages == M.
    /// GIVEN viewport 824×2000, pages 400×600, mode .doubleFixed.
    /// WHEN standardPlan: scale = min(twoUpWidthFit, heightFit)
    ///   twoUpWidthFit = (824-24)/800 = 1.0; heightFit = (2000-16)/600 = 3.306…
    ///   → scale = 1.0; inset = 8/(2·1) = 4.
    /// THEN inner gap = 2·inset·scale = 8 == M.
    @Test func m2_twoUpFixed_gapBetweenPagesEqualsMargin() {
        let plan = ViewModePlanner.standardPlan(
            mode: .doubleFixed,
            viewport: CGSize(width: 824, height: 2000),
            pageSize: CGSize(width: 400, height: 600))

        #expect(plan.scaleFactor == 1.0)
        #expect(plan.pageBreakMarginInset == 4)

        let innerGap = 2 * plan.pageBreakMarginInset * plan.scaleFactor
        #expect(innerGap == ReaderLayout.margin)
    }

    /// M-3 — fixed modes: on-screen margin above and below the page == M.
    /// GIVEN a case where HEIGHT constrains the fit, so scale = heightFitScale.
    ///   viewport 800×616, page 400×600, mode .singleFixed.
    ///   widthFit = (800-16)/400 = 1.96; heightFit = (616-16)/600 = 1.0
    ///   → scale = 1.0.
    /// THEN on-screen page height = 600·1 = 600; leftover vertical = 616-600 =
    ///   16; split top/bottom = 8 each == M.
    @Test func m3_fixedModes_topAndBottomMarginEqualMargin() {
        let viewport = CGSize(width: 800, height: 616)
        let pageSize = CGSize(width: 400, height: 600)
        let plan = ViewModePlanner.standardPlan(
            mode: .singleFixed, viewport: viewport, pageSize: pageSize)

        #expect(plan.scaleFactor == 1.0)

        let onScreenPageHeight = pageSize.height * plan.scaleFactor
        let topBottomMargin = (viewport.height - onScreenPageHeight) / 2
        #expect(topBottomMargin == ReaderLayout.margin)
    }

    /// M-4 — fit margins: fit-width leaves exactly M left/right; fit-height
    /// leaves exactly M top/bottom.
    /// Width: page 400 wide, viewport 816 → s = (816-16)/400 = 2.0;
    ///   viewportW - pageW·s = 816 - 800 = 16 = 2·M.
    /// Height: page 600 tall, viewport 1216 → s = (1216-16)/600 = 2.0;
    ///   viewportH - pageH·s = 1216 - 1200 = 16 = 2·M.
    @Test func m4_fitMargins_widthLeavesMarginLeftRight_heightLeavesMarginTopBottom() {
        let m = ReaderLayout.margin

        let widthScale = ViewModePlanner.widthFitScale(
            viewportWidth: 816, pageWidth: 400, margin: m)
        #expect(widthScale == 2.0)
        #expect(816 - 400 * widthScale == 2 * m)

        let heightScale = ViewModePlanner.heightFitScale(
            viewportHeight: 1216, pageHeight: 600, margin: m)
        #expect(heightScale == 2.0)
        #expect(1216 - 600 * heightScale == 2 * m)
    }

    // MARK: FIT-1 / FIT-2 — fitPlan descriptor (pure)

    /// fitPlan(.width) for a single mode uses widthFitScale and leaves M on
    /// each side; for a two-up mode uses twoUpWidthFitScale and leaves 3·M
    /// across the spread (two outer + one gutter). Inset renders as M at scale.
    /// Single: (816 − 2·8)/400 = 2.0 → 816 − 400·2 = 16 = 2·M.
    /// Two-up: (824 − 3·8)/(2·400) = 1.0 → 824 − 2·400·1 = 24 = 3·M.
    @Test func fitPlanWidthLeavesMarginSingleAndSpread() {
        let m = ReaderLayout.margin

        let single = ViewModePlanner.fitPlan(
            mode: .singleContinuous, axis: .width,
            viewport: CGSize(width: 816, height: 1000),
            pageSize: CGSize(width: 400, height: 600))
        #expect(single.displayMode == 1)
        #expect(single.scaleFactor == 2.0)
        #expect(816 - 400 * single.scaleFactor == 2 * m)
        #expect(2 * single.pageBreakMarginInset * single.scaleFactor == m)

        let twoUp = ViewModePlanner.fitPlan(
            mode: .doubleContinuous, axis: .width,
            viewport: CGSize(width: 824, height: 1000),
            pageSize: CGSize(width: 400, height: 600))
        #expect(twoUp.displayMode == 3)
        #expect(twoUp.scaleFactor == 1.0)
        #expect(824 - 2 * 400 * twoUp.scaleFactor == 3 * m)
    }

    /// fitPlan(.height) uses heightFitScale in every mode: pageH·s + 2M ==
    /// viewportH, and the displayMode is unchanged (fits stay within the mode).
    /// (1216 − 2·8)/600 = 2.0 → 600·2 + 16 = 1216.
    @Test func fitPlanHeightFitsPageHeightPlusTwiceMargin() {
        let m = ReaderLayout.margin
        for mode in ViewMode.allCases {
            let plan = ViewModePlanner.fitPlan(
                mode: mode, axis: .height,
                viewport: CGSize(width: 800, height: 1216),
                pageSize: CGSize(width: 400, height: 600))
            #expect(plan.displayMode == mode.displayModeRaw)
            #expect(plan.scaleFactor == 2.0)
            #expect(600 * plan.scaleFactor + 2 * m == 1216)
            #expect(2 * plan.pageBreakMarginInset * plan.scaleFactor == m)
        }
    }

    // MARK: standardPlan scale selection per mode

    /// Each mode selects the documented fit; the displayMode is the raw value;
    /// the inset renders as M at that scale.
    @Test func standardPlanSelectsDocumentedScalePerMode() {
        let viewport = CGSize(width: 824, height: 616)
        let pageSize = CGSize(width: 400, height: 600)

        // singleFixed → min(width, height) fit.
        let sf = ViewModePlanner.standardPlan(
            mode: .singleFixed, viewport: viewport, pageSize: pageSize)
        #expect(sf.displayMode == 0)
        #expect(sf.scaleFactor == ViewModePlanner.fixedFitScale(
            viewport: viewport, pageSize: pageSize, margin: ReaderLayout.margin))

        // singleContinuous → width fit (fill width, margin L/R).
        let sc = ViewModePlanner.standardPlan(
            mode: .singleContinuous, viewport: viewport, pageSize: pageSize)
        #expect(sc.displayMode == 1)
        #expect(sc.scaleFactor == ViewModePlanner.widthFitScale(
            viewportWidth: viewport.width, pageWidth: pageSize.width,
            margin: ReaderLayout.margin))

        // doubleFixed → min(twoUpWidth, height) fit.
        let df = ViewModePlanner.standardPlan(
            mode: .doubleFixed, viewport: viewport, pageSize: pageSize)
        #expect(df.displayMode == 2)
        let twoUpW = ViewModePlanner.twoUpWidthFitScale(
            viewportWidth: viewport.width, pageWidth: pageSize.width,
            margin: ReaderLayout.margin)
        let heightF = ViewModePlanner.heightFitScale(
            viewportHeight: viewport.height, pageHeight: pageSize.height,
            margin: ReaderLayout.margin)
        #expect(df.scaleFactor == min(twoUpW, heightF))

        // doubleContinuous → two-up width fit.
        let dc = ViewModePlanner.standardPlan(
            mode: .doubleContinuous, viewport: viewport, pageSize: pageSize)
        #expect(dc.displayMode == 3)
        #expect(dc.scaleFactor == twoUpW)

        // Inset renders as M at each plan's own scale.
        for plan in [sf, sc, df, dc] {
            #expect(2 * plan.pageBreakMarginInset * plan.scaleFactor == ReaderLayout.margin)
        }
    }

    // MARK: VM-1 .. VM-4 — mode-button entry (same-family fixed↔continuous)
    //
    // A mode button pressed WITHIN the same column count (single↔single or
    // double↔double) is a fixed/continuous flip: the destination's standard fit
    // with the SAME current page. Continuous destinations preserve the reading
    // y (VM-2/VM-4); fixed destinations anchor the (single/spread) page top at
    // margin M (VM-1/VM-3) — which PDFKit renders centered when the page fits.

    /// VM-1 — single fixed entry (from single continuous): standard fixed fit,
    /// SAME page, page-top anchored at M (centered when it fits).
    /// GIVEN viewport 800×616, page 400×600, current page 2, mode → singleFixed.
    ///   fixedFit = min((800-16)/400=1.96, (616-16)/600=1.0) = 1.0.
    ///   inset = 8/(2·1) = 4.
    @Test func vm1_singleFixedEntry_standardFit_samePage_pageTopMargin() {
        let t = ViewModePlanner.transition(
            from: .singleContinuous, to: .singleFixed,
            currentPageIndex: 2, currentScale: 1.0,
            viewport: CGSize(width: 800, height: 616),
            pageSize: CGSize(width: 400, height: 600))
        #expect(t.displayMode == 0)
        #expect(t.scaleFactor == 1.0)
        #expect(t.pageBreakMarginInset == 4)
        #expect(t.targetPageIndex == 2)
        #expect(t.scrollAnchor == .pageTopMargin(pageIndex: 2))
    }

    /// VM-2 — single continuous entry (from single fixed): width fit, centered,
    /// y-scroll UNCHANGED (preserveY).
    /// GIVEN viewport 816×1000, page 400×600, current page 2, → singleContinuous.
    ///   widthFit = (816-16)/400 = 2.0; inset = 8/(2·2) = 2.
    @Test func vm2_singleContinuousEntry_widthFit_preservesY() {
        let t = ViewModePlanner.transition(
            from: .singleFixed, to: .singleContinuous,
            currentPageIndex: 2, currentScale: 1.0,
            viewport: CGSize(width: 816, height: 1000),
            pageSize: CGSize(width: 400, height: 600))
        #expect(t.displayMode == 1)
        #expect(t.scaleFactor == 2.0)
        #expect(t.pageBreakMarginInset == 2)
        #expect(t.targetPageIndex == 2)
        #expect(t.scrollAnchor == .preserveY)
    }

    /// VM-3 — double fixed entry (from double continuous): two-up standard fit,
    /// SAME page kept, spread top anchored at M.
    /// GIVEN viewport 824×2000, page 400×600, current page 3, → doubleFixed.
    ///   twoUpWidthFit = (824-24)/800 = 1.0; heightFit = (2000-16)/600 = 3.306…
    ///   → min = 1.0; inset = 4. Same page kept (currentPageIndex 3).
    @Test func vm3_doubleFixedEntry_twoUpStandardFit_samePage_pageTopMargin() {
        let t = ViewModePlanner.transition(
            from: .doubleContinuous, to: .doubleFixed,
            currentPageIndex: 3, currentScale: 1.0,
            viewport: CGSize(width: 824, height: 2000),
            pageSize: CGSize(width: 400, height: 600))
        #expect(t.displayMode == 2)
        #expect(t.scaleFactor == 1.0)
        #expect(t.pageBreakMarginInset == 4)
        #expect(t.targetPageIndex == 3)
        #expect(t.scrollAnchor == .pageTopMargin(pageIndex: 3))
    }

    /// VM-4 — double continuous entry (from double fixed): two-up width fit,
    /// y-scroll UNCHANGED (preserveY).
    /// GIVEN viewport 824×1000, page 400×600, current page 3, → doubleContinuous.
    ///   twoUpWidthFit = (824-24)/800 = 1.0; inset = 4.
    @Test func vm4_doubleContinuousEntry_twoUpWidthFit_preservesY() {
        let t = ViewModePlanner.transition(
            from: .doubleFixed, to: .doubleContinuous,
            currentPageIndex: 3, currentScale: 1.0,
            viewport: CGSize(width: 824, height: 1000),
            pageSize: CGSize(width: 400, height: 600))
        #expect(t.displayMode == 3)
        #expect(t.scaleFactor == 1.0)
        #expect(t.pageBreakMarginInset == 4)
        #expect(t.targetPageIndex == 3)
        #expect(t.scrollAnchor == .preserveY)
    }

    // MARK: SW-1 .. SW-5 — cross-family mode switches

    /// SW-2 — double→single: the single page's on-screen width equals the whole
    /// spread's FORMER on-screen width. Spread width = 2·(pageW·oldScale) + M, so
    /// newScale = 2·oldScale + M/pageW. Lands on the pair's top-left (lower)
    /// index and anchors its top at margin M.
    /// GIVEN viewport 824×1000, page 400×600, current page 3, oldScale (the
    ///   two-up STANDARD scale) = twoUpWidthFit = (824-24)/800 = 1.0.
    ///   newScale = 2·1.0 + 8/400 = 2.02.
    ///   leftIndex = (3/2)*2 = 2.
    /// THEN newScale·pageW (808) == 2·oldScale·pageW + M (2·400 + 8 = 808).
    @Test func sw2_doubleToSingle_pageWidthEqualsFormerSpreadWidth() {
        let m = ReaderLayout.margin
        let pageW: CGFloat = 400
        let t = ViewModePlanner.transition(
            from: .doubleContinuous, to: .singleContinuous,
            currentPageIndex: 3, currentScale: 1.0,
            viewport: CGSize(width: 824, height: 1000),
            pageSize: CGSize(width: pageW, height: 600))
        #expect(t.displayMode == 1)
        #expect(abs(t.scaleFactor - 2.02) <= 1e-9)
        #expect(t.targetPageIndex == 2)
        #expect(t.scrollAnchor == .pageTopMargin(pageIndex: 2))

        // The load-bearing identity: former spread width == new single width.
        let oldScale: CGFloat = 1.0                       // two-up standard fit
        let formerSpreadWidth = 2 * (pageW * oldScale) + m   // 808
        let newSingleWidth = pageW * t.scaleFactor           // 400·2.02 = 808
        #expect(abs(newSingleWidth - formerSpreadWidth) <= 1e-9)
    }

    /// SW-3 — single→double (viewport NOT too wide): current page takes the
    /// spread's top-left slot; scroll so its top is at margin M.
    /// GIVEN viewport 824×1000, page 400×600, current page 5, → doubleContinuous.
    ///   twoUpWidthFit = (824-24)/800 = 1.0; pageH·scale = 600·1 = 600 ≤ 1000
    ///   (a full page shows), so anchor = pageTopMargin, NOT preserveY.
    ///   leftIndex = (5/2)*2 = 4.
    @Test func sw3_singleToDouble_currentPageTopLeftScrolledToMargin() {
        let t = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: 5, currentScale: 1.0,
            viewport: CGSize(width: 824, height: 1000),
            pageSize: CGSize(width: 400, height: 600))
        #expect(t.displayMode == 3)
        #expect(t.scaleFactor == 1.0)
        #expect(t.targetPageIndex == 4)
        #expect(t.scrollAnchor == .pageTopMargin(pageIndex: 4))
    }

    /// SW-4 — single→double, viewport TOO WIDE to show a full page height: keep
    /// the user's previous y-scroll (preserveY) instead of snapping to page top.
    /// GIVEN viewport 2424×300, page 400×600, current page 2, → doubleContinuous.
    ///   twoUpWidthFit = (2424-24)/800 = 3.0; pageH·scale = 600·3 = 1800 > 300
    ///   → a full page can't be shown → preserveY.
    @Test func sw4_singleToDouble_wideViewport_preservesY() {
        let t = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: 2, currentScale: 1.0,
            viewport: CGSize(width: 2424, height: 300),
            pageSize: CGSize(width: 400, height: 600))
        #expect(t.displayMode == 3)
        #expect(t.scaleFactor == 3.0)
        #expect(t.targetPageIndex == 2)
        #expect(t.scrollAnchor == .preserveY)
    }

    /// SW-1 — round trip: single→double→single (and double→single→double) return
    /// to the same page, scale, and anchor. Falls out of SW-2/SW-3 being inverses
    /// (double snaps to the pair's left page, so start on an even page for an
    /// exact match). Composes the two transitions and asserts the endpoint.
    @Test func sw1_roundTripReturnsToStart() {
        let viewport = CGSize(width: 824, height: 1000)
        let pageSize = CGSize(width: 400, height: 600)

        // single → double → single, starting on an even page.
        let s0 = ViewModePlanner.widthFitScale(
            viewportWidth: viewport.width, pageWidth: pageSize.width,
            margin: ReaderLayout.margin)                 // (824-16)/400 = 2.02
        let toDouble = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: 4, currentScale: s0,
            viewport: viewport, pageSize: pageSize)
        let backToSingle = ViewModePlanner.transition(
            from: .doubleContinuous, to: .singleContinuous,
            currentPageIndex: toDouble.targetPageIndex, currentScale: toDouble.scaleFactor,
            viewport: viewport, pageSize: pageSize)
        #expect(backToSingle.targetPageIndex == 4)
        #expect(abs(backToSingle.scaleFactor - s0) <= 1e-9)
        #expect(backToSingle.scrollAnchor == .pageTopMargin(pageIndex: 4))

        // double → single → double, starting on an even page.
        let d0 = ViewModePlanner.twoUpWidthFitScale(
            viewportWidth: viewport.width, pageWidth: pageSize.width,
            margin: ReaderLayout.margin)                 // (824-24)/800 = 1.0
        let toSingle = ViewModePlanner.transition(
            from: .doubleContinuous, to: .singleContinuous,
            currentPageIndex: 4, currentScale: d0,
            viewport: viewport, pageSize: pageSize)
        let backToDouble = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: toSingle.targetPageIndex, currentScale: toSingle.scaleFactor,
            viewport: viewport, pageSize: pageSize)
        #expect(backToDouble.targetPageIndex == 4)
        #expect(abs(backToDouble.scaleFactor - d0) <= 1e-9)
    }

    /// SW-5 — a non-standard live zoom must NOT leak into the destination: the
    /// transition output depends only on the standard rule (nothing is persisted
    /// per-mode). Feeding a wild currentScale yields the SAME targets as the
    /// standard scale.
    @Test func sw5_nonStandardZoomDoesNotLeak() {
        let viewport = CGSize(width: 824, height: 1000)
        let pageSize = CGSize(width: 400, height: 600)

        // single→double is a standard fit regardless of the live zoom.
        let up = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: 3, currentScale: 5.7,      // wild user zoom
            viewport: viewport, pageSize: pageSize)
        #expect(up.scaleFactor == 1.0)                    // twoUpWidthFit, not 5.7-derived
        #expect(up.targetPageIndex == 2)

        // double→single derives from the two-up STANDARD scale (1.0), not the
        // live zoom (4.2): newScale = 2·1.0 + 8/400 = 2.02.
        let down = ViewModePlanner.transition(
            from: .doubleContinuous, to: .singleContinuous,
            currentPageIndex: 3, currentScale: 4.2,       // wild user zoom
            viewport: viewport, pageSize: pageSize)
        #expect(abs(down.scaleFactor - 2.02) <= 1e-9)
        #expect(down.targetPageIndex == 2)
    }
}
