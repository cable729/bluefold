#if os(macOS)
import Testing

@testable import ReaderUI

/// Guards the guard: unit tests must never see the user's real library.db.
/// If test-process detection breaks, every fixture that forgets `store:`
/// silently pollutes a real library again (2026-07-08 incident).
@Suite("AppStores test isolation")
@MainActor
struct AppStoresIsolationTests {
    @Test func testProcessIsDetected() {
        #expect(AppStores.isTestProcess)
    }

    @Test func realLibraryStoreIsUnreachableFromTests() {
        #expect(AppStores.library == nil)
    }

    /// LibraryModel's un-injected init opens the real library.db/index.db in
    /// the app; from a test process it must yield nil stores instead.
    @Test func unInjectedLibraryModelOpensNoRealStores() {
        let model = LibraryModel()
        #expect(model.store == nil)
        #expect(model.indexStore == nil)
        #expect(!model.needsSetup)
    }
}
#endif
