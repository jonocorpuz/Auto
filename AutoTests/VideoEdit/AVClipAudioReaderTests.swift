import AVFoundation
import Foundation
import Testing
@testable import Auto

struct AVClipAudioReaderTests {
    /// Writes `samples` (8 kHz mono) as a 48 kHz stereo WAV, like a field recorder.
    private func wav(_ samples: [Float], at url: URL) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let up = 6
        let frames = AVAudioFrameCount(samples.count * up)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = samples[i / up] }
        }
        try file.write(from: buffer)
    }

    @Test func readsDurationAndFindsTheSameOffsetAsTheRawSignal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let speech = SyntheticAudio.degrade(SyntheticAudio.speech(seconds: 30, seed: 5), gain: 1, noise: 0.01, seed: 6)
        let anchorURL = dir.appendingPathComponent("ZOOM.WAV"), clipURL = dir.appendingPathComponent("cam.wav")
        try wav(speech, at: anchorURL)
        try wav(SyntheticAudio.slice(speech, from: 7.5, length: 10), at: clipURL)

        let reader = AVClipAudioReader()
        let anchor = try await reader.read(anchorURL)
        let clip = try await reader.read(clipURL)
        #expect(abs(anchor.duration - 30) < 0.01)
        #expect(anchor.fps == nil)
        let env = try #require(anchor.envelope)
        #expect(abs(env.count - 3000) <= 2)
        let clipEnv = try #require(clip.envelope)
        let m = try #require(AudioSyncMatcher.match(anchor: env, clip: clipEnv))
        #expect(abs(m.offset - 7.5) < 1 / 59.94)
    }

    @Test func missingFileIsUnreadable() async {
        await #expect(throws: ClipAudioReaderError.unreadable) {
            _ = try await AVClipAudioReader().read(URL(fileURLWithPath: "/nonexistent/x.wav"))
        }
    }
}
