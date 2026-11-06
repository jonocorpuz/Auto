import Foundation

/// Splits photos into bursts (similar frames shot close together) and mixed
/// batches of singletons, per camera.
nonisolated enum PhotoGrouper {
    struct Options: Sendable {
        var maxGapSeconds = 2.0
        var maxHamming = 12
        var maxGroupSize = 12
        var singlesBatch = 8
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func group(_ photos: [PhotoRecord], options: Options = .init()) -> [PhotoGroup] {
        let maxSize = max(options.maxGroupSize, 1)
        let batch = max(options.singlesBatch, 1)
        var byCamera: [String: [PhotoRecord]] = [:]
        for p in photos { byCamera[p.camera, default: []].append(p) }

        var output: [PhotoGroup] = []
        var nextID = 0

        for camera in byCamera.keys.sorted() {
            let sorted = byCamera[camera]!.sorted(by: timeOrder)

            // Candidate runs.
            var runs: [[PhotoRecord]] = []
            for p in sorted {
                if let prev = runs.last?.last, similar(prev, p, options) {
                    runs[runs.count - 1].append(p)
                } else {
                    runs.append([p])
                }
            }

            // (first index in sorted order, kind, photos)
            var pieces: [(order: Int, kind: GroupKind, photos: [PhotoRecord])] = []
            var singles: [(order: Int, photo: PhotoRecord)] = []
            var cursor = 0
            for run in runs {
                defer { cursor += run.count }
                if run.count == 1 {
                    singles.append((cursor, run[0]))
                    continue
                }
                var offset = 0
                for size in balancedSizes(count: run.count, maxSize: maxSize) {
                    pieces.append((cursor + offset, .burst, Array(run[offset..<offset + size])))
                    offset += size
                }
            }
            var i = 0
            while i < singles.count {
                let chunk = singles[i..<min(i + batch, singles.count)]
                pieces.append((chunk.first!.order, .mixed, chunk.map(\.photo)))
                i += batch
            }

            for piece in pieces.sorted(by: { $0.order < $1.order }) {
                output.append(PhotoGroup(id: nextID, kind: piece.kind, camera: camera, photos: piece.photos))
                nextID += 1
            }
        }
        return output
    }

    private static func timeOrder(_ a: PhotoRecord, _ b: PhotoRecord) -> Bool {
        switch (a.metrics?.captureTime, b.metrics?.captureTime) {
        case let (x?, y?): return x != y ? x < y : a.id < b.id
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.id < b.id
        }
    }

    private static func similar(_ a: PhotoRecord, _ b: PhotoRecord, _ o: Options) -> Bool {
        guard let ma = a.metrics, let mb = b.metrics,
              let ta = ma.captureTime, let tb = mb.captureTime else { return false }
        guard tb.timeIntervalSince(ta) <= o.maxGapSeconds else { return false }
        return hamming(ma.dHash, mb.dHash) <= o.maxHamming
    }

    /// Balanced chunk sizes, each <= maxSize (25, 12 -> 9/8/8).
    private static func balancedSizes(count: Int, maxSize: Int) -> [Int] {
        let n = (count + maxSize - 1) / maxSize
        let base = count / n
        let extra = count % n
        return (0..<n).map { $0 < extra ? base + 1 : base }
    }
}

/// Higher is better. Lexicographic weighting folded into one Double.
nonisolated enum PhotoRank {
    static func score(_ p: PhotoRecord) -> Double {
        guard let m = p.metrics else { return 0 }
        let closed = Double(m.faces.filter(\.eyesClosed).count)
        let sharp = min(max(log10(1 + max(m.faceSharpness ?? m.sharpness, 0)) / 4, 0), 1)
        let qualities = m.faces.compactMap(\.quality)
        let quality = qualities.isEmpty ? 0 : min(max(qualities.reduce(0, +) / Double(qualities.count), 0), 1)
        let clip = min(max(m.clipHighPct + m.clipLowPct, 0), 1)
        return -closed * 1000 + sharp * 100 + quality * 10 - clip
    }
}
