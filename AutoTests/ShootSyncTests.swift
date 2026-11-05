import Foundation
import Testing
@testable import Auto

private nonisolated final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { all.count }
}

private struct Roots {
    let top: URL
    let a: URL, b: URL, c: URL

    init() throws {
        top = try FixtureCard.makeTempDir("ShootSync")
        a = top.appendingPathComponent("A", isDirectory: true)
        b = top.appendingPathComponent("B", isDirectory: true)
        c = top.appendingPathComponent("C", isDirectory: true)
        for r in [a, b, c] {
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: r.appendingPathComponent(ShootSidecar.fileName))
        }
    }

    func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: top) }
}

@Suite struct ShootSyncTests {
    private func check(_ copies: [URL], cache: ChecksumStore = ChecksumStore(url: nil), hasher: FileHasher = FileHasher(),
                       deep: Bool = false) async -> ShootSyncReport? {
        await ShootSyncChecker.run(copies: copies, cache: cache, hasher: hasher, deep: deep)
    }

    @Test func identicalCopiesAreInSync() async throws {
        let r = try Roots(); defer { r.cleanup() }
        for root in [r.a, r.b] { try r.put(root, "D1/clip.mov", "same"); try r.put(root, "notes.txt", "hi") }
        let report = try #require(await check([r.a, r.b]))
        #expect(report.isInSync)
        #expect(report.fileCount == 2)
        #expect(report.depth == .checksums)
    }

    @Test func fileOnlyOnAIsMissingOnB() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        let report = try #require(await check([r.a, r.b]))
        #expect(report.isOutOfSync)
        let missing = try #require(report.missing[r.b]?.first)
        #expect(missing.file.relPath == "clip.mov")
        #expect(missing.source == r.a)
        #expect(report.missing[r.a]?.isEmpty == true)
    }

    @Test func sameSizeDifferentBytesIsContentConflict() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "aaaa")
        try r.put(r.b, "clip.mov", "bbbb")
        let report = try #require(await check([r.a, r.b]))
        #expect(report.conflicts.map(\.kind) == [.content])
        #expect(report.missing.values.allSatisfy { $0.isEmpty })
        #expect(!report.isInSync)
    }

    @Test func sizeDifferenceIsSizeConflict() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "aaaa")
        try r.put(r.b, "clip.mov", "aaaaaa")
        let report = try #require(await check([r.a, r.b]))
        #expect(report.conflicts.map(\.kind) == [.size])
        #expect(report.conflicts.first?.copies == [r.a, r.b])
    }

    @Test func conflictBetweenAAndBIsNotMissingOnC() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "aaaa")
        try r.put(r.b, "clip.mov", "bbbb")
        let report = try #require(await check([r.a, r.b, r.c]))
        #expect(report.conflicts.map(\.kind) == [.content])
        #expect(report.missing[r.c]?.isEmpty == true)

        // Same with a size disagreement.
        try r.put(r.b, "clip.mov", "bbbbbb")
        let sized = try #require(await check([r.a, r.b, r.c]))
        #expect(sized.conflicts.map(\.kind) == [.size])
        #expect(sized.missing[r.c]?.isEmpty == true)
    }

    @Test func fileOnTwoCopiesAbsentOnThirdIsMissingWhenAgreeing() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "same")
        try r.put(r.b, "clip.mov", "same")
        let report = try #require(await check([r.a, r.b, r.c]))
        #expect(report.missing[r.c]?.first?.source == r.a)
        #expect(report.conflicts.isEmpty)
    }

    @Test func hiddenSidecarAndPartialFilesAreIgnored() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "same")
        try r.put(r.b, "clip.mov", "same")
        try r.put(r.a, ".DS_Store", "x")
        try r.put(r.a, "._clip.mov", "x")
        try r.put(r.a, ".clip.mov.\(UUID().uuidString).auto-partial", "half")
        try r.put(r.a, "D1/.hidden", "x")
        try r.put(r.b, ".auto-shoot-123.tmp", "x")
        let report = try #require(await check([r.a, r.b]))
        #expect(report.isInSync)
        #expect(report.fileCount == 1)
    }

    @Test func nestedShootFolderIsIgnoredOnBothSides() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "same")
        try r.put(r.b, "clip.mov", "same")
        try r.put(r.a, "Nested/inner.mov", "only a")
        try r.put(r.a, "Nested/\(ShootSidecar.fileName)", "{}")
        try r.put(r.b, "Nested/other.mov", "only b")
        try r.put(r.b, "Nested/\(ShootSidecar.fileName)", "{}")
        let report = try #require(await check([r.a, r.b]))
        #expect(report.isInSync)
        #expect(report.fileCount == 1)
    }

    @Test func caseAndUnicodeSpellingsMatch() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "D1/Clip.MOV", "same")
        try r.put(r.b, "d1/clip.mov", "same")
        try r.put(r.a, "caf\u{e9}.mov", "accent")
        try r.put(r.b, "cafe\u{301}.mov", "accent")
        let report = try #require(await check([r.a, r.b]))
        #expect(report.isInSync)
        #expect(report.fileCount == 2)
    }

    @Test func caseCollisionWithinOneCopyIsConflict() throws {
        let a = URL(fileURLWithPath: "/A"), b = URL(fileURLWithPath: "/B")
        let key = ShootSyncChecker.foldedKey("Clip.mov")
        let colliding = InventoryEntry(url: a.appendingPathComponent("Clip.mov"), relPath: "Clip.mov", size: 4, collisions: ["clip.mov"])
        let other = InventoryEntry(url: b.appendingPathComponent("clip.mov"), relPath: "clip.mov", size: 4)
        let result = ShootSyncChecker.compare([a: [key: colliding], b: [key: other]], order: [a, b])
        #expect(result.report.conflicts.map(\.kind) == [.caseCollision])
        #expect(result.report.conflicts.first?.copies == [a])
        #expect(result.toHash.isEmpty)
        #expect(result.report.missing.values.allSatisfy { $0.isEmpty })
    }

    @Test func inventoryKeysAreFolded() throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "D1/Clip.MOV", "x")
        let inv = try ShootSyncChecker.inventory(r.a)
        #expect(inv["d1/clip.mov"]?.relPath == "D1/Clip.MOV")
        #expect(inv.count == 1)
    }

    @Test func secondRunIsAllCacheHitsAndDeepRehashes() async throws {
        let r = try Roots(); defer { r.cleanup() }
        for root in [r.a, r.b] { try r.put(root, "one.mov", "11"); try r.put(root, "two.mov", "22") }
        let cache = ChecksumStore(url: nil)

        let h1 = FileHasher(); let t1 = Tally()
        h1.onFileHashed = { t1.add($0.path) }
        #expect(await check([r.a, r.b], cache: cache, hasher: h1)?.isInSync == true)
        #expect(t1.count == 4)

        let h2 = FileHasher(); let t2 = Tally()
        h2.onFileHashed = { t2.add($0.path) }
        #expect(await check([r.a, r.b], cache: cache, hasher: h2)?.isInSync == true)
        #expect(t2.count == 0)

        let h3 = FileHasher(); let t3 = Tally()
        h3.onFileHashed = { t3.add($0.path) }
        #expect(await check([r.a, r.b], cache: cache, hasher: h3, deep: true)?.isInSync == true)
        #expect(t3.count == 4)
    }

    @Test func cancellationReturnsNil() async throws {
        let r = try Roots(); defer { r.cleanup() }
        for root in [r.a, r.b] { try r.put(root, "one.mov", "11"); try r.put(root, "two.mov", "22") }
        let hasher = FileHasher()
        hasher.onChunkHashed = { _ in hasher.cancel() }
        let report = await check([r.a, r.b], hasher: hasher)
        #expect(report == nil)

        let task = Task { await ShootSyncChecker.run(copies: [r.a, r.b], cache: ChecksumStore(url: nil)) }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func sizePassFiresBeforeHashing() async throws {
        let r = try Roots(); defer { r.cleanup() }
        for root in [r.a, r.b] { try r.put(root, "one.mov", "11") }
        let log = Tally()
        let hasher = FileHasher()
        hasher.onFileHashed = { _ in log.add("hash") }
        let report = await ShootSyncChecker.run(copies: [r.a, r.b], cache: ChecksumStore(url: nil), hasher: hasher,
                                                onSizePass: { rep in
            log.add(rep.depth == .sizes ? "size" : "other")
        })
        #expect(report?.depth == .checksums)
        #expect(log.all == ["size", "hash", "hash"])
    }

    @Test func runDoesNotExecuteOnMainThread() async throws {
        let r = try Roots(); defer { r.cleanup() }
        for root in [r.a, r.b] { try r.put(root, "one.mov", "11") }
        _ = await check([r.a, r.b])
        #expect(MainThreadProbe.shared.everRanOnMain("ShootSyncChecker.run") == false)
    }

    @Test func unreadableRootIsNotChecked() async throws {
        let r = try Roots(); defer { r.cleanup() }
        let gone = r.top.appendingPathComponent("Gone")
        let report = try #require(await check([r.a, gone]))
        guard case .copyUnreadable(let url, _)? = report.notChecked else {
            Issue.record("expected copyUnreadable"); return
        }
        #expect(url == gone)
        #expect(!report.isInSync && !report.isOutOfSync)
    }

    @Test func singleCopyIsNotChecked() async throws {
        let r = try Roots(); defer { r.cleanup() }
        let report = try #require(await check([r.a]))
        #expect(report.notChecked == .singleCopy)
    }

    @Test func checkNeverWritesIntoCopies() async throws {
        let r = try Roots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        func listing(_ root: URL) -> [String] {
            ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).sorted()
        }
        let before = (listing(r.a), listing(r.b))
        _ = await check([r.a, r.b])
        #expect(listing(r.a) == before.0)
        #expect(listing(r.b) == before.1)
    }
}
