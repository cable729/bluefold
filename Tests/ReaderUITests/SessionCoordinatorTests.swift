#if os(macOS)
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("SessionCoordinator")
@MainActor
struct SessionCoordinatorTests {
    private func makeTempSessionFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    @Test func sessionRoundTripsAcrossCoordinators() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        // First run: two windows, tabs, positions, a frame.
        let first = SessionCoordinator(sessionFileURL: file)
        let windowA = first.claimLaunchWindowID()
        let modelA = first.model(for: windowA)
        modelA.openTab(fileURL: URL(fileURLWithPath: "/tmp/axler.pdf"), at: NavEntry(pageIndex: 51))
        modelA.openTab(fileURL: URL(fileURLWithPath: "/tmp/hatcher.pdf"))
        modelA.setWindowFrame(CGRect(x: 40, y: 60, width: 1100, height: 850))

        let windowB = UUID()
        let modelB = first.model(for: windowB)
        modelB.openTab(fileURL: URL(fileURLWithPath: "/tmp/notes.pdf"))
        first.saveNow()

        // Second run restores everything in order.
        let second = SessionCoordinator(sessionFileURL: file)
        let launchID = second.claimLaunchWindowID()
        #expect(launchID == windowA)
        #expect(second.takeRemainingRestoreIDs() == [windowB])
        #expect(second.takeRemainingRestoreIDs().isEmpty)  // one-shot

        let restoredA = second.model(for: launchID)
        #expect(restoredA.tabs.count == 2)
        #expect(restoredA.tabs[0].pathHint.hasSuffix("axler.pdf"))
        #expect(restoredA.tabs[0].pageIndex == 51)
        #expect(restoredA.activeTabID == restoredA.tabs[1].id)
        #expect(restoredA.pendingFrame == CGRect(x: 40, y: 60, width: 1100, height: 850))

        let restoredB = second.model(for: windowB)
        #expect(restoredB.tabs.count == 1)
    }

    @Test func closedWindowLeavesSession() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let coordinator = SessionCoordinator(sessionFileURL: file)
        let a = UUID()
        let b = UUID()
        coordinator.model(for: a).openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        coordinator.model(for: b).openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))

        coordinator.windowClosed(a)
        coordinator.saveNow()

        let reloaded = SessionCoordinator(sessionFileURL: file)
        let snapshot = reloaded.snapshot()
        // Only window b survived the close; it is preserved even unclaimed.
        #expect(snapshot.windows.map(\.id) == [b])
        #expect(reloaded.claimLaunchWindowID() == b)
        #expect(reloaded.model(for: b).tabs.first?.pathHint.hasSuffix("b.pdf") == true)
    }

    @Test func terminationPreservesAllWindows() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let coordinator = SessionCoordinator(sessionFileURL: file)
        let a = UUID()
        let b = UUID()
        coordinator.model(for: a).openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        coordinator.model(for: b).openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))

        coordinator.prepareForTermination()
        // Windows now close as the app quits — this must not shrink the session.
        coordinator.windowClosed(a)
        coordinator.windowClosed(b)

        let reloaded = SessionCoordinator(sessionFileURL: file)
        _ = reloaded.claimLaunchWindowID()
        let remaining = reloaded.takeRemainingRestoreIDs()
        #expect(remaining.count == 1)
    }

    @Test func unclaimedRestoredWindowsSurviveSaves() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        // Save a two-window session.
        let first = SessionCoordinator(sessionFileURL: file)
        first.model(for: UUID()).openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        first.model(for: UUID()).openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        first.saveNow()

        // Second run: claim only the first window, then save.
        let second = SessionCoordinator(sessionFileURL: file)
        _ = second.model(for: second.claimLaunchWindowID())
        second.saveNow()

        // The unopened second window must still be in the file.
        let third = SessionCoordinator(sessionFileURL: file)
        _ = third.claimLaunchWindowID()
        #expect(third.takeRemainingRestoreIDs().count == 1)
    }

    @Test func modelsShareOneProvider() {
        let coordinator = SessionCoordinator(
            sessionFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("unused-\(UUID().uuidString).json")
        )
        let a = coordinator.model(for: UUID())
        let b = coordinator.model(for: UUID())
        #expect(a.provider === b.provider)
        #expect(a.provider === coordinator.provider)
    }
}
#endif
