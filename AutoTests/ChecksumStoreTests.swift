import Foundation
import Testing
@testable import Auto

struct ChecksumStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutoChecksum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stamp(_ url: URL, root: URL) -> ChecksumStore.FileStamp? {
        ChecksumStore.stamp(url, volumeID: "VOL", volumeRoot: root)
    }

    @Test func stampChangesOnMtimeEdit() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.bin")
        try Data(repeating: 1, count: 100).write(to: f)
        let before = try #require(stamp(f, root: dir))
        #expect(before.relPath == "a.bin")
        #expect(before.size == 100)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: f.path)
        let after = try #require(stamp(f, root: dir))
        #expect(before != after)
        #expect(before.inode == after.inode)
    }

    @Test func stampChangesOnReplace() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.bin")
        let g = dir.appendingPathComponent("b.bin")
        try Data(repeating: 1, count: 100).write(to: f)
        try Data(repeating: 2, count: 100).write(to: g)
        let date = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: g.path)
        let before = try #require(stamp(f, root: dir))
        // Replace a.bin with a same-size, same-mtime file that has a new inode.
        try FileManager.default.removeItem(at: f)
        try FileManager.default.moveItem(at: g, to: f)
        let after = try #require(stamp(f, root: dir))
        #expect(before.size == after.size && before.mtime == after.mtime)
        #expect(before.inode != after.inode)
        #expect(before != after)
    }

    @Test func stampIsNilForDirectoriesAndMissing() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(stamp(dir, root: dir) == nil)
        #expect(stamp(dir.appendingPathComponent("nope"), root: dir) == nil)
    }

    @Test func relativePathIsVolumeRelative() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("x/y", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let f = sub.appendingPathComponent("c.mp4")
        try Data([1]).write(to: f)
        #expect(stamp(f, root: dir)?.relPath == "x/y/c.mp4")
        let auto = try #require(ChecksumStore.stamp(f))
        #expect(auto.size == 1)
    }

    @Test func recordAndLookup() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: f)
        let s = try #require(stamp(f, root: dir))
        let store = ChecksumStore(url: nil)
        #expect(store.checksum(for: s) == nil)
        store.record(Data([9, 9]), for: s)
        #expect(store.checksum(for: s) == Data([9, 9]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: f.path)
        let edited = try #require(stamp(f, root: dir))
        #expect(store.checksum(for: edited) == nil)
    }

    @Test func recordCopiedFileSeedsFromChecksum() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: f)
        let media = MediaFile.syncSource(url: f, size: 3, modified: Date())
        let mtime = VerificationCache.modificationDate(f)
        let store = ChecksumStore(url: nil)
        store.record(CopiedFile(file: media, destination: f, destinationModified: mtime, preexisting: false, checksum: nil))
        #expect(store.count == 0)
        store.record(CopiedFile(file: media, destination: f, destinationModified: nil, preexisting: false, checksum: Data([7, 7])))
        #expect(store.count == 0)
        store.record(CopiedFile(file: media, destination: f, destinationModified: mtime, preexisting: true, checksum: Data([7, 7])))
        #expect(store.count == 1)
        #expect(store.checksum(for: try #require(ChecksumStore.stamp(f))) == Data([7, 7]))
    }

    @Test func recordCopiedFileSkipsDestinationModifiedAfterCopy() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: f)
        let media = MediaFile.syncSource(url: f, size: 3, modified: Date())
        let copied = CopiedFile(file: media, destination: f, destinationModified: VerificationCache.modificationDate(f),
                                preexisting: false, checksum: Data([7, 7]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: f.path)
        let store = ChecksumStore(url: nil)
        store.record(copied)
        #expect(store.count == 0)
    }

    @Test func persistenceRoundTrip() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: f)
        let s = try #require(stamp(f, root: dir))
        let file = dir.appendingPathComponent("sub/checksums.json")
        let a = ChecksumStore(url: file)
        a.record(Data([0xab, 0x01]), for: s)
        await a.saveIfDirty()
        #expect(FileManager.default.fileExists(atPath: file.path))
        let b = ChecksumStore(url: file)
        await b.load()
        #expect(b.checksum(for: s) == Data([0xab, 0x01]))
        #expect(b.count == 1)
    }

    @Test func missingFileLoadsEmpty() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChecksumStore(url: dir.appendingPathComponent("checksums.json"))
        await store.load()
        #expect(store.count == 0)
    }

    @Test func corruptFileIsQuarantinedNotOverwritten() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("checksums.json")
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: file)
        let store = ChecksumStore(url: file)
        await store.load()
        #expect(store.count == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let corrupt = try #require(names.first { $0.hasPrefix("checksums.json.corrupt-") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(corrupt)) == garbage)
        // Saving afterwards writes a fresh file and leaves the quarantined one intact.
        store.record(Data([1]), for: .init(volume: "v", relPath: "r", size: 1, mtime: 1, inode: 1))
        await store.saveIfDirty()
        #expect(try Data(contentsOf: dir.appendingPathComponent(corrupt)) == garbage)
        let reloaded = ChecksumStore(url: file)
        await reloaded.load()
        #expect(reloaded.count == 1)
    }

    @Test func saveIfDirtyIsNoOpWhenClean() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("checksums.json")
        await ChecksumStore(url: file).saveIfDirty()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func hasherMatchesKnownMD5() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: f)
        let md5 = try FileHasher().md5(f, onBytes: { _ in })
        #expect(md5.map { String(format: "%02x", $0) }.joined() == "5d41402abc4b2a76b9719d911017c592")
    }

    @Test func hasherCancelMidFileThrows() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: FileHasher.chunk * 2 + 10).write(to: f)
        let hasher = FileHasher()
        hasher.onChunkHashed = { [unowned hasher] _ in hasher.cancel() }
        #expect(throws: FileHasher.Cancelled.self) {
            try hasher.md5(f, onBytes: { _ in })
        }
        #expect(hasher.isCancelled)
    }
}
