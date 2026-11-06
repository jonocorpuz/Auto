import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageFixtures {
    static func jpeg(at url: URL, size: CGSize, fill: (CGContext) -> Void, exifDate: Date? = nil,
                     subsec: String? = nil) throws {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        fill(ctx)
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let d = exifDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.timeZone = .current
            var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: f.string(from: d)]
            if let subsec { exif[kCGImagePropertyExifSubsecTimeOriginal] = subsec }
            props[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func solid(_ color: CGColor) -> (CGContext) -> Void {
        { ctx in
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        }
    }

    static func checkerboard(cell: Int = 4) -> (CGContext) -> Void {
        { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in stride(from: 0, to: ctx.height, by: cell) {
                for x in stride(from: 0, to: ctx.width, by: cell) where ((x / cell) + (y / cell)) % 2 == 0 {
                    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
        }
    }

    /// Checkerboard run through CIGaussianBlur.
    static func blurred(cell: Int = 4, radius: Double = 6) -> (CGContext) -> Void {
        { ctx in
            checkerboard(cell: cell)(ctx)
            guard let base = ctx.makeImage() else { return }
            let input = CIImage(cgImage: base).clampedToExtent()
            let out = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            if let cg = CIContext().createCGImage(out, from: out.extent) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            }
        }
    }

    /// Deterministic coarse blocks of distinct grays (good for hash tests); `inverted` flips every value.
    static func blocks(inverted: Bool = false) -> (CGContext) -> Void {
        { ctx in
            let cols = 9, rows = 8
            var seed: UInt64 = 12345
            for r in 0..<rows {
                for c in 0..<cols {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    var v = Double((seed >> 33) % 1000) / 999
                    if inverted { v = 1 - v }
                    ctx.setFillColor(CGColor(gray: v, alpha: 1))
                    let cw = Double(ctx.width) / Double(cols), rh = Double(ctx.height) / Double(rows)
                    ctx.fill(CGRect(x: Double(c) * cw, y: Double(r) * rh, width: cw + 1, height: rh + 1))
                }
            }
        }
    }
}
