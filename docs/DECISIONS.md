# Decision log

Reasoning behind choices that aren't obvious from the code. Newest last.

1. **Native Swift/SwiftUI/PDFKit over Electron/Tauri.** Every hard
   requirement pointed native: memory control (PDFKit mmaps; we control view
   lifetime), current-Space window placement (NSWindow.collectionBehavior —
   not reachable from cross-platform shells), iPhone support, and free sync
   via CloudKit. Owner approved 2026-07-07.

2. **All logic in a root SwiftPM package; app shells are thin.** Enables
   `swift test` without Xcode (Phase A was built before Xcode was even
   installed), keeps UI-independent logic testable, and lets iOS reuse
   ReaderCore/persistence directly.

3. **Hand-authored pbxproj (objectVersion 77) with synchronized folder
   groups.** Adding files under App/macOS or App/iOS requires NO pbxproj
   edits — critical for agent workflows (no pbxproj merge churn). XcodeGen
   was considered and skipped; revisit only if the project file becomes a
   conflict hotspot.

4. **GRDB is the only dependency.** SQLite+FTS5+migrations in one
   battle-tested SwiftPM package. Keep the surface small for OSS release.

5. **Calibre is read-only, and the app has its OWN library.** Owner wants
   loose PDFs (downloads, homework) without Calibre import friction. Calibre
   remains source of truth for its metadata; the app never writes
   metadata.db and never opens the live file (Calibre may be mid-write; the
   file may be on iCloud) — coordinated copy first. Overlay tags/collections
   attach via calibre_uuid.

6. **Session restore is custom (session.json), not @SceneStorage/NSWindow
   restoration.** System restoration can't represent "3 windows × N tabs
   with per-tab history", fights programmatic window opening, and isn't
   portable to iOS. Versioned JSON with migration hooks; debounced writes.

7. **NavigationHistory lives in ReaderCore, not PDFView.goBack.** PDFView's
   history is opaque and unpersistable; ours survives restart, tab moves
   across windows, and duplication.

8. **Mac app is NOT sandboxed (direct-download distribution); iOS is.**
   Simplifies Calibre-folder access on Mac. iOS uses security-scoped
   bookmarks. If Mac App Store distribution is ever wanted, sandboxing is a
   retrofit project (folder-grant flows exist already, so it's feasible).

9. **Content hash = SHA-256(first 128 KiB ‖ file size).** Full-file hashing
   of 500 MB textbooks is too slow for scan/open paths; head+size is stable
   under Calibre renames/moves and cheap. Hash is the universal book
   identity for non-Calibre files and the index key.

10. **OCR inside the indexing actor, extractor_version-gated.** Owner
    explicitly wants search in scanned books. Vision runs per page only when
    the text layer is empty; bumping extractor_version re-indexes the world.
    OCR'd math is best-effort by design. Word-geometry storage (for in-page
    scan highlights) deliberately deferred.

11. **Theme page filtering via blend modes in PDFPage.draw.** Works on iOS
    (CALayer.filters doesn't), testable at the pixel level, and needs no
    per-page bitmap work. Images invert under dark mode — accepted for v1;
    hue-preserving invert is a possible macOS-only nicety later.

12. **Two-round UI feedback pattern.** Owner tests real builds and reports;
    fixes land same-session. Notable fixes with root causes worth
    remembering: sidebar dead-space = missing maxHeight fills in HSplitView
    children; library freeze = full-size synchronous NSImage cover decodes
    (now CGImageSource-downsampled off-main, NSCache, evicted files
    downloaded with a bounded wait); slow first library open = one write
    transaction per book (now single batch).

13. **Search never navigates while typing.** Owner preference: results
    accumulate in the sidebar list; only explicit clicks move the document
    (and push history — one push per explicit click).

14. **⌘-click opens the new tab ADJACENT to its source; same-book tabs get
    a group dot.** Chrome-style implicit grouping. Full collapsible tab
    groups / sub-tab rows are a possible future step (owner asked for "at
    least" grouping).

15. **Parallel agent workflow.** Independent milestones run as worktree
    agents on branches (Package.swift pre-declares all targets so agents
    never touch it); main session merges, resolves PROGRESS.md checkbox
    conflicts, and verifies. An agent killed mid-run by an API error was
    resumed with no loss — worktree + small commits make interruptions
    cheap.

16. **Sync (M15): snapshot-diff engine over plain CKDatabase ops, not
    CKSyncEngine.** The plan named CKSyncEngine, but its inverted delegate
    model (the framework schedules and asks you for batches) fights a
    pull-style `SyncTransport` protocol, and none of it can be live-tested
    until the owner's signing steps land — blind code should be simple
    code. So: the engine exports full portable snapshots, diffs against a
    `sync_shadow` of last-server-confirmed records, and pushes with
    `.allKeys` (safe because merging is field-level LWW by modified_at and
    every push is preceded by a fetch; a racing overwrite converges next
    cycle). Deterministic record names double as the dedup strategy; names
    can be hashed (255-byte cap) so they are never parsed — the shadow is
    the only name→content resolver, which is also what makes incoming
    CK deletes resolvable. Soft deletes travel as tombstone RECORDS (LWW
    keeps delete-vs-edit sane); only 30-day purges become CK deletes. Own
    push echoes (fetched records whose change tag matches the shadow) are
    skipped — applying them resurrects purged/renamed rows (test-pinned).
    CKSyncEngine (push-notification-driven sync) remains a possible later
    upgrade behind the same transport seam. Full notes: SYNC.md.
