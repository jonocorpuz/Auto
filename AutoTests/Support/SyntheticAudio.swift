import Foundation
@testable import Auto

/// Deterministic speech-like audio: noise bursts of random length and loudness with gaps.
enum SyntheticAudio {
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static func speech(seconds: Double, seed: UInt64, rate: Double = EnvelopeBuilder.sampleRate) -> [Float] {
        var rng = RNG(state: seed)
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let burst = Int(Double.random(in: 0.06...0.35, using: &rng) * rate)
            let gap = Int(Double.random(in: 0.03...0.4, using: &rng) * rate)
            let level = Float.random(in: 0.05...0.8, using: &rng)
            for j in i..<min(n, i + burst) { out[j] = level * Float.random(in: -1...1, using: &rng) }
            i += burst + gap
        }
        return out
    }

    /// `x` scaled by `gain` with a little noise floor added.
    static func degrade(_ x: [Float], gain: Float, noise: Float, seed: UInt64) -> [Float] {
        var rng = RNG(state: seed)
        return x.map { $0 * gain + noise * Float.random(in: -1...1, using: &rng) }
    }

    static func envelope(_ samples: [Float]) -> [Float] {
        var b = EnvelopeBuilder()
        b.append(samples)
        return b.finish()
    }

    static func slice(_ x: [Float], from seconds: Double, length: Double, rate: Double = EnvelopeBuilder.sampleRate) -> [Float] {
        let start = Int(seconds * rate)
        return Array(x[start..<min(x.count, start + Int(length * rate))])
    }
}
