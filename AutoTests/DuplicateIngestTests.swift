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

    private func waitUntil(_ what: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        if !condition() { Issue.record("timed out waiting for \(what)") }
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

    private func makeScenario(extraOnCard2: [(String, UInt8)] = [], card2Verifying: Bool = false) async throws -> Scenario {
        let env = try makeEnv()
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let t = try await env.model.createShoot(name: "T", date: day, parent: env.parent)
        let content: [(String, UInt8)] = [("A.MP4", 1), ("B.MP4", 2)]
        let files1 = try makeFiles(env.dir.appendingPathComponent("c1"), content, camera: "camA")
        let files2 = try makeFiles(env.dir.appendingPathComponent("c2"), content + extraOnCard2, camera: "camB")
        let card1 = insertCard(env, files: files1, name: "CARD1")
        let card2 = insertCard(env, files: files2, name: "CARD2")
        if card2Verifying {
            // A verifier is already running on card 2 when card 1's copy lands.
            card2.verifier = BackupVerifier()
            card2.phase = .verifying
        }
        try await copyFiles(env, card: card1, into: s)
        // The automatic recompute verifies card 2's twins against the copies in S.
        let expected = content.count
        try await waitUntil("card 2 verdict") { card2.backups.count == expected && card2.verifier == nil && card2.phase != .verifying }
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
        // A different file already sits at A.MP4's destination: it must survive, the copy gets a unique name.
        let jobA = try #require(sc.card2.plan?.jobs.first { $0.file.url.lastPathComponent == "A.MP4" })
        let occupied = jobA.destDir.appendingPathComponent("A.MP4")
        try Data(repeating: 9, count: 100).write(to: occupied)
        sc.env.model.copy(sc.card2)
        try await waitUntil("copy to finish") { settled(sc.card2) }
        #expect(try Data(contentsOf: occupied) == Data(repeating: 9, count: 100))
        let names = try mp4s(in: sc.t).map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(names.count == 3)
        #expect(names.contains("B.MP4"))
        #expect(try mp4s(in: sc.s) == before)
    }

    @Test func cardWithVerifierRunningIsRecomputedAfterAnotherCardsCopy() async throws {
        let sc = try await makeScenario(card2Verifying: true)
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        #expect(sc.card2.backups.count == 2)
        try await waitUntil("card 2 backed") { sc.card2.phase == .backed }
    }

    @Test func backedCardIsNotRecomputedAndUnrelatedCardIsLeftAlone() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let files1 = try makeFiles(env.dir.appendingPathComponent("c1"), [("A.MP4", 1)], camera: "camA")
        let unrelated = try makeFiles(env.dir.appendingPathComponent("c2"), [("Z.MP4", 5)], camera: "camB")
        let card1 = insertCard(env, files: files1, name: "CARD1")
        let card2 = insertCard(env, files: unrelated, name: "CARD2")
        let card3 = insertCard(env, files: files1, name: "CARD3")
        card3.phase = .backed
        card3.missing = []
        try await copyFiles(env, card: card1, into: s)
        try await Task.sleep(for: .milliseconds(300))
        #expect(card3.phase == .backed)
        #expect(card3.backups.isEmpty)   // never recomputed
        #expect(card2.backups.isEmpty)   // no shared name+size key
    }

    @Test func pendingAddPlanSurvivesAnotherCardsCopyAndIsPrunedAtCopyTime() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let t = try await env.model.createShoot(name: "T", date: day, parent: env.parent)
        let files1 = try makeFiles(env.dir.appendingPathComponent("c1"), [("A.MP4", 1)], camera: "camA")
        let files2 = try makeFiles(env.dir.appendingPathComponent("c2"), [("A.MP4", 1), ("C.MP4", 3)], camera: "camB")
        let card1 = insertCard(env, files: files1, name: "CARD1")
        let card2 = insertCard(env, files: files2, name: "CARD2")
        // Card 2 plans both files into T before card 1's copy lands.
        let selection = ShootSelection(missing: card2.files, cameras: [], calendar: env.model.calendar)
        try await env.model.addFootage(shootID: t.id, cardID: card2.id, cameras: [], selection: selection)
        #expect(card2.plan?.jobs.count == 2)
        try await copyFiles(env, card: card1, into: s)
        try await waitUntil("card 2 verdict") { card2.backups[files2[0].url] != nil && card2.verifier == nil }
        #expect(card2.phase == .ready)
        #expect(card2.plan?.jobs.count == 2)

        // Copy-time pruning: the twin is now a verified duplicate, so only C.MP4 is written.
        env.model.copy(card2)
        try await waitUntil("copy to finish") { settled(card2) }
        #expect(try mp4s(in: t).map { ($0 as NSString).lastPathComponent } == ["C.MP4"])
    }

    @Test func allDuplicatePlanIsClearedAtCopyTime() async throws {
        let sc = try await makeScenario()
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        // A plan made (as if before the verdict existed) with every file now a duplicate.
        let jobs = ShootPlanner.jobs(missing: sc.card2.files, shoot: sc.t.folder, cameras: [], fallback: "CARD2")
        try ShootPlanner.createDirectories(ShootPlanner.directories(for: jobs), root: sc.t.folder, cardVolumes: [])
        sc.card2.plan = ShootPlanner.plan(jobs: jobs, shoot: sc.t.folder, workRoot: sc.t.folder)
        sc.card2.phase = .ready
        sc.env.model.copy(sc.card2)
        try await waitUntil("pruned plan cleared") { sc.card2.plan == nil && sc.card2.engine == nil }
        #expect(try mp4s(in: sc.t).isEmpty)
    }

    @Test func copyRefusedWhileAnotherCardCopiesIntoOverlappingFolder() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let files1 = try makeFiles(env.dir.appendingPathComponent("c1"), [("A.MP4", 1)], camera: "camA")
        let files2 = try makeFiles(env.dir.appendingPathComponent("c2"), [("B.MP4", 2)], camera: "camB")
        let card1 = insertCard(env, files: files1, name: "CARD1")
        let card2 = insertCard(env, files: files2, name: "CARD2")
        let selection1 = env.model.shootSheetDefaults(shootID: s.id, cardID: card1.id)
        try await env.model.addFootage(shootID: s.id, cardID: card1.id, cameras: [], selection: selection1)
        // Card 2's plan into the same shoot exists already (made before card 1 started).
        let jobs = ShootPlanner.jobs(missing: files2, shoot: s.folder, cameras: [], fallback: "CARD2")
        card2.plan = ShootPlanner.plan(jobs: jobs, shoot: s.folder, workRoot: s.folder)
        card2.phase = .ready
        env.model.copy(card1)
        env.model.copy(card2)
        // Queued, not failed: it waits in its ready state and starts by itself.
        #expect(card2.engine == nil)
        #expect(card2.phase == .ready)
        #expect(card2.queuedBehind == card1.id)
        #expect(card2.plan != nil)
        try await waitUntil("both copies to finish") { settled(card1) && card2.queuedBehind == nil && card2.plan == nil && settled(card2) }
        #expect(try mp4s(in: s) == ["Video/CARD1/A.MP4", "Video/CARD2/B.MP4"])
    }

    @Test func planAppearingDuringAddFootageIsNotReplaced() async throws {
        let sc = try await makeScenario(extraOnCard2: [("C.MP4", 3)])
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        let selection = ShootSelection(missing: sc.card2.files, cameras: [], calendar: sc.env.model.calendar)
        let model = sc.env.model, tID = sc.t.id, cardID = sc.card2.id
        let task = Task { try await model.addFootage(shootID: tID, cardID: cardID, cameras: [], selection: selection) }
        await Task.yield()
        // A Choose Folder plan lands while add-footage is awaiting.
        let other = sc.env.dir.appendingPathComponent("chosen")
        sc.card2.plan = CopyPlan(jobs: [], destinationLabel: "chosen", destinationRoot: other, workRoot: nil)
        let result = await task.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect(sc.card2.plan?.destinationLabel == "chosen")
    }

    @Test func duplicateWhoseCopyIsOfflineOrChangedInPlaceIsCopiedAgain() async throws {
        let sc = try await makeScenario()
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        let a = sc.twins[0], b = sc.twins[1]
        // A's recorded copy is on a drive that isn't mounted.
        sc.card2.backups[a.url] = URL(fileURLWithPath: "/Volumes/NotMountedDrive/Shoot/A.MP4")
        // B's copy changed in place (same size, different bytes and mtime).
        let copyB = try #require(sc.card2.backups[b.url])
        try Data(repeating: 7, count: 100).write(to: copyB)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: copyB.path)
        let selection = ShootSelection(missing: sc.card2.files, cameras: [], calendar: sc.env.model.calendar)
        try await sc.env.model.addFootage(shootID: sc.t.id, cardID: sc.card2.id, cameras: [], selection: selection)
        #expect(Set(sc.card2.plan?.jobs.map { $0.file.url.lastPathComponent } ?? []) == ["A.MP4", "B.MP4"])
    }

    @Test func duplicatesExcludeFilesAlreadyVerifiedInTargetOnceCoverageIsDone() async throws {
        let sc = try await makeScenario()
        defer { try? FileManager.default.removeItem(at: sc.env.dir) }
        // Pretend the verdict points at copies outside any shoot; S also holds identical copies (from card 1).
        let elsewhere = sc.env.dir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for f in sc.twins {
            let url = elsewhere.appendingPathComponent(f.url.lastPathComponent)
            try FileManager.default.copyItem(at: f.url, to: url)
            sc.card2.backups[f.url] = url
        }
        let model = sc.env.model
        #expect(model.duplicates(shootID: sc.s.id, cardID: sc.card2.id).count == 2)   // provisional
        let key = CoverageKey(shootID: sc.s.id, cardID: sc.card2.id)
        await model.startCoverage(key: key, files: sc.card2.files, folder: sc.s.folder, day: sc.s.date).value
        #expect(model.duplicates(shootID: sc.s.id, cardID: sc.card2.id).count == 0)
        #expect(model.duplicates(shootID: sc.t.id, cardID: sc.card2.id).count == 2)
        // An explicit selection narrows the candidates.
        #expect(model.duplicates(shootID: sc.t.id, cardID: sc.card2.id, candidates: [sc.twins[0]]).count == 1)
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
        #expect(sc.card2.backups.count == 2)
        // Delete card 1's copies in S (never the card): the recorded verdict is now stale.
        for name in try mp4s(in: sc.s) { try FileManager.default.removeItem(at: sc.s.folder.appendingPathComponent(name)) }
        let selection = ShootSelection(missing: sc.card2.files, cameras: [], calendar: sc.env.model.calendar)
        try await sc.env.model.addFootage(shootID: sc.t.id, cardID: sc.card2.id, cameras: [], selection: selection)
        #expect(sc.card2.plan?.jobs.count == 2)
    }

    @Test func planningWhileAnotherCardCopiesQueuesAndPrunesTwinsAtCopyTime() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s = try await env.model.createShoot(name: "S", date: day, parent: env.parent)
        let files1 = try makeFiles(env.dir.appendingPathComponent("c1"), [("A.MP4", 1)], camera: "camA")
        let files2 = try makeFiles(env.dir.appendingPathComponent("c2"), [("A.MP4", 1), ("B.MP4", 2)], camera: "camB")
        let card1 = insertCard(env, files: files1, name: "CARD1")
        let card2 = insertCard(env, files: files2, name: "CARD2")
        let selection1 = env.model.shootSheetDefaults(shootID: s.id, cardID: card1.id)
        try await env.model.addFootage(shootID: s.id, cardID: card1.id, cameras: [], selection: selection1)
        // Hold card 1's copy open so card 2 is planned and started while it is still running.
        env.model._testEngineHook = { engine in engine.onChunkWritten = { _ in Thread.sleep(forTimeInterval: 0.6) } }
        env.model.copy(card1)
        #expect(card1.engine != nil)
        #expect(env.model.isCopyingInto(shootID: s.id) === card1)

        // Planning is allowed while card 1 copies; the copy queues and skips card 1's twin at copy time.
        let selection2 = env.model.shootSheetDefaults(shootID: s.id, cardID: card2.id)
        try await env.model.addFootage(shootID: s.id, cardID: card2.id, cameras: [], selection: selection2)
        #expect(card2.plan != nil)
        env.model.copy(card2)
        #expect(card2.queuedBehind == card1.id)
        try await waitUntil("both to finish") { settled(card1) && settled(card2) && card2.queuedBehind == nil && card2.plan == nil }
        #expect(try mp4s(in: s) == ["Video/CARD1/A.MP4", "Video/CARD2/B.MP4"])
        #expect(env.model.isCopyingInto(shootID: s.id) == nil)
    }
}
