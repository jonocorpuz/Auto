import Foundation
import Testing
@testable import Auto

@Suite("CullJournal") struct CullJournalTests {
    private func tempCopy() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func summary(_ id: UUID, date: Date, rejected: Int = 2) -> CullRunSummary {
        CullRunSummary(runID: id, date: date, model: .sonnet, photos: 10, rejected: rejected,
                       groupsDone: 3, groupsTotal: 3, spentUSD: 0.5, undone: false)
    }

    private func run(_ id: UUID, _ date: Date) -> CullJournalEvent {
        .run(runID: id, date: date, model: .sonnet, settings: CullSettings())
    }

    private func moved(_ id: UUID, _ from: String, photo: String = "p") -> CullJournalEvent {
        .moved(runID: id, from: from, to: CullApplier.rejectsDestination(for: from), reason: "blur",
               criterion: nil, keeper: nil, photoID: photo)
    }

    @Test func appendWritesOneLinePerEvent() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID()
        try CullJournal.append(run(id, Date()), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/1.JPG"), runID: id, in: copy)
        let text = try String(contentsOf: CullJournal.url(runID: id, in: copy), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.hasSuffix("\n"))
        #expect(CullJournal.url(runID: id, in: copy).lastPathComponent.hasSuffix("_\(id.uuidString).jsonl"))
        #expect(try CullJournal.events(in: copy).count == 2)
    }

    @Test func finishedRunFolds() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        try CullJournal.append(run(id, date), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/1.JPG"), runID: id, in: copy)
        try CullJournal.append(.finished(runID: id, summary: summary(id, date: date)), runID: id, in: copy)
        let runs = try CullJournal.runs(in: copy)
        #expect(runs.count == 1)
        #expect(runs[0].rejected == 2 && runs[0].undone == false)
    }

    @Test func unfinishedRunGetsPartialSummary() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID()
        try CullJournal.append(run(id, Date(timeIntervalSince1970: 1_700_000_000)), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/1.JPG", photo: "a"), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/1.CR3", photo: "a"), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/2.JPG", photo: "b"), runID: id, in: copy)
        let runs = try CullJournal.runs(in: copy)
        #expect(runs.count == 1)
        #expect(runs[0].rejected == 2)
    }

    @Test func undoneEventMarksRun() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        try CullJournal.append(run(id, date), runID: id, in: copy)
        try CullJournal.append(.finished(runID: id, summary: summary(id, date: date)), runID: id, in: copy)
        try CullJournal.append(.undone(runID: id, date: Date()), runID: id, in: copy)
        #expect(try CullJournal.runs(in: copy).first?.undone == true)
    }

    @Test func runsAreNewestFirst() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let old = UUID(), new = UUID()
        let d1 = Date(timeIntervalSince1970: 1_700_000_000), d2 = Date(timeIntervalSince1970: 1_700_100_000)
        try CullJournal.append(run(new, d2), runID: new, in: copy)
        try CullJournal.append(.finished(runID: new, summary: summary(new, date: d2)), runID: new, in: copy)
        try CullJournal.append(run(old, d1), runID: old, in: copy)
        try CullJournal.append(.finished(runID: old, summary: summary(old, date: d1)), runID: old, in: copy)
        #expect(try CullJournal.runs(in: copy).map(\.runID) == [new, old])
    }

    @Test func truncatedLastLineIsIgnored() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID()
        try CullJournal.append(run(id, Date()), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/1.JPG"), runID: id, in: copy)
        let url = CullJournal.url(runID: id, in: copy)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        h.write(Data(#"{"moved":{"runID":"#.utf8))
        try h.close()
        #expect(try CullJournal.events(in: copy).count == 2)
        #expect(try CullJournal.moveEntries(runID: id, in: copy).count == 1)
        #expect(try CullJournal.runs(in: copy).count == 1)
    }

    @Test func movesAreNetOfRestored() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID()
        try CullJournal.append(run(id, Date()), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/1.JPG"), runID: id, in: copy)
        try CullJournal.append(moved(id, "Photo/A/2.JPG"), runID: id, in: copy)
        try CullJournal.append(.restored(runID: id, from: "Photo/A/1.JPG", to: "Photo/A/1.JPG"), runID: id, in: copy)
        let moves = try CullJournal.moveEntries(runID: id, in: copy)
        #expect(moves.map(\.from) == ["Photo/A/2.JPG"])
        #expect(moves.first?.to == "Photo/A/_Rejects/2.JPG")
    }

    @Test func emptyJournalHasNoRuns() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try CullJournal.runs(in: copy).isEmpty)
    }

    @Test func appendAfterTornLineStartsFreshLine() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID()
        try CullJournal.append(run(id, Date()), runID: id, in: copy)
        let h = try FileHandle(forWritingTo: CullJournal.url(runID: id, in: copy))
        try h.seekToEnd(); h.write(Data(#"{"moved":{"runID":"#.utf8)); try h.close()
        try CullJournal.append(moved(id, "Photo/A/1.JPG"), runID: id, in: copy)
        #expect(try CullJournal.events(in: copy).count == 2)
        #expect(try CullJournal.moveEntries(runID: id, in: copy).count == 1)
    }

    @Test func intentsFoldIntoMovedPairAndRestored() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID()
        func intent(_ f: String) -> CullJournalEvent {
            .intent(runID: id, from: f, to: CullApplier.rejectsDestination(for: f), photoID: "p", size: 1)
        }
        try CullJournal.append(intent("Photo/A/1.JPG"), runID: id, in: copy)
        try CullJournal.append(intent("Photo/A/1.CR3"), runID: id, in: copy)
        #expect(try CullJournal.moveEntries(runID: id, in: copy).allSatisfy(\.intentOnly))
        try CullJournal.append(.movedPair(runID: id, members: [
            CullMovedMember(from: "Photo/A/1.JPG", to: "Photo/A/_Rejects/1.JPG"),
            CullMovedMember(from: "Photo/A/1.CR3", to: "Photo/A/_Rejects/1.CR3")],
            reason: "", criterion: nil, keeper: nil, photoID: "p"), runID: id, in: copy)
        let e = try CullJournal.moveEntries(runID: id, in: copy)
        #expect(e.count == 2 && e.allSatisfy { !$0.intentOnly })
        try CullJournal.append(intent("Photo/A/2.JPG"), runID: id, in: copy)
        try CullJournal.append(.restored(runID: id, from: "Photo/A/2.JPG", to: "Photo/A/2.JPG"), runID: id, in: copy)
        #expect(try CullJournal.moveEntries(runID: id, in: copy).count == 2)
    }

    @Test func finishedStatusRoundTripsAndOldSummaryDecodes() throws {
        let copy = try tempCopy(); defer { try? FileManager.default.removeItem(at: copy) }
        let id = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        var s = summary(id, date: date); s.status = "cancelled"
        try CullJournal.append(run(id, date), runID: id, in: copy)
        try CullJournal.append(.finished(runID: id, summary: s), runID: id, in: copy)
        #expect(try CullJournal.runs(in: copy).first?.status == "cancelled")
        let old = #"{"runID":"\#(id.uuidString)","date":"2023-11-14T22:13:20Z","model":"sonnet","photos":1,"rejected":1,"groupsDone":0,"groupsTotal":0,"spentUSD":0,"undone":false}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(CullRunSummary.self, from: Data(old.utf8)).status == "completed")
    }
}
