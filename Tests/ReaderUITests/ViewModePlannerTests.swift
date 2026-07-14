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
}
