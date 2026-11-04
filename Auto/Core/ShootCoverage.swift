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
            // A card's own files never count as their own backup, even if a shoot folder contains the card.
            var candidates = await DriveIndex.build(shootFolder).compactMapValues { urls -> [URL]? in
                let kept = urls.filter { !VolumeClassifier.isInside($0, anyOf: cardVolumes) }
                return kept.isEmpty ? nil : kept
            }
            let known = Set(candidates.values.joined().map(canonical))
            let inside = sessionCopies.filter {
                isInside($0.destination, folder: shootFolder) && !known.contains(canonical($0.destination))
                    && !VolumeClassifier.isInside($0.destination, anyOf: cardVolumes)
            }
            candidates = BackupVerifier.addingCandidates(inside, to: candidates)

            let triage = await BackupVerifier.triageOffMain(files: files, candidates: candidates, cache: cache)
            var results = triage.settled
            var cancelled = Task.isCancelled
            if !triage.toVerify.isEmpty, !cancelled {
                let outcome = await verifier.run(triage.toVerify, candidates: candidates, cache: cache) { progress($0) }
                results.merge(outcome.results) { $1 }
                cancelled = outcome.cancelled || Task.isCancelled
            }
            return Result(verified: Set(results.filter { $0.value.isVerified }.keys), cancelled: cancelled)
        } onCancel: {
            verifier.cancel()
        }
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isInside(_ url: URL, folder: URL) -> Bool {
        let root = canonical(folder)
        return canonical(url).hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
