import Foundation

@testable import SyncKit

/// An in-memory "server": versioned records, a monotonic change sequence for
/// fetch tokens, and real conflict detection on push (unlike CloudKit's
/// last-writer-wins mode, so the engine's conflict paths get exercised).
actor FakeTransport: SyncTransport {
    struct Stored {
        var record: SyncRecord
        var tag: Int
        var seq: Int
    }

    private var records: [String: Stored] = [:]
    private var deletions: [String: Int] = [:]  // name → seq of the delete
    private var seq = 0
    /// When true, every fetch throws tokenExpired once (then self-clears).
    var expireNextToken = false

    var recordCount: Int { records.count }

    func setExpireNextToken() {
        expireNextToken = true
    }

    func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        if expireNextToken {
            expireNextToken = false
            if token != nil { throw SyncTransportError.tokenExpired }
        }
        let sinceSeq = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? -1
        let changed = records.values
            .filter { $0.seq > sinceSeq }
            .sorted { $0.seq < $1.seq }
            .map { (record: $0.record, tag: String($0.tag)) }
        let deleted = deletions
            .filter { $0.value > sinceSeq }
            .map(\.key)
        return SyncFetchResult(changed: changed, deleted: deleted, token: Data(String(seq).utf8))
    }

    func push(
        saves: [SyncPushSave], deletes: [(name: String, baseTag: String?)]
    ) async throws -> SyncPushResult {
        var result = SyncPushResult()
        for save in saves {
            let name = save.record.name
            if let existing = records[name], String(existing.tag) != save.baseTag {
                result.saves[name] = .conflict(server: existing.record, tag: String(existing.tag))
                continue
            }
            if records[name] == nil, save.baseTag != nil {
                // We thought the server had it but it's gone.
                result.saves[name] = .conflict(server: nil, tag: nil)
                continue
            }
            seq += 1
            let tag = (records[name]?.tag ?? 0) + 1
            records[name] = Stored(record: save.record, tag: tag, seq: seq)
            deletions.removeValue(forKey: name)
            result.saves[name] = .saved(tag: String(tag))
        }
        for (name, baseTag) in deletes {
            if let existing = records[name], String(existing.tag) != baseTag {
                result.deletes[name] = .conflict(server: existing.record, tag: String(existing.tag))
                continue
            }
            if records[name] != nil {
                records.removeValue(forKey: name)
                seq += 1
                deletions[name] = seq
            }
            result.deletes[name] = .deleted
        }
        return result
    }

    /// Test helper: server-side record inspection by name.
    func record(named name: String) -> SyncRecord? {
        records[name]?.record
    }
}
