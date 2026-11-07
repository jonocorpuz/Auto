import CoreGraphics
import Foundation
import Testing
@testable import Auto

struct CullDecisionValidatorTests {
    private func photo(_ id: String, sharp: Double = 10, closed: Int = 0) -> PhotoRecord {
        let faces = (0..<closed).map { _ in FaceInfo(box: .zero, eyesClosed: true, edgeCut: false, quality: nil) }
        let m = PhotoMetrics(captureTime: nil, meanLuma: 0.5, lumaStdDev: 0.2, clipHighPct: 0, clipLowPct: 0,
                             sharpness: sharp, faceSharpness: nil, dHash: 0, horizonTiltDeg: nil, faces: faces)
        return PhotoRecord(id: id, camera: "cam", members: [id], representative: id, stamps: [:], metrics: m, preview: nil, faceStrip: nil)
    }

    private func group(_ photos: [PhotoRecord], kind: GroupKind = .burst) -> PhotoGroup {
        PhotoGroup(id: 1, kind: kind, camera: "cam", photos: photos)
    }

    private func tokens(_ g: PhotoGroup) -> [String: String] {
        Dictionary(uniqueKeysWithValues: g.photos.enumerated().map { (String(format: "p%02d", $0.offset + 1), $0.element.id) })
    }

    private func item(_ id: String, _ verdict: String = "reject", conf: Double = 0.95, keeper: String? = nil, reason: String = "r", score: Int? = nil) -> ModelDecisions.Item {
        .init(id: id, verdict: verdict, reason: reason, keeper: keeper, confidence: conf, criterion: nil, score: score)
    }

    private func run(_ g: PhotoGroup, _ items: [ModelDecisions.Item]?, triage: [CullDecision] = [], mode: CullMode = .balanced) -> [CullDecision] {
        CullDecisionValidator.validate(group: g, tokens: tokens(g), modelOutput: items.map { ModelDecisions(decisions: $0) },
                                       triage: triage, settings: CullSettings(mode: mode))
    }

    private func triageReject(_ id: String) -> CullDecision {
        CullDecision(photoID: id, verdict: .reject, reason: "t", criterion: "blur", keeperID: nil, confidence: 1, source: .localTriage)
    }

    @Test func allRejectBurstKeepsBest() {
        let g = group([photo("a", sharp: 5), photo("b", sharp: 50), photo("c", sharp: 20)])
        let out = run(g, [item("p01"), item("p02"), item("p03")])
        #expect(out.map(\.photoID) == ["a", "b", "c"])
        #expect(out[1].verdict == .keep)
        #expect(out[1].source == .validatorOverride)
        #expect(out[0].verdict == .reject && out[2].verdict == .reject)
    }

    @Test func rankPrefersOpenEyes() {
        let g = group([photo("a", sharp: 50, closed: 1), photo("b", sharp: 5)])
        let out = run(g, [item("p01"), item("p02")])
        #expect(out[1].verdict == .keep)
    }

    @Test(arguments: [(CullMode.gentle, 0.90), (.balanced, 0.75), (.selective, 0.65), (.strict, 0.60), (.selects, 0.50)])
    func lowConfidenceRejectBecomesKeep(mode: CullMode, threshold: Double) {
        let g = group([photo("a"), photo("b")])
        let below = run(g, [item("p01", conf: threshold - 0.01), item("p02", "keep")], mode: mode)
        #expect(below[0].verdict == .keep && below[0].source == .validatorOverride)
        #expect(below[0].reason.hasPrefix("low confidence"))
        let at = run(g, [item("p01", conf: threshold), item("p02", "keep")], mode: mode)
        #expect(at[0].verdict == .reject && at[0].source == .model)
    }

    @Test func tokenHandling() {
        let g = group([photo("a"), photo("b"), photo("c")])
        let out = run(g, [item("p99"), item("p01", "keep"), item("p01"), item("p02", "keep")])
        #expect(out.count == 3)
        #expect(out[0].verdict == .keep && out[0].source == .model)
        #expect(out[1].source == .model)
        #expect(out[2].source == .defaultKeep && out[2].verdict == .keep)
    }

    @Test func oddVerdictAndClamping() {
        let g = group([photo("a"), photo("b")])
        let long = String(repeating: "x", count: 200)
        let out = run(g, [item("p01", "maybe"), item("p02", "keep", conf: 7, reason: long)])
        #expect(out[0].source == .defaultKeep && out[0].verdict == .keep)
        #expect(out[1].reason.count == 90)
        #expect(out[1].confidence == 1)
    }

    @Test func keeperValidation() {
        let g = group([photo("a"), photo("b"), photo("c")])
        let out = run(g, [item("p01", keeper: "p03"), item("p02", keeper: "p99"), item("p03", "keep")])
        #expect(out[0].keeperID == "c")
        #expect(out[1].keeperID == nil)
        let selfK = run(g, [item("p01", keeper: "p01"), item("p02", "keep"), item("p03", "keep")])
        #expect(selfK[0].keeperID == nil)
        let rejK = run(g, [item("p01", keeper: "p02"), item("p02"), item("p03", "keep")])
        #expect(rejK[0].keeperID == nil)
    }

    @Test func nilModelOutput() {
        let g = group([photo("a"), photo("b")])
        let out = run(g, nil, triage: [triageReject("a")])
        #expect(out[0].source == .localTriage && out[0].verdict == .reject)
        #expect(out[1].source == .defaultKeep)
    }

    @Test func triageSurvivesModelDisagreement() {
        let g = group([photo("a"), photo("b")])
        let out = run(g, [item("p01", "keep"), item("p02", "keep")], triage: [triageReject("a")])
        #expect(out[0].verdict == .reject && out[0].source == .localTriage)
    }

    @Test func mixedGroupRescue() {
        let g = group([photo("a", sharp: 1), photo("b", sharp: 9)], kind: .mixed)
        let items = [item("p01"), item("p02")]
        let l2 = run(g, items, mode: .gentle)
        #expect(l2.filter { $0.verdict == .keep }.map(\.photoID) == ["b"])
        let l4 = run(g, items, mode: .selective)
        #expect(l4.allSatisfy { $0.verdict == .reject })
        let tri = run(g, nil, triage: [triageReject("a"), triageReject("b")], mode: .gentle)
        #expect(tri.allSatisfy { $0.verdict == .reject })
    }

    @Test(arguments: [(CullMode.gentle, true), (.balanced, true), (.selective, true), (.strict, false), (.selects, false)])
    func allRejectBurstRescueByMode(mode: CullMode, rescued: Bool) {
        let g = group([photo("a", sharp: 5), photo("b", sharp: 50)])
        let out = run(g, [item("p01", score: 1), item("p02", score: 1)], mode: mode)
        #expect(out.contains { $0.verdict == .keep } == rescued)
    }

    @Test func strictRejectsLowScoreKeeps() {
        let g = group([photo("a"), photo("b")])
        let out = run(g, [item("p01", "keep", score: 4), item("p02", "keep", score: 6)], mode: .strict)
        #expect(out[0].verdict == .reject)
        #expect(out[0].criterion == "weak")
        #expect(out[0].reason == "weak shot")
        #expect(out[0].source == .validatorOverride)
        #expect(out[0].keeperID == nil)
        #expect(out[1].verdict == .keep)
    }

    @Test func selectsAndBalancedHaveNoScoreFloor() {
        let g = group([photo("a"), photo("b")])
        for mode in [CullMode.selects, .balanced] {
            let out = run(g, [item("p01", "keep", score: 2), item("p02", "keep", score: 9)], mode: mode)
            #expect(out.allSatisfy { $0.verdict == .keep })
        }
    }

    @Test func scoreIsClampedToOneThroughTen() {
        let g = group([photo("a"), photo("b")])
        let out = run(g, [item("p01", "keep", score: 99), item("p02", "keep", score: -3)], mode: .selects)
        #expect(out[0].score == 10)
        #expect(out[1].score == 1)
    }
}
