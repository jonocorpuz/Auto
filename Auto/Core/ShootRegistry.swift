import Foundation

/// One remembered shoot. The sidecar in the folder stays the source of truth; this is an index.
nonisolated struct ShootRecord: Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    /// "yyyy-MM-dd", calendar-local.
    var day: String
    var path: String
    var lastSeen: Date
}

/// The list of known shoots, persisted in Application Support.
nonisolated struct ShootRegistry: Codable, Sendable, Equatable {
    var version = 1
    var records: [ShootRecord] = []

    private static func key(_ path: String) -> String {
        VolumeClassifier.normalizedPath(URL(fileURLWithPath: path))
    }

    /// Same id replaces; otherwise same standardized path replaces; otherwise appends.
    mutating func add(_ r: ShootRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) {
            records[i] = r
        } else if let i = records.firstIndex(where: { Self.key($0.path) == Self.key(r.path) }) {
            records[i] = r
        } else {
            records.append(r)
        }
    }

    mutating func remove(id: UUID) {
        records.removeAll { $0.id == id }
    }

    mutating func relocate(id: UUID, to path: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].path = path
    }

    /// Adds unseen ids. Known ids keep their record and only get `lastSeen` refreshed.
    mutating func merge(discovered: [ShootRecord]) {
        for d in discovered {
            if let i = records.firstIndex(where: { $0.id == d.id }) {
                records[i].lastSeen = max(records[i].lastSeen, d.lastSeen)
            } else {
                records.append(d)
            }
        }
    }
}

nonisolated enum ShootAvailability: Sendable, Equatable {
    case online(Shoot)
    /// The path's volume (/Volumes/<name>) isn't mounted.
    case offline
    /// Volume mounted but the folder or sidecar is gone (or it sits on a card).
    case missing
    /// The sidecar's id differs from the record.
    case mismatch
}

nonisolated enum ShootStore {
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Auto", isDirectory: true).appendingPathComponent("shoots.json")
    }

    @concurrent static func load(from url: URL) async -> ShootRegistry {
        guard let data = try? Data(contentsOf: url) else { return ShootRegistry() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ShootRegistry.self, from: data)
        } catch {
            NSLog("Auto: shoots.json unreadable, starting empty: \(error)")
            return ShootRegistry()
        }
    }

    @concurrent static func save(_ r: ShootRegistry, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(r).write(to: url, options: .atomic)
    }

    /// The `/Volumes/<name>` mount point a path lives under, if any.
    private static func volumeRoot(of path: String) -> String? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return "/Volumes/" + parts[2]
    }

    @concurrent static func resolve(_ records: [ShootRecord], calendar: Calendar, cardVolumes: [URL]) async -> [UUID: ShootAvailability] {
        let fm = FileManager.default
        var result: [UUID: ShootAvailability] = [:]
        for record in records {
            if let root = volumeRoot(of: record.path), !fm.fileExists(atPath: root) {
                result[record.id] = .offline
                continue
            }
            let folder = URL(fileURLWithPath: record.path, isDirectory: true)
            if VolumeClassifier.isOnCard(folder, cards: cardVolumes) {
                result[record.id] = .missing
                continue
            }
            let sidecarURL = folder.appendingPathComponent(ShootSidecar.fileName)
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? ShootSidecar.decode(data),
                  let shoot = sidecar.shoot(folder: folder, calendar: calendar) else {
                result[record.id] = .missing
                continue
            }
            result[record.id] = sidecar.id == record.id ? .online(shoot) : .mismatch
        }
        return result
    }

    @concurrent static func discover(under root: URL, calendar: Calendar) async -> [ShootRecord] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [ShootRecord] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: child.appendingPathComponent(ShootSidecar.fileName)),
                  let sidecar = try? ShootSidecar.decode(data) else { continue }
            found.append(ShootRecord(id: sidecar.id, name: sidecar.name, day: sidecar.day,
                                     path: child.standardizedFileURL.path, lastSeen: Date()))
        }
        return found
    }
}
