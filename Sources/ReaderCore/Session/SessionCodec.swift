import Foundation

public enum SessionCodecError: Error, Equatable {
    /// The file was written by a newer app version; refuse rather than
    /// destroy data we don't understand.
    case unsupportedVersion(found: Int, supported: Int)
    case missingVersion
}

/// Versioned JSON encoder/decoder for `SessionSnapshot`.
///
/// Output is pretty-printed with sorted keys so session files are stable and
/// human-diffable. Decoding peeks at `schemaVersion` first and runs any
/// registered migrations, oldest-first, before the typed decode — so old
/// session files keep working as the schema evolves.
public enum SessionCodec {
    public typealias Migration = @Sendable (inout [String: Any]) -> Void

    /// Migration from version N to N+1, operating on the raw JSON object.
    /// Keyed by the *source* version. Register one when bumping
    /// `SessionSnapshot.currentSchemaVersion`.
    public static let migrations: [Int: Migration] = [:]

    public static func encode(_ snapshot: SessionSnapshot) throws -> Data {
        var snapshot = snapshot
        snapshot.schemaVersion = SessionSnapshot.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func decode(
        _ data: Data,
        migrations: [Int: Migration] = Self.migrations
    ) throws -> SessionSnapshot {
        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let version = object["schemaVersion"] as? Int else {
            throw SessionCodecError.missingVersion
        }
        let current = SessionSnapshot.currentSchemaVersion
        guard version <= current else {
            throw SessionCodecError.unsupportedVersion(found: version, supported: current)
        }
        var migrated = data
        if version < current {
            for v in version..<current {
                migrations[v]?(&object)
            }
            object["schemaVersion"] = current
            migrated = try JSONSerialization.data(withJSONObject: object)
        }
        return try JSONDecoder().decode(SessionSnapshot.self, from: migrated)
    }
}
