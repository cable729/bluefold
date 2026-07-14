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
