import Foundation
import GRDB

/// Sync support (M15): portable export of the synced tables, LWW apply of
/// remote records, hard-delete apply, and the local-only sync-state tables
/// (shadow / meta / pending). All key formats are documented on the
/// `Portable*` types.
extension LibraryStore {
    // MARK: - Export

    /// Exports every row of the synced tables — tombstones included — in
    /// natural-key form. Local-only tables (`file_ref`, session, index) never
    /// appear.
    ///
    /// Duplicate natural keys (e.g. two root tags with the same name, which
    /// the schema's NULL-scoped unique key cannot prevent) export once: the
    /// live row wins, then the newest `modified_at`.
    public func syncExport() throws -> [PortableRecord] {
        try dbQueue.read { db in
            let books = try BookRecord.fetchAll(db)
            let tags = try TagRecord.fetchAll(db)
            let collections = try CollectionRecord.fetchAll(db)

            let bookKeyByID = Self.bookKeys(books)
            let tagPaths = Self.paths(rows: tags.map { ($0.id!, $0.name, $0.parentID) })
            let collectionPaths = Self.paths(rows: collections.map { ($0.id!, $0.name, $0.parentID) })

            var records: [PortableRecord] = []

            records += books.compactMap { book -> PortableRecord? in
                guard let key = PortableBookKey.key(
                    calibreUUID: book.calibreUUID, contentHash: book.contentHash
                ) else { return nil }
                return .book(PortableBook(
                    key: key, calibreUUID: book.calibreUUID, contentHash: book.contentHash,
                    title: book.title, authors: book.authors, createdAt: book.createdAt,
                    modifiedAt: book.modifiedAt, deletedAt: book.deletedAt
                ))
            }

            // Canonicalize duplicate paths: live first, then newest.
            records += Self.canonical(tags, id: { $0.id! }, paths: tagPaths,
                                      live: { $0.deletedAt == nil }, modified: { $0.modifiedAt })
                .map { tag, path in
                    .tag(PortableTag(
                        path: path, color: tag.color,
                        modifiedAt: tag.modifiedAt, deletedAt: tag.deletedAt
                    ))
                }

            records += Self.canonical(collections, id: { $0.id! }, paths: collectionPaths,
                                      live: { $0.deletedAt == nil }, modified: { $0.modifiedAt })
                .map { collection, path in
                    .collection(PortableCollection(
                        path: path, kind: collection.kind,
                        modifiedAt: collection.modifiedAt, deletedAt: collection.deletedAt
                    ))
                }

            // Relations: map row ids through the key/path tables; rows whose
            // endpoints resolve to the same natural identity dedupe the same
            // way (live wins, then newest).
            var bookTags: [String: PortableBookTag] = [:]
            for row in try BookTagRecord.fetchAll(db) {
                guard let bookKey = bookKeyByID[row.bookID],
                      let tagPath = tagPaths[row.tagID] else { continue }
                let portable = PortableBookTag(
                    bookKey: bookKey, tagPath: tagPath,
                    modifiedAt: row.modifiedAt, deletedAt: row.deletedAt
                )
                let identity = bookKey + "\u{1}" + tagPath.joined(separator: "\u{1}")
                if let existing = bookTags[identity],
                   Self.prefer(existingLive: existing.deletedAt == nil, existingModified: existing.modifiedAt,
                               candidateLive: portable.deletedAt == nil, candidateModified: portable.modifiedAt)
                { continue }
                bookTags[identity] = portable
            }
            records += bookTags.values.map { .bookTag($0) }

            var items: [String: PortableCollectionItem] = [:]
            for row in try CollectionItemRecord.fetchAll(db) {
                guard let bookKey = bookKeyByID[row.bookID],
                      let path = collectionPaths[row.collectionID] else { continue }
                let portable = PortableCollectionItem(
                    collectionPath: path, bookKey: bookKey, sortOrder: row.sortOrder,
                    modifiedAt: row.modifiedAt, deletedAt: row.deletedAt
                )
                let identity = path.joined(separator: "\u{1}") + "\u{1}" + bookKey
                if let existing = items[identity],
                   Self.prefer(existingLive: existing.deletedAt == nil, existingModified: existing.modifiedAt,
                               candidateLive: portable.deletedAt == nil, candidateModified: portable.modifiedAt)
                { continue }
                items[identity] = portable
            }
            records += items.values.map { .collectionItem($0) }

            records += try UserBookmarkRecord.fetchAll(db).compactMap { row -> PortableRecord? in
                guard let bookKey = bookKeyByID[row.bookID] else { return nil }
                return .bookmark(PortableBookmark(
                    bookKey: bookKey, page: row.page, label: row.label,
                    createdAt: row.createdAt, modifiedAt: row.modifiedAt, deletedAt: row.deletedAt
                ))
            }

            records += try ReadingStateRecord.fetchAll(db).compactMap { row -> PortableRecord? in
                guard let bookKey = bookKeyByID[row.bookID] else { return nil }
                return .readingState(PortableReadingState(
                    bookKey: bookKey, page: row.page, updatedAt: row.updatedAt, device: row.device
                ))
            }

            return records
        }
    }

    // MARK: - Apply (remote changes)

    /// Result of applying a batch of remote records.
    public struct SyncApplyResult: Sendable {
        /// Rows written (remote won LWW or was new).
        public var applied: Int = 0
        /// Rows skipped because the local copy was same-or-newer (local wins).
        public var localWins: Int = 0
        /// Records whose endpoints don't exist locally yet — the caller
        /// should stash these and retry next sync.
        public var pending: [PortableRecord] = []
    }

    /// Applies remote records with last-writer-wins by `modified_at`
    /// (`reading_state`: max `updated_at`). Remote timestamps are written
    /// verbatim — apply never bumps clocks, so a losing remote row stays
    /// losing everywhere. Runs in one transaction.
    public func syncApplyRemote(_ records: [PortableRecord]) throws -> SyncApplyResult {
        let ordered = records.sorted {
            ($0.applyRank, $0.pathDepth) < ($1.applyRank, $1.pathDepth)
        }
        return try dbQueue.write { db in
            var result = SyncApplyResult()
            for record in ordered {
                switch record {
                case .book(let p): try Self.apply(p, db: db, result: &result)
                case .tag(let p): try Self.apply(p, db: db, result: &result)
                case .collection(let p): try Self.apply(p, db: db, result: &result)
                case .bookTag(let p):
                    try Self.applyRelation(
                        record, db: db, result: &result,
                        bookKey: p.bookKey, path: p.tagPath, pathTable: "tag",
                        modifiedAt: p.modifiedAt, deletedAt: p.deletedAt
                    ) { db, bookID, tagID in
                        try db.execute(
                            sql: """
                                INSERT INTO book_tag (book_id, tag_id, modified_at, deleted_at)
                                VALUES (?, ?, ?, ?)
                                ON CONFLICT(book_id, tag_id) DO UPDATE
                                SET modified_at = excluded.modified_at, deleted_at = excluded.deleted_at
                                """,
                            arguments: [bookID, tagID, p.modifiedAt, p.deletedAt]
                        )
                    } existingModified: { db, bookID, tagID in
                        try Int64.fetchOne(
                            db, sql: "SELECT modified_at FROM book_tag WHERE book_id = ? AND tag_id = ?",
                            arguments: [bookID, tagID]
                        )
                    }
                case .collectionItem(let p):
                    try Self.applyRelation(
                        record, db: db, result: &result,
                        bookKey: p.bookKey, path: p.collectionPath, pathTable: "collection",
                        modifiedAt: p.modifiedAt, deletedAt: p.deletedAt
                    ) { db, bookID, collectionID in
                        try db.execute(
                            sql: """
                                INSERT INTO collection_item
                                    (collection_id, book_id, sort_order, modified_at, deleted_at)
                                VALUES (?, ?, ?, ?, ?)
                                ON CONFLICT(collection_id, book_id) DO UPDATE
                                SET sort_order = excluded.sort_order,
                                    modified_at = excluded.modified_at,
                                    deleted_at = excluded.deleted_at
                                """,
                            arguments: [collectionID, bookID, p.sortOrder, p.modifiedAt, p.deletedAt]
                        )
                    } existingModified: { db, bookID, collectionID in
                        try Int64.fetchOne(
                            db,
                            sql: "SELECT modified_at FROM collection_item WHERE collection_id = ? AND book_id = ?",
                            arguments: [collectionID, bookID]
                        )
                    }
                case .bookmark(let p): try Self.apply(p, db: db, result: &result)
                case .readingState(let p): try Self.apply(p, db: db, result: &result)
                }
            }
            return result
        }
    }

    /// Hard-deletes rows for records the server no longer has (tombstone
    /// purges elsewhere, or identity-changing edits like tag renames whose
    /// old records were removed). Children delete before parents; a tag or
    /// collection that still has children locally is skipped (its children's
    /// own deletions arrive in the same batch when the server intends the
    /// subtree gone).
    public func syncApplyRemoteDeletes(_ records: [PortableRecord]) throws -> Int {
        let ordered = records.sorted {
            ($0.applyRank, $0.pathDepth) > ($1.applyRank, $1.pathDepth)
        }
        return try dbQueue.write { db in
            var deleted = 0
            for record in ordered {
                switch record {
                case .book(let p):
                    guard let id = try Self.bookID(forKey: p.key, db: db) else { continue }
                    try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [id])
                    deleted += db.changesCount
                case .tag(let p):
                    guard let id = try Self.rowID(atPath: p.path, table: "tag", db: db) else { continue }
                    let children = try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM tag WHERE parent_id = ?", arguments: [id]
                    ) ?? 0
                    guard children == 0 else { continue }
                    try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
                    deleted += db.changesCount
                case .collection(let p):
                    guard let id = try Self.rowID(atPath: p.path, table: "collection", db: db) else { continue }
                    let children = try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM collection WHERE parent_id = ?", arguments: [id]
                    ) ?? 0
                    guard children == 0 else { continue }
                    try db.execute(sql: "DELETE FROM collection WHERE id = ?", arguments: [id])
                    deleted += db.changesCount
                case .bookTag(let p):
                    guard let bookID = try Self.bookID(forKey: p.bookKey, db: db),
                          let tagID = try Self.rowID(atPath: p.tagPath, table: "tag", db: db)
                    else { continue }
                    try db.execute(
                        sql: "DELETE FROM book_tag WHERE book_id = ? AND tag_id = ?",
                        arguments: [bookID, tagID]
                    )
                    deleted += db.changesCount
                case .collectionItem(let p):
                    guard let bookID = try Self.bookID(forKey: p.bookKey, db: db),
                          let collectionID = try Self.rowID(atPath: p.collectionPath, table: "collection", db: db)
                    else { continue }
                    try db.execute(
                        sql: "DELETE FROM collection_item WHERE collection_id = ? AND book_id = ?",
                        arguments: [collectionID, bookID]
                    )
                    deleted += db.changesCount
                case .bookmark(let p):
                    guard let bookID = try Self.bookID(forKey: p.bookKey, db: db) else { continue }
                    try db.execute(
                        sql: "DELETE FROM user_bookmark WHERE book_id = ? AND created_at = ? AND page = ?",
                        arguments: [bookID, p.createdAt, p.page]
                    )
                    deleted += db.changesCount
                case .readingState(let p):
                    guard let bookID = try Self.bookID(forKey: p.bookKey, db: db) else { continue }
                    try db.execute(
                        sql: "DELETE FROM reading_state WHERE book_id = ?", arguments: [bookID]
                    )
                    deleted += db.changesCount
                }
            }
            return deleted
        }
    }

    // MARK: - Per-type apply

    private static func apply(_ p: PortableBook, db: Database, result: inout SyncApplyResult) throws {
        guard let identities = PortableBookKey.identities(of: p.key) else { return }
        let existing: BookRecord? =
            if let uuid = identities.calibreUUID {
                try BookRecord.filter(Column("calibre_uuid") == uuid).fetchOne(db)
            } else if let hash = identities.contentHash {
                try BookRecord.filter(Column("content_hash") == hash).fetchOne(db)
            } else { nil }

        if var row = existing {
            guard p.modifiedAt > row.modifiedAt else {
                result.localWins += 1
                return
            }
            row.title = p.title
            row.authors = p.authors
            row.createdAt = row.createdAt ?? p.createdAt
            row.modifiedAt = p.modifiedAt
            row.deletedAt = p.deletedAt
            // Secondary identity travels along unless it would collide with a
            // DIFFERENT local row (the known Calibre-twin situation — never
            // merge rows implicitly).
            row.contentHash = try uniqueOrNil(
                p.contentHash, current: row.contentHash, column: "content_hash",
                excludingID: row.id!, db: db
            )
            row.calibreUUID = try uniqueOrNil(
                p.calibreUUID, current: row.calibreUUID, column: "calibre_uuid",
                excludingID: row.id!, db: db
            )
            try row.update(db)
            result.applied += 1
        } else {
            var row = BookRecord(
                id: nil,
                calibreUUID: try uniqueOrNil(p.calibreUUID, current: identities.calibreUUID,
                                             column: "calibre_uuid", excludingID: -1, db: db),
                contentHash: try uniqueOrNil(p.contentHash, current: identities.contentHash,
                                             column: "content_hash", excludingID: -1, db: db),
                title: p.title, authors: p.authors,
                modifiedAt: p.modifiedAt, deletedAt: p.deletedAt,
                createdAt: p.createdAt ?? p.modifiedAt
            )
            // The key's own identity must survive the uniqueness guard, or the
            // record has no anchor at all.
            guard row.calibreUUID != nil || row.contentHash != nil else {
                result.localWins += 1
                return
            }
            try row.insert(db)
            result.applied += 1
        }
    }

    /// Keeps `incoming` unless another row (id != excludingID) already holds
    /// that value in a unique column; falls back to the row's current value.
    private static func uniqueOrNil(
        _ incoming: String?, current: String?, column: String, excludingID: Int64, db: Database
    ) throws -> String? {
        guard let incoming else { return current }
        if incoming == current { return current }
        let taken = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM book WHERE \(column) = ? AND id != ?",
            arguments: [incoming, excludingID]
        ) ?? 0
        return taken > 0 ? current : incoming
    }

    private static func apply(_ p: PortableTag, db: Database, result: inout SyncApplyResult) throws {
        guard let name = p.path.last else { return }
        let parentID = try ensurePath(
            Array(p.path.dropLast()), table: "tag", stubModifiedAt: p.modifiedAt, db: db
        )
        if let existing = try row(named: name, parent: parentID, table: "tag", db: db) {
            guard p.modifiedAt > existing.modifiedAt else {
                result.localWins += 1
                return
            }
            try db.execute(
                sql: "UPDATE tag SET color = ?, modified_at = ?, deleted_at = ? WHERE id = ?",
                arguments: [p.color, p.modifiedAt, p.deletedAt, existing.id]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO tag (name, parent_id, color, modified_at, deleted_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [name, parentID, p.color, p.modifiedAt, p.deletedAt]
            )
        }
        result.applied += 1
    }

    private static func apply(_ p: PortableCollection, db: Database, result: inout SyncApplyResult) throws {
        guard let name = p.path.last else { return }
        let parentID = try ensurePath(
            Array(p.path.dropLast()), table: "collection", stubModifiedAt: p.modifiedAt, db: db
        )
        if let existing = try row(named: name, parent: parentID, table: "collection", db: db) {
            guard p.modifiedAt > existing.modifiedAt else {
                result.localWins += 1
                return
            }
            try db.execute(
                sql: "UPDATE collection SET kind = ?, modified_at = ?, deleted_at = ? WHERE id = ?",
                arguments: [p.kind, p.modifiedAt, p.deletedAt, existing.id]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO collection (name, kind, parent_id, modified_at, deleted_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [name, p.kind, parentID, p.modifiedAt, p.deletedAt]
            )
        }
        result.applied += 1
    }

    private static func applyRelation(
        _ record: PortableRecord, db: Database, result: inout SyncApplyResult,
        bookKey: String, path: [String], pathTable: String,
        modifiedAt: Int64, deletedAt: Int64?,
        upsert: (Database, Int64, Int64) throws -> Void,
        existingModified: (Database, Int64, Int64) throws -> Int64?
    ) throws {
        guard let bookID = try bookID(forKey: bookKey, db: db),
              let endpointID = try rowID(atPath: path, table: pathTable, db: db)
        else {
            result.pending.append(record)
            return
        }
        if let localModified = try existingModified(db, bookID, endpointID),
           localModified >= modifiedAt
        {
            result.localWins += 1
            return
        }
        try upsert(db, bookID, endpointID)
        result.applied += 1
    }

    private static func apply(_ p: PortableBookmark, db: Database, result: inout SyncApplyResult) throws {
        guard let bookID = try bookID(forKey: p.bookKey, db: db) else {
            result.pending.append(.bookmark(p))
            return
        }
        let existing = try Row.fetchOne(
            db, sql: "SELECT id, modified_at FROM user_bookmark WHERE book_id = ? AND created_at = ? AND page = ?",
            arguments: [bookID, p.createdAt, p.page]
        )
        if let existing {
            guard p.modifiedAt > (existing["modified_at"] as Int64) else {
                result.localWins += 1
                return
            }
            try db.execute(
                sql: "UPDATE user_bookmark SET label = ?, modified_at = ?, deleted_at = ? WHERE id = ?",
                arguments: [p.label, p.modifiedAt, p.deletedAt, existing["id"] as Int64]
            )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO user_bookmark (book_id, page, label, created_at, modified_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [bookID, p.page, p.label, p.createdAt, p.modifiedAt, p.deletedAt]
            )
        }
        result.applied += 1
    }

    private static func apply(_ p: PortableReadingState, db: Database, result: inout SyncApplyResult) throws {
        guard let bookID = try bookID(forKey: p.bookKey, db: db) else {
            result.pending.append(.readingState(p))
            return
        }
        let localUpdated = try Int64.fetchOne(
            db, sql: "SELECT updated_at FROM reading_state WHERE book_id = ?", arguments: [bookID]
        )
        if let localUpdated, localUpdated >= p.updatedAt {
            result.localWins += 1
            return
        }
        try db.execute(
            sql: """
                INSERT INTO reading_state (book_id, page, updated_at, device)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(book_id) DO UPDATE
                SET page = excluded.page, updated_at = excluded.updated_at, device = excluded.device
                """,
            arguments: [bookID, p.page, p.updatedAt, p.device]
        )
        result.applied += 1
    }

    // MARK: - Key / path resolution

    private static func bookKeys(_ books: [BookRecord]) -> [Int64: String] {
        var map: [Int64: String] = [:]
        for book in books {
            if let key = PortableBookKey.key(calibreUUID: book.calibreUUID, contentHash: book.contentHash) {
                map[book.id!] = key
            }
        }
        return map
    }

    private static func bookID(forKey key: String, db: Database) throws -> Int64? {
        guard let identities = PortableBookKey.identities(of: key) else { return nil }
        if let uuid = identities.calibreUUID {
            return try Int64.fetchOne(
                db, sql: "SELECT id FROM book WHERE calibre_uuid = ?", arguments: [uuid]
            )
        }
        if let hash = identities.contentHash {
            return try Int64.fetchOne(
                db, sql: "SELECT id FROM book WHERE content_hash = ?", arguments: [hash]
            )
        }
        return nil
    }

    /// Builds id → root path for a self-referential (id, name, parent_id)
    /// table, tolerating tombstoned ancestors (paths resolve through them).
    private static func paths(rows: [(id: Int64, name: String, parentID: Int64?)]) -> [Int64: [String]] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var cache: [Int64: [String]] = [:]
        func path(of id: Int64, guard depth: Int = 0) -> [String] {
            if let hit = cache[id] { return hit }
            guard depth < 128, let row = byID[id] else { return [] }
            let result = (row.parentID.map { path(of: $0, guard: depth + 1) } ?? []) + [row.name]
            cache[id] = result
            return result
        }
        for row in rows { _ = path(of: row.id) }
        return cache
    }

    /// One row per distinct path: live wins, then newest `modified_at`.
    private static func canonical<T>(
        _ rows: [T], id: (T) -> Int64, paths: [Int64: [String]],
        live: (T) -> Bool, modified: (T) -> Int64
    ) -> [(T, [String])] {
        var byPath: [String: (T, [String])] = [:]
        for row in rows {
            guard let path = paths[id(row)], !path.isEmpty else { continue }
            let key = path.joined(separator: "\u{1}")
            if let (existing, _) = byPath[key],
               prefer(existingLive: live(existing), existingModified: modified(existing),
                      candidateLive: live(row), candidateModified: modified(row))
            { continue }
            byPath[key] = (row, path)
        }
        return Array(byPath.values)
    }

    /// True when the existing row should be kept over the candidate.
    private static func prefer(
        existingLive: Bool, existingModified: Int64,
        candidateLive: Bool, candidateModified: Int64
    ) -> Bool {
        if existingLive != candidateLive { return existingLive }
        return existingModified >= candidateModified
    }

    private struct PathRow {
        var id: Int64
        var modifiedAt: Int64
        var deletedAt: Int64?
    }

    /// The canonical row named `name` under `parent` (live preferred, then
    /// newest) in `tag` or `collection`.
    private static func row(
        named name: String, parent: Int64?, table: String, db: Database
    ) throws -> PathRow? {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, modified_at, deleted_at FROM \(table)
                WHERE name = ? AND parent_id IS ?
                ORDER BY (deleted_at IS NULL) DESC, modified_at DESC
                """,
            arguments: [name, parent]
        )
        guard let first = rows.first else { return nil }
        return PathRow(id: first["id"], modifiedAt: first["modified_at"], deletedAt: first["deleted_at"])
    }

    private static func rowID(atPath path: [String], table: String, db: Database) throws -> Int64? {
        var parent: Int64?
        for segment in path {
            guard let found = try row(named: segment, parent: parent, table: table, db: db) else {
                return nil
            }
            parent = found.id
        }
        return parent
    }

    /// Resolves a parent path, creating missing ancestors as live stubs with
    /// the child's timestamp (their own records normally arrive in the same
    /// batch and win or lose LWW independently). Returns the deepest id, or
    /// nil for a root path.
    private static func ensurePath(
        _ path: [String], table: String, stubModifiedAt: Int64, db: Database
    ) throws -> Int64? {
        var parent: Int64?
        for segment in path {
            if let found = try row(named: segment, parent: parent, table: table, db: db) {
                parent = found.id
            } else {
                let defaults = table == "collection" ? ", kind" : ""
                let defaultValues = table == "collection" ? ", 'course'" : ""
                try db.execute(
                    sql: """
                        INSERT INTO \(table) (name, parent_id, modified_at, deleted_at\(defaults))
                        VALUES (?, ?, ?, NULL\(defaultValues))
                        """,
                    arguments: [segment, parent, stubModifiedAt]
                )
                parent = db.lastInsertedRowID
            }
        }
        return parent
    }

    // MARK: - Sync state (shadow / meta / pending)

    /// One shadow entry: the last server-confirmed wire record. `payload` is
    /// opaque to ReaderPersistence (SyncKit encodes it).
    public struct SyncShadowRow: Hashable, Sendable {
        public var name: String
        public var type: String
        public var payload: Data
        public var changeTag: String?

        public init(name: String, type: String, payload: Data, changeTag: String?) {
            self.name = name
            self.type = type
            self.payload = payload
            self.changeTag = changeTag
        }
    }

    public func syncShadowAll() throws -> [SyncShadowRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT record_name, record_type, payload, change_tag FROM sync_shadow")
                .map {
                    SyncShadowRow(
                        name: $0["record_name"], type: $0["record_type"],
                        payload: $0["payload"], changeTag: $0["change_tag"]
                    )
                }
        }
    }

    public func syncShadowUpsert(_ rows: [SyncShadowRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO sync_shadow (record_name, record_type, payload, change_tag)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(record_name) DO UPDATE
                        SET record_type = excluded.record_type,
                            payload = excluded.payload,
                            change_tag = excluded.change_tag
                        """,
                    arguments: [row.name, row.type, row.payload, row.changeTag]
                )
            }
        }
    }

    public func syncShadowDelete(names: [String]) throws {
        guard !names.isEmpty else { return }
        try dbQueue.write { db in
            for name in names {
                try db.execute(sql: "DELETE FROM sync_shadow WHERE record_name = ?", arguments: [name])
            }
        }
    }

    /// Drops ALL sync state (shadow, meta, pending) — used when sync is
    /// disabled/re-enabled or the server zone was reset, so the next sync
    /// starts from a clean full exchange.
    public func syncStateReset() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_shadow")
            try db.execute(sql: "DELETE FROM sync_meta")
            try db.execute(sql: "DELETE FROM sync_pending")
        }
    }

    public func syncMetaGet(_ key: String) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [key])
        }
    }

    public func syncMetaSet(_ key: String, _ value: Data?) throws {
        try dbQueue.write { db in
            if let value {
                try db.execute(
                    sql: """
                        INSERT INTO sync_meta (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM sync_meta WHERE key = ?", arguments: [key])
            }
        }
    }

    public func syncPendingAll() throws -> [(name: String, payload: Data)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT record_name, payload FROM sync_pending ORDER BY first_seen")
                .map { ($0["record_name"], $0["payload"]) }
        }
    }

    /// Replaces the whole pending set (the engine recomputes it every sync).
    public func syncPendingReplace(_ rows: [(name: String, payload: Data)]) throws {
        let ts = now()
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_pending")
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO sync_pending (record_name, payload, first_seen) VALUES (?, ?, ?)",
                    arguments: [row.name, row.payload, ts]
                )
            }
        }
    }
}
