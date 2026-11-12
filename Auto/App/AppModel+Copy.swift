import AppKit
import Foundation

/// Card copies: planning a destination, running the `CopyEngine`, the copy queue and the bookkeeping
/// that follows a run. Source cards are only ever read here.
extension AppModel {
    // MARK: Errors

    struct PhaseError: LocalizedError {
        var errorDescription: String? { "This card can't start a new shoot right now." }
    }

    struct EmptySelectionError: LocalizedError {
        var errorDescription: String? { "Select at least one file to copy." }
    }

    nonisolated struct NotEnoughSpaceError: LocalizedError {
        let needed: Int64
        let free: Int64
        var errorDescription: String? { "Not enough space: needs \(Format.bytes(needed)), \(Format.bytes(free)) free." }
    }

    // MARK: Choosing a destination

    /// Whether `name` can be used as the shoot folder name.
    func isValidShootName(_ name: String) -> Bool {
        ShootPlanner.safeComponent(name) != nil
    }

    private func canPlan(_ card: Card) -> Bool {
        switch card.phase {
        case .needsBackup, .ready, .failed: true
        default: false
        }
    }

    /// "Choose Folder": plans a flat copy of the card's missing files into a folder the user picks.
    func chooseFolder(for card: Card) {
        guard canPlan(card) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy here"
        let alreadyBackedUpCount = card.files.count - card.missing.count
        var message = "Choose where \(card.name)'s \(card.missing.count) files should go."
        if alreadyBackedUpCount > 0 { message += " \(alreadyBackedUpCount) files already backed up are skipped." }
        panel.message = message
        panel.directoryURL = workRoot
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        if isOnCard(folder) {
            let alert = NSAlert()
            alert.messageText = "Can't copy to a camera card"
            alert.informativeText = CardDestinationError().localizedDescription
            alert.runModal()
            return
        }
        // A copy may have started while the panel was open.
        guard card.engine == nil else { return }
        stopVerifier(card)
        card.plan = ShootPlanner.flatPlan(missing: card.missing, into: folder)
        forgetPendingPlan(of: card)
        card.phase = .ready
        cardSettledAfterStop(card)
    }

    /// Every connected card volume plus `card`'s own (it may be stale), deduplicated.
    func volumes(including card: Card) -> [URL] {
        var seen = Set<String>()
        return (cards.map(\.volume) + [card.volume]).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Whether `url` is on any connected card (the source card included).
    func isOnCard(_ url: URL) -> Bool {
        VolumeClassifier.isOnCard(url, cards: cards.map(\.volume))
    }

    func setWorkRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Choose the folder your shoots live in, e.g. T7 Shield › 2026."
        panel.directoryURL = workRoot ?? URL(fileURLWithPath: "/Volumes")
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { workRoot = url }
    }

    func discardPlan(_ card: Card) {
        guard card.engine == nil else { return }
        card.plan = nil
        forgetPendingPlan(of: card)
        recompute(card)
    }

    func openInFinder(_ card: Card) {
        NSWorkspace.shared.open(card.volume)
        if let destination = card.plan?.destinationRoot { NSWorkspace.shared.open(destination) }
    }

    // MARK: Copying

    func copy(_ card: Card) {
        // One engine per card.
        guard let plan = card.plan, card.engine == nil, card.phase != .copying else { return }
        // Two engines never write into overlapping folders (e.g. the same shoot) at once: wait for the other
        // one. Checked before the verifier is touched, so a waiting card keeps its state.
        let myRoots = plan.copyRoots
        if let blocker = cardCopyingInto(myRoots, otherThan: card) {
            enqueue(card, behind: blocker)
            return
        }
        if syncBusyOverlapping(myRoots) {
            enqueueBehindSync(card)
            return
        }
        if cullApplying {
            enqueueBehindCull(card)
            return
        }
        if importBusyOverlapping(myRoots) {
            enqueueBehindImport(card)
            return
        }
        dequeue(card)
        card.mirrorNote = nil
        stopVerifier(card)
        if isOnCard(plan.destinationRoot) {
            card.phase = .failed(CardDestinationError().localizedDescription)
            cardSettledAfterStop(card)
            return
        }
        // Destinations and free space are checked per copy. A copy that fails is left out (marked for sync
        // afterwards) as long as another one can take the files; if none can, the card fails.
        let volumes = volumes(including: card)
        // The checks themselves run off main in the task below, with the preflight.
        let usable = currentRoots(of: plan)
        guard !usable.isEmpty else {
            card.phase = .failed("No copy folder is available.")
            cardSettledAfterStop(card)
            return
        }
        let rootChecks: [RootCheck] = usable.map { root in
            RootCheck(root: root, jobs: Self.jobs(in: plan.jobs, roots: [root], of: myRoots))
        }
        let freeSpaceOf = freeSpaceProvider()

        let engine = CopyEngine()
        card.engine = engine
        noteIngestStarting(roots: myRoots)
        #if DEBUG
        _testEngineHook?(engine)
        #endif
        invalidateBrowserMembership(for: card)
        let startJobs = Self.jobs(in: plan.jobs, roots: usable, of: myRoots)
        card.progress = Self.initialProgress(for: startJobs)
        card.phase = .copying
        let addShootID = addTargets[card.id]
        let preflightShootID = plan.shootID ?? addShootID
        let pruneDuplicates = !includeDuplicatePlans.contains(card.id)

        var prunedMarked = false
        Task {
            // Off main: every copy folder must still exist, and carry the shoot's id for an add-footage plan,
            // before a single byte is written. A copy that fails is left out while another passes.
            let checks = await Task.detached {
                rootChecks.map { check in
                    let error = Self.destinationError(for: check, cardVolumes: volumes, freeSpaceOf: freeSpaceOf,
                                                      shootID: preflightShootID)
                    return (root: check.root, error: error)
                }
            }.value
            guard card.engine === engine else { return }
            // The shoot's copies may have changed while the preflight ran.
            let stillCopies = Set(currentRoots(of: plan).map(VolumeClassifier.normalizedPath))
            let runRoots = checks
                .filter { $0.error == nil && stillCopies.contains(VolumeClassifier.normalizedPath($0.root)) }
                .map(\.root)
            guard !runRoots.isEmpty else {
                let firstError = checks.first(where: { $0.error != nil })?.error
                card.engine = nil
                card.phase = .failed(firstError ?? "No copy folder is available.")
                refreshBrowserMembership(force: true)
                releaseQueuedCopies()
                return
            }

            // The verdict may have changed since the plan was made (another card's copy landed): drop jobs whose
            // file now has a verified copy, unless the user asked to copy duplicates anyway.
            if pruneDuplicates {
                let backups = card.backups
                let files = plan.jobs.map(\.file)
                // No target exclusion here: a file that just landed in the target shoot (a queued card behind
                // another card's copy into the same shoot) is as done as one verified anywhere else.
                let found = IngestDuplicates.find(candidates: files, backups: backups, missing: Set(card.missing.map(\.url)),
                                                  shoots: shootRoots(), target: nil)
                let confirmed = await IngestDuplicates.revalidate(found, backups: backups, cache: verifications)
                guard card.engine === engine else { return }
                let drop = Set(confirmed.files.map(\.url))
                if !drop.isEmpty {
                    // A file verified in only some copies of the target shoot leaves the others short.
                    prunedMarked = markCopiesMissingPruned(of: card, plan: plan, dropped: confirmed.files, backups: backups)
                    card.plan?.jobs.removeAll { drop.contains($0.file.url) }
                    if card.plan?.jobs.isEmpty != false {
                        NSLog("Auto: \(card.name): everything in the plan is already backed up; nothing copied.")
                        card.plan = nil
                        addTargets[card.id] = nil
                        includeDuplicatePlans.remove(card.id)
                        card.engine = nil
                        card.phase = .needsBackup
                        recompute(card)
                        releaseQueuedCopies()
                        if prunedMarked {
                            await saveRegistry()
                            await refreshShoots()
                        }
                        return
                    }
                }
            }
            let runJobs = Self.jobs(in: card.plan?.jobs ?? plan.jobs, roots: runRoots, of: myRoots)
            card.progress = Self.initialProgress(for: runJobs)
            ingestRunCount += 1
            let outcome = await engine.run(runJobs) { progress in card.progress = progress }
            card.engine = nil
            ingestRunCount -= 1
            releaseQueuedCopies()
            await finishCopy(of: card, plan: plan, runRoots: runRoots, outcome: outcome, prunedMarked: prunedMarked)
        }
    }

    /// Bookkeeping after the engine returns: records what landed, marks copies that are now short,
    /// settles the card's phase and schedules the follow-up checks.
    private func finishCopy(of card: Card, plan: CopyPlan, runRoots: [URL], outcome: CopyOutcome, prunedMarked: Bool) async {
        // A file with a failed checksum on any copy, or copies that disagree, is not done: its jobs stay.
        let blocked = Self.integrityBlocked(outcome)
        let landedFiles = outcome.copied.filter { !blocked.contains($0.file.url) }
        // Seed the checksum cache from the verified copies, off main and without waiting for it.
        let store = checksums
        Task.detached {
            for copied in landedFiles { store.record(copied) }
            await store.saveIfDirty()
        }
        sessionCopies.append(contentsOf: landedFiles)
        verifications.record(landedFiles)

        // A file is done once it reached at least one copy; the others are marked for sync.
        let done = Set(landedFiles.map(\.file.url))
        let marked = markUnreachedCopies(of: card, plan: plan, runRoots: runRoots, outcome: outcome, done: done, blocked: blocked)
            || prunedMarked
        card.plan?.jobs.removeAll { done.contains($0.file.url) }
        // Just-copied files must not be selectable again while they re-verify.
        card.missing.removeAll { done.contains($0.url) }
        if card.plan?.jobs.isEmpty == true { card.plan = nil }
        // The add target lives as long as the plan does (partial failures retry into the same shoot).
        if card.plan == nil {
            addTargets[card.id] = nil
            includeDuplicatePlans.remove(card.id)
        }
        card.backedTo = backedToLabel(plan: plan, runRoots: runRoots, outcome: outcome)
        // Flat plans into a folder inside a shoot copy leave that shoot's other copies short.
        let flatMarked = plan.shootID == nil && markShootsContaining(plan.destinationRoot, card: card, done: done)

        // Failures of files that reached no copy fail the card. A mirror failing for a file that did land is a sync matter.
        var blocking = outcome.failures.filter { !done.contains($0.file) }
        for url in blocked where !blocking.contains(where: { $0.file == url }) {
            blocking.append(.init(name: url.lastPathComponent, reason: "Its copies didn't match each other",
                                  file: url, root: nil, kind: .integrity))
        }
        if let first = blocking.first {
            let otherFailureCount = blocking.count - 1
            let more = otherFailureCount > 0 ? " (+\(otherFailureCount) more)" : ""
            card.phase = .failed("\(first.name): \(first.reason)\(more)")
        } else {
            card.phase = .needsBackup
        }
        // A failed card stays failed on screen (Retry copies again); a re-verify would turn it back into "ready".
        if blocking.isEmpty { recompute(card) }

        // This copy may make other cards' files duplicates (or fully backed): re-verify idle cards.
        let copiedKeys = Set(outcome.copied.map(\.file.key))
        for other in cards where other !== card && !copyQueue.contains(other.id) && needsRecompute(other, afterCopyOf: copiedKeys) {
            recomputeOnceIdle(other)
        }
        releaseQueuedCopies()

        // Anything that landed inside a registered shoot changes that shoot's coverage.
        let landed = shoots.filter { item in
            guard case .online(let shoot)? = item.availability else { return false }
            return shoot.copies.contains { ShootPlanner.relativeComponents(plan.destinationRoot, to: $0) != nil }
        }
        for item in landed { checkCoverage(shootID: item.id, cardID: card.id) }
        // Another card's copy landing in a shoot changes the browsed card's membership too.
        if !landed.isEmpty, card.id != browsingCardID { refreshBrowserMembership(force: true) }
        if marked || flatMarked { await saveRegistry() }
        if !landed.isEmpty || marked || flatMarked { await refreshShoots() }

        // The copies of a shoot that just received files may now differ: check them (forced).
        var toCheck = Set(landed.map(\.id))
        if !outcome.copied.isEmpty {
            // Includes flat Choose Folder plans whose root is inside any copy (not only the primary).
            let written = plan.copyRoots + [plan.destinationRoot]
            for item in shoots {
                guard case .online(let shoot)? = item.availability else { continue }
                let wasWrittenInto = shoot.copies.contains { copy in written.contains { Self.overlap($0, copy) } }
                if wasWrittenInto { toCheck.insert(item.id) }
            }
        }
        if !outcome.copied.isEmpty, let shootID = plan.shootID { toCheck.insert(shootID) }
        if !toCheck.isEmpty { scheduleSyncCheck(toCheck, force: true) }
        if !outcome.cancelled { openMainWindow() }
    }

    // MARK: Copy helpers

    /// One copy folder of a plan and the jobs that write into it.
    private struct RootCheck: Sendable {
        let root: URL
        let jobs: [CopyJob]
    }

    /// Another card whose running copy writes into a folder overlapping `roots`.
    private func cardCopyingInto(_ roots: [URL], otherThan card: Card) -> Card? {
        cards.first { other in
            guard other !== card, other.engine != nil, let theirPlan = other.plan else { return false }
            return roots.contains { mine in theirPlan.copyRoots.contains { Self.overlap(mine, $0) } }
        }
    }

    private static func initialProgress(for jobs: [CopyJob]) -> CopyProgress {
        CopyProgress(filesTotal: jobs.count, bytesTotal: jobs.reduce(0) { $0 + $1.file.size })
    }

    /// Why this copy folder can't take its jobs (nil: it can). Touches the disk, so call it off main.
    nonisolated private static func destinationError(for check: RootCheck, cardVolumes: [URL],
                                                     freeSpaceOf: (URL) -> Int64?, shootID: UUID?) -> String? {
        do {
            for directory in ShootPlanner.directories(for: check.jobs) {
                try ShootPlanner.checkDestination(directory, root: check.root, cardVolumes: cardVolumes)
            }
            let needed = check.jobs.reduce(Int64(0)) { $0 + $1.file.size }
            if let free = freeSpaceOf(check.root), free < needed {
                throw NotEnoughSpaceError(needed: needed, free: free)
            }
            try preflight(workRoot: check.root, shootID: shootID)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Where the card's files now live, for the "All on …" line.
    private func backedToLabel(plan: CopyPlan, runRoots: [URL], outcome: CopyOutcome) -> String {
        let reachedRoots = runRoots.filter { root in
            outcome.copied.contains { ShootPlanner.isInside($0.destination, root: root) }
        }
        let reachedLabels = Self.unique(reachedRoots.map { Self.copyLabel($0.path) })
        if plan.copyRoots.count > 1, !reachedLabels.isEmpty {
            return reachedLabels.joined(separator: " and ")
        }
        // "\u{0}" never prefixes a path, so no working volume means "not on the working drive".
        let isOnWorkingDrive = plan.destinationRoot.path.hasPrefix(workingVolume?.path ?? "\u{0}")
        return isOnWorkingDrive ? workingDriveName : plan.destinationLabel
    }

    /// Re-verifies a card now, or right after its in-flight addFootage/addFiles call ends.
    private func recomputeOnceIdle(_ card: Card) {
        if addInFlight.contains(card.id) {
            recomputeAfterAdd.insert(card.id)
        } else {
            recompute(card)
        }
    }

    // MARK: Copy queue

    private func enqueue(_ card: Card, behind other: Card) {
        if !copyQueue.contains(card.id) { copyQueue.append(card.id) }
        card.queuedBehind = other.id
        card.queueNote = "Waiting for \(other.name) to finish"
    }

    /// Takes a card out of the queue (it keeps its plan and phase). Safe to call for any card.
    func dequeue(_ card: Card) {
        copyQueue.removeAll { $0 == card.id }
        card.queuedBehind = nil
        card.queueNote = nil
    }

    /// An engine just ended. Re-verify each waiting card, since the copy that finished may have made its files
    /// duplicates; `finishRecompute` then starts it (and `copy` prunes the twins from its plan).
    func releaseQueuedCopies() {
        cullWaiters.wake()
        flushDeferredSyncChecks()
        startQueuedImports()
        for id in copyQueue {
            guard let queued = cards.first(where: { $0.id == id }) else {
                copyQueue.removeAll { $0 == id }
                continue
            }
            guard queued.engine == nil else { continue }
            recomputeOnceIdle(queued)
        }
    }

    // MARK: Roots, labels and space

    static func overlap(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL == b.standardizedFileURL || ShootPlanner.isInside(a, root: b) || ShootPlanner.isInside(b, root: a)
    }

    /// The jobs that write to `roots`. A single-root plan (flat folder, legacy) uses all jobs.
    private static func jobs(in jobs: [CopyJob], roots: [URL], of all: [URL]) -> [CopyJob] {
        guard all.count > 1 else { return jobs }
        let wantedRoots = Set(roots.map(VolumeClassifier.normalizedPath))
        return jobs.filter { job in
            guard let jobRoot = job.root else { return false }
            return wantedRoots.contains(VolumeClassifier.normalizedPath(jobRoot))
        }
    }

    /// Short name for where a copy lives: the external drive's name, or "This Mac".
    nonisolated static func copyLabel(_ path: String) -> String {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : "This Mac"
    }

    /// After a run in which something landed: every copy of the shoot that did not get every landed file (offline,
    /// left out before the run, or failed during it) is marked `pendingSync`, and the card says so. Returns
    /// whether the registry changed (the caller saves it).
    private func markUnreachedCopies(of card: Card, plan: CopyPlan, runRoots: [URL], outcome: CopyOutcome,
                                     done: Set<URL>, blocked: Set<URL>) -> Bool {
        guard let marks = pendingSync(shootID: plan.shootID, runRoots: runRoots, outcome: outcome,
                                      done: done, blocked: blocked) else { return false }
        card.mirrorNote = marks.note
        return true
    }

    /// Shared by cards and imports: marks every copy of `shootID` that didn't get every landed file as
    /// `pendingSync` and returns the user-facing note (nil: nothing was short, the registry is unchanged).
    func pendingSync(shootID: UUID?, runRoots: [URL], outcome: CopyOutcome, done: Set<URL>, blocked: Set<URL>) -> (note: String, reached: [String])? {
        guard !done.isEmpty, let shootID, let record = registry.records.first(where: { $0.id == shootID }) else { return nil }
        let ran = Set(runRoots.map(VolumeClassifier.normalizedPath))
        var short = record.copyPaths.filter { !ran.contains(VolumeClassifier.normalizedPath(URL(fileURLWithPath: $0))) }
        var reached: [String] = []
        for root in runRoots {
            let landedInRoot = outcome.copied.filter { copied in
                !blocked.contains(copied.file.url) && ShootPlanner.isInside(copied.destination, root: root)
            }
            let landedFiles = Set(landedInRoot.map(\.file.url))
            if done.isSubset(of: landedFiles) {
                reached.append(Self.copyLabel(root.path))
            } else {
                short.append(root.path)
            }
        }
        guard !short.isEmpty else { return nil }
        for path in short { registry.setPendingSync(id: shootID, path: path, true) }

        let shortNames = Self.unique(short.map(Self.copyLabel)).joined(separator: " and ")
        let note: String
        if reached.isEmpty {
            note = "\(shortNames) didn't get every file; sync the shoot when it's connected."
        } else {
            let reachedNames = Self.unique(reached).joined(separator: " and ")
            note = "Copied to \(reachedNames). \(shortNames) wasn't updated; sync the shoot when it's connected."
        }
        return (note, reached)
    }

    nonisolated static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Files that must stay in the plan: a checksum/size failure on any copy, or copies whose source checksums differ.
    nonisolated static func integrityBlocked(_ outcome: CopyOutcome) -> Set<URL> {
        var blocked = Set(outcome.failures.filter { $0.kind == .integrity }.map(\.file))
        var checksumBySource: [URL: Data] = [:]
        for copied in outcome.copied {
            guard let checksum = copied.checksum else { continue }
            if let earlier = checksumBySource[copied.file.url], earlier != checksum {
                blocked.insert(copied.file.url)
            } else {
                checksumBySource[copied.file.url] = checksum
            }
        }
        return blocked
    }

    /// Path key for comparing copy folders: normalized, and insensitive to case and Unicode form.
    private func cmpKey(_ path: String) -> String {
        VolumeClassifier.normalizedPath(URL(fileURLWithPath: path)).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The plan's copy roots that are still copies of its shoot (a copy removed or moved since planning is dropped).
    /// Plans without a shoot keep all roots.
    func currentRoots(of plan: CopyPlan) -> [URL] {
        guard let id = plan.shootID else { return plan.copyRoots }
        guard let record = registry.records.first(where: { $0.id == id }) else { return [] }
        let current = Set(record.copyPaths.map(cmpKey))
        return plan.copyRoots.filter { current.contains(cmpKey($0.path)) }
    }

    /// The free-space lookup to use off main: free bytes on the volume holding a URL (nil: unknown).
    /// Tests can substitute `_testFreeSpace`.
    func freeSpaceProvider() -> @Sendable (URL) -> Int64? {
        #if DEBUG
        if let fake = _testFreeSpace { return fake }
        #endif
        return { Self.diskFreeSpace($0) }
    }

    nonisolated private static func diskFreeSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Copy-time pruning dropped files already verified inside a copy of the target shoot: every other copy of
    /// that shoot lacks them, so mark those copies for sync.
    private func markCopiesMissingPruned(of card: Card, plan: CopyPlan, dropped: [MediaFile], backups: [URL: URL]) -> Bool {
        guard let id = plan.shootID, let record = registry.records.first(where: { $0.id == id }) else { return false }
        let roots = record.copyPaths
        var short = Set<String>()
        for file in dropped {
            guard let copy = backups[file.url] else { continue }
            let path = VolumeClassifier.normalizedPath(copy)
            let holder = roots.first { root in
                path.hasPrefix(VolumeClassifier.normalizedPath(URL(fileURLWithPath: root)) + "/")
            }
            guard let holder else { continue }
            for other in roots where cmpKey(other) != cmpKey(holder) { short.insert(other) }
        }
        guard !short.isEmpty else { return false }
        for path in roots where short.contains(path) { registry.setPendingSync(id: id, path: path, true) }
        let names = Self.unique(roots.filter { short.contains($0) }.map(Self.copyLabel)).joined(separator: " and ")
        card.mirrorNote = "\(names) is missing files already in this shoot; sync the shoot when it's connected."
        return true
    }

    /// A flat copy into a folder inside one copy of a registered shoot: that shoot's other copies lack the files.
    private func markShootsContaining(_ root: URL, card: Card, done: Set<URL>) -> Bool {
        guard !done.isEmpty else { return false }
        var changed = false
        var names: [String] = []
        for record in registry.records {
            let holders = record.copyPaths.filter { ShootPlanner.relativeComponents(root, to: URL(fileURLWithPath: $0)) != nil }
            guard !holders.isEmpty else { continue }
            let holderKeys = Set(holders.map(cmpKey))
            for other in record.copyPaths where !holderKeys.contains(cmpKey(other)) {
                registry.setPendingSync(id: record.id, path: other, true)
                names.append(Self.copyLabel(other))
                changed = true
            }
        }
        if changed {
            card.mirrorNote = "\(Self.unique(names).joined(separator: " and ")) wasn't updated; sync the shoot when it's connected."
        }
        return changed
    }

    /// Whether a card is copying into `shootID` right now (the sheet warns that its files will be skipped).
    func isCopyingInto(shootID: UUID) -> Card? {
        cards.first { $0.engine != nil && addTargets[$0.id] == shootID }
    }

    /// Whether an Add Files run or a card is copying into, or queued to copy into, `shootID`.
    func hasActiveIngest(into shootID: UUID) -> Bool {
        if hasActiveImport(into: shootID) { return true }
        return cards.contains { card in
            let isCopyingOrQueued = card.engine != nil || card.queuedBehind != nil
            let targetsShoot = card.plan?.shootID == shootID || addTargets[card.id] == shootID
            return isCopyingOrQueued && targetsShoot
        }
    }

    /// Why the copies of `shootID` can't be removed or moved right now (nil: they can).
    func copyOpBlock(for shootID: UUID) -> Error? {
        if hasActiveIngest(into: shootID) { return ShootBusyError() }
        if syncActive.contains(shootID) { return SyncBusyError() }
        return nil
    }

    /// Whether another card's verdict can change because files with `copiedKeys` (name+size) just landed:
    /// it has no engine, isn't copying or backed, and some missing file shares a key. A running verifier is
    /// fine: recompute restarts it, and the verification cache keeps what it already proved.
    func needsRecompute(_ card: Card, afterCopyOf copiedKeys: Set<String>) -> Bool {
        guard card.engine == nil else { return false }
        switch card.phase {
        case .copying, .backed: return false
        case .scanning: guard recomputePending.contains(card.id) else { return false }
        default: break
        }
        return card.missing.contains { copiedKeys.contains($0.key) }
    }

    /// Last check before writing: the folder must still exist and, for a shoot, still carry that shoot's id.
    nonisolated static func preflight(workRoot: URL?, shootID: UUID?) throws {
        guard let root = workRoot else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ShootPlanner.PathError.workFolderMissing
        }
        if let shootID {
            guard try ShootFolders.readSidecar(in: root)?.id == shootID else { throw ShootError.sidecarMismatch }
        }
    }

    /// Stops a running copy, or takes a waiting card out of the queue (it stays ready with its plan).
    func stop(_ card: Card) {
        dequeue(card)
        card.engine?.cancel()
    }

    /// Retries the copy if there is a plan, otherwise re-checks the card. Never both at once.
    func retry(_ card: Card) {
        guard card.engine == nil else { return }
        if card.plan != nil {
            copy(card)
        } else {
            card.phase = .needsBackup
            recompute(card)
        }
    }

    /// Only a verified-backed, idle card can be ejected from Auto.
    func canEject(_ card: Card) -> Bool {
        card.phase == .backed && card.engine == nil && card.verifier == nil && !card.ejecting
    }

    func eject(_ card: Card) {
        guard canEject(card) else { return }
        card.ejecting = true
        card.ejectError = nil
        let volume = card.volume
        Task {
            let error = await Task.detached { () -> Error? in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                    return nil
                } catch {
                    return error
                }
            }.value
            card.ejecting = false
            // Shown beside the card; never replaces whatever phase the card is in now.
            if let error { card.ejectError = "Couldn't eject: \(error.localizedDescription)" }
        }
    }
}
