#if os(macOS)
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("Cross-window tab moves")
@MainActor
struct TabMoveTests {
    private func makeCoordinator() -> SessionCoordinator {
        SessionCoordinator(
            sessionFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tabmove-\(UUID().uuidString).json")
        )
    }

    @Test func movePreservesStateAndActivates() {
        let coordinator = makeCoordinator()
        let sourceID = UUID()
        let targetID = UUID()
        let source = coordinator.model(for: sourceID)
        let target = coordinator.model(for: targetID)

        let keep = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/keep.pdf"))
        let moving = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/axler.pdf"))
        source.updateTab(id: moving) { tab in
            tab.pageIndex = 132
            tab.history.push(NavEntry(pageIndex: 5))
        }
        target.openTab(fileURL: URL(fileURLWithPath: "/tmp/other.pdf"))

        coordinator.moveTab(moving, from: sourceID, to: targetID)

        #expect(source.tabs.map(\.id) == [keep])
        #expect(source.activeTabID == keep)
        #expect(target.tabs.count == 2)
        let moved = target.tabs.last!
        #expect(moved.id == moving)
        #expect(moved.pageIndex == 132)
        #expect(moved.history.canGoBack)
        #expect(target.activeTabID == moving)
    }

    @Test func moveToSameWindowIsNoOp() {
        let coordinator = makeCoordinator()
        let windowID = UUID()
        let model = coordinator.model(for: windowID)
        let tab = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))

        coordinator.moveTab(tab, from: windowID, to: windowID)
        #expect(model.tabs.count == 1)
    }

    @Test func multiStepBackViaCount() {
        let coordinator = makeCoordinator()
        let model = coordinator.model(for: UUID())
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))

        final class Recorder: ActivePDFControlling {
            var liveNavEntry: NavEntry? = NavEntry(pageIndex: 40)
            var executed: [NavEntry] = []
            func execute(_ entry: NavEntry) {
                executed.append(entry)
                liveNavEntry = entry
            }
            func showFindResults(_ matches: [PDFKit.PDFSelection], current: PDFKit.PDFSelection?) {}
        }
        let recorder = Recorder()
        model.activeController = recorder

        // Build history: jumped 10 -> 20 -> 30 -> 40.
        for page in [10, 20, 30] {
            model.updateTab(id: model.activeTabID!) { $0.history.push(NavEntry(pageIndex: page)) }
        }
        #expect(model.backEntries.map(\.pageIndex) == [30, 20, 10])

        model.goBack(count: 3)
        #expect(recorder.executed.last?.pageIndex == 10)
        #expect(model.forwardEntries.count == 3)
    }
}

import PDFKit
#endif
