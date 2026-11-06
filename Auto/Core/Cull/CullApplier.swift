import Foundation

/// Low-level hooks, injectable so tests can force ENOTSUP, cross-volume and mid-pair failures.
nonisolated struct CullIO: Sendable {
    /// `renameatx_np(RENAME_EXCL)`: returns 0, or -1 with errno set.
    var renameExclusive: @Sendable (_ srcDir: Int32, _ srcName: String, _ dstDir: Int32, _ dstName: String) -> Int32
    /// Volume of an open directory.
    var deviceID: @Sendable (_ dirFD: Int32) -> dev_t?

    static let live = CullIO(
        renameExclusive: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
        deviceID: { fd in
            var st = stat()
            return fstat(fd, &st) == 0 ? st.st_dev : nil
        })
}

/// Moves rejected photos into `_Rejects` folders. Renames only (never copies or deletes), never
/// overwrites, and never touches a card. Every pair is journaled write-ahead (`intent` per member,
/// fsynced, before any rename) and committed with one atomic `movedPair` line once verified.
///
/// All paths are walked with `openat(O_DIRECTORY | O_NOFOLLOW)` from the copy's `Photo` folder and
/// renamed with `renameatx_np(RENAME_EXCL)` on those directory fds, so a symlink swapped in after
/// checking can't redirect a move.
nonisolated enum CullApplier {
    /// `Photo/<cam>/<sub…>/X` → `Photo/<cam>/_Rejects/<sub…>/X`; `Photo/X` → `Photo/_Rejects/X`.
    static func rejectsDestination(for relPath: String) -> String {
        var parts = relPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] == "Photo" else { return relPath }
        parts.insert("_Rejects", at: parts.count == 2 ? 1 : 2)
        return parts.joined(separator: "/")
    }

    private struct Info {
        let dev: dev_t
        let ino: ino_t
        let size: Int64
        let mtime: Double
        let mode: mode_t
    }

    private static func statAt(_ dir: Int32, _ name: String) -> Info? {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let t = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return Info(dev: st.st_dev, ino: st.st_ino, size: Int64(st.st_size), mtime: t, mode: st.st_mode)
    }

    private static func isRegular(_ i: Info) -> Bool { (i.mode & S_IFMT) == S_IFREG }

    private static let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW

    /// Walks `parts` from `parent` through real directories only. With `create`, missing folders
    /// are made with mkdirat (EEXIST just re-opens). Returns an owned fd, or nil on any symlink,
    /// non-directory or error.
    private static func openDir(_ parent: Int32, _ parts: ArraySlice<String>, create: Bool) -> Int32? {
        var cur = dup(parent)
        guard cur >= 0 else { return nil }
        for p in parts {
            var next = openat(cur, p, dirFlags)
            if next < 0, create, errno == ENOENT {
                if mkdirat(cur, p, 0o755) != 0, errno != EEXIST { close(cur); return nil }
                next = openat(cur, p, dirFlags)
            }
            close(cur)
            guard next >= 0 else { return nil }
            cur = next
        }
        return cur
    }

    /// Components of a shoot-relative path under `Photo/`, or nil if any is unsafe.
    private static func safeParts(_ rel: String, allowRejects: Bool) -> [String]? {
        guard !rel.hasPrefix("/") else { return nil }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "Photo" else { return nil }
        for p in parts {
            if p.isEmpty || p == "." || p == ".." || p.hasPrefix(".") { return nil }
            if p == "_Rejects", !allowRejects { return nil }
        }
        return parts
    }

    private static func openCopy(_ copy: URL) -> Int32? {
        let fd = open(copy.path, O_RDONLY | O_DIRECTORY)
        return fd >= 0 ? fd : nil
    }

    private enum RenameResult { case success, exists, failed }

    /// Exclusive rename on dir fds. A volume without RENAME_EXCL (ENOTSUP) fails the move: a
    /// plain `renameat` could replace a file created in the check-to-rename window, and Auto
    /// never overwrites (same policy as CopyEngine).
    private static func renameExclusive(_ io: CullIO, _ sd: Int32, _ sn: String, _ dd: Int32, _ dn: String) -> RenameResult {
        if io.renameExclusive(sd, sn, dd, dn) == 0 { return .success }
        switch errno {
        case EEXIST:
            return .exists
        default:
            return .failed
        }
    }

    /// `IMG_1.CR3` with n=2 → `IMG_1 2.CR3`; n=1 is the name unchanged (same style as CopyEngine.uniqueURL).
    private static func suffixed(_ rel: String, n: Int) -> String {
        guard n > 1 else { return rel }
        let url = URL(fileURLWithPath: rel)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = (rel as NSString).deletingLastPathComponent
        let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        return dir.isEmpty ? name : dir + "/" + name
    }

    private static func checkCopies(_ copies: [URL], cardVolumes: [URL]) throws -> [URL] {
        var online: [URL] = []
        for copy in copies {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: copy.path, isDirectory: &isDir), isDir.boolValue {
                online.append(copy)
            }
        }
        guard !online.isEmpty else { throw CullError.noCopiesOnline }
        for copy in online {
            do { try ShootPlanner.checkDestination(copy, root: copy, cardVolumes: cardVolumes) }
            catch ShootPlanner.PathError.onCard { throw CullError.onCard }
            catch { throw CullError.outsideShoot(copy.path) }
        }
        return online
    }

    // MARK: - Apply

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
        var seen = Set<String>()
        var rejects: [(decision: CullDecision, record: PhotoRecord)] = []
        for d in plan.decisions where d.verdict == .reject {
            guard let r = plan.records[d.photoID], seen.insert(d.photoID).inserted else { continue }
            rejects.append((d, r))
        }

        var online = try checkCopies(copies, cardVolumes: cardVolumes)
        guard let catalog = plan.catalogCopy?.standardizedFileURL.path,
              let pi = online.firstIndex(where: { $0.standardizedFileURL.path == catalog }) else {
            throw CullError.shootOffline
        }
        online.insert(online.remove(at: pi), at: 0)   // primary first
        guard !rejects.isEmpty else { return 0 }

        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        for copy in online {
            guard let fd = openCopy(copy) else { throw CullError.noCopiesOnline }
            fds.append(fd)
        }

        for copy in online {
            do {
                try CullJournal.append(.run(runID: plan.runID, date: Date(), model: plan.settings.model, settings: plan.settings),
                                       runID: plan.runID, in: copy)
            } catch { throw CullError.journalWriteFailed(error.localizedDescription) }
        }

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
                    guard let stamp = record.stamps[rel], info.size == stamp.size else { return false }
                    if primary { return abs(info.mtime - stamp.mtime.timeIntervalSince1970) < 0.001 }
                    if let a = hashLookup(primaryURL.appendingPathComponent(rel)),
                       let b = hashLookup(copy.appendingPathComponent(rel)), a != b { return false }
                    return true
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

        let status = failure != nil ? "failed" : (cancelled ? "cancelled" : "completed")
        for (ci, copy) in online.enumerated() {
            let summary = CullRunSummary(runID: plan.runID, date: Date(), model: plan.settings.model,
                                         photos: plan.records.count, rejected: movedOnCopy[ci],
                                         groupsDone: 0, groupsTotal: 0, spentUSD: 0, undone: false,
                                         status: status, skippedCrossVolume: crossOnCopy[ci])
            try? CullJournal.append(.finished(runID: plan.runID, summary: summary), runID: plan.runID, in: copy)
        }
        if let failure { throw failure }
        if cancelled { throw CancellationError() }
        return movedOnCopy[0]
    }

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
        attempts: while n < startN + 1000 {
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

    // MARK: - Undo

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

        let target: CullRunSummary
        if let runID {
            guard let s = online.compactMap({ c in perCopy[c]?.first { $0.runID == runID && !$0.undone } }).first else {
                throw CullError.nothingToUndo
            }
            target = s
        } else {
            let all = online.flatMap { (perCopy[$0] ?? []).filter { !$0.undone } }
            guard let s = all.max(by: { $0.date < $1.date }) else { throw CullError.nothingToUndo }
            target = s
        }

        var work: [(copy: URL, entries: [CullJournal.MoveEntry])] = []
        for c in online where perCopy[c]?.contains(where: { $0.runID == target.runID && !$0.undone }) == true {
            work.append((c, Array(try CullJournal.moveEntries(runID: target.runID, in: c).reversed())))
        }
        let total = work.reduce(0) { $0 + $1.entries.count }
        var done = 0
        onProgress(0, total)

        for (copy, entries) in work {
            guard let copyFD = openCopy(copy) else { continue }
            defer { close(copyFD) }
            let photoFD = openat(copyFD, "Photo", dirFlags)
            defer { if photoFD >= 0 { close(photoFD) } }
            let journal: (CullJournalEvent) throws -> Void = {
                do { try CullJournal.append($0, runID: target.runID, in: copy) }
                catch { throw CullError.journalWriteFailed(error.localizedDescription) }
            }
            var restoredTo: [String] = []
            for e in entries {
                if photoFD >= 0 {
                    if let r = try restore(e, photoFD: photoFD, runID: target.runID, io: io, journal: journal) { restoredTo.append(r) }
                } else {
                    try journal(.restoreSkipped(runID: target.runID, path: e.to, why: "Photo folder missing"))
                }
                done += 1
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

    /// Returns the shoot-relative path the file was restored to, or nil if nothing was moved.
    private static func restore(
        _ e: CullJournal.MoveEntry,
        photoFD: Int32,
        runID: UUID,
        io: CullIO,
        journal: (CullJournalEvent) throws -> Void
    ) throws -> String? {
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
        defer { if toDir >= 0 { close(toDir) } }

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
        defer { close(fromDir) }
        if let a = io.deviceID(toDir), let b = io.deviceID(fromDir), a != b {
            try journal(.restoreSkipped(runID: runID, path: e.to, why: "different volume"))
            return nil
        }

        var n = 1
        while n < 1000 {
            let rel = suffixed(e.from, n: n)
            let name = rel.split(separator: "/").last.map(String.init) ?? fromName
            switch renameExclusive(io, toDir, toName, fromDir, name) {
            case .success:
                try journal(.restored(runID: runID, from: e.from, to: rel))
                return rel
            case .exists:
                n += 1
            case .failed:
                try journal(.restoreSkipped(runID: runID, path: e.to, why: "rename failed"))
                return nil
            }
        }
        try journal(.restoreSkipped(runID: runID, path: e.to, why: "no free name"))
        return nil
    }

    /// Removes now-empty folders from the file's `_Rejects` location up through `_Rejects` itself.
    private static func pruneRejects(copy: URL, rel: String) {
        guard let parts = safeParts(rel, allowRejects: true), let idx = parts.firstIndex(of: "_Rejects") else { return }
        var dirParts = Array(parts.dropLast())
        while dirParts.count > idx {
            let path = dirParts.reduce(copy) { $0.appendingPathComponent($1, isDirectory: true) }.path
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, rmdir(path) == 0 else { return }
            dirParts.removeLast()
        }
    }
}
