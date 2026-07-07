#if os(macOS)
import AppKit
import CalibreKit
import Foundation
import Observation
import ReaderCore
import ReaderPersistence
import SearchIndexKit
import UniformTypeIdentifiers

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
}

/// What the grid is currently scoped to (sidebar selection).
public enum LibraryFilter: Hashable {
    case all
    case tag(Int64)
    case collection(Int64)
}

/// State of the library window: the Calibre source, the merged item list
/// (Calibre books + the app's own imports), and the overlay tag/collection
/// system spanning both.
@Observable
@MainActor
public final class LibraryModel {
    public private(set) var items: [LibraryItem] = []
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    /// Books currently being pulled down from iCloud.
    public private(set) var downloading: Set<String> = []
    /// Progress of the background full-text indexing pass; nil when idle.
    public private(set) var indexingProgress: (done: Int, total: Int)?

    public var searchText = ""
    public var filter: LibraryFilter = .all

    // Overlay data (the app's own, synced later via CloudKit).
    public private(set) var tagTree: [TagNode] = []
    public private(set) var collections: [CollectionRecord] = []
    /// Overlay book-row id per LibraryItem id — the join between sources.
    private var bookRowIDs: [String: Int64] = [:]
    /// Overlay tags per LibraryItem id, for display and toggle state.
    public private(set) var itemTags: [String: [TagRecord]] = [:]

    private static let calibrePathKey = "CalibreLibraryPath"
    private static let setupDoneKey = "CalibreSetupDone"

    public private(set) var calibreRoot: URL?
    /// True until the user has made an explicit Calibre choice (use a
    /// folder, or skip). Drives the first-run setup screen.
    public private(set) var needsSetup: Bool
    let store: LibraryStore?

    /// Full-text hits for the current search, recomputed on a debounce —
    /// never queried from a view body (that ran an FTS query per frame).
    public private(set) var textHits: [BookSearchHit] = []
    @ObservationIgnored private var textHitsTask: Task<Void, Never>?

    // Full-text search index (M13). The service actor owns all PDFKit/Vision
    // work; the store is safe to query directly from the main actor.
    let indexStore: IndexStore?
    private let indexingService: IndexingService?
    /// Content hash per LibraryItem id, recorded as books get indexed —
    /// the join between index hits and library items.
    private(set) var contentHashByItemID: [String: String] = [:]
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    /// Guards `indexingProgress` against a cancelled pass clobbering the
    /// progress of the pass that replaced it.
    @ObservationIgnored private var indexingGeneration = 0

    /// Pass a store to use (tests inject an in-memory one); nil opens the
    /// app's library.db. Same for `indexStore` (tests inject an in-memory
    /// index; nil opens the app's index.db when the library store is owned).
    public init(store injected: LibraryStore? = nil, indexStore injectedIndex: IndexStore? = nil) {
        var openError: String?
        if let injected {
            store = injected
            indexStore = injectedIndex
        } else {
            var library: LibraryStore?
            var index: IndexStore?
            do {
                let dir = AppDataDirectory.url()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                library = try LibraryStore(path: dir.appendingPathComponent("library.db").path)
                index = try IndexStore(path: dir.appendingPathComponent("index.db").path)
            } catch {
                openError = "Library database unavailable: \(error.localizedDescription)"
            }
            store = library
            indexStore = index
        }
        indexingService = indexStore.map { IndexingService(store: $0) }
        loadError = openError

        if injected != nil {
            needsSetup = false
            return  // tests: no Calibre auto-detect, no UserDefaults
        }
        needsSetup = !UserDefaults.standard.bool(forKey: Self.setupDoneKey)
        if !needsSetup, let stored = UserDefaults.standard.string(forKey: Self.calibrePathKey) {
            calibreRoot = URL(fileURLWithPath: stored, isDirectory: true)
        }
    }

    // MARK: - Setup

    /// A Calibre library at the conventional iCloud location, if one exists —
    /// offered (never silently applied) during setup.
    public var detectedCalibreCandidate: URL? {
        let stored = UserDefaults.standard.string(forKey: Self.calibrePathKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let conventional = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Calibre")
        for candidate in [stored, conventional].compactMap({ $0 }) {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("metadata.db").path
            ) {
                return candidate
            }
        }
        return nil
    }

    /// Completes setup: a folder to sync from, or nil for "no Calibre —
    /// imported PDFs only".
    public func completeSetup(calibreFolder url: URL?) {
        UserDefaults.standard.set(true, forKey: Self.setupDoneKey)
        needsSetup = false
        if let url {
            attachCalibreFolder(url)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.calibrePathKey)
            calibreRoot = nil
            Task { await reload() }
        }
    }

    /// Detaches Calibre (imported PDFs remain); the grid empties of Calibre
    /// books on the next reload.
    public func detachCalibreFolder() {
        UserDefaults.standard.removeObject(forKey: Self.calibrePathKey)
        calibreRoot = nil
        items.removeAll { $0.source != .imported }
        Task { await reload() }
    }

    public var filteredItems: [LibraryItem] {
        var scoped = items
        switch filter {
        case .all:
            break
        case .tag(let tagID):
            let ids = Set(
                ((try? store?.books(withTag: tagID, includeDescendantTags: true)) ?? [])
                    .compactMap(\.id)
            )
            scoped = items.filter { bookRowIDs[$0.id].map(ids.contains) ?? false }
        case .collection(let collectionID):
            let ordered = ((try? store?.items(inCollection: collectionID)) ?? []).map(\.bookID)
            let position = Dictionary(
                uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) }
            )
            scoped = items
                .compactMap { item -> (LibraryItem, Int)? in
                    guard let rowID = bookRowIDs[item.id], let pos = position[rowID] else { return nil }
                    return (item, pos)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return scoped }
        return scoped.filter { item in
            item.title.lowercased().contains(query)
                || item.authors.contains { $0.lowercased().contains(query) }
                || item.calibreTags.contains { $0.lowercased().contains(query) }
                || (itemTags[item.id] ?? []).contains { $0.name.lowercased().contains(query) }
        }
    }

    public func attachCalibreFolder(_ url: URL) {
        calibreRoot = url
        UserDefaults.standard.set(url.path, forKey: Self.calibrePathKey)
        Task { await reload() }
    }

    public func chooseCalibreFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Calibre library folder (contains metadata.db)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachCalibreFolder(url)
    }

    public func reload() async {
        guard let calibreRoot else {
            // No Calibre attached: the library is just the app's imports.
            items = []
            appendImportedItems()
            reloadOverlay()
            startBackgroundIndexing()
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            // metadata.db itself may be evicted.
            let metadata = calibreRoot.appendingPathComponent("metadata.db")
            try await FileAvailability.ensureLocal(metadata)

            let root = calibreRoot
            // CalibreLibrary reads a private copy; the fetch is fast but
            // touches disk — keep it off the main actor.
            let books = try await Task.detached(priority: .userInitiated) {
                try CalibreLibrary(libraryRoot: root).fetchBooks()
            }.value

            items = books.compactMap { book in
                guard let pdfPath = book.relativePDFPaths.first else { return nil }
                return LibraryItem(
                    id: book.uuid,
                    source: .calibre(uuid: book.uuid),
                    title: book.title,
                    authors: book.authors,
                    calibreTags: book.calibreTags,
                    fileURL: root.appendingPathComponent(pdfPath),
                    coverURL: book.coverRelativePath.map { root.appendingPathComponent($0) }
                )
            }

            // Mirror Calibre books into the overlay DB so app tags can
            // attach to them; Calibre stays the metadata source. One batch
            // transaction, off the main actor — per-book writes made first
            // open take seconds.
            if let store {
                let pairs = items.compactMap { item -> (uuid: String, title: String)? in
                    guard case .calibre(let uuid) = item.source else { return nil }
                    return (uuid, item.title)
                }
                let mapping = try await Task.detached(priority: .userInitiated) {
                    try store.upsertCalibreBooks(pairs)
                }.value
                for item in items {
                    if case .calibre(let uuid) = item.source, let rowID = mapping[uuid] {
                        bookRowIDs[item.id] = rowID
                    }
                }
            }
            appendImportedItems()
            reloadOverlay()
            startBackgroundIndexing()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Debounced full-text query — called by the view when searchText
    /// changes; results land in `textHits`.
    public func searchTextChanged() {
        textHitsTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            textHits = []
            return
        }
        textHitsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.textHits = self.fullTextHits()
        }
    }

    // MARK: - Full-text indexing (M13)

    /// Cancels any in-flight indexing pass and starts a fresh one in the
    /// background. Called after every successful reload().
    private func startBackgroundIndexing() {
        guard indexingService != nil else { return }
        indexingTask?.cancel()
        indexingTask = Task(priority: .utility) { [weak self] in
            await self?.indexLibrary()
        }
    }

    /// Indexes every local book sequentially, recording content hashes as it
    /// goes. Skips iCloud-evicted files (indexing must never trigger
    /// downloads). Internal so tests can await a full pass directly.
    func indexLibrary() async {
        guard let indexingService else { return }
        indexingGeneration += 1
        let generation = indexingGeneration
        // Snapshot: reload() replaces `items` wholesale; a stale pass keeps
        // its own list and the restart takes care of the rest.
        let candidates = items.filter { FileAvailability.isLocal($0.fileURL) }
        indexingProgress = (done: 0, total: candidates.count)
        defer {
            if generation == indexingGeneration {
                indexingProgress = nil
            }
        }

        var done = 0
        for item in candidates {
            if Task.isCancelled { return }
            do {
                let hash = try ContentHash.compute(for: item.fileURL)
                _ = try await indexingService.indexDocument(at: item.fileURL, contentHash: hash)
                contentHashByItemID[item.id] = hash
            } catch {
                // Unreadable/corrupt PDFs are skipped; search simply won't
                // cover them.
            }
            done += 1
            if generation == indexingGeneration {
                indexingProgress = (done: done, total: candidates.count)
            }
        }
    }

    /// Full-text matches for the current search text, mapped back to library
    /// items. Hits whose content hash doesn't belong to a known (indexed,
    /// local) item are dropped.
    public func fullTextHits() -> [BookSearchHit] {
        guard let indexStore else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        let itemIDByHash = Dictionary(
            contentHashByItemID.map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let hits = (try? indexStore.search(query, limit: 60)) ?? []
        return hits.compactMap { hit in
            guard
                let itemID = itemIDByHash[hit.contentHash],
                let item = itemsByID[itemID]
            else { return nil }
            return BookSearchHit(
                id: "\(hit.contentHash)-\(hit.page)",
                itemID: itemID,
                title: item.title,
                page: hit.page,
                snippet: hit.snippet
            )
        }
    }

    /// Adds the app's own imported PDFs (overlay books with a content hash)
    /// to the item list.
    private func appendImportedItems() {
        guard let store else { return }
        let imported = ((try? store.allBooks()) ?? []).filter { $0.contentHash != nil }
        for book in imported {
            guard
                let rowID = book.id,
                let ref = try? store.fileRef(forBook: rowID)
            else { continue }
            let item = LibraryItem(
                id: "imported-\(book.contentHash!)",
                source: .imported,
                title: book.title,
                authors: [],
                calibreTags: [],
                fileURL: URL(fileURLWithPath: ref.pathHint),
                coverURL: nil
            )
            items.append(item)
            bookRowIDs[item.id] = rowID
        }
    }

    /// Refreshes tags/collections and the per-item tag map.
    public func reloadOverlay() {
        guard let store else { return }
        tagTree = (try? store.tagTree()) ?? []
        collections = (try? store.collections()) ?? []
        itemTags = [:]
        for (itemID, rowID) in bookRowIDs {
            itemTags[itemID] = (try? store.tags(forBook: rowID)) ?? []
        }
    }

    // MARK: - Imports

    /// Imports arbitrary PDFs (downloads, homework, …) into the app library.
    public func importPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Import PDFs into your library."
        guard panel.runModal() == .OK else { return }
        importPDFs(at: panel.urls)
    }

    public func importPDFs(at urls: [URL]) {
        guard let store else { return }
        for url in urls {
            guard let hash = try? ContentHash.compute(for: url) else { continue }
            let title = url.deletingPathExtension().lastPathComponent
            _ = try? store.insertLooseBook(
                contentHash: hash,
                title: title,
                pathHint: url.standardizedFileURL.path
            )
        }
        // Rebuild the imported section (idempotent: content_hash is UNIQUE).
        items.removeAll { $0.source == .imported }
        appendImportedItems()
        reloadOverlay()
    }

    // MARK: - Tags

    public func createTag(name: String, parent: Int64? = nil) {
        guard let store, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? store.createTag(name: name, parent: parent)
        reloadOverlay()
    }

    public func deleteTag(id: Int64) {
        try? store?.softDeleteTag(id: id)
        if filter == .tag(id) { filter = .all }
        reloadOverlay()
    }

    public func toggleTag(_ tag: TagRecord, for item: LibraryItem) {
        guard let store, let rowID = bookRowIDs[item.id], let tagID = tag.id else { return }
        var current = Set((itemTags[item.id] ?? []).compactMap(\.id))
        if current.contains(tagID) {
            current.remove(tagID)
        } else {
            current.insert(tagID)
        }
        try? store.setTags(bookID: rowID, tagIDs: current)
        reloadOverlay()
    }

    public func hasTag(_ tag: TagRecord, item: LibraryItem) -> Bool {
        (itemTags[item.id] ?? []).contains { $0.id == tag.id }
    }

    /// Flat list of all tags (depth-first) for menus.
    public var allTags: [TagRecord] {
        func flatten(_ nodes: [TagNode]) -> [TagRecord] {
            nodes.flatMap { [$0.tag] + flatten($0.children) }
        }
        return flatten(tagTree)
    }

    // MARK: - Collections

    public func createCollection(name: String) {
        guard let store, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? store.createCollection(name: name)
        reloadOverlay()
    }

    public func isInCollection(_ collection: CollectionRecord, item: LibraryItem) -> Bool {
        guard let store, let collectionID = collection.id, let rowID = bookRowIDs[item.id]
        else { return false }
        let members = (try? store.items(inCollection: collectionID)) ?? []
        return members.contains { $0.bookID == rowID }
    }

    public func toggleCollection(_ collection: CollectionRecord, for item: LibraryItem) {
        guard let store, let collectionID = collection.id, let rowID = bookRowIDs[item.id]
        else { return }
        if isInCollection(collection, item: item) {
            try? store.removeFromCollection(collectionID: collectionID, bookID: rowID)
        } else {
            let count = ((try? store.items(inCollection: collectionID)) ?? []).count
            try? store.addToCollection(collectionID: collectionID, bookID: rowID, sortOrder: count)
        }
        reloadOverlay()
    }

    func setItemsForTesting(_ items: [LibraryItem]) {
        self.items = items
    }

    /// Ensures the file is local (downloading from iCloud if evicted), then
    /// stages it in a reader window, optionally at a position (full-text
    /// search hits open at their page). Returns a new window ID if one must
    /// be opened by the caller.
    public func openItem(_ item: LibraryItem, at entry: NavEntry? = nil) async throws -> UUID? {
        downloading.insert(item.id)
        defer { downloading.remove(item.id) }
        try await FileAvailability.ensureLocal(item.fileURL)
        return SessionCoordinator.shared.openInReader(fileURL: item.fileURL, at: entry)
    }
}
#endif
