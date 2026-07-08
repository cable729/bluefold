import Foundation
import GRDB
import Testing

@testable import CalibreKit

/// Builds a throwaway Calibre-shaped library on disk: a temp folder holding a
/// `metadata.db` with only the tables/columns CalibreKit reads.
private func makeFixtureLibrary() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CalibreKitFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let dbQueue = try DatabaseQueue(
        path: root.appendingPathComponent("metadata.db").path
    )
    try dbQueue.write { db in
        try db.execute(
            sql: """
                CREATE TABLE books (
                    id INTEGER PRIMARY KEY,
                    uuid TEXT,
                    title TEXT,
                    sort TEXT,
                    path TEXT,
                    has_cover BOOL DEFAULT 0,
                    pubdate TIMESTAMP,
                    timestamp TIMESTAMP
                );
                CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE books_authors_link (book INTEGER, author INTEGER);
                CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE books_tags_link (book INTEGER, tag INTEGER);
                CREATE TABLE data (book INTEGER, format TEXT, name TEXT);
                """
        )

        // Book 1: two authors, two tags, PDF, cover, real pubdate + timestamp.
        try db.execute(
            sql: """
                INSERT INTO books (id, uuid, title, sort, path, has_cover, pubdate, timestamp) VALUES
                (1, 'uuid-analysis', 'Advanced Analysis', 'Advanced Analysis',
                 'Jane Doe/Advanced Analysis (1)', 1, '2015-03-14 00:00:00+00:00',
                 '2021-06-01 10:30:00+00:00'),
                (2, 'uuid-epub-only', 'EPUB Only Novel', 'EPUB Only Novel',
                 'Some Author/EPUB Only Novel (2)', 1, '2020-01-01 00:00:00+00:00',
                 '2020-01-02 00:00:00+00:00'),
                (3, 'uuid-manifolds', 'Introduction to Manifolds', 'Introduction to Manifolds',
                 'John Smith/Introduction to Manifolds (3)', 0, '0101-01-01 00:00:00+00:00',
                 '0101-01-01 00:00:00+00:00'),
                (4, 'uuid-unicode', 'Théorie des Ensembles — 集合論', 'Zébra sort key',
                 'Élodie Müller/Théorie des Ensembles (4)', 1, NULL, NULL);

                INSERT INTO authors (id, name) VALUES
                (1, 'Jane Doe'), (2, 'John Smith'), (3, 'Some Author'), (4, 'Élodie Müller');

                INSERT INTO books_authors_link (book, author) VALUES
                (1, 1), (1, 2), (2, 3), (3, 2), (4, 4);

                INSERT INTO tags (id, name) VALUES (1, 'math'), (2, 'analysis'), (3, 'fiction');

                INSERT INTO books_tags_link (book, tag) VALUES (1, 1), (1, 2), (2, 3);

                INSERT INTO data (book, format, name) VALUES
                (1, 'PDF', 'Advanced Analysis - Jane Doe'),
                (1, 'EPUB', 'Advanced Analysis - Jane Doe'),
                (2, 'EPUB', 'EPUB Only Novel - Some Author'),
                (3, 'PDF', 'Introduction to Manifolds - John Smith'),
                (4, 'PDF', 'Théorie des Ensembles - Élodie Müller');
                """
        )
    }
    return root
}

@Suite("CalibreLibrary")
struct CalibreLibraryTests {
    @Test("only books with a PDF are returned, ordered by sort title")
    func pdfFilteringAndSortOrder() throws {
        let root = try makeFixtureLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = try CalibreLibrary(libraryRoot: root).fetchBooks()

        #expect(books.map(\.id) == [1, 3, 4])  // EPUB-only book 2 excluded
        #expect(books.map(\.sortTitle) == [
            "Advanced Analysis", "Introduction to Manifolds", "Zébra sort key",
        ])
    }

    @Test("authors, tags, uuid, pdf path, cover, and pubdate are populated")
    func fullyPopulatedBook() throws {
        let root = try makeFixtureLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = try CalibreLibrary(libraryRoot: root).fetchBooks()
        let book = try #require(books.first { $0.id == 1 })

        #expect(book.uuid == "uuid-analysis")
        #expect(book.title == "Advanced Analysis")
        #expect(book.authors == ["Jane Doe", "John Smith"])
        #expect(book.calibreTags == ["analysis", "math"])  // alphabetical
        #expect(book.relativePDFPaths == [
            "Jane Doe/Advanced Analysis (1)/Advanced Analysis - Jane Doe.pdf"
        ])
        #expect(book.coverRelativePath == "Jane Doe/Advanced Analysis (1)/cover.jpg")

        let pubdate = try #require(book.pubdate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: pubdate)
        #expect(parts.year == 2015)
        #expect(parts.month == 3)
        #expect(parts.day == 14)

        // Date added (books.timestamp) — the library list view's column.
        let added = try #require(book.addedAt)
        let addedParts = calendar.dateComponents([.year, .month, .day], from: added)
        #expect(addedParts.year == 2021)
        #expect(addedParts.month == 6)
        #expect(addedParts.day == 1)
    }

    @Test("book with no tags/cover and Calibre's undefined pubdate")
    func sparseBook() throws {
        let root = try makeFixtureLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = try CalibreLibrary(libraryRoot: root).fetchBooks()
        let book = try #require(books.first { $0.id == 3 })

        #expect(book.calibreTags.isEmpty)
        #expect(book.coverRelativePath == nil)
        #expect(book.pubdate == nil)  // '0101-01-01 …' sentinel means undefined
        #expect(book.addedAt == nil)  // same sentinel on books.timestamp
        #expect(book.authors == ["John Smith"])
        #expect(book.relativePDFPaths == [
            "John Smith/Introduction to Manifolds (3)/Introduction to Manifolds - John Smith.pdf"
        ])
    }

    @Test("unicode titles, authors, and paths survive the round trip")
    func unicodeBook() throws {
        let root = try makeFixtureLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = try CalibreLibrary(libraryRoot: root).fetchBooks()
        let book = try #require(books.first { $0.id == 4 })

        #expect(book.title == "Théorie des Ensembles — 集合論")
        #expect(book.authors == ["Élodie Müller"])
        #expect(book.relativePDFPaths == [
            "Élodie Müller/Théorie des Ensembles (4)/Théorie des Ensembles - Élodie Müller.pdf"
        ])
        #expect(book.pubdate == nil)
    }

    @Test("pdfURL resolves relative paths against the library root")
    func pdfURLResolution() throws {
        let root = try makeFixtureLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try CalibreLibrary(libraryRoot: root)
        let url = library.pdfURL(for: "Jane Doe/Advanced Analysis (1)/file.pdf")

        #expect(url.path == root.appendingPathComponent("Jane Doe/Advanced Analysis (1)/file.pdf").path)
    }

    @Test("reads a private copy: deleting the original after opening is harmless")
    func readsACopyNotTheLiveFile() throws {
        let root = try makeFixtureLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try CalibreLibrary(libraryRoot: root)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("metadata.db")
        )

        let books = try library.fetchBooks()
        #expect(books.count == 3)
    }

    @Test("missing metadata.db throws metadataNotFound")
    func missingDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalibreKitEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect {
            _ = try CalibreLibrary(libraryRoot: root)
        } throws: { error in
            guard case CalibreError.metadataNotFound = error else { return false }
            return true
        }
    }
}
