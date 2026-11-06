import AppKit
import CoreGraphics
import Foundation
import QuickLookThumbnailing

nonisolated struct QLThumbnailProvider: ThumbnailProvider {
    func thumbnail(for url: URL, maxPixels: CGFloat) async throws -> CGImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixels, height: maxPixels),
            scale: 1,
            representationTypes: .thumbnail
        )
        let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return rep.cgImage
    }
}
