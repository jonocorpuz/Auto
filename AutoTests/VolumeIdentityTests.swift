import Foundation
import Testing
@testable import Auto

struct VolumeIdentityTests {
    @Test func fixtureFolderIsIdentifiedByPath() throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let id = VolumeIdentity.of(card.root)
        #expect(id == "path@\(VolumeClassifier.normalizedPath(card.root))")
        // Stable across calls and trailing slashes.
        #expect(VolumeIdentity.of(URL(fileURLWithPath: card.root.path + "/")) == id)
    }

    @Test func differentFoldersHaveDifferentIdentities() throws {
        let a = try FixtureCard(), b = try FixtureCard()
        defer { a.cleanup(); b.cleanup() }
        #expect(VolumeIdentity.of(a.root) != VolumeIdentity.of(b.root))
    }

    @Test func scannedFilesCarryTheCardIdentity() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let result = await CardScanner.scan(card.root, volumeName: "NO NAME")
        #expect(!result.files.isEmpty)
        #expect(result.files.allSatisfy { $0.cardID == VolumeIdentity.of(card.root) })
    }
}
