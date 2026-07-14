#if os(macOS)
import AppKit
import PDFKit
import Testing

/// PROBES, not unit tests: each test measures real PDFKit behavior on THIS
/// macOS and prints the numbers (run `swift test --filter PDFKitFacts` and
/// read the output). The findings are documented in docs/PDFKIT-FACTS.md;
/// the assertions pin them so a macOS/PDFKit update that changes layout
/// behavior fails loudly instead of silently breaking the view-mode math.
///
/// Geometry note: measurements are taken in DOCUMENT-VIEW coordinates (page
/// points, non-flipped: y=0 is the BOTTOM, content top = max y) — converting
/// through PDFView's flipped view space invites sign errors.
@MainActor
@Suite(.serialized) struct PDFKitFactsTests {
    private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }

    /// FACT 1 — pageBreakMargins are PAGE-SPACE (the visual gap scales with
    /// zoom): the documentView frame (page points) grows by top+bottom per
    /// page / left+right per column, and is invariant under scaleFactor.
    @Test func pageBreakMarginsArePageSpace() {
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 3))
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 800, height: 1000),
            mode: .singlePageContinuous)
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.layoutDocumentView()
        PDFKitProbe.settle()

        let frame1 = view.documentView!.frame.size
        view.scaleFactor = 2.0
        view.layoutDocumentView()
        PDFKitProbe.settle()
        let frame2 = view.documentView!.frame.size

        print("PROBE pageBreakMargins: docView@scale1=\(frame1) @scale2=\(frame2) " +
              "(3×400x600, insets 10 → expect 420 × 1860)")

        #expect(frame1 == frame2,
                "docView frame changed with scaleFactor — coordinate model shifted")
        #expect(near(frame1.height, 1860), "row layout no longer pageH + top + bottom per page")
        #expect(near(frame1.width, 420), "column no longer pageW + left + right")
    }

    /// FACT 2 — two-up horizontal geometry, derived by varying the insets.
    /// Measured (macOS 26): with symmetric insets i, the documentView width
    /// is 2·pageW + 4i − 1 and the INNER gap between the pair is 2i − 1 pt.
    /// There is a constant −1 pt offset at the spine (even at i = 0 the pages
    /// overlap by 1 pt, docWidth 799 not 800) — so a uniform on-screen gap M
    /// between the pair is achieved with left/right inset (M + 1) / 2, not
    /// M / 2. Outer edges get i each; row height = pageH + 2i.
    @Test func twoUpGapAndOuterEdges() {
        func measure(inset: CGFloat) -> (docWidth: CGFloat, gap: CGFloat) {
            let doc = PDFKitProbe.makeDocument(
                pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 4))
            let (view, _) = PDFKitProbe.makeView(
                document: doc, viewport: CGSize(width: 1200, height: 800), mode: .twoUp)
            view.displaysPageBreaks = true
            view.pageBreakMargins = NSEdgeInsets(
                top: inset, left: inset, bottom: inset, right: inset)
            view.scaleFactor = 1.0
            view.layoutDocumentView()
            PDFKitProbe.settle()
            let docView = view.documentView!
            let page0 = doc.page(at: 0)!
            let page1 = doc.page(at: 1)!
            // Measure the on-screen gap from the pages' view-space rects
            // (scale = 1 here, so view points == page points).
            let v0 = view.convert(page0.bounds(for: view.displayBox), from: page0)
            let v1 = view.convert(page1.bounds(for: view.displayBox), from: page1)
            return (docView.frame.width, v1.minX - v0.maxX)
        }

        let at0 = measure(inset: 0)
        let at10 = measure(inset: 10)
        let at20 = measure(inset: 20)
        print("PROBE twoUp: inset0=\(at0) inset10=\(at10) inset20=\(at20) " +
              "(2×400w pages, scale 1)")

        #expect(near(at0.gap, -1) && near(at0.docWidth, 799),
                "two-up spine offset (−1) at zero insets changed")
        #expect(near(at10.gap, 19) && near(at10.docWidth, 859),
                "two-up inner gap formula (2i−1) changed at inset 10")
        #expect(near(at20.gap, 39) && near(at20.docWidth, 919),
                "two-up inner gap formula (2i−1) changed at inset 20")
    }

    /// FACT 3 — enlarged page boxes ARE honored: setBounds with a media+crop
    /// box larger than the content reports back verbatim and renders the
    /// excess as blank padding (content untouched). This is the mechanism
    /// gate for mixed-size alignment (issue #17) and trim-compose.
    @Test func enlargedPageBoxesAreHonored() {
        let doc = PDFKitProbe.makeDocument(pageSizes: [CGSize(width: 400, height: 600)])
        let page = doc.page(at: 0)!
        let enlarged = CGRect(x: -100, y: 0, width: 500, height: 600)
        page.setBounds(enlarged, for: .mediaBox)
        page.setBounds(enlarged, for: .cropBox)

        let reported = page.bounds(for: .cropBox)
        let image = page.thumbnail(of: CGSize(width: 500, height: 600), for: .cropBox)
        var bitmap: NSBitmapImageRep?
        if let tiff = image.tiffRepresentation {
            bitmap = NSBitmapImageRep(data: tiff)
        }
        func brightness(atX x: Int) -> CGFloat {
            guard let bitmap else { return -1 }
            let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2) ?? .black
            return color.brightnessComponent
        }
        let padding = brightness(atX: 40)   // inside the 100pt-wide new strip
        let content = brightness(atX: 300)  // inside the original page

        print("PROBE enlargedBoxes: reported=\(reported) thumb=\(image.size) " +
              "paddingBrightness=\(padding) contentBrightness=\(content)")

        #expect(reported == enlarged, "setBounds(larger) no longer honored")
        #expect(padding > 0.9, "enlarged-box padding did not render blank")
        #expect(content < 0.1, "original content missing after box enlargement")
    }

    /// FACT 4 — goToNextPage in single-continuous scrolls so the target
    /// page's TOP sits exactly one top-inset below the viewport top
    /// (measured in documentView coordinates: visibleTop − pageTop = topInset
    /// at scale 1). Horizontal centering of narrow content shows up as a
    /// NEGATIVE clip-origin x. Drives NAV-1/NAV-2 (issue #19).
    @Test func goToNextPageAnchorsTopBelowInset() {
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 5))
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 800, height: 500),
            mode: .singlePageContinuous)
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.scaleFactor = 1.0
        view.layoutDocumentView()
        PDFKitProbe.settle()

        view.goToNextPage(nil)
        PDFKitProbe.settle(6)

        let clip = PDFKitProbe.scrollView(in: view)!.contentView
        let docHeight = view.documentView!.frame.height   // 5×620 = 3100
        // Non-flipped docView: page index i's TOP (content, below its inset)
        // sits at docHeight − i×620 − 10.
        let page1Top = docHeight - 620 - 10
        let visibleTop = clip.bounds.origin.y + clip.bounds.height
        let topGap = visibleTop - page1Top
        let currentIndex = doc.index(for: view.currentPage!)

        print("PROBE goToNextPage: current=\(currentIndex) clip=\(clip.bounds) " +
              "docHeight=\(docHeight) topGap=\(topGap)")

        #expect(currentIndex == 1)
        #expect(near(topGap, 10, 1.0),
                "goToNextPage no longer lands the page top one inset below the viewport top")
        #expect(clip.bounds.origin.x < 0,
                "narrow content no longer centers via negative clip-origin x")
    }

    /// FACT 5 — the internal NSScrollView ACCEPTS contentInsets, but
    /// PDFKit's go(to:) landing does NOT cleanly compensate for them: with a
    /// 24pt top inset a page-top destination lands ~14pt off the naive
    /// no-inset target and is NOT the fully-compensated position either
    /// (Skim subtracts contentInsets.top manually for this reason). Takeaway:
    /// don't rely on contentInsets for outer margins — compute scroll targets
    /// explicitly. This test pins the qualitative fact (insets stick; landing
    /// ≠ fully-compensated) rather than the fragile exact offset.
    @Test func destinationMathIgnoresContentInsets() {
        let doc = PDFKitProbe.makeDocument(
            pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 2))
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 800, height: 500),
            mode: .singlePageContinuous)
        guard let scroll = PDFKitProbe.scrollView(in: view) else {
            Issue.record("no internal NSScrollView found")
            return
        }
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.scaleFactor = 1.0
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 0)
        view.layoutDocumentView()
        PDFKitProbe.settle()

        view.go(to: PDFDestination(page: doc.page(at: 0)!, at: CGPoint(x: 0, y: 600)))
        PDFKitProbe.settle(6)

        let clip = scroll.contentView
        let docHeight = view.documentView!.frame.height    // 2×620 = 1240
        let noInsetTarget = docHeight - clip.bounds.height  // 740
        let fullyCompensated = noInsetTarget + 24           // 764

        print("PROBE contentInsets: insets.top=24 clip=\(clip.bounds) " +
              "docHeight=\(docHeight) noInsetTarget=\(noInsetTarget) " +
              "fullyCompensated=\(fullyCompensated)")

        #expect(scroll.contentInsets.top == 24, "contentInsets assignment did not stick")
        #expect(!near(clip.bounds.origin.y, fullyCompensated, 3.0),
                "go(to:) now fully honors contentInsets — contentInset-based margins are viable, revisit")
    }
}
#endif
