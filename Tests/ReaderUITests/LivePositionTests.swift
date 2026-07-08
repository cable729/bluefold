#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Round 15: breadcrumbs and the sidebar highlight follow the live scroll
/// position (point-precise), and either split pane can be closed.
@Suite("Live position & pane close")
@MainActor
struct LivePositionTests {
    /// Nodes with concrete points: two sections share page 2 (top and
    /// middle) — exactly the case page-granular lookups get wrong.
    private func makeStopsFixture() -> [OutlineNode] {
        func node(_ label: String, page: Int, y: CGFloat, children: [OutlineNode]? = nil) -> OutlineNode {
            OutlineNode(
                label: label,
                entry: NavEntry(pageIndex: page, point: CGPoint(x: 0, y: y)),
                children: children
            )
        }
        return [
            node("Chapter 1", page: 0, y: 700, children: [
                node("1A", page: 0, y: 700),        // same anchor as the chapter
                node("1B", page: 2, y: 700),        // page-2 top
                node("1C", page: 2, y: 350),        // page-2 middle
            ]),
            node("Chapter 2", page: 4, y: 700),
        ]
    }

    @Test func stopsAreOrderedAndSameSpotKeepsDeepestPath() {
        let stops = OutlineNode.sectionStops(in: makeStopsFixture())
        // Chapter 1 and 1A share an anchor → one stop, with the deeper path.
        #expect(stops.map(\.path) == [
            ["Chapter 1", "1A"],
            ["Chapter 1", "1B"],
            ["Chapter 1", "1C"],
            ["Chapter 2"],
        ])
    }

    @Test func currentStopIsPointPreciseWithinAPage() {
        let stops = OutlineNode.sectionStops(in: makeStopsFixture())

        // Reading near the top of page 2 → 1B; scrolled to the middle → 1C.
        let atTop = OutlineNode.currentStop(
            in: stops, at: NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 690))
        )
        #expect(atTop?.path == ["Chapter 1", "1B"])

        let atMiddle = OutlineNode.currentStop(
            in: stops, at: NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 300))
        )
        #expect(atMiddle?.path == ["Chapter 1", "1C"])

        // Between the section pages, page granularity still works.
        let onPage1 = OutlineNode.currentStop(in: stops, at: NavEntry(pageIndex: 1))
        #expect(onPage1?.path == ["Chapter 1", "1A"])

        // Before everything → nil.
        #expect(OutlineNode.currentStop(in: [], at: NavEntry(pageIndex: 0)) == nil)
    }

    @Test func landingSlopCountsAsStandingOnTheAnchor() {
        let stops = OutlineNode.sectionStops(in: makeStopsFixture())
        // PDFKit parks a few points BELOW an anchor; 1C at y=350, parked at
        // y=380 (30pt above in reading order) must still read as 1C… but
        // parked ABOVE by more than the slop reads as 1B.
        let parked = OutlineNode.currentStop(
            in: stops, at: NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 380))
        )
        #expect(parked?.path == ["Chapter 1", "1C"])
        let wellAbove = OutlineNode.currentStop(
            in: stops, at: NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 450))
        )
        #expect(wellAbove?.path == ["Chapter 1", "1B"])
    }

    // MARK: - Pane close (round 15: ✕ on both headers)

    private func makeSplitModel() -> (ReaderWindowModel, primary: UUID, split: UUID) {
        let model = ReaderWindowModel(store: nil)
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.openInSplit(tabID: a)
        return (model, primary: b, split: a)
    }

    @Test func closingTheSplitPaneKeepsThePrimary() {
        let (model, primary, split) = makeSplitModel()
        model.closePane(.split)
        #expect(model.splitTabID == nil)
        #expect(model.activeTabID == primary)
        #expect(model.tabs.count == 2, "both tabs stay open in the strip")
        _ = split
    }

    @Test func closingThePrimaryPanePromotesTheSplitTab() {
        let (model, primary, split) = makeSplitModel()
        model.closePane(.primary)
        // "The right side takes over as full primary."
        #expect(model.splitTabID == nil)
        #expect(model.activeTabID == split)
        #expect(model.focusedPane == .primary)
        #expect(model.tabs.count == 2, "both tabs stay open in the strip")
        _ = primary
    }

    @Test func closePaneWithoutASplitIsANoOp() {
        let model = ReaderWindowModel(store: nil)
        let only = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.closePane(.primary)
        #expect(model.activeTabID == only)
        #expect(model.tabs.count == 1)
    }
}
#endif
