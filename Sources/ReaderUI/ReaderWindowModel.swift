#if os(macOS)
import Foundation
import Observation
import PDFKit
import ReaderCore
import ReaderPersistence

/// State of one reader window: its tab strip and the active tab.
///
/// Tabs are pure `TabState` data from ReaderCore. This model coordinates the
/// scarce resources: it pins the active tab's document in the
/// `DocumentProvider` and receives position captures when a tab's view is
/// torn down.
/// The live view of the active tab, as the model sees it: enough to read the
/// current position and to command a jump. Implemented by ActivePDFView's
/// coordinator; faked in tests.
@MainActor
public protocol ActivePDFControlling: AnyObject {
    var liveNavEntry: NavEntry? { get }
    func execute(_ entry: NavEntry)
    /// Applies find highlights; pass an empty array to clear them.
    func showFindResults(_ matches: [PDFSelection], current: PDFSelection?)
}

@Observable
@MainActor
public final class ReaderWindowModel {
    public private(set) var tabs: [TabState] = []
    public private(set) var activeTabID: UUID?
    public let provider: DocumentProvider
    public let windowID: UUID

    /// Last known window frame in screen coordinates (persisted for restore).
    public private(set) var windowFrame: CGRect?
    /// Frame to apply when the NSWindow first appears (from restored state).
    public private(set) var pendingFrame: CGRect?

    /// Fired after any persistable mutation; the session coordinator hangs
    /// its debounced save here.
    @ObservationIgnored
    public var onMutation: (() -> Void)?

    /// The active tab's live view; registered on creation, dropped on teardown.
    @ObservationIgnored
    public weak var activeController: ActivePDFControlling?

    /// Overlay DB for bookmarks/reading state; nil disables both.
    @ObservationIgnored
    let store: LibraryStore?
    /// Book row per tab pathHint, resolved lazily.
    @ObservationIgnored
    private var bookRowIDCache: [String: Int64] = [:]
    /// Bookmarks of the active tab's book, refreshed on switch/add/delete.
    public private(set) var activeBookmarks: [UserBookmarkRecord] = []

    public init(
        provider: DocumentProvider = DocumentProvider(),
        windowID: UUID = UUID(),
        restoring state: WindowState? = nil,
        store: LibraryStore? = AppStores.library
    ) {
        self.provider = provider
        self.windowID = windowID
        self.store = store
        if let state {
            tabs = state.tabs
            activeTabID = state.activeTabID ?? state.tabs.first?.id
            pendingFrame = state.frame
            windowFrame = state.frame
            refreshPins()
        }
    }

    /// This window's state for the session snapshot.
    public var stateSnapshot: WindowState {
        WindowState(id: windowID, frame: windowFrame, tabs: tabs, activeTabID: activeTabID)
    }

    public func setWindowFrame(_ frame: CGRect) {
        guard frame != windowFrame else { return }
        windowFrame = frame
        onMutation?()
    }

    public func consumePendingFrame() -> CGRect? {
        defer { pendingFrame = nil }
        return pendingFrame
    }

    public var activeTab: TabState? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    public func url(for tab: TabState) -> URL {
        URL(fileURLWithPath: tab.pathHint)
    }

    /// Opens a new tab for the file, optionally at a specific position. The
    /// same file may be open in any number of tabs; they share one document.
    @discardableResult
    public func openTab(fileURL: URL, activate: Bool = true, at entry: NavEntry? = nil) -> UUID {
        var tab = TabState(pathHint: DocumentProvider.canonicalPath(for: fileURL))
        if let entry {
            tab.apply(entry)
        }
        tabs.append(tab)
        if activate || activeTabID == nil {
            selectTab(id: tab.id)
        }
        onMutation?()
        return tab.id
    }

    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        refreshPins()
        refreshBookmarks()
        onMutation?()
    }

    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)

        if activeTabID == id {
            // Neighbor preference: the tab that took the closed tab's slot,
            // else the new last tab, else none.
            let successor = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activeTabID = successor?.id
        }
        refreshPins()

        // Drop the document if no other tab uses that file.
        if !tabs.contains(where: { $0.pathHint == closed.pathHint }) {
            provider.evict(path: closed.pathHint)
        }
        onMutation?()
    }

    /// Called by the view layer when a tab's PDFView is torn down, persisting
    /// the exact reading position for the next activation.
    public func capture(
        tabID: UUID,
        entry: NavEntry,
        autoScales: Bool,
        displayModeRaw: Int
    ) {
        updateTab(id: tabID) { tab in
            tab.apply(entry)
            tab.autoScales = autoScales
            tab.displayModeRaw = displayModeRaw
        }
        if let tab = tabs.first(where: { $0.id == tabID }) {
            persistReadingState(for: tab)
        }
    }

    // MARK: - Reading state & bookmarks (overlay DB)

    static let deviceName = Host.current().localizedName ?? "Mac"

    func bookRowID(for tab: TabState) -> Int64? {
        if let cached = bookRowIDCache[tab.pathHint] { return cached }
        guard let store else { return nil }
        guard let id = BookResolver.resolveBookID(
            forFileAt: URL(fileURLWithPath: tab.pathHint), store: store
        ) else { return nil }
        bookRowIDCache[tab.pathHint] = id
        return id
    }

    func persistReadingState(for tab: TabState) {
        guard let store, let bookID = bookRowID(for: tab) else { return }
        try? store.setReadingState(bookID: bookID, page: tab.pageIndex, device: Self.deviceName)
    }

    public func refreshBookmarks() {
        guard let store, let activeTab, let bookID = bookRowID(for: activeTab) else {
            activeBookmarks = []
            return
        }
        activeBookmarks = (try? store.bookmarks(forBook: bookID)) ?? []
    }

    /// Bookmarks the active tab's current live page (⌘D).
    public func addBookmarkAtCurrentPosition() {
        guard let store, let activeTab, let bookID = bookRowID(for: activeTab) else { return }
        let page = activeController?.liveNavEntry?.pageIndex ?? activeTab.pageIndex
        _ = try? store.addBookmark(bookID: bookID, page: page)
        refreshBookmarks()
    }

    public func deleteBookmark(id: Int64) {
        try? store?.softDeleteBookmark(id: id)
        refreshBookmarks()
    }

    public func updateTab(id: UUID, _ mutate: (inout TabState) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[index])
        onMutation?()
    }

    /// Closes the active tab; returns false when there is none (caller may
    /// close the window instead, browser-style).
    @discardableResult
    public func closeActiveTab() -> Bool {
        guard let activeTabID else { return false }
        closeTab(id: activeTabID)
        return true
    }

    /// Standard open panel; each chosen PDF becomes a tab in this window.
    public func openTabViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            openTab(fileURL: url)
        }
    }

    // MARK: - Navigation (single source of truth: ReaderCore.NavigationHistory)

    /// Handles an activated internal link for the active tab.
    ///
    /// Same-document, plain click: push `current` onto history, jump in place.
    /// ⌘-click (or a link into another PDF file): open a new tab at the
    /// target — the originating tab doesn't move, matching browser behavior.
    public func linkActivated(target entry: NavEntry, remoteFileURL: URL?, current: NavEntry, inNewTab: Bool) {
        guard let activeTab else { return }

        let fileURL = remoteFileURL ?? url(for: activeTab)
        if inNewTab || remoteFileURL != nil {
            openTab(fileURL: fileURL, at: entry)
        } else {
            updateTab(id: activeTab.id) { tab in
                tab.history.push(current)
                tab.apply(entry)
            }
            activeController?.execute(entry)
        }
    }

    /// Records a jump initiated by chrome (outline click, thumbnail, search
    /// hit): history push + in-place navigation.
    public func jump(to entry: NavEntry) {
        guard let activeTab, let controller = activeController else { return }
        let current = controller.liveNavEntry ?? activeTab.currentNavEntry
        updateTab(id: activeTab.id) { tab in
            tab.history.push(current)
            tab.apply(entry)
        }
        controller.execute(entry)
    }

    public var canGoBack: Bool { activeTab?.history.canGoBack ?? false }
    public var canGoForward: Bool { activeTab?.history.canGoForward ?? false }

    /// Back stack, most recent target first (for the history menu).
    public var backEntries: [NavEntry] { (activeTab?.history.back ?? []).reversed() }
    /// Forward stack, nearest target first (for the history menu).
    public var forwardEntries: [NavEntry] { (activeTab?.history.forward ?? []).reversed() }

    public func goBack(count: Int = 1) {
        for _ in 0..<count {
            traverseHistory { history, current in history.goBack(from: current) }
        }
    }

    public func goForward(count: Int = 1) {
        for _ in 0..<count {
            traverseHistory { history, current in history.goForward(from: current) }
        }
    }

    /// Continuous position update as the user scrolls/pages — keeps restore
    /// crash-safe and the sidebar's current-section highlight live. Not a
    /// history event.
    public func noteCurrentPage(tabID: UUID, pageIndex: Int) {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            tabs[index].pageIndex != pageIndex
        else { return }
        tabs[index].pageIndex = pageIndex
        if tabID == activeTabID {
            persistReadingState(for: tabs[index])
        }
        onMutation?()
    }

    // MARK: - Cross-window tab transfer

    /// Detaches a tab, preserving its full state. The shared document stays
    /// in the provider (the receiving window uses the same one).
    func detachTab(id: UUID) -> TabState? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabID == id {
            let successor = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activeTabID = successor?.id
        }
        refreshPins()
        refreshBookmarks()
        onMutation?()
        return tab
    }

    /// Adopts a tab detached from another window, keeping its position,
    /// zoom, and history intact.
    func adoptTab(_ tab: TabState) {
        tabs.append(tab)
        selectTab(id: tab.id)
        onMutation?()
    }

    private func traverseHistory(
        _ move: (inout NavigationHistory, NavEntry) -> NavEntry?
    ) {
        guard let activeTab, let controller = activeController else { return }
        let current = controller.liveNavEntry ?? activeTab.currentNavEntry
        var target: NavEntry?
        updateTab(id: activeTab.id) { tab in
            target = move(&tab.history, current)
            if let target {
                tab.apply(target)
            }
        }
        if let target {
            controller.execute(target)
        }
    }

    /// Pins exactly the active tab's document so LRU eviction can never
    /// remove what is on screen.
    private func refreshPins() {
        if let activeTab {
            provider.pinnedPaths = [activeTab.pathHint]
        } else {
            provider.pinnedPaths = []
        }
        provider.evictIfNeeded()
    }
}
#endif
