import Foundation
import Testing
@testable import Auto

@MainActor
struct AddFootageTests {
    struct Env {
        let dir: URL
        let model: AppModel
        let parent: URL
    }

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AddFootage-\(UUID().uuidString)", isDirectory: true)
        let parent = dir.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let suite = "AddFootageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        return Env(dir: dir, model: model, parent: parent)
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ url: URL, size: Int64, date: Date, camera: String = "cam") -> MediaFile {
        MediaFile(url: url, size: size, date: date, kind: .video, cameraID: camera)
    }

    private func insertCard(_ env: Env, files: [MediaFile] = [], volume: URL? = nil) -> Card {
        let card = Card(volume: volume ?? env.dir.appendingPathComponent("CARD"), name: "CARD", identity: "card-\(UUID().uuidString)")
        card.files = files
        card.missing = files
        card.phase = .needsBackup
        env.model._testInsert(card: card)
        return card
    }

    @Test func defaultSelectionIsShootDayOnly() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let other = day.addingTimeInterval(3 * 86_400)
        let a = file(URL(fileURLWithPath: "/card/A.MP4"), size: 1, date: shoot.date)
        let b = file(URL(fileURLWithPath: "/card/B.MP4"), size: 2, date: other)
        let card = insertCard(env, files: [a, b])
        let sel = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        #expect(sel.contains(a))
        #expect(!sel.contains(b))
    }

    @Test func coverageWiringStoresDoneAndCancelledIsNotStored() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let folder = env.dir.appendingPathComponent("shoot", isDirectory: true)
        let cardDir = env.dir.appendingPathComponent("cardfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Video"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        let data = Data(repeating: 7, count: 400)
        try data.write(to: cardDir.appendingPathComponent("A.MP4"))
        try data.write(to: folder.appendingPathComponent("Video/A.MP4"))
        try Data(repeating: 9, count: 300).write(to: cardDir.appendingPathComponent("B.MP4"))
        let a = file(cardDir.appendingPathComponent("A.MP4"), size: 400, date: day)
        let b = file(cardDir.appendingPathComponent("B.MP4"), size: 300, date: day)
        let key = CoverageKey(shootID: UUID(), cardID: "c")

        let task = env.model.startCoverage(key: key, files: [a, b], folder: folder, day: day)
        if case .checking? = env.model.coverage[key] {} else { Issue.record("expected checking") }
        await task.value
        guard case .done(let cov)? = env.model.coverage[key] else { Issue.record("expected done"); return }
        #expect(cov.dayTotal == 2)
        #expect(cov.dayInShoot == 1)
        #expect(cov.notInShoot.map(\.url) == [b.url])

        // A superseded check never stores its result as done.
        let first = env.model.startCoverage(key: key, files: [a, b], folder: folder, day: day)
        let second = env.model.startCoverage(key: key, files: [a], folder: folder, day: day)
        await first.value
        await second.value
        guard case .done(let cov2)? = env.model.coverage[key] else { Issue.record("expected done"); return }
        #expect(cov2.dayTotal == 1)
    }

    @Test func refusesWhenSidecarIdMismatches() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let f = file(URL(fileURLWithPath: "/card/A.MP4"), size: 1, date: shoot.date)
        let card = insertCard(env, files: [f])
        // Swap the sidecar for another shoot's id behind the model's back.
        let foreign = ShootSidecar(version: ShootSidecar.currentVersion, id: UUID(), name: "S", day: "2023-11-14", createdAt: Date())
        try ShootSidecar.encode(foreign).write(to: shoot.folder.appendingPathComponent(ShootSidecar.fileName))

        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        await #expect(throws: ShootError.sidecarMismatch) {
            try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)
        }
        #expect(card.plan == nil)
        #expect(!FileManager.default.fileExists(atPath: shoot.folder.appendingPathComponent("Video").path))
    }

    @Test func refusesWhenShootMissingOrUnknown() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let card = insertCard(env, files: [file(URL(fileURLWithPath: "/card/A.MP4"), size: 1, date: shoot.date)])
        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)

        await #expect(throws: (any Error).self) {
            try await env.model.addFootage(shootID: UUID(), cardID: card.id, cameras: [], selection: selection)
        }
        try FileManager.default.removeItem(at: shoot.folder)
        await env.model.refreshShoots()
        await #expect(throws: ShootError.shootOffline) {
            try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)
        }
        #expect(card.plan == nil)
        #expect(!FileManager.default.fileExists(atPath: shoot.folder.path))
    }

    @Test func plansIntoShootFolderSkippingVerifiedFiles() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let cardDir = env.dir.appendingPathComponent("cardfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        let data = Data(repeating: 3, count: 200)
        try data.write(to: cardDir.appendingPathComponent("A.MP4"))
        try Data(repeating: 4, count: 250).write(to: cardDir.appendingPathComponent("B.MP4"))
        try FileManager.default.createDirectory(at: shoot.folder.appendingPathComponent("Video/Old"), withIntermediateDirectories: true)
        try data.write(to: shoot.folder.appendingPathComponent("Video/Old/A.MP4"))
        let a = file(cardDir.appendingPathComponent("A.MP4"), size: 200, date: shoot.date)
        let b = file(cardDir.appendingPathComponent("B.MP4"), size: 250, date: shoot.date)
        let card = insertCard(env, files: [a, b])

        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)

        let plan = try #require(card.plan)
        #expect(plan.jobs.map(\.file.url) == [b.url])
        #expect(plan.workRoot?.standardizedFileURL == shoot.folder.standardizedFileURL)
        #expect(ShootPlanner.isInside(plan.jobs[0].destDir, root: shoot.folder))
        #expect(card.phase == .ready)
    }

    @Test func backedCardCanAddToAnotherShoot() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let cardDir = env.dir.appendingPathComponent("cardfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 120).write(to: cardDir.appendingPathComponent("A.MP4"))
        let a = file(cardDir.appendingPathComponent("A.MP4"), size: 120, date: shoot.date)
        let card = insertCard(env, files: [a])
        card.phase = .backed
        card.missing = []
        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)
        #expect(card.plan?.jobs.map(\.file.url) == [a.url])
        #expect(card.phase == .ready)
    }

    @Test func busyOrScanningCardIsRefused() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let card = insertCard(env, files: [file(URL(fileURLWithPath: "/card/A.MP4"), size: 1, date: shoot.date)])
        card.phase = .scanning
        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        await #expect(throws: (any Error).self) {
            try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)
        }
        #expect(card.plan == nil)
    }

    @Test func missingShootFolderFailsCoverage() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let key = CoverageKey(shootID: UUID(), cardID: "c")
        let task = env.model.startCoverage(key: key, files: [], folder: env.dir.appendingPathComponent("nope"), day: day)
        await task.value
        guard case .failed? = env.model.coverage[key] else { Issue.record("expected failed"); return }
    }

    @Test func forgettingShootClearsCoverage() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let key = CoverageKey(shootID: shoot.id, cardID: "c")
        let task = env.model.startCoverage(key: key, files: [], folder: shoot.folder, day: day)
        await env.model.forgetShoot(id: shoot.id)
        await task.value
        #expect(env.model.coverage[key] == nil)
    }

    @Test func cardInsideShootFolderNeverCountsAsOwnBackup() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let cardDir = shoot.folder.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        try Data(repeating: 8, count: 90).write(to: cardDir.appendingPathComponent("A.MP4"))
        let a = file(cardDir.appendingPathComponent("A.MP4"), size: 90, date: shoot.date)
        let card = insertCard(env, files: [a], volume: cardDir)

        env.model.checkCoverage(shootID: shoot.id, cardID: card.id)
        let key = CoverageKey(shootID: shoot.id, cardID: card.id)
        // checkCoverage's task is not exposed; start the same check explicitly and await it.
        let task = env.model.startCoverage(key: key, files: [a], folder: shoot.folder, day: shoot.date)
        await task.value
        guard case .done(let cov)? = env.model.coverage[key] else { Issue.record("expected done"); return }
        #expect(cov.dayInShoot == 0)
        #expect(cov.notInShoot.map(\.url) == [a.url])
    }
}
