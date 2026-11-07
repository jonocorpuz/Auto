import Foundation

/// Structured output of one Claude call for a group.
nonisolated struct ModelDecisions: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: String
        let verdict: String
        let reason: String
        let keeper: String?
        let confidence: Double
        let criterion: String?
        let score: Int?
    }
    let decisions: [Item]
}

nonisolated enum CullDecisionValidator {
    static let maxReasonLength = 90

    /// Exactly one decision per photo, in group order.
    static func validate(
        group: PhotoGroup,
        tokens: [String: String],
        modelOutput: ModelDecisions?,
        triage: [CullDecision],
        settings: CullSettings
    ) -> [CullDecision] {
        let mode = settings.mode
        let threshold = mode.minConfidence
        let groupIDs = Set(group.photos.map(\.id))

        // Triage wins (first per photo).
        var triageByID: [String: CullDecision] = [:]
        for d in triage where groupIDs.contains(d.photoID) && triageByID[d.photoID] == nil {
            triageByID[d.photoID] = d
        }

        // (1) drop unknown tokens; duplicates: first wins.
        var itemByID: [String: ModelDecisions.Item] = [:]
        for item in modelOutput?.decisions ?? [] {
            guard let pid = tokens[item.id], groupIDs.contains(pid), itemByID[pid] == nil else { continue }
            itemByID[pid] = item
        }

        var out: [CullDecision] = []
        var pendingKeeper: [String: String] = [:]   // photoID → keeper photoID (unvalidated)
        for photo in group.photos {
            if let t = triageByID[photo.id] {
                var d = t
                d.reason = truncate(d.reason)
                d.confidence = clamp(d.confidence)
                out.append(d)
                continue
            }
            // (2) missing → default keep
            guard let item = itemByID[photo.id] else {
                out.append(defaultKeep(photo.id))
                continue
            }
            let confidence = clamp(item.confidence)
            let score = item.score.map { min(max($0, 1), 10) }
            let reason = truncate(item.reason)
            switch item.verdict {
            case "keep":
                out.append(CullDecision(photoID: photo.id, verdict: .keep, reason: reason, criterion: item.criterion,
                                        keeperID: nil, confidence: confidence, source: .model, score: score))
            case "reject":
                if confidence < threshold {   // (3)
                    out.append(CullDecision(photoID: photo.id, verdict: .keep,
                                            reason: truncate("low confidence: " + item.reason),
                                            criterion: item.criterion, keeperID: nil,
                                            confidence: confidence, source: .validatorOverride, score: score))
                } else {
                    out.append(CullDecision(photoID: photo.id, verdict: .reject, reason: reason, criterion: item.criterion,
                                            keeperID: nil, confidence: confidence, source: .model, score: score))
                    if let k = item.keeper, let kid = tokens[k] { pendingKeeper[photo.id] = kid }
                }
            default:
                out.append(defaultKeep(photo.id))
            }
        }

        // Strict: a kept model frame scoring under the floor is rejected.
        if mode == .strict {
            for i in out.indices where out[i].verdict == .keep && out[i].source != .localTriage {
                if let sc = out[i].score, sc < CullMode.strictScoreFloor {
                    out[i].verdict = .reject
                    out[i].criterion = "weak"
                    out[i].reason = "weak shot"
                    out[i].source = .validatorOverride
                    out[i].keeperID = nil
                }
            }
        }

        // (4) keeper must be a known, other, non-rejected photo.
        let rejected = Set(out.filter { $0.verdict == .reject }.map(\.photoID))
        for i in out.indices {
            guard out[i].verdict == .reject, let kid = pendingKeeper[out[i].photoID] else { continue }
            if groupIDs.contains(kid), kid != out[i].photoID, !rejected.contains(kid) {
                out[i].keeperID = kid
            }
        }

        // (5)/(6) all-reject rescue.
        if out.count > 0, out.allSatisfy({ $0.verdict == .reject }) {
            let allTriage = out.allSatisfy { $0.source == .localTriage }
            let applies = group.kind == .burst || (mode == .gentle && !allTriage)
            if applies, mode.rescuesAllRejectBursts, let best = bestIndex(group: group) {
                out[best] = CullDecision(photoID: out[best].photoID, verdict: .keep,
                                         reason: "kept: best of all-reject burst", criterion: out[best].criterion,
                                         keeperID: nil, confidence: out[best].confidence, source: .validatorOverride)
            }
        }
        return out
    }

    private static func bestIndex(group: PhotoGroup) -> Int? {
        var best: Int?
        var bestScore = -Double.infinity
        for (i, p) in group.photos.enumerated() {
            let s = PhotoRank.score(p)
            if best == nil || s > bestScore { best = i; bestScore = s }
        }
        return best
    }

    private static func defaultKeep(_ id: String) -> CullDecision {
        CullDecision(photoID: id, verdict: .keep, reason: "no decision", criterion: nil,
                     keeperID: nil, confidence: 0, source: .defaultKeep)
    }

    private static func truncate(_ s: String) -> String {
        s.count > maxReasonLength ? String(s.prefix(maxReasonLength)) : s
    }

    private static func clamp(_ c: Double) -> Double {
        c.isNaN ? 0 : min(max(c, 0), 1)
    }
}
