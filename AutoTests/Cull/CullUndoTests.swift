import Foundation
import Testing
@testable import Auto

@Suite("CullUndo") struct CullUndoTests {
    private let fm = FileManager.default

    private func temp() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func write(_ copy: URL, _ rel: String, _ text: String) throws {
        let url = copy.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ copy: URL, _ rel: String) -> String? {
        try? String(contentsOf: copy.appendingPathComponent(rel), encoding: .utf8)
    }

    private func exists(_ copy: URL, _ rel: String) -> Bool {
        (try? fm.attributesOfItem(atPath: copy.appendingPathComponent(rel).path)) != nil
    }

    private func record(_ copy: URL, _ members: [String]) throws -> PhotoRecord {
        var stamps: [String: FileStamp] = [:]
        for m in members {
            let a = try fm.attributesOfItem(atPath: copy.appendingPathComponent(m).path)
            stamps[m] = FileStamp(size: Int64(a[.size] as! UInt64), mtime: a[.modificationDate] as! Date)
        }
        return PhotoRecord(id: members[0], camera: "CamA", members: members, representative: members[0], stamps: stamps)
    }

    @discardableResult
    private func cull(_ copies: [URL], _ rels: [[String]]) throws -> UUID {
        let records = try rels.map { try record(copies[0], $0) }
        let decisions = records.map {
            CullDecision(photoID: $0.id, verdict: .reject, reason: "blur", criterion: nil, keeperID: nil, confidence: 1, source: .model)
        }
        let p = CullPlan(runID: UUID(), settings: CullSettings(), decisions: decisions,
                         records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), catalogCopy: copies[0])
        _ = try CullApplier.apply(p, copies: copies, cardVolumes: [], onMoved: { _, _ in })
        return p.runID
    }

    private func undo(_ id: UUID?, _ copies: [URL]) throws -> CullRunSummary {
        try CullApplier.undo(runID: id, copies: copies, cardVolumes: [], onProgress: { _, _ in })
    }

    @Test func restoresPairsOnAllCopiesAndPrunesEmptyRejects() throws {
        let a = try temp(), b = try temp(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        for c in [a, b] { try write(c, "Photo/CamA/d/1.JPG", "j"); try write(c, "Photo/CamA/d/1.CR3", "r") }
        let id = try cull([a, b], [["Photo/CamA/d/1.JPG", "Photo/CamA/d/1.CR3"]])
        #expect(!exists(b, "Photo/CamA/d/1.JPG"))
        let s = try undo(id, [a, b])
        #expect(s.undone)
        for c in [a, b] {
            #expect(read(c, "Photo/CamA/d/1.JPG") == "j" && read(c, "Photo/CamA/d/1.CR3") == "r")
            #expect(!exists(c, "Photo/CamA/_Rejects"))
            #expect(try CullJournal.runs(in: c).first?.undone == true)
            #expect(try CullJournal.moves(runID: id, in: c).isEmpty)
        }
    }

    @Test func nonEmptyRejectsFolderIsKept() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        try write(a, "Photo/CamA/1.JPG", "j")
        try write(a, "Photo/CamA/_Rejects/other.JPG", "keepme")
        let id = try cull([a], [["Photo/CamA/1.JPG"]])
        _ = try undo(id, [a])
        #expect(read(a, "Photo/CamA/1.JPG") == "j")
        #expect(read(a, "Photo/CamA/_Rejects/other.JPG") == "keepme")
    }

    @Test func reoccupiedSourceGoesToUniqueSibling() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        try write(a, "Photo/CamA/1.JPG", "orig")
        let id = try cull([a], [["Photo/CamA/1.JPG"]])
        try write(a, "Photo/CamA/1.JPG", "new")
        _ = try undo(id, [a])
        #expect(read(a, "Photo/CamA/1.JPG") == "new")
        #expect(read(a, "Photo/CamA/1 2.JPG") == "orig")
        let restored = try CullJournal.events(in: a).compactMap { e -> String? in
            if case .restored(_, _, let to) = e { return to } else { return nil }
        }
        #expect(restored == ["Photo/CamA/1 2.JPG"])
    }

    @Test func reoccupiedPairIsRestoredUnderSharedSuffixOnBothCopies() throws {
        let a = try temp(), b = try temp(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        for c in [a, b] { try write(c, "Photo/CamA/IMG.JPG", "j"); try write(c, "Photo/CamA/IMG.CR3", "r") }
        let id = try cull([a, b], [["Photo/CamA/IMG.JPG", "Photo/CamA/IMG.CR3"]])
        try write(a, "Photo/CamA/IMG.JPG", "new")   // only the JPG's name is taken again
        _ = try undo(id, [a, b])
        #expect(read(a, "Photo/CamA/IMG.JPG") == "new")
        #expect(read(a, "Photo/CamA/IMG 2.JPG") == "j" && read(a, "Photo/CamA/IMG 2.CR3") == "r")
        #expect(!exists(a, "Photo/CamA/IMG.CR3"))
        // Shared across copies when possible: the mirror follows the primary's suffix.
        #expect(read(b, "Photo/CamA/IMG 2.JPG") == "j" && read(b, "Photo/CamA/IMG 2.CR3") == "r")
        #expect(!exists(b, "Photo/CamA/IMG.JPG") && !exists(b, "Photo/CamA/IMG.CR3"))
    }

    @Test func missingFileIsRestoreSkipped() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        try write(a, "Photo/CamA/1.JPG", "x"); try write(a, "Photo/CamA/2.JPG", "y")
        let id = try cull([a], [["Photo/CamA/1.JPG"], ["Photo/CamA/2.JPG"]])
        try fm.removeItem(at: a.appendingPathComponent("Photo/CamA/_Rejects/1.JPG"))
        _ = try undo(id, [a])
        #expect(read(a, "Photo/CamA/2.JPG") == "y")
        #expect(!exists(a, "Photo/CamA/1.JPG"))
        let skipped = try CullJournal.events(in: a).filter { if case .restoreSkipped = $0 { return true } else { return false } }
        #expect(skipped.count == 1)
    }

    @Test func nilRunIDUndoesLatestNotUndoneThenNothingToUndo() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        try write(a, "Photo/CamA/1.JPG", "x"); try write(a, "Photo/CamA/2.JPG", "y")
        let first = try cull([a], [["Photo/CamA/1.JPG"]])
        Thread.sleep(forTimeInterval: 1.1)   // run dates are iso8601 seconds
        let second = try cull([a], [["Photo/CamA/2.JPG"]])
        #expect(try undo(nil, [a]).runID == second)
        #expect(exists(a, "Photo/CamA/2.JPG") && !exists(a, "Photo/CamA/1.JPG"))
        #expect(try undo(nil, [a]).runID == first)
        #expect(exists(a, "Photo/CamA/1.JPG"))
        #expect(throws: CullError.nothingToUndo) { try undo(nil, [a]) }
        #expect(throws: CullError.nothingToUndo) { try undo(first, [a]) }
    }

    @Test func intentOnlyAtDestinationIsRecovered() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        let id = UUID()
        try write(a, "Photo/CamA/_Rejects/1.JPG", "abc")   // renamed, crash before movedPair
        try CullJournal.append(.run(runID: id, date: Date(), model: .sonnet, settings: CullSettings()), runID: id, in: a)
        try CullJournal.append(.intent(runID: id, from: "Photo/CamA/1.JPG", to: "Photo/CamA/_Rejects/1.JPG", photoID: "p", size: 3), runID: id, in: a)
        #expect(try CullJournal.moveEntries(runID: id, in: a).first?.intentOnly == true)
        _ = try undo(id, [a])
        #expect(read(a, "Photo/CamA/1.JPG") == "abc")
        #expect(!exists(a, "Photo/CamA/_Rejects"))
    }

    @Test func intentOnlyStillAtSourceOrWrongSizeIsLeftAlone() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        let id = UUID()
        try write(a, "Photo/CamA/1.JPG", "abc")                    // never moved
        try write(a, "Photo/CamA/_Rejects/2.JPG", "different")     // unrelated file at `to`
        try CullJournal.append(.run(runID: id, date: Date(), model: .sonnet, settings: CullSettings()), runID: id, in: a)
        try CullJournal.append(.intent(runID: id, from: "Photo/CamA/1.JPG", to: "Photo/CamA/_Rejects/1.JPG", photoID: "p", size: 3), runID: id, in: a)
        try CullJournal.append(.intent(runID: id, from: "Photo/CamA/2.JPG", to: "Photo/CamA/_Rejects/2.JPG", photoID: "q", size: 3), runID: id, in: a)
        _ = try undo(id, [a])
        #expect(read(a, "Photo/CamA/1.JPG") == "abc")
        #expect(read(a, "Photo/CamA/_Rejects/2.JPG") == "different")
        #expect(!exists(a, "Photo/CamA/2.JPG"))
    }

    @Test func legacyMovedEventsStillUndo() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        let id = UUID()
        try write(a, "Photo/CamA/_Rejects/1.JPG", "x")
        try CullJournal.append(.run(runID: id, date: Date(), model: .sonnet, settings: CullSettings()), runID: id, in: a)
        try CullJournal.append(.moved(runID: id, from: "Photo/CamA/1.JPG", to: "Photo/CamA/_Rejects/1.JPG", reason: "", criterion: nil, keeper: nil, photoID: "p"), runID: id, in: a)
        _ = try undo(id, [a])
        #expect(read(a, "Photo/CamA/1.JPG") == "x")
    }

    @Test func liveApplierRevertUndoesRun() throws {
        let a = try temp(); defer { try? fm.removeItem(at: a) }
        try write(a, "Photo/CamA/1.JPG", "x")
        let id = try cull([a], [["Photo/CamA/1.JPG"]])
        try LiveCullApplier().revert(runID: id, copies: [a], cardVolumes: [], onProgress: { _, _ in })
        #expect(read(a, "Photo/CamA/1.JPG") == "x")
    }
}
