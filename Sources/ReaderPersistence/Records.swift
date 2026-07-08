import Foundation
import GRDB

/// A book in the overlay library. Either Calibre-sourced (`calibreUUID`) or a
/// loose imported PDF (`contentHash`); at least one identity is always set
/// (enforced by a CHECK constraint).
public struct BookRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "book"

    public var id: Int64?
    public var calibreUUID: String?
    public var contentHash: String?
    public var title: String
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case calibreUUID = "calibre_uuid"
        case contentHash = "content_hash"
        case title
        case modifiedAt = "modified_at"
        case deletedAt = "deleted_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Local-only pointer to a book's file on disk. Never synced.
public struct FileRefRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "file_ref"

    public var id: Int64?
    public var bookID: Int64
    public var bookmark: Data?
    public var pathHint: String

    enum CodingKeys: String, CodingKey {
        case id
        case bookID = "book_id"
        case bookmark
        case pathHint = "path_hint"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One row of `LibraryStore.openableBooks()`: what the quick-open palette
/// needs to list and open a book.
public struct OpenableBook: Hashable, Sendable {
    public var bookID: Int64
    public var title: String
    public var pathHint: String

    public init(bookID: Int64, title: String, pathHint: String) {
        self.bookID = bookID
        self.title = title
        self.pathHint = pathHint
    }
}

/// A hierarchical user tag. `parentID == nil` means a root tag.
public struct TagRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "tag"

    public var id: Int64?
    public var name: String
    public var parentID: Int64?
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parent_id"
        case modifiedAt = "modified_at"
        case deletedAt = "deleted_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Book-to-tag association (composite primary key).
public struct BookTagRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "book_tag"

    public var bookID: Int64
    public var tagID: Int64
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case tagID = "tag_id"
        case modifiedAt = "modified_at"
        case deletedAt = "deleted_at"
    }
}

/// A user collection, e.g. a course mixing textbooks and homework PDFs.
/// Hierarchical: `parentID == nil` means a root collection.
public struct CollectionRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "collection"

    public var id: Int64?
    public var name: String
    public var kind: String
    public var parentID: Int64?
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case parentID = "parent_id"
        case modifiedAt = "modified_at"
        case deletedAt = "deleted_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Membership of a book in a collection (composite primary key).
public struct CollectionItemRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "collection_item"

    public var collectionID: Int64
    public var bookID: Int64
    public var sortOrder: Int
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case collectionID = "collection_id"
        case bookID = "book_id"
        case sortOrder = "sort_order"
        case modifiedAt = "modified_at"
        case deletedAt = "deleted_at"
    }
}

/// A user-created bookmark inside a book.
public struct UserBookmarkRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "user_bookmark"

    public var id: Int64?
    public var bookID: Int64
    public var page: Int
    public var label: String?
    public var createdAt: Int64
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case bookID = "book_id"
        case page
        case label
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case deletedAt = "deleted_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Last-read position for a book (one row per book).
public struct ReadingStateRecord: Codable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "reading_state"

    public var bookID: Int64
    public var page: Int
    public var updatedAt: Int64
    public var device: String

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case page
        case updatedAt = "updated_at"
        case device
    }
}

/// A node in the tag hierarchy returned by `LibraryStore.tagTree()`.
public struct TagNode: Hashable, Sendable {
    public var tag: TagRecord
    public var children: [TagNode]

    public init(tag: TagRecord, children: [TagNode] = []) {
        self.tag = tag
        self.children = children
    }
}

/// A node in the collection hierarchy returned by `LibraryStore.collectionTree()`.
public struct CollectionNode: Hashable, Sendable {
    public var collection: CollectionRecord
    public var children: [CollectionNode]

    public init(collection: CollectionRecord, children: [CollectionNode] = []) {
        self.collection = collection
        self.children = children
    }
}

/// A book together with its reading state, as returned by
/// `LibraryStore.recentlyRead(limit:)` (most recently read first).
public struct RecentlyReadEntry: Hashable, Sendable {
    public var book: BookRecord
    public var state: ReadingStateRecord

    public init(book: BookRecord, state: ReadingStateRecord) {
        self.book = book
        self.state = state
    }
}
