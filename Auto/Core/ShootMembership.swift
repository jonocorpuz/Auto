import Foundation

/// Which shoot folders hold a checksum-verified copy of each card file, for the card browser.
/// Read-only: runs `ShootCoverageChecker` per shoot, excluding nested shoots so a copy inside a
/// child shoot counts for the child only.
nonisolated enum ShootMembership {
    struct Target: Sendable, Hashable {
        let id: UUID
        let folder: URL
    }

    enum Outcome: Sendable, Equatable {
        case verified(Set<URL>, copies: [URL: URL])
        case failed(String)
    }

    /// Other folders strictly inside `folder` (lexical, standardized). An equal path or a
    /// sibling sharing a name prefix ("Wedding2" vs "Wedding") is not inside.
    static func nested(in folder: URL, among folders: [URL]) -> [URL] {
        let root = folder.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return folders.filter {
            let p = $0.standardizedFileURL.path
            return p != root && p.hasPrefix(prefix)
        }
    }

    /// Sequential per target. `onResult` fires once per finished shoot; a cancelled or partial
    /// shoot is never reported, and no further shoots start after cancellation.
    @concurrent static func run(
        files: [MediaFile],
        targets: [Target],
        sessionCopies: [CopiedFile],
        cache: VerificationCache,
        cardVolumes: [URL],
        makeVerifier: @escaping @Sendable () -> BackupVerifier = { BackupVerifier() },
        onResult: @escaping @MainActor @Sendable (UUID, Outcome) -> Void
    ) async {
        MainThreadProbe.shared.mark("ShootMembership.run")
        let folders = targets.map(\.folder)
        for target in targets {
            if Task.isCancelled { return }
            let result = await ShootCoverageChecker.run(
                files: files,
                shootFolder: target.folder,
                sessionCopies: sessionCopies,
                cache: cache,
                verifier: makeVerifier(),
                cardVolumes: cardVolumes,
                excluding: nested(in: target.folder, among: folders)
            ) { _ in }
            if result.cancelled || Task.isCancelled { return }
            let outcome: Outcome = result.failure.map { .failed($0) }
                ?? .verified(result.verified, copies: result.copies)
            await onResult(target.id, outcome)
        }
    }
}
