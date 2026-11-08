import Foundation

/// What must be true before a video edit can start, as a checklist the Video Edit tab shows.
nonisolated struct VideoEditReadiness: Equatable, Sendable {
    enum State: Equatable, Sendable { case ok, missing, checking }

    struct Check: Identifiable, Equatable, Sendable {
        enum ID: String, Sendable { case footage, mainCopy, mcp, resolve }
        let id: ID
        let title: String
        let state: State
        /// What to do about it; shown when not ok.
        let hint: String?
    }

    let checks: [Check]

    static let resolveServerName = "davinci-resolve"
    static let mcpMissingHint = "The DaVinci Resolve MCP server isn't set up in Claude Code. Add it as \"\(resolveServerName)\" (claude mcp add --scope user)."

    var isReady: Bool { checks.allSatisfy { $0.state == .ok } }
    /// The first thing to fix, for a one-line explanation under the button.
    var blocker: String? { checks.first { $0.state != .ok }.map { $0.hint ?? $0.title } }

    /// `nil` inputs mean "not known yet".
    static func evaluate(videoCount: Int?, mainCopyOnline: Bool, mcpRegistered: Bool?, resolveRunning: Bool) -> VideoEditReadiness {
        func state(_ v: Bool?) -> State { v.map { $0 ? .ok : .missing } ?? .checking }
        let footage = videoCount.map { $0 > 0 }
        return VideoEditReadiness(checks: [
            Check(id: .footage, title: "Video clips in this shoot", state: state(footage),
                  hint: footage == false ? "This shoot has no video clips." : nil),
            Check(id: .mainCopy, title: "Main copy connected", state: state(mainCopyOnline),
                  hint: mainCopyOnline ? nil : "Connect the drive with the main copy. Syncing reads the clips' audio."),
            Check(id: .mcp, title: "Resolve MCP server set up", state: state(mcpRegistered),
                  hint: mcpRegistered == false ? mcpMissingHint : nil),
            Check(id: .resolve, title: "DaVinci Resolve open", state: state(resolveRunning),
                  hint: resolveRunning ? nil : "Open Resolve, then start the bridge: Workspace ▸ Scripts ▸ resolve_bridge."),
        ])
    }
}
