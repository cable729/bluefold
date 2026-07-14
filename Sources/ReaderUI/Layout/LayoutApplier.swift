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
    @MainActor
    public static func apply(_ plan: LayoutPlan, to view: PDFView, log: AppLogger) {
        let inset = plan.pageBreakMarginInset
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(
            top: inset, left: inset, bottom: inset, right: inset)
        view.autoScales = false
        view.scaleFactor = plan.scaleFactor

        log.debug(
            .layout,
            "applyLayoutPlan mode=\(plan.displayMode) inset=\(inset) "
                + "scale=\(plan.scaleFactor) vp=\(view.bounds.size) "
                + "→ liveScale=\(view.scaleFactor) autoScales=\(view.autoScales)"
        )

        // Defer one runloop: PDFKit centers content narrower than the pane on
        // the next layout pass, so forcing it here (before the scale settles)
        // leaves narrow pages pinned left.
        DispatchQueue.main.async { [weak view] in
            view?.layoutDocumentView()
        }
    }
}
#endif
