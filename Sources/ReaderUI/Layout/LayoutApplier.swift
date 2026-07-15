#if os(macOS)
import AppKit
import PDFKit
import ReaderCore

/// Applies a pure `LayoutPlan` onto a live `PDFView`. Kept as a free static
/// function (not just a Coordinator method) so it can be driven against a bare
/// offscreen `PDFView` in tests without standing up a whole Coordinator.
///
/// The plan owns all the geometry (docs/PDFKIT-FACTS.md): symmetric page-space
/// `pageBreakMargins` render the between-page gaps as `ReaderLayout.margin` on
/// screen at `plan.scaleFactor`, and an explicit `scaleFactor` (with
/// `autoScales` off) realizes the standard fit. `layoutDocumentView()` is
/// deferred one runloop so PDFKit re-centers content narrower than the pane.
public enum LayoutApplier {
    /// A reading position anchored to the CONTENT: the page and the page-space
    /// (PDF content) y-coordinate currently at the viewport top. Cropping a page
    /// changes its media/crop BOX but NOT where the content draws, so a content
    /// coordinate is invariant to the crop — restoring it keeps the exact same
    /// text under the viewport top (a box-fraction anchor drifts because the box
    /// top moves when the margin is cropped away).
    public struct PagePosition: Equatable, Sendable {
        public var pageIndex: Int
        /// Page-space y of the content at the viewport top (PDF content coords).
        public var pagePointY: CGFloat
        public init(pageIndex: Int, pagePointY: CGFloat) {
            self.pageIndex = pageIndex
            self.pagePointY = pagePointY
        }
    }

    /// Captures the content coordinate at the viewport top (see `PagePosition`).
    /// Non-flipped documentView; `pageRectDoc` is the page box scaled into
    /// documentView space, so `scaleFactor` doc-units per page point. `nil` when
    /// there is no page/geometry to read.
    @MainActor
    public static func capturePagePosition(in view: PDFView) -> PagePosition? {
        guard
            let document = view.document,
            let current = view.currentPage,
            let clip = firstScrollView(in: view)?.contentView,
            let docView = clip.documentView
        else { return nil }
        let viewportTopDoc = clip.bounds.origin.y + clip.bounds.height
        // The page at the viewport TOP — not necessarily PDFKit's currentPage
        // (which tracks the center/most-visible page and can lag a scroll).
        // Search outward from currentPage until a page's box brackets the
        // viewport top; fall back to currentPage if none does (viewport in a gap).
        let curIdx = document.index(for: current)
        func anchor(on idx: Int) -> PagePosition? {
            guard let page = document.page(at: idx) else { return nil }
            let box = page.bounds(for: view.displayBox)
            let rectDoc = docView.convert(view.convert(box, from: page), from: view)
            guard box.height > 0, rectDoc.height > 0 else { return nil }
            let scaleY = rectDoc.height / box.height
            let pagePointY = box.minY + (viewportTopDoc - rectDoc.minY) / scaleY
            return PagePosition(pageIndex: idx, pagePointY: pagePointY)
        }
        for delta in 0..<document.pageCount {
            for idx in Set([curIdx - delta, curIdx + delta]) where (0..<document.pageCount).contains(idx) {
                guard let page = document.page(at: idx) else { continue }
                let rectDoc = docView.convert(
                    view.convert(page.bounds(for: view.displayBox), from: page), from: view)
                if rectDoc.minY - 1 <= viewportTopDoc, viewportTopDoc <= rectDoc.maxY + 1 {
                    return anchor(on: idx)
                }
            }
        }
        return anchor(on: curIdx)
    }

    /// Re-lays out and restores `position` (sync + one deferred pass, to survive
    /// PDFKit's late layout) WITHOUT changing scale — the no-zoom continuous trim:
    /// the crop repacks the page stack, this keeps the same content under the
    /// viewport top.
    @MainActor
    public static func reanchor(to position: PagePosition, in view: PDFView, log: AppLogger) {
        view.layoutDocumentView()
        restorePagePosition(position, in: view, log: log)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.layoutDocumentView()
            restorePagePosition(position, in: view, log: log)
        }
    }

    /// The inverse of `capturePagePosition`: scrolls so `position`'s content
    /// coordinate sits at the viewport top under the CURRENT (post-crop) box.
    /// Clamped to the scrollable range.
    @MainActor
    private static func restorePagePosition(
        _ position: PagePosition, in view: PDFView, log: AppLogger
    ) {
        guard
            let document = view.document,
            let page = document.page(at: min(max(0, position.pageIndex), max(0, document.pageCount - 1))),
            let clip = firstScrollView(in: view)?.contentView,
            let docView = clip.documentView
        else { return }
        let box = page.bounds(for: view.displayBox)
        let pageRectDoc = docView.convert(view.convert(box, from: page), from: view)
        guard box.height > 0 else { return }
        let scaleY = pageRectDoc.height / box.height
        let clipHeight = clip.bounds.height
        // Content coord y_p is at docViewY = pageRectDoc.minY + (y_p − box.minY)·scaleY.
        let targetDocY = pageRectDoc.minY + (position.pagePointY - box.minY) * scaleY
        let targetY = targetDocY - clipHeight
        let maxOriginY = max(0, docView.frame.height - clipHeight)
        var origin = clip.bounds.origin           // keep PDFKit's centered x
        origin.y = min(max(0, targetY), maxOriginY)
        clip.setBoundsOrigin(origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        log.debug(
            .trim,
            "restorePagePosition page=\(position.pageIndex) y_p=\(position.pagePointY) "
                + "pageRectDoc=\(pageRectDoc) clipH=\(clipHeight) → origin.y=\(origin.y)"
        )
    }

    /// - Parameter preserveVerticalScroll: for FIT-1 (fit width) the reading
    ///   position must NOT jump. The clip-view bounds origin is in PAGE POINTS
    ///   and is scale-independent (the documentView frame doesn't change with
    ///   `scaleFactor` — docs/PDFKIT-FACTS.md Fact 1), so we capture `origin.y`
    ///   BEFORE the scale change and re-apply it. A change to `scaleFactor`
    ///   makes PDFKit re-center on the old viewport midpoint; that adjustment
    ///   lands on the SAME runloop turn as a synchronous `layoutDocumentView()`,
    ///   so the restore must be synchronous too (a purely deferred restore is
    ///   overwritten — measured). We restore once synchronously and once more
    ///   after the deferred layout pass that re-centers narrow content in x.
    ///   For FIT-2 (fit height) and standard fits it stays `false` — those
    ///   re-fit/center in place.
    @MainActor
    public static func apply(
        _ plan: LayoutPlan, to view: PDFView, log: AppLogger,
        preserveVerticalScroll: Bool = false
    ) {
        // Capture the reading position (page-space clip origin.y) before the
        // scale change so fit-width can restore it.
        let savedOriginY: CGFloat? = preserveVerticalScroll
            ? firstScrollView(in: view)?.contentView.bounds.origin.y
            : nil

        let inset = plan.pageBreakMarginInset
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(
            top: inset, left: inset, bottom: inset, right: inset)
        view.autoScales = false
        view.scaleFactor = plan.scaleFactor

        // Restore the vertical scroll on the SAME turn as the scale change's own
        // re-centering, before the runloop yields (deferring it loses the race).
        if let savedOriginY {
            view.layoutDocumentView()
            restoreVerticalScroll(in: view, to: savedOriginY)
        }

        let savedYText: String = savedOriginY.map { "\($0)" } ?? "nil"
        log.debug(
            .layout,
            "applyLayoutPlan mode=\(plan.displayMode) inset=\(inset) "
                + "scale=\(plan.scaleFactor) vp=\(view.bounds.size) "
                + "preserveY=\(preserveVerticalScroll) savedY=\(savedYText) "
                + "→ liveScale=\(view.scaleFactor) autoScales=\(view.autoScales)"
        )

        // Defer one runloop: PDFKit centers content narrower than the pane on
        // the next layout pass, so forcing it here (before the scale settles)
        // leaves narrow pages pinned left. Re-restore y after that pass, which
        // re-centers on the viewport midpoint and would otherwise undo it.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.layoutDocumentView()
            if let savedOriginY {
                restoreVerticalScroll(in: view, to: savedOriginY)
                log.debug(
                    .layout,
                    "applyLayoutPlan restore preserveY → "
                        + "clip.origin.y=\(firstScrollView(in: view)?.contentView.bounds.origin.y ?? -1) "
                        + "(target \(savedOriginY))"
                )
            }
        }
    }

    /// SIZE-1 — re-fit the CURRENT page of a single-FIXED view to its OWN
    /// whole-page standard fit (margins ≥ M). Because pages differ in size and a
    /// PDFView applies ONE `scaleFactor`, the fit must be recomputed from the
    /// page that just became current — the Coordinator reuses its
    /// `PDFViewPageChanged` observer to call this. No-op unless the view is in
    /// single-page (fixed) mode. Returns the scale it set (nil if it didn't act)
    /// for tests/logs.
    @discardableResult
    @MainActor
    public static func refitSingleFixed(_ view: PDFView, log: AppLogger) -> CGFloat? {
        guard view.displayMode == .singlePage, let page = view.currentPage else { return nil }
        let pageSize = page.bounds(for: view.displayBox).size
        let scale = ViewModePlanner.singlePageScale(
            mode: .singleFixed, viewport: view.bounds.size, currentPageSize: pageSize)
        view.autoScales = false
        view.scaleFactor = scale
        view.layoutDocumentView()
        log.debug(
            .layout,
            "refitSingleFixed page=\(view.document?.index(for: page) ?? -1) "
                + "pageSize=\(pageSize) vp=\(view.bounds.size) → scale=\(scale)"
        )
        return scale
    }

    /// Applies a `ModeTransition` (mode button / mode switch — VM-1..4,
    /// SW-1..5) with the rewind pattern (docs/PDFKIT-FACTS.md): a display-mode
    /// change loses scroll position, so we set the new mode + scale + margins,
    /// resolve the `ScrollAnchor` to a concrete clip origin and apply it
    /// SYNCHRONOUSLY (the Phase-3 lesson: a purely deferred restore loses the
    /// race against PDFKit's own re-center), then re-assert once after a
    /// deferred `layoutDocumentView()` and once more after ~0.25s to survive
    /// PDFKit's late layout pass. Every step is instrumented via `.viewmode`.
    @MainActor
    public static func apply(
        _ transition: ModeTransition, to view: PDFView, log: AppLogger
    ) {
        guard let document = view.document else { return }

        // Capture the reading position BEFORE the mode change (page points,
        // scale-independent) so a preserveY anchor can restore it.
        let beforeOriginY = firstScrollView(in: view)?.contentView.bounds.origin.y ?? 0
        let beforeMode = view.displayMode.rawValue

        view.displayMode = PDFDisplayMode(rawValue: transition.displayMode)
            ?? .singlePageContinuous
        // Two-up modes honor the document's even/odd pairing (VM-5/VM-6): set
        // the live view's book/RTL flags so PDFKit pairs pages the same way the
        // pure planner did when it picked `targetPageIndex`.
        if let mode = ViewMode(displayModeRaw: transition.displayMode), mode.isTwoUp {
            view.displaysAsBook = transition.bookLayout.displaysAsBook
            view.displaysRTL = transition.bookLayout.rtl
        }
        let inset = transition.pageBreakMarginInset
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(
            top: inset, left: inset, bottom: inset, right: inset)
        view.autoScales = false
        view.scaleFactor = transition.scaleFactor

        // Resolve + apply the scroll anchor on the SAME turn as the mode/scale
        // change's own re-center, before the runloop yields.
        view.layoutDocumentView()
        resolveAnchor(transition, in: view, document: document, preserveOriginY: beforeOriginY, log: log)

        let liveY = firstScrollView(in: view)?.contentView.bounds.origin.y ?? -1
        log.debug(
            .viewmode,
            "applyTransition mode=\(beforeMode)→\(view.displayMode.rawValue) "
                + "scale=\(transition.scaleFactor) inset=\(inset) "
                + "target=\(transition.targetPageIndex) anchor=\(transition.scrollAnchor) "
                + "vp=\(view.bounds.size) beforeY=\(beforeOriginY) → clipY=\(liveY)"
        )

        // Deferred re-assert: PDFKit re-centers / re-lays out on the next pass,
        // which would otherwise undo the anchor.
        DispatchQueue.main.async { [weak view] in
            guard let view, let document = view.document else { return }
            view.layoutDocumentView()
            resolveAnchor(transition, in: view, document: document, preserveOriginY: beforeOriginY, log: log)
            let y = firstScrollView(in: view)?.contentView.bounds.origin.y ?? -1
            log.debug(.viewmode, "applyTransition deferred re-assert → clipY=\(y)")
        }
        // Late re-assert (~0.25s): PDFKit has a late layout pass that can move
        // the clip after the deferred one has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak view] in
            guard let view, let document = view.document else { return }
            resolveAnchor(transition, in: view, document: document, preserveOriginY: beforeOriginY, log: log)
            let y = firstScrollView(in: view)?.contentView.bounds.origin.y ?? -1
            log.debug(.viewmode, "applyTransition late re-assert → clipY=\(y)")
        }
    }

    /// NAV-1/NAV-2 — an arrow-key STEP within a CONTINUOUS mode: scroll so the
    /// target page/row's top sits `ReaderLayout.margin` (view points) below the
    /// viewport top, overriding PDFKit's default one-inset landing (Fact 4). For
    /// NAV-1 (`centeredIfFits == true`) a page that fully fits the viewport is
    /// vertically CENTERED with equal top/bottom margins instead (the fit-height
    /// case); NAV-2 rows always pin the top at M. The scroll target is computed
    /// from the live documentView page-point geometry (non-flipped) and re-asserted
    /// with the rewind pattern (sync + deferred + late) so a large scroll that
    /// needs a second hop still settles. Instrumented via `.nav`.
    @MainActor
    public static func stepContinuous(
        toPageIndex targetIndex: Int, centeredIfFits: Bool,
        in view: PDFView, log: AppLogger
    ) {
        guard let document = view.document else { return }
        let clamped = min(max(0, targetIndex), max(0, document.pageCount - 1))
        // Make the target page/row current so `currentPage` (and the
        // PDFViewPageChanged breadcrumb) tracks the step — a bare scroll via
        // setBoundsOrigin does NOT update PDFKit's currentPage. go(to:) lands
        // PDFKit's own position (one inset down); the scroll override below
        // corrects it to margin M on the SAME turn, before the runloop yields,
        // so there is no visible intermediate jump.
        if let page = document.page(at: clamped) { view.go(to: page) }
        view.layoutDocumentView()
        assertStepScroll(toPageIndex: clamped, centeredIfFits: centeredIfFits, in: view, log: log)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.layoutDocumentView()
            assertStepScroll(toPageIndex: clamped, centeredIfFits: centeredIfFits, in: view, log: log)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak view] in
            guard let view else { return }
            assertStepScroll(toPageIndex: clamped, centeredIfFits: centeredIfFits, in: view, log: log)
        }
    }

    /// One pass of the NAV step: recompute the target clip origin.y from LIVE
    /// geometry (docView frame can grow across relayout passes) and set it,
    /// keeping PDFKit's horizontally-centered x.
    @MainActor
    private static func assertStepScroll(
        toPageIndex index: Int, centeredIfFits: Bool, in view: PDFView, log: AppLogger
    ) {
        guard
            let document = view.document,
            let page = document.page(at: index),
            let clip = firstScrollView(in: view)?.contentView,
            let docView = clip.documentView
        else { return }
        let scale = view.scaleFactor
        let margin = ReaderLayout.margin
        // The target page rect in documentView (page-point) space — absolute, so
        // it is stable regardless of the current scroll offset.
        let pageRectView = view.convert(page.bounds(for: view.displayBox), from: page)
        let pageRectDoc = docView.convert(pageRectView, from: view)
        let onScreenPageH = pageRectView.height   // == pageH · scale
        let topGap = centeredIfFits
            ? ViewModePlanner.stepTopGap(
                onScreenPageHeight: onScreenPageH, viewportHeight: view.bounds.height, margin: margin)
            : margin
        let targetY = ViewModePlanner.clipOriginY(
            pageTopDoc: pageRectDoc.maxY, docHeight: docView.frame.height,
            viewportHeight: view.bounds.height, topGap: topGap, scale: scale)
        var origin = clip.bounds.origin           // keep PDFKit's centered x
        origin.y = targetY
        clip.setBoundsOrigin(origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        log.debug(
            .nav,
            "stepScroll page=\(index) scale=\(scale) topGap=\(topGap) "
                + "pageTopDoc=\(pageRectDoc.maxY) docH=\(docView.frame.height) "
                + "onScreenPageH=\(onScreenPageH) vp=\(view.bounds.size) → origin.y=\(targetY)"
        )
    }

    /// Realizes a `ScrollAnchor` as a concrete clip origin. `preserveY` keeps
    /// the pre-switch y; `pageTopMargin` scrolls so the page's top sits
    /// `ReaderLayout.margin` (view points) below the viewport top — computed
    /// from the documentView's page-point geometry (non-flipped: content top =
    /// max y; the visible region's top maps to the viewport top).
    @MainActor
    private static func resolveAnchor(
        _ transition: ModeTransition, in view: PDFView, document: PDFDocument,
        preserveOriginY: CGFloat, log: AppLogger
    ) {
        guard let clip = firstScrollView(in: view)?.contentView else { return }
        switch transition.scrollAnchor {
        case .preserveY:
            var origin = clip.bounds.origin       // keep PDFKit's centered x
            origin.y = preserveOriginY
            clip.setBoundsOrigin(origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)

        case .pageTopMargin(let pageIndex):
            let clamped = min(max(0, pageIndex), max(0, document.pageCount - 1))
            guard
                let page = document.page(at: clamped),
                let docView = clip.documentView
            else { return }
            let isContinuous = view.displayMode == .singlePageContinuous
                || view.displayMode == .twoUpContinuous
            // Fixed modes only lay out the current page/spread — make the target
            // current first so its geometry is valid to convert.
            if !isContinuous { view.go(to: page) }

            let scale = view.scaleFactor
            let margin = ReaderLayout.margin
            // Page rect in documentView (page-point) space — absolute, so it is
            // stable regardless of the current scroll offset.
            let pageRectView = view.convert(page.bounds(for: view.displayBox), from: page)
            let pageRectDoc = docView.convert(pageRectView, from: view)
            let clipHeight = clip.bounds.height   // page points (viewportH / scale)
            // Visible-region top (doc coords) maps to the viewport top; put the
            // page top margin/scale page-points below it. Solve for origin.y:
            //   pageTopDoc = (origin.y + clipHeight) − margin/scale
            let targetY = pageRectDoc.maxY - clipHeight + margin / scale
            let maxOriginY = max(0, docView.frame.height - clipHeight)
            var origin = clip.bounds.origin       // keep PDFKit's centered x
            origin.y = min(max(0, targetY), maxOriginY)
            clip.setBoundsOrigin(origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
            log.debug(
                .viewmode,
                "resolveAnchor pageTopMargin(\(clamped)) scale=\(scale) "
                    + "pageRectDoc=\(pageRectDoc) docH=\(docView.frame.height) "
                    + "clipH=\(clipHeight) targetY=\(targetY) maxY=\(maxOriginY) "
                    + "→ set origin.y=\(origin.y)"
            )
        }
    }

    /// Sets the internal clip view's vertical scroll to `originY` (page points),
    /// keeping PDFKit's horizontally-centered x.
    @MainActor
    private static func restoreVerticalScroll(in view: PDFView, to originY: CGFloat) {
        guard let clip = firstScrollView(in: view)?.contentView else { return }
        var origin = clip.bounds.origin      // keep PDFKit's centered x
        origin.y = originY
        clip.setBoundsOrigin(origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// PDFKit hosts its content in an internal `NSScrollView`; its `contentView`
    /// (clip view) bounds origin is the scroll offset in page points.
    @MainActor
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scroll = subview as? NSScrollView { return scroll }
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
#endif
