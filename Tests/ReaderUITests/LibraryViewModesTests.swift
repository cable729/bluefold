#if os(macOS)
import Foundation
import ReaderPersistence
import Testing

@testable import ReaderUI

/// Round-7 library view modes: the sortable list view (rows + last-read
/// join), the sectioned-by-tag grouping, and the mode/sort plumbing.
@Suite("Library view modes")
@MainActor
struct LibraryViewModesTests {

    private func makeItem(
        _ id: String, title: String? = nil, addedAt: Date? = nil
    ) -> LibraryItem {
        LibraryItem(
            id: id, source: .imported, title: title ?? id, authors: [],
            calibreTags: [], fileURL: URL(fileURLWithPath: "/tmp/\(id).pdf"),
            coverURL: nil, addedAt: addedAt
        )
    }

    /// Two imported books backed by a real in-memory store (the last-read
    /// join needs actual book rows).
    private func makeModelWithImports() throws -> (LibraryModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryViewModes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let homework = dir.appendingPathComponent("homework-3.pdf")
        let notes = dir.appendingPathComponent("lecture-notes.pdf")
        try Data("homework three".utf8).write(to: homework)
        try Data("lecture notes content".utf8).write(to: notes)

        let model = LibraryModel(store: try .inMemory())
        model.importPDFs(at: [homework, notes])
        return (model, dir)
    }

    // MARK: - List rows & sorting

    @Test func listRowsSortByTitleByDefault() throws {
        let model = LibraryModel(store: try .inMemory())
        model.setItemsForTesting([
            makeItem("1", title: "Banana"),
            makeItem("2", title: "apple"),
            makeItem("3", title: "Cherry"),
        ])

        #expect(model.listRows.map(\.title) == ["apple", "Banana", "Cherry"])
    }

    @Test func sortOrderChangeResortsStoredRows() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let model = LibraryModel(store: try .inMemory())
        model.setItemsForTesting([
            makeItem("old", title: "A", addedAt: base),
            makeItem("new", title: "B", addedAt: base.addingTimeInterval(9_999)),
            makeItem("undated", title: "C", addedAt: nil),
        ])

        model.listSortOrder = [KeyPathComparator(\.addedSortKey, order: .reverse)]
        #expect(model.listRows.map(\.id) == ["new", "old", "undated"])

        // Ascending puts the undated (distantPast sort key) books first.
        model.listSortOrder = [KeyPathComparator(\.addedSortKey, order: .forward)]
        #expect(model.listRows.map(\.id) == ["undated", "old", "new"])
    }

    @Test func listRowsFollowSearchNarrowing() throws {
        let model = LibraryModel(store: try .inMemory())
        model.setItemsForTesting([
            makeItem("1", title: "Linear Algebra"),
            makeItem("2", title: "Topology"),
        ])

        model.searchText = "topo"
        #expect(model.listRows.map(\.id) == ["2"])
        model.searchText = ""
        #expect(model.listRows.count == 2)
    }

    // MARK: - Last-read join

    @Test func listRowsCarryLastReadFromReadingState() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(model.store)

        let homework = try #require(model.items.first { $0.title == "homework-3" })
        let notes = try #require(model.items.first { $0.title == "lecture-notes" })
        let rowID = try #require(try store.bookID(forPathHint: homework.fileURL.path))
        try store.setReadingState(bookID: rowID, page: 3, device: "mac")

        model.reloadOverlay()

        let readRow = try #require(model.listRows.first { $0.id == homework.id })
        #expect(readRow.lastReadAt != nil)
        let unreadRow = try #require(model.listRows.first { $0.id == notes.id })
        #expect(unreadRow.lastReadAt == nil)

        // Most-recently-read-first sort: the read book leads, never-read
        // books (distantPast keys) trail.
        model.listSortOrder = [KeyPathComparator(\.lastReadSortKey, order: .reverse)]
        #expect(model.listRows.map(\.id) == [homework.id, notes.id])
    }

    @Test func importedItemsCarryDateAdded() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }

        // insertLooseBook stamps created_at; the items surface it.
        #expect(model.items.allSatisfy { $0.addedAt != nil })
        #expect(model.listRows.allSatisfy { $0.addedAt != nil })
    }

    // MARK: - Sectioned-by-tag grouping

    /// Math ▸ (Algebra ▸ Group Theory, Analysis) with books spread across
    /// the levels — the owner's round-7 sketch, exercised as a pure function.
    @Test func tagSectionsGroupScopeOnlyThenPerChildWithRollup() throws {
        let model = LibraryModel(store: try .inMemory())
        model.createTag(name: "Math")
        let math = try #require(model.allTags.first { $0.name == "Math" })
        model.createTag(name: "Algebra", parent: math.id)
        let algebra = try #require(model.allTags.first { $0.name == "Algebra" })
        model.createTag(name: "Analysis", parent: math.id)
        let analysis = try #require(model.allTags.first { $0.name == "Analysis" })
        model.createTag(name: "Group Theory", parent: algebra.id)
        let groupTheory = try #require(model.allTags.first { $0.name == "Group Theory" })
        model.createTag(name: "Empty Child", parent: math.id)

        let items = [
            makeItem("mathOnly"), makeItem("alg"), makeItem("deep"),
            makeItem("both"), makeItem("ana"),
        ]
        let itemTags: [String: [TagRecord]] = [
            "mathOnly": [math],
            "alg": [algebra],
            "deep": [groupTheory],  // grandchild rolls up into Algebra
            "both": [algebra, analysis],  // appears under both children
            "ana": [analysis],
        ]

        let sections = LibraryModel.tagSections(
            scopeTagID: try #require(math.id), tagTree: model.tagTree,
            items: items, itemTags: itemTags
        )

        // Scope-only section first, then children in tag order; the empty
        // child produces no section.
        #expect(sections.map(\.title) == ["Math", "Algebra", "Analysis"])
        #expect(sections[0].items.map(\.id) == ["mathOnly"])
        #expect(sections[1].items.map(\.id) == ["alg", "deep", "both"])
        #expect(sections[2].items.map(\.id) == ["both", "ana"])
    }

    @Test func tagSectionsEmptyForUnknownScope() throws {
        let model = LibraryModel(store: try .inMemory())
        let sections = LibraryModel.tagSections(
            scopeTagID: 999, tagTree: model.tagTree,
            items: [makeItem("a")], itemTags: [:]
        )
        #expect(sections.isEmpty)
    }

    /// End-to-end through the model: scope selection populates
    /// `tagSections`, search narrows them, leaving the scope clears them.
    @Test func modelPopulatesSectionsInsideTagScope() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.createTag(name: "Math")
        let math = try #require(model.allTags.first { $0.name == "Math" })
        model.createTag(name: "Algebra", parent: math.id)
        let algebra = try #require(model.allTags.first { $0.name == "Algebra" })

        let homework = try #require(model.items.first { $0.title == "homework-3" })
        let notes = try #require(model.items.first { $0.title == "lecture-notes" })
        model.toggleTag(math, for: homework)  // scope tag ONLY
        model.toggleTag(algebra, for: notes)  // child tag

        model.filter = .tag(try #require(math.id))
        #expect(model.tagSections.map(\.title) == ["Math", "Algebra"])
        #expect(model.tagSections[0].items.map(\.id) == [homework.id])
        #expect(model.tagSections[1].items.map(\.id) == [notes.id])

        model.searchText = "lecture"
        #expect(model.tagSections.map(\.title) == ["Algebra"])
        model.searchText = ""

        model.filter = .all
        #expect(model.tagSections.isEmpty)
    }

    // MARK: - View-mode fallback & persistence encoding

    @Test func sectionedFallsBackToGridOutsideTagScopes() throws {
        let model = LibraryModel(store: try .inMemory())
        model.createTag(name: "Math")
        let math = try #require(model.allTags.first)

        model.viewMode = .sectioned
        #expect(model.effectiveViewMode == .grid)  // .all scope

        model.filter = .tag(try #require(math.id))
        #expect(model.effectiveViewMode == .sectioned)

        model.filter = .untagged
        #expect(model.effectiveViewMode == .grid)

        model.viewMode = .list
        #expect(model.effectiveViewMode == .list)  // list works everywhere
    }

    @Test func sortOrderPersistenceRoundTrips() throws {
        let order = [
            KeyPathComparator(\LibraryListRow.addedSortKey, order: .reverse),
            KeyPathComparator(\LibraryListRow.title, order: .forward),
        ]
        let encoded = LibraryModel.persistedString(from: order)
        #expect(encoded == "added:reverse,title:forward")

        let decoded = try #require(LibraryModel.sortOrder(fromPersisted: encoded))
        #expect(decoded == order)

        // Garbage decodes to nil, keeping the default sort.
        #expect(LibraryModel.sortOrder(fromPersisted: "bogus") == nil)
        #expect(LibraryModel.sortOrder(fromPersisted: "") == nil)

        let lastRead = try #require(
            LibraryModel.sortOrder(fromPersisted: "lastRead:reverse,authors:forward")
        )
        #expect(lastRead == [
            KeyPathComparator(\LibraryListRow.lastReadSortKey, order: .reverse),
            KeyPathComparator(\LibraryListRow.authors, order: .forward),
        ])
    }
}
#endif
