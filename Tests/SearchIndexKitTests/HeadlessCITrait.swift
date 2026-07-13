import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Tests that drive Vision text recognition (`VNRecognizeTextRequest`).
    /// Vision's OCR hangs indefinitely on the headless GitHub CI runner (no
    /// window server / GPU service context), deadlocking the whole test
    /// process. Local `./scripts/verify.sh` still exercises them.
    static var requiresVisionOCR: ConditionTrait {
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                 "Vision OCR hangs on the headless CI runner; skipped there")
    }
}
