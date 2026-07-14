#if os(macOS)
import AppKit
import CoreGraphics
import Dependencies
import PDFKit
import ReaderCore
import Testing
@testable import ReaderUI

/// NAV-1 / NAV-2 (Phase 8) — arrow-key stepping in the CONTINUOUS modes, driven
/// end-to-end through the live `ActivePDFView.Coordinator`. The pure scroll math
/// is pinned exactly in ViewModePlannerTests; here we prove the Coordinator +
/// LayoutApplier land the real PDFView the same way: the stepped-to page/row
/// becomes current and its top sits ≈ M below the viewport top (NOT PDFKit's own
/// one-inset landing — Fact 4).
///
/// Tolerances ≥1.5pt and index/gap assertions only (never sub-pixel splits) —
/// the CI runner is 1× and carries a backing-scale sub-pixel term
/// (docs/PDFKIT-FACTS.md). `@Suite(.serialized)` + a document-detach teardown
/// keep this off the known offscreen-PDFView parallel-teardown SIGSEGV race.
@MainActor
@Suite(.serialized) struct NavigationStepTests {
    /// Builds a `ReaderPDFView` hosted in an offscreen window (PDFKit lays out
    /// lazily; an unhosted view reports empty geometry).
    private static func makeReaderView(
        document: PDFDocument, viewport: CGSize, mode: PDFDisplayMode
    ) -> (ReaderPDFView, NSWindow) {
        let view = ReaderPDFView(frame: CGRect(origin: .zero, size: viewport))
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: viewport),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false     // we hold a strong ref; teardown calls close()
        window.contentView = view
        view.displayMode = mode
        view.document = document
        view.layoutDocumentView()
        return (view, window)
    }

    private static func coordinator(for view: ReaderPDFView) -> ActivePDFView.Coordinator {
        let model = ReaderWindowModel(provider: DocumentProvider(), store: nil)
        let coordinator = ActivePDFView.Coordinator(tabID: UUID(), model: model)
        coordinator.view = view
        return coordinator
    }

    /// NAV-1 — single-page-continuous forward arrow lands the NEXT page's top at
    /// margin M below the viewport top (like fixed mode), NOT PDFKit's default
    /// one-inset landing.
    ///
    /// GIVEN 12 pages 400×600 in an 816×1000 viewport, singlePageContinuous at the
    ///   width-fit scale 2.0 (inset 2 → M=8 on screen), showing page 5. The page
    ///   is taller than the viewport (600·2 = 1200 > 1000), so the step pins the
    ///   top at M (no fit-height centering).
    /// WHEN the Coordinator's goToNextPage() runs:
    /// THEN page 6 becomes current and its on-screen top gap ≈ M.
    @Test func nav1_singleContinuous_forwardStep_landsNextPageTopAtMargin() {
        let m = ReaderLayout.margin
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 12))
        let (view, window) = Self.makeReaderView(
            document: doc, viewport: CGSize(width: 816, height: 1000),
            mode: .singlePageContinuous)
        defer { PDFKitProbe.teardown(view, window) }
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        view.autoScales = false
        view.scaleFactor = 2.0
        view.go(to: doc.page(at: 5)!)
        PDFKitProbe.settle()

        let coordinator = Self.coordinator(for: view)
        let box = CapturedLogs()
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            coordinator.goToNextPage()
        }
        // Settle PAST the applier's 0.25s late re-assert. settle(8)=0.16s measured
        // the PRE-correction position, which is already correct for single-page
        // nav but off on the 1× CI runner for a two-up row step (#53). settle(20)
        // ≈0.4s lets the deferred re-assert fire → the final settled position.
        PDFKitProbe.settle(20)

        let page6 = doc.page(at: 6)!
        let rect = view.convert(page6.bounds(for: view.displayBox), from: page6)
        let topGap = view.bounds.height - rect.maxY
        let currentIndex = doc.index(for: view.currentPage!)
        print("PROBE nav1 step: currentIndex=\(currentIndex) topGap=\(topGap) " +
              "(expect page 6, topGap ≈ \(m))")

        #expect(currentIndex == 6, "forward step did not land on page 6: \(currentIndex)")
        #expect(abs(topGap - m) <= 1.5, "page-6 top not at margin M: topGap=\(topGap)")
        #expect(!box.messages(.nav).isEmpty, "step did not instrument via .nav")
    }

    /// NAV-1 — the backward arrow is the inverse: from page 5 it lands page 4's
    /// top at margin M.
    @Test func nav1_singleContinuous_backwardStep_landsPreviousPageTopAtMargin() {
        let m = ReaderLayout.margin
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 12))
        let (view, window) = Self.makeReaderView(
            document: doc, viewport: CGSize(width: 816, height: 1000),
            mode: .singlePageContinuous)
        defer { PDFKitProbe.teardown(view, window) }
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        view.autoScales = false
        view.scaleFactor = 2.0
        view.go(to: doc.page(at: 5)!)
        PDFKitProbe.settle()

        let coordinator = Self.coordinator(for: view)
        withDependencies { $0.appLogger = .noop } operation: {
            coordinator.goToPreviousPage()
        }
        // Settle PAST the applier's 0.25s late re-assert. settle(8)=0.16s measured
        // the PRE-correction position, which is already correct for single-page
        // nav but off on the 1× CI runner for a two-up row step (#53). settle(20)
        // ≈0.4s lets the deferred re-assert fire → the final settled position.
        PDFKitProbe.settle(20)

        let page4 = doc.page(at: 4)!
        let rect = view.convert(page4.bounds(for: view.displayBox), from: page4)
        let topGap = view.bounds.height - rect.maxY
        let currentIndex = doc.index(for: view.currentPage!)
        print("PROBE nav1 back step: currentIndex=\(currentIndex) topGap=\(topGap)")

        #expect(currentIndex == 4, "backward step did not land on page 4: \(currentIndex)")
        #expect(abs(topGap - m) <= 1.5, "page-4 top not at margin M: topGap=\(topGap)")
    }

    /// NAV-2 — two-up-continuous forward arrow advances one ROW (a full spread)
    /// and lands the row's top at margin M.
    ///
    /// GIVEN 12 pages 400×600 in an 824×1000 viewport, twoUpContinuous at the
    ///   two-up width-fit scale 1.0 (inset 4 → M=8 on screen), default pairing,
    ///   showing page 2 (row (2,3)).
    /// WHEN goToNextPage() runs it steps to the next row (4,5):
    /// THEN the current page is in {4,5} and page 4's on-screen top gap ≈ M.
    @Test func nav2_doubleContinuous_forwardStep_advancesOneRow_topAtMargin() {
        let m = ReaderLayout.margin
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 12))
        let (view, window) = Self.makeReaderView(
            document: doc, viewport: CGSize(width: 824, height: 1000),
            mode: .twoUpContinuous)
        defer { PDFKitProbe.teardown(view, window) }
        view.displaysAsBook = false
        view.displaysRTL = false
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        view.autoScales = false
        view.scaleFactor = 1.0
        view.go(to: doc.page(at: 2)!)
        PDFKitProbe.settle()
        #expect(doc.index(for: view.currentPage!) == 2)

        let coordinator = Self.coordinator(for: view)
        let box = CapturedLogs()
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            coordinator.goToNextPage()
        }
        // Settle PAST the applier's 0.25s late re-assert. settle(8)=0.16s measured
        // the PRE-correction position, which is already correct for single-page
        // nav but off on the 1× CI runner for a two-up row step (#53). settle(20)
        // ≈0.4s lets the deferred re-assert fire → the final settled position.
        PDFKitProbe.settle(20)

        let page4 = doc.page(at: 4)!
        let rect = view.convert(page4.bounds(for: view.displayBox), from: page4)
        let topGap = view.bounds.height - rect.maxY
        let currentIndex = doc.index(for: view.currentPage!)
        print("PROBE nav2 row step: currentIndex=\(currentIndex) topGap=\(topGap) " +
              "(expect row 4/5, topGap ≈ \(m))")
        // DIAG (#53): reveal the actual two-up row geometry on the 1× CI runner
        // vs local 2× (where this reads 8.0). If docH / row pitch differs, the
        // pure row-top math is using the wrong pitch for two-up.
        if let docView = view.documentView {
            func docTop(_ i: Int) -> CGFloat {
                let p = doc.page(at: i)!
                return docView.convert(p.bounds(for: view.displayBox), from: p).maxY
            }
            print("PROBE nav2 DIAG: docH=\(docView.frame.height) scale=\(view.scaleFactor) " +
                  "p0Top=\(docTop(0)) p2Top=\(docTop(2)) p4Top=\(docTop(4)) " +
                  "rowPitch02=\(docTop(0) - docTop(2)) rowPitch24=\(docTop(2) - docTop(4)) " +
                  "page4ViewMaxY=\(rect.maxY) vpH=\(view.bounds.height)")
        }

        #expect(currentIndex == 4 || currentIndex == 5,
                "row step did not advance to the (4,5) row: \(currentIndex)")
        #expect(abs(topGap - m) <= 1.5, "row-4 top not at margin M: topGap=\(topGap)")
        #expect(!box.messages(.nav).isEmpty, "row step did not instrument via .nav")
    }
}
#endif
