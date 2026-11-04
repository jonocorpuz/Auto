import Foundation

nonisolated enum CardPhase: Equatable, Sendable {
    case scanning, verifying, needsBackup, ready, copying, backed, failed(String)
    /// Scanned fine but no recognized media. Never backed: there may be files Auto doesn't know.
    case empty
    /// The card (or part of it) couldn't be read, so Auto can't say what's on it.
    case unreadable(String)

    /// Phase straight after a scan when verification can't apply: a scan error wins over
    /// an empty result, and neither ever becomes `.backed`. nil means go on and verify.
    static func afterScan(fileCount: Int, error: String?) -> CardPhase? {
        if let error { return .unreadable(error) }
        if fileCount == 0 { return .empty }
        return nil
    }

    /// Phase after verification of a card's files. nil keeps `current` (a `.failed` card stays failed).
    /// Never `.backed` while anything is missing, so a partial shoot stays "needs backup".
    /// Mirrors AppModel.finishRecompute: all verified -> backed; else a plan -> ready; else needsBackup.
    static func afterVerify(fileCount: Int, missingCount: Int, hasPlan: Bool, current: CardPhase) -> CardPhase? {
        if missingCount == 0 && fileCount > 0 { return .backed }
        if hasPlan { return .ready }
        if case .failed = current { return nil }
        return .needsBackup
    }
}

nonisolated struct CopyPlan: Sendable {
    var jobs: [CopyJob]
    var destinationLabel: String
    var destinationRoot: URL
    var bytes: Int64 { jobs.reduce(0) { $0 + $1.file.size } }
}

/// Pure helpers for naming shoot folders and turning missing files into copy jobs.
nonisolated enum ShootPlanner {
    static let videoFolder = "Video"
    static let photoFolder = "Photo"

    enum PathError: LocalizedError, Equatable {
        case invalidName
        case outsideWorkFolder
        case notAFolder(String)
        case onCard

        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a shoot name that works as a folder name."
            case .outsideWorkFolder: "That shoot folder would land outside your work folder."
            case .notAFolder(let name): "\u{201C}\(name)\u{201D} already exists as a file, so Auto can't make a folder there."
            case .onCard: CardDestinationError().localizedDescription
            }
        }
    }

    /// One safe folder name: "/" and ":" become "-", control characters are dropped and the
    /// result is trimmed. nil for "", "." and "..", which would not create a folder of their own.
    static func safeComponent(_ raw: String) -> String? {
        let replaced = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let visible = String(String.UnicodeScalarView(replaced.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    /// Path components with "." and ".." removed purely lexically. Never touches the disk, so a
    /// not-yet-created folder and its existing parent are spelled the same way (no /private juggling).
    static func lexicalComponents(_ url: URL) -> [String] {
        var out: [String] = []
        for c in url.pathComponents {
            if c == "." || c.isEmpty { continue }
            if c == ".." { if out.count > 1 { out.removeLast() } else { continue } }
            else { out.append(c) }
        }
        return out
    }

    /// Components of `url` below `base`, or nil if `url` is not equal to or inside `base` (lexical).
    static func relativeComponents(_ url: URL, to base: URL) -> [String]? {
        let b = lexicalComponents(base), c = lexicalComponents(url)
        guard c.count >= b.count, Array(c.prefix(b.count)) == b else { return nil }
        return Array(c.dropFirst(b.count))
    }

    /// True when `url` is strictly inside `root` (lexical comparison; no disk access).
    static func isInside(_ url: URL, root: URL) -> Bool {
        guard let rel = relativeComponents(url, to: root) else { return false }
        return !rel.isEmpty
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Symlink-resolved path even when the leaf doesn't exist yet: resolves the nearest existing
    /// ancestor and re-appends the remaining components.
    static func resolvedPath(_ url: URL) -> URL {
        var rest: [String] = []
        var probe = URL(fileURLWithPath: "/" + lexicalComponents(url).dropFirst().joined(separator: "/"))
        while probe.path != "/" && !exists(probe) {
            rest.insert(probe.lastPathComponent, at: 0)
            probe.deleteLastPathComponent()
        }
        var resolved = probe.resolvingSymlinksInPath()
        for part in rest { resolved.appendPathComponent(part) }
        return resolved
    }

    /// Throws unless creating `dir` is safe: it resolves (through symlinks) to `root` or inside it,
    /// is not on a card, and every existing component between root and dir is a folder.
    static func checkDestination(_ dir: URL, root: URL, cardVolumes: [URL]) throws {
        let rDir = resolvedPath(dir), rRoot = resolvedPath(root)
        if VolumeClassifier.isOnCard(dir, cards: cardVolumes) || VolumeClassifier.isOnCard(rDir, cards: cardVolumes) {
            throw PathError.onCard
        }
        guard relativeComponents(dir, to: root) != nil, relativeComponents(rDir, to: rRoot) != nil else {
            throw PathError.outsideWorkFolder
        }
        var current = root
        for part in relativeComponents(dir, to: root) ?? [] {
            current.appendPathComponent(part, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
                throw PathError.notAFolder(part)
            }
        }
    }

    /// Creates each directory one component at a time from `root`, checking every step first, so a
    /// symlink or file in the way is rejected before anything is created behind it.
    static func createDirectories(_ dirs: [URL], root: URL, cardVolumes: [URL]) throws {
        let fm = FileManager.default
        try checkDestination(root, root: root, cardVolumes: cardVolumes)
        if !exists(root) { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        for dir in dirs {
            guard let rel = relativeComponents(dir, to: root) else { throw PathError.outsideWorkFolder }
            var current = root
            for part in rel {
                current.appendPathComponent(part, isDirectory: true)
                try checkDestination(current, root: root, cardVolumes: cardVolumes)
                if !exists(current) { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
            }
        }
    }

    /// First path component of any destination that exists but isn't a folder (preview warning).
    static func problem(for dirs: [URL]) -> PathError? {
        for dir in dirs {
            var current = URL(fileURLWithPath: "/")
            for part in lexicalComponents(dir).dropFirst() {
                current.appendPathComponent(part)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir) {
                    if !isDir.boolValue { return .notAFolder(part) }
                } else { break }
            }
        }
        return nil
    }

    /// Shoot folder: root/<name>. Throws if the name isn't usable or the result would escape `root`.
    static func shootURL(root: URL, name: String) throws -> URL {
        guard let folder = safeComponent(name) else { throw PathError.invalidName }
        let shoot = root.appendingPathComponent(folder, isDirectory: true)
        guard isInside(shoot, root: root) else { throw PathError.outsideWorkFolder }
        return shoot
    }

    /// Unique destination directories of the jobs, sorted by path.
    static func directories(for jobs: [CopyJob]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for job in jobs where seen.insert(job.destDir.path).inserted { result.append(job.destDir) }
        return result.sorted { $0.path < $1.path }
    }

    /// Folder tree rows for the preview: shoot, then Video and Photo sections with their camera folders.
    static func folders(for jobs: [CopyJob], shoot: URL, root: URL) -> [PlannedFolder] {
        func parts(_ url: URL, relativeTo base: URL) -> [String]? { relativeComponents(url, to: base) }
        guard let shootParts = parts(shoot, relativeTo: root) else { return [] }
        var rows = [PlannedFolder(components: shootParts, fileCount: 0, isPhoto: false)]
        for section in [videoFolder, photoFolder] {
            var order: [[String]] = []
            var counts: [[String]: Int] = [:]
            for job in jobs {
                guard let rel = parts(job.destDir, relativeTo: shoot), rel.first == section else { continue }
                if counts[rel] == nil { order.append(rel) }
                counts[rel, default: 0] += 1
            }
            guard !order.isEmpty else { continue }
            let isPhoto = section == photoFolder
            rows.append(PlannedFolder(components: shootParts + [section], fileCount: counts[[section]] ?? 0, isPhoto: isPhoto))
            for rel in order where rel != [section] {
                rows.append(PlannedFolder(components: shootParts + rel, fileCount: counts[rel] ?? 0, isPhoto: isPhoto))
            }
        }
        return rows
    }

    /// Video/Photo/<camera folder> per missing file. Cameras with an empty folder name use their model;
    /// files from unknown cameras go to `fallback`.
    static func jobs(missing: [MediaFile], shoot: URL, cameras: [Camera], fallback: String) -> [CopyJob] {
        var folderFor: [String: String] = [:]
        for camera in cameras {
            folderFor[camera.id] = safeComponent(camera.folderName) ?? safeComponent(camera.model) ?? "Camera"
        }
        let fallbackFolder = safeComponent(fallback) ?? "Card"
        return missing.map { file in
            let section = file.kind == .photo ? photoFolder : videoFolder
            let dir = shoot.appendingPathComponent(section).appendingPathComponent(folderFor[file.cameraID] ?? fallbackFolder)
            return CopyJob(file: file, destDir: dir)
        }
    }

    static func plan(jobs: [CopyJob], shoot: URL) -> CopyPlan {
        let labels = Set(jobs.map { $0.destDir.lastPathComponent }).sorted()
        return CopyPlan(jobs: jobs, destinationLabel: labels.joined(separator: ", "), destinationRoot: shoot)
    }

    /// Everything into one chosen folder.
    static func flatPlan(missing: [MediaFile], into dir: URL) -> CopyPlan {
        CopyPlan(jobs: missing.map { CopyJob(file: $0, destDir: dir) }, destinationLabel: dir.lastPathComponent, destinationRoot: dir)
    }

}

/// One row of the planned folder tree shown before copying.
nonisolated struct PlannedFolder: Sendable, Equatable, Identifiable {
    var components: [String]
    var fileCount: Int
    var isPhoto: Bool
    var exists = false
    var id: String { components.joined(separator: "/") }
    var name: String { components.last ?? "" }
    var depth: Int { components.count - 1 }
}

/// Aggregate status across cards.
nonisolated enum StatusAggregator {
    enum Result: Equatable, Sendable { case idle, unbacked, copying, backed, error }

    /// Priority: copying > error > unbacked > (anything still verifying, or empty: idle) > backed > idle.
    /// An unreadable card is an error; an empty card is neutral but never lets the total go green.
    /// A failed card is reported as `error` because the user has to act on it; it still means unbacked data,
    /// which `error` outranks so the failure isn't masked by another card needing backup.
    static func aggregate(_ phases: [CardPhase]) -> Result {
        if phases.contains(.copying) { return .copying }
        if phases.contains(where: {
            switch $0 { case .failed, .unreadable: true; default: false }
        }) { return .error }
        if phases.contains(where: { $0 == .needsBackup || $0 == .ready }) { return .unbacked }
        // Never show green while a card's files are still being checksum-checked.
        if phases.contains(.verifying) || phases.contains(.empty) { return .idle }
        if phases.contains(.backed) { return .backed }
        return .idle
    }
}
