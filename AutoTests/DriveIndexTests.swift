import Foundation
import Testing
@testable import Auto

struct DriveIndexTests {
    @Test func buildsNameSizeKeysForMediaOnly() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let index = await DriveIndex.build(card.root)
        #expect(index.contains("dsc00001.jpg|1024"))
        #expect(index.contains("dsc00001.arw|4096"))
        #expect(index.contains("c0001.mp4|20000"))
        #expect(!index.contains { $0.hasSuffix(".xml") || $0.contains(".xml|") })
    }

    @Test func emptyFolderGivesEmptyIndex() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await DriveIndex.build(dir).isEmpty)
    }
}
