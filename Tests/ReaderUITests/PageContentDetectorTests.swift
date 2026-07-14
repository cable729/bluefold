#if os(macOS)
import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import ReaderUI

/// Builds a multi-page PDF where every page is `size` and has a solid black
/// block inset by `margin` on all sides — a stand-in for a text column. When
/// `fullBleedPages` is set, those page indices instead fill edge-to-edge (a
/// full-bleed plate) and `narrowPages` draw a skinny central stripe (a cover /
/// mis-detection stand-in the cover guard must reject).
@MainActor
func makeMarginPDF(
    pages: Int,
    size: CGSize,
    margin: CGFloat,
    fullBleedPages: Set<Int> = [],
    narrowPages: Set<Int> = []
) throws -> PDFDocument {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PageContentDetectorTests-\(UUID().uuidString).pdf")
    var mediaBox = CGRect(origin: .zero, size: size)
    let ctx = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
    for index in 0..<pages {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 0, alpha: 1)
        let full = CGRect(origin: .zero, size: size)
        let block: CGRect
        if fullBleedPages.contains(index) {
            block = full
        } else if narrowPages.contains(index) {
            // A thin central stripe: ~20% of the page width — below the cover
            // guard, so the detector must return nil for it.
            block = CGRect(x: size.width * 0.4, y: margin,
                           width: size.width * 0.2, height: size.height - 2 * margin)
        } else {
            block = full.insetBy(dx: margin, dy: margin)
        }
        ctx.fill(block)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return try #require(PDFDocument(url: url))
}

/// Ported from the old branch's `PageContentCropTests` (9f863a5): the raw-CG
/// ink detector that finds a page's printed content box off the PDFKit theme
/// path. Phase 7 re-uses the DETECTION core; application now goes through
/// `PageBoxStore` (crop), per page (TRIM-6), so the detector's public API is
/// per-page `contentBox(of:)` rather than the old document-wide crop.
@Suite("PageContentDetector — per-page ink detection")
@MainActor
struct PageContentDetectorTests {
    private let size = CGSize(width: 480, height: 640)

    @Test("Loose margins detect a tightened content box")
    func detectsWideMargins() throws {
        let doc = try makeMarginPDF(pages: 20, size: size, margin: 90)
        let page = try #require(doc.page(at: 5))
        let box = try #require(PageContentDetector.contentBox(of: page))
        // Ink spans [90, 390] (300 wide). Left pad extends leftward; width grows
        // by left + right padding.
        #expect(abs(box.minX - (90 - PageContentDetector.leftPadding)) <= 3)
        #expect(abs(box.width
            - (300 + PageContentDetector.leftPadding + PageContentDetector.rightPadding)) <= 4)
        #expect(box.width < size.width)  // genuinely tightened
    }

    @Test("Already-tight pages return nil (nothing to reclaim)")
    func skipsTightMargins() throws {
        // 10pt margins are smaller than the padding target — nothing worth
        // trimming, so the detector declines (page left exactly as shipped).
        let doc = try makeMarginPDF(pages: 20, size: size, margin: 10)
        let page = try #require(doc.page(at: 5))
        #expect(PageContentDetector.contentBox(of: page) == nil)
    }

    @Test("A full-bleed page returns nil (nothing to reclaim)")
    func skipsFullBleed() throws {
        let doc = try makeMarginPDF(pages: 20, size: size, margin: 90, fullBleedPages: [7])
        let page = try #require(doc.page(at: 7))
        #expect(PageContentDetector.contentBox(of: page) == nil)
    }

    @Test("A too-narrow content stripe is rejected by the cover guard")
    func coverGuardRejectsNarrowContent() throws {
        let doc = try makeMarginPDF(pages: 20, size: size, margin: 90, narrowPages: [3])
        let page = try #require(doc.page(at: 3))
        #expect(PageContentDetector.contentBox(of: page) == nil)
    }

    @Test("A blank page returns nil")
    func blankPageReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(origin: .zero, size: size)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let doc = try #require(PDFDocument(url: url))
        #expect(PageContentDetector.contentBox(of: try #require(doc.page(at: 0))) == nil)
    }

    @Test("Detection is cached (second call returns the same box)")
    func detectionIsCached() throws {
        let doc = try makeMarginPDF(pages: 4, size: size, margin: 90)
        let page = try #require(doc.page(at: 1))
        let first = PageContentDetector.contentBox(of: page)
        let second = PageContentDetector.contentBox(of: page)
        #expect(first == second)
    }
}
#endif
