# Keybindings

Every shortcut in the app. **Source of truth is the command table**
(`Sources/ReaderUI/Commands/CommandRegistry.swift`) — the menu bar, the
command palette (⌘⇧P), and the help overlay ("/" or "?") all render from it,
and this document mirrors it. If you change a binding, change the table;
update this file in the same commit. `CommandRegistryTests` enforces unique
ids and no duplicate chords.

Conventions borrowed from VS Code (palettes, quick-open), Safari/Chrome
(tabs, history), Preview (go to page, layout), and Gmail/GitHub ("?" help).

## File

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘N | New Window | |
| ⌘T | New Tab… (open panel) | Browser convention |
| ⌥⌘O | Open File… | Moved twice: ⌘O → quick-open palette, then ⌘⇧O → Go to Section. The panel is also in the "+" tab-strip menu. |
| ⌘⇧L | Open Library | Bound at scene level on the Library window; the File-menu item deliberately installs no second binding. |
| ⌘W | Close Tab (falls back to window) | Browser convention |
| ⌘⇧W | Close Window | Browser convention |

## Navigation

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘[ / ⌘] | Back / Forward in jump history | Browser/Preview convention; toolbar buttons offer right-click history menus. |
| ← / → | Previous / Next page | Handled in `ReaderPDFView.keyDown` so it works in continuous display modes too (PDFView only paged in single-page mode). Bare arrows only — ⇧/⌘-modified arrows and text fields keep their normal behavior. |
| ↑ / ↓ | Scroll (PDFView native; pages in single-page mode) | |
| Space / ⇧Space | Scroll down / up a screen (PDFView native) | |
| ⌘G | Go to Page… | Owner request (was ⌥⌘G). ⌘G was free: find next/previous cycles with Enter/⇧Enter inside the search field. Also available in the bottom-bar page field. |
| ⌘P (or ⌘O) | Open Anything… — the OPEN palette | Fuzzy search over every open tab (all windows), every library book, and every collection and tag. Return opens/switches; **⌘Return opens in a background tab (palette stays up for queueing several); ⌥Return opens in a new window**. Collections/tags open every book inside as tabs. VS Code ⌘P / Obsidian ⌘O. |
| ⌘⇧O | Go to Section… — the IN-BOOK palette | Sections (with breadcrumb paths) and bookmarks of the current book. ⌘Return opens the section as an adjacent background tab. VS Code go-to-symbol. |

## Tabs

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌃Tab / ⌃⇧Tab | Next / Previous tab (wraps) | Bound by a window-scoped NSEvent monitor (SwiftUI menus can't reliably own ⌃Tab). |
| ⌘⇧] / ⌘⇧[ | Next / Previous tab (wraps) | Safari/Chrome convention. |
| ⌘1 … ⌘8, ⌘9 | Go to tab by position; ⌘9 = LAST tab | Browser convention; key monitor, not menu items. Page-layout modes moved to ⌥⌘1–4. |
| — | Duplicate Tab, Close Other Tabs | Menu, tab context menu, or command palette. |

## View

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌃⌘S | Show/hide sidebar | Was previously bound on the toolbar button; now owned by the View-menu item (same key). |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 | Single Page / Continuous Scroll / Two Pages / Two Pages Continuous | Moved from plain ⌘digits, which now switch tabs (browser convention won). |
| — | Fit Width / Fit Height | Bottom bar or command palette. |
| — | Light / Dark / Sepia theme | Menu (checkmarked), bottom bar, or command palette. |

## Search

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘F | Find in Document (opens search sidebar, focuses field) | |
| ⌘⇧F | Search All Books — library-wide full text | Opens the Library window with the search field focused, from anywhere. VS Code/Obsidian global-search convention. |
| Esc / Return | Library: clear selection / open selection | Bound locally in `LibraryView`. |

## Bookmarks

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘D | Bookmark This Page | Browser convention. |

## Help & Palettes

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘⇧P | Command Palette — fuzzy over every command | VS Code convention (its Help menu also lists "Show All Commands"). |
| / or ? | Keyboard-shortcut help overlay | Gmail/GitHub convention. Only fires when no text field is being edited, so "/" still types in search fields and palettes. Press again (or Esc) to close. |
| Esc | Close palette / help overlay | Focus returns to the PDF so arrows keep paging. |

## Palette keys (while open)

↑ / ↓ move the selection (wraps), Return runs it, Esc closes, click outside
closes. **⌘Return / ⌘-click** = open in a background tab (the palette stays
open so you can queue several); **⌥Return / ⌥-click** = open in a new
window. Matched characters are highlighted; results are ranked title-match
first, breadcrumb-match second.

## Reassignments & conflicts found in the audit (2026-07-08)

- **⌘O**: was Open File; backlog assigns it to the navigate palette. Palette
  wins (quick-open convention); Open File moved to ⌘⇧O. The ⌘O alias is
  bound by the key monitor, ⌘P by the menu item — one action, two chords,
  both listed in the table.
- **⌘P**: was the system Print menu item (the app has no print feature).
  Freed via `CommandGroup(replacing: .printItem)`. If printing is ever
  added, don't reclaim ⌘P — use the palette or another chord.
- **⌘⇧L**: bound twice conceptually (Library scene shortcut + File menu
  item). Resolved with `installsMenuShortcut: false` on the table entry so
  only the scene binding exists.
- **⌃⌘S**: was on the toolbar button; a table-driven menu item would have
  double-bound it. The toolbar button no longer installs the shortcut.
- **"/" in search fields**: the help-overlay monitor checks the window's
  first responder and never fires while any text field (including the
  palette query and page-number field) is editing.
- **Arrows**: deliberately NOT menu shortcuts — a menu binding would steal
  arrow keys from every text field in the window. Table entries carry the
  chords for documentation; `ReaderPDFView.keyDown` owns the behavior.
- **⌘G**: reassigned to Go to Page (owner request, 2026-07-08). Preview's
  ⌘G = find-next convention is intentionally dropped — find next/previous
  live on Enter/⇧Enter in the search field. Don't rebind ⌘G to find.
- **Palette split (owner request, 2026-07-08)**: ⌘P/⌘O = OPEN palette
  (tabs, books, collections, tags), ⌘⇧O = IN-BOOK palette (sections,
  bookmarks). Open File… moved ⌘⇧O → ⌥⌘O to make room.
- **⌘1–9 → tab switching** (owner chose tabs over layouts, 2026-07-08);
  layouts moved to ⌥⌘1–4. ⌘1–9 bound by the key monitor, not menus (nine
  menu items would be clutter); listed in the command table with
  `installsMenuShortcut: false` so the help overlay and palette show them.
- Not yet bound anywhere (future candidates): ⌘⇧G find previous,
  ⌘+/⌘−/⌘0 zoom, ⌘\\ split view, ⌘B sidebar (VS Code), ⌘, settings (M18).
