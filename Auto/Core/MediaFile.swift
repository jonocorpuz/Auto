import Foundation

nonisolated enum MediaKind: Sendable, Hashable {
    case video, photo, audio
}

nonisolated struct MediaFile: Identifiable, Sendable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    let kind: MediaKind
    let cameraID: String
    /// Identity of the card volume the file was scanned from (see `VolumeIdentity`).
    var cardID = ""

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var key: String { MediaFile.key(name: name, size: size) }

    /// Files are matched across volumes by name + size, the same way you'd eyeball it in Finder.
    static func key(name: String, size: Int64) -> String { "\(name.lowercased())|\(size)" }

    /// One specific file on one specific card: card identity + full path + size + mtime.
    /// Unlike `key`, two cards' same-name, same-size files never share an identity.
    var identity: String { "\(cardID)|\(url.standardizedFileURL.path)|\(size)|\(date.timeIntervalSince1970)" }
}

nonisolated struct Camera: Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    /// Part of identity (`id`) only; never shown in `label` or used in `folderName`.
    let serial: String?
    var folderName: String
    var label: String

    init(id: String, model: String, serial: String?, folderName: String, label: String? = nil) {
        self.id = id
        self.model = model
        self.serial = serial
        self.folderName = folderName
        self.label = label ?? model
    }

    /// Cameras sharing a model get letter suffixes ("FX3 A", "FX3 B", ..., then numbers after Z),
    /// assigned in `id` order so they are stable across scans. Output keeps the input order.
    static func disambiguated(_ cameras: [Camera]) -> [Camera] {
        let groups = Dictionary(grouping: cameras, by: \.model)
        var suffix: [String: String] = [:]
        for (_, group) in groups where group.count > 1 {
            for (i, cam) in group.sorted(by: { $0.id < $1.id }).enumerated() {
                suffix[cam.id] = i < 26 ? String(UnicodeScalar(UInt8(65 + i))) : String(i - 25)
            }
        }
        return cameras.map { cam in
            guard let s = suffix[cam.id] else { return cam }
            var out = cam
            out.label = "\(cam.label) \(s)"
            out.folderName = "\(cam.folderName) \(s)"
            return out
        }
    }
}
