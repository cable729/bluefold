#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Creates a real PDF file with one page per string, drawn via Core Text.
private func makeTextPDF(pageTexts: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("OutlineFindTests-\(UUID().uuidString).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard
        let consumer = CGDataConsumer(url: url as CFURL),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        fatalError("cannot create PDF context")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    for text in pageTexts {
        context.beginPDFPage(nil)
        if !text.isEmpty {
            let attributed = NSAttributedString(
                string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            )
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

@Suite("Outline tree")
@MainActor
struct OutlineNodeTests {
    private func makeDocumentWithOutline() -> PDFDocument {
        let document = PDFDocument()
        for i in 0..<4 {
            document.insert(PDFPage(), at: i)
        }

        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter 1: Vector Spaces"
        chapter.destination = PDFDestination(page: document.page(at: 1)!, at: CGPoint(x: 0, y: 700))
        root.insertChild(chapter, at: 0)

        let section = PDFOutline()
        section.label = "1.A  R^n and C^n"
        section.destination = PDFDestination(page: document.page(at: 2)!, at: CGPoint(x: 0, y: 650))
        chapter.insertChild(section, at: 0)

        document.outlineRoot = root
        return document
    }

    @Test func buildsNestedTreeWithEntries() {
        let document = makeDocumentWithOutline()
        let tree = OutlineNode.tree(from: document)

        #expect(tree.count == 1)
        #expect(tree[0].label == "Chapter 1: Vector Spaces")
        #expect(tree[0].entry?.pageIndex == 1)

        let children = tree[0].children
        #expect(children?.count == 1)
        #expect(children?[0].label == "1.A  R^n and C^n")
        #expect(children?[0].entry?.pageIndex == 2)
        #expect(children?[0].children == nil)
    }

    @Test func documentWithoutOutlineGivesEmptyTree() {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        #expect(OutlineNode.tree(from: document).isEmpty)
    }
}

@Suite("FindController")
@MainActor
struct FindControllerTests {
    private func waitForSearchEnd(_ find: FindController) async throws {
        for _ in 0..<200 {
            if !find.isSearching { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("search did not finish in time")
    }

    @Test func findsMatchesAcrossPages() async throws {
        let url = try makeTextPDF(pageTexts: [
            "a linear map is a function",
            "every linear operator has an eigenvalue here",
            "nothing relevant",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))

        let find = FindController()
        find.search("linear", in: document)
        try await waitForSearchEnd(find)

        #expect(find.matches.count == 2)
        #expect(find.didSearch)
        #expect(find.currentIndex == 0)
    }

    @Test func advanceWrapsAround() async throws {
        let url = try makeTextPDF(pageTexts: ["alpha alpha", "alpha"])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))

        let find = FindController()
        find.search("alpha", in: document)
        try await waitForSearchEnd(find)
        #expect(find.matches.count == 3)

        find.advance(by: 1)
        #expect(find.currentIndex == 1)
        find.advance(by: -2)
        #expect(find.currentIndex == 2)  // wrapped backwards
        find.advance(by: 1)
        #expect(find.currentIndex == 0)  // wrapped forwards
    }

    @Test func cancelClearsState() async throws {
        let url = try makeTextPDF(pageTexts: ["beta"])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))

        let find = FindController()
        find.search("beta", in: document)
        try await waitForSearchEnd(find)
        #expect(!find.matches.isEmpty)

        find.cancel()
        #expect(find.matches.isEmpty)
        #expect(find.currentIndex == nil)
        #expect(!find.didSearch)
    }

    @Test func noMatchesLeavesEmptyState() async throws {
        let url = try makeTextPDF(pageTexts: ["gamma delta"])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))

        let find = FindController()
        find.search("zeta", in: document)
        try await waitForSearchEnd(find)
        #expect(find.matches.isEmpty)
        #expect(find.didSearch)
        #expect(find.current == nil)
    }
}
#endif
