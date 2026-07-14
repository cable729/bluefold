import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Tests that run a PDF through `IndexingService.indexDocument`, which
    /// opens it with PDFKit (`PDFDocument`) and, for scanned pages, renders a
    /// bitmap and runs Vision OCR. That PDFKit/Vision stack hangs on the
    /// headless GitHub CI runner (no window server / GPU service context).
    /// Because Swift Testing runs the module's tests in parallel, one hung
    /// `indexDocument` call blocks a cooperative-pool thread and starves the
    /// whole process, so even unrelated tests never complete and the module
    /// is KILLed at the 300s timeout. Gating every indexing test keeps the
    /// process healthy; the pure ContentHash / query-sanitizer tests (no
    /// PDFKit) still run on CI. Local `./scripts/verify.sh` exercises the
    /// full indexing path. A real-display CI lane can opt back in by setting
    /// `BLUEFOLD_REAL_DISPLAY` (see the ci.yml spike job).
    static var requiresPDFIndexing: ConditionTrait {
        .enabled(if: isRealDisplayAvailable,
                 "PDFKit/Vision indexing hangs on the headless CI runner; skipped there")
    }
}

/// True when the environment can host the PDFKit/Vision indexing stack: local
/// (no `CI`), or a CI lane that asserts a real display via
/// `BLUEFOLD_REAL_DISPLAY`. Positive-opt-in so the plain headless `swift test`
/// job keeps skipping.
var isRealDisplayAvailable: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["CI"] == nil || env["BLUEFOLD_REAL_DISPLAY"] != nil
}
