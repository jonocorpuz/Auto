# Shoot files: Add Files + shoot browser (branch feat/shoot-files)

Source of truth for the slices. Implementers: read your slice and the contracts it touches.

## Goal and done-criteria
1. "Add Files…" on a shoot: a sheet (drop zone, Choose…, staged list grouped by camera and kind, duplicates marked and skipped, "Add N files") that copies verified files into `<shoot>/{Video,Photo}/<camera>/` on every online copy.
2. Clicking a shoot tile opens a read-only Finder-style browser of the primary copy (breadcrumb, icon/list, Quick Look, Show in Finder, Add Files…) that accepts Finder drops.
3. Imports are ingests: same serial scheduling, fan-out, pendingSync, cull lock, progress.
4. Build + tests pass. ROADMAP: add a "Shoot files" item (under Phase 2 ingest / next to 3b) and tick when done.

## Decisions
- **No pseudo-`Card`.** `Card` is welded to a volume (`VolumeIdentity`, `BackupVerifier`, eject, `cards` list in sidebar/MediaView, `volumes(including:)`, phase machine, `recompute`). A fake card would need guards at dozens of sites in a 3000-line AppModel. Reuse at the seams instead: `MediaFile` (cardID `"import"`), `CopyJob`, `ShootPlanner.jobs/plan/checkDestination/createDirectories`, `CopyEngine`, `AppModel.integrityBlocked`, `ShootCoverageChecker.run` (takes any `[MediaFile]`, checksum-verifies against the shoot; this IS the "duplicate already in shoot" detector), `CardScanner.detectCamera` (already per-file, `@concurrent`, no refactor needed). `IngestDuplicates` is NOT used (it needs card `backups`, and "elsewhere" duplicates are out of scope).
- New `ImportJob` (@Observable, App/) is a sibling of `Card` in scheduling: `AppModel.imports: [ImportJob]`. Scheduling hooks are four one-liners in AppModel.swift (below), all other logic in new files.
- Audio goes where ingest puts it: `ShootPlanner.jobs` sends every non-photo to `Video/<camera>`. No camera: fallback folder `"Other"`.
- Camera folders: detected cameras -> `Camera.disambiguated` within the batch -> `ImportPlanner.mapCameras` reuses an existing folder in the shoot (case-insensitive match on `folderName`, per section). A lone "FX3" with only "FX3 A"/"FX3 B" existing is ambiguous (serials are not persisted): it uses plain "FX3". Group header shows the destination folder name.
- Drop confirmation: drops on top level / `Video` / `Photo` open the Add Files sheet pre-staged (the sheet is the review). Drops on a camera folder or deeper show a `confirmationDialog` ("Add 12 files to Video/FX3/Day 2? 3 duplicates skipped") because there is no delete/move in the browser to undo a wrong drop. Never goes straight in.
- Duplicates: whole-shoot (any subfolder, includes `_Rejects`, so rejected photos never come back) checksum match on the primary copy only; mirrors that lack the file are handled by existing sync. Same resolved path dropped twice in one batch is collapsed.
- Exact-folder drops copy flat into that folder (recursion keeps nothing of the source structure), same for every copy (primary-relative subpath mapped onto each copy root; missing dirs created by `createDirectories`).

## Public contract (Core, `nonisolated`, `Sendable`)
```swift
// Auto/Core/ImportPlanner.swift
enum ImportRefusal: LocalizedError, Equatable, Sendable {
  case insideShoot(String)          // source resolves inside any copy of the destination shoot
  case inReservedFolder(String)     // a path component is _Rejects or .auto-cull
  case destinationNotInShoot        // exact-folder target outside the shoot or in _Rejects/.auto-cull
  case destinationOnCard, shootOffline, nothingToAdd, allDuplicates, unreadable(String)
}
enum ImportPlanner {
  static let fallbackFolder = "Other"
  static let reserved: Set<String>                         // ["_rejects", ".auto-cull"] (lowercased)
  static func refusal(for source: URL, shootRoots: [URL]) -> ImportRefusal?   // uses ShootPlanner.resolvedPath + isInside
  static func existingFolders(in shoot: URL) -> [String: [String]]            // "Video"/"Photo" -> names (I/O)
  static func mapCameras(detected: [Camera], existing: [String: [String]]) -> [Camera]  // pure
  static func sortedJobs(files: [MediaFile], copies: [URL], cameras: [Camera]) -> [CopyJob] // = ShootPlanner.jobs(... fallback: "Other")
  static func exactJobs(files: [MediaFile], copies: [URL], primary: URL, folder: URL) throws -> [CopyJob] // folder inside primary, not reserved
}
// Auto/Core/ImportScanner.swift
struct StagedFile: Identifiable, Hashable, Sendable { let file: MediaFile; let origin: URL; let cameraFolder: String; var id: URL { file.url } }
struct ImportScan: Sendable { var files: [StagedFile]; var cameras: [Camera]; var refused: [(URL, ImportRefusal)]; var ignoredCount: Int }
enum ImportScanner {
  /// Expands files/folders (skips hidden, packages, MediaTypes.skippedFolders, non-media, symlinks to outside), refuses per ImportPlanner.refusal,
  /// detects the camera per FILE (not per directory: Downloads mixes cameras; bounded concurrency 4), dedupes by resolved path.
  @concurrent static func scan(_ roots: [URL], shootRoots: [URL], onProgress: @escaping @Sendable (Int) -> Void) async -> ImportScan
}
// Auto/Core/ImportDuplicates.swift
enum ImportDuplicateFinder {
  /// Files with a checksum-identical copy anywhere in `shootFolder` (wraps ShootCoverageChecker.run). Throws ImportRefusal.unreadable on a failed check.
  @concurrent static func find(_ files: [MediaFile], shootFolder: URL, cache: VerificationCache, cardVolumes: [URL],
                               progress: @escaping @Sendable (CopyProgress) -> Void) async throws -> Set<URL>
}
// Auto/Core/ShootBrowser.swift
struct ShootEntry: Identifiable, Hashable, Sendable { let url: URL; let isFolder: Bool; let size: Int64; let date: Date; let kind: MediaKind?; var id: URL { url } }
enum ShootBrowser {
  static func list(_ folder: URL) -> [ShootEntry]            // folders first, localizedStandard sort; hides dotfiles, .auto-cull, symlinks out of tree
  static func breadcrumb(from root: URL, to folder: URL) -> [(name: String, url: URL)]?   // nil if folder not inside root
  static func clamp(_ folder: URL, root: URL) -> URL         // never navigates above the shoot
  static func dropTarget(for folder: URL, root: URL) -> DropTarget   // .sorted (root, Video, Photo) or .exact(folder)
}
enum DropTarget: Equatable, Sendable { case sorted, exact(URL) }
```
```swift
// Auto/App/ImportJob.swift (MainActor, @Observable)
enum ImportPhase: Equatable { case queued(String), preparing, copying, done(ImportSummary), failed(String), stopped }
struct ImportSummary: Equatable { let copied: Int; let bytes: Int64; let skippedDuplicates: Int; let note: String? }
@Observable final class ImportJob: Identifiable {
  let id = UUID(); let shootID: UUID; let shootName: String; var files: [MediaFile]; var plan: CopyPlan
  var phase: ImportPhase; var progress = CopyProgress(); @ObservationIgnored var engine: CopyEngine?; let skippedDuplicates: Int }
// Auto/App/ImportStaging.swift (MainActor, @Observable): what the sheet binds to
@Observable final class ImportStaging: Identifiable {
  let shootID: UUID; let target: DropTarget
  var sources: [URL]; var phase: Phase   // .scanning(count) | .checking | .ready | .failed(String)
  var items: [StagedFile]; var duplicates: Set<URL>; var removed: Set<URL>; var includeDuplicates: Set<URL>
  var groups: [Group] { }   // kind (Video/Photo/Audio) x camera folder; counts, bytes; removable
  var selected: [StagedFile] { }   // items - removed - (duplicates - includeDuplicates)
}
// AppModel (new file Auto/App/AppModel+Import.swift)
var imports: [ImportJob]
func beginImport(shootID: UUID, urls: [URL], target: DropTarget = .sorted) -> ImportStaging   // starts scan+dup check Task
func addSources(_ urls: [URL], to staging: ImportStaging)
func chooseImportSources(for staging: ImportStaging)          // NSOpenPanel, files+folders, multi-select
func commitImport(_ staging: ImportStaging) throws -> ImportJob // throws ImportRefusal
func stopImport(_ job: ImportJob); func dismissImport(_ job: ImportJob)
func hasActiveImport(into shootID: UUID) -> Bool
```
Errors are surfaced as `ImportRefusal` / `ShootError` / `ShootPlanner.PathError`.

## Isolation
- All Core types `nonisolated`; scanning, camera detection, duplicate check, directory listing are `@concurrent static` (or called inside `Task.detached`), never on main. `ShootBrowser.list` is cheap I/O: call from a detached task per navigation, results cached in the view model.
- `ImportJob`, `ImportStaging`, `AppModel.imports`, scheduling: MainActor (default). The engine run is `await engine.run(jobs) { progress in job.progress = progress }` exactly as `copy(_ card:)` does.
- Staging Task: cancel on sheet dismiss (`ImportStaging.task`), re-check `staging` still current after every await.

## Scheduling (reuse, do not parallel-build)
`commitImport` builds `[CopyJob]` from `shoot.copies` (online only, `ShootPlanner.jobs(missing:copies:cameras:fallback:)` or `exactJobs`), then `ShootPlanner.plan(jobs:shoot:workRoot:roots:shootID:)`, creates `ImportJob`, calls `startImportIfPossible(job)` which mirrors `copy(_ card:)`:
1. Blocked (state `.queued(note)`) while: any card engine overlaps `plan.copyRoots` (`cards.first{engine != nil && overlap}`), another import running with overlapping roots, `syncBusyOverlapping(roots)`, or `cullApplying`.
2. Off-main preflight per root: `ShootPlanner.checkDestination` for every dir, free space, `preflight(workRoot:shootID:)` (sidecar id matches); `createDirectories`. A failing mirror is left out and marked pendingSync; a failing primary fails the job.
3. `noteIngestStarting(roots:)`; `ingestRunCount += 1` around `engine.run` (the cull lock waits on this); `-= 1` then `releaseQueuedCopies()`.
4. After run: `integrityBlocked`, `landedFiles` -> `sessionCopies`, `verifications.record`, `checksums.record` (so cards' duplicate verdicts see the landed files; recompute idle cards that `needsRecompute(afterCopyOf:)`), pendingSync marking for unreached copies (shared helper, see S5a), `checkCoverage` for the shoot, `saveRegistry`, `refreshShoots`, `scheduleSyncCheck([shootID], force: true)`.
Hooks in AppModel.swift (S5a): (a) `copy(_ card:)`: `if importBusyOverlapping(myRoots) { enqueueBehindImport(card); return }` next to the sync/cull checks; (b) `releaseQueuedCopies()` also calls `startQueuedImports()`; (c) `hasActiveIngest(into:)` also checks `hasActiveImport`; (d) `ShootCoverage` / shoot removal paths already use `copyOpBlock`, which covers (c). Cull `cullGate`/`acquireApplyLock` need no change because `ingestRunCount` is shared; an import queued behind an applying cull is released by `releaseApplyLock -> releaseQueuedCopies`.
Progress: `ImportProgressRow` in MediaView (above the Shoots grid, like cards) and a status strip in the browser; the sheet closes on commit.

## Data safety
- Sources read-only: only `CopyEngine` opens them for read (hash-while-copy). No API in this feature deletes, moves or renames anything; the browser has no destructive actions.
- Refusals before any write: source inside any copy of the shoot (resolved through symlinks, both ends), source with `_Rejects`/`.auto-cull` component, exact-folder destination outside the shoot or inside reserved folders, destination on a card (`isOnCard` + `checkDestination`), shoot offline, sidecar mismatch.
- Copy: existing `CopyEngine` (temp + RENAME_EXCL, size + MD5 verified, never overwrite, `.renameUnique`). A file is "added" only after verification. A file changed between stage and copy is caught by engine size/checksum verification; stage records size+mtime and commit drops files whose size changed (re-stat, off main).
- Source on a card stays untouched; sources are never `unlink`ed even after success.
- Dups never decided by name alone: name+size nominate, checksum confirms (ShootCoverageChecker). Unreadable check -> user can still add with duplicates un-skipped, with a warning.
- Offline mirrors: `pendingSync`, never silently dropped.

## Files
- Core (new): `Auto/Core/ImportPlanner.swift`, `ImportScanner.swift`, `ImportDuplicates.swift`, `ShootBrowser.swift`.
- App (new): `Auto/App/ImportJob.swift`, `ImportStaging.swift`, `AppModel+Import.swift`. Modify `AppModel.swift` (S5a only): relax `private/fileprivate` to internal for `cullApplying`, `cullWaiters`, `releaseQueuedCopies`, `noteIngestStarting`, `syncBusyOverlapping`, `overlap`, `isOnCard`, `volumes`, `preflight`, `integrityBlocked` use, `unique`, `copyLabel`, `markUnreachedCopies` (extract card-independent `unreachedCopyMarks(...)`); add the four hooks; add `browsingShootID`.
- UI (new): `AddFilesSheet.swift`, `ShootBrowserView.swift`, `ImportProgressRow.swift`. Modify `MediaView.swift` (branch on `browsingShootID`, progress rows, sheet), `ShootTile.swift` (tap -> `model.openShoot`, context "Add Files…"), `CardBrowserView.swift` (make `FileIcon`, `symbol`, `kindLabel` internal; no behavior change), `MainView.swift` (sheet host if sheets live there; grep `shootSheet`).
- Integrations: none new (reuse `QuickLookPreviewer`, `ThumbnailProvider`).
- Tests: `AutoTests/ImportPlannerTests.swift`, `ImportScannerTests.swift`, `ImportDuplicateTests.swift`, `ShootBrowserTests.swift`, `ImportJobFlowTests.swift`; extend `Support/FixtureShoot.swift` (shoot with sidecar, `Video/FX3`, `Photo/A7`, a `_Rejects` file) and use `FixtureCard` for a "drive" source of mixed cameras.

## Tests (Swift Testing, temp dirs, fakes)
- Planner: refusal for source inside shoot (incl. via symlink and in a mirror), `_Rejects`, `.auto-cull`; `mapCameras` reuses "FX3" case-insensitively, two same-model -> A/B, ambiguous lone model; audio -> Video; no camera -> Other; `exactJobs` maps subpath onto each copy, rejects folder outside shoot or reserved.
- Scanner: nested folders, hidden/package/skipped folders, mixed cameras in one directory (Sony XML sidecars, EXIF fixtures), duplicate paths collapsed, symlink out-of-tree handling, non-media counted as ignored.
- Duplicates: same name+size different bytes is NOT a duplicate; identical bytes in another subfolder and in `_Rejects` are; unreadable shoot throws.
- Browser: list ordering/hiding, breadcrumb, clamp (`../` escape), dropTarget cases.
- Flow (AppModel, with `_testEngineHook`-style engine): import fans out to two copies; offline mirror gets pendingSync; unique rename on name clash with different bytes; source untouched (hash before/after); queued behind a running card copy to the same shoot and behind `cullApplying`; `ingestRunCount` returns to 0; refused when destination is a card volume.

## Slices (each one Sonnet implementer run; micro-commit per type)
S1, S2, S3, S4 are disjoint new Core files and run in PARALLEL. S5a/S5b serial after S1-S3. S6 and S7 parallel after S5b. S8 serial after S6+S7. S9 last.
| # | Slice | Depends | Model |
|---|---|---|---|
| S1 | `ImportPlanner` + tests (refusal, mapCameras, jobs) | none | sonnet (data-safety) |
| S2 | `ImportScanner` + `StagedFile` + tests + fixture extensions | S1 `refusal` signature (stub ok) | sonnet |
| S3 | `ImportDuplicateFinder` + tests | none | sonnet |
| S4 | `ShootBrowser` + `ShootEntry` + `DropTarget` + tests | none | haiku-able (pure listing/paths) |
| S5a | AppModel access relax, shared pendingSync helper, 4 hooks, `browsingShootID`; existing tests still green | S1 | sonnet (mechanical but risky; reviewer after) |
| S5b | `ImportJob`, `ImportStaging`, `AppModel+Import.swift` pipeline + flow tests | S1-S3, S5a | sonnet, escalate to opus if it fails twice |
| S6 | `AddFilesSheet` (drop zone `dropDestination(for: URL.self)`, Choose…, grouped list, "Add N files"), `ImportProgressRow`, MediaView/ShootTile entry points | S5b | sonnet |
| S7 | `ShootBrowserView` (breadcrumb, icon/list reusing GridSelection, FileIcon, QuickLookPreviewer, Show in Finder, Add Files…), MediaView/ShootTile open-on-click | S4, S5a (S5b for Add Files button) | sonnet |
| S8 | Browser drop handling: `dropDestination` on view and on folder cells, `.sorted` opens sheet pre-staged, `.exact` shows confirmationDialog then `commitImport` | S6, S7 | sonnet |
| S9 | ARCHITECTURE.md (flow + modules), ROADMAP tick, this plan status | all | haiku |
Reviewer (opus) after S5b (Core + AppModel scheduling, data safety) and again after S8. Launch the app to check the sheet and browser (UI slices).
