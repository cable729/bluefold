# pdf-app (working title)

A native macOS (and soon iOS) PDF reader built for people who live in large
textbooks — designed around memory efficiency, browser-style navigation, and a
taggable library.

## Why another PDF reader?

Existing viewers fall over on a specific workflow: keeping 10+ GB of math
textbooks open at once, jumping through internal cross-references, and finding
things again later. This app is built around:

- **Bounded memory** — only the visible tab holds a live rendered document;
  background tabs keep lightweight state (file, page, zoom, history) and
  reload lazily. Open as many books as you like.
- **Browser-style navigation** — tabs, multiple windows, per-tab back/forward
  history, ⌘-click an internal link to open it in a new tab.
- **Windows that stay put** — new windows open in your *current* macOS Space.
- **Full session restore** — quit and relaunch to exactly the windows/tabs you had.
- **Library with real tagging** — hierarchical tags and collections (mix
  textbooks and homework PDFs), with an existing
  [Calibre](https://calibre-ebook.com) library attached as a read-only source.
- **Full-text search across the library** — background-built SQLite FTS5 index
  finds text in books you've never opened.
- **Themes** — light, dark, and sepia, applied to PDF pages too (smart
  invert / warm-paper rendering).
- **Sync without a subscription** — tags, collections, bookmarks, and reading
  position sync between Mac and iPhone via CloudKit (your iCloud account, no
  third-party service).

## Status

Early development. See [docs/PROGRESS.md](docs/PROGRESS.md) for the milestone
tracker.

## Architecture

All logic lives in a SwiftPM package at the repo root (buildable and testable
with `swift test`, no Xcode required); the macOS/iOS app targets are thin
shells in `App/`.

| Module | Purpose |
|---|---|
| `ReaderCore` | Tab/session/history models, themes (pure Swift, Codable) |
| `ReaderPersistence` | Overlay library DB — tags, collections, bookmarks, reading state (GRDB/SQLite) |
| `CalibreKit` | Read-only Calibre `metadata.db` access (never writes) |
| `SearchIndexKit` | FTS5 full-text indexing of PDF text |
| `SyncKit` | CloudKit sync behind a transport protocol |
| `ReaderUI` | Shared SwiftUI views + PDFKit wrappers |

## Development

```sh
swift build      # build everything
swift test       # run the full unit/integration suite
```

Requires macOS 15+ and Swift 6. The app targets (in `App/`) require Xcode 16+.

## License

[MIT](LICENSE)
