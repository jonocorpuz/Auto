import Testing
import Foundation
@testable import Auto

struct ShootFoldersTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShootFoldersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func sub(_ parent: URL, _ name: String) throws -> URL {
        let u = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func make(_ name: String, in parent: URL, cards: [URL] = []) throws -> Shoot {
        try ShootFolders.create(name: name, date: day, parent: parent, cardVolumes: cards, calendar: cal)
    }

    @Test func createWritesFolderAndSidecar() throws {
        let parent = try temp()
        let shoot = try make("Wedding", in: parent)
        #expect(shoot.folder.lastPathComponent == "Wedding")
        let sidecar = try #require(try ShootFolders.readSidecar(in: shoot.folder))
        #expect(sidecar.id == shoot.id)
        #expect(sidecar.name == "Wedding")
        #expect(sidecar.day == ShootSidecar.dayString(day, calendar: cal))
    }

    @Test func classifyExistingShoot() throws {
        let parent = try temp()
        let shoot = try make("A", in: parent)
        guard case .existingShoot(let s) = ShootFolders.classify(parent: parent, name: "A") else {
            Issue.record("expected existingShoot"); return
        }
        #expect(s.id == shoot.id)
        #expect(ShootFolders.classify(parent: parent, name: "Nope") == .free)
    }

    @Test func classifyPlainFolder() throws {
        let parent = try temp()
        _ = try sub(parent, "Plain")
        #expect(ShootFolders.classify(parent: parent, name: "Plain") == .plainFolder)
    }

    @Test func classifyFileIsNotAFolder() throws {
        let parent = try temp()
        try Data("x".utf8).write(to: parent.appendingPathComponent("F"))
        #expect(ShootFolders.classify(parent: parent, name: "F") == .notAFolder)
        #expect(throws: ShootError.notAFolder("F")) { try make("F", in: parent) }
    }

    @Test func createRefusesPlainFolder() throws {
        let parent = try temp()
        let plain = try sub(parent, "Plain")
        #expect(throws: ShootError.folderExistsWithoutSidecar("Plain")) { try make("Plain", in: parent) }
        #expect(try ShootFolders.readSidecar(in: plain) == nil)
    }

    @Test func createRefusesExistingShoot() throws {
        let parent = try temp()
        let first = try make("A", in: parent)
        #expect(throws: ShootError.alreadyAShoot(first.id)) { try make("A", in: parent) }
        #expect(try ShootFolders.readSidecar(in: first.folder)?.id == first.id)
    }

    @Test func parentNeverCreated() throws {
        let parent = try temp().appendingPathComponent("missing", isDirectory: true)
        #expect(throws: ShootError.parentMissing) { try make("A", in: parent) }
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }

    @Test func parentOnCardRejected() throws {
        let card = try temp()
        let parent = try sub(card, "Shoots")
        #expect(throws: ShootError.onCard) { try make("A", in: parent, cards: [card]) }
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("A").path))
    }

    @Test func parentSymlinkToCardRejected() throws {
        let card = try temp()
        let root = try temp()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: card)
        #expect(throws: ShootError.onCard) { try make("A", in: link, cards: [card]) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: card.path))?.isEmpty == true)
    }

    @Test func danglingSymlinkParentRejected() throws {
        let root = try temp()
        let target = root.appendingPathComponent("gone")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try make("A", in: link) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func adoptWritesSidecarOnce() throws {
        let parent = try temp()
        let folder = try sub(parent, "Existing")
        let other = folder.appendingPathComponent("clip.mov")
        try Data("footage".utf8).write(to: other)

        let shoot = try ShootFolders.adopt(folder: folder, name: "Existing", date: day, cardVolumes: [], calendar: cal)
        let sidecarURL = folder.appendingPathComponent(ShootSidecar.fileName)
        let original = try Data(contentsOf: sidecarURL)

        #expect(throws: ShootError.alreadyAShoot(shoot.id)) {
            try ShootFolders.adopt(folder: folder, name: "Other", date: day, cardVolumes: [], calendar: cal)
        }
        #expect(try Data(contentsOf: sidecarURL) == original)
        #expect(try Data(contentsOf: other) == Data("footage".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["clip.mov", ShootSidecar.fileName].sorted())
    }

    @Test func adoptRejectsCardFolder() throws {
        let card = try temp()
        let folder = try sub(card, "X")
        #expect(throws: ShootError.onCard) {
            try ShootFolders.adopt(folder: folder, name: "X", date: day, cardVolumes: [card], calendar: cal)
        }
        #expect(try ShootFolders.readSidecar(in: folder) == nil)
    }

    @Test func writeSidecarNeverOverwrites() throws {
        let folder = try temp()
        let a = ShootSidecar(version: 1, id: UUID(), name: "A", day: "2024-01-01", createdAt: day)
        let b = ShootSidecar(version: 1, id: UUID(), name: "B", day: "2024-01-02", createdAt: day)
        try ShootFolders.writeSidecar(a, in: folder)
        #expect(throws: ShootError.alreadyAShoot(a.id)) { try ShootFolders.writeSidecar(b, in: folder) }
        #expect(try ShootFolders.readSidecar(in: folder) == a)
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [ShootSidecar.fileName])
    }

    @Test func arbitraryParentContainment() throws {
        let root = try temp()
        let parent = try sub(root, "parent")
        let shoot = try make("../x", in: parent)
        #expect(ShootPlanner.isInside(shoot.folder, root: parent))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
    }

    @Test func unreadableSidecarNeverAdoptedOrOverwritten() throws {
        let parent = try temp()
        let folder = try sub(parent, "Bad")
        let url = folder.appendingPathComponent(ShootSidecar.fileName)
        let junk = Data("not json".utf8)
        try junk.write(to: url)

        guard case .unreadableShoot(let e) = ShootFolders.classify(parent: parent, name: "Bad") else {
            Issue.record("expected unreadableShoot"); return
        }
        #expect(e == .corruptSidecar)
        #expect(throws: ShootError.corruptSidecar) { try make("Bad", in: parent) }
        #expect(throws: ShootError.corruptSidecar) {
            try ShootFolders.adopt(folder: folder, name: "Bad", date: day, cardVolumes: [], calendar: cal)
        }
        let s = ShootSidecar(version: 1, id: UUID(), name: "Bad", day: "2024-01-01", createdAt: day)
        #expect(throws: (any Error).self) { try ShootFolders.writeSidecar(s, in: folder) }
        #expect(try Data(contentsOf: url) == junk)
    }

    @Test func newerVersionSidecarIsUnreadable() throws {
        let parent = try temp()
        let folder = try sub(parent, "Future")
        let future = ShootSidecar(version: 99, id: UUID(), name: "Future", day: "2024-01-01", createdAt: day)
        let url = folder.appendingPathComponent(ShootSidecar.fileName)
        try ShootSidecar.encode(future).write(to: url)
        #expect(ShootFolders.classify(parent: parent, name: "Future") == .unreadableShoot(.unsupportedVersion(99)))
    }

    private func isEmpty(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]).isEmpty
    }

    @Test func danglingSymlinkAtNameIsNotAFolder() throws {
        let parent = try temp()
        let outside = try temp()
        let target = outside.appendingPathComponent("gone")
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("S"), withDestinationURL: target)
        #expect(ShootFolders.classify(parent: parent, name: "S") == .notAFolder)
        #expect(throws: ShootError.notAFolder("S")) { try make("S", in: parent) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(isEmpty(outside))
    }

    @Test func symlinkToOutsideFolderIsNotAFolder() throws {
        let parent = try temp()
        let outside = try temp()
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("S"), withDestinationURL: outside)
        #expect(ShootFolders.classify(parent: parent, name: "S") == .notAFolder)
        #expect(throws: ShootError.notAFolder("S")) { try make("S", in: parent) }
        #expect(isEmpty(outside))
    }

    @Test func symlinkToInsideFolderIsNotAFolder() throws {
        let parent = try temp()
        let real = try sub(parent, "Real")
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("S"), withDestinationURL: real)
        #expect(ShootFolders.classify(parent: parent, name: "S") == .notAFolder)
        #expect(throws: ShootError.notAFolder("S")) { try make("S", in: parent) }
        #expect(isEmpty(real))
    }

    @Test func adoptSymlinkToCardFolderRejected() throws {
        let card = try temp()
        let cardFolder = try sub(card, "DCIM")
        let root = try temp()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cardFolder)
        #expect(throws: ShootError.onCard) {
            try ShootFolders.adopt(folder: link, name: "X", date: day, cardVolumes: [card], calendar: cal)
        }
        #expect(isEmpty(cardFolder))
        // Even without card knowledge a symlink is never adopted.
        #expect(throws: ShootError.notAFolder("link")) {
            try ShootFolders.adopt(folder: link, name: "X", date: day, cardVolumes: [], calendar: cal)
        }
        #expect(isEmpty(cardFolder))
    }

    @Test func writeSidecarRefusesSymlinkedAndCardFolders() throws {
        let card = try temp()
        let root = try temp()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: card)
        let s = ShootSidecar(version: 1, id: UUID(), name: "A", day: "2024-01-01", createdAt: day)
        #expect(throws: ShootError.notAFolder("link")) { try ShootFolders.writeSidecar(s, in: link) }
        #expect(throws: ShootError.onCard) { try ShootFolders.writeSidecar(s, in: card, cardVolumes: [card]) }
        #expect(isEmpty(card))
    }

    @Test func invalidNameIsNeverFree() throws {
        let parent = try temp()
        #expect(ShootFolders.classify(parent: parent, name: "  ") == .invalidName)
        #expect(throws: ShootError.invalidName) { try make("..", in: parent) }
        #expect(isEmpty(parent))
    }

    @Test func createLeavesNoTempFilesOrPreexistingFolderChanges() throws {
        let parent = try temp()
        let shoot = try make("A", in: parent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: shoot.folder.path) == [ShootSidecar.fileName])
    }

    // MARK: Copies

    private func original(_ name: String = "Wedding") throws -> (ShootSidecar, Data) {
        let home = try temp()
        let shoot = try make(name, in: home)
        let url = shoot.folder.appendingPathComponent(ShootSidecar.fileName)
        return (try #require(try ShootFolders.readSidecar(in: shoot.folder)), try Data(contentsOf: url))
    }

    @Test func createCopyWritesByteIdenticalSidecar() throws {
        let (sidecar, bytes) = try original()
        let other = try temp()
        let folder = try ShootFolders.createCopy(of: sidecar, parent: other, cardVolumes: [])
        #expect(folder.lastPathComponent == "Wedding")
        #expect(try Data(contentsOf: folder.appendingPathComponent(ShootSidecar.fileName)) == bytes)
        let read = try #require(try ShootFolders.readSidecar(in: folder))
        #expect(read.id == sidecar.id && read.createdAt == sidecar.createdAt)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [ShootSidecar.fileName])
    }

    @Test func createCopyRefusesPlainFolderAndWritesNothing() throws {
        let (sidecar, _) = try original()
        let other = try temp()
        let plain = try sub(other, "Wedding")
        #expect(throws: ShootError.folderExistsWithoutSidecar("Wedding")) {
            try ShootFolders.createCopy(of: sidecar, parent: other, cardVolumes: [])
        }
        #expect(isEmpty(plain))
        #expect(ShootFolders.classifyCopy(parent: other, sidecar: sidecar) == .plainFolder)
    }

    @Test func sameIdClassifiesSameShootAndCreateCopyRefuses() throws {
        let (sidecar, bytes) = try original()
        let other = try temp()
        let folder = try ShootFolders.createCopy(of: sidecar, parent: other, cardVolumes: [])
        #expect(ShootFolders.classifyCopy(parent: other, sidecar: sidecar) == .sameShoot)
        #expect(throws: ShootError.alreadyAShoot(sidecar.id)) {
            try ShootFolders.createCopy(of: sidecar, parent: other, cardVolumes: [])
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent(ShootSidecar.fileName)) == bytes)
    }

    @Test func otherIdRefusedWithAlreadyAShoot() throws {
        let (sidecar, _) = try original()
        let other = try temp()
        let rival = try make("Wedding", in: other)
        #expect(ShootFolders.classifyCopy(parent: other, sidecar: sidecar) == .otherShoot(rival.id))
        #expect(throws: ShootError.alreadyAShoot(rival.id)) {
            try ShootFolders.createCopy(of: sidecar, parent: other, cardVolumes: [])
        }
        #expect(throws: ShootError.alreadyAShoot(rival.id)) {
            try ShootFolders.adoptCopy(folder: rival.folder, sidecar: sidecar, cardVolumes: [])
        }
        #expect(try ShootFolders.readSidecar(in: rival.folder)?.id == rival.id)
    }

    @Test func createCopyOnCardRejected() throws {
        let (sidecar, _) = try original()
        let card = try temp()
        let parent = try sub(card, "Shoots")
        #expect(throws: ShootError.onCard) {
            try ShootFolders.createCopy(of: sidecar, parent: parent, cardVolumes: [card])
        }
        #expect(isEmpty(parent))
    }

    @Test func classifyCopyOtherCases() throws {
        let (sidecar, _) = try original()
        let parent = try temp()
        #expect(ShootFolders.classifyCopy(parent: parent, sidecar: sidecar) == .free)
        try Data("x".utf8).write(to: parent.appendingPathComponent("Wedding"))
        #expect(ShootFolders.classifyCopy(parent: parent, sidecar: sidecar) == .notAFolder)
        let bad = try temp()
        let folder = try sub(bad, "Wedding")
        try Data("junk".utf8).write(to: folder.appendingPathComponent(ShootSidecar.fileName))
        #expect(ShootFolders.classifyCopy(parent: bad, sidecar: sidecar) == .unreadable(.corruptSidecar))
    }

    @Test func adoptCopyPlainFolderWritesIdenticalSidecarKeepingFiles() throws {
        let (sidecar, bytes) = try original()
        let parent = try temp()
        let folder = try sub(parent, "Handmade")
        try Data("footage".utf8).write(to: folder.appendingPathComponent("clip.mov"))
        try ShootFolders.adoptCopy(folder: folder, sidecar: sidecar, cardVolumes: [])
        #expect(try Data(contentsOf: folder.appendingPathComponent(ShootSidecar.fileName)) == bytes)
        #expect(try Data(contentsOf: folder.appendingPathComponent("clip.mov")) == Data("footage".utf8))
        // Same id again: accepted, no write.
        try ShootFolders.adoptCopy(folder: folder, sidecar: sidecar, cardVolumes: [])
        #expect(try Data(contentsOf: folder.appendingPathComponent(ShootSidecar.fileName)) == bytes)
    }

    @Test func adoptCopyRefusesCardUnreadableAndSymlink() throws {
        let (sidecar, _) = try original()
        let card = try temp()
        let cardFolder = try sub(card, "X")
        #expect(throws: ShootError.onCard) {
            try ShootFolders.adoptCopy(folder: cardFolder, sidecar: sidecar, cardVolumes: [card])
        }
        #expect(isEmpty(cardFolder))

        let parent = try temp()
        let bad = try sub(parent, "Bad")
        let junk = Data("not json".utf8)
        try junk.write(to: bad.appendingPathComponent(ShootSidecar.fileName))
        #expect(throws: ShootError.corruptSidecar) {
            try ShootFolders.adoptCopy(folder: bad, sidecar: sidecar, cardVolumes: [])
        }
        #expect(try Data(contentsOf: bad.appendingPathComponent(ShootSidecar.fileName)) == junk)

        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bad)
        #expect(throws: (any Error).self) {
            try ShootFolders.adoptCopy(folder: link, sidecar: sidecar, cardVolumes: [])
        }
    }

    @Test func newShootErrorsHaveMessages() {
        let e = ShootError.partialCreate(created: ["T7-A"], failed: [.init(name: "T7-B", reason: "full")])
        #expect(e.errorDescription?.contains("T7-A") == true && e.errorDescription?.contains("T7-B: full") == true)
        #expect(ShootError.sameVolumeAsCopy.errorDescription != nil)
        #expect(ShootError.alreadyRegistered.errorDescription != nil)
        #expect(ShootError.lastCopy.errorDescription != nil)
    }
}
