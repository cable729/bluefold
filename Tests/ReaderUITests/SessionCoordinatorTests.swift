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

    // MARK: - Round-5 session loss (last-window close must not wipe the session)

    @Test func closingLastWindowKeepsSessionRecoverable() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let coordinator = SessionCoordinator(sessionFileURL: file)
        let window = coordinator.claimLaunchWindowID()
        coordinator.model(for: window).openTab(fileURL: URL(fileURLWithPath: "/tmp/axler.pdf"))
        coordinator.windowClosed(window)  // last window: app keeps running
        coordinator.saveNow()

        let reloaded = SessionCoordinator(sessionFileURL: file)
        let restored = reloaded.model(for: reloaded.claimLaunchWindowID())
        #expect(restored.tabs.first?.pathHint.hasSuffix("axler.pdf") == true)
    }

    @Test func dockReopenAfterLastWindowCloseRestoresTabs() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let coordinator = SessionCoordinator(sessionFileURL: file)
        let window = coordinator.claimLaunchWindowID()
        coordinator.model(for: window).openTab(fileURL: URL(fileURLWithPath: "/tmp/axler.pdf"))
        coordinator.windowClosed(window)

        // Dock click reopens the default scene in the SAME process; the
        // launch ID must resolve to the stashed window, not a spent one.
        let reopened = coordinator.model(for: coordinator.claimLaunchWindowID())
        #expect(reopened.tabs.first?.pathHint.hasSuffix("axler.pdf") == true)
    }

    @Test func corruptSessionFileFallsBackToBackup() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let first = SessionCoordinator(sessionFileURL: file)
        first.model(for: first.claimLaunchWindowID())
            .openTab(fileURL: URL(fileURLWithPath: "/tmp/axler.pdf"))
        first.saveNow()

        // A successful load rotates the backup…
        _ = SessionCoordinator(sessionFileURL: file)
        // …so when the main file is later mangled, the session still loads.
        try Data("garbage".utf8).write(to: file)
        let recovered = SessionCoordinator(sessionFileURL: file)
        let model = recovered.model(for: recovered.claimLaunchWindowID())
        #expect(model.tabs.first?.pathHint.hasSuffix("axler.pdf") == true)
    }

    @Test func deliberatelyEmptySessionDoesNotResurrectBackup() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let first = SessionCoordinator(sessionFileURL: file)
        let window = first.claimLaunchWindowID()
        let model = first.model(for: window)
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/axler.pdf"))
        first.saveNow()
        _ = SessionCoordinator(sessionFileURL: file)  // rotates the backup

        // The user closes every tab, then quits: a decodable-but-empty
        // session is DELIBERATE — the backup must stay buried.
        model.closeTab(id: model.tabs[0].id)
        first.saveNow()

        let reloaded = SessionCoordinator(sessionFileURL: file)
        let restored = reloaded.model(for: reloaded.claimLaunchWindowID())
        #expect(restored.tabs.isEmpty)
    }

    @Test func emptyWindowsAreNotRestored() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        // One real window + two stray empty ones (accidental default
        // scenes) — only the real one may come back (round-7 bug: empties
        // accumulated forever).
        let coordinator = SessionCoordinator(sessionFileURL: file)
        coordinator.model(for: coordinator.claimLaunchWindowID())
            .openTab(fileURL: URL(fileURLWithPath: "/tmp/axler.pdf"))
        _ = coordinator.model(for: UUID())
        _ = coordinator.model(for: UUID())
        coordinator.saveNow()

        let reloaded = SessionCoordinator(sessionFileURL: file)
        let launch = reloaded.model(for: reloaded.claimLaunchWindowID())
        #expect(launch.tabs.count == 1)
        #expect(reloaded.takeRemainingRestoreIDs().isEmpty)
    }

    @Test func stagedDetachSurvivesQuitWithoutPresentation() throws {
        let file = try makeTempSessionFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let coordinator = SessionCoordinator(sessionFileURL: file)
        let source = coordinator.claimLaunchWindowID()
        let model = coordinator.model(for: source)
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))

        // Tear-off staged a window that the scene never presented (the
        // round-4 wedge), then the app quit.
        let detached = coordinator.detachTabToNewWindow(
            model.tabs[1].id, from: source, at: CGPoint(x: 100, y: 100)
        )
        #expect(detached != nil)
        coordinator.prepareForTermination()

        let reloaded = SessionCoordinator(sessionFileURL: file)
        _ = reloaded.claimLaunchWindowID()
        let allIDs = [reloaded.claimLaunchWindowID()] + reloaded.takeRemainingRestoreIDs()
        let totalTabs = allIDs.map { reloaded.model(for: $0).tabs.count }.reduce(0, +)
        #expect(totalTabs == 2)  // no tab may be lost by an unpresented stage
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
