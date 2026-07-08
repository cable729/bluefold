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
- [x] **M13** Library-wide FTS search UI + background auto-indexing: LibraryModel owns index.db (IndexStore + IndexingService), reload() kicks a cancellable utility-priority pass that indexes local files only (never triggers iCloud downloads), `indexingProgress` toolbar readout, "In Book Text" hit list above the grid (title / p.N / plain snippet), click opens the book at that page via `openItem(_:at:)` → `openInReader(fileURL:at:)`
- [x] **M13b** OCR indexing for scanned PDFs: extractor v2, ~200 DPI CGBitmapContext render + VNRecognizeTextRequest inside the IndexingService actor, `.indexed` reports ocrPages, `.notSearchable` = no text layer AND OCR found nothing; `IndexingService(store:ocrEnabled:)` opt-out. (OCR word boxes for in-page highlights = future)
- [x] **M14** Bookmarks + reading state: BookResolver (content-hash first, file_ref path, auto-register any opened PDF), reading-state writes on capture, Bookmarks sidebar mode + ⌘D, shared AppStores.library. ("Continue Reading" library section pending M13 merge)
- [ ] **M15** CloudKit sync via CKSyncEngine (dev account enrolled; owner must add it in Xcode > Settings > Accounts first)

- [x] **UI-1** Feedback round 1: search moved into the sidebar (results list, no navigation while typing, click = jump+history), 4 icon-tab sidebar modes (fixes segmented overflow), sidebar/window fill constraints (fixes dead-space collapse), active tab highlighted (accent top bar + bold), tabs draggable between windows (payload windowID|tabID -> SessionCoordinator.moveTab), back/forward buttons are history menus, ⌘[/⌘] moved to a History menu, current section highlighted in Contents, live page tracking via PDFViewPageChanged
- [x] **P-1** Collections support tree nesting (migration v2: collection.parent_id; collectionTree(), subtree book queries, reparenting delete)

- [x] **UI-2** Feedback round 2: evicted covers download-on-demand (fixes disappearing covers), In Book Text capped at 5 with Show All toggle, selected book highlighted (accent ring), history entries labeled with outline section names, bottom status bar (page layout modes, fit width/height, page x/y with direct jump, theme switcher), plain back/forward buttons with right-click history, ⌘-click opens ADJACENT tab + same-book tabs get group dots, tab context menu (duplicate/close/close others), collections nest in the sidebar (subtree filtering; New Collection nests under selected scope)

- [x] **UI-3** Overnight round 3 (2026-07-08, owner's feedback backlog):
  - **Tab strip rewritten in AppKit** (`TabStripView.swift`) — SwiftUI DnD was unfixably broken. Chrome-style mouse tracking: drag reorders (live preview), drag past a vertical threshold tears off under a ghost panel; drop on another window's strip moves the tab (screen-level `TabStripRegistry` hit-testing), drop on the desktop opens a new window at the point (staged restorably via `pendingRestore`+`pendingOrder`); a single-tab window just moves. Emptied source windows close.
  - **Two-row tabs**: title over outline breadcrumb (`ReaderWindowModel.tabBreadcrumbs`, refreshed via `DocumentProvider.loadedDocument` so background tabs never disturb the LRU); adjacent same-book tabs render the title once in a spanning group header (replaces the group dot the owner disliked).
  - **Split view**: `WindowState.splitTabID` (optional; schema-1 files keep decoding), `openInSplit`/`closeSplit`, secondary pane is a non-primary `ActivePDFView` with its own link routing (`linkActivated(sourceTabID:via:)`); both panes' documents pinned. Strip context menu + slim pane header manage it.
  - **Tab multi-select**: ⌘-click toggles / ⇧-click ranges in the strip; "Close N Tabs" bulk action.
  - **Open Collection / in New Window** on library collection rows (subtree included, manual order kept, iCloud downloads first).
  - **Theme overhaul** (agent): `AppTheme.auto` follows the system; cross-window sync fixed for real (root cause: lazy per-window `.preferredColorScheme` — replaced with a ThemeManager NSWindow registry setting `window.appearance` imperatively); sepia tints titlebars Claude-tan; status bar always visible so themes are switchable in empty windows.
  - **Live sidebar find** (agent): ~300ms debounce, no Enter; superseding fixed a real PDFKit trap (`beginFindString` from inside `PDFDocumentDidEndFind` delivery is silently ignored — parked queries start one main-actor hop later); per-hit outline breadcrumbs via `OutlineNode.deepestPath` with per-document caching.
  - **Library polish** (agent): selection made instant (root cause: `filteredItems` was a computed property re-running SQLite scope queries per body evaluation; now stored + Equatable cell content), ⌘/⇧ multi-select with contextual action bar (Remove only for app-owned imports), drag-to-tag/collection, Untagged / Not-in-any-collection smart filters with counts, tags-vs-collections help popovers, covers survive scroll (`.task(id:)` cancellation broke retries permanently; per-URL coalescing loader), right-click Reveal in Finder, debounced live FTS.
  - **Status bar** (agent): `‹ [page] / N ›` arrows wired to PDFView paging; reusable `.instantHint` hover hints (150ms) because `.help()` felt like seconds.

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
  book-count badges (LibraryModel.tagCounts). Quick-open (owner request):
  ⌘P lists every library book — type part of the name, Return opens it as
  a tab; Calibre paths mirror into file_ref at library reload
  (upsertFileRefs/openableBooks), open books dedupe into their tab row,
  evicted files download first. One library reload is needed post-update
  before never-opened Calibre books appear.
- [x] **UI-5** Keybindings round 6 (2026-07-08, designed live with owner —
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
  quirks below); tab breadcrumbs persist on TabState in session.json;
  book.authors in the overlay (schema v3) makes quick-open match authors;
  sepia tint fills the clip (offset-crop scans); instantHint bubbles live
  in floating child windows (unclippable); tooltips deduped (.help
  removed beside .instantHint, NSInitialToolTipDelay=150 persisted —
  `register` is invisible to CFPreferences).

- [x] **F-1** Feature wave (2026-07-08 afternoon, owner's priority list; 4 parallel
  worktree agents + deep linking inline, all merged, 330 tests):
  - **Deep linking** (`pdfreader://open?hash=…&dest=…&page=…&x=&y=`): content-hash
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

- [x] **UI-8** Round 14 (2026-07-08, owner): split-view semantics rework.
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

### Phase C
- [~] **M16** iOS app: minimal tabbed reader + session restore DONE (simulator-verified); F-1 added library/search/theming/link-history UI (simulator BUILD-verified only — needs hand-run); CloudKit sync UI pending
- [~] **M17** XCUITest smoke suite EXISTS (`App/macOSUITests/`, `PDFReaderUITests` target hand-added to the pbxproj + shared scheme). Passing END-TO-END locally: quit-and-relaunch session restore, drag-reorder (real synthesized drag), and the assert-only render smokes (`RenderSmokeUITests`: two-row strip + group header, split view from a restored session). Tear-off and cross-window drag tests are written but local XCUITest synthesis can't drive them (see quirks below) — they're unit-tested at the state-machine level (`TabStripDragTests`) and left to CI/human hands end-to-end. Run locally with a fresh app bundle ID: `xcodebuild ... test PDFREADER_BUNDLE_ID_SUFFIX=.uitest<N>`. Remaining: CI job B (xcodebuild UI tests + iOS sim build) once the CI hang below is resolved.
- [ ] **M18** OSS polish, settings window, v0.1 tag

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
- App builds: `xcodebuild -project App/PDFReader.xcodeproj -scheme PDFReader -configuration Debug -derivedDataPath .build/DerivedData build`. The pbxproj is hand-authored (objectVersion 77, synchronized folder groups) — adding files under App/macOS/ requires no pbxproj edits.
- Owner's Calibre library: `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Calibre` (read-only source; files may be iCloud-evicted).
- Apple Developer account: enrolled (cable729@gmail.com, 2026-07-07). Before M15/signing: the owner must add the account in Xcode > Settings > Accounts (GUI step).
- Test corpus guidance from owner: Axler "Linear Algebra Done Right" (in the Calibre library) is the reference for internal-link behavior; also test scanned/ugly PDFs (search there needs M13b OCR); math notation extracts messily — search and snippets must tolerate it. Don't feature Dummit & Foote in demos/screenshots.

## Key design constraints (do not violate)
- Never write to Calibre's metadata.db; never open the live file (copy first).
- Only the ON-SCREEN tabs may hold PDFViews (the active tab, plus the split
  pane's tab when a window is split); PDFDocuments live in a small LRU with
  both on-screen paths pinned.
- NavigationHistory in ReaderCore is the single source of truth for back/forward (not PDFView.goBack).
- Session restore is custom (session.json), not @SceneStorage/NSWindow restoration.
- All synced tables carry modified_at + soft-delete tombstones.

## macOS 26 local-machine quirks discovered overnight (2026-07-08)
These bit hard during UI-test debugging; they are MACHINE/OS behaviors, not
app bugs:
- **Second instance of a bundle ID never opens its window.** After one
  unclean kill of a PDFReader instance, every later direct-exec launch of
  the same bundle ID runs windowless (menu bar only). LaunchServices
  launches (`open`, Finder, Dock) are unaffected — normal usage is fine.
  Consequences: UI tests kill stray instances per-test AND take a
  `PDFREADER_BUNDLE_ID_SUFFIX` build override (app target only) so each run
  can use a fresh ID; `scripts/verify.sh`'s direct-exec launch smoke may
  false-fail on a machine in this state (launch via `open` instead).
- **XCUITest synthesized input is partially broken locally**: plain
  `click()` and coordinate-targeted drags are never delivered (drag releases
  after ~2 interpolation steps); element→element drags inside the KEY window
  work. Hence: reorder is verified end-to-end locally, tear-off/cross-window
  drags are unit-tested at the state-machine level (`TabStripDragTests`,
  crafted NSEvents in real windows) and left to CI/human hands for
  end-to-end.
- **Parallel agents + one screen don't mix**: concurrent app instances from
  several worktrees stole each other's synthesized events and confused
  window-server state. Rule of thumb going forward: agents do code + unit
  tests; ONE consolidated GUI pass at the end.

## PDFKit destination pathologies (macOS 26) — learned the hard way, 2026-07-08
Real books (especially Pearson-style scans: Munkres, Dummit & Foote) break
naive PDFKit navigation. Rules encoded in the codebase; do not regress:
1. **`PDFView.go(to:)` silently no-ops** for destinations whose point is
   outside the page's crop box OR carries kPDFDestinationUnspecifiedValue.
   `go(to: PDFPage)` no-ops too — it wraps an unspecified destination
   internally. ALWAYS navigate with an explicit in-crop point
   (`ReaderPDFView.go(to:in:)` synthesizes crop-top for point-less jumps).
2. **Outline/link destination points can be garbage**: negative x, outside
   an offset crop box (crop origin (144,110) inside a bigger media box),
   or unspecified — even in well-made books' front matter (Aluffi).
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
- [BACKLOG.md](BACKLOG.md) — owner feature requests (both 2026-07-07 rounds) + remaining roadmap
- `./scripts/verify.sh` — the one-command quality gate (tests + both app builds + launch smoke)

## Next step
1. **Owner decisions pending** (do NOT do these unprompted):
   - Merge the 4 duplicate book rows (Calibre + pre-mirror auto-registered
     twins; the auto rows hold reading state, the Calibre rows hold tags;
     palette dedupes by path so it's cosmetic). Shown to the owner
     2026-07-08 with concrete rows (D&F, Axler, Tao, Aluffi) — awaiting
     his go/no-go; back up library.db before running.
   - **App + LLC rename** (owner confirmed he wants both): brainstorm
     session needed. Gates M15 (CloudKit container is bundle-id-scoped)
     and the deep-link scheme (DeepLink.schemes — new scheme first, keep
     `pdfreader` as alias).
   - Still parked: first-launch shortcuts HUD; sub-tag context menu
     (right-click tag → New Sub-Tag / Rename).
2. **Owner hand-verification debt**: F-1 wave UI (tag colors, list/
   sectioned views, keybindings.json flow, split left/right + drag-to-
   split, Copy Link commands), iOS part 2 on a simulator/device, plus the
   older items: ⇤ ⇥ full backward trip through a scan, sidebar follow-mode
   feel, ⇧⏎/⌘⏎ palette variants. VERIFIED by owner 2026-07-08: tab
   tear-off + cross-window drags; deep links land exactly (session-tested
   by agent).
3. **Merge PR #1 (ci-hardening) + PR #2 (ci-frugal)** once GitHub billing
   resets; read the per-module PTY log to name the deadlocking CI module;
   then CI job B (XCUITest + iOS sim build) and wire UI tests into
   scripts/verify.sh.
4. Then: M15 CloudKit (settle bundle identifier FIRST), M18 v0.1
   (settings window, app icon, notarized DMG, screenshots — use Axler).
