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

## Known bugs / rough edges (not yet scheduled)
- Tooltip delay (above).
- Cover loading during scroll (above).
- Selection lag (above).
- OCR'd scanned books: hits are page-granular (no in-page highlight boxes) —
  store Vision word geometry to fix (extractor_version bump).
- macOS 26 "footprint" tool reports two PDFReader lines occasionally
  (stale process match) — cosmetic in verification scripts.
