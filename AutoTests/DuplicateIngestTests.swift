import Foundation
import Testing
@testable import Auto

@MainActor
struct DuplicateIngestTests {
    struct Env {
        let dir: URL
        let model: AppModel
        let parent: URL
    }

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DupIngest-\(UUID().uuidString)", isDirectory: true)
        let parent = dir.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let suite = "DuplicateIngestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        return Env(dir: dir, model: model, parent: parent)
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    /// Writes `contents` (name -> byte value, 100 bytes each) under `dir` and returns the matching card files.
    private func makeFiles(_ dir: URL, _ contents: [(String, UInt8)], camera: String) throws -> [MediaFile] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try contents.map { name, byte in
            let url = dir.appendingPathComponent(name)
            try Data(repeating: byte, count: 100).write(to: url)
            return MediaFile(url: url, size: 100, date: day, kind: .video, cameraID: camera)
        }
    }

    private func insertCard(_ env: Env, files: [MediaFile], name: String) -> Card {
        let card = Card(volume: env.dir.appendingPathComponent(name), name: name, identity: "card-\(UUID().uuidString)")
        card.files = files
        card.missing = files
        card.phase = .needsBackup
        env.model._testInsert(card: card)
        return card
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func settled(_ card: Card) -> Bool { card.engine == nil && card.phase != .copying }

    private func copyFiles(_ env: Env, card: Card, into shoot: Shoot) async throws {
        let selection = env.model.shootSheetDefaults(shootID: shoot.id, cardID: card.id)
        try await env.model.addFootage(shootID: shoot.id, cardID: card.id, cameras: [], selection: selection)
        env.model.copy(card)
        try await waitUntil { settled(card) }
    }

    private func mp4s(in shoot: Shoot) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: shoot.folder.path)
            .filter { $0.hasSuffix(".MP4") }.sorted()
    }

    /// Card 1 copied into S; card 2 holds identical bytes (different camera) and a second shoot T is the target.
    private struct Scenario {
        let env: Env
        let s: Shoot
        let t: Shoot
        let card1: Card
        let card2: Card
        let twins: [MediaFile]
    }

    private func makeScenario(extraOnCard2: [(String, UInt8)] = []) async throws -> Scenario {
        let env = try makeEnv()
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let t = try await env.model.createShoot(name: "T", date: day, parent: env.parent)
        let content: [(String, UInt8)] = [("A.MP4", 1), ("B.MP4", 2)]
        let files1 = try makeFiles(env.dir.appendingPathComponent("c1"), content, camera: "camA")
        let files2 = try makeFiles(env.dir.appendingPathComponent("c2"), content + extraOnCard2, camera: "camB")
        let card1 = insertCard(env, files: files1, name: "CARD1")
        let card2 = insertCard(env, files: files2, name: "CARD2")
        try await copyFiles(env, card: card1, into: s)
        // The automatic recompute verifies card 2's twins against the copies in S.
        let expected = content.count
        try await waitUntil { card2.backups.count == expected && card2.verifier == nil && card2.phase != .verifying }
        return Scenario(env: env, s: s, t: t, card1: card1, card2: card2, twins: Array(files2.prefix(content.count)))
    }

    @Test func twinsArePlannedAsNoJobsAndMixedKeepsOnlyNewFiles() async throws {
        let sc = try await makeScenario(extraOnCard2: [("C.MP4", 3)])
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        #expect(sc.card2.backups.count == 2)
        let report = sc.env.model.duplicates(shootID: sc.t.id, cardID: sc.card2.id)
        #expect(report.count == 2)
        #expect(report.byPlace.first?.place.shootID == sc.s.id)

        let selection = ShootSelection(missing: sc.card2.files, cameras: [], calendar: sc.env.model.calendar)
        try await sc.env.model.addFootage(shootID: sc.t.id, cardID: sc.card2.id, cameras: [], selection: selection)
        let plan = try #require(sc.card2.plan)
        #expect(plan.jobs.map { $0.file.url.lastPathComponent } == ["C.MP4"])
    }

    @Test func allTwinsThrowAllDuplicatesError() async throws {
        let sc = try await makeScenario()
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        let selection = ShootSelection(missing: sc.card2.files, cameras: [], calendar: sc.env.model.calendar)
        await #expect(throws: AppModel.AllDuplicatesError.self) {
            try await sc.env.model.addFootage(shootID: sc.t.id, cardID: sc.card2.id, cameras: [], selection: selection)
        }
        #expect(sc.card2.plan == nil)
    }

    @Test func includeDuplicatesCopiesTwinsWithoutOverwriting() async throws {
        let sc = try await makeScenario()
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        let before = try mp4s(in: sc.s)
        let selection = ShootSelection(missing: sc.card2.files, cameras: [], calendar: sc.env.model.calendar)
        try await sc.env.model.addFootage(shootID: sc.t.id, cardID: sc.card2.id, cameras: [], selection: selection,
                                          includeDuplicates: true)
        #expect(sc.card2.plan?.jobs.count == 2)
        sc.env.model.copy(sc.card2)
        try await waitUntil { settled(sc.card2) }
        #expect(try mp4s(in: sc.t).map { ($0 as NSString).lastPathComponent } == ["A.MP4", "B.MP4"])
        #expect(try mp4s(in: sc.s) == before)
    }

    @Test func card2BecomesBackedThroughAutomaticRecompute() async throws {
        let sc = try await makeScenario()
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        try await waitUntil { sc.card2.phase == .backed }
        #expect(sc.card2.phase == .backed)
        #expect(sc.card2.missing.isEmpty)
    }

    @Test func twinWhoseCopyVanishedIsCopiedAgain() async throws {
        let sc = try await makeScenario()
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        // Delete card 1's copies in S (never the card): the recorded verdict is now stale.
        for name in try mp4s(in: sc.s) { try FileManager.default.removeItem(at: sc.s.folder.appendingPathComponent(name)) }
        let selection = ShootSelection(missing: sc.card2.files, cameras: [], calendar: sc.env.model.calendar)
        try await sc.env.model.addFootage(shootID: sc.t.id, cardID: sc.card2.id, cameras: [], selection: selection)
        #expect(sc.card2.plan?.jobs.count == 2)
    }

    @Test func shootBusyWhileAnotherCardCopiesIntoIt() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let files1 = try makeFiles(env.dir.appendingPathComponent("c1"), [("A.MP4", 1)], camera: "camA")
        let files2 = try makeFiles(env.dir.appendingPathComponent("c2"), [("B.MP4", 2)], camera: "camB")
        let card1 = insertCard(env, files: files1, name: "CARD1")
        let card2 = insertCard(env, files: files2, name: "CARD2")
        let selection1 = env.model.shootSheetDefaults(shootID: s.id, cardID: card1.id)
        try await env.model.addFootage(shootID: s.id, cardID: card1.id, cameras: [], selection: selection1)
        env.model.copy(card1)
        #expect(card1.engine != nil)

        let selection2 = env.model.shootSheetDefaults(shootID: s.id, cardID: card2.id)
        await #expect(throws: AppModel.ShootBusyError.self) {
            try await env.model.addFootage(shootID: s.id, cardID: card2.id, cameras: [], selection: selection2)
        }
        #expect(card2.plan == nil)
        try await waitUntil { settled(card1) }
    }
}
