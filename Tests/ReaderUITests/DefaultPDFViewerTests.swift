#if os(macOS)
import Testing

@testable import ReaderUI

@Suite("DefaultPDFViewer")
@MainActor
struct DefaultPDFViewerTests {
    @Test func promptsOnlyWhenNotDefaultAndNotSuppressed() {
        #expect(
            DefaultPDFViewer.shouldPrompt(
                isDefault: false, suppressed: false, hasBundleID: true
            )
        )
    }

    @Test func neverPromptsOnceDefault() {
        #expect(
            !DefaultPDFViewer.shouldPrompt(
                isDefault: true, suppressed: false, hasBundleID: true
            )
        )
    }

    @Test func suppressionIsDurable() {
        #expect(
            !DefaultPDFViewer.shouldPrompt(
                isDefault: false, suppressed: true, hasBundleID: true
            )
        )
    }

    /// Test/CLI processes have no bundle identifier and must never prompt —
    /// they aren't a registerable handler.
    @Test func bareProcessesNeverPrompt() {
        #expect(
            !DefaultPDFViewer.shouldPrompt(
                isDefault: false, suppressed: false, hasBundleID: false
            )
        )
    }
}
#endif
