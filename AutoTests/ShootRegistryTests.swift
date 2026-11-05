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

    // MARK: Mirrors

    @Test func legacyRegistryJSONDecodesAndIsNotQuarantined() async throws {
        // Exact format ShootRegistrySaver wrote before mirrors existed (pretty, sorted keys, iso8601).
        let legacy = """
        {
          "records" : [
            {
              "day" : "2026-01-02",
              "id" : "11111111-2222-3333-4444-555555555555",
              "lastSeen" : "2023-11-14T22:13:20Z",
              "name" : "Wedding",
              "path" : "\\/Volumes\\/Work\\/Wedding"
            }
          ],
          "version" : 1
        }
        """
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shoots.json")
        try Data(legacy.utf8).write(to: url)
        let reg = await ShootStore.load(from: url)
        #expect(reg.records.count == 1)
        let r = try #require(reg.records.first)
        #expect(r.id == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        #expect(r.name == "Wedding")
        #expect(r.path == "/Volumes/Work/Wedding")
        #expect(r.mirrors.isEmpty)
        #expect(r.pendingSync.isEmpty)
        #expect(r.lastSeen == Date(timeIntervalSince1970: 1_700_000_000))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["shoots.json"])
    }

    @Test func roundTripWithMirrors() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shoots.json")
        let id = UUID()
        var reg = ShootRegistry()
        reg.add(record(id, path: "/p", seen: 100))
        try reg.addMirror(id: id, path: "/m1")
        try reg.addMirror(id: id, path: "/m2")
        reg.setPendingSync(id: id, path: "/m1", false)
        try await ShootStore.save(reg, to: url)
        let loaded = await ShootStore.load(from: url)
        #expect(loaded == reg)
        #expect(loaded.records[0].mirrors == ["/m1", "/m2"])
        #expect(loaded.records[0].pendingSync == ["/m2"])
    }

    @Test func addDedupesOnMirrorPath() {
        var r = ShootRegistry()
        let id = UUID()
        r.add(ShootRecord(id: id, name: "S", day: "d", path: "/a", mirrors: ["/b/c"], lastSeen: Date(timeIntervalSince1970: 0)))
        let other = record(path: "/b/./c/")
        r.add(other)
        // The multi-copy record keeps its primary; only the shared mirror is stripped.
        #expect(r.records.count == 2)
        #expect(r.records[0].id == id)
        #expect(r.records[0].copyPaths == ["/a"])
        #expect(r.records[1] == other)
    }

    @Test func addOverlappingTwoRecordsStripsBoth() {
        var r = ShootRegistry()
        let single = UUID(), multi = UUID()
        r.add(record(single, path: "/x"))
        r.add(ShootRecord(id: multi, name: "S", day: "d", path: "/y", mirrors: ["/z", "/w"], lastSeen: Date(timeIntervalSince1970: 0)))
        r.setPendingSync(id: multi, path: "/y", true)
        let incoming = ShootRecord(id: UUID(), name: "N", day: "d", path: "/x", mirrors: ["/y"], lastSeen: Date(timeIntervalSince1970: 0))
        r.add(incoming)
        #expect(r.records.map(\.id) == [multi, incoming.id])
        #expect(r.records[0].path == "/z")
        #expect(r.records[0].mirrors == ["/w"])
        #expect(r.records[0].pendingSync.isEmpty)
    }

    @Test func addSameIDPreservesMirrors() {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/p"))
        try? r.addMirror(id: id, path: "/m1")
        try? r.addMirror(id: id, path: "/m2")
        let incoming = ShootRecord(id: id, name: "S", day: "d", path: "/M1", mirrors: ["/m3"], lastSeen: Date(timeIntervalSince1970: 9))
        r.add(incoming)
        #expect(r.records.count == 1)
        #expect(r.records[0].path == "/M1")
        #expect(r.records[0].mirrors == ["/m2", "/m3"])
        #expect(r.records[0].pendingSync == ["/m2"])
    }

    @Test func caseInsensitiveComparisonKeepsOriginalCasing() throws {
        var r = ShootRegistry()
        let a = UUID(), b = UUID()
        r.add(record(a, path: "/A/Shoot"))
        r.add(record(b, path: "/B"))
        #expect(throws: ShootRegistry.RegistryError.alreadyRegistered) { try r.addMirror(id: b, path: "/a/shoot/") }
        try r.addMirror(id: a, path: "/Mir/./Ror/")
        #expect(r.records[0].mirrors == ["/Mir/Ror"])
        #expect(r.records[0].pendingSync == ["/Mir/Ror"])
    }

    @Test func addMirrorRefusesDuplicatePathAcrossRecords() throws {
        var r = ShootRegistry()
        let a = UUID(), b = UUID()
        r.add(record(a, path: "/a"))
        r.add(record(b, path: "/b"))
        try r.addMirror(id: a, path: "/a-copy")
        #expect(throws: ShootRegistry.RegistryError.alreadyRegistered) { try r.addMirror(id: b, path: "/a-copy") }
        #expect(throws: ShootRegistry.RegistryError.alreadyRegistered) { try r.addMirror(id: b, path: "/a/") }
        #expect(throws: ShootRegistry.RegistryError.alreadyRegistered) { try r.addMirror(id: a, path: "/a-copy/./") }
        #expect(throws: ShootRegistry.RegistryError.unknownShoot) { try r.addMirror(id: UUID(), path: "/zzz") }
        #expect(r.records[1].mirrors.isEmpty)
        #expect(r.records[0].mirrors == ["/a-copy"])
        #expect(r.records[0].pendingSync == ["/a-copy"])
    }

    @Test func removingPrimaryPromotesMirrorAndLastCopyThrows() throws {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/p"))
        try r.addMirror(id: id, path: "/m1")
        try r.addMirror(id: id, path: "/m2")
        try r.removeCopy(id: id, path: "/p")
        #expect(r.records[0].path == "/m1")
        #expect(r.records[0].mirrors == ["/m2"])
        try r.removeCopy(id: id, path: "/m2")
        #expect(r.records[0].mirrors.isEmpty)
        #expect(r.records[0].pendingSync == ["/m1"])
        #expect(throws: ShootRegistry.RegistryError.lastCopy) { try r.removeCopy(id: id, path: "/m1") }
        #expect(r.records[0].path == "/m1")
        #expect(throws: ShootRegistry.RegistryError.unknownShoot) { try r.removeCopy(id: UUID(), path: "/m1") }
    }

    @Test func relocateMirrorAndPrimaryByPath() throws {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/p"))
        try r.addMirror(id: id, path: "/m")
        try r.relocate(id: id, from: "/m", to: "/m2")
        #expect(r.records[0].mirrors == ["/m2"])
        #expect(r.records[0].pendingSync == ["/m2"])
        #expect(r.records[0].path == "/p")
        try r.relocate(id: id, from: "/p", to: "/p2")
        #expect(r.records[0].path == "/p2")
        #expect(throws: ShootRegistry.RegistryError.notACopy) { try r.relocate(id: id, from: "/nope", to: "/x") }
        #expect(throws: ShootRegistry.RegistryError.alreadyRegistered) { try r.relocate(id: id, from: "/p2", to: "/M2") }
        #expect(throws: ShootRegistry.RegistryError.unknownShoot) { try r.relocate(id: UUID(), from: "/p2", to: "/x") }
        #expect(r.records[0].copyPaths == ["/p2", "/m2"])
    }

    @Test func relocateRefusesOtherRecordsPath() throws {
        var r = ShootRegistry()
        let a = UUID(), b = UUID()
        r.add(record(a, path: "/a"))
        r.add(record(b, path: "/b"))
        #expect(throws: ShootRegistry.RegistryError.alreadyRegistered) { try r.relocate(id: a, from: "/a", to: "/b") }
        #expect(r.records[0].path == "/a")
    }

    @Test func legacyRelocateKeepsInvariants() throws {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/p"))
        try r.addMirror(id: id, path: "/m")
        r.relocate(id: id, to: "/m")   // onto its own mirror: refused
        #expect(r.records[0].copyPaths == ["/p", "/m"])
        r.setPendingSync(id: id, path: "/p", true)
        r.relocate(id: id, to: "/q")
        #expect(r.records[0].copyPaths == ["/q", "/m"])
        #expect(r.records[0].pendingSync == ["/m", "/q"])
    }

    @Test func removingPrimaryInPendingSyncClearsIt() throws {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/p"))
        try r.addMirror(id: id, path: "/m")
        r.setPendingSync(id: id, path: "/p", true)
        try r.removeCopy(id: id, path: "/p")
        #expect(r.records[0].path == "/m")
        #expect(r.records[0].pendingSync == ["/m"])
    }

    @Test func removeCopyOfNonCopyThrowsAndLeavesRecord() throws {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/p"))
        try r.addMirror(id: id, path: "/m")
        let before = r
        #expect(throws: ShootRegistry.RegistryError.notACopy) { try r.removeCopy(id: id, path: "/other") }
        #expect(r == before)
    }

    @Test func unknownIDMutationsAreNoOps() {
        var r = ShootRegistry()
        r.add(record(path: "/p"))
        let before = r
        r.setPendingSync(id: UUID(), path: "/p", true)
        r.relocate(id: UUID(), to: "/x")
        #expect(r == before)
    }

    @Test func decodesMirrorsWithoutPendingSync() throws {
        let json = """
        {"day":"2026-01-02","id":"11111111-2222-3333-4444-555555555555","lastSeen":"2023-11-14T22:13:20Z",
         "mirrors":["/m"],"name":"W","path":"/p"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let rec = try dec.decode(ShootRecord.self, from: Data(json.utf8))
        #expect(rec.mirrors == ["/m"])
        #expect(rec.pendingSync.isEmpty)
    }

    @Test func setPendingSyncTogglesOnlyKnownCopies() {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/p"))
        r.setPendingSync(id: id, path: "/elsewhere", true)
        #expect(r.records[0].pendingSync.isEmpty)
        r.setPendingSync(id: id, path: "/p", true)
        r.setPendingSync(id: id, path: "/p", true)
        #expect(r.records[0].pendingSync == ["/p"])
        r.setPendingSync(id: id, path: "/p", false)
        #expect(r.records[0].pendingSync.isEmpty)
    }

    @Test func mergeDiscoveredNeverAddsMirrors() {
        var r = ShootRegistry()
        let id = UUID()
        r.add(record(id, path: "/mine", seen: 1))
        r.merge(discovered: [record(id, path: "/finder-duplicate", seen: 2)])
        #expect(r.records.count == 1)
        #expect(r.records[0].mirrors.isEmpty)
        #expect(r.records[0].pendingSync.isEmpty)
        #expect(r.records[0].path == "/mine")
    }
}
