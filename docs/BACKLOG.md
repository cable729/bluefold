# Backlog

Owner feature requests and remaining roadmap. Mirror into GitHub issues once
the repo goes public. Items marked (2026-07-07) came from the owner's
end-of-session feedback after using the app.

## Remaining roadmap milestones

- **M15 — CloudKit sync.** Design is in ARCHITECTURE.md §CloudKit. Team ID
  A448YLFLYC is set on the project; the owner's Apple ID is in Xcode. First
  signed build mints the dev certificate. Add iCloud/CloudKit + push
  entitlements to both targets, create container
  `iCloud.com.cable729.pdfreader`, implement SyncKit with CKSyncEngine
  behind `SyncTransport` (fake transport for tests), deploy schema to
  production in CloudKit Console before any release build.
- **iOS part 2.** Library UI (Calibre via iCloud Drive picker, tags,
  collections), FTS search UI, theming (ThemedPDFPage already
  iOS-compatible), link-tap history interception (UIKit gesture analog of
  ReaderPDFView.mouseDown), dataless-file download flow, save session on
  .inactive too.
- **M17 — XCUITest smoke suite + CI job B** (xcodebuild macOS app tests +
  iOS simulator build). Launch-arg fixtures already exist (`--open`,
  `PDFREADER_SESSION_DIR`).
- **M18 — v0.1 release.** Settings window (LRU size, theme, index toggle,
  Calibre folder), app icon, README screenshots (use Axler — NOT Dummit &
  Foote), notarized DMG pipeline, make repo public, CONTRIBUTING.md.

## Feature requests (2026-07-07)

### Reader
- ✅ DONE 2026-07-08 — **Auto (system) theme** — fourth AppTheme option following
  NSApp.effectiveAppearance; pageRenderFilter resolves per current
  appearance; observe appearance changes.
- ✅ DONE 2026-07-08 (status bar; adopt `.instantHint` elsewhere as wanted) — **Faster tooltips** on bottom-bar controls (default help-tag delay feels
  like seconds). Likely custom hover popover instead of .help(), or
  NSToolTipManager delay tweak.
- 🔄 IN FLIGHT 2026-07-08 (palette agent) — **Left/right arrows page-turn** in addition to up/down (PDFView handles
  some of this in single-page mode; ensure it works in continuous modes —
  likely keyDown in ReaderPDFView → goToNextPage/goToPreviousPage).
- 🔄 IN FLIGHT 2026-07-08 (palette agent) — **"/" or "?" opens a keybinding help overlay** — a sheet/HUD listing all
  shortcuts (data-drive it from one table so the overlay never drifts from
  reality).
- 🔄 IN FLIGHT 2026-07-08 (palette agent) — **⌘⇧[ / ⌘⇧] (and ctrl-tab/ctrl-shift-tab) cycle tabs** — owner wrote
  "shift+tab and cmd+shift+tab should cycle between" (tabs). Standard mac
  browser bindings: ⌘⇧[ / ⌘⇧] and ⌃Tab / ⌃⇧Tab. Add to ReaderCommands +
  model.selectNext/PreviousTab (wrap around).
- 🔄 IN FLIGHT 2026-07-08 (palette agent) — **VS Code-style command palette.** Two entry points like Obsidian/VS Code:
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
- ✅ DONE 2026-07-08 — **Explain tags vs collections in the UI** — general affordance, not
  owner-specific examples. E.g. section-header help popovers: tags =
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

### Deep linking / anchors (owner question, answered)
PDFs expose anchors we can link to: **named destinations** (hyperref's
`\hypertarget`/section anchors — PDFDocument can enumerate names),
**outline entries**, and page+point. Theorem/exercise granularity exists in
well-made LaTeX books because every `\ref` target is a named destination.
Plan: a custom URL scheme, e.g.
`pdfreader://open?hash=<contentHash>&dest=<name>` (fallback `&page=N&x=&y=`),
registered by the app; "Copy Link to Here / to Selection" in the reader;
links resolve through the library's content-hash lookup so they survive file
moves. These URLs then work from Obsidian/anywhere. (Cross-book theorem
references inside PDFs already work via PDFActionRemoteGoTo.)

### Infra / distribution
- **CI hardening + "docker"** — macOS apps can't build in Docker
  (owner asked; documented in DECISIONS/plan): the equivalent is GitHub
  Actions macOS runners. Expand CI: xcodebuild macOS app build + unit tests
  per push (job B), iOS simulator build, XCUITest smoke (M17), release
  workflow producing a notarized DMG on tag.
- **Download/marketing website** — GitHub Pages site (static, screenshots,
  download link to notarized DMG releases, feature tour). Do after M18 when
  there's something to download.

## Feature requests (2026-07-07, round 2 — session close)

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

### Tabs (drag & drop is BROKEN in practice — owner tested)
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

### Testing / CI (owner: "the test suite does NOT guarantee everything works")
Correct — unit tests can't catch what the owner keeps finding (layout
collapse, broken DnD, tooltip delay). The industry-standard answer for
macOS apps (Docker is impossible — macOS doesn't containerize):
1. **XCUITest** driving the real app (launch args + PDFREADER_SESSION_DIR
   already exist as hooks) on **GitHub Actions macOS runners** — M17. Smoke
   flows: open → tab → ⌘-click link → back → quit → relaunch → restored;
   library open → search → hit → correct page; tab drag (XCUITest can drag).
2. A single **`scripts/verify.sh`** entry point (build both platforms, swift
   test, xcodebuild test incl. UITests, launch smoke with footprint check) so
   ANY agent — including cheaper/less capable ones — or contributor can run
   the whole gate with one command. CI runs the same script.
3. Optional deeper end-to-end: accessibility-driven runner or snapshot tests
   (pointfree swift-snapshot-testing) for view regressions.

### Product / business (brainstorm sessions wanted — do NOT decide alone)
- **Rename the app** (working title "PDFReader" / pdf-app). Brainstorm with
  owner.
- **Bundle id / team identity**: owner wants to move off com.cable729.* and
  is considering an LLC — brainstorm naming + legal setup with him. NOTE:
  changing bundle id after CloudKit ships is painful (container is
  id-scoped) — settle this BEFORE M15 if possible, or create the container
  under a neutral id now.
- **Cross-platform eventually** (beyond Apple). The split that makes this
  tractable: ReaderCore/persistence logic is UI-independent; a future
  Windows/Linux build would need a new shell + PDF renderer (PDFium/MuPDF).
  Long-horizon; don't let new code deepen PDFKit coupling outside
  ReaderUI/SearchIndexKit extraction paths.

## Known bugs / rough edges (not yet scheduled)
- Tooltip delay (above).
- Cover loading during scroll (above).
- Selection lag (above).
- OCR'd scanned books: hits are page-granular (no in-page highlight boxes) —
  store Vision word geometry to fix (extractor_version bump).
- macOS 26 "footprint" tool reports two PDFReader lines occasionally
  (stale process match) — cosmetic in verification scripts.

## Feedback round 4 (2026-07-08, morning after overnight round 3)

### Tab strip (owner tested with two Axler tabs + Dummit & Foote)
- **Group header is too skinny / hard to read** (17pt row). Also the header
  title RENDERS OUTSIDE the strip, overlapping the window titlebar area —
  NSViews don't clip subviews by default; the strip (or its header/item
  frames during layout) needs explicit clipping (`layer?.masksToBounds`) and
  the header likely deserves ~20-22pt with a background that reads as a
  group. Consider a full design pass on the two-row look with the owner
  live: he called the current group rendering "a little funny".
- **Title text animates from OUTSIDE the tab box on selection — "looks
  awful".** Hypotheses: (a) newly created header/item views get
  `animator().frame` animations starting from frame .zero (top-left), so
  text glides in from nowhere; (b) `setGrouped` re-showing the hidden title
  row mid-animation. Fix: never animate a view's FIRST layout (set frame
  directly when the view was just added), and suppress implicit text
  animations.
- **Tear-off drag by hand FAILED and wedged the strip**: ghost panel stayed
  floating (see owner screenshot), dragged tab stayed hidden. ⌘Q+relaunch
  recovers (session intact). Implication: `endPress` never ran — the ghost
  is only closed there. Debug live with `PDFREADER_SESSION_DIR` set so the
  strip's dragdebug.log records begin/continue/end; suspects: mouseUp not
  delivered to the item view when the pointer is outside the window over
  another app, or the item view being replaced mid-drag. Also add a
  belt-and-braces failsafe: watch for `mouseUp` at the strip/window level
  (local NSEvent monitor during a drag) and force-finish the drag if the
  item view misses it.

### Status bar
- ✅ DONE 2026-07-08 — hide the PDF display controls entirely in empty
  windows (only the theme switcher remains).

### Verified good by owner
- Theme sync/tinting, live search + breadcrumbs, status-bar page arrows.

### Round 4 additions (same morning)
- ✅ DONE 2026-07-08 — **Compact drag preview**: dragging a book now shows a
  small capsule ("3 books" for multi-drags) instead of the full-size cell.
- ✅ DONE 2026-07-08 — **Drag tags onto tags to build the tree** (drop on
  the Tags header or use "Move to Top Level" to un-nest; store refuses
  cycles). Collections already reorder via their own mechanism; add the
  same drag-reparenting there if wanted.
- **CI policy (owner: no billing)**: PR #2 = frugal mode (runs only on PRs
  and manual dispatch, never plain pushes; docs changes skip CI). MERGE IT.
  Nothing can run until the monthly included-minutes reset regardless; the
  routine gate is ./scripts/verify.sh locally.

## Feedback round 5 (2026-07-08, pre-session-handoff) — TOP PRIORITY FIRST

### ✅ DONE 2026-07-08 — P0: tab strip glitch persists across relaunch + SESSION LOSS
All three fixed the same day; owner verification pending:
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
already listed the palette + shortcuts overlay (kept). Not done (design
with owner if wanted): one-time first-launch HUD.

### ✅ DONE 2026-07-08 — Unify the "+" tab button with the library
"+" is now a menu: "From Library…" (opens the Library window) /
"Open File…" (the old panel). The alternative — seeding the NAVIGATE
palette with library books — was deliberately NOT done yet: candidates
would come from the overlay DB, whose file paths (file_ref) only exist
for imports and previously-opened books, so unopened Calibre books would
silently be missing. Revisit with the owner (needs a Calibre-backed
candidate source to be complete).

### ✅ DONE 2026-07-08 — Go to Page is ⌘G
No conflict existed anymore: the M8 find-bar ⌘G/⇧⌘G cycling died with the
sidebar-find rewrite (Enter/⇧Enter cycle in the field). `nav.goToPage`
chord changed ⌥⌘G → ⌘G; KEYBINDINGS.md documents that ⌘G must not be
rebound to find-next.

### CI cost estimate if billing were re-enabled (answered for the owner)
macOS runners bill $0.08/min on private repos. With frugal mode (PR #2):
a full 3-job run ≈ 35–60 macOS-min ≈ **$3–5 per PR run**; worst case with
all timeouts maxed (35+40+30 min) ≈ $8.40. A handful of PRs a month ≈
$10–30/mo. Runaways are capped by the per-job timeouts now — the overnight
disaster mode (6h × N concurrent) is no longer possible.
