# Progress Tracker

Purpose: this file lets any development session (human or AI agent) resume from
repo state alone. Update it in every milestone commit. The full plan lives in
the project owner's plan file; the milestone list below is self-contained.

## Milestones

### Phase A — core packages (CLT-only, no Xcode needed)
- [x] **M0** Scaffold: Package.swift, module stubs, tests, license, README, CI
- [x] **M1** ReaderCore models: TabState, NavEntry, NavigationHistory, SessionSnapshot + versioned JSON codec, AppTheme
- [ ] **M2** CalibreKit: read-only metadata.db reader (books/authors/tags/data joins, PDF path construction, uuid key, copy-before-read), `calibre-ls` CLI
- [ ] **M3** ReaderPersistence: overlay DB schema (book/tag/book_tag/collection/collection_item/user_bookmark/reading_state/file_ref), GRDB migrations, CRUD
- [ ] **M4** SearchIndexKit: IndexingService actor, contentHash (SHA-256 of first 128 KiB + size), FTS5 `page_fts`, snippet queries, `pdfindex` CLI

### Phase B — macOS app (requires Xcode; license must be accepted: `sudo xcodebuild -license accept`)
- [ ] **M5** Minimal viewer: Xcode project (synchronized folders), open panel → ReaderPDFView, one window
- [ ] **M6** Tabs + memory model: tab bar, DocumentProvider LRU (~3), destroy PDFView on tab switch, verify with footprint/Instruments
- [ ] **M7** Links + history: mouseDown interception (GoTo/Named/RemoteGoTo/bare destination), NavigationHistory integration, ⌘-click → new tab, ⌘[/⌘]
- [ ] **M8** Outline sidebar (PDFOutline), page thumbnails, in-PDF find bar (beginFindString + highlightedSelections)
- [ ] **M9** Multi-window: WindowGroup(id:for:), WindowAccessor (.moveToActiveSpace, tabbingMode=.disallowed, isRestorable=false), debounced session.json, full relaunch restore
- [ ] **M10** Theming: light/dark/sepia chrome + ThemedPDFPage draw-override page filtering
- [ ] **M11** Library browser: attach Calibre folder, covers/authors/tags, open→tab, iCloud dataless download-on-open
- [ ] **M12** Own imports + overlay tags/collections UI
- [ ] **M13** Library-wide FTS search UI + background auto-indexing
- [ ] **M14** User bookmarks + reading state ("Continue reading")
- [ ] **M15** CloudKit sync via CKSyncEngine (blocked on Apple Developer account)

### Phase C
- [ ] **M16** iOS app
- [ ] **M17** XCUITest smoke suite + xcodebuild CI job
- [ ] **M18** OSS polish, settings window, v0.1 tag

## Environment notes
- Xcode 26 installed at /Applications/Xcode.app and selected, but **license not yet accepted** — `git`/`swift` shims fail until `sudo xcodebuild -license accept` is run. Workarounds in use: `scripts/test-clt.sh` for `swift test` (CLT lacks auto-wiring for Swift Testing framework paths), `/Library/Developer/CommandLineTools/usr/bin/git` for git, `DEVELOPER_DIR=/Library/Developer/CommandLineTools` for builds.
- Owner's Calibre library: `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Calibre` (read-only source; files may be iCloud-evicted).
- Apple Developer account: not yet enrolled (blocks M15 CloudKit + iOS device deploys).

## Key design constraints (do not violate)
- Never write to Calibre's metadata.db; never open the live file (copy first).
- Only the active tab may hold a PDFView; PDFDocuments live in a small LRU.
- NavigationHistory in ReaderCore is the single source of truth for back/forward (not PDFView.goBack).
- Session restore is custom (session.json), not @SceneStorage/NSWindow restoration.
- All synced tables carry modified_at + soft-delete tombstones.

## Next step
M2/M3/M4 in parallel (worktree agents); Package.swift already defines all targets so parallel work never edits it. After merging: Phase B (needs Xcode license accepted).
