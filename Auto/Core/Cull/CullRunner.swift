import Foundation

/// Moves rejects on disk and rolls a run back. The real conformance wraps `CullApplier`.
nonisolated protocol CullApplying: Sendable {
    func apply(_ plan: CullPlan, copies: [URL], cardVolumes: [URL], onMoved: @escaping @Sendable (Int, Int) -> Void) throws -> Int
    func revert(runID: UUID, copies: [URL], cardVolumes: [URL], onProgress: @escaping @Sendable (Int, Int) -> Void) throws
}

/// Orchestrates one cull: catalog, analyze locally, ask Claude per group, then apply.
/// Nothing is moved until every group is decided; a stop during apply rolls the moves back.
///
/// Every photo is analyzed once at `previewLongEdge` (grouping needs metrics first, so a smaller
/// first pass would cost a second decode). Mixed groups therefore get the same previews as bursts.
///
/// The steps live in extensions: `CullRunner+FirstPass`, `CullRunner+FinalRound`, `CullRunner+Apply`.
nonisolated struct CullRunner: Sendable {
    let analyzer: any PhotoAnalyzer
    let claude: any ClaudeRunner
    let applier: any CullApplying
    let workspaceRoot: URL
    var thumbnailer: any RejectThumbnailer = ImageIORejectThumbnailer()

    static let previewLongEdge = 1024

    typealias ApplyLock = @Sendable (@concurrent @Sendable () async throws -> Void) async throws -> Void

    /// `@concurrent`: the applier blocks its thread, so the run must never execute on the caller's (main) actor.
    @concurrent
    func run(
        shoot: Shoot,
        copies: [URL],
        cardVolumes: [URL],
        settings rawSettings: CullSettings,
        gate: @escaping @Sendable () async -> Void,
        withApplyLock: @escaping ApplyLock,
        onProgress: @escaping @MainActor @Sendable (CullProgress) -> Void,
        onRejects: @escaping @MainActor @Sendable ([CullLiveReject]) -> Void = { _ in }
    ) async -> CullOutcome {
        // Progress and live rejects flow through unbounded streams (tiny values, so nothing is ever
        // dropped), consumed on the main actor and awaited before returning.
        let (progressStream, progressInput) = AsyncStream<CullProgress>.makeStream(bufferingPolicy: .unbounded)
        let progressConsumer = Task { @MainActor in
            for await progress in progressStream { onProgress(progress) }
        }
        let (rejectStream, rejectInput) = AsyncStream<[CullLiveReject]>.makeStream(bufferingPolicy: .unbounded)
        let rejectConsumer = Task { @MainActor in
            for await batch in rejectStream { onRejects(batch) }
        }

        let context = CullRunContext(
            runID: UUID(),
            settings: rawSettings.clamped(),
            gate: gate,
            tracker: CullProgressTracker { _ = progressInput.yield($0) },
            callLog: CullCallLog(),
            emitRejects: { batch in
                if !batch.isEmpty { _ = rejectInput.yield(batch) }
            })
        let outcome = await execute(copies: copies, cardVolumes: cardVolumes, withApplyLock: withApplyLock, context: context)

        progressInput.finish()
        rejectInput.finish()
        await progressConsumer.value
        await rejectConsumer.value
        return outcome
    }

    // MARK: - Pipeline

    private func execute(
        copies: [URL],
        cardVolumes: [URL],
        withApplyLock: @escaping ApplyLock,
        context: CullRunContext
    ) async -> CullOutcome {
        guard let primary = copies.first else { return .failed(.noCopiesOnline, nil) }
        let runID = context.runID
        let settings = context.settings
        let tracker = context.tracker
        let runDate = Date()
        defer { CullWorkspace.removeRun(workspaceRoot, runID: runID) }

        // 1. Catalog.
        tracker.set(.cataloging, 0)
        let scanned: [PhotoRecord]
        do {
            scanned = try PhotoCatalog.scan(shoot: primary, cardVolumes: cardVolumes)
        } catch let error as CullError {
            return .failed(error, nil)
        } catch {
            return .failed(.claudeFailed(error.localizedDescription), nil)
        }
        if Task.isCancelled { return .stopped(nil) }
        guard !scanned.isEmpty else { return .failed(.noPhotos, nil) }
        tracker.set(.cataloging, CullProgressScale.cataloged)

        // 2. Workspace.
        let runDir: URL
        do {
            try CullWorkspace.prepare(at: workspaceRoot, claudeMD: CullPromptBuilder.workspaceClaudeMD,
                                      version: CullPromptBuilder.promptVersion)
            runDir = try CullWorkspace.runDirectory(workspaceRoot, runID: runID)
        } catch {
            return .failed(.claudeFailed("Couldn't prepare the cull workspace: \(error.localizedDescription)"), nil)
        }

        // 3. Local analysis, then grouping.
        let analyzed = await analyzeAll(scanned, primary: primary, runDir: runDir, context: context)
        if Task.isCancelled { return .stopped(nil) }
        let groups = PhotoGrouper.group(analyzed)
        let records = Self.recordsByID(scanned: scanned, analyzed: analyzed)

        // 4. First pass: local triage, then Claude grades whatever triage left undecided.
        let firstPass = await runFirstPass(groups: groups, records: records, context: context)
        if case .stopped = firstPass.ending { return .stopped(nil) }
        if Task.isCancelled { return .stopped(nil) }
        if case .fatal(let error) = firstPass.ending { return .failed(Self.setupError(error), nil) }
        if case .finished(budgetReached: true) = firstPass.ending {
            return .failed(.budgetExceeded(tracker.spent), nil)
        }
        var decisions = groups.indices.flatMap { firstPass.decisionsByGroup[$0] ?? [] }
        var runNote: String?

        // 5. Selects final round: only the best frames across the whole shoot stay.
        if settings.mode.hasFinalRound {
            switch await finalRound(decisions, records: records, photoCount: scanned.count, context: context) {
            case .decided(let finalDecisions, let byScore):
                decisions = finalDecisions
                if byScore { runNote = "Final round finished by score (budget reached)" }
            case .stopped:
                return .stopped(nil)
            case .fatal(let error):
                return .failed(Self.setupError(error), nil)
            }
            if Task.isCancelled { return .stopped(nil) }
        }

        // 6. Plan.
        var plan = CullPlan(runID: runID, settings: settings, decisions: decisions, records: records, catalogCopy: primary)
        plan.spentUSD = tracker.spent
        plan.groupsDone = firstPass.groupsDone
        plan.groupsTotal = groups.count
        plan.note = runNote

        // Diagnostic report for prompt tuning; a failed write never stops the cull.
        let report = CullAnalysisReport(
            runID: runID, date: runDate, mode: settings.mode, model: settings.model,
            promptVersion: CullPromptBuilder.promptVersion, criteria: settings.criteria.sorted(),
            photos: scanned.count, spentUSD: tracker.spent, calls: context.callLog.records, decisions: decisions)
        _ = try? CullAnalysisLog.write(report, in: primary)

        let photoCount = scanned.count
        let groupsDone = firstPass.groupsDone
        let groupsTotal = groups.count
        let note = runNote
        let summary: SummaryMaker = { rejected, undone in
            CullRunSummary(runID: runID, date: Date(), model: settings.model, photos: photoCount, rejected: rejected,
                           groupsDone: groupsDone, groupsTotal: groupsTotal, spentUSD: tracker.spent, undone: undone, note: note)
        }

        let rejectCount = decisions.filter { $0.verdict == .reject }.count
        if rejectCount == 0 {
            tracker.set(.applying(done: 0, total: 0), 1)
            return .completed(summary(0, false))
        }

        // 7. Apply under the shared lock.
        return await applyUnderLock(plan, rejectCount: rejectCount, copies: copies, cardVolumes: cardVolumes,
                                    withApplyLock: withApplyLock, tracker: tracker, summary: summary)
    }

    /// Every scanned photo by id; the analyzed version (with metrics and preview) wins where there is one.
    private static func recordsByID(scanned: [PhotoRecord], analyzed: [PhotoRecord]) -> [String: PhotoRecord] {
        var records: [String: PhotoRecord] = [:]
        for record in scanned { records[record.id] = record }
        for record in analyzed { records[record.id] = record }
        return records
    }

    // MARK: - Local analysis

    /// Analyzes every photo, one task per CPU core at a time. Photos that fail to analyze are left out.
    private func analyzeAll(
        _ records: [PhotoRecord], primary: URL, runDir: URL, context: CullRunContext
    ) async -> [PhotoRecord] {
        let criteria = context.settings.criteria
        let wantsFaceStrips = criteria.contains(CullCriterion.eyes.id) || criteria.contains(CullCriterion.cropped.id)
        let spec = PreviewSpec(longEdge: Self.previewLongEdge, faceStrips: wantsFaceStrips)
        let maxConcurrent = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let analyzer = self.analyzer
        let tracker = context.tracker
        let total = records.count

        var analyzed: [PhotoRecord?] = Array(repeating: nil, count: total)
        var done = 0
        tracker.set(.preparing(done: 0, total: total), CullProgressScale.cataloged)

        await withTaskGroup(of: (Int, PhotoRecord?).self) { tasks in
            var next = 0
            var inFlight = 0
            while next < total || inFlight > 0 {
                while inFlight < maxConcurrent, next < total, !Task.isCancelled {
                    let index = next
                    let record = records[index]
                    next += 1
                    inFlight += 1
                    tasks.addTask {
                        let workName = String(format: "a%05d", index)
                        let url = primary.appendingPathComponent(record.representative)
                        guard let result = try? await analyzer.analyze(url, workName: workName, workDir: runDir, spec: spec) else {
                            return (index, nil)
                        }
                        var analyzedRecord = record
                        analyzedRecord.metrics = result.0
                        analyzedRecord.preview = result.preview
                        analyzedRecord.faceStrip = result.faceStrip
                        return (index, analyzedRecord)
                    }
                }
                guard inFlight > 0, let (index, record) = await tasks.next() else { break }
                inFlight -= 1
                analyzed[index] = record
                done += 1
                tracker.set(.preparing(done: done, total: total),
                            CullProgressScale.cataloged + CullProgressScale.analysisSpan * cullRatio(done, total))
            }
        }
        return analyzed.compactMap { $0 }
    }

    // MARK: - Shared helpers

    /// Rejects with a thumbnail of their run-dir preview; call before the run dir is removed.
    func liveRejects(_ decisions: [CullDecision], records: [String: PhotoRecord]) -> [CullLiveReject] {
        decisions.filter { $0.verdict == .reject }.map { decision in
            let preview = records[decision.photoID]?.preview
            return CullLiveReject(id: decision.photoID, label: CullRejectLabel.label(for: decision), reason: decision.reason,
                                  thumbnailJPEG: preview.flatMap { thumbnailer.thumbnail(preview: $0) })
        }
    }

    /// Spending cap for one Claude call: three times its high estimate, kept between 5 cents and a dollar.
    static func callBudget(photoCount: Int, settings: CullSettings) -> Double {
        let estimate = CullEstimator.estimate(photoCount: photoCount, model: settings.model, settings: settings)
        return min(max(3 * estimate.high, 0.05), 1.00)
    }

    /// A run-directory file as Claude sees it, relative to the workspace root.
    static func workspacePath(of file: URL, runID: UUID) -> String {
        "runs/\(runID.uuidString)/" + file.lastPathComponent
    }

    /// The only Claude errors that end a run are the two setup problems.
    static func setupError(_ error: ClaudeRunnerError) -> CullError {
        error == .notInstalled ? .claudeNotInstalled : .claudeNotLoggedIn
    }
}

// MARK: - Run state

/// What every step of one run shares.
nonisolated struct CullRunContext: Sendable {
    let runID: UUID
    let settings: CullSettings
    /// Awaited before every Claude call; the app holds it while something else needs the shoot.
    let gate: @Sendable () async -> Void
    let tracker: CullProgressTracker
    let callLog: CullCallLog
    let emitRejects: @Sendable ([CullLiveReject]) -> Void
}

/// Where each phase sits on the 0...1 progress bar.
nonisolated enum CullProgressScale {
    static let cataloged = 0.02
    /// Local analysis runs from `cataloged` to `analyzed`.
    static let analysisSpan = 0.28
    static let analyzed = 0.30
    /// The first pass runs from `analyzed` to `applyStart`, or to `finalRoundStart` when a final round follows.
    static let firstPassSpan = 0.65
    static let firstPassSpanBeforeFinalRound = 0.50
    static let finalRoundStart = 0.80
    static let finalRoundSpan = 0.15
    static let applyStart = 0.95
    static let applySpan = 0.05
}

/// `done / total` capped at 1; an empty total counts as finished.
nonisolated func cullRatio(_ done: Int, _ total: Int) -> Double {
    total > 0 ? min(1, Double(done) / Double(total)) : 1
}

/// Times one Claude call for the call log.
nonisolated struct CullCallTimer: Sendable {
    private let started = ContinuousClock.now

    var elapsedMS: Int {
        Int((ContinuousClock.now - started) / .milliseconds(1))
    }
}

extension ClaudeRunnerError {
    /// Claude can't be used at all, so retrying other groups is pointless. Any other error only
    /// costs the one call, which then falls back to local rules.
    nonisolated var endsTheRun: Bool {
        self == .notInstalled || self == .notLoggedIn
    }
}

/// Keeps progress monotonic and forwards it to the stream. Also holds the run's spend.
nonisolated final class CullProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (CullProgress) -> Void
    private var fraction = 0.0
    private var _spent = 0.0

    init(emit: @escaping @Sendable (CullProgress) -> Void) { self.emit = emit }

    var spent: Double { lock.withLock { _spent } }

    /// Reports `phase`; the bar never moves backwards.
    func set(_ phase: CullPhase, _ newFraction: Double) {
        let progress: CullProgress = lock.withLock {
            fraction = max(fraction, min(newFraction, 1))
            return CullProgress(phase: phase, fraction: fraction, spentUSD: _spent)
        }
        emit(progress)
    }

    /// Reverting reports its own fraction and may go down.
    func setRaw(_ phase: CullPhase, _ newFraction: Double) {
        let progress: CullProgress = lock.withLock {
            fraction = newFraction
            return CullProgress(phase: phase, fraction: newFraction, spentUSD: _spent)
        }
        emit(progress)
    }

    func addSpend(_ amount: Double) {
        lock.withLock { _spent += max(0, amount) }
    }
}
