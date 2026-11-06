# Roadmap

Live plan for **Auto**: phases, status, backlog and key decisions. Only open work lives here. When an item lands, move it (as `- [x]`) to [docs/ROADMAP-done.md](docs/ROADMAP-done.md) under the same phase heading. Add new work to the right phase rather than to the bottom.

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

## Phase 2: Ingest parity with Backed

- [ ] Move remaining main-thread disk touches out of views (`workingVolume`, the stat calls in `shootFolders`)
- [ ] Detect a work folder that is itself on a camera card
- [ ] AppModel test harness (fake VolumeWatcher) to cover card lifecycle wiring
- [ ] Card browser: verify on screen, needs a running app: Quick Look open/switch/Space toggle with no "no controller" log; arrows working right after opening or switching to icons; column count with always-visible scrollbars; scroll-to under pinned headers; ⌘-click on duplicated rows in list mode; sidebar spinner/warning rows; Add to Shoot, context menus and CardRow buttons still working with the row tap
- [ ] Shoot flows are untested on the card-lifecycle paths: card removal clearing coverage, `addFootage` before coverage finishes, copy completion re-running coverage, recompute with a card inside a shoot, `mkdir` EEXIST race. Needs a card-source injection seam instead of `#if DEBUG _testInsert`
- [ ] Verify the Shoots grid and New Shoot / Add Footage sheets visually (launch the app, check the window); not yet done
- [ ] Per-root `DriveIndex` caching across recomputes
- [ ] Keep camera A/B suffixes consistent across cards (e.g. reuse the folder mapping already in the shoot)
- [ ] Move `shootPreview`/`createDirectories` file checks off the main actor (debounce preview); `shootPreview` is gone, so re-check the same checks in `ShootFolders` and `addFootage`
- [ ] Harden `CopyEngine` against symlink swaps between check and write (`O_NOFOLLOW`/`openat`)

## Phase 2b: Mirrors, sync and duplicates

A shoot can have mirror copies on other drives. Copies are checked and synced on demand, and ingest skips footage that is already backed up.

### Verify on screen (developer, remote; nothing here has been seen in a running app yet)

Launch the app and tick each item. These are the UI checks still open.

- [ ] New Shoot destinations list: add and remove rows, collision line per row, primary first
- [ ] Shoot tile badge: green, yellow and grey each render; hover shows the tooltip (copies, checked time, "Contents fully verified" line)
- [ ] Shoot popover: Check Again, ⌥ Check Again (deep), Verify Contents, Sync Now, Stop
- [ ] Shoot tile "Copies" context submenu: lists every copy, Locate…, remove copy
- [ ] Add Footage duplicates block; "Copy duplicates anyway" toggles what gets copied
- [ ] Add Footage copy and mirror notices
- [ ] CardRow: "already backed up" count, queue note ("Queued" button), mirror note
- [ ] Card browser duplicate confirmation ("Copy Anyway") before copying
- [ ] Dual-card scenario with two real cards into one shoot with a mirror: no double copies, second card queues behind the first

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
- Content index so duplicates are found after a rename (v1 matches name + size + MD5 only)
- Scheduled periodic deep verification of shoot copies (v1: Verify Contents is manual)
- Cross-root checksum end-to-end test (copy to two roots, then check both)
- Busy-guard and in-flight serialization tests for mirror operations (add, locate, remove)

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
| 2026-11-05 | Mirrors are explicit only (never auto-discovered); a copy on the same drive is refused as a mirror | A mirror is a deliberate second copy; discovery or a same-drive "mirror" would give false safety |
| 2026-11-05 | A card counts as backed up once a file is verified on at least one copy. A copy that missed a write is marked `pendingSync` and shows a yellow badge | Ingest must not wait on a slow or offline mirror; the gap stays visible until Sync Now closes it |
| 2026-11-05 | A checksum mismatch on any copy fails that file | A mismatch means a copy is bad; it must never be reported as verified |
| 2026-11-05 | Duplicates = same name + size + MD5, verified somewhere else. They are skipped by default, with a "Copy duplicates anyway" toggle. Renamed files are not detected | Name + size alone can collide; MD5 confirms the match. Content matching across renames needs an index (Backlog) |
| 2026-11-05 | A green badge from a cached check means "unchanged since last read". It is not proof against bit rot; Verify Contents does a full re-read | Cached checks trust size, mtime, inode and ctime, so silent corruption can pass them; the popover shows the last full verify date separately |
| 2026-11-05 | Overlapping copies queue rather than fail; ingest and Sync Now exclude each other | Two writers to one shoot would race on the same folders and copy state |
| 2026-11-05 | Sync Now never deletes or overwrites. Conflicts are left for the user to resolve | Only the user decides which of two differing files is right; Auto must never destroy either |
