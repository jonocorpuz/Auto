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
        case outsideWorkFolder
        case notAFolder(String)
        case onCard
        case workFolderMissing

        var errorDescription: String? {
            switch self {
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

    /// Unique destination directories of the jobs, sorted by path.
    static func directories(for jobs: [CopyJob]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for job in jobs where seen.insert(job.destDir.path).inserted { result.append(job.destDir) }
        return result.sorted { $0.path < $1.path }
    }

    /// Video/Photo/<camera folder> per missing file. Cameras with an empty folder name use their model;
    /// files from unknown cameras go to `fallback`. `.flat` puts every file straight into Video/ or Photo/
    /// (cameras and fallback ignored) and renames stem collisions (see `uniquifyFlatStems`); `existing`
    /// and `related` only matter for `.flat`.
    static func jobs(missing: [MediaFile], shoot: URL, cameras: [Camera], fallback: String,
                     layout: ShootLayout = .cameraFolders, existing: [URL: [String: Int64]] = [:],
                     related: [MediaFile] = []) -> [CopyJob] {
        if layout == .flat {
            return uniquifyFlatStems(missing.map { CopyJob(file: $0, destDir: flatDirectory($0, shoot: shoot)) },
                                     existing: existing, related: related)
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
    /// `.flat` names are planned once across all copies (what is on disk in any copy counts), so every
    /// copy gets the same name.
    static func jobs(missing: [MediaFile], copies: [URL], cameras: [Camera], fallback: String,
                     layout: ShootLayout = .cameraFolders, existing: [URL: [String: Int64]] = [:],
                     related: [MediaFile] = []) -> [CopyJob] {
        if layout == .flat {
            let rooted = missing.flatMap { file in
                copies.map { CopyJob(file: file, destDir: flatDirectory(file, shoot: $0), root: $0) }
            }
            return uniquifyFlatStems(rooted, existing: existing, related: related)
        }
        let perCopy = copies.map { copy in
            jobs(missing: missing, shoot: copy, cameras: cameras, fallback: fallback).map { job -> CopyJob in
                var rooted = job
                rooted.root = copy
                return rooted
            }
        }
        return missing.indices.flatMap { i in perCopy.map { $0[i] } }
    }

    private static func flatDirectory(_ file: MediaFile, shoot: URL) -> URL {
        shoot.appendingPathComponent(file.kind == .photo ? photoFolder : videoFolder)
    }

    /// The folders a flat plan writes to on each copy (Video/ and Photo/), for `existingNames`.
    static func flatDirectories(copies: [URL]) -> [URL] {
        copies.flatMap { [$0.appendingPathComponent(videoFolder), $0.appendingPathComponent(photoFolder)] }
    }

    /// Lowercased name -> size (-1 when not a regular file) of every visible entry in each folder; a
    /// missing folder maps to [:]. Reads the disk: call `existingNamesOffMain` from the main actor.
    static func existingNames(in dirs: [URL]) -> [URL: [String: Int64]] {
        var out: [URL: [String: Int64]] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        for dir in dirs {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles])) ?? []
            var names: [String: Int64] = [:]
            for url in urls {
                let v = try? url.resourceValues(forKeys: Set(keys))
                names[url.lastPathComponent.lowercased()] = v?.isRegularFile == true ? Int64(v?.fileSize ?? 0) : -1
            }
            out[dir] = names
        }
        return out
    }

    @concurrent static func existingNamesOffMain(in dirs: [URL]) async -> [URL: [String: Int64]] {
        existingNames(in: dirs)
    }

    /// Max capture-time spread for same-stem files of one camera to be one RAW+JPEG(+...) set.
    static let flatPairWindow: TimeInterval = 5

    /// Stem and extension as spelled ("" when there is no extension).
    private static func splitName(_ name: String) -> (stem: String, ext: String) {
        let ns = name as NSString
        return (ns.deletingPathExtension, ns.pathExtension)
    }

    /// A flat layout merges every camera into one folder, so two cameras' IMG_0001 would collide (and a RAW
    /// from one would pair with the other's JPEG). This picks a requested name (`destName`) per file:
    ///
    /// - Sets: files sharing a stem (case-insensitive) are grouped per camera (or, for an unknown camera,
    ///   per card + source folder), so a dual-slot RAW-on-card-1 / JPEG-on-card-2 pair is one set. A file
    ///   starts a new set when its extension is already in the set (two CR3s are two photos) or its date is
    ///   more than `flatPairWindow` from the set's first file.
    /// - `related`: card files not being copied (already covered), so a resumed set is known in full.
    /// - `existing` (per destination folder, from `existingNames`): a set may keep its stem only if, for
    ///   every file already on disk with that stem, the set either has a member with the same name AND
    ///   size (its own earlier copy: a resume) or has no member with that extension. Otherwise that name
    ///   belongs to someone else and the whole set is renamed. Ownership is decided by name + size, never
    ///   by hashing; a wrong guess only affects naming, since CopyEngine still never overwrites.
    /// - Order: sets owning a disk file first, then by camera, date and source path. The first set that may
    ///   keep its stem does; every other set gets "<stem> N" on every member, extension kept, with N the
    ///   lowest whose stem is used by no planned file and no file on disk.
    ///
    /// Jobs with a `root` are grouped by folder relative to it, so all copies share one decision (disk
    /// names from any copy count). Pure and deterministic.
    static func uniquifyFlatStems(_ jobs: [CopyJob], existing: [URL: [String: Int64]] = [:],
                                  related: [MediaFile] = []) -> [CopyJob] {
        var onDisk: [String: [String: Int64]] = [:]
        for (dir, names) in existing {
            for (name, size) in names { onDisk[dir.standardizedFileURL.path, default: [:]][name.lowercased()] = size }
        }
        var groups: [String: [Int]] = [:]
        for (i, job) in jobs.enumerated() {
            let rel = job.root.flatMap { relativeComponents(job.destDir, to: $0) }.map { "rel:" + $0.joined(separator: "/") }
            groups[rel ?? job.destDir.standardizedFileURL.path, default: []].append(i)
        }
        var out = jobs
        for indices in groups.values {
            let section = jobs[indices[0]].destDir.lastPathComponent
            var taken: [String: Set<Int64>] = [:]
            for dir in Set(indices.map { jobs[$0].destDir.standardizedFileURL.path }) {
                for (name, size) in onDisk[dir] ?? [:] { taken[name, default: []].insert(size) }
            }
            var files: [MediaFile] = []
            var seen = Set<URL>()
            for i in indices where seen.insert(jobs[i].file.url).inserted { files.append(jobs[i].file) }
            for f in related where (f.kind == .photo ? photoFolder : videoFolder) == section && seen.insert(f.url).inserted {
                files.append(f)
            }
            let names = flatNames(files, taken: taken)
            for i in indices { if let name = names[jobs[i].file.url] { out[i].destName = name } }
        }
        return out
    }

    private struct FlatSet {
        var members: [MediaFile]
        var exts: Set<String>
        let anchor: Date
        let owner: String
        var first: String
    }

    /// Renamed files only (url -> requested name). See `uniquifyFlatStems`.
    private static func flatNames(_ files: [MediaFile], taken: [String: Set<Int64>]) -> [URL: String] {
        struct Bucket: Hashable { let owner: String; let stem: String }
        var buckets: [Bucket: [MediaFile]] = [:]
        for f in files {
            let owner = f.cameraID.isEmpty
                ? "card:\(f.cardID)|\(f.url.deletingLastPathComponent().standardizedFileURL.path)" : "cam:\(f.cameraID)"
            buckets[Bucket(owner: owner, stem: splitName(f.name).stem.lowercased()), default: []].append(f)
        }
        var setsByStem: [String: [FlatSet]] = [:]
        for (bucket, members) in buckets {
            var sets: [FlatSet] = []
            for f in members.sorted(by: { ($0.date, $0.url.path) < ($1.date, $1.url.path) }) {
                let ext = splitName(f.name).ext.lowercased()
                let path = f.url.standardizedFileURL.path
                if let k = sets.firstIndex(where: { !$0.exts.contains(ext) && abs(f.date.timeIntervalSince($0.anchor)) <= flatPairWindow }) {
                    sets[k].members.append(f)
                    sets[k].exts.insert(ext)
                    sets[k].first = min(sets[k].first, path)
                } else {
                    sets.append(FlatSet(members: [f], exts: [ext], anchor: f.date, owner: bucket.owner, first: path))
                }
            }
            setsByStem[bucket.stem, default: []] += sets
        }
        var diskByStem: [String: [String]] = [:]
        for name in taken.keys { diskByStem[splitName(name).stem, default: []].append(name) }
        var used = Set(files.map { splitName($0.name).stem.lowercased() }).union(diskByStem.keys)

        var result: [URL: String] = [:]
        for stem in setsByStem.keys.sorted() {
            guard let sets = setsByStem[stem] else { continue }
            let disk = diskByStem[stem] ?? []
            if sets.count == 1 && disk.isEmpty { continue }
            func member(_ s: FlatSet, named name: String) -> MediaFile? { s.members.first { $0.name.lowercased() == name } }
            func owns(_ s: FlatSet) -> Bool { disk.contains { name in member(s, named: name).map { taken[name] == [$0.size] } ?? false } }
            func mayKeep(_ s: FlatSet) -> Bool {
                disk.allSatisfy { name in
                    if let m = member(s, named: name) { return taken[name] == [m.size] }
                    return !s.exts.contains(splitName(name).ext)
                }
            }
            let ordered = sets.sorted { a, b in
                (owns(a) ? 0 : 1, a.owner, a.anchor, a.first) < (owns(b) ? 0 : 1, b.owner, b.anchor, b.first)
            }
            var claimed = false
            for s in ordered {
                if !claimed && mayKeep(s) { claimed = true; continue }
                var n = 2
                while used.contains("\(stem) \(n)") { n += 1 }
                used.insert("\(stem) \(n)")
                for f in s.members {
                    let (original, ext) = splitName(f.name)
                    result[f.url] = ext.isEmpty ? "\(original) \(n)" : "\(original) \(n).\(ext)"
                }
            }
        }
        return result
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
