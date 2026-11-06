import Foundation
import Testing
@testable import Auto

struct ShootDaysTests {
    private var la: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func file(_ name: String, _ date: Date, camera: String) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/tmp/\(name)"), size: 1, date: date, kind: .video, cameraID: camera)
    }

    @Test func groupsDistinctDaysPerCameraSorted() {
        let cal = la
        let files = [
            file("a1", date(2025, 3, 29, 10, 0, in: cal), camera: "A"),
            file("a2", date(2025, 3, 22, 9, 0, in: cal), camera: "A"),
            file("a3", date(2025, 3, 22, 15, 0, in: cal), camera: "A"),
            file("b1", date(2025, 3, 22, 12, 0, in: cal), camera: "B"),
        ]
        let result = ShootDays.byCamera(files, calendar: cal)
        #expect(result["A"] == [
            ShootDay(start: date(2025, 3, 22, 0, 0, in: cal), fileCount: 2),
            ShootDay(start: date(2025, 3, 29, 0, 0, in: cal), fileCount: 1),
        ])
        #expect(result["B"] == [ShootDay(start: date(2025, 3, 22, 0, 0, in: cal), fileCount: 1)])
    }

    @Test func dayBoundaryUsesCalendarTimeZone() {
        let cal = la
        let late = date(2025, 3, 22, 23, 30, in: cal)  // 06:30 UTC on the 23rd
        let early = date(2025, 3, 22, 1, 0, in: cal)
        let files = [file("x", late, camera: "A"), file("y", early, camera: "A")]
        #expect(ShootDays.byCamera(files, calendar: cal)["A"]?.count == 1)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(ShootDays.byCamera(files, calendar: utc)["A"]?.count == 2)
    }

    @Test func emptyInputGivesEmptyMap() {
        #expect(ShootDays.byCamera([], calendar: la).isEmpty)
    }
}
