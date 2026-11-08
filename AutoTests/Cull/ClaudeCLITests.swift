import Testing
import Foundation
@testable import Auto

struct ClaudeCLITests {
    private func request() -> ClaudeRequest {
        ClaudeRequest(model: "sonnet", systemPrompt: "role", appendSystemPrompt: "run section",
                      userPrompt: "SECRET USER PROMPT", jsonSchema: #"{"type":"object"}"#,
                      workspace: URL(fileURLWithPath: "/tmp/ws"), maxBudgetUSD: 1.5)
    }

    @Test func argumentsSnapshot() {
        let args = ClaudeCLI.arguments(for: request())
        #expect(args == [
            "-p", "--output-format", "json", "--json-schema", #"{"type":"object"}"#,
            "--model", "sonnet", "--max-budget-usd", "1.50", "--max-turns", "3",
            "--no-session-persistence", "--setting-sources", "project", "--strict-mcp-config",
            "--allowedTools", "Read",
            "--disallowedTools", "Bash", "Edit", "Write", "WebFetch", "WebSearch", "Task",
            "--system-prompt", "role", "--append-system-prompt", "run section",
        ])
        #expect(!args.contains("SECRET USER PROMPT"))
        #expect(!args.contains("/tmp/ws"))
    }

    private let home = URL(fileURLWithPath: "/Users/x")

    @Test func locateOrder() {
        let all: Set<String> = ["/opt/homebrew/bin/claude", "/Users/x/.local/bin/claude", "/usr/local/bin/claude"]
        #expect(ClaudeCLI.locate(env: [:], home: home, fileExists: { all.contains($0) }, loginShellLookup: { nil })?.path == "/opt/homebrew/bin/claude")
        #expect(ClaudeCLI.locate(env: [:], home: home, fileExists: { $0 == "/Users/x/.local/bin/claude" || $0 == "/usr/local/bin/claude" }, loginShellLookup: { nil })?.path == "/Users/x/.local/bin/claude")
        #expect(ClaudeCLI.locate(env: ["AUTO_CLAUDE_PATH": "/custom/claude"], home: home, fileExists: { all.contains($0) || $0 == "/custom/claude" }, loginShellLookup: { nil })?.path == "/custom/claude")
    }

    @Test func locateFallsBackToLoginShell() {
        let url = ClaudeCLI.locate(env: [:], home: home, fileExists: { $0 == "/weird/claude" }, loginShellLookup: { "/weird/claude" })
        #expect(url?.path == "/weird/claude")
        #expect(ClaudeCLI.locate(env: [:], home: home, fileExists: { _ in false }, loginShellLookup: { nil }) == nil)
    }

    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesRealSample() throws {
        let json = #"{"stop_reason":"tool_use","total_cost_usd":0.00166138,"usage":{"input_tokens":6,"cache_creation_input_tokens":7063,"cache_read_input_tokens":17168,"output_tokens":153},"is_error":false,"num_turns":3,"subtype":"success","result":"{\"a\":\"Hi!\"}","structured_output":{"a":"Hi!"},"type":"result"}"#
        let r = try ClaudeCLI.parse(stdout: data(json))
        #expect(String(decoding: r.structured, as: UTF8.self) == #"{"a":"Hi!"}"#)
        #expect(r.costUSD == 0.00166138)
        #expect(r.inputTokens == 6)
        #expect(r.outputTokens == 153)
        #expect(r.cacheReadTokens == 17168)
        #expect(r.cacheWriteTokens == 7063)
        #expect(r.durationMS == nil)
    }

    @Test func parsesDuration() throws {
        let r = try ClaudeCLI.parse(stdout: data(#"{"is_error":false,"duration_ms":4210,"structured_output":{"a":1}}"#))
        #expect(r.durationMS == 4210)
    }

    @Test func fallsBackToResultAsJSON() throws {
        let r = try ClaudeCLI.parse(stdout: data(#"{"is_error":false,"result":"{\"a\":\"b\"}"}"#))
        #expect(String(decoding: r.structured, as: UTF8.self) == #"{"a":"b"}"#)
        #expect(r.costUSD == nil)
    }

    @Test func authErrorMapsToNotLoggedIn() {
        #expect(throws: ClaudeRunnerError.notLoggedIn) {
            try ClaudeCLI.parse(stdout: data(#"{"is_error":true,"result":"Invalid API key - Please run /login"}"#))
        }
    }

    @Test func budgetSubtypeMapsToBudgetExceeded() {
        #expect(throws: ClaudeRunnerError.budgetExceeded) {
            try ClaudeCLI.parse(stdout: data(#"{"is_error":true,"subtype":"error_max_budget_usd"}"#))
        }
    }

    @Test func malformed() {
        #expect(throws: ClaudeRunnerError.self) { try ClaudeCLI.parse(stdout: data("nope")) }
        #expect(throws: ClaudeRunnerError.self) { try ClaudeCLI.parse(stdout: data(#"{"is_error":false,"result":"plain text"}"#)) }
        #expect(throws: ClaudeRunnerError.self) { try ClaudeCLI.parse(stdout: data(#"{"is_error":true,"subtype":"error_max_turns","result":"x"}"#)) }
    }
}
