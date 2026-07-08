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
}
#endif
