import Foundation

/// Quick media tally of a shoot folder, plus one file to use as its thumbnail.
nonisolated struct ShootSummary: Sendable, Equatable {
    var videoCount: Int
    var photoCount: Int
    /// A photo if any exist, otherwise the first video (sorted by path).
    var representative: URL?
}

extension ShootSummary {
    @concurrent static func scan(_ folder: URL) async -> ShootSummary {
        let (videos, photos) = walk(folder)
        let rep = photos.min { $0.path < $1.path } ?? videos.min { $0.path < $1.path }
        return ShootSummary(videoCount: videos.count, photoCount: photos.count, representative: rep)
    }

    /// Synchronous walk (directory enumerators can't be iterated from an async context).
    nonisolated private static func walk(_ folder: URL) -> (videos: [URL], photos: [URL]) {
        var videos: [URL] = []
        var photos: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], []) }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            switch MediaTypes.kind(for: url) {
            case .video: videos.append(url)
            case .photo: photos.append(url)
            default: break
            }
        }
        return (videos, photos)
    }
}
