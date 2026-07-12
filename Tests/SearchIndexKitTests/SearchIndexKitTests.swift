import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import SearchIndexKit

@Test func moduleLoads() {
    #expect(SearchIndexKitInfo.moduleName == "SearchIndexKit")
}

// MARK: - Fixture helpers

enum FixtureError: Error {
    case cannotCreatePDFContext
}

/// Creates a real PDF at `url` with one page per element of `pageTexts`,
/// drawing the text via Core Text. Empty strings produce blank pages.
private func makePDF(at url: URL, pageTexts: [String]) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard
        let consumer = CGDataConsumer(url: url as CFURL),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        throw FixtureError.cannotCreatePDFContext
    }

    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    for text in pageTexts {
        context.beginPDFPage(nil)
        if !text.isEmpty {
            let attributed = NSAttributedString(
                string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
}

/// Creates a "scanned-style" PDF: each page contains ONLY a bitmap image of
/// rendered text (no text layer at all), like a scanned book without OCR.
private func makeScannedPDF(at url: URL, pageTexts: [String]) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard
        let consumer = CGDataConsumer(url: url as CFURL),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        throw FixtureError.cannotCreatePDFContext
    }

    for text in pageTexts {
        context.beginPDFPage(nil)
        if let image = try? renderTextImage(text, pageSize: mediaBox.size) {
            context.draw(image, in: mediaBox)
        }
        context.endPDFPage()
    }
    context.closePDF()
}

/// Renders text into a CGBitmapContext image (2x page size, white background,
/// large Helvetica) so Vision can OCR it reliably.
private func renderTextImage(_ text: String, pageSize: CGSize) throws -> CGImage {
    let scale: CGFloat = 2
    let width = Int(pageSize.width * scale)
    let height = Int(pageSize.height * scale)
    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else {
        throw FixtureError.cannotCreatePDFContext
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

    if !text.isEmpty {
        // 28 pt at page scale = 56 px in this 2x bitmap.
        let font = CTFontCreateWithName("Helvetica" as CFString, 28 * scale, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
        )
        context.textPosition = CGPoint(x: 72 * scale, y: 600 * scale)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    guard let image = context.makeImage() else {
        throw FixtureError.cannotCreatePDFContext
    }
    return image
}

/// A unique temp directory, removed when the value is deinitialized.
private final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIndexKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private let standardPageTexts = [
    "alpha bravo xyzzy",
    "second page charlie",
    "",
]

// MARK: - ContentHash

@Test func contentHashIsDeterministic() throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)

    let first = try ContentHash.compute(for: file)
    let second = try ContentHash.compute(for: file)
    #expect(first == second)
    #expect(first.count == 64)
    let isAllHex = first.allSatisfy(\.isHexDigit)
    #expect(isAllHex)
}

@Test func contentHashChangesWhenFileChanges() throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)
    let original = try ContentHash.compute(for: file)

    // Different content entirely.
    try makePDF(at: file, pageTexts: ["totally different content"])
    let changed = try ContentHash.compute(for: file)
    #expect(original != changed)

    // Same leading bytes, different size: appending past the head still
    // changes the hash because the size is mixed in.
    var data = try Data(contentsOf: file)
    data.append(contentsOf: [0x0a])
    try data.write(to: file)
    let appended = try ContentHash.compute(for: file)
    #expect(appended != changed)
}

// MARK: - Indexing + search

@Test func tokenIsFoundOnCorrectPage() async throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)
    let result = try await service.indexDocument(at: file)
    #expect(result == .indexed(pages: 3, nonEmptyPages: 2, ocrPages: 0))

    let xyzzyHits = try store.search("xyzzy", limit: 10)
    #expect(xyzzyHits.count == 1)
    #expect(xyzzyHits.first?.page == 1)
    #expect(xyzzyHits.first?.contentHash == (try ContentHash.compute(for: file)))

    let charlieHits = try store.search("charlie", limit: 10)
    #expect(charlieHits.count == 1)
    #expect(charlieHits.first?.page == 2)
}

@Test func snippetContainsHighlightMarkers() async throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)
    _ = try await service.indexDocument(at: file)

    let hits = try store.search("bravo", limit: 10)
    let snippet = try #require(hits.first?.snippet)
    #expect(snippet.contains("«bravo»"))
}

@Test func alreadyIndexedThenRemoveThenReindex() async throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)
    let hash = try ContentHash.compute(for: file)

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)

    let first = try await service.indexDocument(at: file)
    #expect(first == .indexed(pages: 3, nonEmptyPages: 2, ocrPages: 0))
    #expect(try store.isIndexed(contentHash: hash, extractorVersion: IndexingService.extractorVersion))

    let second = try await service.indexDocument(at: file)
    #expect(second == .alreadyIndexed)

    try store.removeIndex(contentHash: hash)
    #expect(!(try store.isIndexed(contentHash: hash, extractorVersion: IndexingService.extractorVersion)))
    #expect(try store.search("xyzzy", limit: 10).isEmpty)

    let third = try await service.indexDocument(at: file)
    #expect(third == .indexed(pages: 3, nonEmptyPages: 2, ocrPages: 0))
    #expect(try store.search("xyzzy", limit: 10).count == 1)
}

@Test func cancelledIndexingStopsWithoutWriting() async throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)
    let hash = try ContentHash.compute(for: file)

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)

    let task = Task { () throws -> IndexResult in
        // Spin until the cancel below has landed, so indexDocument's
        // per-page check is guaranteed to observe it.
        while !Task.isCancelled { await Task.yield() }
        return try await service.indexDocument(at: file, contentHash: hash)
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected CancellationError")
    } catch is CancellationError {
        // expected: cancellation surfaces before any page is extracted
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(
        !(try store.isIndexed(
            contentHash: hash, extractorVersion: IndexingService.extractorVersion))
    )
}

@Test func allBlankPDFIsNotSearchable() async throws {
    let dir = try TempDir()
    let file = dir.file("blank.pdf")
    try makePDF(at: file, pageTexts: ["", "", ""])

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)
    let result = try await service.indexDocument(at: file)
    #expect(result == .notSearchable)

    let hash = try ContentHash.compute(for: file)
    #expect(!(try store.isIndexed(contentHash: hash, extractorVersion: IndexingService.extractorVersion)))
}

@Test func multiWordAndPhraseQueriesDoNotThrow() async throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)
    _ = try await service.indexDocument(at: file)

    // Multi-word query matches the page containing both terms.
    let multi = try store.search("alpha xyzzy", limit: 10)
    #expect(multi.first?.page == 1)

    // Inputs that are FTS5 syntax errors when unsanitized must not throw.
    let hostileQueries = [
        "second page",
        "\"second page\"",
        "alpha AND (",
        "xyzzy*",
        "NOT",
        "co-author's \"notes",
        "   ",
    ]
    for query in hostileQueries {
        _ = try store.search(query, limit: 10)
    }
    #expect(try store.search("   ", limit: 10).isEmpty)
}

@Test func unicodeQueryMatchesWithAndWithoutDiacritics() async throws {
    let dir = try TempDir()
    let file = dir.file("kaehler.pdf")
    try makePDF(at: file, pageTexts: ["Introduction to the Kähler manifold"])

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)
    let result = try await service.indexDocument(at: file)
    #expect(result == .indexed(pages: 1, nonEmptyPages: 1, ocrPages: 0))

    let accented = try store.search("Kähler manifold", limit: 10)
    #expect(accented.first?.page == 1)

    let plain = try store.search("Kahler", limit: 10)
    #expect(plain.first?.page == 1)
}

// MARK: - OCR fallback (M13b)

@Test func scannedPDFIsNotSearchableWithOCRDisabled() async throws {
    let dir = try TempDir()
    let file = dir.file("scanned.pdf")
    try makeScannedPDF(at: file, pageTexts: ["scanned page with token qwjzxv"])

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store, ocrEnabled: false)
    let result = try await service.indexDocument(at: file)
    #expect(result == .notSearchable)
}

@Test func scannedPDFIsIndexedViaOCR() async throws {
    let dir = try TempDir()
    let file = dir.file("scanned.pdf")
    try makeScannedPDF(at: file, pageTexts: ["scanned page with token qwjzxv"])

    let store = try IndexStore.inMemory()
    let service = IndexingService(store: store)
    let result = try await service.indexDocument(at: file)
    #expect(result == .indexed(pages: 1, nonEmptyPages: 1, ocrPages: 1))

    let hits = try store.search("qwjzxv", limit: 10)
    #expect(hits.count == 1)
    #expect(hits.first?.page == 1)
    #expect(hits.first?.contentHash == (try ContentHash.compute(for: file)))
}

@Test func extractorVersionBumpTriggersReindex() async throws {
    let dir = try TempDir()
    let file = dir.file("doc.pdf")
    try makePDF(at: file, pageTexts: standardPageTexts)
    let hash = try ContentHash.compute(for: file)

    let store = try IndexStore.inMemory()
    // Simulate a document indexed by the v1 extractor.
    try store.insertPages(
        contentHash: hash,
        pageCount: 3,
        extractorVersion: 1,
        pages: [(page: 1, text: "stale v1 extraction")]
    )
    #expect(try store.isIndexed(contentHash: hash, extractorVersion: 1))
    #expect(!(try store.isIndexed(contentHash: hash, extractorVersion: IndexingService.extractorVersion)))

    // Not .alreadyIndexed: the version mismatch forces a re-index that
    // replaces the stale rows.
    let service = IndexingService(store: store)
    let result = try await service.indexDocument(at: file)
    #expect(result == .indexed(pages: 3, nonEmptyPages: 2, ocrPages: 0))
    #expect(try store.isIndexed(contentHash: hash, extractorVersion: IndexingService.extractorVersion))
    #expect(try store.search("stale", limit: 10).isEmpty)
    #expect(try store.search("xyzzy", limit: 10).count == 1)
}

// MARK: - Query sanitizer

@Test func sanitizerQuotesTermsAndHandlesEmptyInput() {
    #expect(IndexStore.sanitizeQuery("alpha bravo") == "\"alpha\" \"bravo\"")
    #expect(IndexStore.sanitizeQuery("a\"b") == "\"a\"\"b\"")
    #expect(IndexStore.sanitizeQuery("") == nil)
    #expect(IndexStore.sanitizeQuery("  \n ") == nil)
}
