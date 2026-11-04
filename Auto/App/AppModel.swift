import AppKit
import Foundation
import Observation

/// Shared app state. Views read it via `@Environment(AppModel.self)`.
@Observable
final class AppModel {
    enum Status: CaseIterable {
        case idle, unbacked, copying, backed, error

        var label: String {
            switch self {
            case .idle: "Idle"
            case .unbacked: "Not backed up"
            case .copying: "Copying…"
            case .backed: "Backed up"
            case .error: "Something went wrong"
            }
        }

        /// Tint of the dot in the menu bar icon.
        var tint: NSColor {
            switch self {
            case .idle: .tertiaryLabelColor
            case .unbacked: NSColor(red: 0.93, green: 0.42, blue: 0.33, alpha: 1)
            case .copying: .systemBlue
            case .backed: .systemGreen
            case .error: .systemRed
            }
        }
    }

    // MARK: State

    private(set) var cards: [Card] = []
    private(set) var drives: [DriveVolume] = []
    /// The New Shoot sheet request currently showing, if any.
    var shootSheet: ShootSheetRequest?
    /// Card the legacy copy-flow sheet (`.create`) should use; nil picks the first card with work to do.
    private(set) var shootSheetCard: Card?
    /// Known shoots for the Shoots grid, newest first.
    private(set) var shoots: [ShootItem] = []
    private(set) var registry = ShootRegistry()
    private(set) var indexing = false
    /// Per (shoot, card) coverage checks for the Add Footage sheet.
    private(set) var coverage: [CoverageKey: CoverageState] = [:]
    /// Calendar used to split recordings into days (scan and New Shoot selection).
    let calendar = Calendar.current

    /// Aggregate status across cards (see `StatusAggregator`).
    var status: Status {
        switch StatusAggregator.aggregate(cards.map(\.phase)) {
        case .idle: .idle
        case .unbacked: .unbacked
        case .copying: .copying
        case .backed: .backed
        case .error: .error
        }
    }

    /// Root folder Auto works in. Persisted in UserDefaults.
    var workRoot: URL? {
        didSet {
            defaults.set(workRoot?.path, forKey: Keys.workRoot)
            watcher.refresh()
            rebuildIndex()
            Task { await loadShoots() }
        }
    }

    /// Open or raise the main window when a new card mounts.
    var autoOpen: Bool {
        didSet { defaults.set(autoOpen, forKey: Keys.autoOpen) }
    }

    /// Sidebar selection in the main window.
    var selectedTab: AppTab = .media

    /// Light/dark preference, applied app-wide.
    var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Shown in the sidebar's account row. Local macOS user until real accounts exist.
    let accountName: String = {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }()

    var accountInitials: String {
        let letters = accountName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Provided by AppDelegate.
    @ObservationIgnored var openMainWindow: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}

    @ObservationIgnored private var index: [String: [URL]] = [:]
    @ObservationIgnored private let verifications = VerificationCache()
    /// Files CopyEngine copied and verified this session, with their exact destinations.
    @ObservationIgnored private var sessionCopies: [CopiedFile] = []
    @ObservationIgnored private var indexGeneration = 0
    /// Identity of the working volume the current index was built for (nil: none).
    @ObservationIgnored private var indexedVolumeID: String?
    @ObservationIgnored private lazy var watcher = VolumeWatcher(workingVolume: { [weak self] in self?.workingVolume })

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let registryURL: URL
    @ObservationIgnored let thumbnails: any ThumbnailProvider
    @ObservationIgnored private var thumbnailCache: [String: CGImage] = [:]
    @ObservationIgnored private var shootsGeneration = 0
    @ObservationIgnored private var coverageTasks: [CoverageKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var coverageGenerations: [CoverageKey: Int] = [:]
    @ObservationIgnored private var coverageCounter = 0
    /// Card id -> shoot a pending add-footage plan copies into.
    @ObservationIgnored private var addTargets: [Card.ID: UUID] = [:]
    /// Online shoot folders the current backup verification considered (to detect changes).
    @ObservationIgnored private var backupShootFolders: Set<String> = []

    init(registryURL: URL = ShootStore.defaultURL(),
         thumbnails: any ThumbnailProvider = QLThumbnailProvider(),
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.registryURL = registryURL
        self.thumbnails = thumbnails
        autoOpen = defaults.object(forKey: Keys.autoOpen) as? Bool ?? true
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init) ?? .system
        if let path = defaults.string(forKey: Keys.workRoot) {
            workRoot = URL(fileURLWithPath: path)
        }
    }

    private enum Keys {
        static let workRoot = "workRoot"
        static let autoOpen = "autoOpen"
        static let appearance = "appearance"
        static let lastParent = "shoots.lastParent"
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    // MARK: New Shoot sheet

    /// The card the legacy copy-flow sheet acts on: the first one with work to do.
    var ingestCandidate: Card? {
        cards.first { $0.phase == .ready } ?? cards.first { $0.phase == .needsBackup }
    }

    /// Sidebar New Shoot: opens the create sheet.
    func newShoot(card: Card? = nil) {
        selectedTab = .media
        shootSheetCard = card
        shootSheet = .create
    }

    /// Opens the sheet in add mode with the first card that has files on the shoot's day
    /// (else the first card, else none).
    func addFootage(to shootID: UUID) {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return }
        shootSheetCard = nil
        shootSheet = .add(shootID: shootID, cardID: cardForAdding(day: item.date)?.id)
    }

    func cardForAdding(day: Date) -> Card? {
        let start = calendar.startOfDay(for: day)
        let match = cards.first { card in
            card.shootDays.values.contains { $0.contains { calendar.startOfDay(for: $0.start) == start } }
        }
        return match ?? cards.first
    }

    // MARK: Working drive

    /// The mounted volume that holds the work folder.
    var workingVolume: URL? {
        guard let root = workRoot, FileManager.default.fileExists(atPath: root.path) else { return nil }
        return try? root.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    var workingDriveName: String {
        if let volume = workingVolume { return Self.volumeName(volume) }
        if let root = workRoot, root.pathComponents.count > 2, root.pathComponents[1] == "Volumes" {
            return root.pathComponents[2]
        }
        return "your drive"
    }

    /// "T7 Shield > 2026 > Shoots" style path for display.
    var workRootBreadcrumb: String {
        guard let root = workRoot else { return "your drive" }
        let parts = root.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts.dropFirst(2).joined(separator: " › ") }
        return parts.suffix(3).joined(separator: " › ")
    }

    private static func volumeName(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeURLKey])
        // Fixture folders are not volume roots, so name them after the folder.
        guard let root = values?.volume, root.standardizedFileURL == url.standardizedFileURL else { return url.lastPathComponent }
        return values?.volumeName ?? url.lastPathComponent
    }

    // MARK: Volumes

    func start() {
        watcher.onChange = { [weak self] cardURLs, driveVolumes, mountedNew in
            self?.volumesChanged(cards: cardURLs, drives: driveVolumes, mountedNew: mountedNew)
        }
        watcher.start()
        rebuildIndex()
        Task { await loadShoots() }
    }

    private func volumesChanged(cards found: [URL], drives found2: [DriveVolume], mountedNew: Bool) {
        drives = found2

        // Match by identity, not URL: a fast swap to another card with the same volume name
        // drops the old Card (and its backed state) and scans the new one from scratch.
        let identified = found.map { (url: $0, identity: VolumeIdentity.of($0)) }
        let gone = cards.filter { card in !identified.contains { $0.identity == card.identity } }
        for card in gone {
            card.engine?.cancel(); card.verifier?.cancel()
            cancelCoverage { $0.cardID == card.id }
            addTargets[card.id] = nil
        }
        if let shown = shootSheetCard, gone.contains(where: { $0 === shown }) {
            shootSheetCard = nil
            if shootSheet == .create { shootSheet = nil }
        }
        if case .add(_, let cardID?) = shootSheet, gone.contains(where: { $0.id == cardID }) { shootSheet = nil }
        cards.removeAll { card in gone.contains { $0 === card } }

        var added = false
        for (url, identity) in identified where !cards.contains(where: { $0.identity == identity }) {
            let card = Card(volume: url, name: Self.volumeName(url), identity: identity)
            cards.append(card)
            scan(card)
            added = true
        }
        if added && mountedNew && autoOpen { openMainWindow() }

        // The work drive was plugged in, unplugged or swapped: the index is stale.
        if workingVolume.map(VolumeIdentity.of) != indexedVolumeID { rebuildIndex() }
        Task { await refreshShoots() }
    }

    // MARK: Scanning

    private func scan(_ card: Card) {
        card.phase = .scanning
        // The file list is about to change: any coverage computed from it is stale.
        cancelCoverage { $0.cardID == card.id }
        Task {
            let result = await CardScanner.scan(card.volume, volumeName: card.name)
            card.files = result.files
            card.cameras = result.cameras
            card.shootDate = result.shootDate
            card.shootDays = ShootDays.byCamera(result.files, calendar: calendar)
            card.scanError = result.error
            recompute(card)
        }
    }

    /// Scan the card again (e.g. after an unreadable result).
    func rescan(_ card: Card) {
        guard card.engine == nil else { return }
        card.verifier?.cancel()
        card.verifier = nil
        card.plan = nil
        scan(card)
    }

    func rebuildIndex() {
        indexGeneration += 1
        let generation = indexGeneration
        indexedVolumeID = workingVolume.map(VolumeIdentity.of)
        guard let volume = workingVolume else {
            index = [:]
            indexing = false
            cards.forEach { recompute($0) }
            return
        }
        indexing = true
        Task {
            let built = await DriveIndex.build(volume)
            guard generation == indexGeneration else { return }
            index = built
            indexing = false
            cards.forEach { recompute($0) }
        }
    }

    /// A card is backed up only when every file is checksum-verified against a copy on the work drive.
    /// Name+size hits are just candidates; `BackupVerifier` hashes them off the main actor.
    private func recompute(_ card: Card) {
        if case .copying = card.phase { return }
        stopVerifier(card)

        // No media, or a scan error: never verify, never backed.
        if let phase = CardPhase.afterScan(fileCount: card.files.count, error: card.scanError) {
            card.missing = card.files
            card.plan = nil
            card.phase = phase
            return
        }

        let driveReady = workingVolume != nil
        // Session copy destinations count wherever they are (work drive or a chosen folder),
        // but only through the cache entry for that exact card file, or a fresh checksum.
        let candidates = BackupVerifier.addingCandidates(sessionCopies, to: driveReady ? index : [:])
        let generation = card.recomputeGeneration
        let shootFolders = onlineShootFolders()
        backupShootFolders = Set(shootFolders.map(\.path))
        let cardVolumes = cards.map(\.volume)
        let workVolume = driveReady ? workingVolume : nil
        // Never leave a stale green up while re-checking.
        if card.phase == .backed { card.phase = .scanning }
        Task {
            // Any registered, online shoot counts as a backup location ("any shoot counts"). Built off
            // main; card files never count as candidates for themselves.
            let candidates = await Self.backupCandidates(base: candidates, shootFolders: shootFolders,
                                                         cardVolumes: cardVolumes, workVolume: workVolume)
            // Triage stats every candidate on disk, so it runs off the main actor.
            let triage = await BackupVerifier.triageOffMain(files: card.files, candidates: candidates, cache: verifications)
            // Superseded by a copy, a new plan, a rescan or a newer recompute.
            guard card.recomputeGeneration == generation, card.engine == nil, card.phase != .copying else { return }
            settle(card, triage: triage, candidates: candidates, driveReady: driveReady)
        }
    }

    private func settle(_ card: Card, triage: (settled: [URL: VerifyResult], toVerify: [MediaFile]), candidates: [String: [URL]], driveReady: Bool) {
        let allVerified = triage.toVerify.isEmpty && card.files.allSatisfy { triage.settled[$0.url]?.isVerified == true }
        if indexing && driveReady && !allVerified {
            card.phase = .scanning
            return
        }

        if triage.toVerify.isEmpty {
            finishRecompute(card, results: triage.settled)
            return
        }
        if case .failed = card.phase {
            // Keep the failure on screen; unverified files simply stay on the to-copy list.
            finishRecompute(card, results: triage.settled)
            return
        }

        let verifier = BackupVerifier()
        card.verifier = verifier
        card.verifyProgress = CopyProgress(filesTotal: triage.toVerify.count, bytesTotal: triage.toVerify.reduce(0) { $0 + $1.size })
        card.phase = .verifying
        Task {
            let outcome = await verifier.run(triage.toVerify, candidates: candidates, cache: verifications) { progress in
                card.verifyProgress = progress
            }
            // Superseded by a newer recompute, a copy/plan that took over, or the card went away.
            guard !outcome.cancelled, card.verifier === verifier else { return }
            card.verifier = nil
            guard card.phase == .verifying else { return }
            finishRecompute(card, results: triage.settled.merging(outcome.results) { $1 })
        }
    }

    /// Folders of every registered shoot that is currently online (no I/O).
    private func onlineShootFolders() -> [URL] {
        shoots.compactMap { item -> URL? in
            if case .online(let shoot)? = item.availability { return shoot.folder.standardizedFileURL }
            return nil
        }
    }

    /// Merges the work-drive candidates with an index of each online shoot folder, deduplicated by path.
    /// Skips shoot folders on the work volume (already indexed, compared by volume identity), on a card,
    /// or containing a card; drops any candidate that lives on a card.
    @concurrent private static func backupCandidates(base: [String: [URL]], shootFolders: [URL],
                                                     cardVolumes: [URL], workVolume: URL?) async -> [String: [URL]] {
        let workID = workVolume.flatMap { try? $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier }
        var merged: [String: [URL]] = [:]
        var seen = Set<String>()
        func add(_ key: String, _ url: URL) {
            guard !VolumeClassifier.isInside(url, anyOf: cardVolumes),
                  seen.insert(url.standardizedFileURL.path).inserted else { return }
            merged[key, default: []].append(url)
        }
        for (key, urls) in base { for url in urls { add(key, url) } }
        for folder in shootFolders {
            if cardVolumes.contains(where: { VolumeClassifier.isInside($0, anyOf: [folder]) }) { continue }
            if VolumeClassifier.isOnCard(folder, cards: cardVolumes) { continue }
            if let workID, let id = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
               workID.isEqual(id) { continue }
            for (key, urls) in await DriveIndex.build(folder) { for url in urls { add(key, url) } }
        }
        return merged
    }

    /// Cancels any verify, and any triage still in flight, for this card.
    private func stopVerifier(_ card: Card) {
        card.verifier?.cancel()
        card.verifier = nil
        card.recomputeGeneration += 1
    }

    private func finishRecompute(_ card: Card, results: [URL: VerifyResult]) {
        card.missing = BackupVerifier.missing(files: card.files, results: results)
        guard let phase = CardPhase.afterVerify(fileCount: card.files.count, missingCount: card.missing.count,
                                                hasPlan: card.plan != nil, current: card.phase) else { return }
        if phase == .backed {
            // A pending add-footage plan (extra copies into another shoot) survives a backed verdict.
            if addTargets[card.id] != nil, card.plan != nil {
                card.phase = .ready
                return
            }
            card.plan = nil
        }
        card.phase = phase
    }

    // MARK: Shoots

    /// Whether `name` can be used as the shoot folder name.
    func isValidShootName(_ name: String) -> Bool {
        ShootPlanner.safeComponent(name) != nil
    }

    /// Preview of what a shoot would create for the selected files. Folders stay empty without a
    /// work folder or a usable name; the counts always reflect the selection.
    func shootPreview(card: Card, name: String, cameras: [Camera], selection: ShootSelection) -> ShootPreview {
        let selected = selection.filter(card.missing)
        let photos = selected.filter { $0.kind == .photo }.count
        var preview = ShootPreview(folders: [], videoCount: selected.count - photos, photoCount: photos, problem: nil)
        guard let root = workRoot else { return preview }
        do {
            let shoot = try ShootPlanner.shootURL(root: root, name: name)
            let jobs = ShootPlanner.jobs(missing: selected, shoot: shoot, cameras: cameras, fallback: card.name)
            let fm = FileManager.default
            preview.folders = ShootPlanner.folders(for: jobs, shoot: shoot, root: root).map { row in
                var row = row
                let url = row.components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                var isDir: ObjCBool = false
                row.exists = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                return row
            }
            preview.problem = ShootPlanner.problem(for: [shoot] + ShootPlanner.directories(for: jobs))?.errorDescription
        } catch ShootPlanner.PathError.invalidName {
            // Not an error to show while the user is still typing a name.
        } catch {
            preview.problem = error.localizedDescription
        }
        return preview
    }

    private struct PhaseError: LocalizedError {
        var errorDescription: String? { "This card can't start a new shoot right now." }
    }

    private func canPlan(_ card: Card) -> Bool {
        switch card.phase {
        case .needsBackup, .ready, .failed: true
        default: false
        }
    }

    func createShoot(card: Card, name: String, cameras: [Camera], selection: ShootSelection) throws {
        guard let root = workRoot else { return }
        guard workingVolume != nil else { throw ShootPlanner.PathError.workFolderMissing }
        let shoot = try ShootPlanner.shootURL(root: root, name: name)
        // Copies onto a card never count as a backup (e.g. the work folder was set on a card).
        if isOnCard(shoot) { throw CardDestinationError() }
        guard card.engine == nil else { return }
        guard canPlan(card) else { throw PhaseError() }
        let jobs = ShootPlanner.jobs(missing: selection.filter(card.missing), shoot: shoot, cameras: cameras, fallback: card.name)
        guard !jobs.isEmpty else { throw EmptySelectionError() }
        guard jobs.allSatisfy({ ShootPlanner.isInside($0.destDir, root: shoot) }) else { throw ShootPlanner.PathError.outsideWorkFolder }

        try ShootPlanner.createDirectories(ShootPlanner.directories(for: jobs), root: root, cardVolumes: volumes(including: card))
        stopVerifier(card)
        card.plan = ShootPlanner.plan(jobs: jobs, shoot: shoot, workRoot: root)
        addTargets[card.id] = nil
        card.phase = .ready
        shootSheet = nil
        shootSheetCard = nil
    }

    private struct EmptySelectionError: LocalizedError {
        var errorDescription: String? { "Select at least one file to copy." }
    }

    func chooseFolder(for card: Card) {
        guard canPlan(card) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy here"
        panel.message = "Choose where \(card.name)'s \(card.missing.count) files should go."
        panel.directoryURL = workRoot
        NSApp.activate()
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        if isOnCard(dir) {
            let alert = NSAlert()
            alert.messageText = "Can't copy to a camera card"
            alert.informativeText = CardDestinationError().localizedDescription
            alert.runModal()
            return
        }
        guard card.engine == nil else { return }
        stopVerifier(card)
        card.plan = ShootPlanner.flatPlan(missing: card.missing, into: dir)
        addTargets[card.id] = nil
        card.phase = .ready
    }

    /// Every connected card volume plus `card`'s own (it may be stale), deduplicated.
    private func volumes(including card: Card) -> [URL] {
        var seen = Set<String>()
        return (cards.map(\.volume) + [card.volume]).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Whether `url` is on any connected card (the source card included).
    private func isOnCard(_ url: URL) -> Bool {
        VolumeClassifier.isOnCard(url, cards: cards.map(\.volume))
    }

    func setWorkRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Choose the folder your shoots live in, e.g. T7 Shield › 2026."
        panel.directoryURL = workRoot ?? URL(fileURLWithPath: "/Volumes")
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { workRoot = url }
    }

    func discardPlan(_ card: Card) {
        guard card.engine == nil else { return }
        card.plan = nil
        addTargets[card.id] = nil
        recompute(card)
    }

    func openInFinder(_ card: Card) {
        var urls = [card.volume]
        if let dest = card.plan?.destinationRoot { urls.append(dest) }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    // MARK: Copying

    func copy(_ card: Card) {
        // One engine per card; a running verifier yields to the copy.
        guard let plan = card.plan, card.engine == nil, card.phase != .copying else { return }
        stopVerifier(card)
        if isOnCard(plan.destinationRoot) {
            card.phase = .failed(CardDestinationError().localizedDescription)
            return
        }
        do {
            let volumes = volumes(including: card)
            let root = plan.workRoot ?? plan.destinationRoot
            for dir in ShootPlanner.directories(for: plan.jobs) {
                try ShootPlanner.checkDestination(dir, root: root, cardVolumes: volumes)
            }
        } catch {
            card.phase = .failed(error.localizedDescription)
            return
        }
        let values = try? plan.destinationRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < plan.bytes {
            card.phase = .failed("Not enough space: needs \(Format.bytes(plan.bytes)), \(Format.bytes(free)) free.")
            return
        }

        let engine = CopyEngine()
        card.engine = engine
        card.progress = CopyProgress(filesTotal: plan.jobs.count, bytesTotal: plan.bytes)
        card.phase = .copying
        let addShootID = addTargets[card.id]
        let planWorkRoot = plan.workRoot

        Task {
            // Off main: the destination folder must still exist, and an add-footage target must still
            // carry the shoot's id, before a single byte is written.
            do {
                try await Task.detached { try Self.preflight(workRoot: planWorkRoot, shootID: addShootID) }.value
            } catch {
                guard card.engine === engine else { return }
                card.engine = nil
                card.phase = .failed(error.localizedDescription)
                return
            }
            guard card.engine === engine else { return }
            let outcome = await engine.run(plan.jobs) { progress in card.progress = progress }
            card.engine = nil
            sessionCopies.append(contentsOf: outcome.copied)
            verifications.record(outcome.copied)

            let done = Set(outcome.copied.map(\.file.url))
            card.plan?.jobs.removeAll { done.contains($0.file.url) }
            // Just-copied files must not be selectable again while they re-verify.
            card.missing.removeAll { done.contains($0.url) }
            if card.plan?.jobs.isEmpty == true { card.plan = nil }
            // The add target lives as long as the plan does (partial failures retry into the same shoot).
            if card.plan == nil { addTargets[card.id] = nil }
            card.backedTo = plan.destinationRoot.path.hasPrefix(workingVolume?.path ?? "\u{0}") ? workingDriveName : plan.destinationLabel

            if let first = outcome.failures.first {
                let more = outcome.failures.count > 1 ? " (+\(outcome.failures.count - 1) more)" : ""
                card.phase = .failed("\(first.name): \(first.reason)\(more)")
            } else {
                card.phase = .needsBackup
            }
            recompute(card)
            // Anything that landed inside a registered shoot changes that shoot's coverage.
            let landed = shoots.filter { item in
                if case .online(let shoot)? = item.availability { return ShootPlanner.isInside(plan.destinationRoot, root: shoot.folder) }
                return false
            }
            for item in landed { checkCoverage(shootID: item.id, cardID: card.id) }
            if !landed.isEmpty { await refreshShoots() }
            if !outcome.cancelled { openMainWindow() }
        }
    }

    nonisolated private static func preflight(workRoot: URL?, shootID: UUID?) throws {
        guard let root = workRoot else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ShootPlanner.PathError.workFolderMissing
        }
        if let shootID {
            guard try ShootFolders.readSidecar(in: root)?.id == shootID else { throw ShootError.sidecarMismatch }
        }
    }

    func stop(_ card: Card) {
        card.engine?.cancel()
    }

    /// Retries the copy if there is a plan, otherwise re-checks the card. Never both at once.
    func retry(_ card: Card) {
        guard card.engine == nil else { return }
        if card.plan != nil {
            copy(card)
        } else {
            card.phase = .needsBackup
            recompute(card)
        }
    }

    /// Only a verified-backed, idle card can be ejected from Auto.
    func canEject(_ card: Card) -> Bool {
        card.phase == .backed && card.engine == nil && card.verifier == nil && !card.ejecting
    }

    func eject(_ card: Card) {
        guard canEject(card) else { return }
        card.ejecting = true
        card.ejectError = nil
        let volume = card.volume
        Task {
            let error = await Task.detached { () -> Error? in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume); return nil } catch { return error }
            }.value
            card.ejecting = false
            // Shown beside the card; never replaces whatever phase the card is in now.
            if let error { card.ejectError = "Couldn't eject: \(error.localizedDescription)" }
        }
    }
}

extension AppModel {
    // MARK: Shoot registry

    private func cardVolumes() -> [URL] { cards.map(\.volume) }

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

    private func saveRegistry() async {
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

    /// Re-resolves availability, summaries and thumbnails for every known shoot.
    func refreshShoots() async {
        shootsGeneration += 1
        let generation = shootsGeneration
        publishShoots(previous: Dictionary(uniqueKeysWithValues: shoots.map { ($0.id, $0) }))

        let availability = await ShootStore.resolve(registry.records, calendar: calendar, cardVolumes: cardVolumes())
        guard generation == shootsGeneration else { return }
        for i in shoots.indices {
            let id = shoots[i].id
            shoots[i].availability = availability[id]
            if case .online? = availability[id] {} else { shoots[i].summary = nil; shoots[i].thumbnail = nil }
        }
        // The set of shoots that count as backup locations changed: re-verify the cards.
        for item in shoots {
            if case .online? = item.availability { continue }
            discardAddPlans(forShoot: item.id)
        }
        if Set(onlineShootFolders().map(\.path)) != backupShootFolders {
            cards.forEach { recompute($0) }
        }

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
                    path: shoot.folder.standardizedFileURL.path, lastSeen: Date())
    }

    private func register(_ shoot: Shoot) async {
        registry.add(record(for: shoot))
        await saveRegistry()
        await refreshShoots()
    }

    /// Creates `<parent>/<name>` with its sidecar and registers it.
    @discardableResult
    func createShoot(name: String, date: Date, parent: URL) async throws -> Shoot {
        let volumes = cardVolumes()
        let calendar = calendar
        let shoot = try await Task.detached {
            try ShootFolders.create(name: name, date: date, parent: parent, cardVolumes: volumes, calendar: calendar)
        }.value
        await register(shoot)
        return shoot
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

    func classifyShootFolder(parent: URL, name: String) -> ShootFolders.FolderCollision {
        ShootFolders.classify(parent: parent, name: name)
    }

    /// Where new shoot folders go by default: the last chosen parent, else the work folder.
    var defaultShootParent: URL? {
        if let path = defaults.string(forKey: Keys.lastParent), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return workRoot
    }

    func chooseShootParent() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where the shoot folder should be created."
        panel.directoryURL = defaultShootParent
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        defaults.set(url.path, forKey: Keys.lastParent)
        return url
    }

    /// Points a shoot at `folder` after checking the folder's sidecar carries the shoot's id.
    func relocateShoot(id: UUID, to folder: URL) async throws {
        guard registry.records.contains(where: { $0.id == id }) else { return }
        let sidecar = try await Task.detached { try ShootFolders.readSidecar(in: folder) }.value
        guard sidecar?.id == id else { throw ShootError.sidecarMismatch }
        registry.relocate(id: id, to: folder.standardizedFileURL.path)
        await saveRegistry()
        await refreshShoots()
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

    /// Removes the shoot from Auto's list. Files on disk are never touched.
    func forgetShoot(id: UUID) async {
        cancelCoverage { $0.shootID == id }
        discardAddPlans(forShoot: id)
        registry.remove(id: id)
        await saveRegistry()
        await refreshShoots()
    }
}

extension AppModel {
    // MARK: Add footage

    private struct UnknownTargetError: LocalizedError {
        var errorDescription: String? { "That shoot or card isn't available any more." }
    }

    private func cancelCoverage(where match: (CoverageKey) -> Bool) {
        for key in coverageTasks.keys where match(key) { coverageTasks[key]?.cancel(); coverageTasks[key] = nil }
        for key in coverage.keys where match(key) { coverage[key] = nil; coverageGenerations[key] = nil }
    }

    /// Checks (off the main actor) which of the card's files are already verified inside the shoot.
    func checkCoverage(shootID: UUID, cardID: Card.ID) {
        let key = CoverageKey(shootID: shootID, cardID: cardID)
        guard let card = cards.first(where: { $0.id == cardID }),
              let item = shoots.first(where: { $0.id == shootID }),
              case .online(let shoot)? = item.availability else {
            cancelCoverage { $0 == key }
            return
        }
        startCoverage(key: key, files: card.files, folder: shoot.folder, day: item.date)
    }

    /// Core of `checkCoverage` with explicit inputs. Returns the task so callers can await it.
    @discardableResult
    func startCoverage(key: CoverageKey, files: [MediaFile], folder: URL, day: Date) -> Task<Void, Never> {
        coverageTasks[key]?.cancel()
        coverageCounter += 1
        let generation = coverageCounter
        coverageGenerations[key] = generation
        coverage[key] = .checking(CopyProgress())
        let copies = sessionCopies
        let cache = verifications
        let calendar = calendar
        let cardVolumes = cards.map(\.volume)
        let task = Task {
            let (stream, continuation) = AsyncStream<CopyProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let consumer = Task {
                for await progress in stream {
                    if coverageGenerations[key] == generation, case .checking? = coverage[key] { coverage[key] = .checking(progress) }
                }
            }
            let result = await ShootCoverageChecker.run(files: files, shootFolder: folder, sessionCopies: copies, cache: cache,
                                                        cardVolumes: cardVolumes) { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            // Superseded, forgotten or ejected: never store a partial result.
            guard coverageGenerations[key] == generation else { return }
            coverageTasks[key] = nil
            if let failure = result.failure {
                coverage[key] = .failed(failure)
            } else if Task.isCancelled || result.cancelled {
                coverage[key] = nil
            } else {
                coverage[key] = .done(ShootCoverage.compute(files: files, day: day, calendar: calendar, inShoot: result.verified))
            }
        }
        coverageTasks[key] = task
        return task
    }

    /// Selection the sheet starts with in add mode: only the shoot's own day.
    func shootSheetDefaults(shootID: UUID, cardID: Card.ID) -> ShootSelection {
        let card = cards.first { $0.id == cardID }
        let day = shoots.first { $0.id == shootID }?.date ?? .distantPast
        return ShootSelection(files: card?.files ?? [], cameras: card?.cameras ?? [], calendar: calendar, onlyDay: day)
    }

    private struct CoverageUnavailableError: LocalizedError {
        var errorDescription: String? { "Auto couldn't finish checking what this shoot already has. Try again in a moment." }
    }

    /// Add-footage doesn't depend on the backup verdict: a backed-up card can still feed another shoot.
    private func canAddFootage(_ card: Card) -> Bool {
        switch card.phase {
        case .backed, .verifying, .needsBackup, .ready, .failed: card.engine == nil
        default: false
        }
    }

    /// Drops pending (not yet running) add-footage plans aimed at `shootID`.
    private func discardAddPlans(forShoot shootID: UUID) {
        for (cardID, target) in addTargets where target == shootID {
            guard let card = cards.first(where: { $0.id == cardID }) else { addTargets[cardID] = nil; continue }
            guard card.engine == nil else { continue }
            addTargets[cardID] = nil
            card.plan = nil
            if card.phase == .ready { recompute(card) }
        }
    }

    /// Plans a copy of the selected files that are not yet verified inside the shoot into the shoot folder
    /// (Video/Photo/<camera>). Re-reads the sidecar and runs a fresh coverage check first, so it never
    /// plans from a stale snapshot. The user then starts it with `copy(_:)`.
    func addFootage(shootID: UUID, cardID: Card.ID, cameras: [Camera], selection: ShootSelection) async throws {
        guard let item = shoots.first(where: { $0.id == shootID }), let card = cards.first(where: { $0.id == cardID }) else {
            throw UnknownTargetError()
        }
        guard case .online(let shoot)? = item.availability else { throw ShootError.shootOffline }
        guard canAddFootage(card) else { throw PhaseError() }
        let folder = shoot.folder
        let sidecar = try await Task.detached { try ShootFolders.readSidecar(in: folder) }.value
        guard sidecar?.id == shootID else {
            await refreshShoots()
            throw ShootError.sidecarMismatch
        }
        // State may have changed while the sidecar was read.
        guard case .online(let again)? = shoots.first(where: { $0.id == shootID })?.availability, again.folder == folder else {
            throw ShootError.shootOffline
        }
        guard cards.contains(where: { $0 === card }), canAddFootage(card) else { throw PhaseError() }
        if isOnCard(folder) { throw CardDestinationError() }

        // Fresh coverage for exactly the files on the card right now.
        let key = CoverageKey(shootID: shootID, cardID: cardID)
        let snapshot = card.files
        let task = startCoverage(key: key, files: snapshot, folder: folder, day: item.date)
        await task.value
        guard case .done(let covered)? = coverage[key] else {
            if case .failed(let reason)? = coverage[key] { throw ShootCoverageError(reason: reason) }
            throw CoverageUnavailableError()
        }
        guard cards.contains(where: { $0 === card }), card.files == snapshot, canAddFootage(card),
              case .online(let latest)? = shoots.first(where: { $0.id == shootID })?.availability, latest.folder == folder else {
            throw CoverageUnavailableError()
        }

        let jobs = ShootPlanner.jobs(missing: selection.filter(covered.notInShoot), shoot: folder, cameras: cameras, fallback: card.name)
        guard !jobs.isEmpty else { throw EmptySelectionError() }
        guard jobs.allSatisfy({ ShootPlanner.isInside($0.destDir, root: folder) }) else { throw ShootPlanner.PathError.outsideWorkFolder }

        try ShootPlanner.createDirectories(ShootPlanner.directories(for: jobs), root: folder, cardVolumes: volumes(including: card))
        stopVerifier(card)
        card.plan = ShootPlanner.plan(jobs: jobs, shoot: folder, workRoot: folder)
        addTargets[cardID] = shootID
        card.phase = .ready
        shootSheet = nil
        shootSheetCard = nil
    }

    struct ShootCoverageError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    #if DEBUG
    func _testInsert(card: Card) { cards.append(card) }
    #endif
}

enum Format {
    nonisolated static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
