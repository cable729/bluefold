# Testing policy

The goal: agents (and humans) can change code without fear, because the tests
exercise real code and CI plus the local merge gate catch what breaks. The
policy below follows the classical ("Detroit") school as practiced at Google —
see Software Engineering at Google ch. 13 ("Test Doubles"), the Google Testing
Blog ("Know Your Test Doubles", "Change-Detector Tests Considered Harmful",
"Prefer Testing Public APIs"), and Fowler's "Mocks Aren't Stubs".

## The preference order

**Real implementation → fake → stub → mock.** Move down the list only when the
level above is impossible.

1. **Real implementation (the default).** If the real class is fast,
   deterministic, and simple to construct, inject and use it. Most of this
   codebase qualifies: planners, policies, stores with in-memory variants,
   codecs, math.
2. **Fake** — a *working*, lightweight implementation of a non-hermetic
   boundary: clock (`TestClock`), filesystem (in-memory store or a real
   `FileManager` pointed at a per-test temp dir — often the real thing made
   hermetic beats a fake), PDF rendering, network, randomness/UUIDs. A fake
   behaves like the real thing (an in-memory store really stores), it does not
   return canned answers.
3. **Stub** — canned answers to force one specific state. Every stubbed value
   must tie directly to an assertion in that test. Never stub as a wholesale
   dependency replacement.
4. **Mock / interaction verification — last resort.** Only when the calls ARE
   the contract (e.g. "cache hit must not touch the DB"), and then only for
   state-changing calls. Never assert call counts/order for reads.

## Rules

- **Assert state, not interactions.** Test return values and observable state.
  Interaction assertions produce change-detector tests that break on every
  refactor and catch nothing.
- **Test through public APIs.** A test should survive any refactor that
  preserves behavior.
- **Every fake gets contract tests.** One shared behavioral suite runs against
  BOTH the live implementation and the fake (parameterize a swift-testing
  suite over factories), so the fake can't drift from reality. Fidelity is to
  the API contract as consumers observe it; edge cases the real thing can't
  produce in a test (disk full) may stay fake-only — mark them.
- **Tests never touch real user data.** `AppStores.isTestProcess` fences the
  app's databases and UserDefaults from test processes; in-memory stores
  (`LibraryStore.inMemory()`, `IndexStore.inMemory()`) are the entry points.
  Keep it that way.
- **Geometry/layout code is TDD.** The failing test with expected numbers
  comes first (enforced by the Probity hook on the layout paths). Spec-ID
  tests (`m1_…`, `sw2_…`) are the executable spec — see
  [specs/view-modes.md](specs/view-modes.md).

## Dependency injection

- **Library:** [pointfreeco/swift-dependencies](https://github.com/pointfreeco/swift-dependencies).
  It generalizes the pattern this repo already uses (swift-clocks `TestClock`
  injected into `AutosaveObserver`). Built-in `\.continuousClock`, `\.date`,
  `\.uuid` cover the common boundaries.
- **Where:** `@Dependency` for cross-cutting leaf dependencies — clock, date,
  filesystem, logger (`\.appLogger`), PDF rendering. Plain `init` injection
  stays for intra-module wiring (don't convert existing constructor injection
  for its own sake).
- In `@Observable` models, use `@ObservationIgnored @Dependency(\.foo) var foo`.
- In tests: `withDependencies { $0.appLogger = .captured(into: box) } operation: { … }`.
- Style for new dependency interfaces: struct-of-closures ("protocol witness"),
  with `.live` and fake/test constructors in the same file — see
  `AppLogger` (Sources/ReaderCore/AppLogger.swift) for the house example.

## swift-testing idioms

- A fresh `@Suite` struct instance per `@Test` = natural real-object wiring;
  wire dependencies in `init`/stored properties, no shared fixtures.
- Use `@Test(arguments:)` for input matrices and for contract suites
  (parameterize over `[(name, makeImplementation)]`).
- Async time: `TestClock` + `await clock.advance(by:)` — never `sleep`.

## What runs where

| Layer | Runs | Gate |
|---|---|---|
| Pure math/policy/spec-ID tests | `swift test`, everywhere | CI per-PR (blocking) + Codecov patch |
| Snapshot tests (views, PDF layout) | `swift test`, everywhere | CI per-PR (blocking) |
| XCUITest smoke | CI macOS job, local via `VERIFY_UITESTS=1 ./scripts/verify.sh` | CI per-PR |
| CI-blind tests (TCC / Retina / real books) | local only | `./scripts/merge-pr.sh` before ANY merge |

Coverage: `swift test --enable-code-coverage`; Codecov reports untested lines
on every PR and blocks when patch coverage of changed lines is too low. If a
module shows weak coverage, file a `chore` issue rather than ignoring it.

Reference material for agents: pointfreeco/isowords (real-dependency testing at
scale), swift-dependencies docs ("Designing dependencies", "Testing").
