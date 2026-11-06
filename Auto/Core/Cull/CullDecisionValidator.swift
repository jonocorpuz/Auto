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
    }
    let decisions: [Item]
}

nonisolated enum CullDecisionValidator {
    static let maxReasonLength = 90

    /// Minimum confidence for a model reject to stand. 1:0.90 2:0.85 3:0.75 4:0.65 5:0.55
    static func minConfidence(_ aggressiveness: Int) -> Double {
        switch min(max(aggressiveness, 1), 5) {
        case 1: return 0.90
        case 2: return 0.85
        case 3: return 0.75
        case 4: return 0.65
        default: return 0.55
        }
    }

    /// Exactly one decision per photo, in group order.
    static func validate(
        group: PhotoGroup,
        tokens: [String: String],
        modelOutput: ModelDecisions?,
        triage: [CullDecision],
        settings: CullSettings
    ) -> [CullDecision] {
        let level = min(max(settings.aggressiveness, 1), 5)
        let threshold = minConfidence(level)
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
            let reason = truncate(item.reason)
            switch item.verdict {
            case "keep":
                out.append(CullDecision(photoID: photo.id, verdict: .keep, reason: reason, criterion: item.criterion,
                                        keeperID: nil, confidence: confidence, source: .model))
            case "reject":
                if confidence < threshold {   // (3)
                    out.append(CullDecision(photoID: photo.id, verdict: .keep,
                                            reason: truncate("low confidence: " + item.reason),
                                            criterion: item.criterion, keeperID: nil,
                                            confidence: confidence, source: .validatorOverride))
                } else {
                    out.append(CullDecision(photoID: photo.id, verdict: .reject, reason: reason, criterion: item.criterion,
                                            keeperID: nil, confidence: confidence, source: .model))
                    if let k = item.keeper, let kid = tokens[k] { pendingKeeper[photo.id] = kid }
                }
            default:
                out.append(defaultKeep(photo.id))
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
            let applies = group.kind == .burst || (level <= 2 && !allTriage)
            if applies, let best = bestIndex(group: group) {
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
