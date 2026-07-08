#if os(macOS)
import CoreGraphics
import Foundation
import PDFKit
import ReaderCore
import ReaderPersistence
import Testing

@testable import ReaderUI

/// A real PDF file with `pageCount` pages and a Names/Dests name tree —
/// hand-written bytes, because BOTH CGPDFContext destination APIs
/// (`addDestination`, `setDestination`) silently write nothing on macOS 26
/// (probed 2026-07-08; the name never reaches the file).
private func makePDFWithDestinations(
    pageCount: Int,
    destinations: [(name: String, page: Int, point: CGPoint)]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeepLinkTests-\(UUID().uuidString).pdf")

    let pageObjectNumber = { (page: Int) in 4 + page }
    let kids = (0..<pageCount).map { "\(pageObjectNumber($0)) 0 R" }.joined(separator: " ")
    // Name trees must be lexically sorted (PDF 32000 §7.9.6).
    let pairs = destinations.sorted { $0.name < $1.name }.map { dest in
        "(\(dest.name)) [\(pageObjectNumber(dest.page)) 0 R /XYZ \(Int(dest.point.x)) \(Int(dest.point.y)) 0]"
    }.joined(separator: " ")

    var bodies: [String] = []
    bodies.append("<< /Type /Catalog /Pages 2 0 R /Names << /Dests 3 0 R >> >>")
    bodies.append("<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>")
    bodies.append("<< /Names [\(pairs)] >>")
    for _ in 0..<pageCount {
        bodies.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
    }

    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, body) in bodies.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
    }
    let xrefStart = pdf.utf8.count
    pdf += "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
    for offset in offsets {
        pdf += String(format: "%010d 00000 n \n", offset)
    }
    pdf += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n"

    try Data(pdf.utf8).write(to: url)
    return url
}

@Suite("Named destination resolution")
@MainActor
struct NamedDestinationsTests {
    @Test func resolvesNameToPageAndPoint() throws {
        let url = try makePDFWithDestinations(
            pageCount: 5,
            destinations: [
                ("chapter.1", 0, CGPoint(x: 72, y: 700)),
                ("theorem.3.2", 3, CGPoint(x: 100, y: 450)),
            ]
        )
        let document = try #require(PDFDocument(url: url))

        let theorem = NamedDestinations.resolve("theorem.3.2", in: document)
        #expect(theorem?.pageIndex == 3)
        #expect(theorem?.point?.y == 450)

        let chapter = NamedDestinations.resolve("chapter.1", in: document)
        #expect(chapter?.pageIndex == 0)
    }

    @Test func unknownNameResolvesNil() throws {
        let url = try makePDFWithDestinations(
            pageCount: 2,
            destinations: [("known", 1, CGPoint(x: 10, y: 20))]
        )
        let document = try #require(PDFDocument(url: url))
        #expect(NamedDestinations.resolve("unknown", in: document) == nil)
        #expect(NamedDestinations.resolve("", in: document) == nil)
    }

    @Test func documentWithoutNameTreeResolvesNil() {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        #expect(NamedDestinations.resolve("anything", in: document) == nil)
    }
}

@Suite("Deep link routing")
@MainActor
struct DeepLinkRoutingTests {
    @Test func fileURLResolvesThroughContentHash() throws {
        let store = try LibraryStore.inMemory()
        let book = try store.insertLooseBook(
            contentHash: "hash-1", title: "Axler", pathHint: "/books/axler.pdf"
        )
        #expect(book.id != nil)

        let link = try #require(DeepLink(url: URL(string: "pdfreader://open?hash=hash-1&page=3")!))
        let url = DeepLinkRouter.fileURL(for: link, store: store)
        #expect(url?.path == "/books/axler.pdf")
    }

    @Test func unknownHashResolvesNil() throws {
        let store = try LibraryStore.inMemory()
        let link = try #require(DeepLink(url: URL(string: "pdfreader://open?hash=nope")!))
        #expect(DeepLinkRouter.fileURL(for: link, store: store) == nil)
    }

    @Test func destinationBeatsPageFallback() throws {
        let url = try makePDFWithDestinations(
            pageCount: 6,
            destinations: [("section.4", 4, CGPoint(x: 72, y: 700))]
        )
        let document = try #require(PDFDocument(url: url))
        let link = try #require(DeepLink(
            url: URL(string: "pdfreader://open?hash=h&dest=section.4&page=2&x=1&y=2")!
        ))
        let entry = DeepLinkRouter.entry(for: link, in: document)
        #expect(entry?.pageIndex == 4)
    }

    @Test func unresolvableDestinationFallsBackToPage() throws {
        let url = try makePDFWithDestinations(pageCount: 3, destinations: [])
        let document = try #require(PDFDocument(url: url))
        let link = try #require(DeepLink(
            url: URL(string: "pdfreader://open?hash=h&dest=gone&page=2&x=10.0&y=20.0")!
        ))
        let entry = DeepLinkRouter.entry(for: link, in: document)
        #expect(entry == NavEntry(pageIndex: 1, point: CGPoint(x: 10, y: 20)))
    }

    @Test func entryWithoutDocumentUsesPageForm() throws {
        let link = try #require(DeepLink(
            url: URL(string: "pdfreader://open?hash=h&page=7")!
        ))
        #expect(DeepLinkRouter.entry(for: link, in: nil) == NavEntry(pageIndex: 6))
    }
}
#endif
