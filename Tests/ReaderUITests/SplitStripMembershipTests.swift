#if os(macOS)
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

/// Per-pane tab strips (design-system redesign): the split pane owns an
/// ordered strip of tabs (`splitTabIDs`), the primary strip is everything
/// else, and tabs move between the two.
@Suite("Split strip membership")
@MainActor
struct SplitStripMembershipTests {
    private func makeModel() -> ReaderWindowModel {
        ReaderWindowModel(store: nil)
    }

    /// primary [a, b], split [c] (focused, active c)
    private func makeSplitModel() -> (ReaderWindowModel, a: UUID, b: UUID, c: UUID) {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))
        model.openInSplit(tabID: c)
        return (model, a: a, b: b, c: c)
    }

    @Test func panesPartitionTheTabs() {
        let (model, a, b, c) = makeSplitModel()
        #expect(model.primaryTabs.map(\.id) == [a, b])
        #expect(model.splitTabs.map(\.id) == [c])
        #expect(model.pane(ofTab: a) == .primary)
        #expect(model.pane(ofTab: c) == .split)
    }

    @Test func splittingASecondTabGrowsTheSplitStrip() {
        let (model, a, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)
        #expect(model.splitTabs.map(\.id) == [c, b])
        #expect(model.splitTabID == b, "the newly split tab is the pane's active one")
        #expect(model.primaryTabs.map(\.id) == [a])
    }

    @Test func selectingASplitStripTabActivatesItInThePane() {
        let (model, a, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)
        model.selectTab(id: c)
        #expect(model.splitTabID == c)
        #expect(model.focusedPane == .split)
        #expect(model.activeTabID == a, "the primary pane is untouched")
        _ = b
    }

    @Test func closingTheSplitActiveTabPromotesWithinTheSplitStrip() {
        let (model, _, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)  // split strip [c, b], active b
        model.closeTab(id: b)
        #expect(model.splitTabID == c, "successor comes from the SPLIT strip")
        #expect(model.splitTabs.map(\.id) == [c])
    }

    @Test func closeSplitReturnsMembersToThePrimaryStrip() {
        let (model, a, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)
        model.closeSplit()
        #expect(model.splitTabs.isEmpty)
        #expect(model.primaryTabs.map(\.id) == [a, b, c], "nothing closes; `tabs` order decides slots")
    }

    @Test func closingThePrimaryPaneMergesTheStrips() {
        let (model, a, b, c) = makeSplitModel()
        model.closePane(.primary)
        #expect(model.splitTabID == nil)
        #expect(model.activeTabID == c)
        #expect(model.primaryTabs.map(\.id) == [a, b, c])
    }

    @Test func membershipSurvivesSnapshotRoundTrip() throws {
        let (model, _, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)  // split strip [c, b]

        let data = try SessionCodec.encode(SessionSnapshot(windows: [model.stateSnapshot]))
        let decoded = try SessionCodec.decode(data)
        let restored = ReaderWindowModel(restoring: decoded.windows[0], store: nil)
        #expect(restored.splitTabs.map(\.id) == [c, b])
        #expect(restored.splitTabID == b)
    }

    @Test func legacySnapshotWithOnlySplitTabIDRestoresAOneTabStrip() throws {
        // Files written before per-pane strips carry splitTabID but no
        // splitTabIDs: the pane's strip held exactly that tab.
        let (model, _, _, c) = makeSplitModel()
        var state = model.stateSnapshot
        state.splitTabIDs = nil
        let restored = ReaderWindowModel(restoring: state, store: nil)
        #expect(restored.splitTabs.map(\.id) == [c])
        #expect(restored.splitTabID == c)
    }

    @Test func moveTabToSplitPaneJoinsItsStripAndActivates() {
        let (model, a, b, c) = makeSplitModel()
        model.moveTab(id: a, toPane: .split, at: 0)
        #expect(model.splitTabs.map(\.id) == [a, c])
        #expect(model.splitTabID == a)
        #expect(model.primaryTabs.map(\.id) == [b])
        #expect(model.activeTabID == b, "primary activation moved off the departed tab")
    }

    @Test func moveTabToPrimaryLeavesTheSplitStrip() {
        let (model, a, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)  // split [c, b]
        model.moveTab(id: c, toPane: .primary, at: 0)
        #expect(model.primaryTabs.map(\.id) == [c, a])
        #expect(model.splitTabs.map(\.id) == [b])
        #expect(model.activeTabID == c)
        #expect(model.focusedPane == .primary)
    }

    @Test func movingTheLastSplitTabToPrimaryEndsTheSplit() {
        let (model, _, _, c) = makeSplitModel()
        model.moveTab(id: c, toPane: .primary)
        #expect(model.splitTabID == nil)
        #expect(model.splitTabs.isEmpty)
        #expect(model.activeTabID == c)
    }

    @Test func movingTheOnlyPrimaryTabToSplitIsRefused() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.openInSplit(tabID: b)
        model.moveTab(id: a, toPane: .split)
        #expect(model.primaryTabs.map(\.id) == [a], "the primary strip must never empty")
        #expect(model.splitTabs.map(\.id) == [b])
    }

    @Test func primaryReorderSkipsSplitMembers() {
        let (model, a, b, c) = makeSplitModel()
        // Primary strip shows [a, b]; move a to slot 1 → [b, a]. The split
        // member c keeps its place in `tabs`.
        model.moveTab(id: a, toIndex: 1)
        #expect(model.primaryTabs.map(\.id) == [b, a])
        #expect(model.splitTabs.map(\.id) == [c])
    }

    @Test func splitStripReordersIndependently() {
        let (model, _, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)  // split [c, b]
        model.moveTab(id: b, toIndex: 0)
        #expect(model.splitTabs.map(\.id) == [b, c])
        #expect(model.primaryTabs.count == 1)
    }

    @Test func tabOpenedFromASplitSiblingJoinsTheSplitStrip() {
        let (model, _, _, c) = makeSplitModel()
        let opened = model.openTab(
            fileURL: URL(fileURLWithPath: "/tmp/d.pdf"), activate: false, after: c
        )
        #expect(model.pane(ofTab: opened) == .split)
        #expect(model.splitTabs.map(\.id) == [c, opened])
    }

    @Test func adoptTabIntoSplitPaneJoinsItsStrip() {
        let (model, _, _, c) = makeSplitModel()
        let foreign = TabState(pathHint: "/tmp/foreign.pdf")
        model.adoptTab(foreign, at: 0, pane: .split)
        #expect(model.splitTabs.map(\.id) == [foreign.id, c])
        #expect(model.splitTabID == foreign.id)
        #expect(model.focusedPane == .split)
    }

    @Test func adoptTabIntoSplitOfUnsplitWindowFallsBackToPrimary() {
        let model = makeModel()
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let foreign = TabState(pathHint: "/tmp/foreign.pdf")
        model.adoptTab(foreign, pane: .split)
        #expect(model.pane(ofTab: foreign.id) == .primary)
        #expect(model.activeTabID == foreign.id)
    }

    @Test func tabNumbersAddressTheFocusedPaneStrip() {
        let (model, a, b, c) = makeSplitModel()
        model.openInSplit(tabID: b)  // split [c, b] focused
        model.selectTab(number: 1)
        #expect(model.activeTab?.id == c, "⌘1 in the split pane = its strip's first tab")
        model.focusPane(.primary)
        model.selectTab(number: 1)
        #expect(model.activeTab?.id == a)
        _ = a
    }

    @Test func snapshotWhereEveryTabIsSplitCollapsesOnRestore() throws {
        // Defensive: a hand-edited/corrupt file must not restore a window
        // whose primary strip is empty.
        let (model, a, b, c) = makeSplitModel()
        var state = model.stateSnapshot
        state.splitTabIDs = [a, b, c]
        let restored = ReaderWindowModel(restoring: state, store: nil)
        #expect(restored.splitTabID == nil)
        #expect(restored.primaryTabs.count == 3)
        #expect(restored.activeTabID != nil)
    }
}
#endif
