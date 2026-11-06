import Foundation
import Observation

/// What the Add Files sheet binds to: the scanned files, duplicate verdicts and the user's removals.
@Observable
final class ImportStaging: Identifiable {
    enum Phase: Equatable {
        case scanning(Int)
        case checking
        case ready
        case failed(String)
    }

    struct Group: Identifiable, Equatable {
        let kind: MediaKind
        let folder: String
        let count: Int
        let bytes: Int64
        let urls: [URL]
        var id: String { "\(kind)|\(folder)" }
    }

    let id = UUID()
    let shootID: UUID
    let target: DropTarget
    var sources: [URL]
    var phase: Phase = .scanning(0)
    var items: [StagedFile] = []
    /// Cameras after mapping onto the shoot's existing folders.
    var cameras: [Camera] = []
    var duplicates: Set<URL> = []
    var removed: Set<URL> = []
    var includeDuplicates: Set<URL> = []
    var refused: [(URL, ImportRefusal)] = []
    var ignoredCount = 0
    /// Set when the duplicate check couldn't run: nothing is skipped, and the user is told.
    var warning: String?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var generation = 0

    init(shootID: UUID, target: DropTarget, sources: [URL]) {
        self.shootID = shootID
        self.target = target
        self.sources = sources
    }

    /// Items grouped by kind, then destination camera folder.
    var groups: [Group] {
        let live = items.filter { !removed.contains($0.id) }
        let byKey = Dictionary(grouping: live) { "\($0.file.kind)|\($0.cameraFolder)" }
        return byKey.values.map { staged in
            Group(kind: staged[0].file.kind, folder: staged[0].cameraFolder, count: staged.count,
                  bytes: staged.reduce(0) { $0 + $1.file.size }, urls: staged.map(\.id).sorted { $0.path < $1.path })
        }.sorted { ($0.kind.order, $0.folder) < ($1.kind.order, $1.folder) }
    }

    /// Items minus removals minus duplicates the user hasn't re-included.
    var selected: [StagedFile] {
        items.filter { item in
            !removed.contains(item.id) && (!duplicates.contains(item.id) || includeDuplicates.contains(item.id))
        }
    }

    var skippedDuplicateCount: Int {
        items.filter { !removed.contains($0.id) && duplicates.contains($0.id) && !includeDuplicates.contains($0.id) }.count
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}

private extension MediaKind {
    var order: Int {
        switch self {
        case .video: 0
        case .photo: 1
        case .audio: 2
        }
    }
}
