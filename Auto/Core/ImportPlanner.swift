import Foundation

/// Why an import (or part of one) is refused before anything is written.
nonisolated enum ImportRefusal: LocalizedError, Equatable, Sendable {
    /// The source resolves inside (or is) a copy of the destination shoot.
    case insideShoot(String)
    /// A path component is `_Rejects` or `.auto-cull`.
    case inReservedFolder(String)
    /// The exact-folder target is outside the shoot or inside a reserved folder.
    case destinationNotInShoot
    case destinationOnCard, shootOffline, nothingToAdd, allDuplicates
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .insideShoot(let name): "\u{201C}\(name)\u{201D} is already inside this shoot."
        case .inReservedFolder(let name): "\u{201C}\(name)\u{201D} is in a folder Auto manages (_Rejects or .auto-cull)."
        case .destinationNotInShoot: "That folder isn't a place Auto can add files to in this shoot."
        case .destinationOnCard: CardDestinationError().localizedDescription
        case .shootOffline: "This shoot isn't available right now. Connect its drive and try again."
        case .nothingToAdd: "There are no files to add."
        case .allDuplicates: "Every file is already in this shoot."
        case .unreadable(let why): "Couldn't check the shoot for duplicates: \(why)"
        }
    }
}

/// Pure planning for adding loose files to an existing shoot.
nonisolated enum ImportPlanner {
    static let fallbackFolder = "Other"
    /// Lowercased folder names Auto owns inside a shoot.
    static let reserved: Set<String> = ["_rejects", ".auto-cull"]

    /// nil when `source` may be imported into the shoot whose copies are `shootRoots`.
    /// Paths are resolved through symlinks on both ends (disk read only to resolve).
    static func refusal(for source: URL, shootRoots: [URL]) -> ImportRefusal? {
        let name = source.lastPathComponent
        let resolvedSource = ShootPlanner.resolvedPath(source)
        for root in shootRoots {
            let resolvedRoot = ShootPlanner.resolvedPath(root)
            if ShootPlanner.relativeComponents(resolvedSource, to: resolvedRoot) != nil
                || ShootPlanner.relativeComponents(source, to: root) != nil {
                return .insideShoot(name)
            }
        }
        let components = Set(ShootPlanner.lexicalComponents(source).map { $0.lowercased() })
            .union(ShootPlanner.lexicalComponents(resolvedSource).map { $0.lowercased() })
        if !components.isDisjoint(with: reserved) { return .inReservedFolder(name) }
        return nil
    }

    /// Camera folder names already in the shoot: "Video" / "Photo" -> folder names.
    static func existingFolders(in shoot: URL) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for section in [ShootPlanner.videoFolder, ShootPlanner.photoFolder] {
            let dir = shoot.appendingPathComponent(section, isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            out[section] = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent).sorted()
        }
        return out
    }

    /// Points each camera at the folder spelling that already exists in the shoot (case-insensitive,
    /// Video before Photo). No match keeps the camera's own name; a lone "FX3" never adopts "FX3 A".
    static func mapCameras(detected: [Camera], existing: [String: [String]]) -> [Camera] {
        var byLower: [String: String] = [:]
        for section in [ShootPlanner.photoFolder, ShootPlanner.videoFolder] {
            for name in existing[section] ?? [] { byLower[name.lowercased()] = name }
        }
        return detected.map { camera in
            guard let name = byLower[camera.folderName.lowercased()], name != camera.folderName else { return camera }
            var out = camera
            out.folderName = name
            out.defaultFolderName = name
            return out
        }
    }

    /// Video/Photo/<camera> jobs on every copy; unknown cameras go to `Other`, audio to Video.
    static func sortedJobs(files: [MediaFile], copies: [URL], cameras: [Camera]) -> [CopyJob] {
        ShootPlanner.jobs(missing: files, copies: copies, cameras: cameras, fallback: fallbackFolder)
    }

    /// Everything flat into `folder` (inside `primary`), mirrored at the same relative path on each copy.
    static func exactJobs(files: [MediaFile], copies: [URL], primary: URL, folder: URL) throws -> [CopyJob] {
        guard let rel = ShootPlanner.relativeComponents(folder, to: primary),
              let resolvedRel = ShootPlanner.relativeComponents(ShootPlanner.resolvedPath(folder), to: ShootPlanner.resolvedPath(primary)),
              !rel.contains(where: { reserved.contains($0.lowercased()) }),
              !resolvedRel.contains(where: { reserved.contains($0.lowercased()) })
        else { throw ImportRefusal.destinationNotInShoot }
        let perCopy = copies.map { copy -> URL in
            var dir = copy
            for part in rel { dir.appendPathComponent(part, isDirectory: true) }
            return dir
        }
        return files.flatMap { file in
            zip(copies, perCopy).map { copy, dir in CopyJob(file: file, destDir: dir, root: copy) }
        }
    }
}
