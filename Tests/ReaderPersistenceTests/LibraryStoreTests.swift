import Foundation
import GRDB
import Testing

@testable import ReaderPersistence

/// A settable clock for deterministic timestamps in tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64

    init(_ ms: Int64 = 1_000_000) {
        self.ms = ms
    }

    var current: Int64 {
        lock.withLock { ms }
    }

    func advance(by delta: Int64) {
        lock.withLock { ms += delta }
    }

    func set(_ value: Int64) {
        lock.withLock { ms = value }
    }

    var now: @Sendable () -> Int64 {
        { self.current }
    }
}

@Suite struct LibraryStoreTests {

    // MARK: Migration

    @Test func migrationCreatesAllTables() throws {
        let store = try LibraryStore.inMemory()
        let tables = try store.dbQueue.read { db in
            try String.fetchSet(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
            )
        }
        #expect(tables == [
            "book", "file_ref", "tag", "book_tag",
            "collection", "collection_item", "user_bookmark", "reading_state",
        ])
        let foreignKeysOn = try store.dbQueue.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(foreignKeysOn == true)
    }

    // MARK: Books

    @Test func calibreUpsertIsIdempotent() throws {
        let store = try LibraryStore.inMemory()
        let first = try store.upsertCalibreBook(uuid: "uuid-1", title: "Algebra")
        let second = try store.upsertCalibreBook(uuid: "uuid-1", title: "Algebra, 2nd ed.")

        #expect(first.id == second.id)
        #expect(second.title == "Algebra, 2nd ed.")
        let books = try store.allBooks()
        #expect(books.count == 1)
        #expect(books[0].title == "Algebra, 2nd ed.")
    }

    @Test func bookRequiresAtLeastOneIdentity() throws {
        let store = try LibraryStore.inMemory()
        #expect(throws: DatabaseError.self) {
            try store.dbQueue.write { db in
                var book = BookRecord(
                    id: nil, calibreUUID: nil, contentHash: nil,
                    title: "No identity", modifiedAt: 0, deletedAt: nil
                )
                try book.insert(db)
            }
        }
    }

    @Test func looseBookGetsFileRef() throws {
        let store = try LibraryStore.inMemory()
        let bookmark = Data([1, 2, 3])
        let book = try store.insertLooseBook(
            contentHash: "abc123", title: "Homework 4",
            pathHint: "/Users/caleb/hw4.pdf", bookmark: bookmark
        )
        let ref = try store.fileRef(forBook: book.id!)
        #expect(ref?.pathHint == "/Users/caleb/hw4.pdf")
        #expect(ref?.bookmark == bookmark)
    }

    @Test func softDeletedBooksAreHiddenByDefault() throws {
        let store = try LibraryStore.inMemory()
        let keep = try store.upsertCalibreBook(uuid: "keep", title: "Keep")
        let gone = try store.upsertCalibreBook(uuid: "gone", title: "Gone")

        try store.softDeleteBook(id: gone.id!)

        #expect(try store.allBooks().map(\.id) == [keep.id])
        let all = try store.allBooks(includeDeleted: true)
        #expect(all.count == 2)
        #expect(all.first { $0.id == gone.id }?.deletedAt != nil)
    }

    // MARK: Tags

    @Test func tagHierarchyFindsBooksUnderDescendantTags() throws {
        let store = try LibraryStore.inMemory()
        let algebra = try store.createTag(name: "Algebra")
        let linear = try store.createTag(name: "Linear Algebra", parent: algebra.id)
        let book = try store.upsertCalibreBook(uuid: "axler", title: "Linear Algebra Done Right")
        try store.setTags(bookID: book.id!, tagIDs: [linear.id!])

        // Direct query on the parent tag finds nothing...
        #expect(try store.books(withTag: algebra.id!).isEmpty)
        // ...but the descendant-inclusive query finds the book.
        let found = try store.books(withTag: algebra.id!, includeDescendantTags: true)
        #expect(found.map(\.id) == [book.id])
        // And the tag itself still matches directly.
        #expect(try store.books(withTag: linear.id!).map(\.id) == [book.id])
    }

    @Test func tagTreeNestsChildrenUnderRoots() throws {
        let store = try LibraryStore.inMemory()
        let math = try store.createTag(name: "Math")
        _ = try store.createTag(name: "Algebra", parent: math.id)
        _ = try store.createTag(name: "Analysis", parent: math.id)
        _ = try store.createTag(name: "Cooking")

        let tree = try store.tagTree()
        #expect(tree.map(\.tag.name) == ["Cooking", "Math"])
        let mathNode = try #require(tree.first { $0.tag.name == "Math" })
        #expect(mathNode.children.map(\.tag.name) == ["Algebra", "Analysis"])
    }

    @Test func softDeleteTagReparentsChildrenAndTombstonesBookTags() throws {
        let store = try LibraryStore.inMemory()
        let math = try store.createTag(name: "Math")
        let algebra = try store.createTag(name: "Algebra", parent: math.id)
        let linear = try store.createTag(name: "Linear Algebra", parent: algebra.id)
        let book = try store.upsertCalibreBook(uuid: "b1", title: "Book")
        try store.setTags(bookID: book.id!, tagIDs: [algebra.id!])

        try store.softDeleteTag(id: algebra.id!)

        // Child reparented to the deleted tag's parent.
        let tree = try store.tagTree()
        #expect(tree.map(\.tag.name) == ["Math"])
        #expect(tree[0].children.map(\.tag.id) == [linear.id])
        // Book no longer carries the deleted tag.
        #expect(try store.tags(forBook: book.id!).isEmpty)
        #expect(try store.books(withTag: algebra.id!).isEmpty)
    }

    @Test func setTagsReplacesAndResurrects() throws {
        let store = try LibraryStore.inMemory()
        let a = try store.createTag(name: "A")
        let b = try store.createTag(name: "B")
        let book = try store.upsertCalibreBook(uuid: "b1", title: "Book")

        try store.setTags(bookID: book.id!, tagIDs: [a.id!])
        #expect(try store.tags(forBook: book.id!).map(\.id) == [a.id])

        try store.setTags(bookID: book.id!, tagIDs: [b.id!])
        #expect(try store.tags(forBook: book.id!).map(\.id) == [b.id])

        // Re-adding A resurrects its tombstoned row (no PK violation).
        try store.setTags(bookID: book.id!, tagIDs: [a.id!, b.id!])
        #expect(try store.tags(forBook: book.id!).map(\.name) == ["A", "B"])
    }

    // MARK: Collections

    @Test func collectionOrderingAndReorder() throws {
        let store = try LibraryStore.inMemory()
        let course = try store.createCollection(name: "5140 Algebra 2")
        #expect(course.kind == "course")
        let text = try store.upsertCalibreBook(uuid: "text", title: "Textbook")
        let hw = try store.insertLooseBook(contentHash: "hw", title: "HW 1", pathHint: "hw1.pdf")
        let notes = try store.insertLooseBook(contentHash: "notes", title: "Notes", pathHint: "notes.pdf")

        try store.addToCollection(collectionID: course.id!, bookID: text.id!, sortOrder: 0)
        try store.addToCollection(collectionID: course.id!, bookID: hw.id!, sortOrder: 1)
        try store.addToCollection(collectionID: course.id!, bookID: notes.id!, sortOrder: 2)

        #expect(try store.items(inCollection: course.id!).map(\.bookID) == [text.id!, hw.id!, notes.id!])

        try store.reorder(collectionID: course.id!, orderedBookIDs: [notes.id!, text.id!, hw.id!])
        #expect(try store.items(inCollection: course.id!).map(\.bookID) == [notes.id!, text.id!, hw.id!])
    }

    @Test func removeFromCollectionSoftDeletesAndReAddResurrects() throws {
        let store = try LibraryStore.inMemory()
        let course = try store.createCollection(name: "Course")
        let book = try store.upsertCalibreBook(uuid: "b", title: "B")
        try store.addToCollection(collectionID: course.id!, bookID: book.id!)

        try store.removeFromCollection(collectionID: course.id!, bookID: book.id!)
        #expect(try store.items(inCollection: course.id!).isEmpty)

        try store.addToCollection(collectionID: course.id!, bookID: book.id!, sortOrder: 5)
        let items = try store.items(inCollection: course.id!)
        #expect(items.map(\.bookID) == [book.id!])
        #expect(items[0].sortOrder == 5)
    }

    // MARK: Bookmarks

    @Test func bookmarkAddListSoftDelete() throws {
        let store = try LibraryStore.inMemory()
        let book = try store.upsertCalibreBook(uuid: "b", title: "B")
        let late = try store.addBookmark(bookID: book.id!, page: 42, label: "Theorem 3.1")
        let early = try store.addBookmark(bookID: book.id!, page: 7)

        #expect(try store.bookmarks(forBook: book.id!).map(\.id) == [early.id, late.id])

        try store.softDeleteBookmark(id: late.id!)
        #expect(try store.bookmarks(forBook: book.id!).map(\.id) == [early.id])
    }

    // MARK: Reading state

    @Test func readingStateUpserts() throws {
        let clock = TestClock(1_000)
        let store = try LibraryStore.inMemory(now: clock.now)
        let book = try store.upsertCalibreBook(uuid: "b", title: "B")

        try store.setReadingState(bookID: book.id!, page: 10, device: "mac")
        clock.advance(by: 500)
        try store.setReadingState(bookID: book.id!, page: 25, device: "ipad")

        let rowCount = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading_state")
        }
        #expect(rowCount == 1)
        let state = try #require(try store.readingState(forBook: book.id!))
        #expect(state.page == 25)
        #expect(state.device == "ipad")
        #expect(state.updatedAt == 1_500)
    }

    @Test func recentlyReadOrdersByRecencyAndSkipsDeletedBooks() throws {
        let clock = TestClock(1_000)
        let store = try LibraryStore.inMemory(now: clock.now)
        let a = try store.upsertCalibreBook(uuid: "a", title: "A")
        let b = try store.upsertCalibreBook(uuid: "b", title: "B")
        let c = try store.upsertCalibreBook(uuid: "c", title: "C")

        try store.setReadingState(bookID: a.id!, page: 1, device: "mac")
        clock.advance(by: 100)
        try store.setReadingState(bookID: b.id!, page: 2, device: "mac")
        clock.advance(by: 100)
        try store.setReadingState(bookID: c.id!, page: 3, device: "mac")
        try store.softDeleteBook(id: b.id!)

        let recent = try store.recentlyRead(limit: 10)
        #expect(recent.map(\.book.id) == [c.id, a.id])
        #expect(recent[0].state.page == 3)

        #expect(try store.recentlyRead(limit: 1).map(\.book.id) == [c.id])
    }

    // MARK: Tombstones

    @Test func purgeTombstonesDropsOldKeepsFresh() throws {
        let dayMs: Int64 = 86_400_000
        let clock = TestClock(100 * dayMs)
        let store = try LibraryStore.inMemory(now: clock.now)

        let old = try store.upsertCalibreBook(uuid: "old", title: "Old")
        let fresh = try store.upsertCalibreBook(uuid: "fresh", title: "Fresh")
        let live = try store.upsertCalibreBook(uuid: "live", title: "Live")
        let oldTag = try store.createTag(name: "Old Tag")

        try store.softDeleteBook(id: old.id!)
        try store.softDeleteTag(id: oldTag.id!)
        clock.advance(by: 40 * dayMs)
        try store.softDeleteBook(id: fresh.id!)
        clock.advance(by: 5 * dayMs)

        // "old" and "Old Tag" are 45 days dead, "fresh" only 5.
        let purged = try store.purgeTombstones(olderThanDays: 30)
        #expect(purged == 2)

        let remaining = try store.allBooks(includeDeleted: true)
        #expect(Set(remaining.map(\.calibreUUID)) == ["fresh", "live"])
        let tagCount = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag")
        }
        #expect(tagCount == 0)
    }

    // MARK: Foreign keys

    @Test func foreignKeysAreEnforced() throws {
        let store = try LibraryStore.inMemory()
        #expect(throws: DatabaseError.self) {
            try store.setTags(bookID: 999, tagIDs: [123])
        }
        #expect(throws: DatabaseError.self) {
            try store.addBookmark(bookID: 999, page: 1)
        }
        #expect(throws: DatabaseError.self) {
            try store.setReadingState(bookID: 999, page: 1, device: "mac")
        }
    }

    @Test func hardDeleteCascadesToDependents() throws {
        let store = try LibraryStore.inMemory()
        let book = try store.insertLooseBook(contentHash: "h", title: "B", pathHint: "b.pdf")
        try store.setReadingState(bookID: book.id!, page: 3, device: "mac")
        _ = try store.addBookmark(bookID: book.id!, page: 3)

        try store.dbQueue.write { db in
            _ = try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [book.id!])
        }
        let counts = try store.dbQueue.read { db in
            [
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_ref")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_bookmark")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading_state")!,
            ]
        }
        #expect(counts == [0, 0, 0])
    }
}
