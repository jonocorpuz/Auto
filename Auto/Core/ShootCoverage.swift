import Foundation

/// How much of a card's recording day is already inside a shoot folder.
nonisolated struct ShootCoverage: Sendable, Equatable {
    let day: Date
    let dayTotal: Int
    let dayInShoot: Int
    /// All card files (any day) with no verified copy inside the shoot folder.
    let notInShoot: [MediaFile]

    var isComplete: Bool { dayTotal > 0 && dayInShoot == dayTotal }

    /// `inShoot`: card file URLs verified (by checksum) to be present in the shoot.
    static func compute(files: [MediaFile], day: Date, calendar: Calendar, inShoot: Set<URL>) -> ShootCoverage {
        let target = calendar.startOfDay(for: day)
        let onDay = files.filter { calendar.startOfDay(for: $0.date) == target }
        return ShootCoverage(
            day: target,
            dayTotal: onDay.count,
            dayInShoot: onDay.filter { inShoot.contains($0.url) }.count,
            notInShoot: files.filter { !inShoot.contains($0.url) }
        )
    }
}

nonisolated enum ShootCoverageChecker {
    /// Card files that have a checksum-identical copy INSIDE `shootFolder` (any subfolder; camera
    /// folder irrelevant). Name + size only nominate candidates. Copies outside the folder never
    /// count. Read-only: nothing is written anywhere.
    static func run(
        files: [MediaFile],
        shootFolder: URL,
        sessionCopies: [CopiedFile],
        cache: VerificationCache,
        progress: @escaping @Sendable (CopyProgress) -> Void
    ) async -> Set<URL> {
        var candidates = await DriveIndex.build(shootFolder)
        let known = Set(candidates.values.joined().map(canonical))
        let inside = sessionCopies.filter {
            isInside($0.destination, folder: shootFolder) && !known.contains(canonical($0.destination))
        }
        candidates = BackupVerifier.addingCandidates(inside, to: candidates)

        let triage = await BackupVerifier.triageOffMain(files: files, candidates: candidates, cache: cache)
        var results = triage.settled
        if !triage.toVerify.isEmpty {
            let outcome = await BackupVerifier().run(triage.toVerify, candidates: candidates, cache: cache) { progress($0) }
            results.merge(outcome.results) { $1 }
        }
        return Set(results.filter { $0.value.isVerified }.keys)
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isInside(_ url: URL, folder: URL) -> Bool {
        let root = canonical(folder)
        return canonical(url).hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
