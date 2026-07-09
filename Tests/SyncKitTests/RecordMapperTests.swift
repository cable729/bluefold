import Foundation
import ReaderPersistence
import Testing

@testable import SyncKit

@Suite struct RecordMapperTests {
    @Test func bookRoundTrip() {
        let portable = PortableRecord.book(PortableBook(
            key: "cal:uuid-1", calibreUUID: "uuid-1", contentHash: "abc123",
            title: "Linear Algebra Done Right", authors: "Sheldon Axler",
            createdAt: 111, modifiedAt: 222, deletedAt: nil
        ))
        let wire = RecordMapper.syncRecord(from: portable)
        #expect(wire.name == "b|cal:uuid-1")
        #expect(wire.type == "book")
        #expect(RecordMapper.portable(from: wire) == portable)
    }

    @Test func tagPathEscapingRoundTrip() {
        let portable = PortableRecord.tag(PortableTag(
            path: ["Top/ic", "we|ird", "100%"], color: "#FF0000",
            modifiedAt: 5, deletedAt: 9
        ))
        let wire = RecordMapper.syncRecord(from: portable)
        #expect(RecordMapper.portable(from: wire) == portable)
        // The wire path joins with "/" only BETWEEN segments.
        #expect(wire.fields["path"]?.stringValue == "Top%2Fic/we%7Cird/100%25")
    }

    @Test func allTypesRoundTrip() {
        let records: [PortableRecord] = [
            .collection(PortableCollection(path: ["School", "Real Analysis"], kind: "course", modifiedAt: 1, deletedAt: nil)),
            .bookTag(PortableBookTag(bookKey: "sha:beef", tagPath: ["Math"], modifiedAt: 2, deletedAt: 3)),
            .collectionItem(PortableCollectionItem(collectionPath: ["School"], bookKey: "cal:u", sortOrder: 7, modifiedAt: 4, deletedAt: nil)),
            .bookmark(PortableBookmark(bookKey: "sha:beef", page: 12, label: "Thm 1.3", createdAt: 10, modifiedAt: 11, deletedAt: nil)),
            .readingState(PortableReadingState(bookKey: "cal:u", page: 250, updatedAt: 99, device: "Mac")),
        ]
        for record in records {
            let wire = RecordMapper.syncRecord(from: record)
            #expect(RecordMapper.portable(from: wire) == record, "\(wire.type)")
        }
    }

    @Test func longNamesHashDeterministically() {
        let deepPath = (0..<40).map { "segment-number-\($0)-padding-padding" }
        let portable = PortableRecord.tag(PortableTag(path: deepPath, color: nil, modifiedAt: 1, deletedAt: nil))
        let name1 = RecordMapper.name(for: portable)
        let name2 = RecordMapper.name(for: portable)
        #expect(name1 == name2)
        #expect(name1.hasPrefix("t|#"))
        #expect(name1.utf8.count <= 255)
        // Fields still carry the full path, so the record decodes without
        // ever parsing the hashed name.
        let wire = RecordMapper.syncRecord(from: portable)
        #expect(RecordMapper.portable(from: wire) == portable)
    }

    @Test func unknownTypeDecodesToNil() {
        let wire = SyncRecord(name: "x|future", type: "hologram", fields: ["modifiedAt": .int(1)])
        #expect(RecordMapper.portable(from: wire) == nil)
    }

    @Test func syncValueCodableDistinguishesIntAndString() throws {
        let fields: [String: SyncValue] = ["a": .int(42), "b": .string("42")]
        let data = try JSONEncoder().encode(fields)
        let decoded = try JSONDecoder().decode([String: SyncValue].self, from: data)
        #expect(decoded == fields)
    }
}
