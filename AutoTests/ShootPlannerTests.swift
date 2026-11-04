import Foundation
import Testing
@testable import Auto

struct ShootPlannerTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func file(_ name: String, kind: MediaKind, camera: String, size: Int64 = 10) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/card/\(name)"), size: size, date: Date(), kind: kind, cameraID: camera)
    }

    @Test func folderNameUsesFormatAndName() {
        #expect(ShootPlanner.folderName(date: date(2026, 3, 7), name: " Brand film ", dateFormat: "dd.MM.yy") == "07.03.26 Brand film")
        #expect(ShootPlanner.folderName(date: date(2026, 3, 7), name: "", dateFormat: "yyyy-MM-dd") == "2026-03-07")
        #expect(ShootPlanner.folderName(date: date(2026, 3, 7), name: "", dateFormat: "") == "07.03.26")
    }

    @Test func jobsSplitFootageAndPhotoPerCamera() {
        let cams = [Camera(id: "a", model: "FX3", serial: nil, folderName: "A-cam"),
                    Camera(id: "b", model: "A7", serial: nil, folderName: " ")]
        let missing = [file("1.MP4", kind: .video, camera: "a"),
                       file("2.JPG", kind: .photo, camera: "b"),
                       file("3.MP4", kind: .video, camera: "zzz")]
        let shoot = URL(fileURLWithPath: "/w/Client/shoot")
        let jobs = ShootPlanner.jobs(missing: missing, shoot: shoot, cameras: cams, fallback: "CARD")
        #expect(jobs.map(\.destDir.path) == ["/w/Client/shoot/Footage/A-cam", "/w/Client/shoot/Photo/A7", "/w/Client/shoot/Footage/CARD"])
        let plan = ShootPlanner.plan(jobs: jobs, shoot: shoot)
        #expect(plan.destinationLabel == "A-cam, A7, CARD")
        #expect(plan.bytes == 30)
    }

    @Test func sectionsAndSuggestions() {
        let s = ShootPlanner.sections(for: [file("a.JPG", kind: .photo, camera: "a")])
        #expect(s.photo && !s.video)
        let clients = ["Acme", "Beta", "Acme Two"]
        #expect(ShootPlanner.suggestions(for: "acm", in: clients) == ["Acme", "Acme Two"])
        #expect(ShootPlanner.suggestions(for: "beta", in: clients).isEmpty)
        #expect(ShootPlanner.suggestions(for: "", in: clients).isEmpty)
    }

    @Test func flatPlanPutsEverythingInOneFolder() {
        let dir = URL(fileURLWithPath: "/x/Dump")
        let plan = ShootPlanner.flatPlan(missing: [file("a.MP4", kind: .video, camera: "a")], into: dir)
        #expect(plan.jobs.first?.destDir == dir)
        #expect(plan.destinationLabel == "Dump")
    }

    @Test func statusPriority() {
        typealias S = StatusAggregator
        #expect(S.aggregate([]) == .idle)
        #expect(S.aggregate([.scanning]) == .idle)
        #expect(S.aggregate([.backed, .scanning]) == .backed)
        #expect(S.aggregate([.backed, .needsBackup]) == .unbacked)
        #expect(S.aggregate([.ready, .backed]) == .unbacked)
        #expect(S.aggregate([.needsBackup, .failed("x")]) == .error)
        #expect(S.aggregate([.failed("x"), .copying]) == .copying)
    }
}
