#if canImport(AppKit)
import AppKit
#endif
import CalibreKit
import Foundation
import Observation
import ReaderCore
import ReaderPersistence
import SearchIndexKit
import UniformTypeIdentifiers

// LibraryItem, BookSearchHit, and LibraryFilter live in LibraryTypes.swift.

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

    public var searchText = "" {
        didSet { if searchText != oldValue { applySearchFilter() } }
    }
    public var filter: LibraryFilter = .all {
        didSet { if filter != oldValue { rescope() } }
    }

    // View modes (round 7): grid / sortable list / sectioned-by-tag.
    /// How the detail area renders; persisted per user.
    public var viewMode: LibraryViewMode = .grid {
        didSet {
            guard viewMode != oldValue else { return }
            persistViewPreferences()
        }
    }
    /// Column sort of the list view. Stored on the model so rows are
    /// re-sorted once per change, never per body evaluation; persisted.
    public var listSortOrder: [KeyPathComparator<LibraryListRow>] =
        LibraryListRow.defaultSortOrder
    {
        didSet {
            guard listSortOrder != oldValue else { return }
            listRows = listRows.sorted(using: listSortOrder)
            persistViewPreferences()
        }
    }
    /// The list view's rows: `filteredItems` joined with reading state,
    /// pre-sorted. STORED (see `filteredItems` note below). internal(set):
    /// rebuilt from LibraryViewModes.swift.
    public internal(set) var listRows: [LibraryListRow] = []
    /// The sectioned view's groups. Only populated inside a tag scope.
    public internal(set) var tagSections: [LibraryTagSection] = []
    /// Last-read time per item id (reading_state join), refreshed together
    /// with the overlay data.
    private(set) var lastReadByItemID: [String: Date] = [:]
    /// False for tests: view-mode/sort preferences never touch the real
    /// UserDefaults from a test process.
    @ObservationIgnored var persistsViewPreferences = false

    // Overlay data (the app's own, synced later via CloudKit).
    public private(set) var tagTree: [TagNode] = []
    public private(set) var collections: [CollectionRecord] = []
    public private(set) var collectionTree: [CollectionNode] = []
    /// Overlay book-row id per LibraryItem id — the join between sources.
    private var bookRowIDs: [String: Int64] = [:]
    /// Overlay tags per LibraryItem id, for display and toggle state.
    public private(set) var itemTags: [String: [TagRecord]] = [:]

    /// macOS: the folder path as a plain string (no sandbox).
    private static let calibrePathKey = "CalibreLibraryPath"
    /// iOS: a security-scoped bookmark from the folder picker — the only way
    /// a sandboxed app can reopen the user's iCloud Drive folder on relaunch.
    private static let calibreBookmarkKey = "CalibreFolderBookmark"
    private static let setupDoneKey = "CalibreSetupDone"
    /// macOS: plain path strings of the watched folders (round 18).
    private static let watchedFoldersKey = "WatchedFolderPaths"

    /// Folders whose PDFs are imported wholesale and kept in sync — new
    /// files appear, regenerated files keep their book identity, removed
    /// files leave (built for auto-exported note folders, e.g. reMarkable's
    /// iCloud mirror). macOS-only for now: the paths are plain strings.
    public private(set) var watchedFolders: [URL] = []

    /// Per-path (mtime, size) of files already reconciled this session —
    /// rescans skip hashing anything unchanged, so a scan of a settled
    /// folder is stat-only.
    @ObservationIgnored private var scanFingerprints: [String: WatchedFileFingerprint] = [:]
    /// Observes the watched folders + the Calibre root; nil while nothing
    /// is watched. Real app instances only — never tests.
    @ObservationIgnored private var sourceWatcher: FolderWatcher?
    @ObservationIgnored private var sourceReloadTask: Task<Void, Never>?
    @ObservationIgnored private var autoRescanEnabled = false

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
    /// Recreated by `startBackgroundIndexing()` so the OCR setting applies
    /// to the next pass without a relaunch (the actor is just a store
    /// reference plus a flag — recreation is free).
    private var indexingService: IndexingService?
    /// Content hash per LibraryItem id, recorded as books get indexed —
    /// the join between index hits and library items.
    private(set) var contentHashByItemID: [String: String] = [:]
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    /// Guards `indexingProgress` against a cancelled pass clobbering the
    /// progress of the pass that replaced it.
    @ObservationIgnored private var indexingGeneration = 0

    /// User preferences gating the background indexing pass. Injected for
    /// tests; the app uses the shared instance.
    @ObservationIgnored let settings: AppSettings

    /// The app's one library model. The library window and the Settings
    /// window share it, so a Calibre folder change made in either place is
    /// live in the other. Unit tests never see the user's databases: a test
    /// process gets in-memory stores (mirrors the AppStores.library fence).
    public static let shared: LibraryModel = {
        if AppStores.isTestProcess {
            let store = try! LibraryStore.inMemory()
            return LibraryModel(store: store, indexStore: try? IndexStore.inMemory())
        }
        return LibraryModel()
    }()

    /// Pass a store to use (tests inject an in-memory one); nil opens the
    /// app's library.db. Same for `indexStore` (tests inject an in-memory
    /// index; nil opens the app's index.db when the library store is owned).
    public init(
        store injected: LibraryStore? = nil,
        indexStore injectedIndex: IndexStore? = nil,
        settings: AppSettings = .shared
    ) {
        self.settings = settings
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
        indexingService = indexStore.map {
            IndexingService(store: $0, ocrEnabled: settings.ocrIndexingEnabled)
        }
        loadError = openError

        if injected != nil {
            needsSetup = false
            return  // tests: no Calibre auto-detect, no UserDefaults
        }
        needsSetup = !UserDefaults.standard.bool(forKey: Self.setupDoneKey)
        if !needsSetup {
            calibreRoot = Self.restoreCalibreRoot()
        }
        #if os(macOS)
        watchedFolders = (UserDefaults.standard.stringArray(forKey: Self.watchedFoldersKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        #endif
        if !AppStores.isTestProcess {
            loadViewPreferences()
            persistsViewPreferences = true
            autoRescanEnabled = true
            startWatchingSources()
        }
    }

    /// Reopens the persisted Calibre folder, per-platform.
    private static func restoreCalibreRoot() -> URL? {
        #if os(macOS)
        return UserDefaults.standard.string(forKey: calibrePathKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        guard let data = UserDefaults.standard.data(forKey: calibreBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else { return nil }
        // Access is deliberately held for the app's lifetime: the reader
        // opens book files under this root at any time.
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: calibreBookmarkKey)
        }
        return url
        #endif
    }

    // MARK: - Setup

    #if os(macOS)
    /// A Calibre library at the conventional iCloud location, if one exists —
    /// offered (never silently applied) during setup. macOS only: a sandboxed
    /// iOS app can't probe iCloud Drive paths; the folder picker is the way.
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
    #endif

    /// Completes setup: a folder to sync from, or nil for "no Calibre —
    /// imported PDFs only".
    public func completeSetup(calibreFolder url: URL?) {
        UserDefaults.standard.set(true, forKey: Self.setupDoneKey)
        needsSetup = false
        if let url {
            attachCalibreFolder(url)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.calibrePathKey)
            UserDefaults.standard.removeObject(forKey: Self.calibreBookmarkKey)
            calibreRoot = nil
            startWatchingSources()
            Task { await reload() }
        }
    }

    /// Detaches Calibre (imported PDFs remain); the grid empties of Calibre
    /// books on the next reload.
    public func detachCalibreFolder() {
        UserDefaults.standard.removeObject(forKey: Self.calibrePathKey)
        UserDefaults.standard.removeObject(forKey: Self.calibreBookmarkKey)
        calibreRoot = nil
        items.removeAll { $0.source != .imported }
        startWatchingSources()
        Task { await reload() }
    }

    /// The grid's contents: `items` scoped to the sidebar filter, then
    /// narrowed by the search text. STORED, not computed — the scoping runs
    /// SQLite queries, and a computed property re-ran them on every body
    /// evaluation (this is what made selection clicks feel laggy). It is
    /// recomputed only when items / filter / search / overlay data change.
    public private(set) var filteredItems: [LibraryItem] = []
    /// `items` scoped to the sidebar filter, before search narrowing —
    /// cached so per-keystroke search doesn't re-run the scope queries.
    @ObservationIgnored private var scopedItems: [LibraryItem] = []
    /// Sidebar badge counts for the smart filters.
    public private(set) var untaggedCount = 0
    public private(set) var notInAnyCollectionCount = 0
    /// Books matched per tag id — descendant tags included, so each badge
    /// equals what selecting that tag shows.
    public private(set) var tagCounts: [Int64: Int] = [:]

    /// Recomputes the filter scope (SQLite) and the smart-filter counts,
    /// then reapplies the search text. Call after any data change.
    func rescope() {
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
            scoped = itemsInCollection(collectionID)
        case .untagged:
            let ids = Set(((try? store?.booksWithoutTags()) ?? []).compactMap(\.id))
            // Items with no overlay row have no overlay tags by definition.
            scoped = items.filter { bookRowIDs[$0.id].map(ids.contains) ?? true }
        case .notInAnyCollection:
            let ids = Set(((try? store?.booksNotInAnyCollection()) ?? []).compactMap(\.id))
            scoped = items.filter { bookRowIDs[$0.id].map(ids.contains) ?? true }
        }
        scopedItems = scoped

        let untaggedIDs = Set(((try? store?.booksWithoutTags()) ?? []).compactMap(\.id))
        untaggedCount = items.count(where: { bookRowIDs[$0.id].map(untaggedIDs.contains) ?? true })
        let uncollectedIDs = Set(
            ((try? store?.booksNotInAnyCollection()) ?? []).compactMap(\.id)
        )
        notInAnyCollectionCount = items.count(
            where: { bookRowIDs[$0.id].map(uncollectedIDs.contains) ?? true }
        )
        tagCounts = Self.tagCounts(
            tree: tagTree, itemTags: itemTags, liveItemIDs: Set(items.map(\.id))
        )

        applySearchFilter()
    }

    /// Distinct books per tag. A book counts toward every ANCESTOR of its
    /// tags too, because selecting a tag scopes to its whole subtree — the
    /// badge must equal what the click shows. Pure, for direct testing.
    static func tagCounts(
        tree: [TagNode],
        itemTags: [String: [TagRecord]],
        liveItemIDs: Set<String>
    ) -> [Int64: Int] {
        var directItems: [Int64: Set<String>] = [:]
        for (itemID, tags) in itemTags where liveItemIDs.contains(itemID) {
            for tag in tags {
                guard let id = tag.id else { continue }
                directItems[id, default: []].insert(itemID)
            }
        }
        var counts: [Int64: Int] = [:]
        func gather(_ node: TagNode) -> Set<String> {
            var books = node.tag.id.flatMap { directItems[$0] } ?? []
            for child in node.children {
                books.formUnion(gather(child))
            }
            if let id = node.tag.id {
                counts[id] = books.count
            }
            return books
        }
        for root in tree {
            _ = gather(root)
        }
        return counts
    }

    /// Narrows the cached scope by the search text (metadata match — the
    /// full-text hits are separate, see `textHits`). Pure in-memory work,
    /// cheap enough to run per keystroke.
    private func applySearchFilter() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            filteredItems = scopedItems
        } else {
            filteredItems = scopedItems.filter { item in
                item.title.lowercased().contains(query)
                    || item.authors.contains { $0.lowercased().contains(query) }
                    || item.calibreTags.contains { $0.lowercased().contains(query) }
                    || (itemTags[item.id] ?? []).contains { $0.name.lowercased().contains(query) }
            }
        }
        rebuildDerivedViewData()
    }

    public func attachCalibreFolder(_ url: URL) {
        calibreRoot = url
        // Attaching IS an explicit Calibre choice — the Settings window can
        // make it before the library window's first-run screen ever ran.
        if needsSetup {
            UserDefaults.standard.set(true, forKey: Self.setupDoneKey)
            needsSetup = false
        }
        #if os(macOS)
        UserDefaults.standard.set(url.path, forKey: Self.calibrePathKey)
        #else
        // The picker URL is security-scoped: keep access open (held for the
        // app's lifetime — the reader opens books under it at any time) and
        // persist a bookmark for the next launch.
        _ = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.calibreBookmarkKey)
        }
        #endif
        startWatchingSources()
        Task { await reload() }
    }

    /// Test hook: points `reload()` at a Calibre folder WITHOUT persisting
    /// to UserDefaults (attachCalibreFolder would repoint the real app).
    func setCalibreRootForTesting(_ url: URL) {
        calibreRoot = url
    }

    #if os(macOS)
    public func chooseCalibreFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Calibre library folder (contains metadata.db)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachCalibreFolder(url)
    }
    #endif

    public func reload() async {
        guard let calibreRoot else {
            // No Calibre attached: the library is the app's imports plus
            // the watched folders' contents.
            await scanWatchedFolders()
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
                    coverURL: book.coverRelativePath.map { root.appendingPathComponent($0) },
                    addedAt: book.addedAt
                )
            }

            // Mirror Calibre books into the overlay DB so app tags can
            // attach to them; Calibre stays the metadata source. One batch
            // transaction, off the main actor — per-book writes made first
            // open take seconds.
            if let store {
                let pairs = items.compactMap { item -> (uuid: String, title: String, authors: String)? in
                    guard case .calibre(let uuid) = item.source else { return nil }
                    return (uuid, item.title, item.authors.joined(separator: ", "))
                }
                let mapping = try await Task.detached(priority: .userInitiated) {
                    try store.upsertCalibreBooks(pairs)
                }.value
                for item in items {
                    if case .calibre(let uuid) = item.source, let rowID = mapping[uuid] {
                        bookRowIDs[item.id] = rowID
                    }
                }
                // Mirror every Calibre book's PDF path as a file_ref so
                // quick-open (⌘P) can open books never opened before —
                // without this, only imports and already-opened books have
                // a known location.
                let refs = items.compactMap { item -> (bookID: Int64, pathHint: String)? in
                    guard case .calibre = item.source, let rowID = bookRowIDs[item.id]
                    else { return nil }
                    return (rowID, DocumentProvider.canonicalPath(for: item.fileURL))
                }
                try await Task.detached(priority: .userInitiated) {
                    try store.upsertFileRefs(refs)
                }.value
            }
            await scanWatchedFolders()
            appendImportedItems()
            reloadOverlay()
            startBackgroundIndexing()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Debounced live full-text query — called by the view on every
    /// searchText keystroke (no Enter needed); results land in `textHits`.
    /// A new keystroke cancels the superseded query, and the FTS query runs
    /// off the main actor so typing never stalls on SQLite.
    public func searchTextChanged() {
        textHitsTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            textHits = []
            return
        }
        textHitsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            guard let indexStore = self.indexStore else { return }
            // Snapshot main-actor state; the query itself runs detached.
            let hashByItemID = self.contentHashByItemID
            let items = self.items
            let hits = await Task.detached(priority: .userInitiated) {
                Self.fullTextHits(
                    query: query, in: indexStore,
                    contentHashByItemID: hashByItemID, items: items
                )
            }.value
            guard !Task.isCancelled else { return }
            self.textHits = hits
        }
    }

    // MARK: - Full-text indexing (M13)

    /// Cancels any in-flight indexing pass and starts a fresh one in the
    /// background. Called after every successful reload(). No-op while the
    /// user has background indexing turned off (Settings > Search index).
    /// Internal so tests can drive the settings gate directly.
    func startBackgroundIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
        guard settings.backgroundIndexingEnabled, let indexStore else { return }
        // Recreate the service so an OCR toggle applies to this pass.
        indexingService = IndexingService(
            store: indexStore, ocrEnabled: settings.ocrIndexingEnabled
        )
        indexingTask = Task(priority: .utility) { [weak self] in
            await self?.indexLibrary()
        }
    }

    /// True while a background pass is scheduled or running (test hook).
    var isBackgroundIndexingScheduled: Bool { indexingTask != nil }

    /// The OCR flag the current indexing service was built with (test hook).
    var indexingServiceOCREnabled: Bool? { indexingService?.ocrEnabled }

    /// Called by the Settings window when either indexing toggle changes:
    /// re-kicks (or cancels) the background pass so the change is live
    /// without waiting for the next library reload.
    public func indexingSettingsChanged() {
        if settings.backgroundIndexingEnabled {
            startBackgroundIndexing()
        } else {
            indexingTask?.cancel()
            indexingTask = nil
            // Invalidate the cancelled pass's progress writes (it may run a
            // few more loop iterations before it sees the cancellation).
            indexingGeneration += 1
            indexingProgress = nil
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
    /// local) item are dropped. Synchronous — tests and one-shot callers;
    /// the live search path uses the detached static variant.
    public func fullTextHits() -> [BookSearchHit] {
        guard let indexStore else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Self.fullTextHits(
            query: query, in: indexStore,
            contentHashByItemID: contentHashByItemID, items: items
        )
    }

    /// The isolation-free core of the full-text search: pure function of the
    /// query plus snapshots of main-actor state, safe to run detached.
    private nonisolated static func fullTextHits(
        query: String,
        in indexStore: IndexStore,
        contentHashByItemID: [String: String],
        items: [LibraryItem]
    ) -> [BookSearchHit] {
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

    /// Adds the app's own imported PDFs (loose overlay books) to the item
    /// list. Calibre-sourced rows are excluded even when they carry a
    /// content hash — the resolver/indexer backfill hashes onto them, and
    /// they already entered `items` from the Calibre scan.
    private func appendImportedItems() {
        guard let store else { return }
        let imported = ((try? store.allBooks()) ?? [])
            .filter { $0.contentHash != nil && $0.calibreUUID == nil }
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
                coverURL: nil,
                addedAt: book.createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
            items.append(item)
            bookRowIDs[item.id] = rowID
        }
    }

    /// Refreshes tags/collections and the per-item tag map, then rescopes
    /// the grid (overlay changes can move items in and out of the filter).
    public func reloadOverlay() {
        defer { rescope() }
        guard let store else { return }
        tagTree = (try? store.tagTree()) ?? []
        collections = (try? store.collections()) ?? []
        collectionTree = (try? store.collectionTree()) ?? []
        itemTags = [:]
        for (itemID, rowID) in bookRowIDs {
            itemTags[itemID] = (try? store.tags(forBook: rowID)) ?? []
        }
        lastReadByItemID = [:]
        if let times = try? store.lastReadTimes() {
            for (itemID, rowID) in bookRowIDs {
                if let ms = times[rowID] {
                    lastReadByItemID[itemID] = Date(timeIntervalSince1970: Double(ms) / 1000)
                }
            }
        }
    }

    // MARK: - Imports

    #if os(macOS)
    /// Imports arbitrary PDFs (downloads, homework, …) into the app library.
    public func importPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Import PDFs into your library."
        guard panel.runModal() == .OK else { return }
        importPDFs(at: panel.urls)
    }
    #endif

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

    // MARK: - Watched folders (round 18)

    #if os(macOS)
    /// Folder picker for new watched folders (multi-select allowed).
    public func chooseWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders of PDFs to import and keep in sync."
        guard panel.runModal() == .OK else { return }
        addWatchedFolders(panel.urls)
    }
    #endif

    /// Adds folders to the watched set (deduplicated by canonical path) and
    /// imports their contents.
    public func addWatchedFolders(_ urls: [URL]) {
        var added = false
        for url in urls {
            let canonical = URL(
                fileURLWithPath: DocumentProvider.canonicalPath(for: url), isDirectory: true
            )
            guard !watchedFolders.contains(where: { $0.path == canonical.path }) else { continue }
            watchedFolders.append(canonical)
            added = true
        }
        guard added else { return }
        persistWatchedFolders()
        startWatchingSources()
        Task { await reload() }
    }

    /// Stops watching a folder and removes its books from the library
    /// (soft-delete, like Remove from Library — the files are untouched, and
    /// re-adding the folder resurrects the books with their reading state).
    public func removeWatchedFolder(_ url: URL) {
        watchedFolders.removeAll { $0.path == url.path }
        if let store {
            let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
            for ref in (try? store.looseBookFileRefs()) ?? [] where ref.pathHint.hasPrefix(prefix) {
                try? store.softDeleteBook(id: ref.bookID)
                scanFingerprints.removeValue(forKey: ref.pathHint)
            }
        }
        persistWatchedFolders()
        startWatchingSources()
        Task { await reload() }
    }

    private func persistWatchedFolders() {
        guard !AppStores.isTestProcess else { return }
        UserDefaults.standard.set(watchedFolders.map(\.path), forKey: Self.watchedFoldersKey)
    }

    /// Test hook, mirroring `setCalibreRootForTesting`: no persistence, no
    /// filesystem watchers.
    func setWatchedFoldersForTesting(_ urls: [URL]) {
        watchedFolders = urls
    }

    /// One reconciliation pass over every watched folder, off the main
    /// actor: new PDFs register, moved ones follow, regenerated ones keep
    /// their book identity, vanished ones tombstone. Evicted iCloud
    /// placeholders start downloading and are picked up by the scan their
    /// arrival triggers.
    func scanWatchedFolders() async {
        guard let store, !watchedFolders.isEmpty else { return }
        let folders = watchedFolders.map(\.path)
        let previous = scanFingerprints
        scanFingerprints = await Task.detached(priority: .userInitiated) {
            Self.scanFolders(at: folders, store: store, previous: previous)
        }.value
    }

    /// The isolation-free scan core. Returns the new fingerprint cache
    /// (paths that disappeared fall out of it automatically).
    private nonisolated static func scanFolders(
        at folderPaths: [String],
        store: LibraryStore,
        previous: [String: WatchedFileFingerprint]
    ) -> [String: WatchedFileFingerprint] {
        var fingerprints: [String: WatchedFileFingerprint] = [:]
        var present: Set<String> = []
        let fileManager = FileManager.default

        for folder in folderPaths {
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "pdf" else { continue }
                let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
                ])
                guard values?.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                // Present even when evicted: a placeholder is not a removal.
                present.insert(path)
                guard FileAvailability.isLocal(url) else {
                    // Start pulling the bytes down; their arrival is a file
                    // change, which triggers the scan that registers them.
                    try? fileManager.startDownloadingUbiquitousItem(at: url)
                    continue
                }
                let fingerprint = WatchedFileFingerprint(
                    mtimeMS: Int64(
                        (values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
                    ),
                    size: values?.fileSize ?? 0
                )
                if previous[path] == fingerprint {
                    fingerprints[path] = fingerprint  // already reconciled
                    continue
                }
                guard let hash = try? ContentHash.compute(for: url) else { continue }
                let title = url.deletingPathExtension().lastPathComponent
                if (try? store.syncScannedFile(path: path, hash: hash, title: title)) != nil {
                    fingerprints[path] = fingerprint
                }
            }
        }

        // Books whose file vanished from a watched folder: tombstone. Moves
        // were already handled — the hash match repointed their file_ref.
        // `fileExists` keeps evicted-but-listed placeholders safe, and skips
        // nothing extra: a file the enumerator missed but that exists on
        // disk is not a removal.
        let prefixes = folderPaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for ref in (try? store.looseBookFileRefs()) ?? [] {
            guard
                prefixes.contains(where: { ref.pathHint.hasPrefix($0) }),
                !present.contains(ref.pathHint),
                !fileManager.fileExists(atPath: ref.pathHint)
            else { continue }
            try? store.softDeleteBook(id: ref.bookID)
        }
        return fingerprints
    }

    // MARK: - Source watching (round 18)

    /// (Re)arms filesystem observation of the watched folders and the
    /// Calibre root. Any change funnels into one debounced `reload()`:
    /// FSEvents' own latency coalesces bursts, the task debounce coalesces
    /// the rest (reMarkable regenerates whole folders at once).
    private func startWatchingSources() {
        #if os(macOS)
        sourceWatcher?.stop()
        sourceWatcher = nil
        guard autoRescanEnabled else { return }
        var paths = watchedFolders.map(\.path)
        if let calibreRoot {
            paths.append(calibreRoot.path)
        }
        guard !paths.isEmpty else { return }
        sourceWatcher = FolderWatcher(paths: paths, latency: 2.0) { [weak self] _ in
            // FolderWatcher delivers on the main queue.
            MainActor.assumeIsolated { self?.scheduleSourceReload() }
        }
        #endif
    }

    private func scheduleSourceReload() {
        sourceReloadTask?.cancel()
        sourceReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
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

    /// Sets or clears a tag's display color ("#RRGGBB"; nil = colorless).
    public func setTagColor(id: Int64, color: String?) {
        try? store?.setTagColor(id: id, color: color)
        reloadOverlay()
    }

    /// Moves a tag under a new parent (nil = root); the store refuses moves
    /// that would create a cycle. Returns whether anything changed.
    @discardableResult
    public func reparentTag(id: Int64, under parentID: Int64?) -> Bool {
        guard let store, (try? store.setTagParent(id: id, parentID: parentID)) == true else {
            return false
        }
        reloadOverlay()
        return true
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

    public func createCollection(name: String, parent: Int64? = nil) {
        guard let store, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? store.createCollection(name: name, parent: parent)
        reloadOverlay()
    }

    public func deleteCollection(id: Int64) {
        try? store?.softDeleteCollection(id: id)
        if filter == .collection(id) { filter = .all }
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

    // MARK: - Multi-item operations (selection action bar, drag & drop)

    /// The items for a set of ids, in current grid order (fallback: item
    /// order) — the shape selection-wide actions want.
    /// A collection's items in display order: direct members keep their
    /// manual sort order; books from child collections follow, title-ordered
    /// (allBooks/subtree order). Also feeds "Open Collection".
    public func itemsInCollection(_ collectionID: Int64) -> [LibraryItem] {
        let direct = ((try? store?.items(inCollection: collectionID)) ?? []).map(\.bookID)
        let subtree = Set(
            ((try? store?.books(inCollectionSubtree: collectionID)) ?? []).compactMap(\.id)
        )
        let position = Dictionary(
            uniqueKeysWithValues: direct.enumerated().map { ($1, $0) }
        )
        return items
            .compactMap { item -> (LibraryItem, Int)? in
                guard let rowID = bookRowIDs[item.id] else { return nil }
                if let pos = position[rowID] {
                    return (item, pos)
                }
                if subtree.contains(rowID) {
                    return (item, Int.max)
                }
                return nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    public func items(withIDs ids: Set<String>) -> [LibraryItem] {
        let fromGrid = filteredItems.filter { ids.contains($0.id) }
        if fromGrid.count == ids.count { return fromGrid }
        return items.filter { ids.contains($0.id) }
    }

    /// True when every given item carries the tag (drives the checkmark in
    /// the selection tag menu).
    public func allHaveTag(_ tag: TagRecord, items: [LibraryItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { hasTag(tag, item: $0) }
    }

    /// Selection-wide tag toggle: if every item has the tag, remove it from
    /// all; otherwise add it to the ones missing it.
    public func toggleTag(_ tag: TagRecord, forAll targets: [LibraryItem]) {
        guard let store, let tagID = tag.id, !targets.isEmpty else { return }
        let removeFromAll = allHaveTag(tag, items: targets)
        for item in targets {
            guard let rowID = bookRowIDs[item.id] else { continue }
            var current = Set((itemTags[item.id] ?? []).compactMap(\.id))
            if removeFromAll {
                current.remove(tagID)
            } else {
                current.insert(tagID)
            }
            try? store.setTags(bookID: rowID, tagIDs: current)
        }
        reloadOverlay()
    }

    /// Adds a tag to items by id (sidebar drop target). Never removes.
    public func addTag(tagID: Int64, toItemIDs ids: Set<String>) {
        guard let store else { return }
        for item in items(withIDs: ids) {
            guard let rowID = bookRowIDs[item.id] else { continue }
            var current = Set((itemTags[item.id] ?? []).compactMap(\.id))
            guard !current.contains(tagID) else { continue }
            current.insert(tagID)
            try? store.setTags(bookID: rowID, tagIDs: current)
        }
        reloadOverlay()
    }

    /// True when every given item is in the collection.
    public func allInCollection(_ collection: CollectionRecord, items: [LibraryItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { isInCollection(collection, item: $0) }
    }

    /// Selection-wide collection toggle (mirrors `toggleTag(_:forAll:)`).
    public func toggleCollection(_ collection: CollectionRecord, forAll targets: [LibraryItem]) {
        guard collection.id != nil, !targets.isEmpty else { return }
        let removeFromAll = allInCollection(collection, items: targets)
        for item in targets {
            if removeFromAll {
                if isInCollection(collection, item: item) { toggleCollection(collection, for: item) }
            } else {
                if !isInCollection(collection, item: item) { toggleCollection(collection, for: item) }
            }
        }
    }

    /// Adds items to a collection by id (sidebar drop target), appended
    /// after the existing members. Never removes.
    public func addToCollection(collectionID: Int64, itemIDs ids: Set<String>) {
        guard let store else { return }
        var count = ((try? store.items(inCollection: collectionID)) ?? []).count
        for item in items(withIDs: ids) {
            guard let rowID = bookRowIDs[item.id] else { continue }
            let already = ((try? store.items(inCollection: collectionID)) ?? [])
                .contains { $0.bookID == rowID }
            guard !already else { continue }
            try? store.addToCollection(collectionID: collectionID, bookID: rowID, sortOrder: count)
            count += 1
        }
        reloadOverlay()
    }

    /// Removes the app's OWN imported books from the library (soft-delete in
    /// the overlay DB; the PDF file on disk is untouched). Calibre-sourced
    /// items are skipped entirely — Calibre data is read-only, always.
    public func removeImportedItems(_ targets: [LibraryItem]) {
        guard let store else { return }
        var removedIDs: Set<String> = []
        for item in targets where item.source == .imported {
            guard let rowID = bookRowIDs[item.id] else { continue }
            try? store.softDeleteBook(id: rowID)
            // Forget the scan fingerprint too: with it, a watched file would
            // stay "already reconciled" and the removal would silently undo
            // itself only after a relaunch instead of on the next scan.
            scanFingerprints.removeValue(forKey: DocumentProvider.canonicalPath(for: item.fileURL))
            removedIDs.insert(item.id)
            bookRowIDs[item.id] = nil
        }
        guard !removedIDs.isEmpty else { return }
        items.removeAll { removedIDs.contains($0.id) }
        reloadOverlay()
    }

    #if os(macOS)
    /// Reveals the items' PDF files in Finder. Selecting never downloads —
    /// evicted iCloud placeholders are still selectable in Finder.
    public func revealInFinder(_ targets: [LibraryItem]) {
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.fileURL))
    }
    #endif

    func setItemsForTesting(_ items: [LibraryItem]) {
        self.items = items
        rescope()
    }

    /// Downloads the item's file from iCloud if evicted, tracking it in
    /// `downloading` so the UI can show progress. Shared by both platforms'
    /// open paths; the platform layer decides what "open" means afterwards.
    public func ensureLocalTracked(_ item: LibraryItem) async throws {
        downloading.insert(item.id)
        defer { downloading.remove(item.id) }
        try await FileAvailability.ensureLocal(item.fileURL)
    }

    #if os(macOS)
    /// Ensures the file is local (downloading from iCloud if evicted), then
    /// stages it in a reader window, optionally at a position (full-text
    /// search hits open at their page). Returns a new window ID if one must
    /// be opened by the caller.
    public func openItem(_ item: LibraryItem, at entry: NavEntry? = nil) async throws -> UUID? {
        try await ensureLocalTracked(item)
        return SessionCoordinator.shared.openInReader(fileURL: item.fileURL, at: entry)
    }
    #endif
}
