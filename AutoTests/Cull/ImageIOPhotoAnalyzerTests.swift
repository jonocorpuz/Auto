import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Auto

struct ImageIOPhotoAnalyzerTests {
    private let size = CGSize(width: 800, height: 600)

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("analyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func analyze(_ fill: @escaping (CGContext) -> Void, exif: Date? = nil, subsec: String? = nil,
                         spec: PreviewSpec = PreviewSpec()) async throws -> (PhotoMetrics, URL, URL?) {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("a.jpg")
        try ImageFixtures.jpeg(at: src, size: size, fill: fill, exifDate: exif, subsec: subsec)
        let r = try await ImageIOPhotoAnalyzer().analyze(src, workName: "w1", workDir: dir.appendingPathComponent("work"), spec: spec)
        return (r.0, r.preview, r.faceStrip)
    }

    @Test func blackIsDark() async throws {
        let (m, _, _) = try await analyze(ImageFixtures.solid(CGColor(gray: 0, alpha: 1)))
        #expect(m.meanLuma < 0.02)
        #expect(m.clipLowPct > 0.95)
    }

    @Test func whiteClipsHigh() async throws {
        let (m, _, _) = try await analyze(ImageFixtures.solid(CGColor(gray: 1, alpha: 1)))
        #expect(m.clipHighPct > 0.95)
    }

    @Test func sharpnessSeparatesBlur() async throws {
        let (sharp, _, _) = try await analyze(ImageFixtures.checkerboard())
        let (soft, _, _) = try await analyze(ImageFixtures.blurred())
        #expect(sharp.sharpness > 5 * soft.sharpness)
    }

    @Test func dHashSameAndInverted() async throws {
        let (a, _, _) = try await analyze(ImageFixtures.blocks())
        let (b, _, _) = try await analyze(ImageFixtures.blocks())
        let (c, _, _) = try await analyze(ImageFixtures.blocks(inverted: true))
        #expect((a.dHash ^ b.dHash).nonzeroBitCount == 0)
        #expect((a.dHash ^ c.dHash).nonzeroBitCount > 32)
    }

    @Test func exifDateAndSubsecRoundTrip() async throws {
        var comps = DateComponents(year: 2025, month: 3, day: 14, hour: 9, minute: 26, second: 53)
        comps.timeZone = .current
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let (m, _, _) = try await analyze(ImageFixtures.checkerboard(), exif: date, subsec: "250")
        let t = try #require(m.captureTime)
        #expect(abs(t.timeIntervalSince(date) - 0.25) < 0.001)
    }

    @Test func previewRespectsLongEdge() async throws {
        let spec = PreviewSpec(longEdge: 300)
        let (_, preview, _) = try await analyze(ImageFixtures.checkerboard(), spec: spec)
        let src = try #require(CGImageSourceCreateWithURL(preview as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(max(w, h) <= 300 && max(w, h) > 0)
    }

    @Test func noFacesMeansNoStrip() async throws {
        let (m, _, strip) = try await analyze(ImageFixtures.solid(CGColor(gray: 0.5, alpha: 1)))
        #expect(m.faces.isEmpty)
        #expect(strip == nil)
        #expect(m.faceSharpness == nil)
    }

    @Test func analyzeIsFast() async throws {
        let clock = ContinuousClock()
        let d = await clock.measure { _ = try? await analyze(ImageFixtures.checkerboard()) }
        #expect(d < .seconds(2))
    }

    @Test func undecodableThrows() async throws {
        let dir = try tempDir()
        let bad = dir.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)
        await #expect(throws: PhotoAnalyzerError.self) {
            _ = try await ImageIOPhotoAnalyzer().analyze(bad, workName: "x", workDir: dir, spec: PreviewSpec())
        }
    }

    @Test func fakeRecordsCallsAndWritesPlaceholders() async throws {
        let dir = try tempDir()
        let fake = FakePhotoAnalyzer()
        let r = try await fake.analyze(dir.appendingPathComponent("z.jpg"), workName: "k", workDir: dir, spec: PreviewSpec())
        #expect(FileManager.default.fileExists(atPath: r.preview.path))
        #expect(fake.calls.map(\.workName) == ["k"])
    }
}
