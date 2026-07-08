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

@Suite("Outline breadcrumb path")
@MainActor
struct OutlineDeepestPathTests {
    /// 8 pages. Outline:
    ///   Part I (no destination)
    ///     Chapter 1 (p.1)
    ///       1.A Rⁿ and Cⁿ (p.2)
    ///         Complex Numbers (p.3)
    ///   Chapter 2 (p.5)
    private func makeOutlinedDocument() -> PDFDocument {
        let document = PDFDocument()
        for i in 0..<8 {
            document.insert(PDFPage(), at: i)
        }
        func node(_ label: String, page: Int?) -> PDFOutline {
            let outline = PDFOutline()
            outline.label = label
            if let page {
                outline.destination = PDFDestination(
                    page: document.page(at: page)!, at: CGPoint(x: 0, y: 700)
                )
            }
            return outline
        }
        let root = PDFOutline()
        let part = node("Part I", page: nil)
        let chapter1 = node("Chapter 1", page: 1)
        let sectionA = node("1.A Rⁿ and Cⁿ", page: 2)
        let complex = node("Complex Numbers", page: 3)
        let chapter2 = node("Chapter 2", page: 5)
        root.insertChild(part, at: 0)
        root.insertChild(chapter2, at: 1)
        part.insertChild(chapter1, at: 0)
        chapter1.insertChild(sectionA, at: 0)
        sectionA.insertChild(complex, at: 0)
        document.outlineRoot = root
        return document
    }

    private func tree() -> [OutlineNode] {
        OutlineNode.tree(from: makeOutlinedDocument())
    }

    @Test func emptyOutlineGivesEmptyPath() {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let nodes = OutlineNode.tree(from: document)
        #expect(OutlineNode.deepestPath(in: nodes, atOrBefore: 0).isEmpty)
        #expect(OutlineNode.deepestPath(in: [], atOrBefore: 3).isEmpty)
    }

    @Test func pageBeforeFirstSectionGivesEmptyPath() {
        #expect(OutlineNode.deepestPath(in: tree(), atOrBefore: 0).isEmpty)
    }

    @Test func nestedSectionGivesFullAncestorPath() {
        #expect(
            OutlineNode.deepestPath(in: tree(), atOrBefore: 3)
                == ["Part I", "Chapter 1", "1.A Rⁿ and Cⁿ", "Complex Numbers"]
        )
        // Pages after the subsection but before the next chapter stay in it.
        #expect(
            OutlineNode.deepestPath(in: tree(), atOrBefore: 4)
                == ["Part I", "Chapter 1", "1.A Rⁿ and Cⁿ", "Complex Numbers"]
        )
    }

    @Test func ancestorWithoutDestinationStillContributesLabel() {
        #expect(OutlineNode.deepestPath(in: tree(), atOrBefore: 1) == ["Part I", "Chapter 1"])
        #expect(
            OutlineNode.deepestPath(in: tree(), atOrBefore: 2)
                == ["Part I", "Chapter 1", "1.A Rⁿ and Cⁿ"]
        )
    }

    @Test func hitAfterLastSectionMapsToLastSection() {
        #expect(OutlineNode.deepestPath(in: tree(), atOrBefore: 7) == ["Chapter 2"])
    }

    @Test func deepestLabelIsLastPathComponent() {
        let nodes = tree()
        for page in 0..<8 {
            #expect(
                OutlineNode.deepestLabel(in: nodes, atOrBefore: page)
                    == OutlineNode.deepestPath(in: nodes, atOrBefore: page).last
            )
        }
        #expect(OutlineNode.deepestLabel(in: nodes, atOrBefore: 5) == "Chapter 2")
        #expect(OutlineNode.deepestLabel(in: nodes, atOrBefore: 0) == nil)
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

    /// Live-search core guarantee: restarting while a find is still
    /// streaming supersedes it — no stale matches from the old query may
    /// land after the new one.
    @Test func restartSupersedesInFlightSearch() async throws {
        let url = try makeTextPDF(pageTexts: ["alpha alpha", "alpha beta", "beta"])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))

        let find = FindController()
        find.search("alpha", in: document)
        // Immediately supersede, before the first find's notifications drain.
        find.search("beta", in: document)
        try await waitForSearchEnd(find)

        #expect(find.matches.count == 2)
        #expect(find.matches.allSatisfy { $0.string?.lowercased().contains("beta") == true })
        #expect(find.didSearch)
    }

    @Test func rapidFireRestartsKeepOnlyLastQuery() async throws {
        let url = try makeTextPDF(pageTexts: ["alpha beta gamma", "alpha gamma", "gamma"])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))

        let find = FindController()
        for query in ["alpha", "beta", "gam", "gamma"] {
            find.search(query, in: document)
        }
        try await waitForSearchEnd(find)

        #expect(find.matches.count == 3)
        #expect(find.matches.allSatisfy { $0.string?.lowercased().contains("gamma") == true })
    }

    /// Clearing the query mid-flight cancels: nothing stale may land after.
    @Test func emptyQueryCancelsInFlightSearch() async throws {
        let url = try makeTextPDF(pageTexts: ["alpha alpha", "alpha"])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))

        let find = FindController()
        find.search("alpha", in: document)
        find.search("   ", in: document)
        #expect(!find.isSearching)
        #expect(!find.didSearch)

        // Let any stale notifications from the cancelled find drain.
        try await Task.sleep(for: .milliseconds(300))
        #expect(find.matches.isEmpty)
        #expect(find.currentIndex == nil)
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
