import Foundation

/// Streams mono PCM at `sampleRate` into an onset curve at `rate` points per second: the rise in
/// log loudness from one 10 ms frame to the next. Gain-independent, so a lav and a room mic line up.
nonisolated struct EnvelopeBuilder: Sendable {
    static let sampleRate = 8000.0
    static let hop = 80
    static var rate: Double { sampleRate / Double(hop) }
    /// About -70 dB: keeps digital silence and a recorder's noise floor comparable.
    static let floor: Float = 1e-7

    private var sum: Float = 0
    private var count = 0
    private var energies: [Float] = []

    init() {}

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            sum += s * s
            count += 1
            if count == Self.hop {
                energies.append(sum / Float(Self.hop))
                sum = 0
                count = 0
            }
        }
    }

    mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Onset curve, one value per full frame (a trailing partial frame is dropped).
    func finish() -> [Float] {
        guard !energies.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: energies.count)
        var previous = log10(max(energies[0], Self.floor))
        for i in 1..<energies.count {
            let current = log10(max(energies[i], Self.floor))
            out[i] = max(0, current - previous)
            previous = current
        }
        return out
    }
}
