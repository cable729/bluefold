import Foundation
import Observation
import ReaderCore

/// Single-window session model for iOS: owns the tab strip, the active tab,
/// and session persistence (Documents/session.json via SessionCodec — the
/// same versioned format the macOS app writes).
///
/// Memory rule (shared with macOS): tabs are lightweight `TabState` values;
/// only the active tab ever has a live PDFView/PDFDocument. Switching tabs
/// destroys the view after capturing its position back into the TabState.
@MainActor
@Observable
final class ReaderSessionModel {
    private(set) var tabs: [TabState] = []
    private(set) var activeTabID: UUID?
    /// Resolved, security-scope-accessed URL for the active tab (nil when
    /// there is no active tab or its bookmark failed to resolve).
    private(set) var activeURL: URL?

    private var windowID = UUID()
    /// URLs holding startAccessingSecurityScopedResource, per tab.
    private var scopedURLs: [UUID: URL] = [:]

    nonisolated static var sessionFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session.json")
    }

    init() {
        restore()
    }

    var activeTab: TabState? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    // MARK: - Tab operations

    /// Opens each URL (from the document picker) in a new tab, storing a
    /// security-scoped bookmark so the tab survives relaunch.
    func open(urls: [URL]) {
        for url in urls {
            // Keep access open for the life of the tab; PDFDocument reads
            // pages lazily from disk.
            let accessing = url.startAccessingSecurityScopedResource()
            let bookmark = try? url.bookmarkData()
            var tab = TabState(fileBookmark: bookmark, pathHint: url.path)
            tab.autoScales = true
            tabs.append(tab)
            if accessing {
                scopedURLs[tab.id] = url
            }
            activeTabID = tab.id
            activeURL = url
        }
    }

    func activate(_ id: UUID?) {
        guard activeTabID != id else { return }
        activeTabID = id
        activeURL = id.flatMap { tabID in
            tabs.first { $0.id == tabID }.flatMap { resolveURL(for: $0) }
        }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let url = scopedURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = nil
            activeURL = nil
            let neighbor = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activate(neighbor?.id)
        }
    }

    // MARK: - Position capture (from the live PDFView)

    /// Continuous page tracking (PDFViewPageChanged) for crash-safe restore.
    func updatePage(tabID: UUID, pageIndex: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].pageIndex = pageIndex
    }

    /// Precise position captured from PDFView.currentDestination as the view
    /// is torn down (tab switch or close).
    func captureTeardown(tabID: UUID, pageIndex: Int, point: CGPoint?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].pageIndex = pageIndex
        tabs[index].destinationPoint = point
    }

    // MARK: - Session persistence

    func save() {
        let window = WindowState(id: windowID, frame: nil, tabs: tabs, activeTabID: activeTabID)
        let snapshot = SessionSnapshot(windows: [window])
        do {
            let data = try SessionCodec.encode(snapshot)
            try data.write(to: Self.sessionFileURL, options: .atomic)
        } catch {
            // Non-fatal: worst case the next launch starts empty.
        }
    }

    private func restore() {
        guard
            let data = try? Data(contentsOf: Self.sessionFileURL),
            let snapshot = try? SessionCodec.decode(data),
            let window = snapshot.windows.first
        else { return }
        windowID = window.id
        tabs = window.tabs
        let target = window.activeTabID ?? tabs.first?.id
        activeTabID = nil  // force activate() to resolve
        activate(target)
    }

    /// Resolves a tab's bookmark to a live, security-scope-accessed URL,
    /// refreshing the stored bookmark if it went stale.
    private func resolveURL(for tab: TabState) -> URL? {
        if let cached = scopedURLs[tab.id] {
            return cached
        }
        guard let bookmark = tab.fileBookmark else {
            let url = URL(fileURLWithPath: tab.pathHint)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        else { return nil }
        if url.startAccessingSecurityScopedResource() {
            scopedURLs[tab.id] = url
        }
        if stale,
            let fresh = try? url.bookmarkData(),
            let index = tabs.firstIndex(where: { $0.id == tab.id })
        {
            tabs[index].fileBookmark = fresh
        }
        return url
    }
}
