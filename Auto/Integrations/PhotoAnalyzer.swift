import Foundation

/// Controls the preview JPEG and optional face strip produced per photo.
nonisolated struct PreviewSpec: Sendable {
    var longEdge = 1024
    var quality = 0.7
    var faceStrips = true
    var faceHeight = 160
    var maxFaces = 8
}

/// Decodes a photo once, returning local metrics plus a downscaled preview
/// (and optional face strip) written under `workDir`. Never writes next to the source.
protocol PhotoAnalyzer: Sendable {
    func analyze(_ url: URL, workName: String, workDir: URL, spec: PreviewSpec) async throws
        -> (PhotoMetrics, preview: URL, faceStrip: URL?)
}

nonisolated enum PhotoAnalyzerError: Error, Equatable {
    case undecodable
    case writeFailed
}
