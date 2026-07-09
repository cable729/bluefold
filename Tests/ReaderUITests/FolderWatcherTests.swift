#if os(macOS)
import Foundation
import Testing

@testable import ReaderUI

/// Collects watcher callbacks across threads.
private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ new: [String]) {
        lock.withLock { paths.append(contentsOf: new) }
    }

    var all: [String] {
        lock.withLock { paths }
    }
}

@Suite struct FolderWatcherTests {

    @Test func refusesEmptyPathList() {
        #expect(FolderWatcher(paths: [], queue: .global()) { _ in } == nil)
    }

    @Test func reportsFileCreationInWatchedFolder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let collector = PathCollector()
        let queue = DispatchQueue(label: "folder-watcher-tests")
        let watcher = try #require(
            FolderWatcher(paths: [dir.path], latency: 0.1, queue: queue) { paths in
                collector.append(paths)
            }
        )
        defer { watcher.stop() }

        // Give the fresh stream a beat before generating the event.
        try await Task.sleep(for: .milliseconds(300))
        try Data("not really a pdf".utf8).write(to: dir.appendingPathComponent("note.pdf"))

        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline {
            if collector.all.contains(where: { $0.hasSuffix("note.pdf") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(collector.all.contains { $0.hasSuffix("note.pdf") })
    }

    @Test func stopIsIdempotentAndSilences() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let collector = PathCollector()
        let queue = DispatchQueue(label: "folder-watcher-tests-stop")
        let watcher = try #require(
            FolderWatcher(paths: [dir.path], latency: 0.05, queue: queue) { paths in
                collector.append(paths)
            }
        )
        watcher.stop()
        watcher.stop()  // second stop must be a no-op, not a crash

        try Data("x".utf8).write(to: dir.appendingPathComponent("after-stop.pdf"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(!collector.all.contains { $0.hasSuffix("after-stop.pdf") })
    }
}
#endif
