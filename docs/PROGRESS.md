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

- [x] **UI-14** Round 20 (2026-07-11): "Cloth & Paper" design-system
  redesign (from the owner's Claude-design mockup zip) + per-pane tab bars.
  - **Design tokens** (`DesignSystem.swift`): `DesignPalette`
    light/dark/sepia — warm-paper chrome (light `#F2EBE2→#E8E0D5`, sepia
    `#EEE1CE→#E5D6BD`), NAVY dark chrome band (`#1A2C47→#132037` over
    `#1B1A18` content), one accent `#2E7FE5`, ink `#0E2849`. `BookTint`:
    six-color cover palette hashed per book path — FNV-1a needs a
    splitmix64 finalizer (`BookTint.mix`) because every path ends ".pdf"
    and the raw low bits funneled whole libraries into one bucket.
    ThemeManager now paints EVERY theme's titlebar (transparent titlebar +
    chrome background color); `pdfBackground` = palette content color.
  - **Tab strip redesigned** (`TabStripView.swift` rewrite): same-book runs
    share one tinted LOZENGE — swatch + book title once, a chapter cell
    per tab; the active cell is a translucent-ink full-cell fill with ✕
    (mockup's "quiet fill in the divider's ink"). Cells take natural text
    width (measure with the SEMIBOLD font — the active cell renders
    semibold and regular-width metrics truncated it; and mirror the
    constraint chain incl. the always-reserved ✕ slot). On overflow cells
    shrink to a 44pt floor, then the strip SCROLLS horizontally
    (`TabStripScrollView`, Firefox/Chrome behavior; vertical wheel
    scrolls it; active tab auto-scrolled into view). Drag machinery
    (reorder/tear-off/failsafe monitors/ghost) kept; during drags
    lozenges dissolve to uniform singleton cells so slot math stays
    arithmetic.
  - **Per-pane tab bars** (owner request): each split pane owns a strip.
    Model: `splitTabIDs: [UUID]` ordered membership on WindowState
    (backward compatible — old files' `splitTabID` restores a one-tab
    strip; a corrupt all-tabs-split file collapses to one strip),
    `splitTabID` = the split strip's ACTIVE tab. Pane-aware
    select/close/reorder/adopt/cycle/⌘1-9; `moveTab(id:toPane:at:)` for
    cross-pane strip drags; `TabStripRegistry` keys by `TabStripID`
    (window + pane) so tear-offs drop onto either pane of any window.
    Pane headers and the split dot ARE GONE — the non-focused pane dims a
    whisper (black 6%, hit-testing off) instead. ⌘\ etc. unchanged.
  - **Restyles**: status bar (chrome gradient, ink foreground, mono page
    chip), reader sidebar (warm surface, accent-soft current-section row),
    library (serif scope header + book count, warm sidebar, content
    background, generated tinted serif covers for cover-less books).
  - Tests 478 (+20: SplitStripMembershipTests suite, strip lozenge/overflow
    layout, chrome-follows-theme updated to all-themes-tinted).
    RenderSmoke XCUITests updated (two strips in a split window; lozenge
    grouping). Verified: scripts/verify.sh green; hand-checked an isolated
    instance (BLUEFOLD_SESSION_DIR + fixture session) across
    light/dark/sepia via screenshots — lozenges, per-pane bars, focus
    dimming, library grid all render as designed.

- [x] **UI-15** Round 21 (2026-07-11, after v0.3 tag): design-system chrome
  round 2 + cover-cap tab experiment (owner feedback list).
  - **Top bar**: `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`
    on the reader and library scenes — one LOW titlebar row, no window
    title (the strip names what's open), matching the mockup band.
  - **Bottom bar**: mockup layout — borderless layout-mode icons at left
    (active = accent), the ⇤ ‹ [mono chip] of N › ⇥ cluster CENTERED via
    ZStack (not flowed), theme menu right.
  - **Tab cells** show the DEEPEST breadcrumb component, tail-truncated
    ("13.2 Algebraic…", never "…aic Extensions") —
    `deepestBreadcrumbComponent` in TabBarView.swift.
  - **Pane dimming** softened 6% → 3.5%.
  - **Overflow affordance**: edge fade + chevron exactly on the edges
    hiding tabs. Two hard-won facts: (1) NSScrollView re-tiles its own
    subviews — overlays added to it get buried; they live in
    `TabStripContainerView` as SIBLINGS above the scroll view. (2) The
    chevron must sit on a SOLID outer band (3-stop gradient), not on
    half-faded tab text. Visibility tracks clip-bounds notifications
    (reflectScrolledClipView alone went stale).
  - **Cover-cap tabs** (owner experiment): the lozenge's leading edge is
    the book's FIRST PAGE as a full-height left-rounded sliver
    (`coverCapWidth` 21pt) instead of swatch + title text; hovering it
    unfolds `TabCoverPreviewPanel` below the tab — flat (no shadow,
    square top corners against the strip, rounded bottom), enlarged
    cover + title, one shared panel, hidden on click/drag/scroll/strip
    updates. `TabCoverThumbnails` renders page 0 via its OWN PDFDocument
    off-main (never the provider's LRU), cached per path for the app's
    lifetime. Book tint remains the placeholder + lozenge fill.
  - Also: ThemingTests pinned against the live system appearance (the
    suite failed at night when the system auto-flipped dark —
    `overrideSystemAppearance` now pins the auto case).
  - Tests 482 (+affordance state machine, deepest-component, fade z-order).
    Verified: scripts/verify.sh green; hand-checked screenshots (compact
    bar, centered cluster, cover caps + hover panel, chevrons at rest and
    mid-scroll).

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
- [~] **M16b** iPadOS port (2026-07-11): the iOS target already shipped
  `TARGETED_DEVICE_FAMILY = "1,2"`, so the iPad gap was experience, not
  build. Added, all in `App/iOS` (no pbxproj edits — synchronized
  folders): **hardware-keyboard commands** (`ReaderCommandsIOS`, rendered
  by the iPadOS 26 menu bar and the hold-⌘ HUD; chords mirror
  docs/KEYBINDINGS.md — ⌥⌘O open file, ⌘⇧L library, ⌘W close tab,
  ⌘[/⌘] history, ⌘⇧[/⌘⇧] adjacent tab, ⌘1–8/⌘9 tab-by-position/last,
  ⌥⌘1–4 layouts, ⌘F find; ⌘O/⌘P left unbound, reserved for the palettes),
  with sheet flags lifted into `ReaderChromeModel` so scene-level commands
  and the control bar drive the same state; **page layouts honored on
  iOS** (PDFKitView now respects `tab.displayModeRaw` instead of
  hardcoding continuous; control-bar layout menu + `setDisplayMode` apply
  changes to the live view in place); **system find**
  (`isFindInteractionEnabled` + `presentFindNavigator` via the
  `ActivePDFNavigating` protocol, control-bar magnifier button); **←/→
  hardware-arrow paging** in `ReaderPDFViewIOS.keyCommands`
  (`wantsPriorityOverSystemBehavior`, matching the macOS bare-arrow rule;
  not a history event); **pointer hover effects** on control bar + tab
  chips; **library sheet at `.presentationSizing(.page)`** on iOS 18+
  (iPad's default form sheet is too narrow for the covers grid).
  **Simulator-verified 2026-07-11** (iPad Pro 11-inch (M5) sim, seeded
  session.json per the M16 recipe — NOTE the recipe's "pathHint only"
  understates it: TabState decode also requires `scaleFactor` and
  `displayModeRaw`, and reinstalling the app moves the data container so
  absolute pathHints must be re-seeded): session restore on iPad, new
  control-bar buttons, and twoUpContinuous restored from a seeded
  `displayModeRaw: 3` rendering side-by-side pages. NOT yet verified
  (simctl can't synthesize taps/keys): menu-bar/⌘-HUD chords, find
  navigator UI, pointer hover — needs an owner hand-run with a paired
  keyboard/trackpad or an iOS XCUITest target. Single-scene by design:
  app state is App-level @State shared by every scene, so
  `UIApplicationSupportsMultipleScenes` stays off until per-scene models
  exist (see BACKLOG).
- [~] **M16c** iPad round 2 (2026-07-12, owner feedback round): the Cloth &
  Paper design system + the macOS interaction vocabulary, translated to
  touch. Shared layer: `DesignSystem`, `OutlineNode`, `BookResolver`,
  `PageArrows` un-gated from macOS and made public (`PlatformColor`
  typealias bridges NSColor/UIColor; `DesignPalette.current` stays
  macOS-only — iOS resolves via its ThemeStore). iOS chrome rebuilt:
  `ReaderTopBarIOS` (sidebar toggle + history arrows whose long-press menus
  list the jump stack by section — the right-click translation),
  `TabStripIOS` (book-tinted lozenges, title over deepest breadcrumb
  component tail-truncated, drag reorder, long-press context menu, drop
  targets), `ReaderBottomBarIOS` (mockup status bar; compact width
  collapses layouts into one menu and drops fit/section-skips),
  `SidebarIOS` (Contents tree + Bookmarks; fuzzy filter field over section
  paths = the ⌘P stand-in; always-on follow: highlight + ancestor
  auto-expand + scroll-into-view; long-press/drag sections to new
  tab/split), split pane (`splitTabID` persisted; ⌘\ duplicate-toggle,
  chip/section drop zone on the trailing edge, slim header w/ close),
  links (⌘-tap = background tab; long-press = Open Here / New Tab / Split
  via UIEditMenuInteraction), bookmarks on iOS (BookResolver + overlay DB,
  ⌘D + sidebar button, delete via context menu), iPhone reading mode
  (chrome hides on scroll-drag, tap toggles; compact sidebar = sheet).
  Position tracking mirrors macOS's split: `currentPage` → crash-safe
  page index + status number; `currentDestination` (scroll-tick KVO,
  throttled) → live breadcrumb/follow ONLY (currentDestination reads a
  page ahead at boundaries — first build showed p.6 standing on p.5).
  **Simulator-verified 2026-07-12** (iPad Pro 11" + iPhone 17 sims,
  `--sidebar` launch hook added because simctl can't tap): light + dark
  chrome, sidebar follow highlight/expansion, split restore from session,
  live breadcrumbs in the strip, compact iPhone bar. NOT sim-verifiable
  (needs touch/keyboard): drags, long-press menus, chrome auto-hide,
  ⌘-chords — owner hand-run list. Remaining iOS gaps → BACKLOG:
  reading-state persistence, follow-mode toggle, thumbnails sidebar mode,
  multi-scene.
- [~] **M16d** iPad/iPhone round 3 (2026-07-12, owner feedback on round 2):
  **iPhone**: chrome tap-toggle now a dedicated recognizer
  (`chromeTap`, simultaneous + non-cancelling; the round-2 `touchesEnded`
  override never fired — PDFKit subviews consume touches) with an
  unhide-on-tab-change safety; section-skip ⇤ ⇥ added to the compact
  cluster; status-bar scroll-to-top pushes jump history (UIScrollView
  delegate PROXY forwarding to PDFKit's own delegate — the only reliable
  hook); THEME-SWITCH POSITION LOSS fixed: same-tab view rebuilds restore
  from `model.livePosition`, not TabState (SwiftUI can build the
  replacement view before dismantling the old one, so the captured state
  is stale — remember this for any `.id`-keyed representable). **Find
  moved into the sidebar** (Contents/Bookmarks/Find segments; ⌘F and the
  magnifier open it; FindController un-gated from macOS — streaming find,
  typing never navigates, tap = jump+push+highlight). **Tab strip = the
  macOS main-app look**: adjacent same-book tabs group into ONE tinted
  lozenge with the book's page-0 as a rounded left cap
  (`TabCoverThumbIOS`, off-main render on a private PDFDocument, cached);
  cells show section breadcrumbs only; tapping the CURRENT cell opens the
  cover preview panel (the macOS hover panel — where the book name
  lives), `.presentationCompactAdaptation(.popover)`; context menu grew
  Close Tabs to the Left/Right (also added on macOS by a parallel agent:
  `closeTabsToLeft/Right(of:)` + strip menu + palette commands + 9
  tests). **Links draggable** (UIDragInteraction vending the section
  payload; drop on strip = new tab, drop zone = split). **Library**:
  covers fall back to a page-0 render (CoverThumb) and then to a
  BookTint+title generated cover; context menus grew New Tag… / New
  Collection… create-and-apply alerts. Layout trap for the strip: Color
  subviews (dividers/placeholder tints) have no intrinsic height — a
  horizontal ScrollView goes greedy and fills the screen; hard-cap the
  strip (50pt) and lozenges (40pt). Simulator-verified on both devices
  (grouping/caps/sidebar-find/compact cluster); drag/long-press/
  scroll-to-top/tap-toggle remain owner hand-tests (simctl can't touch).
- [~] **M16e** Round 4 (2026-07-12, owner feedback): **library freeze
  fixed** — `LibraryModel.indexLibrary()` is `@MainActor`, so the
  candidate prep (128 KiB read + SHA-256 content hash PER BOOK, `isLocal`
  stats, `isIndexed` lookups) ran on the main thread and froze the UI for
  seconds when the library opened against a large iCloud Calibre folder;
  extracted into `prepareIndexingCandidates` (nonisolated static, run in a
  detached `.utility` task), the per-book `indexDocument` loop stays on
  main but yields on every await. **Split orientation**: `SplitAxis`
  (`.horizontal`/`.vertical`) added to `ReaderCore.WindowState.splitAxis`
  (optional, nil = horizontal, backward-compatible). iOS `SplitContainerIOS`
  lays primary+split along the axis with a draggable divider that CLOSES
  the shrunk pane at either extreme, plus a per-pane top-trailing close
  button; iPhone splits are always vertical (one tab row — the tab strip
  never stacks), iPad chooses via the top-bar Split menu (Split Right /
  Split Bottom / re-orient / close). Verified on both sims (seed
  `splitAxis:"vertical"`). macOS vertical split shipped in parallel (see
  M16e-mac). **NOTE — the desktop simultaneous 2-D grid (left/right AND
  top/bottom at once) is DEFERRED**: it needs a pane-tree/quadrant model
  (a real ReaderCore + renderer redesign) and is tracked in BACKLOG; this
  round delivers single-split ORIENTATION on every platform. **iOS tab
  polish**: `refreshBreadcrumb(forTabWithID:)` fills a tab's section on
  open/restore/download (was "p.N" until first scroll — the macOS app does
  this on view attach); strip fades under the leading/trailing edges;
  tapping the **cover cap** shows the book preview WITHOUT selecting (text
  cells select). **iPhone lock button** (top bar) pins the chrome visible.
  Key iOS traps recorded: (1) a horizontal `ScrollView` of Color-backed
  cells goes height-greedy — hard-cap the strip; (2) the split divider is
  a `GeometryReader` fraction, reset to 0.5 on `splitTabID` change.
- [~] **M16f** Round 4b (2026-07-12): **macOS top/bottom split** landed
  (agent) — `ReaderWindowModel.splitAxis` + `VSplitView`/`HSplitView`
  branch in `ReaderWindowView`, `view.splitDown` / `view.splitOrientationToggle`
  commands, persisted via `WindowState.splitAxis`; per-pane horizontal tab
  strips preserved (panes stack, strips never do). **iPad "scroll lock"
  bug fixed** — toggling a page-layout/fit mode left the previous mode's
  zoom+offset, so the page rendered tiny in a corner; the live
  `apply(displayMode:)` now captures the position, toggles `autoScales`
  (off→on) to force a re-fit, then re-anchors via the shared `go(to:in:)`
  (and `setDisplayMode` persists `autoScales = true` so a layout switch
  isn't saved as a fixed zoom). **iOS tag/collection system** — the macOS
  library sidebar, ported: `LibrarySidebarIOS` (All Books / Untagged /
  Not-in-a-Collection scopes + hierarchical Tags and Collections trees
  with color dots, inline New / New-Sub / Rename / Color / Delete via
  `+` headers and row context menus), driving `LibraryModel.filter`. iPad
  shows it as the leading column of a `NavigationSplitView`; iPhone opens
  it as a `.medium/.large` sheet from a Filter toolbar button. New model
  API: `renameTag(id:to:)`, `renameCollection(id:to:)` (+ store
  `renameCollection`). `TagColor` un-gated (presets + hex→Color
  cross-platform; the NSImage swatch stays macOS-only). `--library`
  launch hook mirrors `--sidebar`. **Verified on both sims against a
  realistic library** (the iPad sim's sandbox already had a Calibre
  mirror): sidebar tree + colors + covers render, and indexing runs in
  the background ("Indexing for search… 3/5") with the UI responsive —
  the freeze fix confirmed live. Deferred (BACKLOG): desktop 2-D grid,
  iPad tab drag-reorder verification, tag drag-to-reparent, sidebar
  drag-to-tag.
- [~] **M16g** Round 5 (2026-07-12, big owner-feedback batch): **reading
  state** — opening a book resumes its last-viewed page on every platform
  (`LibraryModel.lastReadEntry`; macOS `openItem` + iOS library-open use
  it; iOS now WRITES reading_state on capture/save, which it never did).
  **History/nav fixes** — `PDFView.currentNavEntry()` falls back to
  `currentPage` when `currentDestination` is briefly nil (a link tap no
  longer sends "back" to the document top); disabled back/forward guard
  their actions (a disabled iOS Menu still fires primaryAction); the
  status-bar **scroll-to-top gesture removed** (`scrollsToTop = false`);
  background-opened tabs get their section breadcrumb. **Split polish** —
  panes/gaps use the theme background (no white flash); the divider drag
  is **deferred** (a ghost accent line tracks the finger; panes resize
  once on release, killing the per-frame PDF relayout jitter); iPhone can
  drop a tab/section/link on the BOTTOM edge to split top/bottom and has a
  "Split Bottom" tab-menu item. **iPad display-mode ("scroll lock") fix**
  was M16f. **Follow-section** — collapses everything except the current
  section's ancestor path (both platforms); iOS gained a follow toggle.
  **Library** — Finder-style layouts (Large/Small covers, List; toolbar
  menu, persisted), search results ordered Tags & Collections → books →
  in-book hits, and drag a book onto a sidebar tag/collection to apply it.
  **System integration** — `App/iOS/Info.plist` (merged like macOS)
  registers Bluefold as a PDF viewer / open-in-place + share target and
  the `bluefold://` scheme; `onOpenURL` opens incoming PDFs. Verified on
  both sims (split theme bg, list layout, library sidebar tree). NEEDS an
  owner device hand-test (simctl can't drag/tap): tab drag-reorder (wiring
  + `move(before:)` fixed, but the SwiftUI draggable+contextMenu combo is
  fragile in a grouped clipped strip — a UIKit strip is the fallback),
  divider-drag feel, drop-to-split, share-sheet appearance, reading-state
  resume. Cross-device tag visibility still needs CloudKit sync (M15, not
  activated — iOS/macOS have separate library.db).
- [~] **M16h** Round 6 (2026-07-12, split-drag regression fix): the
  drag-to-split drop target added in a00bec5 was DEAD. `SplitZoneDropView`
  was a full-page overlay whose `ZStack` is empty at rest, so the host view
  is hit-transparent and UIKit's drag hit-test never routed the drag to its
  `.onDrop` (the tab strip works because its content is hittable). Replaced
  it with a `SplitZoneDrop` modifier that hangs `.onDrop` on the pdfView
  itself, reads pane size from a `.background` GeometryReader probe, and
  shows the half-page highlight as a non-hit-testing overlay. The split
  MACHINERY was never broken — confirmed by driving `toggleSplit` /
  `setSplitAxis` / `closeSplit` through a temporary `--autosplit` launch hook
  + simctl screenshots (all render correctly; the owner's "menu buttons do
  nothing" report was the drag failure, not a menu-logic bug). Also: the
  split **divider** now floats a hairline + grab handle on the seam with the
  panes flush (no 24pt gap band), and the iOS sidebar follow-section toggle
  uses the macOS crosshair symbols (`scope` / `circle.dashed`) instead of the
  location arrow. **Owner hand-tested drag-to-split on the iPad Pro 13" sim —
  works.** 513 tests green, both schemes build. Shipped as `8a39ae7`.
- [~] **M16i** Round 7 (2026-07-12, owner feedback): **swipe-to-turn in the
  non-continuous modes**. With `usePageViewController(false)`, PDFKit only
  scrolls across a page boundary in the two *continuous* modes; in
  `.singlePage`/`.twoUp` it snaps one screen and never advances on touch, so
  pages could only be turned with a hardware keyboard — no gesture worked.
  Added four `UISwipeGestureRecognizer`s to `ReaderPDFViewIOS` (flick
  left/up = next, right/down = previous). Three details each mattered:
  (1) **one recognizer per direction** — a single recognizer with a combined
  `[.left, .up]` direction mask only fired for one of its directions (left
  turned the page, up silently didn't). (2) Gated to the paged modes in
  `gestureRecognizerShouldBegin` (`isPaged`) and whitelisted in
  `shouldRecognizeSimultaneouslyWith` so PDFKit's own recognizers don't block
  them. (3) The inner scroll view claims a *vertical* drag for in-page
  scrolling and cancels the swipe, so its `panGestureRecognizer` now
  `require(toFail:)`s each page swipe — a fast flick turns the page, a normal
  (slower) scroll drag fails the swipe instantly and scrolls; harmless in the
  continuous modes where the swipes are gated off and fail at once.
  **Simulator-verified 2026-07-12** (iPad Pro 11", single-page): left→677,
  up→677, down→676 all turn; two-up 661/662→663/664; continuous-mode
  scrolling unaffected (664→665 drag).
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
   v0.2. VERIFIED 2026-07-12 (M16h): iOS drag-to-split (tab chip / sidebar
   section onto a page half, all of L/R/T/B) after the hit-transparent
   drop-target fix. VERIFIED 2026-07-12 (M16i): iOS swipe-to-turn in the
   non-continuous modes — single-page left/right/up/down all turn the page,
   two-up advances, continuous-mode scrolling unaffected (iPad Pro 11" sim).
3. After billing: CI job B (XCUITest + iOS sim build) and wire UI tests
   into scripts/verify.sh (M17's CI side).
4. Then M18 v0.1 remainder: mint Developer ID cert + notary
   credentials (steps in scripts/release.sh output), README screenshots
   (use Axler), make the repo public, tag v0.1. App icon DONE (round 20).

- [x] **UI-16** Round 22 (2026-07-11): cover-colored tabs + richer preview
  (owner feedback on the live round-21 build).
  - **CoverPalette**: 1–3 dominant colors from the page-0 render —
    24×32 downsample, 4-bit/channel histogram, page-white AND text-ink
    pixels skipped, greedy distinct-color pick (RGB distance > 0.25),
    empty result for text pages (< 1/8 art pixels) so the hash tint
    remains the fallback. Lozenge fill is now a horizontal
    CAGradientLayer of those colors (alpha .2 / .32 active), blending
    the tab into its own cover. Unit-tested with synthetic banded
    covers (CoverPaletteTests).
  - **Hover anywhere** on a tab previews its book: TabItemNSView hovers
    route through the strip's preview hub (per-tab CHAPTER shown);
    the panel is cover over a [title | chapter] row with a vertical
    hairline; title wraps up to 3 lines. NSTextField trap:
    byTruncatingTail on a wrapping label silently disables wrapping —
    byWordWrapping + cell.truncatesLastVisibleLine is the multi-line
    truncation recipe.
  - **Active-cell width priority**: the selected tab is exempt from the
    overflow shrink pass (its floor = natural width) — neighbors give
    way first, then the strip scrolls.
  - **Sidebar follow-mode highlight**: leading 3pt accent bar + accent
    text on the current section (the accentSoft fill alone was
    invisible on sepia).
  - Tests 490 (+CoverPalette suite, active-width priority). Verified:
    verify.sh green; hand-checked hover-anywhere, wrapped titles,
    per-cell chapters, and real gradient washes on cover fixtures.
