import Foundation
import GRDB

/// One full-text search match.
public struct SearchHit: Equatable, Sendable {
    /// Content hash of the document the hit belongs to.
    public let contentHash: String
    /// 1-based page number within the document.
    public let page: Int
    /// Snippet of matched text with «…» highlight markers.
    public let snippet: String

    public init(contentHash: String, page: Int, snippet: String) {
        self.contentHash = contentHash
        self.page = page
        self.snippet = snippet
    }
}

/// SQLite-backed FTS5 index over PDF page text, keyed by content hash.
///
/// Schema:
/// - `indexed_doc`: one row per indexed document (content hash, page count,
///   timestamp, extractor version for future re-index migrations).
/// - `page_fts`: FTS5 virtual table with one row per non-empty page.
public final class IndexStore: Sendable {
    private let dbQueue: DatabaseQueue

    /// Opens (creating if needed) an index database at the given file path.
    public convenience init(path: String) throws {
        try self.init(dbQueue: DatabaseQueue(path: path))
    }

    /// Creates a private in-memory index (used by tests).
    public static func inMemory() throws -> IndexStore {
        try IndexStore(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-createIndexTables") { db in
            try db.execute(sql: """
                CREATE TABLE indexed_doc(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content_hash TEXT NOT NULL UNIQUE,
                    page_count INTEGER NOT NULL,
                    indexed_at INTEGER NOT NULL,
                    extractor_version INTEGER NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE page_fts USING fts5(
                    text,
                    doc_id UNINDEXED,
                    page UNINDEXED,
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)
        }
        return migrator
    }

    // MARK: - Writes

    /// True when the document is already indexed at the given extractor version.
    public func isIndexed(contentHash: String, extractorVersion: Int) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM indexed_doc
                        WHERE content_hash = ? AND extractor_version = ?
                    )
                    """,
                arguments: [contentHash, extractorVersion]
            ) ?? false
        }
    }

    /// Removes the document and all its page rows from the index.
    public func removeIndex(contentHash: String) throws {
        try dbQueue.write { db in
            try Self.deleteDocument(contentHash: contentHash, db)
        }
    }

    /// Atomically replaces the index entry for a document: deletes any stale
    /// rows for the same content hash, then inserts the doc row and its pages.
    public func insertPages(
        contentHash: String,
        pageCount: Int,
        extractorVersion: Int,
        pages: [(page: Int, text: String)]
    ) throws {
        try dbQueue.write { db in
            try Self.deleteDocument(contentHash: contentHash, db)
            try db.execute(
                sql: """
                    INSERT INTO indexed_doc (content_hash, page_count, indexed_at, extractor_version)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    contentHash, pageCount,
                    Int64(Date().timeIntervalSince1970), extractorVersion,
                ]
            )
            let docId = db.lastInsertedRowID
            for page in pages {
                try db.execute(
                    sql: "INSERT INTO page_fts (text, doc_id, page) VALUES (?, ?, ?)",
                    arguments: [page.text, docId, page.page]
                )
            }
        }
    }

    private static func deleteDocument(contentHash: String, _ db: Database) throws {
        guard
            let docId = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM indexed_doc WHERE content_hash = ?",
                arguments: [contentHash]
            )
        else { return }
        try db.execute(sql: "DELETE FROM page_fts WHERE doc_id = ?", arguments: [docId])
        try db.execute(sql: "DELETE FROM indexed_doc WHERE id = ?", arguments: [docId])
    }

    // MARK: - Search

    /// Full-text search across all indexed documents, best matches first.
    ///
    /// The query is sanitized (each whitespace-separated term becomes a quoted
    /// FTS5 string) so arbitrary user input never raises FTS syntax errors.
    public func search(_ query: String, limit: Int = 20) throws -> [SearchHit] {
        guard let match = Self.sanitizeQuery(query) else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        indexed_doc.content_hash AS content_hash,
                        page_fts.page AS page,
                        snippet(page_fts, 0, '«', '»', '…', 12) AS snippet
                    FROM page_fts
                    JOIN indexed_doc ON indexed_doc.id = page_fts.doc_id
                    WHERE page_fts MATCH ?
                    ORDER BY page_fts.rank
                    LIMIT ?
                    """,
                arguments: [match, limit]
            )
            return rows.map { row in
                SearchHit(
                    contentHash: row["content_hash"],
                    page: row["page"],
                    snippet: row["snippet"]
                )
            }
        }
    }

    /// Wraps each whitespace-separated term in double quotes (doubling any
    /// embedded quotes) so bare words and phrases are always valid FTS5 syntax.
    /// Returns nil when the query contains no terms.
    static func sanitizeQuery(_ query: String) -> String? {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return nil }
        return
            terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }
}
