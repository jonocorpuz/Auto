import Foundation

/// The first pass: local triage decides what it can, then Claude grades the rest one group at a time.
nonisolated extension CullRunner {

    struct FirstPassResult {
        enum Ending {
            /// Every group was handled, unless `budgetReached` stopped new calls from starting.
            case finished(budgetReached: Bool)
            case stopped
            /// Claude isn't installed or isn't logged in.
            case fatal(ClaudeRunnerError)
        }

        /// Decisions keyed by the group's position in the grouper's output.
        var decisionsByGroup: [Int: [CullDecision]]
        var groupsDone: Int
        var ending: Ending
    }

    /// One group that still needs a Claude call.
    private struct GroupWork: Sendable {
        /// Position of the group in the grouper's output.
        let position: Int
        let group: PhotoGroup
        /// The group without the photos triage already rejected: what Claude is shown.
        let callGroup: PhotoGroup
        let triage: [CullDecision]
    }

    func runFirstPass(
        groups: [PhotoGroup], records: [String: PhotoRecord], context: CullRunContext
    ) async -> FirstPassResult {
        let settings = context.settings
        let tracker = context.tracker
        let groupsTotal = groups.count

        let (decidedByTriage, work) = triage(groups, records: records, context: context)
        var result = FirstPassResult(decisionsByGroup: decidedByTriage, groupsDone: groupsTotal - work.count,
                                     ending: .finished(budgetReached: false))

        let span = settings.mode.hasFinalRound
            ? CullProgressScale.firstPassSpanBeforeFinalRound
            : CullProgressScale.firstPassSpan
        func reportProgress(groupsDone: Int) {
            tracker.set(.analyzing(done: groupsDone, total: groupsTotal),
                        CullProgressScale.analyzed + span * cullRatio(groupsDone, groupsTotal))
        }
        reportProgress(groupsDone: result.groupsDone)

        let runSection = CullPromptBuilder.runSection(settings: settings)
        var budgetReached = false
        do {
            // Sliding window: at most `maxConcurrentCalls` Claude calls in flight.
            try await withThrowingTaskGroup(of: (Int, [CullDecision]).self) { tasks in
                var next = 0
                var inFlight = 0
                while next < work.count || inFlight > 0 {
                    while inFlight < settings.maxConcurrentCalls, next < work.count, !budgetReached {
                        if Task.isCancelled { throw CancellationError() }
                        await context.gate()
                        if Task.isCancelled { throw CancellationError() }
                        if tracker.spent >= settings.maxRunBudgetUSD {
                            budgetReached = true
                            break
                        }
                        let item = work[next]
                        next += 1
                        inFlight += 1
                        let call = makeGroupRequest(item.callGroup, index: item.position + 1, count: groupsTotal,
                                                    runSection: runSection, context: context)
                        tasks.addTask {
                            let decided = try await gradeGroup(item, request: call.request,
                                                               tokenToPhotoID: call.tokenToPhotoID, context: context)
                            return (item.position, decided)
                        }
                    }
                    guard inFlight > 0 else { break }
                    if let (position, decided) = try await tasks.next() {
                        inFlight -= 1
                        result.decisionsByGroup[position] = decided
                        result.groupsDone += 1
                        reportProgress(groupsDone: result.groupsDone)
                    }
                }
            }
        } catch let error as ClaudeRunnerError {
            result.ending = .fatal(error)
            return result
        } catch {
            result.ending = .stopped
            return result
        }
        result.ending = .finished(budgetReached: budgetReached)
        return result
    }

    // MARK: - Triage

    /// Runs local triage on every group. Groups it decides completely are returned as decisions
    /// (and shown as live rejects); the others become work for Claude.
    private func triage(
        _ groups: [PhotoGroup], records: [String: PhotoRecord], context: CullRunContext
    ) -> (decided: [Int: [CullDecision]], work: [GroupWork]) {
        var decided: [Int: [CullDecision]] = [:]
        var work: [GroupWork] = []
        for (position, group) in groups.enumerated() {
            let triageDecisions = group.photos.compactMap { LocalTriage.decide($0, settings: context.settings) }
            let triagedIDs = Set(triageDecisions.map(\.photoID))
            let remaining = group.photos.filter { !triagedIDs.contains($0.id) }

            if remaining.isEmpty {
                let decisions = CullPolicy.decide(
                    group: group, tokens: [:], modelOutput: nil, triage: triageDecisions, settings: context.settings)
                decided[position] = decisions
                context.emitRejects(liveRejects(decisions, records: records))
            } else {
                let callGroup = PhotoGroup(id: group.id, kind: group.kind, camera: group.camera, photos: remaining)
                work.append(GroupWork(position: position, group: group, callGroup: callGroup, triage: triageDecisions))
            }
        }
        return (decided, work)
    }

    // MARK: - One Claude call

    /// Asks Claude to grade one group and turns the answer into decisions. Any failure other than a
    /// stop or a Claude setup problem leaves the group with default keeps.
    private func gradeGroup(
        _ item: GroupWork, request: ClaudeRequest, tokenToPhotoID: [String: String], context: CullRunContext
    ) async throws -> [CullDecision] {
        let label = String(item.position + 1)
        let photoIDs = item.callGroup.photos.map(\.id)
        let timer = CullCallTimer()
        var grades: ModelGrades?
        do {
            let response = try await claude.run(request)
            context.tracker.addSpend(response.costUSD ?? 0)
            grades = try? JSONDecoder().decode(ModelGrades.self, from: response.structured)
            context.callLog.record(kind: "group", label: label, photoIDs: photoIDs, response: response,
                                   decoded: grades != nil, error: nil, durationMS: timer.elapsedMS)
        } catch let error as ClaudeRunnerError {
            context.callLog.record(kind: "group", label: label, photoIDs: photoIDs, response: nil,
                                   decoded: false, error: error, durationMS: timer.elapsedMS)
            if error.endsTheRun { throw error }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Unknown failure: this group falls back to default keeps.
        }

        let decided = CullPolicy.decide(group: item.group, tokens: tokenToPhotoID, modelOutput: grades,
                                        triage: item.triage, settings: context.settings)
        var groupRecords: [String: PhotoRecord] = [:]
        for photo in item.group.photos { groupRecords[photo.id] = photo }
        context.emitRejects(liveRejects(decided, records: groupRecords))
        return decided
    }

    /// The request for one group, and the map from the tokens Claude answers with back to photo ids.
    private func makeGroupRequest(
        _ group: PhotoGroup, index: Int, count: Int, runSection: String, context: CullRunContext
    ) -> (request: ClaudeRequest, tokenToPhotoID: [String: String]) {
        let settings = context.settings
        let tokens = CullPromptBuilder.tokens(for: group)

        var frames: [String: (preview: String, faces: String?)] = [:]
        for photo in group.photos {
            guard let preview = photo.preview else { continue }
            let previewPath = Self.workspacePath(of: preview, runID: context.runID)
            let faceStripPath = photo.faceStrip.map { Self.workspacePath(of: $0, runID: context.runID) }
            frames[photo.id] = (previewPath, faceStripPath)
        }

        let request = ClaudeRequest(
            model: settings.model.rawValue,
            systemPrompt: CullPromptBuilder.roleSystemPrompt,
            appendSystemPrompt: runSection,
            userPrompt: CullPromptBuilder.userMessage(group: group, index: index, count: count, tokens: tokens, frames: frames),
            jsonSchema: CullPromptBuilder.jsonSchema,
            workspace: workspaceRoot,
            maxBudgetUSD: Self.callBudget(photoCount: group.photos.count, settings: settings))

        let tokenToPhotoID = Dictionary(uniqueKeysWithValues: tokens.map { photoID, token in (token, photoID) })
        return (request, tokenToPhotoID)
    }
}
