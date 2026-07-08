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
- **Auto (system) theme** — fourth AppTheme option following
  NSApp.effectiveAppearance; pageRenderFilter resolves per current
  appearance; observe appearance changes.
- **Faster tooltips** on bottom-bar controls (default help-tag delay feels
  like seconds). Likely custom hover popover instead of .help(), or
  NSToolTipManager delay tweak.
- **Left/right arrows page-turn** in addition to up/down (PDFView handles
  some of this in single-page mode; ensure it works in continuous modes —
  likely keyDown in ReaderPDFView → goToNextPage/goToPreviousPage).
- **"/" or "?" opens a keybinding help overlay** — a sheet/HUD listing all
  shortcuts (data-drive it from one table so the overlay never drifts from
  reality).
- **⌘⇧[ / ⌘⇧] (and ctrl-tab/ctrl-shift-tab) cycle tabs** — owner wrote
  "shift+tab and cmd+shift+tab should cycle between" (tabs). Standard mac
  browser bindings: ⌘⇧[ / ⌘⇧] and ⌃Tab / ⌃⇧Tab. Add to ReaderCommands +
  model.selectNext/PreviousTab (wrap around).
- **VS Code-style command palette.** Two entry points like Obsidian/VS Code:
  a "navigate" palette (⌘O or ⌘P: fuzzy-search outline entries of the
  current book → jump; also bookmarks and open tabs) and a "run command"
  palette (⌘⇧P: every menu action). Also "go to page" (⌥⌘G or via palette).
  This subsumes "keybind to go to a specific chapter". Build the palette
  over the same command table as the help overlay.
- **Many more keybindings generally** — audit VS Code/Preview/Skim for
  conventions; document in the help overlay.

### Search
- **No Enter required** — live search with debounce (~300ms after typing
  pauses; cancel in-flight PDFDocument find before restarting). Applies to
  sidebar find and library search.
- **Show outline breadcrumb per hit** — e.g. "Chapter 1 › 1A Rⁿ and Cⁿ ›
  Complex Numbers". OutlineNode tree already exists; compute the ancestor
  path of the deepest node at-or-before the hit page (extend
  OutlineNode.deepestLabel to return the full path).

### Library
- **Selection is laggy and can't be unselected** — profile the tap-gesture
  path (simultaneousGesture may be re-rendering the whole grid; move
  selection to a lighter mechanism, e.g. equatable subviews or List-style
  selection); click on empty space or Esc should clear selection.
- **Drag books onto tags/collections in the sidebar** — .draggable(item.id)
  on cells + .dropDestination on tag/collection rows → setTags/addToCollection.
- **Selection action bar** — when something is selected, show contextual
  actions in the toolbar (Open, Tag, Add to Collection, Reveal in Finder,
  Remove). Consider multi-select (⌘-click, ⇧-click) at the same time.
- **"Untagged" and "Not in any collection" smart filters** in the sidebar
  (simple NOT EXISTS queries over book_tag / collection_item).
- **Explain tags vs collections in the UI** — general affordance, not
  owner-specific examples. E.g. section-header help popovers: tags =
  attributes a book IS (topic; hierarchical; a book has many), collections =
  curated sets a book is IN (courses/projects; ordered; mix any sources).
- **Covers don't load while scrolling** — investigate: `.task` on cells
  inside LazyVGrid may be cancelled by scroll-driven cell churn
  (task(id:) cancels on disappear); consider prefetching, retry-on-appear,
  or loading through a small request queue that survives cell recycling.
- **Right-click → Reveal in Finder** (NSWorkspace.activateFileViewerSelecting).

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
- **Theme must sync to ALL windows immediately** and tint the window chrome
  (titlebar/toolbar background via NSWindow.backgroundColor +
  titlebarAppearsTransparent or toolbar style), and be changeable from an
  EMPTY window too (the bottom bar only renders when a document is open —
  move theme control somewhere always present, or always show the bar).
  Note ThemeManager.shared is @Observable so cross-window propagation
  *should* work — investigate why it doesn't (each window's
  preferredColorScheme may not re-evaluate; windows created before a change
  may capture stale state).

### Tabs (drag & drop is BROKEN in practice — owner tested)
- **Reorder tabs within a window by dragging** (not implemented at all).
- **Drag a tab out to create a new window** (drop on empty desktop area).
- **Drag tabs between windows** — implemented via .draggable/.dropDestination
  but does not work in practice; likely gesture conflict with onTapGesture
  or drop-target coverage. Consider replacing SwiftUI DnD with an
  AppKit-backed tab strip if SwiftUI gestures keep fighting.
- **Two-row tab UI**: row 1 = title (as now); row 2 = outline breadcrumb of
  that tab's position. Same PDF open in adjacent tabs: render the title ONCE
  spanning the group (real tab-group header), breadcrumbs per tab beneath.
- **Split view**: two tabs side by side in one window, with management UI;
  plus multi-select/close-many tabs.
- **Commands: "Open Collection" and "Open Collection in New Window"** — open
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
