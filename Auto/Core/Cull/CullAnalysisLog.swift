import Foundation

/// One Claude call of a cull run, for tuning: what was sent, what it cost, how it ended.
nonisolated struct CullCallRecord: Sendable, Codable, Equatable {
    /// "group" (first pass) or "final" (Selects final round).
    let kind: String
    /// Group position (1-based) or final-round batch label, e.g. "r1b3".
    let label: String
    let photoIDs: [String]
    var costUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var durationMS: Int?
    /// "ok", "unreadable" (reply didn't decode) or "error: <message>".
    var outcome: String
}

/// Everything one cull run decided and spent, written once per run for prompt tuning.
/// Diagnostic only: never read back to make a decision.
nonisolated struct CullAnalysisReport: Sendable, Codable, Equatable {
    let runID: UUID
    let date: Date
    let mode: CullMode
    let model: CullModel
    let promptVersion: Int
    let criteria: [String]
    let photos: Int
    let spentUSD: Double
    let calls: [CullCallRecord]
    /// Every photo's final decision, keeps included.
    let decisions: [CullDecision]
}

/// Writes `CullAnalysisReport`s to `<copy>/.auto-cull/analysis/<ISO-date>_<runID>.json`.
/// Kept out of the move journal: the journal drives undo and sync, this file never does.
nonisolated enum CullAnalysisLog {
    private static let directoryName = "analysis"

    static func directory(in copy: URL) -> URL {
        CullJournal.directory(in: copy).appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes the report with an exclusive create, so an existing file is never replaced.
    @discardableResult
    static func write(_ report: CullAnalysisReport, in copy: URL) throws -> URL {
        let dir = directory(in: copy)
        try ShootPlanner.createDirectories([CullJournal.directory(in: copy), dir], root: copy, cardVolumes: [])
        let fileName = "\(CullJournal.fileNameDateStamp(for: report.date))_\(report.runID.uuidString).json"
        let url = dir.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: [.withoutOverwriting])
        return url
    }
}

/// Thread-safe collector of call records during a run.
nonisolated final class CullCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [CullCallRecord] = []

    var records: [CullCallRecord] { lock.withLock { collected } }

    /// Builds and records one call. `response` nil means the call threw `error`.
    func record(kind: String, label: String, photoIDs: [String], response: ClaudeResponse?,
                decoded: Bool, error: Error?, durationMS: Int) {
        var record = CullCallRecord(kind: kind, label: label, photoIDs: photoIDs, outcome: "ok")
        record.durationMS = durationMS
        if let response {
            record.costUSD = response.costUSD
            record.inputTokens = response.inputTokens
            record.outputTokens = response.outputTokens
            record.cacheReadTokens = response.cacheReadTokens
            record.cacheWriteTokens = response.cacheWriteTokens
            record.durationMS = response.durationMS ?? durationMS
            if !decoded { record.outcome = "unreadable" }
        } else {
            record.outcome = "error: " + (error?.localizedDescription ?? "unknown")
        }
        lock.withLock { collected.append(record) }
    }
}
