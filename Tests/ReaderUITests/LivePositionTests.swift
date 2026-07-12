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

/// Round 22: sidebar follow mode matched nothing — the section stops were
/// built from a PRIVATE outline tree, and `OutlineNode.id` is minted per
/// build, so the live section id never equaled any id the sidebar rendered.
/// These pin the fix: one shared tree per document, stops derived from it.
@Suite("Sidebar follow – shared outline identity")
@MainActor
struct SidebarFollowIdentityTests {
    /// Pages 0–3 with a nested outline: Chapter 1 (p.1) > 1.A (p.2).
    private func makeOutlinedDocument() -> PDFDocument {
        let document = PDFDocument()
        for i in 0..<4 {
            document.insert(PDFPage(), at: i)
        }
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter 1"
        chapter.destination = PDFDestination(
            page: document.page(at: 1)!, at: CGPoint(x: 0, y: 700)
        )
        root.insertChild(chapter, at: 0)
        let section = PDFOutline()
        section.label = "1.A"
        section.destination = PDFDestination(
            page: document.page(at: 2)!, at: CGPoint(x: 0, y: 650)
        )
        chapter.insertChild(section, at: 0)
        document.outlineRoot = root
        return document
    }

    private func allIDs(in nodes: [OutlineNode]) -> Set<UUID> {
        var ids: Set<UUID> = []
        func walk(_ nodes: [OutlineNode]) {
            for node in nodes {
                ids.insert(node.id)
                walk(node.children ?? [])
            }
        }
        walk(nodes)
        return ids
    }

    @Test func sectionStopIDsExistInTheSidebarTree() {
        let model = ReaderWindowModel(store: nil)
        let document = makeOutlinedDocument()

        let sidebarIDs = allIDs(in: model.outline(for: document))
        let stopIDs = Set(model.sectionStops(for: document).map(\.nodeID))

        #expect(!stopIDs.isEmpty)
        #expect(stopIDs.isSubset(of: sidebarIDs))
    }

    @Test func sectionStopIDsMatchRegardlessOfBuildOrder() {
        // The scroll observer can request stops BEFORE the sidebar first
        // renders the tree — the shared cache must serve both orders.
        let model = ReaderWindowModel(store: nil)
        let document = makeOutlinedDocument()

        let stopIDs = Set(model.sectionStops(for: document).map(\.nodeID))
        let sidebarIDs = allIDs(in: model.outline(for: document))

        #expect(!stopIDs.isEmpty)
        #expect(stopIDs.isSubset(of: sidebarIDs))
    }

    @Test func ancestorsOfTheLiveSectionAreExpandable() {
        // The sidebar reveal path: expand `ancestorIDs(of: liveID)` in the
        // rendered tree. With mismatched trees this returned [] and the
        // current section stayed collapsed under its chapter.
        let model = ReaderWindowModel(store: nil)
        let document = makeOutlinedDocument()

        let outline = model.outline(for: document)
        let stops = model.sectionStops(for: document)
        // Deep into page 2 → the nested "1.A" stop.
        let stop = OutlineNode.currentStop(
            in: stops, at: NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 600))
        )
        #expect(stop?.path == ["Chapter 1", "1.A"])

        let ancestors = OutlineNode.ancestorIDs(of: stop!.nodeID, in: outline)
        #expect(ancestors == [outline[0].id], "1.A reveals by expanding Chapter 1")
    }

    @Test func noteLivePositionPublishesAnIDTheSidebarRenders() throws {
        // Full pipeline: scroll tick → noteLivePosition → currentSectionNodeID
        // must identify a node of the tree the sidebar draws.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarFollowTests-\(UUID().uuidString).pdf")
        #expect(makeOutlinedDocument().write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let model = ReaderWindowModel(store: nil)
        let document = try #require(model.provider.document(for: url))
        let tabID = model.openTab(fileURL: url)

        model.noteLivePosition(
            tabID: tabID, entry: NavEntry(pageIndex: 2, point: CGPoint(x: 0, y: 600))
        )

        let liveID = try #require(model.currentSectionNodeID)
        let outline = model.outline(for: document)
        #expect(allIDs(in: outline).contains(liveID))
        #expect(!OutlineNode.ancestorIDs(of: liveID, in: outline).isEmpty)
    }
}
#endif
