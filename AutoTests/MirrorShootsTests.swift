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
        // Validation passes (the parent exists and the name is free), then the second drive turns read-only,
        // so creating the mirror fails after the primary exists.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.volB.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.volB.path) }
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
        try await waitUntil { card.verifier == nil && card.phase != .scanning }
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

    // MARK: Stale plans, busy, failover

    /// A card with one real file and a pending add-footage plan into `shoot`.
    private func cardWithPlan(_ env: Env, shoot: Shoot) async throws -> Card {
        let cardFiles = env.dir.appendingPathComponent("c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cardFiles, withIntermediateDirectories: true)
        let url = cardFiles.appendingPathComponent("P.MP4")
        try Data(repeating: 3, count: 100).write(to: url)
        let file = MediaFile(url: url, size: 100, date: shoot.date, kind: .video, cameraID: "cam")
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.files = [file]
        card.missing = [file]
        card.phase = .needsBackup
        env.model._testInsert(card: card)
        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)
        #expect(card.plan != nil)
        return card
    }

    @Test func removingThePrimaryCancelsCoverageAndThePlan() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let card = try await cardWithPlan(env, shoot: shoot)
        let key = CoverageKey(shootID: shoot.id, cardID: card.id)
        #expect(env.model.coverage[key] != nil)
        try await env.model.removeCopy(shootID: shoot.id, path: try record(env, shoot.id).path)
        #expect(card.plan == nil)
        #expect(env.model.coverage[key] == nil)
    }

    @Test func refusedRemoveCopyLeavesThePlanIntact() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let card = try await cardWithPlan(env, shoot: shoot)
        await #expect(throws: ShootError.lastCopy) {
            try await env.model.removeCopy(shootID: shoot.id, path: shoot.folder.path)
        }
        #expect(card.plan != nil)
        #expect(env.model.coverage[CoverageKey(shootID: shoot.id, cardID: card.id)] != nil)
    }

    @Test func relocatingThePrimaryDiscardsThePlan() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let card = try await cardWithPlan(env, shoot: shoot)
        let old = try record(env, shoot.id).path
        let moved = env.volC.appendingPathComponent("S", isDirectory: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: old), to: moved)
        try await env.model.relocateCopy(shootID: shoot.id, from: old, to: moved)
        #expect(card.plan == nil)
    }

    @Test func failoverToTheMirrorDiscardsThePlan() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let card = try await cardWithPlan(env, shoot: shoot)
        try FileManager.default.moveItem(at: shoot.folder, to: env.volA.appendingPathComponent("S.gone"))
        await env.model.refreshShoots()
        #expect(card.plan == nil)
        guard case .online(let now)? = env.model.shoots.first?.availability else { Issue.record("expected online"); return }
        #expect(now.folder.pathComponents.contains("volB"))
        #expect(now.mirrors.isEmpty)
    }

    // MARK: Card volumes, nil ids, duplicates

    private func insertCardVolume(_ env: Env) throws -> URL {
        let volume = env.dir.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let card = Card(volume: volume, name: "CARD", identity: "card-\(UUID().uuidString)")
        env.model._testInsert(card: card)
        return volume
    }

    @Test func cardVolumesAreRefusedEverywhere() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let volume = try insertCardVolume(env)
        let sub = volume.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        await #expect(throws: ShootError.onCard) {
            try await env.model.addMirror(shootID: shoot.id, parent: sub)
        }
        let sidecar = try #require(try ShootFolders.readSidecar(in: shoot.folder))
        let onCard = try ShootFolders.createCopy(of: sidecar, parent: sub, cardVolumes: [])
        await #expect(throws: ShootError.onCard) {
            try await env.model.relocateCopy(shootID: shoot.id, from: try record(env, shoot.id).mirrors[0], to: onCard)
        }
        await #expect(throws: ShootError.onCard) {
            try await env.model.createShoot(name: "T", date: day, parents: [env.volC, sub])
        }
        #expect(!FileManager.default.fileExists(atPath: env.volC.appendingPathComponent("T").path))
    }

    @Test func nilVolumeIdRefusesAddMirrorAndRelocate() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        env.model.volumeIDProvider = { _ in nil }
        await #expect(throws: ShootError.parentMissing) {
            try await env.model.addMirror(shootID: shoot.id, parent: env.volC)
        }
        let sidecar = try #require(try ShootFolders.readSidecar(in: shoot.folder))
        let twin = try ShootFolders.createCopy(of: sidecar, parent: env.volC, cardVolumes: [])
        await #expect(throws: ShootError.parentMissing) {
            try await env.model.relocateCopy(shootID: shoot.id, from: try record(env, shoot.id).mirrors[0], to: twin)
        }
        #expect(try record(env, shoot.id).mirrors.count == 1)
    }

    @Test func duplicateParentsAreRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        await #expect(throws: ShootError.sameVolumeAsCopy) {
            try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volA])
        }
        #expect(env.model.registry.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.volA.appendingPathComponent("S").path))
    }

    @Test func onlyTheMirrorOnlineMakesItTheShootFolder() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        try FileManager.default.removeItem(at: shoot.folder.appendingPathComponent(ShootSidecar.fileName))
        await env.model.refreshShoots()
        guard case .online(let now)? = env.model.shoots.first?.availability else { Issue.record("expected online"); return }
        #expect(now.folder.standardizedFileURL.path == URL(fileURLWithPath: try record(env, shoot.id).mirrors[0]).standardizedFileURL.path)
        #expect(now.mirrors.isEmpty)
    }

    // MARK: Mismatch and same-volume copies are not backup places

    enum BadMirror: Sendable { case sameVolume, mismatch }

    /// Shoot S on volA plus a registered "mirror" that resolves as `kind`, holding the card's A.MP4. The
    /// card's B.MP4 sits in a healthy shoot T, so waiting for B to be verified proves the check settled.
    private func badMirrorScenario(_ env: Env, kind: BadMirror) async throws -> (card: Card, a: URL, s: Shoot, t: Shoot, bad: URL) {
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let t = try ShootFolders.create(name: "T", date: day, parent: env.volC, cardVolumes: [], calendar: env.model.calendar)
        let bad: URL
        switch kind {
        case .sameVolume:
            let sidecar = try #require(try ShootFolders.readSidecar(in: s.folder))
            let sub = env.volA.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            bad = try ShootFolders.createCopy(of: sidecar, parent: sub, cardVolumes: [])
        case .mismatch:
            bad = try ShootFolders.create(name: "S", date: day, parent: env.volB, cardVolumes: [], calendar: env.model.calendar).folder
        }
        let cardFiles = env.dir.appendingPathComponent("cf", isDirectory: true)
        try FileManager.default.createDirectory(at: cardFiles, withIntermediateDirectories: true)
        var files: [MediaFile] = []
        for (name, byte, dir) in [("A.MP4", UInt8(1), bad), ("B.MP4", UInt8(2), t.folder)] {
            let url = cardFiles.appendingPathComponent(name)
            try Data(repeating: byte, count: 100).write(to: url)
            let dest = dir.appendingPathComponent("Video/cam", isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try Data(repeating: byte, count: 100).write(to: dest.appendingPathComponent(name))
            files.append(MediaFile(url: url, size: 100, date: day, kind: .video, cameraID: "cam"))
        }
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.files = files
        card.missing = files
        card.phase = .needsBackup
        env.model._testInsert(card: card)

        // Register straight through the registry file, bypassing addMirror's refusals.
        var reg = env.model.registry
        reg.add(ShootRecord(id: t.id, name: "T", day: ShootSidecar.dayString(day, calendar: env.model.calendar),
                            path: t.folder.standardizedFileURL.path, lastSeen: Date()))
        try reg.addMirror(id: s.id, path: bad.standardizedFileURL.path)
        try await ShootStore.save(reg, to: env.model.registryURL)
        await env.model.loadShoots()
        let item = try #require(env.model.shoots.first { $0.id == s.id })
        let state = try #require(item.copies.first { $0.path == bad.standardizedFileURL.path })
        switch kind {
        case .sameVolume:
            if case .sameVolume = state.availability {} else { Issue.record("expected sameVolume, got \(state.availability)") }
        case .mismatch: #expect(state.availability == .mismatch)
        }
        return (card, files[0].url, s, Shoot(id: t.id, name: "T", date: day, folder: t.folder), bad)
    }

    @Test(arguments: [BadMirror.sameVolume, .mismatch])
    func badMirrorDoesNotCountAsBacked(kind: BadMirror) async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let sc = try await badMirrorScenario(env, kind: kind)
        let b = sc.card.files[1].url
        try await waitUntil { sc.card.backups[b] != nil && sc.card.verifier == nil }
        #expect(sc.card.backups[b] != nil)
        #expect(sc.card.backups[sc.a] == nil)
        #expect(sc.card.phase != .backed)
        // And as a duplicate place: a verdict pointing into it is not reported.
        sc.card.backups[sc.a] = sc.bad.appendingPathComponent("Video/cam/A.MP4")
        sc.card.missing = [sc.card.files[0]]
        let report = env.model.duplicates(shootID: sc.t.id, cardID: sc.card.id)
        #expect(!report.files.contains { $0.url == sc.a })
    }
}
