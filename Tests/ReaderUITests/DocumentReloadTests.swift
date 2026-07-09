#if os(macOS)
import Foundation
import PDFKit
import Testing

@testable import ReaderUI

/// Auto-reload of open documents whose file changed on disk (round 18):
/// the provider swaps the fresh document into the same cache slot, and the
/// coordinator publishes a generation bump for the views.
@MainActor
@Suite struct DocumentReloadTests {

    private func writePDF(pageCount: Int, to url: URL) throws {
        let document = PDFDocument()
        for index in 0..<pageCount {
            document.insert(PDFPage(), at: index)
        }
        #expect(document.write(to: url))
    }

    private func makeTempPDF(pageCount: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reload-\(UUID().uuidString).pdf")
        try writePDF(pageCount: pageCount, to: url)
        return url
    }

    @Test func reloadFromDiskSwapsResidentDocumentInPlace() throws {
        let url = try makeTempPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = DocumentProvider()
        let path = DocumentProvider.canonicalPath(for: url)
        let stale = try #require(provider.document(for: url))
        #expect(stale.pageCount == 1)

        try writePDF(pageCount: 2, to: url)
        #expect(provider.reloadFromDisk(path: path))

        let fresh = try #require(provider.loadedDocument(for: url))
        #expect(fresh !== stale)
        #expect(fresh.pageCount == 2)
        // Same slot: still exactly one resident document for the path.
        #expect(provider.residentPaths == [path])
    }

    @Test func reloadFromDiskRefusesNonResidentAndMissingFiles() throws {
        let url = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = DocumentProvider()
        let path = DocumentProvider.canonicalPath(for: url)

        // Not resident yet: nothing to swap.
        #expect(!provider.reloadFromDisk(path: path))

        _ = try #require(provider.document(for: url))
        try FileManager.default.removeItem(at: url)
        // File gone mid-regeneration: keep the stale document, report false.
        #expect(!provider.reloadFromDisk(path: path))
        #expect(provider.loadedDocument(for: url) != nil)
    }

    @Test func residentPathsChangeHookFiresOnLoadAndEvict() throws {
        let url = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = DocumentProvider()
        var fired = 0
        provider.onResidentPathsChanged = { fired += 1 }

        _ = provider.document(for: url)
        #expect(fired == 1)
        provider.evict(path: DocumentProvider.canonicalPath(for: url))
        #expect(fired == 2)
        // Evicting an absent path is not a change.
        provider.evict(path: "/nowhere.pdf")
        #expect(fired == 2)
    }

    @Test func coordinatorReloadBumpsGenerationAndSwapsDocument() async throws {
        let url = try makeTempPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = SessionCoordinator(
            sessionFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("reload-session-\(UUID().uuidString).json")
        )
        let path = DocumentProvider.canonicalPath(for: url)
        _ = try #require(coordinator.provider.document(for: url))
        #expect(coordinator.documentGenerations[path] == nil)

        try writePDF(pageCount: 2, to: url)
        await coordinator.reloadChangedDocument(atPath: path)

        #expect(coordinator.documentGenerations[path] == 1)
        #expect(coordinator.provider.loadedDocument(for: url)?.pageCount == 2)
    }
}
#endif
