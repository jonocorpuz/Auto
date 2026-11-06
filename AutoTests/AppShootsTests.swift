import Foundation
import Testing
@testable import Auto

@MainActor
struct AppShootsTests {
    struct Env {
        let dir: URL
        let registryURL: URL
        let model: AppModel
    }

    private func makeEnv(workRoot: URL? = nil, seedRoot: Bool = false) throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppShoots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "AppShootsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let workRoot { defaults.set(workRoot.path, forKey: "workRoot") }
        let registryURL = dir.appendingPathComponent("shoots.json")
        let model = AppModel(registryURL: registryURL, thumbnails: FakeThumbnailProvider(), defaults: defaults)
        return Env(dir: dir, registryURL: registryURL, model: model)
    }

    private func parent(in env: Env) throws -> URL {
        let p = env.dir.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }

    @Test func createShootRegistersAndPersists() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let p = try parent(in: env)
        let shoot = try await env.model.createShoot(name: "Wedding", date: Date(), parent: p)

        #expect(FileManager.default.fileExists(atPath: shoot.folder.appendingPathComponent(ShootSidecar.fileName).path))
        #expect(env.model.shoots.map(\.id) == [shoot.id])
        let saved = await ShootStore.load(from: env.registryURL)
        #expect(saved.records.map(\.id) == [shoot.id])
        if case .online? = env.model.shoots.first?.availability {} else { Issue.record("expected online") }
    }

    @Test func discoverMergesExistingShootsUnderWorkRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AppShootsRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let shoot = try ShootFolders.create(name: "Found", date: Date(), parent: base, cardVolumes: [], calendar: .current)

        let env = try makeEnv(workRoot: base)
        defer { try? FileManager.default.removeItem(at: env.dir) }
        await env.model.loadShoots()

        #expect(env.model.shoots.map(\.id) == [shoot.id])
        let saved = await ShootStore.load(from: env.registryURL)
        #expect(saved.records.map(\.id) == [shoot.id])
    }

    @Test func forgetNeverDeletesFolder() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let shoot = try await env.model.createShoot(name: "Keep", date: Date(), parent: try parent(in: env))
        await env.model.forgetShoot(id: shoot.id)

        #expect(env.model.shoots.isEmpty)
        #expect(FileManager.default.fileExists(atPath: shoot.folder.appendingPathComponent(ShootSidecar.fileName).path))
        let saved = await ShootStore.load(from: env.registryURL)
        #expect(saved.records.isEmpty)
    }

    @Test func locateRejectsWrongSidecarID() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let p = try parent(in: env)
        let a = try await env.model.createShoot(name: "A", date: Date(), parent: p)
        let b = try await env.model.createShoot(name: "B", date: Date(), parent: p)

        await #expect(throws: ShootError.sidecarMismatch) {
            try await env.model.relocateShoot(id: a.id, to: b.folder)
        }
        #expect(env.model.registry.records.first { $0.id == a.id }?.path == a.folder.standardizedFileURL.path)
    }

    @Test func locateAcceptsMovedFolder() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let a = try await env.model.createShoot(name: "Moved", date: Date(), parent: try parent(in: env))
        let moved = env.dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: a.folder, to: moved)

        try await env.model.relocateShoot(id: a.id, to: moved)
        if case .online(let s)? = env.model.shoots.first?.availability {
            #expect(s.folder.standardizedFileURL.path == moved.standardizedFileURL.path)
        } else {
            Issue.record("expected online after relocate")
        }
    }

    // addFootagePicksCardWithShootDay is skipped: `cards` is only populated by the volume watcher,
    // so it can't be exercised without real volumes.
}
