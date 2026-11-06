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
}

nonisolated struct ClaudeResponse: Sendable {
    /// JSON bytes of the decisions object.
    let structured: Data
    let costUSD: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
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
            "--allowedTools", "Read",
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

        if obj["is_error"] as? Bool == true {
            if subtype.localizedCaseInsensitiveContains("budget") { throw ClaudeRunnerError.budgetExceeded }
            let text = ([resultText] + ((obj["errors"] as? [String]) ?? []).map { Optional($0) })
                .compactMap { $0 }.joined(separator: " ")
            let lower = text.lowercased()
            if ["login", "log in", "auth", "credential", "invalid api key", "unauthorized"].contains(where: lower.contains) {
                throw ClaudeRunnerError.notLoggedIn
            }
            throw ClaudeRunnerError.malformed(text.isEmpty ? (subtype.isEmpty ? "error result" : subtype) : text)
        }
        if subtype.localizedCaseInsensitiveContains("budget") { throw ClaudeRunnerError.budgetExceeded }

        let structured: Data
        if let s = obj["structured_output"], s is [String: Any] || s is [Any],
           let data = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]) {
            structured = data
        } else if let text = resultText,
                  let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  parsed is [String: Any] || parsed is [Any] {
            structured = data
        } else {
            throw ClaudeRunnerError.malformed("no structured output")
        }

        let usage = obj["usage"] as? [String: Any]
        func int(_ key: String) -> Int? { (usage?[key] as? NSNumber)?.intValue }
        return ClaudeResponse(
            structured: structured,
            costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue,
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            cacheReadTokens: int("cache_read_input_tokens")
        )
    }
}
