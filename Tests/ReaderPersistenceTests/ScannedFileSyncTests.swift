import Foundation
import GRDB
import Testing

@testable import ReaderPersistence

/// `syncScannedFile` is the watched-folder scan's (and the live-reload
/// path's) single write: it must keep book identity stable across the three
/// ways a file can reappear — moved (same bytes, new path), regenerated
/// (same path, new bytes — the reMarkable case), and brand new.
@Suite struct ScannedFileSyncTests {

    @Test func newFileInsertsLooseBookWithFileRef() throws {
        let store = try LibraryStore.inMemory()
        let id = try store.syncScannedFile(
            path: "/notes/Quick sheets.pdf", hash: "aaa", title: "Quick sheets"
        )
        let book = try #require(try store.book(id: id))
        #expect(book.contentHash == "aaa")
        #expect(book.title == "Quick sheets")
        #expect(book.calibreUUID == nil)
        #expect(try store.pathHint(forBookID: id) == "/notes/Quick sheets.pdf")
    }

    @Test func rescanOfUnchangedFileIsIdempotent() throws {
        let store = try LibraryStore.inMemory()
        let first = try store.syncScannedFile(path: "/n/a.pdf", hash: "h1", title: "a")
        let second = try store.syncScannedFile(path: "/n/a.pdf", hash: "h1", title: "a")
        #expect(first == second)
        #expect(try store.allBooks().count == 1)
    }

    @Test func movedFileKeepsBookAndFollowsPath() throws {
        let store = try LibraryStore.inMemory()
        let id = try store.syncScannedFile(path: "/n/old.pdf", hash: "h1", title: "old")
        let after = try store.syncScannedFile(path: "/n/sub/new.pdf", hash: "h1", title: "new")
        #expect(after == id)
        #expect(try store.pathHint(forBookID: id) == "/n/sub/new.pdf")
        // The scan never renames existing books.
        #expect(try store.book(id: id)?.title == "old")
    }

    @Test func regeneratedFileKeepsIdentityAndRebindsHash() throws {
        // The reMarkable case: same path, new bytes on every sync. The book
        // row — and with it tags/bookmarks/reading state — must survive.
        let store = try LibraryStore.inMemory()
        let id = try store.syncScannedFile(path: "/n/notes.pdf", hash: "h1", title: "notes")
        try store.setReadingState(bookID: id, page: 7, device: "mac")

        let after = try store.syncScannedFile(path: "/n/notes.pdf", hash: "h2", title: "notes")
        #expect(after == id)
        #expect(try store.book(id: id)?.contentHash == "h2")
        #expect(try store.readingState(forBook: id)?.page == 7)
        #expect(try store.book(byContentHash: "h1") == nil)
    }

    @Test func regenerationBumpsModifiedAt() throws {
        let clock = TestSyncClock(1_000)
        let store = try LibraryStore.inMemory(now: clock.now)
        let id = try store.syncScannedFile(path: "/n/a.pdf", hash: "h1", title: "a")
        clock.set(2_000)
        _ = try store.syncScannedFile(path: "/n/a.pdf", hash: "h2", title: "a")
        #expect(try store.book(id: id)?.modifiedAt == 2_000)
    }

    @Test func deletedThenRecreatedFileResurrectsTombstonedBook() throws {
        // reMarkable regeneration can look like delete + recreate. If the
        // book got tombstoned in between, the same bytes must resurrect it
        // rather than violate the content_hash UNIQUE constraint.
        let store = try LibraryStore.inMemory()
        let id = try store.syncScannedFile(path: "/n/a.pdf", hash: "h1", title: "a")
        try store.softDeleteBook(id: id)

        let back = try store.syncScannedFile(path: "/n/a.pdf", hash: "h1", title: "a")
        #expect(back == id)
        #expect(try store.book(id: id)?.deletedAt == nil)
    }

    @Test func recreatedWithNewBytesAtKnownPathResurrectsToo() throws {
        // Delete + recreate where the new file's bytes ALSO changed: the
        // path is the only remaining link, and it must still win over
        // inserting a duplicate book.
        let store = try LibraryStore.inMemory()
        let id = try store.syncScannedFile(path: "/n/a.pdf", hash: "h1", title: "a")
        try store.softDeleteBook(id: id)

        let back = try store.syncScannedFile(path: "/n/a.pdf", hash: "h2", title: "a")
        #expect(back == id)
        #expect(try store.book(id: id)?.deletedAt == nil)
        #expect(try store.book(id: id)?.contentHash == "h2")
    }

    @Test func hashMatchOnCalibreBookRefreshesItsFileRef() throws {
        // A Calibre book whose hash the indexer backfilled: a scan finding
        // the same bytes elsewhere follows the file, but the row stays a
        // Calibre book (title untouched).
        let store = try LibraryStore.inMemory()
        let book = try store.upsertCalibreBook(uuid: "u1", title: "Axler")
        try store.setContentHash(bookID: book.id!, hash: "h1")

        let id = try store.syncScannedFile(path: "/elsewhere/axler.pdf", hash: "h1", title: "x")
        #expect(id == book.id)
        #expect(try store.book(id: id)?.title == "Axler")
        #expect(try store.pathHint(forBookID: id) == "/elsewhere/axler.pdf")
    }

    @Test func looseBookFileRefsExcludeCalibreAndTombstoned() throws {
        let store = try LibraryStore.inMemory()
        let live = try store.syncScannedFile(path: "/n/live.pdf", hash: "h1", title: "live")
        let dead = try store.syncScannedFile(path: "/n/dead.pdf", hash: "h2", title: "dead")
        try store.softDeleteBook(id: dead)
        let calibre = try store.upsertCalibreBook(uuid: "u1", title: "c")
        try store.upsertFileRefs([(bookID: calibre.id!, pathHint: "/cal/c.pdf")])

        let refs = try store.looseBookFileRefs()
        #expect(refs.map(\.bookID) == [live])
        #expect(refs.map(\.pathHint) == ["/n/live.pdf"])
    }
}

/// Local settable clock (LibraryStoreTests' TestClock is fileprivate there).
private final class TestSyncClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
    func set(_ value: Int64) { lock.withLock { ms = value } }
    var now: @Sendable () -> Int64 {
        { self.lock.withLock { self.ms } }
    }
}
