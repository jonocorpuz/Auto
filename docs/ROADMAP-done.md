# Roadmap: completed items

Archive of shipped ROADMAP.md items, by phase. Not needed for day-to-day work; grep it when you need history.


## Phase 1: Foundation ✅
- [x] Xcode project `Auto`, macOS 26, menu bar only (`LSUIElement`)
- [x] Menu bar shell + `Settings` (MenuBarExtra popover, later replaced by a status item that opens the main window)
- [x] `AppModel` with status + persisted work folder
- [x] Swift Testing target `AutoTests` + shared scheme
- [x] CLAUDE.md, ARCHITECTURE.md, ROADMAP.md, skills, routed subagents
- [x] GitHub repo `jonocorpuz/Auto`

## Phase 2: Ingest parity with Backed
- [x] Fixture card builder for tests (DCIM + Sony `PRIVATE/M4ROOT` layouts)
- [x] `MediaTypes` / `MediaKind` classification (video, photo, audio)
- [x] `CardScanner`: enumerate media, detect camera (EXIF, QuickTime, Sony XML sidecar), shoot date
- [x] `DriveIndex`: what already exists in the work folder (name + size keys)
- [x] `CopyEngine`: streamed copy, temp name + atomic rename, size + hash verify, unique names, cancel
- [x] `VolumeWatcher`: detect card mount/unmount, ignore non-card volumes
- [x] New Shoot flow: shoot name → folder preview (`<work folder>/<shoot name>/{Video,Photo}/<camera>/`)
- [x] Status item: click opens the main app window (no dropdown/popover); right-click menu for Settings / Quit
- [x] Status icon states: idle / unbacked / copying / backed / error (static "a." with tinted dot, no animation)
- [x] `-AutoFixtureCard <path>` launch argument for manual testing
- [x] Backup status is checksum-verified (`BackupVerifier`): green only when every card file matches a drive copy by hash
- [x] Copy hardening: unique `O_EXCL` partials, `renamex_np` `RENAME_EXCL`, `F_FULLFSYNC` + uncached read-back
- [x] New Shoot has no client or date: shoot name only (required), layout `<work folder>/<shoot name>/{Video,Photo}/<camera>/`, "Footage" renamed "Video", no "Project" folder
- [x] Existing shoot folder: Auto adds into it (`CopyEngine` never overwrites); preview marks folders "already there"
- [x] New Shoot preview rows come from `ShootPlanner.folders(for:shoot:root:)`, built from the same copy jobs `createShoot` uses
- [x] Date format setting and client helpers/suggestions removed; Settings has no "Shoots" section
- [x] `ShootDays.byCamera`: recording days per camera; CardRow shows day chips per camera (e.g. "Mar 22 · 120", "2 days") so two shoots on one card are obvious
- [x] Camera labels never include the serial; same-model bodies get letter suffixes ("FX3 A", "FX3 B") applied to label and folder name (`Camera.disambiguated`)
- [x] New Shoot sheet themed (Theme tokens, `SurfaceCard`), labels above full-width fields
- [x] Safety review fixes: verified copies keyed by card-file identity, refuse card destinations, empty/unreadable phases, path sanitizing, card identity by volume UUID, scans/indexing off main
- [x] New Shoot preview shows sanitized camera folder names
- [x] New Shoot: choose cameras and recording days. Each camera has a checkbox and its days (from the card's not-yet-backed-up files), all checked by default; only checked (camera, day) pairs are copied. Files with no camera show under "Other files" (`ShootSelection`, include-set, injected calendar)
- [x] Partial shoots: unselected files stay "Not backed up"; copied files are pruned from `card.missing` before re-verify, so a second New Shoot lists only leftovers
- [x] Destination safety: folders created one component at a time (`ShootPlanner.createDirectories` with `checkDestination`); symlinks resolved via the nearest existing ancestor; rejects card destinations, paths outside the work folder and files where folders should be. `AppModel.copy` re-checks every destination before starting
- [x] Path containment is lexical, fixing the `/tmp` vs `/private/tmp` mismatch that broke the shoot preview
- [x] Camera folder suffixes skip taken names; `Camera.defaultFolderName` fallback; case-insensitive folder merge
- [x] `DayChip` shared by CardRow and the New Shoot sheet; `Format.count` gives "1 file" / "N files"
- [x] Shoots are first-class: a shoot is a name, one recording date and a user-chosen location (`<parent>/<name>/{Video,Photo}/<camera>/`); other days are added manually
- [x] `Shoot` + `ShootSidecar`: `.auto-shoot.json` in each shoot folder, versioned (v1: id, name, day `yyyy-MM-dd`, createdAt)
- [x] `ShootFolders`: classifies a name or folder (free, existing shoot, plain folder, not a folder, unreadable, invalid name); creates shoots with an exclusive mkdir (the parent is never created) and an exclusive sidecar write (`O_EXCL` temp, `F_FULLFSYNC`, `renameatx_np` `RENAME_EXCL`, card check). Plain folders are adopted only through "Use this folder"
- [x] `ShootRegistry` / `ShootStore`: known shoots in `~/Library/Application Support/Auto/shoots.json`; a corrupt file is kept as `shoots.json.corrupt-<ts>`; saves are serialized (`ShootRegistrySaver`); availability is online / offline / missing / mismatch; discovery looks one level under the work folder; card folders count as missing
- [x] `ShootCoverage` / `ShootCoverageChecker`: per (shoot, card), checksum-verified, cancellable and off main; only looks inside the shoot folder and never counts card files; an unreadable shoot folder is a failure, not zero
- [x] `ShootSummary` (counts + representative file); `ThumbnailProvider` with `QLThumbnailProvider` (QuickLook) and a fake for tests
- [x] `AppModel` shoots: load, create, adopt, locate, forget (forget removes the registry entry only, never files), coverage per (shoot, card), `addFootage` (fresh coverage awaited, plans only files not in the shoot, works for backed cards too)
- [x] Verified copies in any online registered shoot count toward a card's backed-up status; roots containing cards are excluded and volume identity de-duplicates
- [x] Sidebar "Ingest" renamed "New Shoot"; Media "Recent shoots" replaced by a "Shoots" grid (thumbnail, counts, offline/missing dimmed, Locate…, Remove from Auto)
- [x] `NewShootView` create mode (name, date, location, collision line + "Use this folder"); `AddFootageSheet` (card picker, date auto-selection, completeness banner, "Add N files"); CardRow "Add to Shoot" menu with date-matched shoots first
- [x] Card-first shoot flow removed (`createShoot(card:…)`, `shootPreview`, `ingestCandidate`); shoot-first flow is the only one
- [x] Card browser: clicking a card opens a read-only, Finder-style page (icon grid with QuickLook thumbnails or list, locations sidebar, status bar). Files are grouped by `CardBrowser.group` into "Not Backed Up", one group per online shoot holding the verified copy, and "Backed Up Elsewhere"; `Card.backups` records each file's verified copy
- [x] Card browser actions: Quick Look (Space toggles, double-click opens), Show in Finder / Show Backup in Finder, Add to Shoot for the selection (`AppModel.addFiles` → `addFootage(onlyFiles:)` → `copy`; refuses when a plan is already pending). Groups are memoized; thumbnails keyed by file identity with a negative cache
- [x] Card browser: a file with a verified copy in several shoots appears under each of them (`ShootMembership` checks every online shoot, excluding nested shoots; "Not Backed Up" stays exclusive; `browserMembership` is separate from Add Footage coverage)
- [x] Card browser: Finder-style grid selection and keyboard navigation (`GridSelection`: click, ⌘/⇧, ⌘A, arrows, Home/End, section-aware); Quick Look takes panel control through the responder chain (`AppDelegate`)

## Phase 2b: Mirrors, sync and duplicates
- [x] Mirrors are explicit (New Shoot destinations, Add Mirror, Locate…); discovery never adds them. `ShootRecord` carries `mirrors` and `pendingSync`; an older `shoots.json` decodes with none
- [x] Same-drive copies are refused as mirrors (`.sameVolume`)
- [x] Ingest fans out to every online copy of a shoot; an unreached copy is marked `pendingSync` and shows a yellow badge
- [x] Overlapping copies queue (`queuedBehind`) instead of failing
- [x] `FileHasher`: cancellable MD5, uncached reads, 8 MB chunks
- [x] `ChecksumStore`: persistent MD5 cache in `checksums.json`; saves are serialized; verified copies seed it
- [x] `ShootSyncChecker`: size pass, then checksum pass; strictly read-only; any uncertainty is a conflict or "not checked", never "in sync"; nested shoots are not descended into
- [x] `ShootSyncPlanner` / Sync Now: copies files missing from a good copy; never deletes or overwrites; leaves conflicts for the user
- [x] Sync Now and ingest exclude each other (one serial scheduler in `AppModel`)
- [x] Shoot tile badge: green (all copies match), yellow (out of sync), grey (unknown), with a tooltip; "Copies" context submenu
- [x] Shoot popover: Check Again (⌥ for a deep check), Verify Contents, Sync Now, Stop; last full verify kept in `sync-meta.json`
- [x] Duplicate detection at ingest (`IngestDuplicates`): card files already verified elsewhere by name + size + MD5 are skipped by default; "Copy duplicates anyway" toggle in Add Footage
- [x] CardRow shows an "already backed up" count, a queue note and a mirror note; Add Footage shows copy and mirror notices
- [x] Card browser asks before copying duplicates ("Copy Anyway")

### Verify on screen (developer, remote; nothing here has been seen in a running app yet)
