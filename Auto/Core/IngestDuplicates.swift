import Foundation

/// Finds card files that already have a checksum-verified copy somewhere other than the shoot being
/// added to ("duplicates"), and says where those copies live. The verdict itself comes from
/// `BackupVerifier` (`backups` / `missing`); nothing here hashes. Path containment is lexical, like
/// `CardBrowser`. Pure except for `revalidate`, which stats files.
nonisolated enum IngestDuplicates {
    /// Where a verified copy lives: a shoot, or else a plain folder on some drive.
    struct Place: Sendable, Hashable {
        let title: String
        let drive: String
        let shootID: UUID?
    }

    struct PlaceCount: Sendable, Hashable {
        let place: Place
        let count: Int
    }

    struct DriveCount: Sendable, Hashable {
        let drive: String
        let count: Int
        let bytes: Int64
    }

    /// A shoot and every copy root it has (primary plus mirrors).
    struct ShootRoots: Sendable, Hashable {
        let id: UUID
        let name: String
        let roots: [URL]
    }

    struct Report: Sendable, Equatable {
        /// Duplicates, in input order.
        var files: [MediaFile] = []
        var bytes: Int64 = 0
        /// Sorted by count descending (ties by title).
        var byPlace: [PlaceCount] = []
        /// Sorted by count descending (ties by drive name).
        var byDrive: [DriveCount] = []
        /// Where each duplicate's copy lives, so `revalidate` can rebuild the totals.
        fileprivate var placements: [URL: Place] = [:]

        var isEmpty: Bool { files.isEmpty }
        var count: Int { files.count }
    }

    /// `candidates`: the files the user is about to copy (after selection and not-in-target filtering).
    /// A file is a duplicate iff `backups[url] != nil`, `url` is not in `missing`, and its copy is not
    /// inside any of `target`'s roots (those are reported by shoot coverage instead).
    /// Place = the deepest shoot containing the copy, else the copy's parent folder.
    static func find(candidates: [MediaFile], backups: [URL: URL], missing: Set<URL>,
                     shoots: [ShootRoots], target: UUID?) -> Report {
        let targetRoots = shoots.first { $0.id == target }?.roots.map(canonical) ?? []
        var placements: [URL: Place] = [:]
        var files: [MediaFile] = []
        for file in candidates {
            guard let copy = backups[file.url], !missing.contains(file.url) else { continue }
            let path = canonical(copy)
            if targetRoots.contains(where: { contains($0, path) }) { continue }
            placements[file.url] = place(of: copy, in: shoots)
            files.append(file)
        }
        return report(files: files, placements: placements)
    }

    /// Off main: keeps only duplicates whose copy is still recorded identical in `cache` (stat + lookup).
    /// A copy that vanished or changed since the verdict becomes a normal file to copy.
    @concurrent static func revalidate(_ report: Report, backups: [URL: URL], cache: VerificationCache) async -> Report {
        var kept: [MediaFile] = []
        var placements: [URL: Place] = [:]
        for file in report.files {
            guard let copy = backups[file.url],
                  let size = try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.size,
                  cache.verifiedCandidate(for: file, in: [copy]) != nil else { continue }
            kept.append(file)
            placements[file.url] = report.placements[file.url]
        }
        return Self.report(files: kept, placements: placements)
    }

    /// "/Volumes/<name>" lexically, else "This Mac".
    static func driveName(_ url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if components.count > 2, components[0] == "/", components[1] == "Volumes" { return components[2] }
        return "This Mac"
    }

    // MARK: - Private

    private static func report(files: [MediaFile], placements: [URL: Place]) -> Report {
        var placeCounts: [Place: Int] = [:]
        var driveCounts: [String: (count: Int, bytes: Int64)] = [:]
        for file in files {
            guard let place = placements[file.url] else { continue }
            placeCounts[place, default: 0] += 1
            let soFar = driveCounts[place.drive] ?? (0, 0)
            driveCounts[place.drive] = (soFar.count + 1, soFar.bytes + file.size)
        }
        let byPlace = placeCounts
            .map { PlaceCount(place: $0.key, count: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.place.title < b.place.title
            }
        let byDrive = driveCounts
            .map { DriveCount(drive: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.drive < b.drive
            }
        return Report(files: files, bytes: files.reduce(0) { $0 + $1.size },
                      byPlace: byPlace, byDrive: byDrive, placements: placements)
    }

    private static func place(of copy: URL, in shoots: [ShootRoots]) -> Place {
        let path = canonical(copy)
        let drive = driveName(copy)
        // Deepest = longest root path containing the copy.
        var deepest: (shoot: ShootRoots, rootLength: Int)?
        for shoot in shoots {
            for root in shoot.roots.map(canonical) where contains(root, path) {
                let isDeeper = root.count > (deepest?.rootLength ?? -1)
                if isDeeper { deepest = (shoot, root.count) }
            }
        }
        if let deepest { return Place(title: deepest.shoot.name, drive: drive, shootID: deepest.shoot.id) }
        let parent = copy.standardizedFileURL.deletingLastPathComponent().lastPathComponent
        return Place(title: "\(drive) › \(parent)", drive: drive, shootID: nil)
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
