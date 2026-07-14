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
