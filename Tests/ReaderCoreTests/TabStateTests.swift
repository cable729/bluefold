import Foundation
import Testing
@testable import ReaderCore

@Suite struct TabStateTests {
    @Test func currentNavEntryReflectsPosition() {
        let tab = TabState(
            pathHint: "/tmp/book.pdf",
            pageIndex: 5,
            destinationPoint: CGPoint(x: 1, y: 2),
            scaleFactor: 2.0
        )
        let entry = tab.currentNavEntry
        #expect(entry == NavEntry(pageIndex: 5, point: CGPoint(x: 1, y: 2), scaleFactor: 2.0))
    }

    @Test func applyNavEntryUpdatesPosition() {
        var tab = TabState(pathHint: "/tmp/book.pdf", pageIndex: 0, scaleFactor: 1.0)
        tab.apply(NavEntry(pageIndex: 30, point: CGPoint(x: 0, y: 100), scaleFactor: 1.75))
        #expect(tab.pageIndex == 30)
        #expect(tab.destinationPoint == CGPoint(x: 0, y: 100))
        #expect(tab.scaleFactor == 1.75)
    }

    @Test func applyWithoutScaleKeepsExistingScale() {
        var tab = TabState(pathHint: "/tmp/book.pdf", scaleFactor: 1.5)
        tab.apply(NavEntry(pageIndex: 2))
        #expect(tab.scaleFactor == 1.5)
        #expect(tab.destinationPoint == nil)
    }

    @Test func themePageFilters() {
        #expect(AppTheme.light.pageRenderFilter == .none)
        #expect(AppTheme.dark.pageRenderFilter == .invert)
        #expect(AppTheme.sepia.pageRenderFilter == .warmPaper)
    }
}
