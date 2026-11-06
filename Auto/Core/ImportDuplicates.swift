import Foundation

nonisolated enum ImportDuplicateFinder {
    /// Files with a checksum-identical copy anywhere inside `shootFolder` (any subfolder, including
    /// `_Rejects`). Name + size only nominate; the checksum decides. Read-only.
    /// Throws `ImportRefusal.unreadable` when the shoot can't be checked, `CancellationError` when cancelled
    /// (a partial answer would silently re-add duplicates).
    @concurrent static func find(
        _ files: [MediaFile],
        shootFolder: URL,
        cache: VerificationCache,
        cardVolumes: [URL],
        progress: @escaping @Sendable (CopyProgress) -> Void
    ) async throws -> Set<URL> {
        guard !files.isEmpty else { return [] }
        let result = await ShootCoverageChecker.run(
            files: files, shootFolder: shootFolder, sessionCopies: [], cache: cache,
            cardVolumes: cardVolumes, progress: progress)
        if let failure = result.failure { throw ImportRefusal.unreadable(failure) }
        if result.cancelled { throw CancellationError() }
        return result.verified
    }
}
