import Foundation
import Testing
@testable import Auto

struct ClaudeCLIRunnerTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("clr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func script(in dir: URL, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-claude")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func request(_ dir: URL, timeout: Duration = .seconds(30)) -> ClaudeRequest {
        ClaudeRequest(model: "haiku", systemPrompt: "s", appendSystemPrompt: "a", userPrompt: "hello prompt",
                      jsonSchema: "{}", workspace: dir, maxBudgetUSD: 1, timeout: timeout)
    }

    private let success = #"{"type":"result","is_error":false,"structured_output":{"a":1},"total_cost_usd":0.5,"usage":{"input_tokens":3,"output_tokens":4}}"#

    @Test func decodesSuccess() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let exe = try script(in: dir, "cat >/dev/null\necho '\(success)'")
        let resp = try await ClaudeCLIRunner(executable: exe).run(request(dir))
        #expect(resp.costUSD == 0.5)
        #expect(resp.inputTokens == 3)
        #expect(String(decoding: resp.structured, as: UTF8.self) == #"{"a":1}"#)
    }

    @Test func nonzeroExitWithStderr() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let exe = try script(in: dir, "echo boom >&2\nexit 3")
        await #expect(throws: ClaudeRunnerError.exit(3, "boom\n")) {
            try await ClaudeCLIRunner(executable: exe).run(request(dir))
        }
    }

    @Test func cancellationKillsProcess() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let exe = try script(in: dir, "echo $$ > '\(pidFile.path)'\nexec sleep 60")
        let req = request(dir)
        let task = Task { try await ClaudeCLIRunner(executable: exe).run(req) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        var dead = false
        for _ in 0..<60 {
            if kill(pid, 0) != 0 { dead = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(dead)
    }

    @Test func timeout() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let exe = try script(in: dir, "exec sleep 60")
        await #expect(throws: ClaudeRunnerError.timedOut) {
            try await ClaudeCLIRunner(executable: exe).run(request(dir, timeout: .seconds(1)))
        }
    }

    @Test func stdinDelivered() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("stdin.txt")
        let exe = try script(in: dir, "cat > '\(out.path)'\necho '\(success)'")
        _ = try await ClaudeCLIRunner(executable: exe).run(request(dir))
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello prompt")
    }

    @Test func cwdIsWorkspace() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ws = dir.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("pwd.txt")
        let exe = try script(in: dir, "cat >/dev/null\npwd -P > '\(out.path)'\necho '\(success)'")
        _ = try await ClaudeCLIRunner(executable: exe).run(request(ws))
        let got = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: got).resolvingSymlinksInPath().path == ws.resolvingSymlinksInPath().path)
    }

    @Test func apiKeyRemovedFromEnvironment() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("env.txt")
        let exe = try script(in: dir, "cat >/dev/null\nenv > '\(out.path)'\necho '\(success)'")
        let env = ["ANTHROPIC_API_KEY": "sk-secret", "FOO": "bar", "PATH": "/usr/bin:/bin"]
        _ = try await ClaudeCLIRunner(executable: exe, environment: env).run(request(dir))
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(!text.contains("ANTHROPIC_API_KEY"))
        #expect(text.contains("FOO=bar"))
        #expect(text.contains("/opt/homebrew/bin"))
    }

    @Test func missingExecutable() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: ClaudeRunnerError.notInstalled) {
            try await ClaudeCLIRunner(executable: dir.appendingPathComponent("nope")).run(request(dir))
        }
    }
}
