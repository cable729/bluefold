#if os(macOS)
import CoreGraphics
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("Named destination enumeration")
@MainActor
struct NamedDestinationEnumerationTests {
    @Test func enumeratesEveryNameInOneWalk() throws {
        let url = try makePDFWithDestinations(
            pageCount: 5,
            destinations: [
                ("chapter.1", 0, CGPoint(x: 72, y: 700)),
                ("section.1.2", 1, CGPoint(x: 72, y: 500)),
                ("theorem.14.3.2", 3, CGPoint(x: 100, y: 450)),
                ("page.4", 4, CGPoint(x: 0, y: 792)),
            ]
        )
        let document = try #require(PDFDocument(url: url))

        let all = NamedDestinations.all(in: document)
        #expect(all.count == 4)
        #expect(all["theorem.14.3.2"]?.pageIndex == 3)
        #expect(all["theorem.14.3.2"]?.point?.y == 450)
        #expect(all["chapter.1"]?.pageIndex == 0)
    }

    @Test func documentWithoutNameTreeIsEmpty() {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        #expect(NamedDestinations.all(in: document).isEmpty)
    }
}

@Suite struct DestinationClassificationTests {
    @Test func classifiesStructureNames() {
        #expect(AnchorHeadingParser.classifyDestination("chapter.5")
            == .init(kind: .chapter, label: "Chapter 5"))
        #expect(AnchorHeadingParser.classifyDestination("section.5.1")
            == .init(kind: .section, label: "Section 5.1"))
        #expect(AnchorHeadingParser.classifyDestination("subsection.1.2.3")
            == .init(kind: .subsection, label: "Section 1.2.3"))
    }

    @Test func dropsHyperrefCounterFromTheoremFamily() {
        // Abbott-style: theorem.112.2.2.1 displays as Theorem 2.2.1 —
        // the first numeric token is hyperref's internal counter.
        #expect(AnchorHeadingParser.classifyDestination("theorem.112.2.2.1")
            == .init(kind: .theorem, label: "Theorem 2.2.1"))
        #expect(AnchorHeadingParser.classifyDestination("exercise.467.8.2.3")?.kind == .exercise)
    }

    @Test func keepsSingleNumberTheoremNames() {
        // Only one numeric token: nothing to drop.
        #expect(AnchorHeadingParser.classifyDestination("theorem.7")
            == .init(kind: .theorem, label: "Theorem 7"))
    }

    @Test func expandsAbbreviatedPrefixes() {
        #expect(AnchorHeadingParser.classifyDestination("thm.10.2.5")?.label == "Theorem 2.5")
        #expect(AnchorHeadingParser.classifyDestination("defn.4.1.3")?.label == "Definition 1.3")
    }

    @Test func rejectsNoiseNames() {
        for name in ["page.15", "cite.rudin", "Item.1007", "Hfootnote.186.1",
                     "equation.1.2", "figure.3.1", "Doc-Start", "chapter", ""] {
            #expect(AnchorHeadingParser.classifyDestination(name) == nil, "\(name)")
        }
    }
}
#endif
