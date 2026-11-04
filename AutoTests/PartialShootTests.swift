import Foundation
import Testing
@testable import Auto

struct PartialShootTests {
    @Test func afterVerifyNeverBackedWithMissing() {
        #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 1, hasPlan: false, current: .verifying) == .needsBackup)
        #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 0, hasPlan: false, current: .verifying) == .backed)
        #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 2, hasPlan: true, current: .verifying) == .ready)
        for plan in [true, false] {
            #expect(CardPhase.afterVerify(fileCount: 3, missingCount: 1, hasPlan: plan, current: .backed) != .backed)
        }
    }

    @Test func partialCopyLeavesRestMissing() async throws {
        let base = try FixtureCard.makeTempDir("AutoPartial")
        defer { try? FileManager.default.removeItem(at: base) }
        let cardDir = base.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        var files: [MediaFile] = []
        for i in 0..<4 {
            let url = cardDir.appendingPathComponent("C000\(i).MP4")
            try Data(repeating: UInt8(i + 1), count: 1_000 + i).write(to: url)
            files.append(MediaFile(url: url, size: Int64(1_000 + i), date: Date(timeIntervalSince1970: 1_700_000_000), kind: .video, cameraID: "cam"))
        }
        let selected = Array(files.prefix(2))
        let dest = base.appendingPathComponent("shoot/Video/Cam")
        try ShootPlanner.createDirectories([dest], root: base.appendingPathComponent("shoot"), cardVolumes: [])
        let outcome = await CopyEngine().run(selected.map { CopyJob(file: $0, destDir: dest) }) { _ in }
        #expect(outcome.copied.count == 2)

        let cache = VerificationCache()
        cache.record(outcome.copied)
        let candidates = BackupVerifier.addingCandidates(outcome.copied, to: [:])
        let triage = BackupVerifier.triage(files: files, candidates: candidates, cache: cache)
        var results = triage.settled
        let out = await BackupVerifier().run(triage.toVerify, candidates: candidates, cache: cache) { _ in }
        results.merge(out.results) { $1 }

        let missing = BackupVerifier.missing(files: files, results: results)
        #expect(Set(missing.map(\.name)) == Set(files.suffix(2).map(\.name)))
        #expect(CardPhase.afterVerify(fileCount: files.count, missingCount: missing.count, hasPlan: false, current: .verifying) == .needsBackup)
    }
}
