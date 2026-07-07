# Progress Tracker

Purpose: this file lets any development session (human or AI agent) resume from
repo state alone. Update it in every milestone commit. The full plan lives in
the project owner's plan file; the milestone list below is self-contained.

## Milestones

### Phase A — core packages (CLT-only, no Xcode needed)
- [x] **M0** Scaffold: Package.swift, module stubs, tests, license, README, CI
- [x] **M1** ReaderCore models: TabState, NavEntry, NavigationHistory, SessionSnapshot + versioned JSON codec, AppTheme
- [x] **M2** CalibreKit: read-only metadata.db reader (books/authors/tags/data joins, PDF path construction, uuid key, copy-before-read), `calibre-ls` CLI
- [x] **M3** ReaderPersistence: overlay DB schema (book/tag/book_tag/collection/collection_item/user_bookmark/reading_state/file_ref), GRDB migrations, CRUD
- [x] **M4** SearchIndexKit: IndexingService actor, contentHash (SHA-256 of first 128 KiB + size), FTS5 `page_fts`, snippet queries, `pdfindex` CLI

### Phase B — macOS app (requires Xcode; license must be accepted: `sudo xcodebuild -license accept`)
- [x] **M5** Minimal viewer: Xcode project (synchronized folders), open panel → PDFKitView, one window (`--open <path>` launch arg as automation hook)
- [x] **M6** Tabs + memory model: tab bar, DocumentProvider LRU (~3, pinned active), destroy PDFView on tab switch. Verified: 10 textbooks open = 66 MB footprint
- [x] **M7** Links + history: ReaderPDFView mouseDown interception (GoTo/RemoteGoTo/bare destination), NavigationHistory wiring, ⌘-click → new tab at destination, ⌘[/⌘] toolbar back/forward
- [x] **M8** Outline sidebar (PDFOutline tree, jumps push history), lazy page thumbnails, ⌘F find bar (beginFindString + highlightedSelections, ⌘G/⇧⌘G cycling)
- [x] **M9** Multi-window: WindowGroup(id:for:UUID), WindowAccessor (.moveToActiveSpace, tabbingMode=.disallowed, isRestorable=false, frame persistence), SessionCoordinator with debounced session.json (PDFREADER_SESSION_DIR env override for tests), full relaunch restore, ⌘N/⌘T/⌘W/⇧⌘W commands. Verified: 2-book session survives quit+bare relaunch
- [x] **M10** Theming: light/dark/sepia (Claude tan #F5EDE1) — ThemedPDFPage draw-override page filtering (difference-invert / multiply-tan, iOS-compatible), pdfView background, preferredColorScheme, View > Theme menu, UserDefaults persistence
- [x] **M11** Library browser: Library window (⇧⌘L), Calibre auto-detect + folder picker, cover grid with authors/tags, searchable, double-click opens in last-focused reader window (or stages a new one), iCloud dataless download-on-open with progress overlay; Calibre books mirrored into overlay DB (upsertCalibreBook)
- [x] **M12** Own imports + overlay tags/collections UI: library sidebar (All Books / hierarchical Tags / Collections) with scope filtering (descendant tags included), Import PDFs… (contentHash identity), per-book Tags/Collections context menus with toggles, New Tag nests under selected tag, overlay tags shown in accent + searchable
- [ ] **M13** Library-wide FTS search UI + background auto-indexing
- [ ] **M13b** OCR indexing for scanned PDFs (Vision VNRecognizeTextRequest when a page has no text layer; bump extractor_version to re-index; find-in-scanned-doc falls back to index hits at page granularity — store OCR word boxes later for real highlights)
- [ ] **M14** User bookmarks + reading state ("Continue reading")
- [ ] **M15** CloudKit sync via CKSyncEngine (dev account enrolled; owner must add it in Xcode > Settings > Accounts first)

### Phase C
- [ ] **M16** iOS app
- [ ] **M17** XCUITest smoke suite + xcodebuild CI job
- [ ] **M18** OSS polish, settings window, v0.1 tag

## Environment notes
- Xcode 26.6 installed, license accepted — plain `git`/`swift`/`xcodebuild` all work. (`scripts/test-clt.sh` remains for CLT-only environments but is no longer required.)
- App builds: `xcodebuild -project App/PDFReader.xcodeproj -scheme PDFReader -configuration Debug -derivedDataPath .build/DerivedData build`. The pbxproj is hand-authored (objectVersion 77, synchronized folder groups) — adding files under App/macOS/ requires no pbxproj edits.
- Owner's Calibre library: `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Calibre` (read-only source; files may be iCloud-evicted).
- Apple Developer account: enrolled (cable729@gmail.com, 2026-07-07). Before M15/signing: the owner must add the account in Xcode > Settings > Accounts (GUI step).
- Test corpus guidance from owner: Axler "Linear Algebra Done Right" (in the Calibre library) is the reference for internal-link behavior; also test scanned/ugly PDFs (search there needs M13b OCR); math notation extracts messily — search and snippets must tolerate it. Don't feature Dummit & Foote in demos/screenshots.

## Key design constraints (do not violate)
- Never write to Calibre's metadata.db; never open the live file (copy first).
- Only the active tab may hold a PDFView; PDFDocuments live in a small LRU.
- NavigationHistory in ReaderCore is the single source of truth for back/forward (not PDFView.goBack).
- Session restore is custom (session.json), not @SceneStorage/NSWindow restoration.
- All synced tables carry modified_at + soft-delete tombstones.

## Next step
M10 theming, then M11–M14 (library browser, tags/collections UI, search UI + OCR, bookmarks/reading state). M15 CloudKit after the owner adds his dev account in Xcode's GUI.
