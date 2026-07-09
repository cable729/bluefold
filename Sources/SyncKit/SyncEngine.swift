import Foundation
import ReaderPersistence

/// What one `sync()` did — for status UI and logging.
public struct SyncSummary: Sendable, Equatable {
    public var fetchedChanges = 0
    public var fetchedDeletes = 0
    /// Remote rows written locally (remote won LWW or was new).
    public var appliedChanges = 0
    /// Remote rows skipped because local was same-or-newer.
    public var localWins = 0
    public var appliedDeletes = 0
    public var pushedSaves = 0
    public var pushedDeletes = 0
    /// Push conflicts resolved by merging the server version.
    public var conflicts = 0
    /// Records still waiting for their endpoints (retried next sync).
    public var pendingCount = 0
    /// Push rounds used (a round can be triggered by conflict merges).
    public var rounds = 0

    public init() {}
}

/// The sync orchestrator (M15): shadow-diff push, fetch-then-apply with
/// last-writer-wins by `modified_at` (reading state: max `updated_at`).
///
/// State model per record name:
/// - local DB: the truth on this device (exported via `syncExport`)
/// - shadow: the last server-confirmed wire record (diff base + the ONLY
///   name → content resolver, since long record names are hashed)
/// - server: reached only through `SyncTransport`
///
/// A record differing from its shadow pushes; a shadow entry with no local
/// counterpart pushes a delete (tombstone purges propagate as real deletes —
/// soft deletes travel as records with `deletedAt` set). Fetched records
/// apply LWW and always refresh the shadow, so a losing local edit stays
/// diffed and re-pushes.
public actor SyncEngine {
    private let store: LibraryStore
    private let transport: SyncTransport
    private var inFlight: Task<SyncSummary, Error>?

    private static let tokenKey = "changeToken"
    private static let maxPushRounds = 3

    public init(store: LibraryStore, transport: SyncTransport) {
        self.store = store
        self.transport = transport
    }

    /// Runs one full sync cycle. Concurrent calls coalesce onto the cycle
    /// already in flight.
    public func sync() async throws -> SyncSummary {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await performSync() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performSync() async throws -> SyncSummary {
        var summary = SyncSummary()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // 1. Fetch remote changes (token expiry = start over; apply is
        //    idempotent so a full re-fetch is safe).
        let fetch: SyncFetchResult
        do {
            fetch = try await transport.fetchChanges(since: try store.syncMetaGet(Self.tokenKey))
        } catch SyncTransportError.tokenExpired {
            try store.syncMetaSet(Self.tokenKey, nil)
            fetch = try await transport.fetchChanges(since: nil)
        }
        summary.fetchedChanges = fetch.changed.count
        summary.fetchedDeletes = fetch.deleted.count

        let shadowRows = try store.syncShadowAll()
        var shadowByName = Dictionary(uniqueKeysWithValues: shadowRows.map { ($0.name, $0) })

        // 2. Decode: previously-pending records first, fetched ones win on
        //    name collision (they're newer). Fetched versions the shadow
        //    already confirmed (same change tag) are our own push echoes —
        //    applying them would resurrect rows purged/renamed since, so
        //    they are skipped entirely.
        var portablesByName: [String: PortableRecord] = [:]
        for (name, payload) in try store.syncPendingAll() {
            if let record = try? decoder.decode(SyncRecord.self, from: payload),
               let portable = RecordMapper.portable(from: record)
            {
                portablesByName[name] = portable
            }
        }
        var fetchedRecordsByName: [String: (record: SyncRecord, tag: String)] = [:]
        for (record, tag) in fetch.changed {
            if let shadow = shadowByName[record.name], shadow.changeTag == tag { continue }
            guard let portable = RecordMapper.portable(from: record) else { continue }
            portablesByName[record.name] = portable
            fetchedRecordsByName[record.name] = (record, tag)
        }

        // 3. Resolve fetched deletes through the shadow (names are opaque).
        var deletePortables: [PortableRecord] = []
        for name in fetch.deleted {
            portablesByName.removeValue(forKey: name)
            guard let shadow = shadowByName[name],
                  let record = try? decoder.decode(SyncRecord.self, from: shadow.payload),
                  let portable = RecordMapper.portable(from: record)
            else { continue }
            deletePortables.append(portable)
        }

        // 4. Apply, then persist the new shadow/pending/token state.
        let applied = try store.syncApplyRemote(Array(portablesByName.values))
        summary.appliedChanges = applied.applied
        summary.localWins = applied.localWins
        summary.appliedDeletes = try store.syncApplyRemoteDeletes(deletePortables)

        var shadowUpserts: [LibraryStore.SyncShadowRow] = []
        for (name, entry) in fetchedRecordsByName {
            let payload = try encoder.encode(entry.record)
            shadowUpserts.append(.init(name: name, type: entry.record.type, payload: payload, changeTag: entry.tag))
            shadowByName[name] = .init(name: name, type: entry.record.type, payload: payload, changeTag: entry.tag)
        }
        try store.syncShadowUpsert(shadowUpserts)
        try store.syncShadowDelete(names: fetch.deleted)
        for name in fetch.deleted { shadowByName.removeValue(forKey: name) }

        var pendingNames: Set<String> = []
        var pendingRows: [(name: String, payload: Data)] = []
        for portable in applied.pending {
            let record = RecordMapper.syncRecord(from: portable)
            pendingNames.insert(record.name)
            pendingRows.append((record.name, try encoder.encode(record)))
        }
        try store.syncPendingReplace(pendingRows)
        summary.pendingCount = pendingRows.count
        try store.syncMetaSet(Self.tokenKey, fetch.token)

        // 5. Push loop: diff local export against the shadow; conflicts merge
        //    the server version and the next round re-diffs.
        for _ in 0..<Self.maxPushRounds {
            let export = try store.syncExport()
            var localByName: [String: SyncRecord] = [:]
            for portable in export {
                let record = RecordMapper.syncRecord(from: portable)
                localByName[record.name] = record
            }

            var saves: [SyncPushSave] = []
            for (name, record) in localByName {
                if let shadow = shadowByName[name],
                   let shadowRecord = try? decoder.decode(SyncRecord.self, from: shadow.payload),
                   shadowRecord == record
                { continue }
                saves.append(SyncPushSave(record: record, baseTag: shadowByName[name]?.changeTag))
            }
            // A shadow entry with no local row = the row was hard-deleted
            // here (tombstone purge) — propagate a real delete. Pending
            // records are excluded: they exist on the server but can't be
            // applied locally YET; deleting them would destroy remote data.
            let deletes: [(name: String, baseTag: String?)] = shadowByName.keys
                .filter { localByName[$0] == nil && !pendingNames.contains($0) }
                .map { ($0, shadowByName[$0]?.changeTag) }

            guard !saves.isEmpty || !deletes.isEmpty else { break }
            summary.rounds += 1

            let result = try await transport.push(saves: saves, deletes: deletes)

            var conflictPortables: [PortableRecord] = []
            var upserts: [LibraryStore.SyncShadowRow] = []
            var removals: [String] = []

            for save in saves {
                switch result.saves[save.record.name] {
                case .saved(let tag):
                    let payload = try encoder.encode(save.record)
                    upserts.append(.init(name: save.record.name, type: save.record.type, payload: payload, changeTag: tag))
                    shadowByName[save.record.name] = upserts.last
                    summary.pushedSaves += 1
                case .conflict(let server, let tag):
                    summary.conflicts += 1
                    if let server, let portable = RecordMapper.portable(from: server) {
                        conflictPortables.append(portable)
                        let payload = try encoder.encode(server)
                        upserts.append(.init(name: server.name, type: server.type, payload: payload, changeTag: tag))
                        shadowByName[server.name] = upserts.last
                    } else {
                        // Server deleted it; drop the shadow so the local row
                        // re-pushes as a new record next round.
                        removals.append(save.record.name)
                        shadowByName.removeValue(forKey: save.record.name)
                    }
                case nil:
                    continue
                }
            }
            for (name, _) in deletes {
                switch result.deletes[name] {
                case .deleted, nil:
                    removals.append(name)
                    shadowByName.removeValue(forKey: name)
                    if case .deleted = result.deletes[name] { summary.pushedDeletes += 1 }
                case .conflict(let server, let tag):
                    summary.conflicts += 1
                    if let server, let portable = RecordMapper.portable(from: server) {
                        conflictPortables.append(portable)
                        let payload = try encoder.encode(server)
                        upserts.append(.init(name: server.name, type: server.type, payload: payload, changeTag: tag))
                        shadowByName[server.name] = upserts.last
                    } else {
                        removals.append(name)
                        shadowByName.removeValue(forKey: name)
                    }
                }
            }

            try store.syncShadowUpsert(upserts)
            try store.syncShadowDelete(names: removals)

            if conflictPortables.isEmpty {
                break
            }
            let merged = try store.syncApplyRemote(conflictPortables)
            summary.appliedChanges += merged.applied
            summary.localWins += merged.localWins
        }

        return summary
    }
}
