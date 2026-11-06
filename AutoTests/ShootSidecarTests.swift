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
}
