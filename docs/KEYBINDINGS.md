# Keybindings

Every shortcut in the app. **Source of truth is the command table**
(`Sources/ReaderUI/Commands/CommandRegistry.swift`) — the menu bar, the
command palette (⌘⇧P), and the help overlay ("/" or "?") all render from it,
and this document mirrors it. If you change a binding, change the table;
update this file in the same commit. `CommandRegistryTests` enforces unique
ids and no duplicate chords. Users can override any of it with a
keybindings.json overlay — see "User keybindings" below.

Conventions borrowed from VS Code (palettes, quick-open), Safari/Chrome
(tabs, history), Preview (go to page, layout), and Gmail/GitHub ("?" help).

## File

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘N | New Window | |
| ⌘T | New Tab… (open panel) | Browser convention |
| ⌥⌘O | Open File… | Displaced by the palettes. The panel is also in the "+" tab-strip menu. |
| ⌘⇧L | Open Library | Bound at scene level on the Library window; the File-menu item deliberately installs no second binding. |
| ⌘W | Close Tab (falls back to window) | Browser convention |
| ⌘⇧W | Close Window | Browser convention |
| ⌘⇧T | Reopen Closed Tab | Browser convention. Pops the most recently closed tab OR window (up to 30 this run), with position, zoom, and history intact. A tab returns to the window it was closed in when possible. |

## Navigation

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘[ / ⌘] | Back / Forward in jump history | Browser/Preview convention; toolbar buttons offer right-click history menus. |
| ← / → | Previous / Next page | Handled in `ReaderPDFView.keyDown` so it works in continuous display modes too (PDFView only paged in single-page mode). Bare arrows only — ⇧/⌘-modified arrows and text fields keep their normal behavior. |
| ↑ / ↓ | Scroll (PDFView native; pages in single-page mode) | |
| Space / ⇧Space | Scroll down / up a screen (PDFView native) | |
| ⌘G | Go to Page… | Was ⌥⌘G. ⌘G was free: find next/previous cycles with Enter/⇧Enter inside the search field. Also available in the bottom-bar page field. |
| — | Previous / Next Section | Status-bar ⇤ ⇥ buttons flanking the page arrows; also in the Go menu and command palette. Every outline entry (any depth) is a stop; pushes history (⌘[ returns). |
| ⌘O | Open Anything… — the OPEN palette | Fuzzy search over every open tab (all windows), every library book, and every collection and tag. Return opens/switches; **⌘Return opens in a background tab (palette stays up for queueing several); ⌥Return opens in a new window**. Collections/tags open every book inside as tabs. Obsidian quick-open. |
| ⌘P (or ⌘⇧O) | Go to Section… — the IN-BOOK palette | Sections (with breadcrumb paths) and bookmarks of the current book. ⌘Return opens the section as an adjacent background tab. ⌘O = other books, ⌘P = within this book. ⌘⇧O alias keeps VS Code go-to-symbol muscle memory (key monitor). |

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
| ⌘B | Show/hide sidebar | VS Code/Obsidian convention (was ⌃⌘S — do not rebind ⌘B to bold, the app has no text editing). |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 | Single Page / Continuous Scroll / Two Pages / Two Pages Continuous | Moved from plain ⌘digits, which now switch tabs (browser convention won). |
| ⌘\ | Split Right (toggle) | VS Code convention. No split → duplicates the active tab into a right split; any split open → closes it. |
| — | Split Left / Close Split | Menu (checkmarked by side), tab context menu, or command palette. Dragging a tab over a window's PDF area also drops into a left/right split. |
| — | Split Down / Toggle Split Orientation | Split Down stacks the panes top/bottom (primary on top); the toggle flips an open split between side-by-side and top/bottom in place. Menu, tab context menu (Split Down), or command palette. |
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

## Links

| Shortcut | Action | Notes |
| --- | --- | --- |
| — | Copy Link to Here / Copy Link to Selection | Edit menu or command palette. Copies a `bluefold://` URL (content-hash based, survives file moves) that works from Obsidian or anywhere. Deliberately chordless — bind via keybindings.json if wanted. |

## Help & Palettes

| Shortcut | Action | Notes |
| --- | --- | --- |
| ⌘⇧P | Command Palette — fuzzy over every command | VS Code convention (its Help menu also lists "Show All Commands"). |
| / or ? | Keyboard-shortcut help overlay | Gmail/GitHub convention. Only fires when no text field is being edited, so "/" still types in search fields and palettes. Press again (or Esc) to close. |
| Esc | Close palette / help overlay | Focus returns to the PDF so arrows keep paging. |

## Palette keys (while open)

↑ / ↓ move the selection (wraps), Return runs it, Esc closes, click outside
closes. **⌘Return / ⌘-click** = open in a background tab (the palette stays
open so you can queue several); **⇧Return / ⇧-click** (or ⌥) = open in a
new window — browser convention: ⌘ = tab, ⇧ = window. Holding a modifier
shows its effect live: the selected row gets a "→ background tab"/"→ new
window" badge and the footer legend highlights the active variant. Matched
characters are highlighted; results are ranked title-match first,
breadcrumb-match second.

## User keybindings — keybindings.json

Shortcuts are user-editable via a JSON overlay applied over the default
table at launch (relaunch to apply changes). The palette, help overlay,
and menus all reflect overrides automatically because they render from
the one table.

**File**: `~/Library/Application Support/Bluefold/keybindings.json`
(strictly: `<AppDataDirectory>/keybindings.json`, so `BLUEFOLD_SESSION_DIR`
relocates it; `BLUEFOLD_KEYBINDINGS_FILE` overrides the exact path — both
for tests/automation). Run **"Preferences: Open Keybindings File"** from the
command palette (or the Help menu) to create it with a documented template
and open it.

**Format** — a JSON object mapping command id → chord string:

```json
{
  "_docs": ["keys starting with _ are ignored — JSON's comment stand-in"],
  "view.toggleSidebar": "cmd+shift+b",
  "tabs.select.1": "ctrl+1",
  "bookmarks.add": null
}
```

- A **chord** is modifiers + one key joined with `+`. Modifiers: `cmd`
  (aliases `command`, `meta`), `ctrl` (`control`), `opt` (`option`, `alt`),
  `shift` — any order, any case, spaces tolerated. Keys: single characters
  (letters, digits, `[ ] \ / ; ' , . = - + ` etc. — shifted punctuation is
  written as itself: `?`, not `shift+/`) plus `return` (`enter`), `tab`,
  `escape` (`esc`), `space`, `up`, `down`, `left`, `right`.
- A chord string **replaces ALL of the command's default chords**, aliases
  included (e.g. overriding `nav.goToSection` drops both ⌘P and ⌘⇧O).
- `null` or `""` **unbinds** the command (still runnable from the palette
  and menus, just chordless).
- Swaps and freed-chord reuse work in one file regardless of entry order.

**Validation** (never crashes on a bad file): unknown command ids,
unparseable chords, and chords already bound to another command are each
rejected individually and reported — one alert at launch plus a banner in
the "/" help overlay — while every valid entry still applies. Of two
entries claiming the same chord, the alphabetically-first command id wins.

**Limits** (by design):

- `nav.goToPage` is not rebindable and ⌘G cannot be given to anything else
  (see the ⌘G audit note below).
- Bare ←/→ paging is hardwired in `ReaderPDFView.keyDown`; an override on
  `nav.previousPage`/`nav.nextPage` adds a working chord but arrows keep
  paging too. Arrow keys can never be *assigned* via the overlay's monitor
  path (lists and text fields own them).
- Chords without ⌘/⌃/⌥ (like the default `/` help toggle) never fire while
  a text field is editing, so they still type.
- `file.openLibrary` is a scene-level shortcut: rebindable, but unbinding
  falls back to ⌘⇧L (a scene shortcut cannot be absent).
- Monitor-owned chords (see the audit notes) work in reader windows;
  menu-owned chords work app-wide. An override keeps its command's layer.

**Command ids** (defaults in parentheses; ids are stable API):

| Id | Command (default) |
| --- | --- |
| `file.newWindow` | New Window (`cmd+n`) |
| `file.newTab` | New Tab… (`cmd+t`) |
| `file.openFile` | Open File… (`opt+cmd+o`) |
| `file.openLibrary` | Open Library (`shift+cmd+l`) |
| `file.closeTab` | Close Tab (`cmd+w`) |
| `file.closeWindow` | Close Window (`shift+cmd+w`) |
| `nav.back` / `nav.forward` | Back / Forward (`cmd+[` / `cmd+]`) |
| `nav.previousPage` / `nav.nextPage` | Previous / Next Page (`left` / `right`) |
| `nav.previousSection` / `nav.nextSection` | Previous / Next Section (unbound) |
| `nav.goToPage` | Go to Page… (`cmd+g`, **not rebindable**) |
| `nav.openAnything` | Open Anything… (`cmd+o`) |
| `nav.goToSection` | Go to Section… (`cmd+p`, `shift+cmd+o`) |
| `tabs.next` / `tabs.previous` | Next / Previous tab (`shift+cmd+]`+`ctrl+tab` / `shift+cmd+[`+`ctrl+shift+tab`) |
| `tabs.select.1` … `tabs.select.9` | Go to tab N / last (`cmd+1` … `cmd+9`) |
| `tabs.duplicate` / `tabs.closeOthers` | Duplicate Tab / Close Other Tabs (unbound) |
| `tabs.closeToLeft` / `tabs.closeToRight` | Close Tabs to the Left / Right (unbound) |
| `tabs.reopenClosed` | Reopen Closed Tab (`shift+cmd+t`) |
| `view.toggleSidebar` | Show Sidebar (`cmd+b`) |
| `view.layout.singlePage` / `.continuous` / `.twoUp` / `.twoUpContinuous` | Page layouts (`opt+cmd+1`…`opt+cmd+4`) |
| `view.splitRight` | Split Right — toggle (`cmd+\`) |
| `view.splitLeft` / `view.closeSplit` | Split Left / Close Split (unbound) |
| `view.splitDown` / `view.splitOrientationToggle` | Split Down / Toggle Split Orientation (unbound) |
| `view.fitWidth` / `view.fitHeight` | Fit Width / Height (unbound) |
| `view.theme.light` / `.dark` / `.sepia` / `.auto` | Themes (unbound) |
| `search.find` | Find in Document (`cmd+f`) |
| `search.allBooks` | Search All Books… (`shift+cmd+f`) |
| `bookmarks.add` | Bookmark This Page (`cmd+d`) |
| `links.copyToHere` / `links.copyToSelection` | Copy Link to Here / to Selection (unbound) |
| `help.commandPalette` | Command Palette… (`shift+cmd+p`) |
| `help.shortcuts` | Keyboard Shortcuts overlay (`/`, `?`) |
| `prefs.openKeybindings` | Preferences: Open Keybindings File (unbound) |

Implementation: `KeyChord.parse`/`chordString` (round-tripping string form),
`Keybindings` (load/parse/apply/template) in
`Sources/ReaderUI/Commands/`, overlay applied in `CommandRegistry.all`;
`KeybindingsTests` covers parsing, merge, conflicts, and unbind semantics.

## iPadOS / iOS hardware keyboard

The iOS app has its own, much smaller command set
(`App/iOS/ReaderCommandsIOS.swift` — NOT the macOS command table; no
keybindings.json overlay, no palettes yet). Rendered by the iPadOS 26
menu bar and the hold-⌘ shortcut HUD. Chords deliberately mirror the
macOS table so nothing has to be relearned:

| Shortcut | Action |
| --- | --- |
| ⌥⌘O | Open PDF… (document picker) |
| ⌘⇧L | Open Library |
| ⌘W | Close Tab |
| ⌘[ / ⌘] | Back / Forward in jump history |
| ⌘⇧[ / ⌘⇧] | Previous / Next tab (wraps) |
| ⌘1 … ⌘8, ⌘9 | Go to tab by position; ⌘9 = LAST tab |
| ⌥⌘1 … ⌥⌘4 | Single Page / Continuous / Two Pages / Two Pages Continuous |
| ⌘B | Show/hide sidebar (Contents + Bookmarks) |
| ⌘\ | Split (toggle) — duplicates the active tab into a split; closes an open split. iPhone splits top/bottom; iPad splits right (the top-bar Split menu also offers Split Bottom / re-orient) |
| ⌘F | Find in Document — opens the sidebar's Find mode (results list; tap = jump + history push) |
| ⌘D | Bookmark This Page |
| ← / → | Previous / Next page (`ReaderPDFViewIOS.keyCommands`, priority over scroll; same bare-arrow rule as macOS) |

Touch translations of pointer-only macOS gestures: ⌘-click a link =
⌘-tap (hardware keyboard) or long-press → "Open in New Tab"; tab
right-click menu = long-press the tab cell; back/forward right-click
history menus = long-press the arrows; drag-to-split = drag a tab cell,
sidebar section, or PDF LINK onto the trailing edge of the page (links
also drag onto the tab strip). Long-press a tab cell for the tab menu
(Duplicate / Open in Split / Close / Close to Left / Close to Right /
Close Others); **tap the book cover cap** on a tab for the cover preview
panel (the macOS hover analog — shows the book; does NOT select the tab),
tap a tab's text to select it. The split panes carry a draggable divider
(dragging it to an extreme closes the shrunk pane) and a per-pane close
button. The sidebar filter field stands in for the ⌘P in-book palette;
the status-bar scroll-to-top gesture pushes jump history (⌘[ returns).
On iPhone, a **lock button** in the top bar keeps the toolbars visible
(the chrome otherwise auto-hides while reading and toggles on a page tap).
The reader sidebar (Contents / Bookmarks / Find) is reachable on iPhone
too via the top-bar sidebar button (presented as a sheet); its Contents
tab has a **follow-current-section toggle** (the location icon). Opening a
book resumes its last-read page. Bluefold registers as a PDF viewer /
open-in-place handler, so it appears in the iOS share sheet and "Open in…".

⌘O and ⌘P are intentionally UNBOUND on iOS — reserved for the open/in-book
palettes so the chords mean the same thing on every platform when those
arrive. Changing an iOS chord? Keep this table and the macOS table in
sync in the same commit.

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
- **⌘G**: reassigned to Go to Page (2026-07-08). Preview's
  ⌘G = find-next convention is intentionally dropped — find next/previous
  live on Enter/⇧Enter in the search field. Don't rebind ⌘G to find.
- **Palette split (2026-07-08)**:
  ⌘O = OPEN palette (tabs, books, collections, tags), ⌘P (alias ⌘⇧O) =
  IN-BOOK palette (sections, bookmarks). Open File… moved to ⌥⌘O.
- **⌘1–9 → tab switching** (tabs won over layouts, 2026-07-08);
  layouts moved to ⌥⌘1–4. ⌘1–9 bound by the key monitor, not menus (nine
  menu items would be clutter); listed in the command table with
  `installsMenuShortcut: false` so the help overlay and palette show them.
- Not yet bound anywhere (future candidates): ⌘⇧G find previous,
  ⌘+/⌘−/⌘0 zoom, ⌘\\ split view, ⌘, settings (M18).
