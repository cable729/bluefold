import Foundation

/// A book in a Calibre library, as read from `metadata.db`.
///
/// Only books that have at least one PDF file are surfaced by
/// ``CalibreLibrary/fetchBooks()``. The `uuid` is Calibre's stable
/// cross-device identifier for the book; `id` is the library-local row id.
public struct CalibreBook: Sendable, Equatable, Identifiable {
    /// Calibre's library-local book id (`books.id`).
    public let id: Int64

    /// Calibre's stable cross-device book identifier (`books.uuid`).
    public let uuid: String

    /// Display title.
    public let title: String

    /// Title used for sorting (`books.sort`).
    public let sortTitle: String

    /// Author display names, in Calibre's author order.
    public let authors: [String]

    /// Calibre tag names attached to the book, sorted alphabetically.
    public let calibreTags: [String]

    /// Paths of the book's PDF files, relative to the library root
    /// (`<books.path>/<data.name>.pdf`).
    public let relativePDFPaths: [String]

    /// Path of the cover image relative to the library root
    /// (`<books.path>/cover.jpg`), or nil when the book has no cover.
    public let coverRelativePath: String?

    /// Publication date, or nil when Calibre has no (defined) date.
    public let pubdate: Date?

    /// When the book was added to the Calibre library (`books.timestamp`),
    /// or nil when Calibre has no (defined) date.
    public let addedAt: Date?

    public init(
        id: Int64,
        uuid: String,
        title: String,
        sortTitle: String,
        authors: [String],
        calibreTags: [String],
        relativePDFPaths: [String],
        coverRelativePath: String?,
        pubdate: Date?,
        addedAt: Date? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.title = title
        self.sortTitle = sortTitle
        self.authors = authors
        self.calibreTags = calibreTags
        self.relativePDFPaths = relativePDFPaths
        self.coverRelativePath = coverRelativePath
        self.pubdate = pubdate
        self.addedAt = addedAt
    }
}
