import AppKit
import Foundation

/// Video Edit tab: readiness checks for a sync + Resolve build. The run itself isn't built yet.
extension AppModel {
    private static let resolveBundleID = "com.blackmagic-design.DaVinciResolve"

    /// Re-reads the MCP registration (file I/O off main) and whether Resolve is running.
    func refreshVideoEditEnvironment(checkMCP: Bool) async {
        if checkMCP {
            let home = FileManager.default.homeDirectoryForCurrentUser
            resolveMCPRegistered = await Task.detached(priority: .utility) {
                guard let claudeJSON = try? Data(contentsOf: home.appendingPathComponent(".claude.json")) else { return false }
                return ResolveMCP.server(fromClaudeJSON: claudeJSON) != nil
            }.value
        }
        let runningApps = NSWorkspace.shared.runningApplications
        resolveRunning = runningApps.contains { $0.bundleIdentifier == Self.resolveBundleID }
    }

    func videoEditReadiness(shootID: UUID) -> VideoEditReadiness {
        let item = shoots.first { $0.id == shootID }
        return VideoEditReadiness.evaluate(
            videoCount: item?.summary?.videoCount,
            mainCopyOnline: item?.copies.first(where: \.isPrimary)?.availability == .online,
            mcpRegistered: resolveMCPRegistered,
            resolveRunning: resolveRunning)
    }
}
