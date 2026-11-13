import Foundation

nonisolated enum ShootAvailability: Sendable, Equatable {
    case online(Shoot)
    /// The path's volume (/Volumes/<name>) isn't mounted.
    case offline
    /// Volume mounted but the folder or sidecar is gone (or it sits on a card).
    case missing
    /// The sidecar's id differs from the record.
    case mismatch
}

/// How one copy of a shoot looks right now.
nonisolated enum CopyAvailability: Sendable, Equatable {
    case online
    /// /Volumes/<name> isn't mounted.
    case offline
    /// Folder or sidecar is gone, or it sits on a card.
    case missing
    /// The sidecar's id differs from the record.
    case mismatch
    /// Shares a mounted volume with an earlier online copy, so it isn't a real mirror.
    case sameVolume(as: String)
}

nonisolated struct ShootCopyState: Sendable, Equatable, Identifiable {
    let path: String
    let isPrimary: Bool
    var availability: CopyAvailability
    /// Lexical: "/Volumes/<name>" gives the name, anything else is "This Mac".
    var volumeName: String
    var id: String { path }
}

nonisolated struct ShootResolution: Sendable, Equatable {
    /// Aggregate over all copies.
    var availability: ShootAvailability
    var copies: [ShootCopyState]
}

/// Loads and saves the shoot registry, and works out which copies of each shoot are reachable.
nonisolated enum ShootStore {
    static func defaultURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("Auto", isDirectory: true)
            .appendingPathComponent("shoots.json")
    }

    // MARK: Loading and saving

    /// A missing file is an empty registry. An unreadable or undecodable one is quarantined
    /// (never deleted) and an empty registry is returned.
    @concurrent static func load(from url: URL) async -> ShootRegistry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let fileIsMissing = (error as NSError).code == NSFileReadNoSuchFileError
            if !fileIsMissing {
                NSLog("Auto: shoots.json unreadable: \(error)")
                CorruptFileQuarantine.quarantine(url, description: "registry")
            }
            return ShootRegistry()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ShootRegistry.self, from: data)
        } catch {
            NSLog("Auto: shoots.json undecodable, backing up and starting empty: \(error)")
            CorruptFileQuarantine.quarantine(url, description: "registry")
            return ShootRegistry()
        }
    }

    /// Hands out call-order tickets so a slow earlier save can never overwrite a later one.
    private static let tickets = TicketCounter()

    @concurrent static func save(_ registry: ShootRegistry, to url: URL) async throws {
        let ticket = tickets.next()
        try await ShootRegistrySaver.shared.save(registry, to: url, ticket: ticket)
    }

    // MARK: Volumes

    private static let volumesFolder = "/Volumes"

    /// The `/Volumes/<name>` mount point a path lives under, if any.
    private static func volumeRoot(of path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        // ["/", "Volumes", "<name>", ...]
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return volumesFolder + "/" + components[2]
    }

    /// True for a real mount (or a symlink such as "Macintosh HD"). A leftover empty directory in
    /// /Volumes shares the identifier of /Volumes itself and counts as not mounted.
    private static func isMounted(_ volumeRoot: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: volumeRoot) else { return false }
        let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: volumeRoot)) != nil
        if isSymlink { return true }

        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let volumeID = try? URL(fileURLWithPath: volumeRoot).resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
              let volumesFolderID = try? URL(fileURLWithPath: volumesFolder).resourceValues(forKeys: keys).volumeIdentifier as? NSObject
        else { return true }
        return !volumeID.isEqual(volumesFolderID)
    }

    /// Runtime mount identity of the volume holding `url`.
    static func realVolumeID(of url: URL) -> String? {
        guard let id = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return nil }
        return String(describing: id)
    }

    private static func volumeName(of path: String) -> String {
        guard let root = volumeRoot(of: path) else { return "This Mac" }
        return String(root.dropFirst(volumesFolder.count + 1))
    }

    // MARK: Resolving

    /// Resolves every copy of every record. The first online copy (record order) is the effective
    /// primary; later online copies on an already-seen volume are `.sameVolume` and not mirrors.
    /// `volumeID` is injectable so tests can fake distinct drives.
    @concurrent static func resolve(
        _ records: [ShootRecord], calendar: Calendar, cardVolumes: [URL],
        volumeID: @Sendable (URL) -> String? = ShootStore.realVolumeID(of:)
    ) async -> [UUID: ShootResolution] {
        var resolutions: [UUID: ShootResolution] = [:]
        for record in records {
            resolutions[record.id] = resolve(record, calendar: calendar, cardVolumes: cardVolumes, volumeID: volumeID)
        }
        return resolutions
    }

    private static func resolve(_ record: ShootRecord, calendar: Calendar, cardVolumes: [URL],
                                volumeID: (URL) -> String?) -> ShootResolution {
        var copyStates: [ShootCopyState] = []
        var primaryShoot: Shoot?
        var mirrorFolders: [URL] = []
        /// Volume id -> path of the first online copy on that volume.
        var firstCopyOnVolume: [String: String] = [:]

        for (copyIndex, path) in record.copyPaths.enumerated() {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            var availability: CopyAvailability

            switch probeCopy(at: path, folder: folder, record: record, calendar: calendar, cardVolumes: cardVolumes) {
            case .offline: availability = .offline
            case .missing: availability = .missing
            case .mismatch: availability = .mismatch
            case .readable(let shoot):
                availability = .online
                if let volume = volumeID(folder) {
                    if let earlierCopy = firstCopyOnVolume[volume] {
                        availability = .sameVolume(as: earlierCopy)
                    } else {
                        firstCopyOnVolume[volume] = path
                    }
                }
                if availability == .online {
                    if primaryShoot == nil { primaryShoot = shoot } else { mirrorFolders.append(folder) }
                }
            }
            copyStates.append(ShootCopyState(path: path, isPrimary: copyIndex == 0, availability: availability,
                                             volumeName: volumeName(of: path)))
        }

        let aggregate: ShootAvailability
        if var shoot = primaryShoot {
            shoot.mirrors = mirrorFolders
            aggregate = .online(shoot)
        } else if copyStates.contains(where: { $0.availability == .offline }) {
            aggregate = .offline
        } else if copyStates.first?.availability == .mismatch {
            aggregate = .mismatch
        } else {
            aggregate = .missing
        }
        return ShootResolution(availability: aggregate, copies: copyStates)
    }

    /// What one copy folder holds, before volumes are compared.
    private enum CopyProbe {
        case offline
        case missing
        case mismatch
        /// A readable folder whose sidecar belongs to the record.
        case readable(Shoot)
    }

    private static func probeCopy(at path: String, folder: URL, record: ShootRecord,
                                  calendar: Calendar, cardVolumes: [URL]) -> CopyProbe {
        if let volumeRoot = volumeRoot(of: path), !isMounted(volumeRoot) { return .offline }
        if VolumeClassifier.isOnCard(folder, cards: cardVolumes) { return .missing }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ShootSidecar.fileName)),
              let sidecar = try? ShootSidecar.decode(data),
              let shoot = sidecar.shoot(folder: folder, calendar: calendar) else { return .missing }
        guard sidecar.id == record.id else { return .mismatch }
        return .readable(shoot)
    }

    // MARK: Discovery

    /// Shoot folders (direct children with a readable sidecar) under `root`, sorted by folder name.
    @concurrent static func discover(under root: URL, calendar: Calendar) async -> [ShootRecord] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [ShootRecord] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: child.appendingPathComponent(ShootSidecar.fileName)),
                  let sidecar = try? ShootSidecar.decode(data) else { continue }
            found.append(ShootRecord(id: sidecar.id, name: sidecar.name, day: sidecar.day,
                                     path: child.standardizedFileURL.path, lastSeen: Date(),
                                     layout: sidecar.layout))
        }
        return found
    }
}

nonisolated final class TicketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Serializes registry writes and drops any snapshot older than one already written.
actor ShootRegistrySaver {
    static let shared = ShootRegistrySaver()
    /// Registry file path -> ticket of the newest snapshot written there.
    private var lastTicket: [String: Int] = [:]

    func save(_ registry: ShootRegistry, to url: URL, ticket: Int) throws {
        let key = url.standardizedFileURL.path
        if let newestWritten = lastTicket[key], newestWritten > ticket { return }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(registry).write(to: url, options: .atomic)
        lastTicket[key] = ticket
    }
}
