import CryptoKit
import Foundation
import Testing
@testable import Auto

private final class PlanRoots {
    let top: URL
    let a: URL, b: URL
    let shootID = UUID()

    init() throws {
        top = try FixtureCard.makeTempDir("ShootSyncPlan")
        a = top.appendingPathComponent("A", isDirectory: true)
        b = top.appendingPathComponent("B", isDirectory: true)
        for r in [a, b] { try makeRoot(r, id: shootID) }
    }

    func makeRoot(_ root: URL, id: UUID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sidecar = ShootSidecar(version: ShootSidecar.currentVersion, id: id, name: "Shoot", day: "2025-01-01", createdAt: Date())
        try ShootSidecar.encode(sidecar).write(to: root.appendingPathComponent(ShootSidecar.fileName))
    }

    func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).flatMap { String(data: $0, encoding: .utf8) }
    }

    func exists(_ root: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path)
    }

    func check(deep: Bool = false, cache: ChecksumStore = ChecksumStore(url: nil)) async -> ShootSyncReport? {
        await ShootSyncChecker.run(copies: [a, b], cache: cache, deep: deep)
    }

    func cleanup() { try? FileManager.default.removeItem(at: top) }
}

@Suite struct ShootSyncPlanTests {
    private func md5(_ text: String) -> Data { Data(Insecure.MD5.hash(data: Data(text.utf8))) }

    @Test func plansOnlyMissingFilesNeverConflicts() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "D1/only-a.mov", "aaaa")
        try r.put(r.b, "only-b.mov", "bb")
        try r.put(r.a, "clash.mov", "one")
        try r.put(r.b, "clash.mov", "two")      // same size, different content
        try r.put(r.a, "same.mov", "same"); try r.put(r.b, "same.mov", "same")
        let report = try #require(await r.check())
        #expect(report.conflicts.count == 1)

        let plan = try ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: r.shootID)
        #expect(plan.jobs.count == 2)
        #expect(Set(plan.jobs.map(\.file.name)) == ["only-a.mov", "only-b.mov"])
        #expect(!plan.jobs.contains { $0.file.name == "clash.mov" })
        #expect(plan.bytesByDestination[r.b] == 4)
        #expect(plan.bytesByDestination[r.a] == 2)
    }

    @Test func jobShape() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "D1/Cam/clip.mov", "data")
        let report = try #require(await r.check())
        let plan = try ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: r.shootID)
        let job = try #require(plan.jobs.first)
        #expect(plan.jobs.count == 1)
        #expect(job.root == r.b)
        #expect(job.destDir == r.b.appendingPathComponent("D1", isDirectory: true).appendingPathComponent("Cam", isDirectory: true))
        #expect(job.onCollision == .skip)
        #expect(job.file.url == r.a.appendingPathComponent("D1/Cam/clip.mov"))
        #expect(job.file.size == 4)
        #expect(job.expectedChecksum == nil)
        // Passes the engine's lexical root check.
        #expect(ShootPlanner.relativeComponents(job.destDir, to: r.b) == ["D1", "Cam"])
    }

    @Test func expectedChecksumFromStoreWhenKnown() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        let report = try #require(await r.check())
        let store = ChecksumStore(url: nil)
        let source = r.a.appendingPathComponent("clip.mov")
        store.record(md5("data"), for: try #require(ChecksumStore.stamp(source)))
        let plan = try ShootSyncPlanner.plan(report: report, cache: store, shootID: r.shootID)
        #expect(plan.jobs.first?.expectedChecksum == md5("data"))
    }

    @Test func refusesSizeDepthReport() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        var report = try #require(await r.check())
        report.depth = .sizes
        #expect(throws: SyncPlanError.notChecksumChecked) {
            try ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: r.shootID)
        }
    }

    @Test func refusesNotCheckedReport() throws {
        var report = ShootSyncReport(copies: [URL(fileURLWithPath: "/x")])
        report.notChecked = .singleCopy
        report.depth = .checksums
        #expect(throws: SyncPlanError.notChecked) {
            try ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: UUID())
        }
    }

    @Test func refusesDestinationWithOtherShootID() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        let report = try #require(await r.check())
        try FileManager.default.removeItem(at: r.b.appendingPathComponent(ShootSidecar.fileName))
        try r.makeRoot(r.b, id: UUID())
        #expect(throws: SyncPlanError.destinationNotThisShoot(r.b.path)) {
            try ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: r.shootID)
        }
    }

    @Test func refusesUnsafeRelativePath() throws {
        let a = URL(fileURLWithPath: "/tmp/never-a"), b = URL(fileURLWithPath: "/tmp/never-b")
        var report = ShootSyncReport(copies: [a, b])
        report.depth = .checksums
        report.missing[b] = [SyncMissing(file: SyncFile(relPath: "../escape.mov", size: 1), source: a)]
        #expect(throws: SyncPlanError.self) {
            try ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: UUID())
        }
    }

    @Test func checkSpaceThrowsNamingTheDrive() throws {
        let a = URL(fileURLWithPath: "/Volumes/T7-A/Shoot"), b = URL(fileURLWithPath: "/Volumes/T7-B/Shoot")
        let plan = SyncPlan(jobs: [], bytesByDestination: [a: 100, b: 500])
        let free: (URL) -> Int64? = { $0 == a ? 1_000 : 200 }
        let name: (URL) -> String = { $0 == a ? "T7-A" : "T7-B" }
        do {
            try ShootSyncPlanner.checkSpace(plan, free: free, driveName: name)
            Issue.record("expected a throw")
        } catch let error as SyncPlanError {
            #expect(error == .insufficientSpace(drive: "T7-B", needed: 500, free: 200))
            #expect(error.localizedDescription.contains("T7-B"))
        }
        // Enough room everywhere passes; unknown free space fails closed.
        try ShootSyncPlanner.checkSpace(plan, free: { _ in 10_000 }, driveName: name)
        #expect(throws: SyncPlanError.spaceUnknown(drive: "T7-A")) {
            try ShootSyncPlanner.checkSpace(plan, free: { _ in nil }, driveName: name)
        }
    }

    @Test func endToEndPlanCopyThenInSync() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "D1/Cam/one.mov", "one one")
        try r.put(r.a, "two.mov", "two")
        try r.put(r.b, "D2/three.mov", "three three")
        try r.put(r.a, "both.mov", "both"); try r.put(r.b, "both.mov", "both")
        let cache = ChecksumStore(url: nil)
        let report = try #require(await r.check(cache: cache))
        #expect(report.isOutOfSync)

        let plan = try ShootSyncPlanner.plan(report: report, cache: cache, shootID: r.shootID)
        try ShootSyncPlanner.checkSpace(plan, free: { _ in Int64.max })
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.count == 3)
        for c in outcome.copied { cache.record(c) }

        #expect(r.read(r.b, "D1/Cam/one.mov") == "one one")
        #expect(r.read(r.b, "two.mov") == "two")
        #expect(r.read(r.a, "D2/three.mov") == "three three")

        let again = try #require(await r.check(deep: true, cache: ChecksumStore(url: nil)))
        #expect(again.isInSync)
        // Nothing was removed.
        #expect(r.exists(r.a, "both.mov") && r.exists(r.b, "both.mov"))
    }

    @Test func conflictFileIsNeverCopiedOrChanged() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clash.mov", "one"); try r.put(r.b, "clash.mov", "two")
        try r.put(r.a, "extra.mov", "extra")
        let report = try #require(await r.check())
        let plan = try ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: r.shootID)
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(r.read(r.a, "clash.mov") == "one")
        #expect(r.read(r.b, "clash.mov") == "two")
        #expect(r.read(r.b, "extra.mov") == "extra")
        let names = try FileManager.default.contentsOfDirectory(atPath: r.b.path)
        #expect(!names.contains { $0.hasPrefix("clash") && $0 != "clash.mov" })
    }

    @Test func sourceChangedAfterCheckLeavesNothingBehind() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "D1/clip.mov", "before")
        let report = try #require(await r.check())
        let store = ChecksumStore(url: nil)
        let source = r.a.appendingPathComponent("D1/clip.mov")
        store.record(md5("before"), for: try #require(ChecksumStore.stamp(source)))
        let plan = try ShootSyncPlanner.plan(report: report, cache: store, shootID: r.shootID)
        #expect(plan.jobs.first?.expectedChecksum == md5("before"))

        try Data("AFTER!".utf8).write(to: source)   // changed after the check
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(!r.exists(r.b, "D1/clip.mov"))
        let leftovers = (FileManager.default.enumerator(atPath: r.b.path)?.allObjects as? [String]) ?? []
        #expect(!leftovers.contains { $0.hasSuffix(".auto-partial") })
        #expect(r.read(r.a, "D1/clip.mov") == "AFTER!")
    }
}
