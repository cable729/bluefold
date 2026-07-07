#if os(macOS)
import Foundation
import ReaderPersistence
import Testing

@testable import ReaderUI

@Suite("Library tags & collections")
@MainActor
struct LibraryTaggingTests {
    private func makeModelWithImports() throws -> (LibraryModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTagging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Content hashing reads raw bytes; these needn't be valid PDFs.
        let homework = dir.appendingPathComponent("homework-3.pdf")
        let notes = dir.appendingPathComponent("lecture-notes.pdf")
        try Data("homework three".utf8).write(to: homework)
        try Data("lecture notes content".utf8).write(to: notes)

        let model = LibraryModel(store: try .inMemory())
        model.importPDFs(at: [homework, notes])
        return (model, dir)
    }

    @Test func importCreatesItemsIdempotently() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { $0.source == .imported })

        // Re-import the same file: no duplicate (content_hash is UNIQUE).
        model.importPDFs(at: [dir.appendingPathComponent("homework-3.pdf")])
        #expect(model.items.count == 2)
    }

    @Test func tagToggleAndScopeFiltering() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.createTag(name: "Algebra")
        let algebra = try #require(model.allTags.first { $0.name == "Algebra" })
        let homework = try #require(model.items.first { $0.title == "homework-3" })

        model.toggleTag(algebra, for: homework)
        #expect(model.hasTag(algebra, item: homework))

        model.filter = .tag(algebra.id!)
        #expect(model.filteredItems.map(\.id) == [homework.id])

        model.toggleTag(algebra, for: homework)
        #expect(!model.hasTag(algebra, item: homework))
        #expect(model.filteredItems.isEmpty)
    }

    @Test func hierarchicalTagScopeIncludesDescendants() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.createTag(name: "Algebra")
        let algebra = try #require(model.allTags.first { $0.name == "Algebra" })
        model.createTag(name: "Linear Algebra", parent: algebra.id)
        let linear = try #require(model.allTags.first { $0.name == "Linear Algebra" })

        let notes = try #require(model.items.first { $0.title == "lecture-notes" })
        model.toggleTag(linear, for: notes)

        // Scoping to the parent finds the child-tagged book.
        model.filter = .tag(algebra.id!)
        #expect(model.filteredItems.map(\.id) == [notes.id])
    }

    @Test func collectionMembershipAndOrdering() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.createCollection(name: "5140 Algebra 2")
        let course = try #require(model.collections.first)
        let homework = try #require(model.items.first { $0.title == "homework-3" })
        let notes = try #require(model.items.first { $0.title == "lecture-notes" })

        model.toggleCollection(course, for: notes)
        model.toggleCollection(course, for: homework)
        #expect(model.isInCollection(course, item: homework))

        model.filter = .collection(course.id!)
        // Insertion order preserved: notes first, then homework.
        #expect(model.filteredItems.map(\.id) == [notes.id, homework.id])

        model.toggleCollection(course, for: notes)
        #expect(model.filteredItems.map(\.id) == [homework.id])
    }

    @Test func overlayTagsMatchSearch() throws {
        let (model, dir) = try makeModelWithImports()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.createTag(name: "CategoryTheory")
        let tag = try #require(model.allTags.first)
        let homework = try #require(model.items.first { $0.title == "homework-3" })
        model.toggleTag(tag, for: homework)

        model.searchText = "categorytheory"
        #expect(model.filteredItems.map(\.id) == [homework.id])
    }
}
#endif
