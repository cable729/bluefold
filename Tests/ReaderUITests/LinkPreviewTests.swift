import CoreGraphics
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("Link preview geometry")
@MainActor
struct LinkPreviewGeometryTests {
    private let crop = CGRect(x: 40, y: 30, width: 400, height: 800)
    private let column = CGRect(x: 72, y: 30, width: 320, height: 800)

    @Test func scrollPointCentersColumnAndAddsHeadroom() {
        let point = LinkPreview.initialScrollPoint(
            destinationPoint: CGPoint(x: 100, y: 500), columnBounds: column, crop: crop,
            contentScale: 1)
        #expect(point.x == column.minX - LinkPreview.gutter)  // gutter left of the column
        #expect(point.y == 500 + LinkPreview.headroom)        // context above the target
    }

    @Test func scrollPointClampsHeadroomToPageTop() {
        let point = LinkPreview.initialScrollPoint(
            destinationPoint: CGPoint(x: 100, y: 790), columnBounds: column, crop: crop,
            contentScale: 1)
        #expect(point.y == crop.maxY)  // never past the page top
    }

    @Test func scrollGutterScalesWithZoom() {
        let point = LinkPreview.initialScrollPoint(
            destinationPoint: CGPoint(x: 100, y: 500), columnBounds: column, crop: crop,
            contentScale: 2)
        #expect(point.x == column.minX - LinkPreview.gutter / 2)  // gutter is in screen pts
    }

    @Test func nilPointAnchorsAtPageTop() {
        let point = LinkPreview.initialScrollPoint(
            destinationPoint: nil, columnBounds: column, crop: crop, contentScale: 1)
        #expect(point.y == crop.maxY)
    }

    @Test func scrollNeverLeavesPageLeft() {
        // A column flush to the crop's left can't gutter past the page edge.
        let flush = CGRect(x: crop.minX, y: 30, width: 320, height: 800)
        let point = LinkPreview.initialScrollPoint(
            destinationPoint: CGPoint(x: 100, y: 500), columnBounds: flush, crop: crop,
            contentScale: 1)
        #expect(point.x == crop.minX)
    }

    @Test func panelWidthTracksColumnThenCaps() {
        // Column narrower than the cap → panel hugs the column + both gutters.
        let narrow = LinkPreview.panelSize(
            columnWidth: 300, contentScale: 1, maxWidth: 560, maxHeight: 600)
        #expect(narrow.width == 300 + LinkPreview.gutter * 2)
        #expect(narrow.height == 600)
        // Column wider than the cap → panel capped (horizontal scroll beyond).
        let wide = LinkPreview.panelSize(
            columnWidth: 800, contentScale: 1, maxWidth: 560, maxHeight: 600)
        #expect(wide.width == 560)
    }

    @Test func panelWidthScalesWithZoom() {
        let zoomed = LinkPreview.panelSize(
            columnWidth: 300, contentScale: 1.5, maxWidth: 900, maxHeight: 600)
        #expect(zoomed.width == 450 + LinkPreview.gutter * 2)  // 300 × 1.5 + gutters
    }

    @Test func remoteTargetIsNotPreviewable() throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 800)
        let consumer = try #require(CGDataConsumer(data: data))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let document = try #require(PDFDocument(data: data as Data))

        let pdfView = PDFView()
        let remote = LinkTarget(
            entry: NavEntry(pageIndex: 0),
            remoteFileURL: URL(fileURLWithPath: "/tmp/other.pdf"))
        #expect(LinkPreview.configure(pdfView, document: document, target: remote, contentScale: 1) == nil)

        let local = LinkTarget(entry: NavEntry(pageIndex: 0, point: CGPoint(x: 50, y: 600)))
        let width = LinkPreview.configure(pdfView, document: document, target: local, contentScale: 1)
        #expect(width != nil)  // same-document → previewable
    }
}
