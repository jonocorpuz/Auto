import Foundation

/// Production `CullApplying`: wraps `CullApplier` with the live file-system hooks.
nonisolated struct LiveCullApplier: CullApplying {
    /// MD5 lookup for the mirror-vs-primary check (nil = unknown).
    var hashLookup: @Sendable (URL) -> String? = { _ in nil }

    func apply(_ plan: CullPlan, copies: [URL], cardVolumes: [URL], onMoved: @escaping @Sendable (Int, Int) -> Void) throws -> Int {
        try CullApplier.apply(plan, copies: copies, cardVolumes: cardVolumes, hashLookup: hashLookup, onMoved: onMoved)
    }

    func revert(runID: UUID, copies: [URL], cardVolumes: [URL], onProgress: @escaping @Sendable (Int, Int) -> Void) throws {
        try CullApplier.undo(runID: runID, copies: copies, cardVolumes: cardVolumes, onProgress: onProgress)
    }
}
