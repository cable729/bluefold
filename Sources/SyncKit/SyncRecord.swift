import Foundation

/// A transport-level field value: CloudKit-representable scalars only.
public enum SyncValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int64)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        }
    }
}

/// One record on the wire. `name` is the record's identity — deterministic,
/// minted identically on every device, and treated as OPAQUE everywhere else
/// (long names are hashed, so nothing may parse them; the shadow table maps
/// names back to their content).
public struct SyncRecord: Codable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var fields: [String: SyncValue]

    public init(name: String, type: String, fields: [String: SyncValue]) {
        self.name = name
        self.type = type
        self.fields = fields
    }
}
