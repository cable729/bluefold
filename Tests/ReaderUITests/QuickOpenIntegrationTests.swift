#if os(macOS)
import Foundation
import GRDB
import ReaderPersistence
import Testing

@testable import ReaderUI

/// End-to-end pipeline behind "⌘P, type a book name, Return": a real
/// (synthetic) Calibre library on disk → LibraryModel.reload() mirrors PDF
/// paths into file_ref → openableBooks() feeds the palette.
@Suite("Quick-open pipeline")
@MainActor
struct QuickOpenIntegrationTests {
    /// Minimal Calibre-shaped library: metadata.db + one PDF file on disk.
    private func makeCalibreFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickOpenFixture-\(UUID().uuidString)", isDirectory: true)
        let bookDir = root.appendingPathComponent("Sheldon Axler/Linear Algebra Done Right (1)")
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try Data("not a real pdf".utf8)
            .write(to: bookDir.appendingPathComponent("Linear Algebra Done Right - Sheldon Axler.pdf"))

        let dbQueue = try DatabaseQueue(path: root.appendingPathComponent("metadata.db").path)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE books (
                        id INTEGER PRIMARY KEY, uuid TEXT, title TEXT, sort TEXT,
                        path TEXT, has_cover BOOL DEFAULT 0, pubdate TIMESTAMP
                    );
                    CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
                    CREATE TABLE books_authors_link (book INTEGER, author INTEGER);
                    CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
                    CREATE TABLE books_tags_link (book INTEGER, tag INTEGER);
                    CREATE TABLE data (book INTEGER, format TEXT, name TEXT);

                    INSERT INTO books (id, uuid, title, sort, path) VALUES
                    (1, 'uuid-ladr', 'Linear Algebra Done Right', 'Linear Algebra Done Right',
                     'Sheldon Axler/Linear Algebra Done Right (1)');
                    INSERT INTO authors (id, name) VALUES (1, 'Sheldon Axler');
                    INSERT INTO books_authors_link (book, author) VALUES (1, 1);
                    INSERT INTO data (book, format, name) VALUES
                    (1, 'PDF', 'Linear Algebra Done Right - Sheldon Axler');
                    """
            )
        }
        return root
    }

    @Test func reloadMirrorsCalibrePathsAndBooksBecomeOpenable() async throws {
        let root = try makeCalibreFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store)
        model.setCalibreRootForTesting(root)
        await model.reload()

        #expect(model.loadError == nil)
        #expect(model.items.count == 1)

        // The mirror ran: a never-opened Calibre book is openable.
        let openable = try store.openableBooks()
        #expect(openable.count == 1)
        #expect(openable.first?.title == "Linear Algebra Done Right")
        let path = try #require(openable.first?.pathHint)
        #expect(FileManager.default.fileExists(atPath: path))

        // And it surfaces as a palette candidate that opens the file.
        let candidates = NavigateCandidates.assemble(
            outline: [], bookmarks: [], tabs: [],
            books: [BookCandidateInput(title: openable[0].title, path: path)],
            openPaths: []
        )
        #expect(candidates.first?.action == .openBook(URL(fileURLWithPath: path)))
    }
}
#endif
