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

        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a shoot name that works as a folder name."
            case .outsideWorkFolder: "That shoot folder would land outside your work folder."
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

    /// True when `url` is strictly inside `root` (standardized paths, trailing "/" on the root).
    static func isInside(_ url: URL, root: URL) -> Bool {
        let r = root.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
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
        func parts(_ url: URL, relativeTo base: URL) -> [String]? {
            let b = base.standardizedFileURL.pathComponents
            let c = url.standardizedFileURL.pathComponents
            guard c.count >= b.count, Array(c.prefix(b.count)) == b else { return nil }
            return Array(c.dropFirst(b.count))
        }
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
