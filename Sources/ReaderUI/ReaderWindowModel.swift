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
@Observable
@MainActor
public final class ReaderWindowModel {
    public private(set) var tabs: [TabState] = []
    public private(set) var activeTabID: UUID?
    public let provider: DocumentProvider

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

    /// Opens a new tab for the file. The same file may be open in any number
    /// of tabs; they share one live document.
    @discardableResult
    public func openTab(fileURL: URL, activate: Bool = true, at pageIndex: Int = 0) -> UUID {
        let tab = TabState(
            pathHint: DocumentProvider.canonicalPath(for: fileURL),
            pageIndex: pageIndex
        )
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
