import Foundation

nonisolated struct ClaudeRequest: Sendable {
    var model: String
    var systemPrompt: String
    var appendSystemPrompt: String
    var userPrompt: String
    var jsonSchema: String
    var workspace: URL
    var maxBudgetUSD: Double
    var maxTurns = 3
    var timeout: Duration = .seconds(180)
    /// MCP config file for this run (`--mcp-config`). nil: no MCP servers at all.
    var mcpConfigPath: String? = nil
    /// Tools the run may use without asking. MCP tools are named `mcp__<server>` (whole server) or `mcp__<server>__<tool>`.
    var allowedTools: [String] = ["Read"]
}

nonisolated struct ClaudeResponse: Sendable {
    /// JSON bytes of the decisions object.
    let structured: Data
    let costUSD: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    var cacheWriteTokens: Int? = nil
    var durationMS: Int? = nil
}

nonisolated enum ClaudeRunnerError: LocalizedError, Equatable {
    case notInstalled
    case notLoggedIn
    case budgetExceeded
    case timedOut
    case exit(Int32, String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code isn't installed. Install it, or set AUTO_CLAUDE_PATH to its location."
        case .notLoggedIn:
            return "Claude Code isn't signed in. Run `claude` in Terminal and log in."
        case .budgetExceeded:
            return "The cull hit its spending limit before finishing."
        case .timedOut:
            return "Claude took too long to respond."
        case .exit(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Claude exited with status \(code)." : "Claude exited with status \(code): \(trimmed)"
        case .malformed(let detail):
            return "Claude returned an unreadable reply (\(detail))."
        }
    }
}

/// Throws CancellationError when cancelled.
nonisolated protocol ClaudeRunner: Sendable {
    func run(_ r: ClaudeRequest) async throws -> ClaudeResponse
}

nonisolated enum ClaudeCLI {
    static func arguments(for r: ClaudeRequest) -> [String] {
        [
            "-p",
            "--output-format", "json",
            "--json-schema", r.jsonSchema,
            "--model", r.model,
            "--max-budget-usd", String(format: "%.2f", r.maxBudgetUSD),
            "--max-turns", String(r.maxTurns),
            "--no-session-persistence",
            "--setting-sources", "project",
            "--strict-mcp-config",
        ]
        + (r.mcpConfigPath.map { ["--mcp-config", $0] } ?? [])
        + ["--allowedTools"] + r.allowedTools
        + [
            "--disallowedTools", "Bash", "Edit", "Write", "WebFetch", "WebSearch", "Task",
            "--system-prompt", r.systemPrompt,
            "--append-system-prompt", r.appendSystemPrompt,
        ]
    }

    static func locate(
        env: [String: String],
        home: URL,
        fileExists: (String) -> Bool,
        loginShellLookup: () -> String?
    ) -> URL? {
        if let override = env["AUTO_CLAUDE_PATH"], !override.isEmpty, fileExists(override) {
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            "/opt/homebrew/bin/claude",
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/usr/local/bin/claude",
        ]
        for path in candidates where fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        if let found = loginShellLookup(), !found.isEmpty, fileExists(found) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    static func parse(stdout: Data) throws -> ClaudeResponse {
        guard let obj = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] else {
            throw ClaudeRunnerError.malformed("not a JSON object")
        }
        let resultText = obj["result"] as? String
        let subtype = obj["subtype"] as? String ?? ""

        let hitBudget = subtype.localizedCaseInsensitiveContains("budget")

        if obj["is_error"] as? Bool == true {
            if hitBudget { throw ClaudeRunnerError.budgetExceeded }
            throw errorForFailedResult(resultText: resultText, errors: obj["errors"] as? [String] ?? [], subtype: subtype)
        }
        if hitBudget { throw ClaudeRunnerError.budgetExceeded }

        guard let structured = structuredOutput(obj["structured_output"], resultText: resultText) else {
            throw ClaudeRunnerError.malformed("no structured output")
        }

        let usage = obj["usage"] as? [String: Any]
        func int(_ key: String) -> Int? { (usage?[key] as? NSNumber)?.intValue }
        return ClaudeResponse(
            structured: structured,
            costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue,
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            cacheReadTokens: int("cache_read_input_tokens"),
            cacheWriteTokens: int("cache_creation_input_tokens"),
            durationMS: (obj["duration_ms"] as? NSNumber)?.intValue
        )
    }

    private static let loginErrorHints = ["login", "log in", "auth", "credential", "invalid api key", "unauthorized"]

    /// notLoggedIn when the error text looks like an auth problem, otherwise malformed with the text.
    private static func errorForFailedResult(resultText: String?, errors: [String], subtype: String) -> ClaudeRunnerError {
        let text = ([resultText].compactMap { $0 } + errors).joined(separator: " ")
        let lower = text.lowercased()
        if loginErrorHints.contains(where: lower.contains) { return .notLoggedIn }
        if !text.isEmpty { return .malformed(text) }
        return .malformed(subtype.isEmpty ? "error result" : subtype)
    }

    /// JSON bytes of the reply: `structured_output` when present, else `result` if it is itself JSON.
    private static func structuredOutput(_ structuredField: Any?, resultText: String?) -> Data? {
        if let field = structuredField, field is [String: Any] || field is [Any],
           let data = try? JSONSerialization.data(withJSONObject: field, options: [.sortedKeys]) {
            return data
        }
        guard let text = resultText, let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              parsed is [String: Any] || parsed is [Any] else { return nil }
        return data
    }
}
