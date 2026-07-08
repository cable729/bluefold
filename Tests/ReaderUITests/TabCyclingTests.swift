#if os(macOS)
import Foundation
import Testing

@testable import ReaderUI

@Suite("Tab cycling")
@MainActor
struct TabCyclingTests {
    private func makeModel() -> ReaderWindowModel {
        ReaderWindowModel(provider: DocumentProvider(capacity: 3))
    }

    @Test func nextTabWrapsAround() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))
        model.selectTab(id: a)

        model.selectNextTab()
        #expect(model.activeTabID == b)
        model.selectNextTab()
        #expect(model.activeTabID == c)
        model.selectNextTab()
        #expect(model.activeTabID == a)  // wraps
    }

    @Test func previousTabWrapsAround() {
        let model = makeModel()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        let c = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/c.pdf"))
        model.selectTab(id: a)

        model.selectPreviousTab()
        #expect(model.activeTabID == c)  // wraps
        model.selectPreviousTab()
        #expect(model.activeTabID == b)
        model.selectPreviousTab()
        #expect(model.activeTabID == a)
    }

    @Test func singleTabIsANoOp() {
        let model = makeModel()
        let only = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.selectNextTab()
        #expect(model.activeTabID == only)
        model.selectPreviousTab()
        #expect(model.activeTabID == only)
    }

    @Test func noTabsIsANoOp() {
        let model = makeModel()
        model.selectNextTab()
        model.selectPreviousTab()
        #expect(model.activeTabID == nil)
    }

    @Test func cyclingPinsTheNewActiveDocument() {
        let model = makeModel()
        _ = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.selectNextTab()  // b -> a (wrap)
        let activePath = model.tabs.first { $0.id == model.activeTabID }!.pathHint
        #expect(model.provider.pinnedPaths == [activePath])
        _ = b
    }
}
#endif
