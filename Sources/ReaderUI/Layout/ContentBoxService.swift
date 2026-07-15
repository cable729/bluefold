#if os(macOS)
import CoreGraphics
import Foundation
import PDFKit

public enum ContentBoxError: Error, Equatable {
    /// PDFKit could not open the file as a PDF document.
    case cannotOpenPDF(URL)
}

/// Detects every page's printed content box for "trim margins" (#59 bug 1)
/// OFF the main thread — the analogue of `IndexingService` for the FTS/OCR
/// pipeline. Trim used to render all ~600 pages synchronously on `@MainActor`
/// inside `rebuildBoxState`, blanking the PDFView white for ~1 s per toggle;
/// this walks the book on a background actor and returns just the per-page
/// rectangles (~4 floats/page — never rendered pixels, never a second
/// document), which the main-thread applier then seeds and crops with (a cheap
/// `setBounds`, no render).
///
/// PDFKit types are not Sendable, so — exactly like `IndexingService` — this
/// actor opens its OWN `PDFDocument(url:)` and fully consumes it inside the
/// actor; only the `[Int: CGRect]` result (Sendable) crosses back. The detected
/// boxes are in the page's ORIGINAL media coordinates, so they apply verbatim to
/// the live document's pages (same PDF, same geometry).
public actor ContentBoxService {
    /// Pages detected between cooperative `Task.yield()` calls, so a 600-page
    /// book doesn't monopolize the actor's executor.
    private static let yieldBatchSize = 25

    public init() {}

    /// Detects the content box of every page of the PDF at `url`, keyed by page
    /// index. Pages the detector leaves as-is (blank, already tight, or a
    /// cover/mis-detection) are simply absent from the map. Checks cooperative
    /// cancellation before each page so a superseded pass stops within a page.
    public func detectContentBoxes(at url: URL) async throws -> [Int: CGRect] {
        guard let document = PDFDocument(url: url) else {
            throw ContentBoxError.cannotOpenPDF(url)
        }
        var result: [Int: CGRect] = [:]
        let count = document.pageCount
        for index in 0..<count {
            try Task.checkCancellation()
            if let page = document.page(at: index),
               let box = PageContentDetector.computeContentBox(of: page) {
                result[index] = box
            }
            if (index + 1).isMultiple(of: Self.yieldBatchSize) {
                await Task.yield()
            }
        }
        return result
    }
}
#endif
