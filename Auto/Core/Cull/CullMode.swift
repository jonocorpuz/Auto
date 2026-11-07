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
        case .strict: "Only strong shots. Mid shots that aren't the best go."
        case .selects: "Only the top 10% of the shoot."
        }
    }

    /// Feeds the LocalTriage thresholds.
    var triageLevel: Int { self == .gentle ? 2 : 5 }

    var minConfidence: Double {
        switch self {
        case .gentle: 0.90
        case .balanced: 0.75
        case .selective: 0.65
        case .strict: 0.60
        case .selects: 0.50
        }
    }

    var rescuesAllRejectBursts: Bool { self != .strict && self != .selects }
    var scoresFrames: Bool { self == .strict || self == .selects }
    var hasFinalRound: Bool { self == .selects }

    static let selectsKeepFraction = 0.10
    static let strictScoreFloor = 6

    static func migrated(fromAggressiveness level: Int) -> CullMode {
        level <= 2 ? .gentle : .balanced
    }
}
