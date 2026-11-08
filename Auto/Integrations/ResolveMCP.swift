import Foundation

/// The DaVinci Resolve MCP server a video-edit run gives Claude.
/// Reuses the user's own registration in `~/.claude.json` so Auto never asks for paths.
nonisolated enum ResolveMCP {
    static let serverName = "davinci-resolve"
    /// Allows every tool of the server (`--allowedTools`).
    static let allowedTool = "mcp__\(serverName)"

    struct Server: Equatable, Sendable {
        var command: String
        var args: [String]
        var env: [String: String]
    }

    enum Failure: LocalizedError, Equatable {
        case notRegistered

        var errorDescription: String? {
            switch self {
            case .notRegistered:
                "The DaVinci Resolve MCP server isn't set up in Claude Code. Add it as \"\(ResolveMCP.serverName)\" (claude mcp add --scope user)."
            }
        }
    }

    /// The user-scope `mcpServers.davinci-resolve` stdio entry, if any.
    static func server(fromClaudeJSON data: Data) -> Server? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any],
              (entry["type"] as? String ?? "stdio") == "stdio",
              let command = entry["command"] as? String, !command.isEmpty
        else { return nil }
        return Server(command: command,
                      args: entry["args"] as? [String] ?? [],
                      env: entry["env"] as? [String: String] ?? [:])
    }

    /// `--mcp-config` contents holding only the Resolve server.
    static func configJSON(_ s: Server) throws -> Data {
        let entry: [String: Any] = ["type": "stdio", "command": s.command, "args": s.args, "env": s.env]
        return try JSONSerialization.data(withJSONObject: ["mcpServers": [serverName: entry]],
                                          options: [.sortedKeys, .prettyPrinted])
    }

    /// Reads `<home>/.claude.json` and writes `mcp.json` into `workspace`. Returns its path.
    static func writeConfig(home: URL, into workspace: URL) throws -> URL {
        let claudeJSON = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: claudeJSON), let s = server(fromClaudeJSON: data) else {
            throw Failure.notRegistered
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let url = workspace.appendingPathComponent("mcp.json")
        try configJSON(s).write(to: url, options: .atomic)
        return url
    }
}
