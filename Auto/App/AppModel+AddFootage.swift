import AppKit
import Foundation

extension AppModel {
    // MARK: Add footage

    struct UnknownTargetError: LocalizedError {
        var errorDescription: String? { "That shoot or card isn't available any more." }
    }

    func cancelCoverage(where match: (CoverageKey) -> Bool) {
        for key in coverageTasks.keys where match(key) { coverageTasks[key]?.cancel(); coverageTasks[key] = nil }
        for key in coverage.keys where match(key) { coverage[key] = nil; coverageGenerations[key] = nil }
    }

    /// Checks (off the main actor) which of the card's files are already verified inside the shoot.
    func checkCoverage(shootID: UUID, cardID: Card.ID) {
        let key = CoverageKey(shootID: shootID, cardID: cardID)
        guard let card = cards.first(where: { $0.id == cardID }),
              let item = shoots.first(where: { $0.id == shootID }),
              case .online(let shoot)? = item.availability else {
            cancelCoverage { $0 == key }
            return
        }
        startCoverage(key: key, files: card.files, folder: shoot.folder, day: item.date)
    }

    /// Core of `checkCoverage` with explicit inputs. Returns the task so callers can await it.
    @discardableResult
    func startCoverage(key: CoverageKey, files: [MediaFile], folder: URL, day: Date) -> Task<Void, Never> {
        coverageTasks[key]?.cancel()
        coverageCounter += 1
        let generation = coverageCounter
        coverageGenerations[key] = generation
        coverage[key] = .checking(CopyProgress())
        let copies = sessionCopies
        let cache = verifications
        let calendar = calendar
        let cardVolumes = cards.map(\.volume)
        let task = Task {
            let (stream, continuation) = AsyncStream<CopyProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let consumer = Task {
                for await progress in stream {
                    if coverageGenerations[key] == generation, case .checking? = coverage[key] { coverage[key] = .checking(progress) }
                }
            }
            let result = await ShootCoverageChecker.run(files: files, shootFolder: folder, sessionCopies: copies, cache: cache,
                                                        cardVolumes: cardVolumes) { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            // Superseded, forgotten or ejected: never store a partial result.
            guard coverageGenerations[key] == generation else { return }
            coverageTasks[key] = nil
            if let failure = result.failure {
                coverage[key] = .failed(failure)
            } else if Task.isCancelled || result.cancelled {
                coverage[key] = nil
            } else {
                coverage[key] = .done(ShootCoverage.compute(files: files, day: day, calendar: calendar, inShoot: result.verified))
            }
        }
        coverageTasks[key] = task
        return task
    }

    /// Selection the sheet starts with in add mode: only the shoot's own day.
    func shootSheetDefaults(shootID: UUID, cardID: Card.ID) -> ShootSelection {
        let card = cards.first { $0.id == cardID }
        let day = shoots.first { $0.id == shootID }?.date ?? .distantPast
        return ShootSelection(files: card?.files ?? [], cameras: card?.cameras ?? [], calendar: calendar, onlyDay: day)
    }

    private struct CoverageUnavailableError: LocalizedError {
        var errorDescription: String? { "Auto couldn't finish checking what this shoot already has. Try again in a moment." }
    }

    struct AllDuplicatesError: LocalizedError {
        var errorDescription: String? {
            "All selected files are already backed up. Turn on Copy duplicates anyway to copy them again."
        }
    }

    struct ShootBusyError: LocalizedError {
        var errorDescription: String? { "Another card is copying into this shoot. Try again when it finishes." }
    }

    struct SyncBusyError: LocalizedError {
        var errorDescription: String? { "Sync Now is running for this shoot. Try again when it finishes." }
    }

    /// Every shoot with all of its copy roots (primary plus mirrors).
    func shootRoots() -> [IngestDuplicates.ShootRoots] {
        shoots.map { item in
            // A mismatched copy is not this shoot; a same-volume one is not a separate copy. Neither is a place.
            let excluded = Set(item.copies.compactMap { state -> String? in
                switch state.availability {
                case .mismatch, .sameVolume: state.path
                default: nil
                }
            })
            return IngestDuplicates.ShootRoots(id: item.id, name: item.record.name,
                                               roots: item.record.copyPaths.filter { !excluded.contains($0) }
                                                   .map { URL(fileURLWithPath: $0) })
        }
    }

    /// Card files (or `candidates`, e.g. the current selection) that already have a verified copy somewhere
    /// other than `shootID`. Synchronous and cheap: reads the card's verdict, no I/O and no revalidation.
    /// The count is provisional until the (shoot, card) coverage is `.done`; once it is, files already
    /// verified inside the target shoot are excluded first, as `addFootage` does.
    func duplicates(shootID: UUID?, cardID: Card.ID, candidates: [MediaFile]? = nil) -> IngestDuplicates.Report {
        guard let card = cards.first(where: { $0.id == cardID }) else { return IngestDuplicates.Report() }
        var files = candidates ?? card.files
        if let shootID, case .done(let covered)? = coverage[CoverageKey(shootID: shootID, cardID: cardID)] {
            let notIn = Set(covered.notInShoot.map(\.url))
            files = files.filter { notIn.contains($0.url) }
        }
        return IngestDuplicates.find(candidates: files, backups: card.backups, missing: Set(card.missing.map(\.url)),
                                     shoots: shootRoots(), target: shootID)
    }

    /// Add-footage doesn't depend on the backup verdict: a backed-up card can still feed another shoot.
    private func canAddFootage(_ card: Card) -> Bool {
        switch card.phase {
        case .backed, .verifying, .needsBackup, .ready, .failed: card.engine == nil
        default: false
        }
    }

    /// Drops pending (not yet running) add-footage plans aimed at `shootID`.
    func discardAddPlans(forShoot shootID: UUID) {
        for (cardID, target) in addTargets where target == shootID {
            guard let card = cards.first(where: { $0.id == cardID }) else {
                addTargets[cardID] = nil
                includeDuplicatePlans.remove(cardID)
                continue
            }
            guard card.engine == nil else { continue }
            addTargets[cardID] = nil
            includeDuplicatePlans.remove(cardID)
            card.plan = nil
            dequeue(card)
            if card.phase == .ready { recompute(card) }
        }
    }

    /// Plans a copy of the selected files that are not yet verified inside the shoot into the shoot folder
    /// (Video/Photo/<camera>). Re-reads the sidecar and runs a fresh coverage check first, so it never
    /// plans from a stale snapshot. The user then starts it with `copy(_:)`.
    /// `onlyFiles`: when set, only these card files (by URL) are considered, on top of `selection`.
    func addFootage(shootID: UUID, cardID: Card.ID, cameras: [Camera], selection: ShootSelection,
                    onlyFiles: Set<URL>? = nil, includeDuplicates: Bool = false) async throws {
        guard let item = shoots.first(where: { $0.id == shootID }), let card = cards.first(where: { $0.id == cardID }) else {
            throw UnknownTargetError()
        }
        guard case .online(let shoot)? = item.availability else { throw ShootError.shootOffline }
        guard canAddFootage(card) else { throw PhaseError() }
        // A card with no plan at entry must still have none after every await (e.g. a Choose Folder plan).
        let planWasNil = card.plan == nil
        addInFlight.insert(cardID)
        defer {
            addInFlight.remove(cardID)
            if recomputeAfterAdd.remove(cardID) != nil, cards.contains(where: { $0 === card }), card.engine == nil { recompute(card) }
        }
        let folder = shoot.folder
        let sidecar = try await Task.detached { try ShootFolders.readSidecar(in: folder) }.value
        guard sidecar?.id == shootID else {
            await refreshShoots()
            throw ShootError.sidecarMismatch
        }
        // State may have changed while the sidecar was read.
        guard case .online(let again)? = shoots.first(where: { $0.id == shootID })?.availability, again.folder == folder else {
            throw ShootError.shootOffline
        }
        guard cards.contains(where: { $0 === card }), canAddFootage(card) else { throw PhaseError() }
        if planWasNil, card.plan != nil { throw PendingPlanError() }
        if isOnCard(folder) { throw CardDestinationError() }

        // Fresh coverage for exactly the files on the card right now.
        let key = CoverageKey(shootID: shootID, cardID: cardID)
        let snapshot = card.files
        let task = startCoverage(key: key, files: snapshot, folder: folder, day: item.date)
        await task.value
        guard case .done(let covered)? = coverage[key] else {
            if case .failed(let reason)? = coverage[key] { throw ShootCoverageError(reason: reason) }
            throw CoverageUnavailableError()
        }
        guard cards.contains(where: { $0 === card }), card.files == snapshot, canAddFootage(card),
              case .online(let latest)? = shoots.first(where: { $0.id == shootID })?.availability, latest.folder == folder else {
            throw CoverageUnavailableError()
        }
        if planWasNil, card.plan != nil { throw PendingPlanError() }

        var wanted = selection.filter(covered.notInShoot).filter { onlyFiles?.contains($0.url) ?? true }
        if !includeDuplicates, !wanted.isEmpty {
            let backups = card.backups
            let found = IngestDuplicates.find(candidates: wanted, backups: backups, missing: Set(card.missing.map(\.url)),
                                              shoots: shootRoots(), target: shootID)
            // Off main: a duplicate whose verified copy vanished or changed is a normal file again.
            let confirmed = await IngestDuplicates.revalidate(found, backups: backups, cache: verifications)
            guard cards.contains(where: { $0 === card }), card.files == snapshot, canAddFootage(card),
                  case .online(let latest2)? = shoots.first(where: { $0.id == shootID })?.availability, latest2.folder == folder else {
                throw CoverageUnavailableError()
            }
            if planWasNil, card.plan != nil { throw PendingPlanError() }
            let drop = Set(confirmed.files.map(\.url))
            if !drop.isEmpty {
                wanted.removeAll { drop.contains($0.url) }
                if wanted.isEmpty { throw AllDuplicatesError() }
            }
        }
        // Flat shoots: what is already on disk decides renames, listed off main before the state re-check below.
        var flatExisting: [URL: [String: Int64]] = [:]
        var flatRelated: [MediaFile] = []
        if item.record.layout == .flat {
            if case .online(let pre)? = shoots.first(where: { $0.id == shootID })?.availability {
                flatExisting = await ShootPlanner.existingNamesOffMain(in: ShootPlanner.flatDirectories(copies: pre.copies))
            }
            guard cards.contains(where: { $0 === card }), card.files == snapshot, canAddFootage(card) else {
                throw CoverageUnavailableError()
            }
            if planWasNil, card.plan != nil { throw PendingPlanError() }
            let wantedURLs = Set(wanted.map(\.url))
            flatRelated = selection.filter(snapshot).filter { !wantedURLs.contains($0.url) }
        }
        // Every online copy gets the files. No await from here to the plan, so the copies can't change underneath.
        guard case .online(let live)? = shoots.first(where: { $0.id == shootID })?.availability, live.folder == folder else {
            throw ShootError.shootOffline
        }
        let jobs = ShootPlanner.jobs(missing: wanted, copies: live.copies, cameras: cameras, fallback: card.name,
                                     layout: item.record.layout, existing: flatExisting, related: flatRelated)
        guard !jobs.isEmpty else { throw EmptySelectionError() }
        guard jobs.allSatisfy({ job in job.root.map { ShootPlanner.isInside(job.destDir, root: $0) } ?? false }) else {
            throw ShootPlanner.PathError.outsideWorkFolder
        }
        let cardVolumes = volumes(including: card)
        // The primary must be usable. A mirror that can't take its folders is left out; it is marked for sync after the copy.
        // Directories are created off main; state is re-checked after the await.
        let perRoot: [(root: URL, dirs: [URL])] = ([folder] + live.mirrors).map { root in
            (root, ShootPlanner.directories(for: jobs.filter { $0.root == root }))
        }
        let created: [(root: URL, error: Error?)] = await Task.detached {
            perRoot.map { entry in
                do { try ShootPlanner.createDirectories(entry.dirs, root: entry.root, cardVolumes: cardVolumes); return (entry.root, nil) }
                catch { return (entry.root, error) }
            }
        }.value
        if let primaryError = created.first?.error { throw primaryError }
        guard cards.contains(where: { $0 === card }), canAddFootage(card),
              case .online(let after)? = shoots.first(where: { $0.id == shootID })?.availability, after.folder == folder else {
            throw CoverageUnavailableError()
        }
        if planWasNil, card.plan != nil { throw PendingPlanError() }
        var roots = [folder]
        for entry in created.dropFirst() {
            if let error = entry.error {
                NSLog("Auto: skipping copy \(entry.root.path) for this ingest: \(error.localizedDescription)")
            } else if after.mirrors.contains(entry.root) {
                roots.append(entry.root)
            }
        }
        stopVerifier(card)
        dequeue(card)
        card.plan = ShootPlanner.plan(jobs: jobs.filter { job in roots.contains { $0 == job.root } }, shoot: folder, workRoot: folder,
                                      roots: roots, shootID: shootID)
        addTargets[cardID] = shootID
        if includeDuplicates { includeDuplicatePlans.insert(cardID) } else { includeDuplicatePlans.remove(cardID) }
        card.phase = .ready
        cardSettledAfterStop(card)
        shootSheet = nil
        shootSheetCard = nil
    }

    struct ShootCoverageError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Card browser: plans and starts a copy of exactly `urls` (minus anything already verified in the
    /// shoot) into the shoot, through the same checks as the Add Footage sheet.
    func addFiles(_ urls: Set<URL>, from cardID: Card.ID, toShoot shootID: UUID, includeDuplicates: Bool = false) async throws {
        guard let card = cards.first(where: { $0.id == cardID }) else { throw UnknownTargetError() }
        // Never replace a copy the user already has waiting on this card.
        guard card.plan == nil else { throw PendingPlanError() }
        let chosen = card.files.filter { urls.contains($0.url) }
        guard !chosen.isEmpty else { throw EmptySelectionError() }
        let selection = ShootSelection(missing: chosen, cameras: card.cameras, calendar: calendar)
        // addFootage closes the sheets for its own flow; an unrelated open sheet should survive this one.
        let sheet = shootSheet, sheetCard = shootSheetCard
        try await addFootage(shootID: shootID, cardID: cardID, cameras: card.cameras, selection: selection, onlyFiles: urls,
                                  includeDuplicates: includeDuplicates)
        shootSheet = sheet
        shootSheetCard = sheetCard
        copy(card)
    }

    private struct PendingPlanError: LocalizedError {
        var errorDescription: String? { "This card already has a copy waiting. Copy or discard it first." }
    }
}
