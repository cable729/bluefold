#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import ReaderPersistence
import Testing

@testable import ReaderUI

@Suite("Bookmarks & reading state")
@MainActor
struct BookmarksReadingStateTests {
    private func makeFixture() throws -> (ReaderWindowModel, LibraryStore, URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let document = PDFDocument()
        for i in 0..<5 {
            document.insert(PDFPage(), at: i)
        }
        let url = dir.appendingPathComponent("book.pdf")
        document.write(to: url)

        let store = try LibraryStore.inMemory()
        let model = ReaderWindowModel(provider: DocumentProvider(), store: store)
        return (model, store, url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func openingUnknownFileAutoRegistersBook() throws {
        let (model, store, url, cleanup) = try makeFixture()
        defer { cleanup() }

        model.openTab(fileURL: url)
        let tab = try #require(model.activeTab)
        let bookID = try #require(model.bookRowID(for: tab))

        let book = try #require(try store.book(id: bookID))
        #expect(book.contentHash != nil)
        #expect(book.title == "book")
    }

    @Test func captureWritesReadingState() throws {
        let (model, store, url, cleanup) = try makeFixture()
        defer { cleanup() }

        let tabID = model.openTab(fileURL: url)
        model.capture(
            tabID: tabID,
            entry: NavEntry(pageIndex: 3),
            autoScales: true,
            displayModeRaw: 1
        )

        let tab = try #require(model.activeTab)
        let bookID = try #require(model.bookRowID(for: tab))
        let state = try #require(try store.readingState(forBook: bookID))
        #expect(state.page == 3)
        #expect(!state.device.isEmpty)
    }

    @Test func bookmarkAddListDelete() throws {
        let (model, _, url, cleanup) = try makeFixture()
        defer { cleanup() }

        let tabID = model.openTab(fileURL: url)
        model.capture(tabID: tabID, entry: NavEntry(pageIndex: 2), autoScales: true, displayModeRaw: 1)

        model.addBookmarkAtCurrentPosition()
        #expect(model.activeBookmarks.count == 1)
        #expect(model.activeBookmarks[0].page == 2)

        let id = try #require(model.activeBookmarks[0].id)
        model.deleteBookmark(id: id)
        #expect(model.activeBookmarks.isEmpty)
    }

    @Test func sameFileResolvesToSameBookAcrossModels() throws {
        let (model, store, url, cleanup) = try makeFixture()
        defer { cleanup() }

        model.openTab(fileURL: url)
        let firstID = try #require(model.bookRowID(for: model.activeTab!))

        // A second window (fresh model, same store) resolves identically —
        // no duplicate book row.
        let second = ReaderWindowModel(provider: DocumentProvider(), store: store)
        second.openTab(fileURL: url)
        let secondID = try #require(second.bookRowID(for: second.activeTab!))
        #expect(firstID == secondID)
        #expect(try store.allBooks().count == 1)
    }

    @Test func resolutionPrefersContentHashAfterFileMove() throws {
        let (model, store, url, cleanup) = try makeFixture()
        defer { cleanup() }

        model.openTab(fileURL: url)
        let originalID = try #require(model.bookRowID(for: model.activeTab!))

        // Move the file; a fresh model resolving the new path must find the
        // same book via content hash.
        let moved = url.deletingLastPathComponent().appendingPathComponent("renamed.pdf")
        try FileManager.default.moveItem(at: url, to: moved)

        let second = ReaderWindowModel(provider: DocumentProvider(), store: store)
        second.openTab(fileURL: moved)
        let movedID = try #require(second.bookRowID(for: second.activeTab!))
        #expect(movedID == originalID)
    }
}
#endif
