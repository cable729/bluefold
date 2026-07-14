#if os(macOS)
import AppKit
import Foundation
import Observation
import PDFKit
import ReaderCore
import ReaderPersistence
import SearchIndexKit

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
    /// The live view's current auto-scale ("fit") state — read when a
    /// replacement view (theme rebuild) restores zoom from the outgoing one.
    var liveAutoScales: Bool { get }
    /// The tab this controller drives — a rebuild only restores from the
    /// outgoing controller when it's the SAME tab (theme switch), never a
    /// different one (tab switch).
    var controlledTabID: UUID { get }
    /// Position of the current text selection (page + top-left of its
    /// bounds), nil without one — "Copy Link to Selection".
    var selectionNavEntry: NavEntry? { get }
    func execute(_ entry: NavEntry)
    /// Applies find highlights; pass an empty array to clear them.
    func showFindResults(_ matches: [PDFSelection], current: PDFSelection?)
    func apply(displayModeRaw: Int)
    func fitWidth()
    func fitHeight()
    /// TRIM-1..7 — crop every page to its printed content box (a real crop,
    /// orthogonal to zoom) or revert; recomputes the current mode's plan from
    /// the cropped/original sizes, preserving scroll.
    func setTrim(_ on: Bool)
    /// Turn one "step" back/forward without a history push (status-bar
    /// arrows, arrow keys, palette commands) — the view decides what a step
    /// is for its display mode (e.g. a spread in two-up).
    func goToPreviousPage()
    func goToNextPage()
}

/// View-control hooks are optional for test fakes.
public extension ActivePDFControlling {
    var liveAutoScales: Bool { false }
    /// Test fakes don't drive a real tab; a fresh id never matches a real
    /// tab, so they simply opt out of the live-restore path.
    var controlledTabID: UUID { UUID() }
    var selectionNavEntry: NavEntry? { nil }
    func apply(displayModeRaw: Int) {}
    func fitWidth() {}
    func fitHeight() {}
    func setTrim(_ on: Bool) {}
    func goToPreviousPage() {}
    func goToNextPage() {}
}

/// Which pane of a (possibly split) reader window has focus. Ephemeral view
/// state — not persisted; restores default to the primary pane.
public enum ReaderPane: Sendable, Hashable {
    case primary
    case split
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

    /// Fired when a tab is CLOSED (not detached to another window), with its
    /// strip index — the session coordinator records it for ⌘⇧T reopen.
    @ObservationIgnored
    public var onTabClosed: ((TabState, Int) -> Void)?

    /// The primary pane's live view; registered on creation, dropped on
    /// teardown.
    @ObservationIgnored
    public weak var primaryController: ActivePDFControlling?
    /// The split pane's live view, while the window is split.
    @ObservationIgnored
    public weak var splitController: ActivePDFControlling?

    /// The FOCUSED pane's live view — every "act on what I'm reading"
    /// operation (history, section skip, bookmarks, copy link, palettes)
    /// routes through this. The setter keeps old call sites and test fakes
    /// working: it registers the primary pane's controller.
    public var activeController: ActivePDFControlling? {
        get { focusedPane == .split ? (splitController ?? primaryController) : primaryController }
        set { primaryController = newValue }
    }

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
            let live = Set(state.tabs.map(\.id))
            // Files written before per-pane strips carry only splitTabID:
            // the pane's strip held exactly that one tab.
            let members = state.splitTabIDs ?? state.splitTabID.map { [$0] } ?? []
            splitTabIDs = members.filter { live.contains($0) }
            splitTabID = state.splitTabID.flatMap { id in
                splitTabIDs.contains(id) ? id : splitTabIDs.first
            } ?? splitTabIDs.first
            if splitTabIDs.isEmpty { splitTabID = nil }
            // The primary pane must own at least one tab; a snapshot where
            // every tab sat in the split pane collapses back to one strip.
            if splitTabIDs.count == state.tabs.count {
                splitTabIDs = []
                splitTabID = nil
            }
            let primaryIDs = live.subtracting(splitTabIDs)
            activeTabID = state.activeTabID.flatMap {
                primaryIDs.contains($0) ? $0 : nil
            } ?? state.tabs.first { primaryIDs.contains($0.id) }?.id
            // Files written before sided splits carry no side: trailing
            // (right) is what those files meant.
            splitSide = state.splitSide ?? .trailing
            // Files written before vertical splits carry no axis: horizontal
            // (side-by-side) is the only layout those files could mean.
            splitAxis = state.splitAxis ?? .horizontal
            pendingFrame = state.frame
            windowFrame = state.frame
            refreshPins()
        }
    }

    /// This window's state for the session snapshot.
    public var stateSnapshot: WindowState {
        WindowState(
            id: windowID, frame: windowFrame, tabs: tabs,
            activeTabID: activeTabID, splitTabID: splitTabID,
            splitSide: splitTabID == nil ? nil : splitSide,
            splitAxis: splitTabID == nil ? nil : splitAxis,
            splitTabIDs: splitTabIDs.isEmpty ? nil : splitTabIDs
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

    /// Which pane the user is working in. Clicking a pane focuses it; the
    /// sidebar, status bar, history, and every command follow this.
    public private(set) var focusedPane: ReaderPane = .primary

    /// The tab shown in the PRIMARY pane (what `activeTabID` stores; the
    /// name predates split view and persists in session.json).
    public var primaryTab: TabState? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    /// The FOCUSED pane's tab — "the tab you're reading". Everything that
    /// acts on the current document (sidebar, status bar, commands,
    /// bookmarks, history, palettes) reads this, so focus switches carry
    /// the whole UI with them.
    public var activeTab: TabState? {
        focusedPane == .split ? (splitTab ?? primaryTab) : primaryTab
    }

    /// Observable identity of the focused tab (sidebar find + UI resets
    /// watch this instead of `activeTabID`, which only names the primary).
    public var focusedTabID: UUID? { activeTab?.id }

    /// Moves focus to a pane (no-op when the pane isn't on screen).
    public func focusPane(_ pane: ReaderPane) {
        let resolved: ReaderPane = (pane == .split && splitTabID == nil) ? .primary : pane
        guard focusedPane != resolved else { return }
        focusedPane = resolved
        currentSectionNodeID = nil  // stale for the new pane's document
        refreshBookmarks()
    }

    /// Focus routed by tab identity — panes report interaction with the
    /// tab they show.
    public func focusPane(containingTab id: UUID) {
        focusPane(id == splitTabID ? .split : .primary)
    }

    // MARK: - Split view

    /// ACTIVE tab of the secondary pane; nil = not split.
    public private(set) var splitTabID: UUID?

    /// Every tab living in the split pane's own strip, in that strip's
    /// order. Empty = not split. Each pane carries its own tab bar; a tab
    /// is a member of exactly one pane.
    public private(set) var splitTabIDs: [UUID] = []

    /// Side of the primary pane the split pane sits on. Only meaningful
    /// while `splitTabID` is non-nil; kept across closeSplit so a reopened
    /// split lands where the last one was.
    public private(set) var splitSide: SplitSide = .trailing

    /// Axis the split divides along: `.horizontal` = side-by-side (respects
    /// `splitSide`), `.vertical` = stacked top/bottom (primary on top, split
    /// below; `splitSide` is ignored). Only meaningful while `splitTabID` is
    /// non-nil; kept across closeSplit so a reopened split keeps orientation.
    public private(set) var splitAxis: SplitAxis = .horizontal

    public var splitTab: TabState? {
        guard let splitTabID else { return nil }
        return tabs.first { $0.id == splitTabID }
    }

    /// The primary pane's strip: every tab not living in the split pane,
    /// in `tabs` order.
    public var primaryTabs: [TabState] {
        guard !splitTabIDs.isEmpty else { return tabs }
        let members = Set(splitTabIDs)
        return tabs.filter { !members.contains($0.id) }
    }

    /// The split pane's strip, in its own order.
    public var splitTabs: [TabState] {
        splitTabIDs.compactMap { id in tabs.first { $0.id == id } }
    }

    /// The strip of one pane.
    public func tabs(in pane: ReaderPane) -> [TabState] {
        pane == .split ? splitTabs : primaryTabs
    }

    /// Which pane's strip a tab lives in.
    public func pane(ofTab id: UUID) -> ReaderPane {
        splitTabIDs.contains(id) ? .split : .primary
    }

    /// Moves a tab into the secondary pane's strip (on `side` of the
    /// primary), activates it there, and focuses the pane. Moving the
    /// primary pane's active tab first moves that pane's activation to
    /// another of its tabs — the primary strip must never end up empty
    /// (two live views over one TabState would fight over its position).
    public func openInSplit(
        tabID: UUID, side: SplitSide = .trailing, axis: SplitAxis = .horizontal
    ) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if !splitTabIDs.contains(tabID) {
            if tabID == activeTabID {
                if let other = primaryTabs.first(where: { $0.id != tabID }) {
                    activeTabID = other.id
                } else {
                    return // only primary tab: nothing to split against
                }
            }
            splitTabIDs.append(tabID)
        }
        splitTabID = tabID
        splitSide = side
        splitAxis = axis
        focusedPane = .split
        refreshPins()
        refreshBookmarks()
        onMutation?()
    }

    /// ⌘\ with no split open: duplicates the active tab (same book; position
    /// and history are copied but independent from here on) into the split
    /// pane on `side`. The original stays active in the primary pane — this
    /// works even in a single-tab window, unlike `openInSplit`, because the
    /// duplicate provides its own partner.
    @discardableResult
    public func duplicateActiveTabIntoSplit(
        side: SplitSide = .trailing, axis: SplitAxis = .horizontal
    ) -> UUID? {
        guard
            let activeTabID,
            let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return nil }
        var copy = tabs[index]
        copy.id = UUID()
        tabs.insert(copy, at: index + 1)
        splitTabIDs.append(copy.id)
        splitTabID = copy.id
        splitSide = side
        splitAxis = axis
        focusedPane = .split
        refreshPins()
        refreshBreadcrumb(tabID: copy.id)
        onMutation?()
        return copy.id
    }

    /// Ends the split: the pane's tabs return to the primary strip (their
    /// relative `tabs` order decides where), nothing closes.
    public func closeSplit() {
        guard splitTabID != nil || !splitTabIDs.isEmpty else { return }
        splitTabIDs = []
        splitTabID = nil
        focusedPane = .primary
        refreshPins()
        refreshBookmarks()
        onMutation?()
    }

    /// Moves an open split pane to the other side of the primary.
    public func moveSplitToOtherSide() {
        guard splitTabID != nil else { return }
        splitSide = splitSide == .trailing ? .leading : .trailing
        onMutation?()
    }

    /// Re-orients an open split between side-by-side (`.horizontal`) and
    /// stacked top/bottom (`.vertical`). No-op when nothing is split.
    public func setSplitAxis(_ axis: SplitAxis) {
        guard splitTabID != nil, splitAxis != axis else { return }
        splitAxis = axis
        onMutation?()
    }

    /// Closes one PANE of a split — every tab stays open; the two strips
    /// merge into one (round 15: closing the primary promotes the split
    /// pane's active tab to primary).
    public func closePane(_ pane: ReaderPane) {
        guard let splitID = splitTabID else { return }
        switch pane {
        case .split:
            closeSplit()
        case .primary:
            activeTabID = splitID
            splitTabIDs = []
            splitTabID = nil
            focusedPane = .primary
            currentSectionNodeID = nil
            refreshPins()
            refreshBookmarks()
            onMutation?()
        }
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
            // A tab opened from a split-pane sibling (⌘-clicked reference)
            // belongs in that pane's strip, right after its source.
            if let memberIndex = splitTabIDs.firstIndex(of: siblingID) {
                splitTabIDs.insert(tab.id, at: memberIndex + 1)
            }
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

    /// Closes the other tabs of the kept tab's OWN strip — each pane has
    /// its own tab bar, and "Close Other Tabs" reads as that bar's verb.
    public func closeOtherTabs(keeping id: UUID) {
        for tab in tabs(in: pane(ofTab: id)) where tab.id != id {
            closeTab(id: tab.id)
        }
    }

    /// Closes every tab BEFORE this one in its own strip's order — same
    /// per-strip scope as `closeOtherTabs`.
    public func closeTabsToLeft(of id: UUID) {
        let strip = tabs(in: pane(ofTab: id))
        guard let index = strip.firstIndex(where: { $0.id == id }) else { return }
        closeTabs(ids: strip[..<index].map(\.id))
    }

    /// Closes every tab AFTER this one in its own strip's order.
    public func closeTabsToRight(of id: UUID) {
        let strip = tabs(in: pane(ofTab: id))
        guard let index = strip.firstIndex(where: { $0.id == id }) else { return }
        closeTabs(ids: strip[(index + 1)...].map(\.id))
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
        if splitTabIDs.contains(id) {
            // The tab lives in the split pane's strip: activate it THERE
            // and focus the pane — it must never also become the primary
            // (one TabState rendered by two live views fights over its
            // position — round-14 owner bug).
            if splitTabID != id {
                splitTabID = id
                currentSectionNodeID = nil
            }
            focusedPane = .split
        } else {
            activeTabID = id
            focusedPane = .primary
            currentSectionNodeID = nil  // recomputed on the next scroll tick
        }
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
    /// Numbers address the FOCUSED pane's strip — each pane has its own.
    public func selectTab(number: Int) {
        let strip = tabs(in: focusedPane)
        guard !strip.isEmpty else { return }
        let index = number >= 9 ? strip.count - 1 : number - 1
        guard strip.indices.contains(index) else { return }
        selectTab(id: strip[index].id)
    }

    private func cycleTab(by offset: Int) {
        guard !tabs.isEmpty else { return }
        guard
            // Cycle from the FOCUSED tab: starting from the primary while
            // the split pane is focused would re-select the split tab
            // forever (selectTab on it only moves focus).
            let fromID = activeTab?.id,
            let index = tabs.firstIndex(where: { $0.id == fromID })
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
        // On-screen tabs: fold the live scroll position in first, so the
        // reopen stack gets the exact spot (the view's teardown capture
        // arrives after the tab has left `tabs` — too late).
        if let entry = paneController(forTab: id)?.liveNavEntry {
            tabs[index].apply(entry)
        }
        let closed = tabs.remove(at: index)
        removeFromSplitStrip(id)

        if activeTabID == id {
            promotePrimarySuccessor(closing: index)
        }
        refreshPins()

        // Drop the document if no other tab uses that file.
        if !tabs.contains(where: { $0.pathHint == closed.pathHint }) {
            provider.evict(path: closed.pathHint)
        }
        onTabClosed?(closed, index)
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

    /// TRIM — flip the active tab's trim-margins state (persisted) and drive the
    /// live view to crop / uncrop. UI wiring (a toolbar button) can call this or
    /// `setTrimMargins(_:)`.
    public func toggleTrimMargins() {
        guard let activeTab else { return }
        setTrimMargins(!activeTab.trimMargins)
    }

    public func setTrimMargins(_ on: Bool) {
        guard let activeTab else { return }
        updateTab(id: activeTab.id) { $0.trimMargins = on }
        activeController?.setTrim(on)
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

    /// Enablement reads the tab's STORED position, not the live view:
    /// `tabs` is observable, so SwiftUI re-evaluates when it changes.
    /// Reading liveNavEntry here left buttons grayed with no invalidation
    /// to ungray them (round 12.5).
    public var canGoToPreviousSection: Bool {
        guard let activeTab else { return false }
        return OutlineNode.sectionEntry(in: activeOutline, before: activeTab.currentNavEntry) != nil
    }

    public var canGoToNextSection: Bool {
        guard let activeTab else { return false }
        return OutlineNode.sectionEntry(in: activeOutline, after: activeTab.currentNavEntry) != nil
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
    /// One tree per resident document, shared by everything that consumes
    /// outline nodes — the sidebar AND the section-stop index. Node ids are
    /// minted per build (`OutlineNode.id = UUID()`), so two separately built
    /// trees of the same document NEVER share ids; when the stops carried
    /// ids from their own private tree, the sidebar's follow-mode highlight
    /// and auto-expansion compared against ids it had never rendered and
    /// silently matched nothing (round 22 bug). Keyed per document because
    /// a split shows two documents at once.
    @ObservationIgnored private var outlineTreeCache: [ObjectIdentifier: [OutlineNode]] = [:]
    /// Page index → outline ancestor path, memoized per document (search can
    /// produce hundreds of hits; walking the outline per row is wasteful).
    @ObservationIgnored private var breadcrumbCache: [Int: [String]] = [:]

    /// The shared tree for `document`, built on first use.
    private func outlineTree(for document: PDFDocument) -> [OutlineNode] {
        let key = ObjectIdentifier(document)
        if let cached = outlineTreeCache[key] { return cached }
        if outlineTreeCache.count >= 4 {  // stale-document backstop
            outlineTreeCache.removeAll()
            // Stops embed node ids of the trees just dropped; rebuilding a
            // tree mints fresh ids, so stale stops would match nothing.
            sectionStopsCache.removeAll()
        }
        let tree = OutlineNode.tree(from: document)
        outlineTreeCache[key] = tree
        return tree
    }

    /// The outline tree, built once per live document (bodies re-evaluate
    /// constantly; walking PDFOutline each time is wasteful).
    func outline(for document: PDFDocument) -> [OutlineNode] {
        let key = ObjectIdentifier(document)
        if key != outlineCacheKey {
            outlineCacheKey = key
            breadcrumbCache = [:]
        }
        return outlineTree(for: document)
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

    // MARK: - Live position (breadcrumbs while scrolling — round 15)

    /// Ordered section stops per document (derived from the shared
    /// `outlineTreeCache` trees): a split can show TWO documents, and
    /// alternating scroll ticks must not rebuild anything.
    @ObservationIgnored
    private var sectionStopsCache: [ObjectIdentifier: [OutlineNode.SectionStop]] = [:]

    func sectionStops(for document: PDFDocument) -> [OutlineNode.SectionStop] {
        let key = ObjectIdentifier(document)
        if let cached = sectionStopsCache[key] { return cached }
        if sectionStopsCache.count >= 4 {  // stale-document backstop
            sectionStopsCache.removeAll()
        }
        // Built from the SHARED tree, never a private one: the stop node
        // ids drive the sidebar's follow-mode highlight, which compares
        // them against the ids of `outline(for:)` (see outlineTreeCache).
        let stops = OutlineNode.sectionStops(in: outlineTree(for: document))
        sectionStopsCache[key] = stops
        return stops
    }

    /// The section the FOCUSED pane's reading position is inside, point-
    /// precise — drives the sidebar's follow-mode highlight while scrolling.
    /// Nil falls back to the page-granular lookup (e.g. right after a tab
    /// switch, before the first scroll tick).
    public private(set) var currentSectionNodeID: UUID?

    /// Streamed by a pane's scroll observer (throttled): recomputes the
    /// tab's strip breadcrumb and the sidebar highlight from the exact
    /// scroll anchor instead of waiting for a page flip. A binary search
    /// over precomputed stops — cheap enough for every tick.
    public func noteLivePosition(tabID: UUID, entry: NavEntry) {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            let document = provider.loadedDocument(for: url(for: tabs[index]))
        else { return }
        let stop = OutlineNode.currentStop(in: sectionStops(for: document), at: entry)
        if tabID == activeTab?.id, currentSectionNodeID != stop?.nodeID {
            currentSectionNodeID = stop?.nodeID
        }
        let crumb = stop?.path.joined(separator: " › ") ?? ""
        if !crumb.isEmpty, tabs[index].breadcrumb != crumb {
            tabs[index].breadcrumb = crumb
            onMutation?()  // persists with the session (debounced)
        }
    }

    // MARK: - Tab strip breadcrumbs

    /// Refreshes the breadcrumb of every tab showing the document at `url`
    /// — called when a view attaches (the document just became resident),
    /// so background tabs of the same book get labels without activation.
    public func refreshBreadcrumbs(forDocumentAt url: URL) {
        let path = DocumentProvider.canonicalPath(for: url)
        for tab in tabs where tab.pathHint == path {
            refreshBreadcrumb(tabID: tab.id)
        }
    }

    /// Recomputes a tab's breadcrumb if its document is resident; keeps the
    /// last known value otherwise. Never loads a document (LRU stays
    /// intact). The crumb lives ON TabState and persists with the session —
    /// recomputing at launch would need the document, so relaunches showed
    /// "p.N" for every background tab (round 13.5).
    func refreshBreadcrumb(tabID: UUID) {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            let document = provider.loadedDocument(for: url(for: tabs[index]))
        else { return }
        let tab = tabs[index]
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
        if tabs[index].breadcrumb != crumb {
            tabs[index].breadcrumb = crumb
            onMutation?()  // persists with the session
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

    // MARK: - Deep links (Copy Link…)

    /// Copies a bluefold:// link to the active tab's current position (the
    /// live scroll anchor when available — same precision as ⇤ ⇥).
    public func copyDeepLinkToCurrentPosition() {
        guard let activeTab else { return }
        copyDeepLink(entry: activeController?.liveNavEntry ?? activeTab.currentNavEntry)
    }

    /// Copies a bluefold:// link to the current text selection.
    public func copyDeepLinkToSelection() {
        guard let entry = activeController?.selectionNavEntry else { return }
        copyDeepLink(entry: entry)
    }

    private func copyDeepLink(entry: NavEntry?) {
        guard let activeTab else { return }
        let fileURL = url(for: activeTab)
        // Registering the book (BookResolver backfills the content hash
        // onto Calibre rows) is what makes the link resolvable later —
        // hash lookup is how links survive file moves.
        _ = bookRowID(for: activeTab)
        guard let hash = try? ContentHash.compute(for: fileURL) else {
            NSSound.beep()
            return
        }
        let link = DeepLink(contentHash: hash, pageIndex: entry?.pageIndex, point: entry?.point)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.url().absoluteString, forType: .string)
    }

    // MARK: - Margin anchors

    /// Per-document anchor index (outline + named dests + text detection),
    /// keyed like the section-stops cache: a split can show two documents.
    @ObservationIgnored private var anchorIndexCache: [ObjectIdentifier: AnchorIndex] = [:]

    func anchorIndex(for document: PDFDocument) -> AnchorIndex {
        let key = ObjectIdentifier(document)
        if let cached = anchorIndexCache[key] { return cached }
        if anchorIndexCache.count >= 4 {  // stale-document backstop
            anchorIndexCache.removeAll()
        }
        let index = AnchorIndex(document: document, sectionStops: sectionStops(for: document))
        anchorIndexCache[key] = index
        return index
    }

    /// Transient confirmation shown after a clipboard write.
    public struct Toast: Equatable, Sendable {
        public let id: UUID
        public let text: String
    }

    public private(set) var toast: Toast?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    /// Margin-glyph click: copies a deep link to the anchor (⌥ = a markdown
    /// link ready for notes) and pushes the anchor onto the tab's history —
    /// a lightweight "mark this spot"; ⌘[ returns here after wandering off.
    func anchorClicked(_ anchor: Anchor, tabID: UUID? = nil, asMarkdown: Bool = false) {
        let id = tabID ?? activeTabID
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let fileURL = url(for: tab)
        // Registering the book backfills the content hash so the link is
        // resolvable later (same as Copy Link to Here).
        _ = bookRowID(for: tab)
        guard let hash = try? ContentHash.compute(for: fileURL) else {
            NSSound.beep()
            return
        }
        // Both forms: the named destination wins when it resolves, the
        // page+point form is the universal fallback.
        let link = DeepLink(
            contentHash: hash,
            destination: anchor.destName,
            pageIndex: anchor.pageIndex,
            point: anchor.point
        )
        let urlString = link.url().absoluteString
        let text = asMarkdown ? "[\(anchor.label)](\(urlString))" : urlString
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        updateTab(id: tab.id) { $0.history.push(anchor.entry) }
        showToast("Link copied — \(anchor.label)")
    }

    func showToast(_ text: String) {
        let message = Toast(id: UUID(), text: text)
        toast = message
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let self, self.toast?.id == message.id else { return }
            self.toast = nil
        }
    }

    public func updateTab(id: UUID, _ mutate: (inout TabState) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[index])
        onMutation?()
    }

    /// Closes the FOCUSED tab (⌘W in the split pane closes that pane's tab);
    /// returns false when there is none (caller may close the window
    /// instead, browser-style).
    @discardableResult
    public func closeActiveTab() -> Bool {
        guard let focused = activeTab else { return false }
        closeTab(id: focused.id)
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
            let executor = controller ?? paneController(forTab: source.id)
            executor?.execute(entry)
            // The page-change notification won't refresh the strip label:
            // its guard sees the pageIndex we just applied and bails. The
            // breadcrumb stayed stale until the user scrolled (round 9).
            refreshBreadcrumb(tabID: source.id)
        }
    }

    /// Opens a link's destination in a split pane along `axis` — the macOS twin
    /// of the iOS peek's Split buttons. A new background tab at `entry` provides
    /// the split partner, so this works even in a single-tab window.
    public func linkActivatedSplit(
        sourceTabID: UUID? = nil,
        target entry: NavEntry,
        remoteFileURL: URL?,
        axis: SplitAxis
    ) {
        let tabID = sourceTabID ?? activeTabID
        guard let source = tabs.first(where: { $0.id == tabID }) else { return }
        let fileURL = remoteFileURL ?? url(for: source)
        let id = openTab(fileURL: fileURL, activate: false, at: entry, after: source.id)
        openInSplit(tabID: id, axis: axis)
    }

    /// The live view showing a tab, if that tab is on screen in a pane.
    private func paneController(forTab id: UUID) -> ActivePDFControlling? {
        if id == splitTabID { return splitController }
        if id == activeTabID { return primaryController }
        return nil
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
        if tabID == activeTabID || tabID == splitTabID {
            persistReadingState(for: tabs[index])
        }
        refreshBreadcrumb(tabID: tabID)
        onMutation?()
    }

    // MARK: - Tab reordering & cross-window transfer

    /// Moves a tab to a new position within ITS pane's strip (drag
    /// reorder). `toIndex` is a slot in that strip's visible order.
    public func moveTab(id: UUID, toIndex: Int) {
        if let from = splitTabIDs.firstIndex(of: id) {
            let to = max(0, min(toIndex, splitTabIDs.count - 1))
            guard from != to else { return }
            splitTabIDs.remove(at: from)
            splitTabIDs.insert(id, at: to)
            onMutation?()
            return
        }
        // Primary strip: slots index the VISIBLE (non-split) sequence;
        // split members keep their positions in `tabs`.
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: primaryInsertionIndex(forSlot: toIndex))
        onMutation?()
    }

    /// Global `tabs` index where a tab dropped at primary-strip slot
    /// `slot` belongs (computed AFTER any removal).
    private func primaryInsertionIndex(forSlot slot: Int) -> Int {
        let members = Set(splitTabIDs)
        let visible = tabs.enumerated().filter { !members.contains($0.element.id) }
        let clamped = max(0, min(slot, visible.count))
        return clamped < visible.count
            ? visible[clamped].offset
            : (visible.last.map { $0.offset + 1 } ?? tabs.count)
    }

    /// Moves a tab into the OTHER pane's strip at `index` (drag between
    /// the two strips), activating it there. No-op when it would empty the
    /// primary strip (a pane must always have a tab to show).
    public func moveTab(id: UUID, toPane pane: ReaderPane, at index: Int? = nil) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        switch pane {
        case .split:
            guard !splitTabIDs.isEmpty else { return }  // no split open
            if splitTabIDs.contains(id) { return }      // reorders use moveTab(toIndex:)
            guard primaryTabs.count > 1 else { return }
            if activeTabID == id {
                activeTabID = primaryTabs.first { $0.id != id }?.id
            }
            let slot = max(0, min(index ?? splitTabIDs.count, splitTabIDs.count))
            splitTabIDs.insert(id, at: slot)
            splitTabID = id
            focusedPane = .split
        case .primary:
            guard splitTabIDs.contains(id) else { return }
            removeFromSplitStrip(id)
            if let index {
                moveTab(id: id, toIndex: index)
            }
            activeTabID = id
            focusedPane = .primary
        }
        currentSectionNodeID = nil
        refreshPins()
        refreshBookmarks()
        onMutation?()
    }

    /// Detaches a tab, preserving its full state. The shared document stays
    /// in the provider (the receiving window uses the same one).
    func detachTab(id: UUID) -> TabState? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        removeFromSplitStrip(id)
        if activeTabID == id {
            promotePrimarySuccessor(closing: index)
        }
        refreshPins()
        refreshBookmarks()
        onMutation?()
        return tab
    }

    /// Removes a tab (already gone from `tabs`, or about to move panes)
    /// from the split pane's strip, promoting that strip's own successor
    /// when its active tab left. An emptied split pane ends the split.
    private func removeFromSplitStrip(_ id: UUID) {
        guard let memberIndex = splitTabIDs.firstIndex(of: id) else { return }
        splitTabIDs.remove(at: memberIndex)
        if splitTabID == id {
            // Same slot, else the strip's last tab — browser behavior.
            splitTabID = splitTabIDs.indices.contains(memberIndex)
                ? splitTabIDs[memberIndex] : splitTabIDs.last
        }
        if splitTabIDs.isEmpty {
            splitTabID = nil
            if focusedPane == .split { focusedPane = .primary }
        }
    }

    /// Picks the primary pane's next tab after its current one left the
    /// strip: the tab that took the vacated slot, else the last tab —
    /// skipping the split pane's tabs (they are on screen in the other
    /// strip; showing one in both panes would double-render one TabState).
    /// When only split-pane tabs remain, that pane becomes the window:
    /// its strip merges into the primary, unsplit.
    private func promotePrimarySuccessor(closing index: Int) {
        let members = Set(splitTabIDs)
        let slotTab = tabs.indices.contains(index) ? tabs[index] : tabs.last
        if let slotTab, !members.contains(slotTab.id) {
            activeTabID = slotTab.id
        } else if let fallback = tabs.last(where: { !members.contains($0.id) }) {
            activeTabID = fallback.id
        } else if let splitID = splitTabID {
            activeTabID = splitID
            splitTabIDs = []
            splitTabID = nil
            focusedPane = .primary
        } else {
            activeTabID = nil
        }
    }

    /// Adopts a tab detached from another window, keeping its position,
    /// zoom, and history intact. `index` is the insertion slot in the
    /// TARGET PANE's strip (append when nil or out of range); `pane`
    /// picks which strip receives it (split falls back to primary when
    /// the window isn't split).
    func adoptTab(_ tab: TabState, at index: Int? = nil, pane: ReaderPane = .primary) {
        if pane == .split, !splitTabIDs.isEmpty {
            tabs.append(tab)
            let slot = max(0, min(index ?? splitTabIDs.count, splitTabIDs.count))
            splitTabIDs.insert(tab.id, at: slot)
        } else if let index, (0...primaryTabs.count).contains(index) {
            tabs.insert(tab, at: primaryInsertionIndex(forSlot: index))
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
        if let primaryTab {
            pinned.insert(primaryTab.pathHint)
        }
        if let splitTab {
            pinned.insert(splitTab.pathHint)
        }
        provider.pinnedPaths = pinned
        provider.evictIfNeeded()
    }
}
#endif
