import Foundation
import Testing
@testable import Auto

/// Serves canned clip audio by file name.
struct FakeClipAudioReader: ClipAudioReading {
    var clips: [String: ClipAudio]
    func read(_ url: URL) async throws -> ClipAudio {
        guard let c = clips[url.lastPathComponent] else { throw ClipAudioReaderError.unreadable }
        return c
    }
}

struct AudioSyncAnalyzerTests {
    private func shoot(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vsync-\(UUID().uuidString)")
        for f in files {
            let url = root.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        return root
    }

    @Test func endToEndPlacesClipsOnTheRecorder() async throws {
        let speech = SyntheticAudio.speech(seconds: 90, seed: 11)
        func clip(_ from: Double, _ len: Double, seed: UInt64) -> [Float] {
            SyntheticAudio.envelope(SyntheticAudio.degrade(SyntheticAudio.slice(speech, from: from, length: len),
                                                           gain: 0.4, noise: 0.01, seed: seed))
        }
        let reader = FakeClipAudioReader(clips: [
            "ZOOM0001.WAV": ClipAudio(duration: 90, fps: nil, envelope: SyntheticAudio.envelope(speech)),
            "C0001.MP4": ClipAudio(duration: 20, fps: 29.97, envelope: clip(15, 20, seed: 1)),
            "A7501.MP4": ClipAudio(duration: 30, fps: 29.97, envelope: clip(50, 30, seed: 2)),
            "C0002.MP4": ClipAudio(duration: 2, fps: 29.97,
                                   envelope: SyntheticAudio.envelope(SyntheticAudio.speech(seconds: 6, seed: 99))),
            "B.MP4": ClipAudio(duration: 5, fps: 29.97, envelope: nil),
        ])
        let root = try shoot(["Video/ZOOM/ZOOM0001.WAV", "Video/A7SIII/C0001.MP4", "Video/A7SIII/C0002.MP4",
                              "Video/A7V/A7501.MP4", "Video/B/B.MP4", "Video/B/broken.MP4"])
        defer { try? FileManager.default.removeItem(at: root) }

        let phases = Phases()
        let r = try await AudioSyncAnalyzer.analyze(shoot: root, cardVolumes: [], reader: reader) { phases.add($0) }
        let e = try #require(r.plan.events.first)
        #expect(r.plan.events.count == 1)
        #expect(e.video.map(\.id) == ["Video/A7SIII/C0001.MP4", "Video/A7V/A7501.MP4"])
        #expect(abs(e.video[0].start - 15) < 0.017 && abs(e.video[1].start - 50) < 0.017)
        #expect(e.video.map(\.track) == [1, 2])
        #expect(r.plan.unsynced == ["Video/A7SIII/C0002.MP4", "Video/B/B.MP4"])
        #expect(r.unreadable == ["Video/B/broken.MP4"])
        #expect(phases.last == AudioSyncProgress(phase: .matching, done: 1, total: 1))
    }

    @Test func shootWithoutVideoThrows() async throws {
        let root = try shoot(["Video/ZOOM/Z.WAV"])
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: VideoEditError.noVideo) {
            _ = try await AudioSyncAnalyzer.analyze(shoot: root, cardVolumes: [], reader: FakeClipAudioReader(clips: [:]))
        }
    }

    final class Phases: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AudioSyncProgress] = []
        func add(_ p: AudioSyncProgress) { lock.withLock { items.append(p) } }
        var last: AudioSyncProgress? { lock.withLock { items.last } }
    }
}
