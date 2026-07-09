import PDFKit

/// Owns every live `PDFDocument` in the process.
///
/// A `PDFDocument(url:)` memory-maps its file, so holding a handful is cheap —
/// the expensive resources are render caches, which live with `PDFView`s and
/// are destroyed on tab switch (see `ActivePDFView`). This provider bounds the
/// number of live documents with a small LRU, and shares a single instance
/// when the same file is open in several tabs.
@MainActor
public final class DocumentProvider {
    public var capacity: Int

    /// Canonical paths that must not be evicted (documents currently attached
    /// to a visible view). Kept up to date by the window model.
    public var pinnedPaths: Set<String> = []

    /// LRU cache; most-recently-used last.
    private var cache: [(path: String, document: PDFDocument)] = []

    /// Fires after the set of resident paths may have changed (loads,
    /// evictions) — the auto-reload watcher re-arms from this. Loads happen
    /// during view-body evaluation, so handlers must defer real work.
    public var onResidentPathsChanged: (() -> Void)?

    public init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    public static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Returns the shared live document for `url`, loading it if necessary.
    /// Returns nil when the file is missing or not a readable PDF.
    public func document(for url: URL) -> PDFDocument? {
        let path = Self.canonicalPath(for: url)
        if let index = cache.firstIndex(where: { $0.path == path }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.document
        }
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return nil
        }
        // Before any page materializes: themed page class for all pages.
        document.delegate = PageClassProvider.shared
        cache.append((path, document))
        evictIfNeeded()
        onResidentPathsChanged?()
        return document
    }

    /// Re-reads a resident document from disk after its file changed,
    /// swapping the fresh instance into the same cache slot (LRU position
    /// and pin state follow the path, so both are preserved). Returns false
    /// when the path isn't resident, or the file is missing/unparseable —
    /// mid-regeneration states; the stale document stays usable and the
    /// caller retries.
    public func reloadFromDisk(path: String) -> Bool {
        guard let index = cache.firstIndex(where: { $0.path == path }) else { return false }
        guard let fresh = PDFDocument(url: URL(fileURLWithPath: path)) else { return false }
        fresh.delegate = PageClassProvider.shared
        guard fresh.pageCount > 0 else { return false }
        cache[index] = (path, fresh)
        return true
    }

    /// The live document for `url` ONLY if already resident — no load, no
    /// LRU bump. For chrome that decorates background tabs (breadcrumbs)
    /// without disturbing the memory model.
    public func loadedDocument(for url: URL) -> PDFDocument? {
        let path = Self.canonicalPath(for: url)
        return cache.first { $0.path == path }?.document
    }

    /// Paths of documents currently resident, least-recently-used first.
    public var residentPaths: [String] { cache.map(\.path) }

    /// Drops least-recently-used unpinned documents down to `capacity`.
    /// Pinned documents are never evicted, even if that leaves the cache
    /// over capacity.
    public func evictIfNeeded() {
        var index = 0
        var evictedAny = false
        while cache.count > capacity, index < cache.count {
            if pinnedPaths.contains(cache[index].path) {
                index += 1
            } else {
                cache.remove(at: index)
                evictedAny = true
            }
        }
        if evictedAny {
            onResidentPathsChanged?()
        }
    }

    /// Removes a document outright (e.g. after its last tab closes).
    public func evict(path: String) {
        let countBefore = cache.count
        cache.removeAll { $0.path == path && !pinnedPaths.contains(path) }
        if cache.count != countBefore {
            onResidentPathsChanged?()
        }
    }
}
