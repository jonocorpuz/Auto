import Foundation
import Testing
@testable import Auto

struct VideoCatalogTests {
    private func shoot(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcat-\(UUID().uuidString)")
        for f in files {
            let url = root.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        return root
    }

    @Test func listsClipsAndRecordingsByCamera() throws {
        let root = try shoot(["Video/A7SIII/C0001.MP4", "Video/ZOOM/ZOOM0001.WAV", "Video/A7V/A7501.MP4",
                              "Video/_Rejects/A7SIII/C0009.MP4", "Video/A7SIII/.C0002.MP4", "Video/A7SIII/C0001.XML",
                              "Video/A7SIII/THMBNL/C0001.MP4", "Photo/A7V/DSC1.JPG", "Video/loose.mov"])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try VideoCatalog.scan(shoot: root, cardVolumes: [])
        #expect(s == [
            AudioSyncSource(id: "Video/A7SIII/C0001.MP4", camera: "A7SIII", kind: .video),
            AudioSyncSource(id: "Video/A7V/A7501.MP4", camera: "A7V", kind: .video),
            AudioSyncSource(id: "Video/ZOOM/ZOOM0001.WAV", camera: "ZOOM", kind: .audio),
            AudioSyncSource(id: "Video/loose.mov", camera: "", kind: .video),
        ])
    }

    @Test func noVideoFolderIsEmptyAndCardsAreRefused() throws {
        let root = try shoot(["Photo/a.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try VideoCatalog.scan(shoot: root, cardVolumes: []).isEmpty)
        #expect(throws: VideoEditError.onCard) { try VideoCatalog.scan(shoot: root, cardVolumes: [root]) }
    }
}
