#if os(macOS)
import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import ReaderUI

/// #59 bug 1 — the background content-box preloader. The service walks the book
/// off the main thread and must return EXACTLY the boxes the synchronous
/// `PageContentDetector.contentBox` finds (contract test against the live
/// implementation — house policy for any off-main analogue), so the main-thread
/// applier can crop from cached rectangles instead of rendering 600 pages
/// synchronously (the white-flash root cause).
@Suite("Content box preloader")
struct ContentBoxServiceTests {

    /// Contract: the actor's off-main detection equals the on-main detector for
    /// every page — same rects, same "leave as-is" (absent) decisions.
    @Test func matchesSynchronousDetectorPerPage() async throws {
        let size = CGSize(width: 480, height: 640)
        // A mix: normal margins (croppable), one full-bleed (nothing to
        // reclaim → absent), one narrow stripe (cover guard → absent). Build the
        // doc and take ground truth from the synchronous detector inside ONE main
        // hop, returning only Sendable values (PDFDocument isn't Sendable).
        let (url, expected): (URL, [Int: CGRect]) = try await MainActor.run {
            let doc = try makeMarginPDF(
                pages: 8, size: size, margin: 90,
                fullBleedPages: [3], narrowPages: [5])
            let url = try #require(doc.documentURL)
            var map: [Int: CGRect] = [:]
            for i in 0..<doc.pageCount {
                if let box = PageContentDetector.contentBox(of: doc.page(at: i)!) {
                    map[i] = box
                }
            }
            return (url, map)
        }

        let service = ContentBoxService()
        let actual = try await service.detectContentBoxes(at: url)

        #expect(actual.count == expected.count)
        #expect(Set(actual.keys) == Set(expected.keys))
        for (i, box) in expected {
            let got = try #require(actual[i], "service missing page \(i)")
            // Same PDF geometry both sides — expect bit-identical rects.
            #expect(got == box, "page \(i): \(got) != \(box)")
        }
        // Sanity: the full-bleed and narrow pages were left as-is by BOTH.
        #expect(actual[3] == nil)
        #expect(actual[5] == nil)
        #expect(actual[0] != nil)
    }

    /// A missing / unreadable file surfaces a typed error rather than hanging.
    @Test func unreadableURLThrows() async {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")
        let service = ContentBoxService()
        await #expect(throws: ContentBoxError.self) {
            _ = try await service.detectContentBoxes(at: bogus)
        }
    }
}
#endif
