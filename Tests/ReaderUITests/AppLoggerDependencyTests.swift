import Dependencies
import ReaderCore
import Testing
@testable import ReaderUI

/// Wiring contract for the injected instrumentation channel: code reading
/// `@Dependency(\.appLogger)` inside a `withDependencies` scope gets the
/// injected capture sink, and its output is assertable as plain state.
@Suite struct AppLoggerDependencyTests {
    @Test func withDependenciesInjectsCaptureSink() {
        let box = CapturedLogs()
        withDependencies {
            $0.appLogger = .captured(into: box)
        } operation: {
            @Dependency(\.appLogger) var log
            log.debug(.layout, "wired")
            log.info(.viewmode, "also wired")
        }

        #expect(box.messages(.layout) == ["wired"])
        #expect(box.messages(.viewmode) == ["also wired"])
    }

    /// Outside any override the test-default is `.noop`, so suites that don't
    /// care about logging never fail on it (and never write to the real log).
    @Test func defaultTestValueIsNoop() {
        @Dependency(\.appLogger) var log
        log.debug(.layout, "discarded")
    }
}
