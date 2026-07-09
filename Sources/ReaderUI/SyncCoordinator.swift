import Foundation
import Observation
import ReaderPersistence
import SyncKit

/// Owns the app's sync lifecycle (M15): starts/stops the engine as the
/// Settings toggle flips, runs a cycle at launch and every 15 minutes while
/// enabled, exposes status for the Settings window, and nudges the library
/// UI after remote changes land.
///
/// Sync stays inert unless ALL of: the toggle is on, the build carries
/// iCloud entitlements (see docs/SYNC.md — not the case for unsigned dev
/// builds), and an iCloud account is signed in. `status` always says which
/// condition failed, so the Settings UI never shows a dead toggle silently.
@MainActor
@Observable
public final class SyncCoordinator {
    public static let shared = SyncCoordinator()

    public enum Status: Equatable, Sendable {
        case disabled
        /// Enabled but can't run (no entitlement / no account / error).
        case unavailable(String)
        case idle(lastSync: Date?)
        case syncing
        case error(String)

        public var isSyncable: Bool {
            switch self {
            case .idle, .syncing, .error: true
            case .disabled, .unavailable: false
            }
        }
    }

    public private(set) var status: Status = .disabled
    public private(set) var lastSummary: SyncSummary?

    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let syncInterval: Duration

    /// Tests inject settings and drive `start`/`stop` directly; the shared
    /// instance wires itself to `AppSettings.shared` and is started by the
    /// app delegate at launch.
    public init(settings: AppSettings = .shared, syncInterval: Duration = .seconds(15 * 60)) {
        self.settings = settings
        self.syncInterval = syncInterval
        settings.onSyncEnabledChange = { [weak self] enabled in
            if enabled {
                self?.start()
            } else {
                self?.stop()
            }
        }
    }

    /// Launch entry point: engages only when the user already enabled sync.
    public func startIfEnabled() {
        guard settings.syncEnabled else { return }
        start()
    }

    /// Checks availability, builds the engine, runs one cycle, arms the
    /// periodic timer.
    public func start() {
        guard !AppStores.isTestProcess else { return }
        guard let store = LibraryModel.shared.store else {
            status = .unavailable("The library database is unavailable.")
            return
        }
        status = .syncing
        Task { [weak self] in
            let availability = await CloudKitTransport.availability()
            guard let self else { return }
            guard availability == .available else {
                self.status = .unavailable(
                    availability.explanation ?? "iCloud sync is unavailable."
                )
                return
            }
            // Entitlement confirmed — safe to construct CloudKit objects.
            self.engine = SyncEngine(store: store, transport: CloudKitTransport())
            self.status = .idle(lastSync: nil)
            self.syncNow()
            self.armTimer()
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        engine = nil
        status = .disabled
    }

    /// Runs one sync cycle now (also the Settings window's button). Cycles
    /// already in flight coalesce inside the engine.
    public func syncNow() {
        guard let engine else { return }
        status = .syncing
        Task { [weak self] in
            do {
                let summary = try await engine.sync()
                guard let self else { return }
                self.lastSummary = summary
                self.status = .idle(lastSync: Date())
                if summary.appliedChanges > 0 || summary.appliedDeletes > 0 {
                    // Remote rows landed: refresh tags/collections/books in
                    // any open library UI.
                    LibraryModel.shared.reloadOverlay()
                }
            } catch let error as SyncTransportError {
                switch error {
                case .unavailable(let detail):
                    self?.status = .error(detail)
                case .tokenExpired:
                    // The engine normally handles this internally; reaching
                    // here means it expired twice in one cycle. Next cycle
                    // starts clean.
                    self?.status = .error("Sync token expired — will retry.")
                }
            } catch {
                self?.status = .error(error.localizedDescription)
            }
        }
    }

    private func armTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self, syncInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: syncInterval)
                guard !Task.isCancelled else { return }
                self?.syncNow()
            }
        }
    }
}
