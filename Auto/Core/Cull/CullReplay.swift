import Foundation

nonisolated struct CullReplayResult: Equatable, Sendable {
    /// Photo pairs moved on the target.
    var moved = 0
    /// Files restored on the target because the source run was undone.
    var restored = 0
    /// Shoot-relative `from` paths of pairs that couldn't be replayed.
    var skipped: [String] = []
    var runsReplayed = 0
}

/// Replays cull runs journaled on one copy (`source`) onto a copy that missed them (`target`), so
/// mirrors stay in step. Only renames inside the target; never overwrites, never touches cards,
/// and moves nothing a second time (files already at their destination are left alone).
nonisolated enum CullReplay {
    private struct Member {
        let from: String
        let to: String
        let size: Int64
        var srcDir: Int32 = -1
        var srcName = ""
        var dstDir: Int32 = -1
        var dstName = ""
    }

    private struct SourcePair {
        let members: [CullMovedMember]
        let reason: String
        let criterion: String?
        let keeper: String?
        let photoID: String
    }

    private struct SourceRun {
        var run: CullJournalEvent?
        var pairs: [SourcePair] = []
        var restoredFroms = Set<String>()
        var finished: CullRunSummary?
        var undone: Date?
    }

    static func replay(from source: URL, to target: URL, cardVolumes: [URL], io: CullIO = .live) throws -> CullReplayResult {
        guard source.standardizedFileURL.path != target.standardizedFileURL.path else { return CullReplayResult() }
        let online = try CullApplier.checkCopies([target], cardVolumes: cardVolumes)
        guard let target = online.first else { throw CullError.noCopiesOnline }

        var order: [UUID] = []
        var runs: [UUID: SourceRun] = [:]
        func touch(_ id: UUID) { if runs[id] == nil { runs[id] = SourceRun(); order.append(id) } }
        for e in try CullJournal.events(in: source) {
            switch e {
            case .run(let id, _, _, _):
                touch(id); runs[id]?.run = e
            case .moved(let id, let from, let to, let reason, let criterion, let keeper, let photoID):
                touch(id)
                runs[id]?.pairs.append(SourcePair(members: [CullMovedMember(from: from, to: to)], reason: reason,
                                                  criterion: criterion, keeper: keeper, photoID: photoID))
            case .movedPair(let id, let members, let reason, let criterion, let keeper, let photoID):
                touch(id)
                runs[id]?.pairs.append(SourcePair(members: members, reason: reason, criterion: criterion,
                                                  keeper: keeper, photoID: photoID))
            case .intent(let id, _, _, _, _):
                touch(id)   // not completed on the source: nothing to replay
            case .restored(let id, let from, _):
                touch(id); runs[id]?.restoredFroms.insert(from)
            case .restoreSkipped(let id, _, _):
                touch(id)
            case .finished(let id, let summary):
                touch(id); runs[id]?.finished = summary
            case .undone(let id, let date):
                touch(id); runs[id]?.undone = date
            }
        }

        var targetState: [UUID: (run: Bool, finished: Bool, undone: Bool)] = [:]
        for e in try CullJournal.events(in: target) {
            switch e {
            case .run(let id, _, _, _): targetState[id, default: (false, false, false)].run = true
            case .finished(let id, _): targetState[id, default: (false, false, false)].finished = true
            case .undone(let id, _): targetState[id, default: (false, false, false)].undone = true
            default: break
            }
        }

        var result = CullReplayResult()
        for id in order {
            guard let sr = runs[id] else { continue }
            let t = targetState[id] ?? (false, false, false)
            let needed = !t.run || (sr.finished != nil && !t.finished) || (sr.undone != nil && !t.undone)
            guard needed, !t.undone else { continue }
            result.runsReplayed += 1
            try replayRun(id, sr, source: source, targetHasRun: t.run, targetFinished: t.finished, target: target, io: io, result: &result)
        }
        return result
    }

    private static func append(_ e: CullJournalEvent, _ id: UUID, _ target: URL) throws {
        do { try CullJournal.append(e, runID: id, in: target) }
        catch { throw CullError.journalWriteFailed(error.localizedDescription) }
    }

    private static func skippedCount(_ id: UUID, _ target: URL) throws -> Int {
        try CullJournal.events(in: target).filter {
            if case .restoreSkipped(let r, _, _) = $0 { return r == id } else { return false }
        }.count
    }

    private static func replayRun(_ id: UUID, _ sr: SourceRun, source: URL, targetHasRun: Bool, targetFinished: Bool,
                                  target: URL, io: CullIO, result: inout CullReplayResult) throws {
        if !targetHasRun, let run = sr.run { try append(run, id, target) }

        if let undoneDate = sr.undone {
            // The source ended up restored: put the target back too (nothing to do if it never applied).
            let entries = try CullJournal.moveEntries(runID: id, in: target)
            if entries.isEmpty {
                try append(.undone(runID: id, date: undoneDate), id, target)
            } else {
                let before = try skippedCount(id, target)
                try CullApplier.undo(runID: id, copies: [target], cardVolumes: [], io: io, onProgress: { _, _ in })
                let after = try skippedCount(id, target)
                result.restored += max(0, entries.count - (after - before))
            }
        } else {
            guard let fd = CullApplier.openCopy(target) else { throw CullError.noCopiesOnline }
            defer { close(fd) }
            for pair in sr.pairs where !pair.members.allSatisfy({ sr.restoredFroms.contains($0.from) }) {
                if try replayPair(pair, id: id, source: source, copyFD: fd, target: target, io: io) {
                    result.moved += 1
                } else if !pair.members.allSatisfy({ isDone($0, copyFD: fd) }) {
                    result.skipped.append(contentsOf: pair.members.map(\.from))
                }
            }
        }

        if !targetFinished, let summary = sr.finished { try append(.finished(runID: id, summary: summary), id, target) }
    }

    /// True when the file already sits at its destination.
    private static func isDone(_ m: CullMovedMember, copyFD: Int32) -> Bool {
        guard let parts = CullApplier.safeParts(m.to, allowRejects: true) else { return false }
        let photo = openat(copyFD, "Photo", CullApplier.dirFlags)
        guard photo >= 0 else { return false }
        defer { close(photo) }
        guard let dir = CullApplier.openDir(photo, parts[1..<(parts.count - 1)], create: false) else { return false }
        defer { close(dir) }
        return CullApplier.statAt(dir, parts[parts.count - 1]) != nil
    }

    /// Moves one pair on the target, all-or-nothing. Returns false when it was left alone (and logs why).
    private static func replayPair(_ pair: SourcePair, id: UUID, source: URL, copyFD: Int32, target: URL, io: CullIO) throws -> Bool {
        let journal: (CullJournalEvent) throws -> Void = { try append($0, id, target) }
        func skip(_ path: String, _ why: String) throws -> Bool {
            try journal(.restoreSkipped(runID: id, path: path, why: why))
            return false
        }
        if pair.members.allSatisfy({ isDone($0, copyFD: copyFD) }) { return false }
        if pair.members.contains(where: { isDone($0, copyFD: copyFD) }) {
            return try skip(pair.members[0].from, "partly moved already")
        }

        let photoFD = openat(copyFD, "Photo", CullApplier.dirFlags)
        guard photoFD >= 0 else { return try skip(pair.members[0].from, "Photo folder missing") }
        var fds = [photoFD]
        defer { fds.forEach { close($0) } }

        var items: [Member] = []
        for m in pair.members {
            guard let from = CullApplier.safeParts(m.from, allowRejects: false),
                  let to = CullApplier.safeParts(m.to, allowRejects: true), to.contains("_Rejects") else {
                return try skip(m.from, "unsafe path")
            }
            // Size at move time: the source file's current size at `to`.
            var st = stat()
            let srcPath = source.appendingPathComponent(m.to).path
            guard lstat(srcPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return try skip(m.from, "source file missing") }
            guard let sd = CullApplier.openDir(photoFD, from[1..<(from.count - 1)], create: false) else { return try skip(m.from, "missing") }
            fds.append(sd)
            guard let info = CullApplier.statAt(sd, from[from.count - 1]), CullApplier.isRegular(info) else {
                return try skip(m.from, "missing")
            }
            guard info.size == Int64(st.st_size) else { return try skip(m.from, "size mismatch") }
            if let dd = CullApplier.openDir(photoFD, to[1..<(to.count - 1)], create: false) {
                defer { close(dd) }
                if CullApplier.statAt(dd, to[to.count - 1]) != nil { return try skip(m.from, "destination exists") }
            }
            items.append(Member(from: m.from, to: m.to, size: info.size, srcDir: sd, srcName: from[from.count - 1],
                                dstName: to[to.count - 1]))
        }

        // Checks passed: only now create the destination folders.
        for i in items.indices {
            let to = CullApplier.safeParts(items[i].to, allowRejects: true)!
            guard let dd = CullApplier.openDir(photoFD, to[1..<(to.count - 1)], create: true) else {
                items.forEach { CullApplier.pruneRejects(copy: target, rel: $0.to) }
                return try skip(items[i].from, "unsafe folder")
            }
            fds.append(dd)
            items[i].dstDir = dd
            guard let a = io.deviceID(items[i].srcDir), let b = io.deviceID(dd), a == b else {
                items.forEach { CullApplier.pruneRejects(copy: target, rel: $0.to) }
                return try skip(items[i].from, "different volume")
            }
        }

        do {
            for it in items { try journal(.intent(runID: id, from: it.from, to: it.to, photoID: pair.photoID, size: it.size)) }
        } catch {
            for it in items { try? journal(.restored(runID: id, from: it.from, to: it.from)) }
            throw error
        }

        var done: [Member] = []
        var failed = false
        for it in items {
            if CullApplier.renameExclusive(io, it.srcDir, it.srcName, it.dstDir, it.dstName) != .success { failed = true; break }
            done.append(it)
        }
        if failed {
            var stuck: [String] = []
            for it in done.reversed() where CullApplier.renameExclusive(io, it.dstDir, it.dstName, it.srcDir, it.srcName) != .success {
                stuck.append(it.from)
            }
            for it in items where !stuck.contains(it.from) { try? journal(.restored(runID: id, from: it.from, to: it.from)) }
            if !stuck.isEmpty { throw CullError.rollbackFailed(stuck.joined(separator: ", ")) }
            return try skip(pair.members[0].from, "rename failed")
        }

        do {
            try journal(.movedPair(runID: id, members: pair.members, reason: pair.reason, criterion: pair.criterion,
                                   keeper: pair.keeper, photoID: pair.photoID))
        } catch {
            for it in done.reversed() { _ = CullApplier.renameExclusive(io, it.dstDir, it.dstName, it.srcDir, it.srcName) }
            for it in items { try? journal(.restored(runID: id, from: it.from, to: it.from)) }
            throw error
        }
        return true
    }
}
