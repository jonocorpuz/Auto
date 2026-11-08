import Foundation

/// A rejected photo shown live in the cull UI, with a short tag and its full reason.
nonisolated struct CullLiveReject: Sendable, Identifiable, Equatable {
    let id: String            // photoID
    let label: String         // short tag
    let reason: String        // full reason, shown as tooltip
    let thumbnailJPEG: Data?
}

/// Maps a reject decision to a short UI tag.
nonisolated enum CullRejectLabel {
    static func label(for d: CullDecision) -> String {
        let reason = d.reason.lowercased()
        guard let criterion = d.criterion else {
            return d.keeperID != nil ? "Duplicate" : "Rejected"
        }
        switch criterion {
        case "eyes":
            return reason.contains("expression") ? "Bad expression" : "Closed eyes"
        case "exposure":
            return "Exposure"
        case "unusable", "technical":
            return (reason.contains("blur") || reason.contains("focus")) ? "Blurry" : "Unusable"
        case "horizon":
            return "Crooked"
        case "cropped":
            return "Cropped"
        case "duplicates":
            return "Duplicate"
        case "weak":
            return "Weak shot"
        case "select":
            return "Not a select"
        case "crew":
            return "Behind the scenes"
        default:
            return d.keeperID != nil ? "Duplicate" : "Rejected"
        }
    }
}
