import Foundation
import Testing
@testable import Auto

struct MediaTypesTests {
    @Test(arguments: [
        ("a.MP4", MediaKind.video), ("a.mov", .video), ("a.BRAW", .video), ("a.mxf", .video),
        ("a.JPG", .photo), ("a.arw", .photo), ("a.CR3", .photo), ("a.heic", .photo), ("a.dng", .photo),
        ("a.wav", .audio), ("a.M4A", .audio),
    ])
    func classifies(name: String, expected: MediaKind) {
        #expect(MediaTypes.kind(for: URL(fileURLWithPath: "/x/\(name)")) == expected)
    }

    @Test(arguments: ["a.xml", "a.txt", "a", "a.thm", ".DS_Store"])
    func ignoresNonMedia(name: String) {
        #expect(MediaTypes.kind(for: URL(fileURLWithPath: "/x/\(name)")) == nil)
    }

    @Test func skippedFoldersIncludeThumbnails() {
        #expect(MediaTypes.skippedFolders.contains("thmbnl"))
    }

    @Test func fileKeyIsCaseInsensitiveNameAndSize() {
        #expect(MediaFile.key(name: "C0001.MP4", size: 10) == "c0001.mp4|10")
    }
}
