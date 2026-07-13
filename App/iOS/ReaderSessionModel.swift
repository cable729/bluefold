import Foundation
import Observation
import PDFKit
import ReaderCore
import ReaderPersistence
import ReaderUI
import UIKit

/// What the session model needs from the live PDF view (implemented by
/// PDFKitView's coordinator). The iOS analog of ReaderUI's
/// `ActivePDFControlling`, trimmed to navigation.
@MainActor
protocol ActivePDFNavigating: AnyObject {
    /// The view's precise current position, if it has one.
    var liveNavEntry: NavEntry? { get }
    /// Scrolls the view to an entry (validated-point navigation).
    func execute(_ entry: NavEntry)
    /// Applies a page-layout change to the live view.
    func apply(displayMode: PDFDisplayMode)
    /// Presents the system find UI (UIFindInteraction).
    func presentFindNavigator()
    /// Highlights a find match in the view (sidebar Find mode).
    func highlight(_ selection: PDFSelection?)
    /// Fit-to-width / fit-to-height (status bar; same semantics as macOS
    /// ActivePDFControlling: width = autoScales, height = explicit scale).
    func fitWidth()
    func fitHeight()
    /// One "step" back/forward without a history push — the view decides
    /// what a step is for its display mode (a spread in two-up).
    func goToPreviousPage()
    func goToNextPage()
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
    /// The split pane's live view, when a split is open.
    weak var splitController: (any ActivePDFNavigating)?

    /// Tab shown in the trailing split pane (iPad). Mirrors macOS
    /// WindowState.splitTabID; the tab stays in the strip.
    private(set) var splitTabID: UUID?
    /// Resolved URL for the split tab (same lifecycle as `activeURL`).
    private(set) var splitURL: URL?

    /// Live scroll position of the active view (transient — crash-safe
    /// restore only persists the page index, like macOS). Drives the
    /// breadcrumb, the sidebar follow highlight, and section stepping.
    private(set) var livePosition: NavEntry?

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
        // Arm autosave AFTER restore, so reloading the session doesn't
        // immediately rewrite the file we just read.
        autosaver = AutosaveObserver(
            track: { [weak self] in
                guard let self else { return }
                // Everything `save()`'s snapshot reads. Mutating a tab's
                // stored position writes back through the `tabs` array
                // property, so subscript edits (page, zoom, history) trip
                // this too.
                _ = self.tabs
                _ = self.activeTabID
                _ = self.splitTabID
                _ = self.splitAxis
                _ = self.splitSide
            },
            save: { [weak self] in self?.save() }
        )
        autosaver.start()
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
    /// tab survives relaunch. `insertAt` places the tab (default: end);
    /// `activate: false` opens it in the background (⌘-tap links).
    @discardableResult
    func openTab(
        url: URL, at entry: NavEntry? = nil,
        insertAt: Int? = nil, activate: Bool = true
    ) -> UUID {
        // Keep access open for the life of the tab; PDFDocument reads
        // pages lazily from disk.
        let accessing = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData()
        var tab = TabState(fileBookmark: bookmark, pathHint: url.path)
        tab.autoScales = true
        // A freshly opened book always starts in single-page continuous scroll,
        // regardless of what mode other tabs are in. (Restored tabs keep their
        // own layout — restore() doesn't route through here.)
        tab.displayModeRaw = PDFDisplayMode.singlePageContinuous.rawValue
        if let entry {
            tab.apply(entry)
        }
        tabs.insert(tab, at: min(insertAt ?? tabs.count, tabs.count))
        if accessing {
            scopedURLs[tab.id] = url
        }
        if activate {
            setActive(tab.id, url: url)
        } else {
            // Background tab (⌘-tap / long-press "New Tab"): fill its
            // breadcrumb from the resident document so it shows the section,
            // not "p.N".
            refreshBreadcrumb(forTabWithID: tab.id)
        }
        return tab.id
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
        livePosition = nil
        repin()
        if let url {
            startDownloadIfNeeded(tabID: id, url: url)
        }
        refreshBookmarks()
        if let id {
            refreshBreadcrumb(forTabWithID: id)
        }
    }

    /// Fills in a tab's outline breadcrumb from its resident document — so a
    /// freshly opened or restored tab shows its SECTION, not "p.N", before
    /// the first scroll tick lands (the macOS app does this on view attach).
    /// No-op if the document isn't on screen yet (evicted / downloading);
    /// re-run when it becomes available.
    func refreshBreadcrumb(forTabWithID id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let nodes: [OutlineNode]
        if id == activeTabID, let outline = outline() {
            nodes = outline.nodes
        } else if id == splitTabID, let document = splitDocument {
            nodes = OutlineNode.tree(from: document)
        } else if let url = resolveURL(for: tabs[index]),
                  let document = provider.loadedDocument(for: url) {
            // A background tab whose document is already resident (a link
            // opened into a new tab of the same book — never loads a doc).
            nodes = OutlineNode.tree(from: document)
        } else {
            return
        }
        let path = OutlineNode.deepestPath(in: nodes, atOrBefore: tabs[index].pageIndex)
        let crumb = path.joined(separator: " › ")
        if !crumb.isEmpty, tabs[index].breadcrumb != crumb {
            tabs[index].breadcrumb = crumb
        }
    }

    /// Pins every on-screen document (active + split pane) in the LRU.
    private func repin() {
        var paths: Set<String> = []
        if let activeURL {
            paths.insert(DocumentProvider.canonicalPath(for: activeURL))
        }
        if let splitURL {
            paths.insert(DocumentProvider.canonicalPath(for: splitURL))
        }
        provider.pinnedPaths = paths
        provider.evictIfNeeded()
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
                // Document just became readable — fill in its breadcrumb.
                refreshBreadcrumb(forTabWithID: tabID)
            }
        }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if id == splitTabID {
            closeSplit()
        }
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

    /// Tab switching by position: 1…8 = that tab, 9 = LAST tab (browser
    /// convention, same as macOS ⌘1–9).
    func activateTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index].id)
    }

    /// Next (+1) / previous (−1) tab, wrapping (⌘⇧] / ⌘⇧[).
    func activateAdjacentTab(offset: Int) {
        guard
            let activeTabID,
            let index = tabs.firstIndex(where: { $0.id == activeTabID }),
            tabs.count > 1
        else { return }
        let next = (index + offset + tabs.count) % tabs.count
        activate(tabs[next].id)
    }

    // MARK: - Page layout & find (live-view commands)

    var activeDisplayMode: PDFDisplayMode {
        PDFDisplayMode(rawValue: activeTab?.displayModeRaw ?? 1) ?? .singlePageContinuous
    }

    /// Persists the layout on the active tab and applies it to the live
    /// view in place (no view rebuild — position is kept by PDFKit).
    func setDisplayMode(_ mode: PDFDisplayMode) {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        tabs[index].displayModeRaw = mode.rawValue
        // A layout switch re-fits (autoScales), so it must not be persisted
        // as a fixed zoom — otherwise the next launch restores a stale scale.
        tabs[index].autoScales = true
        activeController?.apply(displayMode: mode)
    }

    func presentFind() {
        activeController?.presentFindNavigator()
    }

    func fitWidth() {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        tabs[index].autoScales = true
        activeController?.fitWidth()
    }

    func fitHeight() {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        tabs[index].autoScales = false
        activeController?.fitHeight()
    }

    /// Page-turn arrows. Not a history event: the page change streams back
    /// via the live view's page observer, exactly like scrolling.
    func goToPreviousPage() {
        activeController?.goToPreviousPage()
    }

    func goToNextPage() {
        activeController?.goToNextPage()
    }

    // MARK: - Split pane (iPad)

    var splitTab: TabState? {
        guard let splitTabID else { return nil }
        return tabs.first { $0.id == splitTabID }
    }

    /// The split pane's document (nil closes/hides the pane).
    var splitDocument: PDFDocument? {
        guard let splitURL, splitTabID != nil else { return nil }
        return provider.document(for: splitURL)
    }

    /// Axis the split divides along: `.horizontal` = side-by-side (iPad),
    /// `.vertical` = stacked top/bottom (iPhone, and iPad by choice).
    private(set) var splitAxis: SplitAxis = .horizontal
    /// Which side the SPLIT (secondary) pane sits on: `.trailing` = right
    /// or bottom (default), `.leading` = left or top.
    private(set) var splitSide: SplitSide = .trailing

    /// ⌘\ toggle: no split → duplicate the active tab into a split on
    /// `axis`; split open → close it (macOS Split Right semantics).
    func toggleSplit(axis: SplitAxis = .horizontal, side: SplitSide = .trailing) {
        if splitTabID != nil {
            closeSplit()
        } else {
            // iPhone can't show two pages side by side — always stack.
            splitAxis = UIDevice.current.userInterfaceIdiom == .phone ? .vertical : axis
            splitSide = side
            duplicateActiveTabToSplit()
        }
    }

    /// Changes the orientation of an open split in place.
    func setSplitAxis(_ axis: SplitAxis) {
        guard splitAxis != axis else { return }
        splitAxis = axis
    }

    /// Persists the active view's exact scroll position into its tab BEFORE
    /// a split is created — the panes rebuild during the layout change, and
    /// without this both restore to the top of the page (owner-reported).
    private func captureActivePosition() {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              let live = activeController?.liveNavEntry
        else { return }
        tabs[index].apply(live)
        livePosition = live
    }

    /// iPhone: closing the PRIMARY (top) pane, or dragging the divider all
    /// the way up — the split (bottom) tab becomes the sole primary view.
    func promoteSplitToPrimary() {
        guard let target = splitTabID else { return }
        closeSplit()
        activate(target)
    }

    func duplicateActiveTabToSplit() {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        captureActivePosition()
        var copy = tabs[index]
        copy.id = UUID()
        tabs.insert(copy, at: index + 1)
        openInSplit(tabID: copy.id)
    }

    /// Shows an existing tab in the split pane. The active tab keeps the
    /// primary pane; splitting the active tab itself first activates a
    /// neighbor (a pane can't show the primary's tab). `axis`/`side` place
    /// the split pane (left/right/top/bottom).
    func openInSplit(tabID: UUID, axis: SplitAxis? = nil, side: SplitSide? = nil) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        captureActivePosition()
        if let axis { splitAxis = axis }
        if let side { splitSide = side }
        if tabID == activeTabID {
            guard let other = tabs.first(where: { $0.id != tabID }) else { return }
            activate(other.id)
        }
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        splitTabID = tabID
        splitURL = resolveURL(for: tab)
        repin()
        refreshBreadcrumb(forTabWithID: tabID)
    }

    /// Opens a new tab on `url` (default: the active document) at `entry`,
    /// directly into the split pane (sidebar section drag / long-press).
    func openEntryInSplit(
        _ entry: NavEntry, url: URL? = nil, axis: SplitAxis? = nil, side: SplitSide? = nil
    ) {
        guard let url = url ?? activeURL else { return }
        let id = openTab(url: url, at: entry, activate: false)
        openInSplit(tabID: id, axis: axis, side: side)
    }

    /// Closes the pane; the tab stays in the strip (macOS semantics).
    func closeSplit() {
        guard splitTabID != nil else { return }
        splitTabID = nil
        splitURL = nil
        splitController = nil
        repin()
    }

    // MARK: - Outline, sections, breadcrumbs

    /// Outline snapshot of the active document, cached per document object.
    @ObservationIgnored
    private var outlineCache: (
        document: ObjectIdentifier, nodes: [OutlineNode],
        stops: [OutlineNode.SectionStop]
    )?

    var outlineNodes: [OutlineNode] {
        outline()?.nodes ?? []
    }

    private func outline() -> (nodes: [OutlineNode], stops: [OutlineNode.SectionStop])? {
        guard let document = activeDocument else { return nil }
        let key = ObjectIdentifier(document)
        if let outlineCache, outlineCache.document == key {
            return (outlineCache.nodes, outlineCache.stops)
        }
        let nodes = OutlineNode.tree(from: document)
        let stops = OutlineNode.sectionStops(in: nodes)
        outlineCache = (key, nodes, stops)
        return (nodes, stops)
    }

    /// The active tab's best-known position: live scroll position when the
    /// view has reported one, else the persisted tab state.
    var currentPosition: NavEntry? {
        livePosition ?? activeTab?.currentNavEntry
    }

    /// The section containing the current position (sidebar follow
    /// highlight + breadcrumb). Binary search over cached stops.
    var currentSectionStop: OutlineNode.SectionStop? {
        guard let stops = outline()?.stops, let position = currentPosition
        else { return nil }
        return OutlineNode.currentStop(in: stops, at: position)
    }

    var canGoToPreviousSection: Bool {
        guard let outline = outline(), let position = currentPosition else { return false }
        return OutlineNode.sectionEntry(in: outline.nodes, before: position) != nil
    }

    var canGoToNextSection: Bool {
        guard let outline = outline(), let position = currentPosition else { return false }
        return OutlineNode.sectionEntry(in: outline.nodes, after: position) != nil
    }

    /// Section skips are history events (⌘[ returns), like macOS.
    func goToPreviousSection() {
        guard let outline = outline(), let position = currentPosition,
              let target = OutlineNode.sectionEntry(in: outline.nodes, before: position)
        else { return }
        jump(to: target)
    }

    func goToNextSection() {
        guard let outline = outline(), let position = currentPosition,
              let target = OutlineNode.sectionEntry(in: outline.nodes, after: position)
        else { return }
        jump(to: target)
    }

    /// History-pushing navigation — outline taps, section skips, the page
    /// field, search hits. Pushes the position being LEFT, then jumps.
    func jump(to entry: NavEntry) {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let current = activeController?.liveNavEntry ?? tabs[index].currentNavEntry
        tabs[index].history.push(current)
        tabs[index].apply(entry)
        activeController?.execute(entry)
    }

    /// Find-result navigation (sidebar Find mode): history push + jump to
    /// the match, then highlight the selection in the live view.
    func jumpToFindResult(_ selection: PDFSelection) {
        guard let document = activeDocument,
              let page = selection.pages.first
        else { return }
        let bounds = selection.bounds(for: page)
        jump(to: NavEntry(
            pageIndex: document.index(for: page),
            point: CGPoint(x: bounds.minX, y: bounds.maxY)
        ))
        activeController?.highlight(selection)
    }

    /// Crash-safe page tracking (PDFViewPageChanged → `view.currentPage`,
    /// the page most on screen — the status-bar number). Never a history
    /// event. Distinct from `notePosition`: `currentDestination` anchors to
    /// the visible TOP and reads a page ahead at boundaries (macOS keeps
    /// the same split).
    func noteCurrentPage(tabID: UUID, pageIndex: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].pageIndex = pageIndex
    }

    /// Live scroll-anchor feed (scroll ticks): drives the breadcrumb, the
    /// sidebar follow highlight, and section stepping.
    func notePosition(tabID: UUID, entry: NavEntry) {
        guard tabID == activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        livePosition = entry
        let crumb = currentSectionStop?.path.joined(separator: " › ") ?? ""
        if !crumb.isEmpty, tabs[index].breadcrumb != crumb {
            tabs[index].breadcrumb = crumb
        }
    }

    // MARK: - Bookmarks (overlay DB via BookResolver, like macOS)

    private(set) var activeBookmarks: [UserBookmarkRecord] = []
    @ObservationIgnored private var activeBookID: Int64?

    /// Resolves the active file to its overlay-DB book row and loads its
    /// bookmarks. Called on tab activation; hashing reads only the file
    /// head, so this is cheap even for huge books.
    func refreshBookmarks() {
        activeBookmarks = []
        activeBookID = nil
        guard let activeURL, let store = AppStores.library,
              let id = BookResolver.resolveBookID(forFileAt: activeURL, store: store)
        else { return }
        activeBookID = id
        activeBookmarks = (try? store.bookmarks(forBook: id)) ?? []
    }

    func addBookmarkAtCurrentPosition() {
        guard let store = AppStores.library, let activeBookID,
              let page = currentPosition?.pageIndex
        else { return }
        _ = try? store.addBookmark(bookID: activeBookID, page: page)
        activeBookmarks = (try? store.bookmarks(forBook: activeBookID)) ?? []
    }

    func deleteBookmark(_ id: Int64) {
        guard let store = AppStores.library, let activeBookID else { return }
        try? store.softDeleteBookmark(id: id)
        activeBookmarks = (try? store.bookmarks(forBook: activeBookID)) ?? []
    }

    // MARK: - Navigation & history (single source of truth: ReaderCore)

    /// How a link (or sidebar section) opens.
    enum LinkOpenMode {
        /// In place: history push + jump (plain tap).
        case here
        /// Background tab adjacent to the source (⌘-tap / long-press menu).
        case newTab
        /// Into the trailing split pane (iPad).
        case split
    }

    /// Handles an activated internal link from either pane. Plain taps
    /// push `current` (the position being left) onto THAT tab's history and
    /// jump in place; links into another PDF open a new tab at the
    /// destination, browser-style.
    func linkActivated(
        tabID: UUID, target: LinkTarget, current: NavEntry,
        mode: LinkOpenMode = .here
    ) {
        let sourceIndex = tabs.firstIndex { $0.id == tabID }
        let targetURL = target.remoteFileURL ?? url(forTabAt: sourceIndex)
        switch mode {
        case .newTab:
            guard let targetURL else { return }
            openTab(
                url: targetURL, at: target.entry,
                insertAt: sourceIndex.map { $0 + 1 }, activate: false
            )
        case .split:
            guard let targetURL else { return }
            openEntryInSplit(target.entry, url: targetURL)
        case .here:
            if let remote = target.remoteFileURL {
                openTab(url: remote, at: target.entry)
                return
            }
            guard let index = sourceIndex else { return }
            tabs[index].history.push(current)
            tabs[index].apply(target.entry)
            controller(for: tabID)?.execute(target.entry)
        }
    }

    private func url(forTabAt index: Int?) -> URL? {
        guard let index, tabs.indices.contains(index) else { return nil }
        return resolveURL(for: tabs[index])
    }

    /// The live view showing `tabID`, if it is on screen in either pane.
    private func controller(for tabID: UUID) -> (any ActivePDFNavigating)? {
        if tabID == activeTabID { return activeController }
        if tabID == splitTabID { return splitController }
        return nil
    }

    var canGoBack: Bool { activeTab?.history.canGoBack ?? false }
    var canGoForward: Bool { activeTab?.history.canGoForward ?? false }

    func goBack() {
        traverseHistory { history, current in history.goBack(from: current) }
    }

    func goForward() {
        traverseHistory { history, current in history.goForward(from: current) }
    }

    /// Multi-step traversal (history menus): the intermediate entries pass
    /// through the stack exactly as if stepped one at a time.
    func goBack(steps: Int) {
        for _ in 0..<steps { goBack() }
    }

    func goForward(steps: Int) {
        for _ in 0..<steps { goForward() }
    }

    /// Human label for a history entry (top-bar history menus): its
    /// section, falling back to the page number.
    func label(for entry: NavEntry) -> String {
        if let stops = outline()?.stops,
           let stop = OutlineNode.currentStop(in: stops, at: entry),
           let deepest = stop.path.last {
            return "\(deepest) — p.\(entry.pageIndex + 1)"
        }
        return "p.\(entry.pageIndex + 1)"
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

    // MARK: - Tab management (context menu / drag)

    /// Drag-reorder within the strip.
    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    /// Strip drag-reorder: moves `id` to `index` (a gap position counted in
    /// original tab order), correcting for the removal shift.
    func moveTab(id: UUID, toIndex index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let target = index > from ? index - 1 : index
        tabs.insert(tab, at: min(max(target, 0), tabs.count))
    }

    /// Drop-based reorder: places `tabID` immediately before `targetID`.
    func move(tabID: UUID, before targetID: UUID) {
        guard tabID != targetID,
              let from = tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        let tab = tabs.remove(at: from)
        // Recompute the target index AFTER the removal so the insertion
        // lands right before the target regardless of drag direction.
        let insertAt = tabs.firstIndex(where: { $0.id == targetID }) ?? tabs.count
        tabs.insert(tab, at: insertAt)
    }

    /// Duplicates a tab (position, zoom, and history travel) adjacent to
    /// the original, and activates the copy — macOS Duplicate Tab.
    func duplicate(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var copy = tabs[index]
        copy.id = UUID()
        tabs.insert(copy, at: index + 1)
        activate(copy.id)
    }

    func closeOthers(keeping id: UUID) {
        for tab in tabs where tab.id != id && tab.id != splitTabID {
            close(tab.id)
        }
        activate(id)
    }

    func canCloseTabs(leftOf id: UUID) -> Bool {
        (tabs.firstIndex { $0.id == id } ?? 0) > 0
    }

    func canCloseTabs(rightOf id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index < tabs.count - 1
    }

    /// Strip-order bulk closes. The split pane's tab is spared, like
    /// Close Other Tabs.
    func closeTabs(leftOf id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for tab in tabs.prefix(index) where tab.id != splitTabID {
            close(tab.id)
        }
    }

    func closeTabs(rightOf id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for tab in tabs.suffix(from: index + 1) where tab.id != splitTabID {
            close(tab.id)
        }
    }

    // MARK: - Position capture (from the live PDFView)

    /// Precise position captured from the PDFView as it is torn down
    /// (tab switch or close).
    func capture(tabID: UUID, entry: NavEntry, autoScales: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].apply(entry)
        tabs[index].autoScales = autoScales
        persistReadingState(for: tabs[index])
    }

    // MARK: - Reading state (per-book resume position, overlay DB)

    static let deviceName = UIDevice.current.model

    /// Records a tab's page as the book's resume position — so opening the
    /// same book later (from the library, Files, or a link) lands where the
    /// reader last was, on this device or another (synced later).
    private func persistReadingState(for tab: TabState) {
        guard let store = AppStores.library,
              let url = resolveURL(for: tab),
              let bookID = BookResolver.resolveBookID(forFileAt: url, store: store)
        else { return }
        try? store.setReadingState(
            bookID: bookID, page: tab.pageIndex, device: Self.deviceName)
    }

    // MARK: - Session persistence

    /// Debounced autosave: any change to the session shape (tabs, active tab,
    /// split layout, or a tab's stored position) reschedules a write ~1s
    /// later. This is what makes an in-progress session survive an abrupt
    /// kill — the scenePhase `.background` flush only fires on a clean
    /// transition, which a SIGKILL (Xcode Stop, a jetsam kill, a crash) skips
    /// entirely, leaving only the last cleanly-backgrounded snapshot on disk.
    @ObservationIgnored private var autosaver: AutosaveObserver!

    func save() {
        autosaver?.cancel()
        if let activeTab { persistReadingState(for: activeTab) }
        if let splitTab { persistReadingState(for: splitTab) }
        let window = WindowState(
            id: windowID, frame: nil, tabs: tabs, activeTabID: activeTabID,
            splitTabID: splitTabID,
            splitSide: splitTabID != nil ? splitSide : nil,
            splitAxis: splitTabID != nil ? splitAxis : nil
        )
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
        splitAxis = window.splitAxis ?? .horizontal
        splitSide = window.splitSide ?? .trailing
        if let restoredSplit = window.splitTabID, restoredSplit != activeTabID {
            openInSplit(tabID: restoredSplit)
        }
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
