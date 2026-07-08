#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Status-bar ⇤ ⇥ section skipping: every outline entry (any depth) is a
/// stop, and stops are exact DESTINATIONS (page + in-page point) — real
/// books put several sections on one page.
@Suite("Section skipping")
struct SectionSkipTests {
    // Page 4: Chapter 1 (top). Page 4 lower down: 1.1 (y 400). Page 4
    // further down: 1.2 (y 150). Page 30: Chapter 2.
    private var outline: [OutlineNode] {
        [
            OutlineNode(
                label: "Chapter 1",
                entry: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 700)),
                children: [
                    OutlineNode(
                        label: "1.1",
                        entry: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 400)),
                        children: nil
                    ),
                    OutlineNode(
                        label: "1.2",
                        entry: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 150)),
                        children: nil
                    ),
                ]
            ),
            OutlineNode(
                label: "Chapter 2",
                entry: NavEntry(pageIndex: 30, point: CGPoint(x: 0, y: 700)),
                children: nil
            ),
        ]
    }

    @Test func nextStopsAtInPageAnchors() {
        // Standing at Chapter 1's anchor: next is 1.1 on the SAME page,
        // at its exact point (round 10: used to jump to the next page top).
        let fromChapter1 = OutlineNode.sectionEntry(
            in: outline, after: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 700))
        )
        #expect(fromChapter1 == NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 400)))

        let from11 = OutlineNode.sectionEntry(
            in: outline, after: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 400))
        )
        #expect(from11 == NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 150)))

        let from12 = OutlineNode.sectionEntry(
            in: outline, after: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 150))
        )
        #expect(from12?.pageIndex == 30)

        #expect(OutlineNode.sectionEntry(
            in: outline, after: NavEntry(pageIndex: 30, point: CGPoint(x: 0, y: 700))
        ) == nil)
    }

    @Test func previousStopsAtInPageAnchors() {
        // From 1.2's anchor back to 1.1's, same page.
        let from12 = OutlineNode.sectionEntry(
            in: outline, before: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 150))
        )
        #expect(from12 == NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 400)))

        // From Chapter 2 back to the LAST section of chapter 1 (1.2).
        let fromChapter2 = OutlineNode.sectionEntry(
            in: outline, before: NavEntry(pageIndex: 30, point: CGPoint(x: 0, y: 700))
        )
        #expect(fromChapter2 == NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 150)))

        #expect(OutlineNode.sectionEntry(
            in: outline, before: NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 700))
        ) == nil)
    }

    @Test func landingSlopDoesNotWedgePrevious() {
        // After jumping to 1.1 (anchor y=400) PDFKit parks the view a bit
        // BELOW the anchor. Previous must go to Chapter 1 — not re-jump
        // 1.1 forever (round 13) — and next must move on to 1.2.
        let landed = NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 375))
        #expect(
            OutlineNode.sectionEntry(in: outline, before: landed)
                == NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 700))
        )
        #expect(
            OutlineNode.sectionEntry(in: outline, after: landed)
                == NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 150))
        )
    }

    @Test func deepInASectionPreviousReturnsToItsStart() {
        // Reading well past 1.1's anchor: previous restarts 1.1 first
        // (media-player), then a second press reaches Chapter 1.
        let deep = NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 250))
        #expect(
            OutlineNode.sectionEntry(in: outline, before: deep)
                == NavEntry(pageIndex: 4, point: CGPoint(x: 0, y: 400))
        )
    }

    @Test func pointlessEntriesCountAsPageTop() {
        // Nil-point entries can't come out of tree(from:) anymore (concrete
        // crop-top points are synthesized); for hand-built ones the rule is
        // "never wedge": same-page = standing at the section start, so
        // previous steps BACK rather than restarting (a restart at the page
        // top you're already on is a no-op — the round-13.6 bug).
        let plain = [
            OutlineNode(label: "A", entry: NavEntry(pageIndex: 2), children: nil),
            OutlineNode(label: "B", entry: NavEntry(pageIndex: 8), children: nil),
        ]
        let here = NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 300))
        #expect(OutlineNode.sectionEntry(in: plain, after: here)?.pageIndex == 8)
        #expect(OutlineNode.sectionEntry(in: plain, before: here) == nil)  // A is first
    }

    @Test func chapterAndFirstSectionSharingAnAnchorDoNotWedgePrevious() {
        // Dummit & Foote page 572: "Chapter 14" and "14.1" anchor at the
        // same spot (synthesized page tops in scans). Previous from there
        // must cross into the PREVIOUS chapter's last section, not step to
        // the invisible twin anchor forever (round 13.7).
        let top = CGPoint(x: 0, y: 700)
        let outline = [
            OutlineNode(label: "13.6", entry: NavEntry(pageIndex: 557, point: top), children: nil),
            OutlineNode(
                label: "Chapter 14", entry: NavEntry(pageIndex: 572, point: top),
                children: [
                    OutlineNode(label: "14.1", entry: NavEntry(pageIndex: 572, point: top), children: nil),
                    OutlineNode(label: "14.2", entry: NavEntry(pageIndex: 583, point: top), children: nil),
                ]
            ),
        ]
        let atChapter14 = NavEntry(pageIndex: 572, point: top)
        #expect(
            OutlineNode.sectionEntry(in: outline, before: atChapter14)?.pageIndex == 557
        )
        // And next from the merged anchor moves on to 14.2.
        #expect(
            OutlineNode.sectionEntry(in: outline, after: atChapter14)?.pageIndex == 583
        )
    }

    @Test func previousStepsBackThroughPointlessSections() {
        // The scan case (round 13.6): entries whose points were dropped.
        // Standing at B's page top, previous must reach A — a nil point's
        // -∞ offset used to read as "deep inside B" and re-target B forever.
        let plain = [
            OutlineNode(label: "A", entry: NavEntry(pageIndex: 2), children: nil),
            OutlineNode(label: "B", entry: NavEntry(pageIndex: 8), children: nil),
        ]
        let atBTop = NavEntry(pageIndex: 8, point: CGPoint(x: 0, y: 700))
        #expect(OutlineNode.sectionEntry(in: plain, before: atBTop)?.pageIndex == 2)
    }

    @Test @MainActor func treeSynthesizesConcretePointsForBrokenDestinations() throws {
        // Outline destinations with unspecified points (scans) come out of
        // tree(from:) with CONCRETE crop-top points, so stepping math and
        // go(to:) never see nil.
        let document = PDFDocument()
        for index in 0..<10 {
            document.insert(PDFPage(), at: index)
        }
        let root = PDFOutline()
        for (label, pageIndex) in [("A", 2), ("B", 8)] {
            let node = PDFOutline()
            node.label = label
            node.destination = PDFDestination(
                page: document.page(at: pageIndex)!,
                at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
            )
            root.insertChild(node, at: root.numberOfChildren)
        }
        document.outlineRoot = root

        let nodes = OutlineNode.tree(from: document)
        let entries = nodes.compactMap(\.entry)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.point != nil })

        // And previous from B's synthesized top reaches A.
        let atB = try #require(entries.last)
        #expect(OutlineNode.sectionEntry(in: nodes, before: atB)?.pageIndex == 2)
    }

    @Test func emptyOutlineHasNoStops() {
        let here = NavEntry(pageIndex: 10)
        #expect(OutlineNode.sectionEntry(in: [], after: here) == nil)
        #expect(OutlineNode.sectionEntry(in: [], before: here) == nil)
    }
}

/// Destination points from broken scans (outside the visible page — even
/// negative) must degrade to page-top jumps: PDFView silently refuses to
/// scroll to them, which made every Munkres outline click a no-op.
@Suite("Destination point validation")
@MainActor
struct DestinationPointTests {
    private let page = PDFPage()  // default crop 612×792 at origin

    @Test func inPagePointsPass() {
        #expect(
            ReaderPDFView.validatedPoint(CGPoint(x: 70, y: 700), on: page)
                == CGPoint(x: 70, y: 700)
        )
    }

    @Test func outOfCropPointsDegradeToPageTop() {
        #expect(ReaderPDFView.validatedPoint(CGPoint(x: -19.7, y: 414), on: page) == nil)
        #expect(ReaderPDFView.validatedPoint(CGPoint(x: 70, y: 4000), on: page) == nil)
    }

    @Test func unspecifiedMarkerIsNil() {
        let unspecified = CGPoint(
            x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue
        )
        #expect(ReaderPDFView.validatedPoint(unspecified, on: page) == nil)
    }
}
#endif
