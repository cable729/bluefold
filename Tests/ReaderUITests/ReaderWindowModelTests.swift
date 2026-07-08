#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("ReaderWindowModel")
@MainActor
struct ReaderWindowModelTests {
    private func makeModel(capacity: Int = 3) -> ReaderWindowModel {
        ReaderWindowModel(provider: DocumentProvider(capacity: capacity))
    }

    @Test func openTabActivates() {
        let model = makeModel()
        let id = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        #expect(model.tabs.count == 1)
        #expect(model.activeTabID == id)
    }

    @Test func openInBackgroundKeepsActiveTab() {
        let model = makeModel()
        let first = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let second = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"), activate: false)
        #expect(model.activeTabID == first)
        #expect(model.tabs.map(\.id) == [first, second])
    }

    @Test func sameFileMayOpenInMultipleTabs() {
        let model = makeModel()
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let first = model.openTab(fileURL: url)
        let second = model.openTab(fileURL: url, at: NavEntry(pageIndex: 100))
        #expect(first != second)
        #expect(model.tabs.count == 2)
        #expect(model.tabs[1].pageIndex == 100)
    }

    @Test func closeActiveTabActivatesNeighbor() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))

        model.selectTab(id: b)
        model.closeTab(id: b)
        // The tab that slid into b's position (c) becomes active.
        #expect(model.activeTabID == c)

        model.closeTab(id: c)
        #expect(model.activeTabID == a)

        model.closeTab(id: a)
        #expect(model.activeTabID == nil)
        #expect(model.tabs.isEmpty)
    }

    @Test func closeInactiveTabKeepsActive() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.selectTab(id: a)
        model.closeTab(id: b)
        #expect(model.activeTabID == a)
    }

    @Test func captureUpdatesTabState() {
        let model = makeModel()
        let id = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.capture(
            tabID: id,
            entry: NavEntry(pageIndex: 42, point: CGPoint(x: 0, y: 500), scaleFactor: 1.5),
            autoScales: false,
            displayModeRaw: 3
        )
        let tab = model.tabs[0]
        #expect(tab.pageIndex == 42)
        #expect(tab.destinationPoint == CGPoint(x: 0, y: 500))
        #expect(tab.scaleFactor == 1.5)
        #expect(tab.autoScales == false)
        #expect(tab.displayModeRaw == 3)
    }

    @Test func activeTabDocumentIsPinned() {
        let model = makeModel()
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        #expect(model.provider.pinnedPaths == [model.tabs.first { $0.id == b }!.pathHint])

        model.closeTab(id: b)
        #expect(model.provider.pinnedPaths == [model.tabs[0].pathHint])
    }

    @Test func closingLastTabForFileEvictsDocument() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let url = dir.appendingPathComponent("a.pdf")
        document.write(to: url)

        let model = makeModel()
        let first = model.openTab(fileURL: url)
        let second = model.openTab(fileURL: url)
        _ = model.provider.document(for: url)
        #expect(model.provider.residentPaths.count == 1)

        // One tab on the file remains: document stays resident.
        model.closeTab(id: first)
        #expect(model.provider.residentPaths.count == 1)

        // Last tab closes: document is evicted.
        model.closeTab(id: second)
        #expect(model.provider.residentPaths.isEmpty)
    }

    @Test func backgroundTabOfSameBookGetsBreadcrumbImmediately() throws {
        // A ⌘-clicked reference used to sit as "p.N" in the strip until
        // its tab was first activated (round 9).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowModelTests-\(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = PDFDocument()
        for index in 0..<4 {
            document.insert(PDFPage(), at: index)
        }
        // Minimal outline: "Chapter 2" starting on page 3.
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter 2"
        chapter.destination = PDFDestination(
            page: document.page(at: 2)!, at: CGPoint(x: 0, y: 700)
        )
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root
        let url = dir.appendingPathComponent("outlined.pdf")
        document.write(to: url)

        let model = makeModel()
        model.openTab(fileURL: url)
        // The active tab's view keeps the document resident in the app;
        // tests must load it explicitly.
        _ = model.provider.document(for: url)
        let background = model.openTab(
            fileURL: url, activate: false, at: NavEntry(pageIndex: 3)
        )
        #expect(model.tabs.first { $0.id == background }?.breadcrumb == "Chapter 2")
    }
}
#endif
