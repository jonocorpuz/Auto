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
        var report = ShootSyncReport(copies: order)
        var toHash: [String] = []
        for root in order { report.missing[root] = [] }
        func inv(_ root: URL) -> Inventory { inventories[root] ?? Inventory() }

        // Keys (and everything below them) that must not be compared or propagated.
        var blocked = Set<String>()

        var unreadableKeys = Set<String>()
        for root in order { unreadableKeys.formUnion(inv(root).unreadable.keys) }
        for key in unreadableKeys.sorted() {
            let holders = order.filter { inv($0).unreadable[key] != nil }
            guard let u = holders.first.flatMap({ inv($0).unreadable[key] }) else { continue }
            report.conflicts.append(SyncConflict(relPath: u.relPath, kind: .unreadable(u.message), copies: holders))
            blocked.insert(key)
        }

        var nestedKeys = Set<String>()
        for root in order { nestedKeys.formUnion(inv(root).nestedShoots.keys) }
        for key in nestedKeys.sorted() {
            blocked.insert(key)
            let nested = order.filter { inv($0).nestedShoots[key] != nil }
            let plain = order.filter { inv($0).nestedShoots[key] == nil && (inv($0).occupied[key] != nil || inv($0).files[key] != nil) }
            if !plain.isEmpty, let display = nested.first.flatMap({ inv($0).nestedShoots[key] }) {
                report.conflicts.append(SyncConflict(relPath: display, kind: .nestedShootMismatch, copies: order.filter { nested.contains($0) || plain.contains($0) }))
            }
        }

        func isBlocked(_ key: String) -> Bool {
            if blocked.contains(key) { return true }
            var from = key.startIndex
            while let slash = key[from...].firstIndex(of: "/") {
                if blocked.contains(String(key[..<slash])) { return true }
                from = key.index(after: slash)
            }
            return false
        }

        var fileKeys = Set<String>()
        for root in order { fileKeys.formUnion(inv(root).files.keys) }

        // Same name, different kind of thing (file / folder / symlink / special) on different copies.
        func kind(_ root: URL, _ key: String) -> Inventory.Kind? {
            if inv(root).files[key] != nil { return .file }
            return inv(root).occupied[key]?.kind
        }
        var kindKeys = fileKeys
        for root in order { kindKeys.formUnion(inv(root).occupied.keys) }
        for key in kindKeys.sorted() where !isBlocked(key) {
            let holders = order.filter { kind($0, key) != nil }
            guard Set(holders.compactMap { kind($0, key) }).count > 1, let h = holders.first else { continue }
            let display = inv(h).files[key]?.relPath ?? inv(h).occupied[key]?.relPath ?? key
            report.conflicts.append(SyncConflict(relPath: display, kind: .typeMismatch, copies: holders))
            blocked.insert(key)
        }

        for key in fileKeys.sorted() where !isBlocked(key) {
            let present = order.filter { inv($0).files[key] != nil }
            guard let first = present.first.flatMap({ inv($0).files[key] }) else { continue }
            let colliding = present.filter { !(inv($0).files[key]?.collisions.isEmpty ?? true) }
            if !colliding.isEmpty {
                report.conflicts.append(SyncConflict(relPath: first.relPath, kind: .caseCollision, copies: colliding))
                continue
            }
            report.fileCount += 1
            report.bytes += first.size
            let sizes = Set(present.compactMap { inv($0).files[key]?.size })
            if sizes.count > 1 {
                report.conflicts.append(SyncConflict(relPath: first.relPath, kind: .size, copies: present))
                continue
            }
            for root in order where !present.contains(root) {
                report.missing[root, default: []].append(
                    SyncMissing(file: SyncFile(relPath: first.relPath, size: first.size), source: present[0]))
            }
            if present.count >= 2 { toHash.append(key) }
        }
        report.conflicts.sort { $0.relPath < $1.relPath }
        return (report, toHash)
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
            var r = ShootSyncReport(copies: copies)
            r.notChecked = .singleCopy
            return r
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
        case .cancelled: return nil
        case .unreadable(let root, let message):
            var r = ShootSyncReport(copies: copies)
            r.notChecked = .copyUnreadable(root, message)
            return r
        case .ok(let found): inventories = found
        }
        if Task.isCancelled || hasher.isCancelled { return nil }

        let sized = compare(inventories, order: copies)
        var report = sized.report
        let toHash = sized.toHash
        await onSizePass(report)

        // Checksum pass on a plain thread: it must not occupy the cooperative pool.
        let (stream, yield) = AsyncStream<SyncProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await p in stream { progress(p) }
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

        report.conflicts.append(contentsOf: outcome.conflicts)
        report.conflicts.sort { $0.relPath < $1.relPath }
        let conflicted = Set(outcome.conflicts.map { foldedKey($0.relPath) })
        if !conflicted.isEmpty {
            for (root, list) in report.missing {
                report.missing[root] = list.filter { !conflicted.contains(foldedKey($0.file.relPath)) }
            }
        }
        report.depth = .checksums
        return report
    }

    private struct HashOutcome: Sendable {
        var conflicts: [SyncConflict] = []
        var cancelled = false
    }

    private static func hashPass(keys: [String], inventories: [URL: Inventory], order: [URL],
                                 cache: ChecksumStore, hasher: FileHasher, deep: Bool,
                                 onProgress: @Sendable (SyncProgress) -> Void) -> HashOutcome {
        var outcome = HashOutcome()
        var p = SyncProgress(phase: .hashing)
        p.filesTotal = keys.count
        for key in keys {
            for root in order { if let e = inventories[root]?.files[key] { p.bytesTotal += e.size } }
        }
        var lastReport = Date.distantPast
        func report(force: Bool) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 { lastReport = now; onProgress(p) }
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
                    p.bytesDone += entry.size
                    continue
                }
                let before = p.bytesDone
                do {
                    let d = try hasher.md5(entry.url) { n in
                        p.bytesDone = before + n
                        report(force: false)
                    }
                    p.bytesDone = before + entry.size
                    // Recorded under the stamp taken before hashing: an edit mid-hash is a miss next time.
                    if let stamp { cache.record(d, for: stamp) }
                    digests.append((root, d))
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
            }
            p.filesDone += 1
            report(force: false)
        }
        report(force: true)
        return outcome
    }
}
