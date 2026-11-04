import AVFoundation
import Foundation
import ImageIO

nonisolated enum CardScanner {
    struct Result: Sendable {
        var files: [MediaFile]
        var cameras: [Camera]
        var shootDate: Date?
    }

    static func scan(_ volume: URL, volumeName: String) async -> Result {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(at: volume, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return Result(files: [], cameras: [], shootDate: nil)
        }

        var files: [MediaFile] = []
        var camerasByDir: [String: Camera] = [:]
        var cameras: [String: Camera] = [:]

        while let url = walker.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if MediaTypes.skippedFolders.contains(url.lastPathComponent.lowercased()) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let kind = MediaTypes.kind(for: url) else { continue }

            let dir = url.deletingLastPathComponent().path
            let camera: Camera
            if let known = camerasByDir[dir] {
                camera = known
            } else {
                camera = await detectCamera(url, kind: kind, fallback: volumeName)
                camerasByDir[dir] = camera
            }
            cameras[camera.id] = cameras[camera.id] ?? camera

            let date = values.contentModificationDate ?? values.creationDate ?? Date()
            files.append(MediaFile(url: url, size: Int64(values.fileSize ?? 0), date: date, kind: kind, cameraID: camera.id))
        }

        let shootDate = files.map(\.date).min()
        let sortedCameras = cameras.values.sorted { $0.model < $1.model }
        return Result(files: files.sorted { $0.url.path < $1.url.path }, cameras: sortedCameras, shootDate: shootDate)
    }

    // MARK: Camera detection

    static func detectCamera(_ url: URL, kind: MediaKind, fallback: String) async -> Camera {
        var model: String?
        var serial: String?

        if let sony = sonySidecar(for: url) {
            (model, serial) = sony
        } else if kind == .photo {
            (model, serial) = exifCamera(url)
        } else if kind == .video {
            model = await quickTimeModel(url)
        }

        let name = model.map(friendlyName) ?? fallback
        let id = "\(name)|\(serial ?? "")"
        return Camera(id: id, model: name, serial: serial, folderName: name)
    }

    /// Sony writes C0001M01.XML next to C0001.MP4 with a <Device modelName serialNo> tag.
    private static func sonySidecar(for url: URL) -> (String?, String?)? {
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for name in ["\(base)M01.XML", "\(base)M01.xml", "\(base).XML"] {
            guard let xml = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
                  let device = xml.range(of: "<Device[^>]*>", options: .regularExpression) else { continue }
            let tag = String(xml[device])
            return (attribute("modelName", in: tag), attribute("serialNo", in: tag))
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
        let value = tag[range].dropFirst(name.count + 2).dropLast()
        return value.isEmpty ? nil : String(value)
    }

    private static func exifCamera(_ url: URL) -> (String?, String?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let serial = (exif?[kCGImagePropertyExifBodySerialNumber] as? String) ?? (aux?[kCGImagePropertyExifAuxSerialNumber] as? String)
        return (model, serial)
    }

    private static func quickTimeModel(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.commonKey == .commonKeyModel || item.identifier == .quickTimeMetadataModel {
            if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }

    /// "ILME-FX3" → "FX3", "ILCE-7SM3" → "A7SM3", "Canon EOS R5" → "R5".
    static func friendlyName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("ILME-") { name = String(name.dropFirst(5)) }
        if name.hasPrefix("ILCE-") { name = "A" + name.dropFirst(5) }
        for prefix in ["Canon EOS ", "NIKON ", "Nikon "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
