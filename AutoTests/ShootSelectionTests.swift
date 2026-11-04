import Foundation
import Testing
@testable import Auto

struct ShootSelectionTests {
    func cal(_ seconds: Int = 0) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: seconds)!
        return c
    }

    func date(_ day: Int, hour: Int = 12, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
    }

    func file(_ name: String, camera: String, _ d: Date) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/card/\(name)"), size: 10, date: d, kind: .video, cameraID: camera)
    }

    let cams = [Camera(id: "A", model: "A", serial: nil, folderName: "A"),
                        Camera(id: "B", model: "B", serial: nil, folderName: "B")]

    func sample(_ c: Calendar) -> [MediaFile] {
        [file("a22", camera: "A", date(22, calendar: c)), file("a29", camera: "A", date(29, calendar: c)),
         file("b22", camera: "B", date(22, calendar: c)), file("b29", camera: "B", date(29, calendar: c))]
    }

    @Test func defaultsToEverything() {
        let c = cal(), files = sample(c)
        let sel = ShootSelection(missing: files, cameras: cams, calendar: c)
        #expect(sel.filter(files) == files)
        #expect(sel.isIncluded(camera: "A"))
    }

    @Test func filterKeepsOnlyCheckedPairs() {
        let c = cal(), files = sample(c)
        var sel = ShootSelection(missing: files, cameras: cams, calendar: c)
        sel.set(camera: "A", day: date(29, calendar: c), included: false)
        #expect(sel.filter(files).map(\.name) == ["a22", "b22", "b29"])
        #expect(!sel.isIncluded(camera: "A", day: date(29, calendar: c)))
        #expect(sel.isIncluded(camera: "A", day: date(22, calendar: c)))
    }

    @Test func uncheckingCameraDropsAllDays() {
        let c = cal(), files = sample(c)
        var sel = ShootSelection(missing: files, cameras: cams, calendar: c)
        sel.setCamera("A", included: false, days: [])
        #expect(sel.filter(files).map(\.name) == ["b22", "b29"])
        #expect(!sel.isIncluded(camera: "A"))
    }

    @Test func recheckingCameraRestoresAllDays() {
        let c = cal(), files = sample(c)
        var sel = ShootSelection(missing: files, cameras: cams, calendar: c)
        sel.set(camera: "A", day: date(29, calendar: c), included: false)
        sel.setCamera("A", included: false, days: [])
        let days = ShootSelection.days(missing: files, cameras: cams, calendar: c)["A"]!.map(\.start)
        sel.setCamera("A", included: true, days: days)
        #expect(sel.filter(files) == files)
    }

    @Test func unknownCameraGroupsUnderOther() {
        let c = cal()
        let files = [file("x", camera: "ZZ", date(22, calendar: c)), file("y", camera: "", date(23, calendar: c)),
                     file("a", camera: "A", date(22, calendar: c))]
        let sel = ShootSelection(missing: files, cameras: cams, calendar: c)
        #expect(sel.groupID(files[0]) == ShootSelection.otherID)
        #expect(sel.groupID(files[1]) == ShootSelection.otherID)
        let days = ShootSelection.days(missing: files, cameras: cams, calendar: c)
        #expect(days[ShootSelection.otherID]?.count == 2)
        #expect(days["A"]?.count == 1)
        #expect(days["ZZ"] == nil)
        #expect(sel.isIncluded(camera: ShootSelection.otherID))
    }

    @Test func usesInjectedCalendar() {
        let utc = cal(0), plus10 = cal(10 * 3600)
        let f = file("f", camera: "A", date(22, hour: 20, calendar: utc))  // 22nd 20:00 UTC = 23rd 06:00 +10
        let a = ShootSelection(missing: [f], cameras: cams, calendar: utc)
        let b = ShootSelection(missing: [f], cameras: cams, calendar: plus10)
        #expect(a.pair(f).day != b.pair(f).day)
    }

    @Test func emptyWhenNothingChecked() {
        let c = cal(), files = sample(c)
        var sel = ShootSelection(missing: files, cameras: cams, calendar: c)
        sel.setCamera("A", included: false, days: [])
        sel.setCamera("B", included: false, days: [])
        #expect(sel.isEmpty)
        #expect(sel.filter(files).isEmpty)
    }

    @Test func newPairsNotAutoIncluded() {
        let c = cal(), files = sample(c)
        let sel = ShootSelection(missing: Array(files.prefix(1)), cameras: cams, calendar: c)
        #expect(sel.filter(files).map(\.name) == ["a22"])
    }
}

extension ShootSelectionTests {
    @Test func onlyDaySelectsMatchingDaysAcrossCameras() {
        let c = cal(), files = sample(c)
        let sel = ShootSelection(files: files, cameras: cams, calendar: c, onlyDay: date(22, hour: 5, calendar: c))
        #expect(sel.filter(files).map(\.name) == ["a22", "b22"])
        let days = ShootSelection.days(missing: files, cameras: cams, calendar: c)
        #expect(days["A"]?.count == 2)
    }

    @Test func onlyDayWithNoMatchSelectsNothing() {
        let c = cal(), files = sample(c)
        let sel = ShootSelection(files: files, cameras: cams, calendar: c, onlyDay: date(25, calendar: c))
        #expect(sel.isEmpty)
    }

    @Test func onlyDayRespectsInjectedTimeZone() {
        let utc = cal(0), plus10 = cal(10 * 3600)
        let f = file("f", camera: "A", date(22, hour: 20, calendar: utc))  // 23rd in +10
        let day22 = date(22, hour: 12, calendar: utc)
        #expect(ShootSelection(files: [f], cameras: cams, calendar: utc, onlyDay: day22).filter([f]) == [f])
        #expect(ShootSelection(files: [f], cameras: cams, calendar: plus10, onlyDay: day22).isEmpty)
    }
}
