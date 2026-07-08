#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("Status bar page arrows")
@MainActor
struct PageArrowsTests {
    // MARK: - Enablement math

    @Test func backDisabledOnFirstPage() {
        #expect(!PageArrows.canGoBack(pageIndex: 0, pageCount: 53))
        #expect(PageArrows.canGoForward(pageIndex: 0, pageCount: 53))
    }

    @Test func forwardDisabledOnLastPage() {
        #expect(PageArrows.canGoBack(pageIndex: 52, pageCount: 53))
        #expect(!PageArrows.canGoForward(pageIndex: 52, pageCount: 53))
    }

    @Test func bothEnabledInTheMiddle() {
        #expect(PageArrows.canGoBack(pageIndex: 37, pageCount: 53))
        #expect(PageArrows.canGoForward(pageIndex: 37, pageCount: 53))
    }

    @Test func singlePageDocumentDisablesBoth() {
        #expect(!PageArrows.canGoBack(pageIndex: 0, pageCount: 1))
        #expect(!PageArrows.canGoForward(pageIndex: 0, pageCount: 1))
    }

    @Test func noActiveTabDisablesBoth() {
        #expect(!PageArrows.canGoBack(pageIndex: nil, pageCount: 53))
        #expect(!PageArrows.canGoForward(pageIndex: nil, pageCount: 53))
    }

    @Test func emptyDocumentDisablesBoth() {
        #expect(!PageArrows.canGoBack(pageIndex: 3, pageCount: 0))
        #expect(!PageArrows.canGoForward(pageIndex: 3, pageCount: 0))
    }

    @Test func outOfRangeIndexStaysSane() {
        // Defensive: a stale index past the end must not enable "next".
        #expect(!PageArrows.canGoForward(pageIndex: 53, pageCount: 53))
        #expect(PageArrows.canGoBack(pageIndex: 53, pageCount: 53))
    }

    // MARK: - Model forwarding

    /// Records page-turn commands; everything else is the protocol default.
    @MainActor
    private final class Recorder: ActivePDFControlling {
        var liveNavEntry: NavEntry?
        var turns: [String] = []

        func execute(_ entry: NavEntry) {}
        func showFindResults(_ matches: [PDFSelection], current: PDFSelection?) {}
        func goToPreviousPage() { turns.append("prev") }
        func goToNextPage() { turns.append("next") }
    }

    @Test func modelForwardsPageTurnsToActiveController() {
        let model = ReaderWindowModel(provider: DocumentProvider(), store: nil)
        let recorder = Recorder()
        model.activeController = recorder

        model.goToNextPage()
        model.goToPreviousPage()
        model.goToNextPage()
        #expect(recorder.turns == ["next", "prev", "next"])
    }

    @Test func pageTurnsAreNoOpsWithoutController() {
        let model = ReaderWindowModel(provider: DocumentProvider(), store: nil)
        // Must not crash or mutate anything.
        model.goToNextPage()
        model.goToPreviousPage()
        #expect(model.activeTab == nil)
    }
}
#endif
