import Foundation

/// Quick media tally of a shoot folder, plus one file to use as its thumbnail.
nonisolated struct ShootSummary: Sendable, Equatable {
    var videoCount: Int
    var photoCount: Int
    /// Separate audio files (recorders, lavs).
    var audioCount = 0
    /// A photo if any exist, otherwise the first video (sorted by path).
    var representative: URL?
}

extension ShootSummary {
    @concurrent static func scan(_ folder: URL) async -> ShootSummary {
        let (videos, photos, audio) = walk(folder)
        let rep = photos.min { $0.path < $1.path } ?? videos.min { $0.path < $1.path }
        return ShootSummary(videoCount: videos.count, photoCount: photos.count, audioCount: audio, representative: rep)
    }

    /// Synchronous walk (directory enumerators can't be iterated from an async context).
    nonisolated private static func walk(_ folder: URL) -> (videos: [URL], photos: [URL], audio: Int) {
        var videos: [URL] = []
        var photos: [URL] = []
        var audio = 0
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], [], 0) }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            switch MediaTypes.kind(for: url) {
            case .video: videos.append(url)
            case .photo: photos.append(url)
            case .audio: audio += 1
            default: break
            }
        }
        return (videos, photos, audio)
    }
}
