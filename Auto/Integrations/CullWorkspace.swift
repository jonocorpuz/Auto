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
        var claudeMDSHA256: String
    }

    @discardableResult
    static func prepare(at root: URL, claudeMD: String, version: Int) throws -> URL {
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

        var shouldWrite = true
        if let existing = try? Data(contentsOf: mdURL) {
            let recorded = (try? Data(contentsOf: metaURL))
                .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            shouldWrite = recorded?.claudeMDSHA256 == sha256(existing)
        }
        if shouldWrite {
            try writeAtomically(newData, to: mdURL)
            let meta = Meta(version: version, claudeMDSHA256: sha256(newData))
            try writeAtomically(try JSONEncoder().encode(meta), to: metaURL)
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
