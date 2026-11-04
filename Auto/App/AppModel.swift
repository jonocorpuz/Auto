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
    /// The card whose New Shoot sheet is showing.
    var editingShoot: Card?
    private(set) var indexing = false

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
            UserDefaults.standard.set(workRoot?.path, forKey: Keys.workRoot)
            watcher.refresh()
            rebuildIndex()
        }
    }

    var dateFormat: String {
        didSet { UserDefaults.standard.set(dateFormat, forKey: Keys.dateFormat) }
    }

    /// Open or raise the main window when a new card mounts.
    var autoOpen: Bool {
        didSet { UserDefaults.standard.set(autoOpen, forKey: Keys.autoOpen) }
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

    init() {
        let defaults = UserDefaults.standard
        dateFormat = defaults.string(forKey: Keys.dateFormat) ?? ShootPlanner.defaultDateFormat
        autoOpen = defaults.object(forKey: Keys.autoOpen) as? Bool ?? true
        if let path = defaults.string(forKey: Keys.workRoot) {
            workRoot = URL(fileURLWithPath: path)
        }
    }

    private enum Keys {
        static let workRoot = "workRoot"
        static let dateFormat = "dateFormat"
        static let autoOpen = "autoOpen"
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

    /// "T7 Shield > 2026 > Client work" style path for display.
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
    }

    private func volumesChanged(cards found: [URL], drives found2: [DriveVolume], mountedNew: Bool) {
        drives = found2

        // Match by identity, not URL: a fast swap to another card with the same volume name
        // drops the old Card (and its backed state) and scans the new one from scratch.
        let identified = found.map { (url: $0, identity: VolumeIdentity.of($0)) }
        let gone = cards.filter { card in !identified.contains { $0.identity == card.identity } }
        for card in gone { card.engine?.cancel(); card.verifier?.cancel() }
        if let editing = editingShoot, gone.contains(where: { $0 === editing }) { editingShoot = nil }
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
    }

    // MARK: Scanning

    private func scan(_ card: Card) {
        card.phase = .scanning
        Task {
            let result = await CardScanner.scan(card.volume, volumeName: card.name)
            card.files = result.files
            card.cameras = result.cameras
            card.shootDate = result.shootDate
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
        let triage = BackupVerifier.triage(files: card.files, candidates: candidates, cache: verifications)

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

    private func stopVerifier(_ card: Card) {
        card.verifier?.cancel()
        card.verifier = nil
    }

    private func finishRecompute(_ card: Card, results: [URL: VerifyResult]) {
        card.missing = BackupVerifier.missing(files: card.files, results: results)
        if card.missing.isEmpty && !card.files.isEmpty {
            card.phase = .backed
            card.plan = nil
        } else if card.plan != nil {
            card.phase = .ready
        } else if case .failed = card.phase {
            return
        } else {
            card.phase = .needsBackup
        }
    }

    // MARK: Shoots

    func existingClients() -> [String] {
        guard let root = workRoot,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func shootFolderName(date: Date, name: String) -> String {
        ShootPlanner.folderName(date: date, name: name, dateFormat: dateFormat)
    }

    func shootFolderExists(client: String, date: Date, name: String) -> Bool {
        guard let root = workRoot,
              let shoot = try? ShootPlanner.shootURL(root: root, client: client, date: date, name: name, dateFormat: dateFormat) else { return false }
        return FileManager.default.fileExists(atPath: shoot.path)
    }

    /// Whether `client` can be used as a client folder name.
    func isValidClientName(_ client: String) -> Bool {
        ShootPlanner.safeComponent(client) != nil
    }

    func createShoot(card: Card, client: String, shootName: String, date: Date, cameras: [Camera]) throws {
        guard let root = workRoot else { return }
        let shoot = try ShootPlanner.shootURL(root: root, client: client, date: date, name: shootName, dateFormat: dateFormat)
        // Copies onto a card never count as a backup (e.g. the work folder was set on a card).
        if isOnCard(shoot) { throw CardDestinationError() }
        guard card.engine == nil else { return }
        stopVerifier(card)
        let jobs = ShootPlanner.jobs(missing: card.missing, shoot: shoot, cameras: cameras, fallback: card.name)
        guard jobs.allSatisfy({ ShootPlanner.isInside($0.destDir, root: shoot) }) else { throw ShootPlanner.PathError.outsideWorkFolder }

        let fm = FileManager.default
        try fm.createDirectory(at: shoot.appendingPathComponent("Project"), withIntermediateDirectories: true)
        for dir in Set(jobs.map(\.destDir)) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        card.plan = ShootPlanner.plan(jobs: jobs, shoot: shoot)
        card.phase = .ready
        editingShoot = nil
    }

    func chooseFolder(for card: Card) {
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
        card.phase = .ready
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
        panel.message = "Choose the folder your client folders live in, e.g. T7 Shield › 2026 › Client work."
        panel.directoryURL = workRoot ?? URL(fileURLWithPath: "/Volumes")
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { workRoot = url }
    }

    func discardPlan(_ card: Card) {
        guard card.engine == nil else { return }
        card.plan = nil
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
        let values = try? plan.destinationRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < plan.bytes {
            card.phase = .failed("Not enough space: needs \(Format.bytes(plan.bytes)), \(Format.bytes(free)) free.")
            return
        }

        let engine = CopyEngine()
        card.engine = engine
        card.progress = CopyProgress(filesTotal: plan.jobs.count, bytesTotal: plan.bytes)
        card.phase = .copying

        Task {
            let outcome = await engine.run(plan.jobs) { progress in card.progress = progress }
            card.engine = nil
            sessionCopies.append(contentsOf: outcome.copied)
            verifications.record(outcome.copied)

            let done = Set(outcome.copied.map(\.file.url))
            card.plan?.jobs.removeAll { done.contains($0.file.url) }
            if card.plan?.jobs.isEmpty == true { card.plan = nil }
            card.backedTo = plan.destinationRoot.path.hasPrefix(workingVolume?.path ?? "\u{0}") ? workingDriveName : plan.destinationLabel

            if let first = outcome.failures.first {
                let more = outcome.failures.count > 1 ? " (+\(outcome.failures.count - 1) more)" : ""
                card.phase = .failed("\(first.name): \(first.reason)\(more)")
            } else {
                card.phase = .needsBackup
            }
            recompute(card)
            if !outcome.cancelled { openMainWindow() }
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

enum Format {
    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
