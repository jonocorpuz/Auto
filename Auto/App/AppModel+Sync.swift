import AppKit
import Foundation

/// Runs one mirror check: `copies[0]` is the effective primary.
typealias SyncCheckRunner = @Sendable (_ copies: [URL], _ cache: ChecksumStore, _ deep: Bool,
                                       _ onSizePass: @escaping @MainActor @Sendable (ShootSyncReport) -> Void,
                                       _ progress: @escaping @MainActor @Sendable (SyncProgress) -> Void) async -> ShootSyncReport?

/// One queued check or Sync Now. Checks for the same shoot coalesce.
struct SyncWork {
    enum Kind { case check, sync }
    var id: UUID
    var kind: Kind
    var force: Bool
    var deep: Bool
    var notBefore: ContinuousClock.Instant
}

extension AppModel {
    // MARK: Mirror sync

    nonisolated static let realSyncChecker: SyncCheckRunner = { copies, cache, deep, onSizePass, progress in
        await ShootSyncChecker.run(copies: copies, cache: cache, hasher: FileHasher(), deep: deep,
                                   onSizePass: onSizePass, progress: progress)
    }

    var syncMetaURL: URL { registryURL.deletingLastPathComponent().appendingPathComponent("sync-meta.json") }

    private static func copyKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// What the UI shows for a shoot.
    func syncBadge(for shootID: UUID) -> SyncBadge {
        func counts(_ r: ShootSyncReport) -> SyncBadge {
            .outOfSync(missing: r.missing.values.reduce(0) { $0 + $1.count }, conflicts: r.conflicts.count)
        }
        switch syncStates[shootID] {
        case nil:
            guard let record = registry.records.first(where: { $0.id == shootID }), record.copyPaths.count >= 2 else { return .none }
            return .unknown(reason: "Not checked yet")
        case .single?:
            return .none
        case .unknown(let reason)?:
            return .unknown(reason: reason)
        case .failed(let message)?:
            return .unknown(reason: message)
        case .checking(let progress, let partial)?:
            if let partial, partial.isOutOfSync { return counts(partial) }
            return .checking(progress)
        case .done(let report, let at)?:
            if let stale = staleReason(shootID, report) { return .unknown(reason: stale) }
            if report.isOutOfSync { return counts(report) }
            if report.isInSync {
                if registry.records.first(where: { $0.id == shootID })?.pendingSync.isEmpty == false {
                    return .unknown(reason: "Updating sync status…")
                }
                return .inSync(copies: report.copies.count, checkedAt: at, deepVerifiedAt: lastDeepVerify[shootID])
            }
            return .unknown(reason: "Not fully checked yet")
        case .syncing(let progress)?:
            return .syncing(progress)
        }
    }

    /// Why a finished report no longer describes the shoot (a copy went away or was added, an ingest is writing), or nil.
    private func staleReason(_ id: UUID, _ report: ShootSyncReport) -> String? {
        guard let item = shoots.first(where: { $0.id == id }) else { return "Shoot not found" }
        if item.copies.contains(where: { $0.availability != .online }) { return unknownReason(item) }
        guard case .online(let shoot)? = item.availability,
              shoot.copies.map({ Self.copyKey($0.path) }) == report.copies.map({ Self.copyKey($0.path) }) else {
            return "The copies changed · checking again"
        }
        if let checked = syncMounts[id], let now = syncCurrentMounts[id], checked != now {
            return "A drive was remounted · checking again"
        }
        if isIngesting(into: shoot.copies, shootID: id) { return "Copying footage…" }
        return nil
    }

    nonisolated static func mountIDs(_ paths: [String], _ provider: @Sendable (URL) -> String?) -> [String] {
        paths.map { provider(URL(fileURLWithPath: $0, isDirectory: true)) ?? "?" }
    }

    /// A card is about to write into these roots: checks of the overlapping shoots are stale, so cancel them.
    func noteIngestStarting(roots: [URL]) {
        for item in shoots {
            guard item.record.copyPaths.contains(where: { path in roots.contains { Self.overlap($0, URL(fileURLWithPath: path)) } }) else { continue }
            let id = item.id
            guard item.record.copyPaths.count >= 2 else { continue }
            syncGenerations[id, default: 0] += 1
            if let running = syncRunning, running.id == id { running.task.cancel() }
            syncWork.removeAll { $0.id == id && $0.kind == .check }
            syncStates[id] = .unknown("Copying footage…")
            syncDeferred.insert(id)
        }
    }

    func flushDeferredSyncChecks() {
        guard !syncDeferred.isEmpty else { return }
        let ids = syncDeferred
        syncDeferred = []
        scheduleSyncCheck(ids, force: true)
    }

    func syncBusyOverlapping(_ roots: [URL]) -> Bool {
        syncActive.contains { id in
            guard let item = shoots.first(where: { $0.id == id }) else { return false }
            return item.record.copyPaths.contains { path in roots.contains { Self.overlap($0, URL(fileURLWithPath: path)) } }
        }
    }

    /// Queued behind a Sync Now rather than another card (`queuedBehind` points at the card itself).
    func enqueueBehindSync(_ card: Card) {
        if !copyQueue.contains(card.id) { copyQueue.append(card.id) }
        card.queuedBehind = card.id
        card.queueNote = "Waiting for Sync Now to finish"
    }

    /// Queues a check for each shoot (debounced; coalesced per shoot). `force` skips the throttle; `deep`
    /// re-reads every byte (and implies `force`). A newer request cancels a check of the same shoot that is running.
    func scheduleSyncCheck(_ ids: Set<UUID>, force: Bool, deep: Bool = false) {
        enqueueSync(ids, kind: .check, force: force || deep, deep: deep, delay: syncDebounce)
    }

    /// User-initiated check ("Check Again", with `deep` for "Verify Contents"): forced, starts right away.
    func checkSync(shootID: UUID, deep: Bool = false) {
        enqueueSync([shootID], kind: .check, force: true, deep: deep, delay: .zero)
    }

    /// Copies what is missing between the copies of a shoot. Only acts on a complete `.checksums` report that
    /// is out of sync; it re-checks first (cache hits) so it never plans from a stale report. Returns whether it was
    /// queued: false while a check is still at the size pass, while syncing, or when nothing is missing.
    @discardableResult
    /// Whether Sync Now can be offered for `shootID`: a finished checksum check found files missing and every
    /// copy is online. Shared by the popover and the shoot tile's menu.
    func canSyncNow(shootID: UUID) -> Bool {
        guard let item = shoots.first(where: { $0.id == shootID }),
              !item.copies.isEmpty, item.copies.allSatisfy({ $0.availability == .online }) else { return false }
        guard case .outOfSync(let missing, _) = syncBadge(for: shootID), missing > 0 else { return false }
        guard case .done(let report, _)? = syncStates[shootID] else { return false }
        return report.depth == .checksums && report.notChecked == nil
    }

    @discardableResult
    func syncNow(shootID: UUID) -> Bool {
        guard !cullApplying else { return false }   // a cull is moving files: try again when it finishes
        guard case .done(let report, _)? = syncStates[shootID], report.notChecked == nil, report.depth == .checksums,
              report.missing.values.contains(where: { !$0.isEmpty }) else { return false }
        enqueueSync([shootID], kind: .sync, force: true, deep: false, delay: .zero)
        return true
    }

    /// Stops a running check or Sync Now (files already copied stay; nothing is removed) and drops queued work.
    func stopSync(shootID: UUID) {
        syncWork.removeAll { $0.id == shootID }
        syncGenerations[shootID, default: 0] += 1
        if let running = syncRunning, running.id == shootID { running.task.cancel() }
        if let engine = syncEngines[shootID] {
            engine.cancel()
        } else if case .syncing? = syncStates[shootID] {
            syncStopped.insert(shootID)   // still preparing: the job notices before it writes
        } else if case .checking? = syncStates[shootID] {
            syncStates[shootID] = .unknown("Check stopped")
        }
    }

    func forgetSyncState(_ id: UUID) {
        stopSync(shootID: id)
        syncStopped.remove(id)
        syncStates[id] = nil
        syncNotes[id] = nil
        syncSignatures[id] = nil
        syncMounts[id] = nil
        syncCurrentMounts[id] = nil
        syncDoneAt[id] = nil
        syncDeferred.remove(id)
        if lastDeepVerify.removeValue(forKey: id) != nil { persistDeepVerify() }
    }

    private func persistDeepVerify() {
        let dates = lastDeepVerify, url = syncMetaURL
        let previous = metaSave
        // Chained so an older snapshot can never be written after a newer one.
        metaSave = Task.detached {
            await previous?.value
            SyncMetaStore.save(dates, to: url)
        }
    }

    private func enqueueSync(_ ids: Set<UUID>, kind: SyncWork.Kind, force: Bool, deep: Bool, delay: Duration) {
        let due = ContinuousClock.now.advanced(by: delay)
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            if kind == .check {
                // Anything that started before this request is stale: its result is dropped.
                syncGenerations[id, default: 0] += 1
                if let running = syncRunning, running.id == id { running.task.cancel() }
            }
            if let i = syncWork.firstIndex(where: { $0.id == id && $0.kind == kind }) {
                syncWork[i].force = syncWork[i].force || force
                syncWork[i].deep = syncWork[i].deep || deep
                syncWork[i].notBefore = due
            } else {
                syncWork.append(SyncWork(id: id, kind: kind, force: force, deep: deep, notBefore: due))
            }
        }
        if syncRunner == nil {
            syncRunner = Task { [weak self] in
                if let self { await self.runSyncLoop() }
            }
        } else {
            syncSleeper?.cancel()   // re-evaluate what is due
        }
    }

    /// The one serial worker: at most one check or sync at a time, app-wide.
    private func runSyncLoop() async {
        await startupLoad?.value
        while true {
            let now = ContinuousClock.now
            guard let index = syncWork.firstIndex(where: { $0.notBefore <= now }) else {
                guard let next = syncWork.map(\.notBefore).min() else { break }
                let sleeper = Task<Void, Never> { _ = try? await Task.sleep(until: next, clock: .continuous) }
                syncSleeper = sleeper
                await sleeper.value
                continue
            }
            let work = syncWork.remove(at: index)
            // Checks and syncs read or write the shoot's files: never alongside a cull apply or undo.
            let locked = await acquireApplyLock(excludingIngest: false)
            guard locked else { break }
            switch work.kind {
            case .check: await performCheck(work.id, force: work.force, deep: work.deep)
            case .sync: await performSyncNow(work.id)
            }
            releaseApplyLock()
        }
        syncRunner = nil
        syncSleeper = nil
    }

    private func isIngesting(into copies: [URL], shootID: UUID) -> Bool {
        cards.contains { card in
            guard card.engine != nil else { return false }
            if addTargets[card.id] == shootID || card.plan?.shootID == shootID { return true }
            return (card.plan?.copyRoots ?? []).contains { root in copies.contains { Self.overlap(root, $0) } }
        }
    }

    func unknownReason(_ item: ShootItem) -> String {
        guard !item.copies.isEmpty else { return "Not checked yet" }
        for copy in item.copies where copy.availability != .online {
            let drive = copy.volumeName
            var text: String
            switch copy.availability {
            case .offline: text = "\(drive) isn't connected"
            case .missing: text = "The copy on \(drive) can't be found"
            case .mismatch: text = "The folder on \(drive) is a different shoot"
            case .sameVolume: text = "\(drive) holds more than one copy of this shoot, so it isn't a mirror"
            case .online: continue
            }
            if item.record.pendingSync.contains(where: { Self.copyKey($0) == Self.copyKey(copy.path) }) {
                text += " · new footage isn't on it yet"
            }
            return text
        }
        return "Not checked yet"
    }

    /// The effective-primary-first copy URLs when the shoot has 2+ copies and every one is online; otherwise
    /// the `.single` / `.unknown` state to show.
    private func checkableCopies(_ id: UUID) -> (copies: [URL], blocked: ShootSyncState?) {
        guard let item = shoots.first(where: { $0.id == id }) else { return ([], .unknown("Shoot not found")) }
        guard item.record.copyPaths.count >= 2 else { return ([], .single) }
        guard case .online(let shoot)? = item.availability, !item.copies.isEmpty,
              item.copies.allSatisfy({ $0.availability == .online }),
              shoot.copies.count == item.record.copyPaths.count else { return ([], .unknown(unknownReason(item))) }
        if isIngesting(into: shoot.copies, shootID: id) {
            syncDeferred.insert(id)
            return ([], .unknown("Waiting for a copy into this shoot to finish"))
        }
        return (shoot.copies, nil)
    }

    private func performCheck(_ id: UUID, force: Bool, deep: Bool) async {
        guard let item = shoots.first(where: { $0.id == id }) else { syncStates[id] = nil; return }
        // Mount identity of every copy (a remounted or swapped drive is a new volume): read off main, before
        // the synchronous part below, so the generation captured there cannot miss a bump.
        let provider = volumeIDProvider
        let paths = item.record.copyPaths
        let mounts = await Task.detached { Self.mountIDs(paths, provider) }.value
        syncCurrentMounts[id] = mounts
        let (urls, blocked) = checkableCopies(id)
        if let blocked { syncStates[id] = blocked; return }
        if !force, case .done(let last, _)? = syncStates[id], last.notChecked == nil, last.depth == .checksums,
           let doneAt = syncDoneAt[id], ContinuousClock.now - doneAt < syncThrottle, syncMounts[id] == mounts,
           last.copies.map({ Self.copyKey($0.path) }) == urls.map({ Self.copyKey($0.path) }) {
            return
        }
        // Only copies that were pending when this check began may be cleared by it.
        let pendingAtStart = registry.records.first(where: { $0.id == id })?.pendingSync ?? []
        let gen = syncGenerations[id, default: 0]
        syncChecksStarted += 1
        syncStates[id] = .checking(SyncProgress(phase: .listing), partial: nil)
        let runner = syncChecker, store = checksums
        let onSize: @MainActor @Sendable (ShootSyncReport) -> Void = { [weak self] partial in
            guard let self, gen == self.syncGenerations[id, default: 0], case .checking(let p, _)? = self.syncStates[id] else { return }
            self.syncStates[id] = .checking(p, partial: partial)
        }
        let onProgress: @MainActor @Sendable (SyncProgress) -> Void = { [weak self] progress in
            guard let self, gen == self.syncGenerations[id, default: 0], case .checking(_, let partial)? = self.syncStates[id] else { return }
            self.syncStates[id] = .checking(progress, partial: partial)
        }
        let task = Task<ShootSyncReport?, Never> { await runner(urls, store, deep, onSize, onProgress) }
        syncRunning = (id, task)
        let report = await task.value
        syncRunning = nil
        // A newer request, a stop or a forget superseded this run: its result is dropped.
        guard gen == syncGenerations[id, default: 0], shoots.contains(where: { $0.id == id }) else { return }
        guard let report else { syncStates[id] = .unknown("Check cancelled"); return }
        switch report.notChecked {
        case .singleCopy?: syncStates[id] = .single
        case .copyUnreadable(let url, let message)?:
            syncStates[id] = .unknown("The copy on \(Self.driveLabel(url)) couldn't be read: \(message)")
        case nil:
            syncStates[id] = .done(report, at: Date())
            syncDoneAt[id] = .now
            syncMounts[id] = mounts
            if deep && report.isInSync {
                lastDeepVerify[id] = Date()
                persistDeepVerify()
            }
            await clearPendingSync(id, after: report, only: pendingAtStart)
        }
    }

    /// After a complete check: a copy that is missing nothing and takes part in no conflict is no longer pending.
    private func clearPendingSync(_ id: UUID, after report: ShootSyncReport, only snapshot: [String]) async {
        guard report.notChecked == nil, report.depth == .checksums,
              let record = registry.records.first(where: { $0.id == id }), !record.pendingSync.isEmpty else { return }
        var changed = false
        let allowed = Set(snapshot.map(Self.copyKey))
        for path in record.pendingSync where allowed.contains(Self.copyKey(path)) {
            guard let root = report.copies.first(where: { Self.copyKey($0.path) == Self.copyKey(path) }) else { continue }
            let incomplete = !(report.missing[root] ?? []).isEmpty
                || report.conflicts.contains { $0.copies.contains { Self.copyKey($0.path) == Self.copyKey(path) } }
            if !incomplete { registry.setPendingSync(id: id, path: path, false); changed = true }
        }
        guard changed else { return }
        if let i = shoots.firstIndex(where: { $0.id == id }), let updated = registry.records.first(where: { $0.id == id }) {
            shoots[i].record = updated
        }
        await saveRegistry()
    }

    // MARK: Sync Now

    private static let syncWaitedNote = "Sync Now waited for a copy into this shoot; press Sync Now again when it finishes."

    private func performSyncNow(_ id: UUID) async {
        syncStopped.remove(id)
        syncActive.insert(id)
        defer {
            syncActive.remove(id)
            releaseQueuedCopies()
        }
        let (syncCopies, blocked) = checkableCopies(id)
        if let blocked {
            syncStates[id] = blocked
            if hasActiveIngest(into: id) { syncNotes[id] = Self.syncWaitedNote }
            return
        }
        // Bring every copy up to date with the cull journals first, so rejects are never copied back.
        // Mirrors follow the main copy: the registry's primary is always the replay source.
        let replayNote: String?
        if let primary = primaryCopyURL(id, among: syncCopies) {
            let mirrors = syncCopies.filter { $0.standardizedFileURL != primary.standardizedFileURL }
            replayNote = await Self.replayCullJournals(primary: primary, mirrors: mirrors, cardVolumes: cardVolumes())
        } else {
            replayNote = "Cull replay skipped: the main copy isn't online."
        }
        // Never plan from a stale report: look again first (cache hits make this cheap).
        await performCheck(id, force: true, deep: false)
        guard case .done(let report, _)? = syncStates[id], report.notChecked == nil, report.depth == .checksums,
              report.missing.values.contains(where: { !$0.isEmpty }) else {
            // Still "checking" means a newer request superseded our check: say so rather than dropping the click silently.
            if case .checking? = syncStates[id] { syncNotes[id] = "Sync stopped: the copies changed. Press Sync Now again." }
            return
        }
        if syncStopped.remove(id) != nil { return }

        syncStates[id] = .syncing(CopyProgress())
        let volumes = cardVolumes(), provider = volumeIDProvider, store = checksums
        let plan: SyncPlan
        do {
            plan = try await Self.prepareSync(report: report, shootID: id, cache: store, cardVolumes: volumes, volumeID: provider)
        } catch {
            syncStates[id] = .failed(error.localizedDescription)
            return
        }
        #if DEBUG
        await _testAfterSyncPrepare?(id)
        #endif
        // Stopped or forgotten while preparing: nothing was written yet.
        if syncStopped.remove(id) != nil || !shoots.contains(where: { $0.id == id }) {
            if shoots.contains(where: { $0.id == id }) { syncStates[id] = .unknown("Sync stopped") }
            return
        }
        // An ingest copy may have started while this was preparing: it and Sync Now never write at once.
        if let blocked = checkableCopies(id).blocked {
            syncStates[id] = blocked
            if hasActiveIngest(into: id) { syncNotes[id] = Self.syncWaitedNote }
            return
        }
        let engine = CopyEngine()
        #if DEBUG
        _testSyncEngineHook?(engine)
        #endif
        syncEngines[id] = engine
        syncStates[id] = .syncing(CopyProgress(filesTotal: plan.jobs.count, bytesTotal: plan.jobs.reduce(0) { $0 + $1.file.size }))
        let outcome = await engine.run(plan.jobs) { [weak self] progress in
            guard let self, self.syncEngines[id] === engine else { return }
            self.syncStates[id] = .syncing(progress)
        }
        syncEngines[id] = nil

        // Seed the cache with what landed (off main), so the re-check below is all hits.
        let landed = outcome.copied
        await Task.detached {
            for copied in landed { store.record(copied) }
            await store.saveIfDirty()
        }.value

        // Forgotten while copying: nothing more to record or show.
        guard shoots.contains(where: { $0.id == id }) else { return }
        // Stopped by the user: leave the state as it is, with no re-check or refresh.
        if outcome.cancelled {
            syncStates[id] = .unknown("Sync stopped")
            return
        }
        if outcome.failures.isEmpty {
            syncNotes[id] = replayNote
        } else {
            let first = outcome.failures[0]
            let more = outcome.failures.count > 1 ? " (+\(outcome.failures.count - 1) more)" : ""
            syncNotes[id] = "\(first.name): \(first.reason)\(more)"
        }
        // Forced re-check: clears pendingSync for copies that are now complete, and shows what is left.
        await performCheck(id, force: true, deep: false)
        await refreshShoots()
        // New files in the shoot's copies change which card files count as backed up and what the browser shows.
        if !outcome.copied.isEmpty {
            refreshBrowserMembership(force: true)
            for card in cards where card.engine == nil && !copyQueue.contains(card.id) {
                switch card.phase {
                case .copying, .backed: continue
                default: break
                }
                if addInFlight.contains(card.id) { recomputeAfterAdd.insert(card.id) } else { recompute(card) }
            }
        }
    }

    /// Off main. Every copy must still be off a card, resolve to a drive of its own, and carry this shoot's
    /// sidecar (the planner checks it); every destination folder is validated, then created below its root.
    @concurrent
    nonisolated private static func prepareSync(report: ShootSyncReport, shootID: UUID, cache: ChecksumStore,
                                                cardVolumes: [URL], volumeID: @Sendable (URL) -> String?) async throws -> SyncPlan {
        var drives = Set<String>()
        for root in report.copies {
            if VolumeClassifier.isOnCard(root, cards: cardVolumes) { throw ShootError.onCard }
            guard let drive = volumeID(root) else { throw ShootError.parentMissing }
            guard drives.insert(drive).inserted else { throw ShootError.sameVolumeAsCopy }
        }
        let plan = try await ShootSyncPlanner.plan(report: report, cache: cache, shootID: shootID)
        var roots: [URL] = []
        for job in plan.jobs {
            guard let root = job.root else { throw SyncPlanError.destinationNotThisShoot(job.destDir.path) }
            try ShootPlanner.checkDestination(job.destDir, root: root, cardVolumes: cardVolumes)
            if !roots.contains(root) { roots.append(root) }
        }
        try await ShootSyncPlanner.checkSpace(plan, free: { url in
            let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        })
        for root in roots {
            try ShootPlanner.createDirectories(ShootPlanner.directories(for: plan.jobs.filter { $0.root == root }),
                                               root: root, cardVolumes: cardVolumes)
        }
        return plan
    }

    #if DEBUG
    /// Waits until no check or sync is queued or running.
    func _testSyncIdle() async {
        while let runner = syncRunner { await runner.value }
    }
    #endif
}
