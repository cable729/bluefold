#if os(macOS)
import Foundation
import ReaderPersistence
import Testing

@testable import ReaderUI

@Suite("Tag colors")
struct TagColorTests {

    // MARK: Hex parsing

    @Test func parsesWellFormedHex() throws {
        let components = try #require(TagColor.components(fromHex: "#E05252"))
        #expect(abs(components.0 - 224.0 / 255) < 0.001)
        #expect(abs(components.1 - 82.0 / 255) < 0.001)
        #expect(abs(components.2 - 82.0 / 255) < 0.001)
        // Case-insensitive, and Color construction succeeds.
        #expect(TagColor.color(fromHex: "#e05252") != nil)
        #expect(TagColor.color(fromHex: "#FFFFFF") != nil)
        #expect(TagColor.color(fromHex: "#000000") != nil)
    }

    @Test func malformedHexDegradesToColorless() {
        // Synced data could hold anything; the UI must render it colorless,
        // never crash.
        #expect(TagColor.color(fromHex: nil) == nil)
        #expect(TagColor.color(fromHex: "") == nil)
        #expect(TagColor.color(fromHex: "red") == nil)
        #expect(TagColor.color(fromHex: "E05252") == nil)   // missing #
        #expect(TagColor.color(fromHex: "#FFF") == nil)     // short form
        #expect(TagColor.color(fromHex: "#GGGGGG") == nil)  // non-hex digits
        #expect(TagColor.color(fromHex: "#E0525") == nil)   // 5 digits
        #expect(TagColor.color(fromHex: "#E052521") == nil) // 7 digits
        #expect(TagColor.color(fromHex: "#+05252") == nil)  // sign sneaking in
    }

    @Test func presetsAreValidAndDistinct() {
        #expect(TagColor.presets.count == 8)
        for preset in TagColor.presets {
            #expect(TagColor.color(fromHex: preset.hex) != nil, "\(preset.name)")
        }
        #expect(Set(TagColor.presets.map(\.hex)).count == TagColor.presets.count)
        #expect(Set(TagColor.presets.map(\.name)).count == TagColor.presets.count)
    }

    // MARK: Model flow

    @Test @MainActor func colorFlowsThroughModelToRowsAndChips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagColor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("notes.pdf")
        try Data("notes content".utf8).write(to: pdf)

        let model = LibraryModel(store: try .inMemory())
        model.importPDFs(at: [pdf])
        model.createTag(name: "Algebra")
        let algebra = try #require(model.allTags.first)
        let item = try #require(model.items.first)
        model.toggleTag(algebra, for: item)

        model.setTagColor(id: algebra.id!, color: "#4A84D8")

        // Sidebar rows read tagTree; book-cell chips read itemTags — both
        // must carry the color after one call.
        #expect(model.tagTree.first?.tag.color == "#4A84D8")
        #expect(model.itemTags[item.id]?.first?.color == "#4A84D8")

        // "None" clears it everywhere.
        model.setTagColor(id: algebra.id!, color: nil)
        #expect(model.tagTree.first?.tag.color == nil)
        #expect(model.itemTags[item.id]?.first?.color == nil)
    }
}
#endif
