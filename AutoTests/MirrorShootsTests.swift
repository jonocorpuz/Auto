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

// MARK: Ingest fan-out to every online copy

extension MirrorShootsTests {
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

    private func plan(_ env: Env, _ card: Card, into shoot: Shoot) async throws {
        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)
        // Let the card's verdict see the shoot now, so a later shoot refresh doesn't re-verify it mid-test
        // (that flips a failed card back to ready at a random moment).
        env.model.rebuildIndex()
        try await Task.sleep(for: .milliseconds(150))
    }

    private func settled(_ card: Card) -> Bool { card.engine == nil && card.phase != .copying }

    private func mp4s(_ folder: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".MP4") }.sorted()
    }

    @Test func twoOnlineCopiesBothGetVerifiedFilesAndSeedChecksums() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let card = try ingestCard(env, "CARD", [("A.MP4", 1), ("B.MP4", 2)])
        try await plan(env, card, into: shoot)
        #expect(card.plan?.jobs.count == 4)
        #expect(card.plan?.copyRoots.count == 2)
        env.model.copy(card)
        try await waitUntil { settled(card) && card.phase == .backed }
        let rec = try record(env, shoot.id)
        let copies = [URL(fileURLWithPath: rec.path), URL(fileURLWithPath: rec.mirrors[0])]
        for copy in copies { #expect(mp4s(copy) == ["Video/CARD/A.MP4", "Video/CARD/B.MP4"]) }
        for name in ["A.MP4", "B.MP4"] {
            let a = try Data(contentsOf: copies[0].appendingPathComponent("Video/CARD/\(name)"))
            let b = try Data(contentsOf: copies[1].appendingPathComponent("Video/CARD/\(name)"))
            #expect(a == b && a.count == 100)
        }
        #expect(card.plan == nil && card.missing.isEmpty)
        #expect(rec.pendingSync.isEmpty && card.mirrorNote == nil)
        // The cache is seeded off main without the copy waiting for it.
        try await waitUntil { env.model.checksums.count == 4 }
        #expect(env.model.checksums.count == 4)
    }

    @Test func mirrorGoneBeforeTheCopyLeavesPrimaryCompleteAndMarksSync() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        let mirror = try #require(shoot.mirrors.first)
        try FileManager.default.removeItem(at: mirror)
        env.model.copy(card)
        try await waitUntil { settled(card) && card.phase == .backed }
        #expect(mp4s(shoot.folder) == ["Video/CARD/A.MP4"])
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
        #expect(card.plan == nil && card.missing.isEmpty && card.phase == .backed)
        let rec = try record(env, shoot.id)
        #expect(rec.pendingSync == [mirror.standardizedFileURL.path])
        #expect(card.mirrorNote?.contains("sync") == true)
    }

    @Test func offlineMirrorIsSkippedAndMarkedPending() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        var reg = env.model.registry
        try reg.addMirror(id: shoot.id, path: "/Volumes/NoSuch/S")
        reg.setPendingSync(id: shoot.id, path: "/Volumes/NoSuch/S", false)
        try await ShootStore.save(reg, to: env.model.registryURL)
        await env.model.loadShoots()
        #expect(try record(env, shoot.id).pendingSync.isEmpty)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        #expect(card.plan?.copyRoots.count == 1)
        env.model.copy(card)
        try await waitUntil { settled(card) && card.phase == .backed }
        #expect(mp4s(shoot.folder) == ["Video/CARD/A.MP4"])
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/NoSuch"))
        #expect(try record(env, shoot.id).pendingSync == ["/Volumes/NoSuch/S"])
        #expect(card.mirrorNote?.contains("NoSuch") == true)
    }

    @Test func onlyTheMirrorOnlineReceivesTheCopyAndPrimaryIsMarkedPending() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        let primary = shoot.folder
        let mirror = try #require(shoot.mirrors.first)
        try FileManager.default.removeItem(at: primary.appendingPathComponent(ShootSidecar.fileName))
        await env.model.refreshShoots()
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        #expect(card.plan?.copyRoots.map(\.standardizedFileURL.path) == [mirror.standardizedFileURL.path])
        env.model.copy(card)
        try await waitUntil { settled(card) && card.phase == .backed }
        #expect(mp4s(mirror) == ["Video/CARD/A.MP4"])
        #expect(mp4s(primary).isEmpty)
        #expect(try record(env, shoot.id).pendingSync == [primary.standardizedFileURL.path])
    }

    // MARK: Queueing

    /// Shoot S plus two cards holding the same bytes (A, B), both planned into S.
    private func queueScenario(_ env: Env) async throws -> (shoot: Shoot, card1: Card, card2: Card) {
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let card1 = try ingestCard(env, "CARD1", [("A.MP4", 1), ("B.MP4", 2)])
        let card2 = try ingestCard(env, "CARD2", [("A.MP4", 1), ("B.MP4", 2)])
        try await plan(env, card1, into: shoot)
        try await plan(env, card2, into: shoot)
        return (shoot, card1, card2)
    }

    @Test func secondCardWaitsThenStartsByItselfAndItsTwinsArePruned() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let sc = try await queueScenario(env)
        env.model.copy(sc.card1)
        env.model.copy(sc.card2)
        #expect(sc.card2.engine == nil && sc.card2.phase == .ready)
        #expect(sc.card2.queuedBehind == sc.card1.id)
        #expect(sc.card2.queueNote == "Waiting for CARD1 to finish")
        try await waitUntil { sc.card2.queuedBehind == nil && settled(sc.card1) && settled(sc.card2) && sc.card2.phase == .backed }
        #expect(sc.card2.phase == .backed && sc.card2.plan == nil && sc.card2.queueNote == nil)
        // Only card 1's copies exist: card 2's twins were pruned when it started.
        #expect(mp4s(sc.shoot.folder) == ["Video/CARD1/A.MP4", "Video/CARD1/B.MP4"])
    }

    @Test func stoppingAQueuedCardDequeuesItAndItNeverStarts() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let sc = try await queueScenario(env)
        env.model.copy(sc.card1)
        env.model.copy(sc.card2)
        #expect(sc.card2.queuedBehind != nil)
        env.model.stop(sc.card2)
        #expect(sc.card2.queuedBehind == nil && sc.card2.queueNote == nil)
        #expect(sc.card2.plan != nil && sc.card2.phase == .ready)
        try await waitUntil { settled(sc.card1) && sc.card1.phase == .backed }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sc.card2.engine == nil && sc.card2.plan != nil)
        #expect(mp4s(sc.shoot.folder) == ["Video/CARD1/A.MP4", "Video/CARD1/B.MP4"])
    }
}

// MARK: Review follow-ups

extension MirrorShootsTests {
    private func twoCopyShoot(_ env: Env) async throws -> (shoot: Shoot, mirror: URL) {
        let shoot = try await env.model.createShoot(name: "S", date: day, parents: [env.volA, env.volB])
        return (shoot, try #require(shoot.mirrors.first))
    }

    private func pending(_ env: Env, _ id: UUID) throws -> [String] { try record(env, id).pendingSync }

    @Test func fileVerifiedOnlyInMirrorPrunedAtCopyTimeMarksThePrimary() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        // The footage turns up in a hand-made copy on the other drive, which then becomes a mirror.
        let existing = env.volB.appendingPathComponent("S/Video/CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: existing.appendingPathComponent("A.MP4"))
        try await env.model.addMirror(shootID: shoot.id, parent: env.volB, adopt: true)
        let url = card.files[0].url
        try await waitUntil { card.backups[url] != nil && card.verifier == nil && card.phase != .scanning }
        env.model.copy(card)
        try await waitUntil { settled(card) && card.plan == nil }
        #expect(mp4s(shoot.folder).isEmpty)
        #expect(try pending(env, shoot.id).contains(shoot.folder.standardizedFileURL.path))
        #expect(card.mirrorNote != nil)
    }

    @Test func staleMirrorRootInAPlanIsDroppedAtCopyTime() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        #expect(card.plan?.copyRoots.count == 2)
        var reg = env.model.registry
        try reg.removeCopy(id: shoot.id, path: mirror.standardizedFileURL.path)
        try await ShootStore.save(reg, to: env.model.registryURL)
        await env.model.loadShoots()
        env.model.copy(card)
        try await waitUntil { settled(card) && card.plan == nil }
        #expect(mp4s(shoot.folder) == ["Video/CARD/A.MP4"])
        #expect(mp4s(mirror).isEmpty)
    }

    @Test func removingACopyDropsIdlePlansAndIsRefusedWhileQueuedOrCopying() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card1 = try ingestCard(env, "CARD1", [("A.MP4", 1)])
        let card2 = try ingestCard(env, "CARD2", [("B.MP4", 2)])
        try await plan(env, card1, into: shoot)
        try await plan(env, card2, into: shoot)
        env.model.copy(card1)
        env.model.copy(card2)
        #expect(card2.queuedBehind != nil)
        await #expect(throws: AppModel.ShootBusyError.self) {
            try await env.model.removeCopy(shootID: shoot.id, path: mirror.path)
        }
        try await waitUntil { settled(card1) && card2.queuedBehind == nil && settled(card2) && card2.plan == nil }
        // Idle plans carry the copy as a root, so removing it drops them.
        let card3 = try ingestCard(env, "CARD3", [("C.MP4", 3)])
        try await plan(env, card3, into: shoot)
        #expect(card3.plan != nil)
        try await env.model.removeCopy(shootID: shoot.id, path: mirror.path)
        #expect(card3.plan == nil)
    }

    @Test func checksumFailureOnOneCopyKeepsTheFileAndFailsTheCard() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        let dir = mirror.appendingPathComponent("Video/CARD", isDirectory: true)
        env.model._testEngineHook = { engine in
            engine.onChunkWritten = { _ in
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".auto-partial") {
                    if let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent(name)) {
                        try? handle.write(contentsOf: Data([0xFF]))
                        try? handle.close()
                    }
                }
            }
        }
        env.model.copy(card)
        try await waitUntil { settled(card) }
        if case .failed = card.phase {} else { Issue.record("expected failed, got \(card.phase)") }
        #expect(card.plan?.jobs.count == 2)
        #expect(mp4s(mirror).isEmpty)
        #expect(card.missing.count == 1)
    }

    @Test func differingChecksumsAcrossCopiesBlockTheFile() {
        let file = MediaFile(url: URL(fileURLWithPath: "/c/A.MP4"), size: 1, date: day, kind: .video, cameraID: "cam")
        let other = MediaFile(url: URL(fileURLWithPath: "/c/B.MP4"), size: 1, date: day, kind: .video, cameraID: "cam")
        func copied(_ f: MediaFile, _ root: String, _ sum: UInt8) -> CopiedFile {
            CopiedFile(file: f, destination: URL(fileURLWithPath: "/\(root)/\(f.url.lastPathComponent)"), destinationModified: nil,
                       preexisting: false, checksum: Data([sum]))
        }
        var outcome = CopyOutcome()
        outcome.copied = [copied(file, "a", 1), copied(file, "b", 2), copied(other, "a", 3), copied(other, "b", 3)]
        #expect(AppModel.integrityBlocked(outcome) == [file.url])
        outcome.failures = [.init(name: "B.MP4", reason: "x", file: other.url, root: nil, kind: .destination)]
        #expect(AppModel.integrityBlocked(outcome) == [file.url])
        outcome.failures.append(.init(name: "B.MP4", reason: "x", file: other.url, root: nil, kind: .integrity))
        #expect(AppModel.integrityBlocked(outcome) == [file.url, other.url])
    }

    @Test func mirrorGoneMidRunStillLeavesTheCardBackedAndMarksSync() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1), ("B.MP4", 2)])
        try await plan(env, card, into: shoot)
        env.model._testEngineHook = { engine in
            engine.onChunkWritten = { _ in try? FileManager.default.removeItem(at: mirror) }
        }
        env.model.copy(card)
        try await waitUntil { settled(card) && card.phase == .backed }
        #expect(card.phase == .backed && card.plan == nil)
        #expect(mp4s(shoot.folder) == ["Video/CARD/A.MP4", "Video/CARD/B.MP4"])
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
        #expect(try pending(env, shoot.id) == [mirror.standardizedFileURL.path])
        #expect(card.mirrorNote != nil)
    }

    @Test func fileFailingOnEveryCopyFailsTheCardAndKeepsItsJobs() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1), ("B.MP4", 2)])
        try await plan(env, card, into: shoot)
        // Corrupt every partial on both copies. The shoot stays online, so nothing discards the plan behind the
        // test's back (removing the roots let refreshShoots drop the plan, racing the assertion below).
        let dirs = [shoot.folder, mirror].map { $0.appendingPathComponent("Video/CARD", isDirectory: true) }
        env.model._testEngineHook = { engine in
            engine.onChunkWritten = { _ in
                for dir in dirs {
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".auto-partial") {
                        if let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent(name)) {
                            try? handle.write(contentsOf: Data([0xFF]))
                            try? handle.close()
                        }
                    }
                }
            }
        }
        env.model.copy(card)
        try await waitUntil { settled(card) }
        if case .failed = card.phase {} else { Issue.record("expected failed, got \(card.phase)") }
        let names = card.plan?.jobs.map { $0.file.url.lastPathComponent + "@" + ($0.root?.lastPathComponent ?? "") }
        #expect(card.plan?.jobs.count == 4, "phase \(card.phase) jobs \(String(describing: names)) note \(String(describing: card.mirrorNote))")
        #expect(card.missing.count == 2)
    }

    @Test func blockedFileIsNeverRecordedAsVerifiedNorPrunedOnRetry() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1), ("B.MP4", 2)])
        try await plan(env, card, into: shoot)
        // Corrupt only the mirror's partials: the primary copy verifies, the mirror fails its checksum.
        let dir = mirror.appendingPathComponent("Video/CARD", isDirectory: true)
        env.model._testEngineHook = { engine in
            engine.onChunkWritten = { _ in
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".auto-partial") {
                    if let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent(name)) {
                        try? handle.write(contentsOf: Data([0xFF]))
                        try? handle.close()
                    }
                }
            }
        }
        env.model.copy(card)
        try await waitUntil { settled(card) }
        if case .failed = card.phase {} else { Issue.record("expected failed, got \(card.phase)") }
        #expect(card.plan?.jobs.isEmpty == false)
        // Blocked files must not be remembered as verified copies, so no later recompute can lean on them.
        #expect(env.model._testSessionCopyDestinations.isEmpty)
        env.model.discardPlan(card)
        try await Task.sleep(for: .milliseconds(300))
        try await waitUntil { settled(card) && card.phase != .verifying }
        #expect(env.model._testSessionCopyDestinations.isEmpty)
    }

    @Test func cardQueuedBehindAFailingCardIsReleased() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let sc = try await queueScenario(env)
        let folder = sc.shoot.folder
        env.model._testEngineHook = { engine in
            engine.onChunkWritten = { _ in try? FileManager.default.removeItem(at: folder) }
        }
        env.model.copy(sc.card1)
        env.model.copy(sc.card2)
        #expect(sc.card2.queuedBehind == sc.card1.id)
        try await waitUntil { settled(sc.card1) && sc.card2.queuedBehind == nil }
        #expect(sc.card2.queuedBehind == nil && sc.card2.queueNote == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sc.card2.phase != .copying && sc.card2.engine == nil)
    }

    @Test func removingAQueuedCardLeavesNothingToStart() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let sc = try await queueScenario(env)
        env.model.copy(sc.card1)
        env.model.copy(sc.card2)
        #expect(sc.card2.queuedBehind != nil)
        env.model._testVolumesChanged(cards: [])
        #expect(sc.card2.queuedBehind == nil && sc.card2.queueNote == nil)
        try await waitUntil { sc.card1.engine == nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sc.card2.engine == nil)
        #expect(!mp4s(sc.shoot.folder).contains { $0.contains("CARD2") })
    }

    @Test func discardingOrReplanningAQueuedCardNeverAutoStarts() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let sc = try await queueScenario(env)
        // Hold card 1's copy open while card 2 is re-planned.
        env.model._testEngineHook = { engine in engine.onChunkWritten = { _ in Thread.sleep(forTimeInterval: 0.5) } }
        env.model.copy(sc.card1)
        env.model.copy(sc.card2)
        env.model.discardPlan(sc.card2)
        #expect(sc.card2.queuedBehind == nil && sc.card2.plan == nil)
        // Plan again while card 1 still copies, queue, then re-plan over the queued plan.
        try await plan(env, sc.card2, into: sc.shoot)
        env.model.copy(sc.card2)
        #expect(sc.card2.queuedBehind != nil)
        try await plan(env, sc.card2, into: sc.shoot)
        #expect(sc.card2.queuedBehind == nil && sc.card2.queueNote == nil)
        try await waitUntil { settled(sc.card1) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sc.card2.engine == nil && sc.card2.phase != .copying)
        #expect(!mp4s(sc.shoot.folder).contains { $0.contains("CARD2") })
    }

    @Test func queuedCardsNeverRunConcurrently() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let cards = try [("CARD1", "A.MP4", UInt8(1)), ("CARD2", "B.MP4", 2), ("CARD3", "C.MP4", 3)].map {
            try ingestCard(env, $0.0, [($0.1, $0.2)])
        }
        for card in cards { try await plan(env, card, into: shoot) }
        for card in cards { env.model.copy(card) }
        var maxRunning = 0
        for _ in 0..<600 {
            maxRunning = max(maxRunning, cards.filter { $0.engine != nil }.count)
            if cards.allSatisfy({ $0.plan == nil && $0.engine == nil && $0.queuedBehind == nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(maxRunning == 1)
        #expect(mp4s(shoot.folder) == ["Video/CARD1/A.MP4", "Video/CARD2/B.MP4", "Video/CARD3/C.MP4"])
    }

    @Test func aCopyWithoutSpaceIsDroppedWhileAnotherTakesTheFiles() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        env.model._testFreeSpace = { url in url.pathComponents.contains("volB") ? 10 : nil }
        env.model.copy(card)
        try await waitUntil { settled(card) && card.plan == nil }
        #expect(mp4s(shoot.folder) == ["Video/CARD/A.MP4"])
        #expect(mp4s(mirror).isEmpty)
        #expect(try pending(env, shoot.id) == [mirror.standardizedFileURL.path])
        #expect(card.mirrorNote != nil)
    }

    @Test func checksumsAreWrittenToDisk() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.volA)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        try await plan(env, card, into: shoot)
        env.model.copy(card)
        let file = env.dir.appendingPathComponent("checksums.json")
        try await waitUntil { FileManager.default.fileExists(atPath: file.path) }
        let reread = ChecksumStore(url: file)
        await reread.load()
        #expect(reread.count == 1)
    }

    @Test func flatCopyIntoAShootFolderMarksTheOtherCopies() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let (shoot, mirror) = try await twoCopyShoot(env)
        let card = try ingestCard(env, "CARD", [("A.MP4", 1)])
        let extra = shoot.folder.appendingPathComponent("Extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        card.plan = ShootPlanner.flatPlan(missing: card.missing, into: extra)
        card.phase = .ready
        env.model.copy(card)
        try await waitUntil { settled(card) && card.plan == nil }
        #expect(FileManager.default.fileExists(atPath: extra.appendingPathComponent("A.MP4").path))
        #expect(try pending(env, shoot.id) == [mirror.standardizedFileURL.path])
    }
}
