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

    @Test func reorderWithinWindow() {
        let coordinator = makeCoordinator()
        let model = coordinator.model(for: UUID())
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))

        model.moveTab(id: c, toIndex: 0)
        #expect(model.tabs.map(\.id) == [c, a, b])

        // Out-of-range indices clamp instead of crashing.
        model.moveTab(id: c, toIndex: 99)
        #expect(model.tabs.map(\.id) == [a, b, c])
        model.moveTab(id: a, toIndex: -3)
        #expect(model.tabs.map(\.id) == [a, b, c])

        // Reordering never changes the active tab.
        model.selectTab(id: b)
        model.moveTab(id: b, toIndex: 2)
        #expect(model.activeTabID == b)
    }

    @Test func moveInsertsAtRequestedIndex() {
        let coordinator = makeCoordinator()
        let sourceID = UUID()
        let targetID = UUID()
        let source = coordinator.model(for: sourceID)
        let target = coordinator.model(for: targetID)
        let moving = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/m.pdf"))
        let first = target.openTab(fileURL: URL(fileURLWithPath: "/tmp/1.pdf"))
        let second = target.openTab(fileURL: URL(fileURLWithPath: "/tmp/2.pdf"))

        coordinator.moveTab(moving, from: sourceID, to: targetID, at: 1)
        #expect(target.tabs.map(\.id) == [first, moving, second])
        #expect(target.activeTabID == moving)
    }

    @Test func detachToNewWindowStagesRestorableState() throws {
        let coordinator = makeCoordinator()
        let sourceID = UUID()
        let source = coordinator.model(for: sourceID)
        source.setWindowFrame(CGRect(x: 100, y: 100, width: 800, height: 600))
        let staying = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/stay.pdf"))
        let leaving = source.openTab(fileURL: URL(fileURLWithPath: "/tmp/leave.pdf"))
        source.updateTab(id: leaving) { $0.pageIndex = 42 }

        let newID = try #require(coordinator.detachTabToNewWindow(
            leaving, from: sourceID, at: CGPoint(x: 500, y: 900)
        ))

        #expect(source.tabs.map(\.id) == [staying])

        // The staged window survives a snapshot round-trip even before any
        // scene claims it (quit right after the drag must not lose the tab).
        let snapshot = coordinator.snapshot()
        let staged = try #require(snapshot.windows.first { $0.id == newID })
        #expect(staged.tabs.map(\.id) == [leaving])
        #expect(staged.tabs.first?.pageIndex == 42)
        #expect(staged.frame?.size == CGSize(width: 800, height: 600))

        // Claiming the model adopts the staged state.
        let adopted = coordinator.model(for: newID)
        #expect(adopted.tabs.map(\.id) == [leaving])
        #expect(adopted.activeTabID == leaving)
    }

    @Test func detachUnknownTabReturnsNil() {
        let coordinator = makeCoordinator()
        let windowID = UUID()
        _ = coordinator.model(for: windowID)
        #expect(coordinator.detachTabToNewWindow(UUID(), from: windowID) == nil)
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
