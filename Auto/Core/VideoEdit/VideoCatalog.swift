import Foundation

/// One video clip or audio file in a shoot's `Video/` folder.
nonisolated struct AudioSyncSource: Sendable, Equatable, Hashable, Codable {
    enum Kind: String, Sendable, Codable { case video, audio }
    /// Path relative to the shoot ("Video/A7SIII/C0353.MP4").
    let id: String
    /// Camera or recorder folder under `Video/`; "" for files directly in `Video/` (flat layout).
    let camera: String
    let kind: Kind
}

nonisolated enum VideoEditError: LocalizedError, Equatable {
    case onCard
    case noVideo

    var errorDescription: String? {
        switch self {
        case .onCard: "This folder is on a camera card. Video edits only run on backed-up shoots."
        case .noVideo: "This shoot has no video clips."
        }
    }
}

/// Lists a shoot's video clips and audio files (ingest files recorder audio under `Video/<recorder>`).
/// Skips hidden files, symlinks and `_Rejects`. Read-only.
nonisolated enum VideoCatalog {
    static func scan(shoot: URL, cardVolumes: [URL]) throws -> [AudioSyncSource] {
        if VolumeClassifier.isOnCard(shoot, cards: cardVolumes)
            || VolumeClassifier.isOnCard(ShootPlanner.resolvedPath(shoot), cards: cardVolumes) {
            throw VideoEditError.onCard
        }
        let videoDir = shoot.appendingPathComponent("Video", isDirectory: true)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let root = try? videoDir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              root.isSymbolicLink != true, root.isDirectory == true,
              let walker = FileManager.default.enumerator(at: videoDir, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [AudioSyncSource] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent
            if v.isSymbolicLink == true || name.hasPrefix(".") {
                if v.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if v.isDirectory == true {
                if name == "_Rejects" || MediaTypes.skippedFolders.contains(name.lowercased()) { walker.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true else { continue }
            let kind: AudioSyncSource.Kind
            switch MediaTypes.kind(for: url) {
            case .video?: kind = .video
            case .audio?: kind = .audio
            default: continue
            }
            let parts = Array(url.pathComponents.suffix(walker.level))
            out.append(AudioSyncSource(id: "Video/" + parts.joined(separator: "/"),
                                  camera: parts.count > 1 ? parts[0] : "", kind: kind))
        }
        return out.sorted { $0.id < $1.id }
    }
}
