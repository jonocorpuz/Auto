import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Produces a small JPEG thumbnail for a rejected photo's preview.
nonisolated protocol RejectThumbnailer: Sendable {
    func thumbnail(preview: URL) -> Data?
}

nonisolated struct ImageIORejectThumbnailer: RejectThumbnailer {
    var maxPixel = 240

    func thumbnail(preview: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(preview as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
