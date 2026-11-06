import CoreGraphics
import Foundation

/// Claude model alias used for a cull. rawValue is the CLI alias.
nonisolated enum CullModel: String, Sendable, Codable, CaseIterable {
    case haiku, sonnet, opus
}

nonisolated struct CullSettings: Sendable, Codable, Equatable {
    var criteria: Set<String>
    /// 1...5, clamped.
    var aggressiveness: Int
    var model: CullModel
    /// nil = generated run section.
    var customRunPrompt: String?
    /// UI only; has no effect on applying decisions.
    var reviewBeforeApplying: Bool
    /// 1...4, clamped.
    var maxConcurrentCalls: Int
    var maxRunBudgetUSD: Double

    init(
        criteria: Set<String> = Set(CullCriterion.all.map(\.id)),
        aggressiveness: Int = 2,
        model: CullModel = .sonnet,
        customRunPrompt: String? = nil,
        reviewBeforeApplying: Bool = false,
        maxConcurrentCalls: Int = 2,
        maxRunBudgetUSD: Double = 5.0
    ) {
        self.criteria = criteria
        self.aggressiveness = aggressiveness
        self.model = model
        self.customRunPrompt = customRunPrompt
        self.reviewBeforeApplying = reviewBeforeApplying
        self.maxConcurrentCalls = maxConcurrentCalls
        self.maxRunBudgetUSD = maxRunBudgetUSD
    }

    /// Tolerates older or partial JSON: every missing key takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CullSettings()
        self.criteria = try c.decodeIfPresent(Set<String>.self, forKey: .criteria) ?? defaults.criteria
        self.aggressiveness = try c.decodeIfPresent(Int.self, forKey: .aggressiveness) ?? defaults.aggressiveness
        self.model = try c.decodeIfPresent(CullModel.self, forKey: .model) ?? defaults.model
        self.customRunPrompt = try c.decodeIfPresent(String.self, forKey: .customRunPrompt)
        self.reviewBeforeApplying = try c.decodeIfPresent(Bool.self, forKey: .reviewBeforeApplying) ?? defaults.reviewBeforeApplying
        self.maxConcurrentCalls = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentCalls) ?? defaults.maxConcurrentCalls
        self.maxRunBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .maxRunBudgetUSD) ?? defaults.maxRunBudgetUSD
        self = clamped()
    }

    /// Returns a copy with numeric fields pulled into their supported ranges.
    func clamped() -> CullSettings {
        var s = self
        s.aggressiveness = min(max(s.aggressiveness, 1), 5)
        s.maxConcurrentCalls = min(max(s.maxConcurrentCalls, 1), 4)
        s.maxRunBudgetUSD = s.maxRunBudgetUSD.isNaN ? CullSettings().maxRunBudgetUSD : max(s.maxRunBudgetUSD, 0.1)
        return s
    }
}

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
    case model, localTriage, validatorOverride, defaultKeep
}

nonisolated struct CullDecision: Sendable, Codable, Equatable {
    let photoID: String
    var verdict: Verdict
    var reason: String
    var criterion: String?
    var keeperID: String?
    var confidence: Double
    var source: DecisionSource
}

nonisolated struct CullPlan: Sendable {
    let runID: UUID
    let settings: CullSettings
    let decisions: [CullDecision]
    let records: [String: PhotoRecord]
    var catalogCopy: URL? = nil
}

nonisolated enum CullPhase: Sendable, Equatable {
    case waiting(String)
    case cataloging
    case preparing(done: Int, total: Int)
    case analyzing(done: Int, total: Int)
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
}

extension CullRunSummary {
    enum CodingKeys: String, CodingKey {
        case runID, date, model, photos, rejected, groupsDone, groupsTotal, spentUSD, undone, status, skippedCrossVolume
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
    }
}

nonisolated enum CullOutcome: Sendable {
    case completed(CullRunSummary)
    /// Nothing is left moved.
    case stopped(CullRunSummary?)
    case failed(CullError, CullRunSummary?)
}

nonisolated enum CullError: LocalizedError, Equatable {
    case shootOffline
    case noCopiesOnline
    case onCard
    case outsideShoot(String)
    case noPhotos
    case busy(String)
    case claudeNotInstalled
    case claudeNotLoggedIn
    case claudeFailed(String)
    case budgetExceeded(Double)
    case sourceChanged(String)
    case crossVolume(String)
    case journalWriteFailed(String)
    case nothingToUndo
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .shootOffline:
            return "This shoot's drive is offline. Connect it and try again."
        case .noCopiesOnline:
            return "None of this shoot's copies are online."
        case .onCard:
            return "That folder is on a memory card. Culls only change copies on your drives."
        case .outsideShoot(let path):
            return "\(path) is outside the shoot folder."
        case .noPhotos:
            return "There are no photos to cull in this shoot."
        case .busy(let reason):
            return "The cull can't start yet: \(reason)."
        case .claudeNotInstalled:
            return "The Claude Code CLI isn't installed. Install it, then try again."
        case .claudeNotLoggedIn:
            return "Claude Code isn't logged in. Run `claude` in Terminal and log in, then try again."
        case .claudeFailed(let message):
            return "Claude failed: \(message)"
        case .budgetExceeded(let amount):
            return String(format: "The cull reached its $%.2f budget. Nothing was moved.", amount)
        case .sourceChanged(let path):
            return "\(path) changed since it was scanned, so it was left alone."
        case .crossVolume(let path):
            return "\(path) is on a different volume, so it can't be moved safely."
        case .journalWriteFailed(let message):
            return "Couldn't write the cull journal: \(message)"
        case .nothingToUndo:
            return "There's no cull to undo."
        case .rollbackFailed(let paths):
            return "Some photos couldn't be put back (\(paths)). Undo the cull to restore them."
        }
    }
}

nonisolated enum CullJournalEvent: Codable, Sendable {
    case run(runID: UUID, date: Date, model: CullModel, settings: CullSettings)
    /// from/to are shoot-relative.
    case moved(runID: UUID, from: String, to: String, reason: String, criterion: String?, keeper: String?, photoID: String)
    /// Written (fsynced) before a pair member is renamed, so a crash mid-rename is recoverable.
    case intent(runID: UUID, from: String, to: String, photoID: String, size: Int64? = nil)
    /// One atomic line for a verified pair; supersedes the intents and the legacy per-member `moved`.
    case movedPair(runID: UUID, members: [CullMovedMember], reason: String, criterion: String?, keeper: String?, photoID: String)
    case restored(runID: UUID, from: String, to: String)
    case restoreSkipped(runID: UUID, path: String, why: String)
    case finished(runID: UUID, summary: CullRunSummary)
    case undone(runID: UUID, date: Date)
}


nonisolated struct CullMovedMember: Codable, Sendable, Equatable {
    let from: String
    let to: String
}
