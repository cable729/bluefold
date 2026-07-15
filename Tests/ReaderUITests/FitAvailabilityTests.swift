#if os(macOS)
import Foundation
import Testing

@testable import ReaderUI

/// Bug 6 (#59) — fit width/height must be GRAYED OUT in two-page-FIXED mode
/// (`ViewMode.doubleFixed`, raw 2), where the whole spread is already fit to the
/// viewport and a width/height fit has no meaning. Every other mode keeps them
/// enabled. The status bar and the `view.fitWidth`/`view.fitHeight` commands
/// share this one pure predicate.
@Suite("Fit availability")
struct FitAvailabilityTests {
    @Test func disabledOnlyInTwoPageFixed() {
        #expect(FitAvailability.isEnabled(displayModeRaw: ViewMode.singleFixed.rawValue))
        #expect(FitAvailability.isEnabled(displayModeRaw: ViewMode.singleContinuous.rawValue))
        #expect(!FitAvailability.isEnabled(displayModeRaw: ViewMode.doubleFixed.rawValue))
        #expect(FitAvailability.isEnabled(displayModeRaw: ViewMode.doubleContinuous.rawValue))
    }

    /// A nil/absent mode (no active tab) leaves fit enabled — the disable is a
    /// narrow, specific carve-out, not a default-off.
    @Test func enabledWhenModeUnknown() {
        #expect(FitAvailability.isEnabled(displayModeRaw: nil))
        // An out-of-range raw value is treated as "not two-up-fixed" → enabled.
        #expect(FitAvailability.isEnabled(displayModeRaw: 99))
    }
}
#endif
