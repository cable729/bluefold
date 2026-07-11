# Progress Tracker

Purpose: this file lets any development session (human or AI agent) resume from
repo state alone. Update it in every milestone commit. The milestone list
below is self-contained.

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
- [x] **M9** Multi-window: WindowGroup(id:for:UUID), WindowAccessor (.moveToActiveSpace, tabbingMode=.disallowed, isRestorable=false, frame persistence), SessionCoordinator with debounced session.json (BLUEFOLD_SESSION_DIR env override for tests), full relaunch restore, ⌘N/⌘T/⌘W/⇧⌘W commands. Verified: 2-book session survives quit+bare relaunch
- [x] **M10** Theming: light/dark/sepia (Claude tan #F5EDE1) — ThemedPDFPage draw-override page filtering (difference-invert / multiply-tan, iOS-compatible), pdfView background, preferredColorScheme, View > Theme menu, UserDefaults persistence
- [x] **M11** Library browser: Library window (⇧⌘L), Calibre auto-detect + folder picker, cover grid with authors/tags, searchable, double-click opens in last-focused reader window (or stages a new one), iCloud dataless download-on-open with progress overlay; Calibre books mirrored into overlay DB (upsertCalibreBook)
- [x] **M12** Own imports + overlay tags/collections UI: library sidebar (All Books / hierarchical Tags / Collections) with scope filtering (descendant tags included), Import PDFs… (contentHash identity), per-book Tags/Collections context menus with toggles, New Tag nests under selected tag, overlay tags shown in accent + searchable
- [x] **M13** Library-wide FTS search UI + background auto-indexing: LibraryModel owns index.db (IndexStore + IndexingService), reload() kicks a cancellable utility-priority pass that indexes local files only (never triggers iCloud downloads), `indexingProgress` toolbar readout, "In Book Text" hit list above the grid (title / p.N / plain snippet), click opens the book at that page via `openItem(_:at:)` → `openInReader(fileURL:at:)`
- [x] **M13b** OCR indexing for scanned PDFs: extractor v2, ~200 DPI CGBitmapContext render + VNRecognizeTextRequest inside the IndexingService actor, `.indexed` reports ocrPages, `.notSearchable` = no text layer AND OCR found nothing; `IndexingService(store:ocrEnabled:)` opt-out. (OCR word boxes for in-page highlights = future)
- [x] **M14** Bookmarks + reading state: BookResolver (content-hash first, file_ref path, auto-register any opened PDF), reading-state writes on capture, Bookmarks sidebar mode + ⌘D, shared AppStores.library. ("Continue Reading" library section pending M13 merge)
- [~] **M15** CloudKit sync — CODE DONE + unit-tested (2026-07-09); live
  CloudKit pending signing steps (docs/SYNC.md runbook). What shipped:
  `SyncKit` engine (shadow-diff push / fetch-then-apply, LWW by modified_at,
  reading_state max-updated_at, deterministic record names so devices mint
  identical records), `ReaderPersistence` portable export/apply + migration
  v6 (local-only sync_shadow/sync_meta/sync_pending), `CloudKitTransport`
  (private DB, one zone, opaque payload field, entitlement-gated so unsigned
  builds never touch CKContainer), `SyncCoordinator` + Settings "iCloud
  sync" section (toggle default OFF, status line, Sync Now). 27 new tests
  incl. two-device convergence via FakeTransport (rename keeps memberships,
  tombstone purge propagates as hard delete, push-echo skip prevents
  resurrection, orphan relations pend + heal, expired token refetches
  idempotently). Design + maintainer notes: docs/SYNC.md.

- [x] **UI-1** Feedback round 1: search moved into the sidebar (results list, no navigation while typing, click = jump+history), 4 icon-tab sidebar modes (fixes segmented overflow), sidebar/window fill constraints (fixes dead-space collapse), active tab highlighted (accent top bar + bold), tabs draggable between windows (payload windowID|tabID -> SessionCoordinator.moveTab), back/forward buttons are history menus, ⌘[/⌘] moved to a History menu, current section highlighted in Contents, live page tracking via PDFViewPageChanged
- [x] **P-1** Collections support tree nesting (migration v2: collection.parent_id; collectionTree(), subtree book queries, reparenting delete)

- [x] **UI-2** Feedback round 2: evicted covers download-on-demand (fixes disappearing covers), In Book Text capped at 5 with Show All toggle, selected book highlighted (accent ring), history entries labeled with outline section names, bottom status bar (page layout modes, fit width/height, page x/y with direct jump, theme switcher), plain back/forward buttons with right-click history, ⌘-click opens ADJACENT tab + same-book tabs get group dots, tab context menu (duplicate/close/close others), collections nest in the sidebar (subtree filtering; New Collection nests under selected scope)

- [x] **UI-3** Overnight round 3 (2026-07-08):
  - **Tab strip rewritten in AppKit** (`TabStripView.swift`) — SwiftUI DnD was unfixably broken. Chrome-style mouse tracking: drag reorders (live preview), drag past a vertical threshold tears off under a ghost panel; drop on another window's strip moves the tab (screen-level `TabStripRegistry` hit-testing), drop on the desktop opens a new window at the point (staged restorably via `pendingRestore`+`pendingOrder`); a single-tab window just moves. Emptied source windows close.
  - **Two-row tabs**: title over outline breadcrumb (`ReaderWindowModel.tabBreadcrumbs`, refreshed via `DocumentProvider.loadedDocument` so background tabs never disturb the LRU); adjacent same-book tabs render the title once in a spanning group header (replaces the group dot).
  - **Split view**: `WindowState.splitTabID` (optional; schema-1 files keep decoding), `openInSplit`/`closeSplit`, secondary pane is a non-primary `ActivePDFView` with its own link routing (`linkActivated(sourceTabID:via:)`); both panes' documents pinned. Strip context menu + slim pane header manage it.
  - **Tab multi-select**: ⌘-click toggles / ⇧-click ranges in the strip; "Close N Tabs" bulk action.
  - **Open Collection / in New Window** on library collection rows (subtree included, manual order kept, iCloud downloads first).
  - **Theme overhaul**: `AppTheme.auto` follows the system; cross-window sync fixed for real (root cause: lazy per-window `.preferredColorScheme` — replaced with a ThemeManager NSWindow registry setting `window.appearance` imperatively); sepia tints titlebars Claude-tan; status bar always visible so themes are switchable in empty windows.
  - **Live sidebar find**: ~300ms debounce, no Enter; superseding fixed a real PDFKit trap (`beginFindString` from inside `PDFDocumentDidEndFind` delivery is silently ignored — parked queries start one main-actor hop later); per-hit outline breadcrumbs via `OutlineNode.deepestPath` with per-document caching.
  - **Library polish**: selection made instant (root cause: `filteredItems` was a computed property re-running SQLite scope queries per body evaluation; now stored + Equatable cell content), ⌘/⇧ multi-select with contextual action bar (Remove only for app-owned imports), drag-to-tag/collection, Untagged / Not-in-any-collection smart filters with counts, tags-vs-collections help popovers, covers survive scroll (`.task(id:)` cancellation broke retries permanently; per-URL coalescing loader), right-click Reveal in Finder, debounced live FTS.
  - **Status bar**: `‹ [page] / N ›` arrows wired to PDFView paging; reusable `.instantHint` hover hints (150ms) because `.help()` felt like seconds.

- [x] **UI-4** Feedback round 5 (2026-07-08): P0 session loss FIXED — root
  cause was last-window-close wiping session.json while the app kept running
  (not the staged-detach hypothesis; that path was fine and is now
  test-pinned). Last-closed window with tabs is stashed back into
  pendingRestore (browser-style), claimLaunchWindowID re-resolves spent IDs,
  session.json.bak rotates on good loads with corrupt/empty fallback. Tab
  strip: layer clipping, header trailing constraint + 22pt/11pt sizing,
  first-layout never animates, grouping suspends only when a drag MOVES
  (kills the title-glide), torn-off tab uses alpha 0 instead of isHidden
  (hidden views can drop the drag's own tracking events — the wedge), plus
  local+global mouseUp monitor failsafes; every drag end funnels through
  finishDrag. ⌘G = Go to Page (⌥⌘G retired; find cycles via Enter/⇧Enter).
  Discoverability: toolbar ⌘-button for the palette + empty-state hint line.
  "+" is a menu (From Library… / Open File…). Library tags show subtree
  book-count badges (LibraryModel.tagCounts). Quick-open:
  ⌘P lists every library book — type part of the name, Return opens it as
  a tab; Calibre paths mirror into file_ref at library reload
  (upsertFileRefs/openableBooks), open books dedupe into their tab row,
  evicted files download first. One library reload is needed post-update
  before never-opened Calibre books appear.
- [x] **UI-5** Keybindings round 6 (2026-07-08 —
  see BACKLOG "Keybindings round 6" for the decision log): split palettes
  (⌘P/⌘O open · ⌘⇧O in-book), ⌘Return/⌥Return background/new-window
  variants, collections & tags openable from the palette, ⌘1–9 tab
  switching (layouts → ⌥⌘1–4), ⌘⇧F library-wide search, ⌘-click links →
  background tabs, ⌘O palette focus fix, and a hard fence keeping unit
  tests out of the user's real library.db.

- [x] **UI-6** Feedback rounds 9–13.7 (2026-07-08, all same-day): final
  palette chords (⌘O = open books/collections/tags · ⌘P/⌘⇧O = in-book
  sections/bookmarks) with live ⌘/⇧ modifier feedback (footer legend +
  selected-row badge; ⇧⏎ = new window, ⌘⏎ = background tab, palette stays
  open for queueing); batch opens download concurrently and open books as
  they arrive (one evicted iCloud book used to stall everything
  silently); sidebar outline follows the current section (scope toggle,
  app-owned DisclosureGroup expansion); status-bar ⇤ ⇥ section skipping,
  destination-precise and hardened against every scan pathology (see
  PDFKit pathologies below); tab breadcrumbs persist on TabState in
  session.json;
  book.authors in the overlay (schema v3) makes quick-open match authors;
  sepia tint fills the clip (offset-crop scans); instantHint bubbles live
  in floating child windows (unclippable); tooltips deduped (.help
  removed beside .instantHint, NSInitialToolTipDelay=150 persisted —
  `register` is invisible to CFPreferences).

- [x] **F-1** Feature wave (2026-07-08 afternoon; all merged, 330 tests):
  - **Deep linking** (`bluefold://open?hash=…&dest=…&page=…&x=&y=`): content-hash
    resolution (survives moves), named destinations resolved via the CGPDF
    Names/Dests tree (`NamedDestinations`), `DeepLinkRouter` queues launch URLs +
    downloads evicted books, Copy Link to Here / to Selection (Edit menu +
    palette, chordless). Scheme registered via App/macOS/Info.plist
    (INFOPLIST_FILE merges with generated; synchronized-group exception set keeps
    it out of Resources). Scheme string = `DeepLink.schemes` in ReaderCore — the
    single rename point; register new scheme + keep old as alias on rename.
    VERIFIED live: page and dest links land exactly (Axler dest=section.1.1 →
    p.21 "1A › Complex Numbers").
  - **Tag colors** (schema v4 `tag.color` hex, sidebar dots, tinted chips, Color
    submenu with 8 presets).
  - **Library view modes** (schema v5 `book.created_at`): sortable list view
    (title/author/date added/last read), sectioned-by-tag grid inside a tag scope
    (scope-only books first, then per-child-tag sections), toolbar mode toggle,
    prefs persisted.
  - **User keybindings**: `keybindings.json` overlay (Application Support), chord
    parser + conflict validation with launch alert + help-overlay banner,
    "Preferences: Open Keybindings File" command; format documented in
    KEYBINDINGS.md. ⌘G stays protected.
  - **Split view upgrades**: `SplitSide` (leading/trailing, session-compatible),
    Split Left / Split Right / Close Split commands, ⌘\ toggle (duplicates active
    tab into a right split / closes), drag-to-split drop zones over the PDF area
    (screen-level registry, non-activating overlay, all ends through finishDrag).
  - **iOS part 2**: library UI (folder-picker Calibre source w/ security-scoped
    bookmark), FTS search UI, theming, link-tap history interception, dataless
    download flow, session save on .inactive/.background. Shared-code refactor:
    LinkResolution.swift, PageTheming.swift, LibraryTypes.swift extracted
    cross-platform.

- [x] **UI-8** Round 14 (2026-07-08): split-view semantics rework.
  Root causes: (a) clicking the split tab in the strip made it the primary
  too — one TabState rendered by two live views; (b) ⌘\'s duplicate tab
  GROUPED with its twin, so the spanning header swallowed its title,
  context menu, and drag handle; (c) nothing tracked which pane the user
  was in, so the sidebar/status bar/commands always acted on the primary
  (left) pane. Now: windows have a FOCUSED pane (`focusedPane`,
  ephemeral); `activeTab`/`activeController` mean the focused pane's
  tab/view so every surface (sidebar, status bar, history, bookmarks,
  palettes, ⌘W, copy-link) follows focus; clicking a pane or its header
  focuses it (accent dot + tinted header); selecting the split tab in the
  strip focuses its pane instead of dual-rendering; the split tab never
  groups, gets a split badge, and its menu gains "Move Split to
  Left/Right Side"; group headers answer right-clicks (proxy the first
  tab's menu); BOTH panes have headers with full context menus while
  split; close/detach successor logic skips the split tab and collapses a
  last-remaining split into the primary; ⌃Tab cycles from the focused
  tab. 13 new PaneFocusTests.

- [x] **UI-9** Round 15 (2026-07-08): live breadcrumbs + split polish.
  - **Breadcrumb/sidebar follow the scroll live**: PDFViewPageChanged only
    fires on page flips, so the strip crumb and follow-mode highlight
    froze until scroll settled and couldn't tell apart sections sharing a
    page. Now each pane observes its internal scroll view's bounds
    (80ms trailing throttle) → `noteLivePosition` → binary search over
    per-document precomputed `OutlineNode.sectionStops` (ancestor paths
    baked in; same-spot anchors keep the DEEPEST path; landing slop
    honored). Point-precise `currentSectionNodeID` drives the sidebar;
    stops cache holds up to 4 documents so a two-book split never
    thrashes.
  - **✕ moved to the RIGHT side of tabs** (matches the pane headers).
  - **Either pane's ✕ closes THAT pane** (`closePane`): closing the
    primary promotes the split tab to full primary; tabs never close.
  - **Dragging the split tab un-splits it** (first drag movement closes
    the pane and selects the tab in hand; then it drags like any tab).
  - Parked feature sketch: margin heading anchors
    ("#"/"##"/"###" next to titles/sections/definitions, tied to deep
    links) — see BACKLOG "Round 15" for the sketch + open questions.
  15 new tests (LivePositionTests + stop ordering/slop).

- [x] **UI-10** Round 16 (2026-07-08): margin heading anchors, first cut.
  - **What ships**: a small link glyph in each page's left margin next to
    chapters/sections (outline tier), theorems/definitions/examples
    (text-detection tier), and named-destination anchors. ~50% ink at
    rest; hover brightens it, shows a dashed extent outline around the
    heading line (text tier), tooltip carries the label. Click = copy a
    `bluefold://` link (`dest=` + page/point fallback both encoded) AND
    push the anchor onto the tab's back stack (⌘[ returns there — a
    lightweight "mark this spot"); ⌥-click copies a markdown link
    `[label](url)` for notes. A bottom toast confirms what was copied
    (new `model.toast`, reusable).
  - **Three anchor tiers, merged** (`AnchorIndex`, probed against real
    books): outline stops (works on every book incl. scans), named-dest
    enumeration (`NamedDestinations.all` — one Names-tree walk;
    `AnchorHeadingParser.classifyDestination` whitelists hyperref
    prefixes), text detection per page, lazy + cached
    (`AnchorHeadingParser.parse`: LADR "5.2 definition: x" number-first
    style REQUIRES the colon; classic "Theorem 2.2.1 (Name)." style
    REQUIRES a dotted number + terminator — both guards kill real
    mid-prose false positives like "Exercise 21 in Section 5D shows…").
  - **Probe findings that shaped it** (scratch scripts over real books):
    named dests are NOT a reliable theorem source — Axler has 2259 names
    but zero theorem.*, and other real textbooks range from none at all
    (even clean LaTeX) to a few hundred. And books share ONE hyperref
    counter across theorem-family environments (a `theorem.35.1.3.1`
    dest can actually be Definition 1.3.1), so
    the whole theorem family is one merge family; the text label wins,
    the dest name rides along for durable links.
  - **Rendering**: `PDFPageOverlayViewProvider` WORKS on macOS 26
    (probed): overlay views install per visible page, keep page-point
    coordinates at every zoom (PDFKit scales by transform), unflipped,
    origin = crop-box origin. `AnchorPageOverlayView.hitTest` returns
    glyphs only — page clicks/selection/links pass through. Provider is
    set BEFORE `view.document` or first pages never get overlays; the
    coordinator holds it strongly (PDFView's ref is weak).
  - 25 new tests (AnchorHeadingTests, AnchorSourceTests,
    AnchorIndexTests, AnchorClickTests; name-tree fixture extracted to
    NameTreeFixture.swift for reuse). 385 total green; full verify gate
    passed.
  - **Round-2 candidates**: equations/figures
    behind a "show all anchors" toggle, anchor visibility setting
    (always/hover/off), glyph x-position in tight-cropped scans
    (currently 5pt inside the crop edge — may sit over text in
    margin-less scans), OCR tier for scanned books, labels on history
    entries (NavEntry.label).
  - **Round 16.1** (anchor printed structure, not just the outline):
    the text tier now also detects STRUCTURE printed on
    the page, not just what the (often shallow) outline has — `Chapter 7
    [Title]`/`Appendix A`/`Part III` lines, numbered section headings
    ("1.3 The Axiom of Completeness"; one dot = section, more =
    subsection), capitalized-keyword "2.11 Definition <statement runs
    on>" style (no colon; label keeps number+keyword), and
    undotted per-chapter numbering ("Example 3." — explicit `.`/`:`
    terminator required so wrapped "…see\nTheorem 5" stays dead).
    New guards, each from a probed false positive: running heads end in a
    page number ("4.6 Applications to Vector Calculus 41"), exercise
    sentences start with a verb ("2.6 Prove that…" — first-word
    blacklist), terminator "." must not be a decimal point ("Theorem
    5.19 and…" would backtrack-match). Same-page chapter anchors merge
    at ANY distance (outline dest at page top vs printed "Chapter 1"
    mid-page) keeping the longer label when one extends the other.
    Probed clean on six real textbooks; one Pearson-produced text is
    unfixable-by-text (reflow scrambles headings mid-line — outline
    tier only). 391 tests green, verify gate passed.
  - **Round 16.2**: Settings > Reading > "Margin heading anchors" toggle
    (AppSettings.marginAnchorsEnabled, default ON, persisted). Applies
    LIVE in every visible pane: ActivePDFView.updateNSView reads the
    observable (registers the dependency) and sets the provider's
    isEnabled, which hides/shows already-installed overlay views —
    overlays are still CREATED while disabled because PDFKit asks once
    per page display and caches a nil answer (re-enabling would
    otherwise show nothing until a page turn).
- [x] **UI-11** Round 17 (2026-07-08): dark-flip theme desync
  fixed (symptom: dark chrome + white sidebar labels over sepia
  paper after the machine slept through the system's auto-switch to Dark).
  Root cause, verified by lldb-attaching a live broken instance: SwiftUI's
  scene machinery resets `window.appearance` to nil during its own update
  passes, silently undoing ThemeManager's forced appearance — invisible
  while the system is light (nil ≈ aqua), exposed the moment the system
  flips dark. Fix in ThemeManager: (1) per-window KVO on `\.appearance`
  re-applies chrome whenever the forced appearance drifts (the drift check
  doubles as the re-entrancy guard); (2) system flips now tracked by KVO on
  `NSApp.effectiveAppearance` instead of the AppleInterfaceThemeChanged
  distributed notification, which can be dropped while the app naps through
  a sleep and races the effectiveAppearance flip even when delivered.
  Regression tests: `reassertsForcedAppearanceAfterExternalReset`,
  `tracksSystemFlipViaEffectiveAppearanceKVO` (flip NSApp.appearance to
  drive the KVO in-process). Verified live: relaunched under a dark system
  with sepia theme — window appearance forced Aqua, effective Aqua.
- [x] **UI-12** Round 18 (2026-07-09): watched folders + live auto-reload
  (import folders of externally regenerated PDFs — e.g. reMarkable
  exports — keep them in sync as files regenerate, auto-discover new
  PDFs there and in Calibre).
  - **Watched folders**: `LibraryModel.watchedFolders` (UserDefaults
    `WatchedFolderPaths`, plain paths, macOS-only), managed from Settings >
    Watched folders and the Library ⚙ menu. Every reload() runs
    `scanWatchedFolders()`: recursive *.pdf enumeration, off-main hashing
    with an (mtime,size) fingerprint cache so settled folders are stat-only,
    iCloud-evicted placeholders kick `startDownloadingUbiquitousItem` and
    register on the scan their arrival triggers (a placeholder is never a
    removal). Removing a watched folder soft-deletes its books (files
    untouched; re-adding resurrects with reading state).
  - **Identity across regeneration** (the reMarkable property: every sync
    rewrites the file ⇒ new content hash): all scan/reload writes go through
    `LibraryStore.syncScannedFile(path:hash:title:)` — one transaction,
    decision order hash-match (moved/came back; resurrects tombstones,
    refreshes file_ref) → path-match (regenerated in place: REBINDS
    content_hash on the same book row, keeping tags/bookmarks/reading
    state) → insert loose book. Delete+recreate across scans resurrects via
    either branch, so no content_hash UNIQUE violations.
  - **Source watching**: new `FolderWatcher` (FSEvents wrapper, per-file
    events, works under ~/Library/Mobile Documents since fileproviderd
    writes real files; stream context retains the watcher until stop()).
    LibraryModel watches watched folders + the Calibre root → debounced
    (2s latency + 1s task) full reload, so new Calibre books and new/changed
    /removed watched PDFs land without touching Reload. Watchers arm only in
    real app instances (never tests/injected models); re-armed on
    attach/detach/add/remove. AppDelegate now materializes LibraryModel.shared
    at launch and runs one reload — watching must not wait for the Library
    window to first open.
  - **Live document auto-reload**: SessionCoordinator watches the provider's
    resident paths (re-armed via `DocumentProvider.onResidentPathsChanged`);
    a changed open file → 700ms debounce → `provider.reloadFromDisk(path:)`
    (validating parse; retries 0.5/1/2s while mid-write or momentarily
    missing, stale doc stays usable; re-downloads if the change was an
    eviction) → `documentGenerations[path] += 1`. ActivePDFView ids include
    the generation, so every pane showing the doc tears down (capturing
    position) and rebuilds onto the fresh document (position restored,
    page clamped by go(to:in:)). The reload also re-runs syncScannedFile so
    the book identity follows the new bytes even outside watched folders.
    Settings > Reading kill switch `AutoReloadDocumentsEnabled` (default on),
    applied live.
  - Also fixed in passing: `appendImportedItems` now excludes Calibre rows
    that carry a backfilled content hash — they double-listed as imports
    once anything (resolver/indexer/scan) backfilled a hash onto them.
  - Tests (420 total, +24): ScannedFileSyncTests (store decision table incl.
    resurrect + calibre-hash cases), WatchedFolderScanTests (recursive
    import, regeneration keeps id+reading state, fingerprint skip, delete →
    tombstone → recreate → resurrect, move follows, folder removal,
    no-calibre-duplicate), DocumentReloadTests (in-place swap, non-resident/
    missing refusals, resident-paths hook, coordinator generation bump),
    FolderWatcherTests (live FSEvents temp-dir test, idempotent stop).
  - Parked for later rounds: iOS watched folders (needs security-scoped
    bookmarks), per-folder auto-tag, Calibre-side tombstoning of books
    removed from metadata.db (upsert-only today, pre-existing).

- [x] **UI-13** Round 19 (2026-07-09): ⌘⇧T reopens closed tabs AND windows
  (browser convention).
  - **Reopen stack**: `SessionCoordinator.recentlyClosed` (in-memory, this
    run only, capped at 30) records every real close, most recent last.
    Tab closes flow in via `ReaderWindowModel.onTabClosed` (fired from
    `closeTab` with the strip index; `closeTab` now folds the live scroll
    position into the TabState first — the view's teardown capture arrives
    after the tab left `tabs`, too late for the stack). Window closes are
    recorded in `windowClosed` ONLY when other windows remain — the
    last-window close keeps its round-5 stash (Dock reopen / relaunch),
    recording it too would restore it twice. Detach/move-between-windows
    (`detachTab`) never records: the tab isn't closed, it moved.
  - **Restore** (`reopenLastClosed()`): a tab returns to its source window
    at its old strip index (activated + window brought front) when that
    window still lives, else to the focused reader window; with no reader
    window at all it stages a fresh window (pendingRestore) and returns the
    ID for `openWindow(id:"reader", value:)` — same contract as the other
    staging APIs. A window restages its full WindowState (frame, tabs,
    split, active tab) under its old ID. Position, zoom, and history come
    back intact either way.
  - **Command**: `tabs.reopenClosed` (⌘⇧T, File menu next to Close
    Tab/Close Window, palette, help overlay, rebindable). CommandContext
    grew a `session: SessionCoordinator?` field (nil in bare test contexts)
    so the command is testable against instance coordinators; ReaderCommands
    / ReaderWindowView / WindowKeyEventBridge pass `.shared`.
  - Also fixed in passing: iOS build was broken since round 18 —
    `LibraryModel.sourceWatcher: FolderWatcher?` referenced the
    macOS-only FolderWatcher without an `#if os(macOS)` gate (uses were
    gated, the property declaration wasn't). scripts/verify.sh step 3
    catches it; it now passes again.
  - Tests (428 total, +8): SessionCoordinatorTests (reopen to source window
    at old slot with position, fallback when source window gone, whole-window
    restage with tabs+positions, last-window close NOT double-recorded,
    reopen with zero windows stages fresh, moved tabs not recorded, history
    survives), CommandRegistryTests (⌘⇧T round-trip through the table +
    availability tracks the stack).
  - Verified: scripts/verify.sh all green (launch smoke included); the
    whole restore path below the keystroke is unit-covered. Live ⌘⇧T
    keypress hand-check still TODO.

### Phase C
- [~] **M16** iOS app: minimal tabbed reader + session restore DONE
  (simulator-verified); F-1 added library/search/theming/link-history UI.
  **Simulator hand-run 2026-07-09** (iPhone 17 sim, iOS 26.5):
  VERIFIED live — session restore from a seeded Documents/session.json
  (two tabs, pathHint fallback, correct page landing in Axler), tab strip
  rendering + active highlight, control-bar states, and all three forced
  themes: dark difference-invert (inverted images, dark pages) and sepia
  multiply-tan PIXEL-verified (page body 247,240,231 ≈ Claude tan vs pure
  white in light) via the shared BluefoldTheme UserDefaults key. NOT yet
  verified (simctl can't synthesize taps): library sheet/folder picker,
  FTS search UI, link-tap history, dataless download — needs hand-testing
  or a future iOS XCUITest target. Seeding recipe:
  simctl install → copy PDFs into the app container's Documents → write
  session.json (schemaVersion 1, tabs with pathHint only) → simctl launch
  → simctl io screenshot; theme via `simctl spawn <sim> defaults write
  com.cable729.bluefold.ios BluefoldTheme <raw>`. CloudKit sync UI pending
  (M15 Settings section is macOS-only so far).
- [~] **M17** XCUITest smoke suite EXISTS (`App/macOSUITests/`, `BluefoldUITests` target hand-added to the pbxproj + shared scheme). Passing END-TO-END locally: quit-and-relaunch session restore, drag-reorder (real synthesized drag), and the assert-only render smokes (`RenderSmokeUITests`: two-row strip + group header, split view from a restored session). Tear-off and cross-window drag tests are written but locally synthesized input can't drive them reliably (see XCUITest notes below) — they're unit-tested at the state-machine level (`TabStripDragTests`) and left to CI for end-to-end. Run locally with a fresh app bundle ID: `xcodebuild ... test BLUEFOLD_BUNDLE_ID_SUFFIX=.uitest$(date +%s)`; full-suite local runs can degrade mid-run (see XCUITest notes below) — spot-check single tests locally, full passes belong to CI. `VERIFY_UITESTS=1 ./scripts/verify.sh` runs the suite as opt-in step 5. Remaining: CI job B (xcodebuild UI tests + iOS sim build) once the CI hang below is resolved.
- [~] **M18** code side DONE (2026-07-08): Settings window ⌘, (AppSettings:
  LRU capacity live-applied via SessionCoordinator, indexing + OCR toggles
  with per-pass IndexingService recreation, theme picker, Calibre folder
  attach/detach via LibraryModel.shared, keybindings + deep-link sections),
  scripts/release.sh (build→Developer-ID sign→DMG→notarize→staple, each
  step skippable; DMG path exercised locally), .github/workflows/release.yml
  (v* tags + workflow_dispatch only — inert while CI billing is dead;
  secrets documented inline), CONTRIBUTING.md.
  **v0.1 SHIPPED 2026-07-10**: repo public, website live at
  https://cable729.github.io/bluefold/ (static site on the `gh-pages`
  branch), signed + notarized universal DMG published as release v0.1 on
  this repo — the site's download button reads
  /releases/latest/download/Bluefold.dmg and shows the version via the
  releases API. scripts/publish-release.sh cuts subsequent releases
  (refuses unnotarized DMGs via `stapler validate`); docs/RELEASING.md is
  the runbook. Still open: README/site screenshots, Gatekeeper spot-check
  on a second Mac, release workflow secrets for CI releases (optional).

## ⚠️ CI: BLOCKED ON BILLING; underlying deadlock diagnosed but not yet pinpointed (2026-07-08)
Chronology of findings, most important first:
1. **CI is dead until billing is fixed.** As of ~09:57 UTC every queued job
   fails with GitHub's verbatim message: "The job was not started because
   recent account payments have failed or your spending limit needs to be
   increased." The pre-hardening zombie runs (multiple concurrent 6-hour
   hangs, macOS billed at 10x) exhausted the included minutes. Fix in
   GitHub Settings → Billing & plans (raise the spending limit or wait for
   the monthly reset). Nothing runs — including PR checks — until then.
2. **The underlying failure is a whole-runner test deadlock, not slowness:**
   a PTY-instrumented probe showed the build completing in 80s, then all
   116 tests printing "started" in the same instant and NOT ONE completing
   in 23 minutes (suite takes <1s locally). Vision/OCR was the original
   suspect but the all-at-once pattern points at something process-wide —
   plausibly AppKit/WindowServer access in the runner's session (locally,
   denying WindowServer via sandbox-exec breaks even test *discovery*).
3. **PR #1 (`ci-hardening`) is ready and MUST land before any other push**:
   job timeouts, cancel-in-progress concurrency, SwiftPM build cache,
   workflow_dispatch, per-module test execution with 300s kill-timeouts
   (the next run pinpoints WHICH module(s) deadlock), and CI job B —
   XCUITest smoke + iOS simulator build (completes M17's CI side).
4. After billing + merge: read the per-module run's log; gate or fix the
   deadlocking module(s); then delete this section.

## Environment notes
- Xcode 26.6 installed, license accepted — plain `git`/`swift`/`xcodebuild` all work. (`scripts/test-clt.sh` remains for CLT-only environments but is no longer required.)
- App builds: `xcodebuild -project App/Bluefold.xcodeproj -scheme Bluefold -configuration Debug -derivedDataPath .build/DerivedData build`. The pbxproj is hand-authored (objectVersion 77, synchronized folder groups) — adding files under App/macOS/ requires no pbxproj edits.
- Signing/notarization needs an Apple Developer account added in Xcode > Settings > Accounts (GUI step); runbooks in docs/RELEASING.md and docs/SYNC.md.
- Test corpus guidance: use real textbooks, including scanned/ugly ones (search there needs M13b OCR); Axler "Linear Algebra Done Right" is the reference PDF for internal-link behavior; math notation extracts messily — search and snippets must tolerate it.

## Key design constraints (do not violate)
- Never write to Calibre's metadata.db; never open the live file (copy first).
- Only the ON-SCREEN tabs may hold PDFViews (the active tab, plus the split
  pane's tab when a window is split); PDFDocuments live in a small LRU with
  both on-screen paths pinned.
- NavigationHistory in ReaderCore is the single source of truth for back/forward (not PDFView.goBack).
- Session restore is custom (session.json), not @SceneStorage/NSWindow restoration.
- All synced tables carry modified_at + soft-delete tombstones.

## XCUITest local-run notes (macOS 26)
OS/tooling behaviors, not app bugs:
- Direct-exec launches of a bundle ID can come up windowless after an
  unclean kill of a prior instance (LaunchServices launches via
  `open`/Finder/Dock are unaffected); UI tests kill stray instances
  per-test and take a `BLUEFOLD_BUNDLE_ID_SUFFIX` build override (app
  target only), and `scripts/verify.sh`'s direct-exec launch smoke should
  be retried via `open` if it false-fails.
- Full local XCUITest suite runs can degrade mid-run; spot-check single
  tests with a fresh suffix
  (`-only-testing:… BLUEFOLD_BUNDLE_ID_SUFFIX=.uitest$(date +%s)`) and
  leave full-suite passes to CI's fresh runners.
- Locally synthesized plain `click()`s and coordinate-targeted drags may
  not be delivered (element→element drags inside the key window work);
  tear-off/cross-window drag coverage is unit-level (`TabStripDragTests`,
  crafted NSEvents in real windows) with end-to-end left to CI.

## PDFKit destination pathologies (macOS 26) — learned the hard way, 2026-07-08
Real-world PDFs (especially Pearson-style scans) break
naive PDFKit navigation. Rules encoded in the codebase; do not regress:
1. **`PDFView.go(to:)` silently no-ops** for destinations whose point is
   outside the page's crop box OR carries kPDFDestinationUnspecifiedValue.
   `go(to: PDFPage)` no-ops too — it wraps an unspecified destination
   internally. ALWAYS navigate with an explicit in-crop point
   (`ReaderPDFView.go(to:in:)` synthesizes crop-top for point-less jumps).
2. **Outline/link destination points can be garbage**: negative x, outside
   an offset crop box (crop origin (144,110) inside a bigger media box),
   or unspecified — even in well-made books' front matter.
   `ReaderPDFView.validatedPoint` (12pt slop) gates every incoming point;
   `OutlineNode.tree` synthesizes concrete crop-top points for the rest.
3. **PDFView parks the view a few points BELOW a requested anchor**
   (page-break margins) — position comparisons need landing slop
   (`OutlineNode.sameSpotTolerance` = 40pt, identity-based stepping).
4. **Chapter headings and their first section often share one anchor** —
   ordered section stops dedupe same-spot entries (2pt).
5. **Offset crop boxes break page-space geometry in tile contexts**:
   ThemedPDFPage must fill `context.boundingBoxOfClipPath`, never
   `bounds(for: box)`.
6. Non-PDFKit but adjacent: SwiftUI **enablement must read observable
   state** (liveNavEntry isn't tracked — buttons gray forever), never
   mutate observable state inside makeNSView (defer a runloop turn), and
   UserDefaults `register()` is invisible to CFPreferences readers like
   NSToolTipManager — use `set()`.
7. **Named destinations (2026-07-08, deep-linking session)**: PDFKit has NO
   working public API — the private `namedDestination:` selector returns
   nil. Resolve via the CGPDF catalog (`NamedDestinations`). WRITING side:
   `CGPDFContext addDestination`/`setDestination` silently write nothing —
   test fixtures hand-write a raw PDF name tree
   (Tests/ReaderUITests/DeepLinkResolveTests.swift).
Probe scripts for new pathologies live in the fix-session pattern: load
the actual book with PDFKit in a scratch swift script and print
destinations/crops before theorizing.

## Handoff docs (read these first in a fresh session)
- [ARCHITECTURE.md](ARCHITECTURE.md) — module map, memory model, data stores, diagrams
- [DECISIONS.md](DECISIONS.md) — why things are the way they are
- [BACKLOG.md](BACKLOG.md) — feature-request rounds + remaining roadmap
- `./scripts/verify.sh` — the one-command quality gate (tests + both app builds + launch smoke)

## Next step
1. **Maintainer actions pending** (require account access; do not automate):
   - **Activate iCloud sync** (M15 code is done): the 15-minute signing
     runbook in docs/SYNC.md (add an Apple ID in Xcode, add the iCloud
     capability with container `iCloud.com.cable729.bluefold`, run, toggle
     sync on, verify in CloudKit Console; deploy schema to Production
     before any release build).
   - TODO: merge duplicate book rows (Calibre + pre-mirror auto-registered
     twins; the auto rows hold reading state, the Calibre rows hold tags;
     palette dedupes by path so it's cosmetic; back up library.db before
     running). NOTE: sync deliberately never merges these rows either
     (test-pinned).
   - **Fix GitHub Actions billing** (Settings → Billing & plans): still
     dead as of 2026-07-09 — even merged-PR runs fail in seconds with the
     spending-limit message ("job was not acquired" on the one run that
     queued). PR #1 (hardening) and PR #2 (frugal) are both MERGED, so the
     first billed run will be the per-module one that names the deadlocking
     test module — read its log, gate or fix that module, then delete the
     ⚠️ CI section above.
   - Still parked: first-launch shortcuts HUD; sub-tag context menu
     (right-click tag → New Sub-Tag / Rename).
2. **Hand-verification debt**: ⌘⇧T reopen (round 19), F-1 wave UI
   (tag colors, list/sectioned views, keybindings.json flow, split
   left/right + drag-to-split, Copy Link commands), iOS part 2 on a
   simulator/device, plus the older items: ⇤ ⇥ full backward trip through
   a scan, sidebar follow-mode feel, ⇧⏎/⌘⏎ palette variants. VERIFIED
   2026-07-08: tab tear-off + cross-window drags; deep links land
   exactly. VERIFIED 2026-07-10: default-PDF-viewer prompt (Info.plist
   claims com.adobe.pdf; launch alert + Settings section; Finder file
   opens route through DeepLinkRouter; prompt suppressed under
   BLUEFOLD_SESSION_DIR so harnessed launches stay quiet) — shipped in
   v0.2.
3. After billing: CI job B (XCUITest + iOS sim build) and wire UI tests
   into scripts/verify.sh (M17's CI side).
4. Then M18 v0.1 remainder: mint Developer ID cert + notary
   credentials (steps in scripts/release.sh output), README screenshots
   (use Axler), make the repo public, tag v0.1. App icon DONE (round 20).
