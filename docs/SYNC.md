# iCloud sync (M15)

Library data — tags, collections, bookmarks, reading positions — syncs
between devices through the user's private CloudKit database. Files never
sync (books live in Calibre/iCloud Drive/watched folders already), and
Calibre's own metadata is never written.

## Status

- **Code: DONE and unit-tested** (SyncKit engine + fake-transport
  convergence tests; `swift test --filter SyncKitTests`).
- **Live CloudKit: NOT yet verified** — it needs a build signed with iCloud
  entitlements, which needs the one-time setup below. Until then the
  app runs exactly as before; the Settings toggle reports why sync can't
  engage ("This build isn't signed with iCloud entitlements").

## Activation runbook (one-time, ~15 minutes; requires the developer-account holder)

1. **Add the Apple ID to Xcode** (GUI-only step): Xcode → Settings →
   Accounts → "+" → sign in with the developer account
   (cable729@gmail.com). The team (A448YLFLYC) is already set on both
   targets; the Apple Development certificate mints on the first signed
   build.
2. **Turn on the iCloud capability** for both targets in
   `App/Bluefold.xcodeproj`: select target → Signing & Capabilities →
   "+ Capability" → iCloud → check **CloudKit** → container
   `iCloud.com.cable729.bluefold` (create it there). Xcode will either
   adopt the prepared entitlements files (`App/macOS/Bluefold.entitlements`,
   `App/iOS/Bluefold-iOS.entitlements`) or write identical ones — if it
   creates new files, delete the prepared ones. This registers the container
   with the developer account and sets `CODE_SIGN_ENTITLEMENTS`.
3. **Build & run** (normal ⌘R). In Settings (⌘,) → iCloud sync → toggle on.
   Status should read "Syncing…" then "Last synced …". First sync creates
   the record zone (`BluefoldLibrary`) and the record types automatically
   (CloudKit's Development environment builds schema just-in-time from the
   first saves).
4. **Verify round trip**: tag a book, Sync Now, then check
   [CloudKit Console](https://icloud.developer.apple.com/) → the container →
   Data → Private Database → zone `BluefoldLibrary`. Records should appear
   (types: `book`, `tag`, `bookTag`, `collection`, `collectionItem`,
   `bookmark`, `readingState`; each carries one opaque `payload` field).
5. **Before ANY release build**: CloudKit Console → Schema → *Deploy Schema
   Changes to Production*. The Development environment only serves
   development-signed builds; a notarized release build hits Production,
   which is empty until deployed.

## Design (what a maintainer needs to know)

- **Module split**: `SyncKit` owns wire types (`SyncRecord`), record-name
  minting (`RecordMapper`), the transport protocol, and the engine
  (`SyncEngine` actor). `ReaderPersistence` owns everything that touches
  the database: portable natural-key types (`Portable*`), `syncExport()`,
  `syncApplyRemote(_)` (LWW), `syncApplyRemoteDeletes(_)`, and the
  local-only state tables (migration v6: `sync_shadow`, `sync_meta`,
  `sync_pending`). `ReaderUI.SyncCoordinator` is the app-side lifecycle
  (Settings toggle, launch + 15-min timer + Sync Now).
- **Identity**: record names are deterministic — books `b|cal:<uuid>` /
  `b|sha:<hash>`, tags/collections by full name path, relations by
  endpoint-key concatenation — so devices mint identical records and no
  dedup pass exists. Names longer than 250 bytes collapse to a SHA-256 form;
  therefore **names are never parsed** — the `sync_shadow` table is the only
  name → content resolver (needed for incoming deletes).
- **Merge**: last-writer-wins by `modified_at`; `reading_state` by max
  `updated_at`. Soft deletes travel as records with `deletedAt` (so LWW
  applies); only tombstone PURGES (30 days) travel as real record deletions.
- **Echo rule**: fetched records whose server change tag matches the shadow
  are this device's own push echoes and are skipped — applying them would
  resurrect rows purged or renamed since (test-pinned).
- **Tag/collection rename = delete + create** (path is identity). Book-tag
  rows re-mint under the new path in the same sync, so memberships survive.
- **Calibre-twin guard**: an incoming record whose secondary identity
  (e.g. content hash on a Calibre-keyed book) collides with a DIFFERENT
  local row applies without that field — sync never merges the known
  duplicate rows (whether to merge them is a pending decision).
- **CloudKit specifics**: private DB, one zone, `.allKeys` save policy
  (record-level LWW is safe because the engine field-merges by timestamp
  and fetches before every push; a racing overwrite converges next cycle).
  Poll-based (no push subscriptions yet — a future upgrade could adopt
  CKSyncEngine or CKQuerySubscription for live nudges).
- **Testing**: `FakeTransport` (in-memory server with change tags, tokens,
  and REAL conflict detection — stricter than CloudKit's allKeys mode).
  Convergence tests simulate two devices as two in-memory stores sharing
  one fake server. See `Tests/SyncKitTests/`.
