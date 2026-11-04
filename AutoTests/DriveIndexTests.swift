import Foundation
import Testing
@testable import Auto

struct DriveIndexTests {
    @Test func buildsNameSizeKeysForMediaOnly() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let index = await DriveIndex.build(card.root)
        #expect(index["dsc00001.jpg|1024"]?.count == 1)
        #expect(index["dsc00001.arw|4096"]?.count == 1)
        #expect(index["c0001.mp4|20000"]?.count == 1)
        #expect(!index.keys.contains { $0.contains(".xml|") })
    }

    @Test func collectsEveryCandidateWithTheSameNameAndSize() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for sub in ["a", "b"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("\(sub)/A001.ARW"))
        }
        let index = await DriveIndex.build(dir)
        #expect(index["a001.arw|10"]?.count == 2)
    }

    @Test func emptyFolderGivesEmptyIndex() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await DriveIndex.build(dir).isEmpty)
    }
}
