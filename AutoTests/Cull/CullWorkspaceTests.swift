import CryptoKit
import Foundation
import Testing
@testable import Auto

struct CullWorkspaceTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
    }

    @Test func createsFiles() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try CullWorkspace.prepare(at: root, claudeMD: "rules v1", version: 1)
        #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "rules v1")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
    }

    @Test func settingsDenyBash() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try CullWorkspace.prepare(at: root, claudeMD: "x", version: 1)
        let data = try Data(contentsOf: root.appendingPathComponent(".claude/settings.json"))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let perms = try #require(obj["permissions"] as? [String: [String]])
        #expect(perms["deny"]?.contains("Bash") == true)
        #expect(perms["allow"] == nil)  // untrusted workspaces ignore allow; Read comes from --allowedTools
    }

    @Test func rewritesUneditedOnVersionBump() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try CullWorkspace.prepare(at: root, claudeMD: "v1", version: 1)
        try CullWorkspace.prepare(at: root, claudeMD: "v2", version: 2)
        #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "v2")
    }

    @Test func preservesEditedClaudeMD() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try CullWorkspace.prepare(at: root, claudeMD: "v1", version: 1)
        try "my edits".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try CullWorkspace.prepare(at: root, claudeMD: "v2", version: 2)
        #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "my edits")
    }

    private func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func crashAfterMetaBeforeClaudeMDStillRewrites() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try CullWorkspace.prepare(at: root, claudeMD: "v1", version: 1)
        // Simulate a crash: meta already records v2, file still holds v1.
        let meta = #"{"version":2,"previousHash":"\#(hash("v1"))","currentHash":"\#(hash("v2"))"}"#
        try meta.write(to: root.appendingPathComponent(".auto-workspace.json"), atomically: true, encoding: .utf8)
        try CullWorkspace.prepare(at: root, claudeMD: "v2", version: 2)
        #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "v2")
    }

    @Test func missingMetaKeepsExistingClaudeMD() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try CullWorkspace.prepare(at: root, claudeMD: "v1", version: 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".auto-workspace.json"))
        try CullWorkspace.prepare(at: root, claudeMD: "v2", version: 2)
        #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "v1")
    }

    @Test func runDirectoryCreateAndRemove() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let dir = try CullWorkspace.runDirectory(root, runID: id)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        CullWorkspace.removeRun(root, runID: id)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// Two culls prepare the shared workspace at once; the check-then-move used to throw "item already exists".
    @Test func concurrentPrepareNeverThrows() async throws {
        for _ in 0..<20 {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let failures = await withTaskGroup(of: Bool.self) { tg in
                for _ in 0..<8 {
                    tg.addTask { (try? CullWorkspace.prepare(at: root, claudeMD: "rules", version: 1)) == nil }
                }
                var n = 0
                for await failed in tg where failed { n += 1 }
                return n
            }
            #expect(failures == 0)
        }
    }
}
