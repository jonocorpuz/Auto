import Foundation

/// A media file picked for import, with the camera folder it will land in.
nonisolated struct StagedFile: Identifiable, Hashable, Sendable {
    let file: MediaFile
    /// The root the user dropped or chose that this file came from.
    let origin: URL
    let cameraFolder: String
    var id: URL { file.url }
}

nonisolated struct ImportScan: Sendable {
    var files: [StagedFile] = []
    var cameras: [Camera] = []
    var refused: [(URL, ImportRefusal)] = []
    var ignoredCount = 0
}

nonisolated enum ImportScanner {
    static let cardID = "import"
    private static let concurrency = 4

    private struct Candidate {
        let url: URL
        let origin: URL
        let size: Int64
        let date: Date
        let kind: MediaKind
    }

    /// Read-only: expands files and folders, never writes or moves anything.
    @concurrent static func scan(_ roots: [URL], shootRoots: [URL], onProgress: @escaping @Sendable (Int) -> Void) async -> ImportScan {
        var result = ImportScan()
        var candidates: [Candidate] = []
        var seen = Set<String>()
        var count = 0

        func add(_ url: URL, origin: URL, kind: MediaKind, values: URLResourceValues) {
            let key = ShootPlanner.resolvedPath(url).path
            guard seen.insert(key).inserted else { return }
            let date = values.contentModificationDate ?? values.creationDate ?? Date()
            candidates.append(Candidate(url: url, origin: origin, size: Int64(values.fileSize ?? 0), date: date, kind: kind))
            count += 1
            onProgress(count)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let keySet = Set(keys)
        let fm = FileManager.default

        for root in roots {
            let top = root.standardizedFileURL
            if let refusal = ImportPlanner.refusal(for: top, shootRoots: shootRoots) {
                result.refused.append((top, refusal))
                continue
            }
            let resolvedTop = ShootPlanner.resolvedPath(top)
            guard let topValues = try? resolvedTop.resourceValues(forKeys: keySet) else {
                result.refused.append((top, .unreadable("Couldn't read \(top.lastPathComponent).")))
                continue
            }

            if topValues.isDirectory == true {
                var failure: String?
                let errorBox = ErrorBox()
                guard let walker = fm.enumerator(
                    at: resolvedTop, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, error in
                        if errorBox.first == nil { errorBox.first = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)" }
                        return true
                    }) else {
                    result.refused.append((top, .unreadable("Couldn't read \(top.lastPathComponent).")))
                    continue
                }
                while let url = walker.nextObject() as? URL {
                    guard let values = try? url.resourceValues(forKeys: keySet) else {
                        result.ignoredCount += 1
                        continue
                    }
                    if values.isSymbolicLink == true {
                        // Follow only links whose target stays inside the folder being imported.
                        let target = ShootPlanner.resolvedPath(url)
                        guard ShootPlanner.isInside(target, root: resolvedTop),
                              let tv = try? target.resourceValues(forKeys: keySet), tv.isRegularFile == true,
                              let kind = MediaTypes.kind(for: target) else {
                            result.ignoredCount += 1
                            continue
                        }
                        if let refusal = ImportPlanner.refusal(for: url, shootRoots: shootRoots) {
                            result.refused.append((url, refusal))
                        } else {
                            add(url, origin: top, kind: kind, values: tv)
                        }
                        continue
                    }
                    if values.isDirectory == true {
                        if MediaTypes.skippedFolders.contains(url.lastPathComponent.lowercased()) {
                            walker.skipDescendants()
                        } else if let refusal = ImportPlanner.refusal(for: url, shootRoots: shootRoots) {
                            result.refused.append((url, refusal))
                            walker.skipDescendants()
                        }
                        continue
                    }
                    guard values.isRegularFile == true, let kind = MediaTypes.kind(for: url) else {
                        result.ignoredCount += 1
                        continue
                    }
                    add(url, origin: top, kind: kind, values: values)
                }
                failure = errorBox.first
                if let failure { result.refused.append((top, .unreadable(failure))) }
            } else if topValues.isRegularFile == true, let kind = MediaTypes.kind(for: resolvedTop) {
                add(top, origin: top, kind: kind, values: topValues)
            } else {
                result.ignoredCount += 1
            }
        }

        // Detect the camera per file with bounded concurrency.
        var detected = [Camera?](repeating: nil, count: candidates.count)
        await withTaskGroup(of: (Int, Camera).self) { group in
            var next = 0
            func launch() {
                guard next < candidates.count else { return }
                let index = next
                let c = candidates[index]
                next += 1
                group.addTask { (index, await CardScanner.detectCamera(c.url, kind: c.kind, fallback: ImportPlanner.fallbackFolder)) }
            }
            for _ in 0..<min(concurrency, candidates.count) { launch() }
            while let (index, camera) = await group.next() {
                detected[index] = camera
                launch()
            }
        }

        var byID: [String: Camera] = [:]
        for camera in detected.compactMap({ $0 }) where byID[camera.id] == nil { byID[camera.id] = camera }
        let cameras = Camera.disambiguated(byID.values.sorted { ($0.model, $0.id) < ($1.model, $1.id) })
        let folderByID = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0.folderName) })

        var files: [StagedFile] = []
        for (index, c) in candidates.enumerated() {
            guard let camera = detected[index] else { continue }
            let media = MediaFile(url: c.url, size: c.size, date: c.date, kind: c.kind, cameraID: camera.id, cardID: cardID)
            files.append(StagedFile(file: media, origin: c.origin, cameraFolder: folderByID[camera.id] ?? ImportPlanner.fallbackFolder))
        }
        result.files = files.sorted { $0.file.url.path < $1.file.url.path }
        result.cameras = cameras
        return result
    }

    private final class ErrorBox: @unchecked Sendable { var first: String? }
}
