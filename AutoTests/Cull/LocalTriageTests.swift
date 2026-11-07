import CoreGraphics
import Foundation
import Testing
@testable import Auto

struct LocalTriageTests {
    static func record(luma: Double = 0.5, std: Double = 0.2, hi: Double = 0, lo: Double = 0,
                       sharp: Double = 100, faces: [FaceInfo] = []) -> PhotoRecord {
        PhotoRecord(
            id: "x", camera: "A", members: ["x"], representative: "x", stamps: [:],
            metrics: PhotoMetrics(captureTime: nil, meanLuma: luma, lumaStdDev: std, clipHighPct: hi,
                                  clipLowPct: lo, sharpness: sharp, faceSharpness: nil, dHash: 0,
                                  horizonTiltDeg: nil, faces: faces))
    }

    static func settings(_ ids: Set<String>, mode: CullMode = .gentle) -> CullSettings {
        CullSettings(criteria: ids, mode: mode)
    }

    @Test func blackRejectedOnlyWhenUnusableEnabled() {
        let black = Self.record(luma: 0.005, std: 0.001)
        let d = LocalTriage.decide(black, settings: Self.settings(["unusable"]))
        #expect(d?.verdict == .reject)
        #expect(d?.reason == "black frame / lens cap")
        #expect(d?.criterion == "unusable")
        #expect(d?.source == .localTriage)
        #expect(d?.confidence == 1)
        #expect(LocalTriage.decide(black, settings: Self.settings(["exposure", "eyes"])) == nil)
    }

    @Test(arguments: [(CullMode.gentle, false), (.balanced, true), (.selects, true)])
    func clipThresholdMovesWithMode(mode: CullMode, rejected: Bool) {
        // thresholds: 0.89 gentle (level 2), 0.80 otherwise (level 5)
        let d = LocalTriage.decide(Self.record(hi: 0.85), settings: Self.settings(["exposure"], mode: mode))
        #expect((d != nil) == rejected)
    }

    @Test func clipEndpointsAndReason() {
        #expect(LocalTriage.clipThreshold(level: 1) == 0.92)
        #expect(abs(LocalTriage.clipThreshold(level: 5) - 0.80) < 1e-9)
        let d = LocalTriage.decide(Self.record(hi: 0.94), settings: Self.settings(["exposure"], mode: .gentle))
        #expect(d?.reason == "highlights blown 94%")
        #expect(d?.criterion == "exposure")
        #expect(LocalTriage.decide(Self.record(lo: 0.95), settings: Self.settings(["exposure"], mode: .gentle)) != nil)
    }

    @Test func disabledCriterionReturnsNil() {
        #expect(LocalTriage.decide(Self.record(hi: 0.99), settings: Self.settings(["unusable"], mode: .balanced)) == nil)
        #expect(LocalTriage.decide(Self.record(sharp: 1), settings: Self.settings(["exposure"], mode: .balanced)) == nil)
    }

    @Test(arguments: [(CullMode.gentle, 4.0, true), (.gentle, 6.0, false), (.balanced, 14.0, true), (.balanced, 16.0, false)])
    func blurThresholdPerMode(mode: CullMode, sharp: Double, rejected: Bool) {
        let d = LocalTriage.decide(Self.record(sharp: sharp), settings: Self.settings(["unusable"], mode: mode))
        #expect((d != nil) == rejected)
        if rejected { #expect(d?.reason == "severely blurred") }
    }

    @Test func blurIgnoredWhenFacesPresent() {
        let face = FaceInfo(box: .zero, eyesClosed: false, edgeCut: false, quality: nil)
        #expect(LocalTriage.decide(Self.record(sharp: 1, faces: [face]), settings: Self.settings(["unusable"], mode: .balanced)) == nil)
    }

    @Test func nilMetricsReturnsNil() {
        var p = Self.record()
        p.metrics = nil
        #expect(LocalTriage.decide(p, settings: CullSettings()) == nil)
    }
}
