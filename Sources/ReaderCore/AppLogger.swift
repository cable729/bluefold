import Foundation
import os

/// The app's instrumentation channel, as an injectable value (struct-of-
/// closures — the house DI style, see docs/TESTING.md).
///
/// The live logger writes to unified logging (subsystem
/// `com.cable729.bluefold`, one `os.Logger` per category), which is what
/// `scripts/logs.sh` reads back after a run. Messages ride at .debug/.info —
/// NOT persisted by default; `scripts/logs.sh mac setup` arms persistence.
/// Values are logged `.public` (geometry and state, never user data).
///
/// Tests inject `.captured(into:)` and assert that instrumentation actually
/// fired (state assertion on the captured entries, not call-count mocking).
public struct AppLogger: Sendable {
    /// Feature areas — one unified-logging category each, so
    /// `logs.sh mac show 5 layout` can filter to a single concern.
    public enum Category: String, CaseIterable, Sendable {
        case layout
        case viewmode
        case trim
        case nav
        case session
    }

    public enum Level: Int, Comparable, Sendable {
        case debug, info, notice, error

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Entry: Equatable, Sendable {
        public var level: Level
        public var category: Category
        public var message: String

        public init(level: Level, category: Category, message: String) {
            self.level = level
            self.category = category
            self.message = message
        }
    }

    /// The single primitive; everything else is convenience over it.
    /// The message is autoclosure-free by design: call sites are expected to
    /// interpolate real numbers (inputs AND computed outputs), and capture in
    /// tests needs the rendered string anyway.
    public var log: @Sendable (Level, Category, String) -> Void

    public init(log: @escaping @Sendable (Level, Category, String) -> Void) {
        self.log = log
    }

    public func debug(_ category: Category, _ message: String) {
        log(.debug, category, message)
    }

    public func info(_ category: Category, _ message: String) {
        log(.info, category, message)
    }

    public func notice(_ category: Category, _ message: String) {
        log(.notice, category, message)
    }

    public func error(_ category: Category, _ message: String) {
        log(.error, category, message)
    }
}

extension AppLogger {
    /// The unified-logging subsystem. Keep in sync with
    /// PRODUCT_BUNDLE_IDENTIFIER and scripts/logs.sh.
    public static let subsystem = "com.cable729.bluefold"

    /// Live implementation: one cached `os.Logger` per category.
    public static func live() -> AppLogger {
        let loggers = Dictionary(
            uniqueKeysWithValues: Category.allCases.map {
                ($0, Logger(subsystem: subsystem, category: $0.rawValue))
            }
        )
        return AppLogger { level, category, message in
            guard let logger = loggers[category] else { return }
            // `.public`: this channel carries geometry/state, never user data.
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .notice: logger.notice("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
        }
    }

    /// Discards everything. The default for tests that don't assert logging.
    public static let noop = AppLogger { _, _, _ in }

    /// Test implementation: appends every entry to `box` for state assertions.
    public static func captured(into box: CapturedLogs) -> AppLogger {
        AppLogger { level, category, message in
            box.append(Entry(level: level, category: category, message: message))
        }
    }
}

/// Thread-safe capture sink for `AppLogger.captured(into:)`.
/// (ReaderCore stays dependency-free, so this is a tiny hand-rolled
/// LockIsolated rather than an import.)
public final class CapturedLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppLogger.Entry] = []

    public init() {}

    public var entries: [AppLogger.Entry] {
        lock.withLock { storage }
    }

    func append(_ entry: AppLogger.Entry) {
        lock.withLock { storage.append(entry) }
    }

    /// Entries for one category, rendered messages only — the common assert.
    public func messages(_ category: AppLogger.Category) -> [String] {
        lock.withLock { storage.filter { $0.category == category }.map(\.message) }
    }
}
