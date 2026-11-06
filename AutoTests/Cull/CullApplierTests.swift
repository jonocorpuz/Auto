import Foundation
import Testing
@testable import Auto

@Suite("CullApplier") struct CullApplierTests {
    private let fm = FileManager.default

    private func temp() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("applier-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    private func write(_ copy: URL, _ rel: String, _ text: String) throws -> URL {
        let url = copy.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ copy: URL, _ rel: String) -> String? {
        try? String(contentsOf: copy.appendingPathComponent(rel), encoding: .utf8)
    }

    private func exists(_ copy: URL, _ rel: String) -> Bool {
        (try? fm.attributesOfItem(atPath: copy.appendingPathComponent(rel).path)) != nil
    }

    private func record(_ copy: URL, _ members: [String], camera: String = "CamA") throws -> PhotoRecord {
        var stamps: [String: FileStamp] = [:]
        for m in members {
            let a = try fm.attributesOfItem(atPath: copy.appendingPathComponent(m).path)
            stamps[m] = FileStamp(size: Int64(a[.size] as! UInt64), mtime: a[.modificationDate] as! Date)
        }
        return PhotoRecord(id: members[0], camera: camera, members: members, representative: members[0], stamps: stamps)
    }

    private func plan(_ records: [PhotoRecord], rejecting ids: [String]? = nil, runID: UUID = UUID(), catalog: URL? = nil) -> CullPlan {
        let rejected = ids ?? records.map(\.id)
        let decisions = records.map {
            CullDecision(photoID: $0.id, verdict: rejected.contains($0.id) ? .reject : .keep, reason: "blurry",
                         criterion: "sharpness", keeperID: "keeper", confidence: 0.9, source: .model)
        }
        return CullPlan(runID: runID, settings: CullSettings(), decisions: decisions,
                        records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), catalogCopy: catalog)
    }

    private func apply(_ p: CullPlan, _ copies: [URL], cards: [URL] = []) throws -> Int {
        var p = p
        if p.catalogCopy == nil {
            // Primary = the first copy that exists.
            p.catalogCopy = copies.first { fm.fileExists(atPath: $0.path) }
        }
        return try CullApplier.apply(p, copies: copies, cardVolumes: cards, onMoved: { _, _ in })
    }

    @Test func destinationMapping() {
        #expect(CullApplier.rejectsDestination(for: "Photo/CamA/IMG_1.JPG") == "Photo/CamA/_Rejects/IMG_1.JPG")
        #expect(CullApplier.rejectsDestination(for: "Photo/CamA/day1/IMG_1.JPG") == "Photo/CamA/_Rejects/day1/IMG_1.JPG")
        #expect(CullApplier.rejectsDestination(for: "Photo/IMG_1.JPG") == "Photo/_Rejects/IMG_1.JPG")
    }

    @Test func movesRejectsOnlyAndJournals() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/1.JPG", "one"); try write(copy, "Photo/CamA/2.JPG", "two")
        let r1 = try record(copy, ["Photo/CamA/1.JPG"]), r2 = try record(copy, ["Photo/CamA/2.JPG"])
        let p = plan([r1, r2], rejecting: [r1.id])
        #expect(try apply(p, [copy]) == 1)
        #expect(read(copy, "Photo/CamA/_Rejects/1.JPG") == "one")
        #expect(!exists(copy, "Photo/CamA/1.JPG"))
        #expect(read(copy, "Photo/CamA/2.JPG") == "two")
        let moves = try CullJournal.moves(runID: p.runID, in: copy)
        #expect(moves.count == 1)
        #expect(moves[0].from == "Photo/CamA/1.JPG" && moves[0].to == "Photo/CamA/_Rejects/1.JPG")
        let events = try CullJournal.events(in: copy)
        if case .run = events.first {} else { Issue.record("run not first") }
        if case .finished(_, let s) = events.last { #expect(s.rejected == 1) } else { Issue.record("not finished") }
    }

    @Test func decisionsOutsidePlanRecordsIgnored() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/1.JPG", "one")
        let p = CullPlan(runID: UUID(), settings: CullSettings(),
                         decisions: [CullDecision(photoID: "Photo/CamA/1.JPG", verdict: .reject, reason: "", criterion: nil,
                                                  keeperID: nil, confidence: 1, source: .model)], records: [:])
        #expect(try apply(p, [copy]) == 0)
        #expect(exists(copy, "Photo/CamA/1.JPG"))
    }

    @Test func pairMovesTogether() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/1.JPG", "j"); try write(copy, "Photo/CamA/1.CR3", "r")
        let r = try record(copy, ["Photo/CamA/1.JPG", "Photo/CamA/1.CR3"])
        let p = plan([r])
        #expect(try apply(p, [copy]) == 1)
        #expect(read(copy, "Photo/CamA/_Rejects/1.JPG") == "j")
        #expect(read(copy, "Photo/CamA/_Rejects/1.CR3") == "r")
        #expect(try CullJournal.moves(runID: p.runID, in: copy).count == 2)
    }

    @Test func existingDestinationNeverTouchedAndSuffixShared() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/_Rejects/1.JPG", "old-j")   // only the JPG slot is taken
        try write(copy, "Photo/CamA/1.JPG", "j"); try write(copy, "Photo/CamA/1.CR3", "r")
        let r = try record(copy, ["Photo/CamA/1.JPG", "Photo/CamA/1.CR3"])
        #expect(try apply(plan([r]), [copy]) == 1)
        #expect(read(copy, "Photo/CamA/_Rejects/1.JPG") == "old-j")
        #expect(read(copy, "Photo/CamA/_Rejects/1 2.JPG") == "j")
        #expect(read(copy, "Photo/CamA/_Rejects/1 2.CR3") == "r")
        #expect(!exists(copy, "Photo/CamA/_Rejects/1.CR3"))
    }

    @Test func multipleCopiesShareSuffix() throws {
        let a = try temp(), b = try temp(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        for c in [a, b] { try write(c, "Photo/CamA/1.JPG", "x") }
        try write(a, "Photo/CamA/_Rejects/1.JPG", "old")
        let r = try record(a, ["Photo/CamA/1.JPG"])
        #expect(try apply(plan([r]), [a, b]) == 1)
        #expect(read(a, "Photo/CamA/_Rejects/1 2.JPG") == "x")
        #expect(read(b, "Photo/CamA/_Rejects/1 2.JPG") == "x")
        #expect(!exists(b, "Photo/CamA/1.JPG"))
    }

    @Test func mirrorChecksSizeOnlyAndPrimaryChecksMtime() throws {
        let a = try temp(), b = try temp(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        try write(a, "Photo/CamA/1.JPG", "abc"); try write(b, "Photo/CamA/1.JPG", "abc")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                             ofItemAtPath: b.appendingPathComponent("Photo/CamA/1.JPG").path)
        let r = try record(a, ["Photo/CamA/1.JPG"])
        #expect(try apply(plan([r]), [a, b]) == 1)
        #expect(exists(b, "Photo/CamA/_Rejects/1.JPG"))
    }

    @Test func mirrorSizeMismatchSkipsMirrorOnly() throws {
        let a = try temp(), b = try temp(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        try write(a, "Photo/CamA/1.JPG", "abc"); try write(b, "Photo/CamA/1.JPG", "abcdef")
        let r = try record(a, ["Photo/CamA/1.JPG"])
        #expect(try apply(plan([r]), [a, b]) == 1)
        #expect(exists(a, "Photo/CamA/_Rejects/1.JPG"))
        #expect(read(b, "Photo/CamA/1.JPG") == "abcdef")
    }

    @Test func missingCopySkippedAndAllMissingThrows() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        let gone = fm.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString)")
        try write(a, "Photo/CamA/1.JPG", "x")
        let r = try record(a, ["Photo/CamA/1.JPG"])
        #expect(try apply(plan([r]), [gone, a]) == 1)
        #expect(!exists(gone, ""))
        #expect(throws: CullError.noCopiesOnline) { try apply(plan([r]), [gone]) }
    }

    @Test func staleStampSkipsPair() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/1.JPG", "j"); try write(copy, "Photo/CamA/1.CR3", "r")
        let r = try record(copy, ["Photo/CamA/1.JPG", "Photo/CamA/1.CR3"])
        try write(copy, "Photo/CamA/1.CR3", "changed!")
        #expect(try apply(plan([r]), [copy]) == 0)
        #expect(read(copy, "Photo/CamA/1.JPG") == "j")
        #expect(read(copy, "Photo/CamA/1.CR3") == "changed!")
        #expect(!exists(copy, "Photo/CamA/_Rejects/1.JPG"))
    }

    @Test func mtimeChangeSkipsPairOnPrimary() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        let f = try write(copy, "Photo/CamA/1.JPG", "j")
        let r = try record(copy, ["Photo/CamA/1.JPG"])
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5_000)], ofItemAtPath: f.path)
        #expect(try apply(plan([r]), [copy]) == 0)
        #expect(exists(copy, "Photo/CamA/1.JPG"))
    }

    @Test func refusesRejectsSource() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/_Rejects/1.JPG", "x")
        let r = try record(copy, ["Photo/CamA/_Rejects/1.JPG"])
        #expect(try apply(plan([r]), [copy]) == 0)
        #expect(read(copy, "Photo/CamA/_Rejects/1.JPG") == "x")
        #expect(!exists(copy, "Photo/CamA/_Rejects/_Rejects/1.JPG"))
    }

    @Test func refusesSymlinkSource() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        let outside = try temp(); defer { try? fm.removeItem(at: outside) }
        let target = try write(outside, "real.JPG", "x")
        try fm.createDirectory(at: copy.appendingPathComponent("Photo/CamA"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: copy.appendingPathComponent("Photo/CamA/1.JPG"), withDestinationURL: target)
        let r = PhotoRecord(id: "Photo/CamA/1.JPG", camera: "CamA", members: ["Photo/CamA/1.JPG"],
                            representative: "Photo/CamA/1.JPG",
                            stamps: ["Photo/CamA/1.JPG": FileStamp(size: 1, mtime: Date())])
        #expect(try apply(plan([r]), [copy]) == 0)
        #expect(exists(outside, "real.JPG"))
        #expect((try? fm.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("Photo/CamA/1.JPG").path)) != nil)
    }

    @Test func refusesSymlinkedFolderSource() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        let outside = try temp(); defer { try? fm.removeItem(at: outside) }
        try write(outside, "1.JPG", "x")
        try fm.createDirectory(at: copy.appendingPathComponent("Photo"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: copy.appendingPathComponent("Photo/CamA"), withDestinationURL: outside)
        let stamp = try record(outside, ["1.JPG"]).stamps["1.JPG"]!
        let r = PhotoRecord(id: "Photo/CamA/1.JPG", camera: "CamA", members: ["Photo/CamA/1.JPG"],
                            representative: "Photo/CamA/1.JPG", stamps: ["Photo/CamA/1.JPG": stamp])
        #expect(try apply(plan([r]), [copy]) == 0)
        #expect(read(outside, "1.JPG") == "x")
    }

    @Test func refusesDotDotPath() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        let outside = try temp(); defer { try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: copy.appendingPathComponent("Photo/CamA"), withIntermediateDirectories: true)
        let sibling = outside.lastPathComponent
        let rel = "Photo/CamA/../../../\(sibling)/x.JPG"
        let target = try write(outside, "x.JPG", "x")
        let a = try fm.attributesOfItem(atPath: target.path)
        let r = PhotoRecord(id: rel, camera: "CamA", members: [rel], representative: rel,
                            stamps: [rel: FileStamp(size: 1, mtime: a[.modificationDate] as! Date)])
        #expect(try apply(plan([r]), [copy]) == 0)
        #expect(read(outside, "x.JPG") == "x")
    }

    @Test func refusesCopyOnCard() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/1.JPG", "x")
        let r = try record(copy, ["Photo/CamA/1.JPG"])
        #expect(throws: CullError.onCard) { try apply(plan([r]), [copy], cards: [copy]) }
        #expect(exists(copy, "Photo/CamA/1.JPG"))
        #expect(!exists(copy, ".auto-cull"))
    }

    @Test func movedFileKeepsSameInode() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        let f = try write(copy, "Photo/CamA/1.JPG", "x")
        let before = try fm.attributesOfItem(atPath: f.path)[.systemFileNumber] as! UInt64
        let r = try record(copy, ["Photo/CamA/1.JPG"])
        _ = try apply(plan([r]), [copy])
        let after = try fm.attributesOfItem(atPath: copy.appendingPathComponent("Photo/CamA/_Rejects/1.JPG").path)[.systemFileNumber] as! UInt64
        #expect(before == after)
    }

    @Test func journalPathsAreShootRelative() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/day1/1.JPG", "x")
        let r = try record(copy, ["Photo/CamA/day1/1.JPG"])
        let p = plan([r])
        _ = try apply(p, [copy])
        var sawPair = false
        defer { #expect(sawPair) }
        for e in try CullJournal.events(in: copy) {
            if case .movedPair(_, let members, let reason, let crit, let keeper, let photoID) = e {
                #expect(members.count == 1)
                let from = members[0].from, to = members[0].to
                #expect(from == "Photo/CamA/day1/1.JPG")
                #expect(to == "Photo/CamA/_Rejects/day1/1.JPG")
                #expect(!from.hasPrefix("/") && !to.hasPrefix("/"))
                #expect(reason == "blurry" && crit == "sharpness" && keeper == "keeper" && photoID == r.id)
                sawPair = true
            }
        }
    }

    @Test func cancelBetweenPairsStopsCleanly() async throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        var records: [PhotoRecord] = []
        for i in 1...5 {
            try write(copy, "Photo/CamA/\(i).JPG", "x\(i)")
            records.append(try record(copy, ["Photo/CamA/\(i).JPG"]))
        }
        let p = plan(records, catalog: copy)
        let task = Task.detached { () -> Int in
            try CullApplier.apply(p, copies: [copy], cardVolumes: [], onMoved: { done, _ in
                if done == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; Issue.record("expected CancellationError") }
        catch is CancellationError {}
        #expect(true)
        #expect(exists(copy, "Photo/CamA/_Rejects/2.JPG"))
        #expect(read(copy, "Photo/CamA/3.JPG") == "x3")
        #expect(try CullJournal.moves(runID: p.runID, in: copy).count == 2)
        let events = try CullJournal.events(in: copy)
        if case .finished(_, let s) = events.last { #expect(s.rejected == 2 && s.status == "cancelled") } else { Issue.record("not finished") }
    }
}

nonisolated private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

nonisolated private func realRename(_ a: Int32, _ b: String, _ c: Int32, _ d: String) -> Int32 {
    renameatx_np(a, b, c, d, UInt32(RENAME_EXCL))
}

nonisolated private func pathOf(_ fd: Int32) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    _ = fcntl(fd, F_GETPATH, &buf)
    return String(cString: buf)
}

extension CullApplierTests {
    private func applyIO(_ p: CullPlan, _ copies: [URL], io: CullIO,
                         hash: @escaping @Sendable (URL) -> String? = { _ in nil }) throws -> Int {
        var p = p
        if p.catalogCopy == nil { p.catalogCopy = copies[0] }
        return try CullApplier.apply(p, copies: copies, cardVolumes: [], hashLookup: hash, io: io, onMoved: { _, _ in })
    }

    private func pairFixture() throws -> (URL, PhotoRecord) {
        let copy = try temp()
        try write(copy, "Photo/CamA/1.JPG", "j"); try write(copy, "Photo/CamA/1.CR3", "raw")
        return (copy, try record(copy, ["Photo/CamA/1.JPG", "Photo/CamA/1.CR3"]))
    }

    @Test func memberKRenameFailureRollsBackEarlierMembers() throws {
        let (copy, r) = try pairFixture(); defer { try? fm.removeItem(at: copy) }
        let c = CallCounter()
        let io = CullIO(renameExclusive: { a, b, cc, d in
            if c.next() == 2 { errno = EIO; return -1 }
            return realRename(a, b, cc, d)
        }, deviceID: CullIO.live.deviceID)
        let p = plan([r])
        #expect(try applyIO(p, [copy], io: io) == 0)
        #expect(read(copy, "Photo/CamA/1.JPG") == "j" && read(copy, "Photo/CamA/1.CR3") == "raw")
        #expect(!exists(copy, "Photo/CamA/_Rejects/1.JPG"))
        #expect(try CullJournal.moves(runID: p.runID, in: copy).isEmpty)
    }

    @Test func rollbackFailureStaysJournaledAndThrows() throws {
        let (copy, r) = try pairFixture(); defer { try? fm.removeItem(at: copy) }
        let c = CallCounter()
        let io = CullIO(renameExclusive: { a, b, cc, d in
            if c.next() == 2 {
                // Member 1 fails, and something reoccupies member 0's source before rollback.
                try? Data("squatter".utf8).write(to: copy.appendingPathComponent("Photo/CamA/1.JPG"))
                errno = EIO; return -1
            }
            return realRename(a, b, cc, d)
        }, deviceID: CullIO.live.deviceID)
        let p = plan([r])
        do { _ = try applyIO(p, [copy], io: io); Issue.record("expected rollbackFailed") }
        catch let e as CullError { if case .rollbackFailed = e {} else { Issue.record("wrong error \(e)") } }
        #expect(read(copy, "Photo/CamA/_Rejects/1.JPG") == "j")
        #expect(read(copy, "Photo/CamA/1.JPG") == "squatter")
        let entries = try CullJournal.moveEntries(runID: p.runID, in: copy)
        #expect(entries.contains { $0.from == "Photo/CamA/1.JPG" && $0.intentOnly })
        // Undo recovers the squatted-over file to a unique sibling.
        try CullApplier.undo(runID: p.runID, copies: [copy], cardVolumes: [], onProgress: { _, _ in })
        #expect(read(copy, "Photo/CamA/1.JPG") == "squatter")
        #expect(read(copy, "Photo/CamA/1 2.JPG") == "j")
    }

    @Test func journalAppendFailureMidPairRollsBack() throws {
        let (copy, r) = try pairFixture(); defer { try? fm.removeItem(at: copy) }
        let p = plan([r])
        let journal = { CullJournal.url(runID: p.runID, in: copy).path }
        let c = CallCounter()
        let io = CullIO(renameExclusive: { a, b, cc, d in
            let rc = realRename(a, b, cc, d)
            if c.next() == 2 { chmod(journal(), 0o444) }   // the movedPair append will now fail
            return rc
        }, deviceID: CullIO.live.deviceID)
        do { _ = try applyIO(p, [copy], io: io); Issue.record("expected journalWriteFailed") }
        catch let e as CullError { if case .journalWriteFailed = e {} else { Issue.record("wrong error \(e)") } }
        chmod(journal(), 0o644)
        #expect(read(copy, "Photo/CamA/1.JPG") == "j" && read(copy, "Photo/CamA/1.CR3") == "raw")
        #expect(!exists(copy, "Photo/CamA/_Rejects/1.JPG"))
    }

    @Test func symlinkedRejectsFolderIsRefused() throws {
        let copy = try temp(); defer { try? fm.removeItem(at: copy) }
        let outside = try temp(); defer { try? fm.removeItem(at: outside) }
        try write(copy, "Photo/CamA/1.JPG", "x")
        try fm.createSymbolicLink(at: copy.appendingPathComponent("Photo/CamA/_Rejects"), withDestinationURL: outside)
        let r = try record(copy, ["Photo/CamA/1.JPG"])
        #expect(try apply(plan([r]), [copy]) == 0)
        #expect(read(copy, "Photo/CamA/1.JPG") == "x")
        #expect((try fm.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    @Test func primaryOfflineOrMissingThrowsShootOffline() throws {
        let b = try temp(); defer { try? fm.removeItem(at: b) }
        let gone = fm.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString)")
        try write(b, "Photo/CamA/1.JPG", "x")
        let r = try record(b, ["Photo/CamA/1.JPG"])
        #expect(throws: CullError.shootOffline) {
            try CullApplier.apply(plan([r], catalog: gone), copies: [gone, b], cardVolumes: [], onMoved: { _, _ in })
        }
        #expect(throws: CullError.shootOffline) {
            try CullApplier.apply(plan([r]), copies: [b], cardVolumes: [], onMoved: { _, _ in })
        }
        #expect(read(b, "Photo/CamA/1.JPG") == "x")
    }

    @Test func enotsupRefusesToMoveRatherThanRiskOverwrite() throws {
        let (copy, r) = try pairFixture(); defer { try? fm.removeItem(at: copy) }
        try write(copy, "Photo/CamA/_Rejects/1.CR3", "old")
        let io = CullIO(renameExclusive: { _, _, _, _ in errno = ENOTSUP; return -1 }, deviceID: CullIO.live.deviceID)
        #expect(try applyIO(plan([r]), [copy], io: io) == 0)
        #expect(read(copy, "Photo/CamA/_Rejects/1.CR3") == "old")
        #expect(read(copy, "Photo/CamA/1.JPG") == "j")
        #expect(read(copy, "Photo/CamA/1.CR3") == "raw")
    }

    @Test func crossVolumeIsSkippedAndCounted() throws {
        let (copy, r) = try pairFixture(); defer { try? fm.removeItem(at: copy) }
        let live = CullIO.live
        let io = CullIO(renameExclusive: live.renameExclusive, deviceID: { fd in
            pathOf(fd).contains("_Rejects") ? 12345 : live.deviceID(fd)
        })
        let p = plan([r])
        #expect(try applyIO(p, [copy], io: io) == 0)
        #expect(read(copy, "Photo/CamA/1.JPG") == "j")
        #expect(try CullJournal.moves(runID: p.runID, in: copy).isEmpty)
        if case .finished(_, let s) = try CullJournal.events(in: copy).last {
            #expect(s.skippedCrossVolume == 1 && s.rejected == 0)
        } else { Issue.record("not finished") }
    }

    @Test func mirrorMD5MismatchSkipsMirrorOnly() throws {
        let a = try temp(), b = try temp(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        try write(a, "Photo/CamA/1.JPG", "abc"); try write(b, "Photo/CamA/1.JPG", "abd")
        let r = try record(a, ["Photo/CamA/1.JPG"])
        let aPath = a.path
        let hash: @Sendable (URL) -> String? = { $0.path.hasPrefix(aPath) ? "h1" : "h2" }
        #expect(try applyIO(plan([r]), [a, b], io: .live, hash: hash) == 1)
        #expect(exists(a, "Photo/CamA/_Rejects/1.JPG"))
        #expect(read(b, "Photo/CamA/1.JPG") == "abd")
        // Equal hashes proceed.
        let c = try temp(); defer { try? fm.removeItem(at: c) }
        try write(c, "Photo/CamA/1.JPG", "abc")
        let a2 = try temp(); defer { try? fm.removeItem(at: a2) }
        try write(a2, "Photo/CamA/1.JPG", "abc")
        let r2 = try record(a2, ["Photo/CamA/1.JPG"])
        #expect(try applyIO(plan([r2]), [a2, c], io: .live, hash: { _ in "same" }) == 1)
        #expect(exists(c, "Photo/CamA/_Rejects/1.JPG"))
    }
}
