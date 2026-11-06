import Foundation
import Observation

enum ImportPhase: Equatable {
    case queued(String)
    case preparing
    case copying
    case done(ImportSummary)
    case failed(String)
    case stopped
}

struct ImportSummary: Equatable {
    let copied: Int
    let bytes: Int64
    let skippedDuplicates: Int
    /// E.g. a mirror that wasn't updated; nil when every copy got everything.
    let note: String?
}

/// One Add Files run into a shoot. A sibling of `Card` in scheduling (see `AppModel+Import`).
@Observable
final class ImportJob: Identifiable {
    let id = UUID()
    let shootID: UUID
    let shootName: String
    var files: [MediaFile]
    var plan: CopyPlan
    var phase: ImportPhase
    var progress = CopyProgress()
    let skippedDuplicates: Int
    @ObservationIgnored var engine: CopyEngine?
    /// The run's task (tests await it).
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var stopRequested = false

    init(shootID: UUID, shootName: String, files: [MediaFile], plan: CopyPlan, skippedDuplicates: Int,
         phase: ImportPhase = .queued("Starting")) {
        self.shootID = shootID
        self.shootName = shootName
        self.files = files
        self.plan = plan
        self.skippedDuplicates = skippedDuplicates
        self.phase = phase
    }

    /// Waiting for, preparing or running a copy: the shoot's copies can't be removed meanwhile.
    var isActive: Bool {
        switch phase {
        case .queued, .preparing, .copying: true
        case .done, .failed, .stopped: false
        }
    }

    var isFinished: Bool { !isActive }
}
