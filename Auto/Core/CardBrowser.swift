import Foundation

/// Groups a card's files for the read-only card browser: files with no verified copy first,
/// then one group per shoot that holds verified copies, then copies that live outside any shoot.
/// Pure: no I/O (path containment is lexical, like `ShootPlanner.isInside`), so it's safe to call from views.
nonisolated enum CardBrowser {
    enum GroupKind: Sendable, Hashable {
        case notBackedUp
        case shoot(UUID)
        case elsewhere
    }

    struct Group: Sendable, Identifiable, Hashable {
        let kind: GroupKind
        let title: String
        let files: [MediaFile]

        var id: GroupKind { kind }
        var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    struct ShootRef: Sendable, Hashable, Equatable {
        let id: UUID
        let name: String
        let folder: URL
    }

    /// `backups`: card file URL -> verified copy. `missing`: card files whose copy failed re-verification.
    /// A file with no copy, or in `missing`, is "Not Backed Up" and appears nowhere else.
    /// Otherwise it appears under every shoot whose `memberships` entry contains it (a checksum-verified
    /// result). A shoot with no entry yet falls back to where the `backups` copy lexically lives (the
    /// deepest shoot wins). Backed up but in no shoot: "Backed Up Elsewhere". Groups follow `shoots` order;
    /// empty groups are dropped; membership ids that match no shoot are ignored.
    static func group(files: [MediaFile], backups: [URL: URL], missing: Set<URL>,
                      shoots: [ShootRef], memberships: [UUID: Set<URL>]) -> [Group] {
        // Deepest folder first so nested shoots win over their parents.
        let ordered = shoots
            .map { (ref: $0, path: canonical($0.folder)) }
            .sorted { $0.path.count > $1.path.count }

        var notBacked: [MediaFile] = []
        var elsewhere: [MediaFile] = []
        var byShoot: [UUID: [MediaFile]] = [:]
        for file in files {
            guard let copy = backups[file.url], !missing.contains(file.url) else { notBacked.append(file); continue }
            var placed = false
            for ref in shoots where memberships[ref.id]?.contains(file.url) == true {
                byShoot[ref.id, default: []].append(file)
                placed = true
            }
            let path = canonical(copy)
            if let match = ordered.first(where: { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }),
               memberships[match.ref.id] == nil {
                byShoot[match.ref.id, default: []].append(file)
                placed = true
            }
            if !placed { elsewhere.append(file) }
        }

        var groups: [Group] = []
        if !notBacked.isEmpty { groups.append(Group(kind: .notBackedUp, title: "Not Backed Up", files: sorted(notBacked))) }
        for ref in shoots {
            guard let list = byShoot[ref.id], !list.isEmpty else { continue }
            groups.append(Group(kind: .shoot(ref.id), title: ref.name, files: sorted(list)))
        }
        if !elsewhere.isEmpty { groups.append(Group(kind: .elsewhere, title: "Backed Up Elsewhere", files: sorted(elsewhere))) }
        return groups
    }

    /// Every file once, in on-screen order: the first occurrence wins when a file is in several groups.
    static func uniqueFiles(_ groups: [Group]) -> [MediaFile] {
        var seen = Set<MediaFile.ID>()
        return groups.flatMap(\.files).filter { seen.insert($0.id).inserted }
    }

    private static func sorted(_ files: [MediaFile]) -> [MediaFile] {
        files.sorted { a, b in
            a.date != b.date ? a.date < b.date : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
