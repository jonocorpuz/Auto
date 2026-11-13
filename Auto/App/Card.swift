import Foundation
import Observation

/// One connected camera card and its backup state.
@Observable
final class Card: Identifiable {
    let volume: URL
    let name: String
    /// Volume UUID + path (path alone for fixture folders). A different card mounted at the
    /// same path gets a different identity, so it never inherits this card's state.
    let identity: String
    var id: String { identity }

    var phase: CardPhase = .scanning
    var files: [MediaFile] = []
    var missing: [MediaFile] = []
    /// Card file URL -> its verified copy, from the last backup check.
    var backups: [URL: URL] = [:]
    var cameras: [Camera] = []
    var shootDate: Date?
    var shootDays: [String: [ShootDay]] = [:]
    /// Set when the last scan hit a read error (see `CardScanner.Result.error`).
    var scanError: String?
    var plan: CopyPlan?
    var progress = CopyProgress()
    var verifyProgress = CopyProgress()
    var backedTo: String?
    /// Set after a copy that didn't reach every copy of the shoot; cleared on the next copy or rescan.
    var mirrorNote: String?
    /// The card whose copy this one waits for (both write into the same folder); nil when not queued.
    /// A queued card keeps its `.ready` phase and starts by itself when the other copy finishes.
    var queuedBehind: Card.ID?
    var queueNote: String?
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
