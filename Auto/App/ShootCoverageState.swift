import Foundation

/// Identifies one shoot-versus-card coverage check.
struct CoverageKey: Hashable, Sendable {
    let shootID: UUID
    let cardID: String
}

/// Result of checking how much of a card is already verified inside a shoot folder.
enum CoverageState: Equatable {
    case checking(CopyProgress)
    case done(ShootCoverage)
    case failed(String)
}

/// Per-shoot result of the card browser's membership check for the browsed card.
/// `done` only ever carries a complete, checksum-verified result.
enum BrowserMembershipState: Equatable {
    case checking
    case done(Set<URL>, copies: [URL: URL])
    case failed(String)
}
