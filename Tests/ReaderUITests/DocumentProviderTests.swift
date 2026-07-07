#if os(macOS)
import Foundation
import PDFKit
import Testing

@testable import ReaderUI

/// Writes a tiny real PDF (blank pages) and returns its URL.
private func makeBlankPDF(named name: String, in dir: URL, pages: Int = 1) -> URL {
    let document = PDFDocument()
    for i in 0..<pages {
        document.insert(PDFPage(), at: i)
    }
    let url = dir.appendingPathComponent("\(name).pdf")
    document.write(to: url)
    return url
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DocumentProviderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("DocumentProvider")
@MainActor
struct DocumentProviderTests {
    @Test func sameURLReturnsSharedInstance() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = makeBlankPDF(named: "a", in: dir)

        let provider = DocumentProvider(capacity: 3)
        let first = provider.document(for: url)
        let second = provider.document(for: url)
        #expect(first != nil)
        #expect(first === second)
        #expect(provider.residentPaths.count == 1)
    }

    @Test func evictsLeastRecentlyUsedBeyondCapacity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<5).map { makeBlankPDF(named: "doc\($0)", in: dir) }

        let provider = DocumentProvider(capacity: 3)
        for url in urls {
            _ = provider.document(for: url)
        }
        #expect(provider.residentPaths.count == 3)
        // The three most recently opened remain.
        let expected = urls.suffix(3).map { DocumentProvider.canonicalPath(for: $0) }
        #expect(provider.residentPaths == expected)
    }

    @Test func accessRefreshesRecency() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<4).map { makeBlankPDF(named: "doc\($0)", in: dir) }

        let provider = DocumentProvider(capacity: 3)
        _ = provider.document(for: urls[0])
        _ = provider.document(for: urls[1])
        _ = provider.document(for: urls[2])
        _ = provider.document(for: urls[0])  // refresh 0 → now MRU
        _ = provider.document(for: urls[3])  // evicts 1, not 0

        let resident = Set(provider.residentPaths)
        #expect(resident.contains(DocumentProvider.canonicalPath(for: urls[0])))
        #expect(!resident.contains(DocumentProvider.canonicalPath(for: urls[1])))
    }

    @Test func pinnedDocumentsSurviveEviction() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<5).map { makeBlankPDF(named: "doc\($0)", in: dir) }

        let provider = DocumentProvider(capacity: 2)
        let pinnedPath = DocumentProvider.canonicalPath(for: urls[0])
        provider.pinnedPaths = [pinnedPath]

        for url in urls {
            _ = provider.document(for: url)
        }
        #expect(provider.residentPaths.contains(pinnedPath))
        #expect(provider.residentPaths.count == 2)
    }

    @Test func missingFileReturnsNil() throws {
        let provider = DocumentProvider()
        let ghost = URL(fileURLWithPath: "/nonexistent/nowhere.pdf")
        #expect(provider.document(for: ghost) == nil)
        #expect(provider.residentPaths.isEmpty)
    }
}
#endif
