import Foundation

nonisolated enum CardPhase: Equatable, Sendable {
    case scanning, verifying, needsBackup, ready, copying, backed, failed(String)
    /// Scanned fine but no recognized media. Never backed: there may be files Auto doesn't know.
    case empty
    /// The card (or part of it) couldn't be read, so Auto can't say what's on it.
    case unreadable(String)

    /// Phase straight after a scan when verification can't apply: a scan error wins over
    /// an empty result, and neither ever becomes `.backed`. nil means go on and verify.
    static func afterScan(fileCount: Int, error: String?) -> CardPhase? {
        if let error { return .unreadable(error) }
        if fileCount == 0 { return .empty }
        return nil
    }

    /// Phase after verification of a card's files. nil keeps `current` (a `.failed` card stays failed).
    /// Never `.backed` while anything is missing, so a partial shoot stays "needs backup".
    /// Mirrors AppModel.finishRecompute: all verified -> backed; else a plan -> ready; else needsBackup.
    static func afterVerify(fileCount: Int, missingCount: Int, hasPlan: Bool, current: CardPhase) -> CardPhase? {
        if missingCount == 0 && fileCount > 0 { return .backed }
        if hasPlan { return .ready }
        if case .failed = current { return nil }
        return .needsBackup
    }
}

nonisolated struct CopyPlan: Sendable {
    var jobs: [CopyJob]
    var destinationLabel: String
    var destinationRoot: URL
    /// The work folder every destination must stay inside (falls back to `destinationRoot`).
    var workRoot: URL?
    /// Every copy root the jobs write to (primary first). Empty = just `workRoot ?? destinationRoot`.
    var roots: [URL] = []
    /// The shoot these jobs add to (nil for flat folder plans).
    var shootID: UUID?
    var bytes: Int64 { jobs.reduce(0) { $0 + $1.file.size } }
    var copyRoots: [URL] { roots.isEmpty ? [workRoot ?? destinationRoot] : roots }
}

/// Pure helpers for naming shoot folders and turning missing files into copy jobs.
nonisolated enum ShootPlanner {
    static let videoFolder = "Video"
    static let photoFolder = "Photo"

    enum PathError: LocalizedError, Equatable {
        case invalidName
        case outsideWorkFolder
        case notAFolder(String)
        case onCard
        case workFolderMissing

        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a shoot name that works as a folder name."
            case .outsideWorkFolder: "That shoot folder would land outside your work folder."
            case .notAFolder(let name): "\u{201C}\(name)\u{201D} already exists as a file, so Auto can't make a folder there."
            case .onCard: CardDestinationError().localizedDescription
            case .workFolderMissing: "Your work folder isn't available. Connect the drive or choose it again in Settings."
            }
        }
    }

    /// One safe folder name: "/" and ":" become "-", control characters are dropped and the
    /// result is trimmed. nil for "", "." and "..", which would not create a folder of their own.
    static func safeComponent(_ raw: String) -> String? {
        let replaced = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let visible = String(String.UnicodeScalarView(replaced.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    /// Path components with "." and ".." removed purely lexically. Never touches the disk, so a
    /// not-yet-created folder and its existing parent are spelled the same way (no /private juggling).
    static func lexicalComponents(_ url: URL) -> [String] {
        var out: [String] = []
        for c in url.pathComponents {
            if c == "." || c.isEmpty { continue }
            if c == ".." { if out.count > 1 { out.removeLast() } else { continue } }
            else { out.append(c) }
        }
        return out
    }

    /// Components of `url` below `base`, or nil if `url` is not equal to or inside `base` (lexical).
    static func relativeComponents(_ url: URL, to base: URL) -> [String]? {
        let b = lexicalComponents(base), c = lexicalComponents(url)
        guard c.count >= b.count, Array(c.prefix(b.count)) == b else { return nil }
        return Array(c.dropFirst(b.count))
    }

    /// True when `url` is strictly inside `root` (lexical comparison; no disk access).
    static func isInside(_ url: URL, root: URL) -> Bool {
        guard let rel = relativeComponents(url, to: root) else { return false }
        return !rel.isEmpty
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Symlink-resolved path even when the leaf doesn't exist yet: resolves the nearest existing
    /// ancestor and re-appends the remaining components.
    static func resolvedPath(_ url: URL) -> URL {
        var rest: [String] = []
        var probe = URL(fileURLWithPath: "/" + lexicalComponents(url).dropFirst().joined(separator: "/"))
        while probe.path != "/" && !exists(probe) {
            rest.insert(probe.lastPathComponent, at: 0)
            probe.deleteLastPathComponent()
        }
        var resolved = probe.resolvingSymlinksInPath()
        for part in rest { resolved.appendPathComponent(part) }
        return resolved
    }

    /// Throws unless creating `dir` is safe: it resolves (through symlinks) to `root` or inside it,
    /// is not on a card, and every existing component between root and dir is a folder.
    static func checkDestination(_ dir: URL, root: URL, cardVolumes: [URL]) throws {
        let rDir = resolvedPath(dir), rRoot = resolvedPath(root)
        if VolumeClassifier.isOnCard(dir, cards: cardVolumes) || VolumeClassifier.isOnCard(rDir, cards: cardVolumes) {
            throw PathError.onCard
        }
        guard relativeComponents(dir, to: root) != nil, relativeComponents(rDir, to: rRoot) != nil else {
            throw PathError.outsideWorkFolder
        }
        var current = root
        for part in relativeComponents(dir, to: root) ?? [] {
            current.appendPathComponent(part, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir) {
                if !isDir.boolValue { throw PathError.notAFolder(part) }
            } else if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                // Dangling symlink: its target can't be vouched for, so never write through it.
                throw PathError.outsideWorkFolder
            }
        }
    }

    /// Creates each directory one component at a time from `root`, checking every step first, so a
    /// symlink or file in the way is rejected before anything is created behind it.
    static func createDirectories(_ dirs: [URL], root: URL, cardVolumes: [URL]) throws {
        let fm = FileManager.default
        try checkDestination(root, root: root, cardVolumes: cardVolumes)
        // Never create the root: a missing drive must not grow a tree on the wrong disk.
        var rootIsDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &rootIsDir), rootIsDir.boolValue else {
            throw PathError.workFolderMissing
        }
        for dir in dirs {
            guard let rel = relativeComponents(dir, to: root) else { throw PathError.outsideWorkFolder }
            var current = root
            for part in rel {
                current.appendPathComponent(part, isDirectory: true)
                try checkDestination(current, root: root, cardVolumes: cardVolumes)
                if !exists(current) { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
            }
        }
    }

    /// Shoot folder: root/<name>. Throws if the name isn't usable or the result would escape `root`.
    static func shootURL(root: URL, name: String) throws -> URL {
        guard let folder = safeComponent(name) else { throw PathError.invalidName }
        let shoot = root.appendingPathComponent(folder, isDirectory: true)
        guard isInside(shoot, root: root) else { throw PathError.outsideWorkFolder }
        return shoot
    }

    /// Unique destination directories of the jobs, sorted by path.
    static func directories(for jobs: [CopyJob]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for job in jobs where seen.insert(job.destDir.path).inserted { result.append(job.destDir) }
        return result.sorted { $0.path < $1.path }
    }

    /// Video/Photo/<camera folder> per missing file. Cameras with an empty folder name use their model;
    /// files from unknown cameras go to `fallback`. `.flat` puts every file straight into Video/ or Photo/
    /// (cameras and fallback ignored) and renames cross-set stem collisions (see `uniquifyFlatStems`).
    static func jobs(missing: [MediaFile], shoot: URL, cameras: [Camera], fallback: String,
                     layout: ShootLayout = .cameraFolders) -> [CopyJob] {
        if layout == .flat {
            return uniquifyFlatStems(missing.map { file in
                CopyJob(file: file, destDir: shoot.appendingPathComponent(file.kind == .photo ? photoFolder : videoFolder))
            })
        }
        var folderFor: [String: String] = [:]
        for camera in cameras {
            folderFor[camera.id] = safeComponent(camera.folderName)
                ?? safeComponent(camera.defaultFolderName)
                ?? safeComponent(camera.model)
                ?? "Camera"
        }
        let fallbackFolder = safeComponent(fallback) ?? "Card"
        // Names differing only by case are one folder on APFS: keep the first spelling seen per section.
        var spelling: [String: String] = [:]
        return missing.map { file in
            let section = file.kind == .photo ? photoFolder : videoFolder
            let raw = folderFor[file.cameraID] ?? fallbackFolder
            let name = spelling[section + "/" + raw.lowercased(), default: raw]
            spelling[section + "/" + raw.lowercased()] = name
            let dir = shoot.appendingPathComponent(section).appendingPathComponent(name)
            return CopyJob(file: file, destDir: dir)
        }
    }

    /// One job per file per copy, file-major (f1 to every copy, then f2, ...). Every job carries its copy
    /// `root`, so a copy that disappears fails with `.rootMissing` instead of being recreated.
    /// Every copy is planned from the same `missing` list, so a flat rename is identical on every copy.
    static func jobs(missing: [MediaFile], copies: [URL], cameras: [Camera], fallback: String,
                     layout: ShootLayout = .cameraFolders) -> [CopyJob] {
        let perCopy = copies.map { copy in
            jobs(missing: missing, shoot: copy, cameras: cameras, fallback: fallback, layout: layout).map { job -> CopyJob in
                var rooted = job
                rooted.root = copy
                return rooted
            }
        }
        return missing.indices.flatMap { i in perCopy.map { $0[i] } }
    }

    /// Stem and extension as spelled ("" when there is no extension).
    private static func splitName(_ name: String) -> (stem: String, ext: String) {
        let ns = name as NSString
        return (ns.deletingPathExtension, ns.pathExtension)
    }

    /// A flat layout merges every camera into one folder, so two cameras' IMG_0001 would collide (and a RAW
    /// from one would pair with the other's JPEG). Within each destination folder, files sharing a stem
    /// (case-insensitive) are grouped into sets by (card, source folder, camera, stem), so a RAW+JPEG pair
    /// stays one set. The first set (by camera, then source path) keeps its stem; each later set gets
    /// "<stem> 2", "<stem> 3", ... on every member, extension kept, never reusing a stem planned for that
    /// folder. Pure and deterministic, so the same input names every copy alike. Only the requested name
    /// changes: CopyEngine still never overwrites a file already on disk.
    static func uniquifyFlatStems(_ jobs: [CopyJob]) -> [CopyJob] {
        struct SetKey: Hashable { let card: String; let parent: String; let camera: String }
        var out = jobs
        var byFolder: [String: [Int]] = [:]
        for (i, job) in jobs.enumerated() { byFolder[job.destDir.standardizedFileURL.path, default: []].append(i) }
        let stemOf = { (i: Int) in splitName(jobs[i].destName ?? jobs[i].file.name).stem }
        for indices in byFolder.values {
            // Every stem planned in this folder is taken, so a rename never lands on another set's name.
            var used = Set(indices.map { stemOf($0).lowercased() })
            var byStem: [String: [SetKey: [Int]]] = [:]
            for i in indices {
                let file = jobs[i].file
                let key = SetKey(card: file.cardID, parent: file.url.deletingLastPathComponent().standardizedFileURL.path,
                                 camera: file.cameraID)
                byStem[stemOf(i).lowercased(), default: [:]][key, default: []].append(i)
            }
            for stem in byStem.keys.sorted() {
                guard let sets = byStem[stem], sets.count > 1 else { continue }
                let ordered = sets.map { key, members in
                    (key: key, members: members, first: members.map { jobs[$0].file.url.standardizedFileURL.path }.min() ?? "")
                }.sorted { ($0.key.camera, $0.first, $0.key.card) < ($1.key.camera, $1.first, $1.key.card) }
                for set in ordered.dropFirst() {
                    var n = 2
                    while used.contains("\(stem) \(n)") { n += 1 }
                    used.insert("\(stem) \(n)")
                    for i in set.members {
                        let (original, ext) = splitName(jobs[i].destName ?? jobs[i].file.name)
                        out[i].destName = ext.isEmpty ? "\(original) \(n)" : "\(original) \(n).\(ext)"
                    }
                }
            }
        }
        return out
    }

    static func plan(jobs: [CopyJob], shoot: URL, workRoot: URL? = nil, roots: [URL] = [], shootID: UUID? = nil) -> CopyPlan {
        let labels = Set(jobs.map { $0.destDir.lastPathComponent }).sorted()
        return CopyPlan(jobs: jobs, destinationLabel: labels.joined(separator: ", "), destinationRoot: shoot, workRoot: workRoot,
                        roots: roots, shootID: shootID)
    }

    /// Everything into one chosen folder.
    static func flatPlan(missing: [MediaFile], into dir: URL) -> CopyPlan {
        CopyPlan(jobs: missing.map { CopyJob(file: $0, destDir: dir, root: dir) }, destinationLabel: dir.lastPathComponent,
                 destinationRoot: dir, workRoot: dir)
    }

}

/// Aggregate status across cards.
nonisolated enum StatusAggregator {
    enum Result: Equatable, Sendable { case idle, unbacked, copying, backed, error }

    /// Priority: copying > error > unbacked > (anything still verifying, or empty: idle) > backed > idle.
    /// An unreadable card is an error; an empty card is neutral but never lets the total go green.
    /// A failed card is reported as `error` because the user has to act on it; it still means unbacked data,
    /// which `error` outranks so the failure isn't masked by another card needing backup.
    static func aggregate(_ phases: [CardPhase]) -> Result {
        if phases.contains(.copying) { return .copying }
        if phases.contains(where: {
            switch $0 { case .failed, .unreadable: true; default: false }
        }) { return .error }
        if phases.contains(where: { $0 == .needsBackup || $0 == .ready }) { return .unbacked }
        // Never show green while a card's files are still being checksum-checked.
        if phases.contains(.verifying) || phases.contains(.empty) { return .idle }
        if phases.contains(.backed) { return .backed }
        return .idle
    }
}
