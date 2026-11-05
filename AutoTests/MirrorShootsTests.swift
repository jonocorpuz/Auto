import Foundation
import Testing
@testable import Auto

/// AppModel mirror behaviour. Every temp folder shares one real volume, so distinct "drives" are faked:
/// a path under a folder named volA / volB / volC reports that volume id.
@MainActor
struct MirrorShootsTests {
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

    private func makeEnv(fake: Bool = true) throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorShoots-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let vols = ["volA", "volB", "volC"].map { dir.appendingPathComponent($0, isDirectory: true) }
        for v in vols { try fm.createDirectory(at: v, withIntermediateDirectories: true) }
        let suite = "MirrorShootsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        if fake { model.volumeIDProvider = Self.fakeProvider }
        return Env(dir: dir, model: model, volA: vols[0], volB: vols[1], volC: vols[2])
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ env: Env, _ id: UUID) throws -> ShootRecord {
        try #require(env.model.registry.records.first { $0.id == id })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func sidecarID(_ folder: URL) throws -> UUID? {
        try ShootFolders.readSidecar(in: folder)?.id
    }

    // MARK: Create on many drives

    @Test func createOnTwoParentsRegistersPathAndMirrorWithSameSidecar() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let rec = try record(env, shoot.id)
        #expect(rec.mirrors.count == 1)
        #expect(rec.pendingSync.isEmpty)
        let primary = URL(fileURLWithPath: rec.path)
        let mirror = URL(fileURLWithPath: rec.mirrors[0])
        #expect(primary.lastPathComponent == "S" && mirror.lastPathComponent == "S")
        #expect(primary.pathComponents.contains("volA") && mirror.pathComponents.contains("volB"))
        #expect(try sidecarID(primary) == shoot.id)
        #expect(try sidecarID(mirror) == shoot.id)
        let a = try Data(contentsOf: primary.appendingPathComponent(ShootSidecar.fileName))
        let b = try Data(contentsOf: mirror.appendingPathComponent(ShootSidecar.fileName))
        #expect(a == b)
        guard case .online(let resolved)? = env.model.shoots.first?.availability else { Issue.record("expected online"); return }
        #expect(resolved.mirrors.count == 1)
        #expect(env.model.shoots.first?.copies.count == 2)
    }

    @Test func parentsOnTheSameVolumeAreRefused() async throws {
        let env = try makeEnv(fake: false); defer { try? FileManager.default.removeItem(at: env.dir) }
        // Real provider: all temp folders share one volume.
        await #expect(throws: ShootError.sameVolumeAsCopy) {
            try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        }
        #expect(env.model.registry.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.volA.appendingPathComponent("S").path))
    }

    @Test func partialCreateRegistersWhatExistsAndThrows() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let volB = env.volB
        // The second parent vanishes after validation looked at it.
        env.model.volumeIDProvider = { url in
            if url.pathComponents.contains("volB") { try? FileManager.default.removeItem(at: volB) }
            return Self.fakeProvider(url)
        }
        do {
            _ = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
            Issue.record("expected partialCreate")
        } catch ShootError.partialCreate(let created, let failed) {
            #expect(created == ["volA"])
            #expect(failed.map(\.name) == ["volB"])
        }
        let rec = try #require(env.model.registry.records.first)
        #expect(rec.mirrors.isEmpty)
        #expect(rec.path.hasSuffix("/volA/S"))
        #expect(try sidecarID(URL(fileURLWithPath: rec.path)) == rec.id)
    }

    @Test func singleParentWrapperStillWorks() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "One", date: day, parent: env.volA)
        #expect(try record(env, shoot.id).mirrors.isEmpty)
    }

    // MARK: Add Mirror

    @Test func addMirrorCreatesFolderAndMarksPending() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try await env.model.addMirror(shootID: shoot.id, parent: env.volB)
        let rec = try record(env, shoot.id)
        #expect(rec.mirrors.count == 1)
        #expect(rec.pendingSync == rec.mirrors)
        #expect(try sidecarID(URL(fileURLWithPath: rec.mirrors[0])) == shoot.id)
        guard case .online(let resolved)? = env.model.shoots.first?.availability else { Issue.record("expected online"); return }
        #expect(resolved.copies.count == 2)
    }

    @Test func addMirrorOnTheSameVolumeIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let sub = env.volA.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        await #expect(throws: ShootError.sameVolumeAsCopy) {
            try await env.model.addMirror(shootID: shoot.id, parent: sub)
        }
        #expect(try record(env, shoot.id).mirrors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sub.appendingPathComponent("S").path))
    }

    @Test func plainFolderNeedsAdopt() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let existing = env.volB.appendingPathComponent("S", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let keep = existing.appendingPathComponent("keep.txt")
        try Data("hello".utf8).write(to: keep)

        await #expect(throws: ShootError.folderExistsWithoutSidecar("S")) {
            try await env.model.addMirror(shootID: shoot.id, parent: env.volB)
        }
        #expect(try ShootFolders.readSidecar(in: existing) == nil)
        #expect(try record(env, shoot.id).mirrors.isEmpty)

        try await env.model.addMirror(shootID: shoot.id, parent: env.volB, adopt: true)
        #expect(try sidecarID(existing) == shoot.id)
        #expect(try Data(contentsOf: keep) == Data("hello".utf8))
        #expect(try record(env, shoot.id).mirrors.count == 1)
    }

    @Test func folderAlreadyCarryingThisShootIsLinkedWithoutAWrite() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let sidecar = try #require(try ShootFolders.readSidecar(in: shoot.folder))
        let copy = try ShootFolders.createCopy(of: sidecar, parent: env.volB, cardVolumes: [])
        let before = try Data(contentsOf: copy.appendingPathComponent(ShootSidecar.fileName))
        try await env.model.addMirror(shootID: shoot.id, parent: env.volB)
        #expect(try Data(contentsOf: copy.appendingPathComponent(ShootSidecar.fileName)) == before)
        #expect(try record(env, shoot.id).mirrors.count == 1)
    }

    @Test func folderOfAnotherShootIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let other = try ShootFolders.create(name: "S", date: day, parent: env.volB, cardVolumes: [], calendar: env.model.calendar)
        await #expect(throws: ShootError.alreadyAShoot(other.id)) {
            try await env.model.addMirror(shootID: shoot.id, parent: env.volB)
        }
        #expect(try record(env, shoot.id).mirrors.isEmpty)
    }

    @Test func mirrorInsideAnotherRegisteredShootIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let host = try await env.model.createShoot(name: "Host", date: day, parent: env.volB)
        await #expect(throws: ShootError.alreadyRegistered) {
            try await env.model.addMirror(shootID: shoot.id, parent: host.folder)
        }
        #expect(!FileManager.default.fileExists(atPath: host.folder.appendingPathComponent("S").path))
    }

    @Test func addMirrorToOfflineShootThrows() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        try FileManager.default.removeItem(at: shoot.folder.appendingPathComponent(ShootSidecar.fileName))
        await env.model.refreshShoots()
        await #expect(throws: ShootError.shootOffline) {
            try await env.model.addMirror(shootID: shoot.id, parent: env.volB)
        }
    }

    // MARK: Backed by a mirror

    @Test func cardFileVerifiedOnlyInMirrorCountsAsBacked() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let cardFiles = env.dir.appendingPathComponent("c1", isDirectory: true)
        try FileManager.default.createDirectory(at: cardFiles, withIntermediateDirectories: true)
        let url = cardFiles.appendingPathComponent("A.MP4")
        try Data(repeating: 5, count: 100).write(to: url)
        let file = MediaFile(url: url, size: 100, date: day, kind: .video, cameraID: "cam")
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.files = [file]
        card.missing = [file]
        card.phase = .needsBackup
        env.model._testInsert(card: card)

        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        // The footage exists only in a hand-made copy on the other drive.
        let existing = env.volB.appendingPathComponent("S/Video/cam", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 100).write(to: existing.appendingPathComponent("A.MP4"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(card.phase != .backed)

        try await env.model.addMirror(shootID: shoot.id, parent: env.volB, adopt: true)
        try await waitUntil { card.phase == .backed }
        #expect(card.phase == .backed)
        #expect(card.backups[url]?.pathComponents.contains("volB") == true)
    }

    @Test func duplicatesLookInMirrorRootsToo() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let t = try await env.model.createShoot(name: "T", date: day, parent: env.volC)
        let mirrorFolder = URL(fileURLWithPath: try record(env, s.id).mirrors[0], isDirectory: true)
        let dest = mirrorFolder.appendingPathComponent("Video/cam", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 100).write(to: dest.appendingPathComponent("A.MP4"))

        let cardURL = env.dir.appendingPathComponent("c/A.MP4")
        let file = MediaFile(url: cardURL, size: 100, date: day, kind: .video, cameraID: "cam")
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.files = [file]
        card.backups = [cardURL: dest.appendingPathComponent("A.MP4")]
        card.missing = []
        card.phase = .backed
        env.model._testInsert(card: card)

        let report = env.model.duplicates(shootID: t.id, cardID: card.id)
        #expect(report.count == 1)
        #expect(report.byPlace.first?.place.shootID == s.id)
    }

    // MARK: Relocate / remove copy

    @Test func relocateCopyMovesAMirrorAndChecksSidecar() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let oldMirror = try record(env, shoot.id).mirrors[0]
        let moved = env.volC.appendingPathComponent("S", isDirectory: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: oldMirror), to: moved)

        // A folder with another shoot's sidecar is refused.
        let impostor = try ShootFolders.create(name: "Imp", date: day, parent: env.volC, cardVolumes: [], calendar: env.model.calendar)
        await #expect(throws: ShootError.sidecarMismatch) {
            try await env.model.relocateCopy(shootID: shoot.id, from: oldMirror, to: impostor.folder)
        }
        try await env.model.relocateCopy(shootID: shoot.id, from: oldMirror, to: moved)
        let rec = try record(env, shoot.id)
        #expect(rec.mirrors.count == 1)
        #expect(rec.mirrors[0].hasSuffix("/volC/S"))
        #expect(env.model.shoots.first?.copies.allSatisfy { $0.availability == .online } == true)
    }

    @Test func relocateCopyOntoAnotherCopysDriveIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let oldMirror = try record(env, shoot.id).mirrors[0]
        let sidecar = try #require(try ShootFolders.readSidecar(in: shoot.folder))
        let sub = env.volA.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let twin = try ShootFolders.createCopy(of: sidecar, parent: sub, cardVolumes: [])
        await #expect(throws: ShootError.sameVolumeAsCopy) {
            try await env.model.relocateCopy(shootID: shoot.id, from: oldMirror, to: twin)
        }
        #expect(try record(env, shoot.id).mirrors == [oldMirror])
    }

    @Test func relocateCopyOntoAnExistingCopyPathIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let oldMirror = try record(env, shoot.id).mirrors[0]
        await #expect(throws: ShootError.alreadyRegistered) {
            try await env.model.relocateCopy(shootID: shoot.id, from: oldMirror, to: shoot.folder)
        }
    }

    @Test func removeCopyKeepsFilesAndRefusesTheLastCopy() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let mirror = try record(env, shoot.id).mirrors[0]
        try await env.model.removeCopy(shootID: shoot.id, path: mirror)
        let rec = try record(env, shoot.id)
        #expect(rec.mirrors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: mirror).appendingPathComponent(ShootSidecar.fileName).path))
        await #expect(throws: ShootError.lastCopy) {
            try await env.model.removeCopy(shootID: shoot.id, path: rec.path)
        }
        #expect(try record(env, shoot.id).path == rec.path)
    }

    @Test func volumeIdentityUsesTheProvider() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        #expect(await env.model.volumeIdentity(of: env.volB) == "volB")
        let real = try makeEnv(fake: false); defer { try? FileManager.default.removeItem(at: real.dir) }
        #expect(await real.model.volumeIdentity(of: real.volA) != nil)
    }
}
