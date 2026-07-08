import Foundation
import ReaderPersistence

/// Process-wide handles to the app's databases. Reader windows and the
/// library window share these (SQLite handles concurrent connections, but
/// one connection per file keeps things simple).
@MainActor
public enum AppStores {
    /// True when running inside a unit-test process (XCTest or
    /// swift-testing). UI-test-LAUNCHED app processes are not test
    /// processes — they must behave like the real app (they isolate via
    /// PDFREADER_SESSION_DIR instead).
    static var isTestProcess: Bool {
        // `swift test` executes suites inside swiftpm-testing-helper;
        // Xcode-hosted runs use an .xctest bundle / config-path env / a
        // loaded XCTest runtime. Cover all of them.
        let arg0 = ProcessInfo.processInfo.arguments.first ?? ""
        return arg0.hasSuffix("swiftpm-testing-helper")
            || arg0.contains(".xctest")
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    public static let library: LibraryStore? = {
        // Unit tests must NEVER touch the user's real library.db.
        // ReaderWindowModel defaults its store to this handle, and test
        // fixtures that forgot to inject `store:` filled a real library
        // with junk book rows via BookResolver auto-registration
        // (2026-07-08). Tests that want a store inject an in-memory one.
        if isTestProcess { return nil }
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
