#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Round-14 split semantics: the window has a FOCUSED pane; `activeTab`,
/// the controllers, and every "act on what I'm reading" surface follow it.
@Suite("Pane focus")
@MainActor
struct PaneFocusTests {
    @MainActor
    private final class FakeController: ActivePDFControlling {
        var liveNavEntry: NavEntry?
        var executed: [NavEntry] = []
        func execute(_ entry: NavEntry) { executed.append(entry) }
        func showFindResults(_ matches: [PDFSelection], current: PDFSelection?) {}
    }

    private func makeSplitModel() -> (ReaderWindowModel, primary: UUID, split: UUID) {
        let model = ReaderWindowModel(store: nil)
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.openInSplit(tabID: a)
        #expect(model.activeTabID == b)
        #expect(model.splitTabID == a)
        return (model, primary: b, split: a)
    }

    @Test func openingASplitFocusesIt() {
        let (model, _, split) = makeSplitModel()
        #expect(model.focusedPane == .split)
        #expect(model.activeTab?.id == split)
    }

    @Test func selectingTheSplitTabFocusesThePaneInsteadOfDualRendering() {
        let (model, primary, split) = makeSplitModel()
        model.focusPane(.primary)

        model.selectTab(id: split)
        // The primary pane must NOT adopt the split tab: one TabState shown
        // by two live views fights over its position (round-14 bug).
        #expect(model.activeTabID == primary)
        #expect(model.focusedPane == .split)
        #expect(model.activeTab?.id == split)
    }

    @Test func selectingAnotherTabReturnsFocusToPrimary() {
        let (model, primary, _) = makeSplitModel()
        #expect(model.focusedPane == .split)

        model.selectTab(id: primary)
        #expect(model.focusedPane == .primary)
        #expect(model.activeTab?.id == primary)
    }

    @Test func focusRoutesTheActiveController() {
        let (model, _, split) = makeSplitModel()
        let primaryController = FakeController()
        let splitController = FakeController()
        model.primaryController = primaryController
        model.splitController = splitController

        model.focusPane(.split)
        #expect(model.activeController === splitController)
        model.focusPane(.primary)
        #expect(model.activeController === primaryController)

        // Focused-pane routing carries navigation: a chrome jump while the
        // split is focused must move the split pane's view and history.
        model.focusPane(.split)
        model.jump(to: NavEntry(pageIndex: 7))
        #expect(splitController.executed.map(\.pageIndex) == [7])
        #expect(primaryController.executed.isEmpty)
        #expect(model.tabs.first { $0.id == split }?.history.canGoBack == true)
    }

    @Test func focusPaneByTabIdentity() {
        let (model, primary, split) = makeSplitModel()
        model.focusPane(containingTab: primary)
        #expect(model.focusedPane == .primary)
        model.focusPane(containingTab: split)
        #expect(model.focusedPane == .split)
    }

    @Test func closingTheSplitReturnsFocusToPrimary() {
        let (model, primary, _) = makeSplitModel()
        #expect(model.focusedPane == .split)
        model.closeSplit()
        #expect(model.focusedPane == .primary)
        #expect(model.activeTab?.id == primary)
    }

    @Test func closeActiveTabClosesTheFocusedSplitTab() {
        let (model, primary, split) = makeSplitModel()
        #expect(model.focusedPane == .split)

        // ⌘W with the split pane focused: "get rid of it" (round 14).
        #expect(model.closeActiveTab())
        #expect(model.splitTabID == nil)
        #expect(model.tabs.map(\.id) == [primary])
        #expect(model.focusedPane == .primary)
        _ = split
    }

    @Test func closingThePrimaryNeverPromotesTheSplitTabWhileOthersExist() {
        let model = ReaderWindowModel(store: nil)
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))
        model.openInSplit(tabID: c)
        model.selectTab(id: b)

        model.closeTab(id: b)
        // Successor picking skips the split tab (it is already on screen).
        #expect(model.activeTabID == a)
        #expect(model.splitTabID == c)
    }

    @Test func lastRemainingSplitTabCollapsesIntoThePrimaryPane() {
        let (model, primary, split) = makeSplitModel()
        model.closeTab(id: primary)
        // Only the split tab is left: it becomes the primary, unsplit.
        #expect(model.activeTabID == split)
        #expect(model.splitTabID == nil)
        #expect(model.focusedPane == .primary)
    }

    @Test func cyclingStartsFromTheFocusedTab() {
        let model = ReaderWindowModel(store: nil)
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))
        model.openInSplit(tabID: b)   // primary=c (activation moved), split=b focused
        #expect(model.activeTabID == c)

        // From focused b, next is c → primary pane, primary focus.
        model.selectNextTab()
        #expect(model.focusedPane == .primary)
        #expect(model.activeTab?.id == c)

        // From c, next wraps to a — not stuck re-focusing the split tab.
        model.selectNextTab()
        #expect(model.activeTab?.id == a)

        // And cycling INTO the split tab focuses its pane.
        model.selectNextTab()
        #expect(model.activeTab?.id == b)
        #expect(model.focusedPane == .split)
        #expect(model.activeTabID == a)
    }

    @Test func moveSplitToOtherSideFlipsTheSide() {
        let (model, _, _) = makeSplitModel()
        #expect(model.splitSide == .trailing)
        model.moveSplitToOtherSide()
        #expect(model.splitSide == .leading)
        model.moveSplitToOtherSide()
        #expect(model.splitSide == .trailing)
    }

    @Test func focusIsEphemeralNotPersisted() {
        let (model, _, _) = makeSplitModel()
        #expect(model.focusedPane == .split)
        let restored = ReaderWindowModel(restoring: model.stateSnapshot, store: nil)
        #expect(restored.focusedPane == .primary)
        #expect(restored.splitTabID == model.splitTabID)
    }

    @Test func eachPaneStripShowsOnlyItsOwnTabs() {
        // Per-pane tab bars: the split tab appears in the SPLIT strip only,
        // so it can never hide behind another strip's grouping.
        let (model, primary, split) = makeSplitModel()
        #expect(model.tabs(in: .primary).map(\.id) == [primary])
        #expect(model.tabs(in: .split).map(\.id) == [split])
        #expect(model.splitTabID == split, "the split strip's own active tab")
        #expect(model.activeTabID == primary, "the primary strip's own active tab")
    }
}
#endif
