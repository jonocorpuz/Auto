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
- [ ] Media tab: real "Recent shoots" grid from the work folder (placeholder tiles now)
- [ ] Video Edit / Photo Edit tabs (empty placeholders now)
- [ ] Wire up "Soon" settings: eject after backup, sound, proxy codec/resolution, Resolve project + frame rate, RAW+JPEG grouping, DNG
- [ ] User accounts (sidebar shows the local macOS user for now)

- [ ] Notifications on completion / failure
- [ ] Ingest history + resumable index
- [ ] Optional second backup destination
- [ ] Launch at login
- [ ] App icon
- [ ] Developer ID signing + notarization; release build script
- [ ] `release-readiness` checklist passes

---

## Backlog / Ideas

- xxHash for faster verification on large cards
- Proxy generation in Resolve instead of AVFoundation
- Investigate one-off Media Library (Apple Music) TCC prompt seen on a fresh build; likely stale TCC grant after re-signing

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
