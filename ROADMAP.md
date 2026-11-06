# Roadmap

Live plan for **Auto**: phases, status, backlog and key decisions. Tick items as they land, and add new work to the right phase rather than to the bottom.

See also: [CLAUDE.md](CLAUDE.md), [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Vision

Plug in a card and Auto does the rest: it backs the footage up safely, files it under the right shoot, makes proxies, and opens a ready-to-cut DaVinci Resolve project.

## Backed → Auto: what "better" means

| Area | Backed | Auto target |
| :--- | :--- | :--- |
| Scope | Ingest + verify only | Ingest **+ editing pipeline** |
| App shell | AppKit `NSStatusItem` + `NSPopover`, SwiftPM + `build.sh` | Menu bar status item that opens a full app window (no dropdown), Xcode project, shared scheme |
| State | `ObservableObject` + Combine | `@Observable` |
| Tests | None | Swift Testing on every Core engine |
| Destinations | One work folder | Primary + optional backup destination(s) |
| Resumability | Re-scan diff | Persisted ingest index; resume after unplug or crash |
| Feedback | Popover + icon tint | + system notifications on finish / failure |

---

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
- [ ] Move remaining main-thread disk touches out of views (`workingVolume`, the stat calls in `shootFolders`)
- [ ] Detect a work folder that is itself on a camera card
- [x] New Shoot preview shows sanitized camera folder names
- [ ] AppModel test harness (fake VolumeWatcher) to cover card lifecycle wiring
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
- [ ] Card browser: verify on screen, needs a running app: Quick Look open/switch/Space toggle with no "no controller" log; arrows working right after opening or switching to icons; column count with always-visible scrollbars; scroll-to under pinned headers; ⌘-click on duplicated rows in list mode; sidebar spinner/warning rows; Add to Shoot, context menus and CardRow buttons still working with the row tap
- [ ] Shoot flows are untested on the card-lifecycle paths: card removal clearing coverage, `addFootage` before coverage finishes, copy completion re-running coverage, recompute with a card inside a shoot, `mkdir` EEXIST race. Needs a card-source injection seam instead of `#if DEBUG _testInsert`
- [ ] Verify the Shoots grid and New Shoot / Add Footage sheets visually (launch the app, check the window); not yet done
- [ ] Per-root `DriveIndex` caching across recomputes
- [ ] Keep camera A/B suffixes consistent across cards (e.g. reuse the folder mapping already in the shoot)
- [ ] Move `shootPreview`/`createDirectories` file checks off the main actor (debounce preview); `shootPreview` is gone, so re-check the same checks in `ShootFolders` and `addFootage`
- [ ] Harden `CopyEngine` against symlink swaps between check and write (`O_NOFOLLOW`/`openat`)

## Phase 2b: Mirrors, sync and duplicates

A shoot can have mirror copies on other drives. Copies are checked and synced on demand, and ingest skips footage that is already backed up.

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

## Phase 3: Editing pipeline

- [ ] `PipelineStep` protocol + `Pipeline` runner (ordered, per-step result, re-runnable, cancellable)
- [ ] Step: organize (separate video / photo / audio, consistent naming)
- [ ] Step: proxies (AVFoundation, configurable codec/resolution)
- [ ] `ResolveClient` behind a protocol + fake for tests
- [ ] Step: Resolve project (create project from template, import media, bins per camera, timeline at clip resolution/fps)
- [ ] Per-shoot pipeline settings (which steps run)

## Phase 4: Polish & release

- [x] Main window redesign: sidebar tabs (Media, Video Edit, Photo Edit, Settings), Ingest button, account row, floating content panel
- [x] Light/dark/system appearance (Settings tab + account menu)
- [x] Media tab: "Shoots" grid from the shoot registry (thumbnails, counts, availability); placeholder tiles gone
- [ ] Video Edit / Photo Edit tabs (empty placeholders now)
- [ ] Wire up "Soon" settings: eject after backup, sound, proxy codec/resolution, Resolve project + frame rate, RAW+JPEG grouping, DNG
- [ ] User accounts (sidebar shows the local macOS user for now)

- [ ] Notifications on completion / failure
- [ ] Ingest history + resumable index
- [x] Optional second backup destination (shipped as shoot mirrors, see Phase 2b)
- [ ] Launch at login
- [ ] App icon
- [ ] Developer ID signing + notarization; release build script
- [ ] `release-readiness` checklist passes

---

## Backlog / Ideas

- xxHash for faster verification on large cards
- Proxy generation in Resolve instead of AVFoundation
- Investigate one-off Media Library (Apple Music) TCC prompt seen on a fresh build; likely stale TCC grant after re-signing
- Show in Finder for shoots (cards already have it)
- Edit a shoot's name or date (v1: fixed at creation)
- Card browser: reuse `AppModel.index` for shoots on the work volume instead of re-walking them in membership checks
- Card browser: test that card removal clears browser membership (needs a `VolumeWatcher` seam)

## Key Decisions

| Date | Decision | Why |
| :--- | :--- | :--- |
| 2026-11-03 | Xcode project (not SwiftPM like Backed) | Asset catalogs, signing, previews, test hosting |
| 2026-11-03 | App Sandbox **off** | Needs free access to `/Volumes/*`, the work folder, and spawning Resolve scripting. Revisit only for Mac App Store. |
| 2026-11-03 | Swift Testing over XCTest | Modern API, parameterized tests |
| 2026-11-03 | macOS 26 minimum | Latest SwiftUI APIs; personal tool |
| 2026-11-03 | Multi-agent workflow with model routing (`.claude/agents/`) | Parallel slices; cheap models for search/docs, opus for design/review |
| 2026-11-03 | Micro-commits, no AI co-author, never auto-push | Developer preference |
| 2026-11-03 | No menu bar dropdown: the status item opens the main window | Developer wants the app to live in the menu bar but open as a real window |
| 2026-11-03 | Drop Backed's animated `OrbView` | Developer found it cheesy; status is shown with a static tinted dot |
| 2026-11-03 | Settings is a tab in the main window, not a separate window | One window, sidebar navigation; Cmd-comma selects the tab |
| 2026-11-03 | Backed status requires checksum verification, not name+size | Same-name/same-size RAWs from different bodies could falsely show as backed |
| 2026-11-03 | Shoots are `<work folder>/<name>`, no client or date folders | Developer files shoots by name only; `Video`/`Photo` per camera |
| 2026-11-03 | New Shoot copies only the checked (camera, day) pairs; unselected files stay on the card as "Not backed up" | Explicit include-set: pairs that appear in a later scan are not auto-included, so nothing is copied that the user did not check |
| 2026-11-03 | Destination checks run before every folder creation and before every copy; path containment is lexical, symlinks resolved only at the nearest existing ancestor | Symlinks must not let a copy escape the work folder or land on a card; resolving the whole path made `/tmp` vs `/private/tmp` mismatch and broke the preview |
| 2026-11-03 | Shoots are first-class: name + one recording date + user-chosen location, folder `<parent>/<name>/{Video,Photo}/<camera>/`. Supersedes the fixed `<work folder>/<name>` layout above | Developer picks where each shoot lives; the date is what ties footage to a shoot |
| 2026-11-03 | Other recording days are added to a shoot manually (Add Footage), not automatically | One date per shoot keeps the shoot's identity clear; a second day is an explicit action |
| 2026-11-03 | A shoot is "complete" when every card file from the shoot's date has a checksum-verified copy in the shoot folder | Name or size matches, or files from other days, must not make a shoot look done |
| 2026-11-03 | Verified copies in any online registered shoot count toward a card's backed-up status ("any shoot counts"); roots containing cards are excluded | Footage can live in several shoots; a copy only counts once checksum-verified |
| 2026-11-03 | Existing plain folders are used only through an explicit "Use this folder" | Auto must not take over a user's folder silently |
| 2026-11-03 | Shoot identity lives in `.auto-shoot.json` in the folder; the registry in Application Support is a list of known shoots. A corrupt registry is kept as `shoots.json.corrupt-<ts>`, never overwritten. Forget removes the registry entry only | The shoot survives relocation and rescans; no silent loss of the list or any file |
| 2026-11-03 | Shoot name and date are not editable in v1 | Keeps v1 small; editing is in the Backlog |
| 2026-11-04 | Card browser membership is per shoot, read-only, and runs only while the browsed card is shown and the main window is visible; a partial or cancelled shoot check is never reported | A failed or interrupted check must not hide a copy or shrink "Not Backed Up"; Add Footage keeps its own coverage so the two cannot interfere |
