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
