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

    @Test func traversalClientStaysInsideTheWorkRoot() throws {
        let root = URL(fileURLWithPath: "/Volumes/T7/Work")
        let shoot = try ShootPlanner.shootURL(root: root, client: "../../CARD/DCIM", date: date(2026, 3, 7), name: "x", dateFormat: "dd.MM.yy")
        #expect(shoot.path == "/Volumes/T7/Work/..-..-CARD-DCIM/07.03.26 x")
        #expect(ShootPlanner.isInside(shoot, root: root))
    }

    @Test func slashesInTheDateFormatDontMakeFolders() throws {
        #expect(ShootPlanner.folderName(date: date(2026, 3, 7), name: "a/b:c", dateFormat: "dd/MM/yy") == "07-03-26 a-b-c")
        let root = URL(fileURLWithPath: "/w")
        let shoot = try ShootPlanner.shootURL(root: root, client: "Acme", date: date(2026, 3, 7), name: "", dateFormat: "dd/MM/yy")
        #expect(shoot.path == "/w/Acme/07-03-26")
        // A format that renders as ".." falls back to the default.
        #expect(ShootPlanner.folderName(date: date(2026, 3, 7), name: "", dateFormat: "'..'") == "07.03.26")
    }

    @Test(arguments: ["", "   ", ".", "..", " .. ", "\n"])
    func unusableClientNamesThrow(_ client: String) {
        #expect(throws: ShootPlanner.PathError.invalidClient) {
            try ShootPlanner.shootURL(root: URL(fileURLWithPath: "/w"), client: client, date: Date(), name: "", dateFormat: "dd.MM.yy")
        }
    }

    @Test func safeComponentAndContainment() {
        #expect(ShootPlanner.safeComponent(" Acme / Co ") == "Acme - Co")
        #expect(ShootPlanner.safeComponent("..") == nil)
        #expect(ShootPlanner.isInside(URL(fileURLWithPath: "/w/a"), root: URL(fileURLWithPath: "/w/")))
        #expect(!ShootPlanner.isInside(URL(fileURLWithPath: "/w"), root: URL(fileURLWithPath: "/w")))
        #expect(!ShootPlanner.isInside(URL(fileURLWithPath: "/work/a"), root: URL(fileURLWithPath: "/w")))
        #expect(!ShootPlanner.isInside(URL(fileURLWithPath: "/w/../x"), root: URL(fileURLWithPath: "/w")))
    }

    @Test func cameraFolderNamesAreSanitized() {
        let cams = [Camera(id: "a", model: "FX3", serial: nil, folderName: "../../evil")]
        let jobs = ShootPlanner.jobs(missing: [file("1.MP4", kind: .video, camera: "a"), file("2.MP4", kind: .video, camera: "?")],
                                     shoot: URL(fileURLWithPath: "/w/C/s"), cameras: cams, fallback: "..")
        #expect(jobs.map(\.destDir.path) == ["/w/C/s/Footage/..-..-evil", "/w/C/s/Footage/Card"])
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
        // Verifying is neutral: never green, but it doesn't hide a card that needs action.
        #expect(S.aggregate([.verifying]) == .idle)
        #expect(S.aggregate([.backed, .verifying]) == .idle)
        #expect(S.aggregate([.needsBackup, .verifying]) == .unbacked)
    }

    @Test func emptyAndUnreadableCardsAreNeverBacked() {
        typealias S = StatusAggregator
        #expect(S.aggregate([.empty]) == .idle)
        #expect(S.aggregate([.backed, .empty]) == .idle)
        #expect(S.aggregate([.unreadable("x")]) == .error)
        #expect(S.aggregate([.backed, .unreadable("x")]) == .error)
        #expect(S.aggregate([.needsBackup, .empty]) == .unbacked)
    }

    @Test func afterScanPhase() {
        #expect(CardPhase.afterScan(fileCount: 0, error: nil) == .empty)
        #expect(CardPhase.afterScan(fileCount: 3, error: "denied") == .unreadable("denied"))
        #expect(CardPhase.afterScan(fileCount: 0, error: "denied") == .unreadable("denied"))
        #expect(CardPhase.afterScan(fileCount: 3, error: nil) == nil)
    }
}
