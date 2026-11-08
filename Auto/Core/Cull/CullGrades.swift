import Foundation

/// What a frame is, as the model reads it. Drives which rules apply.
nonisolated enum FrameRole: String, Sendable, Codable, CaseIterable {
    case milestone, group, celebration, establishing, candid, detail, crew, accidental

    /// Kept unless unusable (deduped within a moment): the shots the story needs.
    var isProtected: Bool {
        switch self {
        case .milestone, .group, .celebration, .detail: true
        case .establishing, .candid, .crew, .accidental: false
        }
    }

    /// Gets priority into the Selects final-round pool.
    var isKeyMoment: Bool { self == .milestone || self == .group || self == .celebration }
}

/// The model's description of one frame. The app turns it into a verdict (`CullPolicy`).
nonisolated struct CullGrades: Sendable, Codable, Equatable {
    var role: FrameRole
    /// Moment label within its group ("m1"); frames sharing it are near-identical.
    var moment: String
    /// 1...5 each. `subject` is 0 when no person matters in the frame.
    var technical: Int
    var composition: Int
    var subject: Int
    var story: Int

    static let weights = (technical: 0.20, composition: 0.25, subject: 0.25, story: 0.30)

    /// Weighted 1...5. `subject` 0 is left out and the other weights rescale.
    var quality: Double {
        var sum = Double(technical) * Self.weights.technical
            + Double(composition) * Self.weights.composition
            + Double(story) * Self.weights.story
        var weight = Self.weights.technical + Self.weights.composition + Self.weights.story
        if subject > 0 {
            sum += Double(subject) * Self.weights.subject
            weight += Self.weights.subject
        }
        return sum / weight
    }

    /// `quality` mapped onto 1...10 for ranking and the Selects round.
    var score: Int {
        min(10, max(1, Int((1 + (quality - 1) * 9 / 4).rounded())))
    }

    /// Unusable whatever the mode: nothing meant to be photographed, or a broken frame.
    var isUnusable: Bool { role == .accidental || technical <= 1 }
}

/// Structured output of one grading call.
nonisolated struct ModelGrades: Decodable, Sendable {
    struct Frame: Decodable, Sendable {
        let id: String
        let role: String
        let moment: String
        let technical: Int
        let composition: Int
        let subject: Int
        let story: Int
        let reason: String
    }
    let frames: [Frame]
}
