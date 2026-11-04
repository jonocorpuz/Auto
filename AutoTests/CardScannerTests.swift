import Foundation
import Testing
@testable import Auto

struct CardScannerTests {
    @Test(arguments: [
        ("ILME-FX3", "FX3"), ("ILCE-7SM3", "A7SM3"), ("Canon EOS R5", "R5"),
        ("NIKON Z 6", "Z 6"), ("  ILME-FX3 \n", "FX3"), ("A/B:C", "A-B-C"),
    ])
    func friendlyName(raw: String, expected: String) {
        #expect(CardScanner.friendlyName(raw) == expected)
    }

    @Test func scanFindsMediaAndSkipsThumbnails() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let result = await CardScanner.scan(card.root, volumeName: "NO NAME")

        let names = result.files.map(\.name).sorted()
        #expect(names == ["C0001.MP4", "DSC00001.ARW", "DSC00001.JPG"])
        #expect(!result.files.contains { $0.url.path.contains("THMBNL") })

        let kinds = Dictionary(uniqueKeysWithValues: result.files.map { ($0.name, $0.kind) })
        #expect(kinds["C0001.MP4"] == .video)
        #expect(kinds["DSC00001.ARW"] == .photo)
        #expect(kinds["DSC00001.JPG"] == .photo)
    }

    @Test func detectsSonySidecarCamera() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let result = await CardScanner.scan(card.root, volumeName: "NO NAME")

        let fx3 = try #require(result.cameras.first { $0.model == "FX3" })
        #expect(fx3.serial == "1234567")
        #expect(fx3.label == "FX3 · serial ...4567")
        let clip = try #require(result.files.first { $0.name == "C0001.MP4" })
        #expect(clip.cameraID == fx3.id)
        // Photos have no EXIF, so they fall back to the volume name.
        #expect(result.cameras.contains { $0.model == "NO NAME" })
    }

    @Test func shootDateIsEarliestFileDate() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let result = await CardScanner.scan(card.root, volumeName: "NO NAME")
        let shoot = try #require(result.shootDate)
        #expect(abs(shoot.timeIntervalSince(FixtureCard.clipDate)) < 1)
    }

    @Test func cleanScanHasNoError() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        #expect(await CardScanner.scan(card.root, volumeName: "NO NAME").error == nil)
    }

    @Test func unreadableFolderIsReportedNotSilentlySkipped() async throws {
        let card = try FixtureCard()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.clip.path)
            card.cleanup()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: card.clip.path)
        let result = await CardScanner.scan(card.root, volumeName: "NO NAME")
        #expect(result.error != nil)
        #expect(CardPhase.afterScan(fileCount: result.files.count, error: result.error) != nil)
    }

    @Test func missingVolumeIsAnErrorNotAnEmptyCard() async throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("AutoGone-\(UUID().uuidString)")
        let result = await CardScanner.scan(gone, volumeName: "X")
        #expect(result.files.isEmpty)
        #expect(result.error != nil)
    }
}
