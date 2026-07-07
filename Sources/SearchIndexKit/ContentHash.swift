import CryptoKit
import Foundation

/// Content-based identity for a PDF file, stable across moves and renames.
///
/// The hash is SHA-256 over the first 128 KiB of the file's bytes followed by
/// the file size as a little-endian UInt64. Reading only the head is
/// deliberate: textbooks can be hundreds of megabytes, and the head + exact
/// size is more than enough to distinguish real-world documents.
public enum ContentHash {
    /// Number of leading bytes hashed.
    public static let headByteCount = 128 * 1024

    /// Returns the lowercase hex SHA-256 of (first 128 KiB || LE UInt64 size).
    public static func compute(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let head = try handle.read(upToCount: headByteCount) ?? Data()
        let fileSize = try handle.seekToEnd()

        var hasher = SHA256()
        hasher.update(data: head)
        withUnsafeBytes(of: fileSize.littleEndian) { buffer in
            hasher.update(bufferPointer: buffer)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
