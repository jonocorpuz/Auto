import Foundation

nonisolated enum MediaTypes {
    static let video: Set<String> = ["mp4", "mov", "mxf", "m4v", "avi", "mts", "m2ts", "braw", "r3d", "crm", "insv", "360", "mkv"]
    static let photo: Set<String> = ["jpg", "jpeg", "heic", "heif", "arw", "cr2", "cr3", "nef", "nrw", "raf", "dng", "orf", "rw2", "pef", "srw", "tif", "tiff", "png", "insp"]
    static let audio: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff"]
    static let all = video.union(photo).union(audio)

    /// Thumbnail, proxy and housekeeping folders cameras write next to the real media.
    static let skippedFolders: Set<String> = ["thmbnl", "thumb", "thumbnails", "sub", "misc", "general", "cache", ".spotlight-v100", ".fseventsd", ".trashes"]

    static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if video.contains(ext) { return .video }
        if photo.contains(ext) { return .photo }
        if audio.contains(ext) { return .audio }
        return nil
    }
}
