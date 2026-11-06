import Foundation

nonisolated struct SyncPlan: Sendable {
    /// One job per file missing from a copy. `root` = destination copy, `.skip`, `expectedChecksum` when known.
    var jobs: [CopyJob]
    /// Raw bytes to write, keyed by destination copy root.
    var bytesByDestination: [URL: Int64]
}

nonisolated enum SyncPlanError: LocalizedError, Equatable {
    case notChecksumChecked
    case notChecked
    case destinationNotThisShoot(String)
    case unsafePath(String)
    case insufficientSpace(drive: String, needed: Int64, free: Int64)
    case spaceUnknown(drive: String)

    var errorDescription: String? {
        switch self {
        case .notChecksumChecked:
            return "The copies haven't been fully checked yet. Check them again before syncing."
        case .notChecked:
            return "The copies couldn't be checked, so nothing was synced."
        case .destinationNotThisShoot(let path):
            return "The folder at \(path) isn't a copy of this shoot, so nothing was synced."
        case .unsafePath(let rel):
            return "\"\(rel)\" isn't a safe path inside the shoot, so nothing was synced."
        case .insufficientSpace(let drive, let needed, let free):
            let f = ByteCountFormatter()
            return "Not enough space on \(drive): needs \(f.string(fromByteCount: needed)), \(f.string(fromByteCount: free)) free."
        case .spaceUnknown(let drive):
            return "Can't tell how much space is free on \(drive), so nothing was synced."
        }
    }
}

/// Turns a fully checked `ShootSyncReport` into copy jobs. Reads sidecars, folders and source attributes
/// only (so it runs off the main actor). Plans only `missing` files, never conflicts, nothing destructive.
nonisolated enum ShootSyncPlanner {
    /// Per-volume slack on top of the planned bytes: filesystem overhead, other writers.
    static let volumeHeadroom: Int64 = 256 << 20
    /// Each file is rounded up to a multiple of this (allocation overhead).
    static let fileRounding: Int64 = 1 << 20

    /// Throws unless the report is a complete checksum-depth check, every source and destination root's
    /// sidecar carries `shootID`, and every relative path is a plain path below its root.
    @concurrent static func plan(report: ShootSyncReport, cache: ChecksumStore, shootID: UUID) async throws -> SyncPlan {
        guard report.notChecked == nil else { throw SyncPlanError.notChecked }
        guard report.depth == .checksums else { throw SyncPlanError.notChecksumChecked }

        var confirmed = Set<URL>()
        func confirm(_ root: URL) throws {
            if confirmed.contains(root) { return }
            let sidecarURL = root.appendingPathComponent(ShootSidecar.fileName)
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? ShootSidecar.decode(data), sidecar.id == shootID else {
                throw SyncPlanError.destinationNotThisShoot(root.path)
            }
            confirmed.insert(root)
        }
        var volumes: [URL: (id: String, root: URL)?] = [:]
        func volume(of root: URL) -> (id: String, root: URL)? {
            if let known = volumes[root] { return known }
            let v = ChecksumStore.volumeID(of: root)
            volumes[root] = .some(v)
            return v
        }
        var resolvedDirs: [String: URL] = [:]

        var jobs: [CopyJob] = []
        var bytes: [URL: Int64] = [:]
        for root in report.copies {
            let list = report.missing[root] ?? []
            if list.isEmpty { continue }
            try confirm(root)
            for item in list {
                guard report.copies.contains(item.source), item.source != root else {
                    throw SyncPlanError.destinationNotThisShoot(item.source.path)
                }
                try confirm(item.source)
                let parts = item.file.relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw SyncPlanError.unsafePath(item.file.relPath)
                }
                let destDir = resolveDirectory(root: root, components: Array(parts.dropLast()), memo: &resolvedDirs)
                let sourceURL = item.source.appendingPathComponent(item.file.relPath)
                let modified = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let media = MediaFile.syncSource(url: sourceURL, size: item.file.size, modified: modified)
                var expected = item.checksum
                if expected == nil {
                    let stamp: ChecksumStore.FileStamp?
                    if let v = volume(of: item.source) {
                        stamp = ChecksumStore.stamp(sourceURL, volumeID: v.id, volumeRoot: v.root)
                    } else {
                        stamp = ChecksumStore.stamp(sourceURL)
                    }
                    expected = stamp.flatMap { cache.checksum(for: $0) }
                }
                jobs.append(CopyJob(file: media, destDir: destDir, root: root, onCollision: .skip, expectedChecksum: expected))
                bytes[root, default: 0] += item.file.size
            }
        }
        return SyncPlan(jobs: jobs, bytesByDestination: bytes)
    }

    /// `root` + `components`, reusing an existing child folder whose folded name (NFC + case-insensitive,
    /// as the checker compares) matches, so a differently cased sibling is never created. An exact-name
    /// match wins. Components that don't exist yet are appended as spelled.
    private static func resolveDirectory(root: URL, components: [String], memo: inout [String: URL]) -> URL {
        var current = root
        var prefix = ""
        var exists = true
        for part in components {
            prefix += "/" + ShootSyncChecker.foldedKey(part)
            let memoKey = root.path + "|" + prefix
            if let hit = memo[memoKey] { current = hit; continue }
            var chosen = current.appendingPathComponent(part, isDirectory: true)
            if exists {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
                if names.contains(part) {
                    // The exact spelling exists.
                } else if let match = names.sorted().first(where: { ShootSyncChecker.foldedKey($0) == ShootSyncChecker.foldedKey(part) }) {
                    chosen = current.appendingPathComponent(match, isDirectory: true)
                } else {
                    exists = false
                }
            }
            memo[memoKey] = chosen
            current = chosen
        }
        return current
    }

    /// All-or-nothing: throws naming the first drive that can't hold what is planned for it.
    /// Destinations on the same volume are summed; each file is rounded up to 1 MB and each volume needs
    /// 256 MB of headroom. An unknown free size fails closed. Does disk I/O, so it runs off the main actor.
    @concurrent static func checkSpace(_ plan: SyncPlan, free: @Sendable (URL) -> Int64?,
                                       driveName: @Sendable (URL) -> String = ShootSyncPlanner.defaultDriveName) async throws {
        var roots: [URL] = []
        for job in plan.jobs { if let r = job.root, !roots.contains(r) { roots.append(r) } }
        for r in plan.bytesByDestination.keys where !roots.contains(r) { roots.append(r) }
        roots.sort { $0.path < $1.path }

        var needed: [String: (root: URL, bytes: Int64)] = [:]
        var order: [String] = []
        for root in roots {
            let key = volumeKey(of: root)
            if needed[key] == nil { order.append(key); needed[key] = (root, volumeHeadroom) }
            let jobs = plan.jobs.filter { $0.root == root }
            if jobs.isEmpty { needed[key]?.bytes += plan.bytesByDestination[root] ?? 0 }
            for job in jobs {
                let rounded = (job.file.size + fileRounding - 1) / fileRounding * fileRounding
                needed[key]?.bytes += max(rounded, fileRounding)
            }
        }
        for key in order {
            guard let entry = needed[key] else { continue }
            guard let available = free(entry.root) else { throw SyncPlanError.spaceUnknown(drive: driveName(entry.root)) }
            if available < entry.bytes {
                throw SyncPlanError.insufficientSpace(drive: driveName(entry.root), needed: entry.bytes, free: available)
            }
        }
    }

    /// Volume UUID, else the mount point, else the path itself.
    static func volumeKey(of url: URL) -> String {
        if let id = ChecksumStore.volumeID(of: url)?.id { return id }
        let fresh = URL(fileURLWithPath: url.path)
        if let mount = try? fresh.resourceValues(forKeys: [.volumeURLKey]).volume { return "mount@" + mount.path }
        return "path@" + url.path
    }

    static func defaultDriveName(_ url: URL) -> String {
        let fresh = URL(fileURLWithPath: url.path)
        if let name = try? fresh.resourceValues(forKeys: [.volumeNameKey]).volumeName, !name.isEmpty { return name }
        return url.lastPathComponent
    }
}
