#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import SearchIndexKit
import Testing

@testable import ReaderUI

/// Creates a real PDF file with one page per string, drawn via Core Text.
private func makeTextPDF(pageTexts: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LibraryIndexingTests-\(UUID().uuidString).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard
        let consumer = CGDataConsumer(url: url as CFURL),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        fatalError("cannot create PDF context")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    for text in pageTexts {
        context.beginPDFPage(nil)
        if !text.isEmpty {
            let attributed = NSAttributedString(
                string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            )
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

@Suite("Library full-text indexing")
@MainActor
struct LibraryIndexingTests {
    @Test func indexesImportedBooksAndMapsHitsToItems() async throws {
        let indexStore = try IndexStore.inMemory()
        let model = LibraryModel(store: try .inMemory(), indexStore: indexStore)

        let vectorBook = try makeTextPDF(pageTexts: [
            "introduction to vector spaces",
            "the span of a list contains zqvwqx obviously",
        ])
        let groupBook = try makeTextPDF(pageTexts: ["groups rings and fields"])
        defer {
            try? FileManager.default.removeItem(at: vectorBook)
            try? FileManager.default.removeItem(at: groupBook)
        }

        model.importPDFs(at: [vectorBook, groupBook])
        #expect(model.items.count == 2)

        await model.indexLibrary()
        #expect(model.indexingProgress == nil)
        #expect(model.contentHashByItemID.count == 2)

        model.searchText = "zqvwqx"
        let hits = model.fullTextHits()
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        let expectedItem = try #require(
            model.items.first { $0.fileURL.path == vectorBook.standardizedFileURL.path }
        )
        #expect(hit.itemID == expectedItem.id)
        #expect(hit.title == expectedItem.title)
        #expect(hit.page == 2)
        #expect(hit.snippet.contains("«zqvwqx»"))
        #expect(hit.id.hasSuffix("-2"))

        model.searchText = "fields"
        let groupHits = model.fullTextHits()
        #expect(groupHits.count == 1)
        #expect(groupHits.first?.page == 1)

        // Empty search text yields nothing.
        model.searchText = "   "
        #expect(model.fullTextHits().isEmpty)
    }

    @Test func hitsForUnknownHashesAreDropped() async throws {
        let indexStore = try IndexStore.inMemory()
        let model = LibraryModel(store: try .inMemory(), indexStore: indexStore)

        let book = try makeTextPDF(pageTexts: ["ordinary local content"])
        defer { try? FileManager.default.removeItem(at: book) }
        model.importPDFs(at: [book])
        await model.indexLibrary()

        // A document indexed under a hash no library item maps to — e.g. a
        // book that was removed, or indexed on another machine.
        try indexStore.insertPages(
            contentHash: String(repeating: "f", count: 64),
            pageCount: 1,
            extractorVersion: IndexingService.extractorVersion,
            pages: [(page: 1, text: "phantom orphaned wqzzvk content")]
        )
        #expect(try indexStore.search("wqzzvk", limit: 10).count == 1)

        model.searchText = "wqzzvk"
        #expect(model.fullTextHits().isEmpty)

        model.searchText = "ordinary"
        #expect(model.fullTextHits().count == 1)
    }

    @Test func unchangedCandidatesKeepTheRunningPass() async throws {
        let settings = AppSettings(defaults: nil)
        let model = LibraryModel(
            store: try .inMemory(), indexStore: try IndexStore.inMemory(),
            settings: settings
        )

        let book = try makeTextPDF(pageTexts: ["alpha bravo"])
        defer { try? FileManager.default.removeItem(at: book) }
        model.importPDFs(at: [book])

        model.startBackgroundIndexing()
        #expect(model.indexingPassesStarted == 1)
        #expect(model.isBackgroundIndexingScheduled)

        // A reload that didn't change any book (iCloud sync churn firing the
        // folder watcher) must not restart the pass.
        model.startBackgroundIndexing()
        #expect(model.indexingPassesStarted == 1)

        // A new book changes the candidate set: the pass restarts.
        let second = try makeTextPDF(pageTexts: ["charlie delta"])
        defer { try? FileManager.default.removeItem(at: second) }
        model.importPDFs(at: [second])
        model.startBackgroundIndexing()
        #expect(model.indexingPassesStarted == 2)
    }

    @Test func settingsChangesRestartOrStopThePass() async throws {
        let settings = AppSettings(defaults: nil)
        let model = LibraryModel(
            store: try .inMemory(), indexStore: try IndexStore.inMemory(),
            settings: settings
        )

        let book = try makeTextPDF(pageTexts: ["alpha bravo"])
        defer { try? FileManager.default.removeItem(at: book) }
        model.importPDFs(at: [book])

        model.startBackgroundIndexing()
        #expect(model.indexingPassesStarted == 1)

        // Toggling OCR restarts the pass even though candidates are the same.
        settings.ocrIndexingEnabled = false
        model.indexingSettingsChanged()
        #expect(model.indexingPassesStarted == 2)
        #expect(model.indexingServiceOCREnabled == false)

        // Disabling stops it; re-enabling starts fresh.
        settings.backgroundIndexingEnabled = false
        model.indexingSettingsChanged()
        #expect(!model.isBackgroundIndexingScheduled)
        settings.backgroundIndexingEnabled = true
        model.indexingSettingsChanged()
        #expect(model.indexingPassesStarted == 3)
    }

    @Test func indexingSkipsMissingFiles() async throws {
        let indexStore = try IndexStore.inMemory()
        let model = LibraryModel(store: try .inMemory(), indexStore: indexStore)

        model.setItemsForTesting([
            LibraryItem(
                id: "gone", source: .imported, title: "Evicted Book",
                authors: [], calibreTags: [],
                fileURL: URL(fileURLWithPath: "/nonexistent/evicted-\(UUID()).pdf"),
                coverURL: nil
            )
        ])

        await model.indexLibrary()
        #expect(model.contentHashByItemID.isEmpty)
        #expect(model.indexingProgress == nil)
    }
}
#endif
