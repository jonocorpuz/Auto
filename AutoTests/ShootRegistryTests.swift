import Testing
import Foundation
@testable import Auto

struct ShootRegistryTests {
    private func record(_ id: UUID = UUID(), path: String = "/tmp/x", seen: Double = 0) -> ShootRecord {
        ShootRecord(id: id, name: "S", day: "2026-01-02", path: path, lastSeen: Date(timeIntervalSince1970: seen))
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func writeSidecar(_ id: UUID, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let s = ShootSidecar(version: 1, id: id, name: "S", day: "2026-01-02", createdAt: Date(timeIntervalSince1970: 0))
        try ShootSidecar.encode(s).write(to: folder.appendingPathComponent(ShootSidecar.fileName))
    }

    @Test func addDedupesByID() {
        let id = UUID()
        var r = ShootRegistry()
        r.add(record(id, path: "/a"))
        r.add(record(id, path: "/b"))
        #expect(r.records.count == 1)
        #expect(r.records[0].path == "/b")
    }

    @Test func addDedupesByPath() {
        var r = ShootRegistry()
        r.add(record(path: "/a/b"))
        let second = record(path: "/a/./b/")
        r.add(second)
        #expect(r.records == [second])
    }

    @Test func relocateUpdatesPath() {
        let id = UUID()
        var r = ShootRegistry()
        r.add(record(id, path: "/a"))
        r.relocate(id: id, to: "/z")
        #expect(r.records[0].path == "/z")
    }

    @Test func mergeDiscoveredKeepsExisting() {
        let id = UUID()
        var r = ShootRegistry()
        r.add(record(id, path: "/mine", seen: 1))
        let other = record(path: "/other")
        r.merge(discovered: [record(id, path: "/elsewhere", seen: 5), other])
        #expect(r.records.count == 2)
        #expect(r.records[0].path == "/mine")
        #expect(r.records[0].lastSeen == Date(timeIntervalSince1970: 5))
        #expect(r.records[1] == other)
    }

    @Test func saveLoadRoundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/shoots.json")
        var reg = ShootRegistry()
        reg.add(record(path: "/a", seen: 100))
        try await ShootStore.save(reg, to: url)
        #expect(await ShootStore.load(from: url) == reg)
    }

    @Test func loadCorruptGivesEmpty() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shoots.json")
        try Data("not json".utf8).write(to: url)
        #expect(await ShootStore.load(from: url) == ShootRegistry())
        #expect(await ShootStore.load(from: dir.appendingPathComponent("nope.json")) == ShootRegistry())
    }

    @Test func resolveReportsOnlineMissingMismatch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let okID = UUID()
        let ok = dir.appendingPathComponent("ok")
        try writeSidecar(okID, in: ok)
        let mm = dir.appendingPathComponent("mm")
        try writeSidecar(UUID(), in: mm)
        let noSidecar = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: noSidecar, withIntermediateDirectories: true)

        let rOK = record(okID, path: ok.path)
        let rMM = record(path: mm.path)
        let rEmpty = record(path: noSidecar.path)
        let rGone = record(path: dir.appendingPathComponent("gone").path)
        let out = await ShootStore.resolve([rOK, rMM, rEmpty, rGone], calendar: Calendar(identifier: .gregorian), cardVolumes: [])
        if case .online(let shoot) = out[rOK.id] { #expect(shoot.id == okID) } else { Issue.record("expected online") }
        #expect(out[rMM.id] == .mismatch)
        #expect(out[rEmpty.id] == .missing)
        #expect(out[rGone.id] == .missing)
    }

    @Test func resolveTreatsCardFolderAsMissing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let folder = dir.appendingPathComponent("shoot")
        try writeSidecar(id, in: folder)
        let rec = record(id, path: folder.path)
        let out = await ShootStore.resolve([rec], calendar: Calendar(identifier: .gregorian), cardVolumes: [dir])
        #expect(out[id] == .missing)
    }

    @Test func resolveOfflineForUnmountedVolume() async {
        let rec = record(path: "/Volumes/NoSuchDrive-\(UUID().uuidString)/Shoot")
        let out = await ShootStore.resolve([rec], calendar: Calendar(identifier: .gregorian), cardVolumes: [])
        #expect(out[rec.id] == .offline)
    }

    @Test func discoverFindsSidecarsOneLevelDeep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID()
        try writeSidecar(a, in: dir.appendingPathComponent("A"))
        try writeSidecar(UUID(), in: dir.appendingPathComponent("A/nested/deep"))
        try writeSidecar(UUID(), in: dir.appendingPathComponent("x/y"))
        try writeSidecar(UUID(), in: dir.appendingPathComponent(".hidden"))
        let found = await ShootStore.discover(under: dir, calendar: Calendar(identifier: .gregorian))
        #expect(found.map(\.id) == [a])
    }

    @Test func corruptFileIsQuarantinedNotDeleted() async throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("shoots.json")
        let bytes = Data("{ not json".utf8)
        try bytes.write(to: url)
        #expect(await ShootStore.load(from: url) == ShootRegistry())
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("shoots.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(backups[0])) == bytes)
    }

    @Test func missingFileMakesNoBackup() async throws {
        let dir = try tempDir()
        _ = await ShootStore.load(from: dir.appendingPathComponent("shoots.json"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func rapidSavesLeaveTheLaterSnapshot() async throws {
        let url = try tempDir().appendingPathComponent("shoots.json")
        var first = ShootRegistry(); first.add(record(path: "/tmp/one"))
        var second = first; second.add(record(path: "/tmp/two"))
        try await ShootStore.save(first, to: url)
        try await ShootStore.save(second, to: url)
        #expect(await ShootStore.load(from: url) == second)
        // A stale ticket arriving late is dropped.
        let saver = ShootRegistrySaver()
        try await saver.save(second, to: url, ticket: 10)
        try await saver.save(first, to: url, ticket: 9)
        #expect(await ShootStore.load(from: url) == second)
    }
}
