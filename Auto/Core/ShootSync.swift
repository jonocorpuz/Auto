import Foundation

nonisolated struct SyncFile: Sendable, Hashable {
    let relPath: String          // display spelling, "/"-joined, relative to the copy root
    let size: Int64
}

nonisolated struct SyncConflict: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case size, content, caseCollision
        case unreadable(String)
        /// A folder holds a nested shoot (has a sidecar) on some copies but is a plain folder on others.
        case nestedShootMismatch
        /// A regular file on some copies, a symlink / folder / special file on others.
        case typeMismatch
    }
    let relPath: String
    let kind: Kind
    let copies: [URL]            // copy roots that disagree
}

nonisolated struct SyncMissing: Sendable, Hashable {
    let file: SyncFile
    let source: URL              // copy root that has it (preferring the effective primary)
    /// MD5 of the source as the checker read it, when the file was hashed (present on 2+ copies and agreeing).
    var checksum: Data? = nil
}

nonisolated struct ShootSyncReport: Sendable, Equatable {
    enum NotChecked: Sendable, Equatable { case singleCopy, copyUnreadable(URL, String) }
    enum Depth: Sendable, Equatable { case sizes, checksums }
    var copies: [URL]
    var missing: [URL: [SyncMissing]] = [:]      // keyed by DESTINATION copy root
    var conflicts: [SyncConflict] = []
    var fileCount = 0
    var bytes: Int64 = 0
    var depth: Depth = .sizes
    var notChecked: NotChecked?
    var isInSync: Bool { notChecked == nil && depth == .checksums && missing.values.allSatisfy { $0.isEmpty } && conflicts.isEmpty }
    var isOutOfSync: Bool { notChecked == nil && (!missing.values.allSatisfy { $0.isEmpty } || !conflicts.isEmpty) }
}

nonisolated struct SyncProgress: Sendable, Equatable {
    enum Phase: Sendable { case listing, hashing }
    var phase: Phase
    var filesDone = 0, filesTotal = 0
    var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
}

/// One regular file in a copy's inventory.
nonisolated struct InventoryEntry: Sendable, Hashable {
    let url: URL
    let relPath: String          // display spelling
    let size: Int64
    /// Other spellings in the same copy that fold to the same key (case collision).
    var collisions: [String] = []
}

/// Everything one copy contains, keyed by folded relative path.
nonisolated struct Inventory: Sendable, Equatable {
    struct Unreadable: Sendable, Hashable {
        let relPath: String
        let message: String
    }
    var files: [String: InventoryEntry] = [:]
    enum Kind: Sendable, Hashable { case file, dir, symlink, special }
    struct Occupant: Sendable, Hashable {
        let kind: Kind
        let relPath: String
    }
    /// Non-regular names (symlinks, special files) and folders by folded key.
    var occupied: [String: Occupant] = [:]
    /// Folders containing a sidecar (nested shoots), key -> display path. Never descended into.
    var nestedShoots: [String: String] = [:]
    /// Folders or files that could not be read. Never silently dropped.
    var unreadable: [String: Unreadable] = [:]
}

/// Compares the copies of a shoot (sizes, then checksums). Strictly read-only.
/// Every uncertainty fails closed: it surfaces as a conflict or `notChecked`, never as "in sync".
nonisolated enum ShootSyncChecker {
    /// NFC + case-insensitive fold: the comparison key for relative paths.
    static func foldedKey(_ relPath: String) -> String {
        relPath.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    // MARK: Inventory

    /// Inventory of `root`. Skips hidden entries (sidecar, `.auto-partial`, `.DS_Store`, `._*`) and does not
    /// descend into nested shoots (folders with a sidecar). Unreadable entries are recorded, not dropped.
    /// Throws if `root` itself is unreadable, and `CancellationError` when `isCancelled` turns true.
    static func inventory(_ root: URL, isCancelled: () -> Bool = { Task.isCancelled }) throws -> Inventory {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var inv = Inventory()
        try walk(dir: root, rel: "", inv: &inv, isCancelled: isCancelled)
        return inv
    }

    private static func walk(dir: URL, rel: String, inv: inout Inventory, isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            if rel.isEmpty { throw error }
            inv.unreadable[foldedKey(rel)] = Inventory.Unreadable(relPath: rel, message: error.localizedDescription)
            return
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for url in children {
            if isCancelled() { throw CancellationError() }
            let name = url.lastPathComponent
            let childRel = rel.isEmpty ? name : rel + "/" + name
            let key = foldedKey(childRel)
            guard let v = try? url.resourceValues(forKeys: keys) else {
                inv.unreadable[key] = Inventory.Unreadable(relPath: childRel, message: "Cannot read attributes")
                continue
            }
            if v.isSymbolicLink == true {
                inv.occupied[key] = Inventory.Occupant(kind: .symlink, relPath: childRel)
            } else if v.isDirectory == true {
                inv.occupied[key] = Inventory.Occupant(kind: .dir, relPath: childRel)
                if fm.fileExists(atPath: url.appendingPathComponent(ShootSidecar.fileName).path) {
                    inv.nestedShoots[key] = childRel
                } else {
                    try walk(dir: url, rel: childRel, inv: &inv, isCancelled: isCancelled)
                }
            } else if v.isRegularFile == true {
                guard let size = v.fileSize else {
                    inv.unreadable[key] = Inventory.Unreadable(relPath: childRel, message: "Cannot read size")
                    continue
                }
                if var existing = inv.files[key] {
                    existing.collisions.append(childRel)
                    inv.files[key] = existing
                } else {
                    inv.files[key] = InventoryEntry(url: url, relPath: childRel, size: Int64(size))
                }
            } else {
                inv.occupied[key] = Inventory.Occupant(kind: .special, relPath: childRel)
            }
        }
    }

    // MARK: Size pass

    /// Pure: inventories -> size-pass report + folded keys needing a checksum comparison.
    static func compare(_ inventories: [URL: Inventory], order: [URL]) -> (report: ShootSyncReport, toHash: [String]) {
        var pass = SizePass(inventories: inventories, order: order)
        // Order matters: each step blocks keys the later steps must not compare or propagate.
        pass.reportUnreadable()
        pass.reportNestedShoots()
        pass.reportTypeMismatches()
        pass.compareFiles()
        pass.report.conflicts.sort { $0.relPath < $1.relPath }
        return (pass.report, pass.toHash)
    }

    /// Working state of one `compare` run.
    private struct SizePass {
        let inventories: [URL: Inventory]
        /// Copy roots, effective primary first.
        let order: [URL]
        var report: ShootSyncReport
        var toHash: [String] = []
        /// Keys (and everything below them) that must not be compared or propagated.
        var blocked = Set<String>()

        init(inventories: [URL: Inventory], order: [URL]) {
            self.inventories = inventories
            self.order = order
            report = ShootSyncReport(copies: order)
            for root in order { report.missing[root] = [] }
        }

        func inventory(_ root: URL) -> Inventory { inventories[root] ?? Inventory() }

        /// Union over every copy of the keys of one of the inventory's tables.
        func allKeys<Value>(_ table: (Inventory) -> [String: Value]) -> Set<String> {
            var union = Set<String>()
            for root in order { union.formUnion(table(inventory(root)).keys) }
            return union
        }

        /// True when `key` or any folder above it is blocked.
        func isBlocked(_ key: String) -> Bool {
            if blocked.contains(key) { return true }
            var searchStart = key.startIndex
            while let slash = key[searchStart...].firstIndex(of: "/") {
                let ancestor = String(key[..<slash])
                if blocked.contains(ancestor) { return true }
                searchStart = key.index(after: slash)
            }
            return false
        }

        /// Anything unreadable on any copy is a conflict and is not compared further.
        mutating func reportUnreadable() {
            for key in allKeys({ $0.unreadable }).sorted() {
                let holders = order.filter { inventory($0).unreadable[key] != nil }
                guard let firstHolder = holders.first,
                      let unreadable = inventory(firstHolder).unreadable[key] else { continue }
                report.conflicts.append(SyncConflict(relPath: unreadable.relPath, kind: .unreadable(unreadable.message),
                                                     copies: holders))
                blocked.insert(key)
            }
        }

        /// Nested shoots are never compared. A folder that is a nested shoot on some copies but a plain
        /// folder or file on others is a conflict.
        mutating func reportNestedShoots() {
            for key in allKeys({ $0.nestedShoots }).sorted() {
                blocked.insert(key)
                let nested = order.filter { inventory($0).nestedShoots[key] != nil }
                let plain = order.filter { root in
                    let copy = inventory(root)
                    let isNested = copy.nestedShoots[key] != nil
                    let isPresent = copy.occupied[key] != nil || copy.files[key] != nil
                    return !isNested && isPresent
                }
                guard !plain.isEmpty, let firstNested = nested.first,
                      let display = inventory(firstNested).nestedShoots[key] else { continue }
                let disagreeing = order.filter { nested.contains($0) || plain.contains($0) }
                report.conflicts.append(SyncConflict(relPath: display, kind: .nestedShootMismatch, copies: disagreeing))
            }
        }

        func kind(_ root: URL, _ key: String) -> Inventory.Kind? {
            if inventory(root).files[key] != nil { return .file }
            return inventory(root).occupied[key]?.kind
        }

        /// Same name, different kind of thing (file / folder / symlink / special) on different copies.
        mutating func reportTypeMismatches() {
            let keys = allKeys({ $0.files }).union(allKeys({ $0.occupied }))
            for key in keys.sorted() where !isBlocked(key) {
                let holders = order.filter { kind($0, key) != nil }
                let kinds = Set(holders.compactMap { kind($0, key) })
                guard kinds.count > 1, let firstHolder = holders.first else { continue }
                let copy = inventory(firstHolder)
                let display = copy.files[key]?.relPath ?? copy.occupied[key]?.relPath ?? key
                report.conflicts.append(SyncConflict(relPath: display, kind: .typeMismatch, copies: holders))
                blocked.insert(key)
            }
        }

        /// Case collisions and size differences are conflicts; files absent from a copy are missing there;
        /// files on two or more copies with equal sizes go on to the checksum pass.
        mutating func compareFiles() {
            for key in allKeys({ $0.files }).sorted() where !isBlocked(key) {
                let present = order.filter { inventory($0).files[key] != nil }
                guard let primaryHolder = present.first,
                      let first = inventory(primaryHolder).files[key] else { continue }

                let colliding = present.filter { !(inventory($0).files[key]?.collisions.isEmpty ?? true) }
                if !colliding.isEmpty {
                    report.conflicts.append(SyncConflict(relPath: first.relPath, kind: .caseCollision, copies: colliding))
                    continue
                }

                report.fileCount += 1
                report.bytes += first.size
                let sizes = Set(present.compactMap { inventory($0).files[key]?.size })
                if sizes.count > 1 {
                    report.conflicts.append(SyncConflict(relPath: first.relPath, kind: .size, copies: present))
                    continue
                }

                for root in order where !present.contains(root) {
                    let missing = SyncMissing(file: SyncFile(relPath: first.relPath, size: first.size), source: primaryHolder)
                    report.missing[root, default: []].append(missing)
                }
                if present.count >= 2 { toHash.append(key) }
            }
        }
    }

    // MARK: Run

    private enum ListOutcome: Sendable {
        case ok([URL: Inventory])
        case unreadable(URL, String)
        case cancelled
    }

    /// `copies[0]` is the effective primary (preferred sync source). Read-only everywhere.
    /// `onSizePass` fires once (main actor) with the `depth == .sizes` report, before any hashing.
    /// That report is provisional: it must NEVER drive Sync Now or be shown as "in sync".
    /// Returns nil when cancelled (never a partial result). Cancelling the task cancels `hasher`.
    /// `hasher` is single-use: once cancelled it stays cancelled, so pass a fresh one per run.
    @concurrent static func run(copies: [URL], cache: ChecksumStore, hasher: FileHasher = FileHasher(),
                                deep: Bool = false,
                                onSizePass: @escaping @MainActor @Sendable (ShootSyncReport) -> Void = { _ in },
                                progress: @escaping @MainActor @Sendable (SyncProgress) -> Void = { _ in }) async -> ShootSyncReport? {
        MainThreadProbe.shared.mark("ShootSyncChecker.run")
        return await withTaskCancellationHandler {
            await runBody(copies: copies, cache: cache, hasher: hasher, deep: deep, onSizePass: onSizePass, progress: progress)
        } onCancel: {
            hasher.cancel()
        }
    }

    private static func listAll(_ copies: [URL], hasher: FileHasher) -> ListOutcome {
        var inventories: [URL: Inventory] = [:]
        for root in copies {
            if hasher.isCancelled { return .cancelled }
            do { inventories[root] = try inventory(root, isCancelled: { hasher.isCancelled }) }
            catch is CancellationError { return .cancelled }
            catch { return .unreadable(root, error.localizedDescription) }
        }
        return .ok(inventories)
    }

    private static func runBody(copies: [URL], cache: ChecksumStore, hasher: FileHasher, deep: Bool,
                                onSizePass: @escaping @MainActor @Sendable (ShootSyncReport) -> Void,
                                progress: @escaping @MainActor @Sendable (SyncProgress) -> Void) async -> ShootSyncReport? {
        guard copies.count >= 2 else {
            var report = ShootSyncReport(copies: copies)
            report.notChecked = .singleCopy
            return report
        }

        await progress(SyncProgress(phase: .listing))
        // Listing walks whole trees: keep it off the cooperative pool too.
        let listed: ListOutcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: listAll(copies, hasher: hasher))
            }
        }
        let inventories: [URL: Inventory]
        switch listed {
        case .cancelled:
            return nil
        case .unreadable(let root, let message):
            var report = ShootSyncReport(copies: copies)
            report.notChecked = .copyUnreadable(root, message)
            return report
        case .ok(let found):
            inventories = found
        }
        if Task.isCancelled || hasher.isCancelled { return nil }

        let (sizeReport, toHash) = compare(inventories, order: copies)
        await onSizePass(sizeReport)

        // Checksum pass on a plain thread: it must not occupy the cooperative pool.
        let (stream, yield) = AsyncStream<SyncProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await update in stream { progress(update) }
        }
        let outcome: HashOutcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: hashPass(keys: toHash, inventories: inventories, order: copies, cache: cache,
                                                        hasher: hasher, deep: deep) { _ = yield.yield($0) })
            }
        }
        yield.finish()
        await consumer.value
        await cache.saveIfDirty()   // even when cancelled: entries are per file and valid
        if outcome.cancelled || Task.isCancelled { return nil }

        return applying(outcome, to: sizeReport)
    }

    /// The final report: checksum conflicts added, conflicted files no longer offered as missing,
    /// and every missing file tagged with the digest its copies agreed on.
    private static func applying(_ outcome: HashOutcome, to sizeReport: ShootSyncReport) -> ShootSyncReport {
        var report = sizeReport
        report.conflicts.append(contentsOf: outcome.conflicts)
        report.conflicts.sort { $0.relPath < $1.relPath }

        let conflicted = Set(outcome.conflicts.map { foldedKey($0.relPath) })
        if !conflicted.isEmpty {
            for (root, list) in report.missing {
                report.missing[root] = list.filter { !conflicted.contains(foldedKey($0.file.relPath)) }
            }
        }
        if !outcome.digests.isEmpty {
            for (root, list) in report.missing {
                report.missing[root] = list.map { item in
                    var tagged = item
                    tagged.checksum = outcome.digests[foldedKey(item.file.relPath)]
                    return tagged
                }
            }
        }
        report.depth = .checksums
        return report
    }

    private struct HashOutcome: Sendable {
        var conflicts: [SyncConflict] = []
        var digests: [String: Data] = [:]   // folded key -> digest all copies agree on
        var cancelled = false
    }

    private static func hashPass(keys: [String], inventories: [URL: Inventory], order: [URL],
                                 cache: ChecksumStore, hasher: FileHasher, deep: Bool,
                                 onProgress: @Sendable (SyncProgress) -> Void) -> HashOutcome {
        var outcome = HashOutcome()
        var progress = SyncProgress(phase: .hashing)
        progress.filesTotal = keys.count
        for key in keys {
            for root in order {
                if let entry = inventories[root]?.files[key] { progress.bytesTotal += entry.size }
            }
        }
        // Throttled: hashing reports per chunk, far more often than the UI needs.
        let minimumReportInterval: TimeInterval = 0.1
        var lastReport = Date.distantPast
        func report(force: Bool) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > minimumReportInterval else { return }
            lastReport = now
            onProgress(progress)
        }
        report(force: true)

        for key in keys {
            var digests: [(URL, Data)] = []
            var failure: SyncConflict?
            var display = key
            for root in order {
                guard let entry = inventories[root]?.files[key] else { continue }
                display = entry.relPath
                if hasher.isCancelled { outcome.cancelled = true; return outcome }
                let stamp = ChecksumStore.stamp(entry.url)
                if !deep, let stamp, let hit = cache.checksum(for: stamp) {
                    digests.append((root, hit))
                    progress.bytesDone += entry.size
                    continue
                }
                let bytesBeforeFile = progress.bytesDone
                do {
                    let digest = try hasher.md5(entry.url) { bytesHashed in
                        progress.bytesDone = bytesBeforeFile + bytesHashed
                        report(force: false)
                    }
                    progress.bytesDone = bytesBeforeFile + entry.size
                    // Recorded under the stamp taken before hashing: an edit mid-hash is a miss next time.
                    if let stamp { cache.record(digest, for: stamp) }
                    digests.append((root, digest))
                } catch is FileHasher.Cancelled {
                    outcome.cancelled = true
                    return outcome
                } catch {
                    failure = SyncConflict(relPath: entry.relPath, kind: .unreadable(error.localizedDescription), copies: [root])
                    break
                }
            }
            if let failure {
                outcome.conflicts.append(failure)
            } else if Set(digests.map(\.1)).count > 1 {
                outcome.conflicts.append(SyncConflict(relPath: display, kind: .content, copies: digests.map(\.0)))
            } else if let agreed = digests.first?.1 {
                outcome.digests[key] = agreed
            }
            progress.filesDone += 1
            report(force: false)
        }
        report(force: true)
        return outcome
    }
}
