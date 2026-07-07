import Foundation
import PDFKit

/// Outcome of an `IndexingService.indexDocument(at:contentHash:)` call.
public enum IndexResult: Equatable, Sendable {
    /// The document was already indexed at the current extractor version.
    case alreadyIndexed
    /// The document was indexed. `pages` is the total page count; text was
    /// extracted from `nonEmptyPages` of them.
    case indexed(pages: Int, nonEmptyPages: Int)
    /// No page produced any text (e.g. a scanned book with no OCR layer).
    case notSearchable
}

public enum IndexingError: Error, Equatable {
    /// PDFKit could not open the file as a PDF document.
    case cannotOpenPDF(URL)
}

/// Extracts text from PDFs and writes it into an `IndexStore`.
///
/// PDFKit types are not Sendable, so every `PDFDocument` is created and fully
/// consumed inside this actor — it never crosses an isolation boundary.
public actor IndexingService {
    /// Bump when text extraction changes so existing entries are re-indexed.
    public static let extractorVersion = 1

    /// Pages extracted between cooperative `Task.yield()` calls.
    private static let yieldBatchSize = 25

    private let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
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
        for index in 0..<pageCount {
            if let text = document.page(at: index)?.string,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                pages.append((page: index + 1, text: text))
            }
            // Extraction dominates the cost; yield periodically so a 500 MB
            // textbook doesn't monopolize the actor's executor.
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
        return .indexed(pages: pageCount, nonEmptyPages: pages.count)
    }
}
