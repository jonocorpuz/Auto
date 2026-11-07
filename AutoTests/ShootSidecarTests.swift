import Testing
import Foundation
@testable import Auto

struct ShootSidecarTests {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func sample() -> ShootSidecar {
        ShootSidecar(version: 1, id: UUID(), name: "Wedding", day: "2025-10-22",
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func roundTripsVersion1() throws {
        let s = sample()
        let decoded = try ShootSidecar.decode(try ShootSidecar.encode(s))
        #expect(decoded == s)
    }

    @Test func dayStringIsCalendarLocal() throws {
        let la = calendar("America/Los_Angeles")
        let utc = calendar("UTC")
        // 2025-10-23 03:00 UTC = 2025-10-22 20:00 PDT
        let instant = Date(timeIntervalSince1970: 1_761_188_400)
        #expect(ShootSidecar.dayString(instant, calendar: la) == "2025-10-22")
        #expect(ShootSidecar.dayString(instant, calendar: utc) == "2025-10-23")

        let s = ShootSidecar(version: 1, id: UUID(), name: "x", day: "2025-10-22", createdAt: instant)
        #expect(s.date(in: la) == la.startOfDay(for: instant))
        #expect(s.date(in: utc) == utc.startOfDay(for: s.date(in: utc)!))
    }

    @Test func rejectsNewerVersion() throws {
        var s = sample()
        s.version = 2
        let data = try ShootSidecar.encode(s)
        #expect(throws: ShootError.unsupportedVersion(2)) { try ShootSidecar.decode(data) }
    }

    @Test func ignoresUnknownKeys() throws {
        let json = """
        {"version":1,"id":"\(UUID().uuidString)","name":"A","day":"2025-01-02",
         "createdAt":"2025-01-02T10:00:00Z","future":{"x":1}}
        """
        let s = try ShootSidecar.decode(Data(json.utf8))
        #expect(s.name == "A")
    }

    @Test func corruptDataThrows() {
        #expect(throws: ShootError.corruptSidecar) { try ShootSidecar.decode(Data("nope".utf8)) }
        #expect(throws: ShootError.corruptSidecar) { try ShootSidecar.decode(Data("{\"version\":1}".utf8)) }
    }

    @Test func shootFromSidecarUsesFolderAndDay() {
        let la = calendar("America/Los_Angeles")
        let s = sample()
        let folder = URL(fileURLWithPath: "/tmp/Wedding")
        let shoot = s.shoot(folder: folder, calendar: la)
        #expect(shoot?.id == s.id)
        #expect(shoot?.name == "Wedding")
        #expect(shoot?.folder == folder)
        #expect(shoot?.date == la.date(from: DateComponents(year: 2025, month: 10, day: 22)))
    }

    // MARK: Layout

    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func sidecarWithoutLayoutDecodesAsCameraFolders() throws {
        let json = #"{"version":1,"id":"\#(UUID().uuidString)","name":"W","day":"2025-10-22","createdAt":"2025-01-01T00:00:00Z"}"#
        let s = try ShootSidecar.decode(Data(json.utf8))
        #expect(s.layout == .cameraFolders)
    }

    @Test func recordWithoutLayoutDecodesAsCameraFolders() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"W","day":"2025-10-22","path":"/x","lastSeen":"2025-01-01T00:00:00Z"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(ShootRecord.self, from: Data(json.utf8)).layout == .cameraFolders)
    }

    @Test func flatLayoutRoundTrips() throws {
        var s = sample()
        s.layout = .flat
        #expect(try ShootSidecar.decode(try ShootSidecar.encode(s)).layout == .flat)
        let rec = ShootRecord(id: UUID(), name: "W", day: "2025-10-22", path: "/x", lastSeen: Date(timeIntervalSince1970: 0), layout: .flat)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(ShootRecord.self, from: try e.encode(rec)).layout == .flat)
    }

    @Test func createFlatWritesLayoutAndDiscoverCarriesIt() async throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cal = Calendar(identifier: .gregorian)
        let shoot = try ShootFolders.create(name: "Flat", date: Date(), parent: dir, cardVolumes: [], calendar: cal, layout: .flat)
        #expect(shoot.layout == .flat)
        #expect(try ShootFolders.readSidecar(in: shoot.folder)?.layout == .flat)
        let found = await ShootStore.discover(under: dir, calendar: cal)
        #expect(found.first?.layout == .flat)
        var reg = ShootRegistry()
        var stale = found[0]; stale.layout = .cameraFolders
        reg.add(stale)
        reg.merge(discovered: found)
        #expect(reg.records.first?.layout == .flat)
        let plain = try ShootFolders.create(name: "Cams", date: Date(), parent: dir, cardVolumes: [], calendar: cal)
        #expect(plain.layout == .cameraFolders)
    }

    @Test func mirrorCopyPreservesLayout() throws {
        let dir = try tmp()
        let other = try tmp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        let shoot = try ShootFolders.create(name: "Flat", date: Date(), parent: dir, cardVolumes: [], calendar: Calendar(identifier: .gregorian), layout: .flat)
        let sidecar = try #require(try ShootFolders.readSidecar(in: shoot.folder))
        let copy = try ShootFolders.createCopy(of: sidecar, parent: other, cardVolumes: [])
        #expect(try ShootFolders.readSidecar(in: copy)?.layout == .flat)
    }
}
