import Foundation

/// The Selects final round: elimination rounds over the best-scored keeps of the whole shoot.
nonisolated extension CullRunner {

    enum FinalRoundOutcome {
        /// `byScore`: the budget ran out and the remaining rounds finished with the score fallback.
        case decided([CullDecision], byScore: Bool)
        case stopped
        /// Claude isn't installed or isn't logged in.
        case fatal(ClaudeRunnerError)
    }

    private struct FinalPicks: Decodable {
        struct Pick: Decodable { let id: String; let reason: String? }
        let picks: [Pick]
    }

    private typealias Candidate = SelectsPlanner.Candidate

    /// Cuts the scored keeps down to `SelectsPlanner.targetCount`. Unscored keeps are outside the quota.
    /// A failed batch falls back to its top scores; only a fatal Claude error, the budget or a stop ends the run.
    func finalRound(
        _ firstPassDecisions: [CullDecision],
        records: [String: PhotoRecord],
        photoCount: Int,
        context: CullRunContext
    ) async -> FinalRoundOutcome {
        let settings = context.settings
        let tracker = context.tracker

        let candidates = Self.candidates(from: firstPassDecisions, records: records)
        let strongCount = candidates.filter { $0.score >= SelectsPlanner.strongScore }.count
        let target = SelectsPlanner.targetCount(photoCount: photoCount, strongCount: strongCount)
        guard candidates.count > target else { return .decided(firstPassDecisions, byScore: false) }

        var decisions = firstPassDecisions
        /// Rejects every photo of `ids` that is not in `keep`, and returns those new rejects.
        func cut(keeping keep: Set<String>, among ids: Set<String>) -> [CullDecision] {
            var cuts: [CullDecision] = []
            for i in decisions.indices where ids.contains(decisions[i].photoID) && !keep.contains(decisions[i].photoID) {
                decisions[i].verdict = .reject
                decisions[i].criterion = "select"
                decisions[i].reason = "not a select"
                decisions[i].keeperID = nil
                decisions[i].confidence = 1
                decisions[i].source = .finalRound
                cuts.append(decisions[i])
            }
            return cuts
        }

        // Only the top-ranked candidates enter the rounds; the rest are cut straight away.
        let pool = SelectsPlanner.pool(from: candidates, target: target)
        let poolIDs = Set(pool.map(\.photoID))
        let candidateIDs = Set(candidates.map(\.photoID))
        context.emitRejects(liveRejects(cut(keeping: poolIDs, among: candidateIDs), records: records))

        let batchSize = SelectsPlanner.batchSize
        let survivorsAfterEachRound = SelectsPlanner.roundPlan(poolCount: pool.count, target: target, batchSize: batchSize)
        let survivorsBeforeEachRound = [pool.count] + survivorsAfterEachRound.dropLast()
        let totalCalls = survivorsBeforeEachRound.reduce(0) { total, survivors in
            total + (survivors + batchSize - 1) / batchSize
        }
        var callsDone = 0
        func reportProgress(callsDone: Int) {
            tracker.set(.finalRound(done: callsDone, total: totalCalls),
                        CullProgressScale.finalRoundStart + CullProgressScale.finalRoundSpan * cullRatio(callsDone, totalCalls))
        }
        tracker.set(.finalRound(done: 0, total: totalCalls), CullProgressScale.finalRoundStart)

        let roles = Self.rolesByPhotoID(firstPassDecisions)
        var survivors = pool
        var budgetReached = false
        for (roundIndex, survivorsAfter) in survivorsAfterEachRound.enumerated() {
            let batches = SelectsPlanner.batches(survivors, size: batchSize)
            let quotas = SelectsPlanner.quotas(batchSizes: batches.map(\.count), survivorsAfter: survivorsAfter)
            var picked: [Candidate] = []
            do {
                // Sliding window: at most `maxConcurrentCalls` Claude calls in flight.
                try await withThrowingTaskGroup(of: [Candidate].self) { tasks in
                    var next = 0
                    var inFlight = 0
                    while next < batches.count || inFlight > 0 {
                        while inFlight < settings.maxConcurrentCalls, next < batches.count {
                            if Task.isCancelled { throw CancellationError() }
                            if !budgetReached {
                                await context.gate()
                                if Task.isCancelled { throw CancellationError() }
                                if tracker.spent >= settings.maxRunBudgetUSD { budgetReached = true }
                            }
                            let batch = batches[next]
                            let quota = quotas[next]
                            next += 1
                            let batchNumber = next

                            let hasPreview = batch.contains { records[$0.photoID]?.preview != nil }
                            if budgetReached || quota == 0 || !hasPreview {
                                // No call: the batch keeps its top scores.
                                picked += SelectsPlanner.merge(picks: [], batch: batch, quota: quota)
                                callsDone += 1
                                reportProgress(callsDone: callsDone)
                                continue
                            }

                            inFlight += 1
                            let call = makeFinalRoundRequest(
                                batch: batch, quota: quota, round: roundIndex + 1, batchNumber: batchNumber,
                                batchCount: batches.count, roles: roles, records: records, context: context)
                            let label = "r\(roundIndex + 1)b\(batchNumber)"
                            tasks.addTask {
                                try await pickFromBatch(batch, quota: quota, request: call.request,
                                                        tokenToPhotoID: call.tokenToPhotoID, label: label, context: context)
                            }
                        }
                        guard inFlight > 0 else { break }
                        if let merged = try await tasks.next() {
                            inFlight -= 1
                            picked += merged
                            callsDone += 1
                            reportProgress(callsDone: callsDone)
                        }
                    }
                }
            } catch let error as ClaudeRunnerError {
                return .fatal(error)
            } catch {
                return .stopped
            }
            if Task.isCancelled { return .stopped }
            survivors = SelectsPlanner.trim(picked, to: survivorsAfter)
        }

        let finalIDs = Set(survivors.map(\.photoID))
        context.emitRejects(liveRejects(cut(keeping: finalIDs, among: poolIDs), records: records))
        return .decided(decisions, byScore: budgetReached)
    }

    // MARK: - Candidates

    /// Every keep the model scored. Its local rank breaks ties between equal scores.
    private static func candidates(from decisions: [CullDecision], records: [String: PhotoRecord]) -> [Candidate] {
        decisions.compactMap { decision in
            guard decision.verdict == .keep, let score = decision.score else { return nil }
            return Candidate(photoID: decision.photoID,
                             score: score,
                             tiebreak: records[decision.photoID].map(PhotoRank.score) ?? 0,
                             keyMoment: decision.grades?.role.isKeyMoment ?? false)
        }
    }

    /// The role the model gave each graded photo; the first decision wins for a repeated id.
    private static func rolesByPhotoID(_ decisions: [CullDecision]) -> [String: String] {
        var roles: [String: String] = [:]
        for decision in decisions {
            guard let grades = decision.grades, roles[decision.photoID] == nil else { continue }
            roles[decision.photoID] = grades.role.rawValue
        }
        return roles
    }

    // MARK: - One Claude call

    /// Asks Claude to pick `quota` frames from one batch. Missing or unusable picks are filled from
    /// the batch's top scores, so a failed call still returns exactly the quota.
    private func pickFromBatch(
        _ batch: [Candidate], quota: Int, request: ClaudeRequest, tokenToPhotoID: [String: String],
        label: String, context: CullRunContext
    ) async throws -> [Candidate] {
        let photoIDs = batch.map(\.photoID)
        let timer = CullCallTimer()
        var pickedIDs: [String] = []
        do {
            let response = try await claude.run(request)
            context.tracker.addSpend(response.costUSD ?? 0)
            let reply = try? JSONDecoder().decode(FinalPicks.self, from: response.structured)
            if let reply { pickedIDs = reply.picks.compactMap { tokenToPhotoID[$0.id] } }
            context.callLog.record(kind: "final", label: label, photoIDs: photoIDs, response: response,
                                   decoded: reply != nil, error: nil, durationMS: timer.elapsedMS)
        } catch let error as ClaudeRunnerError {
            context.callLog.record(kind: "final", label: label, photoIDs: photoIDs, response: nil,
                                   decoded: false, error: error, durationMS: timer.elapsedMS)
            if error.endsTheRun { throw error }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Unknown failure: this batch falls back to its top scores.
        }
        return SelectsPlanner.merge(picks: pickedIDs, batch: batch, quota: quota)
    }

    /// The request for one batch, and the map from the tokens Claude answers with back to photo ids.
    /// Every candidate gets a token; only those with a preview are listed for Claude to read.
    private func makeFinalRoundRequest(
        batch: [Candidate], quota: Int, round: Int, batchNumber: Int, batchCount: Int,
        roles: [String: String], records: [String: PhotoRecord], context: CullRunContext
    ) -> (request: ClaudeRequest, tokenToPhotoID: [String: String]) {
        let settings = context.settings
        var tokenToPhotoID: [String: String] = [:]
        var frames: [(token: String, path: String, score: Int, role: String?)] = []
        for (offset, candidate) in batch.enumerated() {
            let token = "p" + String(format: "%02d", offset + 1)
            tokenToPhotoID[token] = candidate.photoID
            guard let preview = records[candidate.photoID]?.preview else { continue }
            frames.append((token, Self.workspacePath(of: preview, runID: context.runID), candidate.score, roles[candidate.photoID]))
        }

        let message = CullPromptBuilder.finalRoundUserMessage(
            round: round, batch: batchNumber, batchCount: batchCount, pick: quota, frames: frames)
        let request = ClaudeRequest(
            model: settings.model.rawValue,
            systemPrompt: CullPromptBuilder.finalRoundSystemPrompt,
            appendSystemPrompt: CullPromptBuilder.finalRoundRunSection(settings: settings),
            userPrompt: message,
            jsonSchema: CullPromptBuilder.finalRoundSchema,
            workspace: workspaceRoot,
            maxBudgetUSD: Self.callBudget(photoCount: batch.count, settings: settings))
        return (request, tokenToPhotoID)
    }
}
