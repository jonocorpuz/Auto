import Foundation

nonisolated enum DriveIndex {
    /// Name+size keys for every media file on the drive.
    static func build(_ root: URL) async -> Set<String> {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var index = Set<String>()
        while let url = walker.nextObject() as? URL {
            guard MediaTypes.all.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            index.insert(MediaFile.key(name: url.lastPathComponent, size: Int64(values.fileSize ?? 0)))
        }
        return index
    }
}
