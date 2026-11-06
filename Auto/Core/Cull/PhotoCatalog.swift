import Foundation

/// Walks a shoot's `Photo/` folder and groups files into photo records (RAW+JPEG pairs share one).
nonisolated enum PhotoCatalog {
    private static let previewable: Set<String> = ["jpg", "jpeg", "heic"]

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

        struct Entry { let rel: String; let stamp: FileStamp }
        var buckets: [String: (camera: String, entries: [Entry])] = [:]

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

        var records: [PhotoRecord] = []
        for (_, bucket) in buckets {
            let sorted = bucket.entries.sorted { $0.rel < $1.rel }
            let rep = sorted.first { previewable.contains(($0.rel as NSString).pathExtension.lowercased()) } ?? sorted[0]
            var stamps: [String: FileStamp] = [:]
            for e in sorted { stamps[e.rel] = e.stamp }
            records.append(PhotoRecord(id: rep.rel, camera: bucket.camera, members: sorted.map(\.rel),
                                       representative: rep.rel, stamps: stamps, metrics: nil, preview: nil, faceStrip: nil))
        }
        return records.sorted { ($0.camera, $0.id) < ($1.camera, $1.id) }
    }
}
