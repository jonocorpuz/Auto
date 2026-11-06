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
        let volC: URL
    }

    nonisolated private static let fakeProvider: @Sendable (URL) -> String? = { url in
        for name in ["volA", "volB", "volC"] where url.pathComponents.contains(name) { return name }
        return nil
    }

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncNow-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let vols = ["volA", "volB", "volC"].map { dir.appendingPathComponent($0, isDirectory: true) }
        for v in vols { try fm.createDirectory(at: v, withIntermediateDirectories: true) }
        let suite = "SyncNowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        model.volumeIDProvider = Self.fakeProvider
        model.syncDebounce = .zero
        return Env(dir: dir, model: model, volA: vols[0], volB: vols[1], volC: vols[2])
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

    private func ingestCard(_ env: Env, _ name: String, _ contents: [(String, UInt8)]) throws -> Card {
        let dir = env.dir.appendingPathComponent("cf-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try contents.map { fileName, byte -> MediaFile in
            let url = dir.appendingPathComponent(fileName)
            try Data(repeating: byte, count: 100).write(to: url)
            return MediaFile(url: url, size: 100, date: day, kind: .video, cameraID: "cam")
        }
        let card = Card(volume: env.dir.appendingPathComponent(name), name: name, identity: "card-\(UUID().uuidString)")
        card.files = files
        card.missing = files
        card.phase = .needsBackup
        env.model._testInsert(card: card)
        return card
    }

    private func plan(_ env: Env, _ card: Card, into id: UUID) async throws {
        let selection = env.model.shootSheetDefaults(shootID: id, cardID: card.id)
        try await env.model.addFootage(shootID: id, cardID: card.id, cameras: [], selection: selection)
    }

    /// A checker that waits for `gate` (ignoring cancellation) on its first call, then delegates to the real one.
    private func gatedChecker(_ gate: Gate) -> SyncCheckRunner {
        { copies, cache, deep, onSize, progress in
            if gate.next() == 1 { while !gate.released { try? await Task.sleep(for: .milliseconds(5)) } }
            return await AppModel.realSyncChecker(copies, cache, deep, onSize, progress)
        }
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
        env.model.syncThrottle = .zero
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

    // MARK: Review fixes

    private func badge(_ env: Env, _ id: UUID) -> SyncBadge { env.model.syncBadge(for: id) }

    private func isGreen(_ b: SyncBadge) -> Bool {
        if case .inSync = b { return true }
        return false
    }

    @Test func greenBecomesGreyWhenAMirrorGoesOfflineWhileTheWorkerIsBusy() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(isGreen(badge(env, s.id)))
        let other = try await env.model.createShoot(name: "T", date: day, parents: [env.volA, env.volB])
        await env.model._testSyncIdle()
        let gate = Gate()
        env.model.syncChecker = gatedChecker(gate)
        env.model.checkSync(shootID: other.id)
        try await waitUntil { gate.calls == 1 }
        try FileManager.default.removeItem(at: s.b)
        await env.model.refreshShoots()
        guard case .unknown = badge(env, s.id) else { Issue.record("expected grey, got \(badge(env, s.id))"); return }
        gate.release()
        await env.model._testSyncIdle()
    }

    @Test func greenIsNotShownAfterAThirdCopyIsAdded() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(isGreen(badge(env, s.id)))
        let other = try await env.model.createShoot(name: "T", date: day, parents: [env.volA, env.volB])
        await env.model._testSyncIdle()
        let gate = Gate()
        env.model.syncChecker = gatedChecker(gate)
        env.model.checkSync(shootID: other.id)
        try await waitUntil { gate.calls == 1 }
        try await env.model.addMirror(shootID: s.id, parent: env.volC)
        #expect(!isGreen(badge(env, s.id)))
        gate.release()
        await env.model._testSyncIdle()
    }

    @Test func throttleKeysOnMountIdentity() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        let started = env.model.syncChecksStarted
        env.model.scheduleSyncCheck([s.id], force: false)
        await env.model._testSyncIdle()
        #expect(env.model.syncChecksStarted == started)
        // The same paths on a drive that mounted afresh: a different volume identity, so no throttling.
        env.model.volumeIDProvider = { url in
            for name in ["volA", "volB", "volC"] where url.pathComponents.contains(name) { return name + "-remounted" }
            return nil
        }
        env.model.scheduleSyncCheck([s.id], force: false)
        await env.model._testSyncIdle()
        #expect(env.model.syncChecksStarted == started + 1)
    }

    @Test func driveSwappedUnderTheSamePathTurnsGreyUntilRechecked() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        #expect(isGreen(badge(env, s.id)))
        let other = try await env.model.createShoot(name: "T", date: day, parents: [env.volA, env.volB])
        await env.model._testSyncIdle()
        let gate = Gate()
        env.model.syncChecker = gatedChecker(gate)
        env.model.checkSync(shootID: other.id)
        try await waitUntil { gate.calls == 1 }
        // Same paths, same availability, but the mirror's drive is a different mounted volume now.
        env.model.volumeIDProvider = { url in
            if url.pathComponents.contains("volB") { return "volB-swapped" }
            return url.pathComponents.contains("volA") ? "volA" : nil
        }
        await env.model.refreshShoots()
        guard case .unknown(let reason) = badge(env, s.id) else { Issue.record("expected grey, got \(badge(env, s.id))"); return }
        #expect(reason.contains("remounted"))
        gate.release()
        await env.model._testSyncIdle()
        #expect(isGreen(badge(env, s.id)))   // rechecked against the new volumes
    }

    @Test func ingestWaitsBehindARunningSyncNow() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: s.id)
        let gate = Gate()
        env.model.syncChecker = gatedChecker(gate)
        #expect(env.model.syncNow(shootID: s.id))
        try await waitUntil { gate.calls == 1 }
        env.model.copy(card)
        #expect(card.engine == nil)
        #expect(card.queuedBehind != nil)
        #expect(card.queueNote == "Waiting for Sync Now to finish")
        gate.release()
        await env.model._testSyncIdle()
        try await waitUntil { card.engine == nil && card.phase == .backed }
        await env.model._testSyncIdle()
        for root in [s.a, s.b] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Video/CARD/A.MP4").path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Video/a.mov").path))
        }
        #expect(report(env.model.syncStates[s.id])?.isInSync == true)
    }

    @Test func checksWaitForARunningIngestAndRunWhenItEnds() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: s.id)
        let hold = DispatchSemaphore(value: 0)
        env.model._testEngineHook = { engine in engine.onChunkWritten = { _ in hold.wait(); hold.signal() } }
        env.model.copy(card)
        #expect(env.model.syncStates[s.id] == .unknown("Copying footage…"))
        let started = env.model.syncChecksStarted
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        guard case .unknown(let reason)? = env.model.syncStates[s.id] else { Issue.record("expected unknown"); return }
        #expect(reason.contains("Waiting"))
        #expect(env.model.syncChecksStarted == started)
        #expect(env.model.syncNow(shootID: s.id) == false)
        hold.signal()
        try await waitUntil { card.engine == nil && card.phase == .backed }
        await env.model._testSyncIdle()
        #expect(report(env.model.syncStates[s.id])?.isInSync == true)
    }

    @Test func ingestThatCopiesNothingLeavesNoStuckState() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: s.id)
        try FileManager.default.removeItem(at: card.files[0].url)   // every job fails: nothing is copied
        env.model.copy(card)
        try await waitUntil { card.engine == nil && card.phase != .copying }
        await env.model._testSyncIdle()
        #expect(report(env.model.syncStates[s.id])?.isInSync == true)
    }

    @Test func stopDuringTheCheckDropsItsResult() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        let gate = Gate()
        env.model.syncChecker = gatedChecker(gate)
        env.model.checkSync(shootID: s.id)
        try await waitUntil { gate.calls == 1 }
        env.model.stopSync(shootID: s.id)
        #expect(env.model.syncStates[s.id] == .unknown("Check stopped"))
        gate.release()
        await env.model._testSyncIdle()
        #expect(env.model.syncStates[s.id] == .unknown("Check stopped"))
    }

    @Test func stopDuringPrepareWritesNothing() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        env.model._testAfterSyncPrepare = { id in env.model.stopSync(shootID: id) }
        #expect(env.model.syncNow(shootID: s.id))
        await env.model._testSyncIdle()
        #expect(!FileManager.default.fileExists(atPath: s.b.appendingPathComponent("Video/a.mov").path))
        #expect(env.model.syncStates[s.id] == .unknown("Sync stopped"))
    }

    @Test func stopDuringCopyingKeepsWhatLandedAndSkipsTheRecheck() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a1.mov", "one"); try write(s.a, "Video/a2.mov", "two")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        let hold = DispatchSemaphore(value: 0)
        env.model._testSyncEngineHook = { engine in engine.onChunkWritten = { _ in hold.wait(); hold.signal() } }
        #expect(env.model.syncNow(shootID: s.id))
        try await waitUntil { if case .syncing(let p)? = env.model.syncStates[s.id] { return p.filesTotal == 2 } else { return false } }
        env.model.stopSync(shootID: s.id)
        hold.signal()
        await env.model._testSyncIdle()
        #expect(env.model.syncStates[s.id] == .unknown("Sync stopped"))
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: s.b.appendingPathComponent("Video").path)) ?? []
        #expect(landed.filter { !$0.hasPrefix(".") }.count < 2)
        #expect(try String(contentsOf: s.a.appendingPathComponent("Video/a1.mov"), encoding: .utf8) == "one")
    }

    @Test func forgettingTheShootMidSyncWritesNothingAndLeavesNoState() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        env.model._testAfterSyncPrepare = { id in await env.model.forgetShoot(id: id) }
        #expect(env.model.syncNow(shootID: s.id))
        await env.model._testSyncIdle()
        #expect(!FileManager.default.fileExists(atPath: s.b.appendingPathComponent("Video/a.mov").path))
        #expect(env.model.syncStates[s.id] == nil)
        #expect(env.model.syncNotes[s.id] == nil)
    }

    @Test func aDifferentFileAppearingAtTheDestinationFillsSyncNotesAndIsNotOverwritten() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        let target = s.b.appendingPathComponent("Video/a.mov")
        env.model._testAfterSyncPrepare = { _ in try? Data("other".utf8).write(to: target) }
        #expect(env.model.syncNow(shootID: s.id))
        await env.model._testSyncIdle()
        #expect(env.model.syncNotes[s.id]?.contains("a.mov") == true)
        #expect(try String(contentsOf: target, encoding: .utf8) == "other")
        #expect(env.model.syncBadge(for: s.id) == .outOfSync(missing: 0, conflicts: 1))
    }

    @Test func removeAndRelocateAreRefusedWhileSyncing() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        nonisolated(unsafe) var refused = 0
        let volC = env.volC
        env.model._testAfterSyncPrepare = { id in
            do { try await env.model.removeCopy(shootID: id, path: s.b.path); Issue.record("remove should be refused") }
            catch is AppModel.ShootBusyError { refused += 1 } catch { Issue.record("unexpected \(error)") }
            do { try await env.model.relocateCopy(shootID: id, from: s.b.path, to: volC); Issue.record("relocate should be refused") }
            catch is AppModel.ShootBusyError { refused += 1 } catch { Issue.record("unexpected \(error)") }
        }
        #expect(env.model.syncNow(shootID: s.id))
        await env.model._testSyncIdle()
        #expect(refused == 2)
        #expect(FileManager.default.fileExists(atPath: s.b.appendingPathComponent("Video/a.mov").path))
    }

    @Test func nonForcedNewerRequestDuringARunningCheckSupersedesIt() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        let gate = Gate()
        env.model.syncChecker = gatedChecker(gate)
        env.model.checkSync(shootID: s.id)
        try await waitUntil { gate.calls == 1 }
        env.model.scheduleSyncCheck([s.id], force: false)
        gate.release()
        await env.model._testSyncIdle()
        #expect(gate.calls == 2)
        #expect(report(env.model.syncStates[s.id])?.isInSync == true)
    }

    @Test func syncNowSupersededDuringItsFirstCheckSaysSo() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await twoCopies(env)
        try write(s.a, "Video/a.mov", "clip")
        env.model.checkSync(shootID: s.id)
        await env.model._testSyncIdle()
        let gate = Gate()
        env.model.syncChecker = gatedChecker(gate)
        #expect(env.model.syncNow(shootID: s.id))
        try await waitUntil { gate.calls == 1 }
        env.model.scheduleSyncCheck([s.id], force: true)
        gate.release()
        await env.model._testSyncIdle()
        #expect(env.model.syncNotes[s.id]?.contains("Sync stopped") == true)
        #expect(!FileManager.default.fileExists(atPath: s.b.appendingPathComponent("Video/a.mov").path))
    }
}
