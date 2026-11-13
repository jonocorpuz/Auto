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
            let formatter = ByteCountFormatter()
            let neededText = formatter.string(fromByteCount: needed)
            let freeText = formatter.string(fromByteCount: free)
            return "Not enough space on \(drive): needs \(neededText), \(freeText) free."
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

        var builder = PlanBuilder(shootID: shootID, cache: cache)
        var jobs: [CopyJob] = []
        var bytes: [URL: Int64] = [:]
        for root in report.copies {
            let missingHere = report.missing[root] ?? []
            if missingHere.isEmpty { continue }
            try builder.confirmBelongsToShoot(root)
            for item in missingHere {
                let sourceIsAnotherCopy = report.copies.contains(item.source) && item.source != root
                guard sourceIsAnotherCopy else { throw SyncPlanError.destinationNotThisShoot(item.source.path) }
                try builder.confirmBelongsToShoot(item.source)
                jobs.append(try builder.job(copying: item, into: root))
                bytes[root, default: 0] += item.file.size
            }
        }
        return SyncPlan(jobs: jobs, bytesByDestination: bytes)
    }

    /// Memoized lookups for one `plan` run.
    private struct PlanBuilder {
        let shootID: UUID
        let cache: ChecksumStore
        /// Copy roots whose sidecar has been checked.
        private var confirmedRoots = Set<URL>()
        /// Copy root -> its volume (nil when it has none).
        private var volumes: [URL: (id: String, root: URL)?] = [:]
        /// See `resolveDirectory`.
        private var resolvedDirs: [String: URL] = [:]

        init(shootID: UUID, cache: ChecksumStore) {
            self.shootID = shootID
            self.cache = cache
        }

        mutating func confirmBelongsToShoot(_ root: URL) throws {
            if confirmedRoots.contains(root) { return }
            let sidecarURL = root.appendingPathComponent(ShootSidecar.fileName)
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? ShootSidecar.decode(data), sidecar.id == shootID else {
                throw SyncPlanError.destinationNotThisShoot(root.path)
            }
            confirmedRoots.insert(root)
        }

        mutating func job(copying item: SyncMissing, into root: URL) throws -> CopyJob {
            let components = item.file.relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let isUnsafe = components.isEmpty || components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            guard !isUnsafe else { throw SyncPlanError.unsafePath(item.file.relPath) }

            let destDir = ShootSyncPlanner.resolveDirectory(root: root, components: Array(components.dropLast()), memo: &resolvedDirs)
            let sourceURL = item.source.appendingPathComponent(item.file.relPath)
            let modified = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let media = MediaFile.syncSource(url: sourceURL, size: item.file.size, modified: modified)
            let expected = item.checksum ?? cachedChecksum(of: sourceURL, inCopy: item.source)
            return CopyJob(file: media, destDir: destDir, root: root, onCollision: .skip, expectedChecksum: expected)
        }

        private mutating func cachedChecksum(of sourceURL: URL, inCopy sourceRoot: URL) -> Data? {
            let stamp: ChecksumStore.FileStamp?
            if let volume = volume(of: sourceRoot) {
                stamp = ChecksumStore.stamp(sourceURL, volumeID: volume.id, volumeRoot: volume.root)
            } else {
                stamp = ChecksumStore.stamp(sourceURL)
            }
            return stamp.flatMap { cache.checksum(for: $0) }
        }

        private mutating func volume(of root: URL) -> (id: String, root: URL)? {
            if let known = volumes[root] { return known }
            let volume = ChecksumStore.volumeID(of: root)
            volumes[root] = .some(volume)
            return volume
        }
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
        // Every destination root, in path order.
        var roots: [URL] = []
        for job in plan.jobs {
            if let root = job.root, !roots.contains(root) { roots.append(root) }
        }
        for root in plan.bytesByDestination.keys where !roots.contains(root) { roots.append(root) }
        roots.sort { $0.path < $1.path }

        // Volume key -> a root on it and the bytes it needs; `volumeOrder` keeps first-seen order.
        var needed: [String: (root: URL, bytes: Int64)] = [:]
        var volumeOrder: [String] = []
        for root in roots {
            let key = volumeKey(of: root)
            if needed[key] == nil {
                volumeOrder.append(key)
                needed[key] = (root, volumeHeadroom)
            }
            let jobs = plan.jobs.filter { $0.root == root }
            if jobs.isEmpty { needed[key]?.bytes += plan.bytesByDestination[root] ?? 0 }
            for job in jobs {
                needed[key]?.bytes += allocatedSize(of: job.file.size)
            }
        }

        for key in volumeOrder {
            guard let entry = needed[key] else { continue }
            guard let available = free(entry.root) else { throw SyncPlanError.spaceUnknown(drive: driveName(entry.root)) }
            if available < entry.bytes {
                throw SyncPlanError.insufficientSpace(drive: driveName(entry.root), needed: entry.bytes, free: available)
            }
        }
    }

    /// `size` rounded up to a whole number of `fileRounding` units, at least one.
    private static func allocatedSize(of size: Int64) -> Int64 {
        let rounded = (size + fileRounding - 1) / fileRounding * fileRounding
        return max(rounded, fileRounding)
    }

    /// Volume UUID, else the mount point, else the path itself.
    private static func volumeKey(of url: URL) -> String {
        if let id = ChecksumStore.volumeID(of: url)?.id { return id }
        let fresh = URL(fileURLWithPath: url.path)
        if let mount = try? fresh.resourceValues(forKeys: [.volumeURLKey]).volume { return "mount@" + mount.path }
        return "path@" + url.path
    }

    private static func defaultDriveName(_ url: URL) -> String {
        let fresh = URL(fileURLWithPath: url.path)
        if let name = try? fresh.resourceValues(forKeys: [.volumeNameKey]).volumeName, !name.isEmpty { return name }
        return url.lastPathComponent
    }
}
