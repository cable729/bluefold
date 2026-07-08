import Foundation
import Observation
import PDFKit
import ReaderCore
import ReaderUI

/// What the session model needs from the live PDF view (implemented by
/// PDFKitView's coordinator). The iOS analog of ReaderUI's
/// `ActivePDFControlling`, trimmed to navigation.
@MainActor
protocol ActivePDFNavigating: AnyObject {
    /// The view's precise current position, if it has one.
    var liveNavEntry: NavEntry? { get }
    /// Scrolls the view to an entry (validated-point navigation).
    func execute(_ entry: NavEntry)
}

/// Single-window session model for iOS: owns the tab strip, the active tab,
/// navigation history, and session persistence (Documents/session.json via
/// SessionCodec — the same versioned format the macOS app writes).
///
/// Memory rule (shared with macOS): tabs are lightweight `TabState` values;
/// only the active tab ever has a live PDFView. Documents come from the
/// shared `DocumentProvider` LRU (which also installs `ThemedPDFPage`), with
/// the active tab's path pinned.
@MainActor
@Observable
final class ReaderSessionModel {
    private(set) var tabs: [TabState] = []
    private(set) var activeTabID: UUID?
    /// Resolved, security-scope-accessed URL for the active tab (nil when
    /// there is no active tab or its bookmark failed to resolve).
    private(set) var activeURL: URL?
    /// Tab whose file is currently being downloaded from iCloud (dataless
    /// placeholder); drives the progress overlay.
    private(set) var downloadingTabID: UUID?
    /// Set when a download attempt for the active tab failed.
    private(set) var downloadError: String?

    /// The live view of the active tab, for navigation commands. Weak: the
    /// coordinator owns itself via the view hierarchy.
    weak var activeController: (any ActivePDFNavigating)?

    /// Live PDFDocument LRU shared with the macOS memory model; installs
    /// ThemedPDFPage on every document it loads.
    let provider = DocumentProvider()

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

    /// The active tab's document — nil while its file is still downloading
    /// or unreadable. Reads observable state (`activeURL`,
    /// `downloadingTabID`) so a finished download re-evaluates the body.
    var activeDocument: PDFDocument? {
        guard let activeURL, downloadingTabID == nil else { return nil }
        return provider.document(for: activeURL)
    }

    // MARK: - Tab operations

    /// Opens each URL (from the document picker) in a new tab.
    func open(urls: [URL]) {
        for url in urls {
            openTab(url: url)
        }
    }

    /// Opens a new tab on `url`, optionally at a position (library search
    /// hits open at their page). Stores a security-scoped bookmark so the
    /// tab survives relaunch.
    func openTab(url: URL, at entry: NavEntry? = nil) {
        // Keep access open for the life of the tab; PDFDocument reads
        // pages lazily from disk.
        let accessing = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData()
        var tab = TabState(fileBookmark: bookmark, pathHint: url.path)
        tab.autoScales = true
        if let entry {
            tab.apply(entry)
        }
        tabs.append(tab)
        if accessing {
            scopedURLs[tab.id] = url
        }
        setActive(tab.id, url: url)
    }

    func activate(_ id: UUID?) {
        guard activeTabID != id else { return }
        guard let id, let tab = tabs.first(where: { $0.id == id }) else {
            setActive(nil, url: nil)
            return
        }
        setActive(id, url: resolveURL(for: tab))
    }

    private func setActive(_ id: UUID?, url: URL?) {
        activeTabID = id
        activeURL = url
        downloadingTabID = nil
        downloadError = nil
        if let url {
            provider.pinnedPaths = [DocumentProvider.canonicalPath(for: url)]
            provider.evictIfNeeded()
            startDownloadIfNeeded(tabID: id, url: url)
        } else {
            provider.pinnedPaths = []
        }
    }

    /// Dataless-file flow: an iCloud-evicted file can't open until its bytes
    /// are local. Kicks a coordinated download and shows progress via
    /// `downloadingTabID`; when it clears, `activeDocument` re-evaluates.
    private func startDownloadIfNeeded(tabID: UUID?, url: URL) {
        guard let tabID, !FileAvailability.isLocal(url) else { return }
        downloadingTabID = tabID
        Task {
            do {
                try await FileAvailability.ensureLocal(url)
            } catch {
                if activeTabID == tabID {
                    downloadError = error.localizedDescription
                }
            }
            if downloadingTabID == tabID {
                downloadingTabID = nil
            }
        }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let url = scopedURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        let closed = tabs.remove(at: index)
        if activeTabID == id {
            // Unpin before evicting, or the closed document stays resident.
            activeTabID = nil
            activeURL = nil
            downloadingTabID = nil
            provider.pinnedPaths = []
            let neighbor = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activate(neighbor?.id)
        }
        if !tabs.contains(where: { $0.pathHint == closed.pathHint }) {
            provider.evict(path: DocumentProvider.canonicalPath(
                for: URL(fileURLWithPath: closed.pathHint)))
        }
    }

    // MARK: - Navigation & history (single source of truth: ReaderCore)

    /// Handles a tapped internal link: push `current` (the position being
    /// left) onto the active tab's history, then jump in place. Links into
    /// another PDF open a new tab at the destination, browser-style.
    func linkActivated(target: LinkTarget, current: NavEntry) {
        if let remote = target.remoteFileURL {
            openTab(url: remote, at: target.entry)
            return
        }
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        tabs[index].history.push(current)
        tabs[index].apply(target.entry)
        activeController?.execute(target.entry)
    }

    var canGoBack: Bool { activeTab?.history.canGoBack ?? false }
    var canGoForward: Bool { activeTab?.history.canGoForward ?? false }

    func goBack() {
        traverseHistory { history, current in history.goBack(from: current) }
    }

    func goForward() {
        traverseHistory { history, current in history.goForward(from: current) }
    }

    private func traverseHistory(
        _ step: (inout NavigationHistory, NavEntry) -> NavEntry?
    ) {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let current = activeController?.liveNavEntry ?? tabs[index].currentNavEntry
        guard let target = step(&tabs[index].history, current) else { return }
        tabs[index].apply(target)
        activeController?.execute(target)
    }

    // MARK: - Position capture (from the live PDFView)

    /// Continuous page tracking (PDFViewPageChanged) for crash-safe restore.
    /// Not a history event.
    func updatePage(tabID: UUID, pageIndex: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].pageIndex = pageIndex
    }

    /// Precise position captured from the PDFView as it is torn down
    /// (tab switch or close).
    func capture(tabID: UUID, entry: NavEntry, autoScales: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].apply(entry)
        tabs[index].autoScales = autoScales
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
