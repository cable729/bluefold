import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Outcome of an `IndexingService.indexDocument(at:contentHash:)` call.
public enum IndexResult: Equatable, Sendable {
    /// The document was already indexed at the current extractor version.
    case alreadyIndexed
    /// The document was indexed. `pages` is the total page count; text was
    /// extracted from `nonEmptyPages` of them, `ocrPages` of which had no
    /// text layer and were recognized via Vision OCR.
    case indexed(pages: Int, nonEmptyPages: Int, ocrPages: Int)
    /// No page produced any text: no text layer, and OCR (when enabled)
    /// recognized nothing either.
    case notSearchable
}

public enum IndexingError: Error, Equatable {
    /// PDFKit could not open the file as a PDF document.
    case cannotOpenPDF(URL)
}

/// Extracts text from PDFs and writes it into an `IndexStore`.
///
/// Pages without a text layer (scanned books) fall back to Vision OCR when
/// `ocrEnabled` — the recognized text is messy for math notation, which is
/// fine: FTS tolerates it and snippets are shown as-is.
///
/// PDFKit and Vision types are not Sendable, so every `PDFDocument`, bitmap
/// context, and `VNRecognizeTextRequest` is created and fully consumed inside
/// this actor — nothing crosses an isolation boundary.
public actor IndexingService {
    /// Bump when text extraction changes so existing entries are re-indexed.
    /// v2: OCR fallback for pages without a text layer.
    public static let extractorVersion = 2

    /// Pages extracted between cooperative `Task.yield()` calls.
    private static let yieldBatchSize = 25

    /// OCR render resolution. PDF points are 72 DPI; ~200 DPI is enough for
    /// Vision to read body text reliably without huge bitmaps.
    private static let ocrScale: CGFloat = 200.0 / 72.0

    private let store: IndexStore
    private let ocrEnabled: Bool

    public init(store: IndexStore, ocrEnabled: Bool = true) {
        self.store = store
        self.ocrEnabled = ocrEnabled
    }

    /// Indexes the PDF at `url`, keyed by its content hash (computed when not
    /// supplied). Empty/whitespace-only pages are skipped but still counted in
    /// the document's page count.
    public func indexDocument(at url: URL, contentHash: String? = nil) async throws -> IndexResult {
        let hash = try contentHash ?? ContentHash.compute(for: url)
        if try store.isIndexed(contentHash: hash, extractorVersion: Self.extractorVersion) {
            return .alreadyIndexed
        }

        guard let document = PDFDocument(url: url) else {
            throw IndexingError.cannotOpenPDF(url)
        }

        let pageCount = document.pageCount
        var pages: [(page: Int, text: String)] = []
        var ocrPages = 0
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ocrEnabled {
                if let recognized = recognizeText(on: page),
                    !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    text = recognized
                    ocrPages += 1
                }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append((page: index + 1, text: text))
            }
            // Extraction (and OCR especially) dominates the cost; yield
            // periodically so a 500 MB textbook doesn't monopolize the
            // actor's executor.
            if (index + 1).isMultiple(of: Self.yieldBatchSize) {
                await Task.yield()
            }
        }

        guard !pages.isEmpty else { return .notSearchable }

        // insertPages transactionally deletes stale rows for this hash first,
        // so a cancelled or crashed run never leaves a partial index behind.
        try store.insertPages(
            contentHash: hash,
            pageCount: pageCount,
            extractorVersion: Self.extractorVersion,
            pages: pages
        )
        return .indexed(pages: pageCount, nonEmptyPages: pages.count, ocrPages: ocrPages)
    }

    // MARK: - OCR fallback

    /// Renders the page to a bitmap at ~200 DPI and runs Vision text
    /// recognition over it. Returns nil when rendering fails or nothing is
    /// recognized. Math notation comes out messy — expected; we index it
    /// as-is beyond trimming.
    private func recognizeText(on page: PDFPage) -> String? {
        guard let image = renderImage(of: page) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private func renderImage(of page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int((bounds.width * Self.ocrScale).rounded())
        let height = Int((bounds.height * Self.ocrScale).rounded())
        guard
            width > 0, height > 0,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: Self.ocrScale, y: Self.ocrScale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
