import Foundation

/// Walks a shoot's `Photo/` folder and groups files into photo records (RAW+JPEG pairs share one).
nonisolated enum PhotoCatalog {
    /// One photo file found by the walk, shoot-relative.
    private struct Entry { let rel: String; let stamp: FileStamp }
    /// Files that may belong to one photo: same folder and stem.
    private typealias Bucket = (camera: String, entries: [Entry])

    private static let previewable: Set<String> = ["jpg", "jpeg", "heic"]
    /// Max mtime spread for same-stem files directly in Photo/ to count as one RAW+JPEG photo.
    static let pairWindow: TimeInterval = 5

    static func scan(shoot: URL, cardVolumes: [URL]) throws -> [PhotoRecord] {
        let resolved = ShootPlanner.resolvedPath(shoot)
        if VolumeClassifier.isOnCard(shoot, cards: cardVolumes) || VolumeClassifier.isOnCard(resolved, cards: cardVolumes) {
            throw CullError.onCard
        }
        let fm = FileManager.default
        let photoDir = shoot.appendingPathComponent("Photo", isDirectory: true)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
        guard let rootValues = try? photoDir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              rootValues.isSymbolicLink != true, rootValues.isDirectory == true,
              let walker = fm.enumerator(at: photoDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }

        var buckets: [String: Bucket] = [:]

        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { if v.isDirectory == true { walker.skipDescendants() }; continue }
            if v.isSymbolicLink == true { if v.isDirectory == true { walker.skipDescendants() }; continue }
            if v.isDirectory == true {
                if name == "_Rejects" { walker.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, MediaTypes.kind(for: url) == .photo else { continue }
            // Last `level` components, independent of how the enumerator spells the base path.
            let parts = Array(url.pathComponents.suffix(walker.level))
            let inner = parts.joined(separator: "/")
            let camera = parts.count > 1 ? parts[0] : ""
            let dir = parts.dropLast().joined(separator: "/")
            let base = (name as NSString).deletingPathExtension.lowercased()
            let key = dir.lowercased() + "/" + base
            let stamp = FileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate ?? .distantPast)
            buckets[key, default: (camera, [])].entries.append(Entry(rel: "Photo/" + inner, stamp: stamp))
        }

        return splitFlatBuckets(Array(buckets.values))
            .map(record(for:))
            .sorted { ($0.camera, $0.id) < ($1.camera, $1.id) }
    }

    // MARK: - Steps

    private static func splitFlatBuckets(_ buckets: [Bucket]) -> [Bucket] {
        var groups: [Bucket] = []
        for bucket in buckets {
            // Directly in Photo/ (flat layout) different cameras can share a stem, so only files written
            // within `pairWindow` of each other pair up; camera folders keep pairing on stem alone.
            guard bucket.camera.isEmpty, bucket.entries.count > 1 else { groups.append(bucket); continue }
            let byRel = Dictionary(uniqueKeysWithValues: bucket.entries.map { ($0.rel, $0) })
            for cluster in flatClusters(bucket.entries.map { ($0.rel, $0.stamp.mtime) }) {
                groups.append((bucket.camera, cluster.compactMap { byRel[$0] }))
            }
        }
        return groups
    }

    /// One photo from its files. The first previewable file (by path) represents it and is its ID.
    private static func record(for bucket: Bucket) -> PhotoRecord {
        let sorted = bucket.entries.sorted { $0.rel < $1.rel }
        let rep = sorted.first { previewable.contains(($0.rel as NSString).pathExtension.lowercased()) } ?? sorted[0]
        var stamps: [String: FileStamp] = [:]
        for e in sorted { stamps[e.rel] = e.stamp }
        return PhotoRecord(id: rep.rel, camera: bucket.camera, members: sorted.map(\.rel),
                           representative: rep.rel, stamps: stamps, metrics: nil, preview: nil, faceStrip: nil)
    }

    /// Same-stem files directly in Photo/, split into photos: sorted by mtime, a file joins the current
    /// group only within `pairWindow` of the group's first file. An unknown mtime (`.distantPast`)
    /// never pairs: such a file is a photo of its own.
    static func flatClusters(_ entries: [(rel: String, mtime: Date)]) -> [[String]] {
        var out: [[String]] = []
        var cluster: [(rel: String, mtime: Date)] = []
        for e in entries.sorted(by: { ($0.mtime, $0.rel) < ($1.mtime, $1.rel) }) {
            if e.mtime == .distantPast { out.append([e.rel]); continue }
            if let start = cluster.first, e.mtime.timeIntervalSince(start.mtime) > pairWindow {
                out.append(cluster.map(\.rel))
                cluster = []
            }
            cluster.append(e)
        }
        if !cluster.isEmpty { out.append(cluster.map(\.rel)) }
        return out
    }
}
