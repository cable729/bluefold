import Foundation
import ReaderPersistence
import Testing

@testable import SyncKit

/// LibraryStore sync-support edge cases (export canonicalization, apply
/// guards) that the engine tests don't reach directly.
@Suite struct SyncStoreTests {
    private func store(at ms: Int64 = 1_000_000) throws -> LibraryStore {
        try LibraryStore.inMemory(now: { ms })
    }

    @Test func exportIncludesTombstonesAsRecords() throws {
        let store = try store()
        let tag = try store.createTag(name: "Gone")
        try store.softDeleteTag(id: tag.id!)
        let tags = try store.syncExport().compactMap { record -> PortableTag? in
            if case .tag(let t) = record { return t } else { return nil }
        }
        #expect(tags.count == 1)
        #expect(tags.first?.deletedAt != nil)
    }

    @Test func duplicateRootTagsExportOnce() throws {
        // The schema's UNIQUE(name, parent_id) cannot stop duplicate ROOT
        // tags (SQL NULLs compare distinct) — export must still mint exactly
        // one record per path, preferring the live row.
        let store = try store()
        let first = try store.createTag(name: "Dup")
        _ = try store.createTag(name: "Dup")
        try store.softDeleteTag(id: first.id!)

        let tags = try store.syncExport().compactMap { record -> PortableTag? in
            if case .tag(let t) = record { return t } else { return nil }
        }
        #expect(tags.count == 1)
        #expect(tags.first?.deletedAt == nil)  // the live row won
    }

    @Test func applySkipsOlderRemote() throws {
        let store = try store(at: 5_000)
        _ = try store.createTag(name: "Mine")
        let older = PortableRecord.tag(PortableTag(
            path: ["Mine"], color: "#123456", modifiedAt: 4_000, deletedAt: nil
        ))
        let result = try store.syncApplyRemote([older])
        #expect(result.localWins == 1)
        #expect(try store.tagTree().first?.tag.color == nil)
    }

    @Test func applyWritesRemoteTimestampsVerbatim() throws {
        let store = try store(at: 5_000)
        let remote = PortableRecord.tag(PortableTag(
            path: ["Theirs"], color: nil, modifiedAt: 99_000, deletedAt: nil
        ))
        _ = try store.syncApplyRemote([remote])
        let tag = try #require(try store.tagTree().first?.tag)
        #expect(tag.modifiedAt == 99_000)  // NOT the local clock's 5_000
    }

    @Test func calibreTwinIdentityNeverMergesRows() throws {
        // A local loose book (sha) and an incoming Calibre record carrying
        // the SAME content hash must stay two rows — merging them is an
        // owner decision that sync must not make.
        let store = try store()
        _ = try store.insertLooseBook(contentHash: "samehash", title: "Loose", pathHint: "/l.pdf")
        let remote = PortableRecord.book(PortableBook(
            key: "cal:u9", calibreUUID: "u9", contentHash: "samehash", title: "Calibre Copy",
            authors: nil, createdAt: 2_000_000, modifiedAt: 2_000_000, deletedAt: nil
        ))
        _ = try store.syncApplyRemote([remote])

        let books = try store.allBooks()
        #expect(books.count == 2)
        let calibreRow = try #require(books.first { $0.calibreUUID == "u9" })
        // The colliding hash stayed off the new row.
        #expect(calibreRow.contentHash == nil)
        #expect(try store.allBooks().filter { $0.contentHash == "samehash" }.count == 1)
    }

    @Test func remoteHashBackfillTravelsWhenUnique() throws {
        let store = try store()
        _ = try store.upsertCalibreBook(uuid: "u1", title: "Book")
        let remote = PortableRecord.book(PortableBook(
            key: "cal:u1", calibreUUID: "u1", contentHash: "fresh", title: "Book",
            authors: nil, createdAt: nil, modifiedAt: 9_000_000, deletedAt: nil
        ))
        _ = try store.syncApplyRemote([remote])
        #expect(try store.allBooks().first { $0.calibreUUID == "u1" }?.contentHash == "fresh")
    }

    @Test func missingAncestorsAreCreatedOnApply() throws {
        let store = try store()
        let deep = PortableRecord.tag(PortableTag(
            path: ["A", "B", "C"], color: nil, modifiedAt: 3_000, deletedAt: nil
        ))
        _ = try store.syncApplyRemote([deep])
        let tree = try store.tagTree()
        #expect(tree.first?.tag.name == "A")
        #expect(tree.first?.children.first?.tag.name == "B")
        #expect(tree.first?.children.first?.children.first?.tag.name == "C")
    }

    @Test func hardDeleteSkipsTagWithLiveChildren() throws {
        let store = try store()
        let parent = try store.createTag(name: "Parent")
        _ = try store.createTag(name: "Child", parent: parent.id!)
        let deleted = try store.syncApplyRemoteDeletes([
            .tag(PortableTag(path: ["Parent"], color: nil, modifiedAt: 1, deletedAt: nil))
        ])
        #expect(deleted == 0)
        #expect(try store.tagTree().first?.tag.name == "Parent")
    }

    @Test func syncStateResetClearsEverything() throws {
        let store = try store()
        try store.syncMetaSet("changeToken", Data([1, 2, 3]))
        try store.syncShadowUpsert([.init(name: "n", type: "tag", payload: Data([9]), changeTag: "1")])
        try store.syncPendingReplace([("p", Data([8]))])
        try store.syncStateReset()
        #expect(try store.syncMetaGet("changeToken") == nil)
        #expect(try store.syncShadowAll().isEmpty)
        #expect(try store.syncPendingAll().isEmpty)
    }
}
