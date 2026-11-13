import Foundation
import Testing
@testable import Auto

@MainActor
struct AppCullTests {
    struct Env {
        let dir: URL
        let model: AppModel
        let defaults: UserDefaults
        let suite: String
        let claude: FakeClaudeRunner
        let applier: FakeCullApplier
    }

    private func makeEnv(black: Bool = false, hang: Bool = false, photos: Int = 3, applier: FakeCullApplier = FakeCullApplier(), realApplier: Bool = false) throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppCull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "AppCullTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var metrics: [String: PhotoMetrics] = [:]
        for i in 0..<photos {
            var m = FakePhotoAnalyzer.defaultMetrics
            m.captureTime = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 1000)
            if black { m.meanLuma = 0; m.lumaStdDev = 0 }
            metrics[String(format: "IMG_%04d.JPG", i)] = m
        }
        let claude = FakeClaudeRunner(hang: hang) { _ in
            .success(ClaudeResponse(structured: try! JSONSerialization.data(withJSONObject: ["frames": [[String: Any]]()]),
                                    costUSD: 0.01, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil))
        }
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(),
                             defaults: defaults, claude: claude, photoAnalyzer: FakePhotoAnalyzer(metrics: metrics),
                             cullApplier: realApplier ? LiveCullApplier() : applier, cullWorkspaceRoot: dir.appendingPathComponent("ws"))
        return Env(dir: dir, model: model, defaults: defaults, suite: suite, claude: claude, applier: applier)
    }

    private func makeShoot(_ env: Env, name: String, photos: Int = 3) async throws -> Shoot {
        let parent = env.dir.appendingPathComponent("parent-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let shoot = try await env.model.createShoot(name: name, date: Date(), parents: [parent])
        let cam = shoot.folder.appendingPathComponent("Photo/CamA", isDirectory: true)
        try FileManager.default.createDirectory(at: cam, withIntermediateDirectories: true)
        for i in 0..<photos { try Data("x\(i)".utf8).write(to: cam.appendingPathComponent(String(format: "IMG_%04d.JPG", i))) }
        await env.model.refreshShoots()
        return shoot
    }

    private func waitUntil(_ timeout: Double = 30, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return cond()
    }

    @Test func settingsRoundTripThroughDefaults() throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        env.model.cullSettings.model = .haiku
        env.model.cullSettings.mode = .strict
        let again = AppModel(registryURL: env.dir.appendingPathComponent("other.json"), thumbnails: FakeThumbnailProvider(),
                             defaults: env.defaults)
        #expect(again.cullSettings.model == .haiku)
        #expect(again.cullSettings.mode == .strict)
        #expect(env.defaults.data(forKey: "settings.cull.v1") != nil)
    }

    @Test func blockReasonWhenOfflineOrUnknown() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await makeShoot(env, name: "Gone")
        #expect(env.model.cullBlockReason(shootID: shoot.id) == nil)
        try FileManager.default.removeItem(at: shoot.folder)
        await env.model.refreshShoots()
        #expect(env.model.cullBlockReason(shootID: shoot.id) == "Shoot is offline")
        #expect(env.model.startCull(shootID: shoot.id) == false)
    }

    @Test func startCullReachesCompleted() async throws {
        let env = try makeEnv(black: true)
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await makeShoot(env, name: "Done")
        #expect(env.model.startCull(shootID: shoot.id))
        let finished = await waitUntil {
            if case .finished? = env.model.cullStates[shoot.id] { return true }
            return false
        }
        #expect(finished)
        guard case .finished(.completed(let summary))? = env.model.cullStates[shoot.id] else {
            Issue.record("got \(String(describing: env.model.cullStates[shoot.id]))"); return
        }
        #expect(summary.photos == 3)
        #expect(env.applier.plans.count == 1)
        #expect(env.applier.applyOnMainThread == [false])
        #expect(env.model.cullBlockReason(shootID: shoot.id) == nil)
    }

    @Test func liveRejectsKeptAndAppliedAfterCompletion() async throws {
        let env = try makeEnv(black: true)
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await makeShoot(env, name: "Live")
        #expect(env.model.startCull(shootID: shoot.id))
        #expect(await waitUntil { if case .finished? = env.model.cullStates[shoot.id] { true } else { false } })
        #expect(env.model.cullLiveRejects[shoot.id]?.count == 3)
        #expect(env.model.cullLiveRejectsApplied[shoot.id] == true)
    }

    @Test func stoppedRunKeepsRejectsNotApplied() async throws {
        let env = try makeEnv(black: true, applier: FakeCullApplier(waitForCancelInApply: true))
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await makeShoot(env, name: "Stop")
        #expect(env.model.startCull(shootID: shoot.id))
        #expect(await waitUntil { env.applier.applyStarted && env.model.cullLiveRejects[shoot.id]?.count == 3 })
        env.model.stopCull(shootID: shoot.id)
        #expect(await waitUntil { if case .finished(.stopped)? = env.model.cullStates[shoot.id] { true } else { false } })
        #expect(env.model.cullLiveRejects[shoot.id]?.count == 3)
        #expect(env.model.cullLiveRejectsApplied[shoot.id] == false)
    }

    @Test func liveRejectsClearedOnNewRun() async throws {
        let env = try makeEnv(black: true)
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await makeShoot(env, name: "Clear")
        #expect(env.model.startCull(shootID: shoot.id))
        #expect(await waitUntil { if case .finished? = env.model.cullStates[shoot.id] { true } else { false } })
        #expect(env.model.cullLiveRejects[shoot.id]?.isEmpty == false)
        #expect(env.model.startCull(shootID: shoot.id))
        #expect(env.model.cullLiveRejects[shoot.id]?.isEmpty == true)
        #expect(env.model.cullLiveRejectsApplied[shoot.id] == false)
    }

    @Test func liveRejectsClearedOnUndo() async throws {
        let env = try makeEnv(black: true, realApplier: true)
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await makeShoot(env, name: "Undo")
        #expect(env.model.startCull(shootID: shoot.id))
        #expect(await waitUntil { if case .finished(.completed)? = env.model.cullStates[shoot.id] { true } else { false } })
        #expect(env.model.cullLiveRejects[shoot.id]?.isEmpty == false)
        #expect(await env.model.undoLastCull(shootID: shoot.id))
        #expect(env.model.cullLiveRejects[shoot.id] == nil)
        #expect(env.model.cullLiveRejectsApplied[shoot.id] == nil)
    }

    @Test func engineAssignmentAloneIsNotARunningIngest() throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.engine = CopyEngine()   // preflight: not counted until engine.run starts
        env.model._testInsert(card: card)
        #expect(env.model.cullBusyNotice() == nil)
    }

    @Test func busyNoticeWhileIngesting() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        #expect(env.model.cullBusyNotice() == nil)
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        env.model.ingestRunCount = 1
        env.model._testInsert(card: card)
        #expect(env.model.cullBusyNotice() == "Ingest in progress. The cull will start when it finishes.")
        env.model.ingestRunCount = 0
        #expect(env.model.cullBusyNotice() == nil)
    }

    @Test func cullWaitsForIngestThenRuns() async throws {
        let env = try makeEnv(black: true)
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await makeShoot(env, name: "Wait")
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        env.model.ingestRunCount = 1
        env.model._testInsert(card: card)
        #expect(env.model.startCull(shootID: shoot.id))
        guard case .waiting? = env.model.cullStates[shoot.id] else { Issue.record("expected waiting"); return }
        try await Task.sleep(for: .milliseconds(150))
        guard case .waiting? = env.model.cullStates[shoot.id] else { Issue.record("still waiting expected"); return }
        #expect(env.applier.plans.isEmpty)
        env.model.stopCull(shootID: shoot.id)
        let stopped = await waitUntil {
            if case .finished(.stopped)? = env.model.cullStates[shoot.id] { return true }
            return false
        }
        #expect(stopped)
        env.model.ingestRunCount = 0
    }

    @Test func twoShootsConcurrentSameShootRefused() async throws {
        let env = try makeEnv(hang: true)
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let a = try await makeShoot(env, name: "A")
        let b = try await makeShoot(env, name: "B")
        #expect(env.model.startCull(shootID: a.id))
        #expect(env.model.cullBlockReason(shootID: a.id) == "Already culling this shoot")
        #expect(env.model.startCull(shootID: a.id) == false)
        #expect(env.model.startCull(shootID: b.id))
        let both = await waitUntil { env.claude.inFlight >= 2 }
        #expect(both)
        env.model.stopCull(shootID: a.id)
        env.model.stopCull(shootID: b.id)
        let done = await waitUntil {
            for id in [a.id, b.id] { guard case .finished(.stopped)? = env.model.cullStates[id] else { return false } }
            return true
        }
        #expect(done)
        #expect(env.applier.plans.isEmpty)
    }
}
