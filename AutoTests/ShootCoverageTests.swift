import Foundation
import Testing
@testable import Auto

struct ShootCoverageTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var day2: Date { day1.addingTimeInterval(2 * 86_400) }

    private struct Env {
        let base: URL, card: URL, shoot: URL
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    private func env() throws -> Env {
        let base = try FixtureCard.makeTempDir("AutoCoverage")
        let fm = FileManager.default
        let e = Env(base: base, card: base.appendingPathComponent("card"), shoot: base.appendingPathComponent("work/shoot"))
        try fm.createDirectory(at: e.card, withIntermediateDirectories: true)
        try fm.createDirectory(at: e.shoot, withIntermediateDirectories: true)
        return e
    }

    private func card(_ e: Env, _ name: String, _ data: Data, date: Date) throws -> MediaFile {
        let url = e.card.appendingPathComponent(name)
        try data.write(to: url)
        return MediaFile(url: url, size: Int64(data.count), date: date, kind: .video, cameraID: "cam")
    }

    @discardableResult
    private func put(_ data: Data, _ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func check(_ files: [MediaFile], _ e: Env, copies: [CopiedFile] = [], cache: VerificationCache = VerificationCache()) async -> Set<URL> {
        await ShootCoverageChecker.run(files: files, shootFolder: e.shoot, sessionCopies: copies, cache: cache) { _ in }
    }

    @Test func completeWhenEveryDayFileVerified() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", Data(repeating: 1, count: 500), date: day1)
        let b = try card(e, "B.MP4", Data(repeating: 2, count: 600), date: day1)
        try put(Data(repeating: 1, count: 500), "A.MP4", in: e.shoot.appendingPathComponent("Video"))
        try put(Data(repeating: 2, count: 600), "B.MP4", in: e.shoot.appendingPathComponent("Video"))
        let inShoot = await check([a, b], e)
        let cov = ShootCoverage.compute(files: [a, b], day: day1, calendar: cal, inShoot: inShoot)
        #expect(cov.isComplete && cov.dayTotal == 2 && cov.dayInShoot == 2 && cov.notInShoot.isEmpty)
    }

    @Test func nameSizeMatchWithDifferentContentIsNotInShoot() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", Data(repeating: 1, count: 500), date: day1)
        try put(Data(repeating: 9, count: 500), "A.MP4", in: e.shoot)
        let inShoot = await check([a], e)
        #expect(inShoot.isEmpty)
        #expect(!ShootCoverage.compute(files: [a], day: day1, calendar: cal, inShoot: inShoot).isComplete)
    }

    @Test func copyElsewhereInWorkFolderDoesNotCount() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", Data(repeating: 1, count: 500), date: day1)
        try put(Data(repeating: 1, count: 500), "A.MP4", in: e.base.appendingPathComponent("work/other"))
        #expect(await check([a], e).isEmpty)
    }

    @Test func sessionCopyInsideShootCounts() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", Data(repeating: 1, count: 500), date: day1)
        let dest = try put(Data(repeating: 1, count: 500), "A.MP4", in: e.shoot)
        let outside = try put(Data(repeating: 1, count: 500), "A.MP4", in: e.base.appendingPathComponent("work/other"))
        let copy = CopiedFile(file: a, destination: dest, destinationModified: nil, preexisting: false)
        let out = CopiedFile(file: a, destination: outside, destinationModified: nil, preexisting: false)
        try FileManager.default.removeItem(at: dest)  // indexed copy gone; only the session copy names it
        #expect(await check([a], e, copies: [out]).isEmpty)
        try Data(repeating: 1, count: 500).write(to: dest)
        #expect(await check([a], e, copies: [copy]) == [a.url])
    }

    @Test func cacheHitSkipsHashing() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", Data(repeating: 1, count: 500), date: day1)
        let dest = try put(Data(repeating: 1, count: 500), "A.MP4", in: e.shoot)
        let cache = VerificationCache()
        let first = await check([a], e, cache: cache)
        #expect(first == [a.url])
        // Card file gone: only a cache hit can still verify it.
        try FileManager.default.removeItem(at: a.url)
        #expect(await check([a], e, cache: cache) == [a.url])
        #expect(await check([a], e, cache: VerificationCache()).isEmpty)
        _ = dest
    }

    @Test func otherDayFilesReportedInNotInShoot() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", Data(repeating: 1, count: 500), date: day1)
        let b = try card(e, "B.MP4", Data(repeating: 2, count: 600), date: day2)
        try put(Data(repeating: 1, count: 500), "A.MP4", in: e.shoot)
        let inShoot = await check([a, b], e)
        let cov = ShootCoverage.compute(files: [a, b], day: day1, calendar: cal, inShoot: inShoot)
        #expect(cov.isComplete)
        #expect(cov.notInShoot == [b])
    }

    @Test func emptyDayIsNotComplete() {
        let a = MediaFile(url: URL(fileURLWithPath: "/c/A.MP4"), size: 1, date: day1, kind: .video, cameraID: "cam")
        let cov = ShootCoverage.compute(files: [a], day: day2, calendar: cal, inShoot: [a.url])
        #expect(cov.dayTotal == 0 && !cov.isComplete)
    }

    @Test func matchesAcrossCameraFolders() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try card(e, "A.MP4", Data(repeating: 1, count: 500), date: day1)
        try put(Data(repeating: 1, count: 500), "A.MP4", in: e.shoot.appendingPathComponent("Video/OtherCam"))
        #expect(await check([a], e) == [a.url])
    }
}
