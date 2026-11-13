import Foundation

/// Turns the model's grades for one group into exactly one decision per photo, in group order.
/// The model only describes frames; every keep/reject rule and threshold lives here.
///
/// Order, most certain first:
/// 1. Local triage wins.
/// 2. Unusable (accidental role or technical 1) goes, when the unusable criterion is on.
/// 3. Crew / behind-the-scenes frames go (not in Gentle).
/// 4. Moments: one frame per moment label survives; the rest go as duplicates (not in Gentle).
/// 5. Quality: unprotected roles under the mode's floor, or with an unflattering prominent subject, go.
/// Protected roles (milestone, group, celebration, detail) skip step 5.
nonisolated enum CullPolicy {
    private static let maxReasonLength = 90

    static func decide(
        group: PhotoGroup,
        tokens: [String: String],
        modelOutput: ModelGrades?,
        triage: [CullDecision],
        settings: CullSettings
    ) -> [CullDecision] {
        let mode = settings.mode
        let groupIDs = Set(group.photos.map(\.id))
        let triageByID = triageByPhotoID(triage, groupIDs: groupIDs)
        let frameByID = framesByPhotoID(modelOutput, tokens: tokens, groupIDs: groupIDs)

        // 1. Triage wins; every other photo starts as a keep carrying its grades.
        var out = group.photos.map { photo in
            initialDecision(for: photo, triage: triageByID[photo.id], frame: frameByID[photo.id])
        }

        // 2-3. Unusable and crew.
        for i in out.indices {
            guard let g = gradedKeep(out[i]) else { continue }
            if g.isUnusable, settings.criteria.contains(CullCriterion.unusable.id) {
                reject(&out[i], CullCriterion.unusable.id)
            } else if g.role == .crew, mode.rejectsCrew {
                reject(&out[i], "crew")
            }
        }

        // 4. One frame per moment.
        if mode.dedupesMoments, settings.criteria.contains(CullCriterion.duplicates.id) {
            rejectDuplicateMoments(&out, photos: group.photos)
        }

        // 5. Quality, unprotected roles only.
        for i in out.indices {
            guard let g = gradedKeep(out[i]), !g.role.isProtected else { continue }
            if mode.subjectVeto, g.subject == 1 {
                reject(&out[i], CullCriterion.eyes.id)
            } else if let floor = mode.qualityFloor, g.quality < floor {
                reject(&out[i], "weak")
            }
        }

        if group.kind == .burst, mode.rescuesAllRejectBursts {
            rescueBestOfAllRejectBurst(&out, photos: group.photos)
        }
        return out
    }

    // MARK: - Steps

    /// First triage decision per photo of this group.
    private static func triageByPhotoID(_ triage: [CullDecision], groupIDs: Set<String>) -> [String: CullDecision] {
        var byID: [String: CullDecision] = [:]
        for d in triage where groupIDs.contains(d.photoID) && byID[d.photoID] == nil {
            byID[d.photoID] = d
        }
        return byID
    }

    /// The model's frame per photo. Unknown tokens are dropped; the first entry per photo wins.
    private static func framesByPhotoID(_ modelOutput: ModelGrades?, tokens: [String: String],
                                        groupIDs: Set<String>) -> [String: ModelGrades.Frame] {
        var byID: [String: ModelGrades.Frame] = [:]
        for f in modelOutput?.frames ?? [] {
            guard let pid = tokens[f.id], groupIDs.contains(pid), byID[pid] == nil else { continue }
            byID[pid] = f
        }
        return byID
    }

    private static func initialDecision(for photo: PhotoRecord, triage: CullDecision?,
                                        frame: ModelGrades.Frame?) -> CullDecision {
        if var triage {
            triage.reason = truncate(triage.reason)
            return triage
        }
        guard let frame else {
            return CullDecision(photoID: photo.id, verdict: .keep, reason: "no decision", criterion: nil,
                                keeperID: nil, confidence: 0, source: .defaultKeep)
        }
        let grades = grades(from: frame)
        return CullDecision(photoID: photo.id, verdict: .keep, reason: truncate(frame.reason), criterion: nil,
                            keeperID: nil, confidence: 1, source: .model, score: grades.score, grades: grades)
    }

    /// Grades of a model-graded frame that is still a keep; nil once rejected or when not model-graded.
    private static func gradedKeep(_ d: CullDecision) -> CullGrades? {
        d.verdict == .keep && d.source == .model ? d.grades : nil
    }

    private static func reject(_ d: inout CullDecision, _ criterion: String, keeper: String? = nil) {
        d.verdict = .reject
        d.criterion = criterion
        d.keeperID = keeper
    }

    /// Keeps the best-ranked frame of each moment label and rejects the rest as its duplicates.
    private static func rejectDuplicateMoments(_ out: inout [CullDecision], photos: [PhotoRecord]) {
        var byMoment: [String: [Int]] = [:]
        for i in out.indices {
            guard let g = gradedKeep(out[i]) else { continue }
            byMoment[g.moment, default: []].append(i)
        }
        for indices in byMoment.values where indices.count > 1 {
            let best = indices.max { a, b in rank(out[a], photos[a]) < rank(out[b], photos[b]) }!
            let keeperID = out[best].photoID
            for i in indices where i != best {
                reject(&out[i], CullCriterion.duplicates.id, keeper: keeperID)
            }
        }
    }

    /// When every frame of a burst was rejected (and not all by local triage), keeps the best one that
    /// isn't crew or accidental.
    private static func rescueBestOfAllRejectBurst(_ out: inout [CullDecision], photos: [PhotoRecord]) {
        guard !out.isEmpty,
              out.allSatisfy({ $0.verdict == .reject }),
              !out.allSatisfy({ $0.source == .localTriage }) else { return }
        let rescuable = out.indices.filter { out[$0].criterion != "crew" && out[$0].grades?.role != .accidental }
        guard let best = rescuable.max(by: { rank(out[$0], photos[$0]) < rank(out[$1], photos[$1]) }) else { return }
        out[best].verdict = .keep
        out[best].criterion = nil
        out[best].keeperID = nil
        out[best].reason = truncate("kept: best of all-reject burst; " + out[best].reason)
        out[best].source = .validatorOverride
    }

    // MARK: - Grades

    static func grades(from f: ModelGrades.Frame) -> CullGrades {
        func clamp(_ v: Int, _ lo: Int) -> Int { min(max(v, lo), 5) }
        return CullGrades(role: FrameRole(rawValue: f.role) ?? .candid,
                          moment: f.moment,
                          technical: clamp(f.technical, 1),
                          composition: clamp(f.composition, 1),
                          subject: clamp(f.subject, 0),
                          story: clamp(f.story, 1))
    }

    // MARK: - Helpers

    /// Best frame of a moment: quality, then sharpness of execution, then subject, then local metrics.
    private static func rank(_ d: CullDecision, _ p: PhotoRecord) -> (Double, Int, Int, Double) {
        guard let g = d.grades else { return (-1, 0, 0, PhotoRank.score(p)) }
        return (g.quality, g.technical, g.subject, PhotoRank.score(p))
    }

    private static func truncate(_ s: String) -> String {
        s.count > maxReasonLength ? String(s.prefix(maxReasonLength)) : s
    }
}
