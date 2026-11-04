import Foundation
import Testing
@testable import Auto

struct CardBrowserTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ name: String, _ offset: TimeInterval = 0) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/Volumes/CARD/DCIM/\(name)"), size: 10,
                  date: t0.addingTimeInterval(offset), kind: .video, cameraID: "cam")
    }

    private let shootA = CardBrowser.ShootRef(id: UUID(), name: "Wedding", folder: URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding"))
    private let shootB = CardBrowser.ShootRef(id: UUID(), name: "Promo", folder: URL(fileURLWithPath: "/Volumes/Work/Shoots/Promo"))

    @Test func everythingMissingIsOneNotBackedUpGroup() {
        let groups = CardBrowser.group(files: [file("B.MP4", 5), file("A.MP4")], backups: [:], shoots: [shootA])
        #expect(groups.map(\.kind) == [.notBackedUp])
        #expect(groups[0].files.map(\.name) == ["A.MP4", "B.MP4"])
    }

    @Test func backedUpFilesGroupByShootInShootOrder() {
        let a = file("A.MP4"), b = file("B.MP4"), c = file("C.MP4"), d = file("D.MP4")
        let backups: [URL: URL] = [
            a.url: URL(fileURLWithPath: "/Volumes/Work/Shoots/Promo/Video/FX3/A.MP4"),
            b.url: URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding/Video/FX3/B.MP4"),
            c.url: URL(fileURLWithPath: "/Volumes/Work/Loose/C.MP4"),
        ]
        let groups = CardBrowser.group(files: [a, b, c, d], backups: backups, shoots: [shootA, shootB])
        #expect(groups.map(\.kind) == [.notBackedUp, .shoot(shootA.id), .shoot(shootB.id), .elsewhere])
        #expect(groups.map { $0.files.map(\.name) } == [["D.MP4"], ["B.MP4"], ["A.MP4"], ["C.MP4"]])
    }

    @Test func noNotBackedUpGroupWhenAllBacked() {
        let a = file("A.MP4")
        let groups = CardBrowser.group(files: [a], backups: [a.url: shootA.folder.appendingPathComponent("A.MP4")], shoots: [shootA])
        #expect(groups.map(\.kind) == [.shoot(shootA.id)])
        #expect(groups[0].title == "Wedding")
        #expect(groups[0].bytes == 10)
    }

    @Test func siblingFolderWithSharedPrefixIsNotInsideShoot() {
        let a = file("A.MP4")
        let groups = CardBrowser.group(files: [a], backups: [a.url: URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding2/A.MP4")],
                                       shoots: [shootA])
        #expect(groups.map(\.kind) == [.elsewhere])
    }

    @Test func nestedShootWinsOverParent() {
        let parent = CardBrowser.ShootRef(id: UUID(), name: "Parent", folder: URL(fileURLWithPath: "/Volumes/Work/Shoots"))
        let a = file("A.MP4")
        let groups = CardBrowser.group(files: [a], backups: [a.url: shootA.folder.appendingPathComponent("A.MP4")],
                                       shoots: [parent, shootA])
        #expect(groups.map(\.kind) == [.shoot(shootA.id)])
    }
}
