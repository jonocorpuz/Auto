import Foundation

nonisolated enum DriveIndex {
    /// Every media file on the drive, grouped by name+size key. Same-key files are candidates only:
    /// they still need a checksum comparison before a card file counts as backed up.
    /// `@concurrent`: with approachable concurrency a plain nonisolated async func would run on the
    /// caller's actor (the main actor) and freeze the UI while walking the drive.
    @concurrent static func build(_ root: URL) async -> [String: [URL]] {
        MainThreadProbe.shared.mark("DriveIndex.build")
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

    /// Extra candidates keyed by the name a renamed copy came from: "img_1 2.cr3|10" also nominates for
    /// "img_1.cr3|10", so a copy renamed to dodge a collision (CopyEngine's unique name, or a flat-layout
    /// stem rename) is still found on a later run. Only widens nominations: a checksum still decides.
    static func renamedAliases(_ index: [String: [URL]]) -> [String: [URL]] {
        var out: [String: [URL]] = [:]
        for (key, urls) in index {
            guard let bar = key.lastIndex(of: "|") else { continue }
            // Peel every suffix: a renamed name that was itself taken becomes "IMG_1 2 2.CR3".
            var name = String(key[..<bar])
            while let original = originalName(name) {
                out[original + key[bar...], default: []].append(contentsOf: urls)
                name = original
            }
        }
        return out
    }

    /// "<stem> <n>.<ext>" (n >= 2, the CopyEngine / flat-layout rename) -> "<stem>.<ext>"; nil otherwise.
    static func originalName(_ name: String) -> String? {
        let ns = name as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        guard let space = stem.lastIndex(of: " ") else { return nil }
        let digits = stem[stem.index(after: space)...]
        let base = stem[..<space]
        guard !base.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              digits.first != "0", let n = Int(digits), n >= 2 else { return nil }
        return ext.isEmpty ? String(base) : "\(base).\(ext)"
    }
}
