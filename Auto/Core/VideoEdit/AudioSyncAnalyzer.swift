import Foundation

nonisolated struct AudioSyncProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case reading, matching }
    let phase: Phase
    let done: Int
    let total: Int
}

/// Catalog → read every file's sound → match every clip and recording against every recording → plan.
/// Read-only on the shoot.
nonisolated enum AudioSyncAnalyzer {
    static let maxConcurrentReads = 4

    struct Result: Sendable {
        let plan: AudioSyncPlan
        let probes: [AudioSyncProbe]
        /// Files the reader couldn't open (left off every timeline's sync, listed for the user).
        let unreadable: [String]
    }

    static func analyze(shoot: URL, cardVolumes: [URL], reader: any ClipAudioReading,
                        thresholds: AudioSyncThresholds = AudioSyncThresholds(),
                        progress: (@Sendable (AudioSyncProgress) -> Void)? = nil) async throws -> Result {
        let sources = try VideoCatalog.scan(shoot: shoot, cardVolumes: cardVolumes)
        guard sources.contains(where: { $0.kind == .video }) else { throw VideoEditError.noVideo }

        // Read, a few at a time.
        var audio: [String: ClipAudio] = [:]
        var unreadable: [String] = []
        try await withThrowingTaskGroup(of: (String, ClipAudio?).self) { group in
            var next = 0
            func launch() {
                guard next < sources.count else { return }
                let s = sources[next]
                next += 1
                group.addTask {
                    do { return (s.id, try await reader.read(shoot.appendingPathComponent(s.id))) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (s.id, nil) }
                }
            }
            for _ in 0..<min(maxConcurrentReads, sources.count) { launch() }
            var done = 0
            while let (id, clip) = try await group.next() {
                if let clip { audio[id] = clip } else { unreadable.append(id) }
                done += 1
                progress?(AudioSyncProgress(phase: .reading, done: done, total: sources.count))
                launch()
            }
        }

        let probes: [AudioSyncProbe] = sources.compactMap { s in
            audio[s.id].map { AudioSyncProbe(source: s, duration: $0.duration, fps: $0.fps, hasAudio: $0.envelope != nil) }
        }

        // Match everything with sound against every recording.
        let anchors = sources.filter { $0.kind == .audio && audio[$0.id]?.envelope != nil }
        let others = sources.filter { audio[$0.id]?.envelope != nil }
        var matches: [String: [String: AudioSyncMatch]] = [:]
        let total = anchors.count
        for (i, anchor) in anchors.enumerated() {
            try Task.checkCancellation()
            let a = audio[anchor.id]!.envelope!
            for s in others where s.id != anchor.id {
                if let m = AudioSyncMatcher.match(anchor: a, clip: audio[s.id]!.envelope!) {
                    matches[anchor.id, default: [:]][s.id] = m
                }
            }
            progress?(AudioSyncProgress(phase: .matching, done: i + 1, total: total))
        }

        let plan = AudioSyncPlanner.plan(probes: probes, matches: matches, thresholds: thresholds)
        return Result(plan: plan, probes: probes, unreadable: unreadable.sorted())
    }
}
