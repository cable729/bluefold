#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// A three-page in-memory PDF for link-resolution tests.
@MainActor
private func makeDocument(pages: Int = 3) -> PDFDocument {
    let document = PDFDocument()
    for i in 0..<pages {
        document.insert(PDFPage(), at: i)
    }
    return document
}

@Suite("Link resolution")
@MainActor
struct LinkResolutionTests {
    private let bounds = CGRect(x: 10, y: 10, width: 100, height: 20)

    @Test func resolvesGoToAction() throws {
        let document = makeDocument()
        let targetPage = try #require(document.page(at: 2))
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.action = PDFActionGoTo(
            destination: PDFDestination(page: targetPage, at: CGPoint(x: 72, y: 500))
        )

        let target = try #require(ReaderPDFView.resolveTarget(of: annotation, in: document))
        #expect(target.entry.pageIndex == 2)
        #expect(target.entry.point == CGPoint(x: 72, y: 500))
        #expect(target.remoteFileURL == nil)
    }

    @Test func resolvesBareDestinationWithoutAction() throws {
        // LaTeX/hyperref output often sets .destination with no action object.
        let document = makeDocument()
        let targetPage = try #require(document.page(at: 1))
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.destination = PDFDestination(page: targetPage, at: CGPoint(x: 0, y: 700))

        let target = try #require(ReaderPDFView.resolveTarget(of: annotation, in: document))
        #expect(target.entry.pageIndex == 1)
    }

    @Test func resolvesRemoteGoToAsOtherFile() throws {
        let document = makeDocument()
        let otherFile = URL(fileURLWithPath: "/tmp/appendix.pdf")
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.action = PDFActionRemoteGoTo(pageIndex: 7, at: CGPoint(x: 0, y: 400), fileURL: otherFile)

        let target = try #require(ReaderPDFView.resolveTarget(of: annotation, in: document))
        #expect(target.entry.pageIndex == 7)
        #expect(target.remoteFileURL != nil)
        #expect(target.remoteFileURL?.lastPathComponent == "appendix.pdf")
    }

    @Test func unspecifiedDestinationPointBecomesNil() throws {
        let document = makeDocument()
        let targetPage = try #require(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.action = PDFActionGoTo(
            destination: PDFDestination(
                page: targetPage,
                at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
            )
        )

        let target = try #require(ReaderPDFView.resolveTarget(of: annotation, in: document))
        #expect(target.entry.point == nil)
    }

    @Test func nonLinkAnnotationResolvesToNil() {
        let document = makeDocument()
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        #expect(ReaderPDFView.resolveTarget(of: annotation, in: document) == nil)
    }
}

/// Stands in for the live PDFView: records executed jumps.
@MainActor
private final class FakeController: ActivePDFControlling {
    var liveNavEntry: NavEntry?
    var executed: [NavEntry] = []

    init(at entry: NavEntry) {
        liveNavEntry = entry
    }

    func execute(_ entry: NavEntry) {
        executed.append(entry)
        liveNavEntry = entry
    }
}

@Suite("Navigation flows")
@MainActor
struct NavigationFlowTests {
    private func makeModelWithTab() -> (ReaderWindowModel, UUID, FakeController) {
        let model = ReaderWindowModel(provider: DocumentProvider())
        let id = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/book.pdf"))
        let controller = FakeController(at: NavEntry(pageIndex: 10))
        model.activeController = controller
        return (model, id, controller)
    }

    @Test func plainLinkClickPushesHistoryAndJumps() {
        let (model, id, controller) = makeModelWithTab()

        model.linkActivated(
            target: NavEntry(pageIndex: 250),
            remoteFileURL: nil,
            current: NavEntry(pageIndex: 10),
            inNewTab: false
        )

        #expect(controller.executed == [NavEntry(pageIndex: 250)])
        let tab = model.tabs.first { $0.id == id }!
        #expect(tab.pageIndex == 250)
        #expect(tab.history.canGoBack)
        #expect(model.tabs.count == 1)
    }

    @Test func commandClickOpensNewTabAtDestination() {
        let (model, id, controller) = makeModelWithTab()

        model.linkActivated(
            target: NavEntry(pageIndex: 250),
            remoteFileURL: nil,
            current: NavEntry(pageIndex: 10),
            inNewTab: true
        )

        #expect(model.tabs.count == 2)
        let newTab = model.tabs[1]
        #expect(newTab.pageIndex == 250)
        #expect(model.activeTabID == newTab.id)
        // Originating tab did not move and gained no history.
        let original = model.tabs.first { $0.id == id }!
        #expect(original.pageIndex == 0)
        #expect(!original.history.canGoBack)
        #expect(controller.executed.isEmpty)
    }

    @Test func remoteLinkOpensOtherFileInNewTab() {
        let (model, _, _) = makeModelWithTab()

        model.linkActivated(
            target: NavEntry(pageIndex: 7),
            remoteFileURL: URL(fileURLWithPath: "/tmp/appendix.pdf"),
            current: NavEntry(pageIndex: 10),
            inNewTab: false
        )

        #expect(model.tabs.count == 2)
        #expect(model.tabs[1].pathHint.hasSuffix("appendix.pdf"))
        #expect(model.tabs[1].pageIndex == 7)
    }

    @Test func backReturnsToPushedPositionThenForwardRestores() {
        let (model, id, controller) = makeModelWithTab()

        model.linkActivated(
            target: NavEntry(pageIndex: 250),
            remoteFileURL: nil,
            current: NavEntry(pageIndex: 10),
            inNewTab: false
        )
        #expect(model.canGoBack)

        model.goBack()
        #expect(controller.executed.last == NavEntry(pageIndex: 10))
        #expect(model.canGoForward)
        #expect(!model.canGoBack)

        model.goForward()
        #expect(controller.executed.last == NavEntry(pageIndex: 250))
        let tab = model.tabs.first { $0.id == id }!
        #expect(tab.pageIndex == 250)
    }

    @Test func chromeJumpPushesHistory() {
        let (model, id, controller) = makeModelWithTab()

        model.jump(to: NavEntry(pageIndex: 99))
        #expect(controller.executed.last == NavEntry(pageIndex: 99))
        let tab = model.tabs.first { $0.id == id }!
        #expect(tab.history.canGoBack)

        model.goBack()
        #expect(controller.executed.last == NavEntry(pageIndex: 10))
    }

    @Test func backWithNoHistoryIsNoOp() {
        let (model, _, controller) = makeModelWithTab()
        model.goBack()
        model.goForward()
        #expect(controller.executed.isEmpty)
    }
}
#endif
