import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Vision

/// ImageIO + Vision implementation. One thumbnail decode per photo; everything else
/// derives from that preview. Sources are only ever opened read-only.
nonisolated struct ImageIOPhotoAnalyzer: PhotoAnalyzer {
    /// Eye aspect ratio (height/width of the eye landmark box, in pixels) below which
    /// eyes count as closed. Open eyes measure roughly 0.25-0.4, blinks below 0.15;
    /// 0.18 sits between with a bias against false "closed" calls.
    static let eyeClosedThreshold = 0.18
    static let metricsLongEdge = 512

    /// Luma at or above this counts as blown highlights, at or below `clipLowLevel` as crushed shadows.
    private static let clipHighLevel: UInt8 = 250
    private static let clipLowLevel: UInt8 = 5
    /// Each face crop in the strip is padded by this share of the face box on every side.
    private static let faceCropPadding = 0.2
    /// Max centre distance (normalized, Manhattan) for a capture-quality result to belong to a face.
    private static let faceQualityMatchDistance = 0.1
    /// A face box within this normalized margin of the frame edge counts as cut off.
    private static let edgeCutMargin = 0.01

    // MARK: - Analyze

    func analyze(_ url: URL, workName: String, workDir: URL, spec: PreviewSpec) async throws
        -> (PhotoMetrics, preview: URL, faceStrip: URL?)
    {
        try Task.checkCancellation()
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw PhotoAnalyzerError.undecodable }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: spec.longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
        else { throw PhotoAnalyzerError.undecodable }

        let captureTime = Self.captureTime(source)

        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let previewURL = workDir.appendingPathComponent("\(workName).jpg")
        try Self.writeJPEG(image, to: previewURL, quality: spec.quality)

        let gray = Self.grayImage(image, longEdge: Self.metricsLongEdge)
        let stats = Self.lumaStats(gray)
        let sharp = Self.laplacianVariance(gray, region: nil)
        let hash = Self.dHash(image)

        try Task.checkCancellation()
        let vision = Self.runVision(image)
        var faces = vision.faces
        // Face sharpness is measured on the largest face only.
        let largestFace = faces.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
        let faceSharp = largestFace.map { Self.laplacianVariance(gray, region: $0.box) }
        faces.sort { $0.box.minX < $1.box.minX }   // left to right, matching the face strip numbering

        var stripURL: URL?
        if spec.faceStrips, !faces.isEmpty {
            stripURL = try Self.writeFaceStrip(image, faces: faces, spec: spec,
                                               to: workDir.appendingPathComponent("\(workName)_faces.jpg"))
        }

        let metrics = PhotoMetrics(
            captureTime: captureTime, meanLuma: stats.mean, lumaStdDev: stats.std,
            clipHighPct: stats.clipHigh, clipLowPct: stats.clipLow, sharpness: sharp,
            faceSharpness: faceSharp, dHash: hash, horizonTiltDeg: vision.horizonDeg, faces: faces)
        return (metrics, previewURL, stripURL)
    }

    // MARK: - EXIF

    static func captureTime(_ source: CGImageSource) -> Date? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let offset = exif["OffsetTimeOriginal" as CFString] as? String
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = Self.timeZone(offset) ?? .current
        guard var date = f.date(from: raw) else { return nil }
        if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
           let digits = Double("0." + sub.trimmingCharacters(in: .whitespaces)) {
            date = date.addingTimeInterval(digits)
        }
        return date
    }

    private static func timeZone(_ offset: String?) -> TimeZone? {
        guard let o = offset?.trimmingCharacters(in: .whitespaces), o.count == 6,
              let sign = o.first, sign == "+" || sign == "-" else { return nil }
        let parts = o.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (h * 3600 + m * 60))
    }

    // MARK: - Writing

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PhotoAnalyzerError.writeFailed }
        CGImageDestinationAddImage(dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PhotoAnalyzerError.writeFailed }
    }

    static func writeFaceStrip(_ image: CGImage, faces: [FaceInfo], spec: PreviewSpec, to url: URL) throws -> URL? {
        let crops = faces.prefix(spec.maxFaces).compactMap { faceCrop(of: image, box: $0.box) }
        guard !crops.isEmpty else { return nil }
        // Every crop is scaled to the strip height and laid out left to right.
        let stripHeight = spec.faceHeight
        let widths = crops.map { crop in
            max(1, Int((Double(crop.width) * Double(stripHeight) / Double(crop.height)).rounded()))
        }
        let totalWidth = widths.reduce(0, +)
        guard let ctx = CGContext(data: nil, width: totalWidth, height: stripHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PhotoAnalyzerError.writeFailed }
        ctx.interpolationQuality = .high
        var x = 0
        for (crop, cropWidth) in zip(crops, widths) {
            ctx.draw(crop, in: CGRect(x: x, y: 0, width: cropWidth, height: stripHeight))
            x += cropWidth
        }
        guard let strip = ctx.makeImage() else { throw PhotoAnalyzerError.writeFailed }
        try writeJPEG(strip, to: url, quality: spec.quality)
        return url
    }

    /// The face box (normalized, top-left origin) in pixels, padded and clipped to the image; nil if empty.
    private static func faceCrop(of image: CGImage, box: CGRect) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        let faceRect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
        let padded = faceRect.insetBy(dx: -faceRect.width * faceCropPadding, dy: -faceRect.height * faceCropPadding)
        let rect = padded.intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return image.cropping(to: rect)
    }

    // MARK: - Gray metrics

    struct Gray { var width: Int; var height: Int; var pixels: [UInt8] }

    static func grayImage(_ image: CGImage, longEdge: Int) -> Gray {
        let scale = min(1.0, Double(longEdge) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        return Gray(width: w, height: h, pixels: drawGray(image, width: w, height: h))
    }

    private static func drawGray(_ image: CGImage, width w: Int, height h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px
    }

    static func lumaStats(_ g: Gray) -> (mean: Double, std: Double, clipHigh: Double, clipLow: Double) {
        let n = Double(g.pixels.count)
        guard n > 0 else { return (0, 0, 0, 0) }
        var sum = 0.0, sumSq = 0.0, hi = 0, lo = 0
        for p in g.pixels {
            let v = Double(p)
            sum += v; sumSq += v * v
            if p >= clipHighLevel { hi += 1 }
            if p <= clipLowLevel { lo += 1 }
        }
        let mean = sum / n
        let variance = max(0, sumSq / n - mean * mean)
        return (mean / 255, variance.squareRoot() / 255, Double(hi) / n, Double(lo) / n)
    }

    /// Variance of the 3x3 Laplacian response (kernel 0 1 0 / 1 -4 1 / 0 1 0).
    /// `region` is a normalized top-left-origin rect; nil means the whole image.
    static func laplacianVariance(_ g: Gray, region: CGRect?) -> Double {
        var x0 = 1, y0 = 1, x1 = g.width - 1, y1 = g.height - 1
        if let r = region {
            x0 = max(1, Int(r.minX * Double(g.width))); x1 = min(g.width - 1, Int((r.maxX * Double(g.width)).rounded(.up)))
            y0 = max(1, Int(r.minY * Double(g.height))); y1 = min(g.height - 1, Int((r.maxY * Double(g.height)).rounded(.up)))
        }
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        g.pixels.withUnsafeBufferPointer { p in
            let w = g.width
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * w + x
                    let l = Double(Int(p[i - 1]) + Int(p[i + 1]) + Int(p[i - w]) + Int(p[i + w]) - 4 * Int(p[i]))
                    sum += l; sumSq += l * l; n += 1
                }
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    /// 64-bit difference hash: 9x8 gray, bit set when a pixel is brighter than its right neighbour.
    static func dHash(_ image: CGImage) -> UInt64 {
        let px = drawGray(image, width: 9, height: 8)
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                hash <<= 1
                if px[y * 9 + x] > px[y * 9 + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    // MARK: - Vision

    struct VisionResult { var faces: [FaceInfo]; var horizonDeg: Double? }

    /// Vision failures are non-fatal: the photo just gets no faces/horizon.
    static func runVision(_ image: CGImage) -> VisionResult {
        let rects = VNDetectFaceRectanglesRequest()
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let horizon = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([rects, landmarks, quality, horizon])

        let size = CGSize(width: image.width, height: image.height)
        let qualities = quality.results ?? []
        // Landmark observations carry eye points; fall back to plain rectangles when there are none.
        let observations: [VNFaceObservation]
        if let withLandmarks = landmarks.results, !withLandmarks.isEmpty {
            observations = withLandmarks
        } else {
            observations = rects.results ?? []
        }
        var faces: [FaceInfo] = []
        for obs in observations {
            let visionBox = obs.boundingBox
            // Vision boxes have a bottom-left origin; FaceInfo uses top-left.
            let box = CGRect(x: visionBox.minX, y: 1 - visionBox.maxY, width: visionBox.width, height: visionBox.height)
            let nearestQuality = qualities.min { dist($0.boundingBox, visionBox) < dist($1.boundingBox, visionBox) }
            let matchedQuality = nearestQuality.flatMap {
                dist($0.boundingBox, visionBox) < faceQualityMatchDistance ? $0.faceCaptureQuality : nil
            }
            let cut = box.minX < edgeCutMargin || box.minY < edgeCutMargin
                || box.maxX > 1 - edgeCutMargin || box.maxY > 1 - edgeCutMargin
            faces.append(FaceInfo(box: box, eyesClosed: eyesClosed(obs, size: size),
                                  edgeCut: cut, quality: matchedQuality.map(Double.init)))
        }
        let tilt = (horizon.results?.first).map { Double($0.angle) * 180 / .pi }
        return VisionResult(faces: faces, horizonDeg: tilt)
    }

    private static func dist(_ a: CGRect, _ b: CGRect) -> Double {
        abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }

    private static func eyesClosed(_ obs: VNFaceObservation, size: CGSize) -> Bool {
        guard let lm = obs.landmarks else { return false }
        var ratios: [Double] = []
        for region in [lm.leftEye, lm.rightEye] {
            guard let region else { continue }
            let pts = region.pointsInImage(imageSize: size)
            guard pts.count >= 4 else { continue }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let w = (xs.max() ?? 0) - (xs.min() ?? 0)
            let h = (ys.max() ?? 0) - (ys.min() ?? 0)
            if w > 0 { ratios.append(Double(h / w)) }
        }
        guard !ratios.isEmpty else { return false }
        return ratios.reduce(0, +) / Double(ratios.count) < eyeClosedThreshold
    }
}
