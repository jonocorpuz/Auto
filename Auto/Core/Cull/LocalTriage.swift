import Foundation

/// Cheap, certain rejections made without asking Claude.
nonisolated enum LocalTriage {
    /// Clip threshold: 0.92 at level 1 down to 0.80 at level 5.
    static func clipThreshold(level: Int) -> Double {
        let l = Double(min(max(level, 1), 5))
        return 0.92 - (l - 1) * 0.03
    }

    static func blurThreshold(level: Int) -> Double {
        switch min(max(level, 1), 5) {
        case 1, 2: return 5
        case 3: return 10
        default: return 15
        }
    }

    static func decide(_ p: PhotoRecord, settings: CullSettings) -> CullDecision? {
        guard let m = p.metrics else { return nil }
        let level = settings.mode.triageLevel

        func reject(_ reason: String, _ criterion: CullCriterion) -> CullDecision {
            CullDecision(photoID: p.id, verdict: .reject, reason: reason, criterion: criterion.id,
                         keeperID: nil, confidence: 1, source: .localTriage)
        }

        let unusable = settings.criteria.contains(CullCriterion.unusable.id)
        if unusable, m.meanLuma < 0.02, m.lumaStdDev < 0.01 {
            return reject("black frame / lens cap", .unusable)
        }
        if settings.criteria.contains(CullCriterion.exposure.id) {
            let t = clipThreshold(level: level)
            if m.clipHighPct > t {
                return reject("highlights blown \(Int((m.clipHighPct * 100).rounded()))%", .exposure)
            }
            if m.clipLowPct > t {
                return reject("shadows crushed \(Int((m.clipLowPct * 100).rounded()))%", .exposure)
            }
        }
        if unusable, m.faces.isEmpty, m.sharpness < blurThreshold(level: level) {
            return reject("severely blurred", .unusable)
        }
        return nil
    }
}
