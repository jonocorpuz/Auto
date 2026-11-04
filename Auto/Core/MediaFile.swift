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

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var key: String { MediaFile.key(name: name, size: size) }

    /// Files are matched across volumes by name + size, the same way you'd eyeball it in Finder.
    static func key(name: String, size: Int64) -> String { "\(name.lowercased())|\(size)" }
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
