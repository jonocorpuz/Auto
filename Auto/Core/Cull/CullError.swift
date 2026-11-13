import Foundation

nonisolated enum CullError: LocalizedError, Equatable {
    case shootOffline
    case noCopiesOnline
    case onCard
    case outsideShoot(String)
    case noPhotos
    case claudeNotInstalled
    case claudeNotLoggedIn
    case claudeFailed(String)
    case budgetExceeded(Double)
    case journalWriteFailed(String)
    case nothingToUndo
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .shootOffline:
            return "This shoot's drive is offline. Connect it and try again."
        case .noCopiesOnline:
            return "None of this shoot's copies are online."
        case .onCard:
            return "That folder is on a memory card. Culls only change copies on your drives."
        case .outsideShoot(let path):
            return "\(path) is outside the shoot folder."
        case .noPhotos:
            return "There are no photos to cull in this shoot."
        case .claudeNotInstalled:
            return "The Claude Code CLI isn't installed. Install it, then try again."
        case .claudeNotLoggedIn:
            return "Claude Code isn't logged in. Run `claude` in Terminal and log in, then try again."
        case .claudeFailed(let message):
            return "Claude failed: \(message)"
        case .budgetExceeded(let amount):
            return String(format: "The cull reached its $%.2f budget. Nothing was moved.", amount)
        case .journalWriteFailed(let message):
            return "Couldn't write the cull journal: \(message)"
        case .nothingToUndo:
            return "There's no cull to undo."
        case .rollbackFailed(let paths):
            return "Some photos couldn't be put back (\(paths)). Undo the cull to restore them."
        }
    }
}
