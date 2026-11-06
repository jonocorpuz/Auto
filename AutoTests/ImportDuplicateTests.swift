import Foundation
import Testing
@testable import Auto

struct ImportDuplicateTests {
    private struct Env {
        let base: URL, source: URL, shoot: URL
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    private func env() throws -> Env {
        let base = try FixtureCard.makeTempDir("AutoImportDup")
        let e = Env(base: base, source: base.appendingPathComponent("drive"), shoot: base.appendingPathComponent("work/shoot"))
        try FileManager.default.createDirectory(at: e.source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: e.shoot, withIntermediateDirectories: true)
        return e
    }

    private func source(_ e: Env, _ name: String, _ byte: UInt8, size: Int = 500) throws -> MediaFile {
        let url = e.source.appendingPathComponent(name)
        try Data(repeating: byte, count: size).write(to: url)
        return MediaFile(url: url, size: Int64(size), date: Date(), kind: .video, cameraID: "import")
    }

    private func put(_ byte: UInt8, _ name: String, in dir: URL, size: Int = 500) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: byte, count: size).write(to: dir.appendingPathComponent(name))
    }

    private func find(_ files: [MediaFile], _ e: Env) async throws -> Set<URL> {
        try await ImportDuplicateFinder.find(files, shootFolder: e.shoot, cache: VerificationCache(), cardVolumes: []) { _ in }
    }

    @Test func sameNameAndSizeDifferentBytesIsNotDuplicate() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try source(e, "A.MP4", 1)
        try put(9, "A.MP4", in: e.shoot.appendingPathComponent("Video/FX3"))
        #expect(try await find([a], e).isEmpty)
    }

    @Test func identicalBytesInAnotherSubfolderIsDuplicate() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try source(e, "A.MP4", 1)
        let b = try source(e, "B.MP4", 2)
        try put(1, "A.MP4", in: e.shoot.appendingPathComponent("Video/FX3/Day 2"))
        #expect(try await find([a, b], e) == [a.url])
    }

    @Test func identicalBytesInRejectsIsDuplicate() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try source(e, "IMG_1.ARW", 3)
        try put(3, "IMG_1.ARW", in: e.shoot.appendingPathComponent("Photo/A7/_Rejects"))
        #expect(try await find([a], e) == [a.url])
    }

    @Test func differentNameSameBytesIsNotNominated() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try source(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot.appendingPathComponent("Video"))
        // Same name is what nominates; a different name must not match.
        let b = try source(e, "B.MP4", 1)
        #expect(try await find([a, b], e) == [a.url])
    }

    @Test func emptyInputIsNoDuplicates() async throws {
        let e = try env(); defer { e.cleanup() }
        #expect(try await find([], e).isEmpty)
    }

    @Test func unreadableShootThrows() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try source(e, "A.MP4", 1)
        let missing = e.base.appendingPathComponent("nope")
        await #expect(throws: ImportRefusal.self) {
            _ = try await ImportDuplicateFinder.find([a], shootFolder: missing, cache: VerificationCache(), cardVolumes: []) { _ in }
        }
    }

    @Test func sourcesAreUntouched() async throws {
        let e = try env(); defer { e.cleanup() }
        let a = try source(e, "A.MP4", 1)
        try put(1, "A.MP4", in: e.shoot)
        let before = try Data(contentsOf: a.url)
        _ = try await find([a], e)
        #expect(try Data(contentsOf: a.url) == before)
    }
}
