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
        // Case differences and firmlink spellings (/System/Volumes/Data/...) defeat a path comparison, so also
        // compare on-disk identity: any ancestor of the source that is a shoot copy means it is inside.
        let rootIDs = shootRoots.compactMap { identity(of: $0) }
        if !rootIDs.isEmpty {
            for start in [resolvedSource, source] where hasAncestor(of: start, matchingAnyOf: rootIDs) {
                return .insideShoot(name)
            }
        }
        let components = Set(ShootPlanner.lexicalComponents(source).map { $0.lowercased() })
            .union(ShootPlanner.lexicalComponents(resolvedSource).map { $0.lowercased() })
        if !components.isDisjoint(with: reserved) { return .inReservedFolder(name) }
        return nil
    }

    /// True when `start` or any folder above it is one of `identities`.
    private static func hasAncestor(of start: URL, matchingAnyOf identities: [DiskIdentity]) -> Bool {
        var probe = start
        while true {
            if let id = identity(of: probe), identities.contains(where: { $0.matches(id) }) { return true }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path || probe.path == "/" { return false }
            probe = parent
        }
    }

    private struct DiskIdentity {
        let file: any NSObjectProtocol
        let volume: any NSObjectProtocol
        func matches(_ other: DiskIdentity) -> Bool { file.isEqual(other.file) && volume.isEqual(other.volume) }
    }

    private static func identity(of url: URL) -> DiskIdentity? {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
              let file = values.fileResourceIdentifier, let volume = values.volumeIdentifier else { return nil }
        return DiskIdentity(file: file, volume: volume)
    }

    /// Camera folder names already in the shoot: "Video" / "Photo" -> folder names.
    static func existingFolders(in shoot: URL) -> [String: [String]] {
        var foldersBySection: [String: [String]] = [:]
        for section in [ShootPlanner.videoFolder, ShootPlanner.photoFolder] {
            let sectionFolder = shoot.appendingPathComponent(section, isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: sectionFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            foldersBySection[section] = folders.map(\.lastPathComponent).sorted()
        }
        return foldersBySection
    }

    /// Points each camera at the folder spelling that already exists in the shoot (case-insensitive,
    /// Video before Photo). No match keeps the camera's own name; a lone "FX3" never adopts "FX3 A".
    static func mapCameras(detected: [Camera], existing: [String: [String]]) -> [Camera] {
        // Photo first so a Video spelling overwrites it: Video wins.
        var spellingByLowercased: [String: String] = [:]
        for section in [ShootPlanner.photoFolder, ShootPlanner.videoFolder] {
            for name in existing[section] ?? [] { spellingByLowercased[name.lowercased()] = name }
        }
        return detected.map { camera in
            guard let existingName = spellingByLowercased[camera.folderName.lowercased()],
                  existingName != camera.folderName else { return camera }
            var renamed = camera
            renamed.folderName = existingName
            renamed.defaultFolderName = existingName
            return renamed
        }
    }

    /// Video/Photo/<camera> jobs on every copy; unknown cameras go to `Other`, audio to Video.
    /// `.flat` drops the camera level (Video/ or Photo/ directly), renaming cross-camera stem collisions.
    /// `existing`: `ShootPlanner.existingNamesOffMain(in: ShootPlanner.flatDirectories(copies:))` for `.flat`.
    static func sortedJobs(files: [MediaFile], copies: [URL], cameras: [Camera],
                           layout: ShootLayout = .cameraFolders, existing: [URL: [String: Int64]] = [:]) -> [CopyJob] {
        ShootPlanner.jobs(missing: files, copies: copies, cameras: cameras, fallback: fallbackFolder, layout: layout,
                          existing: existing)
    }

    /// Everything flat into `folder` (inside `primary`), mirrored at the same relative path on each copy.
    static func exactJobs(files: [MediaFile], copies: [URL], primary: URL, folder: URL) throws -> [CopyJob] {
        func isReserved(_ component: String) -> Bool { reserved.contains(component.lowercased()) }
        guard let relative = ShootPlanner.relativeComponents(folder, to: primary),
              let resolvedRelative = ShootPlanner.relativeComponents(ShootPlanner.resolvedPath(folder),
                                                                     to: ShootPlanner.resolvedPath(primary)),
              !relative.contains(where: isReserved),
              !resolvedRelative.contains(where: isReserved)
        else { throw ImportRefusal.destinationNotInShoot }

        let folderPerCopy = copies.map { copy -> URL in
            var folder = copy
            for component in relative { folder.appendPathComponent(component, isDirectory: true) }
            return folder
        }
        return files.flatMap { file in
            zip(copies, folderPerCopy).map { copy, folder in CopyJob(file: file, destDir: folder, root: copy) }
        }
    }
}
