import CoreGraphics
import Foundation

/// One shoot as the Shoots grid shows it: the remembered record plus what was found on disk.
struct ShootItem: Identifiable {
    var record: ShootRecord
    /// Recording day (local start of day); distant past if the record's day can't be parsed.
    var date: Date
    /// nil until resolved.
    var availability: ShootAvailability?
    /// Per-copy state from the last resolve; empty until resolved.
    var copies: [ShootCopyState] = []
    var summary: ShootSummary?
    var thumbnail: CGImage?

    var id: UUID { record.id }
}

/// What the New Shoot sheet is asked to do.
enum ShootSheetRequest: Identifiable, Equatable {
    case create
    case add(shootID: UUID, cardID: Card.ID?)
    case addFiles(ImportStaging)

    static func == (lhs: ShootSheetRequest, rhs: ShootSheetRequest) -> Bool { lhs.id == rhs.id }

    var id: String {
        switch self {
        case .create: "create"
        case .add(let shootID, _): "add-\(shootID.uuidString)"
        case .addFiles(let staging): "files-\(staging.id.uuidString)"
        }
    }
}
