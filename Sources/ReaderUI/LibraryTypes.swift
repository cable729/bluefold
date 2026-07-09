import Foundation

/// One book in the library UI, whichever source it came from.
public struct LibraryItem: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case calibre(uuid: String)
        case imported
    }

    public var id: String
    public var source: Source
    public var title: String
    public var authors: [String]
    public var calibreTags: [String]
    public var fileURL: URL
    public var coverURL: URL?
    /// When the book entered the library: Calibre's `timestamp` for Calibre
    /// books, the overlay row's `created_at` for the app's own imports.
    public var addedAt: Date?

    public init(
        id: String,
        source: Source,
        title: String,
        authors: [String],
        calibreTags: [String],
        fileURL: URL,
        coverURL: URL? = nil,
        addedAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.authors = authors
        self.calibreTags = calibreTags
        self.fileURL = fileURL
        self.coverURL = coverURL
        self.addedAt = addedAt
    }
}

/// The (mtime, size) of a watched-folder file at last reconciliation —
/// rescans skip hashing files whose fingerprint hasn't moved.
struct WatchedFileFingerprint: Equatable, Sendable {
    var mtimeMS: Int64
    var size: Int
}

/// One full-text search match in a library book (M13 "In Book Text").
public struct BookSearchHit: Identifiable, Equatable, Sendable {
    /// `"<contentHash>-<page>"` — stable across searches.
    public let id: String
    /// The `LibraryItem.id` the hit belongs to.
    public let itemID: String
    /// Book title, for display.
    public let title: String
    /// 1-based page number, as stored in the index.
    public let page: Int
    /// Matched text with «…» highlight markers.
    public let snippet: String

    public init(id: String, itemID: String, title: String, page: Int, snippet: String) {
        self.id = id
        self.itemID = itemID
        self.title = title
        self.page = page
        self.snippet = snippet
    }
}

/// What the grid is currently scoped to (sidebar selection).
public enum LibraryFilter: Hashable {
    case all
    case tag(Int64)
    case collection(Int64)
    /// Smart filter: books with no live overlay tag.
    case untagged
    /// Smart filter: books in no live collection.
    case notInAnyCollection
}
