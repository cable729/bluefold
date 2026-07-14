import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// These suites drive real NSWindows + synthesized NSEvents, which need a
    /// window server the headless CI runner doesn't provide (drags mis-fire or
    /// deadlock there). Skipped on headless CI, but a real-display lane can opt
    /// back in by setting `BLUEFOLD_REAL_DISPLAY` (see the ci.yml spike job and
    /// `./scripts/verify.sh`, which run them where a window server exists).
    static var requiresWindowServer: ConditionTrait {
        .enabled(if: isRealDisplayAvailable,
                 "needs a window server; skipped on headless CI")
    }
}

/// True when a window server is available: either we are not under CI at all
/// (local dev / `merge-pr.sh`), or a CI lane explicitly asserts a real display
/// via `BLUEFOLD_REAL_DISPLAY`. Keeping this positive-opt-in means the plain
/// headless `swift test` job keeps skipping, while an xcodebuild GUI-session
/// lane can run the same tests.
var isRealDisplayAvailable: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["CI"] == nil || env["BLUEFOLD_REAL_DISPLAY"] != nil
}
