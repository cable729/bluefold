#if os(macOS)
import Foundation
import ReaderPersistence

/// Process-wide handles to the app's databases. Reader windows and the
/// library window share these (SQLite handles concurrent connections, but
/// one connection per file keeps things simple).
@MainActor
public enum AppStores {
    public static let library: LibraryStore? = {
        do {
            let dir = AppDataDirectory.url()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try LibraryStore(path: dir.appendingPathComponent("library.db").path)
        } catch {
            NSLog("PDFReader: library store unavailable: \(error)")
            return nil
        }
    }()
}
#endif
