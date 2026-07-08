#if os(macOS)
import Foundation
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

    @Test func pointlessEntriesCountAsPageTop() {
        let plain = [
            OutlineNode(label: "A", entry: NavEntry(pageIndex: 2), children: nil),
            OutlineNode(label: "B", entry: NavEntry(pageIndex: 8), children: nil),
        ]
        // Mid-page-2 position: A (page top) is behind, B ahead.
        let here = NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 300))
        #expect(OutlineNode.sectionEntry(in: plain, after: here)?.pageIndex == 8)
        #expect(OutlineNode.sectionEntry(in: plain, before: here)?.pageIndex == 2)
    }

    @Test func emptyOutlineHasNoStops() {
        let here = NavEntry(pageIndex: 10)
        #expect(OutlineNode.sectionEntry(in: [], after: here) == nil)
        #expect(OutlineNode.sectionEntry(in: [], before: here) == nil)
    }
}
#endif
