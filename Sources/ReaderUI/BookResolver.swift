#if os(macOS)
import Foundation
import ReaderPersistence
import SearchIndexKit

/// Maps an open file to its overlay-DB book row, so bookmarks and reading
/// state attach to ANY PDF the reader opens — library member or not.
///
/// Resolution order: content hash (stable across moves; the indexer
/// backfills it onto Calibre rows), then file_ref path, then auto-register
/// the file as a loose book.
@MainActor
enum BookResolver {
    static func resolveBookID(forFileAt url: URL, store: LibraryStore) -> Int64? {
        let path = url.standardizedFileURL.path
        let hash = try? ContentHash.compute(for: url)

        if let hash, let book = try? store.book(byContentHash: hash), let id = book.id {
            return id
        }
        if let id = try? store.bookID(forPathHint: path) {
            if let hash {
                try? store.setContentHash(bookID: id, hash: hash)
            }
            return id
        }
        guard let hash else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        return try? store.insertLooseBook(contentHash: hash, title: title, pathHint: path).id
    }
}
#endif
