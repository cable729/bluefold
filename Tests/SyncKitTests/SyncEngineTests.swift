import Foundation
import ReaderPersistence
import Testing

@testable import SyncKit

/// A settable clock for deterministic timestamps.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64

    init(_ ms: Int64 = 1_000_000) { self.ms = ms }

    var now: @Sendable () -> Int64 {
        { self.lock.withLock { self.ms } }
    }

    func set(_ value: Int64) { lock.withLock { ms = value } }
    func advance(by delta: Int64) { lock.withLock { ms += delta } }
}

/// One simulated device: its own store, clock, and engine, all sharing the
/// test's FakeTransport "server".
private struct Device {
    let clock: TestClock
    let store: LibraryStore
    let engine: SyncEngine

    init(transport: FakeTransport, at ms: Int64 = 1_000_000) throws {
        clock = TestClock(ms)
        store = try LibraryStore.inMemory(now: clock.now)
        engine = SyncEngine(store: store, transport: transport)
    }

    @discardableResult
    func sync() async throws -> SyncSummary {
        try await engine.sync()
    }
}

@Suite struct SyncEngineTests {
    // MARK: - Full round trip

    @Test func fullLibraryRoundTrip() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server, at: 2_000_000)

        // Device A builds a small library.
        let axler = try a.store.upsertCalibreBook(uuid: "axler-uuid", title: "Linear Algebra Done Right", authors: "Sheldon Axler")
        let loose = try a.store.insertLooseBook(contentHash: "deadbeef", title: "Lecture Notes", pathHint: "/notes.pdf")
        let math = try a.store.createTag(name: "Math")
        let algebra = try a.store.createTag(name: "Algebra", parent: math.id!)
        try a.store.setTagColor(id: algebra.id!, color: "#3366FF")
        let course = try a.store.createCollection(name: "Fall 2026")
        let unit = try a.store.createCollection(name: "Unit 1", parent: course.id!)
        try a.store.setTags(bookID: axler.id!, tagIDs: [algebra.id!])
        try a.store.addToCollection(collectionID: unit.id!, bookID: axler.id!, sortOrder: 2)
        try a.store.addToCollection(collectionID: unit.id!, bookID: loose.id!, sortOrder: 1)
        try a.store.addBookmark(bookID: axler.id!, page: 21, label: "1A starts")
        try a.store.setReadingState(bookID: axler.id!, page: 42, device: "mac-a")

        try await a.sync()
        let summaryB = try await b.sync()
        #expect(summaryB.appliedChanges > 0)

        // B sees the same library, by natural keys.
        let bAxler = try #require(try b.store.allBooks().first { $0.calibreUUID == "axler-uuid" })
        #expect(bAxler.title == "Linear Algebra Done Right")
        #expect(bAxler.authors == "Sheldon Axler")
        #expect(try b.store.allBooks().contains { $0.contentHash == "deadbeef" })

        let bTree = try b.store.tagTree()
        let bMath = try #require(bTree.first { $0.tag.name == "Math" })
        let bAlgebra = try #require(bMath.children.first { $0.tag.name == "Algebra" })
        #expect(bAlgebra.tag.color == "#3366FF")
        #expect(try b.store.books(withTag: bAlgebra.tag.id!).map(\.calibreUUID) == ["axler-uuid"])

        let bCollections = try b.store.collectionTree()
        let bCourse = try #require(bCollections.first { $0.collection.name == "Fall 2026" })
        let bUnit = try #require(bCourse.children.first { $0.collection.name == "Unit 1" })
        let items = try b.store.items(inCollection: bUnit.collection.id!)
        #expect(items.count == 2)
        #expect(items.map(\.sortOrder).sorted() == [1, 2])

        let bookmarks = try b.store.bookmarks(forBook: bAxler.id!)
        #expect(bookmarks.map(\.page) == [21])
        #expect(bookmarks.first?.label == "1A starts")

        let state = try #require(try b.store.readingState(forBook: bAxler.id!))
        #expect(state.page == 42)
        #expect(state.device == "mac-a")
    }

    // MARK: - LWW

    @Test func lastWriterWinsOnBothSidesEditing() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server)

        let tag = try a.store.createTag(name: "Topology")
        try await a.sync()
        try await b.sync()
        let bTag = try #require(try b.store.tagTree().first { $0.tag.name == "Topology" }?.tag)

        // A edits at t=2M, B edits later at t=3M — B's edit must win
        // everywhere regardless of push order.
        a.clock.set(2_000_000)
        try a.store.setTagColor(id: tag.id!, color: "#AAAAAA")
        b.clock.set(3_000_000)
        try b.store.setTagColor(id: bTag.id!, color: "#BBBBBB")

        try await a.sync()
        try await b.sync()
        try await a.sync()

        #expect(try a.store.tagTree().first { $0.tag.name == "Topology" }?.tag.color == "#BBBBBB")
        #expect(try b.store.tagTree().first { $0.tag.name == "Topology" }?.tag.color == "#BBBBBB")
    }

    @Test func independentSameNameTagsConvergeToOneRecord() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server)

        a.clock.set(1_000_000)
        _ = try a.store.createTag(name: "Probability")
        b.clock.set(2_000_000)
        let bTag = try b.store.createTag(name: "Probability")
        try b.store.setTagColor(id: bTag.id!, color: "#00FF00")

        try await a.sync()
        try await b.sync()  // conflict: same record name, B newer → B wins
        try await a.sync()

        #expect(try a.store.tagTree().filter { $0.tag.name == "Probability" }.count == 1)
        #expect(try a.store.tagTree().first { $0.tag.name == "Probability" }?.tag.color == "#00FF00")
        await #expect(server.recordCount == 1)
    }

    // MARK: - Deletion

    @Test func tombstonePropagates() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server)

        let tag = try a.store.createTag(name: "Doomed")
        try await a.sync()
        try await b.sync()
        #expect(try b.store.tagTree().contains { $0.tag.name == "Doomed" })

        a.clock.advance(by: 1000)
        try a.store.softDeleteTag(id: tag.id!)
        try await a.sync()
        try await b.sync()

        // Gone from B's live tree, but still present as a tombstone (soft).
        #expect(!(try b.store.tagTree().contains { $0.tag.name == "Doomed" }))
    }

    @Test func tombstonePurgePropagatesAsHardDelete() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server)

        let book = try a.store.insertLooseBook(contentHash: "cafe", title: "Notes", pathHint: "/n.pdf")
        let mark = try a.store.addBookmark(bookID: book.id!, page: 3)
        try await a.sync()
        try await b.sync()

        a.clock.advance(by: 1000)
        try a.store.softDeleteBookmark(id: mark.id!)
        try await a.sync()
        try await b.sync()

        // 31 days later A purges; the hard delete must reach B.
        a.clock.advance(by: 31 * 86_400_000)
        let purged = try a.store.purgeTombstones()
        #expect(purged > 0)
        let summaryA = try await a.sync()
        #expect(summaryA.pushedDeletes > 0)
        try await b.sync()

        let bBook = try #require(try b.store.allBooks().first { $0.contentHash == "cafe" })
        // Row is fully gone on B, not just tombstoned.
        #expect(try b.store.bookmarks(forBook: bBook.id!).isEmpty)
        let all = try b.store.syncExport().filter {
            if case .bookmark = $0 { return true } else { return false }
        }
        #expect(all.isEmpty)
    }

    @Test func tagRenamePreservesMembershipAcrossDevices() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server)

        let book = try a.store.upsertCalibreBook(uuid: "u1", title: "Algebra")
        let tag = try a.store.createTag(name: "Mth")
        try a.store.setTags(bookID: book.id!, tagIDs: [tag.id!])
        try await a.sync()
        try await b.sync()

        a.clock.advance(by: 1000)
        try a.store.renameTag(id: tag.id!, name: "Math")
        try await a.sync()
        try await b.sync()

        let bTree = try b.store.tagTree()
        #expect(bTree.map(\.tag.name) == ["Math"])
        let bTag = try #require(bTree.first?.tag)
        #expect(try b.store.books(withTag: bTag.id!).map(\.calibreUUID) == ["u1"])
        // The old record family is gone from the server too.
        try await a.sync()
        #expect(try a.store.tagTree().map(\.tag.name) == ["Math"])
    }

    // MARK: - Reading state

    @Test func readingStateNewestUpdateWins() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server)

        let book = try a.store.upsertCalibreBook(uuid: "u1", title: "Book")
        a.clock.set(5_000_000)
        try a.store.setReadingState(bookID: book.id!, page: 50, device: "mac-a")
        try await a.sync()
        try await b.sync()

        let bBook = try #require(try b.store.allBooks().first { $0.calibreUUID == "u1" })
        #expect(try b.store.readingState(forBook: bBook.id!)?.page == 50)

        // B reads further, LATER — B's position wins on A even though A
        // pushes its own state again in between.
        b.clock.set(6_000_000)
        try b.store.setReadingState(bookID: bBook.id!, page: 30, device: "mac-b")
        try await b.sync()
        try await a.sync()

        let aState = try #require(try a.store.readingState(forBook: book.id!))
        #expect(aState.page == 30)
        #expect(aState.device == "mac-b")

        // An OLDER remote state never regresses a newer local one.
        a.clock.set(7_000_000)
        try a.store.setReadingState(bookID: book.id!, page: 99, device: "mac-a")
        try await a.sync()
        try await b.sync()
        #expect(try b.store.readingState(forBook: bBook.id!)?.page == 99)
    }

    // MARK: - Pending (missing endpoints)

    @Test func orphanRelationWaitsInPendingAndHeals() async throws {
        let server = FakeTransport()
        let b = try Device(transport: server)

        // The server has a book_tag whose book/tag records don't exist yet
        // (e.g. a partial push from another device that then went offline).
        let orphan = PortableRecord.bookTag(PortableBookTag(
            bookKey: "cal:ghost", tagPath: ["Math"], modifiedAt: 500, deletedAt: nil
        ))
        let tagRecord = PortableRecord.tag(PortableTag(path: ["Math"], color: nil, modifiedAt: 400, deletedAt: nil))
        _ = try await server.push(
            saves: [
                SyncPushSave(record: RecordMapper.syncRecord(from: orphan), baseTag: nil),
                SyncPushSave(record: RecordMapper.syncRecord(from: tagRecord), baseTag: nil),
            ],
            deletes: []
        )

        let summary1 = try await b.sync()
        #expect(summary1.pendingCount == 1)
        // The pending record must NOT be deleted off the server just because
        // this device can't apply it yet.
        let orphanName = RecordMapper.name(for: orphan)
        await #expect(server.record(named: orphanName) != nil)

        // The book arrives later; the stashed relation applies.
        let bookRecord = PortableRecord.book(PortableBook(
            key: "cal:ghost", calibreUUID: "ghost", contentHash: nil, title: "Ghost Book",
            authors: nil, createdAt: 600, modifiedAt: 600, deletedAt: nil
        ))
        _ = try await server.push(
            saves: [SyncPushSave(record: RecordMapper.syncRecord(from: bookRecord), baseTag: nil)],
            deletes: []
        )
        let summary2 = try await b.sync()
        #expect(summary2.pendingCount == 0)

        let ghost = try #require(try b.store.allBooks().first { $0.calibreUUID == "ghost" })
        let tags = try b.store.tags(forBook: ghost.id!)
        #expect(tags.map(\.name) == ["Math"])
    }

    // MARK: - Robustness

    @Test func expiredTokenRefetchesIdempotently() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)

        _ = try a.store.createTag(name: "Stable")
        try await a.sync()
        await server.setExpireNextToken()
        let summary = try await a.sync()

        // Full refetch of its own records: everything is same-or-newer
        // locally, nothing duplicates, nothing pushes.
        #expect(summary.pushedSaves == 0)
        #expect(try a.store.tagTree().filter { $0.tag.name == "Stable" }.count == 1)
    }

    @Test func steadyStateSyncsAreQuiet() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)

        _ = try a.store.createTag(name: "Quiet")
        let first = try await a.sync()
        #expect(first.pushedSaves > 0)
        let second = try await a.sync()
        #expect(second.pushedSaves == 0)
        #expect(second.pushedDeletes == 0)
        #expect(second.appliedChanges == 0)
        let third = try await a.sync()
        #expect(third.fetchedChanges == 0)
    }

    @Test func collectionItemOrderAndRemovalSync() async throws {
        let server = FakeTransport()
        let a = try Device(transport: server)
        let b = try Device(transport: server)

        let b1 = try a.store.upsertCalibreBook(uuid: "u1", title: "One")
        let b2 = try a.store.upsertCalibreBook(uuid: "u2", title: "Two")
        let coll = try a.store.createCollection(name: "Course")
        try a.store.addToCollection(collectionID: coll.id!, bookID: b1.id!, sortOrder: 0)
        try a.store.addToCollection(collectionID: coll.id!, bookID: b2.id!, sortOrder: 1)
        try await a.sync()
        try await b.sync()

        a.clock.advance(by: 1000)
        try a.store.reorder(collectionID: coll.id!, orderedBookIDs: [b2.id!, b1.id!])
        try a.store.removeFromCollection(collectionID: coll.id!, bookID: b1.id!)
        try await a.sync()
        try await b.sync()

        let bColl = try #require(try b.store.collections().first { $0.name == "Course" })
        let items = try b.store.items(inCollection: bColl.id!)
        #expect(items.count == 1)
        let survivor = try #require(try b.store.allBooks().first { $0.calibreUUID == "u2" })
        #expect(items.first?.bookID == survivor.id)
    }
}
