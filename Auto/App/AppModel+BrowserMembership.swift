import AppKit
import Foundation

extension AppModel {
    // MARK: Browser membership

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
            if case .online(let shoot)? = item.availability {
                return ShootMembership.Target(id: item.id, folder: shoot.folder.standardizedFileURL)
            }
            return nil
        }
    }

    private func stopMembership() {
        membershipTask?.cancel()
        membershipTask = nil
        membershipGeneration += 1
        membershipInputs = nil
    }

    private func markMembershipChecking(_ targets: [ShootMembership.Target]) {
        browserMembership = Dictionary(targets.map { ($0.id, BrowserMembershipState.checking) }) { $1 }
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
            stopMembership()
            if !browserMembership.isEmpty { browserMembership = [:] }
            return
        }
        switch card.phase {
        case .empty, .unreadable:
            stopMembership()
            if !browserMembership.isEmpty { browserMembership = [:] }
            return
        default: break
        }
        let targets = onlineMembershipTargets()
        let settled: Bool
        switch card.phase {
        case .needsBackup, .ready, .backed, .failed:
            settled = card.engine == nil && card.verifier == nil && !recomputePending.contains(card.id)
        default: settled = false
        }
        guard settled else {
            stopMembership()
            markMembershipChecking(targets)
            return
        }
        let inputs = MembershipInputs(cardID: card.id, files: card.files, targets: targets, backups: card.backups,
                                      missing: Set(card.missing.map(\.url)), sessionCopies: sessionCopies.map(\.destination))
        if !force, membershipInputs == inputs {
            let finished = targets.allSatisfy { target in
                switch browserMembership[target.id] {
                case .done?, .failed?: true
                default: false
                }
            }
            if membershipTask != nil || finished { return }
        }

        membershipTask?.cancel()
        membershipGeneration += 1
        let generation = membershipGeneration
        membershipInputs = inputs
        markMembershipChecking(targets)
        guard !targets.isEmpty else { membershipTask = nil; return }
        let cardID = card.id
        let files = card.files
        let copies = sessionCopies
        let cache = verifications
        let volumes = cardVolumes()
        #if DEBUG
        let runner = _testMembershipRunner
        #endif
        membershipTask = Task {
            #if DEBUG
            if let runner {
                await runner(files, targets) { [self] id, outcome in deliverMembership(id, outcome, generation: generation, cardID: cardID) }
                if generation == membershipGeneration { membershipTask = nil }
                return
            }
            #endif
            await ShootMembership.run(files: files, targets: targets, sessionCopies: copies, cache: cache,
                                      cardVolumes: volumes) { [self] id, outcome in
                deliverMembership(id, outcome, generation: generation, cardID: cardID)
            }
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

    #if DEBUG
    /// Test seam: replaces `ShootMembership.run`, so a test can deliver a result after supersession.
    typealias MembershipRunner = @Sendable ([MediaFile], [ShootMembership.Target],
                                            @escaping @MainActor @Sendable (UUID, ShootMembership.Outcome) -> Void) async -> Void
    func _testSetMembershipRunner(_ runner: MembershipRunner?) { _testMembershipRunner = runner }
    func _testBrowserMembershipIdle() async { await membershipTask?.value }
    #endif
}
