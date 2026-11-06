import CoreGraphics
import Foundation
import Testing
@testable import Auto

struct ShootSummaryTests {
    private func makeFolder(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        for f in files {
            let url = root.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func countsVideoAndPhoto() async throws {
        let root = try makeFolder(["a/one.mp4", "a/two.MOV", "b/p.jpg", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await ShootSummary.scan(root)
        #expect(s.videoCount == 2)
        #expect(s.photoCount == 1)
    }

    @Test func prefersPhotoAsRepresentative() async throws {
        let root = try makeFolder(["a.mp4", "z/p.jpg", "y/q.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await ShootSummary.scan(root)
        #expect(s.representative?.lastPathComponent == "q.jpg")
    }

    @Test func fallsBackToVideo() async throws {
        let root = try makeFolder(["b.mp4", "a.mp4"])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await ShootSummary.scan(root)
        #expect(s.representative?.lastPathComponent == "a.mp4")
    }

    @Test func skipsHiddenSidecar() async throws {
        let root = try makeFolder([ShootSidecar.fileName, ".hidden/x.mp4", ".secret.jpg", "v.mp4"])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await ShootSummary.scan(root)
        #expect(s.videoCount == 1)
        #expect(s.photoCount == 0)
    }

    @Test func emptyFolder() async throws {
        let root = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await ShootSummary.scan(root)
        #expect(s == ShootSummary(videoCount: 0, photoCount: 0, representative: nil))
    }

    @Test func fakeThumbnailProviderReturnsImageOrThrows() async throws {
        let bad = URL(fileURLWithPath: "/tmp/bad.jpg")
        let fake = FakeThumbnailProvider(failing: [bad])
        let provider: any ThumbnailProvider = fake
        let img = try await provider.thumbnail(for: URL(fileURLWithPath: "/tmp/ok.jpg"), maxPixels: 64)
        #expect(img.width == 1)
        await #expect(throws: FakeThumbnailProvider.Failure.self) {
            _ = try await provider.thumbnail(for: bad, maxPixels: 64)
        }
    }
}
