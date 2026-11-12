import Foundation

nonisolated struct CopyPlan: Sendable {
    var jobs: [CopyJob]
    var destinationLabel: String
    var destinationRoot: URL
    /// The work folder every destination must stay inside (falls back to `destinationRoot`).
    var workRoot: URL?
    /// Every copy root the jobs write to (primary first). Empty = just `workRoot ?? destinationRoot`.
    var roots: [URL] = []
    /// The shoot these jobs add to (nil for flat folder plans).
    var shootID: UUID?

    var bytes: Int64 {
        jobs.reduce(0) { total, job in total + job.file.size }
    }

    var copyRoots: [URL] {
        if roots.isEmpty { return [workRoot ?? destinationRoot] }
        return roots
    }
}

/// Pure helpers for naming shoot folders and turning missing files into copy jobs.
/// The flat-layout renaming rules live in `ShootPlanner+FlatNames.swift`.
nonisolated enum ShootPlanner {
    static let videoFolder = "Video"
    static let photoFolder = "Photo"

    enum PathError: LocalizedError, Equatable {
        case outsideWorkFolder
        case notAFolder(String)
        case onCard
        case workFolderMissing

        var errorDescription: String? {
            switch self {
            case .outsideWorkFolder: "That shoot folder would land outside your work folder."
            case .notAFolder(let name): "\u{201C}\(name)\u{201D} already exists as a file, so Auto can't make a folder there."
            case .onCard: CardDestinationError().localizedDescription
            case .workFolderMissing: "Your work folder isn't available. Connect the drive or choose it again in Settings."
            }
        }
    }

    // MARK: Folder names and lexical paths

    /// One safe folder name: "/" and ":" become "-", control characters are dropped and the
    /// result is trimmed. nil for "", "." and "..", which would not create a folder of their own.
    static func safeComponent(_ raw: String) -> String? {
        let withoutSeparators = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let visibleScalars = withoutSeparators.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let visible = String(String.UnicodeScalarView(visibleScalars))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    /// Path components with "." and ".." removed purely lexically. Never touches the disk, so a
    /// not-yet-created folder and its existing parent are spelled the same way (no /private juggling).
    static func lexicalComponents(_ url: URL) -> [String] {
        var components: [String] = []
        for component in url.pathComponents {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                // ".." steps up one level, but never above the leading "/".
                if components.count > 1 { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return components
    }

    /// Components of `url` below `base`, or nil if `url` is not equal to or inside `base` (lexical).
    static func relativeComponents(_ url: URL, to base: URL) -> [String]? {
        let baseComponents = lexicalComponents(base)
        let urlComponents = lexicalComponents(url)
        guard urlComponents.count >= baseComponents.count,
              Array(urlComponents.prefix(baseComponents.count)) == baseComponents else { return nil }
        return Array(urlComponents.dropFirst(baseComponents.count))
    }

    /// True when `url` is strictly inside `root` (lexical comparison; no disk access).
    static func isInside(_ url: URL, root: URL) -> Bool {
        guard let componentsBelowRoot = relativeComponents(url, to: root) else { return false }
        return !componentsBelowRoot.isEmpty
    }

    // MARK: Destination safety

    /// True for anything at the path, including a dangling symlink (which `fileExists` misses).
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Symlink-resolved path even when the leaf doesn't exist yet: resolves the nearest existing
    /// ancestor and re-appends the remaining components.
    static func resolvedPath(_ url: URL) -> URL {
        let lexicalPath = "/" + lexicalComponents(url).dropFirst().joined(separator: "/")
        var existingAncestor = URL(fileURLWithPath: lexicalPath)
        var missingComponents: [String] = []
        while existingAncestor.path != "/" && !exists(existingAncestor) {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents { resolved.appendPathComponent(component) }
        return resolved
    }

    /// Throws unless creating `dir` is safe: it resolves (through symlinks) to `root` or inside it,
    /// is not on a card, and every existing component between root and dir is a folder.
    static func checkDestination(_ dir: URL, root: URL, cardVolumes: [URL]) throws {
        let resolvedDir = resolvedPath(dir)
        let resolvedRoot = resolvedPath(root)

        let isOnCard = VolumeClassifier.isOnCard(dir, cards: cardVolumes)
            || VolumeClassifier.isOnCard(resolvedDir, cards: cardVolumes)
        if isOnCard { throw PathError.onCard }

        guard let componentsBelowRoot = relativeComponents(dir, to: root),
              relativeComponents(resolvedDir, to: resolvedRoot) != nil else {
            throw PathError.outsideWorkFolder
        }

        var current = root
        for component in componentsBelowRoot {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue { throw PathError.notAFolder(component) }
            } else if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                // Dangling symlink: its target can't be vouched for, so never write through it.
                throw PathError.outsideWorkFolder
            }
        }
    }

    /// Creates each directory one component at a time from `root`, checking every step first, so a
    /// symlink or file in the way is rejected before anything is created behind it.
    static func createDirectories(_ dirs: [URL], root: URL, cardVolumes: [URL]) throws {
        let fileManager = FileManager.default
        try checkDestination(root, root: root, cardVolumes: cardVolumes)

        // Never create the root: a missing drive must not grow a tree on the wrong disk.
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            throw PathError.workFolderMissing
        }

        for dir in dirs {
            guard let componentsBelowRoot = relativeComponents(dir, to: root) else { throw PathError.outsideWorkFolder }
            var current = root
            for component in componentsBelowRoot {
                current.appendPathComponent(component, isDirectory: true)
                try checkDestination(current, root: root, cardVolumes: cardVolumes)
                if !exists(current) {
                    try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
                }
            }
        }
    }

    // MARK: Copy jobs

    /// "Photo" for photos, "Video" for everything else (video and audio).
    static func sectionFolder(for file: MediaFile) -> String {
        file.kind == .photo ? photoFolder : videoFolder
    }

    /// Unique destination directories of the jobs, sorted by path.
    static func directories(for jobs: [CopyJob]) -> [URL] {
        var seenPaths = Set<String>()
        var directories: [URL] = []
        for job in jobs where seenPaths.insert(job.destDir.path).inserted {
            directories.append(job.destDir)
        }
        return directories.sorted { $0.path < $1.path }
    }

    /// Video/Photo/<camera folder> per missing file. Cameras with an empty folder name use their model;
    /// files from unknown cameras go to `fallback`. `.flat` puts every file straight into Video/ or Photo/
    /// (cameras and fallback ignored) and renames stem collisions (see `uniquifyFlatStems`); `existing`
    /// and `related` only matter for `.flat`.
    static func jobs(missing: [MediaFile], shoot: URL, cameras: [Camera], fallback: String,
                     layout: ShootLayout = .cameraFolders, existing: [URL: [String: Int64]] = [:],
                     related: [MediaFile] = []) -> [CopyJob] {
        if layout == .flat {
            let flatJobs = missing.map { file in
                CopyJob(file: file, destDir: flatDirectory(file, shoot: shoot))
            }
            return uniquifyFlatStems(flatJobs, existing: existing, related: related)
        }

        let folderByCameraID = cameraFolderNames(cameras)
        let fallbackFolder = safeComponent(fallback) ?? "Card"
        // Names differing only by case are one folder on APFS: keep the first spelling seen per section.
        var firstSpelling: [String: String] = [:]
        return missing.map { file in
            let section = sectionFolder(for: file)
            let requestedFolder = folderByCameraID[file.cameraID] ?? fallbackFolder
            let caseInsensitiveKey = section + "/" + requestedFolder.lowercased()
            let folder = firstSpelling[caseInsensitiveKey, default: requestedFolder]
            firstSpelling[caseInsensitiveKey] = folder
            let destDir = shoot.appendingPathComponent(section).appendingPathComponent(folder)
            return CopyJob(file: file, destDir: destDir)
        }
    }

    /// Camera id -> folder name: the user's name, else the default name, else the model, else "Camera".
    private static func cameraFolderNames(_ cameras: [Camera]) -> [String: String] {
        var folderByCameraID: [String: String] = [:]
        for camera in cameras {
            folderByCameraID[camera.id] = safeComponent(camera.folderName)
                ?? safeComponent(camera.defaultFolderName)
                ?? safeComponent(camera.model)
                ?? "Camera"
        }
        return folderByCameraID
    }

    /// One job per file per copy, file-major (f1 to every copy, then f2, ...). Every job carries its copy
    /// `root`, so a copy that disappears fails with `.rootMissing` instead of being recreated.
    /// `.flat` names are planned once across all copies (what is on disk in any copy counts), so every
    /// copy gets the same name.
    static func jobs(missing: [MediaFile], copies: [URL], cameras: [Camera], fallback: String,
                     layout: ShootLayout = .cameraFolders, existing: [URL: [String: Int64]] = [:],
                     related: [MediaFile] = []) -> [CopyJob] {
        if layout == .flat {
            let flatJobs = missing.flatMap { file in
                copies.map { copy in
                    CopyJob(file: file, destDir: flatDirectory(file, shoot: copy), root: copy)
                }
            }
            return uniquifyFlatStems(flatJobs, existing: existing, related: related)
        }

        let jobsPerCopy: [[CopyJob]] = copies.map { copy in
            let unrooted = jobs(missing: missing, shoot: copy, cameras: cameras, fallback: fallback)
            return unrooted.map { job in
                var rooted = job
                rooted.root = copy
                return rooted
            }
        }
        return missing.indices.flatMap { fileIndex in
            jobsPerCopy.map { jobsForOneCopy in jobsForOneCopy[fileIndex] }
        }
    }

    private static func flatDirectory(_ file: MediaFile, shoot: URL) -> URL {
        shoot.appendingPathComponent(sectionFolder(for: file))
    }

    /// The folders a flat plan writes to on each copy (Video/ and Photo/), for `existingNames`.
    static func flatDirectories(copies: [URL]) -> [URL] {
        copies.flatMap { copy in
            [copy.appendingPathComponent(videoFolder), copy.appendingPathComponent(photoFolder)]
        }
    }

    /// The size `existingNames` reports for an entry that is not a regular file (a folder, a symlink).
    private static let sizeOfNonRegularFile: Int64 = -1

    /// Lowercased name -> size (-1 when not a regular file) of every visible entry in each folder; a
    /// missing folder maps to [:]. Reads the disk: call `existingNamesOffMain` from the main actor.
    static func existingNames(in dirs: [URL]) -> [URL: [String: Int64]] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var namesByDirectory: [URL: [String: Int64]] = [:]
        for dir in dirs {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            var sizeByName: [String: Int64] = [:]
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let isRegularFile = values?.isRegularFile == true
                let size = isRegularFile ? Int64(values?.fileSize ?? 0) : sizeOfNonRegularFile
                sizeByName[entry.lastPathComponent.lowercased()] = size
            }
            namesByDirectory[dir] = sizeByName
        }
        return namesByDirectory
    }

    @concurrent static func existingNamesOffMain(in dirs: [URL]) async -> [URL: [String: Int64]] {
        existingNames(in: dirs)
    }

    // MARK: Plans

    static func plan(jobs: [CopyJob], shoot: URL, workRoot: URL? = nil, roots: [URL] = [], shootID: UUID? = nil) -> CopyPlan {
        let destinationFolderNames = Set(jobs.map { $0.destDir.lastPathComponent }).sorted()
        return CopyPlan(jobs: jobs,
                        destinationLabel: destinationFolderNames.joined(separator: ", "),
                        destinationRoot: shoot,
                        workRoot: workRoot,
                        roots: roots,
                        shootID: shootID)
    }

    /// Everything into one chosen folder.
    static func flatPlan(missing: [MediaFile], into dir: URL) -> CopyPlan {
        let jobs = missing.map { file in CopyJob(file: file, destDir: dir, root: dir) }
        return CopyPlan(jobs: jobs, destinationLabel: dir.lastPathComponent, destinationRoot: dir, workRoot: dir)
    }
}
