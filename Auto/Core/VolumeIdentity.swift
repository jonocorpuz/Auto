import Foundation

/// Stable-per-mount identity for a card: volume UUID (or the opaque volume identifier) plus its
/// normalized path. Folders that aren't volume roots (fixture cards) are identified by path alone.
nonisolated enum VolumeIdentity {
    static func of(_ url: URL) -> String {
        let path = VolumeClassifier.normalizedPath(url)
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeUUIDStringKey, .volumeIdentifierKey]
        // A fresh URL so cached resource values from an earlier mount aren't reused.
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let root = values.volume, VolumeClassifier.normalizedPath(root) == path else {
            return "path@\(path)"
        }
        if let uuid = values.volumeUUIDString { return "\(uuid)@\(path)" }
        if let id = values.volumeIdentifier { return "\(String(describing: id))@\(path)" }
        return "path@\(path)"
    }
}
