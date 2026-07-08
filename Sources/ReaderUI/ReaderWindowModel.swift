#if os(macOS)
import AppKit
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
    /// Turn one "step" back/forward without a history push (status-bar
    /// arrows, arrow keys, palette commands) — the view decides what a step
    /// is for its display mode (e.g. a spread in two-up).
    func goToPreviousPage()
    func goToNextPage()
}

/// View-control hooks are optional for test fakes.
public extension ActivePDFControlling {
    func apply(displayModeRaw: Int) {}
    func fitWidth() {}
    func fitHeight() {}
    func goToPreviousPage() {}
    func goToNextPage() {}
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

    /// The NSWindow hosting this model's scene (registered by the window's
    /// key-event bridge; used to focus another window's tab from the palette).
    @ObservationIgnored
    public weak var hostWindow: NSWindow?

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
            splitTabID = state.splitTabID.flatMap { id in
                state.tabs.contains { $0.id == id } ? id : nil
            }
            pendingFrame = state.frame
            windowFrame = state.frame
            refreshPins()
        }
    }

    /// This window's state for the session snapshot.
    public var stateSnapshot: WindowState {
        WindowState(
            id: windowID, frame: windowFrame, tabs: tabs,
            activeTabID: activeTabID, splitTabID: splitTabID
        )
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

    // MARK: - Split view

    /// Tab shown in the secondary pane; nil = not split.
    public private(set) var splitTabID: UUID?

    public var splitTab: TabState? {
        guard let splitTabID else { return nil }
        return tabs.first { $0.id == splitTabID }
    }

    /// Shows a tab in the secondary pane. Splitting the active tab first
    /// moves activation to another tab so the two panes never show the same
    /// tab (two live views over one TabState would fight over its position).
    public func openInSplit(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if tabID == activeTabID {
            if let other = tabs.first(where: { $0.id != tabID }) {
                selectTab(id: other.id)
            } else {
                return // only tab in the window: nothing to split against
            }
        }
        splitTabID = tabID
        refreshPins()
        onMutation?()
    }

    public func closeSplit() {
        guard splitTabID != nil else { return }
        splitTabID = nil
        refreshPins()
        onMutation?()
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
        } else {
            // Background tabs (⌘-click) get their breadcrumb NOW if the
            // document is resident (same book: it always is) — the strip
            // used to show "p.98" until the tab was first activated.
            refreshBreadcrumb(tabID: tab.id)
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

    /// Closes several tabs at once (strip multi-selection).
    public func closeTabs(ids: [UUID]) {
        for id in ids {
            closeTab(id: id)
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
        refreshBreadcrumb(tabID: id)
        onMutation?()
    }

    /// Activates the tab after the active one, wrapping at the end
    /// (⌃Tab / ⌘⇧]).
    public func selectNextTab() {
        cycleTab(by: 1)
    }

    /// Activates the tab before the active one, wrapping at the start
    /// (⌃⇧Tab / ⌘⇧[).
    public func selectPreviousTab() {
        cycleTab(by: -1)
    }

    /// Direct tab selection, browser-style: 1-based; 9 always means the
    /// LAST tab (⌘9 in Safari/Chrome). Out-of-range numbers no-op.
    public func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        selectTab(id: tabs[index].id)
    }

    private func cycleTab(by offset: Int) {
        guard !tabs.isEmpty else { return }
        guard
            let activeTabID,
            let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else {
            selectTab(id: tabs[0].id)
            return
        }
        let count = tabs.count
        let next = ((index + offset) % count + count) % count
        guard next != index else { return }
        selectTab(id: tabs[next].id)
    }

    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        tabBreadcrumbs.removeValue(forKey: id)
        if splitTabID == id {
            splitTabID = nil
        }

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
        refreshBreadcrumb(tabID: tabID)
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

    /// Page-turn arrows (status bar). Not a history event: the resulting
    /// page change streams back via the live view's page-change observer,
    /// exactly like scrolling.
    public func goToPreviousPage() {
        activeController?.goToPreviousPage()
    }

    public func goToNextPage() {
        activeController?.goToNextPage()
    }

    // MARK: - Section skipping (status-bar ⇤ ⇥ buttons)

    /// Outline of the active document, or [] without one.
    private var activeOutline: [OutlineNode] {
        guard
            let activeTab,
            let document = provider.document(for: url(for: activeTab))
        else { return [] }
        return outline(for: document)
    }

    /// Where the reader actually IS — the live view's scroll anchor when
    /// available (page + in-page point), falling back to the tab's stored
    /// position. Point precision matters: several sections share a page.
    private var currentPosition: NavEntry? {
        activeController?.liveNavEntry ?? activeTab?.currentNavEntry
    }

    public var canGoToPreviousSection: Bool {
        guard let currentPosition else { return false }
        return OutlineNode.sectionEntry(in: activeOutline, before: currentPosition) != nil
    }

    public var canGoToNextSection: Bool {
        guard let currentPosition else { return false }
        return OutlineNode.sectionEntry(in: activeOutline, after: currentPosition) != nil
    }

    /// Section skips are deliberate navigation: they push history, so ⌘[
    /// returns to where reading left off. The target is the section's exact
    /// destination (page AND point) — identical to clicking it in the
    /// outline (round 10: page-only jumps landed at the top of the page).
    public func goToPreviousSection() {
        guard
            let currentPosition,
            let entry = OutlineNode.sectionEntry(in: activeOutline, before: currentPosition)
        else { return }
        jump(to: entry)
    }

    public func goToNextSection() {
        guard
            let currentPosition,
            let entry = OutlineNode.sectionEntry(in: activeOutline, after: currentPosition)
        else { return }
        jump(to: entry)
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

    // MARK: - Tab strip breadcrumbs

    /// Last known outline breadcrumb per tab, for the strip's second row.
    /// Transient (not persisted) and kept after document eviction so
    /// background tabs keep their label without reloading anything.
    public private(set) var tabBreadcrumbs: [UUID: String] = [:]

    /// Refreshes the breadcrumb of every tab showing the document at `url`
    /// — called when a view attaches (the document just became resident),
    /// so restored background tabs get labels without being activated.
    public func refreshBreadcrumbs(forDocumentAt url: URL) {
        let path = DocumentProvider.canonicalPath(for: url)
        for tab in tabs where tab.pathHint == path {
            refreshBreadcrumb(tabID: tab.id)
        }
    }

    /// Recomputes a tab's breadcrumb if its document is resident; keeps the
    /// last known value otherwise. Never loads a document (LRU stays intact).
    func refreshBreadcrumb(tabID: UUID) {
        guard
            let tab = tabs.first(where: { $0.id == tabID }),
            let document = provider.loadedDocument(for: url(for: tab))
        else { return }
        // The active document goes through the memoized path; other resident
        // documents take a one-off walk so they never evict its cache.
        let path: [String] =
            if tabID == activeTabID {
                breadcrumbPath(for: tab.pageIndex, in: document)
            } else {
                OutlineNode.deepestPath(
                    in: OutlineNode.tree(from: document), atOrBefore: tab.pageIndex
                ).filter { !$0.isEmpty }
            }
        let crumb = path.joined(separator: " › ")
        if tabBreadcrumbs[tabID] != crumb {
            tabBreadcrumbs[tabID] = crumb
        }
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

    /// Handles an activated internal link.
    ///
    /// Same-document, plain click: push `current` onto the SOURCE tab's
    /// history, jump that tab's view in place. ⌘-click: open a BACKGROUND
    /// tab at the target next to the source — the originating tab stays
    /// active, matching browser ⌘-click. A plain click on a link into
    /// another PDF file opens and activates its tab. The source defaults to
    /// the active tab; the split pane routes through its own tab and view.
    public func linkActivated(
        sourceTabID: UUID? = nil,
        via controller: ActivePDFControlling? = nil,
        target entry: NavEntry,
        remoteFileURL: URL?,
        current: NavEntry,
        inNewTab: Bool
    ) {
        let tabID = sourceTabID ?? activeTabID
        guard let source = tabs.first(where: { $0.id == tabID }) else { return }

        let fileURL = remoteFileURL ?? url(for: source)
        if inNewTab || remoteFileURL != nil {
            // ⌘-click = browser semantics: the reference opens in an
            // adjacent tab WITHOUT switching away from what you're reading.
            // A plain click on a cross-file link still navigates (activates).
            openTab(fileURL: fileURL, activate: !inNewTab, at: entry, after: source.id)
        } else {
            updateTab(id: source.id) { tab in
                tab.history.push(current)
                tab.apply(entry)
            }
            let executor = controller
                ?? (source.id == activeTabID ? activeController : nil)
            executor?.execute(entry)
            // The page-change notification won't refresh the strip label:
            // its guard sees the pageIndex we just applied and bails. The
            // breadcrumb stayed stale until the user scrolled (round 9).
            refreshBreadcrumb(tabID: source.id)
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
        refreshBreadcrumb(tabID: activeTab.id)  // see linkActivated
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
        refreshBreadcrumb(tabID: tabID)
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
        tabBreadcrumbs.removeValue(forKey: id)
        if splitTabID == id {
            splitTabID = nil
        }
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
            refreshBreadcrumb(tabID: activeTab.id)  // see linkActivated
        }
    }

    /// Pins exactly the on-screen documents (active tab, plus the split
    /// pane's tab when the window is split) so LRU eviction can never remove
    /// what is visible.
    private func refreshPins() {
        var pinned: Set<String> = []
        if let activeTab {
            pinned.insert(activeTab.pathHint)
        }
        if let splitTab {
            pinned.insert(splitTab.pathHint)
        }
        provider.pinnedPaths = pinned
        provider.evictIfNeeded()
    }
}
#endif
