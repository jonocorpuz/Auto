import Foundation

// MARK: - Undo

nonisolated extension CullApplier {
    /// Restores a run's moves (newest first) on every online copy. `runID == nil` picks the latest
    /// run that isn't undone. Runs to completion regardless of task cancellation.
    @discardableResult
    static func undo(
        runID: UUID?,
        copies: [URL],
        cardVolumes: [URL],
        io: CullIO = .live,
        onProgress: @Sendable (Int, Int) -> Void
    ) throws -> CullRunSummary {
        let online = try checkCopies(copies, cardVolumes: cardVolumes)
        var perCopy: [URL: [CullRunSummary]] = [:]
        for c in online { perCopy[c] = try CullJournal.runs(in: c) }

        let target = try runToUndo(runID, online: online, runsPerCopy: perCopy)

        var work: [(copy: URL, entries: [CullJournal.MoveEntry])] = []
        for c in online where perCopy[c]?.contains(where: { $0.runID == target.runID && !$0.undone }) == true {
            work.append((c, Array(try CullJournal.moveEntries(runID: target.runID, in: c).reversed())))
        }
        let total = work.reduce(0) { $0 + $1.entries.count }
        var done = 0
        onProgress(0, total)

        var sharedN: [String: Int] = [:]
        for (copy, entries) in work {
            guard let copyFD = openCopy(copy) else { continue }
            defer { close(copyFD) }
            let photoFD = openat(copyFD, "Photo", dirFlags)
            defer { if photoFD >= 0 { close(photoFD) } }
            let journal: (CullJournalEvent) throws -> Void = {
                do { try CullJournal.append($0, runID: target.runID, in: copy) }
                catch { throw CullError.journalWriteFailed(error.localizedDescription) }
            }
            // Entries of one photo are restored together (newest group first), under one shared suffix.
            for group in groupedByPhoto(entries) {
                if photoFD >= 0 {
                    let key = group[0].photoID
                    let start = key.flatMap { sharedN[$0] } ?? 1
                    let n = try restoreGroup(group, startN: start, photoFD: photoFD, runID: target.runID, io: io, journal: journal)
                    if let key, let n { sharedN[key] = n }
                } else {
                    for e in group { try journal(.restoreSkipped(runID: target.runID, path: e.to, why: "Photo folder missing")) }
                }
                done += group.count
                onProgress(done, total)
            }
            // rmdir only removes empty folders; stop at the first one that isn't.
            for e in entries { pruneRejects(copy: copy, rel: e.to) }
            try journal(.undone(runID: target.runID, date: Date()))
        }
        var result = target
        result.undone = true
        return result
    }

    /// The run named by `runID`, or the newest run not yet undone on any online copy.
    private static func runToUndo(_ runID: UUID?, online: [URL],
                                  runsPerCopy: [URL: [CullRunSummary]]) throws -> CullRunSummary {
        if let runID {
            let matches = online.compactMap { c in runsPerCopy[c]?.first { $0.runID == runID && !$0.undone } }
            guard let match = matches.first else { throw CullError.nothingToUndo }
            return match
        }
        let notUndone = online.flatMap { (runsPerCopy[$0] ?? []).filter { !$0.undone } }
        guard let newest = notUndone.max(by: { $0.date < $1.date }) else { throw CullError.nothingToUndo }
        return newest
    }

    /// Groups entries by photo, keeping first-seen order. Entries without a photo ID stand alone.
    private static func groupedByPhoto(_ entries: [CullJournal.MoveEntry]) -> [[CullJournal.MoveEntry]] {
        var groups: [[CullJournal.MoveEntry]] = []
        var groupIndex: [String: Int] = [:]
        for e in entries {
            if let pid = e.photoID, let gi = groupIndex[pid] {
                groups[gi].append(e)
            } else {
                if let pid = e.photoID { groupIndex[pid] = groups.count }
                groups.append([e])
            }
        }
        return groups
    }

    private struct Prepared {
        let entry: CullJournal.MoveEntry
        let toDir: Int32
        let toName: String
        let fromDir: Int32
        let fromName: String
    }

    /// Restores every member of one photo under the smallest suffix n free for all of them (starting
    /// at `startN`). Returns the n used, or nil if nothing was restored. Members that fail a check are
    /// journaled as skipped and left out; a rename that fails rolls the whole group back.
    private static func restoreGroup(
        _ group: [CullJournal.MoveEntry],
        startN: Int,
        photoFD: Int32,
        runID: UUID,
        io: CullIO,
        journal: (CullJournalEvent) throws -> Void
    ) throws -> Int? {
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        var items: [Prepared] = []
        for e in group {
            if let p = try prepareRestore(e, photoFD: photoFD, runID: runID, io: io, journal: journal) {
                fds += [p.toDir, p.fromDir]
                items.append(p)
            }
        }
        guard !items.isEmpty else { return nil }

        var n = max(startN, 1)
        attempts: while n < max(startN, 1) + maxRestoreSuffixAttempts {
            var done: [(Prepared, String)] = []
            for it in items {
                let rel = suffixed(it.entry.from, n: n)
                let name = rel.split(separator: "/").last.map(String.init) ?? it.fromName
                let r = renameExclusive(io, it.toDir, it.toName, it.fromDir, name)
                if r == .success { done.append((it, name)); continue }
                var stuck: [String] = []
                for (d, dn) in done.reversed() where renameExclusive(io, d.fromDir, dn, d.toDir, d.toName) != .success {
                    stuck.append(d.entry.to)
                }
                if !stuck.isEmpty { throw CullError.rollbackFailed(stuck.joined(separator: ", ")) }
                if r == .exists { n += 1; continue attempts }
                for i in items { try journal(.restoreSkipped(runID: runID, path: i.entry.to, why: "rename failed")) }
                return nil
            }
            for (it, _) in done {
                try journal(.restored(runID: runID, from: it.entry.from, to: suffixed(it.entry.from, n: n)))
            }
            return n
        }
        for i in items { try journal(.restoreSkipped(runID: runID, path: i.entry.to, why: "no free name")) }
        return nil
    }

    private static let maxRestoreSuffixAttempts = 1000

    /// Checks one member and opens its folders (caller closes them). Nil means it was handled
    /// (journaled as skipped or as never moved) and there is nothing to rename.
    private static func prepareRestore(
        _ e: CullJournal.MoveEntry,
        photoFD: Int32,
        runID: UUID,
        io: CullIO,
        journal: (CullJournalEvent) throws -> Void
    ) throws -> Prepared? {
        guard let fromParts = safeParts(e.from, allowRejects: false),
              let toParts = safeParts(e.to, allowRejects: true), toParts.contains("_Rejects") else {
            try journal(.restoreSkipped(runID: runID, path: e.to, why: "unsafe path"))
            return nil
        }
        let fromName = fromParts[fromParts.count - 1], toName = toParts[toParts.count - 1]

        var toDir: Int32 = -1
        var toInfo: Info?
        if let d = openDir(photoFD, toParts[1..<(toParts.count - 1)], create: false) {
            toDir = d
            toInfo = statAt(d, toName)
        }
        var handedOver = false
        defer { if toDir >= 0, !handedOver { close(toDir) } }

        guard let info = toInfo, isRegular(info) else {
            if e.intentOnly, let fd = openDir(photoFD, fromParts[1..<(fromParts.count - 1)], create: false) {
                defer { close(fd) }
                if statAt(fd, fromName) != nil {
                    // Never moved: just clear the intent.
                    try journal(.restored(runID: runID, from: e.from, to: e.from))
                    return nil
                }
            }
            try journal(.restoreSkipped(runID: runID, path: e.to, why: "missing"))
            return nil
        }
        if e.intentOnly, let size = e.size, info.size != size {
            try journal(.restoreSkipped(runID: runID, path: e.to, why: "size mismatch"))
            return nil
        }
        guard let fromDir = openDir(photoFD, fromParts[1..<(fromParts.count - 1)], create: true) else {
            try journal(.restoreSkipped(runID: runID, path: e.from, why: "unsafe folder"))
            return nil
        }
        if let a = io.deviceID(toDir), let b = io.deviceID(fromDir), a != b {
            close(fromDir)
            try journal(.restoreSkipped(runID: runID, path: e.to, why: "different volume"))
            return nil
        }
        handedOver = true
        return Prepared(entry: e, toDir: toDir, toName: toName, fromDir: fromDir, fromName: fromName)
    }
}
