import Foundation
import Testing
@testable import Auto

struct BackupVerifierTests {
    private func makeFile(_ dir: URL, _ path: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    private func media(_ url: URL) throws -> MediaFile {
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return MediaFile(url: url, size: size, date: Date(timeIntervalSince1970: 1_700_000_000), kind: .photo, cameraID: "cam")
    }

    private func run(_ files: [MediaFile], _ candidates: [String: [URL]], cache: VerificationCache? = nil) async -> VerifyOutcome {
        await BackupVerifier().run(files, candidates: candidates, cache: cache) { _ in }
    }

    @Test func identicalFileIsVerified() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = try media(makeFile(dir, "card/A001.ARW", Array(repeating: 7, count: 5_000)))
        let copy = try makeFile(dir, "drive/A001.ARW", Array(repeating: 7, count: 5_000))
        let out = await run([card], [card.key: [copy]])
        #expect(out.results[card.url] == .verified(copy))
    }

    @Test func sameNameAndSizeButDifferentBytesIsMismatch() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = try media(makeFile(dir, "card/A001.ARW", Array(repeating: 7, count: 5_000)))
        let other = try makeFile(dir, "drive/A001.ARW", Array(repeating: 8, count: 5_000))
        let out = await run([card], [card.key: [other]])
        #expect(out.results[card.url] == .mismatch)
        #expect(BackupVerifier.missing(files: [card], results: out.results).count == 1)
    }

    @Test func noCandidatesIsMissing() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = try media(makeFile(dir, "card/A001.ARW", [1, 2, 3]))
        let out = await run([card], [:])
        #expect(out.results[card.url] == .missing)
    }

    @Test func onlyTheSecondCandidateMatches() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = try media(makeFile(dir, "card/A001.ARW", Array(repeating: 7, count: 100)))
        let wrong = try makeFile(dir, "drive/a/A001.ARW", Array(repeating: 9, count: 100))
        let right = try makeFile(dir, "drive/b/A001.ARW", Array(repeating: 7, count: 100))
        let out = await run([card], [card.key: [wrong, right]])
        #expect(out.results[card.url] == .verified(right))
    }

    @Test func cardFileIsNeverModified() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeFile(dir, "card/A001.ARW", Array(repeating: 7, count: 100))
        let before = try Data(contentsOf: url)
        let card = try media(url)
        _ = await run([card], [card.key: [url]])
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func cancelBeforeStartReturnsCancelledWithNoResults() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = try media(makeFile(dir, "card/A001.ARW", [1, 2, 3]))
        let copy = try makeFile(dir, "drive/A001.ARW", [1, 2, 3])
        let verifier = BackupVerifier()
        verifier.cancel()
        let out = await verifier.run([card], candidates: [card.key: [copy]]) { _ in }
        #expect(out.cancelled)
        #expect(out.results.isEmpty)
    }

    @Test func cancelMidFileStopsAndDoesNotClaimVerified() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Array(repeating: UInt8(5), count: 20 << 20) // several 8 MB chunks
        let card = try media(makeFile(dir, "card/A001.ARW", bytes))
        let copy = try makeFile(dir, "drive/A001.ARW", bytes)
        let verifier = BackupVerifier()
        verifier.onChunkHashed = { [unowned verifier] _ in verifier.cancel() }
        let out = await verifier.run([card], candidates: [card.key: [copy]]) { _ in }
        #expect(out.cancelled)
        #expect(out.results[card.url] == nil)
    }

    @Test func cacheSkipsRehashUntilTheDriveFileChanges() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = try media(makeFile(dir, "card/A001.ARW", Array(repeating: 7, count: 100)))
        let copy = try makeFile(dir, "drive/A001.ARW", Array(repeating: 7, count: 100))
        let cache = VerificationCache()
        _ = await run([card], [card.key: [copy]], cache: cache)

        var triage = BackupVerifier.triage(files: [card], candidates: [card.key: [copy]], cache: cache)
        #expect(triage.settled[card.url] == .verified(copy))
        #expect(triage.toVerify.isEmpty)

        // Same size, new content and mtime: must be hashed again.
        try Data(repeating: 8, count: 100).write(to: copy)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: copy.path)
        triage = BackupVerifier.triage(files: [card], candidates: [card.key: [copy]], cache: cache)
        #expect(triage.settled[card.url] == nil)
        #expect(triage.toVerify.count == 1)
    }

    @Test func triageSplitsMissingAndCandidates() throws {
        let a = MediaFile(url: URL(fileURLWithPath: "/card/A.ARW"), size: 10, date: .now, kind: .photo, cameraID: "c")
        let c = MediaFile(url: URL(fileURLWithPath: "/card/C.ARW"), size: 10, date: .now, kind: .photo, cameraID: "c")
        let triage = BackupVerifier.triage(
            files: [a, c],
            candidates: [a.key: [URL(fileURLWithPath: "/drive/A.ARW")]])
        #expect(triage.toVerify == [a])
        #expect(triage.settled[c.url] == .missing)
        // A name+size hit that was never hashed (A) is not backed up.
        #expect(BackupVerifier.missing(files: [a, c], results: triage.settled).map(\.name) == ["A.ARW", "C.ARW"])
    }

    @Test func copyingOneCardNeverVerifiesAnotherCardsSameNameFile() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = try media(makeFile(dir, "cardA/DCIM/A001.ARW", Array(repeating: 7, count: 5_000)))
        var b = try media(makeFile(dir, "cardB/DCIM/A001.ARW", Array(repeating: 8, count: 5_000)))
        a.cardID = "A"; b.cardID = "B"
        #expect(a.key == b.key) // same name and size, different content
        let drive = dir.appendingPathComponent("drive")

        let outcome = await CopyEngine().run([CopyJob(file: a, destDir: drive)]) { _ in }
        let copied = try #require(outcome.copied.first)
        #expect(copied.destination.lastPathComponent == "A001.ARW")
        #expect(!copied.preexisting)

        let cache = VerificationCache()
        cache.record(outcome.copied)
        let candidates = BackupVerifier.addingCandidates(outcome.copied, to: [:])

        let tA = BackupVerifier.triage(files: [a], candidates: candidates, cache: cache)
        #expect(tA.settled[a.url] == .verified(copied.destination))

        let tB = BackupVerifier.triage(files: [b], candidates: candidates, cache: cache)
        #expect(tB.settled[b.url] == nil)
        #expect(tB.toVerify == [b])
        let out = await run(tB.toVerify, candidates, cache: cache)
        #expect(out.results[b.url] == .mismatch)
        #expect(BackupVerifier.missing(files: [b], results: out.results) == [b])
    }

    @Test func cacheEntryIsTiedToTheCardNotJustThePath() async throws {
        let dir = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeFile(dir, "card/A001.ARW", Array(repeating: 7, count: 100))
        let copy = try makeFile(dir, "drive/A001.ARW", Array(repeating: 7, count: 100))
        var first = try media(url); first.cardID = "uuid-1@/Volumes/Untitled"
        var second = first; second.cardID = "uuid-2@/Volumes/Untitled" // swapped card, same path/size/date
        let cache = VerificationCache()
        _ = await run([first], [first.key: [copy]], cache: cache)
        #expect(BackupVerifier.triage(files: [first], candidates: [first.key: [copy]], cache: cache).settled[url] == .verified(copy))
        #expect(BackupVerifier.triage(files: [second], candidates: [second.key: [copy]], cache: cache).toVerify == [second])
    }

    @Test func renamedCopyStaysACandidateForItsCardFile() throws {
        let file = MediaFile(url: URL(fileURLWithPath: "/card/A001.ARW"), size: 10, date: .now, kind: .photo, cameraID: "c")
        let copied = CopiedFile(file: file, destination: URL(fileURLWithPath: "/drive/A001 2.ARW"), destinationModified: nil, preexisting: false)
        let merged = BackupVerifier.addingCandidates([copied, copied], to: [file.key: [URL(fileURLWithPath: "/drive/x/A001.ARW")]])
        #expect(merged[file.key]?.count == 2)
    }
}
