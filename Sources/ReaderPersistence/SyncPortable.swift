import Foundation

/// Portable, natural-key representations of the synced library tables (M15).
///
/// Row ids are device-local and never travel; identity across devices is:
/// - book: `"cal:<calibre_uuid>"` or `"sha:<content_hash>"` (calibre wins
///   when a row has both — see `PortableBookKey`)
/// - tag / collection: the full name path from the root (`["Math", "Algebra"]`)
/// - book_tag / collection_item: the concatenation of their endpoints' keys
/// - user_bookmark: `(bookKey, createdAt, page)` — created_at never changes
/// - reading_state: bookKey (one row per book)
///
/// Tombstones are portable too: a soft-deleted row exports as a record with
/// `deletedAt` set, so deletion propagates with LWW semantics instead of
/// racing against re-creation. Hard deletes (tombstone purges) surface as
/// record deletions at the transport level.
public enum PortableBookKey {
    /// Builds the canonical identity key for a book row. Calibre identity
    /// wins when both are present so the key never flips when a content hash
    /// is backfilled onto a Calibre row.
    public static func key(calibreUUID: String?, contentHash: String?) -> String? {
        if let uuid = calibreUUID { return "cal:" + uuid }
        if let hash = contentHash { return "sha:" + hash }
        return nil
    }

    /// Splits a key back into (calibreUUID, contentHash) — exactly one is set.
    public static func identities(of key: String) -> (calibreUUID: String?, contentHash: String?)? {
        if key.hasPrefix("cal:") { return (String(key.dropFirst(4)), nil) }
        if key.hasPrefix("sha:") { return (nil, String(key.dropFirst(4))) }
        return nil
    }
}

public struct PortableBook: Codable, Hashable, Sendable {
    public var key: String
    public var calibreUUID: String?
    public var contentHash: String?
    public var title: String
    public var authors: String?
    public var createdAt: Int64?
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    public init(
        key: String, calibreUUID: String?, contentHash: String?, title: String,
        authors: String?, createdAt: Int64?, modifiedAt: Int64, deletedAt: Int64?
    ) {
        self.key = key
        self.calibreUUID = calibreUUID
        self.contentHash = contentHash
        self.title = title
        self.authors = authors
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct PortableTag: Codable, Hashable, Sendable {
    /// Name path from the root; the last segment is the tag's own name.
    public var path: [String]
    public var color: String?
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    public init(path: [String], color: String?, modifiedAt: Int64, deletedAt: Int64?) {
        self.path = path
        self.color = color
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct PortableCollection: Codable, Hashable, Sendable {
    public var path: [String]
    public var kind: String
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    public init(path: [String], kind: String, modifiedAt: Int64, deletedAt: Int64?) {
        self.path = path
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct PortableBookTag: Codable, Hashable, Sendable {
    public var bookKey: String
    public var tagPath: [String]
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    public init(bookKey: String, tagPath: [String], modifiedAt: Int64, deletedAt: Int64?) {
        self.bookKey = bookKey
        self.tagPath = tagPath
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct PortableCollectionItem: Codable, Hashable, Sendable {
    public var collectionPath: [String]
    public var bookKey: String
    public var sortOrder: Int
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    public init(
        collectionPath: [String], bookKey: String, sortOrder: Int,
        modifiedAt: Int64, deletedAt: Int64?
    ) {
        self.collectionPath = collectionPath
        self.bookKey = bookKey
        self.sortOrder = sortOrder
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct PortableBookmark: Codable, Hashable, Sendable {
    public var bookKey: String
    public var page: Int
    public var label: String?
    public var createdAt: Int64
    public var modifiedAt: Int64
    public var deletedAt: Int64?

    public init(
        bookKey: String, page: Int, label: String?, createdAt: Int64,
        modifiedAt: Int64, deletedAt: Int64?
    ) {
        self.bookKey = bookKey
        self.page = page
        self.label = label
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct PortableReadingState: Codable, Hashable, Sendable {
    public var bookKey: String
    public var page: Int
    public var updatedAt: Int64
    public var device: String

    public init(bookKey: String, page: Int, updatedAt: Int64, device: String) {
        self.bookKey = bookKey
        self.page = page
        self.updatedAt = updatedAt
        self.device = device
    }
}

/// One synced row in natural-key form.
public enum PortableRecord: Codable, Hashable, Sendable {
    case book(PortableBook)
    case tag(PortableTag)
    case collection(PortableCollection)
    case bookTag(PortableBookTag)
    case collectionItem(PortableCollectionItem)
    case bookmark(PortableBookmark)
    case readingState(PortableReadingState)

    /// Stable ordering rank so batches apply parents/endpoints before the
    /// rows that reference them.
    public var applyRank: Int {
        switch self {
        case .book: 0
        case .tag: 1
        case .collection: 2
        case .bookTag: 3
        case .collectionItem: 4
        case .bookmark: 5
        case .readingState: 6
        }
    }

    /// Depth used to order rows of the same rank (parents before children on
    /// apply; children before parents on delete).
    public var pathDepth: Int {
        switch self {
        case .tag(let t): t.path.count
        case .collection(let c): c.path.count
        default: 0
        }
    }
}
