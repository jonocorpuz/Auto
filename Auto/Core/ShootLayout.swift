import Foundation

/// How a shoot folder is organized on disk. Stored in the sidecar; absent means `.cameraFolders`.
nonisolated enum ShootLayout: String, Codable, Sendable, Hashable {
    /// One subfolder per camera.
    case cameraFolders
    /// Everything straight into the shoot folder.
    case flat
}
