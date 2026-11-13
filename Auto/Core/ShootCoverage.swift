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
    struct Result: Sendable, Equatable {
        var verified: Set<URL>
        /// True when the run was cancelled: `verified` is partial and must not be treated as complete.
        var cancelled: Bool
        /// Set when the shoot folder couldn't be checked at all (not a readable folder, or on a card).
        var failure: String? = nil
        /// Card file URL -> the checksum-verified copy inside the shoot folder.
        var copies: [URL: URL] = [:]
    }

    /// Card files that have a checksum-identical copy INSIDE `shootFolder` (any subfolder; camera
    /// folder irrelevant). Name + size only nominate candidates. Copies outside the folder never
    /// count. Read-only: nothing is written anywhere.
    /// `@concurrent`: a plain nonisolated async func would run on the caller's actor (see DriveIndex).
    /// Cancelling the calling task cancels `verifier`.
    @concurrent static func run(
        files: [MediaFile],
        shootFolder: URL,
        sessionCopies: [CopiedFile],
        cache: VerificationCache,
        verifier: BackupVerifier = BackupVerifier(),
        cardVolumes: [URL] = [],
        excluding: [URL] = [],
        progress: @escaping @Sendable (CopyProgress) -> Void
    ) async -> Result {
        MainThreadProbe.shared.mark("ShootCoverageChecker.run")
        return await withTaskCancellationHandler {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: shootFolder.path, isDirectory: &isDir), isDir.boolValue,
                  FileManager.default.isReadableFile(atPath: shootFolder.path) else {
                return Result(verified: [], cancelled: false, failure: "The shoot folder can't be read.")
            }
            if VolumeClassifier.isOnCard(shootFolder, cards: cardVolumes) {
                return Result(verified: [], cancelled: false, failure: "The shoot folder is on a camera card.")
            }
            let candidates = await candidates(in: shootFolder, sessionCopies: sessionCopies,
                                              cardVolumes: cardVolumes, excluding: excluding)

            let triage = await BackupVerifier.triageOffMain(files: files, candidates: candidates, cache: cache)
            var results = triage.settled
            var cancelled = Task.isCancelled
            if !triage.toVerify.isEmpty, !cancelled {
                let outcome = await verifier.run(triage.toVerify, candidates: candidates, cache: cache) { progress($0) }
                results.merge(outcome.results) { $1 }
                cancelled = outcome.cancelled || Task.isCancelled
            }
            var copies: [URL: URL] = [:]
            for (url, result) in results {
                if case .verified(let copy) = result { copies[url] = copy }
            }
            return Result(verified: Set(copies.keys), cancelled: cancelled, copies: copies)
        } onCancel: {
            verifier.cancel()
        }
    }

    /// Name+size candidate index of everything inside `shootFolder`, plus this session's copies that
    /// landed there and aren't indexed yet. Never a card file or anything under `excluding`.
    private static func candidates(in shootFolder: URL, sessionCopies: [CopiedFile], cardVolumes: [URL],
                                   excluding: [URL]) async -> [String: [URL]] {
        // Canonicalize excluded folders once; each candidate is canonicalized once below.
        let excludedRoots = excluding.map { canonical($0) }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func isExcluded(_ url: URL) -> Bool {
            guard !excludedRoots.isEmpty else { return false }
            let path = canonical(url)
            return excludedRoots.contains { path.hasPrefix($0) }
        }
        // A card's own files never count as their own backup, even if a shoot folder contains the card.
        func isUsable(_ url: URL) -> Bool {
            !VolumeClassifier.isInside(url, anyOf: cardVolumes) && !isExcluded(url)
        }

        let indexed = await DriveIndex.build(shootFolder).compactMapValues { urls -> [URL]? in
            let kept = urls.filter(isUsable)
            return kept.isEmpty ? nil : kept
        }
        let indexedPaths = Set(indexed.values.joined().map(canonical))
        let unindexedSessionCopies = sessionCopies.filter { copy in
            isInside(copy.destination, folder: shootFolder)
                && !indexedPaths.contains(canonical(copy.destination))
                && isUsable(copy.destination)
        }
        return BackupVerifier.addingCandidates(unindexedSessionCopies, to: indexed)
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isInside(_ url: URL, folder: URL) -> Bool {
        let root = canonical(folder)
        return canonical(url).hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
