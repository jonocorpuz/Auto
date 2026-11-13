import Foundation

/// One remembered shoot. The sidecar in the folder stays the source of truth; this is an index.
nonisolated struct ShootRecord: Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    /// "yyyy-MM-dd", calendar-local.
    var day: String
    /// Primary copy.
    var path: String
    /// Other copies, standardized paths, in user order.
    var mirrors: [String] = []
    /// Copies known to be missing footage from an ingest that couldn't reach them. A hint only.
    var pendingSync: [String] = []
    var lastSeen: Date
    var layout: ShootLayout = .cameraFolders

    /// Every copy, primary first.
    var copyPaths: [String] { [path] + mirrors }

    init(id: UUID, name: String, day: String, path: String,
         mirrors: [String] = [], pendingSync: [String] = [], lastSeen: Date,
         layout: ShootLayout = .cameraFolders) {
        self.id = id
        self.name = name
        self.day = day
        self.path = path
        self.mirrors = mirrors
        self.pendingSync = pendingSync
        self.lastSeen = lastSeen
        self.layout = layout
    }

    // Hand-written because synthesized decoding ignores property defaults, and a decode failure
    // quarantines the whole registry. Older registries lack `mirrors`, `pendingSync` and `layout`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        day = try container.decode(String.self, forKey: .day)
        path = try container.decode(String.self, forKey: .path)
        mirrors = try container.decodeIfPresent([String].self, forKey: .mirrors) ?? []
        pendingSync = try container.decodeIfPresent([String].self, forKey: .pendingSync) ?? []
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        layout = try container.decodeIfPresent(ShootLayout.self, forKey: .layout) ?? .cameraFolders
    }
}

/// The list of known shoots, persisted in Application Support (see `ShootStore`).
/// Registry only: nothing here ever touches a shoot's files.
nonisolated struct ShootRegistry: Codable, Sendable, Equatable {
    enum RegistryError: Error, Equatable, LocalizedError {
        case alreadyRegistered
        case lastCopy
        case unknownShoot
        case notACopy

        var errorDescription: String? {
            switch self {
            case .alreadyRegistered: "That folder is already part of a shoot in Auto."
            case .lastCopy: "This is the only copy of the shoot, so it can't be removed. Remove the shoot instead."
            case .unknownShoot: "Auto doesn't know that shoot any more."
            case .notACopy: "That folder isn't one of this shoot's copies."
            }
        }
    }

    var version = 1
    var records: [ShootRecord] = []

    // MARK: Path spelling

    /// Standardized path, original casing. This is what gets stored.
    private static func storedPath(_ path: String) -> String {
        VolumeClassifier.normalizedPath(URL(fileURLWithPath: path))
    }

    /// Comparison form: card and Mac volumes are usually case-insensitive and may differ in Unicode form.
    private static func comparablePath(_ path: String) -> String {
        storedPath(path).precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func isSamePath(_ a: String, _ b: String) -> Bool {
        comparablePath(a) == comparablePath(b)
    }

    private func index(of id: UUID) -> Int? {
        records.firstIndex { $0.id == id }
    }

    // MARK: Adding and removing shoots

    /// Same id merges (incoming path becomes primary, existing mirrors kept, incoming mirrors unioned).
    /// Every other record loses just the paths it shares with the incoming one, and is dropped only
    /// if that leaves it with no copies.
    mutating func add(_ incoming: ShootRecord) {
        let incomingPaths = Set(incoming.copyPaths.map(Self.comparablePath))
        let indexOfSameShoot = index(of: incoming.id)

        var kept: [ShootRecord] = []
        for (index, var existing) in records.enumerated() {
            if index == indexOfSameShoot {
                kept.append(Self.merged(incoming, into: existing))
            } else if Self.strip(&existing, paths: incomingPaths) {
                kept.append(existing)
            }
        }
        if indexOfSameShoot == nil { kept.append(incoming) }
        records = kept
    }

    /// `incoming` with the mirrors and pending hints of the record it replaces folded in.
    private static func merged(_ incoming: ShootRecord, into existing: ShootRecord) -> ShootRecord {
        let primary = incoming.path

        // Existing mirrors first, then the incoming ones; never the new primary, never twice.
        var mirrors: [String] = []
        for mirror in existing.mirrors + incoming.mirrors {
            let isPrimary = isSamePath(mirror, primary)
            let isAlreadyListed = mirrors.contains { isSamePath($0, mirror) }
            if !isPrimary, !isAlreadyListed { mirrors.append(mirror) }
        }

        // The old hint about the new primary is dropped; the incoming record decides that one.
        var pending = existing.pendingSync.filter { !isSamePath($0, primary) } + incoming.pendingSync
        // A hint only makes sense for a path that is still a copy.
        pending.removeAll { path in
            let isStillACopy = isSamePath(path, primary) || mirrors.contains { isSamePath($0, path) }
            return !isStillACopy
        }
        var seenPending = Set<String>()
        pending = pending.filter { seenPending.insert(comparablePath($0)).inserted }

        var result = incoming
        result.mirrors = mirrors
        result.pendingSync = pending
        return result
    }

    /// Drops `paths` (comparable form) from a record's copies and pendingSync, promoting a mirror if
    /// the primary went. Returns false when nothing is left of the record.
    private static func strip(_ record: inout ShootRecord, paths: Set<String>) -> Bool {
        record.mirrors.removeAll { paths.contains(comparablePath($0)) }
        record.pendingSync.removeAll { paths.contains(comparablePath($0)) }
        let primaryWasTaken = paths.contains(comparablePath(record.path))
        if primaryWasTaken {
            guard !record.mirrors.isEmpty else { return false }
            record.path = record.mirrors.removeFirst()
        }
        return true
    }

    mutating func remove(id: UUID) {
        records.removeAll { $0.id == id }
    }

    /// Adds unseen ids. Known ids keep their record and only get `lastSeen` and `layout` refreshed.
    /// Discovery never adds or changes mirrors.
    mutating func merge(discovered: [ShootRecord]) {
        for found in discovered {
            if let index = index(of: found.id) {
                records[index].lastSeen = max(records[index].lastSeen, found.lastSeen)
                records[index].layout = found.layout
            } else {
                records.append(found)
            }
        }
    }

    // MARK: Copies of one shoot

    /// Replaces one copy path, primary or mirror.
    mutating func relocate(id: UUID, from: String, to: String) throws(RegistryError) {
        guard let recordIndex = index(of: id) else { throw .unknownShoot }
        guard let copyIndex = records[recordIndex].copyPaths.firstIndex(where: { Self.isSamePath($0, from) }) else {
            throw .notACopy
        }

        // The new path may not belong to any copy other than the one being moved.
        for (otherRecordIndex, otherRecord) in records.enumerated() {
            for (otherCopyIndex, otherPath) in otherRecord.copyPaths.enumerated() {
                let isTheCopyBeingMoved = otherRecordIndex == recordIndex && otherCopyIndex == copyIndex
                if Self.isSamePath(otherPath, to) && !isTheCopyBeingMoved { throw .alreadyRegistered }
            }
        }

        let newPath = Self.storedPath(to)
        if copyIndex == 0 {
            records[recordIndex].path = newPath
        } else {
            records[recordIndex].mirrors[copyIndex - 1] = newPath
        }
        for pendingIndex in records[recordIndex].pendingSync.indices
        where Self.isSamePath(records[recordIndex].pendingSync[pendingIndex], from) {
            records[recordIndex].pendingSync[pendingIndex] = newPath
        }
    }

    /// Adds a mirror and marks it pending, since a new mirror is out of sync until checked.
    mutating func addMirror(id: UUID, path: String) throws(RegistryError) {
        guard let recordIndex = index(of: id) else { throw .unknownShoot }
        let isAlreadyACopy = records.contains { record in
            record.copyPaths.contains { Self.isSamePath($0, path) }
        }
        if isAlreadyACopy { throw .alreadyRegistered }

        let newPath = Self.storedPath(path)
        records[recordIndex].mirrors.append(newPath)
        records[recordIndex].pendingSync.append(newPath)
    }

    /// Removing the primary promotes the first mirror. The last copy can't be removed (use `remove(id:)`).
    mutating func removeCopy(id: UUID, path: String) throws(RegistryError) {
        guard let recordIndex = index(of: id) else { throw .unknownShoot }
        guard let copyIndex = records[recordIndex].copyPaths.firstIndex(where: { Self.isSamePath($0, path) }) else {
            throw .notACopy
        }
        guard !records[recordIndex].mirrors.isEmpty else { throw .lastCopy }

        if copyIndex == 0 {
            records[recordIndex].path = records[recordIndex].mirrors.removeFirst()
        } else {
            records[recordIndex].mirrors.remove(at: copyIndex - 1)
        }
        records[recordIndex].pendingSync.removeAll { Self.isSamePath($0, path) }
    }

    /// Sets or clears the "missing footage" hint for one copy. Ignored for a path that isn't a copy.
    mutating func setPendingSync(id: UUID, path: String, _ isPending: Bool) {
        guard let recordIndex = index(of: id) else { return }
        records[recordIndex].pendingSync.removeAll { Self.isSamePath($0, path) }
        let isACopy = records[recordIndex].copyPaths.contains { Self.isSamePath($0, path) }
        if isPending, isACopy {
            records[recordIndex].pendingSync.append(Self.storedPath(path))
        }
    }
}
