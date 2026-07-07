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

    private func loadSession() {
        guard
            let data = try? Data(contentsOf: sessionFileURL),
            let snapshot = try? SessionCodec.decode(data)
        else { return }
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
        if let launchWindowID { return launchWindowID }
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
        models.removeValue(forKey: windowID)
        windowOrder.removeAll { $0 == windowID }
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
