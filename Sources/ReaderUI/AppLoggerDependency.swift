import Dependencies
import ReaderCore

/// swift-dependencies registration for the app's instrumentation channel.
///
/// Usage in ReaderUI types (including plain classes and @Observable models —
/// use `@ObservationIgnored` in the latter):
///
///     @Dependency(\.appLogger) var log
///     log.debug(.layout, "fitWidth vp=\(viewport) page=\(box) → scale=\(scale)")
///
/// Tests: `withDependencies { $0.appLogger = .captured(into: box) } { … }`.
/// The test default is `.noop` so suites that don't assert logging never fail
/// on it; suites that DO care inject a capture sink explicitly.
private enum AppLoggerKey: DependencyKey {
    static let liveValue = AppLogger.live()
    static let testValue = AppLogger.noop
    static let previewValue = AppLogger.noop
}

extension DependencyValues {
    public var appLogger: AppLogger {
        get { self[AppLoggerKey.self] }
        set { self[AppLoggerKey.self] = newValue }
    }
}
