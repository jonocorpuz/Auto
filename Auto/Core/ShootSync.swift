import Foundation

nonisolated struct SyncFile: Sendable, Hashable {
    let relPath: String          // display spelling, "/"-joined, relative to the copy root
    let size: Int64
}

nonisolated struct SyncConflict: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case size, content, caseCollision, unreadable(String) }
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
    var isInSync: Bool { notChecked == nil && depth == .checksums && missing.values.allSatisfy(\.isEmpty) && conflicts.isEmpty }
    var isOutOfSync: Bool { notChecked == nil && (!missing.values.allSatisfy(\.isEmpty) || !conflicts.isEmpty) }
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

/// Compares the copies of a shoot (sizes, then checksums). Strictly read-only.
nonisolated enum ShootSyncChecker {
    static func foldedKey(_ relPath: String) -> String {
        relPath.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Inventory

    /// Regular files under `root`, keyed by NFC + case-folded relative path. Skips hidden files
    /// (sidecar, `.auto-partial`, `.DS_Store`, `._*`), symlinks and nested shoots (folders with a sidecar).
    static func inventory(_ root: URL) throws -> [String: InventoryEntry] {
        let base = root.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: base.path])
        }
        _ = try fm.contentsOfDirectory(atPath: base.path) // surfaces permission errors
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: base.path])
        }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var out: [String: InventoryEntry] = [:]
        for case let url as URL in e {
            if Task.isCancelled { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if fm.fileExists(atPath: url.appendingPathComponent(ShootSidecar.fileName).path) { e.skipDescendants() }
                continue
            }
            let urlPath = url.resolvingSymlinksInPath().path
            guard v.isRegularFile == true, urlPath.hasPrefix(prefix) else { continue }
            let rel = String(urlPath.dropFirst(prefix.count))
            let key = foldedKey(rel)
            if var existing = out[key] {
                existing.collisions.append(rel)
                out[key] = existing
            } else {
                out[key] = InventoryEntry(url: url, relPath: rel, size: Int64(v.fileSize ?? 0))
            }
        }
        return out
    }

    // MARK: Size pass

    /// Pure: inventories -> size-pass report + folded keys needing a checksum comparison.
    static func compare(_ inventories: [URL: [String: InventoryEntry]], order: [URL]) -> (report: ShootSyncReport, toHash: [String]) {
        var report = ShootSyncReport(copies: order)
        var toHash: [String] = []
        for root in order { report.missing[root] = [] }
        var keySet = Set<String>()
        for root in order { keySet.formUnion(inventories[root]?.keys.map { $0 } ?? []) }
        for key in keySet.sorted() {
            let present = order.filter { inventories[$0]?[key] != nil }
            guard let first = present.first.flatMap({ inventories[$0]?[key] }) else { continue }
            let colliding = present.filter { !(inventories[$0]?[key]?.collisions.isEmpty ?? true) }
            if !colliding.isEmpty {
                report.conflicts.append(SyncConflict(relPath: first.relPath, kind: .caseCollision, copies: colliding))
                continue
            }
            report.fileCount += 1
            report.bytes += first.size
            let sizes = Set(present.compactMap { inventories[$0]?[key]?.size })
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

    /// `copies[0]` is the effective primary (preferred sync source). Read-only everywhere.
    /// `onSizePass` fires once (main actor) with the depth == .sizes report, before any hashing.
    /// Returns nil when cancelled (never a partial result). Cancelling the task cancels `hasher`.
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

    private static func runBody(copies: [URL], cache: ChecksumStore, hasher: FileHasher, deep: Bool,
                                onSizePass: @escaping @MainActor @Sendable (ShootSyncReport) -> Void,
                                progress: @escaping @MainActor @Sendable (SyncProgress) -> Void) async -> ShootSyncReport? {
        guard copies.count >= 2 else {
            var r = ShootSyncReport(copies: copies)
            r.notChecked = .singleCopy
            return r
        }
        await progress(SyncProgress(phase: .listing))
        var inventories: [URL: [String: InventoryEntry]] = [:]
        for root in copies {
            if Task.isCancelled || hasher.isCancelled { return nil }
            do { inventories[root] = try inventory(root) } catch {
                var r = ShootSyncReport(copies: copies)
                r.notChecked = .copyUnreadable(root, error.localizedDescription)
                return r
            }
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
        let snapshot = inventories
        let outcome: HashOutcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: hashPass(keys: toHash, inventories: snapshot, order: copies, cache: cache,
                                                        hasher: hasher, deep: deep) { _ = yield.yield($0) })
            }
        }
        yield.finish()
        await consumer.value
        await cache.saveIfDirty()
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

    private static func hashPass(keys: [String], inventories: [URL: [String: InventoryEntry]], order: [URL],
                                 cache: ChecksumStore, hasher: FileHasher, deep: Bool,
                                 onProgress: @Sendable (SyncProgress) -> Void) -> HashOutcome {
        var outcome = HashOutcome()
        var p = SyncProgress(phase: .hashing)
        p.filesTotal = keys.count
        for key in keys {
            for root in order { if let e = inventories[root]?[key] { p.bytesTotal += e.size } }
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
                guard let entry = inventories[root]?[key] else { continue }
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
