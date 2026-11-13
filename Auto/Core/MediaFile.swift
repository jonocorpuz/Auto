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

    /// A file on a shoot copy (not a card) used as the source of a sync copy job.
    static func syncSource(url: URL, size: Int64, modified: Date) -> MediaFile {
        MediaFile(url: url, size: size, date: modified, kind: MediaTypes.kind(for: url) ?? .video, cameraID: "", cardID: "copy")
    }

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
    /// Name to fall back to when the user clears the folder field (includes any "A"/"B" suffix).
    var defaultFolderName: String

    init(id: String, model: String, serial: String?, folderName: String, label: String? = nil) {
        self.id = id
        self.model = model
        self.serial = serial
        self.folderName = folderName
        self.defaultFolderName = folderName
        self.label = label ?? model
    }

    /// Cameras sharing a model get letter suffixes ("FX3 A", "FX3 B", ..., then numbers after Z),
    /// assigned in `id` order so they are stable across scans. Suffixes that would collide
    /// (case-insensitively) with another camera's name on the card are skipped.
    /// Output keeps the input order.
    static func disambiguated(_ cameras: [Camera]) -> [Camera] {
        let groups = Dictionary(grouping: cameras, by: \.model)
        var taken = Set<String>()
        for cam in cameras where (groups[cam.model]?.count ?? 0) <= 1 {
            taken.insert(cam.label.lowercased())
            taken.insert(cam.folderName.lowercased())
        }
        var suffixByID: [String: String] = [:]
        for model in groups.keys.sorted() {
            guard let group = groups[model], group.count > 1 else { continue }
            var suffixNumber = 0
            for cam in group.sorted(by: { $0.id < $1.id }) {
                while true {
                    let suffix = suffixText(suffixNumber)
                    suffixNumber += 1
                    let label = "\(cam.label) \(suffix)".lowercased()
                    let folder = "\(cam.folderName) \(suffix)".lowercased()
                    if taken.contains(label) || taken.contains(folder) { continue }
                    taken.insert(label)
                    taken.insert(folder)
                    suffixByID[cam.id] = suffix
                    break
                }
            }
        }
        return cameras.map { cam in
            guard let suffix = suffixByID[cam.id] else { return cam }
            var renamed = cam
            renamed.label = "\(cam.label) \(suffix)"
            renamed.folderName = "\(cam.folderName) \(suffix)"
            renamed.defaultFolderName = renamed.folderName
            return renamed
        }
    }

    /// 0 -> "A" ... 25 -> "Z", then 26 -> "1", 27 -> "2", ...
    private static func suffixText(_ number: Int) -> String {
        let letterCount = 26
        guard number < letterCount else { return String(number - letterCount + 1) }
        let letterA: UInt8 = 65
        return String(UnicodeScalar(letterA + UInt8(number)))
    }
}
