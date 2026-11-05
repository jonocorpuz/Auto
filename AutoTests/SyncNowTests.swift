import Foundation
import Testing
@testable import Auto

/// AppModel sync state, scheduler and Sync Now. Temp folders share one real volume, so distinct "drives" are
/// faked with `volumeIDProvider` (a path under volA / volB / volC reports that id), as in MirrorShootsTests.
@MainActor
struct SyncNowTests {
    struct Env {
        let dir: URL
        let model: AppModel
        let volA: URL
        let volB: URL
    }

    nonisolated private static let fakeProvider: @Sendable (URL) -> String? = { url in
        for name in ["volA", "volB", "volC"] where url.pathComponents.contains(name) { return name }
        return nil
    }

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncNow-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let vols = ["volA", "volB"].map { dir.appendingPathComponent($0, isDirectory: true) }
        for v in vols { try fm.createDirectory(at: v, withIntermediateDirectories: true) }
        let suite = "SyncNowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        model.volumeIDProvider = Self.fakeProvider
        model.syncDebounce = .zero
        return Env(dir: dir, model: model, volA: vols[0], volB: vols[1])
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    /// A shoot on volA with a mirror on volB.
    private func twoCopies(_ env: Env) async throws -> (id: UUID, a: URL, b: URL) {
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        await env.model._testSyncIdle()
        return (shoot.id, shoot.folder, try #require(shoot.mirrors.first))
    }

    private func write(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func report(_ state: ShootSyncState?) -> ShootSyncReport? {
        if case .done(let r, _)? = state { return r }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Hands out checker calls one by one; the first can be held until released.
    nonisolated final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _released = false
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var released: Bool { lock.lock(); defer { lock.unlock() }; return _released }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; _calls += 1; return _calls }
        func release() { lock.lock(); _released = true; lock.unlock() }
    }

    // MARK: Check

    @Test func fileMissingOnMirrorReachesDoneOutOfSync() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        let r = try #require(report(env.model.syncStates[s.id]))
        #expect(r.isOutOfSync)
        #expect(r.missing.values.flatMap { $0 }.map(\.file.relPath) == ["Video/a.mov"])
        #expect(env.model.syncBadge(for: s.id) == .outOfSync(missing: 1, conflicts: 0))
    }

    @Test func singleCopyIsNone() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "Solo", date: day, parent: env.volA)
        env.model.scheduleSyncCheck([shoot.id], force: true)
        await env.model._testSyncIdle()
        #expect(env.model.syncStates[shoot.id] == .single)
        #expect(env.model.syncBadge(for: shoot.id) == .none)
        #expect(env.model.syncChecksStarted == 0)
    }

    @Test func offlineCopyIsUnknownAndNoCheckRuns() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        var reg = env.model.registry
        try reg.addMirror(id: shoot.id, path: "/Volumes/NoSuch/S")
        try await ShootStore.save(reg, to: env.model.registryURL)
        await env.model.loadShoots()
        env.model.scheduleSyncCheck([shoot.id], force: true)
        await env.model._testSyncIdle()
        guard case .unknown(let reason)? = env.model.syncStates[shoot.id] else { Issue.record("expected unknown"); return }
        #expect(reason.contains("NoSuch"))
        #expect(env.model.syncChecksStarted == 0)
        guard case .unknown(let badge) = env.model.syncBadge(for: shoot.id) else { Issue.record("expected unknown badge"); return }
        #expect(badge.contains("NoSuch"))
    }

    @Test func forcedChecksRunButThrottledOnesDoNot() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        let base = env.model.syncChecksStarted
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(env.model.syncChecksStarted == base + 1)
        env.model.scheduleSyncCheck([s.id], force: false)
        await env.model._testSyncIdle()
        #expect(env.model.syncChecksStarted == base + 1)
        env.model.scheduleSyncCheck([s.id], force: true)
        await env.model._testSyncIdle()
        #expect(env.model.syncChecksStarted == base + 2)
        // Once the throttle has lapsed a plain request runs again.
        env.model.syncThrottle = 0
        env.model.scheduleSyncCheck([s.id], force: false)
        await env.model._testSyncIdle()
        #expect(env.model.syncChecksStarted == base + 3)
    }

    @Test func newerRequestCancelsOlderAndStaleResultIsDropped() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        let gate = Gate()
        env.model.syncChecker = { copies, _, _, _, _ in
            let n = gate.next()
            if n == 1 {
                // Ignores cancellation on purpose and reports something out of sync once released.
                while !gate.released { try? await Task.sleep(for: .milliseconds(5)) }
                var stale = ShootSyncReport(copies: copies)
                stale.depth = .checksums
                stale.missing[copies[1]] = [SyncMissing(file: SyncFile(relPath: "stale.mov", size: 1), source: copies[0])]
                return stale
            }
            var fresh = ShootSyncReport(copies: copies)
            fresh.depth = .checksums
            return fresh
        }
        env.model.checkSync(shootID: s.id)
        try await waitUntil { gate.calls == 1 }
        env.model.checkSync(shootID: s.id)
        gate.release()
        await env.model._testSyncIdle()
        #expect(gate.calls == 2)
        #expect(report(env.model.syncStates[s.id])?.isInSync == true)
    }

    @Test func syncNowRefusesWhileCheckIsOnlyAtSizes() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        let gate = Gate()
        env.model.syncChecker = { copies, _, _, onSize, _ in
            var sizes = ShootSyncReport(copies: copies)
            sizes.missing[copies[1]] = [SyncMissing(file: SyncFile(relPath: "x.mov", size: 1), source: copies[0])]
            await onSize(sizes)
            _ = gate.next()
            while !gate.released { try? await Task.sleep(for: .milliseconds(5)) }
            var done = ShootSyncReport(copies: copies)
            done.depth = .checksums
            return done
        }
        env.model.checkSync(shootID: s.id)
        try await waitUntil { gate.calls == 1 }
        guard case .checking(_, let partial)? = env.model.syncStates[s.id] else { Issue.record("expected checking"); return }
        #expect(partial?.depth == .sizes)
        #expect(env.model.syncNow(shootID: s.id) == false)
        #expect(env.model.syncBadge(for: s.id) == .outOfSync(missing: 1, conflicts: 0))   // yellow before hashing finishes
        gate.release()
        await env.model._testSyncIdle()
        #expect(env.model.syncNow(shootID: s.id) == false)   // in sync: nothing to do
    }

    @Test func deepCheckIsGreenWithDeepVerifiedDateAndPersists() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip"); try write(s.b, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        guard case .inSync(let copies, _, let plain) = env.model.syncBadge(for: s.id) else { Issue.record("expected green"); return }
        #expect(copies == 2 && plain == nil)
        env.model.checkSync(shootID: s.id, deep: true)
        await env.model._testSyncIdle()
        guard case .inSync(_, _, let deep) = env.model.syncBadge(for: s.id) else { Issue.record("expected green"); return }
        #expect(deep != nil)
        try await waitUntil { SyncMetaStore.load(from: env.model.syncMetaURL)[s.id] != nil }
        #expect(SyncMetaStore.load(from: env.model.syncMetaURL)[s.id] != nil)
    }

    // MARK: Sync Now

    @Test func syncNowCopiesMissingFileByteIdenticalAndLeavesSourceAlone() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/Cam A/a.mov", String(repeating: "x", count: 5000))
        try write(s.b, "Video/b.mov", "only on b")
        let sourceBefore = try Data(contentsOf: s.a.appendingPathComponent("Video/Cam A/a.mov"))
        let sourceDate = try FileManager.default.attributesOfItem(atPath: s.a.appendingPathComponent("Video/Cam A/a.mov").path)[.modificationDate] as? Date
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(env.model.syncNow(shootID: s.id))
        await env.model._testSyncIdle()
        #expect(try Data(contentsOf: s.b.appendingPathComponent("Video/Cam A/a.mov")) == sourceBefore)
        #expect(try Data(contentsOf: s.a.appendingPathComponent("Video/b.mov")) == Data("only on b".utf8))
        #expect(try Data(contentsOf: s.a.appendingPathComponent("Video/Cam A/a.mov")) == sourceBefore)
        let after = try FileManager.default.attributesOfItem(atPath: s.a.appendingPathComponent("Video/Cam A/a.mov").path)[.modificationDate] as? Date
        #expect(after == sourceDate)
        #expect(report(env.model.syncStates[s.id])?.isInSync == true)
        guard case .inSync = env.model.syncBadge(for: s.id) else { Issue.record("expected green"); return }
        #expect(env.model.syncNotes[s.id] == nil)
    }

    @Test func syncNowNeverTouchesAConflict() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/clash.mov", "AAAA"); try write(s.b, "Video/clash.mov", "BBBB")
        try write(s.a, "Video/extra.mov", "extra")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(env.model.syncNow(shootID: s.id))
        await env.model._testSyncIdle()
        #expect(try String(contentsOf: s.a.appendingPathComponent("Video/clash.mov"), encoding: .utf8) == "AAAA")
        #expect(try String(contentsOf: s.b.appendingPathComponent("Video/clash.mov"), encoding: .utf8) == "BBBB")
        #expect(try String(contentsOf: s.b.appendingPathComponent("Video/extra.mov"), encoding: .utf8) == "extra")
        let names = try FileManager.default.contentsOfDirectory(atPath: s.b.appendingPathComponent("Video").path).sorted()
        #expect(names == ["clash.mov", "extra.mov"])
        #expect(env.model.syncBadge(for: s.id) == .outOfSync(missing: 0, conflicts: 1))
    }

    @Test func syncNowRefusesWhenMirrorSidecarIsAnotherShoot() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(env.model.syncNow(shootID: s.id))
        // The mirror turns into a different shoot before the job writes: the check sees it as not-this-shoot.
        let other = ShootSidecar(version: 1, id: UUID(), name: "S", day: "2023-11-14", createdAt: Date())
        try ShootSidecar.encode(other).write(to: s.b.appendingPathComponent(ShootSidecar.fileName))
        await env.model._testSyncIdle()
        #expect(!FileManager.default.fileExists(atPath: s.b.appendingPathComponent("Video/a.mov").path))
        guard case .failed? = env.model.syncStates[s.id] else { Issue.record("expected failed"); return }
    }

    @Test func pendingSyncIsClearedAfterACleanCheck() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip"); try write(s.b, "Video/a.mov", "clip")
        var reg = env.model.registry
        reg.setPendingSync(id: s.id, path: s.b.standardizedFileURL.path, true)
        try await ShootStore.save(reg, to: env.model.registryURL)
        await env.model.loadShoots()
        #expect(env.model.registry.records.first?.pendingSync == [s.b.standardizedFileURL.path])
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(env.model.registry.records.first?.pendingSync.isEmpty == true)
        let saved = await ShootStore.load(from: env.model.registryURL)
        #expect(saved.records.first?.pendingSync.isEmpty == true)
    }

    @Test func pendingSyncSurvivesWhileTheCopyStillMissesFiles() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        var reg = env.model.registry
        reg.setPendingSync(id: s.id, path: s.b.standardizedFileURL.path, true)
        try await ShootStore.save(reg, to: env.model.registryURL)
        await env.model.loadShoots()
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(env.model.registry.records.first?.pendingSync == [s.b.standardizedFileURL.path])
        // Sync Now fills the copy, then the follow-up check clears the hint.
        #expect(env.model.syncNow(shootID: s.id))
        await env.model._testSyncIdle()
        #expect(env.model.registry.records.first?.pendingSync.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: s.b.appendingPathComponent("Video/a.mov").path))
    }
}
