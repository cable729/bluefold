import Foundation

/// One record to save, with the change tag we believe the server has (nil =
/// we think the record is new). Transports MAY use the tag for conflict
/// detection; the CloudKit transport currently saves last-writer-wins because
/// the engine already merges by `modified_at`.
public struct SyncPushSave: Sendable {
    public var record: SyncRecord
    public var baseTag: String?

    public init(record: SyncRecord, baseTag: String?) {
        self.record = record
        self.baseTag = baseTag
    }
}

public enum SyncSaveOutcome: Sendable {
    /// Saved; the server's new change tag.
    case saved(tag: String)
    /// The server had a newer version (or had deleted the record — server
    /// is nil then). The engine merges it and re-pushes if local still wins.
    case conflict(server: SyncRecord?, tag: String?)
}

public enum SyncDeleteOutcome: Sendable {
    case deleted
    /// The server version changed since we last saw it; here's its record.
    case conflict(server: SyncRecord?, tag: String?)
}

public struct SyncPushResult: Sendable {
    /// Keyed by record name.
    public var saves: [String: SyncSaveOutcome]
    public var deletes: [String: SyncDeleteOutcome]

    public init(saves: [String: SyncSaveOutcome] = [:], deletes: [String: SyncDeleteOutcome] = [:]) {
        self.saves = saves
        self.deletes = deletes
    }
}

public struct SyncFetchResult: Sendable {
    /// Changed records with their server change tags.
    public var changed: [(record: SyncRecord, tag: String)]
    /// Names of records deleted on the server.
    public var deleted: [String]
    /// Opaque resume token to persist for the next fetch.
    public var token: Data?

    public init(changed: [(record: SyncRecord, tag: String)], deleted: [String], token: Data?) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
    }
}

/// The seam between the sync engine and the wire. Production: CloudKit
/// private database. Tests: `FakeTransport` (an in-memory server).
public protocol SyncTransport: Sendable {
    /// All changes since `token` (nil = everything).
    func fetchChanges(since token: Data?) async throws -> SyncFetchResult
    /// Pushes saves and deletes; per-record outcomes.
    func push(saves: [SyncPushSave], deletes: [(name: String, baseTag: String?)]) async throws -> SyncPushResult
}

/// Errors a transport can raise that the engine understands specially.
public enum SyncTransportError: Error, Sendable {
    /// The server's change token is no longer valid — the engine must reset
    /// its token (and will re-fetch everything; apply is idempotent).
    case tokenExpired
    /// Sync backend not reachable/usable right now (offline, no account…).
    case unavailable(String)
}
