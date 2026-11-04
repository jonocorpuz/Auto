import Foundation
import Observation

/// One connected camera card and its backup state.
@Observable
final class Card: Identifiable {
    typealias Phase = CardPhase

    let volume: URL
    let name: String
    var id: URL { volume }

    var phase: Phase = .scanning
    var files: [MediaFile] = []
    var missing: [MediaFile] = []
    var cameras: [Camera] = []
    var shootDate: Date?
    var plan: CopyPlan?
    var progress = CopyProgress()
    var backedTo: String?
    var ejecting = false
    @ObservationIgnored var engine: CopyEngine?

    init(volume: URL, name: String) {
        self.volume = volume
        self.name = name
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.size } }
    var videoCount: Int { files.filter { $0.kind != .photo }.count }
    var photoCount: Int { files.filter { $0.kind == .photo }.count }
}
