#if os(macOS)
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("Split view model semantics")
@MainActor
struct SplitViewTests {
    private func makeModel() -> ReaderWindowModel {
        ReaderWindowModel(store: nil)
    }

    @Test func openInSplitShowsTabAndKeepsDistinctActiveTab() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))

        model.openInSplit(tabID: a)
        #expect(model.splitTabID == a)
        #expect(model.activeTabID == b)
    }

    @Test func splittingTheActiveTabMovesActivationAway() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.selectTab(id: b)

        model.openInSplit(tabID: b)
        #expect(model.splitTabID == b)
        #expect(model.activeTabID == a, "the two panes must never show the same tab")
    }

    @Test func cannotSplitTheOnlyTab() {
        let model = makeModel()
        let only = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.openInSplit(tabID: only)
        #expect(model.splitTabID == nil)
    }

    @Test func closingSplitTabEndsTheSplit() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.openInSplit(tabID: a)

        model.closeTab(id: a)
        #expect(model.splitTabID == nil)
    }

    @Test func splitPinsBothDocuments() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))

        model.openInSplit(tabID: a)
        #expect(model.provider.pinnedPaths == ["/tmp/a.pdf", "/tmp/b.pdf"])

        model.closeSplit()
        #expect(model.provider.pinnedPaths == ["/tmp/b.pdf"])
    }

    @Test func splitSurvivesSnapshotRoundTrip() throws {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.openInSplit(tabID: a)

        let data = try SessionCodec.encode(SessionSnapshot(windows: [model.stateSnapshot]))
        let decoded = try SessionCodec.decode(data)
        let restored = ReaderWindowModel(
            windowID: model.windowID,
            restoring: decoded.windows[0],
            store: nil
        )
        #expect(restored.splitTabID == a)
        #expect(restored.splitSide == .trailing)
    }

    @Test func splitSideSurvivesSnapshotRoundTrip() throws {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.openInSplit(tabID: a, side: .leading)

        let data = try SessionCodec.encode(SessionSnapshot(windows: [model.stateSnapshot]))
        let decoded = try SessionCodec.decode(data)
        let restored = ReaderWindowModel(
            windowID: model.windowID,
            restoring: decoded.windows[0],
            store: nil
        )
        #expect(restored.splitTabID == a)
        #expect(restored.splitSide == .leading)
    }

    @Test func schema1FilesWithoutSplitKeyStillDecode() throws {
        // A pre-split session file must keep decoding (splitTabID optional).
        let json = """
        {"schemaVersion":1,"windows":[{"id":"\(UUID().uuidString)","tabs":[],"activeTabID":null}]}
        """
        let decoded = try SessionCodec.decode(Data(json.utf8))
        #expect(decoded.windows[0].splitTabID == nil)
        #expect(decoded.windows[0].splitSide == nil)
    }

    @Test func filesWithSplitButNoSideDecodeAndDefaultToTrailing() throws {
        // Session files written between split view (round 3) and sided
        // splits carry splitTabID but no splitSide: they must keep decoding,
        // and restore as a RIGHT split (the only behavior they could mean).
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.openInSplit(tabID: a, side: .leading)

        var state = model.stateSnapshot
        state.splitSide = nil // as an older writer would have produced
        let data = try SessionCodec.encode(SessionSnapshot(windows: [state]))
        #expect(!String(decoding: data, as: UTF8.self).contains("splitSide"))

        let decoded = try SessionCodec.decode(data)
        let restored = ReaderWindowModel(
            windowID: model.windowID,
            restoring: decoded.windows[0],
            store: nil
        )
        #expect(restored.splitTabID == a)
        #expect(restored.splitSide == .trailing)
    }

    @Test func snapshotOmitsSideWhenNotSplit() {
        let model = makeModel()
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        #expect(model.stateSnapshot.splitSide == nil)
    }

    // MARK: - Split left/right + ⌘\ duplicate-into-split

    @Test func openInSplitOnTheOtherSideMovesTheSplit() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))

        model.openInSplit(tabID: a, side: .trailing)
        #expect(model.splitSide == .trailing)
        model.openInSplit(tabID: a, side: .leading)
        #expect(model.splitTabID == a)
        #expect(model.splitSide == .leading)
    }

    @Test func duplicateIntoSplitWorksEvenWithASingleTab() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))

        let copy = model.duplicateActiveTabIntoSplit(side: .leading)
        #expect(copy != nil)
        #expect(model.tabs.count == 2)
        #expect(model.splitTabID == copy)
        #expect(model.splitSide == .leading)
        #expect(model.activeTabID == a, "the original stays active in the primary pane")
        #expect(model.tabs.map(\.pathHint) == ["/tmp/a.pdf", "/tmp/a.pdf"])
        #expect(model.provider.pinnedPaths == ["/tmp/a.pdf"])
    }

    @Test func duplicateIntoSplitCopiesPositionButStaysIndependent() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.updateTab(id: a) { $0.pageIndex = 41 }

        let copy = model.duplicateActiveTabIntoSplit()
        #expect(model.splitTab?.pageIndex == 41)

        model.noteCurrentPage(tabID: a, pageIndex: 7)
        #expect(model.tabs.first { $0.id == copy }?.pageIndex == 41,
                "the split copy's position is independent of the original")
    }

    @Test func splitCommandsToggleThroughTheTable() {
        let model = makeModel()
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let context = CommandContext(model: model)
        let right = CommandRegistry.command(id: "view.splitRight")
        let left = CommandRegistry.command(id: "view.splitLeft")
        let close = CommandRegistry.command(id: "view.closeSplit")

        #expect(right?.chords.contains(KeyChord("\\", [.command])) == true)
        #expect(close?.isAvailable(context) == false)

        // ⌘\ with no split: duplicate the active tab into a RIGHT split.
        right?.run(context)
        #expect(model.splitTabID != nil)
        #expect(model.splitSide == .trailing)
        #expect(model.tabs.count == 2)
        #expect(right?.isOn?(context) == true)
        #expect(left?.isOn?(context) == false)
        #expect(close?.isAvailable(context) == true)

        // ⌘\ with a split open: close it (the tab itself stays).
        right?.run(context)
        #expect(model.splitTabID == nil)
        #expect(model.tabs.count == 2)

        // Split Left mirrors, and Close Split closes.
        left?.run(context)
        #expect(model.splitSide == .leading)
        #expect(left?.isOn?(context) == true)
        #expect(right?.isOn?(context) == false)
        close?.run(context)
        #expect(model.splitTabID == nil)
    }

    @Test func splitLeftChordClosesAnOpenRightSplitToo() {
        // Owner spec: with ANY split open the chord commands close it —
        // side changes go through the tab context menu.
        let model = makeModel()
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let context = CommandContext(model: model)

        CommandRegistry.command(id: "view.splitRight")?.run(context)
        #expect(model.splitSide == .trailing)
        CommandRegistry.command(id: "view.splitLeft")?.run(context)
        #expect(model.splitTabID == nil)
    }

    // MARK: - Cross-window move-then-split

    private func makeCoordinator() -> SessionCoordinator {
        SessionCoordinator(
            sessionFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("split-\(UUID().uuidString).json")
        )
    }

    @Test func moveTabIntoSplitTransfersThenSplits() {
        let coordinator = makeCoordinator()
        let source = coordinator.model(for: UUID())
        let target = coordinator.model(for: UUID())
        let moved = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/moved.pdf"))
        _ = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/stays.pdf"))
        let existing = target.openTab(fileURL: URL(fileURLWithPath: "/tmp/target.pdf"))

        coordinator.moveTabIntoSplit(
            moved, from: source.windowID, to: target.windowID, side: .leading
        )

        #expect(!source.tabs.contains { $0.id == moved })
        #expect(target.tabs.contains { $0.id == moved })
        #expect(target.splitTabID == moved)
        #expect(target.splitSide == .leading)
        #expect(target.activeTabID == existing, "the two panes never show the same tab")
        #expect(coordinator.provider.pinnedPaths.contains("/tmp/moved.pdf"))
        #expect(coordinator.provider.pinnedPaths.contains("/tmp/target.pdf"))
    }

    @Test func moveTabIntoSplitOnEmptyTargetFallsBackToPlainMove() {
        let coordinator = makeCoordinator()
        let source = coordinator.model(for: UUID())
        let target = coordinator.model(for: UUID()) // no tabs
        let moved = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/moved.pdf"))
        _ = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/stays.pdf"))

        coordinator.moveTabIntoSplit(
            moved, from: source.windowID, to: target.windowID, side: .trailing
        )

        #expect(target.tabs.map(\.id) == [moved])
        #expect(target.splitTabID == nil, "nothing to keep in the primary pane")
        #expect(target.activeTabID == moved)
    }

    @Test func closeManyClosesAllRequestedTabs() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))

        model.closeTabs(ids: [a, c])
        #expect(model.tabs.map(\.id) == [b])
        #expect(model.activeTabID == b)
    }

    @Test func openInNewWindowStagesAllFilesAsTabs() {
        let coordinator = SessionCoordinator(
            sessionFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("split-\(UUID().uuidString).json")
        )
        let urls = [
            URL(fileURLWithPath: "/tmp/one.pdf"),
            URL(fileURLWithPath: "/tmp/two.pdf"),
        ]
        let newID = coordinator.openInNewWindow(fileURLs: urls)

        // Staged state survives a snapshot before any scene claims it.
        let staged = coordinator.snapshot().windows.first { $0.id == newID }
        #expect(staged?.tabs.map(\.pathHint) == ["/tmp/one.pdf", "/tmp/two.pdf"])

        let model = coordinator.model(for: newID)
        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == model.tabs.first?.id)
    }
}
#endif
