#if os(macOS)
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("NavigateCandidates")
@MainActor
struct NavigateCandidatesTests {
    /// Chapter 1 › 1A › Complex Numbers, plus a destination-less container.
    private func syntheticOutline() -> [OutlineNode] {
        [
            OutlineNode(
                label: "Chapter 1",
                entry: NavEntry(pageIndex: 0),
                children: [
                    OutlineNode(
                        label: "1A Vector Spaces",
                        entry: NavEntry(pageIndex: 2),
                        children: [
                            OutlineNode(
                                label: "Complex Numbers",
                                entry: NavEntry(pageIndex: 3),
                                children: nil
                            )
                        ]
                    )
                ]
            ),
            OutlineNode(
                label: "Appendices",
                entry: nil,  // container with no destination — not jumpable
                children: [
                    OutlineNode(label: "Notation", entry: NavEntry(pageIndex: 90), children: nil)
                ]
            ),
        ]
    }

    @Test func outlineFlattensWithBreadcrumbPaths() {
        let candidates = NavigateCandidates.assemble(
            outline: syntheticOutline(), bookmarks: [], tabs: []
        )
        let titles = candidates.map(\.title)
        #expect(titles == ["Chapter 1", "1A Vector Spaces", "Complex Numbers", "Notation"])

        let complex = candidates[2]
        #expect(complex.subtitle == "Chapter 1 › 1A Vector Spaces")
        #expect(complex.action == .jump(NavEntry(pageIndex: 3)))
        #expect(complex.searchText == "Chapter 1 › 1A Vector Spaces › Complex Numbers")

        // Top-level entries have no breadcrumb.
        #expect(candidates[0].subtitle == nil)
    }

    @Test func destinationlessNodesAreSkippedButKeepPathAlive() {
        let candidates = NavigateCandidates.assemble(
            outline: syntheticOutline(), bookmarks: [], tabs: []
        )
        #expect(!candidates.contains { $0.title == "Appendices" })
        let notation = candidates.first { $0.title == "Notation" }
        #expect(notation?.subtitle == "Appendices")
    }

    @Test func bookmarksUseLabelOrPageFallback() {
        let candidates = NavigateCandidates.assemble(
            outline: [],
            bookmarks: [
                BookmarkCandidateInput(page: 11, label: "Key theorem"),
                BookmarkCandidateInput(page: 41, label: nil),
            ],
            tabs: []
        )
        #expect(candidates.map(\.title) == ["Key theorem", "Page 42"])
        #expect(candidates[1].action == .jump(NavEntry(pageIndex: 41)))
        #expect(candidates[0].subtitle == "Bookmark — p.12")
    }

    @Test func activeTabIsExcludedAndOthersKeepWindowLabel() {
        let windowA = UUID()
        let windowB = UUID()
        let active = UUID()
        let sibling = UUID()
        let elsewhere = UUID()

        let candidates = NavigateCandidates.assemble(
            outline: [],
            bookmarks: [],
            tabs: [
                TabCandidateInput(
                    windowID: windowA, tabID: active, title: "Axler",
                    pageIndex: 5, isActive: true, windowLabel: nil
                ),
                TabCandidateInput(
                    windowID: windowA, tabID: sibling, title: "Rudin",
                    pageIndex: 0, isActive: false, windowLabel: nil
                ),
                TabCandidateInput(
                    windowID: windowB, tabID: elsewhere, title: "Tao",
                    pageIndex: 9, isActive: false, windowLabel: "other window"
                ),
            ]
        )

        #expect(candidates.map(\.title) == ["Rudin", "Tao"])
        #expect(candidates[0].action == .selectTab(windowID: windowA, tabID: sibling))
        #expect(candidates[0].subtitle == "Open Tab — p.1")
        #expect(candidates[1].subtitle == "Open Tab — other window — p.10")
    }

    @Test func assemblyOrderIsTabsBookmarksOutline() {
        let candidates = NavigateCandidates.assemble(
            outline: [OutlineNode(label: "Intro", entry: NavEntry(pageIndex: 0), children: nil)],
            bookmarks: [BookmarkCandidateInput(page: 3, label: nil)],
            tabs: [
                TabCandidateInput(
                    windowID: UUID(), tabID: UUID(), title: "Open Book",
                    pageIndex: 0, isActive: false, windowLabel: nil
                )
            ]
        )
        #expect(candidates.map(\.title) == ["Open Book", "Page 4", "Intro"])
    }
}
#endif
