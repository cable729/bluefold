#if os(macOS)
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("Library open targeting")
@MainActor
struct LibraryOpenTargetingTests {
    private func makeCoordinator() -> SessionCoordinator {
        SessionCoordinator(
            sessionFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("library-open-\(UUID().uuidString).json")
        )
    }

    @Test func opensIntoLastFocusedWindow() {
        let coordinator = makeCoordinator()
        let a = UUID()
        let b = UUID()
        let modelA = coordinator.model(for: a)
        let modelB = coordinator.model(for: b)
        modelA.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        modelB.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))

        coordinator.noteWindowFocused(a)
        let result = coordinator.openInReader(fileURL: URL(fileURLWithPath: "/tmp/new.pdf"))

        #expect(result == nil)
        #expect(modelA.tabs.count == 2)
        #expect(modelB.tabs.count == 1)
        #expect(modelA.tabs.last?.pathHint.hasSuffix("new.pdf") == true)
    }

    @Test func fallsBackToNewestWindowWhenFocusUnknown() {
        let coordinator = makeCoordinator()
        _ = coordinator.model(for: UUID())
        let newest = coordinator.model(for: UUID())

        let result = coordinator.openInReader(fileURL: URL(fileURLWithPath: "/tmp/x.pdf"))
        #expect(result == nil)
        #expect(newest.tabs.count == 1)
    }

    @Test func stagesNewWindowWhenNoneExist() {
        let coordinator = makeCoordinator()
        let result = coordinator.openInReader(fileURL: URL(fileURLWithPath: "/tmp/x.pdf"))

        let newID = try! #require(result)
        let staged = coordinator.model(for: newID)
        #expect(staged.tabs.count == 1)
        #expect(staged.tabs[0].pathHint.hasSuffix("x.pdf"))
    }
}

@Suite("Library filtering")
@MainActor
struct LibraryFilteringTests {
    private func makeItems() -> [LibraryItem] {
        [
            LibraryItem(
                id: "1", source: .calibre(uuid: "1"),
                title: "Linear Algebra Done Right", authors: ["Sheldon Axler"],
                calibreTags: ["Mathematics"], fileURL: URL(fileURLWithPath: "/tmp/a.pdf"),
                coverURL: nil
            ),
            LibraryItem(
                id: "2", source: .calibre(uuid: "2"),
                title: "Algebraic Topology", authors: ["Allen Hatcher"],
                calibreTags: ["Topology"], fileURL: URL(fileURLWithPath: "/tmp/b.pdf"),
                coverURL: nil
            ),
        ]
    }

    @Test func filtersAcrossTitleAuthorAndTag() {
        let model = LibraryModel()
        model.setItemsForTesting(makeItems())

        model.searchText = "axler"
        #expect(model.filteredItems.map(\.id) == ["1"])

        model.searchText = "topology"
        #expect(model.filteredItems.map(\.id) == ["2"])

        model.searchText = "algebra"
        #expect(model.filteredItems.count == 2)

        model.searchText = "  "
        #expect(model.filteredItems.count == 2)
    }
}
#endif
