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
    }

    @Test func schema1FilesWithoutSplitKeyStillDecode() throws {
        // A pre-split session file must keep decoding (splitTabID optional).
        let json = """
        {"schemaVersion":1,"windows":[{"id":"\(UUID().uuidString)","tabs":[],"activeTabID":null}]}
        """
        let decoded = try SessionCodec.decode(Data(json.utf8))
        #expect(decoded.windows[0].splitTabID == nil)
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
