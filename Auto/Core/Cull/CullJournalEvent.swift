import Foundation

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
