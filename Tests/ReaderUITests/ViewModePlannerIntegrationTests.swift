#if os(macOS)
import AppKit
import CoreGraphics
import Dependencies
import PDFKit
import ReaderCore
import Testing
@testable import ReaderUI

/// One live-view check that the PURE planner math (ViewModePlannerTests) holds
/// against a REAL PDFView: apply a standardPlan to an offscreen twoUpContinuous
/// view and measure the on-screen inner gap between the pair. Ties the paper
/// math to PDFKit's actual `pageBreakMargins` behavior (docs/PDFKIT-FACTS.md
/// Fact 2). Tolerance ~1.5pt absorbs the backing-scale-dependent sub-pixel
/// spine loss that Fact 2 documents (never a per-machine pixel constant).
@MainActor
@Suite(.serialized) struct ViewModePlannerIntegrationTests {
    /// GIVEN 4 pages 400×600 in a 824×1000 viewport, mode .doubleContinuous.
    /// WHEN standardPlan is applied to the live view:
    ///   scale = (824 - 3·8)/(2·400) = 800/800 = 1.0.
    ///   inset = 8/(2·1) = 4 (page points).
    /// THEN the measured inner gap = 2·inset·scale = 8 ≈ ReaderLayout.margin
    ///   (at scale 1, view points == page points).
    @Test func standardPlanRendersInnerGapEqualToMargin() {
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 4))
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 824, height: 1000),
            mode: .twoUpContinuous)

        let plan = ViewModePlanner.standardPlan(
            mode: .doubleContinuous,
            viewport: CGSize(width: 824, height: 1000),
            pageSize: CGSize(width: 400, height: 600))
        #expect(plan.scaleFactor == 1.0)
        #expect(plan.pageBreakMarginInset == 4)

        let box = CapturedLogs()
        withDependencies {
            $0.appLogger = .captured(into: box)
        } operation: {
            LayoutApplier.apply(plan, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)

        let page0 = doc.page(at: 0)!
        let page1 = doc.page(at: 1)!
        let v0 = view.convert(page0.bounds(for: view.displayBox), from: page0)
        let v1 = view.convert(page1.bounds(for: view.displayBox), from: page1)
        let innerGap = v1.minX - v0.maxX

        print("PROBE standardPlan twoUpContinuous: scale=\(view.scaleFactor) " +
              "inset=\(plan.pageBreakMarginInset) innerGap=\(innerGap) " +
              "(expect ≈ \(ReaderLayout.margin))")

        #expect(abs(innerGap - ReaderLayout.margin) <= 1.5,
                "live inner gap \(innerGap) ≠ ReaderLayout.margin \(ReaderLayout.margin)")
        // The applier set an explicit scale (autoScales off) from the plan.
        #expect(view.autoScales == false)
        #expect(abs(view.scaleFactor - plan.scaleFactor) <= 0.001)
        #expect(!box.messages(.layout).isEmpty, "applier did not instrument via .layout")
    }
}
#endif
