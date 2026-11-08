import Foundation

/// How hard a cull culls. Replaces the old 1...5 strictness slider.
nonisolated enum CullMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case gentle, balanced, selective, strict, selects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: "Gentle"
        case .balanced: "Balanced"
        case .selective: "Selective"
        case .strict: "Strict"
        case .selects: "Selects"
        }
    }

    var blurb: String {
        switch self {
        case .gentle: "Only obvious failures: black frames, misfires, badly blurred."
        case .balanced: "Best frame of each burst; obvious failures out."
        case .selective: "Best of each burst, plus weak singles with a clear flaw."
        case .strict: "Key moments, groups and details, plus only the stronger candids."
        case .selects: "About the best 15% of the shoot, more or less with its quality."
        }
    }

    /// Feeds the LocalTriage thresholds.
    var triageLevel: Int { self == .gentle ? 2 : 5 }

    var rescuesAllRejectBursts: Bool { self != .strict && self != .selects }
    var hasFinalRound: Bool { self == .selects }

    // Policy knobs (see `CullPolicy`). Tune here, not in the prompt.

    /// Near-identical frames collapse to the best one per moment.
    var dedupesMoments: Bool { self != .gentle }
    /// Behind-the-scenes frames (other photographers, gear) go.
    var rejectsCrew: Bool { self != .gentle }
    /// Unprotected roles (candid, establishing) under this weighted 1...5 quality go.
    /// Selects shares Strict's floor; its final round then ranks what is left down to the target.
    var qualityFloor: Double? {
        switch self {
        case .gentle, .balanced: nil
        case .selective: 2.5
        case .strict, .selects: 3.0
        }
    }
    /// Unprotected roles whose prominent subject grades 1 (eyes closed, eating, yawning) go.
    var subjectVeto: Bool { self == .selective || self == .strict || self == .selects }

    /// Selects aims for this share of the shoot, scaled by how many frames grade well.
    static let selectsKeepFraction = 0.15

    static func migrated(fromAggressiveness level: Int) -> CullMode {
        level <= 2 ? .gentle : .balanced
    }
}
