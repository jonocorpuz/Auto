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
| App shell | AppKit `NSStatusItem` + `NSPopover`, SwiftPM + `build.sh` | SwiftUI `MenuBarExtra`, Xcode project, shared scheme |
| State | `ObservableObject` + Combine | `@Observable` |
| Tests | None | Swift Testing on every Core engine |
| Destinations | One work folder | Primary + optional backup destination(s) |
| Resumability | Re-scan diff | Persisted ingest index; resume after unplug or crash |
| Feedback | Popover + icon tint | + system notifications on finish / failure |

---

## Phase 1: Foundation ✅

- [x] Xcode project `Auto`, macOS 26, menu bar only (`LSUIElement`)
- [x] `MenuBarExtra` popover + `Settings` scene
- [x] `AppModel` with status + persisted work folder
- [x] Swift Testing target `AutoTests` + shared scheme
- [x] CLAUDE.md, ARCHITECTURE.md, ROADMAP.md, skills, routed subagents
- [x] GitHub repo `jonocorpuz/Auto`

## Phase 2: Ingest parity with Backed

- [ ] Fixture card builder for tests (DCIM + Sony `PRIVATE/M4ROOT` layouts)
- [ ] `MediaTypes` / `MediaKind` classification (video, photo, audio)
- [ ] `CardScanner`: enumerate media, detect camera (EXIF, QuickTime, Sony XML sidecar), shoot date
- [ ] `DriveIndex`: what already exists in the work folder (name + size keys)
- [ ] `CopyEngine`: streamed copy, temp name + atomic rename, size + hash verify, unique names, cancel
- [ ] `VolumeWatcher`: detect card mount/unmount, ignore non-card volumes
- [ ] New Shoot flow: client autocomplete → shoot name → folder preview (`Client/YYYY-MM-DD Shoot/Camera/`)
- [ ] Status icon states: idle / unbacked / copying / backed / error
- [ ] `-AutoFixtureCard <path>` launch argument for manual testing

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
- Port Backed's `OrbView` / status visuals

## Key Decisions

| Date | Decision | Why |
| :--- | :--- | :--- |
| 2026-11-03 | Xcode project (not SwiftPM like Backed) | Asset catalogs, signing, previews, test hosting |
| 2026-11-03 | App Sandbox **off** | Needs free access to `/Volumes/*`, the work folder, and spawning Resolve scripting. Revisit only for Mac App Store. |
| 2026-11-03 | Swift Testing over XCTest | Modern API, parameterized tests |
| 2026-11-03 | macOS 26 minimum | Latest SwiftUI APIs; personal tool |
| 2026-11-03 | Multi-agent workflow with model routing (`.claude/agents/`) | Parallel slices; cheap models for search/docs, opus for design/review |
| 2026-11-03 | Micro-commits, no AI co-author, never auto-push | Developer preference |
