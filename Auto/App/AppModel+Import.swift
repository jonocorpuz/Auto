import AppKit
import Foundation

/// One copy folder an import writes into, with the jobs that land in it.
nonisolated private struct ImportFolderCheck: Sendable {
    let root: URL
    let jobs: [CopyJob]
}

/// Everything the off-main import preflight reads.
nonisolated private struct ImportPreflightInput: Sendable {
    let folderChecks: [ImportFolderCheck]
    let shootID: UUID
    let staged: [MediaFile]
    /// Duplicates the user chose to copy anyway: not re-checked.
    let keptDuplicates: Set<URL>
    let primaryFolder: URL
    let cardVolumes: [URL]
    let cache: VerificationCache
    let freeSpaceOf: @Sendable (URL) -> Int64?
}

/// What the import preflight found, before a byte is written.
nonisolated private struct ImportPreflight: Sendable {
    /// Each copy folder and why it can't take the files (nil: it can).
    let folderResults: [(root: URL, error: String?)]
    /// Sources that changed since staging; they are dropped.
    let changed: Set<URL>
    /// Sources already in the shoot (landed since staging); they are skipped.
    let duplicates: Set<URL>
}

/// Add Files: copies loose files and folders into a shoot through the same engine, queue and bookkeeping as a
/// card ingest. Sources are only ever read (by `CopyEngine`); nothing here deletes, moves or renames them.
extension AppModel {
    // MARK: Staging

    /// Opens a staging session for the sheet and starts the scan + duplicate check.
    @discardableResult
    func beginImport(shootID: UUID, urls: [URL], target: DropTarget = .sorted) -> ImportStaging {
        let staging = ImportStaging(shootID: shootID, target: target, sources: urls)
        restartStaging(staging)
        return staging
    }

    func addSources(_ urls: [URL], to staging: ImportStaging) {
        let known = Set(staging.sources.map { $0.standardizedFileURL.path })
        let fresh = urls.filter { !known.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        staging.sources += fresh
        restartStaging(staging)
    }

    func chooseImportSources(for staging: ImportStaging) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the files and folders to add to this shoot."
        NSApp.activate()
        if panel.runModal() == .OK { addSources(panel.urls, to: staging) }
    }

    private func restartStaging(_ staging: ImportStaging) {
        staging.cancel()
        let generation = staging.generation
        staging.phase = .scanning(0)
        staging.task = Task { await runStaging(staging, generation: generation) }
    }

    private func onlineShoot(_ id: UUID) -> Shoot? {
        guard case .online(let shoot)? = shoots.first(where: { $0.id == id })?.availability else { return nil }
        return shoot
    }

    private func runStaging(_ staging: ImportStaging, generation: Int) async {
        // A newer scan (sources added) or a cancel supersedes this one.
        func current() -> Bool { !Task.isCancelled && staging.generation == generation }
        guard let shoot = onlineShoot(staging.shootID) else {
            staging.phase = .failed(ImportRefusal.shootOffline.localizedDescription)
            return
        }
        let primary = shoot.folder
        let scan: ImportScan
        do {
            scan = try await ImportScanner.scan(staging.sources, shootRoots: shoot.copies) { count in
                Task { @MainActor in
                    if staging.generation == generation, case .scanning = staging.phase { staging.phase = .scanning(count) }
                }
            }
        } catch { return }
        guard current() else { return }
        let flat = shoot.layout == .flat
        // Flat shoots have no camera folders to map onto; their file names are listed off main instead.
        let existing: [String: [String]] = flat ? [:] : await Task.detached { ImportPlanner.existingFolders(in: primary) }.value
        if flat { staging.flatExisting = await ShootPlanner.existingNamesOffMain(in: ShootPlanner.flatDirectories(copies: shoot.copies)) }
        guard current() else { return }
        let cameras = flat ? scan.cameras : ImportPlanner.mapCameras(detected: scan.cameras, existing: existing)
        let folderByID = Dictionary(cameras.map { ($0.id, $0.folderName) }, uniquingKeysWith: { first, _ in first })
        staging.cameras = cameras
        staging.items = scan.files.map {
            StagedFile(file: $0.file, origin: $0.origin, cameraFolder: folderByID[$0.file.cameraID] ?? $0.cameraFolder)
        }
        staging.refused = scan.refused
        staging.ignoredCount = scan.ignoredCount
        staging.warning = nil
        staging.duplicates = []
        staging.phase = .checking

        let files = staging.items.map(\.file)
        let volumes = cards.map(\.volume)
        do {
            let found = try await ImportDuplicateFinder.find(files, shootFolder: primary, cache: verifications,
                                                             cardVolumes: volumes) { _ in }
            guard current() else { return }
            staging.duplicates = found
        } catch is CancellationError {
            return
        } catch {
            guard current() else { return }
            // The shoot couldn't be checked: nothing is skipped, and the sheet says so.
            staging.warning = error.localizedDescription
        }
        staging.phase = .ready
    }

    // MARK: Commit

    /// Plans the selected files into every online copy of the shoot and starts (or queues) the copy.
    /// Throws before anything is written.
    @discardableResult
    func commitImport(_ staging: ImportStaging) throws -> ImportJob {
        guard staging.phase == .ready else { throw ImportRefusal.nothingToAdd }
        guard let item = shoots.first(where: { $0.id == staging.shootID }), case .online(let shoot)? = item.availability else {
            throw ImportRefusal.shootOffline
        }
        let selected = staging.selected
        guard !selected.isEmpty else {
            let onlyDuplicatesLeft = !staging.items.isEmpty && staging.skippedDuplicateCount > 0
            throw onlyDuplicatesLeft ? ImportRefusal.allDuplicates : ImportRefusal.nothingToAdd
        }
        if shoot.copies.contains(where: { isOnCard($0) }) { throw ImportRefusal.destinationOnCard }
        let files = selected.map(\.file)
        let jobs: [CopyJob]
        switch staging.target {
        case .sorted:
            jobs = ImportPlanner.sortedJobs(files: files, copies: shoot.copies, cameras: staging.cameras,
                                            layout: shoot.layout, existing: staging.flatExisting)
        case .exact(let folder):
            jobs = try ImportPlanner.exactJobs(files: files, copies: shoot.copies, primary: shoot.folder, folder: folder)
        }
        guard !jobs.isEmpty,
              jobs.allSatisfy({ job in job.root.map { ShootPlanner.isInside(job.destDir, root: $0) } ?? false }) else {
            throw ShootPlanner.PathError.outsideWorkFolder
        }
        let plan = ShootPlanner.plan(jobs: jobs, shoot: shoot.folder, workRoot: shoot.folder, roots: shoot.copies, shootID: shoot.id)
        let job = ImportJob(shootID: shoot.id, shootName: item.record.name, files: files, plan: plan,
                            skippedDuplicates: staging.skippedDuplicateCount)
        job.keptDuplicates = staging.includeDuplicates.intersection(staging.duplicates)
        staging.cancel()
        imports.append(job)
        startImportIfPossible(job)
        return job
    }

    func hasActiveImport(into shootID: UUID) -> Bool {
        imports.contains { $0.shootID == shootID && $0.isActive }
    }

    func stopImport(_ job: ImportJob) {
        switch job.phase {
        case .queued:
            job.phase = .stopped
        case .preparing, .copying:
            job.stopRequested = true
            job.engine?.cancel()
        default: break
        }
    }

    func dismissImport(_ job: ImportJob) {
        guard job.isFinished else { return }
        imports.removeAll { $0 === job }
    }

    // MARK: Scheduling

    /// An import is running (or preparing) into folders overlapping `roots`.
    func importBusyOverlapping(_ roots: [URL]) -> Bool {
        imports.contains { job in
            job.engine != nil && job.plan.copyRoots.contains { mine in roots.contains { Self.overlap(mine, $0) } }
        }
    }

    /// Cards that asked to copy while an import writes into the same shoot wait here.
    func enqueueBehindImport(_ card: Card) {
        if !copyQueue.contains(card.id) { copyQueue.append(card.id) }
        card.queuedBehind = card.id
        card.queueNote = "Waiting for Add Files to finish"
    }

    /// Something ended: give every queued import another chance, oldest first.
    func startQueuedImports() {
        for job in imports {
            if case .queued = job.phase { startImportIfPossible(job) }
        }
    }

    private func importBlocker(_ job: ImportJob) -> String? {
        let roots = job.plan.copyRoots
        func overlapsMine(_ theirRoots: [URL]) -> Bool {
            theirRoots.contains { theirs in roots.contains { Self.overlap($0, theirs) } }
        }
        let cardIsWriting = cards.contains { card in card.engine != nil && overlapsMine(card.plan?.copyRoots ?? []) }
        if cardIsWriting { return "Waiting for a card copy to finish" }
        let otherImportIsWriting = imports.contains { other in
            other !== job && other.engine != nil && overlapsMine(other.plan.copyRoots)
        }
        if otherImportIsWriting { return "Waiting for another Add Files to finish" }
        if syncBusyOverlapping(roots) { return "Waiting for Sync Now to finish" }
        if cullApplying { return "Waiting for a photo cull to finish" }
        return nil
    }

    func startImportIfPossible(_ job: ImportJob) {
        guard job.engine == nil, case .queued = job.phase else { return }
        if let note = importBlocker(job) {
            job.phase = .queued(note)
            return
        }
        let plan = job.plan
        let usable = currentRoots(of: plan)
        guard !usable.isEmpty else {
            job.phase = .failed("No copy folder is available.")
            return
        }
        if isOnCard(plan.destinationRoot) {
            job.phase = .failed(ImportRefusal.destinationOnCard.localizedDescription)
            return
        }
        let folderChecks: [ImportFolderCheck] = usable.map { root in
            ImportFolderCheck(root: root, jobs: plan.jobs.filter { Self.writes($0, into: root) })
        }
        let freeSpaceOf: @Sendable (URL) -> Int64? = freeSpaceProvider()
        let input = ImportPreflightInput(folderChecks: folderChecks, shootID: job.shootID, staged: job.files,
                                         keptDuplicates: job.keptDuplicates, primaryFolder: plan.copyRoots[0],
                                         cardVolumes: cards.map(\.volume), cache: verifications,
                                         freeSpaceOf: freeSpaceOf)
        let engine = CopyEngine()
        job.engine = engine
        job.phase = .preparing
        noteIngestStarting(roots: plan.copyRoots)
        #if DEBUG
        _testEngineHook?(engine)
        #endif
        let initialJobs = folderChecks.flatMap(\.jobs)
        job.progress = CopyProgress(filesTotal: initialJobs.count, bytesTotal: Self.totalBytes(initialJobs))

        job.task = Task {
            let preflight = await Task.detached { await Self.preflightImport(input) }.value
            await runImport(job, engine: engine, plan: plan, preflight: preflight)
        }
    }

    private static func totalBytes(_ jobs: [CopyJob]) -> Int64 {
        jobs.reduce(0) { $0 + $1.file.size }
    }

    /// Whether `job` writes below the copy folder `root`.
    nonisolated private static func writes(_ job: CopyJob, into root: URL) -> Bool {
        guard let jobRoot = job.root else { return false }
        return VolumeClassifier.normalizedPath(jobRoot) == VolumeClassifier.normalizedPath(root)
    }

    /// After the preflight: copies what is still wanted into the copy folders that passed, or says why not.
    private func runImport(_ job: ImportJob, engine: CopyEngine, plan: CopyPlan, preflight: ImportPreflight) async {
        guard job.engine === engine else {
            job.phase = .failed("This import was interrupted. Add the files again.")
            releaseQueuedCopies()
            return
        }

        // A copy folder may have been removed from the shoot while the preflight ran.
        let stillCopies = Set(currentRoots(of: plan).map(VolumeClassifier.normalizedPath))
        let primaryKey = VolumeClassifier.normalizedPath(plan.copyRoots[0])
        let primaryCheck = preflight.folderResults.first { VolumeClassifier.normalizedPath($0.root) == primaryKey }
        let primaryOK = primaryCheck.map { $0.error == nil } ?? false
        let runRoots = preflight.folderResults
            .filter { $0.error == nil && stillCopies.contains(VolumeClassifier.normalizedPath($0.root)) }
            .map(\.root)
        let runJobs = plan.jobs.filter { copyJob in
            let url = copyJob.file.url
            if preflight.changed.contains(url) || preflight.duplicates.contains(url) { return false }
            return runRoots.contains { Self.writes(copyJob, into: $0) }
        }

        if job.stopRequested {
            endImport(job, phase: .stopped)
            return
        }
        guard primaryOK, !runRoots.isEmpty else {
            let firstError = preflight.folderResults.first(where: { $0.error != nil })?.error
            endImport(job, phase: .failed(firstError ?? "No copy folder is available."))
            return
        }
        guard !runJobs.isEmpty else {
            if preflight.changed.isEmpty && !preflight.duplicates.isEmpty {
                // Everything turned out to be in the shoot already.
                let skipped = job.skippedDuplicates + preflight.duplicates.count
                endImport(job, phase: .done(ImportSummary(copied: 0, bytes: 0, skippedDuplicates: skipped, note: nil)))
                return
            }
            endImport(job, phase: .failed("The files changed since they were added; add them again."))
            return
        }
        // A cull may have taken the lock while the preflight ran: wait for it like a card does.
        if cullApplying {
            job.engine = nil
            job.phase = .queued("Waiting for a photo cull to finish")
            return
        }

        job.progress = CopyProgress(filesTotal: runJobs.count, bytesTotal: Self.totalBytes(runJobs))
        job.phase = .copying
        ingestRunCount += 1
        let outcome = await engine.run(runJobs) { progress in job.progress = progress }
        job.engine = nil
        ingestRunCount -= 1
        await finishImport(job, plan: plan, runRoots: runRoots, outcome: outcome,
                           dropped: preflight.changed.count, duplicates: preflight.duplicates.count)
    }

    /// Ends an import that copied nothing.
    private func endImport(_ job: ImportJob, phase: ImportPhase) {
        job.engine = nil
        job.phase = phase
        releaseQueuedCopies()
    }

    // MARK: Preflight (off main)

    /// Off main, before a byte is written: every copy folder exists and carries this shoot's id, has room,
    /// and its directories are safe; sources that changed since staging are dropped.
    nonisolated private static func preflightImport(_ input: ImportPreflightInput) async -> ImportPreflight {
        let folderResults = input.folderChecks.map { check -> (root: URL, error: String?) in
            do {
                try prepareCopyFolder(check, shootID: input.shootID, cardVolumes: input.cardVolumes,
                                      freeSpaceOf: input.freeSpaceOf)
                return (check.root, nil)
            } catch {
                return (check.root, error.localizedDescription)
            }
        }
        let changed = changedSources(input.staged)
        // Another copy (a card ingest that ran first) may have landed the same bytes since staging.
        var duplicates = Set<URL>()
        let toCheck = input.staged.filter { !input.keptDuplicates.contains($0.url) && !changed.contains($0.url) }
        if !toCheck.isEmpty,
           let found = try? await ImportDuplicateFinder.find(toCheck, shootFolder: input.primaryFolder, cache: input.cache,
                                                             cardVolumes: input.cardVolumes, progress: { _ in }) {
            duplicates = found
        }
        return ImportPreflight(folderResults: folderResults, changed: changed, duplicates: duplicates)
    }

    /// Checks one copy folder can take its jobs, then creates their directories.
    nonisolated private static func prepareCopyFolder(_ check: ImportFolderCheck, shootID: UUID, cardVolumes: [URL],
                                                      freeSpaceOf: @Sendable (URL) -> Int64?) throws {
        let directories = ShootPlanner.directories(for: check.jobs)
        let resolvedRoot = ShootPlanner.resolvedPath(check.root)
        for directory in directories {
            // A directory that resolves into _Rejects or .auto-cull (e.g. through a symlink) is off limits.
            let components = ShootPlanner.relativeComponents(ShootPlanner.resolvedPath(directory), to: resolvedRoot) ?? []
            if components.contains(where: { ImportPlanner.reserved.contains($0.lowercased()) }) {
                throw ImportRefusal.destinationNotInShoot
            }
            try ShootPlanner.checkDestination(directory, root: check.root, cardVolumes: cardVolumes)
        }
        let needed = check.jobs.reduce(Int64(0)) { $0 + $1.file.size }
        if let free = freeSpaceOf(check.root), free < needed {
            throw NotEnoughSpaceError(needed: needed, free: free)
        }
        try preflight(workRoot: check.root, shootID: shootID)
        try ShootPlanner.createDirectories(directories, root: check.root, cardVolumes: cardVolumes)
    }

    /// Staged sources whose size, or modification date (beyond a second), no longer match the scan.
    nonisolated private static func changedSources(_ staged: [MediaFile]) -> Set<URL> {
        var changed = Set<URL>()
        for file in staged {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.resolvingSymlinksInPath().path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            let modified = attributes?[.modificationDate] as? Date
            let sizeChanged = size != file.size
            let dateChanged = modified.map { abs($0.timeIntervalSince(file.date)) > 1 } == true
            if sizeChanged || dateChanged { changed.insert(file.url) }
        }
        return changed
    }

    // MARK: Finish

    private func finishImport(_ job: ImportJob, plan: CopyPlan, runRoots: [URL], outcome: CopyOutcome, dropped: Int, duplicates: Int) async {
        let blocked = Self.integrityBlocked(outcome)
        let landedFiles = outcome.copied.filter { !blocked.contains($0.file.url) }
        let store = checksums
        Task.detached {
            for copied in landedFiles { store.record(copied) }
            await store.saveIfDirty()
        }
        sessionCopies.append(contentsOf: landedFiles)
        verifications.record(landedFiles)

        let done = Set(landedFiles.map(\.file.url))
        let marks = pendingSync(shootID: plan.shootID, runRoots: runRoots, outcome: outcome, done: done, blocked: blocked)
        var blocking = outcome.failures.filter { !done.contains($0.file) }
        for url in blocked where !blocking.contains(where: { $0.file == url }) {
            blocking.append(.init(name: url.lastPathComponent, reason: "Its copies didn't match each other",
                                  file: url, root: nil, kind: .integrity))
        }
        let doneFiles = job.files.filter { done.contains($0.url) }
        var notes: [String] = []
        if let note = marks?.note { notes.append(note) }
        if dropped > 0 {
            let verb = dropped == 1 ? "was" : "were"
            notes.append("\(Format.count(dropped, "file", "files")) changed since they were added and \(verb) skipped.")
        }
        if let first = blocking.first {
            let more = blocking.count > 1 ? " (+\(blocking.count - 1) more)" : ""
            job.phase = .failed("\(first.name): \(first.reason)\(more)")
        } else if outcome.cancelled || job.stopRequested {
            job.phase = .stopped
        } else {
            let note = notes.isEmpty ? nil : notes.joined(separator: " ")
            job.phase = .done(ImportSummary(copied: doneFiles.count, bytes: doneFiles.reduce(0) { $0 + $1.size },
                                            skippedDuplicates: job.skippedDuplicates + duplicates, note: note))
        }

        // Cards' duplicate verdicts see the landed files.
        let copiedKeys = Set(outcome.copied.map(\.file.key))
        for other in cards where other.engine == nil && !copyQueue.contains(other.id) {
            guard needsRecompute(other, afterCopyOf: copiedKeys) else { continue }
            if addInFlight.contains(other.id) {
                recomputeAfterAdd.insert(other.id)
            } else {
                recompute(other)
            }
        }
        releaseQueuedCopies()
        for card in cards where coverage[CoverageKey(shootID: job.shootID, cardID: card.id)] != nil {
            checkCoverage(shootID: job.shootID, cardID: card.id)
        }
        refreshBrowserMembership(force: true)
        if marks != nil { await saveRegistry() }
        await refreshShoots()
        if !outcome.copied.isEmpty { scheduleSyncCheck([job.shootID], force: true) }
    }
}
