# Roadmap

Live plan for **Auto**: phases, status, backlog and key decisions. Tick items as they land, and add new work to the right phase rather than to the bottom.

See also: [CLAUDE.md](CLAUDE.md), [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Vision

Plug in a card and Auto does the rest: it backs the footage up safely, files it under the right client and shoot, makes proxies, and opens a ready-to-cut DaVinci Resolve project.

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
- [x] New Shoot flow: client autocomplete → shoot name → folder preview (`Client/YYYY-MM-DD Shoot/Camera/`)
- [x] Status item: click opens the main app window (no dropdown/popover); right-click menu for Settings / Quit
- [x] Status icon states: idle / unbacked / copying / backed / error (static "a." with tinted dot, no animation)
- [x] `-AutoFixtureCard <path>` launch argument for manual testing
- [x] Backup status is checksum-verified (`BackupVerifier`): green only when every card file matches a drive copy by hash
- [x] Copy hardening: unique `O_EXCL` partials, `renamex_np` `RENAME_EXCL`, `F_FULLFSYNC` + uncached read-back
- [ ] Manual end-to-end test with a real card + real work drive (copy, eject, auto-open on mount)
- [x] Safety review fixes: verified copies keyed by card-file identity, refuse card destinations, empty/unreadable phases, path sanitizing, card identity by volume UUID, scans/indexing off main
- [ ] Move remaining main-thread disk touches out of views (`workingVolume`, `existingClients`, `shootFolderExists`)
- [ ] Detect a work folder that is itself on a camera card
- [ ] New Shoot preview should show sanitized camera folder names
- [ ] AppModel test harness (fake VolumeWatcher) to cover card lifecycle wiring

## Phase 3: Editing pipeline

- [ ] `PipelineStep` protocol + `Pipeline` runner (ordered, per-step result, re-runnable, cancellable)
- [ ] Step: organize (separate video / photo / audio, consistent naming)
- [ ] Step: proxies (AVFoundation, configurable codec/resolution)
- [ ] `ResolveClient` behind a protocol + fake for tests
- [ ] Step: Resolve project (create project from template, import media, bins per camera, timeline at clip resolution/fps)
- [ ] Per-shoot pipeline settings (which steps run)

## Phase 4: Polish & release

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
| 2026-11-03 | Backed status requires checksum verification, not name+size | Same-name/same-size RAWs from different bodies could falsely show as backed |
