import Foundation

nonisolated enum DriveIndex {
    /// Every media file on the drive, grouped by name+size key. Same-key files are candidates only:
    /// they still need a checksum comparison before a card file counts as backed up.
    static func build(_ root: URL) async -> [String: [URL]] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var index: [String: [URL]] = [:]
        while let url = walker.nextObject() as? URL {
            guard MediaTypes.all.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            index[MediaFile.key(name: url.lastPathComponent, size: Int64(values.fileSize ?? 0)), default: []].append(url)
        }
        return index
    }
}
