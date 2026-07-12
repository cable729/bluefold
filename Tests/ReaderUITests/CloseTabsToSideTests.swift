#if os(macOS)
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

/// "Close Tabs to the Left/Right" (tab context menu + palette): closes one
/// side of a tab within its OWN strip, through the normal per-tab close
/// path (reopen stack, split membership, pins all stay correct).
@Suite("Close tabs to one side")
@MainActor
struct CloseTabsToSideTests {
    private func makeModel() -> ReaderWindowModel {
        ReaderWindowModel(store: nil)
    }

    /// One flat strip [a, b, c, d], active d (last opened).
    private func makeFourTabModel() -> (ReaderWindowModel, a: UUID, b: UUID, c: UUID, d: UUID) {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))
        let d = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/d.pdf"))
        return (model, a: a, b: b, c: c, d: d)
    }

    @Test func closeToLeftClosesOnlyThatSide() {
        let (model, a, b, c, d) = makeFourTabModel()
        var closed: [UUID] = []
        model.onTabClosed = { tab, _ in closed.append(tab.id) }

        model.closeTabsToLeft(of: c)

        #expect(model.tabs.map(\.id) == [c, d])
        #expect(closed == [a, b], "each tab goes through the close path, strip order")
    }

    @Test func closeToRightClosesOnlyThatSide() {
        let (model, a, b, c, d) = makeFourTabModel()
        var closed: [UUID] = []
        model.onTabClosed = { tab, _ in closed.append(tab.id) }

        model.closeTabsToRight(of: b)

        #expect(model.tabs.map(\.id) == [a, b])
        #expect(closed == [c, d])
    }

    @Test func closeToLeftKeepsActiveTabActive() {
        let (model, _, _, c, _) = makeFourTabModel()
        model.selectTab(id: c)

        model.closeTabsToLeft(of: c)

        #expect(model.activeTabID == c, "the kept tab was active; it stays active")
    }

    @Test func closeToRightKeepsActiveTabActive() {
        let (model, _, b, _, _) = makeFourTabModel()
        model.selectTab(id: b)

        model.closeTabsToRight(of: b)

        #expect(model.activeTabID == b)
    }

    @Test func activeTabInsideClosedRangeActivatesTheKeptTab() {
        let (model, a, _, c, _) = makeFourTabModel()
        model.selectTab(id: c)  // active tab sits in the doomed range

        model.closeTabsToRight(of: a)

        #expect(model.tabs.map(\.id) == [a])
        #expect(model.activeTabID == a)
    }

    @Test func emptySideIsANoOp() {
        let (model, a, _, _, d) = makeFourTabModel()
        var closedCount = 0
        model.onTabClosed = { _, _ in closedCount += 1 }

        model.closeTabsToLeft(of: a)   // nothing left of the first tab
        model.closeTabsToRight(of: d)  // nothing right of the last tab
        model.closeTabsToLeft(of: UUID())  // unknown tab: no-op

        #expect(model.tabs.count == 4)
        #expect(closedCount == 0)
    }

    @Test func closingSidesIsScopedToTheTabsOwnStrip() {
        // primary [a, b], split [c] — "to the right of a" must not reach
        // into the split pane's strip.
        let (model, a, b, c, _) = makeFourTabModel()
        model.closeTab(id: model.tabs.last!.id)  // drop d: [a, b, c]
        model.openInSplit(tabID: c)

        model.closeTabsToRight(of: a)

        #expect(model.primaryTabs.map(\.id) == [a])
        #expect(model.splitTabs.map(\.id) == [c], "the split pane is untouched")
        #expect(model.splitTabID == c)
        _ = b
    }

    @Test func closeToLeftInsideTheSplitStripUsesThatStripsOrder() {
        // primary [a], split [c, b] (b active in the pane).
        let (model, a, b, c, _) = makeFourTabModel()
        model.closeTab(id: model.tabs.last!.id)  // drop d
        model.openInSplit(tabID: c)
        model.openInSplit(tabID: b)  // split strip [c, b]

        model.closeTabsToLeft(of: b)

        #expect(model.splitTabs.map(\.id) == [b])
        #expect(model.splitTabID == b)
        #expect(model.primaryTabs.map(\.id) == [a], "the primary strip is untouched")
    }

    @Test func closeToRightInsideTheSplitStripPromotesThePanesSuccessor() {
        // split strip [c, b], active b — closing b (to the right of c)
        // promotes c within the pane, split stays open.
        let (model, a, b, c, _) = makeFourTabModel()
        model.closeTab(id: model.tabs.last!.id)  // drop d
        model.openInSplit(tabID: c)
        model.openInSplit(tabID: b)

        model.closeTabsToRight(of: c)

        #expect(model.splitTabs.map(\.id) == [c])
        #expect(model.splitTabID == c)
        #expect(model.activeTabID == a)
        _ = b
    }
}
#endif
