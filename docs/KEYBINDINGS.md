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
| ⌘⇧O | Open File… | **Moved from ⌘O**, which now opens the navigate palette (VS Code/Obsidian quick-open). |
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
| ⌘P (or ⌘O) | Go to Anything… — navigate palette | Fuzzy search over the outline (with breadcrumb paths), bookmarks, and every open tab in every window. VS Code ⌘P / Obsidian ⌘O. |

## Tabs

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌃Tab / ⌃⇧Tab | Next / Previous tab (wraps) | Bound by a window-scoped NSEvent monitor (SwiftUI menus can't reliably own ⌃Tab). |
| ⌘⇧] / ⌘⇧[ | Next / Previous tab (wraps) | Safari/Chrome convention. |
| — | Duplicate Tab, Close Other Tabs | Menu, tab context menu, or command palette. |

## View

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌃⌘S | Show/hide sidebar | Was previously bound on the toolbar button; now owned by the View-menu item (same key). |
| ⌘1 / ⌘2 / ⌘3 / ⌘4 | Single Page / Continuous Scroll / Two Pages / Two Pages Continuous | Preview uses ⌘1/⌘2 similarly. |
| — | Fit Width / Fit Height | Bottom bar or command palette. |
| — | Light / Dark / Sepia theme | Menu (checkmarked), bottom bar, or command palette. |

## Search

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘F | Find in Document (opens search sidebar, focuses field) | |
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
closes. Matched characters are highlighted; navigate results are ranked
title-match first, breadcrumb-match second.

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
- Not yet bound anywhere (future candidates): ⌘⇧G find previous,
  ⌘+/⌘−/⌘0 zoom, ⌘9 zoom-to-fit, ⌘⌥←/→ or ⌘1..9 direct tab selection.
