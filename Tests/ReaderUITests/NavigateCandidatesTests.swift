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
        let candidates = NavigateCandidates.assembleInBook(
            outline: syntheticOutline(), bookmarks: []
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
        let candidates = NavigateCandidates.assembleInBook(
            outline: syntheticOutline(), bookmarks: []
        )
        #expect(!candidates.contains { $0.title == "Appendices" })
        let notation = candidates.first { $0.title == "Notation" }
        #expect(notation?.subtitle == "Appendices")
    }

    @Test func bookmarksUseLabelOrPageFallback() {
        let candidates = NavigateCandidates.assembleInBook(
            outline: [],
            bookmarks: [
                BookmarkCandidateInput(page: 11, label: "Key theorem"),
                BookmarkCandidateInput(page: 41, label: nil),
            ]
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

        let candidates = NavigateCandidates.assembleOpen(
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

    @Test func inBookOrderIsBookmarksThenOutline() {
        let candidates = NavigateCandidates.assembleInBook(
            outline: [OutlineNode(label: "Intro", entry: NavEntry(pageIndex: 0), children: nil)],
            bookmarks: [BookmarkCandidateInput(page: 3, label: nil)]
        )
        #expect(candidates.map(\.title) == ["Page 4", "Intro"])
    }

    @Test func openOrderIsTabsBooksCollectionsTags() {
        let candidates = NavigateCandidates.assembleOpen(
            tabs: [
                TabCandidateInput(
                    windowID: UUID(), tabID: UUID(), title: "Open Book",
                    pageIndex: 0, isActive: false, windowLabel: nil
                )
            ],
            books: [BookCandidateInput(title: "Hatcher", path: "/books/hatcher.pdf")],
            collections: [GroupCandidateInput(id: 1, name: "5140 Algebra", bookCount: 3)],
            tags: [GroupCandidateInput(id: 2, name: "Analysis", bookCount: 1)]
        )
        #expect(candidates.map(\.title) == ["Open Book", "Hatcher", "5140 Algebra", "Analysis"])
        #expect(candidates[2].action == .openCollection(1))
        #expect(candidates[2].subtitle == "Collection — 3 books as tabs")
        #expect(candidates[3].action == .openTag(2))
        #expect(candidates[3].subtitle == "Tag — 1 book as tabs")
    }

    @Test func emptyCollectionsAndTagsAreHidden() {
        let candidates = NavigateCandidates.assembleOpen(
            tabs: [],
            collections: [GroupCandidateInput(id: 1, name: "Empty", bookCount: 0)],
            tags: [GroupCandidateInput(id: 2, name: "Bare", bookCount: 0)]
        )
        #expect(candidates.isEmpty)
    }

    @Test func libraryBooksFollowTabsAndSkipOpenOnes() {
        let candidates = NavigateCandidates.assembleOpen(
            tabs: [
                TabCandidateInput(
                    windowID: UUID(), tabID: UUID(), title: "Axler",
                    pageIndex: 0, isActive: false, windowLabel: nil
                )
            ],
            books: [
                BookCandidateInput(title: "Axler", path: "/books/axler.pdf"),
                BookCandidateInput(title: "Hatcher", path: "/books/hatcher.pdf"),
            ],
            openPaths: ["/books/axler.pdf"]
        )
        // The open book keeps only its tab row (switch, don't duplicate).
        #expect(candidates.map(\.title) == ["Axler", "Hatcher"])
        #expect(
            candidates.last?.action
                == .openBook(URL(fileURLWithPath: "/books/hatcher.pdf"))
        )
        #expect(candidates.last?.subtitle == "Library — open in a new tab")
    }
}
#endif
