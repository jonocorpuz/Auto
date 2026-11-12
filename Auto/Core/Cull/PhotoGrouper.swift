import Foundation

/// Splits photos into bursts (similar frames shot close together) and mixed
/// batches of singletons, per camera.
nonisolated enum PhotoGrouper {
    /// Frames further apart than this never share a burst.
    static let maxGapSeconds = 2.0
    /// Largest dHash distance between neighbouring frames of one burst.
    static let maxHamming = 12
    /// Longer bursts are split into balanced pieces of at most this many frames.
    static let maxGroupSize = 12
    /// Singles are sent to the model in mixed batches of this size.
    static let singlesBatch = 8

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func group(_ photos: [PhotoRecord]) -> [PhotoGroup] {
        var photosByCamera: [String: [PhotoRecord]] = [:]
        for photo in photos {
            photosByCamera[photo.camera, default: []].append(photo)
        }

        var groups: [PhotoGroup] = []
        for camera in photosByCamera.keys.sorted() {
            let inCaptureOrder = photosByCamera[camera]!.sorted(by: timeOrder)
            for piece in pieces(of: inCaptureOrder) {
                groups.append(PhotoGroup(id: groups.count, kind: piece.kind, camera: camera, photos: piece.photos))
            }
        }
        return groups
    }

    // MARK: - One camera

    /// A group before it gets its id. `order` is the index of its first photo in capture order.
    private struct Piece {
        let order: Int
        let kind: GroupKind
        let photos: [PhotoRecord]
    }

    /// One camera's photos (in capture order) as bursts and mixed batches, ordered by first photo.
    private static func pieces(of photos: [PhotoRecord]) -> [Piece] {
        var pieces: [Piece] = []
        var singles: [(order: Int, photo: PhotoRecord)] = []

        var firstIndexOfRun = 0
        for run in similarRuns(in: photos) {
            defer { firstIndexOfRun += run.count }
            if run.count == 1 {
                singles.append((firstIndexOfRun, run[0]))
                continue
            }
            var offset = 0
            for size in balancedSizes(count: run.count, maxSize: maxGroupSize) {
                let burst = Array(run[offset..<offset + size])
                pieces.append(Piece(order: firstIndexOfRun + offset, kind: .burst, photos: burst))
                offset += size
            }
        }

        var batchStart = 0
        while batchStart < singles.count {
            let batch = singles[batchStart..<min(batchStart + singlesBatch, singles.count)]
            pieces.append(Piece(order: batch.first!.order, kind: .mixed, photos: batch.map(\.photo)))
            batchStart += singlesBatch
        }

        return pieces.sorted { $0.order < $1.order }
    }

    /// Splits photos in capture order into runs where each frame is similar to the one before it.
    private static func similarRuns(in photos: [PhotoRecord]) -> [[PhotoRecord]] {
        var runs: [[PhotoRecord]] = []
        for photo in photos {
            if let previous = runs.last?.last, similar(previous, photo) {
                runs[runs.count - 1].append(photo)
            } else {
                runs.append([photo])
            }
        }
        return runs
    }

    // MARK: - Helpers

    /// Capture time first (photos without one go last), then id.
    private static func timeOrder(_ a: PhotoRecord, _ b: PhotoRecord) -> Bool {
        switch (a.metrics?.captureTime, b.metrics?.captureTime) {
        case let (x?, y?): return x != y ? x < y : a.id < b.id
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.id < b.id
        }
    }

    /// `earlier` and `later` are neighbours in capture order.
    private static func similar(_ earlier: PhotoRecord, _ later: PhotoRecord) -> Bool {
        guard let earlierMetrics = earlier.metrics, let laterMetrics = later.metrics,
              let earlierTime = earlierMetrics.captureTime, let laterTime = laterMetrics.captureTime else { return false }
        guard laterTime.timeIntervalSince(earlierTime) <= maxGapSeconds else { return false }
        return hamming(earlierMetrics.dHash, laterMetrics.dHash) <= maxHamming
    }

    /// Balanced chunk sizes, each <= maxSize (25, 12 -> 9/8/8).
    private static func balancedSizes(count: Int, maxSize: Int) -> [Int] {
        let chunkCount = (count + maxSize - 1) / maxSize
        let baseSize = count / chunkCount
        let chunksWithOneExtra = count % chunkCount
        return (0..<chunkCount).map { $0 < chunksWithOneExtra ? baseSize + 1 : baseSize }
    }
}

/// Higher is better. Lexicographic weighting folded into one Double.
nonisolated enum PhotoRank {
    static func score(_ p: PhotoRecord) -> Double {
        guard let metrics = p.metrics else { return 0 }

        let closedEyeFaces = Double(metrics.faces.filter(\.eyesClosed).count)

        // Sharpness spans orders of magnitude, so it is compared on a log scale squeezed into 0...1.
        let rawSharpness = max(metrics.faceSharpness ?? metrics.sharpness, 0)
        let sharpness = unitClamp(log10(1 + rawSharpness) / 4)

        let faceQualities = metrics.faces.compactMap(\.quality)
        var meanFaceQuality = 0.0
        if !faceQualities.isEmpty {
            meanFaceQuality = unitClamp(faceQualities.reduce(0, +) / Double(faceQualities.count))
        }

        let clipping = unitClamp(metrics.clipHighPct + metrics.clipLowPct)

        // Each term outweighs everything after it: closed eyes, then sharpness, face quality, clipping.
        return -closedEyeFaces * 1000 + sharpness * 100 + meanFaceQuality * 10 - clipping
    }

    private static func unitClamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
