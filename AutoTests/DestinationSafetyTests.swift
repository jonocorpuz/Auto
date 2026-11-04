import Foundation
import Testing
@testable import Auto

struct DestinationSafetyTests {
    private func temp() throws -> URL { try FixtureCard.makeTempDir("AutoDest") }
    private func contents(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    @Test func symlinkIntoCardIsRejectedBeforeCreating() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), card = base.appendingPathComponent("card")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("shoot"), withIntermediateDirectories: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("shoot/Video"), withDestinationURL: card)
        #expect(throws: ShootPlanner.PathError.onCard) {
            try ShootPlanner.createDirectories([root.appendingPathComponent("shoot/Video/FX3")], root: root, cardVolumes: [card])
        }
        #expect(contents(card).isEmpty)
    }

    @Test func symlinkOutsideRootIsRejected() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), other = base.appendingPathComponent("other")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("shoot"), withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("shoot/Video"), withDestinationURL: other)
        #expect(throws: ShootPlanner.PathError.outsideWorkFolder) {
            try ShootPlanner.createDirectories([root.appendingPathComponent("shoot/Video/FX3")], root: root, cardVolumes: [])
        }
        #expect(contents(other).isEmpty)
    }

    @Test func regularFileAtShootPathThrowsNotAFolder() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("shoot"))
        #expect(throws: ShootPlanner.PathError.notAFolder("shoot")) {
            try ShootPlanner.createDirectories([root.appendingPathComponent("shoot/Video")], root: root, cardVolumes: [])
        }
    }

    @Test func problemReportsFileInPath() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        try Data([1]).write(to: base.appendingPathComponent("shoot"))
        #expect(ShootPlanner.problem(for: [base.appendingPathComponent("shoot/Video/FX3")]) == .notAFolder("shoot"))
        #expect(ShootPlanner.problem(for: [base.appendingPathComponent("fine/Video")]) == nil)
    }

    @Test func flatPlanRootEqualsDirIsAllowed() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        try ShootPlanner.checkDestination(base, root: base, cardVolumes: [])
        try ShootPlanner.createDirectories([base], root: base, cardVolumes: [])
    }

    @Test func createsNestedFoldersNormally() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let shoot = base.appendingPathComponent("shoot")
        try ShootPlanner.createDirectories([shoot.appendingPathComponent("Video/FX3"), shoot.appendingPathComponent("Photo/A7")], root: base, cardVolumes: [])
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: shoot.appendingPathComponent("Video/FX3").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: shoot.appendingPathComponent("Photo/A7").path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func missingRootIsNeverCreated() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("gone/root")
        #expect(throws: ShootPlanner.PathError.workFolderMissing) {
            try ShootPlanner.createDirectories([root.appendingPathComponent("shoot/Video")], root: root, cardVolumes: [])
        }
        #expect(contents(base).isEmpty)
    }

    @Test func rootThatIsAFileThrows() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try Data([1]).write(to: root)
        #expect(throws: ShootPlanner.PathError.workFolderMissing) {
            try ShootPlanner.createDirectories([root.appendingPathComponent("shoot")], root: root, cardVolumes: [])
        }
    }

    @Test func shootLevelSymlinkIntoCardIsRejected() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), card = base.appendingPathComponent("card")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("shoot"), withDestinationURL: card)
        #expect(throws: ShootPlanner.PathError.onCard) {
            try ShootPlanner.createDirectories([root.appendingPathComponent("shoot/Video/FX3")], root: root, cardVolumes: [card])
        }
        #expect(contents(card).isEmpty)
    }

    @Test func danglingCameraSymlinkCreatesNothing() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), elsewhere = base.appendingPathComponent("elsewhere/new")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("shoot/Video"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("shoot/Video/FX3"), withDestinationURL: elsewhere)
        #expect(throws: ShootPlanner.PathError.outsideWorkFolder) {
            try ShootPlanner.createDirectories([root.appendingPathComponent("shoot/Video/FX3")], root: root, cardVolumes: [])
        }
        #expect(!fm.fileExists(atPath: base.appendingPathComponent("elsewhere").path))
    }

    @Test func dotDotInDestinationIsRejected() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: ShootPlanner.PathError.outsideWorkFolder) {
            try ShootPlanner.checkDestination(root.appendingPathComponent("shoot/../../outside"), root: root, cardVolumes: [])
        }
    }
}
