import CoreGraphics
import Foundation
@testable import Auto

nonisolated struct FakeThumbnailProvider: ThumbnailProvider {
    struct Failure: Error {}
    var failing: Set<URL> = []

    func thumbnail(for url: URL, maxPixels: CGFloat) async throws -> CGImage {
        if failing.contains(url) { throw Failure() }
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return ctx.makeImage()!
    }
}
