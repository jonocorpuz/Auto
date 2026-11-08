import Foundation
import Testing
@testable import Auto

struct AudioSyncPlannerTests {
    private static func video(_ cam: String, _ name: String, _ duration: Double, fps: Double = 29.97, audio: Bool = true) -> AudioSyncProbe {
        AudioSyncProbe(source: AudioSyncSource(id: "Video/\(cam)/\(name)", camera: cam, kind: .video),
                       duration: duration, fps: fps, hasAudio: audio)
    }
    private static func recorder(_ name: String, _ duration: Double, cam: String = "ZOOM") -> AudioSyncProbe {
        AudioSyncProbe(source: AudioSyncSource(id: "Video/\(cam)/\(name)", camera: cam, kind: .audio),
                       duration: duration, fps: nil, hasAudio: true)
    }
    private static func strong(_ offset: Double) -> AudioSyncMatch {
        AudioSyncMatch(offset: offset, correlation: 0.7, peakRatio: 3, overlap: 10)
    }
    private static let weak = AudioSyncMatch(offset: 40, correlation: 0.2, peakRatio: 1.3, overlap: 10)
    private static let none = AudioSyncMatch(offset: 5, correlation: 0.05, peakRatio: 1.05, overlap: 10)

    @Test func oneRecorderTwoCamerasStackOnTheirOwnTracks() throws {
        let zoom = Self.recorder("ZOOM0001.WAV", 600)
        let a1 = Self.video("A7SIII", "C0001.MP4", 120), a2 = Self.video("A7SIII", "C0002.MP4", 100)
        let b1 = Self.video("A7V", "A7501.MP4", 300)
        let plan = AudioSyncPlanner.plan(probes: [zoom, a1, a2, b1], matches: [zoom.source.id: [
            a1.source.id: Self.strong(10), a2.source.id: Self.strong(200), b1.source.id: Self.strong(5)]])
        let e = try #require(plan.events.first)
        #expect(plan.events.count == 1)
        #expect(e.name == "Sync 1 – ZOOM0001")
        #expect(e.baseID == zoom.source.id && e.fps == 29.97 && e.duration == 600)
        #expect(e.video.map(\.id) == [a1.source.id, a2.source.id, b1.source.id])
        #expect(e.video.map(\.track) == [1, 1, 2])
        #expect(e.video.map(\.start) == [10, 200, 5])
        #expect(e.audio.map(\.track) == [1] && e.audio[0].start == 0 && e.audio[0].match == nil)
        #expect(e.video.allSatisfy { !$0.needsReview })
        #expect(plan.unsynced.isEmpty && plan.unmatchedAudio.isEmpty)
    }

    @Test func clipStartingBeforeTheRecordingShiftsTheEvent() throws {
        let zoom = Self.recorder("Z.WAV", 100), a = Self.video("A", "a.MP4", 30)
        let e = try #require(AudioSyncPlanner.plan(probes: [zoom, a], matches: [zoom.source.id: [a.source.id: Self.strong(-4)]]).events.first)
        #expect(e.video[0].start == 0)
        #expect(e.audio[0].start == 4)
        #expect(e.duration == 104)
    }

    @Test func weakMatchesAreFlaggedAndNonMatchesGoToEverythingElse() throws {
        let zoom = Self.recorder("Z.WAV", 100)
        let w = Self.video("A", "w.MP4", 10), n = Self.video("A", "n.MP4", 10)
        let silent = Self.video("A", "s.MP4", 10, audio: false), unmatched = Self.video("B", "u.MP4", 10)
        let plan = AudioSyncPlanner.plan(probes: [zoom, w, n, silent, unmatched], matches: [zoom.source.id: [
            w.source.id: Self.weak, n.source.id: Self.none]])
        let e = try #require(plan.events.first)
        #expect(e.video.map(\.id) == [w.source.id])
        #expect(e.video[0].needsReview)
        #expect(plan.unsynced == [n.source.id, silent.source.id, unmatched.source.id].sorted())
    }

    @Test func recordersThatHearEachOtherMergeAroundTheLongest() throws {
        let room = Self.recorder("ROOM.WAV", 900, cam: "ZOOM"), lav = Self.recorder("LAV.WAV", 300, cam: "LAV")
        let cam = Self.video("A", "a.MP4", 60)
        let plan = AudioSyncPlanner.plan(probes: [room, lav, cam], matches: [
            room.source.id: [lav.source.id: Self.strong(100), cam.source.id: Self.strong(500)],
            lav.source.id: [room.source.id: Self.strong(-100), cam.source.id: Self.strong(20)],
        ])
        #expect(plan.events.count == 1)
        let e = try #require(plan.events.first)
        #expect(e.baseID == room.source.id)
        #expect(e.audio.map(\.id) == [room.source.id, lav.source.id])
        #expect(e.audio.map(\.start) == [0, 100])
        #expect(e.audio.map(\.track) == [1, 2])
        // Best match wins (equal correlation: either recorder gives the same spot here).
        #expect(e.video[0].start == 500 || e.video[0].start == 120)
    }

    @Test func eachClipGoesToItsStrongestRecording() throws {
        let z1 = Self.recorder("Z1.WAV", 100), z2 = Self.recorder("Z2.WAV", 100)
        let a = Self.video("A", "a.MP4", 10)
        var better = Self.strong(30); better.correlation = 0.9
        let plan = AudioSyncPlanner.plan(probes: [z1, z2, a], matches: [
            z1.source.id: [a.source.id: Self.strong(10)], z2.source.id: [a.source.id: better]])
        #expect(plan.events.map(\.baseID) == [z2.source.id])
        #expect(plan.events[0].name == "Sync 1 – Z2")
        #expect(plan.unmatchedAudio == [z1.source.id])
    }

    @Test func overlappingClipsFromOneCameraOpenAnotherTrack() {
        var items = [("A", 0.0, 50.0), ("A", 40.0, 20.0), ("A", 60.0, 5.0), ("B", 0.0, 10.0)].enumerated().map { i, t in
            AudioSyncItem(id: "\(i)", kind: .video, camera: t.0, track: 0, start: t.1, duration: t.2, match: nil, needsReview: false)
        }
        AudioSyncPlanner.assignVideoTracks(&items)
        #expect(items.map(\.track) == [1, 2, 1, 3])
    }
}
