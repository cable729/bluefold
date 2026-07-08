#if os(macOS)
import Foundation
import ReaderPersistence
import SearchIndexKit
import Testing

@testable import ReaderUI

/// A scratch UserDefaults suite that never touches the user's real domain,
/// wiped on teardown.
private func makeScratchDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
    let suite = "AppSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

@Suite("AppSettings")
@MainActor
struct AppSettingsTests {
    @Test func defaultsWhenNothingStored() {
        let (defaults, cleanup) = makeScratchDefaults()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.documentCapacity == AppSettings.defaultDocumentCapacity)
        #expect(settings.backgroundIndexingEnabled)
        #expect(settings.ocrIndexingEnabled)
    }

    @Test func persistenceRoundTrip() {
        let (defaults, cleanup) = makeScratchDefaults()
        defer { cleanup() }

        let first = AppSettings(defaults: defaults)
        first.documentCapacity = 7
        first.backgroundIndexingEnabled = false
        first.ocrIndexingEnabled = false

        // A fresh instance over the same suite sees the persisted values.
        let second = AppSettings(defaults: defaults)
        #expect(second.documentCapacity == 7)
        #expect(!second.backgroundIndexingEnabled)
        #expect(!second.ocrIndexingEnabled)
    }

    @Test func capacityClampsOnWriteAndOnLoad() {
        let (defaults, cleanup) = makeScratchDefaults()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.documentCapacity = 0
        #expect(settings.documentCapacity == AppSettings.documentCapacityRange.lowerBound)
        settings.documentCapacity = 99
        #expect(settings.documentCapacity == AppSettings.documentCapacityRange.upperBound)

        // A hand-edited absurd value in the store loads clamped too.
        defaults.set(-5, forKey: AppSettings.documentCapacityKey)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.documentCapacity == AppSettings.documentCapacityRange.lowerBound)
    }

    @Test func nilDefaultsKeepsValuesInMemoryOnly() {
        let settings = AppSettings(defaults: nil)
        settings.documentCapacity = 5
        #expect(settings.documentCapacity == 5)
        // Nothing persisted: a second nil-backed instance is factory-fresh.
        #expect(AppSettings(defaults: nil).documentCapacity == AppSettings.defaultDocumentCapacity)
    }

    @Test func capacityChangeHookFiresOncePerRealChange() {
        let settings = AppSettings(defaults: nil)
        var received: [Int] = []
        settings.onDocumentCapacityChange = { received.append($0) }

        settings.documentCapacity = 5
        settings.documentCapacity = 5  // no-op: same value
        settings.documentCapacity = 99  // clamps, then notifies once
        #expect(received == [5, AppSettings.documentCapacityRange.upperBound])
    }

    @Test func sessionCoordinatorAppliesCapacityLive() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = AppSettings.shared.documentCapacity
        defer { AppSettings.shared.documentCapacity = original }

        let coordinator = SessionCoordinator(
            sessionFileURL: dir.appendingPathComponent("session.json")
        )
        #expect(coordinator.provider.capacity == original)

        // Settings change lands on the provider without a relaunch.
        AppSettings.shared.documentCapacity = min(
            original + 2, AppSettings.documentCapacityRange.upperBound
        )
        #expect(coordinator.provider.capacity == AppSettings.shared.documentCapacity)
    }
}

@Suite("Indexing settings gates")
@MainActor
struct IndexingSettingsTests {
    private func makeModel(settings: AppSettings) throws -> LibraryModel {
        try LibraryModel(
            store: .inMemory(),
            indexStore: IndexStore.inMemory(),
            settings: settings
        )
    }

    @Test func backgroundIndexingDisabledSchedulesNothing() throws {
        let settings = AppSettings(defaults: nil)
        settings.backgroundIndexingEnabled = false
        let model = try makeModel(settings: settings)

        model.startBackgroundIndexing()
        #expect(!model.isBackgroundIndexingScheduled)
        #expect(model.indexingProgress == nil)
    }

    @Test func backgroundIndexingEnabledSchedulesAPass() throws {
        let settings = AppSettings(defaults: nil)
        let model = try makeModel(settings: settings)

        model.startBackgroundIndexing()
        #expect(model.isBackgroundIndexingScheduled)

        // Turning the setting off cancels the pass and clears progress.
        settings.backgroundIndexingEnabled = false
        model.indexingSettingsChanged()
        #expect(!model.isBackgroundIndexingScheduled)
        #expect(model.indexingProgress == nil)
    }

    @Test func ocrToggleAppliesToTheNextPass() throws {
        let settings = AppSettings(defaults: nil)
        settings.ocrIndexingEnabled = false
        let model = try makeModel(settings: settings)
        #expect(model.indexingServiceOCREnabled == false)

        settings.ocrIndexingEnabled = true
        model.startBackgroundIndexing()
        #expect(model.indexingServiceOCREnabled == true)

        settings.ocrIndexingEnabled = false
        model.startBackgroundIndexing()
        #expect(model.indexingServiceOCREnabled == false)
    }
}
#endif
