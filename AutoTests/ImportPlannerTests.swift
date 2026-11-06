import Foundation
import Testing
@testable import Auto

struct ImportPlannerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportPlanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func make(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func file(_ name: String, kind: MediaKind, camera: String) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/src/\(name)"), size: 10, date: Date(), kind: kind, cameraID: camera, cardID: "import")
    }

    private func cam(_ id: String, _ model: String, serial: String? = nil) -> Camera {
        Camera(id: id, model: model, serial: serial, folderName: model)
    }

    // MARK: refusal

    @Test func sourceOutsideTheShootIsAllowed() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let shoot = base.appendingPathComponent("Shoot")
        let other = base.appendingPathComponent("Drive/clip.mov")
        try make(shoot)
        try make(other.deletingLastPathComponent())
        #expect(ImportPlanner.refusal(for: other, shootRoots: [shoot]) == nil)
    }

    @Test func differentlyCasedPathIntoTheShootIsRefused() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let shoot = base.appendingPathComponent("Shoot")
        try make(shoot.appendingPathComponent("Video"))
        try Data("x".utf8).write(to: shoot.appendingPathComponent("Video/clip.mov"))
        let cased = base.appendingPathComponent("SHOOT/video/clip.mov")
        // Only meaningful on a case-insensitive volume (the default).
        guard FileManager.default.fileExists(atPath: cased.path) else { return }
        #expect(ImportPlanner.refusal(for: cased, shootRoots: [shoot]) == .insideShoot("clip.mov"))
        #expect(ImportPlanner.refusal(for: base.appendingPathComponent("SHOOT"), shootRoots: [shoot]) == .insideShoot("SHOOT"))
    }

    @Test func sourceInsideAnyCopyIsRefused() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let primary = base.appendingPathComponent("A/Shoot"), mirror = base.appendingPathComponent("B/Shoot")
        try make(primary.appendingPathComponent("Video/FX3"))
        try make(mirror.appendingPathComponent("Video/FX3"))
        let inPrimary = primary.appendingPathComponent("Video/FX3/a.mov")
        let inMirror = mirror.appendingPathComponent("Video/FX3/a.mov")
        #expect(ImportPlanner.refusal(for: inPrimary, shootRoots: [primary, mirror]) == .insideShoot("a.mov"))
        #expect(ImportPlanner.refusal(for: inMirror, shootRoots: [primary, mirror]) == .insideShoot("a.mov"))
        #expect(ImportPlanner.refusal(for: primary, shootRoots: [primary, mirror]) == .insideShoot("Shoot"))
    }

    @Test func sourceInsideShootViaSymlinkIsRefused() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let shoot = base.appendingPathComponent("Shoot")
        try make(shoot.appendingPathComponent("Video"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shoot)
        #expect(ImportPlanner.refusal(for: link.appendingPathComponent("Video/a.mov"), shootRoots: [shoot]) == .insideShoot("a.mov"))
        // Shoot reached through a symlink, source given by the real path.
        let shootViaLink = link
        #expect(ImportPlanner.refusal(for: shoot.appendingPathComponent("Video/a.mov"), shootRoots: [shootViaLink]) == .insideShoot("a.mov"))
    }

    @Test func reservedFolderComponentsAreRefused() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let shoot = base.appendingPathComponent("Shoot")
        try make(shoot)
        #expect(ImportPlanner.refusal(for: base.appendingPathComponent("Old/_Rejects/a.jpg"), shootRoots: [shoot]) == .inReservedFolder("a.jpg"))
        #expect(ImportPlanner.refusal(for: base.appendingPathComponent("x/.auto-cull/b.jpg"), shootRoots: [shoot]) == .inReservedFolder("b.jpg"))
        #expect(ImportPlanner.refusal(for: base.appendingPathComponent("x/_REJECTS"), shootRoots: [shoot]) == .inReservedFolder("_REJECTS"))
    }

    // MARK: mapCameras

    @Test func reusesExistingFolderCaseInsensitively() {
        let out = ImportPlanner.mapCameras(detected: [cam("a", "FX3")], existing: ["Video": ["fx3"], "Photo": []])
        #expect(out[0].folderName == "fx3")
        #expect(out[0].defaultFolderName == "fx3")
    }

    @Test func photoOnlyFolderIsReused() {
        let out = ImportPlanner.mapCameras(detected: [cam("a", "A7")], existing: ["Video": [], "Photo": ["a7"]])
        #expect(out[0].folderName == "a7")
    }

    @Test func twoSameModelCamerasGetLettersAndMatchExisting() {
        let detected = Camera.disambiguated([cam("1", "FX3", serial: "1"), cam("2", "FX3", serial: "2")])
        #expect(detected.map(\.folderName) == ["FX3 A", "FX3 B"])
        let out = ImportPlanner.mapCameras(detected: detected, existing: ["Video": ["fx3 b"]])
        #expect(out.map(\.folderName) == ["FX3 A", "fx3 b"])
    }

    @Test func loneModelWithOnlyLetteredFoldersUsesPlainName() {
        let out = ImportPlanner.mapCameras(detected: [cam("a", "FX3")], existing: ["Video": ["FX3 A", "FX3 B"]])
        #expect(out[0].folderName == "FX3")
    }

    @Test func noExistingFoldersKeepsNames() {
        let out = ImportPlanner.mapCameras(detected: [cam("a", "FX3")], existing: [:])
        #expect(out[0].folderName == "FX3")
    }

    @Test func existingFoldersListsOnlyDirectories() throws {
        let shoot = try tempDir()
        defer { try? FileManager.default.removeItem(at: shoot) }
        try make(shoot.appendingPathComponent("Video/FX3"))
        try make(shoot.appendingPathComponent("Photo/A7"))
        try Data().write(to: shoot.appendingPathComponent("Video/loose.mov"))
        let found = ImportPlanner.existingFolders(in: shoot)
        #expect(found["Video"] == ["FX3"])
        #expect(found["Photo"] == ["A7"])
    }

    // MARK: sortedJobs

    @Test func sortedJobsRoutesByKindAndCamera() {
        let copies = [URL(fileURLWithPath: "/A/Shoot"), URL(fileURLWithPath: "/B/Shoot")]
        let files = [file("v.mov", kind: .video, camera: "a"), file("p.arw", kind: .photo, camera: "b"),
                     file("s.wav", kind: .audio, camera: "a"), file("x.mov", kind: .video, camera: "")]
        let jobs = ImportPlanner.sortedJobs(files: files, copies: copies, cameras: [cam("a", "FX3"), cam("b", "A7")])
        #expect(jobs.count == 8)
        let first = jobs.filter { $0.root == copies[0] }
        #expect(first.map { $0.destDir.path } == ["/A/Shoot/Video/FX3", "/A/Shoot/Photo/A7", "/A/Shoot/Video/FX3", "/A/Shoot/Video/Other"])
        #expect(jobs.filter { $0.root == copies[1] }.map { $0.destDir.path }.first == "/B/Shoot/Video/FX3")
    }

    // MARK: exactJobs

    @Test func exactJobsMapSubpathOntoEachCopy() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let primary = base.appendingPathComponent("A/Shoot"), mirror = base.appendingPathComponent("B/Shoot")
        let folder = primary.appendingPathComponent("Video/FX3/Day 2")
        let jobs = try ImportPlanner.exactJobs(files: [file("a.mov", kind: .video, camera: "")], copies: [primary, mirror],
                                               primary: primary, folder: folder)
        #expect(jobs.map { $0.destDir.path } == [folder.path, mirror.appendingPathComponent("Video/FX3/Day 2").path])
        #expect(jobs.map(\.root) == [primary, mirror])
    }

    @Test func exactJobsRejectFolderOutsideShootOrReserved() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let primary = base.appendingPathComponent("Shoot")
        try make(primary)
        let files = [file("a.mov", kind: .video, camera: "")]
        for folder in [base.appendingPathComponent("Elsewhere"), primary.appendingPathComponent("../Elsewhere"),
                       primary.appendingPathComponent("Photo/_Rejects"), primary.appendingPathComponent(".auto-cull"),
                       primary.appendingPathComponent("Video/_rejects/sub")] {
            #expect(throws: ImportRefusal.destinationNotInShoot) {
                try ImportPlanner.exactJobs(files: files, copies: [primary], primary: primary, folder: folder)
            }
        }
    }

    @Test func exactJobsRejectSymlinkEscape() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let primary = base.appendingPathComponent("Shoot"), outside = base.appendingPathComponent("Outside")
        try make(primary)
        try make(outside)
        try FileManager.default.createSymbolicLink(at: primary.appendingPathComponent("Video"), withDestinationURL: outside)
        #expect(throws: ImportRefusal.destinationNotInShoot) {
            try ImportPlanner.exactJobs(files: [file("a.mov", kind: .video, camera: "")], copies: [primary],
                                        primary: primary, folder: primary.appendingPathComponent("Video/FX3"))
        }
    }
}
