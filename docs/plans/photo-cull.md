# Photo cull plan (Phase 3b)

Source of truth for the cull slices. Implementers: read only your slice and the contracts it touches.

## Developer decisions (2026-11-05)
- Cull a whole online shoot (`<copy>/Photo/**`, skipping `_Rejects`, hidden files and symlinks). Default model is sonnet.
- Decisions apply automatically. The "Review before applying" toggle is UI only and does nothing.
- Rejects are **moved** to `Photo/<cam>/_Rejects/<sub…>/X`. Never delete, never overwrite. RAW+JPEG pairs move together. Every move is journaled; Undo last cull is supported.
- **Copies:** apply to every *online* copy in `shoot.copies`. Mark offline copies `pendingSync` (existing mechanism). Sync replays the cull journal on a copy before planning missing files (slice S13), so rejects never come back. Undo replays the same way.
- **Stop = revert.** Nothing is moved until all groups are analyzed. Stop during analysis leaves zero changes. Stop during apply rolls back this run's moves (the undo path) → outcome `.stopped`.
- **Locking:** ingest, Sync Now and cull apply/undo/replay all mutate files. A cull **cannot apply** while any ingest or sync runs anywhere. Start Cull while one runs: the sheet shows "Ingest in progress. The cull will start when it finishes." and the cull waits in state `.waiting`. While ingest runs, culls also pause before launching their next group (runner `gate`). Multiple culls on *different* shoots may run at once; the same shoot twice is refused. Applies are serialized with each other and with ingest/sync.
- **Claude isolation, no API key, no `--bare`:** run with cwd = an app-managed workspace `~/Library/Application Support/Auto/CullWorkspace/` that holds its own `CLAUDE.md` (stable rules, below) and `.claude/settings.json` (allow Read only). Args (verify each flag against `claude --help` / one real run):
  `-p --output-format json --json-schema <schema> --model <m> --max-budget-usd <x> --max-turns 3 --no-session-persistence --setting-sources project --strict-mcp-config --allowedTools Read --disallowedTools Bash Edit Write WebFetch WebSearch Task --system-prompt <short role> --append-system-prompt <run section>`; user message on stdin. Per-run images go in `CullWorkspace/runs/<runID>/` and are deleted at the end. The app writes `CLAUDE.md` if missing, or if it still matches the hash of the version the app last wrote; it never clobbers user edits. Manual check (S7b): subscription auth works, `~/.claude/CLAUDE.md` is NOT loaded, the workspace CLAUDE.md IS loaded.

## Contracts (Core, all `nonisolated`, `Sendable`), in `Auto/Core/Cull/`
```swift
struct CullCriterion: Sendable, Hashable, Identifiable { let id, title, definition: String
  static let exposure, duplicates, unusable, horizon, cropped, eyes: CullCriterion; static let all: [CullCriterion] }
enum CullModel: String, Sendable, Codable, CaseIterable { case haiku, sonnet, opus }   // rawValue = CLI alias
struct CullSettings: Sendable, Codable, Equatable {
  var criteria: Set<String> = Set(CullCriterion.all.map(\.id)); var aggressiveness = 2 /*1...5 clamped*/
  var model: CullModel = .sonnet; var customRunPrompt: String? /*nil = generated run section*/
  var reviewBeforeApplying = false /*UI only*/; var maxConcurrentCalls = 2 /*1...4*/; var maxRunBudgetUSD = 5.0 }
struct FileStamp: Sendable, Codable, Equatable { let size: Int64; let mtime: Date }
struct FaceInfo: Sendable, Codable, Equatable { var box: CGRect /*normalized*/; var eyesClosed: Bool; var edgeCut: Bool; var quality: Double? }
struct PhotoMetrics: Sendable, Codable, Equatable { var captureTime: Date?; var meanLuma, lumaStdDev, clipHighPct, clipLowPct, sharpness: Double
  var faceSharpness: Double?; var dHash: UInt64; var horizonTiltDeg: Double?; var faces: [FaceInfo] }
struct PhotoRecord: Sendable, Identifiable, Equatable { let id: String /*shoot-relative path of representative*/; let camera: String
  let members: [String] /*shoot-relative*/; let representative: String /*JPEG preferred*/; let stamps: [String: FileStamp]
  var metrics: PhotoMetrics?; var preview: URL?; var faceStrip: URL? }
enum GroupKind: String, Sendable, Codable { case burst, mixed }
struct PhotoGroup: Sendable, Identifiable { let id: Int; let kind: GroupKind; let camera: String; let photos: [PhotoRecord] }
enum Verdict: String, Sendable, Codable { case keep, reject }
enum DecisionSource: String, Sendable, Codable { case model, localTriage, validatorOverride, defaultKeep }
struct CullDecision: Sendable, Codable, Equatable { let photoID: String; var verdict: Verdict; var reason: String; var criterion: String?
  var keeperID: String?; var confidence: Double; var source: DecisionSource }
struct CullPlan: Sendable { let runID: UUID; let settings: CullSettings; let decisions: [CullDecision]; let records: [String: PhotoRecord] }
enum CullPhase: Sendable, Equatable { case waiting(String), cataloging, preparing(done: Int, total: Int), analyzing(done: Int, total: Int),
  applying(done: Int, total: Int), reverting(done: Int, total: Int), undoing(done: Int, total: Int) }
struct CullProgress: Sendable, Equatable { let phase: CullPhase; let fraction: Double; let spentUSD: Double }
// weights: cataloging 0–0.02, preparing 0.02–0.30, analyzing 0.30–0.95, applying 0.95–1.0; fraction never decreases (except a revert, which reports its own phase)
struct CullRunSummary: Sendable, Codable, Equatable { let runID: UUID; let date: Date; let model: CullModel; let photos, rejected, groupsDone, groupsTotal: Int; let spentUSD: Double; var undone: Bool }
enum CullOutcome: Sendable { case completed(CullRunSummary), stopped(CullRunSummary?) /*nothing left moved*/, failed(CullError, CullRunSummary?) }
enum CullError: LocalizedError, Equatable { case shootOffline, noCopiesOnline, onCard, outsideShoot(String), noPhotos, busy(String)
  case claudeNotInstalled, claudeNotLoggedIn, claudeFailed(String), budgetExceeded(Double)
  case sourceChanged(String), crossVolume(String), journalWriteFailed(String), nothingToUndo }   // errorDescription user-readable
```
Journal `CullJournal.swift`: JSONL at `<copy>/.auto-cull/<ISO-date>_<runID>.jsonl`, appended, fsync per line. A truncated last line is ignored.
```swift
enum CullJournalEvent: Codable, Sendable {
  case run(runID: UUID, date: Date, model: CullModel, settings: CullSettings)
  case moved(runID: UUID, from: String, to: String, reason: String, criterion: String?, keeper: String?, photoID: String) // shoot-relative
  case restored(runID: UUID, from: String, to: String); case restoreSkipped(runID: UUID, path: String, why: String)
  case finished(runID: UUID, summary: CullRunSummary); case undone(runID: UUID, date: Date) }
enum CullJournal { static func directory(in copy: URL) -> URL; static func url(runID: UUID, in copy: URL) -> URL
  static func append(_ e: CullJournalEvent, runID: UUID, in copy: URL) throws
  static func runs(in copy: URL) throws -> [CullRunSummary] /*newest first*/
  static func moves(runID: UUID, in copy: URL) throws -> [(from: String, to: String)] /*net of restored*/ }
```
Engines:
```swift
enum PhotoCatalog { static func scan(shoot: URL, cardVolumes: [URL]) throws -> [PhotoRecord] }
enum PhotoGrouper { struct Options: Sendable { var maxGapSeconds = 2.0; var maxHamming = 12; var maxGroupSize = 12; var singlesBatch = 8 }
  static func group(_ p: [PhotoRecord], options: Options = .init()) -> [PhotoGroup]; static func hamming(_ a: UInt64, _ b: UInt64) -> Int }
enum PhotoRank { static func score(_ p: PhotoRecord) -> Double } // fewest eyesClosed > faceSharpness/sharpness > faceQ > least clipping
enum LocalTriage { static func decide(_ p: PhotoRecord, settings: CullSettings) -> CullDecision? } // nil = ask Claude
enum CullPromptBuilder {
  static let workspaceClaudeMD: String          // stable rules (below), written into CullWorkspace/CLAUDE.md
  static let roleSystemPrompt: String           // one short paragraph for --system-prompt
  static func runSection(settings: CullSettings) -> String   // customRunPrompt ?? criteria + strictness; for --append-system-prompt
  static func userMessage(group: PhotoGroup, index: Int, count: Int, tokens: [String: String] /*photoID→"p03"*/, frames: [String: (preview: String, faces: String?)]) -> String
  static func metricsLine(_ p: PhotoRecord, token: String, t0: Date?) -> String
  static let jsonSchema: String; static let promptVersion = 1 }
enum CullEstimator { static func estimate(photoCount: Int, model: CullModel, settings: CullSettings) -> (low: Double, high: Double, calls: Int) }
struct ModelDecisions: Decodable, Sendable { struct Item: Decodable, Sendable { let id, verdict, reason: String; let keeper: String?; let confidence: Double; let criterion: String? }; let decisions: [Item] }
enum CullDecisionValidator { static func minConfidence(_ aggressiveness: Int) -> Double // 1:0.90 2:0.85 3:0.75 4:0.65 5:0.55
  static func validate(group: PhotoGroup, tokens: [String: String] /*"p03"→photoID*/, modelOutput: ModelDecisions?, triage: [CullDecision], settings: CullSettings) -> [CullDecision] }
enum CullApplier {
  static func apply(_ plan: CullPlan, copies: [URL] /*online only*/, cardVolumes: [URL], onMoved: @Sendable (Int, Int) -> Void) throws -> Int
  static func undo(runID: UUID?, /*nil = latest not undone*/ copies: [URL], cardVolumes: [URL], onProgress: @Sendable (Int, Int) -> Void) throws -> CullRunSummary
  static func rejectsDestination(for relPath: String) -> String }  // Photo/<cam>/<sub…>/X → Photo/<cam>/_Rejects/<sub…>/X
enum CullReplay { static func replay(from source: URL, to target: URL, cardVolumes: [URL]) throws -> Int } // S13
struct CullRunner { let analyzer: any PhotoAnalyzer; let claude: any ClaudeRunner; let workspace: URL
  func run(shoot: Shoot, copies: [URL], cardVolumes: [URL], settings: CullSettings,
           gate: @escaping @Sendable () async -> Void,            // awaited before each new group and before apply (pauses during ingest/sync)
           applyLock: @escaping @Sendable () async -> AsyncLockToken, // or equivalent: exclusive mutation slot held for the apply phase
           onProgress: @escaping @MainActor @Sendable (CullProgress) -> Void) async -> CullOutcome }
```
Integrations:
```swift
// PhotoAnalyzer.swift
struct PreviewSpec: Sendable { var longEdge = 1024; var quality = 0.7; var faceStrips = true; var faceHeight = 160; var maxFaces = 8 }
protocol PhotoAnalyzer: Sendable { func analyze(_ url: URL, workName: String, workDir: URL, spec: PreviewSpec) async throws -> (PhotoMetrics, preview: URL, faceStrip: URL?) }
// ImageIOPhotoAnalyzer: CGImageSourceCreateThumbnailAtIndex (FromImageAlways, max px), EXIF DateTimeOriginal+SubSec, metrics on a 512px gray image
// (luma hist, Laplacian variance via Accelerate, dHash), Vision face rects + landmarks (eye openness), face capture quality, horizon.
// ClaudeRunner.swift
struct ClaudeRequest: Sendable { var model: String; var systemPrompt: String; var appendSystemPrompt: String; var userPrompt: String
  var jsonSchema: String; var workspace: URL /*cwd*/; var maxBudgetUSD: Double; var maxTurns = 3; var timeout: Duration = .seconds(180) }
struct ClaudeResponse: Sendable { let structured: Data; let costUSD: Double?; let inputTokens, outputTokens, cacheReadTokens: Int? }
enum ClaudeRunnerError: LocalizedError, Equatable { case notInstalled, notLoggedIn, budgetExceeded, timedOut, exit(Int32, String), malformed(String) }
protocol ClaudeRunner: Sendable { func run(_ r: ClaudeRequest) async throws -> ClaudeResponse } // throws CancellationError when cancelled
enum ClaudeCLI { static func arguments(for r: ClaudeRequest) -> [String]
  static func locate(env: [String: String], home: URL, fileExists: (String) -> Bool, loginShellLookup: () -> String?) -> URL?
  // order: /opt/homebrew/bin, ~/.local/bin, ~/.claude/local, /usr/local/bin, then `zsh -lc 'command -v claude'` (5s timeout, cached)
  static func parse(stdout: Data) throws -> ClaudeResponse } // structured_output, else `result` parsed as JSON; is_error + auth text → notLoggedIn
final class ClaudeCLIRunner: ClaudeRunner { init(executable: URL? = nil) } // Process+Pipes drained concurrently; cancel → terminate, SIGKILL after 2s; timeout race
```

## Data safety (applier, undo, replay)
- Per copy: every source and destination passes `ShootPlanner.checkDestination(parent, root: copy, cardVolumes:)` and resolves under `copy/Photo`. Refuse any path with a `_Rejects` component (as a source), a hidden component, a symlink or a non-regular file (`lstat`).
- Renames only. Same volume via `volumeIdentifierKey`, else `crossVolume`; never copy+delete. Use `renamex_np(RENAME_EXCL)`; on ENOTSUP, pre-check and then `FileManager.moveItem`; on EEXIST, take the next name.
- Pair-aware unique names: the smallest n where every member's `<base> n.<ext>` is free (reuse CopyEngine's suffix style). Use the same n across copies when possible.
- Stale check: each member's size+mtime must equal `stamps` (primary copy). On mirrors, check size, and also MD5 via ChecksumStore if both hashes are known. On a mismatch, skip the whole pair. If member k fails, roll back members 0..k-1.
- Verify after move: destination exists, same inode, same size, source gone. Journal `run` first, then append+fsync `moved` after each verified pair.
- Undo/revert: newest first. If `from` is free, rename back EXCL. If it's reoccupied, use a unique sibling and log `restored(to:)`. If the file is missing, log `restoreSkipped`. Then `rmdir` empty `_Rejects` dirs only.
- Replay (S13): for each run in the source journal that is missing or incomplete in the target: a file at `from` with matching size → move to the mapped `to` (EXCL, same checks); already at `to` → skip; else log a skip. Also apply `undone`. Then copy the journal into target `.auto-cull/` (exclusive temp + rename). Runs before `ShootSyncPlanner` inside Sync Now.
- Previews live only in `CullWorkspace/runs/<runID>/`, removed in `defer`. Sources are opened read-only.
- Model output can only reference known tokens. The applier accepts only photoIDs in `plan.records`.

## Prompt text (verbatim)
`workspaceClaudeMD`:
```
# Photo cull workspace

You are a photo-culling assistant for a professional photographer. You see one group of frames at a time and decide keep or reject for every frame. Rejected frames are moved to a _Rejects folder, not deleted, but a wrong reject costs the photographer a picture: be conservative.

## How to work
1. Read every image listed under FRAMES in a single turn (issue all Read calls together). A file ending in _faces.jpg is an enlarged strip of every detected face in that frame, numbered 0, 1, 2… left to right.
2. Judge from the images. METRICS come from a local analyzer and are hints that can be wrong; the image is ground truth.
3. Reply with JSON only, matching the schema, with exactly one entry per frame id. No prose.

## Hard rules
- When uncertain, keep.
- In a burst, first sort the frames into distinct poses or moments. Never reject every frame of a pose; keep at least one per pose.
- To choose the keeper within a pose prefer, in order: all eyes open, then sharp focus on the subject's eyes, then better expression, then better exposure.
- When you reject a frame because a similar frame is better, put that frame's id in "keeper".
- A crooked horizon is a reject only if straightening it would crop into the subject.
- Heads or limbs cut at an awkward joint (top of head through the eyes, wrist, elbow, knee, ankle) are a reject only when another frame of the same pose is better.
- Exposure recoverable from RAW (mildly over or under) is not a reject.
- Deliberate creative choices (panning motion blur, silhouettes, low key, intentional shallow focus) are keeps.
- Judge only the criteria listed in the system prompt; ignore any other flaw.
- reason: 12 words or fewer, concrete, e.g. "eyes closed; p02 sharper" or "lens cap, black frame".
- criterion: the id of the criterion behind a reject. confidence: 0 to 1, how sure you are the verdict is right.
```
`runSection` = `Criteria in use\n{{criteria}}\n\nStrictness: level {{aggressiveness}} of 5\n{{aggressiveness_rules}}`
Criteria (`- <id>: <definition>`):
- exposure: Blown highlights or crushed shadows on the subject beyond recovery from RAW.
- duplicates: Near-identical frames of the same pose; keep the best per the strictness level.
- unusable: Motion blur or missed focus on the subject; accidental shots (ground, sky, lens cap, finger over lens).
- horizon: Crooked horizon that cannot be straightened without cropping the subject.
- cropped: Heads or limbs cut off at awkward joints by the frame edge.
- eyes: Closed eyes, mid-blink or clearly bad expressions on the main subjects.

Strictness levels:
1. Reject only obvious technical failures: black or white frames, lens cap, accidental shots, completely out of focus. Keep every duplicate.
2. Reject clear technical failures and frames that are badly blurred or have the main subject's eyes fully closed. Keep duplicates unless they are virtually identical.
3. Reject frames that clearly fail an enabled criterion. In bursts, reject near-identical frames that are clearly worse than the keeper of the same pose.
4. Be selective. In bursts keep the best one or two frames per pose. Reject a frame with any enabled flaw when a better frame of the same moment exists.
5. Keep only the single best frame per pose. Reject every other frame of a burst, and any single frame with a visible flaw on an enabled criterion.

User message:
```
Group {{index}} of {{count}}. {{group_kind}}
Camera: {{camera}}

METRICS (t = seconds after the first frame; sharp/fsharp = edge detail overall/on faces, higher is sharper, compare only within this group; clipHi/clipLo = % of pixels blown/crushed; tilt = horizon angle in degrees; eyesClosed and edgeCut list face numbers; faceQ = face quality 0-1)
{{metrics}}

FRAMES
{{frames}}
```
- burst: `Burst: {{n}} frames of one scene within {{span}}s. Compare them against each other.` mixed: `Mixed singles: {{n}} unrelated frames. Judge each on its own; do not use "keeper".`
- metrics line: `p03 t+0.4s sharp=812 fsharp=430 mean=0.42 clipHi=0.2% clipLo=1.1% tilt=2.3 faces=6 eyesClosed=[2] edgeCut=[0] faceQ=0.71` (nil fields omitted; sharp is an integer, pct to 1 dp)
- frames line: `p03: g07_p03.jpg (faces: g07_p03_faces.jpg)` (paths relative to the run dir)

Schema:
```json
{"type":"object","additionalProperties":false,"required":["decisions"],"properties":{"decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","verdict","reason","confidence"],"properties":{"id":{"type":"string","pattern":"^p[0-9]{2}$"},"verdict":{"enum":["keep","reject"]},"reason":{"type":"string","maxLength":90},"criterion":{"type":"string"},"keeper":{"type":"string","pattern":"^p[0-9]{2}$"},"confidence":{"type":"number","minimum":0,"maximum":1}}}}}}
```
Efficiency: preview 1024 for bursts and 768 for mixed; write a face strip only when faces ≥ 1 and `eyes` or `cropped` is enabled; triage-rejected frames are left out of the call, and an empty group skips Claude; per-call budget = clamp(3 × group estimate, 0.05, 1.00); stop launching groups once spent ≥ run budget (in-flight calls finish, nothing is applied → `.failed(.budgetExceeded)`).

LocalTriage (enabled criteria only): unusable black (meanLuma < 0.02 && stdDev < 0.01) at every level; exposure clipHi/clipLo > 0.92 (L1) down to 0.80 (L5); unusable blur when sharpness < 5 (L1–2) / < 15 (L4–5) and there are no faces. Result: `.localTriage`, confidence 1.

Validator order: (1) drop unknown or duplicate tokens, first wins; (2) missing → keep/.defaultKeep; (3) reject with confidence < minConfidence → keep/.validatorOverride "low confidence: …"; (4) a keeper that is unknown, self or rejected → nil; (5) burst all-reject → keep the top PhotoRank ("kept: best of all-reject burst"); (6) at level ≤ 2 apply rule 5 to mixed groups too, unless every reject is from triage.

## Tests (AutoTests/Cull/), Swift Testing, temp dirs, fakes only
See the architect's list per engine: catalog pairing/skips/card refusal; grouper gaps/hash/camera/max size/nil time; triage per criterion and level; prompt builder (only enabled criteria, no `{{` left, custom run prompt verbatim, metrics format, no absolute paths, schema parses); estimator monotonic; validator rules 1–6; journal fold and truncated line; applier (moves, pairs, collision suffix shared, never touches an existing destination, stale skip, refusals, same inode, journal entries, multiple copies, cancel between pairs); undo (restore, reoccupied, missing, marked undone, nothingToUndo, rmdir empty only); replay (moves on the target, idempotent, size mismatch skipped, undone replayed); analyzer (black/white/sharp vs blur/dHash/EXIF round-trip/preview size/no faces); ClaudeCLI pure (args snapshot, locate order, parse); ClaudeCLIRunner with `#!/bin/sh` fake scripts (JSON, nonzero exit, cancel kills the pid in < 3s, timeout, stdin, missing exe); runner (happy path, stop during analysis = zero moves, stop during apply = reverted, progress monotonic, max concurrency, budget, notLoggedIn aborts, a single group failure → default keep, gate pauses launches, workspace run dir removed).

## Slices
- Wave 1 (parallel): **S1** Core models (CullModels.swift, CullCriterion.swift + tests), haiku. **S7a** ClaudeRunner.swift (protocol, types, `ClaudeCLI` helpers) + ClaudeCLITests + FakeClaudeRunner, sonnet.
- Wave 2 (parallel, after S1): **S2** PhotoCatalog + AutoTests/Support/FixtureShoot.swift. **S3** PhotoGrouper + PhotoRank + LocalTriage. **S4** CullPromptBuilder + CullEstimator (haiku). **S5** CullDecisionValidator. **S6** CullJournal + CullApplier.apply (opus review). **S7b** ClaudeCLIRunner + workspace setup + manual CLI check (opus review). **S8** PhotoAnalyzer + ImageIOPhotoAnalyzer + FakePhotoAnalyzer + ImageFixtures.
- Wave 3: **S6b** undo/revert (after S6, opus review). **S13** CullReplay + hook into Sync Now (after S6b, opus review). **S9** CullRunner (opus review).
- Wave 4: **S10** AppModel glue: settings in injected defaults `settings.cull.v1`, per-shoot `cullStates`, waiting/gate/apply lock shared with ingest + Sync Now, start/stop/undo, mark offline copies pendingSync, injection of ClaudeRunner/PhotoAnalyzer.
- Wave 5 (parallel): **S11a** CullSettingsSheet (criteria toggles, slider with level label, model picker, editable run prompt with "Edited · Reset", "Open workspace in Finder", review toggle with no effect, estimate line, busy notice). **S11b** PhotoEditView (shoot picker, photo count, last run, Start Cull, Undo last cull, bottom progress bar with phase + ProgressView + $ spent + Stop) + MainView.swift:68-69 routing.
- Wave 6: combined review → docs (ROADMAP Phase 3b, ARCHITECTURE module map + flow).
