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

    @Test func traversalShootNameStaysInsideTheWorkRoot() throws {
        let root = URL(fileURLWithPath: "/Volumes/T7/Work")
        let shoot = try ShootPlanner.shootURL(root: root, name: "../../CARD/DCIM")
        #expect(shoot.path == "/Volumes/T7/Work/..-..-CARD-DCIM")
        #expect(ShootPlanner.isInside(shoot, root: root))
    }

    @Test func shootURLIsNameDirectlyUnderRoot() throws {
        let root = URL(fileURLWithPath: "/w")
        #expect(try ShootPlanner.shootURL(root: root, name: " Brand film ").path == "/w/Brand film")
        #expect(try ShootPlanner.shootURL(root: root, name: "a/b:c").path == "/w/a-b-c")
    }

    @Test(arguments: ["", "   ", ".", "..", " .. ", "\n"])
    func unusableShootNamesThrow(_ name: String) {
        #expect(throws: ShootPlanner.PathError.invalidName) {
            try ShootPlanner.shootURL(root: URL(fileURLWithPath: "/w"), name: name)
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
        #expect(jobs.map(\.destDir.path) == ["/w/C/s/Video/..-..-evil", "/w/C/s/Video/Card"])
    }

    @Test func jobsFallBackToDefaultFolderName() {
        var cam = Camera(id: "a", model: "FX3", serial: nil, folderName: "FX3 B")
        cam.folderName = ""
        let jobs = ShootPlanner.jobs(missing: [file("1.MP4", kind: .video, camera: "a")],
                                     shoot: URL(fileURLWithPath: "/w/s"), cameras: [cam], fallback: "CARD")
        #expect(jobs.map(\.destDir.path) == ["/w/s/Video/FX3 B"])
    }

    @Test func caseVariantCameraFoldersMerge() {
        let cams = [Camera(id: "a", model: "FX3", serial: nil, folderName: "FX3"),
                    Camera(id: "b", model: "FX3", serial: nil, folderName: "fx3")]
        let shoot = URL(fileURLWithPath: "/w/s")
        let jobs = ShootPlanner.jobs(missing: [file("1.MP4", kind: .video, camera: "a"), file("2.MP4", kind: .video, camera: "b"),
                                               file("3.JPG", kind: .photo, camera: "b")],
                                     shoot: shoot, cameras: cams, fallback: "CARD")
        #expect(ShootPlanner.directories(for: jobs).map(\.path) == ["/w/s/Photo/fx3", "/w/s/Video/FX3"])
    }

    @Test func jobsSplitVideoAndPhotoPerCamera() {
        let cams = [Camera(id: "a", model: "FX3", serial: nil, folderName: "A-cam"),
                    Camera(id: "b", model: "A7", serial: nil, folderName: " ")]
        let missing = [file("1.MP4", kind: .video, camera: "a"),
                       file("2.JPG", kind: .photo, camera: "b"),
                       file("3.MP4", kind: .video, camera: "zzz")]
        let shoot = URL(fileURLWithPath: "/w/Client/shoot")
        let jobs = ShootPlanner.jobs(missing: missing, shoot: shoot, cameras: cams, fallback: "CARD")
        #expect(jobs.map(\.destDir.path) == ["/w/Client/shoot/Video/A-cam", "/w/Client/shoot/Photo/A7", "/w/Client/shoot/Video/CARD"])
        let plan = ShootPlanner.plan(jobs: jobs, shoot: shoot)
        #expect(plan.destinationLabel == "A-cam, A7, CARD")
        #expect(plan.bytes == 30)
    }

    @Test func multiCopyJobsAreFileMajorAndRooted() {
        let cams = [Camera(id: "a", model: "FX3", serial: nil, folderName: "A-cam")]
        let a = URL(fileURLWithPath: "/volA/S"), b = URL(fileURLWithPath: "/volB/S")
        let jobs = ShootPlanner.jobs(missing: [file("1.MP4", kind: .video, camera: "a"), file("2.JPG", kind: .photo, camera: "a")],
                                     copies: [a, b], cameras: cams, fallback: "CARD")
        #expect(jobs.map(\.file.name) == ["1.MP4", "1.MP4", "2.JPG", "2.JPG"])
        #expect(jobs.map(\.destDir.path) == ["/volA/S/Video/A-cam", "/volB/S/Video/A-cam", "/volA/S/Photo/A-cam", "/volB/S/Photo/A-cam"])
        #expect(jobs.map(\.root?.path) == ["/volA/S", "/volB/S", "/volA/S", "/volB/S"])
        let plan = ShootPlanner.plan(jobs: jobs, shoot: a, workRoot: a, roots: [a, b], shootID: UUID())
        #expect(plan.copyRoots == [a, b])
        #expect(plan.bytes == 40)
    }

    @Test func flatPlanJobsCarryTheirRoot() {
        let dir = URL(fileURLWithPath: "/out")
        let plan = ShootPlanner.flatPlan(missing: [file("1.MP4", kind: .video, camera: "a")], into: dir)
        #expect(plan.jobs.allSatisfy { $0.root == dir })
        #expect(plan.copyRoots == [dir])
    }

    private func mixedJobs() -> (jobs: [CopyJob], shoot: URL, root: URL) {
        let cams = [Camera(id: "a", model: "FX3", serial: nil, folderName: "A-cam"),
                    Camera(id: "b", model: "A7", serial: nil, folderName: "B-cam")]
        let missing = [file("1.MP4", kind: .video, camera: "b"),
                       file("2.MP4", kind: .video, camera: "a"),
                       file("3.MP4", kind: .video, camera: "b"),
                       file("4.JPG", kind: .photo, camera: "a")]
        let root = URL(fileURLWithPath: "/w")
        let shoot = URL(fileURLWithPath: "/w/Brand film")
        return (ShootPlanner.jobs(missing: missing, shoot: shoot, cameras: cams, fallback: "CARD"), shoot, root)
    }

    @Test func directoriesAreUniqueLeafDestinations() {
        let f = mixedJobs()
        let dirs = ShootPlanner.directories(for: f.jobs)
        #expect(dirs.map(\.path) == Set(f.jobs.map(\.destDir.path)).sorted())
        #expect(dirs.count == 3)
        #expect(!dirs.contains(f.shoot))
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

    @Test func shootURLUnderPrivateTmpRoot() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let root = fm.isWritableFile(atPath: base.path)
            ? base.appendingPathComponent("AutoRoot-\(UUID().uuidString)", isDirectory: true)
            : fm.temporaryDirectory.appendingPathComponent("AutoRoot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let shoot = try ShootPlanner.shootURL(root: root, name: "New Shoot")
        #expect(ShootPlanner.isInside(shoot, root: root))
        let jobs = ShootPlanner.jobs(missing: [file("a.MP4", kind: .video, camera: "a")], shoot: shoot, cameras: [], fallback: "Card")
        #expect(jobs.allSatisfy { ShootPlanner.isInside($0.destDir, root: root) })
    }

    @Test func afterVerifyPhase() {
        #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 0, hasPlan: false, current: .verifying) == .backed)
        #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 1, hasPlan: false, current: .verifying) == .needsBackup)
        #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 1, hasPlan: true, current: .verifying) == .ready)
        #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 1, hasPlan: false, current: .failed("x")) == nil)
    }
}
