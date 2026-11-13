import CoreGraphics
import Foundation

nonisolated struct FileStamp: Sendable, Codable, Equatable {
    let size: Int64
    let mtime: Date
}

nonisolated struct FaceInfo: Sendable, Codable, Equatable {
    /// Normalized (0...1) face rectangle.
    var box: CGRect
    var eyesClosed: Bool
    var edgeCut: Bool
    var quality: Double?
}

nonisolated struct PhotoMetrics: Sendable, Codable, Equatable {
    var captureTime: Date?
    var meanLuma: Double
    var lumaStdDev: Double
    var clipHighPct: Double
    var clipLowPct: Double
    var sharpness: Double
    var faceSharpness: Double?
    var dHash: UInt64
    var horizonTiltDeg: Double?
    var faces: [FaceInfo]
}

nonisolated struct PhotoRecord: Sendable, Identifiable, Equatable {
    /// Shoot-relative path of the representative file.
    let id: String
    let camera: String
    /// Shoot-relative paths of every file in the pair or set.
    let members: [String]
    /// JPEG preferred.
    let representative: String
    let stamps: [String: FileStamp]
    var metrics: PhotoMetrics?
    var preview: URL?
    var faceStrip: URL?
}

nonisolated enum GroupKind: String, Sendable, Codable {
    case burst, mixed
}

nonisolated struct PhotoGroup: Sendable, Identifiable {
    let id: Int
    let kind: GroupKind
    let camera: String
    let photos: [PhotoRecord]
}

nonisolated enum Verdict: String, Sendable, Codable {
    case keep, reject
}

nonisolated enum DecisionSource: String, Sendable, Codable {
    case model, localTriage, validatorOverride, defaultKeep, finalRound
}

nonisolated struct CullDecision: Sendable, Codable, Equatable {
    let photoID: String
    var verdict: Verdict
    var reason: String
    var criterion: String?
    var keeperID: String?
    var confidence: Double
    var source: DecisionSource
    /// 1...10 frame score, derived from `grades`.
    var score: Int? = nil
    /// The model's grades, when the model graded this frame.
    var grades: CullGrades? = nil
}

nonisolated struct CullPlan: Sendable {
    let runID: UUID
    let settings: CullSettings
    let decisions: [CullDecision]
    let records: [String: PhotoRecord]
    var catalogCopy: URL? = nil
    /// Run totals for the journal's finished summary.
    var spentUSD: Double = 0
    var groupsDone = 0
    var groupsTotal = 0
    var note: String? = nil
}

nonisolated enum CullPhase: Sendable, Equatable {
    case waiting(String)
    case cataloging
    case preparing(done: Int, total: Int)
    case analyzing(done: Int, total: Int)
    case finalRound(done: Int, total: Int)
    case applying(done: Int, total: Int)
    case reverting(done: Int, total: Int)
    case undoing(done: Int, total: Int)
}

nonisolated struct CullProgress: Sendable, Equatable {
    let phase: CullPhase
    let fraction: Double
    let spentUSD: Double
}

nonisolated struct CullRunSummary: Sendable, Codable, Equatable {
    let runID: UUID
    let date: Date
    let model: CullModel
    let photos: Int
    let rejected: Int
    let groupsDone: Int
    let groupsTotal: Int
    let spentUSD: Double
    var undone: Bool
    /// "completed", "cancelled" or "failed".
    var status: String = "completed"
    /// Pairs left alone because the destination was on another volume.
    var skippedCrossVolume: Int = 0
    /// Extra detail for the run, e.g. that the final round finished by score.
    var note: String?
}

extension CullRunSummary {
    enum CodingKeys: String, CodingKey {
        case runID, date, model, photos, rejected, groupsDone, groupsTotal, spentUSD, undone, status, skippedCrossVolume, note
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(UUID.self, forKey: .runID)
        date = try c.decode(Date.self, forKey: .date)
        model = try c.decode(CullModel.self, forKey: .model)
        photos = try c.decode(Int.self, forKey: .photos)
        rejected = try c.decode(Int.self, forKey: .rejected)
        groupsDone = try c.decode(Int.self, forKey: .groupsDone)
        groupsTotal = try c.decode(Int.self, forKey: .groupsTotal)
        spentUSD = try c.decode(Double.self, forKey: .spentUSD)
        undone = try c.decode(Bool.self, forKey: .undone)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "completed"
        skippedCrossVolume = try c.decodeIfPresent(Int.self, forKey: .skippedCrossVolume) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

nonisolated enum CullOutcome: Sendable {
    case completed(CullRunSummary)
    /// Nothing is left moved.
    case stopped(CullRunSummary?)
    case failed(CullError, CullRunSummary?)
}
