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
    /// Camera detection reads file headers; this many at once.
    private static let concurrency = 4

    private struct Candidate {
        let url: URL
        let origin: URL
        let size: Int64
        let date: Date
        let kind: MediaKind
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]

    /// Read-only: expands files and folders, never writes or moves anything.
    @concurrent static func scan(_ roots: [URL], shootRoots: [URL], onProgress: @escaping @Sendable (Int) -> Void) async throws -> ImportScan {
        var collector = Collector(shootRoots: shootRoots, onProgress: onProgress)
        for root in roots {
            try Task.checkCancellation()
            try collector.collect(root)
        }
        collector.reportProgress(force: true)
        try Task.checkCancellation()

        let detected = try await detectCameras(collector.candidates)
        return staged(collector.candidates, cameras: detected, into: collector.result)
    }

    // MARK: Collecting files

    /// Walks the dropped roots, gathering candidates and refusals.
    private struct Collector {
        let shootRoots: [URL]
        let onProgress: @Sendable (Int) -> Void
        var result = ImportScan()
        var candidates: [Candidate] = []
        /// Resolved paths already collected, so a file reached twice is staged once.
        private var seen = Set<String>()
        private var lastReport = ContinuousClock.now

        /// Progress is reported every this many files, or at least this often.
        private static let reportEveryFiles = 200
        private static let reportInterval: Duration = .milliseconds(100)

        init(shootRoots: [URL], onProgress: @escaping @Sendable (Int) -> Void) {
            self.shootRoots = shootRoots
            self.onProgress = onProgress
        }

        mutating func reportProgress(force: Bool = false) {
            let now = ContinuousClock.now
            let count = candidates.count
            guard force || count % Self.reportEveryFiles == 0 || now - lastReport >= Self.reportInterval else { return }
            lastReport = now
            onProgress(count)
        }

        private mutating func add(_ url: URL, origin: URL, kind: MediaKind, values: URLResourceValues) {
            let key = ShootPlanner.resolvedPath(url).path
            guard seen.insert(key).inserted else { return }
            let date = values.contentModificationDate ?? values.creationDate ?? Date()
            candidates.append(Candidate(url: url, origin: origin, size: Int64(values.fileSize ?? 0), date: date, kind: kind))
            reportProgress()
        }

        /// One dropped or chosen item: a file, or a folder walked recursively.
        mutating func collect(_ root: URL) throws {
            let top = root.standardizedFileURL
            if let refusal = ImportPlanner.refusal(for: top, shootRoots: shootRoots) {
                result.refused.append((top, refusal))
                return
            }
            let resolvedTop = ShootPlanner.resolvedPath(top)
            guard let topValues = try? resolvedTop.resourceValues(forKeys: Set(ImportScanner.resourceKeys)) else {
                result.refused.append((top, .unreadable("Couldn't read \(top.lastPathComponent).")))
                return
            }

            if topValues.isDirectory == true {
                try collectFolder(top, resolved: resolvedTop)
            } else if topValues.isRegularFile == true, let kind = MediaTypes.kind(for: resolvedTop) {
                add(top, origin: top, kind: kind, values: topValues)
            } else {
                result.ignoredCount += 1
            }
        }

        private mutating func collectFolder(_ top: URL, resolved resolvedTop: URL) throws {
            let keySet = Set(ImportScanner.resourceKeys)
            let errorBox = ErrorBox()
            guard let walker = FileManager.default.enumerator(
                at: resolvedTop, includingPropertiesForKeys: ImportScanner.resourceKeys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    if errorBox.first == nil { errorBox.first = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)" }
                    return true
                }) else {
                result.refused.append((top, .unreadable("Couldn't read \(top.lastPathComponent).")))
                return
            }

            while let url = walker.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: keySet) else {
                    result.ignoredCount += 1
                    continue
                }
                if values.isSymbolicLink == true {
                    collectSymlink(url, top: top, resolvedTop: resolvedTop)
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

            if let failure = errorBox.first { result.refused.append((top, .unreadable(failure))) }
        }

        /// Follows only links whose target is a media file inside the folder being imported.
        private mutating func collectSymlink(_ url: URL, top: URL, resolvedTop: URL) {
            let target = ShootPlanner.resolvedPath(url)
            guard ShootPlanner.isInside(target, root: resolvedTop),
                  let targetValues = try? target.resourceValues(forKeys: Set(ImportScanner.resourceKeys)),
                  targetValues.isRegularFile == true,
                  let kind = MediaTypes.kind(for: target) else {
                result.ignoredCount += 1
                return
            }
            if let refusal = ImportPlanner.refusal(for: url, shootRoots: shootRoots) {
                result.refused.append((url, refusal))
            } else {
                add(url, origin: top, kind: kind, values: targetValues)
            }
        }
    }

    // MARK: Cameras

    /// The camera of each candidate (same order), detected with bounded concurrency.
    private static func detectCameras(_ candidates: [Candidate]) async throws -> [Camera?] {
        var detected = [Camera?](repeating: nil, count: candidates.count)
        try await withThrowingTaskGroup(of: (Int, Camera).self) { group in
            var nextIndex = 0
            func launchNext() {
                guard nextIndex < candidates.count else { return }
                let index = nextIndex
                let candidate = candidates[index]
                nextIndex += 1
                group.addTask {
                    (index, await CardScanner.detectCamera(candidate.url, kind: candidate.kind, fallback: ImportPlanner.fallbackFolder))
                }
            }
            for _ in 0..<min(concurrency, candidates.count) { launchNext() }
            while let (index, camera) = try await group.next() {
                try Task.checkCancellation()
                detected[index] = camera
                launchNext()
            }
        }
        return detected
    }

    /// `scan` with the staged files (sorted by path) and the disambiguated cameras filled in.
    private static func staged(_ candidates: [Candidate], cameras detected: [Camera?], into scan: ImportScan) -> ImportScan {
        var firstCameraByID: [String: Camera] = [:]
        for camera in detected.compactMap({ $0 }) where firstCameraByID[camera.id] == nil {
            firstCameraByID[camera.id] = camera
        }
        let cameras = Camera.disambiguated(firstCameraByID.values.sorted { ($0.model, $0.id) < ($1.model, $1.id) })
        let folderByID = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0.folderName) })

        var files: [StagedFile] = []
        for (index, candidate) in candidates.enumerated() {
            guard let camera = detected[index] else { continue }
            let media = MediaFile(url: candidate.url, size: candidate.size, date: candidate.date, kind: candidate.kind,
                                  cameraID: camera.id, cardID: cardID)
            let folder = folderByID[camera.id] ?? ImportPlanner.fallbackFolder
            files.append(StagedFile(file: media, origin: candidate.origin, cameraFolder: folder))
        }

        var result = scan
        result.files = files.sorted { $0.file.url.path < $1.file.url.path }
        result.cameras = cameras
        return result
    }

    private final class ErrorBox: @unchecked Sendable { var first: String? }
}
