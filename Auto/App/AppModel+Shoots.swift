import AppKit
import Foundation

extension AppModel {
    // MARK: Shoot registry

    func cardVolumes() -> [URL] { cards.map(\.volume) }

    /// Loads the registry, merges shoots found under the work folder, saves if changed, then refreshes.
    func loadShoots() async {
        var loaded = await ShootStore.load(from: registryURL)
        let before = loaded
        if let root = workRoot {
            let found = await ShootStore.discover(under: root, calendar: calendar)
            // discover stamps lastSeen = now on every scan; only persist real additions or path-less changes.
            let known = Set(loaded.records.map(\.id))
            if found.contains(where: { !known.contains($0.id) }) { loaded.merge(discovered: found) }
        }
        registry = loaded
        if loaded != before { await saveRegistry() }
        await refreshShoots()
    }

    func saveRegistry() async {
        do { try await ShootStore.save(registry, to: registryURL) } catch {
            NSLog("Auto: couldn't save shoots.json: \(error)")
        }
    }

    private func day(of record: ShootRecord) -> Date {
        let parts = record.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return .distantPast }
        return calendar.startOfDay(for: date)
    }

    private func publishShoots(previous: [UUID: ShootItem]) {
        shoots = registry.records.map { record in
            var item = previous[record.id] ?? ShootItem(record: record, date: .distantPast)
            item.record = record
            item.date = day(of: record)
            return item
        }.sorted { a, b in
            a.date != b.date ? a.date > b.date : a.record.name.localizedStandardCompare(b.record.name) == .orderedAscending
        }
    }

    private static func effectiveFolder(_ availability: ShootAvailability?) -> URL? {
        if case .online(let shoot)? = availability { return shoot.folder.standardizedFileURL }
        return nil
    }

    /// Re-resolves availability, summaries and thumbnails for every known shoot.
    func refreshShoots() async {
        shootsGeneration += 1
        let generation = shootsGeneration
        publishShoots(previous: Dictionary(uniqueKeysWithValues: shoots.map { ($0.id, $0) }))

        let resolved = await ShootStore.resolve(registry.records, calendar: calendar, cardVolumes: cardVolumes(),
                                                volumeID: volumeIDProvider)
        // Mounted volume of every copy of each multi-copy shoot: a swapped or remounted drive changes these.
        let provider = volumeIDProvider
        let copyPaths = registry.records.filter { $0.copyPaths.count >= 2 }.map { ($0.id, $0.copyPaths) }
        let mountsByShoot: [UUID: [String]] = await Task.detached {
            Dictionary(uniqueKeysWithValues: copyPaths.map { ($0.0, Self.mountIDs($0.1, provider)) })
        }.value
        let availability = resolved.mapValues(\.availability)
        guard generation == shootsGeneration else { return }
        var syncChanged = Set<UUID>()
        for i in shoots.indices {
            let id = shoots[i].id
            // The copy Auto reads from changed (failover to a mirror, or back): coverage and add plans aimed at
            // the old folder are stale.
            if Self.effectiveFolder(shoots[i].availability) != Self.effectiveFolder(availability[id]) {
                cancelCoverage { $0.shootID == id }
                discardAddPlans(forShoot: id)
            }
            shoots[i].availability = availability[id]
            shoots[i].copies = resolved[id]?.copies ?? []
            syncCurrentMounts[id] = mountsByShoot[id]
            let signature = shoots[i].copies.map { "\($0.path)|\($0.availability)" } + (mountsByShoot[id] ?? [])
            if syncSignatures[id] != signature { syncSignatures[id] = signature; syncChanged.insert(id) }
            if case .online? = availability[id] {} else { shoots[i].summary = nil; shoots[i].thumbnail = nil }
        }
        // A copy came, went or changed: check (or re-evaluate) the shoots whose copies changed. Covers launch.
        syncSignatures = syncSignatures.filter { key, _ in shoots.contains { $0.id == key } }
        var syncForced = Set<UUID>()
        for id in syncChanged {
            if let checked = syncMounts[id], let now = syncCurrentMounts[id], checked != now {
                syncForced.insert(id)   // a drive was swapped or remounted under the same path
                if !syncActive.contains(id) { syncStates[id] = .unknown("A drive was remounted · checking again") }
            }
            guard let item = shoots.first(where: { $0.id == id }), item.record.copyPaths.count >= 2,
                  item.copies.contains(where: { $0.availability != .online }) else { continue }
            syncForced.insert(id)
            if !syncActive.contains(id) { syncStates[id] = .unknown(unknownReason(item)) }
        }
        if !syncForced.isEmpty { scheduleSyncCheck(syncForced, force: true) }
        if !syncChanged.subtracting(syncForced).isEmpty { scheduleSyncCheck(syncChanged.subtracting(syncForced), force: false) }
        // The set of shoots that count as backup locations changed: re-verify the cards.
        for item in shoots {
            if case .online? = item.availability { continue }
            discardAddPlans(forShoot: item.id)
        }
        if Set(onlineShootFolders().map(\.path)) != backupShootFolders {
            cards.forEach { recompute($0) }
        }
        refreshBrowserMembership()

        let online: [(UUID, URL)] = shoots.compactMap { item in
            if case .online(let shoot)? = item.availability { return (item.id, shoot.folder) }
            return nil
        }
        for (id, folder) in online {
            let summary = await ShootSummary.scan(folder)
            guard generation == shootsGeneration, let i = shoots.firstIndex(where: { $0.id == id }) else { return }
            shoots[i].summary = summary
        }

        for (id, _) in online {
            guard let i = shoots.firstIndex(where: { $0.id == id }), let rep = shoots[i].summary?.representative else { continue }
            let key = "\(id.uuidString)|\(rep.path)"
            let image: CGImage?
            if let cached = thumbnailCache[key] {
                image = cached
            } else {
                image = try? await thumbnails.thumbnail(for: rep, maxPixels: 480)
                if let image { thumbnailCache[key] = image }
            }
            guard generation == shootsGeneration, let j = shoots.firstIndex(where: { $0.id == id }) else { return }
            shoots[j].thumbnail = image
        }
    }

    private func record(for shoot: Shoot) -> ShootRecord {
        ShootRecord(id: shoot.id, name: shoot.name, day: ShootSidecar.dayString(shoot.date, calendar: calendar),
                    path: shoot.folder.standardizedFileURL.path,
                    mirrors: shoot.mirrors.map { $0.standardizedFileURL.path }, lastSeen: Date(), layout: shoot.layout)
    }

    private func register(_ shoot: Shoot) async {
        registry.add(record(for: shoot))
        await saveRegistry()
        await refreshShoots()
    }

    /// Creates `<parent>/<name>` with its sidecar and registers it.
    @discardableResult
    func createShoot(name: String, date: Date, parent: URL, layout: ShootLayout = .cameraFolders) async throws -> Shoot {
        try await createShoot(name: name, date: date, parents: [parent], layout: layout)
    }

    /// Creates the shoot in `parents[0]` and a mirror in each further parent (all must be on distinct
    /// drives). If a mirror can't be made nothing is rolled back: the shoot registers with the copies
    /// that exist and `ShootError.partialCreate` is thrown.
    @discardableResult
    func createShoot(name: String, date: Date, parents: [URL], layout: ShootLayout = .cameraFolders) async throws -> Shoot {
        guard !parents.isEmpty else { throw ShootError.parentMissing }
        let volumes = cardVolumes()
        let calendar = calendar
        let provider = volumeIDProvider
        let registered = registry.records.flatMap(\.copyPaths)
        let outcome = try await Task.detached {
            try Self.createCopies(name: name, date: date, parents: parents, cardVolumes: volumes,
                                  calendar: calendar, registered: registered, layout: layout, volumeID: provider)
        }.value
        await register(outcome.shoot)
        if !outcome.failures.isEmpty {
            throw ShootError.partialCreate(created: outcome.created, failed: outcome.failures)
        }
        return outcome.shoot
    }

    private struct CreateOutcome: Sendable {
        var shoot: Shoot
        var created: [String]
        var failures: [ShootError.CopyFailure]
    }

    /// Drive name for messages: the `/Volumes/<name>` component, else the folder's own name.
    nonisolated static func driveLabel(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts[2] }
        return url.lastPathComponent
    }

    nonisolated private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Off main. With several parents every one is validated first (exists, off the cards, distinct
    /// drives, name free); then the primary and each mirror are created.
    nonisolated private static func createCopies(name: String, date: Date, parents: [URL], cardVolumes: [URL],
                                                 calendar: Calendar, registered: [String],
                                                 layout: ShootLayout, volumeID: @Sendable (URL) -> String?) throws -> CreateOutcome {
        if parents.count > 1 {
            var seen = Set<String>()
            for parent in parents {
                guard isExistingDirectory(parent) else { throw ShootError.parentMissing }
                if VolumeClassifier.isOnCard(parent, cards: cardVolumes) { throw ShootError.onCard }
                guard let vid = volumeID(parent) else { throw ShootError.parentMissing }
                guard seen.insert(vid).inserted else { throw ShootError.sameVolumeAsCopy }
                if let component = ShootPlanner.safeComponent(name) {
                    try checkNotOverlapping(parent.appendingPathComponent(component, isDirectory: true), registered: registered)
                }
                switch ShootFolders.classify(parent: parent, name: name) {
                case .free: break
                case .existingShoot(let s): throw ShootError.alreadyAShoot(s.id)
                case .plainFolder: throw ShootError.folderExistsWithoutSidecar(name)
                case .notAFolder: throw ShootError.notAFolder(name)
                case .unreadableShoot(let e): throw e
                case .invalidName: throw ShootError.invalidName
                }
            }
        }
        var shoot = try ShootFolders.create(name: name, date: date, parent: parents[0], cardVolumes: cardVolumes, calendar: calendar, layout: layout)
        var created = [driveLabel(parents[0])]
        var failures: [ShootError.CopyFailure] = []
        if parents.count > 1 {
            // The primary exists now and must be registered whatever happens next, so a failed read-back
            // only fails the mirrors.
            let sidecar: ShootSidecar?
            let readError: Error?
            do { sidecar = try ShootFolders.readSidecar(in: shoot.folder); readError = nil } catch { sidecar = nil; readError = error }
            for parent in parents.dropFirst() {
                do {
                    guard let sidecar else { throw readError ?? ShootError.corruptSidecar }
                    shoot.mirrors.append(try ShootFolders.createCopy(of: sidecar, parent: parent, cardVolumes: cardVolumes))
                    created.append(driveLabel(parent))
                } catch {
                    failures.append(.init(name: driveLabel(parent), reason: error.localizedDescription))
                }
            }
        }
        return CreateOutcome(shoot: shoot, created: created, failures: failures)
    }

    /// Runtime mount identity of the volume holding `url`, read off the main actor.
    func volumeIdentity(of url: URL) async -> String? {
        let provider = volumeIDProvider
        return await Task.detached { provider(url) }.value
    }

    /// "Use this folder": turns an existing plain folder into a shoot.
    @discardableResult
    func adoptFolder(_ url: URL, name: String, date: Date) async throws -> Shoot {
        let volumes = cardVolumes()
        let calendar = calendar
        let shoot = try await Task.detached {
            try ShootFolders.adopt(folder: url, name: name, date: date, cardVolumes: volumes, calendar: calendar)
        }.value
        await register(shoot)
        return shoot
    }

    /// Checks the folder off the main actor.
    func classifyShootFolder(parent: URL, name: String) async -> ShootFolders.FolderCollision {
        await Task.detached { ShootFolders.classify(parent: parent, name: name) }.value
    }

    /// Where new shoot folders go by default: the last chosen parent, else the work folder.
    var defaultShootParent: URL? {
        if let path = defaults.string(forKey: Keys.lastParent), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return workRoot
    }

    func chooseShootParent() -> URL? {
        guard let url = chooseParentFolder() else { return nil }
        defaults.set(url.path, forKey: Keys.lastParent)
        return url
    }

    /// Same panel, but doesn't remember the choice (mirror drives aren't the default parent).
    func chooseMirrorParent() -> URL? { chooseParentFolder() }

    private func chooseParentFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where the shoot folder should be created."
        panel.directoryURL = defaultShootParent
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Points a shoot at `folder` after checking the folder's sidecar carries the shoot's id.
    func relocateShoot(id: UUID, to folder: URL) async throws {
        guard registry.records.contains(where: { $0.id == id }) else { return }
        let sidecar = try await Task.detached { try ShootFolders.readSidecar(in: folder) }.value
        guard sidecar?.id == id else { throw ShootError.sidecarMismatch }
        guard let current = registry.records.first(where: { $0.id == id }) else { return }
        try registry.relocate(id: id, from: current.path, to: folder.standardizedFileURL.path)
        await saveRegistry()
        await refreshShoots()
        scheduleSyncCheck([id], force: true)
    }

    /// Asks the user for the shoot's new folder.
    func locateShoot(id: UUID) {
        guard let item = shoots.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Locate"
        panel.message = "Choose the folder for \"\(item.record.name)\"."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await relocateShoot(id: id, to: url) } catch {
                let alert = NSAlert()
                alert.messageText = "Can't use that folder"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func mapRegistryError(_ error: ShootRegistry.RegistryError) -> Error {
        switch error {
        case .alreadyRegistered: ShootError.alreadyRegistered
        case .lastCopy: ShootError.lastCopy
        default: error
        }
    }

    /// Adds a mirror of an online shoot in `parent/<shoot name>`. A free name is created; a plain folder
    /// there is only used when `adopt` is true; a folder already carrying this shoot's sidecar is linked
    /// without a write. The mirror must be on a different drive than every online copy, and must not
    /// overlap any registered copy. The sidecar is verified before the mirror is registered.
    func addMirror(shootID: UUID, parent: URL, adopt: Bool = false) async throws {
        try beginCopyOp(shootID)
        defer { copyOpsInFlight.remove(shootID) }
        guard let item = shoots.first(where: { $0.id == shootID }) else { throw UnknownTargetError() }
        guard case .online(let shoot)? = item.availability else { throw ShootError.shootOffline }
        let source = shoot.folder
        let online = shoot.copies
        let registered = registry.records.flatMap(\.copyPaths)
        let volumes = cardVolumes()
        let provider = volumeIDProvider
        let (folder, targetVolume) = try await Task.detached {
            try Self.prepareMirror(shootID: shootID, source: source, parent: parent, adopt: adopt, onlineCopies: online,
                                   registered: registered, cardVolumes: volumes, volumeID: provider)
        }.value
        guard let current = registry.records.first(where: { $0.id == shootID }) else { throw UnknownTargetError() }
        // Re-check against every copy now on a mounted drive (not just the online ones seen before the await).
        let all = current.copyPaths
        let clash = await Task.detached { Self.sharesVolume(targetVolume, with: all, volumeID: provider) }.value
        if clash { throw ShootError.sameVolumeAsCopy }
        do { try registry.addMirror(id: shootID, path: folder.standardizedFileURL.path) } catch { throw mapRegistryError(error) }
        await saveRegistry()
        await refreshShoots()
        scheduleSyncCheck([shootID], force: true)
    }

    /// Off main. Returns the mirror folder, created, adopted or linked, with its sidecar verified.
    nonisolated private static func prepareMirror(
        shootID: UUID, source: URL, parent: URL, adopt: Bool, onlineCopies: [URL], registered: [String],
        cardVolumes: [URL], volumeID: @Sendable (URL) -> String?
    ) throws -> (folder: URL, volume: String) {
        guard let sidecar = try ShootFolders.readSidecar(in: source), sidecar.id == shootID else { throw ShootError.sidecarMismatch }
        guard isExistingDirectory(parent) else { throw ShootError.parentMissing }
        if VolumeClassifier.isOnCard(parent, cards: cardVolumes) { throw ShootError.onCard }
        guard let parentID = volumeID(parent) else { throw ShootError.parentMissing }
        if onlineCopies.contains(where: { volumeID($0) == parentID }) { throw ShootError.sameVolumeAsCopy }
        guard let component = ShootPlanner.safeComponent(sidecar.name) else { throw ShootError.invalidName }
        let target = parent.appendingPathComponent(component, isDirectory: true)
        try checkNotOverlapping(target, registered: registered)

        switch ShootFolders.classifyCopy(parent: parent, sidecar: sidecar) {
        case .free: try ShootFolders.createCopy(of: sidecar, parent: parent, cardVolumes: cardVolumes)
        case .sameShoot: break
        case .plainFolder:
            guard adopt else { throw ShootError.folderExistsWithoutSidecar(component) }
            try ShootFolders.adoptCopy(folder: target, sidecar: sidecar, cardVolumes: cardVolumes)
        case .otherShoot(let id): throw ShootError.alreadyAShoot(id)
        case .notAFolder: throw ShootError.notAFolder(component)
        case .unreadable(let e): throw e
        }
        guard try ShootFolders.readSidecar(in: target)?.id == shootID else { throw ShootError.sidecarMismatch }
        guard let targetID = volumeID(target) else { throw ShootError.parentMissing }
        if onlineCopies.contains(where: { volumeID($0) == targetID }) { throw ShootError.sameVolumeAsCopy }
        return (target, targetID)
    }

    /// Whether any of `paths` sits on the volume `id`. Off main.
    nonisolated private static func sharesVolume(_ id: String, with paths: [String], volumeID: @Sendable (URL) -> String?) -> Bool {
        paths.contains { volumeID(URL(fileURLWithPath: $0, isDirectory: true)) == id }
    }

    private struct CopyOpBusyError: LocalizedError {
        var errorDescription: String? { "Another change to this shoot's copies is still in progress." }
    }

    private func beginCopyOp(_ id: UUID) throws {
        guard copyOpsInFlight.insert(id).inserted else { throw CopyOpBusyError() }
    }

    /// Refuses a folder equal to, inside or containing any registered copy (symlinks resolved, case-insensitive).
    nonisolated private static func checkNotOverlapping(_ target: URL, registered: [String]) throws {
        func norm(_ url: URL) -> String {
            let p = ShootPlanner.resolvedPath(url).standardizedFileURL.path
                .precomposedStringWithCanonicalMapping.lowercased()
            return p.hasSuffix("/") ? p : p + "/"
        }
        let t = norm(target)
        for path in registered {
            let r = norm(URL(fileURLWithPath: path, isDirectory: true))
            if t.hasPrefix(r) || r.hasPrefix(t) { throw ShootError.alreadyRegistered }
        }
    }

    /// Asks for the parent folder of a new mirror, offering to adopt a plain folder of the same name.
    func addMirror(shootID: UUID) {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Mirror"
        panel.message = "Choose a folder on another drive for a mirror of \"\(item.record.name)\"."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                do { try await addMirror(shootID: shootID, parent: url) } catch ShootError.folderExistsWithoutSidecar(let name) {
                    let ask = NSAlert()
                    ask.messageText = "Use the existing \"\(name)\" folder?"
                    ask.informativeText = "A folder with that name is already there. Auto will add its shoot info file and use it as a mirror; nothing in it is changed."
                    ask.addButton(withTitle: "Use Folder")
                    ask.addButton(withTitle: "Cancel")
                    guard ask.runModal() == .alertFirstButtonReturn else { return }
                    try await addMirror(shootID: shootID, parent: url, adopt: true)
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Can't add that mirror"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Points one copy (primary or mirror) at `folder` after checking its sidecar carries the shoot's id
    /// and that no other online copy is on the same drive.
    func relocateCopy(shootID: UUID, from path: String, to folder: URL) async throws {
        try beginCopyOp(shootID)
        defer { copyOpsInFlight.remove(shootID) }
        guard let item = shoots.first(where: { $0.id == shootID }) else { throw UnknownTargetError() }
        // Dry run on a copy: unknown copy or already-registered folder is reported before any disk checks.
        var trial = registry
        do { try trial.relocate(id: shootID, from: path, to: folder.standardizedFileURL.path) } catch { throw mapRegistryError(error) }
        if let busy = copyOpBlock(for: shootID) { throw busy }
        let fromKey = URL(fileURLWithPath: path).standardizedFileURL.path
        let others = item.copies.filter { $0.availability == .online && $0.path != path }.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let registered = registry.records.flatMap(\.copyPaths).filter { URL(fileURLWithPath: $0).standardizedFileURL.path != fromKey }
        let volumes = cardVolumes()
        let provider = volumeIDProvider
        let targetVolume = try await Task.detached { () throws -> String in
            guard try ShootFolders.readSidecar(in: folder)?.id == shootID else { throw ShootError.sidecarMismatch }
            if VolumeClassifier.isOnCard(folder, cards: volumes) { throw ShootError.onCard }
            try Self.checkNotOverlapping(folder, registered: registered)
            guard let vid = provider(folder) else { throw ShootError.parentMissing }
            if others.contains(where: { provider($0) == vid }) { throw ShootError.sameVolumeAsCopy }
            return vid
        }.value
        // Re-check against every copy of the record now on a mounted drive, other than the one moving.
        guard let current = registry.records.first(where: { $0.id == shootID }) else { throw UnknownTargetError() }
        let remaining = current.copyPaths.filter { URL(fileURLWithPath: $0).standardizedFileURL.path != fromKey }
        let clash = await Task.detached { Self.sharesVolume(targetVolume, with: remaining, volumeID: provider) }.value
        if clash { throw ShootError.sameVolumeAsCopy }
        var again = registry
        do { try again.relocate(id: shootID, from: path, to: folder.standardizedFileURL.path) } catch { throw mapRegistryError(error) }
        if let busy = copyOpBlock(for: shootID) { throw busy }
        if isEffectivePrimary(shootID, path: path) {
            // The folder Auto reads from is moving: coverage aimed at it is stale.
            cancelCoverage { $0.shootID == shootID }
        }
        // Idle plans carry this copy as a root: drop them (the user plans again).
        discardAddPlans(forShoot: shootID)
        registry = again
        await saveRegistry()
        await refreshShoots()
        scheduleSyncCheck([shootID], force: true)
    }

    private func isEffectivePrimary(_ shootID: UUID, path: String) -> Bool {
        guard let item = shoots.first(where: { $0.id == shootID }), case .online(let shoot)? = item.availability else { return false }
        return shoot.folder.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Drops one copy from Auto's list. Files on the drive are never touched; the last copy can't go.
    /// Refused while any card is copying into the shoot.
    func removeCopy(shootID: UUID, path: String) async throws {
        try beginCopyOp(shootID)
        defer { copyOpsInFlight.remove(shootID) }
        var trial = registry
        do { try trial.removeCopy(id: shootID, path: path) } catch { throw mapRegistryError(error) }
        if let busy = copyOpBlock(for: shootID) { throw busy }
        if isEffectivePrimary(shootID, path: path) { cancelCoverage { $0.shootID == shootID } }
        // Idle plans carry this copy as a root: drop them (the user plans again).
        discardAddPlans(forShoot: shootID)
        registry = trial
        await saveRegistry()
        await refreshShoots()
        scheduleSyncCheck([shootID], force: true)
    }

    /// Asks the user where one copy of the shoot is now.
    func locateCopy(shootID: UUID, path: String) {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Locate"
        panel.message = "Choose the folder for this copy of \"\(item.record.name)\"."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await relocateCopy(shootID: shootID, from: path, to: url) } catch {
                let alert = NSAlert()
                alert.messageText = "Can't use that folder"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Removes the shoot from Auto's list. Files on disk are never touched.
    func forgetShoot(id: UUID) async {
        cancelCoverage { $0.shootID == id }
        discardAddPlans(forShoot: id)
        forgetSyncState(id)
        registry.remove(id: id)
        await saveRegistry()
        await refreshShoots()
    }
}
