import Foundation
@testable import Auto

nonisolated final class FakePhotoAnalyzer: PhotoAnalyzer, @unchecked Sendable {
    struct Call: Equatable, Sendable { let url: URL; let workName: String }

    private let lock = NSLock()
    private var scripted: [String: PhotoMetrics]
    private var failing: Set<String>
    private var _calls: [Call] = []
    private let fallback: PhotoMetrics

    /// `metrics` is keyed by source filename (lastPathComponent).
    init(metrics: [String: PhotoMetrics] = [:], failing: Set<String> = [], fallback: PhotoMetrics = FakePhotoAnalyzer.defaultMetrics) {
        self.scripted = metrics
        self.failing = failing
        self.fallback = fallback
    }

    static let defaultMetrics = PhotoMetrics(
        captureTime: nil, meanLuma: 0.5, lumaStdDev: 0.2, clipHighPct: 0, clipLowPct: 0,
        sharpness: 100, faceSharpness: nil, dHash: 0, horizonTiltDeg: nil, faces: [])

    var calls: [Call] { lock.withLock { _calls } }

    func analyze(_ url: URL, workName: String, workDir: URL, spec: PreviewSpec) async throws
        -> (PhotoMetrics, preview: URL, faceStrip: URL?)
    {
        let name = url.lastPathComponent
        let (m, fail): (PhotoMetrics, Bool) = lock.withLock {
            _calls.append(Call(url: url, workName: workName))
            return (scripted[name] ?? fallback, failing.contains(name))
        }
        if fail { throw PhotoAnalyzerError.undecodable }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let preview = workDir.appendingPathComponent("\(workName).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: preview)
        var strip: URL?
        if spec.faceStrips, !m.faces.isEmpty {
            let s = workDir.appendingPathComponent("\(workName)_faces.jpg")
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: s)
            strip = s
        }
        return (m, preview, strip)
    }
}
