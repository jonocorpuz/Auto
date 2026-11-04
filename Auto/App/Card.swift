import Foundation
import Observation

/// One connected camera card and its backup state.
@Observable
final class Card: Identifiable {
    typealias Phase = CardPhase

    let volume: URL
    let name: String
    /// Volume UUID + path (path alone for fixture folders). A different card mounted at the
    /// same path gets a different identity, so it never inherits this card's state.
    let identity: String
    var id: String { identity }

    var phase: Phase = .scanning
    var files: [MediaFile] = []
    var missing: [MediaFile] = []
    var cameras: [Camera] = []
    var shootDate: Date?
    /// Set when the last scan hit a read error (see `CardScanner.Result.error`).
    var scanError: String?
    var plan: CopyPlan?
    var progress = CopyProgress()
    var verifyProgress = CopyProgress()
    var backedTo: String?
    var ejecting = false
    var ejectError: String?
    @ObservationIgnored var engine: CopyEngine?
    @ObservationIgnored var verifier: BackupVerifier?
    /// Bumped whenever pending verify work for this card is superseded.
    @ObservationIgnored var recomputeGeneration = 0

    init(volume: URL, name: String, identity: String? = nil) {
        self.volume = volume
        self.name = name
        self.identity = identity ?? VolumeIdentity.of(volume)
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.size } }
    var videoCount: Int { files.filter { $0.kind != .photo }.count }
    var photoCount: Int { files.filter { $0.kind == .photo }.count }
}
