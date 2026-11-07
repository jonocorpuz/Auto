import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Auto

struct CullRejectLabelTests {
    private func decision(_ criterion: String?, reason: String = "", keeper: String? = nil) -> CullDecision {
        CullDecision(
            photoID: "p1", verdict: .reject, reason: reason, criterion: criterion,
            keeperID: keeper, confidence: 0.9, source: .model
        )
    }

    @Test func eyesMapToClosedEyesOrBadExpression() {
        #expect(CullRejectLabel.label(for: decision("eyes", reason: "Eyes closed mid-blink")) == "Closed eyes")
        #expect(CullRejectLabel.label(for: decision("eyes", reason: "Bad Expression on subject")) == "Bad expression")
    }

    @Test func exposureMaps() {
        #expect(CullRejectLabel.label(for: decision("exposure", reason: "Blown highlights")) == "Exposure")
    }

    @Test func unusableAndTechnicalSplitOnBlurOrFocus() {
        #expect(CullRejectLabel.label(for: decision("unusable", reason: "Motion blur on face")) == "Blurry")
        #expect(CullRejectLabel.label(for: decision("technical", reason: "Missed focus")) == "Blurry")
        #expect(CullRejectLabel.label(for: decision("unusable", reason: "Lens cap on")) == "Unusable")
        #expect(CullRejectLabel.label(for: decision("technical", reason: "Ground shot")) == "Unusable")
    }

    @Test func horizonCroppedDuplicatesWeakSelect() {
        #expect(CullRejectLabel.label(for: decision("horizon")) == "Crooked")
        #expect(CullRejectLabel.label(for: decision("cropped")) == "Cropped")
        #expect(CullRejectLabel.label(for: decision("duplicates")) == "Duplicate")
        #expect(CullRejectLabel.label(for: decision("weak")) == "Weak shot")
        #expect(CullRejectLabel.label(for: decision("select")) == "Not a select")
    }

    @Test func unknownOrNilCriterionFallsBack() {
        #expect(CullRejectLabel.label(for: decision(nil, keeper: "p2")) == "Duplicate")
        #expect(CullRejectLabel.label(for: decision(nil)) == "Rejected")
        #expect(CullRejectLabel.label(for: decision("something-new", keeper: "p2")) == "Duplicate")
        #expect(CullRejectLabel.label(for: decision("something-new")) == "Rejected")
    }
}

struct ImageIORejectThumbnailerTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func thumbnailsGeneratedJPEGWithinBounds() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preview.jpg")

        let w = 800, h = 600
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        let data = try #require(ImageIORejectThumbnailer().thumbnail(preview: url))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let thumb = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(thumb.width, thumb.height) <= 240)
        #expect(max(thumb.width, thumb.height) > 0)
    }

    @Test func missingFileReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.jpg")
        #expect(ImageIORejectThumbnailer().thumbnail(preview: missing) == nil)
    }
}
