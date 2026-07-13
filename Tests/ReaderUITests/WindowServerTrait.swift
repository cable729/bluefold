import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// These suites drive real NSWindows + synthesized NSEvents, which need a
    /// window server the headless CI runner doesn't provide (drags mis-fire or
    /// deadlock there). Local `./scripts/verify.sh` still exercises them.
    static var requiresWindowServer: ConditionTrait {
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                 "needs a window server; skipped on headless CI")
    }
}
