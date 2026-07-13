import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Tests that build and index a rasterized "scanned" PDF (an embedded
    /// bitmap image, no text layer) and run it through the image/OCR path —
    /// CoreGraphics image rendering and, when OCR is enabled, Vision text
    /// recognition (`VNRecognizeTextRequest`). Both hang indefinitely on the
    /// headless GitHub CI runner (no window server / GPU service context),
    /// deadlocking the whole test process. Local `./scripts/verify.sh` still
    /// exercises them. Pure text-layer index tests are unaffected.
    static var requiresScannedPDFSupport: ConditionTrait {
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                 "scanned-PDF image/OCR path hangs on the headless CI runner; skipped there")
    }
}
