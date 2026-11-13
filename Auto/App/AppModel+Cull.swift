import AppKit
import Foundation

/// Photo cull: starting, stopping and undoing culls, and the app-wide apply lock that keeps cull moves,
/// ingests and mirror syncs from touching a shoot at the same time.
extension AppModel {
    // MARK: Locking

    private var ingestRunning: Bool { ingestRunCount > 0 }

    /// Takes the app-wide mutex. With `excludingIngest` (a cull apply/undo) it also waits for every running ingest
    /// and makes new ingests queue until `releaseApplyLock`. Returns false if the task was cancelled while waiting.
    func acquireApplyLock(excludingIngest: Bool) async -> Bool {
        do {
            while applyLockHeld || (excludingIngest && ingestRunning) { try await cullWaiters.wait() }
        } catch { return false }
        applyLockHeld = true
        cullApplying = excludingIngest
        return true
    }

    func releaseApplyLock() {
        let wasCull = cullApplying
        applyLockHeld = false
        cullApplying = false
        cullWaiters.wake()
        if wasCull { releaseQueuedCopies() }   // ingests that queued behind the apply
    }

    /// Cards that asked to copy while a cull was applying wait here.
    func enqueueBehindCull(_ card: Card) {
        if !copyQueue.contains(card.id) { copyQueue.append(card.id) }
        card.queuedBehind = card.id
        card.queueNote = "Waiting for a photo cull to finish"
    }

    /// Pauses a cull between groups while any ingest or sync runs.
    fileprivate func cullGate() async {
        while ingestRunning || !syncActive.isEmpty {
            if Task.isCancelled { return }
            do { try await cullWaiters.wait() } catch { return }
        }
    }

    /// `body` is `@concurrent`: it runs off the main actor even though this method is main-actor isolated.
    fileprivate func cullWithApplyLock(shootID: UUID, _ body: @concurrent @Sendable () async throws -> Void) async throws {
        guard await acquireApplyLock(excludingIngest: true) else { throw CancellationError() }
        defer { releaseApplyLock() }
        cullApplyEntered.insert(shootID)
        try await body()
    }

    // MARK: Queries

    /// Why a cull can't start for `shootID` (nil: it can). Ingest and sync don't block: the cull waits for them.
    func cullBlockReason(shootID: UUID) -> String? {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return "Shoot not found" }
        switch cullStates[shootID] {
        case .waiting?, .running?: return "Already culling this shoot"
        default: break
        }
        if cullTasks[shootID] != nil { return "Already culling this shoot" }
        guard item.copies.contains(where: { $0.availability == .online }) else { return "Shoot is offline" }
        guard item.copies.first(where: \.isPrimary)?.availability == .online else { return "Connect the main copy of this shoot to cull" }
        return nil
    }

    /// Shown before starting: a cull started now waits for the running ingest or sync.
    func cullBusyNotice() -> String? {
        if ingestRunning { return "Ingest in progress. The cull will start when it finishes." }
        if !syncActive.isEmpty { return "Sync in progress. The cull will start when it finishes." }
        return nil
    }

    func cullRunPromptPreview(mode: CullMode) -> String {
        var settings = cullSettings
        settings.mode = mode
        settings.setCustomPrompt(nil, for: mode)
        return CullPromptBuilder.runSection(settings: settings)
    }

    func revealCullWorkspace() { NSWorkspace.shared.activateFileViewerSelecting([cullWorkspaceRoot]) }

    func lastCullRun(shootID: UUID) -> CullRunSummary? { cullLastRuns[shootID] }

    /// Reads the primary's journal (off main) and caches the run the UI should offer to undo, else the newest.
    func loadLastCullRun(shootID: UUID) async {
        guard let primary = onlineCullCopies(shootID).first else {
            cullLastRuns[shootID] = nil
            return
        }
        let runs = await Self.readCullRuns(primary)
        let latestNotUndone = runs.first(where: { !$0.undone })
        cullLastRuns[shootID] = latestNotUndone ?? runs.first
    }

    /// Photo count and cost estimate for the sheet, catalogued off main. Nil when the shoot is offline or unreadable.
    func cullPreflight(shootID: UUID) async -> (photos: Int, estimate: (low: Double, high: Double, calls: Int))? {
        guard let primary = onlineCullCopies(shootID).first else { return nil }
        let volumes = cardVolumes()
        guard let count = await Self.countPhotos(primary, cardVolumes: volumes) else { return nil }
        return (count, CullEstimator.estimate(photoCount: count, model: cullSettings.model, settings: cullSettings.clamped()))
    }

    /// The registry's primary folder, when it is among `copies` (standardized path match).
    func primaryCopyURL(_ shootID: UUID, among copies: [URL]) -> URL? {
        guard let item = shoots.first(where: { $0.id == shootID }),
              let primary = item.copies.first(where: \.isPrimary) else { return nil }
        let url = URL(fileURLWithPath: primary.path, isDirectory: true).standardizedFileURL
        return copies.first { $0.standardizedFileURL == url }
    }

    /// Online copies of the shoot, primary first.
    private func onlineCullCopies(_ shootID: UUID) -> [URL] {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return [] }
        let online = item.copies.filter { $0.availability == .online }
        let ordered = online.filter(\.isPrimary) + online.filter { !$0.isPrimary }
        return ordered.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    // MARK: Run

    /// Starts a cull of the whole shoot on every online copy. False when refused (see `cullBlockReason`).
    @discardableResult
    func startCull(shootID: UUID) -> Bool {
        guard cullBlockReason(shootID: shootID) == nil,
              let item = shoots.first(where: { $0.id == shootID }) else { return false }
        let copies = onlineCullCopies(shootID)
        guard let primary = copies.first else { return false }
        let shoot = Shoot(id: shootID, name: item.record.name, date: item.date, folder: primary,
                          mirrors: Array(copies.dropFirst()))
        let runner = CullRunner(analyzer: photoAnalyzer, claude: claude, applier: cullApplier, workspaceRoot: cullWorkspaceRoot)
        let settings = cullSettings.clamped()
        let volumes = cardVolumes()
        cullNotes[shootID] = nil
        cullLiveRejects[shootID] = []
        cullLiveRejectsApplied[shootID] = false
        if let notice = cullBusyNotice() {
            cullStates[shootID] = .waiting(notice)
        } else {
            cullStates[shootID] = .running(Self.cullStartingProgress)
        }
        cullTasks[shootID] = Task { [weak self] in
            await self?.runCull(shootID, shoot: shoot, copies: copies, runner: runner, settings: settings, volumes: volumes)
        }
        return true
    }

    private static let cullStartingProgress = CullProgress(phase: .cataloging, fraction: 0, spentUSD: 0)

    private func runCull(_ shootID: UUID, shoot: Shoot, copies: [URL], runner: CullRunner,
                         settings: CullSettings, volumes: [URL]) async {
        // Starts when the running ingest or sync finishes (state stays `.waiting` until then).
        await cullGate()
        if Task.isCancelled {
            await finishCull(shootID, .stopped(nil))
            return
        }
        cullStates[shootID] = .running(Self.cullStartingProgress)
        // Mirrors follow the main copy: bring any mirror that lacks the primary's earlier culls up to date first.
        if copies.count > 1,
           let replayed = await replayBeforeCull(primary: copies[0], mirrors: Array(copies.dropFirst()), volumes: volumes) {
            if let note = replayed.note { cullNotes[shootID] = note }
            if replayed.failed {
                await finishCull(shootID, .stopped(nil))
                return
            }
        }
        let outcome = await runner.run(
            shoot: shoot, copies: copies, cardVolumes: volumes, settings: settings,
            gate: { [weak self] in await self?.cullGate() },
            withApplyLock: { [weak self] body in
                guard let self else { throw CancellationError() }
                try await self.cullWithApplyLock(shootID: shootID, body)
            },
            onProgress: { [weak self] progress in
                guard let self, self.cullTasks[shootID] != nil else { return }
                if case .waiting(let note) = progress.phase {
                    self.cullStates[shootID] = .waiting(note)
                } else {
                    self.cullStates[shootID] = .running(progress)
                }
            },
            onRejects: { [weak self] batch in
                guard let self, self.cullTasks[shootID] != nil else { return }
                self.cullLiveRejects[shootID, default: []].append(contentsOf: batch)
            })
        await finishCull(shootID, outcome)
    }

    /// Cancels the run. During apply the runner rolls this run's moves back (outcome `.stopped`).
    func stopCull(shootID: UUID) {
        cullTasks[shootID]?.cancel()
    }

    /// Replays the primary's journal onto lagging mirrors under the apply lock. Nil when no mirror lags.
    private func replayBeforeCull(primary: URL, mirrors: [URL], volumes: [URL]) async -> (note: String?, failed: Bool)? {
        guard await Self.mirrorsLag(primary: primary, mirrors: mirrors) else { return nil }
        guard await acquireApplyLock(excludingIngest: true) else { return (nil, true) }
        let note = await Self.replayCullJournals(primary: primary, mirrors: mirrors, cardVolumes: volumes)
        releaseApplyLock()
        return (note, note?.hasPrefix("Cull replay:") == true)
    }

    private func finishCull(_ shootID: UUID, _ outcome: CullOutcome) async {
        cullTasks[shootID] = nil
        cullStates[shootID] = .finished(outcome)
        // Files may have moved on completion, on a failure after apply started, and on a stop (rollback may be partial).
        switch outcome {
        case .completed(let summary):
            cullLiveRejectsApplied[shootID] = true
            cullApplyEntered.remove(shootID)
            await afterCullChangedFiles(shootID, moved: summary.rejected > 0)
        case .failed, .stopped:
            if cullApplyEntered.remove(shootID) != nil { await afterCullChangedFiles(shootID, moved: true) }
        }
    }

    /// Offline copies missed the moves (sync replays the journal later), the summaries/thumbnails change,
    /// and the copies get re-checked.
    private func afterCullChangedFiles(_ shootID: UUID, moved: Bool) async {
        if moved { await markOfflineCopiesPending(shootID) }
        await refreshShoots()
        await loadLastCullRun(shootID: shootID)
        scheduleSyncCheck([shootID], force: true)
    }

    private func markOfflineCopiesPending(_ shootID: UUID) async {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return }
        let offline = item.copies.filter { $0.availability != .online }
        guard !offline.isEmpty else { return }
        for copy in offline { registry.setPendingSync(id: shootID, path: copy.path, true) }
        republishRecord(of: shootID)
        await saveRegistry()
    }

    /// Undoes the latest cull that isn't undone, on every online copy, under the apply lock.
    func undoLastCull(shootID: UUID) async -> Bool {
        guard cullBlockReason(shootID: shootID) == nil else { return false }
        let copies = onlineCullCopies(shootID)
        guard !copies.isEmpty else { return false }
        cullNotes[shootID] = nil
        cullStates[shootID] = .waiting(cullBusyNotice() ?? "Waiting to undo…")
        guard await acquireApplyLock(excludingIngest: true) else {
            cullStates[shootID] = nil
            return false
        }
        // The bar starts empty; it only reads as full once a callback reports nothing left to move.
        let undoStarting = CullProgress(phase: .undoing(done: 0, total: 0), fraction: 0, spentUSD: 0)
        cullStates[shootID] = .running(undoStarting)
        let volumes = cardVolumes()
        let runID = cullLastRuns[shootID]?.runID
        let result = await Self.performUndo(runID: runID, copies: copies, cardVolumes: volumes) { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self, case .running? = self.cullStates[shootID] else { return }
                self.cullStates[shootID] = .running(Self.undoProgress(done: done, total: total))
            }
        }
        releaseApplyLock()
        cullStates[shootID] = nil
        switch result {
        case .success(let summary):
            cullLiveRejects[shootID] = nil
            cullLiveRejectsApplied[shootID] = nil
            await afterCullChangedFiles(shootID, moved: summary.rejected > 0)
            return true
        case .failure(let error):
            cullNotes[shootID] = error.localizedDescription
            // Undo can fail after partial progress: refresh and re-check regardless.
            await afterCullChangedFiles(shootID, moved: true)
            return false
        }
    }

    nonisolated private static func undoProgress(done: Int, total: Int) -> CullProgress {
        let fraction = total > 0 ? Double(done) / Double(total) : 1
        return CullProgress(phase: .undoing(done: done, total: total), fraction: fraction, spentUSD: 0)
    }

    // MARK: Off-main work

    @concurrent
    nonisolated private static func performUndo(runID: UUID?, copies: [URL], cardVolumes: [URL],
                                                onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Result<CullRunSummary, Error> {
        do {
            let summary = try CullApplier.undo(runID: runID, copies: copies, cardVolumes: cardVolumes, onProgress: onProgress)
            return .success(summary)
        } catch {
            return .failure(error)
        }
    }

    @concurrent
    nonisolated private static func readCullRuns(_ copy: URL) async -> [CullRunSummary] {
        (try? CullJournal.runs(in: copy)) ?? []
    }

    @concurrent
    nonisolated private static func countPhotos(_ copy: URL, cardVolumes: [URL]) async -> Int? {
        (try? PhotoCatalog.scan(shoot: copy, cardVolumes: cardVolumes))?.count
    }

    /// True when an online mirror's journal lacks a run the primary has.
    @concurrent
    nonisolated fileprivate static func mirrorsLag(primary: URL, mirrors: [URL]) async -> Bool {
        func runIDs(in copy: URL) -> Set<UUID> {
            let runs = (try? CullJournal.runs(in: copy)) ?? []
            return Set(runs.map(\.runID))
        }
        let primaryRuns = runIDs(in: primary)
        guard !primaryRuns.isEmpty else { return false }
        return mirrors.contains { mirror in !primaryRuns.isSubset(of: runIDs(in: mirror)) }
    }

    /// Copies the primary's cull journal onto the mirrors (moves only; nothing is copied or deleted), so the
    /// sync planner sees matching paths. The primary is always the source. Returns a note when pairs couldn't be replayed.
    @concurrent
    nonisolated static func replayCullJournals(primary: URL, mirrors: [URL], cardVolumes: [URL]) async -> String? {
        guard !mirrors.isEmpty else { return nil }
        let primaryRunCount = (try? CullJournal.runs(in: primary).count) ?? 0
        guard primaryRunCount > 0 else { return nil }
        var skipped = 0
        var failure: String?
        for copy in mirrors {
            do {
                skipped += try CullReplay.replay(from: primary, to: copy, cardVolumes: cardVolumes).skipped.count
            } catch {
                failure = error.localizedDescription
            }
        }
        // `replayBeforeCull` recognises a failure by this prefix.
        if let failure { return "Cull replay: \(failure)" }
        guard skipped > 0 else { return nil }
        return "\(Format.count(skipped, "culled photo", "culled photos")) couldn't be matched on every copy."
    }
}
