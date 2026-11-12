import Foundation

nonisolated enum CardPhase: Equatable, Sendable {
    case scanning, verifying, needsBackup, ready, copying, backed, failed(String)
    /// Scanned fine but no recognized media. Never backed: there may be files Auto doesn't know.
    case empty
    /// The card (or part of it) couldn't be read, so Auto can't say what's on it.
    case unreadable(String)

    /// Phase straight after a scan when verification can't apply: a scan error wins over
    /// an empty result, and neither ever becomes `.backed`. nil means go on and verify.
    static func afterScan(fileCount: Int, error: String?) -> CardPhase? {
        if let error { return .unreadable(error) }
        if fileCount == 0 { return .empty }
        return nil
    }

    /// Phase after verification of a card's files. nil keeps `current` (a `.failed` card stays failed).
    /// Never `.backed` while anything is missing, so a partial shoot stays "needs backup".
    static func afterVerify(fileCount: Int, missingCount: Int, hasPlan: Bool, current: CardPhase) -> CardPhase? {
        let everythingIsVerified = missingCount == 0 && fileCount > 0
        if everythingIsVerified { return .backed }
        if hasPlan { return .ready }
        if case .failed = current { return nil }
        return .needsBackup
    }
}

/// Aggregate status across cards.
nonisolated enum StatusAggregator {
    enum Result: Equatable, Sendable { case idle, unbacked, copying, backed, error }

    /// Priority: copying > error > unbacked > (anything still verifying, or empty: idle) > backed > idle.
    /// An unreadable card is an error; an empty card is neutral but never lets the total go green.
    /// A failed card is reported as `error` because the user has to act on it; it still means unbacked data,
    /// which `error` outranks so the failure isn't masked by another card needing backup.
    static func aggregate(_ phases: [CardPhase]) -> Result {
        if phases.contains(.copying) { return .copying }

        let anyCardHasAnError = phases.contains { phase in
            switch phase {
            case .failed, .unreadable: true
            default: false
            }
        }
        if anyCardHasAnError { return .error }

        let anyCardNeedsBackup = phases.contains { $0 == .needsBackup || $0 == .ready }
        if anyCardNeedsBackup { return .unbacked }

        // Never show green while a card's files are still being checksum-checked.
        if phases.contains(.verifying) || phases.contains(.empty) { return .idle }
        if phases.contains(.backed) { return .backed }
        return .idle
    }
}
