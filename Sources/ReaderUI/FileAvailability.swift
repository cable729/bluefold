#if os(macOS)
import Foundation

/// Handles iCloud-evicted ("dataless") files: books in an iCloud Drive
/// Calibre library may exist only as placeholders. Opening one directly
/// yields a broken PDFDocument, so every open path goes through here.
enum FileAvailability {
    enum Status {
        case local
        case downloading
        case notUbiquitous
    }

    static func status(of url: URL) -> Status {
        guard
            let values = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey,
            ])
        else { return .notUbiquitous }
        if values.isUbiquitousItem != true {
            return .notUbiquitous
        }
        return values.ubiquitousItemDownloadingStatus == .current ? .local : .downloading
    }

    /// True when the file's bytes are on disk and ready to open.
    static func isLocal(_ url: URL) -> Bool {
        switch status(of: url) {
        case .local: true
        case .downloading: false
        case .notUbiquitous: FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Triggers download of an evicted file and waits (polling) until its
    /// bytes are local. Fast no-op when already local.
    static func ensureLocal(_ url: URL, timeout: TimeInterval = 120) async throws {
        if isLocal(url) { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(400))
            if isLocal(url) { return }
        }
        throw CocoaError(.fileReadUnknown, userInfo: [
            NSLocalizedDescriptionKey: "Timed out downloading \(url.lastPathComponent) from iCloud."
        ])
    }
}
#endif
