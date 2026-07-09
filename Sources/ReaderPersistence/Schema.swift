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

        migrator.registerMigration("v2") { db in
            // Hierarchical collections (parent_id NULL = root), mirroring tags.
            try db.alter(table: "collection") { t in
                t.add(column: "parent_id", .integer).references("collection")
            }
            try db.create(index: "idx_collection_parent_id", on: "collection", columns: ["parent_id"])
        }

        migrator.registerMigration("v3") { db in
            // Authors, mirrored from Calibre at library reload — quick-open
            // must match "dummit" even though the title is "Abstract
            // Algebra, 3rd Edition" (overlay titles carry no author).
            try db.alter(table: "book") { t in
                t.add(column: "authors", .text)
            }
        }

        migrator.registerMigration("v4") { db in
            // Tag colors (round 7): a "#RRGGBB" hex string, NULL = colorless.
            // Stored as plain text (not a preset index) so CloudKit sync
            // carries it verbatim and the UI palette can evolve without
            // another migration; setTagColor bumps modified_at.
            try db.alter(table: "tag") { t in
                t.add(column: "color", .text)
            }
        }

        migrator.registerMigration("v5") { db in
            // Date added — the library list view's sort column. Imports set
            // it at insert; pre-v5 rows backfill from modified_at (the
            // closest existing proxy). Calibre-sourced books display
            // Calibre's own `timestamp` instead, so this mostly matters for
            // the app's own imports.
            try db.alter(table: "book") { t in
                t.add(column: "created_at", .integer)
            }
            try db.execute(sql: "UPDATE book SET created_at = modified_at")
        }

        migrator.registerMigration("v6") { db in
            // Local-only CloudKit sync state (M15). None of these tables are
            // themselves synced.
            //
            // sync_shadow: the last server-confirmed wire record per record
            // name — the diff base for pushes AND the record-name → natural-key
            // resolver for incoming deletes (record names are opaque identity;
            // they are never parsed). payload is an opaque SyncKit-encoded
            // blob; ReaderPersistence just stores it.
            try db.create(table: "sync_shadow") { t in
                t.column("record_name", .text).primaryKey()
                t.column("record_type", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("change_tag", .text)
            }
            // sync_meta: small KV store (server change token, etc.).
            try db.create(table: "sync_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .blob).notNull()
            }
            // sync_pending: fetched records that could not be applied yet
            // (e.g. a book_tag whose book record hasn't arrived) — retried at
            // the start of every sync.
            try db.create(table: "sync_pending") { t in
                t.column("record_name", .text).primaryKey()
                t.column("payload", .blob).notNull()
                t.column("first_seen", .integer).notNull()
            }
        }

        return migrator
    }
}
