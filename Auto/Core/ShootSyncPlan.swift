import Foundation

nonisolated struct SyncPlan: Sendable {
    /// One job per file missing from a copy. `root` = destination copy, `.skip`, `expectedChecksum` when known.
    var jobs: [CopyJob]
    /// Bytes to write, keyed by destination copy root.
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

/// Turns a fully checked `ShootSyncReport` into copy jobs. Reads sidecars and source attributes only.
/// Plans only `missing` files, never conflicts, and nothing destructive.
nonisolated enum ShootSyncPlanner {
    /// Throws unless the report is a complete checksum-depth check, every destination root's sidecar
    /// carries `shootID`, and every relative path is a plain path below its root.
    static func plan(report: ShootSyncReport, cache: ChecksumStore, shootID: UUID) throws -> SyncPlan {
        guard report.notChecked == nil else { throw SyncPlanError.notChecked }
        guard report.depth == .checksums else { throw SyncPlanError.notChecksumChecked }

        var jobs: [CopyJob] = []
        var bytes: [URL: Int64] = [:]
        for root in report.copies {
            let list = report.missing[root] ?? []
            if list.isEmpty { continue }
            let sidecarURL = root.appendingPathComponent(ShootSidecar.fileName)
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? ShootSidecar.decode(data), sidecar.id == shootID else {
                throw SyncPlanError.destinationNotThisShoot(root.path)
            }
            for item in list {
                let parts = item.file.relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw SyncPlanError.unsafePath(item.file.relPath)
                }
                var destDir = root
                for part in parts.dropLast() { destDir = destDir.appendingPathComponent(part, isDirectory: true) }
                let sourceURL = item.source.appendingPathComponent(item.file.relPath)
                let modified = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let media = MediaFile.syncSource(url: sourceURL, size: item.file.size, modified: modified)
                let expected = ChecksumStore.stamp(sourceURL).flatMap { cache.checksum(for: $0) }
                jobs.append(CopyJob(file: media, destDir: destDir, root: root, onCollision: .skip, expectedChecksum: expected))
                bytes[root, default: 0] += item.file.size
            }
        }
        return SyncPlan(jobs: jobs, bytesByDestination: bytes)
    }

    /// All-or-nothing: throws naming the first drive that can't hold what is planned for it.
    /// Destinations on the same volume are summed. An unknown free size fails closed.
    static func checkSpace(_ plan: SyncPlan, free: (URL) -> Int64?,
                           driveName: (URL) -> String = ShootSyncPlanner.defaultDriveName) throws {
        var needed: [String: (root: URL, bytes: Int64)] = [:]
        var order: [String] = []
        for root in plan.bytesByDestination.keys.sorted(by: { $0.path < $1.path }) {
            let key = ChecksumStore.volumeID(of: root)?.id ?? root.path
            if needed[key] == nil { order.append(key); needed[key] = (root, 0) }
            needed[key]?.bytes += plan.bytesByDestination[root] ?? 0
        }
        for key in order {
            guard let entry = needed[key] else { continue }
            guard let available = free(entry.root) else { throw SyncPlanError.spaceUnknown(drive: driveName(entry.root)) }
            if available < entry.bytes {
                throw SyncPlanError.insufficientSpace(drive: driveName(entry.root), needed: entry.bytes, free: available)
            }
        }
    }

    static func defaultDriveName(_ url: URL) -> String {
        let fresh = URL(fileURLWithPath: url.path)
        if let name = try? fresh.resourceValues(forKeys: [.volumeNameKey]).volumeName, !name.isEmpty { return name }
        return url.lastPathComponent
    }
}
