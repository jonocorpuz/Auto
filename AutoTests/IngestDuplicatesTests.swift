import Foundation
import Testing
@testable import Auto

@MainActor
struct IngestDuplicatesTests {
    private func file(_ name: String, size: Int64 = 100, cardID: String = "card") -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/Volumes/CARD/DCIM/\(name)"), size: size,
                  date: Date(timeIntervalSince1970: 1_700_000_000), kind: .video, cameraID: "cam", cardID: cardID)
    }

    private func shoot(_ name: String, _ roots: String...) -> IngestDuplicates.ShootRoots {
        IngestDuplicates.ShootRoots(id: UUID(), name: name, roots: roots.map { URL(fileURLWithPath: $0) })
    }

    private func copy(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func backupOutsideTargetIsDuplicate() {
        let target = shoot("Target", "/Volumes/A/Target")
        let other = shoot("Other", "/Volumes/A/Other")
        let f = file("C1.MP4")
        let r = IngestDuplicates.find(candidates: [f], backups: [f.url: copy("/Volumes/A/Other/C1.MP4")],
                                      missing: [], shoots: [target, other], target: target.id)
        #expect(r.files == [f])
        #expect(r.bytes == 100)
        #expect(r.byPlace.first?.place.title == "Other")
        #expect(r.byPlace.first?.place.shootID == other.id)
    }

    @Test func backupInsideTargetOrItsMirrorIsNotADuplicate() {
        let target = shoot("Target", "/Volumes/A/Target", "/Volumes/B/Target")
        let a = file("A.MP4"), b = file("B.MP4")
        let r = IngestDuplicates.find(
            candidates: [a, b],
            backups: [a.url: copy("/Volumes/A/Target/Day 1/A.MP4"), b.url: copy("/Volumes/B/Target/B.MP4")],
            missing: [], shoots: [target], target: target.id)
        #expect(r.isEmpty)
        #expect(r.byPlace.isEmpty)
    }

    @Test func nilTargetCountsEverything() {
        let s = shoot("S", "/Volumes/A/S")
        let f = file("A.MP4")
        let r = IngestDuplicates.find(candidates: [f], backups: [f.url: copy("/Volumes/A/S/A.MP4")],
                                      missing: [], shoots: [s], target: nil)
        #expect(r.count == 1)
    }

    @Test func siblingFolderWithSharedPrefixIsNotInsideTarget() {
        let target = shoot("Target", "/Volumes/A/Wedding")
        let f = file("A.MP4")
        let r = IngestDuplicates.find(candidates: [f], backups: [f.url: copy("/Volumes/A/Wedding 2/A.MP4")],
                                      missing: [], shoots: [target], target: target.id)
        #expect(r.count == 1)
    }

    @Test func missingOverridesBackups() {
        let f = file("A.MP4"), g = file("B.MP4")
        let r = IngestDuplicates.find(
            candidates: [f, g],
            backups: [f.url: copy("/Volumes/A/x/A.MP4"), g.url: copy("/Volumes/A/x/B.MP4")],
            missing: [f.url], shoots: [], target: nil)
        #expect(r.files == [g])
    }

    @Test func filesWithoutBackupAreNotDuplicates() {
        let r = IngestDuplicates.find(candidates: [file("A.MP4")], backups: [:], missing: [], shoots: [], target: nil)
        #expect(r.isEmpty)
        #expect(r == IngestDuplicates.Report())
    }

    @Test func placeIsDeepestNestedShoot() {
        let outer = shoot("Outer", "/Volumes/A/Outer")
        let inner = shoot("Inner", "/Volumes/A/Outer/Inner")
        let f = file("A.MP4")
        let r = IngestDuplicates.find(candidates: [f], backups: [f.url: copy("/Volumes/A/Outer/Inner/Day/A.MP4")],
                                      missing: [], shoots: [outer, inner], target: nil)
        #expect(r.byPlace.map(\.place.shootID) == [inner.id])
        // Order of the shoots array must not matter.
        let r2 = IngestDuplicates.find(candidates: [f], backups: [f.url: copy("/Volumes/A/Outer/Inner/Day/A.MP4")],
                                       missing: [], shoots: [inner, outer], target: nil)
        #expect(r2.byPlace.map(\.place.shootID) == [inner.id])
    }

    @Test func nonShootCopyUsesParentFolderTitle() {
        let f = file("A.MP4")
        let r = IngestDuplicates.find(candidates: [f], backups: [f.url: copy("/Volumes/T7-A/Misc/A.MP4")],
                                      missing: [], shoots: [], target: nil)
        let place = r.byPlace.first?.place
        #expect(place?.shootID == nil)
        #expect(place?.drive == "T7-A")
        #expect(place?.title == "T7-A › Misc")
    }

    @Test func byDriveGroupsAndSums() {
        let a1 = file("A1.MP4", size: 10), a2 = file("A2.MP4", size: 20)
        let b1 = file("B1.MP4", size: 40), m1 = file("M1.MP4", size: 80)
        let r = IngestDuplicates.find(
            candidates: [a1, a2, b1, m1],
            backups: [a1.url: copy("/Volumes/A/s/A1.MP4"), a2.url: copy("/Volumes/A/t/A2.MP4"),
                      b1.url: copy("/Volumes/B/s/B1.MP4"), m1.url: copy("/Users/me/Movies/M1.MP4")],
            missing: [], shoots: [], target: nil)
        #expect(r.byDrive == [
            .init(drive: "A", count: 2, bytes: 30),
            .init(drive: "B", count: 1, bytes: 40),
            .init(drive: "This Mac", count: 1, bytes: 80),
        ])
        #expect(r.bytes == 150)
        #expect(r.count == 4)
    }

    @Test func byPlaceSortedByCountDescending() {
        let s1 = shoot("One", "/Volumes/A/One"), s2 = shoot("Two", "/Volumes/A/Two")
        let f1 = file("1.MP4"), f2 = file("2.MP4"), f3 = file("3.MP4")
        let r = IngestDuplicates.find(
            candidates: [f1, f2, f3],
            backups: [f1.url: copy("/Volumes/A/One/1.MP4"), f2.url: copy("/Volumes/A/Two/2.MP4"),
                      f3.url: copy("/Volumes/A/Two/3.MP4")],
            missing: [], shoots: [s1, s2], target: nil)
        #expect(r.byPlace.map(\.place.title) == ["Two", "One"])
        #expect(r.byPlace.map(\.count) == [2, 1])
    }

    @Test func driveNames() {
        #expect(IngestDuplicates.driveName(copy("/Volumes/T7-A/x/y.mp4")) == "T7-A")
        #expect(IngestDuplicates.driveName(copy("/Volumes/T7-A")) == "T7-A")
        #expect(IngestDuplicates.driveName(copy("/Users/me/y.mp4")) == "This Mac")
        #expect(IngestDuplicates.driveName(copy("/Volumes")) == "This Mac")
    }

    // MARK: revalidate

    private func makeCandidate(in dir: URL, name: String, size: Int64 = 100) throws -> (MediaFile, URL) {
        let card = MediaFile(url: URL(fileURLWithPath: "/Volumes/CARD/DCIM/\(name)"), size: size,
                             date: Date(timeIntervalSince1970: 1_700_000_000), kind: .video, cameraID: "cam", cardID: "card")
        let url = dir.appendingPathComponent(name)
        try Data(count: Int(size)).write(to: url)
        return (card, url)
    }

    @Test func revalidateKeepsRecordedCopyAndDropsChangedOrDeleted() async throws {
        let dir = try FixtureCard.makeTempDir("IngestDupes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (keep, keepCopy) = try makeCandidate(in: dir, name: "keep.MP4")
        let (touched, touchedCopy) = try makeCandidate(in: dir, name: "touched.MP4")
        let (gone, goneCopy) = try makeCandidate(in: dir, name: "gone.MP4")
        let (unrecorded, unrecordedCopy) = try makeCandidate(in: dir, name: "unrecorded.MP4")

        let cache = VerificationCache()
        for (f, url) in [(keep, keepCopy), (touched, touchedCopy), (gone, goneCopy)] {
            cache.record(f, candidate: url, mtime: try #require(VerificationCache.modificationDate(url)))
        }
        let backups = [keep.url: keepCopy, touched.url: touchedCopy, gone.url: goneCopy, unrecorded.url: unrecordedCopy]
        let report = IngestDuplicates.find(candidates: [keep, touched, gone, unrecorded], backups: backups,
                                           missing: [], shoots: [], target: nil)
        #expect(report.count == 4)

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(500)],
                                              ofItemAtPath: touchedCopy.path)
        try FileManager.default.removeItem(at: goneCopy)

        let result = await IngestDuplicates.revalidate(report, backups: backups, cache: cache)
        #expect(result.files == [keep])
        #expect(result.bytes == 100)
        #expect(result.byPlace.map(\.count) == [1])
        #expect(result.byDrive.map(\.count) == [1])
        #expect(result.byDrive.first?.bytes == 100)
    }

    @Test func revalidateOfEmptyReportIsEmpty() async {
        let r = await IngestDuplicates.revalidate(.init(), backups: [:], cache: VerificationCache())
        #expect(r.isEmpty)
    }
}
