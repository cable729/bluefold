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

    /// FIT-1 — fit width leaves exactly M left/right AND preserves the vertical
    /// reading position (the y-scroll must NOT jump).
    ///
    /// (a) PURE: single-page fit at viewport 800 wide, page 400 wide, M=8 →
    ///   scale = (800 − 2·8)/400 = 784/400 = 1.96; leftover width
    ///   viewportW − pageW·scale = 800 − 400·1.96 = 800 − 784 = 16 = 2·M.
    ///   (two-up analog: viewportW − 2·pageW·scale = 3·M — asserted in the
    ///   pure ViewModePlannerTests.m4 / fitPlanTwoUp checks.)
    /// (b) INTEGRATION: a single-page-continuous PDFView scrolled to a known
    ///   non-zero y, then fit-width applied AT A DIFFERENT SCALE (1.0 → 1.96).
    ///   The clip-view bounds origin is page-space and scale-independent
    ///   (docs/PDFKIT-FACTS.md), so preserving it keeps the reading position:
    ///   the clip origin.y after apply must equal the origin.y before, ≤1pt.
    @Test func fit1_fitWidth_leavesMarginLeftRight_and_preservesVerticalScroll() {
        let m = ReaderLayout.margin

        // (a) pure — single-page fit width leaves exactly M on each side.
        let plan = ViewModePlanner.fitPlan(
            mode: .singleContinuous, axis: .width,
            viewport: CGSize(width: 800, height: 500),
            pageSize: CGSize(width: 400, height: 600))
        #expect(abs(plan.scaleFactor - 1.96) <= 1e-9)
        #expect(plan.displayMode == ViewMode.singleContinuous.displayModeRaw)
        #expect(800 - 400 * plan.scaleFactor == 2 * m)   // 800 − 784 == 16

        // (b) integration — scroll to a known y, apply fit-width, assert the
        // clip origin.y is unchanged (reading position preserved).
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 5))
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 800, height: 500),
            mode: .singlePageContinuous)
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        view.autoScales = false
        view.scaleFactor = 1.0          // starting scale, DIFFERENT from 1.96
        view.layoutDocumentView()
        PDFKitProbe.settle()

        let clip = PDFKitProbe.scrollView(in: view)!.contentView
        // Scroll to a mid-document y that is valid at both scales (higher scale
        // → smaller clip height → larger max origin, so a scale-1 valid y stays
        // valid). docHeight ≈ 5×608 = 3040; clip.height(scale 1) = 500 → maxY
        // ≈ 2540. 900 is comfortably inside.
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: 900))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        PDFKitProbe.settle()
        let beforeY = clip.bounds.origin.y

        let box = CapturedLogs()
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(
                plan, to: view, log: AppLogger.captured(into: box),
                preserveVerticalScroll: true)
        }
        PDFKitProbe.settle(8)

        let afterY = clip.bounds.origin.y
        print("PROBE fitWidth preserveScroll: beforeY=\(beforeY) afterY=\(afterY) " +
              "scale=\(view.scaleFactor)")

        #expect(abs(view.scaleFactor - 1.96) <= 0.001, "fit-width did not set the fit scale")
        #expect(abs(afterY - beforeY) <= 1.0,
                "fit-width jumped the vertical scroll: \(beforeY) → \(afterY)")
        #expect(!box.messages(.layout).isEmpty, "applier did not instrument via .layout")
    }

    /// FIT-2 — fit height: pageH·scale + 2M == viewport height, current page
    /// re-fitted IN PLACE (no page jump), vertically centered.
    ///
    /// (a) PURE: viewport 1216 tall, page 600 tall, M=8 →
    ///   scale = (1216 − 2·8)/600 = 1200/600 = 2.0; pageH·scale + 2M =
    ///   600·2 + 16 = 1216 == viewportH.
    /// (b) INTEGRATION: a single-page (fixed) view showing page 2; after
    ///   fit-height the current page index is unchanged and the page is
    ///   vertically fitted+centered (on-screen height ≈ 1200, equal top/bottom
    ///   margins ≈ M).
    @Test func fit2_fitHeight_pageHeightPlusTwiceMarginEqualsViewportHeight() {
        let m = ReaderLayout.margin

        // (a) pure — height fit: pageH·s + 2M == viewportH.
        let plan = ViewModePlanner.fitPlan(
            mode: .singleFixed, axis: .height,
            viewport: CGSize(width: 800, height: 1216),
            pageSize: CGSize(width: 400, height: 600))
        #expect(plan.scaleFactor == 2.0)
        #expect(600 * plan.scaleFactor + 2 * m == 1216)

        // (b) integration — fit-height re-fits the CURRENT page without jumping.
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 4))
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 800, height: 1216),
            mode: .singlePage)
        view.go(to: doc.page(at: 2)!)
        PDFKitProbe.settle()
        let beforeIndex = doc.index(for: view.currentPage!)
        #expect(beforeIndex == 2)

        let box = CapturedLogs()
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(
                plan, to: view, log: AppLogger.captured(into: box),
                preserveVerticalScroll: false)
        }
        PDFKitProbe.settle(8)

        let afterIndex = doc.index(for: view.currentPage!)
        let page = view.currentPage!
        let rect = view.convert(page.bounds(for: view.displayBox), from: page)
        let onScreenH = rect.height
        let topGap = view.bounds.height - rect.maxY
        let bottomGap = rect.minY
        print("PROBE fitHeight: beforeIndex=\(beforeIndex) afterIndex=\(afterIndex) " +
              "onScreenH=\(onScreenH) topGap=\(topGap) bottomGap=\(bottomGap)")

        #expect(afterIndex == beforeIndex, "fit-height jumped to a different page")
        #expect(abs(onScreenH - (view.bounds.height - 2 * m)) <= 1.5,
                "page not fitted to height: \(onScreenH)")
        // Centering is exact on a 2× (Retina) backing (top == bottom == M) but
        // rounds to a 1px split on a 1× runner (7/9). The robust invariants:
        // the two gaps sum to 2·M (centering conserves the total), and each is
        // within ~1px of M. Do NOT assert top == bottom tightly — that carries
        // the backing-scale sub-pixel term (see docs/PDFKIT-FACTS.md).
        #expect(abs((topGap + bottomGap) - 2 * m) <= 1.5, "top+bottom margins ≠ 2·M")
        #expect(abs(topGap - m) <= 1.5 && abs(bottomGap - m) <= 1.5,
                "page not vertically centered (top=\(topGap) bottom=\(bottomGap))")
    }

    /// SW-3 (live) — single→double continuous through the applier: the pair's
    /// top-left page must land with its top exactly M below the viewport top,
    /// and STAY there past PDFKit's late relayout pass (the whole point of the
    /// rewind). Proves the pure `pageTopMargin` anchor resolves to a concrete
    /// clip origin the applier can hold.
    ///
    /// GIVEN 12 pages 400×600 in an 824×1000 viewport, singlePageContinuous at a
    ///   known scale, showing page 5 (a MID-document row, so a full viewport of
    ///   content sits below it and the row CAN be scrolled to the top — the last
    ///   rows bottom out against the document end and cannot).
    /// WHEN transition(singleContinuous → doubleContinuous, page 5) is applied:
    ///   twoUpWidthFit = (824-24)/800 = 1.0; pageH·scale = 600 ≤ 1000 (full page
    ///   fits) → anchor = pageTopMargin(leftIndex = (5/2)*2 = 4).
    /// THEN after settling 8 turns, page 4's on-screen top gap ≈ M (≤2pt), the
    ///   current page is the pair (4 or 5), and the clip origin did not drift
    ///   between the immediate and the settled reads (rewind held).
    @Test func sw3_live_singleToDouble_landsPageTopAtMargin_andHolds() {
        let m = ReaderLayout.margin
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 12))
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 824, height: 1000),
            mode: .singlePageContinuous)
        view.autoScales = false
        view.scaleFactor = 2.02                 // singleContinuous width fit
        view.go(to: doc.page(at: 5)!)
        PDFKitProbe.settle()

        let transition = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: 5, currentScale: view.scaleFactor,
            viewport: view.bounds.size,
            pageSize: doc.page(at: 5)!.bounds(for: view.displayBox).size)
        #expect(transition.scaleFactor == 1.0)
        #expect(transition.targetPageIndex == 4)
        #expect(transition.scrollAnchor == .pageTopMargin(pageIndex: 4))

        let clip = PDFKitProbe.scrollView(in: view)!.contentView
        let box = CapturedLogs()
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(transition, to: view, log: AppLogger.captured(into: box))
        }
        let immediateOriginY = clip.bounds.origin.y
        PDFKitProbe.settle(8)                   // past PDFKit's late relayout pass
        let settledOriginY = clip.bounds.origin.y

        let page4 = doc.page(at: 4)!
        let rect = view.convert(page4.bounds(for: view.displayBox), from: page4)
        let topGap = view.bounds.height - rect.maxY
        let currentIndex = doc.index(for: view.currentPage!)
        print("PROBE sw3 live: scale=\(view.scaleFactor) topGap=\(topGap) " +
              "immediateY=\(immediateOriginY) settledY=\(settledOriginY) " +
              "currentIndex=\(currentIndex) (expect topGap ≈ \(m), pair 4/5)")

        #expect(abs(view.scaleFactor - 1.0) <= 0.001)
        #expect(abs(topGap - m) <= 2.0,
                "page-4 top not at margin M: topGap=\(topGap)")
        #expect(currentIndex == 4 || currentIndex == 5,
                "did not land on the pair: currentIndex=\(currentIndex)")
        #expect(abs(settledOriginY - immediateOriginY) <= 1.0,
                "clip drifted after relayout (rewind failed): \(immediateOriginY) → \(settledOriginY)")
        #expect(!box.messages(.viewmode).isEmpty,
                "applier did not instrument via .viewmode")
    }

    /// VM-6 — a PDF whose catalog carries `/PageLayout /TwoPageRight` is read as
    /// a book (`displaysAsBook == true`); PDFKit does NOT auto-apply `/PageLayout`
    /// (docs/PDFKIT-FACTS.md §3), so we read it ourselves from the CGPDF catalog.
    /// The fixture is a hand-assembled minimal PDF (four objects + a byte-exact
    /// xref) so the catalog key is provably present; a `/TwoPageLeft` control
    /// PDF must map to the default.
    @Test func vm6_pageLayoutRight_honored_fromCatalog() {
        let bookDoc = PDFDocument(data: Self.minimalPDF(pageLayout: "TwoPageRight"))
        #expect(bookDoc != nil, "fixture PDF failed to parse")
        #expect(bookDoc?.pageCount == 2, "fixture should have 2 pages")
        let bookLayout = ViewModePlanner.bookLayout(of: bookDoc!)
        #expect(bookLayout.displaysAsBook == true,
                "/TwoPageRight should read as displaysAsBook = true")
        #expect(bookLayout.rtl == false)

        // Control: /TwoPageLeft (odd pages on the left) → not a book.
        let leftDoc = PDFDocument(data: Self.minimalPDF(pageLayout: "TwoPageLeft"))
        #expect(ViewModePlanner.bookLayout(of: leftDoc!) == .default)

        // A PDF with no /PageLayout key at all → default.
        let plainDoc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 2))
        #expect(ViewModePlanner.bookLayout(of: plainDoc) == .default)
    }

    /// A minimal, byte-exact PDF: catalog (obj 1) carries `/PageLayout`, a pages
    /// node (obj 2) and two page objects (3, 4). The xref offsets are computed
    /// from the assembled bytes so CGPDFDocument parses it without rebuilding.
    static func minimalPDF(pageLayout: String) -> Data {
        let bodyObjects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLayout /\(pageLayout) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, obj) in bodyObjects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(obj)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        let count = bodyObjects.count + 1                 // + the free object 0
        pdf += "xref\n0 \(count)\n"
        pdf += "0000000000 65535 f \n"                    // 20 bytes incl. EOL
        for off in offsets {
            pdf += String(format: "%010d 00000 n \n", off)
        }
        pdf += "trailer\n<< /Size \(count) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
#endif
