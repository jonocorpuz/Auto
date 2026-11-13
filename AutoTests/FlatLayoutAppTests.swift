import Foundation
import Testing
@testable import Auto

/// Flat shoot layout through AppModel: creation, manual import and card ingest.
@MainActor
struct FlatLayoutAppTests {
    struct Env {
        let dir: URL
        let model: AppModel
        let parent: URL
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FlatApp-\(UUID().uuidString)", isDirectory: true)
        let parent = dir.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let suite = "FlatLayoutAppTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        return Env(dir: dir, model: model, parent: parent)
    }

    private func media(_ url: URL, size: Int, kind: MediaKind, date: Date, camera: String = "cam") throws -> MediaFile {
        try Data(repeating: 7, count: size).write(to: url)
        return MediaFile(url: url, size: Int64(size), date: date, kind: kind, cameraID: camera)
    }

    private func insertCard(_ env: Env, files: [MediaFile]) -> Card {
        let card = Card(volume: env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.files = files
        card.missing = files
        card.phase = .needsBackup
        env.model._testInsert(card: card)
        return card
    }

    @Test func createFlatShootWritesLayoutToSidecarAndRegistry() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "F", date: day, parents: [env.parent], layout: .flat)
        #expect(shoot.layout == .flat)
        #expect(try ShootFolders.readSidecar(in: shoot.folder)?.layout == .flat)
        #expect(env.model.registry.records.first { $0.id == shoot.id }?.layout == .flat)
        let normal = try await env.model.createShoot(name: "N", date: day, parents: [env.parent])
        #expect(normal.layout == .cameraFolders)
        #expect(env.model.registry.records.first { $0.id == normal.id }?.layout == .cameraFolders)
    }

    @Test func manualImportIntoFlatShootLandsDirectlyUnderSections() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "F", date: day, parents: [env.parent], layout: .flat)
        let drop = env.dir.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 600).write(to: drop.appendingPathComponent("clip.mp4"))
        try Data(repeating: 2, count: 300).write(to: drop.appendingPathComponent("pic.jpg"))

        let staging = env.model.beginImport(shootID: shoot.id, urls: [drop], target: .sorted)
        await staging.task?.value
        #expect(staging.phase == .ready)
        let job = try env.model.commitImport(staging)
        await job.task?.value
        guard case .done = job.phase else { Issue.record("expected done, got \(job.phase)"); return }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: shoot.folder.appendingPathComponent("Video/clip.mp4").path))
        #expect(fm.fileExists(atPath: shoot.folder.appendingPathComponent("Photo/pic.jpg").path))
    }

    @Test func cardIngestRenamesWholeSetWhenAFileCollidesOnDisk() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "F", date: day, parents: [env.parent], layout: .flat)
        let photo = shoot.folder.appendingPathComponent("Photo")
        try FileManager.default.createDirectory(at: photo, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 50).write(to: photo.appendingPathComponent("IMG_1.CR3"))
        let cardDir = env.dir.appendingPathComponent("cardfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        let raw = try media(cardDir.appendingPathComponent("IMG_1.CR3"), size: 80, kind: .photo, date: shoot.date)
        let jpg = try media(cardDir.appendingPathComponent("IMG_1.JPG"), size: 40, kind: .photo, date: shoot.date)
        let card = insertCard(env, files: [raw, jpg])

        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)

        let plan = try #require(card.plan)
        #expect(plan.jobs.allSatisfy { $0.destDir.standardizedFileURL == photo.standardizedFileURL })
        #expect(Set(plan.jobs.map { $0.requestedName }) == ["IMG_1 2.CR3", "IMG_1 2.JPG"])
    }

    @Test func cameraFolderShootStillSortsIntoCameraFolders() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "N", date: day, parents: [env.parent])
        let cardDir = env.dir.appendingPathComponent("cardfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        let a = try media(cardDir.appendingPathComponent("A.MP4"), size: 60, kind: .video, date: shoot.date)
        let card = insertCard(env, files: [a])

        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)

        let job = try #require(card.plan?.jobs.first)
        #expect(job.destDir.standardizedFileURL != shoot.folder.appendingPathComponent("Video").standardizedFileURL)
        #expect(job.destDir.deletingLastPathComponent().lastPathComponent == "Video")
    }
}
