import Foundation

/// Card browser membership: which shoots hold a verified copy of the browsed card's files.
/// Read-only hashing that only runs while that card's browser is on screen.
extension AppModel {
    /// Everything a membership check depends on; an unchanged value means the last run is still valid.
    struct MembershipInputs: Equatable {
        let cardID: Card.ID
        let files: [MediaFile]
        let targets: [ShootMembership.Target]
        let backups: [URL: URL]
        let missing: Set<URL>
        let sessionCopies: [URL]
    }

    /// The browser for `cardID` is on screen.
    func browserAppeared(_ cardID: Card.ID) {
        browserOnScreen = cardID
        refreshBrowserMembership()
    }

    /// Clears only when `cardID` is still the one on screen (a swapped-in browser may have appeared first).
    func browserDisappeared(_ cardID: Card.ID) {
        guard browserOnScreen == cardID else { return }
        browserOnScreen = nil
        refreshBrowserMembership()
    }

    private func onlineMembershipTargets() -> [ShootMembership.Target] {
        shoots.compactMap { item in
            guard case .online(let shoot)? = item.availability else { return nil }
            return ShootMembership.Target(id: item.id, folder: shoot.folder.standardizedFileURL)
        }
    }

    private func stopMembership() {
        membershipTask?.cancel()
        membershipTask = nil
        membershipGeneration += 1
        membershipInputs = nil
    }

    private func clearMembership() {
        stopMembership()
        if !browserMembership.isEmpty { browserMembership = [:] }
    }

    private func markMembershipChecking(_ targets: [ShootMembership.Target]) {
        var checking: [UUID: BrowserMembershipState] = [:]
        for target in targets { checking[target.id] = .checking }
        browserMembership = checking
    }

    /// Whether the card's backup verdict is final, so membership can be computed from it.
    private func hasSettledVerdict(_ card: Card) -> Bool {
        switch card.phase {
        case .needsBackup, .ready, .backed, .failed:
            card.engine == nil && card.verifier == nil && !recomputePending.contains(card.id)
        default:
            false
        }
    }

    private func membershipFinished(for targets: [ShootMembership.Target]) -> Bool {
        targets.allSatisfy { target in
            switch browserMembership[target.id] {
            case .done?, .failed?: true
            default: false
            }
        }
    }

    /// The card is about to change under the browser: drop the running check and show "checking".
    func invalidateBrowserMembership(for card: Card) {
        guard mainWindowVisible, card.id == browsingCardID, browserOnScreen == card.id else { return }
        stopMembership()
        markMembershipChecking(onlineMembershipTargets())
    }

    /// Starts, restarts or clears the browser's per-shoot membership check for the browsed card.
    /// Read-only; results are stored only when complete and still current.
    func refreshBrowserMembership(force: Bool = false) {
        guard mainWindowVisible, let card = browsingCard, browserOnScreen == card.id else {
            clearMembership()
            return
        }
        switch card.phase {
        case .empty, .unreadable:
            clearMembership()
            return
        default:
            break
        }

        let targets = onlineMembershipTargets()
        guard hasSettledVerdict(card) else {
            stopMembership()
            markMembershipChecking(targets)
            return
        }

        let inputs = MembershipInputs(cardID: card.id, files: card.files, targets: targets, backups: card.backups,
                                      missing: Set(card.missing.map(\.url)), sessionCopies: sessionCopies.map(\.destination))
        if !force, membershipInputs == inputs {
            // Same inputs: the run in flight, or the results already stored, are still right.
            let isRunning = membershipTask != nil
            if isRunning || membershipFinished(for: targets) { return }
        }

        membershipTask?.cancel()
        membershipGeneration += 1
        membershipInputs = inputs
        markMembershipChecking(targets)
        guard !targets.isEmpty else {
            membershipTask = nil
            return
        }
        membershipTask = startMembershipRun(card: card, targets: targets, generation: membershipGeneration)
    }

    private func startMembershipRun(card: Card, targets: [ShootMembership.Target], generation: Int) -> Task<Void, Never> {
        let cardID = card.id
        let files = card.files
        let copies = sessionCopies
        let cache = verifications
        let volumes = cardVolumes()
        #if DEBUG
        let testRunner = _testMembershipRunner
        #endif
        return Task {
            let deliver: @MainActor @Sendable (UUID, ShootMembership.Outcome) -> Void = { [self] id, outcome in
                deliverMembership(id, outcome, generation: generation, cardID: cardID)
            }
            #if DEBUG
            if let testRunner {
                await testRunner(files, targets, deliver)
                if generation == membershipGeneration { membershipTask = nil }
                return
            }
            #endif
            await ShootMembership.run(files: files, targets: targets, sessionCopies: copies, cache: cache,
                                      cardVolumes: volumes, onResult: deliver)
            if generation == membershipGeneration { membershipTask = nil }
        }
    }

    /// Superseded, or the user moved to another card: never store a stale result.
    private func deliverMembership(_ id: UUID, _ outcome: ShootMembership.Outcome, generation: Int, cardID: Card.ID) {
        guard generation == membershipGeneration, browsingCardID == cardID else { return }
        switch outcome {
        case .verified(let urls, let copies): browserMembership[id] = .done(urls, copies: copies)
        case .failed(let reason): browserMembership[id] = .failed(reason)
        }
    }

    // MARK: Test seams

    #if DEBUG
    /// Test seam: replaces `ShootMembership.run`, so a test can deliver a result after supersession.
    typealias MembershipRunner = @Sendable ([MediaFile], [ShootMembership.Target],
                                            @escaping @MainActor @Sendable (UUID, ShootMembership.Outcome) -> Void) async -> Void
    func _testSetMembershipRunner(_ runner: MembershipRunner?) { _testMembershipRunner = runner }
    func _testBrowserMembershipIdle() async { await membershipTask?.value }
    #endif
}
