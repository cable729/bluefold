#if os(macOS)
import Foundation
import Observation
import PDFKit
import ReaderCore

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

    /// The active tab's live view; registered on creation, dropped on teardown.
    @ObservationIgnored
    public weak var activeController: ActivePDFControlling?

    public init(provider: DocumentProvider = DocumentProvider()) {
        self.provider = provider
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
        return tab.id
    }

    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        refreshPins()
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
    }

    public func updateTab(id: UUID, _ mutate: (inout TabState) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[index])
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

    public func goBack() {
        traverseHistory { history, current in history.goBack(from: current) }
    }

    public func goForward() {
        traverseHistory { history, current in history.goForward(from: current) }
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
