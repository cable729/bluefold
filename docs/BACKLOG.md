# Backlog

Feature requests and remaining roadmap. Mirror into GitHub issues once
the repo goes public.

## Remaining roadmap milestones

- ✅ CODE-DONE 2026-07-09 (live CloudKit pending the
  signing runbook in docs/SYNC.md) — **M15 — CloudKit sync.** SyncKit
  engine + FakeTransport convergence tests, CloudKitTransport
  (entitlement-gated), Settings toggle + status + Sync Now. Remaining
  steps: add Apple ID in Xcode, add iCloud capability/container
  `iCloud.com.cable729.bluefold` to both targets, verify a live round
  trip, deploy schema to Production before any release build.
- ✅ CODE-DONE 2026-07-08 (F-1; simulator build only — needs hand-run) —
  **iOS part 2.** Library UI (Calibre via iCloud Drive picker, tags,
  collections), FTS search UI, theming, link-tap history interception,
  dataless-file download flow, session save on .inactive/.background.
  Deferred: iOS own-imports into the overlay DB; outline sidebar /
  bookmarks / reading state on iOS.
- ✅ DONE 2026-07-11 (M16b; keyboard/pointer paths need an owner hand-run) —
  **iPadOS port.** Hardware-keyboard commands (menu bar / hold-⌘ HUD,
  chords mirror KEYBINDINGS.md), page layouts honored per tab + layout
  menu, system find (UIFindInteraction, ⌘F), ←/→ hardware-arrow paging,
  pointer hover effects, page-sized library sheet.
  **Round 2 DONE 2026-07-12** (M16c): design-system chrome (top band /
  lozenge strip / mockup status bar with go-to-page), sidebar (Contents +
  Bookmarks, fuzzy filter = ⌘P stand-in, always-on follow), split pane
  (⌘\ toggle, drag chip/section to trailing edge), link long-press/⌘-tap
  open modes, tab drag-reorder + context menus, history long-press menus,
  bookmarks (⌘D), iPhone chrome auto-hide. Deferred iPad follow-ups:
  multi-window/multi-scene (needs per-scene session models — today's app
  state is App-level and session.json is single-window on iOS),
  reading-state persistence on iOS, sidebar follow-mode toggle +
  thumbnails mode, per-pane tab bars (macOS round 20 parity),
  ⌘O/⌘P palettes, Apple Pencil annotation questions.
- **M17 — XCUITest smoke suite + CI job B** (xcodebuild macOS app tests +
  iOS simulator build). Launch-arg fixtures already exist (`--open`,
  `BLUEFOLD_SESSION_DIR`).
- **M18 — v0.1 release.** Settings window (LRU size, theme, index toggle,
  Calibre folder), app icon, README screenshots, notarized DMG pipeline,
  make repo public, CONTRIBUTING.md.

## Feature requests (2026-07-07)

### Reader
- ✅ DONE 2026-07-08 — **Auto (system) theme** — fourth AppTheme option following
  NSApp.effectiveAppearance; pageRenderFilter resolves per current
  appearance; observe appearance changes.
- ✅ DONE 2026-07-08 (status bar; adopt `.instantHint` elsewhere as wanted) — **Faster tooltips** on bottom-bar controls (default help-tag delay feels
  like seconds). Likely custom hover popover instead of .help(), or
  NSToolTipManager delay tweak.
- 🔄 IN FLIGHT 2026-07-08 — **Left/right arrows page-turn** in addition to up/down (PDFView handles
  some of this in single-page mode; ensure it works in continuous modes —
  likely keyDown in ReaderPDFView → goToNextPage/goToPreviousPage).
- 🔄 IN FLIGHT 2026-07-08 — **"/" or "?" opens a keybinding help overlay** — a sheet/HUD listing all
  shortcuts (data-drive it from one table so the overlay never drifts from
  reality).
- 🔄 IN FLIGHT 2026-07-08 — **⌘⇧[ / ⌘⇧] (and ctrl-tab/ctrl-shift-tab) cycle tabs** — standard mac
  browser bindings: ⌘⇧[ / ⌘⇧] and ⌃Tab / ⌃⇧Tab. Add to ReaderCommands +
  model.selectNext/PreviousTab (wrap around).
- 🔄 IN FLIGHT 2026-07-08 — **VS Code-style command palette.** Two entry points like Obsidian/VS Code:
  a "navigate" palette (⌘O or ⌘P: fuzzy-search outline entries of the
  current book → jump; also bookmarks and open tabs) and a "run command"
  palette (⌘⇧P: every menu action). Also "go to page" (⌥⌘G or via palette).
  This subsumes "keybind to go to a specific chapter". Build the palette
  over the same command table as the help overlay.
- **Many more keybindings generally** — audit VS Code/Preview/Skim for
  conventions; document in the help overlay.

### Search
- ✅ DONE 2026-07-08 — **No Enter required** — live search with debounce (~300ms after typing
  pauses; cancel in-flight PDFDocument find before restarting). Applies to
  sidebar find and library search.
- ✅ DONE 2026-07-08 — **Show outline breadcrumb per hit** — e.g. "Chapter 1 › 1A Rⁿ and Cⁿ ›
  Complex Numbers". OutlineNode tree already exists; compute the ancestor
  path of the deepest node at-or-before the hit page (extend
  OutlineNode.deepestLabel to return the full path).

### Library
- ✅ DONE 2026-07-08 — **Selection is laggy and can't be unselected** — profile the tap-gesture
  path (simultaneousGesture may be re-rendering the whole grid; move
  selection to a lighter mechanism, e.g. equatable subviews or List-style
  selection); click on empty space or Esc should clear selection.
- ✅ DONE 2026-07-08 — **Drag books onto tags/collections in the sidebar** — .draggable(item.id)
  on cells + .dropDestination on tag/collection rows → setTags/addToCollection.
- ✅ DONE 2026-07-08 — **Selection action bar** — when something is selected, show contextual
  actions in the toolbar (Open, Tag, Add to Collection, Reveal in Finder,
  Remove). Consider multi-select (⌘-click, ⇧-click) at the same time.
- ✅ DONE 2026-07-08 — **"Untagged" and "Not in any collection" smart filters** in the sidebar
  (simple NOT EXISTS queries over book_tag / collection_item).
- ✅ DONE 2026-07-08 — **Explain tags vs collections in the UI** — general affordance. E.g. section-header help popovers: tags =
  attributes a book IS (topic; hierarchical; a book has many), collections =
  curated sets a book is IN (courses/projects; ordered; mix any sources).
- ✅ DONE 2026-07-08 — **Covers don't load while scrolling** — investigate: `.task` on cells
  inside LazyVGrid may be cancelled by scroll-driven cell churn
  (task(id:) cancels on disappear); consider prefetching, retry-on-appear,
  or loading through a small request queue that survives cell recycling.
- ✅ DONE 2026-07-08 — **Right-click → Reveal in Finder** (NSWorkspace.activateFileViewerSelecting).
- ✅ DONE 2026-07-08 (round 5) — **Tag rows show matched-book counts** in the
  sidebar, descendant tags included so each badge equals what clicking the
  tag shows; zero-count tags show no badge (`LibraryModel.tagCounts`).

### Deep linking / anchors — ✅ SHIPPED 2026-07-08
Implemented as designed below (F-1): `bluefold://open?hash=…&dest=…&page=…`,
Copy Link to Here / to Selection, `NamedDestinations` CGPDF resolver.
Original plan:
PDFs expose anchors we can link to: **named destinations** (hyperref's
`\hypertarget`/section anchors — PDFDocument can enumerate names),
**outline entries**, and page+point. Theorem/exercise granularity exists in
well-made LaTeX books because every `\ref` target is a named destination.
Plan: a custom URL scheme, e.g.
`bluefold://open?hash=<contentHash>&dest=<name>` (fallback `&page=N&x=&y=`),
registered by the app; "Copy Link to Here / to Selection" in the reader;
links resolve through the library's content-hash lookup so they survive file
moves. These URLs then work from Obsidian/anywhere. (Cross-book theorem
references inside PDFs already work via PDFActionRemoteGoTo.)

### Infra / distribution
- **CI hardening + "docker"** — macOS apps can't build in Docker
  (documented in DECISIONS/plan): the equivalent is GitHub
  Actions macOS runners. Expand CI: xcodebuild macOS app build + unit tests
  per push (job B), iOS simulator build, XCUITest smoke (M17), release
  workflow producing a notarized DMG on tag.
- **Download/marketing website** — GitHub Pages site (static, screenshots,
  download link to notarized DMG releases, feature tour). Do after M18 when
  there's something to download.

## Feature requests (2026-07-07, round 2)

### Theming
- ✅ DONE 2026-07-08 — **Theme must sync to ALL windows immediately** and tint the window chrome
  (titlebar/toolbar background via NSWindow.backgroundColor +
  titlebarAppearsTransparent or toolbar style), and be changeable from an
  EMPTY window too (the bottom bar only renders when a document is open —
  move theme control somewhere always present, or always show the bar).
  Note ThemeManager.shared is @Observable so cross-window propagation
  *should* work — investigate why it doesn't (each window's
  preferredColorScheme may not re-evaluate; windows created before a change
  may capture stale state).

### Tabs (drag & drop was BROKEN in practice)
- ✅ DONE 2026-07-08 (AppKit strip rewrite) — **Reorder tabs within a window by dragging** (not implemented at all).
- ✅ DONE 2026-07-08 — **Drag a tab out to create a new window** (drop on empty desktop area).
- ✅ DONE 2026-07-08 (AppKit rewrite as predicted) — **Drag tabs between windows** — implemented via .draggable/.dropDestination
  but does not work in practice; likely gesture conflict with onTapGesture
  or drop-target coverage. Consider replacing SwiftUI DnD with an
  AppKit-backed tab strip if SwiftUI gestures keep fighting.
- ✅ DONE 2026-07-08 (incl. spanning group headers replacing the dot) — **Two-row tab UI**: row 1 = title (as now); row 2 = outline breadcrumb of
  that tab's position. Same PDF open in adjacent tabs: render the title ONCE
  spanning the group (real tab-group header), breadcrumbs per tab beneath.
- ✅ DONE 2026-07-08 (side-by-side panes + multi-select/close-many) — **Split view**: two tabs side by side in one window, with management UI;
  plus multi-select/close-many tabs.
- ✅ DONE 2026-07-08 — **Commands: "Open Collection" and "Open Collection in New Window"** — open
  every book in a collection as tabs (pairs well with the command palette).

### Testing / CI
The test suite does NOT guarantee everything works — unit tests can't
catch what manual testing keeps finding (layout collapse, broken DnD,
tooltip delay). The industry-standard answer for
macOS apps (Docker is impossible — macOS doesn't containerize):
1. **XCUITest** driving the real app (launch args + BLUEFOLD_SESSION_DIR
   already exist as hooks) on **GitHub Actions macOS runners** — M17. Smoke
   flows: open → tab → ⌘-click link → back → quit → relaunch → restored;
   library open → search → hit → correct page; tab drag (XCUITest can drag).
2. A single **`scripts/verify.sh`** entry point (build both platforms, swift
   test, xcodebuild test incl. UITests, launch smoke with footprint check) so
   ANY agent — including cheaper/less capable ones — or contributor can run
   the whole gate with one command. CI runs the same script.
3. Optional deeper end-to-end: accessibility-driven runner or snapshot tests
   (pointfree swift-snapshot-testing) for view regressions.

### Product / business (open decisions)
- **Rename the app** (working title "Bluefold" / pdf-app).
- **Bundle id / team identity**: move off com.cable729.* eventually. NOTE:
  changing bundle id after CloudKit ships is painful (container is
  id-scoped) — settle this BEFORE M15 if possible, or create the container
  under a neutral id now.
- **Cross-platform eventually** (beyond Apple). The split that makes this
  tractable: ReaderCore/persistence logic is UI-independent; a future
  Windows/Linux build would need a new shell + PDF renderer (PDFium/MuPDF).
  Long-horizon; don't let new code deepen PDFKit coupling outside
  ReaderUI/SearchIndexKit extraction paths.

## Feedback round 7 (2026-07-08) — feature requests to schedule

### Library / tags
- **Right-click a tag → create a sub-tag** ("add more" from the tag's own
  context menu; today nesting requires drag or the New Tag flow from
  inside a scope). Also consider "Rename Tag" in the same menu.
- ✅ DONE 2026-07-08 (F-1) — **Tag colors** — schema v4 `tag.color` hex,
  sidebar dot, tinted chips, Color submenu (8 presets + None).
- ✅ DONE 2026-07-08 (F-1) — **Library view modes**: sortable list view
  (title/author/date added/last read; schema v5 `book.created_at`) and
  the sectioned-by-tag grid (scope-only first, then per-child sections),
  toolbar toggle, prefs persisted.

### ✅ Fixed same day (round-7 bugs)
- Tag/collection ⓘ popovers: now open on HOVER (200ms) and the text
  wraps at 320pt instead of truncating to one line (`.fixedSize` was
  missing). Click still pins.
- Multi-select + right-click: tag/collection toggles, Open, Reveal, and
  Remove from Library now act on the WHOLE selection when the clicked
  cell is part of it (labels say the count, e.g. "Remove 3 Books…").
- "Opens like 5 windows": empty (tabless) windows are no longer saved
  into the session — stray default scenes from odd launches had been
  accumulating forever. Corollary: a deliberately emptied session no
  longer falls back to the .bak (only a corrupt/missing file does).

## Feedback round 8 (2026-07-08) — ✅ all done same day
- **Prev/next CHAPTER buttons** in the status bar (⇤ ⇥
  flanking the page arrows). Top-level outline entries are the stops;
  jumps push history; also Go menu + palette (`nav.previousChapter/
  nextChapter`, chordless).
- **Empty-window layout glitch**: the shortcut-hint line rendered beside
  the buttons and off-window — ContentUnavailableView lays `actions` out
  horizontally; wrapped in one VStack child.
- **Hover delays**: global `NSInitialToolTipDelay = 150` (registered
  default at launch) makes EVERY `.help` tooltip near-instant, matching
  the custom `.instantHint` bubbles.

## Feedback round 10 (2026-07-08) — ✅ all done same day
- **Batch-opening a tag appeared to do NOTHING**: palette batch-opens awaited
  every iCloud download SEQUENTIALLY before opening anything — one
  evicted book stalled the lot for up to 120s silently.
  Now: already-local books open instantly; evicted ones download
  concurrently and each opens on arrival (new-window variant opens the
  window immediately and stragglers append to it).
- **Tabs showed "p.N" after relaunch**: restored background tabs never
  got breadcrumbs until first activation. When a document's view
  attaches, every tab of that book refreshes its label.
- **Section skips land on the exact anchor**: stops are now full
  destinations (page + in-page point) ordered by reading position, so
  books with several sections per page (Aluffi III.2.1 → III.2.2) step
  correctly instead of jumping to a page top. Current position uses the
  live view's scroll anchor.
- **Sidebar follows the current section** (VS Code-style): scope button
  next to the sidebar mode picker (default ON, persisted); the outline
  auto-expands ancestors and scrolls the current section into view as
  reading/section-skipping progresses. Expansion state is app-owned now
  (custom recursive DisclosureGroups).

## Feedback rounds 11–13.7 (2026-07-08) — ✅ the broken-scan saga, all fixed
One connected arc, kicked off by "clicking sections in Munkres does
nothing". Every fix is unit-test-pinned; the durable lessons live in
PROGRESS.md § "PDFKit destination pathologies". Summary:
- **R11**: Munkres outline points lie OUTSIDE the crop box (x = -19.7,
  crop starts at 144) → PDFView refuses them → clicks no-oped. Points now
  validated (`ReaderPDFView.validatedPoint`, 12pt slop). Same offset crop
  origin broke the sepia tint fill → ThemedPDFPage now fills
  `context.boundingBoxOfClipPath` instead of box geometry.
- **R12**: quick-open couldn't find "dummit" — overlay titles carry no
  author. `book.authors` column (schema v3), mirrored at library reload,
  searchable + shown in palette subtitles. instantHint bubbles moved into
  a floating child window (overlays got clipped everywhere).
- **R12.5**: `go(to: PDFPage)` — and any PDFDestination with UNSPECIFIED
  coordinates — is a silent no-op on macOS 26 PDFKit. Point-less jumps
  synthesize an explicit crop-top point. Also: enablement must read
  OBSERVABLE state (liveNavEntry isn't tracked → permanently gray
  buttons), and never mutate observable state inside makeNSView.
- **R13/13.6**: previous-section wedges. PDFKit parks the view ~few pt
  below a requested anchor → identity-based stepping with 40pt landing
  slop; outline tree now synthesizes concrete crop-top points for broken
  destinations so reading-order math never sees nil (-∞ offsets made
  "previous" restart the current section forever).
- **R13.5**: tab breadcrumbs persist ON TabState in session.json
  (recomputing needs the live document; background tabs never load one —
  relaunches showed "p.N" everywhere).
- **R13.7**: chapter heading + first section often share ONE anchor
  (always in scans) — same-spot stops dedupe (2pt) so ⇤ crosses chapter
  boundaries instead of stepping to an invisible twin.

## Round 15 (2026-07-08) — margin heading anchors ("#") — NEEDS A DESIGN SESSION
Parked deliberately: hold a design session before building. Sketch of the
idea:
- Render markdown-style depth markers in the page MARGIN next to structural
  anchors: `#` for a chapter/title, `##` for a section, `###` deeper — and
  possibly for sub-section anchors like definitions/theorems/paragraphs.
- Anchor sources, in richness order: named destinations (hyperref gives
  theorem/definition granularity in well-made LaTeX books — enumerate via
  the CGPDF name tree, see NamedDestinations), outline entries (works for
  scans too), possibly heading-detection heuristics later.
- Interaction ideas to explore: hover to reveal, click a
  marker = Copy Link to that anchor (pairs with bluefold:// deep links),
  maybe jump/peek. Rendering probably a PDFView overlay layer or page
  annotations drawn at anchor points (mind the destination pathologies:
  validate points, offset crop boxes).
- OPEN QUESTIONS for the design session: always-visible vs hover-only;
  which anchor kinds get markers; depth→#-count mapping for named dests
  (no tree structure — infer from name prefixes like section./theorem.?);
  scans with junk anchor points; performance on 1000-page books.

## Known bugs / rough edges (not yet scheduled)
- Tooltip delay (above).
- Cover loading during scroll (above).
- Selection lag (above).
- OCR'd scanned books: hits are page-granular (no in-page highlight boxes) —
  store Vision word geometry to fix (extractor_version bump).
- macOS 26 "footprint" tool reports two Bluefold lines occasionally
  (stale process match) — cosmetic in verification scripts.

## Feedback round 4 (2026-07-08)

### Tab strip (tested with two tabs of one book plus a second book)
- **Group header is too skinny / hard to read** (17pt row). Also the header
  title RENDERS OUTSIDE the strip, overlapping the window titlebar area —
  NSViews don't clip subviews by default; the strip (or its header/item
  frames during layout) needs explicit clipping (`layer?.masksToBounds`) and
  the header likely deserves ~20-22pt with a background that reads as a
  group. Consider a full design pass on the two-row look.
- **Title text animates from OUTSIDE the tab box on selection — "looks
  awful".** Hypotheses: (a) newly created header/item views get
  `animator().frame` animations starting from frame .zero (top-left), so
  text glides in from nowhere; (b) `setGrouped` re-showing the hidden title
  row mid-animation. Fix: never animate a view's FIRST layout (set frame
  directly when the view was just added), and suppress implicit text
  animations.
- **Tear-off drag by hand FAILED and wedged the strip**: ghost panel stayed
  floating, dragged tab stayed hidden. ⌘Q+relaunch
  recovers (session intact). Implication: `endPress` never ran — the ghost
  is only closed there. Debug live with `BLUEFOLD_SESSION_DIR` set so the
  strip's dragdebug.log records begin/continue/end; suspects: mouseUp not
  delivered to the item view when the pointer is outside the window over
  another app, or the item view being replaced mid-drag. Also add a
  belt-and-braces failsafe: watch for `mouseUp` at the strip/window level
  (local NSEvent monitor during a drag) and force-finish the drag if the
  item view misses it.

### Status bar
- ✅ DONE 2026-07-08 — hide the PDF display controls entirely in empty
  windows (only the theme switcher remains).

### Verified in manual testing
- Theme sync/tinting, live search + breadcrumbs, status-bar page arrows.

### Round 4 additions
- ✅ DONE 2026-07-08 — **Compact drag preview**: dragging a book now shows a
  small capsule ("3 books" for multi-drags) instead of the full-size cell.
- ✅ DONE 2026-07-08 — **Drag tags onto tags to build the tree** (drop on
  the Tags header or use "Move to Top Level" to un-nest; store refuses
  cycles). Collections already reorder via their own mechanism; add the
  same drag-reparenting there if wanted.
- **CI policy (Actions billing disabled)**: PR #2 = frugal mode (runs only
  on PRs and manual dispatch, never plain pushes; docs changes skip CI).
  MERGE IT. The routine gate is ./scripts/verify.sh locally.

## Feedback round 5 (2026-07-08) — TOP PRIORITY FIRST

### ✅ DONE 2026-07-08 — P0: tab strip glitch persists across relaunch + SESSION LOSS
All three fixed the same day; manual re-verification still TODO:
1. **Session loss — root cause found, different from the hypothesis.** The
   staged-detach path was fine (now pinned by
   `stagedDetachSurvivesQuitWithoutPresentation`). The real chain: closing
   the LAST reader window fires `windowClosed` → the window leaves the
   snapshot → the debounced save writes an EMPTY session while the app
   keeps running (that's also why the stuck ghost panel was still on
   screen — the app had never quit). A Dock-click "relaunch" then reopens
   the default scene, whose memoized `claimLaunchWindowID` pointed at the
   spent window ID → fresh empty model saved under it. Fixes: (a) closing
   the last window with tabs stashes its state back into
   `pendingRestore` (browser-style reopen), (b) `claimLaunchWindowID`
   re-resolves when its window is gone, (c) `session.json.bak` rotates on
   every good load and is the fallback when the main file is corrupt or
   windowless. Five new SessionCoordinator tests cover the class.
2. **Header overflow**: strip layer now clips (`masksToBounds`); header
   title got the missing trailing constraint (long titles used to render
   past the header, unclipped); header raised 17→22pt, font 10→11.
   XCUITest render smoke now asserts header-inside-strip + min height.
3. **Stuck ghost**: three-layer fix. (a) The torn-off tab is no longer
   `isHidden` (a hidden NSView can lose the tracking events of the drag it
   started — the suspected wedge mechanism); it goes `alphaValue = 0` and
   leaves the layout flow instead. (b) Local + global mouseUp NSEvent
   monitors force-finish any drag whose item view misses its mouseUp.
   (c) The drag cancels safely if the dragged tab vanishes mid-drag or the
   strip leaves its window. All ends funnel through one `finishDrag`.
   Also fixed while in there: a plain CLICK on a grouped tab no longer
   dissolves/re-forms the group (grouping now suspends only once a drag
   actually moves), and no view animates its very first layout — together
   these kill the round-4 "title glides in from outside" glitch.

### ✅ DONE 2026-07-08 — Keybinding discoverability
Toolbar now has a ⌘-icon "Commands" button (opens the command palette;
hover hint lists ⌘⇧P / ⌘P / "/"), and the empty-window state shows
"⌘⇧P all commands · ⌘P go to anything · / shortcuts". The Help menu
already listed the palette + shortcuts overlay (kept). Not done: one-time
first-launch HUD.

### ✅ DONE 2026-07-08 — Unify the "+" tab button with the library
"+" is now a menu: "From Library…" (opens the Library window) /
"Open File…" (the old panel).

### ✅ DONE 2026-07-08 — Keybindings round 6
Decisions: split palettes; ⌘1–9 = tabs; collections/tags in the open
palette; ⌘⇧F = library search. Shipped:
- **⌘P/⌘O = OPEN palette**: open tabs, library books, collections, tags.
  Return opens/switches; ⌘Return = background tab(s), palette stays up
  for queueing; ⌥Return = new window. Collections/tags open every book in
  their subtree as tabs (evicted files download first, missing skipped).
- **⌘⇧O = IN-BOOK palette**: sections + bookmarks (VS Code go-to-symbol).
  Open File… moved to ⌥⌘O.
- **⌘1–8 tab by position, ⌘9 last tab** (browser); layouts → ⌥⌘1–4.
- **⌘⇧F = Search All Books**: library window opens with the search field
  focused (LibrarySearchFocusBridge), from any window.
- **⌘-click on PDF links opens BACKGROUND tabs** (was: switched); plain
  click on cross-file links still navigates.
- Also this round: ⌘O palette focus bug fixed (AppKit first responder
  released before presenting), and unit tests are permanently fenced off
  the real library.db (AppStores.isTestProcess + isolation tests) after
  test fixtures polluted it with junk rows (cleaned).
- NOT done (parked): user-editable keybindings.json overlay
  (✅ DONE 2026-07-08, F-1); one-time first-launch shortcuts HUD;
  merging duplicate book rows (Calibre + pre-mirror
  auto-registered twins) — needs a decision, currently harmless
  (palette dedupes by path).

### ✅ DONE 2026-07-08 — Quick-open a book from the keyboard
"⌘P, type part of the book name, Return" opens any library book as a tab
— no library window. Done by seeding the navigate palette with library
books: library reload now mirrors every Calibre book's PDF path into
`file_ref` (`LibraryStore.upsertFileRefs`), `openableBooks()` joins
book+file_ref, and the palette appends a "Library — open in a new tab"
section (fetched once per palette open, never per keystroke). Books
already open anywhere dedupe into their "Open Tab" row (switch, don't
duplicate); iCloud-evicted files download before the tab opens. NOTE:
Calibre books need ONE library reload after this update before they're
listed (the mirror runs at reload); imports and previously-opened books
work immediately.

### ✅ DONE 2026-07-08 — Go to Page is ⌘G
No conflict existed anymore: the M8 find-bar ⌘G/⇧⌘G cycling died with the
sidebar-find rewrite (Enter/⇧Enter cycle in the field). `nav.goToPage`
chord changed ⌥⌘G → ⌘G; KEYBINDINGS.md documents that ⌘G must not be
rebound to find-next.

### CI cost estimate if billing were re-enabled
macOS runners bill $0.08/min on private repos. With frugal mode (PR #2):
a full 3-job run ≈ 35–60 macOS-min ≈ **$3–5 per PR run**; worst case with
all timeouts maxed (35+40+30 min) ≈ $8.40. A handful of PRs a month ≈
$10–30/mo. Runaways are capped by the per-job timeouts.
