import Foundation

/// Temp shoot folder for tests.
nonisolated final class FixtureShoot {
    let root: URL
    private(set) var files: [String: Data] = [:]
    private var extraRoots: [URL] = []

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AutoFixtureShoot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func add(_ relPath: String, bytes: Data = Data("x".utf8)) -> URL {
        let url = root.appendingPathComponent(relPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: url)
        files[relPath] = bytes
        return url
    }

    /// A second temp root holding the same files.
    func mirror() -> URL {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("AutoFixtureShoot-\(UUID().uuidString)", isDirectory: true)
        for (rel, data) in files {
            let url = other.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        extraRoots.append(other)
        return other
    }

    func cleanup() {
        for url in [root] + extraRoots { try? FileManager.default.removeItem(at: url) }
    }
}
