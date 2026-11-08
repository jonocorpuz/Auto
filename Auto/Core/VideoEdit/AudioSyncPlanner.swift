import Foundation

/// What the reader learned about one source.
nonisolated struct AudioSyncProbe: Sendable, Equatable {
    let source: AudioSyncSource
    let duration: Double
    /// Video frame rate; nil for audio files.
    let fps: Double?
    let hasAudio: Bool
}

/// One clip or recording placed on an event timeline.
nonisolated struct AudioSyncItem: Sendable, Equatable, Codable {
    let id: String
    let kind: AudioSyncSource.Kind
    let camera: String
    /// 1-based video track (video) or audio track for recorder files (audio).
    var track: Int
    /// Seconds from the event's start.
    var start: Double
    let duration: Double
    /// The match that placed it (relative to its anchor). nil for the event's base recording.
    let match: AudioSyncMatch?
    /// Placed on a weak match: Claude checks it before it counts.
    let needsReview: Bool
}

/// A synced moment (speech, ceremony): one or more recordings and the clips that match them.
nonisolated struct AudioSyncEvent: Sendable, Equatable, Codable {
    let name: String
    /// The longest recording; everything else is placed relative to it.
    let baseID: String
    let fps: Double?
    let duration: Double
    let video: [AudioSyncItem]
    let audio: [AudioSyncItem]
}

nonisolated struct AudioSyncPlan: Sendable, Equatable, Codable {
    var events: [AudioSyncEvent]
    /// Video clips that matched no recording (sorted by id). They go on the "everything else" timeline.
    var unsynced: [String]
    /// Recordings that no clip matched.
    var unmatchedAudio: [String]
}

nonisolated struct AudioSyncThresholds: Sendable, Equatable {
    /// A match counts outright at or above both of these.
    var correlation = 0.30
    var peakRatio = 1.5
    /// Below `correlation` but at or above this (with peakRatio ≥ `weakPeakRatio`): placed, flagged for review.
    var weakCorrelation = 0.15
    var weakPeakRatio = 1.2

    func isConfident(_ m: AudioSyncMatch) -> Bool { m.correlation >= correlation && m.peakRatio >= peakRatio }
    func isWeak(_ m: AudioSyncMatch) -> Bool { m.correlation >= weakCorrelation && m.peakRatio >= weakPeakRatio }
}

/// Turns probes and audio matches into events. Each recording anchors an event; recordings that
/// match each other merge into one. Pure.
nonisolated enum AudioSyncPlanner {

    /// `matches[anchorID][sourceID]`: where `sourceID` sits inside the recording `anchorID`.
    static func plan(probes: [AudioSyncProbe], matches: [String: [String: AudioSyncMatch]],
                     thresholds: AudioSyncThresholds = AudioSyncThresholds()) -> AudioSyncPlan {
        let byID = Dictionary(probes.map { ($0.source.id, $0) }, uniquingKeysWith: { a, _ in a })
        let anchors = probes.filter { $0.source.kind == .audio && $0.hasAudio }.map(\.source.id).sorted()

        // 1. Recordings that hear each other form one group; positions relative to the group's longest.
        var edges: [String: [(String, Double)]] = [:]   // a -> (b, start of b minus start of a)
        for a in anchors {
            for b in anchors where a != b {
                guard let m = matches[a]?[b], thresholds.isConfident(m) else { continue }
                edges[a, default: []].append((b, m.offset))
                edges[b, default: []].append((a, -m.offset))
            }
        }
        var groupOf: [String: Int] = [:]
        var groups: [(base: String, position: [String: Double])] = []
        let byLength = anchors.sorted { (byID[$0]?.duration ?? 0, $1) > (byID[$1]?.duration ?? 0, $0) }
        for start in byLength where groupOf[start] == nil {
            var position = [start: 0.0]
            var queue = [start]
            groupOf[start] = groups.count
            while let a = queue.first {
                queue.removeFirst()
                for (b, delta) in edges[a] ?? [] where position[b] == nil {
                    position[b] = position[a]! + delta
                    groupOf[b] = groups.count
                    queue.append(b)
                }
            }
            groups.append((start, position))
        }

        // 2. Each clip goes to its best recording.
        var placed: [Int: [AudioSyncItem]] = [:]
        var unsynced: [String] = []
        let videos = probes.filter { $0.source.kind == .video }.sorted { $0.source.id < $1.source.id }
        for v in videos {
            let candidates = anchors.compactMap { a in matches[a]?[v.source.id].map { (a, $0) } }
            let best = candidates.max { lhs, rhs in
                (thresholds.isConfident(lhs.1) ? 1 : 0, lhs.1.correlation) < (thresholds.isConfident(rhs.1) ? 1 : 0, rhs.1.correlation)
            }
            guard v.hasAudio, let (anchor, m) = best, thresholds.isConfident(m) || thresholds.isWeak(m),
                  let g = groupOf[anchor], let anchorStart = groups[g].position[anchor] else {
                unsynced.append(v.source.id)
                continue
            }
            placed[g, default: []].append(AudioSyncItem(
                id: v.source.id, kind: .video, camera: v.source.camera, track: 0,
                start: anchorStart + m.offset, duration: v.duration, match: m,
                needsReview: !thresholds.isConfident(m)))
        }

        // 3. Build events with at least one clip; shift so the earliest item starts at 0.
        var events: [AudioSyncEvent] = []
        var unmatchedAudio: [String] = []
        for (g, group) in groups.enumerated() {
            let members = group.position.keys.sorted()
            guard var video = placed[g], !video.isEmpty else {
                unmatchedAudio.append(contentsOf: members)
                continue
            }
            var audio = members.map { id in
                AudioSyncItem(id: id, kind: .audio, camera: byID[id]?.source.camera ?? "", track: 0,
                         start: group.position[id]!, duration: byID[id]?.duration ?? 0,
                         match: id == group.base ? nil : matches[group.base]?[id],
                         needsReview: false)
            }
            let origin = min(video.map(\.start).min()!, audio.map(\.start).min()!)
            for i in video.indices { video[i].start -= origin }
            for i in audio.indices { audio[i].start -= origin }
            assignVideoTracks(&video)
            audio.sort { ($0.start, $0.id) < ($1.start, $1.id) }
            for i in audio.indices { audio[i].track = i + 1 }
            video.sort { ($0.track, $0.start, $0.id) < ($1.track, $1.start, $1.id) }
            let end = (video + audio).map { $0.start + $0.duration }.max() ?? 0
            events.append(AudioSyncEvent(name: "", baseID: group.base, fps: commonFPS(video, byID), duration: end,
                                    video: video, audio: audio))
        }

        // Recording order isn't known across recorders, so events go in base-file order.
        events.sort { $0.baseID < $1.baseID }
        events = events.enumerated().map { i, e in
            let stem = ((e.baseID as NSString).lastPathComponent as NSString).deletingPathExtension
            return AudioSyncEvent(name: "Sync \(i + 1) – \(stem)", baseID: e.baseID, fps: e.fps,
                             duration: e.duration, video: e.video, audio: e.audio)
        }
        return AudioSyncPlan(events: events, unsynced: unsynced, unmatchedAudio: unmatchedAudio.sorted())
    }

    /// One block of tracks per camera (cameras by name); within a camera, a clip takes the first of
    /// that camera's tracks it doesn't overlap, opening a new one if needed.
    static func assignVideoTracks(_ items: inout [AudioSyncItem]) {
        var next = 1
        for camera in Set(items.map(\.camera)).sorted() {
            var trackEnds: [Double] = []
            let indices = items.indices.filter { items[$0].camera == camera }
                .sorted { (items[$0].start, items[$0].id) < (items[$1].start, items[$1].id) }
            for i in indices {
                if let t = trackEnds.firstIndex(where: { $0 <= items[i].start + 1e-6 }) {
                    trackEnds[t] = items[i].start + items[i].duration
                    items[i].track = next + t
                } else {
                    trackEnds.append(items[i].start + items[i].duration)
                    items[i].track = next + trackEnds.count - 1
                }
            }
            next += trackEnds.count
        }
    }

    private static func commonFPS(_ video: [AudioSyncItem], _ byID: [String: AudioSyncProbe]) -> Double? {
        var counts: [Double: Int] = [:]
        for v in video { if let f = byID[v.id]?.fps { counts[(f * 1000).rounded() / 1000, default: 0] += 1 } }
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }
}
