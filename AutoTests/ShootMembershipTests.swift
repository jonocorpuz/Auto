import Foundation
import Testing
@testable import Auto

struct ShootMembershipTests {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Env {
        let base: URL, card: URL
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        func shoot(_ name: String) -> URL { base.appendingPathComponent("work/\(name)") }
    }

    private func env() throws -> Env {
        let base = try FixtureCard.makeTempDir("AutoMembership")
        let e = Env(base: base, card: base.appendingPathComponent("card"))
        try FileManager.default.createDirectory(at: e.card, withIntermediateDirectories: true)
        return e
    }

    private func card(_ e: Env, _ name: String, _ byte: UInt8, size: Int = 500) throws -> MediaFile {
        let url = e.card.appendingPathComponent(name)
        try Data(repeating: byte, count: size).write(to: url)
        return MediaFile(url: url, size: Int64(size), date: day, kind: .video, cameraID: "cam")
    }

    @discardableResult
    private func put(_ byte: UInt8, _ name: String, in dir: URL, size: Int = 500) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: byte, count: size).write(to: url)
        return url
    }

    @MainActor private final class Sink {
        var results: [UUID: ShootMembership.Outcome] = [:]
        var order: [UUID] = []
        func add(_ id: UUID, _ o: ShootMembership.Outcome) { results[id] = o; order.append(id) }
    }

    private nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @MainActor private func run(_ files: [MediaFile], _ targets: [ShootMembership.Target], cache: VerificationCache = VerificationCache(),
                                makeVerifier: @escaping @Sendable () -> BackupVerifier = { BackupVerifier() }) async -> Sink {
        let sink = Sink()
        await ShootMembership.run(files: files, targets: targets, sessionCopies: [], cache: cache, cardVolumes: [], makeVerifier: makeVerifier) { sink.add($0, $1) }
        return sink
    }

    private func verifiedSet(_ o: ShootMembership.Outcome?) -> Set<URL> {
        if case .verified(let s, _) = o { return s } else { return [] }
    }

    @Test(arguments: [
        ("/w/Wedding", "/w/Wedding/Day1", true),
        ("/w/Wedding", "/w/Wedding", false),
        ("/w/Wedding", "/w/Wedding2", false),
        ("/w/Wedding/", "/w/Wedding/A/../B", true),
    ])
    func nestedFolders(parent: String, other: String, isNested: Bool) {
        let r = ShootMembership.nested(in: URL(fileURLWithPath: parent), among: [URL(fileURLWithPath: other)])
        #expect((r.count == 1) == isNested)
    }

    @Test @MainActor func identicalCopyInTwoShootsVerifiedInBoth() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot("S1")); try put(1, "A.MP4", in: e.shoot("S2"))
        let t1 = ShootMembership.Target(id: UUID(), folder: e.shoot("S1"))
        let t2 = ShootMembership.Target(id: UUID(), folder: e.shoot("S2"))
        let s = await run([a], [t1, t2])
        #expect(verifiedSet(s.results[t1.id]) == [a.url])
        #expect(verifiedSet(s.results[t2.id]) == [a.url])
        #expect(s.order == [t1.id, t2.id])
    }

    @Test @MainActor func nameSizeMatchDifferentContentNotMember() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(9, "A.MP4", in: e.shoot("S1"))
        let t = ShootMembership.Target(id: UUID(), folder: e.shoot("S1"))
        let s = await run([a], [t])
        #expect(s.results[t.id] == .verified([], copies: [:]))
    }

    @Test @MainActor func nestedCopyCountsOnlyForChild() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        let child = e.shoot("Parent/Child")
        try put(1, "A.MP4", in: child)
        let parent = ShootMembership.Target(id: UUID(), folder: e.shoot("Parent"))
        let kid = ShootMembership.Target(id: UUID(), folder: child)
        let s = await run([a], [parent, kid])
        #expect(verifiedSet(s.results[parent.id]).isEmpty)
        #expect(verifiedSet(s.results[kid.id]) == [a.url])
    }

    @Test @MainActor func unreadableShootFailsAndNextShootStillChecked() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot("S2"))
        let bad = ShootMembership.Target(id: UUID(), folder: e.shoot("Missing"))
        let good = ShootMembership.Target(id: UUID(), folder: e.shoot("S2"))
        let s = await run([a], [bad, good])
        if case .failed = s.results[bad.id] {} else { Issue.record("expected failure") }
        #expect(verifiedSet(s.results[good.id]) == [a.url])
    }

    @Test @MainActor func cancelMidRunReportsNothingForCancelledShoot() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot("S1")); try put(1, "A.MP4", in: e.shoot("S2"))
        let t1 = ShootMembership.Target(id: UUID(), folder: e.shoot("S1"))
        let t2 = ShootMembership.Target(id: UUID(), folder: e.shoot("S2"))
        let s = await run([a], [t1, t2], makeVerifier: {
            let v = BackupVerifier()
            v.onChunkHashed = { [unowned v] _ in v.cancel() }
            return v
        })
        #expect(s.order.isEmpty)
    }

    @MainActor private final class TaskBox { var task: Task<Void, Never>? }

    @Test @MainActor func cancelInsideFirstResultReportsOnlyFirstShoot() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot("S1")); try put(1, "A.MP4", in: e.shoot("S2"))
        let t1 = ShootMembership.Target(id: UUID(), folder: e.shoot("S1"))
        let t2 = ShootMembership.Target(id: UUID(), folder: e.shoot("S2"))
        let sink = Sink()
        let box = TaskBox()
        let task = Task {
            await ShootMembership.run(files: [a], targets: [t1, t2], sessionCopies: [], cache: VerificationCache(), cardVolumes: []) { id, o in
                sink.add(id, o)
                box.task?.cancel()
            }
        }
        box.task = task
        await task.value
        #expect(sink.order == [t1.id])
    }

    @Test func nestedResolvesSymlinks() throws {
        let e = try env(); defer { e.cleanup() }
        let real = e.shoot("Real/Child")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = e.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.shoot("Real"))
        // A child reached through a symlink to the parent is still nested in the parent.
        #expect(ShootMembership.nested(in: e.shoot("Real"), among: [link.appendingPathComponent("Child")]).count == 1)
    }

    @Test @MainActor func secondRunIsCacheHitNoHashing() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot("S1"))
        let t = ShootMembership.Target(id: UUID(), folder: e.shoot("S1"))
        let cache = VerificationCache()
        let counter = Counter()
        let make: @Sendable () -> BackupVerifier = {
            let v = BackupVerifier(); v.onChunkHashed = { _ in counter.bump() }; return v
        }
        _ = await run([a], [t], cache: cache, makeVerifier: make)
        let first = counter.value
        #expect(first > 0)
        let s = await run([a], [t], cache: cache, makeVerifier: make)
        #expect(counter.value == first)
        #expect(verifiedSet(s.results[t.id]) == [a.url])
    }

    @Test @MainActor func runsOffMain() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot("S1"))
        _ = await run([a], [ShootMembership.Target(id: UUID(), folder: e.shoot("S1"))])
        #expect(MainThreadProbe.shared.everRanOnMain("ShootMembership.run") == false)
    }

    @Test @MainActor func readOnly() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot("S1")); try put(2, "B.MP4", in: e.shoot("S1/Sub"))
        func snapshot() -> [String] {
            let en = FileManager.default.enumerator(at: e.base, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            return (en?.allObjects as? [URL] ?? []).map {
                let v = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return "\($0.path)|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }.sorted()
        }
        let before = snapshot()
        _ = await run([a], [ShootMembership.Target(id: UUID(), folder: e.shoot("S1"))])
        #expect(snapshot() == before)
    }
}
