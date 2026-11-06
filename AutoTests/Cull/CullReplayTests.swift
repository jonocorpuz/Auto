import Foundation
import Testing
@testable import Auto

@Suite("CullReplay") struct CullReplayTests {
    private let fm = FileManager.default

    private func temp() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)").resolvingSymlinksInPath()
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

    /// Culls on `primary` only, so the mirror misses the run.
    private func cull(_ primary: URL, _ rels: [[String]]) throws -> UUID {
        let records = try rels.map { try record(primary, $0) }
        let decisions = records.map {
            CullDecision(photoID: $0.id, verdict: .reject, reason: "blur", criterion: nil, keeperID: nil, confidence: 1, source: .model)
        }
        let p = CullPlan(runID: UUID(), settings: CullSettings(), decisions: decisions,
                         records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), catalogCopy: primary)
        _ = try CullApplier.apply(p, copies: [primary], cardVolumes: [], onMoved: { _, _ in })
        return p.runID
    }

    private func fixture() throws -> (a: URL, b: URL, id: UUID) {
        let a = try temp(), b = try temp()
        for c in [a, b] {
            try write(c, "Photo/CamA/d/1.JPG", "jj"); try write(c, "Photo/CamA/d/1.CR3", "rrr")
            try write(c, "Photo/CamA/d/2.JPG", "keep")
        }
        let id = try cull(a, [["Photo/CamA/d/1.JPG", "Photo/CamA/d/1.CR3"]])
        return (a, b, id)
    }

    private func replay(_ a: URL, _ b: URL) throws -> CullReplayResult {
        try CullReplay.replay(from: a, to: b, cardVolumes: [])
    }

    @Test func replaysAppliedRunOntoMirror() throws {
        let (a, b, id) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        let r = try replay(a, b)
        #expect(r.moved == 1 && r.skipped.isEmpty && r.runsReplayed == 1)
        #expect(!exists(b, "Photo/CamA/d/1.JPG") && !exists(b, "Photo/CamA/d/1.CR3"))
        #expect(read(b, "Photo/CamA/_Rejects/d/1.JPG") == "jj" && read(b, "Photo/CamA/_Rejects/d/1.CR3") == "rrr")
        #expect(read(b, "Photo/CamA/d/2.JPG") == "keep")
        #expect(try CullJournal.runs(in: b).first?.runID == id)
        #expect(try CullJournal.moves(runID: id, in: b).count == 2)
    }

    @Test func idempotent() throws {
        let (a, b, _) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        _ = try replay(a, b)
        let r = try replay(a, b)
        #expect(r == CullReplayResult())
    }

    @Test func sizeMismatchIsSkipped() throws {
        let (a, b, _) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        try write(b, "Photo/CamA/d/1.CR3", "different size")
        let r = try replay(a, b)
        #expect(r.moved == 0)
        #expect(Set(r.skipped) == ["Photo/CamA/d/1.JPG", "Photo/CamA/d/1.CR3"])
        #expect(exists(b, "Photo/CamA/d/1.JPG") && exists(b, "Photo/CamA/d/1.CR3"))
        #expect(!exists(b, "Photo/CamA/_Rejects"))
    }

    @Test func fileAlreadyAtDestinationIsSkipped() throws {
        let (a, b, _) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        try write(b, "Photo/CamA/_Rejects/d/1.JPG", "jj")
        try fm.removeItem(at: b.appendingPathComponent("Photo/CamA/d/1.JPG"))
        let r = try replay(a, b)
        #expect(r.moved == 0)
        #expect(exists(b, "Photo/CamA/d/1.CR3"))
        #expect(!exists(b, "Photo/CamA/_Rejects/d/1.CR3"))
    }

    @Test func undoneSourceRestoresMirror() throws {
        let (a, b, id) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        _ = try replay(a, b)
        try CullApplier.undo(runID: id, copies: [a], cardVolumes: [], onProgress: { _, _ in })
        let r = try replay(a, b)
        #expect(r.restored == 2 && r.runsReplayed == 1)
        #expect(read(b, "Photo/CamA/d/1.JPG") == "jj" && read(b, "Photo/CamA/d/1.CR3") == "rrr")
        #expect(try CullJournal.runs(in: b).first?.undone == true)
        #expect(try replay(a, b) == CullReplayResult())
    }

    @Test func missingFileIsSkipped() throws {
        let (a, b, _) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        try fm.removeItem(at: b.appendingPathComponent("Photo/CamA/d/1.CR3"))
        let r = try replay(a, b)
        #expect(r.moved == 0 && r.skipped.count == 2)
        #expect(exists(b, "Photo/CamA/d/1.JPG"))
    }

    @Test func neverOverwritesExistingDestination() throws {
        let (a, b, _) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        try write(b, "Photo/CamA/_Rejects/d/1.CR3", "precious")
        let r = try replay(a, b)
        #expect(r.moved == 0)
        #expect(read(b, "Photo/CamA/_Rejects/d/1.CR3") == "precious")
        #expect(read(b, "Photo/CamA/d/1.JPG") == "jj" && read(b, "Photo/CamA/d/1.CR3") == "rrr")
    }

    @Test func refusesCardTarget() throws {
        let (a, b, _) = try fixture(); defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        #expect(throws: CullError.onCard) {
            try CullReplay.replay(from: a, to: b, cardVolumes: [b])
        }
        #expect(read(b, "Photo/CamA/d/1.JPG") == "jj")
    }
}
