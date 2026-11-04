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
        #expect(outcome.copiedKeys == [file.key])
        let copy = f.dst.appendingPathComponent("A.MP4")
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
        #expect(try md5(renamed) == md5(file.url))
    }

    @Test func identicalExistingFileCountsAsCopied() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = try makeFile(in: f.src, "A.MP4", bytes: 2_000)
        try FileManager.default.copyItem(at: file.url, to: f.dst.appendingPathComponent("A.MP4"))

        let outcome = await CopyEngine().run([CopyJob(file: file, destDir: f.dst)]) { _ in }
        #expect(outcome.copiedKeys == [file.key])
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
        #expect(outcome.copiedKeys.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.dst.path).isEmpty)
    }

    @Test func cancelMidCopyRemovesPartialFile() async throws {
        let f = try fixture(); defer { f.cleanup() }
        // Several chunks (8 MB each) so cancellation lands mid-file.
        let file = try makeFile(in: f.src, "Big.MP4", bytes: 64 << 20)
        let engine = CopyEngine()
        let outcome = await engine.run([CopyJob(file: file, destDir: f.dst)]) { progress in
            if progress.bytesDone > 0 { engine.cancel() }
        }
        #expect(outcome.cancelled)
        #expect(outcome.copiedKeys.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.dst.path).isEmpty)
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
}

@MainActor final class ProgressBox { var last: CopyProgress? }
