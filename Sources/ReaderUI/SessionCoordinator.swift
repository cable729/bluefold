#if os(macOS)
import Foundation
import Observation
import ReaderCore

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

    public init(sessionFileURL: URL? = nil) {
        self.sessionFileURL = sessionFileURL ?? Self.defaultSessionFileURL()
        loadSession()
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
        if let snapshot = Self.decodeSession(at: sessionFileURL),
           !snapshot.windows.isEmpty {
            stage(snapshot)
            // This file restored real windows: it becomes the fallback.
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: sessionFileURL, to: backupURL)
        } else if let backup = Self.decodeSession(at: backupURL) {
            // Main file missing, corrupt, or empty while a previous session
            // had windows — recover rather than silently losing everything.
            stage(backup)
        }
    }

    private static func decodeSession(at url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SessionCodec.decode(data)
    }

    private func stage(_ snapshot: SessionSnapshot) {
        for window in snapshot.windows {
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
        }
        if lastFocusedWindowID == windowID {
            lastFocusedWindowID = nil
        }
        scheduleSave()
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
    /// in New Window"); the caller presents the returned ID via
    /// `openWindow(id: "reader", value:)`.
    public func openInNewWindow(fileURLs: [URL]) -> UUID {
        let newID = UUID()
        let tabs = fileURLs.map {
            TabState(pathHint: DocumentProvider.canonicalPath(for: $0))
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
