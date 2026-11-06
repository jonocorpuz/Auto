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

    func plan(_ report: ShootSyncReport, cache: ChecksumStore = ChecksumStore(url: nil)) async throws -> SyncPlan {
        try await ShootSyncPlanner.plan(report: report, cache: cache, shootID: shootID)
    }

    func leftovers(_ root: URL) -> [String] {
        ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).filter { $0.hasSuffix(".auto-partial") }
    }

    func cleanup() { try? FileManager.default.removeItem(at: top) }
}

@Suite struct ShootSyncPlanTests {
    private func md5(_ text: String) -> Data { Data(Insecure.MD5.hash(data: Data(text.utf8))) }

    private func job(_ root: URL, size: Int64) -> CopyJob {
        CopyJob(file: MediaFile.syncSource(url: root.appendingPathComponent("f.mov"), size: size, modified: Date()),
                destDir: root, root: root, onCollision: .skip)
    }

    @Test func plansOnlyMissingFilesNeverConflicts() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "D1/only-a.mov", "aaaa")
        try r.put(r.b, "only-b.mov", "bb")
        try r.put(r.a, "clash.mov", "one")
        try r.put(r.b, "clash.mov", "two")      // same size, different content
        try r.put(r.a, "same.mov", "same"); try r.put(r.b, "same.mov", "same")
        let report = try #require(await r.check())
        #expect(report.conflicts.count == 1)

        let plan = try await r.plan(report)
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
        let plan = try await r.plan(report)
        let job = try #require(plan.jobs.first)
        #expect(plan.jobs.count == 1)
        #expect(job.root == r.b)
        #expect(job.destDir == r.b.appendingPathComponent("D1", isDirectory: true).appendingPathComponent("Cam", isDirectory: true))
        #expect(job.onCollision == .skip)
        #expect(job.file.url == r.a.appendingPathComponent("D1/Cam/clip.mov"))
        #expect(job.file.size == 4)
        // A file on only one copy was never hashed, so there is no known checksum.
        #expect(job.expectedChecksum == nil)
        #expect(ShootPlanner.relativeComponents(job.destDir, to: r.b) == ["D1", "Cam"])
    }

    @Test func expectedChecksumFromStoreWhenKnown() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        let report = try #require(await r.check())
        let store = ChecksumStore(url: nil)
        let source = r.a.appendingPathComponent("clip.mov")
        store.record(md5("data"), for: try #require(ChecksumStore.stamp(source)))
        let plan = try await r.plan(report, cache: store)
        #expect(plan.jobs.first?.expectedChecksum == md5("data"))
    }

    @Test func checkedDigestInReportBeatsStore() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        let c = r.top.appendingPathComponent("C", isDirectory: true)
        try r.makeRoot(c, id: r.shootID)
        try r.put(r.a, "clip.mov", "data"); try r.put(c, "clip.mov", "data")
        let report = try #require(await ShootSyncChecker.run(copies: [r.a, c, r.b], cache: ChecksumStore(url: nil)))
        #expect(report.missing[r.b]?.first?.checksum == md5("data"))
        let plan = try await r.plan(report, cache: ChecksumStore(url: nil))   // empty store
        #expect(plan.jobs.first?.expectedChecksum == md5("data"))
    }

    @Test func refusesSizeDepthReport() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        var report = try #require(await r.check())
        report.depth = .sizes
        await #expect(throws: SyncPlanError.notChecksumChecked) { try await r.plan(report) }
    }

    @Test func refusesNotCheckedReport() async throws {
        var report = ShootSyncReport(copies: [URL(fileURLWithPath: "/x")])
        report.notChecked = .singleCopy
        report.depth = .checksums
        await #expect(throws: SyncPlanError.notChecked) {
            try await ShootSyncPlanner.plan(report: report, cache: ChecksumStore(url: nil), shootID: UUID())
        }
    }

    @Test func refusesDestinationWithOtherShootID() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        let report = try #require(await r.check())
        try FileManager.default.removeItem(at: r.b.appendingPathComponent(ShootSidecar.fileName))
        try r.makeRoot(r.b, id: UUID())
        await #expect(throws: SyncPlanError.destinationNotThisShoot(r.b.path)) { try await r.plan(report) }
    }

    @Test func refusesDestinationWithoutSidecar() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        let report = try #require(await r.check())
        try FileManager.default.removeItem(at: r.b.appendingPathComponent(ShootSidecar.fileName))
        await #expect(throws: SyncPlanError.destinationNotThisShoot(r.b.path)) { try await r.plan(report) }
    }

    @Test func refusesSourceWithOtherShootID() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clip.mov", "data")
        let report = try #require(await r.check())
        try FileManager.default.removeItem(at: r.a.appendingPathComponent(ShootSidecar.fileName))
        try r.makeRoot(r.a, id: UUID())
        await #expect(throws: SyncPlanError.destinationNotThisShoot(r.a.path)) { try await r.plan(report) }
    }

    @Test func refusesSourceOutsideReportCopiesOrSameAsDestination() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        let stranger = r.top.appendingPathComponent("Stranger", isDirectory: true)
        try r.makeRoot(stranger, id: r.shootID)
        var report = ShootSyncReport(copies: [r.a, r.b])
        report.depth = .checksums
        report.missing[r.b] = [SyncMissing(file: SyncFile(relPath: "x.mov", size: 1), source: stranger)]
        await #expect(throws: SyncPlanError.destinationNotThisShoot(stranger.path)) { try await r.plan(report) }
        report.missing[r.b] = [SyncMissing(file: SyncFile(relPath: "x.mov", size: 1), source: r.b)]
        await #expect(throws: SyncPlanError.destinationNotThisShoot(r.b.path)) { try await r.plan(report) }
    }

    @Test func refusesUnsafeRelativePaths() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        for rel in ["../x", "D1/../../x", "/abs", "a//b", "./x", "", "D1/.."] {
            var report = ShootSyncReport(copies: [r.a, r.b])
            report.depth = .checksums
            report.missing[r.b] = [SyncMissing(file: SyncFile(relPath: rel, size: 1), source: r.a)]
            await #expect(throws: SyncPlanError.unsafePath(rel)) { try await r.plan(report) }
        }
    }

    @Test func reusesExistingFolderWithDifferentCase() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.b, "d1/cam/y.mov", "yy")
        try r.put(r.a, "D1/Cam/x.mov", "xxx")
        let report = try #require(await r.check())
        let plan = try await r.plan(report)
        let job = try #require(plan.jobs.first { $0.file.name == "x.mov" })
        #expect(job.destDir == r.b.appendingPathComponent("d1", isDirectory: true).appendingPathComponent("cam", isDirectory: true))
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(r.read(r.b, "d1/cam/x.mov") == "xxx")
        let top = try FileManager.default.contentsOfDirectory(atPath: r.b.path).filter { $0.lowercased() == "d1" }
        #expect(top == ["d1"])
    }

    @Test func checkSpaceThrowsNamingTheDriveWithHeadroom() async throws {
        let a = URL(fileURLWithPath: "/Volumes/T7-A/Shoot"), b = URL(fileURLWithPath: "/Volumes/T7-B/Shoot")
        let plan = SyncPlan(jobs: [job(a, size: 100), job(b, size: 500)], bytesByDestination: [a: 100, b: 500])
        let need = ShootSyncPlanner.volumeHeadroom + ShootSyncPlanner.fileRounding
        let free: @Sendable (URL) -> Int64? = { $0 == a ? need : need - 1 }
        let name: @Sendable (URL) -> String = { $0 == a ? "T7-A" : "T7-B" }
        do {
            try await ShootSyncPlanner.checkSpace(plan, free: free, driveName: name)
            Issue.record("expected a throw")
        } catch let error as SyncPlanError {
            #expect(error == .insufficientSpace(drive: "T7-B", needed: need, free: need - 1))
            #expect(error.localizedDescription.contains("T7-B"))
        }
        try await ShootSyncPlanner.checkSpace(plan, free: { _ in need }, driveName: name)
        await #expect(throws: SyncPlanError.spaceUnknown(drive: "T7-A")) {
            try await ShootSyncPlanner.checkSpace(plan, free: { _ in nil }, driveName: name)
        }
    }

    @Test func checkSpaceRoundsFilesUpAndSumsPerVolume() async throws {
        let a = URL(fileURLWithPath: "/Volumes/Same/One"), b = URL(fileURLWithPath: "/Volumes/Same/Two")
        // Same fake path prefix is not the same volume here (no real mount), so use one root, two files.
        let plan = SyncPlan(jobs: [job(a, size: ShootSyncPlanner.fileRounding + 1), job(a, size: 1)], bytesByDestination: [a: 0])
        let need = ShootSyncPlanner.volumeHeadroom + 3 * ShootSyncPlanner.fileRounding
        try await ShootSyncPlanner.checkSpace(plan, free: { _ in need }, driveName: { _ in "Same" })
        await #expect(throws: SyncPlanError.insufficientSpace(drive: "Same", needed: need, free: need - 1)) {
            try await ShootSyncPlanner.checkSpace(plan, free: { _ in need - 1 }, driveName: { _ in "Same" })
        }
        _ = b
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

        let plan = try await r.plan(report, cache: cache)
        try await ShootSyncPlanner.checkSpace(plan, free: { _ in Int64.max })
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied.count == 3)
        for c in outcome.copied { cache.record(c) }

        #expect(r.read(r.b, "D1/Cam/one.mov") == "one one")
        #expect(r.read(r.b, "two.mov") == "two")
        #expect(r.read(r.a, "D2/three.mov") == "three three")

        let again = try #require(await r.check(deep: true, cache: ChecksumStore(url: nil)))
        #expect(again.isInSync)
        #expect(r.exists(r.a, "both.mov") && r.exists(r.b, "both.mov"))
    }

    @Test func conflictFileIsNeverCopiedOrChanged() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "clash.mov", "one"); try r.put(r.b, "clash.mov", "two")
        try r.put(r.a, "extra.mov", "extra")
        let report = try #require(await r.check())
        let plan = try await r.plan(report)
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
        let plan = try await r.plan(report, cache: store)
        #expect(plan.jobs.first?.expectedChecksum == md5("before"))

        try Data("AFTER!".utf8).write(to: source)   // changed after the check
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(!r.exists(r.b, "D1/clip.mov"))
        #expect(r.leftovers(r.b).isEmpty)
        #expect(r.read(r.a, "D1/clip.mov") == "AFTER!")
    }

    @Test func intruderAtDestinationIsNeverOverwritten() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "one.mov", "one")
        let report = try #require(await r.check())
        let plan = try await r.plan(report)
        try r.put(r.b, "one.mov", "intruder")       // appears after planning
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.destinationExists.errorDescription)
        #expect(r.read(r.b, "one.mov") == "intruder")
        #expect(!r.exists(r.b, "one 2.mov"))
        #expect(r.leftovers(r.b).isEmpty)
        #expect(r.read(r.a, "one.mov") == "one")
    }

    @Test func destinationRootRemovedAfterPlanIsNotRecreated() async throws {
        let r = try PlanRoots(); defer { r.cleanup() }
        try r.put(r.a, "D1/one.mov", "one")
        let report = try #require(await r.check())
        let plan = try await r.plan(report)
        try FileManager.default.removeItem(at: r.b)
        let outcome = await CopyEngine().run(plan.jobs) { _ in }
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures.first?.reason == CopyEngine.CopyError.rootMissing.errorDescription)
        #expect(!FileManager.default.fileExists(atPath: r.b.path))
    }
}
