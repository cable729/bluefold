import CryptoKit
import Foundation
import ReaderPersistence

/// Maps between `PortableRecord` (natural-key rows) and `SyncRecord` (wire
/// records). Record names are deterministic so every device mints the same
/// name for the same logical row — no dedup pass is ever needed. Fields carry
/// ALL identity data redundantly; names are pure identity and never parsed.
public enum RecordMapper {
    public enum RecordType {
        public static let book = "book"
        public static let tag = "tag"
        public static let collection = "collection"
        public static let bookTag = "bookTag"
        public static let collectionItem = "collectionItem"
        public static let bookmark = "bookmark"
        public static let readingState = "readingState"
    }

    // MARK: - Record names

    /// CloudKit caps record names at 255 bytes; anything longer collapses to
    /// a type-prefixed SHA-256 of the logical name (still deterministic).
    static let maxNameBytes = 250

    static func recordName(prefix: String, key: String) -> String {
        let full = prefix + "|" + key
        guard full.utf8.count > maxNameBytes else { return full }
        let digest = SHA256.hash(data: Data(full.utf8))
        return prefix + "|#" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Escapes a path segment so "/" can join segments unambiguously.
    static func escape(_ segment: String) -> String {
        segment
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "|", with: "%7C")
    }

    static func unescape(_ segment: String) -> String {
        segment
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%25", with: "%")
    }

    static func joined(_ path: [String]) -> String {
        path.map(escape).joined(separator: "/")
    }

    static func split(_ joined: String) -> [String] {
        joined.split(separator: "/", omittingEmptySubsequences: false).map { unescape(String($0)) }
    }

    public static func name(for record: PortableRecord) -> String {
        switch record {
        case .book(let p):
            recordName(prefix: "b", key: p.key)
        case .tag(let p):
            recordName(prefix: "t", key: joined(p.path))
        case .collection(let p):
            recordName(prefix: "c", key: joined(p.path))
        case .bookTag(let p):
            recordName(prefix: "bt", key: p.bookKey + "|" + joined(p.tagPath))
        case .collectionItem(let p):
            recordName(prefix: "ci", key: joined(p.collectionPath) + "|" + p.bookKey)
        case .bookmark(let p):
            recordName(prefix: "bm", key: p.bookKey + "|\(p.createdAt)|\(p.page)")
        case .readingState(let p):
            recordName(prefix: "rs", key: p.bookKey)
        }
    }

    // MARK: - Portable → wire

    public static func syncRecord(from record: PortableRecord) -> SyncRecord {
        var fields: [String: SyncValue] = [:]
        let type: String
        switch record {
        case .book(let p):
            type = RecordType.book
            fields["key"] = .string(p.key)
            fields["calibreUUID"] = p.calibreUUID.map(SyncValue.string)
            fields["contentHash"] = p.contentHash.map(SyncValue.string)
            fields["title"] = .string(p.title)
            fields["authors"] = p.authors.map(SyncValue.string)
            fields["createdAt"] = p.createdAt.map(SyncValue.int)
            fields["modifiedAt"] = .int(p.modifiedAt)
            fields["deletedAt"] = p.deletedAt.map(SyncValue.int)
        case .tag(let p):
            type = RecordType.tag
            fields["path"] = .string(joined(p.path))
            fields["color"] = p.color.map(SyncValue.string)
            fields["modifiedAt"] = .int(p.modifiedAt)
            fields["deletedAt"] = p.deletedAt.map(SyncValue.int)
        case .collection(let p):
            type = RecordType.collection
            fields["path"] = .string(joined(p.path))
            fields["kind"] = .string(p.kind)
            fields["modifiedAt"] = .int(p.modifiedAt)
            fields["deletedAt"] = p.deletedAt.map(SyncValue.int)
        case .bookTag(let p):
            type = RecordType.bookTag
            fields["bookKey"] = .string(p.bookKey)
            fields["tagPath"] = .string(joined(p.tagPath))
            fields["modifiedAt"] = .int(p.modifiedAt)
            fields["deletedAt"] = p.deletedAt.map(SyncValue.int)
        case .collectionItem(let p):
            type = RecordType.collectionItem
            fields["collectionPath"] = .string(joined(p.collectionPath))
            fields["bookKey"] = .string(p.bookKey)
            fields["sortOrder"] = .int(Int64(p.sortOrder))
            fields["modifiedAt"] = .int(p.modifiedAt)
            fields["deletedAt"] = p.deletedAt.map(SyncValue.int)
        case .bookmark(let p):
            type = RecordType.bookmark
            fields["bookKey"] = .string(p.bookKey)
            fields["page"] = .int(Int64(p.page))
            fields["label"] = p.label.map(SyncValue.string)
            fields["createdAt"] = .int(p.createdAt)
            fields["modifiedAt"] = .int(p.modifiedAt)
            fields["deletedAt"] = p.deletedAt.map(SyncValue.int)
        case .readingState(let p):
            type = RecordType.readingState
            fields["bookKey"] = .string(p.bookKey)
            fields["page"] = .int(Int64(p.page))
            fields["updatedAt"] = .int(p.updatedAt)
            fields["device"] = .string(p.device)
        }
        return SyncRecord(
            name: name(for: record), type: type,
            fields: fields.compactMapValues { $0 }
        )
    }

    // MARK: - Wire → portable

    /// Decodes a wire record; nil for unknown types or missing required
    /// fields (never throws — foreign/newer records are skipped, not fatal).
    public static func portable(from record: SyncRecord) -> PortableRecord? {
        func str(_ key: String) -> String? { record.fields[key]?.stringValue }
        func int(_ key: String) -> Int64? { record.fields[key]?.intValue }

        switch record.type {
        case RecordType.book:
            guard let key = str("key"), let title = str("title"), let modified = int("modifiedAt")
            else { return nil }
            return .book(PortableBook(
                key: key, calibreUUID: str("calibreUUID"), contentHash: str("contentHash"),
                title: title, authors: str("authors"), createdAt: int("createdAt"),
                modifiedAt: modified, deletedAt: int("deletedAt")
            ))
        case RecordType.tag:
            guard let path = str("path"), let modified = int("modifiedAt") else { return nil }
            return .tag(PortableTag(
                path: split(path), color: str("color"),
                modifiedAt: modified, deletedAt: int("deletedAt")
            ))
        case RecordType.collection:
            guard let path = str("path"), let kind = str("kind"), let modified = int("modifiedAt")
            else { return nil }
            return .collection(PortableCollection(
                path: split(path), kind: kind, modifiedAt: modified, deletedAt: int("deletedAt")
            ))
        case RecordType.bookTag:
            guard let bookKey = str("bookKey"), let tagPath = str("tagPath"),
                  let modified = int("modifiedAt")
            else { return nil }
            return .bookTag(PortableBookTag(
                bookKey: bookKey, tagPath: split(tagPath),
                modifiedAt: modified, deletedAt: int("deletedAt")
            ))
        case RecordType.collectionItem:
            guard let path = str("collectionPath"), let bookKey = str("bookKey"),
                  let sortOrder = int("sortOrder"), let modified = int("modifiedAt")
            else { return nil }
            return .collectionItem(PortableCollectionItem(
                collectionPath: split(path), bookKey: bookKey, sortOrder: Int(sortOrder),
                modifiedAt: modified, deletedAt: int("deletedAt")
            ))
        case RecordType.bookmark:
            guard let bookKey = str("bookKey"), let page = int("page"),
                  let created = int("createdAt"), let modified = int("modifiedAt")
            else { return nil }
            return .bookmark(PortableBookmark(
                bookKey: bookKey, page: Int(page), label: str("label"),
                createdAt: created, modifiedAt: modified, deletedAt: int("deletedAt")
            ))
        case RecordType.readingState:
            guard let bookKey = str("bookKey"), let page = int("page"),
                  let updated = int("updatedAt"), let device = str("device")
            else { return nil }
            return .readingState(PortableReadingState(
                bookKey: bookKey, page: Int(page), updatedAt: updated, device: device
            ))
        default:
            return nil
        }
    }
}
