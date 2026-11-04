import CoreGraphics
import Foundation

/// Produces a preview image for a media file. Faked in tests.
protocol ThumbnailProvider: Sendable {
    func thumbnail(for url: URL, maxPixels: CGFloat) async throws -> CGImage
}
