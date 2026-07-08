import Foundation
import GRDB

/// The public API of the overlay library database.
///
/// Wraps a `DatabaseQueue` and exposes synchronous, throwing CRUD for books,
/// hierarchical tags, collections, user bookmarks, and reading state.
///
/// Sync-related invariants maintained by every write:
/// - `modified_at` is bumped to the injected clock's current unix ms.
/// - Deletes on synced tables are soft (tombstones with `deleted_at` set);
///   `purgeTombstones(olderThanDays:)` hard-deletes expired tombstones.
public final class LibraryStore: Sendable {
    /// The default clock: current unix time in milliseconds.
    public static let systemClock: @Sendable () -> Int64 = {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Int64

    /// Opens (creating if needed) the library database at `path`.
    public init(path: String, now: @escaping @Sendable () -> Int64 = LibraryStore.systemClock) throws {
        self.dbQueue = try DatabaseQueue(path: path, configuration: Self.configuration())
        self.now = now
        try LibrarySchema.migrator().migrate(dbQueue)
    }

    /// Creates an in-memory library database (for tests and previews).
    public static func inMemory(now: @escaping @Sendable () -> Int64 = LibraryStore.systemClock) throws -> LibraryStore {
        try LibraryStore(dbQueue: DatabaseQueue(configuration: configuration()), now: now)
    }

    private init(dbQueue: DatabaseQueue, now: @escaping @Sendable () -> Int64) throws {
        self.dbQueue = dbQueue
        self.now = now
        try LibrarySchema.migrator().migrate(dbQueue)
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }

    // MARK: - Books

    /// Inserts a Calibre-sourced book, or updates the title of the existing
    /// row with the same `calibre_uuid`. Resurrects a soft-deleted row.
    @discardableResult
    public func upsertCalibreBook(uuid: String, title: String) throws -> BookRecord {
        let ts = now()
        return try dbQueue.write { db in
            if var existing = try BookRecord
                .filter(Column("calibre_uuid") == uuid)
                .fetchOne(db)
            {
                existing.title = title
                existing.modifiedAt = ts
                existing.deletedAt = nil
                try existing.update(db)
                return existing
            }
            var book = BookRecord(
                id: nil, calibreUUID: uuid, contentHash: nil,
                title: title, modifiedAt: ts, deletedAt: nil
            )
            try book.insert(db)
            return book
        }
    }

    /// Inserts a loose imported PDF identified by its content hash, together
    /// with a local-only `file_ref` row pointing at the file on disk.
    @discardableResult
    public func insertLooseBook(
        contentHash: String,
        title: String,
        pathHint: String,
        bookmark: Data? = nil
    ) throws -> BookRecord {
        let ts = now()
        return try dbQueue.write { db in
            var book = BookRecord(
                id: nil, calibreUUID: nil, contentHash: contentHash,
                title: title, modifiedAt: ts, deletedAt: nil
            )
            try book.insert(db)
            var ref = FileRefRecord(
                id: nil, bookID: book.id!, bookmark: bookmark, pathHint: pathHint
            )
            try ref.insert(db)
            return book
        }
    }

    public func book(byContentHash hash: String) throws -> BookRecord? {
        try dbQueue.read { db in
            try BookRecord
                .filter(Column("content_hash") == hash && Column("deleted_at") == nil)
                .fetchOne(db)
        }
    }

    /// Resolves a book through its local file reference (path_hint).
    public func bookID(forPathHint path: String) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT b.id FROM book b JOIN file_ref f ON f.book_id = b.id
                    WHERE f.path_hint = ? AND b.deleted_at IS NULL
                    """,
                arguments: [path]
            )
        }
    }

    /// Backfills a book's content hash (e.g. once the indexer has computed
    /// it for a Calibre-sourced book), unifying hash-based lookups.
    public func setContentHash(bookID: Int64, hash: String) throws {
        let ts = now()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE book SET content_hash = ?, modified_at = ? WHERE id = ? AND content_hash IS NULL",
                arguments: [hash, ts, bookID]
            )
        }
    }

    public func book(id: Int64) throws -> BookRecord? {
        try dbQueue.read { db in
            try BookRecord.fetchOne(db, key: id)
        }
    }

    /// Batch upsert for library scans: one transaction instead of one per
    /// book (the per-row fsync cost dominates first-open time otherwise).
    /// Returns book-row id per calibre uuid.
    public func upsertCalibreBooks(_ books: [(uuid: String, title: String)]) throws -> [String: Int64] {
        let ts = now()
        return try dbQueue.write { db in
            var ids: [String: Int64] = [:]
            for (uuid, title) in books {
                try db.execute(
                    sql: """
                        INSERT INTO book (calibre_uuid, title, modified_at, deleted_at)
                        VALUES (?, ?, ?, NULL)
                        ON CONFLICT(calibre_uuid) DO UPDATE SET
                            title = excluded.title,
                            modified_at = CASE WHEN book.title <> excluded.title
                                               OR book.deleted_at IS NOT NULL
                                          THEN excluded.modified_at ELSE book.modified_at END,
                            deleted_at = NULL
                        """,
                    arguments: [uuid, title, ts]
                )
                if let id = try Int64.fetchOne(
                    db, sql: "SELECT id FROM book WHERE calibre_uuid = ?", arguments: [uuid]
                ) {
                    ids[uuid] = id
                }
            }
            return ids
        }
    }

    public func allBooks(includeDeleted: Bool = false) throws -> [BookRecord] {
        try dbQueue.read { db in
            var request = BookRecord.order(Column("title"))
            if !includeDeleted {
                request = request.filter(Column("deleted_at") == nil)
            }
            return try request.fetchAll(db)
        }
    }

    public func softDeleteBook(id: Int64) throws {
        let ts = now()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE book SET deleted_at = ?, modified_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [ts, ts, id]
            )
        }
    }

    /// The local-only file reference for a book, if one was recorded.
    public func fileRef(forBook bookID: Int64) throws -> FileRefRecord? {
        try dbQueue.read { db in
            try FileRefRecord.filter(Column("book_id") == bookID).fetchOne(db)
        }
    }

    // MARK: - Tags

    @discardableResult
    public func createTag(name: String, parent: Int64? = nil) throws -> TagRecord {
        let ts = now()
        return try dbQueue.write { db in
            var tag = TagRecord(
                id: nil, name: name, parentID: parent, modifiedAt: ts, deletedAt: nil
            )
            try tag.insert(db)
            return tag
        }
    }

    public func renameTag(id: Int64, name: String) throws {
        let ts = now()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tag SET name = ?, modified_at = ? WHERE id = ?",
                arguments: [name, ts, id]
            )
        }
    }

    /// Moves a tag under a new parent (nil = root). Refuses moves that would
    /// create a cycle — onto itself or any of its own descendants — so the
    /// tree stays a tree; returns whether the move happened.
    @discardableResult
    public func setTagParent(id: Int64, parentID: Int64?) throws -> Bool {
        let ts = now()
        return try dbQueue.write { db in
            guard try TagRecord.fetchOne(db, key: id)?.deletedAt == nil else { return false }
            if let parentID {
                guard parentID != id else { return false }
                guard let parent = try TagRecord.fetchOne(db, key: parentID),
                      parent.deletedAt == nil else { return false }
                // Walk up from the target parent; hitting `id` means the
                // target is inside the subtree being moved.
                var cursor = parent.parentID
                while let current = cursor {
                    if current == id { return false }
                    cursor = try TagRecord.fetchOne(db, key: current)?.parentID
                }
            }
            try db.execute(
                sql: "UPDATE tag SET parent_id = ?, modified_at = ? WHERE id = ?",
                arguments: [parentID, ts, id]
            )
            return true
        }
    }

    /// Soft-deletes a tag. Its `book_tag` rows are tombstoned too, and live
    /// child tags are reparented to the deleted tag's own parent.
    public func softDeleteTag(id: Int64) throws {
        let ts = now()
        try dbQueue.write { db in
            guard let tag = try TagRecord.fetchOne(db, key: id) else { return }
            try db.execute(
                sql: "UPDATE tag SET deleted_at = ?, modified_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [ts, ts, id]
            )
            try db.execute(
                sql: "UPDATE book_tag SET deleted_at = ?, modified_at = ? WHERE tag_id = ? AND deleted_at IS NULL",
                arguments: [ts, ts, id]
            )
            try db.execute(
                sql: "UPDATE tag SET parent_id = ?, modified_at = ? WHERE parent_id = ? AND deleted_at IS NULL",
                arguments: [tag.parentID, ts, id]
            )
        }
    }

    /// The live tag hierarchy: root tags with recursively nested children,
    /// each level sorted by name.
    public func tagTree() throws -> [TagNode] {
        try dbQueue.read { db in
            let tags = try TagRecord
                .filter(Column("deleted_at") == nil)
                .order(Column("name"))
                .fetchAll(db)
            var childrenByParent: [Int64?: [TagRecord]] = [:]
            for tag in tags {
                childrenByParent[tag.parentID, default: []].append(tag)
            }
            func nodes(under parent: Int64?) -> [TagNode] {
                (childrenByParent[parent] ?? []).map { tag in
                    TagNode(tag: tag, children: nodes(under: tag.id))
                }
            }
            return nodes(under: nil)
        }
    }

    /// Replaces the full live tag set of a book: tags not in `tagIDs` are
    /// tombstoned, tags in `tagIDs` are inserted or resurrected.
    public func setTags(bookID: Int64, tagIDs: Set<Int64>) throws {
        let ts = now()
        try dbQueue.write { db in
            let existing = try BookTagRecord
                .filter(Column("book_id") == bookID)
                .fetchAll(db)
            let existingByTag = Dictionary(uniqueKeysWithValues: existing.map { ($0.tagID, $0) })

            for row in existing where row.deletedAt == nil && !tagIDs.contains(row.tagID) {
                try db.execute(
                    sql: "UPDATE book_tag SET deleted_at = ?, modified_at = ? WHERE book_id = ? AND tag_id = ?",
                    arguments: [ts, ts, bookID, row.tagID]
                )
            }
            for tagID in tagIDs {
                if let row = existingByTag[tagID] {
                    if row.deletedAt != nil {
                        try db.execute(
                            sql: "UPDATE book_tag SET deleted_at = NULL, modified_at = ? WHERE book_id = ? AND tag_id = ?",
                            arguments: [ts, bookID, tagID]
                        )
                    }
                } else {
                    var row = BookTagRecord(
                        bookID: bookID, tagID: tagID, modifiedAt: ts, deletedAt: nil
                    )
                    try row.insert(db)
                }
            }
        }
    }

    /// The live tags of a book, sorted by name.
    public func tags(forBook bookID: Int64) throws -> [TagRecord] {
        try dbQueue.read { db in
            try TagRecord.fetchAll(
                db,
                sql: """
                    SELECT t.* FROM tag t
                    JOIN book_tag bt ON bt.tag_id = t.id AND bt.deleted_at IS NULL
                    WHERE bt.book_id = ? AND t.deleted_at IS NULL
                    ORDER BY t.name
                    """,
                arguments: [bookID]
            )
        }
    }

    /// The live books tagged with `tagID` — optionally including books tagged
    /// with any live descendant of `tagID` in the hierarchy.
    public func books(withTag tagID: Int64, includeDescendantTags: Bool = false) throws -> [BookRecord] {
        try dbQueue.read { db in
            if includeDescendantTags {
                return try BookRecord.fetchAll(
                    db,
                    sql: """
                        WITH RECURSIVE sub(id) AS (
                            SELECT ?
                            UNION
                            SELECT t.id FROM tag t
                            JOIN sub ON t.parent_id = sub.id
                            WHERE t.deleted_at IS NULL
                        )
                        SELECT DISTINCT b.* FROM book b
                        JOIN book_tag bt ON bt.book_id = b.id AND bt.deleted_at IS NULL
                        JOIN sub ON sub.id = bt.tag_id
                        WHERE b.deleted_at IS NULL
                        ORDER BY b.title
                        """,
                    arguments: [tagID]
                )
            }
            return try BookRecord.fetchAll(
                db,
                sql: """
                    SELECT b.* FROM book b
                    JOIN book_tag bt ON bt.book_id = b.id AND bt.deleted_at IS NULL
                    WHERE bt.tag_id = ? AND b.deleted_at IS NULL
                    ORDER BY b.title
                    """,
                arguments: [tagID]
            )
        }
    }

    /// The live books with no live tag assignment at all — the "Untagged"
    /// smart filter. A book counts as untagged when every `book_tag` row it
    /// has is tombstoned or points at a tombstoned tag.
    public func booksWithoutTags() throws -> [BookRecord] {
        try dbQueue.read { db in
            try BookRecord.fetchAll(
                db,
                sql: """
                    SELECT b.* FROM book b
                    WHERE b.deleted_at IS NULL
                      AND NOT EXISTS (
                        SELECT 1 FROM book_tag bt
                        JOIN tag t ON t.id = bt.tag_id AND t.deleted_at IS NULL
                        WHERE bt.book_id = b.id AND bt.deleted_at IS NULL
                      )
                    ORDER BY b.title
                    """
            )
        }
    }

    /// The live books that belong to no live collection — the "Not in any
    /// collection" smart filter. Tombstoned memberships and memberships in
    /// tombstoned collections don't count.
    public func booksNotInAnyCollection() throws -> [BookRecord] {
        try dbQueue.read { db in
            try BookRecord.fetchAll(
                db,
                sql: """
                    SELECT b.* FROM book b
                    WHERE b.deleted_at IS NULL
                      AND NOT EXISTS (
                        SELECT 1 FROM collection_item ci
                        JOIN collection c ON c.id = ci.collection_id AND c.deleted_at IS NULL
                        WHERE ci.book_id = b.id AND ci.deleted_at IS NULL
                      )
                    ORDER BY b.title
                    """
            )
        }
    }

    // MARK: - Collections

    @discardableResult
    public func collections(includeDeleted: Bool = false) throws -> [CollectionRecord] {
        try dbQueue.read { db in
            var request = CollectionRecord.order(Column("name"))
            if !includeDeleted {
                request = request.filter(Column("deleted_at") == nil)
            }
            return try request.fetchAll(db)
        }
    }

    public func createCollection(name: String, kind: String = "course", parent: Int64? = nil) throws -> CollectionRecord {
        let ts = now()
        return try dbQueue.write { db in
            var collection = CollectionRecord(
                id: nil, name: name, kind: kind, parentID: parent, modifiedAt: ts, deletedAt: nil
            )
            try collection.insert(db)
            return collection
        }
    }

    /// Soft-deletes a collection. Its `collection_item` rows are tombstoned
    /// too, and live child collections are reparented to the deleted
    /// collection's own parent.
    public func softDeleteCollection(id: Int64) throws {
        let ts = now()
        try dbQueue.write { db in
            guard let collection = try CollectionRecord.fetchOne(db, key: id) else { return }
            try db.execute(
                sql: "UPDATE collection SET deleted_at = ?, modified_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [ts, ts, id]
            )
            try db.execute(
                sql: "UPDATE collection_item SET deleted_at = ?, modified_at = ? WHERE collection_id = ? AND deleted_at IS NULL",
                arguments: [ts, ts, id]
            )
            try db.execute(
                sql: "UPDATE collection SET parent_id = ?, modified_at = ? WHERE parent_id = ? AND deleted_at IS NULL",
                arguments: [collection.parentID, ts, id]
            )
        }
    }

    /// The live collection hierarchy: root collections with recursively
    /// nested children, each level sorted by name.
    public func collectionTree() throws -> [CollectionNode] {
        try dbQueue.read { db in
            let collections = try CollectionRecord
                .filter(Column("deleted_at") == nil)
                .order(Column("name"))
                .fetchAll(db)
            var childrenByParent: [Int64?: [CollectionRecord]] = [:]
            for collection in collections {
                childrenByParent[collection.parentID, default: []].append(collection)
            }
            func nodes(under parent: Int64?) -> [CollectionNode] {
                (childrenByParent[parent] ?? []).map { collection in
                    CollectionNode(collection: collection, children: nodes(under: collection.id))
                }
            }
            return nodes(under: nil)
        }
    }

    /// The live books in the collection or any live descendant collection,
    /// de-duplicated and sorted by title.
    public func books(inCollectionSubtree collectionID: Int64) throws -> [BookRecord] {
        try dbQueue.read { db in
            try BookRecord.fetchAll(
                db,
                sql: """
                    WITH RECURSIVE sub(id) AS (
                        SELECT ?
                        UNION
                        SELECT c.id FROM collection c
                        JOIN sub ON c.parent_id = sub.id
                        WHERE c.deleted_at IS NULL
                    )
                    SELECT DISTINCT b.* FROM book b
                    JOIN collection_item ci ON ci.book_id = b.id AND ci.deleted_at IS NULL
                    JOIN sub ON sub.id = ci.collection_id
                    WHERE b.deleted_at IS NULL
                    ORDER BY b.title
                    """,
                arguments: [collectionID]
            )
        }
    }

    /// Adds a book to a collection, resurrecting a tombstoned membership.
    public func addToCollection(collectionID: Int64, bookID: Int64, sortOrder: Int = 0) throws {
        let ts = now()
        try dbQueue.write { db in
            if try CollectionItemRecord
                .filter(Column("collection_id") == collectionID && Column("book_id") == bookID)
                .fetchOne(db) != nil
            {
                try db.execute(
                    sql: """
                        UPDATE collection_item
                        SET deleted_at = NULL, sort_order = ?, modified_at = ?
                        WHERE collection_id = ? AND book_id = ?
                        """,
                    arguments: [sortOrder, ts, collectionID, bookID]
                )
            } else {
                var item = CollectionItemRecord(
                    collectionID: collectionID, bookID: bookID,
                    sortOrder: sortOrder, modifiedAt: ts, deletedAt: nil
                )
                try item.insert(db)
            }
        }
    }

    /// Soft-deletes a book's membership in a collection.
    public func removeFromCollection(collectionID: Int64, bookID: Int64) throws {
        let ts = now()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE collection_item SET deleted_at = ?, modified_at = ?
                    WHERE collection_id = ? AND book_id = ? AND deleted_at IS NULL
                    """,
                arguments: [ts, ts, collectionID, bookID]
            )
        }
    }

    /// The live items of a collection, ordered by `sort_order`.
    public func items(inCollection collectionID: Int64) throws -> [CollectionItemRecord] {
        try dbQueue.read { db in
            try CollectionItemRecord
                .filter(Column("collection_id") == collectionID && Column("deleted_at") == nil)
                .order(Column("sort_order"), Column("book_id"))
                .fetchAll(db)
        }
    }

    /// Rewrites `sort_order` so live items follow `orderedBookIDs`.
    public func reorder(collectionID: Int64, orderedBookIDs: [Int64]) throws {
        let ts = now()
        try dbQueue.write { db in
            for (index, bookID) in orderedBookIDs.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE collection_item SET sort_order = ?, modified_at = ?
                        WHERE collection_id = ? AND book_id = ? AND deleted_at IS NULL
                        """,
                    arguments: [index, ts, collectionID, bookID]
                )
            }
        }
    }

    // MARK: - User bookmarks

    @discardableResult
    public func addBookmark(bookID: Int64, page: Int, label: String? = nil) throws -> UserBookmarkRecord {
        let ts = now()
        return try dbQueue.write { db in
            var bookmark = UserBookmarkRecord(
                id: nil, bookID: bookID, page: page, label: label,
                createdAt: ts, modifiedAt: ts, deletedAt: nil
            )
            try bookmark.insert(db)
            return bookmark
        }
    }

    /// The live bookmarks of a book, ordered by page then creation time.
    public func bookmarks(forBook bookID: Int64) throws -> [UserBookmarkRecord] {
        try dbQueue.read { db in
            try UserBookmarkRecord
                .filter(Column("book_id") == bookID && Column("deleted_at") == nil)
                .order(Column("page"), Column("created_at"))
                .fetchAll(db)
        }
    }

    public func softDeleteBookmark(id: Int64) throws {
        let ts = now()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE user_bookmark SET deleted_at = ?, modified_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [ts, ts, id]
            )
        }
    }

    // MARK: - Reading state

    /// Upserts the last-read position of a book; `updated_at` is set to now.
    public func setReadingState(bookID: Int64, page: Int, device: String) throws {
        let ts = now()
        try dbQueue.write { db in
            var state = ReadingStateRecord(
                bookID: bookID, page: page, updatedAt: ts, device: device
            )
            try state.upsert(db)
        }
    }

    public func readingState(forBook bookID: Int64) throws -> ReadingStateRecord? {
        try dbQueue.read { db in
            try ReadingStateRecord.fetchOne(db, key: bookID)
        }
    }

    /// The most recently read live books, newest first.
    public func recentlyRead(limit: Int = 10) throws -> [RecentlyReadEntry] {
        try dbQueue.read { db in
            let states = try ReadingStateRecord.fetchAll(
                db,
                sql: """
                    SELECT rs.* FROM reading_state rs
                    JOIN book b ON b.id = rs.book_id AND b.deleted_at IS NULL
                    ORDER BY rs.updated_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return try states.compactMap { state in
                guard let book = try BookRecord.fetchOne(db, key: state.bookID) else { return nil }
                return RecentlyReadEntry(book: book, state: state)
            }
        }
    }

    // MARK: - Tombstones

    /// Hard-deletes soft-deleted rows whose tombstone is older than the
    /// cutoff. Returns the number of rows purged.
    @discardableResult
    public func purgeTombstones(olderThanDays days: Int = 30) throws -> Int {
        let cutoff = now() - Int64(days) * 86_400_000
        return try dbQueue.write { db in
            var purged = 0
            // Association tables first, then entities (FK cascades would
            // clean these up anyway, but explicit order keeps counts exact).
            for table in ["book_tag", "collection_item", "user_bookmark", "tag", "collection", "book"] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                    arguments: [cutoff]
                )
                purged += db.changesCount
            }
            return purged
        }
    }
}
