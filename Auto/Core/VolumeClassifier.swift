import Foundation

/// A mounted volume and the facts needed to classify it. Pure data, so the
/// classifier can be tested without touching real volumes.
nonisolated struct VolumeDescriptor: Equatable, Sendable {
    var url: URL
    var name: String
    var isInternal: Bool
    var isRemovable: Bool
    var isLocal: Bool
    var isRootFileSystem: Bool
    var isDiskImage: Bool
    var hasCardLayout: Bool
}

/// A non-card volume the user can pick as a destination.
nonisolated struct DriveVolume: Equatable, Sendable, Identifiable {
    var url: URL
    var name: String
    var id: URL { url }
}

nonisolated struct VolumeClassification: Equatable, Sendable {
    var cards: [URL]
    var drives: [DriveVolume]
}

/// Ported from Backed's AppModel.refreshVolumes.
nonisolated enum VolumeClassifier {
    /// Folders (relative to the volume root) that only camera cards have.
    static let cardMarkers = ["DCIM", "PRIVATE/M4ROOT", "PRIVATE/AVCHD", "PRIVATE/XDROOT", "XDROOT", "CLIP", "CONTENTS/VIDEO"]

    static func hasCardLayout(at url: URL) -> Bool {
        cardMarkers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Standardized path with no trailing slash, so `file:///Volumes/X/` equals `/Volumes/X`.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Lowercased, symlink-resolved, normalized path (card file systems are usually case-insensitive).
    private static func comparablePath(_ url: URL) -> String {
        normalizedPath(url.resolvingSymlinksInPath()).lowercased()
    }

    /// True when `url` is a card root or anything inside one. Pure path check (symlinks resolved).
    static func isInside(_ url: URL, anyOf roots: [URL]) -> Bool {
        let path = comparablePath(url)
        return roots.contains { root in
            let rootPath = comparablePath(root)
            return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
        }
    }

    /// True when `destination` would land on any of `cards`: inside a card folder, or on the same
    /// volume as a card that is a volume root (compared by volume identifier, not just path).
    static func isOnCard(_ destination: URL, cards: [URL]) -> Bool {
        if isInside(destination, anyOf: cards) { return true }
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeIdentifierKey]
        // Walk up to the nearest existing ancestor so a not-yet-created folder still resolves.
        var probe = destination.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        guard let destinationValues = try? URL(fileURLWithPath: probe.path).resourceValues(forKeys: keys),
              let destinationVolumeID = destinationValues.volumeIdentifier else { return false }
        for card in cards {
            guard let cardValues = try? URL(fileURLWithPath: card.path).resourceValues(forKeys: keys),
                  let cardVolumeRoot = cardValues.volume,
                  normalizedPath(cardVolumeRoot) == normalizedPath(card),
                  let cardVolumeID = cardValues.volumeIdentifier else { continue }
            if destinationVolumeID.isEqual(cardVolumeID) { return true }
        }
        return false
    }

    static func classify(_ volumes: [VolumeDescriptor], workingVolume: URL?) -> VolumeClassification {
        let working = workingVolume.map(normalizedPath)
        func isWorking(_ url: URL) -> Bool { working != nil && normalizedPath(url) == working }

        var cards: [URL] = []
        var drives: [DriveVolume] = []
        for volume in volumes {
            let isCandidate = !volume.isRootFileSystem && volume.isLocal
                && volume.url.path.hasPrefix("/Volumes/") && !volume.isDiskImage
            guard isCandidate else { continue }
            let isWorkingVolume = isWorking(volume.url)
            if !isWorkingVolume && (volume.hasCardLayout || volume.isRemovable) {
                cards.append(volume.url)
            } else if !volume.isInternal || isWorkingVolume {
                drives.append(DriveVolume(url: volume.url, name: volume.name))
            }
        }
        // The working volume first, then by name.
        drives.sort { a, b in
            let aIsWorking = isWorking(a.url)
            let bIsWorking = isWorking(b.url)
            if aIsWorking != bIsWorking { return aIsWorking }
            return a.name < b.name
        }
        return VolumeClassification(cards: cards, drives: drives)
    }
}

/// A copy destination that is on a camera card. Copies there never count as a backup.
nonisolated struct CardDestinationError: LocalizedError, Equatable {
    var errorDescription: String? {
        "That folder is on a camera card. Choose a folder on your work drive or another drive."
    }
}
