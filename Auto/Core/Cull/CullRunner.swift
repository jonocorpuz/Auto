import Foundation

/// Moves rejects on disk and rolls a run back. The real conformance wraps `CullApplier`.
nonisolated protocol CullApplying: Sendable {
    func apply(_ plan: CullPlan, copies: [URL], cardVolumes: [URL], onMoved: @escaping @Sendable (Int, Int) -> Void) throws -> Int
    func revert(runID: UUID, copies: [URL], cardVolumes: [URL], onProgress: @escaping @Sendable (Int, Int) -> Void) throws
}

/// Orchestrates one cull: catalog, analyze locally, ask Claude per group, then apply.
/// Nothing is moved until every group is decided; a stop during apply rolls the moves back.
///
/// Efficiency note: every photo is analyzed once at `PreviewSpec.longEdge` 1024 (grouping needs
/// metrics first, so a smaller first pass would cost a second decode). Mixed groups therefore
/// get 1024px previews too, slightly more image tokens than the 768 the plan allows.
nonisolated struct CullRunner: Sendable {
    let analyzer: any PhotoAnalyzer
    let claude: any ClaudeRunner
    let applier: any CullApplying
    let workspaceRoot: URL

    static let previewLongEdge = 1024

    /// `@concurrent`: the applier blocks its thread, so the run must never execute on the caller's (main) actor.
    @concurrent
    func run(
        shoot: Shoot,
        copies: [URL],
        cardVolumes: [URL],
        settings rawSettings: CullSettings,
        gate: @escaping @Sendable () async -> Void,
        withApplyLock: @escaping @Sendable (@concurrent @Sendable () async throws -> Void) async throws -> Void,
        onProgress: @escaping @MainActor @Sendable (CullProgress) -> Void
    ) async -> CullOutcome {
        // Progress flows through a stream consumed on the main actor and awaited before returning.
        let (stream, yield) = AsyncStream<CullProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await p in stream { onProgress(p) }
        }
        let tracker = ProgressTracker { _ = yield.yield($0) }
        let outcome = await execute(copies: copies, cardVolumes: cardVolumes, settings: rawSettings.clamped(),
                                    gate: gate, withApplyLock: withApplyLock, tracker: tracker)
        yield.finish()
        await consumer.value
        return outcome
    }

    // MARK: - Pipeline

    private func execute(
        copies: [URL],
        cardVolumes: [URL],
        settings: CullSettings,
        gate: @escaping @Sendable () async -> Void,
        withApplyLock: @escaping @Sendable (@concurrent @Sendable () async throws -> Void) async throws -> Void,
        tracker: ProgressTracker
    ) async -> CullOutcome {
        guard let primary = copies.first else { return .failed(.noCopiesOnline, nil) }
        let runID = UUID()
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
        tracker.set(.cataloging, 0.02)

        // 2. Workspace.
        let runDir: URL
        do {
            try CullWorkspace.prepare(at: workspaceRoot, claudeMD: CullPromptBuilder.workspaceClaudeMD,
                                      version: CullPromptBuilder.promptVersion)
            runDir = try CullWorkspace.runDirectory(workspaceRoot, runID: runID)
        } catch {
            return .failed(.claudeFailed("Couldn't prepare the cull workspace: \(error.localizedDescription)"), nil)
        }

        // 3. Local analysis, bounded concurrency.
        let analyzed = await analyzeAll(scanned, primary: primary, runDir: runDir, settings: settings, tracker: tracker)
        if Task.isCancelled { return .stopped(nil) }

        let groups = PhotoGrouper.group(analyzed)
        var records: [String: PhotoRecord] = [:]
        for r in scanned { records[r.id] = r }
        for r in analyzed { records[r.id] = r }

        // 4. Triage, and the work list for Claude.
        struct Work {
            let position: Int
            let group: PhotoGroup
            let callGroup: PhotoGroup
            let triage: [CullDecision]
        }
        var decisionsByGroup: [Int: [CullDecision]] = [:]
        var work: [Work] = []
        for (position, group) in groups.enumerated() {
            let triage = group.photos.compactMap { LocalTriage.decide($0, settings: settings) }
            let triaged = Set(triage.map(\.photoID))
            let remaining = group.photos.filter { !triaged.contains($0.id) }
            if remaining.isEmpty {
                decisionsByGroup[position] = CullDecisionValidator.validate(
                    group: group, tokens: [:], modelOutput: nil, triage: triage, settings: settings)
            } else {
                let call = PhotoGroup(id: group.id, kind: group.kind, camera: group.camera, photos: remaining)
                work.append(Work(position: position, group: group, callGroup: call, triage: triage))
            }
        }
        let groupsTotal = groups.count
        var groupsDone = groups.count - work.count
        tracker.set(.analyzing(done: groupsDone, total: groupsTotal), analyzingFraction(groupsDone, groupsTotal))

        // 5. Claude calls, sliding window.
        let runSection = CullPromptBuilder.runSection(settings: settings)
        var budgetHit = false
        var fatal: ClaudeRunnerError?
        do {
            try await withThrowingTaskGroup(of: (Int, [CullDecision]).self) { tg in
                var next = 0
                var inFlight = 0
                while next < work.count || inFlight > 0 {
                    while inFlight < settings.maxConcurrentCalls, next < work.count, !budgetHit {
                        if Task.isCancelled { throw CancellationError() }
                        await gate()
                        if Task.isCancelled { throw CancellationError() }
                        if tracker.spent >= settings.maxRunBudgetUSD { budgetHit = true; break }
                        let item = work[next]
                        next += 1
                        inFlight += 1
                        let request = makeRequest(item.callGroup, index: item.position + 1, count: groupsTotal,
                                                  runID: runID, settings: settings, runSection: runSection)
                        let triage = item.triage
                        let group = item.group
                        let tokens = request.tokens
                        let claude = self.claude
                        let req = request.request
                        let position = item.position
                        tg.addTask {
                            var output: ModelDecisions?
                            do {
                                let response = try await claude.run(req)
                                tracker.addSpend(response.costUSD ?? 0)
                                output = try? JSONDecoder().decode(ModelDecisions.self, from: response.structured)
                            } catch let error as ClaudeRunnerError {
                                switch error {
                                case .notInstalled, .notLoggedIn: throw error
                                default: break
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // Unknown failure: this group falls back to default keeps.
                            }
                            let decided = CullDecisionValidator.validate(
                                group: group, tokens: tokens.reverse, modelOutput: output, triage: triage, settings: settings)
                            return (position, decided)
                        }
                    }
                    guard inFlight > 0 else { break }
                    if let (position, decided) = try await tg.next() {
                        inFlight -= 1
                        decisionsByGroup[position] = decided
                        groupsDone += 1
                        tracker.set(.analyzing(done: groupsDone, total: groupsTotal),
                                    analyzingFraction(groupsDone, groupsTotal))
                    }
                }
            }
        } catch let error as ClaudeRunnerError {
            fatal = error
        } catch {
            return .stopped(nil)
        }
        if Task.isCancelled { return .stopped(nil) }
        if let fatal {
            return .failed(fatal == .notInstalled ? .claudeNotInstalled : .claudeNotLoggedIn, nil)
        }
        if budgetHit {
            return .failed(.budgetExceeded(tracker.spent), nil)
        }

        // 6. Plan.
        let decisions = groups.indices.flatMap { decisionsByGroup[$0] ?? [] }
        let rejectCount = decisions.filter { $0.verdict == .reject }.count
        let plan = CullPlan(runID: runID, settings: settings, decisions: decisions, records: records, catalogCopy: primary)
        let groupsDoneFinal = groupsDone
        let summary: @Sendable (Int, Bool) -> CullRunSummary = { rejected, undone in
            CullRunSummary(runID: runID, date: Date(), model: settings.model, photos: scanned.count, rejected: rejected,
                           groupsDone: groupsDoneFinal, groupsTotal: groupsTotal, spentUSD: tracker.spent, undone: undone)
        }
        if rejectCount == 0 {
            tracker.set(.applying(done: 0, total: 0), 1)
            return .completed(summary(0, false))
        }

        // 7. Apply under the shared lock.
        let result = ApplyResult()
        let applier = self.applier
        do {
            try await withApplyLock {
                if Task.isCancelled { result.set(.stopped(nil)); return }
                tracker.set(.applying(done: 0, total: rejectCount), 0.95)
                var applyError: Error?
                var moved = 0
                do {
                    moved = try applier.apply(plan, copies: copies, cardVolumes: cardVolumes) { done, total in
                        tracker.set(.applying(done: done, total: total), 0.95 + 0.05 * ratio(done, total))
                    }
                } catch {
                    applyError = error
                }
                let cancelled = Task.isCancelled || applyError is CancellationError
                if cancelled || applyError != nil {
                    // Revert must complete, so it runs in a task that is never cancelled.
                    let revertError: Error? = await Task.detached {
                        do {
                            try applier.revert(runID: runID, copies: copies, cardVolumes: cardVolumes) { done, total in
                                tracker.setRaw(.reverting(done: done, total: total), 0.95 * (1 - ratio(done, total)))
                            }
                            return nil
                        } catch {
                            return error
                        }
                    }.value
                    if cancelled {
                        if let revertError, !(revertError is CullError && (revertError as? CullError) == .nothingToUndo) {
                            result.set(.failed(Self.cullError(revertError), nil))
                        } else {
                            result.set(.stopped(summary(rejectCount, true)))
                        }
                    } else if let applyError {
                        result.set(.failed(Self.cullError(applyError), nil))
                    }
                    return
                }
                tracker.set(.applying(done: moved, total: moved), 1)
                result.set(.completed(summary(moved, false)))
            }
        } catch {
            if result.value == nil {
                return Task.isCancelled || error is CancellationError ? .stopped(nil) : .failed(Self.cullError(error), nil)
            }
        }
        return result.value ?? .stopped(nil)
    }

    private static func cullError(_ error: Error) -> CullError {
        (error as? CullError) ?? .journalWriteFailed(error.localizedDescription)
    }

    // MARK: - Local analysis

    private func analyzeAll(
        _ records: [PhotoRecord], primary: URL, runDir: URL, settings: CullSettings, tracker: ProgressTracker
    ) async -> [PhotoRecord] {
        let faceStrips = settings.criteria.contains(CullCriterion.eyes.id) || settings.criteria.contains(CullCriterion.cropped.id)
        let spec = PreviewSpec(longEdge: Self.previewLongEdge, faceStrips: faceStrips)
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let analyzer = self.analyzer
        var out: [PhotoRecord?] = Array(repeating: nil, count: records.count)
        var done = 0
        let total = records.count
        tracker.set(.preparing(done: 0, total: total), 0.02)

        await withTaskGroup(of: (Int, PhotoRecord?).self) { tg in
            var next = 0
            var inFlight = 0
            while next < total || inFlight > 0 {
                while inFlight < width, next < total, !Task.isCancelled {
                    let index = next
                    let record = records[index]
                    next += 1
                    inFlight += 1
                    tg.addTask {
                        let name = String(format: "a%05d", index)
                        let url = primary.appendingPathComponent(record.representative)
                        guard let result = try? await analyzer.analyze(url, workName: name, workDir: runDir, spec: spec) else {
                            return (index, nil)
                        }
                        var r = record
                        r.metrics = result.0
                        r.preview = result.preview
                        r.faceStrip = result.faceStrip
                        return (index, r)
                    }
                }
                guard inFlight > 0, let (index, record) = await tg.next() else { break }
                inFlight -= 1
                out[index] = record
                done += 1
                tracker.set(.preparing(done: done, total: total), 0.02 + 0.28 * ratio(done, total))
            }
        }
        return out.compactMap { $0 }
    }

    // MARK: - Requests

    /// photoID → token, with the inverse the validator wants.
    struct TokenMap: Sendable {
        let forward: [String: String]
        var reverse: [String: String] { Dictionary(uniqueKeysWithValues: forward.map { ($1, $0) }) }
    }

    private func makeRequest(
        _ group: PhotoGroup, index: Int, count: Int, runID: UUID, settings: CullSettings, runSection: String
    ) -> (request: ClaudeRequest, tokens: TokenMap) {
        let tokens = CullPromptBuilder.tokens(for: group)
        var frames: [String: (preview: String, faces: String?)] = [:]
        let prefix = "runs/\(runID.uuidString)/"
        for photo in group.photos {
            guard let preview = photo.preview else { continue }
            frames[photo.id] = (prefix + preview.lastPathComponent, photo.faceStrip.map { prefix + $0.lastPathComponent })
        }
        let message = CullPromptBuilder.userMessage(group: group, index: index, count: count, tokens: tokens, frames: frames)
        let estimate = CullEstimator.estimate(photoCount: group.photos.count, model: settings.model, settings: settings)
        let budget = min(max(3 * estimate.high, 0.05), 1.00)
        let request = ClaudeRequest(
            model: settings.model.rawValue,
            systemPrompt: CullPromptBuilder.roleSystemPrompt,
            appendSystemPrompt: runSection,
            userPrompt: message,
            jsonSchema: CullPromptBuilder.jsonSchema(for: settings.mode),
            workspace: workspaceRoot,
            maxBudgetUSD: budget)
        return (request, TokenMap(forward: tokens))
    }
}

// MARK: - Helpers

private nonisolated func ratio(_ done: Int, _ total: Int) -> Double {
    total > 0 ? min(1, Double(done) / Double(total)) : 1
}

private nonisolated func analyzingFraction(_ done: Int, _ total: Int) -> Double {
    0.30 + 0.65 * ratio(done, total)
}

private nonisolated final class ApplyResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: CullOutcome?
    var value: CullOutcome? { lock.withLock { _value } }
    func set(_ v: CullOutcome) { lock.withLock { _value = v } }
}

/// Keeps progress monotonic and forwards it to the stream.
private nonisolated final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (CullProgress) -> Void
    private var fraction = 0.0
    private var _spent = 0.0

    init(emit: @escaping @Sendable (CullProgress) -> Void) { self.emit = emit }

    var spent: Double { lock.withLock { _spent } }

    func set(_ phase: CullPhase, _ f: Double) {
        let p: CullProgress = lock.withLock {
            fraction = max(fraction, min(f, 1))
            return CullProgress(phase: phase, fraction: fraction, spentUSD: _spent)
        }
        emit(p)
    }

    /// Reverting reports its own fraction and may go down.
    func setRaw(_ phase: CullPhase, _ f: Double) {
        let p: CullProgress = lock.withLock {
            fraction = f
            return CullProgress(phase: phase, fraction: f, spentUSD: _spent)
        }
        emit(p)
    }

    func addSpend(_ amount: Double) {
        lock.withLock { _spent += max(0, amount) }
    }
}
