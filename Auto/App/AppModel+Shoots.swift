import AppKit
import Foundation

/// Shoots: the registry of known shoots, creating and adopting shoot folders, and managing each
/// shoot's copies (primary and mirrors). Nothing here touches the files inside a shoot.
extension AppModel {
    private static let shootThumbnailMaxPixels: CGFloat = 480

    // MARK: Registry

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
        do {
            try await ShootStore.save(registry, to: registryURL)
        } catch {
            NSLog("Auto: couldn't save shoots.json: \(error)")
        }
    }

    /// Copies the shoot's registry record onto its published item after an in-place registry edit.
    func republishRecord(of shootID: UUID) {
        guard let index = shoots.firstIndex(where: { $0.id == shootID }),
              let updated = registry.records.first(where: { $0.id == shootID }) else { return }
        shoots[index].record = updated
    }

    /// The record's "yyyy-MM-dd" day as a date (`.distantPast` when it can't be parsed).
    private func day(of record: ShootRecord) -> Date {
        let parts = record.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .distantPast }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return .distantPast }
        return calendar.startOfDay(for: date)
    }

    /// Rebuilds `shoots` from the registry, newest first then by name, keeping what is already known
    /// about each shoot (availability, summary, thumbnail).
    private func publishShoots() {
        let previous = Dictionary(uniqueKeysWithValues: shoots.map { ($0.id, $0) })
        let items = registry.records.map { record in
            var item = previous[record.id] ?? ShootItem(record: record, date: .distantPast)
            item.record = record
            item.date = day(of: record)
            return item
        }
        shoots = items.sorted { first, second in
            if first.date != second.date { return first.date > second.date }
            return first.record.name.localizedStandardCompare(second.record.name) == .orderedAscending
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
        publishShoots()

        let resolved = await ShootStore.resolve(registry.records, calendar: calendar, cardVolumes: cardVolumes(),
                                                volumeID: volumeIDProvider)
        // Mounted volume of every copy of each multi-copy shoot: a swapped or remounted drive changes these.
        let provider = volumeIDProvider
        let copyPaths = registry.records.filter { $0.copyPaths.count >= 2 }.map { ($0.id, $0.copyPaths) }
        let mountsByShoot: [UUID: [String]] = await Task.detached {
            Dictionary(uniqueKeysWithValues: copyPaths.map { ($0.0, Self.mountIDs($0.1, provider)) })
        }.value
        guard generation == shootsGeneration else { return }

        let shootsWithChangedCopies = applyResolved(resolved, mountsByShoot: mountsByShoot)
        scheduleSyncChecks(forChangedCopiesOf: shootsWithChangedCopies)

        // Plans aimed at a shoot that is no longer online can't run.
        for item in shoots {
            if case .online? = item.availability { continue }
            discardAddPlans(forShoot: item.id)
        }
        // The set of shoots that count as backup locations changed: re-verify the cards.
        if Set(onlineShootFolders().map(\.path)) != backupShootFolders {
            cards.forEach { recompute($0) }
        }
        refreshBrowserMembership()

        let onlineShoots: [(id: UUID, folder: URL)] = shoots.compactMap { item in
            guard case .online(let shoot)? = item.availability else { return nil }
            return (item.id, shoot.folder)
        }
        for (id, folder) in onlineShoots {
            let summary = await ShootSummary.scan(folder)
            guard generation == shootsGeneration, let index = shoots.firstIndex(where: { $0.id == id }) else { return }
            shoots[index].summary = summary
        }
        for (id, _) in onlineShoots {
            guard let representative = shoots.first(where: { $0.id == id })?.summary?.representative else { continue }
            let image = await shootThumbnail(shootID: id, representative: representative)
            guard generation == shootsGeneration, let index = shoots.firstIndex(where: { $0.id == id }) else { return }
            shoots[index].thumbnail = image
        }
    }

    /// Stores the freshly resolved availability and copies on each shoot. Returns the shoots whose copies
    /// (their paths, availability or mounted drives) differ from the last refresh.
    private func applyResolved(_ resolved: [UUID: ShootResolution], mountsByShoot: [UUID: [String]]) -> Set<UUID> {
        var changed = Set<UUID>()
        for index in shoots.indices {
            let id = shoots[index].id
            let availability = resolved[id]?.availability
            // The copy Auto reads from changed (failover to a mirror, or back): coverage and add plans aimed at
            // the old folder are stale.
            if Self.effectiveFolder(shoots[index].availability) != Self.effectiveFolder(availability) {
                cancelCoverage { $0.shootID == id }
                discardAddPlans(forShoot: id)
            }
            shoots[index].availability = availability
            shoots[index].copies = resolved[id]?.copies ?? []
            syncCurrentMounts[id] = mountsByShoot[id]

            let signature = shoots[index].copies.map { "\($0.path)|\($0.availability)" } + (mountsByShoot[id] ?? [])
            if syncSignatures[id] != signature {
                syncSignatures[id] = signature
                changed.insert(id)
            }

            if case .online? = availability { continue }
            shoots[index].summary = nil
            shoots[index].thumbnail = nil
        }
        // Forget the signatures of shoots that are gone.
        syncSignatures = syncSignatures.filter { id, _ in shoots.contains { $0.id == id } }
        return changed
    }

    /// A copy came, went or changed: check (or re-evaluate) the shoots whose copies changed. Covers launch.
    private func scheduleSyncChecks(forChangedCopiesOf changed: Set<UUID>) {
        var forced = Set<UUID>()
        for id in changed {
            // A drive was swapped or remounted under the same path.
            if let checkedMounts = syncMounts[id], let currentMounts = syncCurrentMounts[id], checkedMounts != currentMounts {
                forced.insert(id)
                if !syncActive.contains(id) { syncStates[id] = .unknown("A drive was remounted · checking again") }
            }
            guard let item = shoots.first(where: { $0.id == id }), item.record.copyPaths.count >= 2,
                  item.copies.contains(where: { $0.availability != .online }) else { continue }
            forced.insert(id)
            if !syncActive.contains(id) { syncStates[id] = .unknown(unknownReason(item)) }
        }
        let unforced = changed.subtracting(forced)
        if !forced.isEmpty { scheduleSyncCheck(forced, force: true) }
        if !unforced.isEmpty { scheduleSyncCheck(unforced, force: false) }
    }

    /// The shoot's grid thumbnail, from the cache when its representative file is unchanged.
    private func shootThumbnail(shootID: UUID, representative: URL) async -> CGImage? {
        let key = "\(shootID.uuidString)|\(representative.path)"
        if let cached = thumbnailCache[key] { return cached }
        let image = try? await thumbnails.thumbnail(for: representative, maxPixels: Self.shootThumbnailMaxPixels)
        if let image { thumbnailCache[key] = image }
        return image
    }

    // MARK: Creating and adopting

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

    /// Creates `<parents[0]>/<name>` with its sidecar, registers it, and makes a mirror in each further parent (all must be on distinct
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
        let wantsMirrors = parents.count > 1
        if wantsMirrors {
            try validateMirroredParents(parents, name: name, cardVolumes: cardVolumes, registered: registered, volumeID: volumeID)
        }
        var shoot = try ShootFolders.create(name: name, date: date, parent: parents[0], cardVolumes: cardVolumes,
                                            calendar: calendar, layout: layout)
        var created = [driveLabel(parents[0])]
        var failures: [ShootError.CopyFailure] = []
        guard wantsMirrors else { return CreateOutcome(shoot: shoot, created: created, failures: failures) }

        // The primary exists now and must be registered whatever happens next, so a failed read-back
        // only fails the mirrors.
        let sidecar: ShootSidecar?
        let readError: Error?
        do {
            sidecar = try ShootFolders.readSidecar(in: shoot.folder)
            readError = nil
        } catch {
            sidecar = nil
            readError = error
        }
        for parent in parents.dropFirst() {
            do {
                guard let sidecar else { throw readError ?? ShootError.corruptSidecar }
                shoot.mirrors.append(try ShootFolders.createCopy(of: sidecar, parent: parent, cardVolumes: cardVolumes))
                created.append(driveLabel(parent))
            } catch {
                failures.append(.init(name: driveLabel(parent), reason: error.localizedDescription))
            }
        }
        return CreateOutcome(shoot: shoot, created: created, failures: failures)
    }

    /// Every parent must exist, be off the cards, sit on its own drive and have the shoot's name free.
    nonisolated private static func validateMirroredParents(_ parents: [URL], name: String, cardVolumes: [URL],
                                                            registered: [String], volumeID: (URL) -> String?) throws {
        var seenVolumes = Set<String>()
        for parent in parents {
            guard isExistingDirectory(parent) else { throw ShootError.parentMissing }
            if VolumeClassifier.isOnCard(parent, cards: cardVolumes) { throw ShootError.onCard }
            guard let parentVolume = volumeID(parent) else { throw ShootError.parentMissing }
            guard seenVolumes.insert(parentVolume).inserted else { throw ShootError.sameVolumeAsCopy }
            if let component = ShootPlanner.safeComponent(name) {
                try checkNotOverlapping(parent.appendingPathComponent(component, isDirectory: true), registered: registered)
            }
            switch ShootFolders.classify(parent: parent, name: name) {
            case .free: break
            case .existingShoot(let existing): throw ShootError.alreadyAShoot(existing.id)
            case .plainFolder: throw ShootError.folderExistsWithoutSidecar(name)
            case .notAFolder: throw ShootError.notAFolder(name)
            case .unreadableShoot(let error): throw error
            case .invalidName: throw ShootError.invalidName
            }
        }
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

    // MARK: Choosing folders

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

    // MARK: Locating a moved shoot

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
            do {
                try await relocateShoot(id: id, to: url)
            } catch {
                showAlert("Can't use that folder", error)
            }
        }
    }

    // MARK: Copies (primary and mirrors)

    /// Registry errors the UI has its own wording for.
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
        do {
            try registry.addMirror(id: shootID, path: folder.standardizedFileURL.path)
        } catch {
            throw mapRegistryError(error)
        }
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
        case .unreadable(let error): throw error
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
        // Trailing slash so "/a/b" is not seen as inside "/a/bc".
        func comparablePath(_ url: URL) -> String {
            let path = ShootPlanner.resolvedPath(url).standardizedFileURL.path
                .precomposedStringWithCanonicalMapping.lowercased()
            return path.hasSuffix("/") ? path : path + "/"
        }
        let targetPath = comparablePath(target)
        for path in registered {
            let registeredPath = comparablePath(URL(fileURLWithPath: path, isDirectory: true))
            let overlaps = targetPath.hasPrefix(registeredPath) || registeredPath.hasPrefix(targetPath)
            if overlaps { throw ShootError.alreadyRegistered }
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
                do {
                    try await addMirror(shootID: shootID, parent: url)
                } catch ShootError.folderExistsWithoutSidecar(let name) {
                    guard confirmAdoptingFolder(named: name) else { return }
                    try await addMirror(shootID: shootID, parent: url, adopt: true)
                }
            } catch {
                showAlert("Can't add that mirror", error)
            }
        }
    }

    private func confirmAdoptingFolder(named name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use the existing \"\(name)\" folder?"
        alert.informativeText = "A folder with that name is already there. Auto will add its shoot info file and use it as a mirror; nothing in it is changed."
        alert.addButton(withTitle: "Use Folder")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// Points one copy (primary or mirror) at `folder` after checking its sidecar carries the shoot's id
    /// and that no other online copy is on the same drive.
    func relocateCopy(shootID: UUID, from path: String, to folder: URL) async throws {
        try beginCopyOp(shootID)
        defer { copyOpsInFlight.remove(shootID) }
        guard let item = shoots.first(where: { $0.id == shootID }) else { throw UnknownTargetError() }
        // Dry run on a copy: unknown copy or already-registered folder is reported before any disk checks.
        var trial = registry
        do {
            try trial.relocate(id: shootID, from: path, to: folder.standardizedFileURL.path)
        } catch {
            throw mapRegistryError(error)
        }
        if let busy = copyOpBlock(for: shootID) { throw busy }

        let movingPath = URL(fileURLWithPath: path).standardizedFileURL.path
        func isNotTheMovingCopy(_ copyPath: String) -> Bool {
            URL(fileURLWithPath: copyPath).standardizedFileURL.path != movingPath
        }
        let others = item.copies
            .filter { $0.availability == .online && $0.path != path }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let registered = registry.records.flatMap(\.copyPaths).filter(isNotTheMovingCopy)
        let volumes = cardVolumes()
        let provider = volumeIDProvider
        let targetVolume = try await Task.detached { () throws -> String in
            guard try ShootFolders.readSidecar(in: folder)?.id == shootID else { throw ShootError.sidecarMismatch }
            if VolumeClassifier.isOnCard(folder, cards: volumes) { throw ShootError.onCard }
            try Self.checkNotOverlapping(folder, registered: registered)
            guard let folderVolume = provider(folder) else { throw ShootError.parentMissing }
            if others.contains(where: { provider($0) == folderVolume }) { throw ShootError.sameVolumeAsCopy }
            return folderVolume
        }.value
        // Re-check against every copy of the record now on a mounted drive, other than the one moving.
        guard let current = registry.records.first(where: { $0.id == shootID }) else { throw UnknownTargetError() }
        let remaining = current.copyPaths.filter(isNotTheMovingCopy)
        let clash = await Task.detached { Self.sharesVolume(targetVolume, with: remaining, volumeID: provider) }.value
        if clash { throw ShootError.sameVolumeAsCopy }
        // The registry may have changed while the checks ran off main: apply the move to the current one.
        var updated = registry
        do {
            try updated.relocate(id: shootID, from: path, to: folder.standardizedFileURL.path)
        } catch {
            throw mapRegistryError(error)
        }
        if let busy = copyOpBlock(for: shootID) { throw busy }
        if isEffectivePrimary(shootID, path: path) {
            // The folder Auto reads from is moving: coverage aimed at it is stale.
            cancelCoverage { $0.shootID == shootID }
        }
        // Idle plans carry this copy as a root: drop them (the user plans again).
        discardAddPlans(forShoot: shootID)
        registry = updated
        await saveRegistry()
        await refreshShoots()
        scheduleSyncCheck([shootID], force: true)
    }

    private func isEffectivePrimary(_ shootID: UUID, path: String) -> Bool {
        guard let item = shoots.first(where: { $0.id == shootID }),
              case .online(let shoot)? = item.availability else { return false }
        return shoot.folder.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Drops one copy from Auto's list. Files on the drive are never touched; the last copy can't go.
    /// Refused while any card is copying into the shoot.
    func removeCopy(shootID: UUID, path: String) async throws {
        try beginCopyOp(shootID)
        defer { copyOpsInFlight.remove(shootID) }
        var updated = registry
        do {
            try updated.removeCopy(id: shootID, path: path)
        } catch {
            throw mapRegistryError(error)
        }
        if let busy = copyOpBlock(for: shootID) { throw busy }
        if isEffectivePrimary(shootID, path: path) { cancelCoverage { $0.shootID == shootID } }
        // Idle plans carry this copy as a root: drop them (the user plans again).
        discardAddPlans(forShoot: shootID)
        registry = updated
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
            do {
                try await relocateCopy(shootID: shootID, from: path, to: url)
            } catch {
                showAlert("Can't use that folder", error)
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
