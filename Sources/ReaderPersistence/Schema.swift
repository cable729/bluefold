import GRDB

/// The overlay library database schema.
///
/// Every table that will sync via CloudKit carries `modified_at` (Int64 unix
/// milliseconds) and a soft-delete tombstone `deleted_at` (Int64 unix
/// milliseconds, NULL = live). `file_ref` is local-only and never synced.
enum LibrarySchema {
    /// Builds the migrator for the overlay library database.
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // A book known to the app: either Calibre-sourced (calibre_uuid)
            // or a loose imported PDF (content_hash). At least one identity
            // must be present.
            try db.create(table: "book") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("calibre_uuid", .text).unique()
                t.column("content_hash", .text).unique()
                t.column("title", .text).notNull()
                t.column("modified_at", .integer).notNull()
                t.column("deleted_at", .integer)
                t.check(sql: "calibre_uuid IS NOT NULL OR content_hash IS NOT NULL")
            }

            // Local-only pointer to the file on disk (security-scoped
            // bookmark + human-readable path hint). Never synced.
            try db.create(table: "file_ref") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("book_id", .integer).notNull()
                    .references("book", onDelete: .cascade)
                t.column("bookmark", .blob)
                t.column("path_hint", .text).notNull()
            }

            // Hierarchical user tags (parent_id NULL = root).
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("parent_id", .integer).references("tag")
                t.column("modified_at", .integer).notNull()
                t.column("deleted_at", .integer)
                t.uniqueKey(["name", "parent_id"])
            }

            try db.create(table: "book_tag") { t in
                t.column("book_id", .integer).notNull()
                    .references("book", onDelete: .cascade)
                t.column("tag_id", .integer).notNull()
                    .references("tag", onDelete: .cascade)
                t.column("modified_at", .integer).notNull()
                t.column("deleted_at", .integer)
                t.primaryKey(["book_id", "tag_id"])
            }

            // Collections, e.g. a course mixing textbooks and homework PDFs.
            try db.create(table: "collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull().defaults(to: "course")
                t.column("modified_at", .integer).notNull()
                t.column("deleted_at", .integer)
            }

            try db.create(table: "collection_item") { t in
                t.column("collection_id", .integer).notNull()
                    .references("collection", onDelete: .cascade)
                t.column("book_id", .integer).notNull()
                    .references("book", onDelete: .cascade)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("modified_at", .integer).notNull()
                t.column("deleted_at", .integer)
                t.primaryKey(["collection_id", "book_id"])
            }

            try db.create(table: "user_bookmark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("book_id", .integer).notNull()
                    .references("book", onDelete: .cascade)
                t.column("page", .integer).notNull()
                t.column("label", .text)
                t.column("created_at", .integer).notNull()
                t.column("modified_at", .integer).notNull()
                t.column("deleted_at", .integer)
            }

            // One row per book; last-read position. No tombstone: rows live
            // and die with their book.
            try db.create(table: "reading_state") { t in
                t.column("book_id", .integer).primaryKey()
                    .references("book", onDelete: .cascade)
                t.column("page", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("device", .text).notNull()
            }

            try db.create(index: "idx_tag_parent_id", on: "tag", columns: ["parent_id"])
            try db.create(index: "idx_book_tag_tag_id", on: "book_tag", columns: ["tag_id"])
            try db.create(index: "idx_collection_item_book_id", on: "collection_item", columns: ["book_id"])
            try db.create(index: "idx_book_calibre_uuid", on: "book", columns: ["calibre_uuid"])
            try db.create(index: "idx_book_content_hash", on: "book", columns: ["content_hash"])
        }

        return migrator
    }
}
