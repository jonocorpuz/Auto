import CryptoKit
import Foundation

/// App-managed working directory for headless Claude runs: own CLAUDE.md, Read-only permissions.
nonisolated enum CullWorkspace {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Auto/CullWorkspace", isDirectory: true)
    }

    private struct Meta: Codable {
        var version: Int
        var previousHash: String?
        var currentHash: String?
        var claudeMDSHA256: String?  // legacy single-hash format
    }

    /// Concurrent culls share one workspace; the check-then-move in `writeAtomically` and the meta/CLAUDE.md
    /// read-modify-write must not interleave.
    private static let prepareLock = NSLock()

    @discardableResult
    static func prepare(at root: URL, claudeMD: String, version: Int) throws -> URL {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        let fm = FileManager.default
        let claudeDir = root.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let settings: [String: Any] = [
            "permissions": [
                "deny": ["Bash", "Edit", "Write", "WebFetch", "WebSearch"],
            ],
        ]
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(settingsData, to: claudeDir.appendingPathComponent("settings.json"))

        let mdURL = root.appendingPathComponent("CLAUDE.md")
        let metaURL = root.appendingPathComponent(".auto-workspace.json")
        let newData = Data(claudeMD.utf8)

        // Crash safety: meta is written first (with old and new hash), then CLAUDE.md, so an
        // interrupted update still reads as "unedited". Missing/unreadable meta = assume user-edited.
        let recorded = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        let existing = try? Data(contentsOf: mdURL)
        var shouldWrite = true
        var previous = recorded?.currentHash ?? recorded?.claudeMDSHA256
        if let existing {
            let h = sha256(existing)
            let known = [recorded?.currentHash, recorded?.previousHash, recorded?.claudeMDSHA256]
            shouldWrite = known.contains(h)
            previous = h
        }
        if shouldWrite {
            let meta = Meta(version: version, previousHash: previous, currentHash: sha256(newData), claudeMDSHA256: nil)
            try writeAtomically(try JSONEncoder().encode(meta), to: metaURL)
            try writeAtomically(newData, to: mdURL)
        }
        return root
    }

    static func runDirectory(_ root: URL, runID: UUID) throws -> URL {
        let dir = root.appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func removeRun(_ root: URL, runID: UUID) {
        let dir = root.appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
