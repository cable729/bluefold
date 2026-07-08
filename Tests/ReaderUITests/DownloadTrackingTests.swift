import Foundation
import ReaderPersistence
import Testing

@testable import ReaderUI

/// The shared download-tracking seam both platforms' open paths use
/// (macOS `openItem`, the iOS library screen).
@Suite("Download tracking")
@MainActor
struct DownloadTrackingTests {
    private func makeItem(fileURL: URL) -> LibraryItem {
        LibraryItem(
            id: "1", source: .imported, title: "Local Book",
            authors: [], calibreTags: [], fileURL: fileURL, coverURL: nil
        )
    }

    @Test func ensureLocalTrackedIsAFastNoOpForLocalFiles() async throws {
        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store, indexStore: try .inMemory())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-\(UUID().uuidString).pdf")
        try Data("not a real pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try await model.ensureLocalTracked(makeItem(fileURL: url))
        #expect(model.downloading.isEmpty)
    }

    @Test func ensureLocalTrackedClearsTrackingOnFailure() async throws {
        let store = try LibraryStore.inMemory()
        let model = LibraryModel(store: store, indexStore: try .inMemory())
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")

        await #expect(throws: (any Error).self) {
            try await model.ensureLocalTracked(self.makeItem(fileURL: missing))
        }
        #expect(model.downloading.isEmpty)
    }
}
