#if os(macOS)
import Foundation
import ReaderPersistence
import Testing

@testable import ReaderUI

/// The watched-folder scan: whole-folder import, and the sync behaviors the
/// reMarkable use case needs — regeneration keeps identity, deletions
/// tombstone, moves follow. Fixtures are plain data files named *.pdf
/// (content hashing never parses PDF structure).
@MainActor
@Suite struct WatchedFolderScanTests {

    private func makeFixtureFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        return dir
    }

    /// The scan's canonicalization (temp dirs live behind /var → /private/var).
    private func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @Test func importsEveryPDFRecursivelyIgnoringOthers() async throws {
        let dir = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("aaa".utf8).write(to: dir.appendingPathComponent("a.pdf"))
        try Data("bbb".utf8).write(to: dir.appendingPathComponent("sub/b.PDF"))
        try Data("not a book".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        model.setWatchedFoldersForTesting([dir])
        await model.reload()

        let titles = model.items.map(\.title).sorted()
        #expect(titles == ["a", "b"])
        #expect(model.items.allSatisfy { $0.source == .imported })
        // Registered for quick-open too.
        #expect(try store.openableBooks().count == 2)
    }

    @Test func regeneratedFileKeepsBookIdentityAndReadingState() async throws {
        let dir = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.pdf")
        try Data("version 1".utf8).write(to: file)

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        model.setWatchedFoldersForTesting([dir])
        await model.reload()

        let bookID = try #require(try store.bookID(forPathHint: canonical(file)))
        let hashBefore = try #require(try store.book(id: bookID)?.contentHash)
        try store.setReadingState(bookID: bookID, page: 12, device: "mac")

        // reMarkable-style regeneration: same path, new bytes (different
        // size, so the scan fingerprint can't shadow the change).
        try Data("version 2 — longer".utf8).write(to: file)
        await model.reload()

        let after = try #require(try store.bookID(forPathHint: canonical(file)))
        #expect(after == bookID)
        #expect(try store.book(id: bookID)?.contentHash != hashBefore)
        #expect(try store.readingState(forBook: bookID)?.page == 12)
        #expect(model.items.count == 1)
    }

    @Test func unchangedFilesAreNotRescannedButStayPresent() async throws {
        let dir = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("stable".utf8).write(to: dir.appendingPathComponent("a.pdf"))

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        model.setWatchedFoldersForTesting([dir])
        await model.reload()
        let modifiedBefore = try #require(try store.allBooks().first?.modifiedAt)

        await model.reload()  // fingerprint hit: no write, no tombstone
        #expect(model.items.count == 1)
        #expect(try store.allBooks().first?.modifiedAt == modifiedBefore)
    }

    @Test func deletedFileTombstonesItsBook() async throws {
        let dir = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.pdf")
        try Data("soon gone".utf8).write(to: file)

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        model.setWatchedFoldersForTesting([dir])
        await model.reload()
        let bookID = try #require(try store.bookID(forPathHint: canonical(file)))

        try FileManager.default.removeItem(at: file)
        await model.reload()

        #expect(model.items.isEmpty)
        #expect(try store.book(id: bookID)?.deletedAt != nil)
    }

    @Test func deleteThenRecreateResurrectsTheSameBook() async throws {
        // Regeneration can look like delete + recreate across two scans.
        let dir = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.pdf")
        try Data("v1".utf8).write(to: file)

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        model.setWatchedFoldersForTesting([dir])
        await model.reload()
        let bookID = try #require(try store.bookID(forPathHint: canonical(file)))

        try FileManager.default.removeItem(at: file)
        await model.reload()
        #expect(try store.book(id: bookID)?.deletedAt != nil)

        try Data("v2 regenerated".utf8).write(to: file)
        await model.reload()
        let back = try #require(try store.bookID(forPathHint: canonical(file)))
        #expect(back == bookID)
        #expect(try store.book(id: bookID)?.deletedAt == nil)
        #expect(model.items.count == 1)
    }

    @Test func movedFileFollowsWithoutDuplicating() async throws {
        let dir = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("a.pdf")
        try Data("movable".utf8).write(to: original)

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        model.setWatchedFoldersForTesting([dir])
        await model.reload()
        let bookID = try #require(try store.bookID(forPathHint: canonical(original)))

        let moved = dir.appendingPathComponent("sub/renamed.pdf")
        try FileManager.default.moveItem(at: original, to: moved)
        await model.reload()

        #expect(model.items.count == 1)
        #expect(try store.bookID(forPathHint: canonical(moved)) == bookID)
        #expect(try store.book(id: bookID)?.deletedAt == nil)
    }

    @Test func removingWatchedFolderRemovesItsBooks() async throws {
        let dir = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("watched".utf8).write(to: dir.appendingPathComponent("a.pdf"))

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        // Canonicalized like addWatchedFolders would.
        let canonicalDir = URL(fileURLWithPath: canonical(dir), isDirectory: true)
        model.setWatchedFoldersForTesting([canonicalDir])
        await model.reload()
        #expect(model.items.count == 1)

        model.removeWatchedFolder(canonicalDir)
        // removeWatchedFolder kicks its own reload Task; await one directly
        // for determinism.
        await model.reload()

        #expect(model.watchedFolders.isEmpty)
        #expect(model.items.isEmpty)
    }

    @Test func calibreBooksWithBackfilledHashesDoNotDuplicateAsImports() throws {
        // appendImportedItems must skip Calibre rows even when they carry a
        // content hash (resolver/indexer backfill) — they're already listed
        // from the Calibre scan.
        let store = try LibraryStore.inMemory()
        let calibre = try store.upsertCalibreBook(uuid: "u1", title: "Axler")
        try store.setContentHash(bookID: calibre.id!, hash: "h-backfilled")
        try store.upsertFileRefs([(bookID: calibre.id!, pathHint: "/cal/axler.pdf")])

        let model = LibraryModel(store: store)
        model.importPDFs(at: [])  // triggers appendImportedItems rebuild
        #expect(model.items.isEmpty)
    }
}
#endif
