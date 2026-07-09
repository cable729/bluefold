import Foundation

/// Where the app keeps its own files (session.json, library.db, index.db).
/// `BLUEFOLD_SESSION_DIR` overrides it so tests and XCUITest runs are
/// fully isolated. Cross-platform: on iOS this resolves inside the app
/// sandbox's Application Support directory.
public enum AppDataDirectory {
    public static func url() -> URL {
        if let dir = ProcessInfo.processInfo.environment["BLUEFOLD_SESSION_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = support.appendingPathComponent("Bluefold", isDirectory: true)
        migrateLegacyDirectoryIfNeeded(to: dir, in: support)
        return dir
    }

    /// One-time migration: the app was renamed from PDFReader to Bluefold
    /// (2026-07). Session state, library.db, and index.db live under the
    /// old folder for anyone who ran a pre-rename build.
    private static func migrateLegacyDirectoryIfNeeded(to dir: URL, in support: URL) {
        let fm = FileManager.default
        let legacy = support.appendingPathComponent("PDFReader", isDirectory: true)
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.moveItem(at: legacy, to: dir)
    }
}
