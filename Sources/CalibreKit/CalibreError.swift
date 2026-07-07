import Foundation

/// Errors thrown by CalibreKit.
public enum CalibreError: Error, Sendable {
    /// No `metadata.db` exists at the expected location in the library root.
    case metadataNotFound(URL)

    /// Copying `metadata.db` to a temporary location failed.
    case copyFailed(underlying: any Error)

    /// A query against the (copied) metadata database failed.
    case queryFailed(underlying: any Error)
}

extension CalibreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .metadataNotFound(let url):
            return "no metadata.db found at \(url.path)"
        case .copyFailed(let underlying):
            return "failed to copy metadata.db: \(underlying)"
        case .queryFailed(let underlying):
            return "metadata query failed: \(underlying)"
        }
    }
}
