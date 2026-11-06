import CryptoKit
import Foundation
import Testing
@testable import Auto

/// Add Files through AppModel: staging, scheduling, fan-out and bookkeeping. Folders under volA/volB/volC
/// report distinct fake volumes so mirrors can exist in one temp dir.
@MainActor
struct ImportJobFlowTests {
    struct Env {
        let dir: URL
        let model: AppModel
        let volA: URL
        let volB: URL
        let source: URL
    }

    nonisolated private static let fakeProvider: @Sendable (URL) -> String? = { url in
        for name in ["volA", "volB", "volC"] where url.pathComponents.contains(name) { return name }
        return nil
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportFlow-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let vols = ["volA", "volB"].map { dir.appendingPathComponent($0, isDirectory: true) }
        let source = dir.appendingPathComponent("drop", isDirectory: true)
        for v in vols + [source] { try fm.createDirectory(at: v, withIntermediateDirectories: true) }
        let suite = "ImportJobFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        model.volumeIDProvider = Self.fakeProvider
        return Env(dir: dir, model: model, volA: vols[0], volB: vols[1], source: source)
    }

    @discardableResult
    private func write(_ name: String, count: Int, seed: UInt8, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data((0..<count).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) }).write(to: url)
        return url
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func stage(_ env: Env, shoot: Shoot, urls: [URL], target: DropTarget = .sorted) async -> ImportStaging {
        let staging = env.model.beginImport(shootID: shoot.id, urls: urls, target: target)
        await staging.task?.value
        return staging
    }

    private func files(under root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().path + "/"
        let e = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey])
        return (e?.compactMap { $0 as? URL } ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }.sorted()
    }

    // MARK: Tests

    @Test func fansOutToTwoCopiesAndLeavesSourceUntouched() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let card = try FixtureCard(); defer { card.cleanup() }
        let before = try [card.dcim.appendingPathComponent("DSC00001.JPG"), card.clip.appendingPathComponent("C0001.MP4")].map(sha)

        let staging = await stage(env, shoot: shoot, urls: [card.root])
        #expect(staging.phase == .ready)
        let job = try env.model.commitImport(staging)
        #expect(env.model.hasActiveImport(into: shoot.id))
        await job.task?.value

        guard case .done(let summary) = job.phase else { Issue.record("expected done, got \(job.phase)"); return }
        #expect(summary.copied == staging.selected.count)
        #expect(summary.note == nil)
        let a = files(under: shoot.folder).filter { $0.hasSuffix(".JPG") || $0.hasSuffix(".MP4") }
        let b = files(under: try #require(shoot.mirrors.first)).filter { $0.hasSuffix(".JPG") || $0.hasSuffix(".MP4") }
        #expect(!a.isEmpty && a == b)
        #expect(a.contains { $0.hasPrefix("Video/") } && a.contains { $0.hasPrefix("Photo/") })
        #expect(env.model.ingestRunCount == 0)
        #expect(!env.model.hasActiveImport(into: shoot.id))
        let after = try [card.dcim.appendingPathComponent("DSC00001.JPG"), card.clip.appendingPathComponent("C0001.MP4")].map(sha)
        #expect(before == after)
        #expect(FileManager.default.fileExists(atPath: card.dcim.appendingPathComponent("DSC00001.JPG").path))
    }

    @Test func offlineMirrorIsMarkedPendingSync() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let mirror = try #require(shoot.mirrors.first)
        let hidden = env.dir.appendingPathComponent("hidden")
        try FileManager.default.moveItem(at: mirror, to: hidden)
        await env.model.refreshShoots()
        let online = try #require({ () -> Shoot? in
            if case .online(let s)? = env.model.shoots.first(where: { $0.id == shoot.id })?.availability { return s }
            return nil
        }())
        #expect(online.mirrors.isEmpty)
        try write("clip.mp4", count: 500, seed: 1, in: env.source)

        let staging = await stage(env, shoot: shoot, urls: [env.source])
        let job = try env.model.commitImport(staging)
        await job.task?.value

        guard case .done(let summary) = job.phase else { Issue.record("expected done, got \(job.phase)"); return }
        #expect(summary.note != nil)
        let record = try #require(env.model.registry.records.first { $0.id == shoot.id })
        #expect(!record.pendingSync.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
    }

    @Test func duplicatesAreSkippedUnlessIncluded() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let dup = try write("a.mp4", count: 800, seed: 3, in: env.source)
        try write("b.mp4", count: 900, seed: 4, in: env.source)
        let existing = shoot.folder.appendingPathComponent("Video/Old")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dup, to: existing.appendingPathComponent("a.mp4"))

        let staging = await stage(env, shoot: shoot, urls: [env.source])
        #expect(staging.duplicates.count == 1)
        #expect(staging.selected.count == 1)
        let job = try env.model.commitImport(staging)
        await job.task?.value
        guard case .done(let summary) = job.phase else { Issue.record("expected done, got \(job.phase)"); return }
        #expect(summary.copied == 1)
        #expect(summary.skippedDuplicates == 1)
        #expect(files(under: shoot.folder).filter { $0.hasSuffix("a.mp4") } == ["Video/Old/a.mp4"])
    }

    @Test func allDuplicatesRefusedBeforeAnyWrite() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let dup = try write("a.mp4", count: 800, seed: 3, in: env.source)
        try FileManager.default.copyItem(at: dup, to: shoot.folder.appendingPathComponent("a.mp4"))
        let before = files(under: shoot.folder)
        let staging = await stage(env, shoot: shoot, urls: [env.source])
        #expect(throws: ImportRefusal.allDuplicates) { try env.model.commitImport(staging) }
        #expect(env.model.imports.isEmpty)
        #expect(files(under: shoot.folder) == before)
    }

    @Test func sourceInsideShootIsRefusedAtScan() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let inside = try write("in.mp4", count: 300, seed: 5, in: shoot.folder)
        let before = files(under: shoot.folder)
        let staging = await stage(env, shoot: shoot, urls: [inside])
        #expect(staging.items.isEmpty)
        #expect(staging.refused.count == 1)
        #expect(throws: ImportRefusal.nothingToAdd) { try env.model.commitImport(staging) }
        #expect(files(under: shoot.folder) == before)
    }

    @Test func exactTargetOutsideShootIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try write("a.mp4", count: 300, seed: 6, in: env.source)
        let staging = await stage(env, shoot: shoot, urls: [env.source], target: .exact(env.volB))
        #expect(throws: ImportRefusal.destinationNotInShoot) { try env.model.commitImport(staging) }
        #expect(env.model.imports.isEmpty)
        #expect(files(under: env.volB).isEmpty)
    }

    @Test func exactTargetCopiesFlatIntoFolder() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        try write("a.mp4", count: 300, seed: 6, in: env.source)
        let folder = shoot.folder.appendingPathComponent("Video/FX3/Day 2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = await stage(env, shoot: shoot, urls: [env.source], target: .exact(folder))
        let job = try env.model.commitImport(staging)
        await job.task?.value
        guard case .done = job.phase else { Issue.record("expected done, got \(job.phase)"); return }
        #expect(files(under: shoot.folder).contains("Video/FX3/Day 2/a.mp4"))
        #expect(files(under: try #require(shoot.mirrors.first)).contains("Video/FX3/Day 2/a.mp4"))
    }

    @Test func queuesBehindCardCopyIntoSameShoot() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try write("a.mp4", count: 300, seed: 7, in: env.source)
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.plan = ShootPlanner.plan(jobs: [], shoot: shoot.folder, workRoot: shoot.folder, roots: [shoot.folder], shootID: shoot.id)
        card.engine = CopyEngine()
        env.model._testInsert(card: card)

        let staging = await stage(env, shoot: shoot, urls: [env.source])
        let job = try env.model.commitImport(staging)
        guard case .queued = job.phase else { Issue.record("expected queued, got \(job.phase)"); return }
        #expect(job.engine == nil)
        #expect(env.model.hasActiveImport(into: shoot.id))

        card.engine = nil
        env.model.releaseQueuedCopies()
        await job.task?.value
        guard case .done = job.phase else { Issue.record("expected done, got \(job.phase)"); return }
        #expect(env.model.ingestRunCount == 0)
    }

    @Test func cardCopyQueuesBehindRunningImport() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try write("a.mp4", count: 300, seed: 7, in: env.source)
        let staging = await stage(env, shoot: shoot, urls: [env.source])
        let job = try env.model.commitImport(staging)
        #expect(env.model.importBusyOverlapping([shoot.folder]))

        let cardFile = try write("c.mp4", count: 200, seed: 9, in: env.source)
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        let media = MediaFile(url: cardFile, size: 200, date: day, kind: .video, cameraID: "x")
        card.plan = ShootPlanner.plan(jobs: ShootPlanner.jobs(missing: [media], copies: [shoot.folder], cameras: [], fallback: "CARD"),
                                      shoot: shoot.folder, workRoot: shoot.folder, roots: [shoot.folder], shootID: shoot.id)
        card.phase = .ready
        env.model._testInsert(card: card)
        env.model.copy(card)
        #expect(card.engine == nil)
        #expect(card.queuedBehind != nil)
        await job.task?.value
    }

    @Test func waitsWhileCullApplying() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try write("a.mp4", count: 300, seed: 8, in: env.source)
        let staging = await stage(env, shoot: shoot, urls: [env.source])
        env.model.cullApplying = true
        let job = try env.model.commitImport(staging)
        guard case .queued = job.phase else { Issue.record("expected queued, got \(job.phase)"); return }
        #expect(job.engine == nil)
        #expect(files(under: shoot.folder).filter { $0.hasSuffix("a.mp4") }.isEmpty)

        env.model.cullApplying = false
        env.model.releaseQueuedCopies()
        await job.task?.value
        guard case .done = job.phase else { Issue.record("expected done, got \(job.phase)"); return }
        #expect(env.model.ingestRunCount == 0)
    }

    @Test func nameClashWithDifferentBytesGetsUniqueName() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try write("a.mp4", count: 500, seed: 1, in: env.source)
        let staging0 = await stage(env, shoot: shoot, urls: [env.source])
        let first = try env.model.commitImport(staging0)
        await first.task?.value
        let landed = files(under: shoot.folder).filter { $0.hasSuffix("a.mp4") }
        #expect(landed.count == 1)

        try write("a.mp4", count: 500, seed: 2, in: env.source)   // same name and size, different bytes
        let staging = await stage(env, shoot: shoot, urls: [env.source])
        #expect(staging.duplicates.isEmpty)
        let second = try env.model.commitImport(staging)
        await second.task?.value
        #expect(files(under: shoot.folder).filter { $0.contains("a") && $0.hasSuffix(".mp4") }.count == 2)
    }

    @Test func destinationOnCardIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try write("a.mp4", count: 300, seed: 8, in: env.source)
        let staging = await stage(env, shoot: shoot, urls: [env.source])
        env.model._testInsert(card: Card(volume: env.volA, name: "CARD", identity: "card-x"))
        #expect(throws: ImportRefusal.destinationOnCard) { try env.model.commitImport(staging) }
        #expect(env.model.imports.isEmpty)
    }

    @Test func stoppingAQueuedImportCancelsIt() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try write("a.mp4", count: 300, seed: 8, in: env.source)
        let staging = await stage(env, shoot: shoot, urls: [env.source])
        env.model.cullApplying = true
        let job = try env.model.commitImport(staging)
        env.model.stopImport(job)
        #expect(job.phase == .stopped)
        env.model.cullApplying = false
        env.model.releaseQueuedCopies()
        #expect(job.engine == nil)
        env.model.dismissImport(job)
        #expect(env.model.imports.isEmpty)
    }
}
