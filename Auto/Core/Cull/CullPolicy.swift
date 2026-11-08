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
    static let maxReasonLength = 90

    static func decide(
        group: PhotoGroup,
        tokens: [String: String],
        modelOutput: ModelGrades?,
        triage: [CullDecision],
        settings: CullSettings
    ) -> [CullDecision] {
        let mode = settings.mode
        let groupIDs = Set(group.photos.map(\.id))
        var triageByID: [String: CullDecision] = [:]
        for d in triage where groupIDs.contains(d.photoID) && triageByID[d.photoID] == nil {
            triageByID[d.photoID] = d
        }

        // Unknown tokens dropped; first entry per photo wins.
        var frameByID: [String: ModelGrades.Frame] = [:]
        for f in modelOutput?.frames ?? [] {
            guard let pid = tokens[f.id], groupIDs.contains(pid), frameByID[pid] == nil else { continue }
            frameByID[pid] = f
        }

        var out: [CullDecision] = []
        for photo in group.photos {
            if var t = triageByID[photo.id] {
                t.reason = truncate(t.reason)
                out.append(t)
                continue
            }
            guard let f = frameByID[photo.id] else {
                out.append(CullDecision(photoID: photo.id, verdict: .keep, reason: "no decision", criterion: nil,
                                        keeperID: nil, confidence: 0, source: .defaultKeep))
                continue
            }
            let grades = grades(from: f)
            out.append(CullDecision(photoID: photo.id, verdict: .keep, reason: truncate(f.reason), criterion: nil,
                                    keeperID: nil, confidence: 1, source: .model, score: grades.score, grades: grades))
        }

        func reject(_ i: Int, _ criterion: String, keeper: String? = nil) {
            out[i].verdict = .reject
            out[i].criterion = criterion
            out[i].keeperID = keeper
        }
        func graded(_ i: Int) -> CullGrades? {
            out[i].verdict == .keep && out[i].source == .model ? out[i].grades : nil
        }

        // 2-3. Unusable and crew.
        for i in out.indices {
            guard let g = graded(i) else { continue }
            if g.isUnusable, settings.criteria.contains(CullCriterion.unusable.id) {
                reject(i, CullCriterion.unusable.id)
            } else if g.role == .crew, mode.rejectsCrew {
                reject(i, "crew")
            }
        }

        // 4. One frame per moment.
        if mode.dedupesMoments, settings.criteria.contains(CullCriterion.duplicates.id) {
            var byMoment: [String: [Int]] = [:]
            for i in out.indices {
                guard let g = graded(i) else { continue }
                byMoment[g.moment, default: []].append(i)
            }
            for indices in byMoment.values where indices.count > 1 {
                let best = indices.max { a, b in rank(out[a], group.photos[a]) < rank(out[b], group.photos[b]) }!
                for i in indices where i != best {
                    reject(i, CullCriterion.duplicates.id, keeper: out[best].photoID)
                }
            }
        }

        // 5. Quality, unprotected roles only.
        for i in out.indices {
            guard let g = graded(i), !g.role.isProtected else { continue }
            if mode.subjectVeto, g.subject == 1 {
                reject(i, CullCriterion.eyes.id)
            } else if let floor = mode.qualityFloor, g.quality < floor {
                reject(i, "weak")
            }
        }

        // All-reject rescue for bursts, in the forgiving modes.
        if !out.isEmpty, out.allSatisfy({ $0.verdict == .reject }), group.kind == .burst,
           mode.rescuesAllRejectBursts, !out.allSatisfy({ $0.source == .localTriage }),
           let best = out.indices.filter({ out[$0].criterion != "crew" && out[$0].grades?.role != .accidental })
               .max(by: { rank(out[$0], group.photos[$0]) < rank(out[$1], group.photos[$1]) }) {
            out[best].verdict = .keep
            out[best].criterion = nil
            out[best].keeperID = nil
            out[best].reason = truncate("kept: best of all-reject burst; " + out[best].reason)
            out[best].source = .validatorOverride
        }
        return out
    }

    static func grades(from f: ModelGrades.Frame) -> CullGrades {
        func clamp(_ v: Int, _ lo: Int) -> Int { min(max(v, lo), 5) }
        return CullGrades(role: FrameRole(rawValue: f.role) ?? .candid,
                          moment: f.moment,
                          technical: clamp(f.technical, 1),
                          composition: clamp(f.composition, 1),
                          subject: clamp(f.subject, 0),
                          story: clamp(f.story, 1))
    }

    /// Best frame of a moment: quality, then sharpness of execution, then subject, then local metrics.
    private static func rank(_ d: CullDecision, _ p: PhotoRecord) -> (Double, Int, Int, Double) {
        guard let g = d.grades else { return (-1, 0, 0, PhotoRank.score(p)) }
        return (g.quality, g.technical, g.subject, PhotoRank.score(p))
    }

    private static func truncate(_ s: String) -> String {
        s.count > maxReasonLength ? String(s.prefix(maxReasonLength)) : s
    }
}
