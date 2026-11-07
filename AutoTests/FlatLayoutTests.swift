import CryptoKit
import Foundation
import Testing
@testable import Auto

/// Flat shoot layout: planning, collision renames, CopyEngine's requested name, and re-run coverage.
struct FlatLayoutTests {
    private func file(_ path: String, kind: MediaKind, camera: String, card: String = "") -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: path), size: 10, date: Date(timeIntervalSince1970: 1_600_000_000), kind: kind,
                  cameraID: camera, cardID: card)
    }

    private let cams = [Camera(id: "a", model: "R5", serial: nil, folderName: "R5"),
                        Camera(id: "b", model: "R6", serial: nil, folderName: "R6")]

    /// Camera A and camera B each shot IMG_1 as RAW+JPEG.
    private func collidingPairs() -> [MediaFile] {
        [file("/cardA/DCIM/IMG_1.CR3", kind: .photo, camera: "a", card: "A"),
         file("/cardA/DCIM/IMG_1.JPG", kind: .photo, camera: "a", card: "A"),
         file("/cardB/DCIM/IMG_1.CR3", kind: .photo, camera: "b", card: "B"),
         file("/cardB/DCIM/IMG_1.JPG", kind: .photo, camera: "b", card: "B")]
    }

    private func names(_ jobs: [CopyJob]) -> [String] { jobs.map { $0.destName ?? $0.file.name } }

    // MARK: Planner

    @Test func flatPutsVideoAndPhotoStraightIntoTheirSection() {
        let files = [file("/c/C0001.MP4", kind: .video, camera: "a"), file("/c/IMG_2.CR3", kind: .photo, camera: "b"),
                     file("/c/A.WAV", kind: .audio, camera: "a")]
        let jobs = ShootPlanner.jobs(missing: files, shoot: URL(fileURLWithPath: "/w/s"), cameras: cams, fallback: "CARD", layout: .flat)
        #expect(jobs.map(\.destDir.path) == ["/w/s/Video", "/w/s/Photo", "/w/s/Video"])
        #expect(jobs.allSatisfy { $0.destName == nil })
    }

    @Test func unknownCamerasAreFlatToo() {
        let files = [file("/c/C0001.MP4", kind: .video, camera: "?"), file("/c/IMG_2.JPG", kind: .photo, camera: "?")]
        let jobs = ShootPlanner.jobs(missing: files, shoot: URL(fileURLWithPath: "/w/s"), cameras: [], fallback: "CARD", layout: .flat)
        #expect(jobs.map(\.destDir.path) == ["/w/s/Video", "/w/s/Photo"])
    }

    @Test func crossCameraStemCollisionRenamesTheWholeLaterSet() {
        let jobs = ShootPlanner.jobs(missing: collidingPairs(), shoot: URL(fileURLWithPath: "/w/s"), cameras: cams,
                                     fallback: "CARD", layout: .flat)
        #expect(names(jobs) == ["IMG_1.CR3", "IMG_1.JPG", "IMG_1 2.CR3", "IMG_1 2.JPG"])
        #expect(jobs[0].destName == nil && jobs[1].destName == nil)
    }

    @Test func collisionWinnerDoesNotDependOnInputOrder() {
        let jobs = ShootPlanner.jobs(missing: collidingPairs().reversed(), shoot: URL(fileURLWithPath: "/w/s"), cameras: cams,
                                     fallback: "CARD", layout: .flat)
        #expect(names(jobs) == ["IMG_1 2.JPG", "IMG_1 2.CR3", "IMG_1.JPG", "IMG_1.CR3"])
    }

    @Test func renameSkipsAStemAlreadyPlannedInTheFolder() {
        let files = collidingPairs() + [file("/cardC/IMG_1 2.JPG", kind: .photo, camera: "c", card: "C")]
        let jobs = ShootPlanner.jobs(missing: files, shoot: URL(fileURLWithPath: "/w/s"), cameras: cams, fallback: "CARD", layout: .flat)
        #expect(names(jobs) == ["IMG_1.CR3", "IMG_1.JPG", "IMG_1 3.CR3", "IMG_1 3.JPG", "IMG_1 2.JPG"])
    }

    @Test func caseOnlyStemDifferencesCollide() {
        let files = [file("/cardA/img_1.jpg", kind: .photo, camera: "a"), file("/cardB/IMG_1.JPG", kind: .photo, camera: "b")]
        let jobs = ShootPlanner.jobs(missing: files, shoot: URL(fileURLWithPath: "/w/s"), cameras: cams, fallback: "CARD", layout: .flat)
        #expect(names(jobs) == ["img_1.jpg", "IMG_1 2.JPG"])
    }

    @Test func differentSectionsNeverCollide() {
        let files = [file("/cardA/X.JPG", kind: .photo, camera: "a"), file("/cardB/X.MP4", kind: .video, camera: "b")]
        let jobs = ShootPlanner.jobs(missing: files, shoot: URL(fileURLWithPath: "/w/s"), cameras: cams, fallback: "CARD", layout: .flat)
        #expect(jobs.allSatisfy { $0.destName == nil })
    }

    @Test func everyCopyRootGetsTheSameNames() {
        let copies = [URL(fileURLWithPath: "/a/s"), URL(fileURLWithPath: "/b/s")]
        let jobs = ShootPlanner.jobs(missing: collidingPairs(), copies: copies, cameras: cams, fallback: "CARD", layout: .flat)
        #expect(jobs.count == 8)
        #expect(jobs.map(\.root) == [copies[0], copies[1], copies[0], copies[1], copies[0], copies[1], copies[0], copies[1]])
        #expect(jobs.map(\.destDir.path) == ["/a/s/Photo", "/b/s/Photo", "/a/s/Photo", "/b/s/Photo",
                                             "/a/s/Photo", "/b/s/Photo", "/a/s/Photo", "/b/s/Photo"])
        #expect(names(jobs) == ["IMG_1.CR3", "IMG_1.CR3", "IMG_1.JPG", "IMG_1.JPG",
                                "IMG_1 2.CR3", "IMG_1 2.CR3", "IMG_1 2.JPG", "IMG_1 2.JPG"])
    }

    @Test func cameraFoldersOutputIsUnchanged() {
        let shoot = URL(fileURLWithPath: "/w/s")
        let byDefault = ShootPlanner.jobs(missing: collidingPairs(), shoot: shoot, cameras: cams, fallback: "CARD")
        let explicit = ShootPlanner.jobs(missing: collidingPairs(), shoot: shoot, cameras: cams, fallback: "CARD", layout: .cameraFolders)
        for jobs in [byDefault, explicit] {
            #expect(jobs.map(\.destDir.path) == ["/w/s/Photo/R5", "/w/s/Photo/R5", "/w/s/Photo/R6", "/w/s/Photo/R6"])
            #expect(jobs.allSatisfy { $0.destName == nil })
        }
    }

    @Test func importSortedJobsFlat() {
        let copies = [URL(fileURLWithPath: "/p/s"), URL(fileURLWithPath: "/m/s")]
        let files = [file("/x/IMG_9.JPG", kind: .photo, camera: "a"), file("/x/C1.MP4", kind: .video, camera: "?")]
        let jobs = ImportPlanner.sortedJobs(files: files, copies: copies, cameras: cams, layout: .flat)
        #expect(jobs.map(\.destDir.path) == ["/p/s/Photo", "/m/s/Photo", "/p/s/Video", "/m/s/Video"])
        #expect(jobs.map(\.root) == [copies[0], copies[1], copies[0], copies[1]])
        let sorted = ImportPlanner.sortedJobs(files: files, copies: copies, cameras: cams)
        #expect(sorted.map(\.destDir.path) == ["/p/s/Photo/R5", "/m/s/Photo/R5", "/p/s/Video/Other", "/m/s/Video/Other"])
    }

    // MARK: CopyEngine

    private func md5(_ url: URL) throws -> Data { Data(Insecure.MD5.hash(data: try Data(contentsOf: url))) }

    private func sourceFile(_ dir: URL, _ name: String, fill: UInt8) throws -> MediaFile {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: fill, count: 500).write(to: url)
        return MediaFile(url: url, size: 500, date: Date(), kind: .photo, cameraID: "b")
    }

    @Test func copyEngineHonoursDestName() async throws {
        let src = try FixtureCard.makeTempDir("FlatSrc"), dst = try FixtureCard.makeTempDir("FlatDst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let f = try sourceFile(src, "IMG_1.CR3", fill: 0x11)
        var job = CopyJob(file: f, destDir: dst.appendingPathComponent("Photo"), root: dst)
        job.destName = "IMG_1 2.CR3"
        let outcome = await CopyEngine().run([job]) { _ in }
        let expected = dst.appendingPathComponent("Photo/IMG_1 2.CR3")
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.first?.destination.standardizedFileURL == expected.standardizedFileURL)
        #expect(try md5(expected) == md5(f.url))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("Photo/IMG_1.CR3").path))
    }

    @Test func takenDestNameGetsAUniqueSiblingAndIsNeverOverwritten() async throws {
        let src = try FixtureCard.makeTempDir("FlatSrc"), dst = try FixtureCard.makeTempDir("FlatDst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let f = try sourceFile(src, "IMG_1.CR3", fill: 0x11)
        let existing = dst.appendingPathComponent("IMG_1 2.CR3")
        let before = Data(repeating: 0x99, count: 500)
        try before.write(to: existing)
        var job = CopyJob(file: f, destDir: dst)
        job.destName = "IMG_1 2.CR3"
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(try Data(contentsOf: existing) == before)
        // CopyEngine's own unique-name rule applies to the requested name.
        let unique = dst.appendingPathComponent("IMG_1 2 2.CR3")
        #expect(outcome.copied.first?.destination == unique)
        #expect(try md5(unique) == md5(f.url))
    }

    @Test func identicalFileAtDestNameIsKeptNotDuplicated() async throws {
        let src = try FixtureCard.makeTempDir("FlatSrc"), dst = try FixtureCard.makeTempDir("FlatDst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let f = try sourceFile(src, "IMG_1.CR3", fill: 0x11)
        try Data(repeating: 0x11, count: 500).write(to: dst.appendingPathComponent("IMG_1 2.CR3"))
        var job = CopyJob(file: f, destDir: dst)
        job.destName = "IMG_1 2.CR3"
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.copied.first?.preexisting == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["IMG_1 2.CR3"])
    }

    @Test(arguments: ["../IMG_1.CR3", "a/b.CR3", ".hidden.CR3", ""])
    func destNameMustBeOnePlainComponent(_ name: String) async throws {
        let src = try FixtureCard.makeTempDir("FlatSrc"), dst = try FixtureCard.makeTempDir("FlatDst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let f = try sourceFile(src, "IMG_1.CR3", fill: 0x11)
        let inner = dst.appendingPathComponent("Photo")
        var job = CopyJob(file: f, destDir: inner, root: dst)
        job.destName = name
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inner.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["Photo"])
    }

    // MARK: Re-run coverage of renamed copies

    @Test func originalNameOfRenamedCopies() {
        #expect(DriveIndex.originalName("IMG_1 2.CR3") == "IMG_1.CR3")
        #expect(DriveIndex.originalName("img_1 13.jpg") == "img_1.jpg")
        #expect(DriveIndex.originalName("A 2") == "A")
        #expect(DriveIndex.originalName("IMG_1.CR3") == nil)
        #expect(DriveIndex.originalName("IMG 1.CR3") == nil)
        #expect(DriveIndex.originalName("IMG 02.CR3") == nil)
        #expect(DriveIndex.originalName(" 2.CR3") == nil)
        let aliases = DriveIndex.renamedAliases(["img_1 2 2.cr3|5": [URL(fileURLWithPath: "/d/IMG_1 2 2.CR3")]])
        #expect(aliases["img_1 2.cr3|5"]?.count == 1)
        #expect(aliases["img_1.cr3|5"]?.count == 1)
    }

    @Test func renamedCopyStillVerifiesTheCardFileOnAFreshRun() async throws {
        let card = try FixtureCard.makeTempDir("FlatCard"), drive = try FixtureCard.makeTempDir("FlatDrive")
        defer { try? FileManager.default.removeItem(at: card); try? FileManager.default.removeItem(at: drive) }
        let fm = FileManager.default
        try fm.createDirectory(at: drive.appendingPathComponent("Photo"), withIntermediateDirectories: true)
        let mine = try sourceFile(card, "IMG_1.CR3", fill: 0x22)
        // Another camera's IMG_1 kept the plain name; this card's copy was renamed.
        try Data(repeating: 0x33, count: 500).write(to: drive.appendingPathComponent("Photo/IMG_1.CR3"))
        let renamed = drive.appendingPathComponent("Photo/IMG_1 2.CR3")
        try Data(repeating: 0x22, count: 500).write(to: renamed)

        let index = await DriveIndex.build(drive)
        let triage = BackupVerifier.triage(files: [mine], candidates: index)
        #expect(triage.toVerify.map(\.url) == [mine.url])
        let outcome = await BackupVerifier().run(triage.toVerify, candidates: index) { _ in }
        guard case .verified(let hit) = outcome.results[mine.url] else { Issue.record("not verified"); return }
        #expect(hit.lastPathComponent == "IMG_1 2.CR3")
    }

    @Test func renamedCopyWithDifferentBytesNeverCounts() async throws {
        let card = try FixtureCard.makeTempDir("FlatCard"), drive = try FixtureCard.makeTempDir("FlatDrive")
        defer { try? FileManager.default.removeItem(at: card); try? FileManager.default.removeItem(at: drive) }
        let mine = try sourceFile(card, "IMG_1.CR3", fill: 0x22)
        try Data(repeating: 0x44, count: 500).write(to: drive.appendingPathComponent("IMG_1 2.CR3"))
        let index = await DriveIndex.build(drive)
        let outcome = await BackupVerifier().run([mine], candidates: index) { _ in }
        #expect(outcome.results[mine.url] == .mismatch)
    }

    // MARK: PhotoCatalog

    private func touch(_ f: FixtureShoot, _ rel: String, _ date: Date) throws {
        let url = f.add(rel)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func flatPairWithinFiveSecondsIsOnePhoto() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try touch(f, "Photo/IMG_1.CR3", t)
        try touch(f, "Photo/IMG_1.JPG", t.addingTimeInterval(3))
        let r = try PhotoCatalog.scan(shoot: f.root, cardVolumes: [])
        #expect(r.count == 1)
        #expect(r.first?.members == ["Photo/IMG_1.CR3", "Photo/IMG_1.JPG"])
        #expect(r.first?.camera == "")
    }

    @Test func flatSameStemAnHourApartIsTwoPhotos() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try touch(f, "Photo/IMG_1.CR3", t)
        try touch(f, "Photo/IMG_1.JPG", t.addingTimeInterval(3_600))
        let r = try PhotoCatalog.scan(shoot: f.root, cardVolumes: [])
        #expect(r.count == 2)
        #expect(Set(r.map(\.id)) == ["Photo/IMG_1.CR3", "Photo/IMG_1.JPG"])
        #expect(r.allSatisfy { $0.members.count == 1 })
    }

    @Test func cameraFolderPairIgnoresTimeGap() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try touch(f, "Photo/R5/IMG_1.CR3", t)
        try touch(f, "Photo/R5/IMG_1.JPG", t.addingTimeInterval(3_600))
        let r = try PhotoCatalog.scan(shoot: f.root, cardVolumes: [])
        #expect(r.count == 1)
        #expect(r.first?.members.count == 2)
        #expect(r.first?.representative == "Photo/R5/IMG_1.JPG")
    }
}
