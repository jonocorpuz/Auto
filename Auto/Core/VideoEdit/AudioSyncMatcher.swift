import Accelerate
import Foundation

/// Where a clip's sound sits inside an anchor recording.
nonisolated struct AudioSyncMatch: Sendable, Equatable, Codable {
    /// Seconds from the anchor's start to the clip's start; negative when the clip starts first.
    var offset: Double
    /// Pearson correlation of the two onset curves over the overlap, -1...1.
    var correlation: Double
    /// Best peak over the next best one more than `exclusion` away. 1 means ambiguous.
    var peakRatio: Double
    /// Seconds the two overlap at that offset.
    var overlap: Double
}

/// Finds the offset of `clip` inside `anchor` by FFT cross-correlation of onset curves (`EnvelopeBuilder`).
nonisolated enum AudioSyncMatcher {
    /// The clip must overlap the anchor at least this long (or its whole length when shorter).
    static let minOverlap = 3.0
    /// Peaks closer than this to the best one don't count as rivals.
    static let exclusion = 1.0
    static let maxPeakRatio = 99.0

    static func match(anchor: [Float], clip: [Float], rate: Double = EnvelopeBuilder.rate) -> AudioSyncMatch? {
        guard let a = zNormalized(anchor), let b = zNormalized(clip) else { return nil }
        let minOv = min(Int(minOverlap * rate), b.count)
        guard minOv > 0, a.count >= minOv else { return nil }
        var n = 1
        while n < a.count + b.count { n <<= 1 }
        let xc = crossCorrelation(a, b, n: n)

        // Lag k: clip sample 0 sits at anchor sample k. Negative lags wrap to n + k.
        let lags = -(b.count - minOv)...(a.count - minOv)
        func value(_ k: Int) -> Float { xc[k >= 0 ? k : n + k] }
        var best = lags.lowerBound
        var bestValue = -Float.greatestFiniteMagnitude
        for k in lags where value(k) > bestValue { best = k; bestValue = value(k) }

        let ex = Int(exclusion * rate)
        var rival = -Float.greatestFiniteMagnitude
        for k in lags where abs(k - best) > ex { rival = max(rival, value(k)) }
        let ratio: Double = rival > 0 ? min(Double(bestValue / rival), maxPeakRatio) : maxPeakRatio

        // Sub-frame peak by parabolic interpolation.
        var fraction = 0.0
        if lags.contains(best - 1), lags.contains(best + 1) {
            let y0 = Double(value(best - 1)), y1 = Double(bestValue), y2 = Double(value(best + 1))
            let denom = y0 - 2 * y1 + y2
            if denom < 0 { fraction = min(max(0.5 * (y0 - y2) / denom, -0.5), 0.5) }
        }

        let lo = max(0, -best), hi = min(b.count, a.count - best)
        let r = pearson(a, b, lag: best, range: lo..<hi)
        return AudioSyncMatch(offset: (Double(best) + fraction) / rate, correlation: r,
                         peakRatio: ratio, overlap: Double(hi - lo) / rate)
    }

    private static func zNormalized(_ x: [Float]) -> [Float]? {
        guard x.count > 1 else { return nil }
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(x, 1, nil, 1, &mean, &std, vDSP_Length(x.count))
        guard std > 1e-9 else { return nil }
        var out = [Float](repeating: 0, count: x.count)
        vDSP_normalize(x, 1, &out, 1, &mean, &std, vDSP_Length(x.count))
        return out
    }

    /// out[k] = Σ a[i + k]·b[i], circular over `n` (a power of two ≥ a.count + b.count, so no wrap-around).
    static func crossCorrelation(_ a: [Float], _ b: [Float], n: Int) -> [Float] {
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = n / 2

        func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
            var padded = x
            padded.append(contentsOf: repeatElement(0, count: n - x.count))
            var re = [Float](repeating: 0, count: half)
            var im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            return (re, im)
        }

        var (ar, ai) = forward(a)
        let (br, bi) = forward(b)
        // A · conj(B). Packed format: index 0 holds the real DC (re) and Nyquist (im) terms.
        let dc = ar[0] * br[0], nyquist = ai[0] * bi[0]
        for i in 1..<half {
            let r = ar[i] * br[i] + ai[i] * bi[i]
            let m = ai[i] * br[i] - ar[i] * bi[i]
            ar[i] = r
            ai[i] = m
        }
        ar[0] = dc
        ai[0] = nyquist

        var out = [Float](repeating: 0, count: n)
        ar.withUnsafeMutableBufferPointer { rp in
            ai.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        return vDSP.multiply(1 / Float(4 * n), out)
    }

    private static func pearson(_ a: [Float], _ b: [Float], lag: Int, range: Range<Int>) -> Double {
        guard range.count > 1 else { return 0 }
        var ma = 0.0, mb = 0.0
        for i in range { ma += Double(a[i + lag]); mb += Double(b[i]) }
        ma /= Double(range.count); mb /= Double(range.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in range {
            let x = Double(a[i + lag]) - ma, y = Double(b[i]) - mb
            sab += x * y; saa += x * x; sbb += y * y
        }
        guard saa > 0, sbb > 0 else { return 0 }
        return sab / (saa * sbb).squareRoot()
    }
}
