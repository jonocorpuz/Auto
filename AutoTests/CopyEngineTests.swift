import CryptoKit
import Foundation
import Testing
@testable import Auto

struct CopyEngineTests {
    private func makeFile(in dir: URL, _ name: String, bytes: Int, fill: UInt8 = 0x42, date: Date = Date(timeIntervalSince1970: 1_600_000_000)) throws -> MediaFile {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: fill, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return MediaFile(url: url, size: Int64(bytes), date: date, kind: .video, cameraID: "cam")
    }

    private func md5(_ url: URL) throws -> String {
        Insecure.MD5.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func mtime(_ url: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func fixture() throws -> (src: URL, dst: URL, cleanup: () -> Void) {
        let src = try FixtureCard.makeTempDir("CopySrc")
        let dst = try FixtureCard.makeTempDir("CopyDst")
        return (src, dst, {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        })
    }

    @Test func copiesAndVerifies() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 300_000)
        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: f.dst)]) { _ in }

        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.map(\.file.key) == [file.key])
        let copy = f.dst.appendingPathComponent("A.MP4")
        #expect(outcome.copied.first?.destination == copy)
        #expect(outcome.copied.first?.preexisting == false)
        #expect(try md5(copy) == md5(file.url))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.dst.path).filter { $0.hasSuffix(".auto-partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func preservesModificationDate() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 1_000, date: Date(timeIntervalSince1970: 1_500_000_000))
        _ = await CopyEngine().run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        let copied = try mtime(f.dst.appendingPathComponent("A.MP4"))
        #expect(abs(copied.timeIntervalSince1970 - 1_500_000_000) < 1)
    }

    @Test func neverOverwritesDifferentFile() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000, fill: 0x01)
        let existing = f.dst.appendingPathComponent("A.MP4")
        try Data(repeating: 0x99, count: 2_000).write(to: existing) // same size, different content
        let before = try md5(existing)

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(try md5(existing) == before)
        let renamed = f.dst.appendingPathComponent("A 2.MP4")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(outcome.copied.first?.destination == renamed)
        #expect(try md5(renamed) == md5(file.url))
    }

    @Test func identicalExistingFileCountsAsCopied() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000)
        try FileManager.default.copyItem(at: file.url, to: f.dst.appendingPathComponent("A.MP4"))

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        #expect(outcome.copied.map(\.file.key) == [file.key])
        #expect(outcome.copied.first?.preexisting == true)
        #expect(outcome.copied.first?.destination == f.dst.appendingPathComponent("A.MP4"))
        #expect(outcome.failures.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.dst.path)
        #expect(names == ["A.MP4"])
    }

    @Test func renameNeverOverwritesRacedDestination() throws {
        let f = try fixture(); defer { f.cleanup() }
        let partial = f.dst.appendingPathComponent(".A.MP4.\(UUID().uuidString).auto-partial")
        try Data(repeating: 0x01, count: 100).write(to: partial)
        // Destination appears after name selection but before the rename.
        let dest = f.dst.appendingPathComponent("A.MP4")
        try Data(repeating: 0x99, count: 100).write(to: dest)
        try Data(repeating: 0x98, count: 100).write(to: f.dst.appendingPathComponent("A 2.MP4"))

        let final = try CopyEngine.moveWithoutOverwriting(partial, to: dest)
        #expect(final.lastPathComponent == "A 3.MP4")
        #expect(try Data(contentsOf: dest) == Data(repeating: 0x99, count: 100))
        #expect(try Data(contentsOf: f.dst.appendingPathComponent("A 2.MP4")) == Data(repeating: 0x98, count: 100))
        #expect(try Data(contentsOf: final) == Data(repeating: 0x01, count: 100))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func sourceIsUnchangedAfterCopy() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 50_000)
        let hashBefore = try md5(file.url)
        let mtimeBefore = try mtime(file.url)
        _ = await CopyEngine().run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        #expect(try md5(file.url) == hashBefore)
        #expect(try mtime(file.url) == mtimeBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.src.path) == ["A.MP4"])
    }

    @Test func cancelBeforeRunLeavesNoPartialFiles() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 10_000)
        let engine = CopyEngine()
        engine.cancel()
        let outcome = await engine.run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        #expect(outcome.cancelled)
        #expect(outcome.copied.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.dst.path).isEmpty)
    }

    @Test func cancelMidCopyRemovesPartialFile() async throws {
        let f = try fixture(); defer { f.cleanup() }
        // Several chunks (8 MB each) so cancellation lands mid-file.
        let file = try makeFile(in: f.src, "Big.MP4", bytes: 24 << 20)
        let engine = CopyEngine()
        engine.onChunkWritten = { [unowned engine] _ in engine.cancel() } // after the first chunk
        let outcome = await engine.run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        #expect(outcome.cancelled)
        #expect(outcome.copied.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.dst.path).isEmpty)
    }

    @Test func cancelDuringVerificationLeavesNothing() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "Big.MP4", bytes: 24 << 20)
        let engine = CopyEngine()
        engine.onVerifyChunk = { [unowned engine] _ in engine.cancel() }
        let outcome = await engine.run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        #expect(outcome.cancelled)
        #expect(outcome.copied.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.dst.path).isEmpty)
    }

    @Test func noProgressDeliveredAfterRunReturns() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let files = try (0..<5).map { try makeFile(in: f.src, "F\($0).MP4", bytes: 20_000) }
        let box = ProgressBox()
        _ = await CopyEngine().run(files.map { CopyJob(file: $0, destDir: f.dst) }) { _ in box.count += 1 }
        let atReturn = box.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(atReturn > 0)
        #expect(box.count == atReturn)
    }

    @Test func reportsFinalProgress() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 5_000)
        let box = ProgressBox()
        _ = await CopyEngine().run([CopyJob(file: file, destDir: f.dst)]) { box.last = $0 }
        let last = try #require(box.last)
        #expect(last.filesDone == 1)
        #expect(last.fraction == 1)
    }

    // MARK: Generalized jobs (root, onCollision, expectedChecksum)

    private func md5Data(_ url: URL) throws -> Data { Data(Insecure.MD5.hash(data: try Data(contentsOf: url))) }

    private func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func checksumIsSourceMD5ForNewAndPreexistingFiles() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let fresh = try makeFile(in: f.src, "A.MP4", bytes: 3_000, fill: 0x11)
        let same = try makeFile(in: f.src, "B.MP4", bytes: 3_000, fill: 0x22)
        try FileManager.default.copyItem(at: same.url, to: f.dst.appendingPathComponent("B.MP4"))

        let outcome = await CopyEngine().run([CopyJob(file: fresh, destDir: f.dst), CopyJob(file: same, destDir: f.dst)]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.count == 2)
        #expect(outcome.copied[0].preexisting == false)
        #expect(outcome.copied[0].checksum == (try md5Data(fresh.url)))
        #expect(outcome.copied[1].preexisting == true)
        #expect(outcome.copied[1].checksum == (try md5Data(same.url)))
    }

    @Test func skipWithDifferentFileFailsAndLeavesItUntouched() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000, fill: 0x01)
        let existing = f.dst.appendingPathComponent("A.MP4")
        let other = Data(repeating: 0x99, count: 2_000)
        try other.write(to: existing)

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: f.dst, onCollision: .skip)]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.destinationExists.errorDescription)
        #expect(try Data(contentsOf: existing) == other)
        #expect(try names(f.dst) == ["A.MP4"])
    }

    @Test func skipWithDifferentSizeFileFailsToo() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000)
        let existing = f.dst.appendingPathComponent("A.MP4")
        try Data(repeating: 0x99, count: 10).write(to: existing)

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: f.dst, onCollision: .skip)]) { _ in }
        #expect(outcome.failures.count == 1)
        #expect(try Data(contentsOf: existing) == Data(repeating: 0x99, count: 10))
        #expect(try names(f.dst) == ["A.MP4"])
    }

    @Test func skipWithIdenticalFileIsPreexisting() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000)
        try FileManager.default.copyItem(at: file.url, to: f.dst.appendingPathComponent("A.MP4"))

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: f.dst, onCollision: .skip)]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.first?.preexisting == true)
        #expect(outcome.copied.first?.checksum == (try md5Data(file.url)))
        #expect(try names(f.dst) == ["A.MP4"])
    }

    @Test func skipMoveRefusesRacedDestinationAndKeepsOtherFile() throws {
        let f = try fixture(); defer { f.cleanup() }
        let partial = f.dst.appendingPathComponent(".A.MP4.\(UUID().uuidString).auto-partial")
        try Data(repeating: 0x01, count: 100).write(to: partial)
        let dest = f.dst.appendingPathComponent("A.MP4")
        try Data(repeating: 0x99, count: 100).write(to: dest)

        #expect(throws: CopyEngine.CopyError.self) {
            try CopyEngine.moveWithoutOverwriting(partial, to: dest, renameOnCollision: false)
        }
        #expect(try Data(contentsOf: dest) == Data(repeating: 0x99, count: 100))
        #expect(try names(f.dst).count == 2) // the helper leaves the partial; copyVerified removes it (see the end-to-end race test)
    }

    @Test func expectedChecksumMatchCopies() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000)
        let job = CopyJob(file: file, destDir: f.dst, expectedChecksum: try md5Data(file.url))
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.count == 1)
    }

    @Test func expectedChecksumMismatchFailsAndLeavesNothing() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000)
        let job = CopyJob(file: file, destDir: f.dst, expectedChecksum: Data(repeating: 0, count: 16))
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.sourceChanged.errorDescription)
        #expect(try names(f.dst).isEmpty)
    }

    @Test func expectedChecksumMismatchOnPreexistingFileFails() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000)
        try FileManager.default.copyItem(at: file.url, to: f.dst.appendingPathComponent("A.MP4"))
        let job = CopyJob(file: file, destDir: f.dst, onCollision: .skip, expectedChecksum: Data(repeating: 0, count: 16))
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.sourceChanged.errorDescription)
        #expect(try names(f.dst) == ["A.MP4"])
    }

    @Test func missingRootFailsWithoutCreatingDirectories() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 1_000)
        let root = f.dst.appendingPathComponent("Gone")
        let dest = root.appendingPathComponent("Sub/Deeper")

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: dest, root: root)]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.rootMissing.errorDescription)
        #expect(try names(f.dst).isEmpty)
    }

    @Test func rootThatIsAFileFailsAsMissing() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 1_000)
        let root = f.dst.appendingPathComponent("NotADir")
        try Data([1]).write(to: root)

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: root.appendingPathComponent("Sub"), root: root)]) { _ in }
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.rootMissing.errorDescription)
        #expect(try names(f.dst) == ["NotADir"])
    }

    @Test func existingRootGetsMissingSubfoldersBelowItOnly() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 1_000)
        let root = f.dst.appendingPathComponent("Copy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let dest = root.appendingPathComponent("Cam/Day 1")

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: dest, root: root)]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.first?.destination == dest.appendingPathComponent("A.MP4"))
        #expect(try names(f.dst) == ["Copy"])
        #expect(try names(root) == ["Cam"])
    }

    @Test func destinationOutsideRootIsRefused() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 1_000)
        let root = f.dst.appendingPathComponent("Copy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let outside = f.dst.appendingPathComponent("Other/Sub")

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: outside, root: root)]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.outsideRoot.errorDescription)
        #expect(try names(f.dst) == ["Copy"])
    }

    @Test func symlinkedComponentBelowRootIsRefused() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 1_000)
        let root = f.dst.appendingPathComponent("Copy")
        let elsewhere = f.dst.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Cam"), withDestinationURL: elsewhere)

        let job = CopyJob(file: file, destDir: root.appendingPathComponent("Cam/Day"), root: root)
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.outsideRoot.errorDescription)
        #expect(try names(elsewhere).isEmpty)
    }

    @Test func regularFileComponentBelowRootFailsAndCreatesNothing() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 1_000)
        let root = f.dst.appendingPathComponent("Copy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data([1]).write(to: root.appendingPathComponent("Cam"))

        let job = CopyJob(file: file, destDir: root.appendingPathComponent("Cam/Day/Deeper"), root: root)
        let outcome = await CopyEngine().run([job]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(try names(root) == ["Cam"])
        #expect(try Data(contentsOf: root.appendingPathComponent("Cam")) == Data([1]))
    }

    @Test func skipRaceWithDifferentFileMidCopyFailsAndLeavesNoPartial() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000, fill: 0x01)
        let dest = f.dst.appendingPathComponent("A.MP4")
        let other = Data(repeating: 0x99, count: 2_000)
        let engine = CopyEngine()
        engine.onChunkWritten = { _ in try? other.write(to: dest) }

        let outcome = await engine.run([CopyJob(file: file, destDir: f.dst, onCollision: .skip)]) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.destinationExists.errorDescription)
        #expect(try Data(contentsOf: dest) == other)
        #expect(try names(f.dst) == ["A.MP4"])
    }

    @Test func skipRaceWithIdenticalFileMidCopyIsPreexisting() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000, fill: 0x01)
        let dest = f.dst.appendingPathComponent("A.MP4")
        let same = try Data(contentsOf: file.url)
        let engine = CopyEngine()
        engine.onChunkWritten = { _ in try? same.write(to: dest) }

        let outcome = await engine.run([CopyJob(file: file, destDir: f.dst, onCollision: .skip)]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.first?.preexisting == true)
        #expect(outcome.copied.first?.destination == dest)
        #expect(outcome.copied.first?.checksum == (try md5Data(file.url)))
        #expect(try names(f.dst) == ["A.MP4"])
    }

    @Test func syncSourceUsesCopyCardIDAndKind() {
        let url = URL(fileURLWithPath: "/tmp/x/clip.mp4")
        let m = MediaFile.syncSource(url: url, size: 5, modified: Date(timeIntervalSince1970: 7))
        #expect(m.cardID == "copy")
        #expect(m.cameraID == "")
        #expect(m.kind == .video)
        #expect(m.size == 5)
    }
}

@MainActor final class ProgressBox { var last: CopyProgress?; var count = 0 }
