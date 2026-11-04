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
    static let cardMarkers = ["DCIM", "PRIVATE/M4ROOT", "PRIVATE/AVCHD", "PRIVATE/XDROOT", "XDROOT", "CLIP", "CONTENTS/VIDEO"]

    static func hasCardLayout(at url: URL) -> Bool {
        cardMarkers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Standardized path with no trailing slash, so `file:///Volumes/X/` equals `/Volumes/X`.
    static func normalizedPath(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func classify(_ volumes: [VolumeDescriptor], workingVolume: URL?) -> VolumeClassification {
        let working = workingVolume.map(normalizedPath)
        var cards: [URL] = []
        var drives: [DriveVolume] = []
        for v in volumes {
            guard !v.isRootFileSystem, v.isLocal, v.url.path.hasPrefix("/Volumes/"), !v.isDiskImage else { continue }
            let isWorking = working != nil && normalizedPath(v.url) == working
            if !isWorking && (v.hasCardLayout || v.isRemovable) {
                cards.append(v.url)
            } else if !v.isInternal || isWorking {
                drives.append(DriveVolume(url: v.url, name: v.name))
            }
        }
        drives.sort { a, b in
            let aw = working != nil && normalizedPath(a.url) == working
            let bw = working != nil && normalizedPath(b.url) == working
            return aw != bw ? aw : a.name < b.name
        }
        return VolumeClassification(cards: cards, drives: drives)
    }
}
