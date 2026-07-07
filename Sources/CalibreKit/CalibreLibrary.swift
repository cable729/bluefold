import Foundation
import GRDB

/// Strictly read-only access to a Calibre library on disk.
///
/// A Calibre library is a folder containing `metadata.db` (SQLite) plus one
/// subfolder per book (`<Author>/<Title (id)>/`) holding the book files and
/// `cover.jpg`.
///
/// The live `metadata.db` is NEVER opened: Calibre may be writing to it, and
/// the file may live on iCloud Drive. Instead, the initializer copies it to a
/// private temporary location (inside an `NSFileCoordinator` coordinated read
/// when possible) and opens the copy read-only. The copy is deleted when the
/// library object is deallocated.
public final class CalibreLibrary: Sendable {
    /// The library root folder (the one containing `metadata.db`).
    public let libraryRoot: URL

    private let dbQueue: DatabaseQueue
    private let tempDirectory: URL

    /// Copies `metadata.db` aside and opens the copy read-only.
    ///
    /// - Throws: ``CalibreError/metadataNotFound(_:)`` when the library has no
    ///   `metadata.db`, ``CalibreError/copyFailed(underlying:)`` when the copy
    ///   cannot be made, or ``CalibreError/queryFailed(underlying:)`` when the
    ///   copy cannot be opened as a SQLite database.
    public init(libraryRoot: URL) throws {
        self.libraryRoot = libraryRoot
        let source = libraryRoot.appendingPathComponent("metadata.db", isDirectory: false)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            throw CalibreError.metadataNotFound(source)
        }

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CalibreKit-\(UUID().uuidString)", isDirectory: true)
        let destination = tempDirectory.appendingPathComponent("metadata.db", isDirectory: false)
        do {
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            throw CalibreError.copyFailed(underlying: error)
        }
        self.tempDirectory = tempDirectory

        // Coordinated read around the copy; falls back to a plain copy when
        // coordination itself fails (e.g. no file coordination daemon).
        var coordinationError: NSError?
        var copyError: (any Error)?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: source,
            options: [.withoutChanges],
            error: &coordinationError
        ) { actualURL in
            do {
                try fileManager.copyItem(at: actualURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if coordinationError != nil {
            // Coordination failed before the accessor ran; try a plain copy.
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                try? fileManager.removeItem(at: tempDirectory)
                throw CalibreError.copyFailed(underlying: error)
            }
        } else if let copyError {
            try? fileManager.removeItem(at: tempDirectory)
            throw CalibreError.copyFailed(underlying: copyError)
        }

        var config = Configuration()
        config.readonly = true
        do {
            self.dbQueue = try DatabaseQueue(path: destination.path, configuration: config)
        } catch {
            try? fileManager.removeItem(at: tempDirectory)
            throw CalibreError.queryFailed(underlying: error)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Fetches every book that has at least one PDF file, ordered by
    /// Calibre's sort title (`books.sort`).
    public func fetchBooks() throws -> [CalibreBook] {
        do {
            return try dbQueue.read { db in
                let bookRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT b.id, b.uuid, b.title, b.sort, b.path, b.has_cover, b.pubdate
                        FROM books b
                        WHERE EXISTS (
                            SELECT 1 FROM data d WHERE d.book = b.id AND d.format = 'PDF'
                        )
                        ORDER BY b.sort
                        """
                )

                // Aggregate authors (in Calibre's link order), tags
                // (alphabetical), and PDF file names per book id.
                var authorsByBook: [Int64: [String]] = [:]
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT bal.book AS book, a.name AS name
                        FROM books_authors_link bal
                        JOIN authors a ON a.id = bal.author
                        ORDER BY bal.rowid
                        """
                ) {
                    authorsByBook[row["book"], default: []].append(row["name"])
                }

                var tagsByBook: [Int64: [String]] = [:]
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT btl.book AS book, t.name AS name
                        FROM books_tags_link btl
                        JOIN tags t ON t.id = btl.tag
                        ORDER BY t.name
                        """
                ) {
                    tagsByBook[row["book"], default: []].append(row["name"])
                }

                var pdfNamesByBook: [Int64: [String]] = [:]
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT d.book AS book, d.name AS name
                        FROM data d
                        WHERE d.format = 'PDF'
                        ORDER BY d.rowid
                        """
                ) {
                    pdfNamesByBook[row["book"], default: []].append(row["name"])
                }

                return bookRows.map { row in
                    let id: Int64 = row["id"]
                    let path: String = row["path"]
                    let hasCover: Bool = row["has_cover"] ?? false
                    return CalibreBook(
                        id: id,
                        uuid: row["uuid"] ?? "",
                        title: row["title"],
                        sortTitle: row["sort"] ?? row["title"],
                        authors: authorsByBook[id] ?? [],
                        calibreTags: tagsByBook[id] ?? [],
                        relativePDFPaths: (pdfNamesByBook[id] ?? []).map { "\(path)/\($0).pdf" },
                        coverRelativePath: hasCover ? "\(path)/cover.jpg" : nil,
                        pubdate: Self.parsePubdate(row["pubdate"])
                    )
                }
            }
        } catch let error as CalibreError {
            throw error
        } catch {
            throw CalibreError.queryFailed(underlying: error)
        }
    }

    /// Resolves a library-relative path (as found in
    /// ``CalibreBook/relativePDFPaths`` or ``CalibreBook/coverRelativePath``)
    /// against the library root.
    public func pdfURL(for relativePath: String) -> URL {
        libraryRoot.appendingPathComponent(relativePath, isDirectory: false)
    }

    // MARK: - Pubdate parsing

    /// Parses Calibre pubdate strings such as `2015-03-14 00:00:00+00:00`.
    /// Calibre uses `0101-01-01 …` as its "undefined date" sentinel; that (and
    /// anything unparseable) yields nil.
    private static func parsePubdate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("0101-01-01") { return nil }  // Calibre UNDEFINED_DATE

        let withZone = DateFormatter()
        withZone.locale = Locale(identifier: "en_US_POSIX")
        withZone.dateFormat = "yyyy-MM-dd HH:mm:ssxxx"
        if let date = withZone.date(from: raw) { return date }

        let withFractionalZone = DateFormatter()
        withFractionalZone.locale = Locale(identifier: "en_US_POSIX")
        withFractionalZone.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSxxx"
        if let date = withFractionalZone.date(from: raw) { return date }

        let bare = DateFormatter()
        bare.locale = Locale(identifier: "en_US_POSIX")
        bare.timeZone = TimeZone(identifier: "UTC")
        bare.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return bare.date(from: raw)
    }
}
