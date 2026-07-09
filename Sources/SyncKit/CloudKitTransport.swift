#if canImport(CloudKit)
import CloudKit
import Foundation

/// Whether CloudKit sync can run in this process right now.
public enum SyncAvailability: Sendable, Equatable {
    case available
    /// The build isn't signed with iCloud entitlements (the default until
    /// the owner completes the signing steps in docs/SYNC.md).
    case noEntitlement
    /// Signed and entitled, but no iCloud account is usable.
    case noAccount(String)
    case error(String)

    /// A short human-readable explanation for the Settings UI.
    public var explanation: String? {
        switch self {
        case .available: nil
        case .noEntitlement:
            "This build isn't signed with iCloud entitlements. See docs/SYNC.md."
        case .noAccount(let detail): detail
        case .error(let detail): detail
        }
    }
}

/// CloudKit implementation of `SyncTransport`: the user's private database,
/// one custom record zone. Each wire record travels as a single opaque
/// `payload` field (JSON-encoded `SyncRecord`), so the CloudKit schema is
/// two fields per record type and the codec stays entirely on our side.
///
/// Saves use `.allKeys` (last-writer-wins at the record level): the engine
/// already merges by `modified_at` and fetches before every push, so a rare
/// racing overwrite converges on the next cycle — see DECISIONS.md.
///
/// NOT live-verified yet: requires a provisioned build (owner signing steps
/// pending). Keep changes here conservative until it can run for real.
public final class CloudKitTransport: SyncTransport {
    public static let defaultContainerID = "iCloud.com.cable729.bluefold"
    public static let zoneName = "BluefoldLibrary"

    static let payloadField = "payload"
    static let pushChunkSize = 300

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    public init(containerID: String = CloudKitTransport.defaultContainerID) {
        database = CKContainer(identifier: containerID).privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: - Availability

    /// True when the running binary carries an iCloud container entitlement.
    /// Constructing a CKContainer WITHOUT one raises an Objective-C exception
    /// (uncatchable from Swift), so check this before touching CloudKit.
    public static var hasEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              )
        else { return false }
        return (value as? [String])?.isEmpty == false
        #else
        // iOS builds get the entitlement together with their provisioning
        // profile; a missing profile means an unsigned dev loop where sync
        // stays off.
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #endif
    }

    public static func availability(
        containerID: String = CloudKitTransport.defaultContainerID
    ) async -> SyncAvailability {
        guard hasEntitlement else { return .noEntitlement }
        do {
            let status = try await CKContainer(identifier: containerID).accountStatus()
            switch status {
            case .available:
                return .available
            case .noAccount:
                return .noAccount("No iCloud account is signed in.")
            case .restricted:
                return .noAccount("The iCloud account is restricted.")
            case .temporarilyUnavailable:
                return .noAccount("iCloud is temporarily unavailable — try again later.")
            case .couldNotDetermine:
                return .error("Could not determine iCloud account status.")
            @unknown default:
                return .error("Unknown iCloud account status.")
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - SyncTransport

    public func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        // An unreadable token (e.g. from a future format) falls back to a
        // full fetch, which apply handles idempotently.
        let sinceToken = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        return try await fetchLoop(from: sinceToken)
    }

    private func fetchLoop(from token: CKServerChangeToken?) async throws -> SyncFetchResult {
        var changed: [(record: SyncRecord, tag: String)] = []
        var deleted: [String] = []
        var cursor = token
        let decoder = JSONDecoder()

        while true {
            let response: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )
            do {
                response = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor)
            } catch let error as CKError where error.code == .zoneNotFound {
                // First contact: create the zone; there is nothing to fetch.
                try await ensureZone()
                return SyncFetchResult(changed: [], deleted: [], token: nil)
            } catch let error as CKError where error.code == .changeTokenExpired {
                throw SyncTransportError.tokenExpired
            } catch {
                throw Self.mapped(error)
            }

            for (_, result) in response.modificationResultsByID {
                guard let modification = try? result.get() else { continue }
                let ckRecord = modification.record
                guard let payload = ckRecord[Self.payloadField] as? Data,
                      let record = try? decoder.decode(SyncRecord.self, from: payload)
                else { continue }
                changed.append((record, ckRecord.recordChangeTag ?? ""))
            }
            deleted += response.deletions.map(\.recordID.recordName)

            cursor = response.changeToken
            if !response.moreComing { break }
        }

        let tokenData = try cursor.map {
            try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        return SyncFetchResult(changed: changed, deleted: deleted, token: tokenData)
    }

    public func push(
        saves: [SyncPushSave], deletes: [(name: String, baseTag: String?)]
    ) async throws -> SyncPushResult {
        var result = SyncPushResult()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var savesRemaining = saves
        var deletesRemaining = deletes
        var zoneEnsured = false

        while !savesRemaining.isEmpty || !deletesRemaining.isEmpty {
            let saveChunk = Array(savesRemaining.prefix(Self.pushChunkSize))
            savesRemaining.removeFirst(saveChunk.count)
            let deleteBudget = Self.pushChunkSize - saveChunk.count
            let deleteChunk = Array(deletesRemaining.prefix(max(0, deleteBudget)))
            deletesRemaining.removeFirst(deleteChunk.count)

            let ckRecords: [CKRecord] = try saveChunk.map { save in
                let recordID = CKRecord.ID(recordName: save.record.name, zoneID: zoneID)
                let ckRecord = CKRecord(recordType: save.record.type, recordID: recordID)
                ckRecord[Self.payloadField] = try encoder.encode(save.record) as NSData
                return ckRecord
            }
            let deleteIDs = deleteChunk.map { CKRecord.ID(recordName: $0.name, zoneID: zoneID) }

            let response: (
                saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
                deleteResults: [CKRecord.ID: Result<Void, any Error>]
            )
            do {
                response = try await database.modifyRecords(
                    saving: ckRecords, deleting: deleteIDs,
                    savePolicy: .allKeys, atomically: false
                )
            } catch let error as CKError where error.code == .zoneNotFound && !zoneEnsured {
                try await ensureZone()
                zoneEnsured = true
                savesRemaining = saveChunk + savesRemaining
                deletesRemaining = deleteChunk + deletesRemaining
                continue
            } catch {
                throw Self.mapped(error)
            }

            for (recordID, saveResult) in response.saveResults {
                switch saveResult {
                case .success(let saved):
                    result.saves[recordID.recordName] = .saved(tag: saved.recordChangeTag ?? "")
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .serverRecordChanged,
                       let server = ckError.serverRecord,
                       let payload = server[Self.payloadField] as? Data,
                       let record = try? decoder.decode(SyncRecord.self, from: payload)
                    {
                        result.saves[recordID.recordName] =
                            .conflict(server: record, tag: server.recordChangeTag)
                    } else if let ckError = error as? CKError, ckError.code == .unknownItem {
                        result.saves[recordID.recordName] = .conflict(server: nil, tag: nil)
                    } else {
                        throw Self.mapped(error)
                    }
                }
            }
            for (recordID, deleteResult) in response.deleteResults {
                switch deleteResult {
                case .success:
                    result.deletes[recordID.recordName] = .deleted
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        // Already gone — that's what we wanted.
                        result.deletes[recordID.recordName] = .deleted
                    } else {
                        throw Self.mapped(error)
                    }
                }
            }
        }

        return result
    }

    // MARK: - Helpers

    private func ensureZone() async throws {
        do {
            _ = try await database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: []
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    private static func mapped(_ error: any Error) -> any Error {
        guard let ckError = error as? CKError else { return error }
        switch ckError.code {
        case .notAuthenticated:
            return SyncTransportError.unavailable("No iCloud account is signed in.")
        case .networkUnavailable, .networkFailure:
            return SyncTransportError.unavailable("The network is unavailable.")
        case .quotaExceeded:
            return SyncTransportError.unavailable("iCloud storage is full.")
        case .changeTokenExpired:
            return SyncTransportError.tokenExpired
        default:
            return error
        }
    }
}
#endif
