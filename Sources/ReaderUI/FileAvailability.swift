import Foundation

/// Handles iCloud-evicted ("dataless") files: books in an iCloud Drive
/// Calibre library may exist only as placeholders. Opening one directly
/// yields a broken PDFDocument, so every open path goes through here.
/// Cross-platform (Foundation only) — the iOS app uses the same download
/// flow against the user's iCloud Drive Calibre folder.
public enum FileAvailability {
    public enum Status {
        case local
        case downloading
        case notUbiquitous
    }

    public static func status(of url: URL) -> Status {
        // Fresh instance: NSURL caches resource values per object, so
        // polling the same URL can read the pre-download status forever.
        let url = URL(fileURLWithPath: url.path)
        guard
            let values = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey,
            ])
        else { return .notUbiquitous }
        if values.isUbiquitousItem != true {
            return .notUbiquitous
        }
        // .downloaded (bytes on disk, a newer version may exist in the
        // cloud) is openable too — on iOS, document-picker folders can sit
        // there without ever reaching .current.
        let status = values.ubiquitousItemDownloadingStatus
        return (status == .current || status == .downloaded) ? .local : .downloading
    }

    /// True when the file's bytes are on disk and ready to open.
    public static func isLocal(_ url: URL) -> Bool {
        switch status(of: url) {
        case .local: true
        case .downloading: false
        case .notUbiquitous: FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// The sync daemon's recorded failure for this item, if downloading it
    /// has already failed (auth, quota, missing on server, …).
    private static func downloadError(of url: URL) -> Error? {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
        return values?.ubiquitousItemDownloadingError
    }

    /// Triggers download of an evicted file and waits (polling) until its
    /// bytes are local. Fast no-op when already local.
    public static func ensureLocal(_ url: URL, timeout: TimeInterval = 120) async throws {
        if isLocal(url) { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        // On iOS, a bare download request for a file inside a
        // document-picker folder can be ignored; a coordinated read is the
        // documented way to make the file provider materialize the bytes.
        // It blocks until the download finishes, so it runs off-pool and is
        // cancelled once polling settles the question either way.
        // nonisolated(unsafe): NSFileCoordinator isn't Sendable, but
        // cancel() is documented thread-safe.
        nonisolated(unsafe) let coordinator = NSFileCoordinator(filePresenter: nil)
        DispatchQueue.global(qos: .utility).async {
            var coordinationError: NSError?
            coordinator.coordinate(
                readingItemAt: url, options: .withoutChanges, error: &coordinationError
            ) { _ in }
        }
        defer { coordinator.cancel() }

        let deadline = Date(timeIntervalSinceNow: timeout)
        var lastRequest = Date()
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(400))
            if isLocal(url) { return }
            if let error = downloadError(of: url) {
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedDescriptionKey:
                        "iCloud couldn't download \(url.lastPathComponent): "
                        + error.localizedDescription,
                    NSUnderlyingErrorKey: error,
                ])
            }
            // Re-request occasionally: a single request can be dropped when
            // the sync daemon is busy or restarts mid-wait.
            if Date().timeIntervalSince(lastRequest) > 10 {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                lastRequest = Date()
            }
        }
        throw CocoaError(.fileReadUnknown, userInfo: [
            NSLocalizedDescriptionKey: "Timed out downloading \(url.lastPathComponent) from iCloud."
        ])
    }
}
