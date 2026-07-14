import Foundation
import Testing
@testable import ReaderCore

/// The instrumentation contract: `AppLogger.captured(into:)` records every
/// entry (level, category, rendered message) so feature tests can assert that
/// code under test actually instrumented its inputs and outputs — state
/// assertions on the sink, per docs/TESTING.md, not call-count mocking.
@Suite struct AppLoggerTests {
    @Test func capturedSinkRecordsEntriesInOrder() {
        let box = CapturedLogs()
        let log = AppLogger.captured(into: box)

        log.debug(.layout, "fit vp=(800.0, 600.0) page=(469.0, 616.0) → scale=1.66")
        log.info(.viewmode, "mode single→twoUp page=12")
        log.error(.session, "restore failed")

        #expect(box.entries == [
            .init(level: .debug, category: .layout,
                  message: "fit vp=(800.0, 600.0) page=(469.0, 616.0) → scale=1.66"),
            .init(level: .info, category: .viewmode, message: "mode single→twoUp page=12"),
            .init(level: .error, category: .session, message: "restore failed"),
        ])
    }

    @Test func messagesFiltersByCategory() {
        let box = CapturedLogs()
        let log = AppLogger.captured(into: box)

        log.debug(.layout, "a")
        log.debug(.trim, "b")
        log.notice(.layout, "c")

        #expect(box.messages(.layout) == ["a", "c"])
        #expect(box.messages(.nav).isEmpty)
    }

    /// The capture sink must be safe under concurrent writers (view code logs
    /// from main, background precompute logs from its queue).
    @Test func capturedSinkIsThreadSafe() async {
        let box = CapturedLogs()
        let log = AppLogger.captured(into: box)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { log.debug(.layout, "entry \(i)") }
            }
        }

        #expect(box.entries.count == 100)
    }

    /// Live smoke: constructing the real logger and writing through it must
    /// not trap. (What unified logging does with it is `scripts/logs.sh`
    /// territory, verified live — not assertable from a test process.)
    @Test func liveLoggerAcceptsAllLevelsAndCategories() {
        let log = AppLogger.live()
        for category in AppLogger.Category.allCases {
            log.debug(category, "test-debug")
            log.info(category, "test-info")
            log.notice(category, "test-notice")
            log.error(category, "test-error")
        }
    }

    @Test func noopDiscards() {
        // Compiles, runs, does nothing — the safe test-default.
        AppLogger.noop.debug(.layout, "dropped")
    }
}
