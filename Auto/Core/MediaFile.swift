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
    let serial: String?
    var folderName: String

    var label: String {
        guard let serial, serial.count >= 4 else { return model }
        return "\(model) · serial ...\(serial.suffix(4))"
    }
}
