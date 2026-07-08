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
    func apply(displayModeRaw: Int)
    func fitWidth()
    func fitHeight()
}

/// View-control hooks are optional for test fakes.
public extension ActivePDFControlling {
    func apply(displayModeRaw: Int) {}
    func fitWidth() {}
    func fitHeight() {}
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

    /// Opens a new tab for the file, optionally at a specific position and
    /// optionally inserted right after another tab (so ⌘-clicked references
    /// group next to the tab they came from). The same file may be open in
    /// any number of tabs; they share one document.
    @discardableResult
    public func openTab(
        fileURL: URL,
        activate: Bool = true,
        at entry: NavEntry? = nil,
        after siblingID: UUID? = nil
    ) -> UUID {
        var tab = TabState(pathHint: DocumentProvider.canonicalPath(for: fileURL))
        if let entry {
            tab.apply(entry)
        }
        if let siblingID, let index = tabs.firstIndex(where: { $0.id == siblingID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if activate || activeTabID == nil {
            selectTab(id: tab.id)
        }
        onMutation?()
        return tab.id
    }

    /// Duplicates a tab — same file, position, zoom, and history — inserted
    /// right after the original.
    @discardableResult
    public func duplicateTab(id: UUID) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = tabs[index]
        copy.id = UUID()
        tabs.insert(copy, at: index + 1)
        selectTab(id: copy.id)
        onMutation?()
        return copy.id
    }

    public func closeOtherTabs(keeping id: UUID) {
        for tab in tabs where tab.id != id {
            closeTab(id: tab.id)
        }
    }

    /// Number of open tabs per file — drives the tab strip's group markers.
    public var tabCountByPath: [String: Int] {
        tabs.reduce(into: [:]) { counts, tab in
            counts[tab.pathHint, default: 0] += 1
        }
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

    // MARK: - View controls (bottom bar)

    public func setDisplayMode(_ raw: Int) {
        guard let activeTab else { return }
        updateTab(id: activeTab.id) { $0.displayModeRaw = raw }
        activeController?.apply(displayModeRaw: raw)
    }

    public func fitWidth() {
        guard let activeTab else { return }
        updateTab(id: activeTab.id) { $0.autoScales = true }
        activeController?.fitWidth()
    }

    public func fitHeight() {
        guard let activeTab else { return }
        updateTab(id: activeTab.id) { $0.autoScales = false }
        activeController?.fitHeight()
    }

    // MARK: - Outline (cached per live document)

    @ObservationIgnored private var outlineCacheKey: ObjectIdentifier?
    @ObservationIgnored private var outlineCacheNodes: [OutlineNode] = []
    /// Page index → outline ancestor path, memoized per document (search can
    /// produce hundreds of hits; walking the outline per row is wasteful).
    @ObservationIgnored private var breadcrumbCache: [Int: [String]] = [:]

    /// The outline tree, built once per live document (bodies re-evaluate
    /// constantly; walking PDFOutline each time is wasteful).
    func outline(for document: PDFDocument) -> [OutlineNode] {
        let key = ObjectIdentifier(document)
        if key != outlineCacheKey {
            outlineCacheNodes = OutlineNode.tree(from: document)
            outlineCacheKey = key
            breadcrumbCache = [:]
        }
        return outlineCacheNodes
    }

    /// Outline ancestor path of the page, root first — e.g.
    /// ["Chapter 1", "1A Rⁿ and Cⁿ", "Complex Numbers"]. Empty for PDFs
    /// without an outline (e.g. scans) or pages before the first section.
    func breadcrumbPath(for pageIndex: Int, in document: PDFDocument) -> [String] {
        let nodes = outline(for: document)  // also validates the cache key
        if let cached = breadcrumbCache[pageIndex] { return cached }
        let path = OutlineNode.deepestPath(in: nodes, atOrBefore: pageIndex)
            .filter { !$0.isEmpty }
        breadcrumbCache[pageIndex] = path
        return path
    }

    /// Human label for a history entry: the deepest outline section at or
    /// before the page, falling back to the page number.
    public func historyLabel(for entry: NavEntry) -> String {
        let page = "p.\(entry.pageIndex + 1)"
        guard
            let activeTab,
            let document = provider.document(for: url(for: activeTab)),
            let section = OutlineNode.deepestLabel(
                in: outline(for: document), atOrBefore: entry.pageIndex
            )
        else { return page }
        return "\(section) — \(page)"
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
            openTab(fileURL: fileURL, at: entry, after: activeTab.id)
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

    // MARK: - Tab reordering & cross-window transfer

    /// Moves a tab to a new position in the strip (drag reorder).
    public func moveTab(id: UUID, toIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(toIndex, tabs.count - 1))
        guard from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        onMutation?()
    }

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
    /// zoom, and history intact. `index` is the strip insertion point
    /// (append when nil or out of range).
    func adoptTab(_ tab: TabState, at index: Int? = nil) {
        if let index, (0...tabs.count).contains(index) {
            tabs.insert(tab, at: index)
        } else {
            tabs.append(tab)
        }
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
