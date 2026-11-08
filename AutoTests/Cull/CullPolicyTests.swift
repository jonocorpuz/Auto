import Foundation
import Testing
@testable import Auto

struct CullPolicyTests {

    private static func photo(_ i: Int) -> PhotoRecord {
        let id = "Photo/CamA/\(i).JPG"
        var r = PhotoRecord(id: id, camera: "CamA", members: [id], representative: id, stamps: [:])
        r.metrics = FakePhotoAnalyzer.defaultMetrics
        return r
    }

    private static func group(_ n: Int, kind: GroupKind = .mixed) -> PhotoGroup {
        PhotoGroup(id: 1, kind: kind, camera: "CamA", photos: (0..<n).map(photo))
    }

    private static func tokens(_ g: PhotoGroup) -> [String: String] {
        Dictionary(uniqueKeysWithValues: CullPromptBuilder.tokens(for: g).map { ($0.value, $0.key) })
    }

    private static func frame(_ i: Int, _ role: FrameRole = .candid, moment: String? = nil,
                              t: Int = 3, c: Int = 3, s: Int = 3, st: Int = 3) -> ModelGrades.Frame {
        ModelGrades.Frame(id: String(format: "p%02d", i + 1), role: role.rawValue, moment: moment ?? "m\(i + 1)",
                          technical: t, composition: c, subject: s, story: st, reason: "r\(i)")
    }

    private static func decide(_ g: PhotoGroup, _ frames: [ModelGrades.Frame], mode: CullMode = .balanced,
                               criteria: Set<String>? = nil, triage: [CullDecision] = []) -> [CullDecision] {
        var settings = CullSettings()
        settings.mode = mode
        if let criteria { settings.criteria = criteria }
        return CullPolicy.decide(group: g, tokens: tokens(g), modelOutput: ModelGrades(frames: frames),
                                 triage: triage, settings: settings)
    }

    // MARK: Grades

    @Test func qualityWeighsStoryMostAndSkipsAbsentSubject() {
        let flat = CullGrades(role: .candid, moment: "m1", technical: 3, composition: 3, subject: 3, story: 3)
        #expect(flat.quality == 3)
        #expect(flat.score == 6)
        let noPeople = CullGrades(role: .detail, moment: "m1", technical: 4, composition: 4, subject: 0, story: 4)
        #expect(noPeople.quality == 4)
        let storyHeavy = CullGrades(role: .candid, moment: "m1", technical: 3, composition: 3, subject: 3, story: 5)
        let compHeavy = CullGrades(role: .candid, moment: "m1", technical: 3, composition: 5, subject: 3, story: 3)
        #expect(storyHeavy.quality > compHeavy.quality)
        #expect(CullGrades(role: .candid, moment: "m", technical: 5, composition: 5, subject: 5, story: 5).score == 10)
        #expect(CullGrades(role: .candid, moment: "m", technical: 1, composition: 1, subject: 1, story: 1).score == 1)
    }

    @Test func gradesAreClampedAndUnknownRoleIsCandid() {
        let f = ModelGrades.Frame(id: "p01", role: "selfie", moment: "m1", technical: 9, composition: -2,
                                  subject: -1, story: 0, reason: "")
        let g = CullPolicy.grades(from: f)
        #expect(g.role == .candid)
        #expect(g.technical == 5 && g.composition == 1 && g.subject == 0 && g.story == 1)
    }

    // MARK: Decisions

    @Test func oneDecisionPerPhotoInOrderWithGradesAndScore() {
        let g = Self.group(3)
        let out = Self.decide(g, (0..<3).map { Self.frame($0) })
        #expect(out.map(\.photoID) == g.photos.map(\.id))
        #expect(out.allSatisfy { $0.verdict == .keep && $0.source == .model && $0.score == 6 && $0.grades != nil })
        #expect(out[1].reason == "r1")
    }

    @Test func missingAndUnknownTokensBecomeDefaultKeeps() {
        let g = Self.group(2)
        let stray = ModelGrades.Frame(id: "p99", role: "candid", moment: "m1", technical: 1,
                                      composition: 1, subject: 1, story: 1, reason: "x")
        let out = Self.decide(g, [stray, Self.frame(1)])
        #expect(out[0].source == .defaultKeep && out[0].verdict == .keep)
        #expect(out[1].source == .model)
    }

    @Test func triageWins() {
        let g = Self.group(2)
        let t = CullDecision(photoID: g.photos[0].id, verdict: .reject, reason: "black frame / lens cap",
                             criterion: "unusable", keeperID: nil, confidence: 1, source: .localTriage)
        let out = Self.decide(g, [Self.frame(0, .milestone, st: 5), Self.frame(1)], triage: [t])
        #expect(out[0] == t)
    }

    @Test func accidentalAndBrokenFramesGoInEveryModeWhenUnusableIsOn() {
        for mode in CullMode.allCases {
            let g = Self.group(3)
            let out = Self.decide(g, [Self.frame(0, .accidental), Self.frame(1, .milestone, t: 1), Self.frame(2)], mode: mode)
            #expect(out[0].verdict == .reject && out[0].criterion == "unusable", "\(mode)")
            #expect(out[1].verdict == .reject && out[1].criterion == "unusable", "\(mode): protected roles still go when broken")
            #expect(out[2].verdict == .keep, "\(mode)")
        }
        let g = Self.group(1)
        #expect(Self.decide(g, [Self.frame(0, .accidental)], criteria: ["duplicates"])[0].verdict == .keep)
    }

    @Test func crewGoesExceptInGentle() {
        let g = Self.group(1)
        #expect(Self.decide(g, [Self.frame(0, .crew, t: 5, c: 5, s: 5, st: 5)], mode: .balanced)[0].criterion == "crew")
        #expect(Self.decide(g, [Self.frame(0, .crew)], mode: .gentle)[0].verdict == .keep)
    }

    @Test func oneFramePerMomentWithTheBestAsKeeper() {
        let g = Self.group(4, kind: .burst)
        let frames = [Self.frame(0, moment: "m1", s: 2), Self.frame(1, moment: "m1", s: 4),
                      Self.frame(2, moment: "m1", t: 2), Self.frame(3, moment: "m2")]
        let out = Self.decide(g, frames)
        #expect(out.map(\.verdict) == [.reject, .keep, .reject, .keep])
        #expect(out[0].criterion == "duplicates" && out[0].keeperID == g.photos[1].id)
        #expect(out[2].keeperID == g.photos[1].id)
    }

    @Test func gentleAndDisabledDuplicatesKeepEveryMomentFrame() {
        let g = Self.group(2, kind: .burst)
        let frames = [Self.frame(0, moment: "m1"), Self.frame(1, moment: "m1")]
        #expect(Self.decide(g, frames, mode: .gentle).allSatisfy { $0.verdict == .keep })
        #expect(Self.decide(g, frames, criteria: ["unusable"]).allSatisfy { $0.verdict == .keep })
    }

    @Test func qualityFloorsCutOnlyUnprotectedRoles() {
        let g = Self.group(FrameRole.allCases.count)
        let weak = FrameRole.allCases.enumerated().map { i, role in Self.frame(i, role, t: 2, c: 2, s: 2, st: 2) }
        for mode in [CullMode.selective, .strict] {
            let out = Self.decide(g, weak, mode: mode)
            for (i, role) in FrameRole.allCases.enumerated() {
                switch role {
                case .candid, .establishing: #expect(out[i].verdict == .reject && out[i].criterion == "weak", "\(mode) \(role)")
                case .crew: #expect(out[i].criterion == "crew")
                case .accidental: #expect(out[i].criterion == "unusable")
                default: #expect(out[i].verdict == .keep, "\(mode) protects \(role)")
                }
            }
        }
        for mode in [CullMode.gentle, .balanced, .selects] {
            let out = Self.decide(g, weak, mode: mode)
            #expect(out[FrameRole.allCases.firstIndex(of: .candid)!].verdict == .keep, "\(mode)")
        }
    }

    @Test func strictIsHarderThanSelective() {
        let g = Self.group(1)
        let mid = [Self.frame(0, t: 3, c: 3, s: 2, st: 3)]   // quality 2.75
        #expect(Self.decide(g, mid, mode: .selective)[0].verdict == .keep)
        #expect(Self.decide(g, mid, mode: .strict)[0].verdict == .reject)
    }

    @Test func unflatteringSubjectVetoesCandidsInSelectiveAndStrict() {
        let g = Self.group(2)
        let frames = [Self.frame(0, s: 1, st: 5), Self.frame(1, .group, s: 1)]
        for mode in [CullMode.selective, .strict] {
            let out = Self.decide(g, frames, mode: mode)
            #expect(out[0].verdict == .reject && out[0].criterion == "eyes", "\(mode)")
            #expect(out[1].verdict == .keep, "\(mode): groups are protected")
        }
        #expect(Self.decide(g, frames, mode: .balanced)[0].verdict == .keep)
    }

    @Test func allRejectBurstRescuesBestRealFrameInForgivingModes() {
        let g = Self.group(3, kind: .burst)
        let frames = [Self.frame(0, .crew, t: 5), Self.frame(1, .accidental), Self.frame(2, t: 1, c: 4)]
        let out = Self.decide(g, frames, mode: .balanced)
        #expect(out[0].verdict == .reject)
        #expect(out.filter { $0.verdict == .keep }.count == 1)
        #expect(out[2].verdict == .keep && out[2].source == .validatorOverride)
        #expect(Self.decide(g, frames, mode: .strict).allSatisfy { $0.verdict == .reject })
    }
}
