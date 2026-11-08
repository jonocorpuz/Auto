import Foundation
import Testing
@testable import Auto

@Suite("CullRunner") struct CullRunnerTests {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [CullProgress] = []
        var items: [CullProgress] { lock.withLock { _items } }
        func add(_ p: CullProgress) { lock.withLock { _items.append(p) } }
    }

    private final class StringSet: @unchecked Sendable {
        private let lock = NSLock()
        private var _set: Set<String> = []
        var value: Set<String> { lock.withLock { _set } }
        func insert(_ s: String) { lock.withLock { _ = _set.insert(s) } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _n = 0
        private var _open = true
        var n: Int { lock.withLock { _n } }
        func hit() { lock.withLock { _n += 1 } }
        var isOpen: Bool { get { lock.withLock { _open } } set { lock.withLock { _open = newValue } } }
    }

    private final class RejectCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [[CullLiveReject]] = []
        var batches: [[CullLiveReject]] { lock.withLock { _batches } }
        func add(_ b: [CullLiveReject]) { lock.withLock { _batches.append(b) } }
    }

    private struct FakeThumbnailer: RejectThumbnailer {
        func thumbnail(preview: URL) -> Data? { Data("thumb:\(preview.lastPathComponent)".utf8) }
    }

    private struct Env {
        let shoot: FixtureShoot
        let workspace: URL
        let runner: CullRunner
        let claude: FakeClaudeRunner
        let applier: FakeCullApplier
        let rejected: StringSet
        var copy: URL { shoot.root }
    }

    private static func photoName(_ i: Int) -> String { String(format: "Photo/CamA/IMG_%04d.JPG", i) }

    /// 24 well-spaced photos make three mixed groups of eight. `black` photos are triaged locally.
    private static func makeEnv(
        photos: Int = 24,
        black: Bool = false,
        hang: Bool = false,
        hangIf: (@Sendable (ClaudeRequest) -> Bool)? = nil,
        applier: FakeCullApplier = FakeCullApplier(),
        reply: (@Sendable (ClaudeRequest, StringSet) -> Result<ClaudeResponse, Error>)? = nil
    ) -> Env {
        let shoot = FixtureShoot()
        var metrics: [String: PhotoMetrics] = [:]
        for i in 0..<photos {
            shoot.add(photoName(i))
            var m = FakePhotoAnalyzer.defaultMetrics
            m.captureTime = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 1000)
            if black { m.meanLuma = 0; m.lumaStdDev = 0 }
            metrics[String(format: "IMG_%04d.JPG", i)] = m
        }
        let rejected = StringSet()
        let claude = FakeClaudeRunner(hang: hang, hangIf: hangIf) { req in
            if let reply { return reply(req, rejected) }
            return rejectFirst(req, rejected)
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("CullWS-\(UUID().uuidString)")
        var runner = CullRunner(analyzer: FakePhotoAnalyzer(metrics: metrics), claude: claude, applier: applier, workspaceRoot: workspace)
        runner.thumbnailer = FakeThumbnailer()
        return Env(shoot: shoot, workspace: workspace, runner: runner, claude: claude, applier: applier, rejected: rejected)
    }

    private static func tokens(in prompt: String) -> [(token: String, index: Int)] {
        prompt.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("p"), let colon = line.firstIndex(of: ":"), line.contains("/a"),
                  let r = line.range(of: #"/a(\d{5})"#, options: .regularExpression) else { return nil }
            let digits = line[r].dropFirst(2)
            return (String(line[line.startIndex..<colon]), Int(digits)!)
        }
    }

    private static func response(_ items: [[String: Any]], cost: Double? = 0.01) -> Result<ClaudeResponse, Error> {
        let data = try! JSONSerialization.data(withJSONObject: ["frames": items])
        return .success(ClaudeResponse(structured: data, costUSD: cost, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil))
    }

    /// One graded frame. `subject` 0 so quality depends on technical, composition and story only.
    private static func frame(_ token: String, role: String = "candid", moment: String,
                              technical: Int = 3, composition: Int = 3, story: Int = 3,
                              reason: String = "fine") -> [String: Any] {
        ["id": token, "role": role, "moment": moment, "technical": technical, "composition": composition,
         "subject": 0, "story": story, "reason": reason]
    }

    /// Grades (technical >= 2, so never unusable) whose derived score is `score`; 1 maps to 2.
    private static func frame(_ token: String, score: Int, moment: String) -> [String: Any] {
        for t in 2...5 { for c in 1...5 { for st in 1...5 {
            let g = CullGrades(role: .candid, moment: moment, technical: t, composition: c, subject: 0, story: st)
            if g.score == max(score, 2) { return frame(token, moment: moment, technical: t, composition: c, story: st) }
        } } }
        fatalError("no grades for score \(score)")
    }

    /// Rejects the first frame of every group as accidental (unusable), keeps the rest.
    private static func rejectFirst(_ req: ClaudeRequest, _ rejected: StringSet, cost: Double? = 0.01) -> Result<ClaudeResponse, Error> {
        let frames = tokens(in: req.userPrompt)
        var items: [[String: Any]] = []
        for (n, f) in frames.enumerated() {
            if n == 0 {
                rejected.insert(photoName(f.index))
                items.append(frame(f.token, role: "accidental", moment: "m\(n + 1)", technical: 1, reason: "soft"))
            } else {
                items.append(frame(f.token, moment: "m\(n + 1)"))
            }
        }
        return response(items, cost: cost)
    }

    private func go(
        _ env: Env,
        settings: CullSettings = CullSettings(),
        gate: @escaping @Sendable () async -> Void = {},
        collector: Collector = Collector(),
        rejects: RejectCollector = RejectCollector()
    ) async -> CullOutcome {
        await env.runner.run(
            shoot: Shoot(id: UUID(), name: "T", date: Date(), folder: env.copy),
            copies: [env.copy], cardVolumes: [], settings: settings, gate: gate,
            withApplyLock: { body in try await body() },
            onProgress: { collector.add($0) },
            onRejects: { rejects.add($0) })
    }

    private func cleanup(_ env: Env) {
        env.shoot.cleanup()
        try? FileManager.default.removeItem(at: env.workspace)
    }

    @Test func happyPathPlansExactlyTheValidatedRejects() async {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        let outcome = await go(env)
        guard case .completed(let summary) = outcome else { Issue.record("expected completed, got \(outcome)"); return }
        #expect(env.applier.plans.count == 1)
        let plan = env.applier.plans[0]
        let rejects = Set(plan.decisions.filter { $0.verdict == .reject }.map(\.photoID))
        #expect(rejects == env.rejected.value)
        #expect(rejects.count == 3)
        #expect(plan.decisions.count == 24)
        #expect(Set(plan.records.keys).count == 24)
        #expect(summary.rejected == 3)
        #expect(summary.groupsDone == 3 && summary.groupsTotal == 3)
        #expect(summary.photos == 24)
        #expect(abs(summary.spentUSD - 0.03) < 1e-9)
        #expect(env.applier.reverts.isEmpty)
        #expect(plan.catalogCopy == env.copy)
    }

    @Test func writesAnalysisReportWithEveryDecisionAndCall() async {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        guard case .completed = await go(env) else { Issue.record("expected completed"); return }
        let reports = CullAnalysisLog.reports(in: env.copy)
        #expect(reports.count == 1)
        guard let r = reports.first else { return }
        #expect(r.decisions.count == 24)
        #expect(r.decisions.filter { $0.verdict == .keep }.count == 21)
        #expect(r.calls.count == 3)
        #expect(r.calls.allSatisfy { $0.kind == "group" && $0.outcome == "ok" && $0.costUSD == 0.01 })
        #expect(Set(r.calls.flatMap(\.photoIDs)).count == 24)
        #expect(abs(r.spentUSD - 0.03) < 1e-9)
        #expect(r.promptVersion == CullPromptBuilder.promptVersion)
        let plan = env.applier.plans[0]
        #expect(abs(plan.spentUSD - 0.03) < 1e-9 && plan.groupsDone == 3 && plan.groupsTotal == 3)
    }

    @Test func analysisReportRecordsUnreadableReplies() async {
        let env = Self.makeEnv { _, _ in
            .success(ClaudeResponse(structured: Data("nope".utf8), costUSD: 0.02, inputTokens: 100, outputTokens: 5,
                                    cacheReadTokens: nil))
        }
        defer { cleanup(env) }
        _ = await go(env)
        let calls = CullAnalysisLog.reports(in: env.copy).first?.calls ?? []
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.outcome == "unreadable" && $0.inputTokens == 100 })
    }

    @Test func stopDuringAnalysisAppliesNothing() async throws {
        let env = Self.makeEnv(hang: true)
        defer { cleanup(env) }
        let task = Task { await go(env) }
        for _ in 0..<500 where env.claude.inFlight == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(env.claude.inFlight > 0)
        task.cancel()
        let outcome = await task.value
        guard case .stopped(nil) = outcome else { Issue.record("expected stopped(nil), got \(outcome)"); return }
        #expect(env.claude.terminated > 0)
        #expect(env.applier.plans.isEmpty)
        #expect(env.applier.reverts.isEmpty)
    }

    @Test func stopDuringApplyRevertsOnce() async throws {
        let applier = FakeCullApplier(waitForCancelInApply: true)
        let env = Self.makeEnv(applier: applier)
        defer { cleanup(env) }
        let task = Task { await go(env) }
        for _ in 0..<500 where !applier.applyStarted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(applier.applyStarted)
        task.cancel()
        let outcome = await task.value
        guard case .stopped(let summary) = outcome else { Issue.record("expected stopped, got \(outcome)"); return }
        #expect(summary?.undone == true)
        #expect(applier.reverts.count == 1)
        #expect(applier.reverts.first == applier.plans.first?.runID)
        #expect(applier.revertWasCancelled == [false])
    }

    @Test func progressIsMonotonicAndPhasesInOrder() async {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        let collector = Collector()
        _ = await go(env, collector: collector)
        let items = collector.items
        #expect(!items.isEmpty)
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        func rank(_ p: CullPhase) -> Int {
            switch p {
            case .waiting: return -1
            case .cataloging: return 0
            case .preparing: return 1
            case .analyzing, .finalRound: return 2
            case .applying: return 3
            case .reverting, .undoing: return 4
            }
        }
        let ranks = items.map { rank($0.phase) }
        #expect(zip(ranks, ranks.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(ranks.last == 3)
        #expect(items.last?.fraction == 1)
    }

    @Test func concurrencyNeverExceedsSetting() async {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        var s = CullSettings(); s.maxConcurrentCalls = 1
        _ = await go(env, settings: s)
        #expect(env.claude.maxInFlight <= 1)
        #expect(env.claude.requests.count == 3)

        let env2 = Self.makeEnv()
        defer { cleanup(env2) }
        s.maxConcurrentCalls = 2
        _ = await go(env2, settings: s)
        #expect(env2.claude.maxInFlight <= 2)
    }

    @Test func runBudgetStopsLaunchesAndAppliesNothing() async {
        let env = Self.makeEnv { req, rejected in Self.rejectFirst(req, rejected, cost: 3.0) }
        defer { cleanup(env) }
        var s = CullSettings(); s.maxConcurrentCalls = 1; s.maxRunBudgetUSD = 5
        let outcome = await go(env, settings: s)
        guard case .failed(.budgetExceeded(let spent), _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(spent >= 5)
        #expect(env.claude.requests.count == 2)
        #expect(env.applier.plans.isEmpty)
    }

    @Test func notLoggedInAbortsWithNothingApplied() async {
        let env = Self.makeEnv { _, _ in .failure(ClaudeRunnerError.notLoggedIn) }
        defer { cleanup(env) }
        let outcome = await go(env)
        guard case .failed(.claudeNotLoggedIn, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(env.applier.plans.isEmpty)
    }

    @Test func notInstalledAborts() async {
        let env = Self.makeEnv { _, _ in .failure(ClaudeRunnerError.notInstalled) }
        defer { cleanup(env) }
        let outcome = await go(env)
        guard case .failed(.claudeNotInstalled, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(env.applier.plans.isEmpty)
    }

    @Test func oneGroupFailureDefaultsToKeepAndOthersApply() async {
        let env = Self.makeEnv { req, rejected in
            if req.userPrompt.contains("Group 2 of") { return .failure(ClaudeRunnerError.timedOut) }
            return Self.rejectFirst(req, rejected)
        }
        defer { cleanup(env) }
        let outcome = await go(env)
        guard case .completed(let summary) = outcome else { Issue.record("got \(outcome)"); return }
        let plan = env.applier.plans[0]
        let rejects = plan.decisions.filter { $0.verdict == .reject }
        #expect(rejects.count == 2)
        #expect(plan.decisions.filter { $0.source == .defaultKeep }.count == 8)
        #expect(summary.groupsDone == 3)
    }

    @Test func gateIsAwaitedBeforeEachLaunch() async {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        let counter = Counter()
        _ = await go(env, gate: { counter.hit() })
        #expect(counter.n == 3)
    }

    @Test func blockedGateDelaysLaunches() async throws {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        let gateState = Counter()
        gateState.isOpen = false
        let task = Task {
            await go(env, gate: {
                while !gateState.isOpen { try? await Task.sleep(for: .milliseconds(10)) }
            })
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(env.claude.requests.isEmpty)
        gateState.isOpen = true
        let outcome = await task.value
        guard case .completed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(env.claude.requests.count == 3)
    }

    @Test func triageOnlyGroupsSkipClaude() async {
        let env = Self.makeEnv(black: true)
        defer { cleanup(env) }
        let outcome = await go(env)
        #expect(env.claude.requests.isEmpty)
        // Every frame is a black frame, so every decision is a local reject (burst rescue may keep one).
        #expect(env.applier.plans.first?.decisions.allSatisfy { $0.source == .localTriage || $0.source == .validatorOverride } == true)
        if case .completed = outcome {} else { Issue.record("got \(outcome)") }
    }

    @Test func runDirectoryIsRemoved() async throws {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        _ = await go(env)
        let runs = env.workspace.appendingPathComponent("runs")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
        #expect(left.isEmpty)
        #expect(FileManager.default.fileExists(atPath: env.workspace.appendingPathComponent("CLAUDE.md").path))
    }

    @Test func requestShape() async {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        let s = CullSettings()
        _ = await go(env, settings: s)
        let requests = env.claude.requests
        #expect(requests.count == 3)
        for r in requests {
            #expect(r.workspace == env.workspace)
            #expect(r.model == "sonnet")
            #expect(r.appendSystemPrompt == CullPromptBuilder.runSection(settings: s))
            #expect(r.systemPrompt == CullPromptBuilder.roleSystemPrompt)
            #expect(r.jsonSchema == CullPromptBuilder.jsonSchema)
            #expect(r.maxBudgetUSD >= 0.05 && r.maxBudgetUSD <= 1.0)
            #expect(!r.userPrompt.contains(env.shoot.root.path))
            #expect(!r.userPrompt.contains(env.workspace.path))
            #expect(!r.userPrompt.contains("/Users/") && !r.userPrompt.contains("/private/") && !r.userPrompt.contains("/var/"))
            #expect(r.userPrompt.contains("runs/"))
        }
    }

    @Test func noPhotosFails() async {
        let env = Self.makeEnv(photos: 0)
        defer { cleanup(env) }
        let outcome = await go(env)
        guard case .failed(.noPhotos, _) = outcome else { Issue.record("got \(outcome)"); return }
    }

    // MARK: - Mode schema

    @Test func everyModeSendsTheSameGradingSchemaAndGuide() async {
        for mode in CullMode.allCases where !mode.hasFinalRound {
            let env = Self.makeEnv()
            defer { cleanup(env) }
            var s = CullSettings(); s.mode = mode
            _ = await go(env, settings: s)
            let requests = env.claude.requests
            #expect(requests.count == 3)
            #expect(requests.allSatisfy { $0.jsonSchema == CullPromptBuilder.jsonSchema })
            #expect(requests.allSatisfy { $0.appendSystemPrompt == CullModePrompts.gradingGuide })
        }
    }

    @Test func strictPolicyRejectsWeakCandidsButKeepsKeyMoments() async {
        // Every frame its own moment; even positions are weak candids, odd positions weak milestones.
        let env = Self.makeEnv { req, _ in
            let items = Self.tokens(in: req.userPrompt).enumerated().map { n, f in
                Self.frame(f.token, role: n % 2 == 0 ? "candid" : "milestone", moment: "m\(n + 1)",
                           technical: 2, composition: 2, story: 2)
            }
            return Self.response(items)
        }
        defer { cleanup(env) }
        var s = CullSettings(); s.mode = .strict
        _ = await go(env, settings: s)
        guard let plan = env.applier.plans.first else { Issue.record("no plan"); return }
        let rejects = plan.decisions.filter { $0.verdict == .reject }
        #expect(rejects.count == 12)
        #expect(rejects.allSatisfy { $0.criterion == "weak" && $0.grades?.role == .candid })
        #expect(plan.decisions.filter { $0.verdict == .keep }.allSatisfy { $0.grades?.role == .milestone })
    }

    // MARK: - Selects final round

    private static func isFinal(_ r: ClaudeRequest) -> Bool { r.systemPrompt == CullPromptBuilder.finalRoundSystemPrompt }

    private static func pickCount(_ prompt: String) -> Int {
        guard let r = prompt.range(of: #"Pick exactly (\d+)"#, options: .regularExpression) else { return 0 }
        return Int(prompt[r].split(separator: " ").last!)!
    }

    /// Group calls grade every frame as its own moment with score `score(index)`. The default,
    /// 1 + index % 6 (1 comes back as 2), has no strong frames, so the soft target sits at its 10% floor:
    /// score 6 = indices 5, 11, 17, 23…, score 5 = 4, 10, 16, 22…. Frames matching `unscored` are left
    /// out, so they stay default keeps.
    private static func scoredKeeps(_ req: ClaudeRequest, unscored: (Int) -> Bool = { _ in false },
                                    score: (Int) -> Int = { 1 + $0 % 6 }) -> Result<ClaudeResponse, Error> {
        let items: [[String: Any]] = tokens(in: req.userPrompt).enumerated().compactMap { n, f in
            unscored(f.index) ? nil : frame(f.token, score: score(f.index), moment: "m\(n + 1)")
        }
        return response(items, cost: 0)
    }

    /// The soft Selects target the runner used: strong frames are the first-pass scores of 7+.
    private static func target(_ plan: CullPlan) -> Int {
        SelectsPlanner.targetCount(photoCount: plan.decisions.count,
                                   strongCount: plan.decisions.filter { ($0.score ?? 0) >= SelectsPlanner.strongScore }.count)
    }

    /// Final-round calls pick the *last* frames listed, so the result differs from the score fallback.
    private static func pickLast(_ req: ClaudeRequest, cost: Double? = 0) -> Result<ClaudeResponse, Error> {
        let frames = tokens(in: req.userPrompt)
        let picks = frames.suffix(pickCount(req.userPrompt)).map { ["id": $0.token, "reason": "nice"] }
        let data = try! JSONSerialization.data(withJSONObject: ["picks": picks])
        return .success(ClaudeResponse(structured: data, costUSD: cost, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil))
    }

    private static var selects: CullSettings { var s = CullSettings(); s.mode = .selects; return s }

    private static func kept(_ plan: CullPlan) -> Set<String> {
        Set(plan.decisions.filter { $0.verdict == .keep }.map(\.photoID))
    }

    @Test func selectsKeepsExactlyTheTargetAndRejectsTheRestAsSelect() async {
        let env = Self.makeEnv(photos: 40) { req, _ in Self.isFinal(req) ? Self.pickLast(req) : Self.scoredKeeps(req) }
        defer { cleanup(env) }
        let rejects = RejectCollector()
        let outcome = await go(env, settings: Self.selects, rejects: rejects)
        guard case .completed(let summary) = outcome else { Issue.record("got \(outcome)"); return }
        guard let plan = env.applier.plans.first else { Issue.record("no plan"); return }
        #expect(Self.target(plan) == 4)
        #expect(plan.decisions.count == 40)
        // Pool = six 6s, then the 5s 0004, 0010, 0016, 0022; the model picks the four lowest-ranked of the pool.
        #expect(Self.kept(plan) == Set([4, 10, 16, 22].map(Self.photoName)))
        let cuts = plan.decisions.filter { $0.verdict == .reject }
        #expect(cuts.count == 36)
        #expect(cuts.allSatisfy { $0.criterion == "select" && $0.source == .finalRound && $0.reason == "not a select"
            && $0.keeperID == nil && $0.confidence == 1 })
        #expect(summary.rejected == 36)

        let groupCalls = env.claude.requests.filter { !Self.isFinal($0) }
        let finalCalls = env.claude.requests.filter(Self.isFinal)
        #expect(groupCalls.allSatisfy { $0.jsonSchema == CullPromptBuilder.jsonSchema })
        #expect(finalCalls.count == 1)
        for r in finalCalls {
            #expect(r.jsonSchema == CullPromptBuilder.finalRoundSchema)
            #expect(r.appendSystemPrompt == CullPromptBuilder.finalRoundRunSection(settings: Self.selects))
            #expect(r.maxBudgetUSD >= 0.05 && r.maxBudgetUSD <= 1.0)
            #expect(r.userPrompt.contains("runs/") && !r.userPrompt.contains("/Users/"))
            #expect(Self.tokens(in: r.userPrompt).map(\.token) == (1...10).map { String(format: "p%02d", $0) })
        }

        // Live cuts: the 30 outside the pool, then the 6 pool frames that lost.
        let live = rejects.batches.flatMap { $0 }
        #expect(live.count == 36)
        #expect(live.allSatisfy { $0.label == "Not a select" && $0.reason == "not a select" && $0.thumbnailJPEG != nil })
        #expect(Set(live.map(\.id)) == Set(cuts.map(\.photoID)))
    }

    @Test func selectsMultiRoundEndsAtTarget() async {
        let env = Self.makeEnv(photos: 80) { req, _ in Self.isFinal(req) ? Self.pickLast(req) : Self.scoredKeeps(req) }
        defer { cleanup(env) }
        let collector = Collector()
        // Progress keeps only the newest value; a slow gate lets the main-actor consumer see each launch.
        let outcome = await go(env, settings: Self.selects, gate: { try? await Task.sleep(for: .milliseconds(20)) },
                               collector: collector)
        guard case .completed = outcome, let plan = env.applier.plans.first else { Issue.record("got \(outcome)"); return }
        let target = Self.target(plan)
        #expect(target == 8)
        #expect(Self.kept(plan).count == target)
        let pool = SelectsPlanner.poolSize(target: target)
        let rounds = SelectsPlanner.roundPlan(poolCount: pool, target: target, batchSize: SelectsPlanner.batchSize)
        #expect(rounds.count > 1)
        let calls = ([pool] + rounds.dropLast()).reduce(0) { $0 + ($1 + 9) / 10 }
        #expect(env.claude.requests.filter(Self.isFinal).count == calls)
        #expect(collector.items.contains { if case .finalRound(_, calls) = $0.phase { return true }; return false })
    }

    @Test func failedFinalRoundCallFallsBackToTopScores() async {
        for failure in [Result<ClaudeResponse, Error>.failure(ClaudeRunnerError.timedOut),
                        .success(ClaudeResponse(structured: Data("nope".utf8), costUSD: 0, inputTokens: nil,
                                                outputTokens: nil, cacheReadTokens: nil))] {
            let env = Self.makeEnv(photos: 40) { req, _ in Self.isFinal(req) ? failure : Self.scoredKeeps(req) }
            defer { cleanup(env) }
            let outcome = await go(env, settings: Self.selects)
            guard case .completed = outcome, let plan = env.applier.plans.first else { Issue.record("got \(outcome)"); continue }
            #expect(Self.kept(plan) == Set([5, 11, 17, 23].map(Self.photoName)))
        }
    }

    @Test func unscoredKeepsStayKeptOutsideTheQuota() async {
        let unscored: @Sendable (Int) -> Bool = { $0 % 5 == 0 }
        let env = Self.makeEnv(photos: 40) { req, _ in
            Self.isFinal(req) ? Self.pickLast(req) : Self.scoredKeeps(req, unscored: unscored)
        }
        defer { cleanup(env) }
        let outcome = await go(env, settings: Self.selects)
        guard case .completed = outcome, let plan = env.applier.plans.first else { Issue.record("got \(outcome)"); return }
        #expect(Self.target(plan) == 4)
        let unscoredIDs = Set((0..<40).filter(unscored).map(Self.photoName))
        let kept = Self.kept(plan)
        #expect(unscoredIDs.isSubset(of: kept))
        #expect(kept.subtracting(unscoredIDs).count == 4)
        #expect(plan.decisions.filter { $0.verdict == .reject }.allSatisfy { !unscoredIDs.contains($0.photoID) })
    }

    @Test func stopDuringFinalRoundAppliesNothing() async throws {
        let env = Self.makeEnv(photos: 40, hangIf: { Self.isFinal($0) }) { req, _ in
            Self.isFinal(req) ? Self.pickLast(req) : Self.scoredKeeps(req)
        }
        defer { cleanup(env) }
        let task = Task { await go(env, settings: Self.selects) }
        for _ in 0..<500 where env.claude.requests.filter(Self.isFinal).isEmpty || env.claude.inFlight == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(env.claude.inFlight > 0)
        task.cancel()
        let outcome = await task.value
        guard case .stopped(nil) = outcome else { Issue.record("expected stopped(nil), got \(outcome)"); return }
        #expect(env.applier.plans.isEmpty)
        #expect(env.applier.reverts.isEmpty)
    }

    @Test func budgetHitInFinalRoundFinishesByScoreAndApplies() async {
        let env = Self.makeEnv(photos: 80) { req, _ in Self.isFinal(req) ? Self.pickLast(req, cost: 10) : Self.scoredKeeps(req) }
        defer { cleanup(env) }
        var s = Self.selects; s.maxConcurrentCalls = 1; s.maxRunBudgetUSD = 5
        let outcome = await go(env, settings: s)
        guard case .completed(let summary) = outcome, let plan = env.applier.plans.first else { Issue.record("got \(outcome)"); return }
        #expect(env.claude.requests.filter(Self.isFinal).count == 1)
        #expect(Self.kept(plan).count == Self.target(plan))
        #expect(summary.note?.contains("by score") == true)
    }

    @Test func malformedOrUnknownFinalRoundResponseKeepsTopScores() async {
        let unknown = Result<ClaudeResponse, Error>.success(ClaudeResponse(
            structured: try! JSONSerialization.data(withJSONObject: ["picks": [["id": "zz1"], ["id": "zz2"]]]),
            costUSD: 0, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil))
        let env = Self.makeEnv(photos: 40) { req, _ in Self.isFinal(req) ? unknown : Self.scoredKeeps(req) }
        defer { cleanup(env) }
        let outcome = await go(env, settings: Self.selects)
        guard case .completed = outcome, let plan = env.applier.plans.first else { Issue.record("got \(outcome)"); return }
        #expect(Self.kept(plan) == Set([5, 11, 17, 23].map(Self.photoName)))
    }

    @Test func overQuotaPicksKeepClaudesOrder() async {
        // Claude returns every frame, worst-ranked first; its first four (not the top scores) must survive.
        let env = Self.makeEnv(photos: 40) { req, _ in
            guard Self.isFinal(req) else { return Self.scoredKeeps(req) }
            let picks = Self.tokens(in: req.userPrompt).reversed().map { ["id": $0.token] }
            let data = try! JSONSerialization.data(withJSONObject: ["picks": picks])
            return .success(ClaudeResponse(structured: data, costUSD: 0, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil))
        }
        defer { cleanup(env) }
        let outcome = await go(env, settings: Self.selects)
        guard case .completed = outcome, let plan = env.applier.plans.first else { Issue.record("got \(outcome)"); return }
        #expect(Self.kept(plan).count == 4)
        #expect(Self.kept(plan) == Set([4, 10, 16, 22].map(Self.photoName)))
    }

    @Test func notLoggedInInFinalRoundFailsAndFinishesRejectStream() async {
        let env = Self.makeEnv(photos: 40) { req, _ in
            Self.isFinal(req) ? .failure(ClaudeRunnerError.notLoggedIn) : Self.scoredKeeps(req)
        }
        defer { cleanup(env) }
        let outcome = await go(env, settings: Self.selects, rejects: RejectCollector())
        guard case .failed(.claudeNotLoggedIn, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(env.applier.plans.isEmpty)
    }

    @Test func selectsProgressPassesThroughFinalRound() async {
        let env = Self.makeEnv(photos: 40) { req, _ in Self.isFinal(req) ? Self.pickLast(req) : Self.scoredKeeps(req) }
        defer { cleanup(env) }
        let collector = Collector()
        _ = await go(env, settings: Self.selects, gate: { try? await Task.sleep(for: .milliseconds(20)) },
                     collector: collector)
        let items = collector.items
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        let analyzing = items.filter { if case .analyzing = $0.phase { return true }; return false }
        let final = items.filter { if case .finalRound = $0.phase { return true }; return false }
        #expect(!final.isEmpty)
        #expect(analyzing.allSatisfy { $0.fraction <= 0.80 + 1e-9 })
        #expect(final.allSatisfy { $0.fraction >= 0.80 - 1e-9 && $0.fraction <= 0.95 + 1e-9 })
        #expect(final.first?.phase == .finalRound(done: 0, total: 1))
        #expect(items.last?.fraction == 1)
    }

    // MARK: - Live rejects

    @Test func onRejectsStreamsEachGroupsRejectsWithThumbnails() async {
        let env = Self.makeEnv()
        defer { cleanup(env) }
        let rejects = RejectCollector()
        _ = await go(env, rejects: rejects)
        let batches = rejects.batches
        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count == 1 })
        let live = batches.flatMap { $0 }
        #expect(Set(live.map(\.id)) == env.rejected.value)
        #expect(live.allSatisfy { $0.label == "Unusable" && $0.reason == "soft" })
        #expect(live.allSatisfy { $0.thumbnailJPEG.map { String(decoding: $0, as: UTF8.self).hasPrefix("thumb:a") } == true })
    }

    @Test func onRejectsIncludesTriageOnlyGroups() async {
        let env = Self.makeEnv(black: true)
        defer { cleanup(env) }
        let rejects = RejectCollector()
        _ = await go(env, rejects: rejects)
        #expect(env.claude.requests.isEmpty)
        let planned = Set(env.applier.plans.first?.decisions.filter { $0.verdict == .reject }.map(\.photoID) ?? [])
        let live = rejects.batches.flatMap { $0 }
        #expect(!live.isEmpty)
        #expect(Set(live.map(\.id)) == planned)
        #expect(live.allSatisfy { $0.thumbnailJPEG != nil })
    }
}
