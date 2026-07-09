# Contributing

Small project, sharp edges documented. Read this once; it will save you a
broken pbxproj or a clobbered database.

## Dev setup

- **Xcode 26+** (Swift 6.3), license accepted: `sudo xcodebuild -license accept`
- All logic lives in the root SwiftPM package — most work needs only:

  ```sh
  swift test
  ```

- The app targets are thin shells over the package. Build them with:

  ```sh
  # macOS app
  xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold \
      -configuration Debug -derivedDataPath .build/DerivedData build

  # iOS app (simulator)
  xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold-iOS \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath .build/DerivedData-iOS build CODE_SIGNING_ALLOWED=NO
  ```

## The gate

Before merging anything, run the one-command verification gate:

```sh
./scripts/verify.sh
```

It runs the unit tests, builds both apps, and launch-smokes the macOS app.
If it passes, you're good. (Releases use `scripts/release.sh` — see its
`--help`.)

## Code conventions

- **Logic goes in `Sources/` packages** (ReaderCore, ReaderUI,
  ReaderPersistence, CalibreKit, SearchIndexKit), where `swift test` can
  reach it. `App/macOS` and `App/iOS` stay scene-and-delegate thin.
- **The pbxproj is hand-authored** (objectVersion 77, synchronized folder
  groups). New Swift files under `Sources/` or `App/` need **no pbxproj
  edits** — just create the file. Don't let Xcode "fix" or regenerate the
  project; diff any pbxproj change you didn't type yourself.
- New logic gets unit tests (swift-testing, `@Suite`/`@Test`). Tests must
  never touch real user data — inject in-memory stores
  (`LibraryStore.inMemory()`, `IndexStore.inMemory()`) and note that
  `AppStores.isTestProcess` fences the app's databases and UserDefaults
  from test processes; keep it that way.

## Design constraints (do not violate)

- **Never write to Calibre's `metadata.db`** — never even open the live
  file (copy first). The Calibre library is read-only, always.
- **Only on-screen tabs hold `PDFView`s** (the active tab, plus the split
  pane's tab when a window is split); `PDFDocument`s live in a small LRU
  with the on-screen paths pinned. 10 GB of open books must not mean 10 GB
  of RAM.
- **`NavigationHistory` (ReaderCore) is the single source of truth** for
  back/forward — not `PDFView.goBack`.
- **Session restore is custom** (`session.json` via SessionCoordinator),
  not `@SceneStorage`/NSWindow restoration.
- All synced tables carry `modified_at` + soft-delete tombstones.
- PDFKit navigation has real-world pathologies (silent `go(to:)` no-ops,
  garbage destination points, offset crop boxes). Read
  "PDFKit destination pathologies" in [docs/PROGRESS.md](docs/PROGRESS.md)
  before touching navigation code.

## Where things are explained

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — module map, memory model, data stores
- [docs/DECISIONS.md](docs/DECISIONS.md) — why things are the way they are
- [docs/PROGRESS.md](docs/PROGRESS.md) — milestone status + hard-won quirk notes
- [docs/BACKLOG.md](docs/BACKLOG.md) — planned work and owner feature requests
- [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md) — command table + keybindings.json format
