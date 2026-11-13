import Foundation

// MARK: - Apply

nonisolated extension CullApplier {
    private struct Planned {
        let rel: String
        let srcDir: Int32
        let srcName: String
        let info: Info
        var to = ""
        var dstDir: Int32 = -1
        var dstName = ""
    }

    private enum PairOutcome { case moved(n: Int), skipped, crossVolume }

    /// Returns the number of pairs moved on the primary copy. Throws `CancellationError` after
    /// finishing cleanly when cancelled (the journal then holds exactly what moved).
    static func apply(
        _ plan: CullPlan,
        copies: [URL],
        cardVolumes: [URL],
        hashLookup: @Sendable (URL) -> String? = { _ in nil },
        io: CullIO = .live,
        onMoved: @Sendable (Int, Int) -> Void
    ) throws -> Int {
        let rejects = uniqueRejects(in: plan)

        var online = try checkCopies(copies, cardVolumes: cardVolumes)
        guard let catalog = plan.catalogCopy?.standardizedFileURL.path,
              let pi = online.firstIndex(where: { $0.standardizedFileURL.path == catalog }) else {
            throw CullError.shootOffline
        }
        online.insert(online.remove(at: pi), at: 0)   // the primary (catalogued) copy goes first
        guard !rejects.isEmpty else { return 0 }

        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        for copy in online {
            guard let fd = openCopy(copy) else { throw CullError.noCopiesOnline }
            fds.append(fd)
        }

        try journalRunStart(plan, on: online)

        let total = rejects.count
        var processed = 0
        var movedOnCopy = [Int](repeating: 0, count: online.count)
        var crossOnCopy = [Int](repeating: 0, count: online.count)
        var failure: Error?
        var cancelled = false
        let primaryURL = online[0]

        pairs: for (decision, record) in rejects {
            if Task.isCancelled { cancelled = true; break }
            var members = record.members
            if !members.contains(record.representative) { members.insert(record.representative, at: 0) }

            var sharedN = 1
            copyLoop: for (ci, copy) in online.enumerated() {
                let primary = ci == 0
                let check: (String, Info) -> Bool = { rel, info in
                    memberUnchanged(rel, info, record: record, isPrimary: primary, primaryURL: primaryURL,
                                    copy: copy, hashLookup: hashLookup)
                }
                let journal: (CullJournalEvent) throws -> Void = {
                    try CullJournal.append($0, runID: plan.runID, in: copy)
                }
                do {
                    let outcome = try movePair(members: members, copyFD: fds[ci], startN: sharedN, runID: plan.runID,
                                               decision: decision, io: io, check: check, journal: journal)
                    switch outcome {
                    case .moved(let n):
                        movedOnCopy[ci] += 1
                        if primary { sharedN = n }
                    case .skipped:
                        if primary { break copyLoop }   // primary skipped: leave mirrors alone too
                    case .crossVolume:
                        crossOnCopy[ci] += 1
                        if primary { break copyLoop }
                    }
                } catch {
                    failure = error
                    break pairs
                }
            }
            processed += 1
            onMoved(processed, total)
        }

        let status: String
        if failure != nil {
            status = "failed"
        } else if cancelled {
            status = "cancelled"
        } else {
            status = "completed"
        }
        journalRunFinished(plan, on: online, status: status, movedOnCopy: movedOnCopy, crossOnCopy: crossOnCopy)
        if let failure { throw failure }
        if cancelled { throw CancellationError() }
        return movedOnCopy[0]
    }

    /// Each rejected photo once, in decision order. Decisions for photos missing from the plan are dropped.
    private static func uniqueRejects(in plan: CullPlan) -> [(decision: CullDecision, record: PhotoRecord)] {
        var seen = Set<String>()
        var rejects: [(decision: CullDecision, record: PhotoRecord)] = []
        for d in plan.decisions where d.verdict == .reject {
            guard let r = plan.records[d.photoID], seen.insert(d.photoID).inserted else { continue }
            rejects.append((d, r))
        }
        return rejects
    }

    private static func journalRunStart(_ plan: CullPlan, on copies: [URL]) throws {
        for copy in copies {
            do {
                try CullJournal.append(.run(runID: plan.runID, date: Date(), model: plan.settings.model, settings: plan.settings),
                                       runID: plan.runID, in: copy)
            } catch { throw CullError.journalWriteFailed(error.localizedDescription) }
        }
    }

    /// Best effort: a missing `finished` line only makes the run read as unfinished.
    private static func journalRunFinished(_ plan: CullPlan, on copies: [URL], status: String,
                                           movedOnCopy: [Int], crossOnCopy: [Int]) {
        for (ci, copy) in copies.enumerated() {
            let summary = CullRunSummary(runID: plan.runID, date: Date(), model: plan.settings.model,
                                         photos: plan.records.count, rejected: movedOnCopy[ci],
                                         groupsDone: plan.groupsDone, groupsTotal: plan.groupsTotal,
                                         spentUSD: plan.spentUSD, undone: false,
                                         status: status, skippedCrossVolume: crossOnCopy[ci], note: plan.note)
            try? CullJournal.append(.finished(runID: plan.runID, summary: summary), runID: plan.runID, in: copy)
        }
    }

    /// True when a member is still the file that was analysed: same size, plus the same mtime on the
    /// primary, or (on a mirror) no hash disagreement with the primary.
    private static func memberUnchanged(
        _ rel: String,
        _ info: Info,
        record: PhotoRecord,
        isPrimary: Bool,
        primaryURL: URL,
        copy: URL,
        hashLookup: (URL) -> String?
    ) -> Bool {
        guard let stamp = record.stamps[rel], info.size == stamp.size else { return false }
        if isPrimary { return abs(info.mtime - stamp.mtime.timeIntervalSince1970) < mtimeTolerance }
        if let primaryHash = hashLookup(primaryURL.appendingPathComponent(rel)),
           let mirrorHash = hashLookup(copy.appendingPathComponent(rel)), primaryHash != mirrorHash { return false }
        return true
    }

    /// Seconds; absorbs float rounding of the stored timestamp.
    private static let mtimeTolerance = 0.001

    /// How many suffixes (`IMG 2`, `IMG 3`, ...) to try before giving up on a free name.
    private static let maxSuffixAttempts = 1000

    /// Moves every member of one photo into `_Rejects` using a shared suffix. Skips (with everything
    /// put back) when any member fails a check. Throws when journaling fails or a rollback can't
    /// put every file back (those members keep their journaled intent for undo to recover).
    private static func movePair(
        members: [String],
        copyFD: Int32,
        startN: Int,
        runID: UUID,
        decision: CullDecision,
        io: CullIO,
        check: (String, Info) -> Bool,
        journal: (CullJournalEvent) throws -> Void
    ) throws -> PairOutcome {
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        let photoFD = openat(copyFD, "Photo", dirFlags)
        guard photoFD >= 0 else { return .skipped }
        fds.append(photoFD)

        var srcs: [Planned] = []
        for rel in members {
            guard let parts = safeParts(rel, allowRejects: false),
                  let dir = openDir(photoFD, parts[1..<(parts.count - 1)], create: false) else { return .skipped }
            fds.append(dir)
            guard let info = statAt(dir, parts[parts.count - 1]), isRegular(info), check(rel, info) else { return .skipped }
            srcs.append(Planned(rel: rel, srcDir: dir, srcName: parts[parts.count - 1], info: info))
        }

        var n = max(startN, 1)
        attempts: while n < startN + maxSuffixAttempts {
            var items = srcs
            for i in items.indices {
                let dstRel = suffixed(rejectsDestination(for: items[i].rel), n: n)
                let dparts = dstRel.split(separator: "/").map(String.init)
                guard let dd = openDir(photoFD, dparts[1..<(dparts.count - 1)], create: true) else { return .skipped }
                fds.append(dd)
                items[i].to = dstRel
                items[i].dstDir = dd
                items[i].dstName = dparts[dparts.count - 1]
                if statAt(dd, items[i].dstName) != nil { n += 1; continue attempts }
                guard let a = io.deviceID(items[i].srcDir), let b = io.deviceID(dd), a == b else { return .crossVolume }
            }

            // Write-ahead: one fsynced intent per member before any rename.
            do {
                for it in items {
                    try journal(.intent(runID: runID, from: it.rel, to: it.to, photoID: decision.photoID, size: it.info.size))
                }
            } catch {
                cancelIntents(items, runID, journal)
                throw CullError.journalWriteFailed(error.localizedDescription)
            }

            var done: [Planned] = []
            var result = RenameResult.success
            for it in items {
                result = renameExclusive(io, it.srcDir, it.srcName, it.dstDir, it.dstName)
                if result != .success { break }
                done.append(it)
                guard let after = statAt(it.dstDir, it.dstName), after.ino == it.info.ino, after.dev == it.info.dev,
                      after.size == it.info.size, statAt(it.srcDir, it.srcName) == nil else {
                    result = .failed
                    break
                }
            }
            if result != .success {
                try unwind(items: items, moved: done, runID: runID, io: io, journal: journal, journalError: nil)
                if result == .exists { n += 1; continue attempts }
                return .skipped
            }

            do {
                try journal(.movedPair(runID: runID, members: items.map { CullMovedMember(from: $0.rel, to: $0.to) },
                                       reason: decision.reason, criterion: decision.criterion,
                                       keeper: decision.keeperID, photoID: decision.photoID))
            } catch {
                try unwind(items: items, moved: items, runID: runID, io: io, journal: journal, journalError: error)
            }
            return .moved(n: n)
        }
        return .skipped
    }

    /// Best effort: marks never-completed intents as restored so they can't be mistaken later.
    private static func cancelIntents(_ items: [Planned], _ runID: UUID, _ journal: (CullJournalEvent) throws -> Void) {
        for it in items {
            try? journal(.restored(runID: runID, from: it.rel, to: it.rel))
        }
    }

    /// Puts moved members back, newest first. A member that can't be moved back keeps its intent
    /// and makes this throw `rollbackFailed`; otherwise throws journalWriteFailed if given a cause.
    private static func unwind(
        items: [Planned],
        moved: [Planned],
        runID: UUID,
        io: CullIO,
        journal: (CullJournalEvent) throws -> Void,
        journalError: Error?
    ) throws {
        var stuck: [String] = []
        for it in moved.reversed() {
            if renameExclusive(io, it.dstDir, it.dstName, it.srcDir, it.srcName) != .success { stuck.append(it.rel) }
        }
        cancelIntents(items.filter { !stuck.contains($0.rel) }, runID, journal)
        if !stuck.isEmpty { throw CullError.rollbackFailed(stuck.joined(separator: ", ")) }
        if let journalError { throw CullError.journalWriteFailed(journalError.localizedDescription) }
    }
}
