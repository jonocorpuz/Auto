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
        #expect(fx3.label == "FX3")
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

    @Test func labelNeverContainsSerial() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        let result = await CardScanner.scan(card.root, volumeName: "NO NAME")
        for cam in result.cameras {
            #expect(!cam.label.contains("serial"))
            #expect(!cam.label.contains("4567"))
            #expect(!cam.folderName.contains("4567"))
        }
    }

    @Test func sameModelBodiesGetLetterSuffixes() {
        let a = Camera(id: "FX3|111", model: "FX3", serial: "111", folderName: "FX3")
        let b = Camera(id: "FX3|222", model: "FX3", serial: "222", folderName: "FX3")
        let solo = Camera(id: "A7|9", model: "A7", serial: "9", folderName: "A7")
        let forward = Camera.disambiguated([a, b, solo])
        let shuffled = Camera.disambiguated([solo, b, a])
        for out in [forward, shuffled] {
            let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
            #expect(byID["FX3|111"]?.label == "FX3 A")
            #expect(byID["FX3|111"]?.folderName == "FX3 A")
            #expect(byID["FX3|222"]?.label == "FX3 B")
            #expect(byID["FX3|222"]?.folderName == "FX3 B")
            #expect(byID["A7|9"]?.label == "A7")
            #expect(byID["A7|9"]?.folderName == "A7")
        }
        #expect(forward.map(\.id) == ["FX3|111", "FX3|222", "A7|9"])
        #expect(shuffled.map(\.id) == ["A7|9", "FX3|222", "FX3|111"])
    }
}
