#if os(macOS)
import Foundation
import Observation
import PDFKit
import ReaderCore
import SearchIndexKit

/// App-level owner of the session: every window's model, the shared document
/// LRU, and the debounced `session.json` persistence that makes browser-style
/// restore possible.
@Observable
@MainActor
public final class SessionCoordinator {
    public static let shared = SessionCoordinator()

    /// One LRU across all windows — the memory bound is per-app, not per-window.
    public let provider = DocumentProvider()

    private(set) var models: [UUID: ReaderWindowModel] = [:]
    private var windowOrder: [UUID] = []

    /// Window states loaded from disk, not yet claimed by a scene.
    private var pendingRestore: [UUID: WindowState] = [:]
    private var pendingOrder: [UUID] = []

    /// During app termination window-close events must not mutate the session.
    private(set) var isTerminating = false

    /// `--open` launch arguments apply to the first window only.
    public var launchArgumentsConsumed = false

    /// The window ID handed to the scene macOS opens at launch.
    private var launchWindowID: UUID?
    private var openedRemaining = false

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let sessionFileURL: URL

    /// Reload generation per canonical document path, bumped after a changed
    /// file was re-read from disk. `ActivePDFView` ids include it, so a bump
    /// rebuilds every pane showing that document — position is captured on
    /// teardown and restored on rebuild, exactly like session restore.
    public private(set) var documentGenerations: [String: Int] = [:]

    /// Watches the resident documents' files; re-armed whenever the set of
    /// resident paths changes. Real app only — never test processes.
    @ObservationIgnored private var documentWatcher: FolderWatcher?
    /// Per-path debounce of in-flight reload attempts.
    @ObservationIgnored private var documentReloadTasks: [String: Task<Void, Never>] = [:]

    public init(sessionFileURL: URL? = nil) {
        self.sessionFileURL = sessionFileURL ?? Self.defaultSessionFileURL()
        // The document LRU size is a user preference (Settings > Memory):
        // start from the persisted value and follow changes live, in
        // ThemeManager's apply-from-didSet style. Growing takes effect on
        // the next load; shrinking evicts immediately.
        provider.capacity = AppSettings.shared.documentCapacity
        AppSettings.shared.onDocumentCapacityChange = { [weak self] capacity in
            guard let self else { return }
            self.provider.capacity = capacity
            self.provider.evictIfNeeded()
        }
        // Auto-reload of changed files: follow the resident set (loads fire
        // during view-body evaluation — defer the re-arm) and the setting.
        provider.onResidentPathsChanged = { [weak self] in
            DispatchQueue.main.async { self?.rearmDocumentWatcher() }
        }
        AppSettings.shared.onAutoReloadDocumentsChange = { [weak self] in
            self?.rearmDocumentWatcher()
        }
        loadSession()
    }

    // MARK: - Auto-reload of changed documents (round 18)

    private func rearmDocumentWatcher() {
        documentWatcher?.stop()
        documentWatcher = nil
        guard !AppStores.isTestProcess, AppSettings.shared.autoReloadDocumentsEnabled
        else { return }
        let paths = provider.residentPaths
        guard !paths.isEmpty else { return }
        documentWatcher = FolderWatcher(paths: paths, latency: 0.5) { [weak self] changed in
            // FolderWatcher delivers on the main queue.
            MainActor.assumeIsolated {
                guard let self else { return }
                let resident = Set(self.provider.residentPaths)
                for path in Set(changed) where resident.contains(path) {
                    self.scheduleDocumentReload(path: path)
                }
            }
        }
    }

    private func scheduleDocumentReload(path: String) {
        documentReloadTasks[path]?.cancel()
        documentReloadTasks[path] = Task { [weak self] in
            // Let the writer finish — regenerations arrive as write bursts.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.reloadChangedDocument(atPath: path)
            self?.documentReloadTasks[path] = nil
        }
    }

    /// Re-reads a changed file and swaps the fresh document into the cache,
    /// then bumps the path's generation so visible panes rebuild onto it.
    /// Retries briefly while the file is mid-write or momentarily absent
    /// (atomic-replace regeneration); gives up quietly otherwise — the
    /// stale document stays usable. Internal for tests.
    func reloadChangedDocument(atPath path: String) async {
        for delay in [0, 500, 1_000, 2_000] {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            if Task.isCancelled { return }
            if provider.reloadFromDisk(path: path) {
                noteDocumentReloaded(atPath: path)
                return
            }
            // Not parseable yet. If the file was evicted from iCloud rather
            // than rewritten, pull it back down before the next attempt.
            let url = URL(fileURLWithPath: path)
            if !FileAvailability.isLocal(url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
    }

    /// Publishes a completed reload (generation bump → pane rebuild) and
    /// rebinds the book identity: regenerated bytes mean a new content
    /// hash, and without the rebind reading state/bookmarks/deep links
    /// would fork onto a duplicate book row. Internal for tests.
    func noteDocumentReloaded(atPath path: String) {
        documentGenerations[path, default: 0] += 1
        guard let store = LibraryModel.shared.store else { return }
        Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            guard let hash = try? ContentHash.compute(for: url) else { return }
            _ = try? store.syncScannedFile(
                path: path,
                hash: hash,
                title: url.deletingPathExtension().lastPathComponent
            )
        }
    }

    // MARK: - Session file

    static func defaultSessionFileURL() -> URL {
        AppDataDirectory.url().appendingPathComponent("session.json")
    }

    /// Known-good copy of the previous session, rotated on every successful
    /// load — a corrupt or wrongly-emptied session.json is never a total loss.
    static func backupSessionFileURL(for sessionFileURL: URL) -> URL {
        sessionFileURL.appendingPathExtension("bak")
    }

    private func loadSession() {
        let backupURL = Self.backupSessionFileURL(for: sessionFileURL)
        if let snapshot = Self.decodeSession(at: sessionFileURL) {
            stage(snapshot)
            if !snapshot.windows.isEmpty {
                // This file restored real windows: it becomes the fallback.
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: sessionFileURL, to: backupURL)
            }
            // A decodable-but-empty session is LEGITIMATE (every tab was
            // closed) — resurrecting the backup here would bring back
            // long-closed books.
        } else if let backup = Self.decodeSession(at: backupURL) {
            // Main file corrupt or missing while a backup exists:
            // recover rather than silently losing everything.
            stage(backup)
        }
    }

    private static func decodeSession(at url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SessionCodec.decode(data)
    }

    private func stage(_ snapshot: SessionSnapshot) {
        // Tabless windows are filtered on save AND on load — the load-side
        // filter cleans sessions written before the save-side one existed.
        for window in snapshot.windows where !window.tabs.isEmpty {
            pendingRestore[window.id] = window
            pendingOrder.append(window.id)
        }
    }

    // MARK: - Window lifecycle

    /// The window ID for the scene macOS opens by default at launch: the
    /// first restored window if any, else a fresh one. Memoized — scene
    /// bodies re-evaluate.
    public func claimLaunchWindowID() -> UUID {
        // Memoized while the window lives or is restorable. When it's gone
        // (last window closed, then a Dock-click reopens the default scene),
        // re-resolve so the reopened window picks up a stashed session
        // instead of materializing empty under a spent ID.
        if let launchWindowID,
           models[launchWindowID] != nil || pendingRestore[launchWindowID] != nil {
            return launchWindowID
        }
        let id = pendingOrder.first ?? UUID()
        launchWindowID = id
        return id
    }

    /// Restored windows beyond the launch window, to be opened once from the
    /// first scene's onAppear.
    public func takeRemainingRestoreIDs() -> [UUID] {
        guard !openedRemaining else { return [] }
        openedRemaining = true
        return pendingOrder.filter { $0 != launchWindowID }
    }

    /// Returns the model for a window, creating it (from restored state when
    /// available) on first request.
    public func model(for windowID: UUID) -> ReaderWindowModel {
        if let model = models[windowID] { return model }
        let restored = pendingRestore.removeValue(forKey: windowID)
        pendingOrder.removeAll { $0 == windowID }

        let model = ReaderWindowModel(
            provider: provider,
            windowID: windowID,
            restoring: restored
        )
        model.onMutation = { [weak self] in self?.scheduleSave() }
        model.onTabClosed = { [weak self] tab, index in
            self?.noteClosed(.tab(tab, sourceWindowID: windowID, index: index))
        }
        models[windowID] = model
        windowOrder.append(windowID)
        scheduleSave()
        return model
    }

    public func windowClosed(_ windowID: UUID) {
        guard !isTerminating else { return }
        let closing = models.removeValue(forKey: windowID)
        windowOrder.removeAll { $0 == windowID }
        // Closing the LAST window must never wipe the session: the app keeps
        // running, so quitting (or Dock-reopening) afterwards would find
        // nothing. Stash the window's state instead — reopen or next launch
        // restores it, browser-style. This was the round-5 session loss.
        if let closing, models.isEmpty, !closing.tabs.isEmpty {
            pendingRestore[windowID] = closing.stateSnapshot
            pendingOrder.append(windowID)
        } else if let closing, !closing.tabs.isEmpty {
            // Other windows remain, so this state would otherwise be gone —
            // ⌘⇧T can bring the whole window back. (The last-window branch
            // above already preserves its state for Dock reopen / relaunch;
            // recording it here too would restore it twice.)
            noteClosed(.window(closing.stateSnapshot))
        }
        if lastFocusedWindowID == windowID {
            lastFocusedWindowID = nil
        }
        scheduleSave()
    }

    // MARK: - Recently closed (⌘⇧T)

    /// A tab or window the user closed this run — what ⌘⇧T restores,
    /// most recent last.
    enum ClosedItem {
        case tab(TabState, sourceWindowID: UUID, index: Int)
        case window(WindowState)
    }

    private(set) var recentlyClosed: [ClosedItem] = []
    private let recentlyClosedLimit = 30

    private func noteClosed(_ item: ClosedItem) {
        recentlyClosed.append(item)
        if recentlyClosed.count > recentlyClosedLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - recentlyClosedLimit)
        }
    }

    public var canReopenClosedItem: Bool { !recentlyClosed.isEmpty }

    /// Pops the most recently closed tab or window, browser-style. A tab
    /// returns to its source window (at its old strip position) when that
    /// window still exists, else to the focused reader window. Returns nil
    /// when the item landed in an existing window, or a staged window ID the
    /// caller must present via `openWindow(id: "reader", value:)` — a
    /// reopened window, or a reopened tab with no window left to land in.
    public func reopenLastClosed() -> UUID? {
        guard let item = recentlyClosed.popLast() else { return nil }
        switch item {
        case .tab(let tab, let sourceWindowID, let index):
            let targetID = models[sourceWindowID] != nil
                ? sourceWindowID
                : lastFocusedWindowID.flatMap { models[$0] != nil ? $0 : nil }
                    ?? windowOrder.last
            if let targetID, let target = models[targetID] {
                target.adoptTab(tab, at: targetID == sourceWindowID ? index : nil)
                target.hostWindow?.makeKeyAndOrderFront(nil)
                return nil
            }
            // No reader window at all: stage a fresh one around the tab.
            let newID = UUID()
            pendingRestore[newID] = WindowState(id: newID, tabs: [tab], activeTabID: tab.id)
            pendingOrder.append(newID)
            scheduleSave()
            return newID
        case .window(let state):
            // Restage under its old ID — frame, tabs, split, and active tab
            // all come back exactly as closed.
            pendingRestore[state.id] = state
            pendingOrder.append(state.id)
            scheduleSave()
            return state.id
        }
    }

    // MARK: - Opening from the library

    /// The reader window that most recently became key; library opens land here.
    private var lastFocusedWindowID: UUID?

    public func noteWindowFocused(_ windowID: UUID) {
        lastFocusedWindowID = windowID
    }

    /// Opens a file as a tab in the most recently focused reader window,
    /// optionally at a position (library search hits, "continue reading").
    /// Returns nil on success, or a fresh window ID the caller must open via
    /// `openWindow(id: "reader", value:)` when no reader window exists —
    /// the tab is already staged in that window's model.
    public func openInReader(fileURL: URL, at entry: NavEntry? = nil) -> UUID? {
        let targetID = lastFocusedWindowID.flatMap { models[$0] != nil ? $0 : nil }
            ?? windowOrder.last
        if let targetID, let target = models[targetID] {
            target.openTab(fileURL: fileURL, at: entry)
            return nil
        }
        let newID = UUID()
        model(for: newID).openTab(fileURL: fileURL, at: entry)
        return newID
    }

    /// Opens every file as a tab in the most recently focused reader window
    /// ("Open Collection"). Same contract as `openInReader`: returns nil on
    /// success, or a staged fresh window ID the caller must present.
    public func openAllInReader(fileURLs: [URL]) -> UUID? {
        guard !fileURLs.isEmpty else { return nil }
        let targetID = lastFocusedWindowID.flatMap { models[$0] != nil ? $0 : nil }
            ?? windowOrder.last
        if let targetID, let target = models[targetID] {
            for url in fileURLs {
                target.openTab(fileURL: url)
            }
            return nil
        }
        let newID = UUID()
        let target = model(for: newID)
        for url in fileURLs {
            target.openTab(fileURL: url)
        }
        return newID
    }

    /// Stages a fresh window holding every file as a tab ("Open Collection
    /// in New Window", palette ⇧⏎); the caller presents the returned ID via
    /// `openWindow(id: "reader", value:)`. `entries` (parallel to
    /// `fileURLs`, nil-padded) position each tab — a section opened in a
    /// new window starts at that section.
    public func openInNewWindow(fileURLs: [URL], entries: [NavEntry?]? = nil) -> UUID {
        let newID = UUID()
        let tabs = fileURLs.enumerated().map { index, url in
            var tab = TabState(pathHint: DocumentProvider.canonicalPath(for: url))
            if let entries, entries.indices.contains(index), let entry = entries[index] {
                tab.apply(entry)
            }
            return tab
        }
        pendingRestore[newID] = WindowState(
            id: newID, tabs: tabs, activeTabID: tabs.first?.id
        )
        pendingOrder.append(newID)
        scheduleSave()
        return newID
    }

    /// Moves a tab between windows (tab-strip drag & drop), preserving its
    /// reading position, zoom, and history. `index` is the insertion point
    /// in the target strip (append when nil).
    public func moveTab(
        _ tabID: UUID,
        from sourceWindowID: UUID,
        to targetWindowID: UUID,
        at index: Int? = nil
    ) {
        guard
            sourceWindowID != targetWindowID,
            let source = models[sourceWindowID],
            let target = models[targetWindowID],
            let tab = source.detachTab(id: tabID)
        else { return }
        target.adoptTab(tab, at: index)
        scheduleSave()
    }

    /// Moves a tab into another window's SPLIT pane (drag-to-split drop on a
    /// content-area half): the tab transfers exactly like `moveTab`, then
    /// opens as the target's split on `side`. A target with no tab of its
    /// own to keep in the primary pane just receives the tab as a plain move.
    public func moveTabIntoSplit(
        _ tabID: UUID,
        from sourceWindowID: UUID,
        to targetWindowID: UUID,
        side: SplitSide
    ) {
        guard
            sourceWindowID != targetWindowID,
            let source = models[sourceWindowID],
            let target = models[targetWindowID],
            let tab = source.detachTab(id: tabID)
        else { return }
        let canSplit = !target.tabs.isEmpty
        target.adoptTab(tab)
        if canSplit {
            target.openInSplit(tabID: tab.id, side: side)
        }
        scheduleSave()
    }

    /// Detaches a tab into a freshly staged window (tab dragged out of the
    /// strip onto the desktop). Returns the new window ID; the caller must
    /// present it via `openWindow(id: "reader", value:)`. The new window
    /// inherits the source window's size, positioned under the drop point.
    public func detachTabToNewWindow(
        _ tabID: UUID,
        from sourceWindowID: UUID,
        at screenPoint: CGPoint? = nil
    ) -> UUID? {
        guard
            let source = models[sourceWindowID],
            source.tabs.contains(where: { $0.id == tabID }),
            let tab = source.detachTab(id: tabID)
        else { return nil }
        let newID = UUID()
        var frame: CGRect?
        if let screenPoint {
            let size = source.windowFrame?.size ?? CGSize(width: 900, height: 700)
            // Drop point becomes roughly the new window's tab-strip area.
            frame = CGRect(
                x: screenPoint.x - size.width / 2,
                y: screenPoint.y - size.height + 24,
                width: size.width,
                height: size.height
            )
        }
        pendingRestore[newID] = WindowState(
            id: newID, frame: frame, tabs: [tab], activeTabID: tab.id
        )
        // Listed in pendingOrder so the snapshot keeps this window even if
        // the app quits before the scene claims the model.
        pendingOrder.append(newID)
        scheduleSave()
        return newID
    }

    // MARK: - Persistence

    func snapshot() -> SessionSnapshot {
        var windows = windowOrder.compactMap { models[$0]?.stateSnapshot }
        // Windows never shown this run keep their saved state.
        windows.append(contentsOf: pendingOrder.compactMap { pendingRestore[$0] })
        // Empty windows don't restore (Chrome/Safari behavior): they carry
        // nothing worth resurrecting, and stray default scenes from odd
        // launches were accumulating as ghost windows across restarts
        // (round 7: the owner's session held four of them).
        windows.removeAll { $0.tabs.isEmpty }
        return SessionSnapshot(windows: windows)
    }

    public func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        do {
            let data = try SessionCodec.encode(snapshot())
            try FileManager.default.createDirectory(
                at: sessionFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: sessionFileURL, options: .atomic)
        } catch {
            NSLog("PDFReader: session save failed: \(error)")
        }
    }

    /// Called from applicationShouldTerminate, before windows tear down.
    public func prepareForTermination() {
        isTerminating = true
        saveNow()
    }
}
#endif
