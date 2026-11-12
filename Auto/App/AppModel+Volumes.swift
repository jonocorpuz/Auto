import AppKit
import Foundation

extension AppModel {
    // MARK: Volumes

    func start() {
        watcher.onChange = { [weak self] cardURLs, driveVolumes, mountedNew in
            self?.volumesChanged(cards: cardURLs, drives: driveVolumes, mountedNew: mountedNew)
        }
        watcher.start()
        rebuildIndex()
        let metaURL = syncMetaURL
        startupLoad = Task {
            await checksums.load()
            let saved = await Task.detached { SyncMetaStore.load(from: metaURL) }.value
            for (id, date) in saved where lastDeepVerify[id] == nil { lastDeepVerify[id] = date }
        }
        Task { await loadShoots() }
    }

    private func volumesChanged(cards cardURLs: [URL], drives driveVolumes: [DriveVolume], mountedNew: Bool) {
        drives = driveVolumes

        // Match by identity, not URL: a fast swap to another card with the same volume name
        // drops the old Card (and its backed state) and scans the new one from scratch.
        let mounted = cardURLs.map { (url: $0, identity: VolumeIdentity.of($0)) }
        let ejected = cards.filter { card in !mounted.contains { $0.identity == card.identity } }
        removeCards(ejected)

        var addedCard = false
        for (url, identity) in mounted where !cards.contains(where: { $0.identity == identity }) {
            let card = Card(volume: url, name: Self.volumeName(url), identity: identity)
            cards.append(card)
            scan(card)
            addedCard = true
        }
        if addedCard && mountedNew && autoOpen { openMainWindow() }

        // The work drive was plugged in, unplugged or swapped: the index is stale.
        if workingVolume.map(VolumeIdentity.of) != indexedVolumeID { rebuildIndex() }
        Task { await refreshShoots() }
    }

    /// Stops everything running for cards that are no longer mounted and drops them from the UI.
    private func removeCards(_ ejected: [Card]) {
        for card in ejected {
            card.engine?.cancel()
            card.verifier?.cancel()
            cancelCoverage { $0.cardID == card.id }
            forgetPendingPlan(of: card)
            recomputePending.remove(card.id)
        }

        if let sheetCard = shootSheetCard, ejected.contains(where: { $0 === sheetCard }) {
            shootSheetCard = nil
            if shootSheet == .create { shootSheet = nil }
        }
        if case .add(_, let cardID?) = shootSheet, ejected.contains(where: { $0.id == cardID }) {
            shootSheet = nil
        }

        cards.removeAll { card in ejected.contains { $0 === card } }
        if let browsedID = browsingCardID, !cards.contains(where: { $0.id == browsedID }) {
            browsingCardID = nil
        }
    }

    /// Clears the bookkeeping that belongs to a card's pending copy plan (not the plan itself).
    private func forgetPendingPlan(of card: Card) {
        addTargets[card.id] = nil
        includeDuplicatePlans.remove(card.id)
        dequeue(card)
    }

    // MARK: Scanning

    private func scan(_ card: Card) {
        card.phase = .scanning
        card.mirrorNote = nil
        card.backups = [:]
        // The file list is about to change: any coverage computed from it is stale.
        cancelCoverage { $0.cardID == card.id }
        invalidateBrowserMembership(for: card)
        Task {
            let result = await CardScanner.scan(card.volume, volumeName: card.name)
            card.files = result.files
            card.cameras = result.cameras
            card.shootDate = result.shootDate
            card.shootDays = ShootDays.byCamera(result.files, calendar: calendar)
            card.scanError = result.error
            recompute(card)
        }
    }

    /// Scan the card again (e.g. after an unreadable result).
    func rescan(_ card: Card) {
        guard card.engine == nil else { return }
        card.verifier?.cancel()
        card.verifier = nil
        card.plan = nil
        forgetPendingPlan(of: card)
        scan(card)
    }

    func rebuildIndex() {
        indexGeneration += 1
        let generation = indexGeneration
        indexedVolumeID = workingVolume.map(VolumeIdentity.of)
        guard let volume = workingVolume else {
            index = [:]
            indexing = false
            cards.forEach { recompute($0) }
            return
        }
        indexing = true
        Task {
            let built = await DriveIndex.build(volume)
            guard generation == indexGeneration else { return }
            index = built
            indexing = false
            cards.forEach { recompute($0) }
        }
    }

    /// A card is backed up only when every file is checksum-verified against a copy on the work drive.
    /// Name+size hits are just candidates; `BackupVerifier` hashes them off the main actor.
    func recompute(_ card: Card) {
        if card.phase == .copying { return }
        stopVerifier(card)
        invalidateBrowserMembership(for: card)

        // No media, or a scan error: never verify, never backed.
        if let phase = CardPhase.afterScan(fileCount: card.files.count, error: card.scanError) {
            card.missing = card.files
            card.backups = [:]
            card.plan = nil
            dequeue(card)
            card.phase = phase
            refreshBrowserMembership()
            return
        }

        let driveReady = workingVolume != nil
        // Session copy destinations count wherever they are (work drive or a chosen folder),
        // but only through the cache entry for that exact card file, or a fresh checksum.
        let candidates = BackupVerifier.addingCandidates(sessionCopies, to: driveReady ? index : [:])
        let generation = card.recomputeGeneration
        let shootFolders = onlineShootFolders()
        backupShootFolders = Set(shootFolders.map(\.path))
        let cardVolumes = cards.map(\.volume)
        let workVolume = driveReady ? workingVolume : nil
        recomputePending.insert(card.id)
        // Never leave a stale green up while re-checking (in the header or the card browser).
        if card.phase == .backed {
            card.phase = .scanning
            card.backups = [:]
        }
        Task {
            // Any registered, online shoot counts as a backup location ("any shoot counts"). Built off
            // main; card files never count as candidates for themselves.
            let candidates = await Self.backupCandidates(base: candidates, shootFolders: shootFolders,
                                                         cardVolumes: cardVolumes, workVolume: workVolume)
            // Triage stats every candidate on disk, so it runs off the main actor.
            let triage = await BackupVerifier.triageOffMain(files: card.files, candidates: candidates, cache: verifications)
            // Superseded by a copy, a new plan, a rescan or a newer recompute.
            guard card.recomputeGeneration == generation else { return }
            recomputePending.remove(card.id)
            guard card.engine == nil, card.phase != .copying else { return }
            settle(card, triage: triage, candidates: candidates, driveReady: driveReady)
        }
    }

    /// Applies a triage result: settles the card straight away when nothing needs hashing, otherwise
    /// starts a `BackupVerifier` for the files that do.
    private func settle(_ card: Card, triage: (settled: [URL: VerifyResult], toVerify: [MediaFile]),
                        candidates: [String: [URL]], driveReady: Bool) {
        let allVerified = triage.toVerify.isEmpty && card.files.allSatisfy { triage.settled[$0.url]?.isVerified == true }
        // The index is still being built, so a missing copy may simply not be indexed yet.
        if indexing && driveReady && !allVerified {
            card.phase = .scanning
            card.backups = [:]
            return
        }

        if triage.toVerify.isEmpty {
            finishRecompute(card, results: triage.settled)
            return
        }
        if case .failed = card.phase {
            // Keep the failure on screen; unverified files simply stay on the to-copy list.
            finishRecompute(card, results: triage.settled)
            return
        }

        let verifier = BackupVerifier()
        card.verifier = verifier
        let bytesToVerify = triage.toVerify.reduce(0) { $0 + $1.size }
        card.verifyProgress = CopyProgress(filesTotal: triage.toVerify.count, bytesTotal: bytesToVerify)
        card.phase = .verifying
        Task {
            let outcome = await verifier.run(triage.toVerify, candidates: candidates, cache: verifications) { progress in
                card.verifyProgress = progress
            }
            // Superseded by a newer recompute, a copy/plan that took over, or the card went away.
            guard !outcome.cancelled, card.verifier === verifier else { return }
            card.verifier = nil
            guard card.phase == .verifying else { return }
            finishRecompute(card, results: triage.settled.merging(outcome.results) { $1 })
        }
    }

    /// Folders of every online copy of every registered shoot, mirrors included (no I/O). A card file
    /// verified only in a mirror counts as backed up.
    func onlineShootFolders() -> [URL] {
        shoots.flatMap { item -> [URL] in
            guard case .online(let shoot)? = item.availability else { return [] }
            return shoot.copies.map(\.standardizedFileURL)
        }
    }

    /// Merges the work-drive candidates with an index of each online shoot folder, deduplicated by path.
    /// Skips shoot folders on the work volume (already indexed, compared by volume identity), on a card,
    /// or containing a card; drops any candidate that lives on a card.
    @concurrent private static func backupCandidates(base: [String: [URL]], shootFolders: [URL],
                                                     cardVolumes: [URL], workVolume: URL?) async -> [String: [URL]] {
        func volumeIdentifier(of url: URL) -> (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
            try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        let workVolumeID = workVolume.flatMap(volumeIdentifier(of:))

        var merged: [String: [URL]] = [:]
        var seenPaths = Set<String>()
        func add(_ candidatesByKey: [String: [URL]]) {
            for (key, urls) in candidatesByKey {
                for url in urls {
                    if VolumeClassifier.isInside(url, anyOf: cardVolumes) { continue }
                    let isNewPath = seenPaths.insert(url.standardizedFileURL.path).inserted
                    if isNewPath { merged[key, default: []].append(url) }
                }
            }
        }

        add(base)
        for folder in shootFolders {
            let containsCard = cardVolumes.contains { VolumeClassifier.isInside($0, anyOf: [folder]) }
            if containsCard { continue }
            if VolumeClassifier.isOnCard(folder, cards: cardVolumes) { continue }
            if let workVolumeID, let folderVolumeID = volumeIdentifier(of: folder), workVolumeID.isEqual(folderVolumeID) {
                continue
            }
            add(await DriveIndex.build(folder))
        }
        return merged
    }

    /// Cancels any verify, and any triage still in flight, for this card.
    func stopVerifier(_ card: Card) {
        card.verifier?.cancel()
        card.verifier = nil
        card.recomputeGeneration += 1
        recomputePending.remove(card.id)
    }

    /// Every path that stops the verifier (and its triage) and then settles the card itself, instead of
    /// letting `finishRecompute` run, must end here so the browser's membership leaves `.checking`.
    func cardSettledAfterStop(_ card: Card) {
        if card.id == browsingCardID { refreshBrowserMembership() }
    }

    func finishRecompute(_ card: Card, results: [URL: VerifyResult]) {
        // Every exit: the card may have settled. A plain refresh restarts the run only when its inputs
        // (files, verdict, session copies, shoots) changed or the run was stopped.
        // A queued card was re-verified because the copy it waited for finished: start it now (it re-queues
        // if another copy is still in the way), so the twins that just landed are pruned from its plan.
        defer {
            if card.id == browsingCardID { refreshBrowserMembership() }
            if card.queuedBehind != nil, card.engine == nil, !addInFlight.contains(card.id) { copy(card) }
        }
        card.missing = BackupVerifier.missing(files: card.files, results: results)
        card.backups = results.compactMapValues { result in
            if case .verified(let copy) = result { copy } else { nil }
        }
        guard let phase = CardPhase.afterVerify(fileCount: card.files.count, missingCount: card.missing.count,
                                                hasPlan: card.plan != nil, current: card.phase) else { return }
        // A pending plan (add-footage or a chosen folder) survives a backed verdict; its jobs are
        // pruned against the verdict when the copy starts.
        if phase == .backed, card.plan != nil {
            card.phase = .ready
            return
        }
        card.phase = phase
    }

    #if DEBUG
    func _testVolumesChanged(cards urls: [URL]) { volumesChanged(cards: urls, drives: [], mountedNew: false) }
    func _testInsert(card: Card) { cards.append(card) }
    #endif
}
