import Foundation

/// Naming for the `.flat` layout, where every camera's files share one Video/ or Photo/ folder.
nonisolated extension ShootPlanner {
    /// Max capture-time spread for same-stem files of one camera to be one RAW+JPEG(+...) set.
    static let flatPairWindow: TimeInterval = 5

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
        let diskNamesByFolderPath = lowercasedNamesByFolderPath(existing)
        var renamedJobs = jobs

        for jobIndices in jobIndicesByDestinationFolder(jobs).values {
            let section = jobs[jobIndices[0]].destDir.lastPathComponent

            // Sizes of every file on disk under each (lowercased) name, across all copies of this folder.
            let folderPaths = Set(jobIndices.map { jobs[$0].destDir.standardizedFileURL.path })
            var sizesOnDisk: [String: Set<Int64>] = [:]
            for folderPath in folderPaths {
                for (name, size) in diskNamesByFolderPath[folderPath] ?? [:] {
                    sizesOnDisk[name, default: []].insert(size)
                }
            }

            // Each file once: the ones being copied, then related files landing in the same section.
            var files: [MediaFile] = []
            var seenURLs = Set<URL>()
            for index in jobIndices where seenURLs.insert(jobs[index].file.url).inserted {
                files.append(jobs[index].file)
            }
            for file in related where sectionFolder(for: file) == section && seenURLs.insert(file.url).inserted {
                files.append(file)
            }

            let newNameByURL = flatNames(files, sizesOnDisk: sizesOnDisk)
            for index in jobIndices {
                if let newName = newNameByURL[jobs[index].file.url] {
                    renamedJobs[index].destName = newName
                }
            }
        }
        return renamedJobs
    }

    /// `existing` re-keyed by standardized folder path, with every file name lowercased.
    private static func lowercasedNamesByFolderPath(_ existing: [URL: [String: Int64]]) -> [String: [String: Int64]] {
        var namesByFolderPath: [String: [String: Int64]] = [:]
        for (folder, sizeByName) in existing {
            let folderPath = folder.standardizedFileURL.path
            for (name, size) in sizeByName {
                namesByFolderPath[folderPath, default: [:]][name.lowercased()] = size
            }
        }
        return namesByFolderPath
    }

    /// Job indices grouped by where they land: the folder relative to the job's copy root when it has
    /// one (so the same folder on every copy is one group), else the absolute folder path.
    private static func jobIndicesByDestinationFolder(_ jobs: [CopyJob]) -> [String: [Int]] {
        var indicesByFolder: [String: [Int]] = [:]
        for (index, job) in jobs.enumerated() {
            let folderKey: String
            if let root = job.root, let componentsBelowRoot = relativeComponents(job.destDir, to: root) {
                folderKey = "rel:" + componentsBelowRoot.joined(separator: "/")
            } else {
                folderKey = job.destDir.standardizedFileURL.path
            }
            indicesByFolder[folderKey, default: []].append(index)
        }
        return indicesByFolder
    }

    // MARK: Sets

    /// Files that belong together under one stem: a RAW+JPEG(+...) set from one camera.
    private struct FlatSet {
        var members: [MediaFile]
        /// Lowercased extensions of the members.
        var extensions: Set<String>
        /// Capture date of the set's first file.
        let anchorDate: Date
        /// The camera (or card + source folder) the members came from.
        let owner: String
        /// Lowest source path among the members: the final tie-breaker when ordering sets.
        var firstPath: String
    }

    /// Stem and extension as spelled ("" when there is no extension).
    private static func splitName(_ name: String) -> (stem: String, ext: String) {
        let name = name as NSString
        return (name.deletingPathExtension, name.pathExtension)
    }

    /// Who a file belongs to: its camera, or for an unknown camera its card + source folder.
    private static func flatOwner(of file: MediaFile) -> String {
        if file.cameraID.isEmpty {
            let sourceFolder = file.url.deletingLastPathComponent().standardizedFileURL.path
            return "card:\(file.cardID)|\(sourceFolder)"
        }
        return "cam:\(file.cameraID)"
    }

    /// Every set, keyed by its lowercased stem.
    private static func flatSetsByStem(_ files: [MediaFile]) -> [String: [FlatSet]] {
        struct Bucket: Hashable {
            let owner: String
            let stem: String
        }
        var filesByBucket: [Bucket: [MediaFile]] = [:]
        for file in files {
            let bucket = Bucket(owner: flatOwner(of: file), stem: splitName(file.name).stem.lowercased())
            filesByBucket[bucket, default: []].append(file)
        }

        var setsByStem: [String: [FlatSet]] = [:]
        for (bucket, bucketFiles) in filesByBucket {
            setsByStem[bucket.stem, default: []] += flatSets(bucketFiles, owner: bucket.owner)
        }
        return setsByStem
    }

    /// Splits one owner's same-stem files into sets, oldest first. A file joins the first set that
    /// lacks its extension and started within `flatPairWindow` of it; otherwise it starts a new set.
    private static func flatSets(_ files: [MediaFile], owner: String) -> [FlatSet] {
        let oldestFirst = files.sorted { ($0.date, $0.url.path) < ($1.date, $1.url.path) }
        var sets: [FlatSet] = []
        for file in oldestFirst {
            let ext = splitName(file.name).ext.lowercased()
            let path = file.url.standardizedFileURL.path
            let joinableSet = sets.firstIndex { set in
                !set.extensions.contains(ext) && abs(file.date.timeIntervalSince(set.anchorDate)) <= flatPairWindow
            }
            if let joinableSet {
                sets[joinableSet].members.append(file)
                sets[joinableSet].extensions.insert(ext)
                sets[joinableSet].firstPath = min(sets[joinableSet].firstPath, path)
            } else {
                sets.append(FlatSet(members: [file], extensions: [ext], anchorDate: file.date, owner: owner, firstPath: path))
            }
        }
        return sets
    }

    // MARK: Choosing names

    /// Renamed files only (url -> requested name). See `uniquifyFlatStems`.
    /// `sizesOnDisk`: lowercased name -> sizes of the files already on disk under that name.
    private static func flatNames(_ files: [MediaFile], sizesOnDisk: [String: Set<Int64>]) -> [URL: String] {
        let setsByStem = flatSetsByStem(files)

        var diskNamesByStem: [String: [String]] = [:]
        for diskName in sizesOnDisk.keys {
            diskNamesByStem[splitName(diskName).stem, default: []].append(diskName)
        }
        let plannedStems = Set(files.map { splitName($0.name).stem.lowercased() })
        var usedStems = plannedStems.union(diskNamesByStem.keys)

        var newNameByURL: [URL: String] = [:]
        for stem in setsByStem.keys.sorted() {
            guard let sets = setsByStem[stem] else { continue }
            let diskNames = diskNamesByStem[stem] ?? []
            let stemIsUncontested = sets.count == 1 && diskNames.isEmpty
            if stemIsUncontested { continue }

            let contest = StemContest(diskNames: diskNames, sizesOnDisk: sizesOnDisk)
            var stemIsClaimed = false
            for set in contest.ordered(sets) {
                if !stemIsClaimed && contest.mayKeepStem(set) {
                    stemIsClaimed = true
                    continue
                }
                let number = lowestFreeNumber(for: stem, usedStems: usedStems)
                usedStems.insert("\(stem) \(number)")
                for file in set.members {
                    newNameByURL[file.url] = numberedName(file.name, number: number)
                }
            }
        }
        return newNameByURL
    }

    /// The sets competing for one stem, and the files already on disk under that stem.
    private struct StemContest {
        /// Lowercased names on disk that share the stem.
        let diskNames: [String]
        let sizesOnDisk: [String: Set<Int64>]

        private func member(of set: FlatSet, named diskName: String) -> MediaFile? {
            set.members.first { $0.name.lowercased() == diskName }
        }

        /// True when the only file on disk under `diskName` has exactly `file`'s size (its earlier copy).
        private func isOnDiskCopy(of file: MediaFile, named diskName: String) -> Bool {
            sizesOnDisk[diskName] == [file.size]
        }

        /// The set already has one of its members on disk (a resumed copy).
        func ownsADiskFile(_ set: FlatSet) -> Bool {
            diskNames.contains { diskName in
                guard let file = member(of: set, named: diskName) else { return false }
                return isOnDiskCopy(of: file, named: diskName)
            }
        }

        /// Every disk file with this stem is either the set's own earlier copy or has an extension the
        /// set doesn't use.
        func mayKeepStem(_ set: FlatSet) -> Bool {
            diskNames.allSatisfy { diskName in
                if let file = member(of: set, named: diskName) {
                    return isOnDiskCopy(of: file, named: diskName)
                }
                return !set.extensions.contains(ShootPlanner.splitName(diskName).ext)
            }
        }

        /// Sets owning a disk file first, then by owner, date and source path.
        func ordered(_ sets: [FlatSet]) -> [FlatSet] {
            sets.sorted { a, b in
                let aRank = ownsADiskFile(a) ? 0 : 1
                let bRank = ownsADiskFile(b) ? 0 : 1
                return (aRank, a.owner, a.anchorDate, a.firstPath) < (bRank, b.owner, b.anchorDate, b.firstPath)
            }
        }
    }

    /// The lowest N >= 2 for which "<stem> N" is not used by a planned file or a file on disk.
    private static func lowestFreeNumber(for stem: String, usedStems: Set<String>) -> Int {
        var number = 2
        while usedStems.contains("\(stem) \(number)") { number += 1 }
        return number
    }

    /// "IMG_1.CR3" with 2 -> "IMG_1 2.CR3" (spelling and extension kept).
    private static func numberedName(_ name: String, number: Int) -> String {
        let (stem, ext) = splitName(name)
        if ext.isEmpty { return "\(stem) \(number)" }
        return "\(stem) \(number).\(ext)"
    }
}
