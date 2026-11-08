import Foundation
import Testing
@testable import Auto

struct AudioSyncMatcherTests {
    private static let anchorSamples = SyntheticAudio.speech(seconds: 60, seed: 1)
    private static let anchor = SyntheticAudio.envelope(anchorSamples)
    private static let frame = 1 / 29.97

    @Test func envelopeIgnoresGainAndChunking() {
        // Real recordings have a noise floor that scales with gain; pure digital silence sits at the fixed floor.
        let x = SyntheticAudio.degrade(SyntheticAudio.speech(seconds: 5, seed: 7), gain: 1, noise: 0.01, seed: 8)
        var chunked = EnvelopeBuilder()
        stride(from: 0, to: x.count, by: 777).forEach { chunked.append(Array(x[$0..<min(x.count, $0 + 777)])) }
        let whole = SyntheticAudio.envelope(x)
        #expect(chunked.finish() == whole)
        #expect(whole.count == x.count / EnvelopeBuilder.hop)
        let louder = SyntheticAudio.envelope(x.map { $0 * 4 })
        let diff = zip(whole, louder).map { abs($0 - $1) }.max()!
        #expect(diff < 1e-3)
    }

    @Test func crossCorrelationMatchesDirectSum() {
        let a: [Float] = [1, 2, 0, -1, 3, 0.5]
        let b: [Float] = [0.5, -1, 2]
        let xc = AudioSyncMatcher.crossCorrelation(a, b, n: 16)
        for k in -2...5 {
            var direct: Float = 0
            for i in b.indices where (0..<a.count).contains(i + k) { direct += a[i + k] * b[i] }
            #expect(abs(xc[k >= 0 ? k : 16 + k] - direct) < 1e-4, "lag \(k)")
        }
    }

    @Test func findsAClipInsideTheRecordingWithinAFrame() throws {
        let clip = SyntheticAudio.degrade(SyntheticAudio.slice(Self.anchorSamples, from: 12.34, length: 8),
                                          gain: 0.3, noise: 0.01, seed: 2)
        let m = try #require(AudioSyncMatcher.match(anchor: Self.anchor, clip: SyntheticAudio.envelope(clip)))
        #expect(abs(m.offset - 12.34) < Self.frame / 2)
        #expect(m.correlation > 0.5)
        #expect(m.peakRatio > 1.5)
        #expect(abs(m.overlap - 8) < 0.02)
        #expect(AudioSyncThresholds().isConfident(m))
    }

    @Test func clipStartingBeforeTheRecordingGetsANegativeOffset() throws {
        let lead = SyntheticAudio.speech(seconds: 2, seed: 9)
        let clip = lead + SyntheticAudio.slice(Self.anchorSamples, from: 0, length: 6)
        let m = try #require(AudioSyncMatcher.match(anchor: Self.anchor, clip: SyntheticAudio.envelope(clip)))
        #expect(abs(m.offset + 2) < Self.frame / 2)
        #expect(abs(m.overlap - 6) < 0.05)
    }

    @Test func unrelatedSoundIsNotConfident() throws {
        let other = SyntheticAudio.envelope(SyntheticAudio.speech(seconds: 8, seed: 42))
        let m = try #require(AudioSyncMatcher.match(anchor: Self.anchor, clip: other))
        #expect(!AudioSyncThresholds().isConfident(m))
        #expect(!AudioSyncThresholds().isWeak(m))
    }

    @Test func silenceOrTooShortHasNoMatch() {
        #expect(AudioSyncMatcher.match(anchor: Self.anchor, clip: [Float](repeating: 0, count: 500)) == nil)
        #expect(AudioSyncMatcher.match(anchor: [1], clip: Self.anchor) == nil)
    }
}
