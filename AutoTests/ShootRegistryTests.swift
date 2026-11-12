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
        if case .online(let shoot) = out[rOK.id]?.availability { #expect(shoot.id == okID) } else { Issue.record("expected online") }
        #expect(out[rMM.id]?.availability == .mismatch)
        #expect(out[rEmpty.id]?.availability == .missing)
        #expect(out[rGone.id]?.availability == .missing)
    }

    @Test func resolveTreatsCardFolderAsMissing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let folder = dir.appendingPathComponent("shoot")
        try writeSidecar(id, in: folder)
        let rec = record(id, path: folder.path)
        let out = await ShootStore.resolve([rec], calendar: Calendar(identifier: .gregorian), cardVolumes: [dir])
        #expect(out[id]?.availability == .missing)
    }

    @Test func resolveOfflineForUnmountedVolume() async {
        let rec = record(path: "/Volumes/NoSuchDrive-\(UUID().uuidString)/Shoot")
        let out = await ShootStore.resolve([rec], calendar: Calendar(identifier: .gregorian), cardVolumes: [])
        #expect(out[rec.id]?.availability == .offline)
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

    // MARK: Per-copy resolve

    private let cal = Calendar(identifier: .gregorian)

    /// Fakes one distinct drive per top-level test folder (the folder name before the copy name).
    private func fakeDrives(_ roots: [URL]) -> @Sendable (URL) -> String? {
        let prefixes = roots.map { $0.standardizedFileURL.path }
        return { url in
            let p = url.standardizedFileURL.path
            return prefixes.firstIndex { p == $0 || p.hasPrefix($0 + "/") }.map { "drive\($0)" }
        }
    }

    private func copyRecord(_ id: UUID, _ paths: [String]) -> ShootRecord {
        ShootRecord(id: id, name: "S", day: "2026-01-02", path: paths[0], mirrors: Array(paths.dropFirst()),
                    lastSeen: Date(timeIntervalSince1970: 0))
    }

    @Test func bothCopiesOnlineGivesFolderAndMirrors() async throws {
        let a = try tempDir(), b = try tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let id = UUID()
        try writeSidecar(id, in: a.appendingPathComponent("S"))
        try writeSidecar(id, in: b.appendingPathComponent("S"))
        let rec = copyRecord(id, [a.appendingPathComponent("S").path, b.appendingPathComponent("S").path])
        let out = await ShootStore.resolve([rec], calendar: cal, cardVolumes: [], volumeID: fakeDrives([a, b]))
        guard case .online(let shoot)? = out[id]?.availability else { Issue.record("expected online"); return }
        #expect(shoot.folder.standardizedFileURL.path == a.appendingPathComponent("S").standardizedFileURL.path)
        #expect(shoot.mirrors.map { $0.standardizedFileURL.path } == [b.appendingPathComponent("S").standardizedFileURL.path])
        #expect(shoot.copies.count == 2)
        #expect(out[id]?.copies.map(\.availability) == [.online, .online])
        #expect(out[id]?.copies.map(\.isPrimary) == [true, false])
        #expect(out[id]?.copies.map(\.volumeName) == ["This Mac", "This Mac"])
    }

    @Test func missingPrimaryMakesMirrorTheEffectivePrimary() async throws {
        let a = try tempDir(), b = try tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let id = UUID()
        try writeSidecar(id, in: b.appendingPathComponent("S"))
        let rec = copyRecord(id, [a.appendingPathComponent("gone").path, b.appendingPathComponent("S").path])
        let out = await ShootStore.resolve([rec], calendar: cal, cardVolumes: [], volumeID: fakeDrives([a, b]))
        guard case .online(let shoot)? = out[id]?.availability else { Issue.record("expected online"); return }
        #expect(shoot.folder.standardizedFileURL.path == b.appendingPathComponent("S").standardizedFileURL.path)
        #expect(shoot.mirrors.isEmpty)
        #expect(out[id]?.copies.map(\.availability) == [.missing, .online])
    }

    @Test func mirrorWithOtherIDIsMismatchForThatCopyOnly() async throws {
        let a = try tempDir(), b = try tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let id = UUID()
        try writeSidecar(id, in: a.appendingPathComponent("S"))
        try writeSidecar(UUID(), in: b.appendingPathComponent("S"))
        let rec = copyRecord(id, [a.appendingPathComponent("S").path, b.appendingPathComponent("S").path])
        let out = await ShootStore.resolve([rec], calendar: cal, cardVolumes: [], volumeID: fakeDrives([a, b]))
        guard case .online(let shoot)? = out[id]?.availability else { Issue.record("expected online"); return }
        #expect(shoot.mirrors.isEmpty)
        #expect(out[id]?.copies.map(\.availability) == [.online, .mismatch])
    }

    @Test func secondCopyOnSameVolumeIsNotAMirror() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let first = dir.appendingPathComponent("one"), second = dir.appendingPathComponent("two")
        try writeSidecar(id, in: first)
        try writeSidecar(id, in: second)
        let rec = copyRecord(id, [first.path, second.path])
        // Real volume lookup: every temp dir shares one volume.
        let out = await ShootStore.resolve([rec], calendar: cal, cardVolumes: [])
        guard case .online(let shoot)? = out[id]?.availability else { Issue.record("expected online"); return }
        #expect(shoot.mirrors.isEmpty)
        #expect(out[id]?.copies.map(\.availability) == [.online, .sameVolume(as: first.path)])
    }

    @Test func distinctFakeDrivesInOneDirAreBothOnline() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let first = dir.appendingPathComponent("one"), second = dir.appendingPathComponent("two")
        try writeSidecar(id, in: first)
        try writeSidecar(id, in: second)
        let rec = copyRecord(id, [first.path, second.path])
        let out = await ShootStore.resolve([rec], calendar: cal, cardVolumes: [], volumeID: fakeDrives([first, second]))
        #expect(out[id]?.copies.map(\.availability) == [.online, .online])
    }

    @Test func unmountedVolumeCopyIsOfflineWithVolumeName() async {
        let name = "NoSuchDrive-\(UUID().uuidString)"
        let rec = record(path: "/Volumes/\(name)/x")
        let out = await ShootStore.resolve([rec], calendar: cal, cardVolumes: [])
        #expect(out[rec.id]?.copies.first?.availability == .offline)
        #expect(out[rec.id]?.copies.first?.volumeName == name)
    }

    @Test func aggregatePriority() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let offline = "/Volumes/NoSuchDrive-\(UUID().uuidString)/x"
        let gone = dir.appendingPathComponent("gone").path
        let mm = dir.appendingPathComponent("mm")
        try writeSidecar(UUID(), in: mm)
        let ok = dir.appendingPathComponent("ok")

        // offline beats missing and mismatch when nothing is online
        let r1 = copyRecord(UUID(), [gone, offline])
        let r2 = copyRecord(UUID(), [offline, mm.path])
        // mismatch primary, nothing offline
        let r3 = copyRecord(UUID(), [mm.path, gone])
        // missing primary, mismatched mirror: missing
        let r4 = copyRecord(UUID(), [gone, mm.path])
        // online beats everything
        let id5 = UUID()
        try writeSidecar(id5, in: ok)
        let r5 = copyRecord(id5, [offline, gone, ok.path])
        let out = await ShootStore.resolve([r1, r2, r3, r4, r5], calendar: cal, cardVolumes: [])
        #expect(out[r1.id]?.availability == .offline)
        #expect(out[r2.id]?.availability == .offline)
        #expect(out[r3.id]?.availability == .mismatch)
        #expect(out[r4.id]?.availability == .missing)
        if case .online(let shoot)? = out[id5]?.availability {
            #expect(shoot.folder.standardizedFileURL.path == ok.standardizedFileURL.path)
        } else { Issue.record("expected online") }
    }

    @Test func singleCopyResolutionHasOneStateAndNoMirrors() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try writeSidecar(id, in: dir)
        let out = await ShootStore.resolve([record(id, path: dir.path)], calendar: cal, cardVolumes: [])
        guard case .online(let shoot)? = out[id]?.availability else { Issue.record("expected online"); return }
        #expect(shoot.mirrors.isEmpty)
        #expect(out[id]?.copies.count == 1)
        #expect(out[id]?.copies.first?.isPrimary == true)
    }

    @Test func registryErrorsHaveFriendlyMessages() {
        let all: [ShootRegistry.RegistryError] = [.alreadyRegistered, .lastCopy, .unknownShoot, .notACopy]
        for e in all {
            let text = e.localizedDescription
            #expect(!text.contains("RegistryError"))
            #expect(text.hasSuffix("."))
        }
    }
}
