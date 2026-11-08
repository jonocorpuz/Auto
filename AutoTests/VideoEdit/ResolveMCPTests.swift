import Foundation
import Testing
@testable import Auto

struct ResolveMCPTests {
    private static let claudeJSON = #"""
    {"numStartups": 3,
     "mcpServers": {
       "other": {"type": "stdio", "command": "/bin/other"},
       "davinci-resolve": {"type": "stdio", "command": "/py", "args": ["/srv/server.py"],
                           "env": {"PYTHONPATH": "/lib"}}},
     "projects": {"/x": {"mcpServers": {}}}}
    """#

    @Test func readsTheUserScopeEntry() {
        let s = ResolveMCP.server(fromClaudeJSON: Data(Self.claudeJSON.utf8))
        #expect(s == .init(command: "/py", args: ["/srv/server.py"], env: ["PYTHONPATH": "/lib"]))
    }

    @Test func missingOrNonStdioEntryIsNil() {
        #expect(ResolveMCP.server(fromClaudeJSON: Data(#"{"mcpServers":{}}"#.utf8)) == nil)
        #expect(ResolveMCP.server(fromClaudeJSON: Data(#"{"mcpServers":{"davinci-resolve":{"type":"http","url":"x"}}}"#.utf8)) == nil)
        #expect(ResolveMCP.server(fromClaudeJSON: Data("not json".utf8)) == nil)
    }

    @Test func writesAConfigWithOnlyTheResolveServer() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(Self.claudeJSON.utf8).write(to: home.appendingPathComponent(".claude.json"))

        let url = try ResolveMCP.writeConfig(home: home, into: tmp.appendingPathComponent("ws"))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let servers = obj["mcpServers"] as! [String: Any]
        #expect(Array(servers.keys) == ["davinci-resolve"])
        #expect((servers["davinci-resolve"] as! [String: Any])["command"] as? String == "/py")
    }

    @Test func unregisteredServerThrows() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: ResolveMCP.Failure.notRegistered) {
            try ResolveMCP.writeConfig(home: tmp, into: tmp.appendingPathComponent("ws"))
        }
    }
}
