import Foundation

/// Where the app keeps its own files (session.json, library.db, index.db).
/// `PDFREADER_SESSION_DIR` overrides it so tests and XCUITest runs are
/// fully isolated. Cross-platform: on iOS this resolves inside the app
/// sandbox's Application Support directory.
public enum AppDataDirectory {
    public static func url() -> URL {
        if let dir = ProcessInfo.processInfo.environment["PDFREADER_SESSION_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return support.appendingPathComponent("PDFReader", isDirectory: true)
    }
}
