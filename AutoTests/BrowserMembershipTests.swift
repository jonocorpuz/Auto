import Foundation
import Testing
@testable import Auto

@MainActor
struct BrowserMembershipTests {
    struct Env {
        let dir: URL
        let model: AppModel
        let parent: URL
        let cardDir: URL
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserMembership-\(UUID().uuidString)", isDirectory: true)
        let parent = dir.appendingPathComponent("parent", isDirectory: true)
        let cardDir = dir.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        let suite = "BrowserMembershipTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(registryURL: dir.appendingPathComponent("shoots.json"), thumbnails: FakeThumbnailProvider(), defaults: defaults)
        return Env(dir: dir, model: model, parent: parent, cardDir: cardDir)
    }

    /// A card file on disk plus an identical copy in each given shoot folder.
    private func makeFile(_ env: Env, _ name: String, byte: UInt8, copiedTo shoots: [Shoot]) throws -> MediaFile {
        let data = Data(repeating: byte, count: 400)
        let url = env.cardDir.appendingPathComponent(name)
        try data.write(to: url)
        for shoot in shoots {
            let dir = shoot.folder.appendingPathComponent("Video", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name))
        }
        return MediaFile(url: url, size: 400, date: day, kind: .video, cameraID: "cam")
    }

    private func insertCard(_ env: Env, files: [MediaFile], phase: CardPhase = .backed, backups: [URL: URL] = [:]) -> Card {
        let card = Card(volume: env.cardDir, name: "CARD", identity: "card-\(UUID().uuidString)")
        card.files = files
        card.backups = backups
        card.missing = []
        card.phase = phase
        env.model._testInsert(card: card)
        return card
    }

    private func isDone(_ state: BrowserMembershipState?) -> Bool {
        if case .done? = state { true } else { false }
    }

    @Test func browsedSettledCardGroupsFileUnderBothShoots() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s1 = try await env.model.createShoot(name: "One", date: day, parent: env.parent)
        let s2 = try await env.model.createShoot(name: "Two", date: day, parent: env.parent)
        let a = try makeFile(env, "A.MP4", byte: 3, copiedTo: [s1, s2])
        let card = insertCard(env, files: [a], backups: [a.url: s1.folder.appendingPathComponent("Video/A.MP4")])

        env.model.browsingCardID = card.id
        env.model.browserAppeared(card.id)
        await env.model._testBrowserMembershipIdle()

        #expect(isDone(env.model.browserMembership[s1.id]))
        #expect(isDone(env.model.browserMembership[s2.id]))
        let groups = env.model.browserGroups(for: card)
        #expect(groups.map(\.kind).contains(.shoot(s1.id)))
        #expect(groups.map(\.kind).contains(.shoot(s2.id)))
        #expect(!groups.map(\.kind).contains(.notBackedUp))
        #expect(!groups.map(\.kind).contains(.elsewhere))
        // Reveal uses each shoot's own verified copy.
        let copies = env.model.browserBackupCopies([a], in: .shoot(s2.id)).map { $0.standardizedFileURL.path }
        #expect(copies.count == 1)
        #expect(copies[0].hasPrefix(s2.folder.standardizedFileURL.path))
    }

    @Test func closingBrowserCancelsAndClears() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s1 = try await env.model.createShoot(name: "One", date: day, parent: env.parent)
        let a = try makeFile(env, "A.MP4", byte: 3, copiedTo: [s1])
        let card = insertCard(env, files: [a])
        env.model.browsingCardID = card.id
        env.model.browserAppeared(card.id)
        #expect(env.model.browserMembership[s1.id] == .checking)

        env.model.browserDisappeared(card.id)
        await env.model._testBrowserMembershipIdle()
        #expect(env.model.browserMembership.isEmpty)

        // Leaving the Media browser the other way (browsing nothing) clears too.
        env.model.browserAppeared(card.id)
        env.model.browsingCardID = nil
        await env.model._testBrowserMembershipIdle()
        #expect(env.model.browserMembership.isEmpty)
    }

    @Test func disappearClearsOnlyMatchingCard() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s1 = try await env.model.createShoot(name: "One", date: day, parent: env.parent)
        let a = try makeFile(env, "A.MP4", byte: 3, copiedTo: [s1])
        let card = insertCard(env, files: [a])
        env.model.browsingCardID = card.id
        env.model.browserAppeared(card.id)
        env.model.browserDisappeared("some-other-card")
        await env.model._testBrowserMembershipIdle()
        #expect(isDone(env.model.browserMembership[s1.id]))
    }

    @Test func notStartedWhileVerifyingOrCopying() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s1 = try await env.model.createShoot(name: "One", date: day, parent: env.parent)
        let a = try makeFile(env, "A.MP4", byte: 3, copiedTo: [s1])
        let card = insertCard(env, files: [a], phase: .verifying)
        env.model.browsingCardID = card.id
        env.model.browserAppeared(card.id)
        await env.model._testBrowserMembershipIdle()
        #expect(env.model.browserMembership[s1.id] == .checking)

        card.phase = .copying
        env.model.refreshBrowserMembership(force: true)
        await env.model._testBrowserMembershipIdle()
        #expect(env.model.browserMembership[s1.id] == .checking)

        card.phase = .backed
        env.model.refreshBrowserMembership()
        await env.model._testBrowserMembershipIdle()
        #expect(isDone(env.model.browserMembership[s1.id]))
    }

    @Test func switchingCardDropsStaleResults() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s1 = try await env.model.createShoot(name: "One", date: day, parent: env.parent)
        let a = try makeFile(env, "A.MP4", byte: 3, copiedTo: [s1])
        let b = try makeFile(env, "B.MP4", byte: 5, copiedTo: [])
        let first = insertCard(env, files: [a])
        let second = insertCard(env, files: [b])

        env.model.browsingCardID = first.id
        env.model.browserAppeared(first.id)
        env.model.browsingCardID = second.id
        env.model.browserAppeared(second.id)
        await env.model._testBrowserMembershipIdle()

        // Only the second card's result is stored: its file has no copy in the shoot.
        guard case .done(let urls, _)? = env.model.browserMembership[s1.id] else { Issue.record("expected done"); return }
        #expect(urls.isEmpty)
        #expect(!urls.contains(a.url))
    }

    @Test func offlineShootHasNoMembershipAndFallsBack() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let offlineID = UUID()
        let record = ShootRecord(id: offlineID, name: "Gone", day: "2023-11-14",
                                 path: "/Volumes/NoSuchVolume-\(UUID().uuidString)/Gone", lastSeen: Date())
        try await ShootStore.save(ShootRegistry(records: [record]), to: env.model.registryURL)
        await env.model.loadShoots()
        guard case .offline? = env.model.shoots.first?.availability else { Issue.record("expected offline"); return }

        let a = try makeFile(env, "A.MP4", byte: 3, copiedTo: [])
        // The card's verified copy lives under the offline shoot's path.
        let copy = URL(fileURLWithPath: record.path).appendingPathComponent("Video/A.MP4")
        let card = insertCard(env, files: [a], backups: [a.url: copy])
        env.model.browsingCardID = card.id
        env.model.browserAppeared(card.id)
        await env.model._testBrowserMembershipIdle()

        #expect(env.model.browserMembership[offlineID] == nil)
        #expect(env.model.browserGroups(for: card).map(\.kind) == [.shoot(offlineID)])
    }

    @Test func browserRunDoesNotDisturbAddFootageCoverage() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.dir) }
        let s1 = try await env.model.createShoot(name: "One", date: day, parent: env.parent)
        let a = try makeFile(env, "A.MP4", byte: 3, copiedTo: [s1])
        let card = insertCard(env, files: [a])
        let key = CoverageKey(shootID: s1.id, cardID: card.id)

        let task = env.model.startCoverage(key: key, files: [a], folder: s1.folder, day: day)
        env.model.browsingCardID = card.id
        env.model.browserAppeared(card.id)
        env.model.browserDisappeared(card.id)
        env.model.browserAppeared(card.id)
        await env.model._testBrowserMembershipIdle()
        await task.value

        guard case .done(let cov)? = env.model.coverage[key] else { Issue.record("expected coverage done"); return }
        #expect(cov.dayInShoot == 1)
        #expect(isDone(env.model.browserMembership[s1.id]))
    }
}
