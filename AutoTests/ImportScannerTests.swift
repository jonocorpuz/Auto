import Foundation
import Testing
@testable import Auto

struct ImportScannerTests {
    private func write(_ rel: String, in root: URL, _ bytes: Data = Data("x".utf8)) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func sonyXML(_ model: String, serial: String) -> Data {
        Data("<NonRealTimeMeta><Device manufacturer=\"Sony\" modelName=\"\(model)\" serialNo=\"\(serial)\"/></NonRealTimeMeta>".utf8)
    }

    private func scan(_ roots: [URL], shoots: [URL] = []) async throws -> ImportScan {
        try await ImportScanner.scan(roots, shootRoots: shoots, onProgress: { _ in })
    }

    @Test func nestedFoldersHiddenPackagesSkippedAndIgnored() async throws {
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        _ = try write("a/b/clip.mp4", in: drive)
        _ = try write("a/pic.jpg", in: drive)
        _ = try write("a/song.wav", in: drive)
        _ = try write("a/notes.txt", in: drive)
        _ = try write("a/.hidden.mp4", in: drive)
        _ = try write("THMBNL/t.jpg", in: drive)
        _ = try write("Thing.app/Contents/x.mp4", in: drive)

        let result = try await scan([drive])
        #expect(result.files.map(\.file.name) == ["clip.mp4", "pic.jpg", "song.wav"])
        #expect(result.ignoredCount == 1)
        #expect(result.refused.isEmpty)
        #expect(result.files.allSatisfy { $0.file.cardID == "import" && $0.origin == drive.standardizedFileURL })
        #expect(result.files.first { $0.file.name == "song.wav" }?.file.kind == .audio)
    }

    @Test func mixedCamerasInOneDirectory() async throws {
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        _ = try write("Downloads/C0001.MP4", in: drive)
        _ = try write("Downloads/C0001M01.XML", in: drive, sonyXML("ILME-FX3", serial: "111"))
        _ = try write("Downloads/C0002.MP4", in: drive)
        _ = try write("Downloads/C0002M01.XML", in: drive, sonyXML("ILCE-7M4", serial: "222"))
        _ = try write("Downloads/loose.mov", in: drive)

        let result = try await scan([drive])
        let folder = Dictionary(uniqueKeysWithValues: result.files.map { ($0.file.name, $0.cameraFolder) })
        #expect(folder["C0001.MP4"] == "FX3")
        #expect(folder["C0002.MP4"] == "A7M4")
        #expect(folder["loose.mov"] == ImportPlanner.fallbackFolder)
        #expect(Set(result.cameras.map(\.folderName)) == ["FX3", "A7M4", "Other"])
    }

    @Test func sameModelCamerasGetDisambiguated() async throws {
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        _ = try write("C0001.MP4", in: drive)
        _ = try write("C0001M01.XML", in: drive, sonyXML("ILME-FX3", serial: "111"))
        _ = try write("C0002.MP4", in: drive)
        _ = try write("C0002M01.XML", in: drive, sonyXML("ILME-FX3", serial: "222"))
        let result = try await scan([drive])
        #expect(Set(result.files.map(\.cameraFolder)) == ["FX3 A", "FX3 B"])
    }

    @Test func duplicatePathsCollapsed() async throws {
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        let clip = try write("a/clip.mp4", in: drive)
        let result = try await scan([drive, drive.appendingPathComponent("a"), clip, clip])
        #expect(result.files.count == 1)
    }

    @Test func refusesSourcesInsideShootAndReserved() async throws {
        let shoot = FixtureShoot()
        let mirror = FixtureCard.makeTempDirSafe()
        defer { shoot.cleanup(); try? FileManager.default.removeItem(at: mirror) }
        let inside = shoot.add("Video/FX3/c.mp4")
        let mirrorFile = try write("Video/FX3/m.mp4", in: mirror)
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        _ = try write("ok.mp4", in: drive)
        _ = try write("_Rejects/bad.jpg", in: drive)

        let result = try await scan([inside, mirrorFile, drive], shoots: [shoot.root, mirror])
        #expect(result.files.map(\.file.name) == ["ok.mp4"])
        #expect(result.refused.count == 3)
        #expect(result.refused.contains { $0.1 == .insideShoot("c.mp4") })
        #expect(result.refused.contains { $0.1 == .insideShoot("m.mp4") })
        #expect(result.refused.contains { $0.1 == .inReservedFolder("_Rejects") })
    }

    @Test func symlinkHandling() async throws {
        let drive = try FixtureCard.makeTempDir()
        let outside = try FixtureCard.makeTempDir()
        let shoot = FixtureShoot()
        defer {
            shoot.cleanup()
            for u in [drive, outside] { try? FileManager.default.removeItem(at: u) }
        }
        let fm = FileManager.default
        let real = try write("real.mp4", in: drive)
        let out = try write("out.mp4", in: outside)
        let inShoot = shoot.add("Video/FX3/s.mp4")
        try fm.createSymbolicLink(at: drive.appendingPathComponent("inlink.mp4"), withDestinationURL: real)
        try fm.createSymbolicLink(at: drive.appendingPathComponent("outlink.mp4"), withDestinationURL: out)

        let walked = try await scan([drive])
        #expect(walked.files.map(\.file.name) == ["real.mp4"]) // inlink collapses onto real, outlink skipped
        #expect(walked.ignoredCount == 1)

        // A symlink to a file inside the shoot, chosen explicitly, is refused.
        let link = drive.appendingPathComponent("shootlink.mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: inShoot)
        let refused = try await scan([link], shoots: [shoot.root])
        #expect(refused.files.isEmpty)
        #expect(refused.refused.count == 1)

        // An explicit symlink to an outside file is followed.
        let followed = try await scan([drive.appendingPathComponent("outlink.mp4")])
        #expect(followed.files.count == 1)
    }

    @Test func progressReportsCountAndSourcesUntouched() async throws {
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        let clip = try write("a.mp4", in: drive, Data(repeating: 7, count: 100))
        _ = try write("b.mp4", in: drive)
        nonisolated final class Box: @unchecked Sendable { var last = 0 }
        let box = Box()
        let result = try await ImportScanner.scan([drive], shootRoots: [], onProgress: { box.last = $0 })
        #expect(box.last == 2 && result.files.count == 2)
        #expect(try Data(contentsOf: clip) == Data(repeating: 7, count: 100))
    }

    @Test func progressIsThrottled() async throws {
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        for n in 0..<450 { _ = try write("f\(n).mp4", in: drive) }
        nonisolated final class Box: @unchecked Sendable { var calls = 0; var last = 0 }
        let box = Box()
        let result = try await ImportScanner.scan([drive], shootRoots: [], onProgress: { box.calls += 1; box.last = $0 })
        #expect(result.files.count == 450 && box.last == 450)
        #expect(box.calls < 100)
    }

    @Test func cancellationThrows() async throws {
        let drive = try FixtureCard.makeTempDir()
        defer { try? FileManager.default.removeItem(at: drive) }
        for n in 0..<50 { _ = try write("f\(n).mp4", in: drive) }
        let task = Task { try await ImportScanner.scan([drive], shootRoots: [], onProgress: { _ in }) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private extension FixtureCard {
    static func makeTempDirSafe() -> URL { (try? makeTempDir()) ?? FileManager.default.temporaryDirectory }
}
