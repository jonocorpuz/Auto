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
    /// Which shoots hold a verified copy of the browsed card's files. Browsed card only; separate from
    /// `coverage` (which Add Footage awaits).
    private(set) var browserMembership: [UUID: BrowserMembershipState] = [:]
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
    var selectedTab: AppTab = .media {
        didSet { if selectedTab != .media { browsingCardID = nil } }
    }
    /// Card open in the Media tab's file browser; nil shows the overview.
    var browsingCardID: Card.ID? {
        didSet {
            guard browsingCardID != oldValue else { return }
            fileThumbnails.removeAll()
            missingThumbnails.removeAll()
            browserCache = nil
            refreshBrowserMembership()
        }
    }

    /// Whether the main window is showing (not closed or minimized). Membership hashing only runs while
    /// it is: the window object outlives a close, so the browser's onDisappear can't be relied on.
    var mainWindowVisible = true {
        didSet { if mainWindowVisible != oldValue { refreshBrowserMembership() } }
    }

    var browsingCard: Card? {
        browsingCardID.flatMap { id in cards.first { $0.id == id } }
    }

    /// The browsed card's files grouped into "Not Backed Up", then by the shoot holding their copy.
    /// Memoized on its inputs, so selection clicks and copy-progress ticks don't regroup the card.
    func browserGroups(for card: Card) -> [CardBrowser.Group] {
        // Every registered shoot, online or not: a copy in a shoot that just went offline still belongs
        // to it until the re-verify drops it, rather than falling into "Backed Up Elsewhere".
        // A missing or mismatched shoot's folder is no longer that shoot: it isn't a group.
        let refs = shoots.compactMap { item -> CardBrowser.ShootRef? in
            let folder: URL
            switch item.availability {
            case .online(let shoot)?: folder = shoot.folder
            case .missing?, .mismatch?: return nil
            case .offline?, nil: folder = URL(fileURLWithPath: item.record.path, isDirectory: true)
            }
            return CardBrowser.ShootRef(id: item.id, name: item.record.name, folder: folder)
        }
        // A `.failed` shoot (its coverage check couldn't run) still gets a group through the lexical
        // `card.backups` fallback in `CardBrowser.group`: that copy was checksum-verified by the card
        // verifier, so hiding it would mislead. Only checked memberships can add *more* shoots.
        // Only complete, verified results, and only for the card being browsed.
        var memberships: [UUID: Set<URL>] = [:]
        if card.id == browsingCardID {
            for (id, state) in browserMembership {
                if case .done(let urls, _) = state { memberships[id] = urls }
            }
        }
        let key = BrowserKey(cardID: card.id, files: card.files, backups: card.backups,
                             missing: Set(card.missing.map(\.url)), shoots: refs, memberships: memberships)
        if let browserCache, browserCache.key == key { return browserCache.groups }
        let groups = CardBrowser.group(files: card.files, backups: card.backups, missing: key.missing,
                                       shoots: refs, memberships: memberships)
        browserCache = (key, groups)
        return groups
    }

    private struct BrowserKey: Equatable {
        let cardID: Card.ID
        let files: [MediaFile]
        let backups: [URL: URL]
        let missing: Set<URL>
        let shoots: [CardBrowser.ShootRef]
        let memberships: [UUID: Set<URL>]
    }

    /// Verified copies to reveal for `files`: inside a shoot group, that shoot's own copies (when its
    /// check is done); otherwise the card's backup verdict.
    func browserBackupCopies(_ files: [MediaFile], in kind: CardBrowser.GroupKind?) -> [URL] {
        if case .shoot(let id)? = kind, case .done(_, let copies)? = browserMembership[id] {
            return files.compactMap { copies[$0.url] }
        }
        guard let card = browsingCard else { return [] }
        return files.compactMap { card.backups[$0.url] }
    }

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
    /// Card browser previews, keyed by file path. Cleared wholesale when it grows large.
    @ObservationIgnored private var fileThumbnails: [String: CGImage] = [:]
    /// Files QuickLook couldn't preview, so they aren't retried on every scroll.
    @ObservationIgnored private var missingThumbnails: Set<String> = []
    @ObservationIgnored private var browserCache: (key: BrowserKey, groups: [CardBrowser.Group])?
    @ObservationIgnored private var shootsGeneration = 0
    @ObservationIgnored private var coverageTasks: [CoverageKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var coverageGenerations: [CoverageKey: Int] = [:]
    @ObservationIgnored private var coverageCounter = 0
    @ObservationIgnored private var membershipTask: Task<Void, Never>?
    @ObservationIgnored private var membershipGeneration = 0
    @ObservationIgnored private var membershipInputs: MembershipInputs?
    #if DEBUG
    @ObservationIgnored var _testEngineHook: ((CopyEngine) -> Void)?
    var _testSessionCopyDestinations: [URL] { sessionCopies.map(\.destination) }
    @ObservationIgnored var _testFreeSpace: (@Sendable (URL) -> Int64?)?
    /// Sync Now: awaited after the plan is prepared and before the engine is created.
    @ObservationIgnored var _testAfterSyncPrepare: (@MainActor (UUID) async -> Void)?
    @ObservationIgnored var _testSyncEngineHook: ((CopyEngine) -> Void)?
    @ObservationIgnored fileprivate var _testMembershipRunner: MembershipRunner?
    #endif
    /// Cards whose recompute (stat-triage Task) is in flight: the verdict isn't settled yet even though
    /// `verifier` is nil.
    @ObservationIgnored private var recomputePending: Set<Card.ID> = []
    /// The card whose browser is on screen (nil: none). Membership only runs while it is the browsed card.
    @ObservationIgnored private var browserOnScreen: Card.ID?
    /// Card id -> shoot a pending add-footage plan copies into.
    @ObservationIgnored private var addTargets: [Card.ID: UUID] = [:]
    /// Cards whose current plan was made with "copy duplicates anyway" (no copy-time pruning).
    @ObservationIgnored private var includeDuplicatePlans: Set<Card.ID> = []
    /// Cards with an addFootage/addFiles call in flight, and those that should be recomputed when it ends.
    @ObservationIgnored private var addInFlight: Set<Card.ID> = []
    @ObservationIgnored private var recomputeAfterAdd: Set<Card.ID> = []
    /// Online shoot folders the current backup verification considered (to detect changes).
    @ObservationIgnored private var backupShootFolders: Set<String> = []
    /// Shoots with a mirror operation (add / relocate / remove copy) in flight; one at a time per shoot.
    @ObservationIgnored private var copyOpsInFlight: Set<UUID> = []
    /// Runtime mount identity of the volume holding a URL (nil: unknown). Injectable so tests can fake
    /// distinct drives; every mirror / same-volume decision goes through it.
    @ObservationIgnored var volumeIDProvider: @Sendable (URL) -> String? = ShootStore.realVolumeID(of:)
    /// MD5 cache (`checksums.json` next to the registry). Seeded by every verified copy so a later sync check is all hits.
    @ObservationIgnored let checksums: ChecksumStore
    /// Cards waiting for another card's copy into an overlapping folder, in the order they asked.
    @ObservationIgnored private var copyQueue: [Card.ID] = []

    // MARK: Mirror sync state (see the "Mirror sync" extension)
    /// Where each shoot's mirror check / Sync Now stands. Absent until first scheduled.
    private(set) var syncStates: [UUID: ShootSyncState] = [:]
    /// When each shoot's contents were last fully re-read (a deep check that came back in sync). Persisted.
    private(set) var lastDeepVerify: [UUID: Date] = [:]
    /// Failures from the last Sync Now per shoot (e.g. a different file appeared at the destination).
    private(set) var syncNotes: [UUID: String] = [:]
    /// Quiet period before a scheduled check starts; requests inside it coalesce.
    @ObservationIgnored var syncDebounce: Duration = .seconds(2)
    /// A non-forced check is skipped when the last complete one is younger than this and the copies are unchanged.
    @ObservationIgnored var syncThrottle: Duration = .seconds(600)
    /// Runs one check. Injectable so tests can hold or fake it; the default is `ShootSyncChecker.run`.
    @ObservationIgnored var syncChecker: SyncCheckRunner = AppModel.realSyncChecker
    /// Checks actually started (a throttled, deferred or offline request doesn't count). For tests.
    @ObservationIgnored private(set) var syncChecksStarted = 0
    @ObservationIgnored fileprivate var syncWork: [SyncWork] = []
    @ObservationIgnored fileprivate var syncRunner: Task<Void, Never>?
    @ObservationIgnored fileprivate var syncSleeper: Task<Void, Never>?
    @ObservationIgnored fileprivate var syncRunning: (id: UUID, task: Task<ShootSyncReport?, Never>)?
    @ObservationIgnored fileprivate var syncGenerations: [UUID: Int] = [:]
    @ObservationIgnored fileprivate var syncEngines: [UUID: CopyEngine] = [:]
    @ObservationIgnored fileprivate var syncStopped: Set<UUID> = []
    @ObservationIgnored fileprivate var syncSignatures: [UUID: [String]] = [:]
    @ObservationIgnored fileprivate var startupLoad: Task<Void, Never>?
    /// Shoots whose check was held back (or invalidated) by an ingest copy: re-checked once an engine ends.
    @ObservationIgnored fileprivate var syncDeferred: Set<UUID> = []
    /// Shoots with a Sync Now job in flight (its first check through its re-check).
    @ObservationIgnored fileprivate var syncActive: Set<UUID> = []
    /// Mount identity of each copy and the time of the last complete check, for the throttle.
    @ObservationIgnored fileprivate var syncMounts: [UUID: [String]] = [:]
    @ObservationIgnored fileprivate var syncCurrentMounts: [UUID: [String]] = [:]
    @ObservationIgnored fileprivate var syncDoneAt: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored fileprivate var metaSave: Task<Void, Never>?

    // MARK: Photo cull state (see the "Photo cull" extension)
    /// Per-shoot cull state, keyed by shoot id. Absent = idle.
    private(set) var cullStates: [UUID: CullState] = [:]
    /// Settings for the next cull; clamped and saved to defaults on every set.
    var cullSettings: CullSettings {
        didSet {
            let clamped = cullSettings.clamped()
            if clamped != cullSettings { cullSettings = clamped; return }
            CullSettingsStore.save(cullSettings, to: defaults)
        }
    }
    /// Notes from the last cull action per shoot (e.g. why an undo failed).
    private(set) var cullNotes: [UUID: String] = [:]
    @ObservationIgnored let claude: any ClaudeRunner
    @ObservationIgnored let photoAnalyzer: any PhotoAnalyzer
    @ObservationIgnored let cullApplier: any CullApplying
    @ObservationIgnored let cullWorkspaceRoot: URL
    @ObservationIgnored fileprivate var cullTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored fileprivate let cullWaiters = CullWaiters()
    /// The app-wide mutex for anything that moves or reads files being moved: cull apply/undo, and each sync-loop job.
    @ObservationIgnored fileprivate var applyLockHeld = false
    /// True while a cull apply/undo holds the mutex: ingest queues behind it.
    @ObservationIgnored fileprivate var cullApplying = false
    /// Most relevant run per shoot, read from the primary's journal by `loadLastCullRun`.
    private(set) var cullLastRuns: [UUID: CullRunSummary] = [:]

    init(registryURL: URL = ShootStore.defaultURL(),
         thumbnails: any ThumbnailProvider = QLThumbnailProvider(),
         defaults: UserDefaults = .standard,
         claude: any ClaudeRunner = ClaudeCLIRunner(),
         photoAnalyzer: any PhotoAnalyzer = ImageIOPhotoAnalyzer(),
         cullApplier: any CullApplying = LiveCullApplier(),
         cullWorkspaceRoot: URL = CullWorkspace.defaultRoot) {
        self.defaults = defaults
        self.claude = claude
        self.photoAnalyzer = photoAnalyzer
        self.cullApplier = cullApplier
        self.cullWorkspaceRoot = cullWorkspaceRoot
        self.cullSettings = CullSettingsStore.load(from: defaults)
        self.registryURL = registryURL
        self.checksums = ChecksumStore(url: registryURL.deletingLastPathComponent().appendingPathComponent("checksums.json"))
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
        let metaURL = syncMetaURL
        startupLoad = Task {
            await checksums.load()
            let saved = await Task.detached { SyncMetaStore.load(from: metaURL) }.value
            for (id, date) in saved where lastDeepVerify[id] == nil { lastDeepVerify[id] = date }
        }
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
            includeDuplicatePlans.remove(card.id)
            dequeue(card)
            recomputePending.remove(card.id)
        }
        if let shown = shootSheetCard, gone.contains(where: { $0 === shown }) {
            shootSheetCard = nil
            if shootSheet == .create { shootSheet = nil }
        }
        if case .add(_, let cardID?) = shootSheet, gone.contains(where: { $0.id == cardID }) { shootSheet = nil }
        cards.removeAll { card in gone.contains { $0 === card } }
        if let browsing = browsingCardID, !cards.contains(where: { $0.id == browsing }) { browsingCardID = nil }

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
        card.mirrorNote = nil
        card.backups = [:]
        // The file list is about to change: any coverage computed from it is stale.
        cancelCoverage { $0.cardID == card.id }
        invalidateBrowserMembership(for: card)
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
        addTargets[card.id] = nil
        includeDuplicatePlans.remove(card.id)
        dequeue(card)
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
        invalidateBrowserMembership(for: card)

        // No media, or a scan error: never verify, never backed.
        if let phase = CardPhase.afterScan(fileCount: card.files.count, error: card.scanError) {
            card.missing = card.files
            card.backups = [:]
            card.plan = nil
            dequeue(card)
            card.phase = phase
            refreshBrowserMembership()
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
        recomputePending.insert(card.id)
        // Never leave a stale green up while re-checking (in the header or the card browser).
        if card.phase == .backed { card.phase = .scanning; card.backups = [:] }
        Task {
            // Any registered, online shoot counts as a backup location ("any shoot counts"). Built off
            // main; card files never count as candidates for themselves.
            let candidates = await Self.backupCandidates(base: candidates, shootFolders: shootFolders,
                                                         cardVolumes: cardVolumes, workVolume: workVolume)
            // Triage stats every candidate on disk, so it runs off the main actor.
            let triage = await BackupVerifier.triageOffMain(files: card.files, candidates: candidates, cache: verifications)
            // Superseded by a copy, a new plan, a rescan or a newer recompute.
            guard card.recomputeGeneration == generation else { return }
            recomputePending.remove(card.id)
            guard card.engine == nil, card.phase != .copying else { return }
            settle(card, triage: triage, candidates: candidates, driveReady: driveReady)
        }
    }

    private func settle(_ card: Card, triage: (settled: [URL: VerifyResult], toVerify: [MediaFile]), candidates: [String: [URL]], driveReady: Bool) {
        let allVerified = triage.toVerify.isEmpty && card.files.allSatisfy { triage.settled[$0.url]?.isVerified == true }
        if indexing && driveReady && !allVerified {
            card.phase = .scanning
            card.backups = [:]
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

    /// Folders of every online copy of every registered shoot, mirrors included (no I/O). A card file
    /// verified only in a mirror counts as backed up.
    private func onlineShootFolders() -> [URL] {
        shoots.flatMap { item -> [URL] in
            if case .online(let shoot)? = item.availability { return shoot.copies.map(\.standardizedFileURL) }
            return []
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
        recomputePending.remove(card.id)
    }

    /// Every path that stops the verifier (and its triage) and then settles the card itself, instead of
    /// letting `finishRecompute` run, must end here so the browser's membership leaves `.checking`.
    private func cardSettledAfterStop(_ card: Card) {
        if card.id == browsingCardID { refreshBrowserMembership() }
    }

    private func finishRecompute(_ card: Card, results: [URL: VerifyResult]) {
        // Every exit: the card may have settled. A plain refresh restarts the run only when its inputs
        // (files, verdict, session copies, shoots) changed or the run was stopped.
        // A queued card was re-verified because the copy it waited for finished: start it now (it re-queues
        // if another copy is still in the way), so the twins that just landed are pruned from its plan.
        defer {
            if card.id == browsingCardID { refreshBrowserMembership() }
            if card.queuedBehind != nil, card.engine == nil, !addInFlight.contains(card.id) { copy(card) }
        }
        card.missing = BackupVerifier.missing(files: card.files, results: results)
        card.backups = results.compactMapValues { if case .verified(let copy) = $0 { copy } else { nil } }
        guard let phase = CardPhase.afterVerify(fileCount: card.files.count, missingCount: card.missing.count,
                                                hasPlan: card.plan != nil, current: card.phase) else { return }
        if phase == .backed {
            // A pending plan (add-footage or a chosen folder) survives a backed verdict; its jobs are
            // pruned against the verdict when the copy starts.
            if card.plan != nil {
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

    private struct PhaseError: LocalizedError {
        var errorDescription: String? { "This card can't start a new shoot right now." }
    }

    private func canPlan(_ card: Card) -> Bool {
        switch card.phase {
        case .needsBackup, .ready, .failed: true
        default: false
        }
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
        let skipped = card.files.count - card.missing.count
        var message = "Choose where \(card.name)'s \(card.missing.count) files should go."
        if skipped > 0 { message += " \(skipped) files already backed up are skipped." }
        panel.message = message
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
        dequeue(card)
        addTargets[card.id] = nil
        includeDuplicatePlans.remove(card.id)
        card.phase = .ready
        cardSettledAfterStop(card)
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
        dequeue(card)
        addTargets[card.id] = nil
        includeDuplicatePlans.remove(card.id)
        recompute(card)
    }

    func openInFinder(_ card: Card) {
        var urls = [card.volume]
        if let dest = card.plan?.destinationRoot { urls.append(dest) }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    // MARK: Copying

    func copy(_ card: Card) {
        // One engine per card.
        guard let plan = card.plan, card.engine == nil, card.phase != .copying else { return }
        // Two engines never write into overlapping folders (e.g. the same shoot) at once: wait for the other
        // one. Checked before the verifier is touched, so a waiting card keeps its state.
        let myRoots = plan.copyRoots
        if let blocker = cards.first(where: { other in
            guard other !== card, other.engine != nil, let theirs = other.plan else { return false }
            return myRoots.contains { mine in theirs.copyRoots.contains { Self.overlap(mine, $0) } }
        }) {
            enqueue(card, behind: blocker)
            return
        }
        if syncBusyOverlapping(myRoots) { enqueueBehindSync(card); return }
        if cullApplying { enqueueBehindCull(card); return }
        dequeue(card)
        card.mirrorNote = nil
        stopVerifier(card)
        if isOnCard(plan.destinationRoot) {
            card.phase = .failed(CardDestinationError().localizedDescription)
            cardSettledAfterStop(card)
            return
        }
        // Destinations and free space are checked per copy. A copy that fails is left out (marked for sync
        // afterwards) as long as another one can take the files; if none can, the card fails.
        let volumes = volumes(including: card)
        // The checks themselves run off main in the task below, with the preflight.
        let usable = currentRoots(of: plan)
        guard !usable.isEmpty else {
            card.phase = .failed("No copy folder is available.")
            cardSettledAfterStop(card)
            return
        }
        let rootChecks: [(root: URL, jobs: [CopyJob])] = usable.map { ($0, Self.jobs(in: plan.jobs, roots: [$0], of: myRoots)) }
        let freeSpaceOf = freeSpaceProvider()

        let engine = CopyEngine()
        card.engine = engine
        noteIngestStarting(roots: myRoots)
        #if DEBUG
        _testEngineHook?(engine)
        #endif
        invalidateBrowserMembership(for: card)
        let startJobs = Self.jobs(in: plan.jobs, roots: usable, of: myRoots)
        card.progress = CopyProgress(filesTotal: startJobs.count, bytesTotal: startJobs.reduce(0) { $0 + $1.file.size })
        card.phase = .copying
        let addShootID = addTargets[card.id]
        let preflightShootID = plan.shootID ?? addShootID
        let pruneDuplicates = !includeDuplicatePlans.contains(card.id)

        var prunedMarked = false
        Task {
            // Off main: every copy folder must still exist, and carry the shoot's id for an add-footage plan,
            // before a single byte is written. A copy that fails is left out while another passes.
            let checks: [(root: URL, error: String?)] = await Task.detached {
                rootChecks.map { entry in
                    do {
                        for dir in ShootPlanner.directories(for: entry.jobs) {
                            try ShootPlanner.checkDestination(dir, root: entry.root, cardVolumes: volumes)
                        }
                        let needed = entry.jobs.reduce(Int64(0)) { $0 + $1.file.size }
                        if let free = freeSpaceOf(entry.root), free < needed {
                            throw NotEnoughSpaceError(needed: needed, free: free)
                        }
                        try Self.preflight(workRoot: entry.root, shootID: preflightShootID)
                        return (entry.root, nil)
                    } catch { return (entry.root, error.localizedDescription) }
                }
            }.value
            guard card.engine === engine else { return }
            // The shoot's copies may have changed while the preflight ran.
            let stillCopies = Set(currentRoots(of: plan).map(VolumeClassifier.normalizedPath))
            let runRoots = checks.filter { $0.error == nil && stillCopies.contains(VolumeClassifier.normalizedPath($0.root)) }.map(\.root)
            guard !runRoots.isEmpty else {
                card.engine = nil
                card.phase = .failed(checks.first(where: { $0.error != nil })?.error ?? "No copy folder is available.")
                refreshBrowserMembership(force: true)
                releaseQueuedCopies()
                return
            }

            // The verdict may have changed since the plan was made (another card's copy landed): drop jobs whose
            // file now has a verified copy, unless the user asked to copy duplicates anyway.
            if pruneDuplicates {
                let backups = card.backups
                let files = plan.jobs.map(\.file)
                // No target exclusion here: a file that just landed in the target shoot (a queued card behind
                // another card's copy into the same shoot) is as done as one verified anywhere else.
                let found = IngestDuplicates.find(candidates: files, backups: backups, missing: Set(card.missing.map(\.url)),
                                                  shoots: shootRoots(), target: nil)
                let confirmed = await IngestDuplicates.revalidate(found, backups: backups, cache: verifications)
                guard card.engine === engine else { return }
                let drop = Set(confirmed.files.map(\.url))
                if !drop.isEmpty {
                    // A file verified in only some copies of the target shoot leaves the others short.
                    prunedMarked = markCopiesMissingPruned(of: card, plan: plan, dropped: confirmed.files, backups: backups)
                    card.plan?.jobs.removeAll { drop.contains($0.file.url) }
                    if card.plan?.jobs.isEmpty != false {
                        NSLog("Auto: \(card.name): everything in the plan is already backed up; nothing copied.")
                        card.plan = nil
                        addTargets[card.id] = nil
                        includeDuplicatePlans.remove(card.id)
                        card.engine = nil
                        card.phase = .needsBackup
                        recompute(card)
                        releaseQueuedCopies()
                        if prunedMarked { await saveRegistry(); await refreshShoots() }
                        return
                    }
                }
            }
            let runJobs = Self.jobs(in: card.plan?.jobs ?? plan.jobs, roots: runRoots, of: myRoots)
            card.progress = CopyProgress(filesTotal: runJobs.count, bytesTotal: runJobs.reduce(0) { $0 + $1.file.size })
            let outcome = await engine.run(runJobs) { progress in card.progress = progress }
            card.engine = nil
            // A file with a failed checksum on any copy, or copies that disagree, is not done: its jobs stay.
            let blocked = Self.integrityBlocked(outcome)
            let landedFiles = outcome.copied.filter { !blocked.contains($0.file.url) }
            // Seed the checksum cache from the verified copies, off main and without waiting for it.
            let store = checksums
            Task.detached {
                for copied in landedFiles { store.record(copied) }
                await store.saveIfDirty()
            }
            sessionCopies.append(contentsOf: landedFiles)
            verifications.record(landedFiles)

            // A file is done once it reached at least one copy; the others are marked for sync.
            let done = Set(landedFiles.map(\.file.url))
            let marked = markUnreachedCopies(of: card, plan: plan, runRoots: runRoots, outcome: outcome, done: done, blocked: blocked)
                || prunedMarked
            card.plan?.jobs.removeAll { done.contains($0.file.url) }
            // Just-copied files must not be selectable again while they re-verify.
            card.missing.removeAll { done.contains($0.url) }
            if card.plan?.jobs.isEmpty == true { card.plan = nil }
            // The add target lives as long as the plan does (partial failures retry into the same shoot).
            if card.plan == nil { addTargets[card.id] = nil; includeDuplicatePlans.remove(card.id) }
            let reachedLabels = Self.unique(runRoots.filter { root in outcome.copied.contains { ShootPlanner.isInside($0.destination, root: root) } }
                .map { Self.copyLabel($0.path) })
            if myRoots.count > 1, !reachedLabels.isEmpty {
                card.backedTo = reachedLabels.joined(separator: " and ")
            } else {
                card.backedTo = plan.destinationRoot.path.hasPrefix(workingVolume?.path ?? "\u{0}") ? workingDriveName : plan.destinationLabel
            }
            // Flat plans into a folder inside a shoot copy leave that shoot's other copies short.
            let flatMarked = plan.shootID == nil && markShootsContaining(plan.destinationRoot, card: card, done: done)

            // Failures of files that reached no copy fail the card. A mirror failing for a file that did land is a sync matter.
            var blocking = outcome.failures.filter { !done.contains($0.file) }
            for url in blocked where !blocking.contains(where: { $0.file == url }) {
                blocking.append(.init(name: url.lastPathComponent, reason: "Its copies didn't match each other", file: url, root: nil, kind: .integrity))
            }
            if let first = blocking.first {
                let more = blocking.count > 1 ? " (+\(blocking.count - 1) more)" : ""
                card.phase = .failed("\(first.name): \(first.reason)\(more)")
            } else {
                card.phase = .needsBackup
            }
            // A failed card stays failed on screen (Retry copies again); a re-verify would turn it back into "ready".
            if blocking.isEmpty { recompute(card) }
            // This copy may make other cards' files duplicates (or fully backed): re-verify idle cards.
            let copiedKeys = Set(outcome.copied.map(\.file.key))
            for other in cards where other !== card && !copyQueue.contains(other.id) && needsRecompute(other, afterCopyOf: copiedKeys) {
                if addInFlight.contains(other.id) { recomputeAfterAdd.insert(other.id) } else { recompute(other) }
            }
            releaseQueuedCopies()
            // Anything that landed inside a registered shoot changes that shoot's coverage.
            let landed = shoots.filter { item in
                if case .online(let shoot)? = item.availability {
                    return shoot.copies.contains { ShootPlanner.relativeComponents(plan.destinationRoot, to: $0) != nil }
                }
                return false
            }
            for item in landed { checkCoverage(shootID: item.id, cardID: card.id) }
            // Another card's copy landing in a shoot changes the browsed card's membership too.
            if !landed.isEmpty, card.id != browsingCardID { refreshBrowserMembership(force: true) }
            if marked || flatMarked { await saveRegistry() }
            if !landed.isEmpty || marked || flatMarked { await refreshShoots() }
            // The copies of a shoot that just received files may now differ: check them (forced).
            var toCheck = Set(landed.map(\.id))
            if !outcome.copied.isEmpty {
                // Includes flat Choose Folder plans whose root is inside any copy (not only the primary).
                let written = plan.copyRoots + [plan.destinationRoot]
                for item in shoots {
                    guard case .online(let shoot)? = item.availability else { continue }
                    if shoot.copies.contains(where: { copy in written.contains { Self.overlap($0, copy) } }) { toCheck.insert(item.id) }
                }
            }
            if !outcome.copied.isEmpty, let shootID = plan.shootID { toCheck.insert(shootID) }
            if !toCheck.isEmpty { scheduleSyncCheck(toCheck, force: true) }
            if !outcome.cancelled { openMainWindow() }
        }
    }

    // MARK: Copy queue

    private func enqueue(_ card: Card, behind other: Card) {
        if !copyQueue.contains(card.id) { copyQueue.append(card.id) }
        card.queuedBehind = other.id
        card.queueNote = "Waiting for \(other.name) to finish"
    }

    /// Takes a card out of the queue (it keeps its plan and phase). Safe to call for any card.
    private func dequeue(_ card: Card) {
        copyQueue.removeAll { $0 == card.id }
        card.queuedBehind = nil
        card.queueNote = nil
    }

    /// An engine just ended. Re-verify each waiting card, since the copy that finished may have made its files
    /// duplicates; `finishRecompute` then starts it (and `copy` prunes the twins from its plan).
    private func releaseQueuedCopies() {
        cullWaiters.wake()
        flushDeferredSyncChecks()
        for id in copyQueue {
            guard let queued = cards.first(where: { $0.id == id }) else { copyQueue.removeAll { $0 == id }; continue }
            guard queued.engine == nil else { continue }
            if addInFlight.contains(id) { recomputeAfterAdd.insert(id) } else { recompute(queued) }
        }
    }

    nonisolated private struct NotEnoughSpaceError: LocalizedError {
        let needed: Int64
        let free: Int64
        var errorDescription: String? { "Not enough space: needs \(Format.bytes(needed)), \(Format.bytes(free)) free." }
    }

    private static func overlap(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL == b.standardizedFileURL || ShootPlanner.isInside(a, root: b) || ShootPlanner.isInside(b, root: a)
    }

    /// The jobs that write to `roots`. A single-root plan (flat folder, legacy) uses all jobs.
    private static func jobs(in jobs: [CopyJob], roots: [URL], of all: [URL]) -> [CopyJob] {
        guard all.count > 1 else { return jobs }
        let keys = Set(roots.map(VolumeClassifier.normalizedPath))
        return jobs.filter { job in job.root.map { keys.contains(VolumeClassifier.normalizedPath($0)) } ?? false }
    }

    nonisolated private static func copyLabel(_ path: String) -> String {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : "This Mac"
    }

    /// After a run in which something landed: every copy of the shoot that did not get every landed file (offline,
    /// left out before the run, or failed during it) is marked `pendingSync`, and the card says so. Returns
    /// whether the registry changed (the caller saves it).
    private func markUnreachedCopies(of card: Card, plan: CopyPlan, runRoots: [URL], outcome: CopyOutcome,
                                     done: Set<URL>, blocked: Set<URL>) -> Bool {
        guard !done.isEmpty, let shootID = plan.shootID, let record = registry.records.first(where: { $0.id == shootID }) else { return false }
        let ran = Set(runRoots.map(VolumeClassifier.normalizedPath))
        var short = record.copyPaths.filter { !ran.contains(VolumeClassifier.normalizedPath(URL(fileURLWithPath: $0))) }
        var reached: [String] = []
        for root in runRoots {
            let landed = Set(outcome.copied.filter { !blocked.contains($0.file.url) && ShootPlanner.isInside($0.destination, root: root) }.map(\.file.url))
            if done.isSubset(of: landed) { reached.append(Self.copyLabel(root.path)) } else { short.append(root.path) }
        }
        guard !short.isEmpty else { return false }
        for path in short { registry.setPendingSync(id: shootID, path: path, true) }
        let missing = Self.unique(short.map(Self.copyLabel)).joined(separator: " and ")
        card.mirrorNote = reached.isEmpty
            ? "\(missing) didn't get every file; sync the shoot when it's connected."
            : "Copied to \(Self.unique(reached).joined(separator: " and ")). \(missing) wasn't updated; sync the shoot when it's connected."
        return true
    }

    nonisolated private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Files that must stay in the plan: a checksum/size failure on any copy, or copies whose source checksums differ.
    nonisolated static func integrityBlocked(_ outcome: CopyOutcome) -> Set<URL> {
        var blocked = Set(outcome.failures.filter { $0.kind == .integrity }.map(\.file))
        var seen: [URL: Data] = [:]
        for copied in outcome.copied {
            guard let sum = copied.checksum else { continue }
            if let earlier = seen[copied.file.url], earlier != sum { blocked.insert(copied.file.url) } else { seen[copied.file.url] = sum }
        }
        return blocked
    }

    private func cmpKey(_ path: String) -> String {
        VolumeClassifier.normalizedPath(URL(fileURLWithPath: path)).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The plan's copy roots that are still copies of its shoot (a copy removed or moved since planning is dropped).
    /// Plans without a shoot keep all roots.
    private func currentRoots(of plan: CopyPlan) -> [URL] {
        guard let id = plan.shootID else { return plan.copyRoots }
        guard let record = registry.records.first(where: { $0.id == id }) else { return [] }
        let current = Set(record.copyPaths.map(cmpKey))
        return plan.copyRoots.filter { current.contains(cmpKey($0.path)) }
    }

    /// Free bytes on the volume holding `url` (nil: unknown). Injectable for tests.
    /// The free-space lookup to use off main (the test fake in DEBUG builds).
    private func freeSpaceProvider() -> @Sendable (URL) -> Int64? {
        #if DEBUG
        if let fake = _testFreeSpace {
            nonisolated(unsafe) let hook = fake // test-only closure; tests pass pure functions
            return { hook($0) }
        }
        #endif
        return { Self.diskFreeSpace($0) }
    }

    nonisolated private static func diskFreeSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Copy-time pruning dropped files already verified inside a copy of the target shoot: every other copy of
    /// that shoot lacks them, so mark those copies for sync.
    private func markCopiesMissingPruned(of card: Card, plan: CopyPlan, dropped: [MediaFile], backups: [URL: URL]) -> Bool {
        guard let id = plan.shootID, let record = registry.records.first(where: { $0.id == id }) else { return false }
        let roots = record.copyPaths
        var short = Set<String>()
        for file in dropped {
            guard let copy = backups[file.url] else { continue }
            let path = VolumeClassifier.normalizedPath(copy)
            guard let holder = roots.first(where: { path.hasPrefix(VolumeClassifier.normalizedPath(URL(fileURLWithPath: $0)) + "/") }) else { continue }
            for other in roots where cmpKey(other) != cmpKey(holder) { short.insert(other) }
        }
        guard !short.isEmpty else { return false }
        for path in roots where short.contains(path) { registry.setPendingSync(id: id, path: path, true) }
        let names = Self.unique(roots.filter { short.contains($0) }.map(Self.copyLabel)).joined(separator: " and ")
        card.mirrorNote = "\(names) is missing files already in this shoot; sync the shoot when it's connected."
        return true
    }

    /// A flat copy into a folder inside one copy of a registered shoot: that shoot's other copies lack the files.
    private func markShootsContaining(_ root: URL, card: Card, done: Set<URL>) -> Bool {
        guard !done.isEmpty else { return false }
        var changed = false
        var names: [String] = []
        for record in registry.records {
            let holders = record.copyPaths.filter { ShootPlanner.relativeComponents(root, to: URL(fileURLWithPath: $0)) != nil }
            guard !holders.isEmpty else { continue }
            let holderKeys = Set(holders.map(cmpKey))
            for other in record.copyPaths where !holderKeys.contains(cmpKey(other)) {
                registry.setPendingSync(id: record.id, path: other, true)
                names.append(Self.copyLabel(other))
                changed = true
            }
        }
        if changed {
            card.mirrorNote = "\(Self.unique(names).joined(separator: " and ")) wasn't updated; sync the shoot when it's connected."
        }
        return changed
    }

    /// Whether a card is copying into `shootID` right now (the sheet warns that its files will be skipped).
    func isCopyingInto(shootID: UUID) -> Card? {
        cards.first { $0.engine != nil && addTargets[$0.id] == shootID }
    }

    /// A card is copying into, or queued to copy into, `shootID`, or Sync Now is running for it: its copies can't be
    /// removed or moved.
    private func hasActiveCopy(into shootID: UUID) -> Bool {
        syncActive.contains(shootID) || hasActiveIngest(into: shootID)
    }

    private func hasActiveIngest(into shootID: UUID) -> Bool {
        cards.contains { ($0.engine != nil || $0.queuedBehind != nil) && ($0.plan?.shootID == shootID || addTargets[$0.id] == shootID) }
    }

    /// Why the copies of `shootID` can't be removed or moved right now (nil: they can).
    private func copyOpBlock(for shootID: UUID) -> Error? {
        if hasActiveIngest(into: shootID) { return ShootBusyError() }
        if syncActive.contains(shootID) { return SyncBusyError() }
        return nil
    }

    /// Whether another card's verdict can change because files with `copiedKeys` (name+size) just landed:
    /// it has no engine, isn't copying or backed, and some missing file shares a key. A running verifier is
    /// fine: recompute restarts it, and the verification cache keeps what it already proved.
    private func needsRecompute(_ card: Card, afterCopyOf copiedKeys: Set<String>) -> Bool {
        guard card.engine == nil else { return false }
        switch card.phase {
        case .copying, .backed: return false
        case .scanning: guard recomputePending.contains(card.id) else { return false }
        default: break
        }
        return card.missing.contains { copiedKeys.contains($0.key) }
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

    /// Stops a running copy, or takes a waiting card out of the queue (it stays ready with its plan).
    func stop(_ card: Card) {
        dequeue(card)
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
    // MARK: Browser membership

    fileprivate struct MembershipInputs: Equatable {
        let cardID: Card.ID
        let files: [MediaFile]
        let targets: [ShootMembership.Target]
        let backups: [URL: URL]
        let missing: Set<URL>
        let sessionCopies: [URL]
    }

    /// The browser for `cardID` is on screen.
    func browserAppeared(_ cardID: Card.ID) {
        browserOnScreen = cardID
        refreshBrowserMembership()
    }

    /// Clears only when `cardID` is still the one on screen (a swapped-in browser may have appeared first).
    func browserDisappeared(_ cardID: Card.ID) {
        guard browserOnScreen == cardID else { return }
        browserOnScreen = nil
        refreshBrowserMembership()
    }

    private func onlineMembershipTargets() -> [ShootMembership.Target] {
        shoots.compactMap { item in
            if case .online(let shoot)? = item.availability {
                return ShootMembership.Target(id: item.id, folder: shoot.folder.standardizedFileURL)
            }
            return nil
        }
    }

    private func stopMembership() {
        membershipTask?.cancel()
        membershipTask = nil
        membershipGeneration += 1
        membershipInputs = nil
    }

    private func markMembershipChecking(_ targets: [ShootMembership.Target]) {
        browserMembership = Dictionary(targets.map { ($0.id, BrowserMembershipState.checking) }) { $1 }
    }

    /// The card is about to change under the browser: drop the running check and show "checking".
    private func invalidateBrowserMembership(for card: Card) {
        guard mainWindowVisible, card.id == browsingCardID, browserOnScreen == card.id else { return }
        stopMembership()
        markMembershipChecking(onlineMembershipTargets())
    }

    /// Starts, restarts or clears the browser's per-shoot membership check for the browsed card.
    /// Read-only; results are stored only when complete and still current.
    func refreshBrowserMembership(force: Bool = false) {
        guard mainWindowVisible, let card = browsingCard, browserOnScreen == card.id else {
            stopMembership()
            if !browserMembership.isEmpty { browserMembership = [:] }
            return
        }
        switch card.phase {
        case .empty, .unreadable:
            stopMembership()
            if !browserMembership.isEmpty { browserMembership = [:] }
            return
        default: break
        }
        let targets = onlineMembershipTargets()
        let settled: Bool
        switch card.phase {
        case .needsBackup, .ready, .backed, .failed:
            settled = card.engine == nil && card.verifier == nil && !recomputePending.contains(card.id)
        default: settled = false
        }
        guard settled else {
            stopMembership()
            markMembershipChecking(targets)
            return
        }
        let inputs = MembershipInputs(cardID: card.id, files: card.files, targets: targets, backups: card.backups,
                                      missing: Set(card.missing.map(\.url)), sessionCopies: sessionCopies.map(\.destination))
        if !force, membershipInputs == inputs {
            let finished = targets.allSatisfy { target in
                switch browserMembership[target.id] {
                case .done?, .failed?: true
                default: false
                }
            }
            if membershipTask != nil || finished { return }
        }

        membershipTask?.cancel()
        membershipGeneration += 1
        let generation = membershipGeneration
        membershipInputs = inputs
        markMembershipChecking(targets)
        guard !targets.isEmpty else { membershipTask = nil; return }
        let cardID = card.id
        let files = card.files
        let copies = sessionCopies
        let cache = verifications
        let volumes = cardVolumes()
        #if DEBUG
        let runner = _testMembershipRunner
        #endif
        membershipTask = Task {
            #if DEBUG
            if let runner {
                await runner(files, targets) { [self] id, outcome in deliverMembership(id, outcome, generation: generation, cardID: cardID) }
                if generation == membershipGeneration { membershipTask = nil }
                return
            }
            #endif
            await ShootMembership.run(files: files, targets: targets, sessionCopies: copies, cache: cache,
                                      cardVolumes: volumes) { [self] id, outcome in
                deliverMembership(id, outcome, generation: generation, cardID: cardID)
            }
            if generation == membershipGeneration { membershipTask = nil }
        }
    }

    /// Superseded, or the user moved to another card: never store a stale result.
    private func deliverMembership(_ id: UUID, _ outcome: ShootMembership.Outcome, generation: Int, cardID: Card.ID) {
        guard generation == membershipGeneration, browsingCardID == cardID else { return }
        switch outcome {
        case .verified(let urls, let copies): browserMembership[id] = .done(urls, copies: copies)
        case .failed(let reason): browserMembership[id] = .failed(reason)
        }
    }

    #if DEBUG
    /// Test seam: replaces `ShootMembership.run`, so a test can deliver a result after supersession.
    typealias MembershipRunner = @Sendable ([MediaFile], [ShootMembership.Target],
                                            @escaping @MainActor @Sendable (UUID, ShootMembership.Outcome) -> Void) async -> Void
    func _testSetMembershipRunner(_ runner: MembershipRunner?) { _testMembershipRunner = runner }
    func _testBrowserMembershipIdle() async { await membershipTask?.value }
    #endif

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
                    mirrors: shoot.mirrors.map { $0.standardizedFileURL.path }, lastSeen: Date())
    }

    private func register(_ shoot: Shoot) async {
        registry.add(record(for: shoot))
        await saveRegistry()
        await refreshShoots()
    }

    /// Creates `<parent>/<name>` with its sidecar and registers it.
    @discardableResult
    func createShoot(name: String, date: Date, parent: URL) async throws -> Shoot {
        try await createShoot(name: name, date: date, parents: [parent])
    }

    /// Creates the shoot in `parents[0]` and a mirror in each further parent (all must be on distinct
    /// drives). If a mirror can't be made nothing is rolled back: the shoot registers with the copies
    /// that exist and `ShootError.partialCreate` is thrown.
    @discardableResult
    func createShoot(name: String, date: Date, parents: [URL]) async throws -> Shoot {
        guard !parents.isEmpty else { throw ShootError.parentMissing }
        let volumes = cardVolumes()
        let calendar = calendar
        let provider = volumeIDProvider
        let registered = registry.records.flatMap(\.copyPaths)
        let outcome = try await Task.detached {
            try Self.createCopies(name: name, date: date, parents: parents, cardVolumes: volumes,
                                  calendar: calendar, registered: registered, volumeID: provider)
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
    nonisolated private static func driveLabel(_ url: URL) -> String {
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
                                                 volumeID: @Sendable (URL) -> String?) throws -> CreateOutcome {
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
        var shoot = try ShootFolders.create(name: name, date: date, parent: parents[0], cardVolumes: cardVolumes, calendar: calendar)
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

    struct AllDuplicatesError: LocalizedError {
        var errorDescription: String? {
            "All selected files are already backed up. Turn on Copy duplicates anyway to copy them again."
        }
    }

    struct ShootBusyError: LocalizedError {
        var errorDescription: String? { "Another card is copying into this shoot. Try again when it finishes." }
    }

    struct SyncBusyError: LocalizedError {
        var errorDescription: String? { "Sync Now is running for this shoot. Try again when it finishes." }
    }

    /// Every shoot with all of its copy roots (primary plus mirrors).
    private func shootRoots() -> [IngestDuplicates.ShootRoots] {
        shoots.map { item in
            // A mismatched copy is not this shoot; a same-volume one is not a separate copy. Neither is a place.
            let excluded = Set(item.copies.compactMap { state -> String? in
                switch state.availability {
                case .mismatch, .sameVolume: state.path
                default: nil
                }
            })
            return IngestDuplicates.ShootRoots(id: item.id, name: item.record.name,
                                               roots: item.record.copyPaths.filter { !excluded.contains($0) }
                                                   .map { URL(fileURLWithPath: $0) })
        }
    }

    /// Card files (or `candidates`, e.g. the current selection) that already have a verified copy somewhere
    /// other than `shootID`. Synchronous and cheap: reads the card's verdict, no I/O and no revalidation.
    /// The count is provisional until the (shoot, card) coverage is `.done`; once it is, files already
    /// verified inside the target shoot are excluded first, as `addFootage` does.
    func duplicates(shootID: UUID?, cardID: Card.ID, candidates: [MediaFile]? = nil) -> IngestDuplicates.Report {
        guard let card = cards.first(where: { $0.id == cardID }) else { return IngestDuplicates.Report() }
        var files = candidates ?? card.files
        if let shootID, case .done(let covered)? = coverage[CoverageKey(shootID: shootID, cardID: cardID)] {
            let notIn = Set(covered.notInShoot.map(\.url))
            files = files.filter { notIn.contains($0.url) }
        }
        return IngestDuplicates.find(candidates: files, backups: card.backups, missing: Set(card.missing.map(\.url)),
                                     shoots: shootRoots(), target: shootID)
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
            guard let card = cards.first(where: { $0.id == cardID }) else {
                addTargets[cardID] = nil
                includeDuplicatePlans.remove(cardID)
                continue
            }
            guard card.engine == nil else { continue }
            addTargets[cardID] = nil
            includeDuplicatePlans.remove(cardID)
            card.plan = nil
            dequeue(card)
            if card.phase == .ready { recompute(card) }
        }
    }

    /// Plans a copy of the selected files that are not yet verified inside the shoot into the shoot folder
    /// (Video/Photo/<camera>). Re-reads the sidecar and runs a fresh coverage check first, so it never
    /// plans from a stale snapshot. The user then starts it with `copy(_:)`.
    /// `onlyFiles`: when set, only these card files (by URL) are considered, on top of `selection`.
    func addFootage(shootID: UUID, cardID: Card.ID, cameras: [Camera], selection: ShootSelection,
                    onlyFiles: Set<URL>? = nil, includeDuplicates: Bool = false) async throws {
        guard let item = shoots.first(where: { $0.id == shootID }), let card = cards.first(where: { $0.id == cardID }) else {
            throw UnknownTargetError()
        }
        guard case .online(let shoot)? = item.availability else { throw ShootError.shootOffline }
        guard canAddFootage(card) else { throw PhaseError() }
        // A card with no plan at entry must still have none after every await (e.g. a Choose Folder plan).
        let planWasNil = card.plan == nil
        addInFlight.insert(cardID)
        defer {
            addInFlight.remove(cardID)
            if recomputeAfterAdd.remove(cardID) != nil, cards.contains(where: { $0 === card }), card.engine == nil { recompute(card) }
        }
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
        if planWasNil, card.plan != nil { throw PendingPlanError() }
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
        if planWasNil, card.plan != nil { throw PendingPlanError() }

        var wanted = selection.filter(covered.notInShoot).filter { onlyFiles?.contains($0.url) ?? true }
        if !includeDuplicates, !wanted.isEmpty {
            let backups = card.backups
            let found = IngestDuplicates.find(candidates: wanted, backups: backups, missing: Set(card.missing.map(\.url)),
                                              shoots: shootRoots(), target: shootID)
            // Off main: a duplicate whose verified copy vanished or changed is a normal file again.
            let confirmed = await IngestDuplicates.revalidate(found, backups: backups, cache: verifications)
            guard cards.contains(where: { $0 === card }), card.files == snapshot, canAddFootage(card),
                  case .online(let latest2)? = shoots.first(where: { $0.id == shootID })?.availability, latest2.folder == folder else {
                throw CoverageUnavailableError()
            }
            if planWasNil, card.plan != nil { throw PendingPlanError() }
            let drop = Set(confirmed.files.map(\.url))
            if !drop.isEmpty {
                wanted.removeAll { drop.contains($0.url) }
                if wanted.isEmpty { throw AllDuplicatesError() }
            }
        }
        // Every online copy gets the files. No await from here to the plan, so the copies can't change underneath.
        guard case .online(let live)? = shoots.first(where: { $0.id == shootID })?.availability, live.folder == folder else {
            throw ShootError.shootOffline
        }
        let jobs = ShootPlanner.jobs(missing: wanted, copies: live.copies, cameras: cameras, fallback: card.name)
        guard !jobs.isEmpty else { throw EmptySelectionError() }
        guard jobs.allSatisfy({ job in job.root.map { ShootPlanner.isInside(job.destDir, root: $0) } ?? false }) else {
            throw ShootPlanner.PathError.outsideWorkFolder
        }
        let cardVolumes = volumes(including: card)
        // The primary must be usable. A mirror that can't take its folders is left out; it is marked for sync after the copy.
        // Directories are created off main; state is re-checked after the await.
        let perRoot: [(root: URL, dirs: [URL])] = ([folder] + live.mirrors).map { root in
            (root, ShootPlanner.directories(for: jobs.filter { $0.root == root }))
        }
        let created: [(root: URL, error: Error?)] = await Task.detached {
            perRoot.map { entry in
                do { try ShootPlanner.createDirectories(entry.dirs, root: entry.root, cardVolumes: cardVolumes); return (entry.root, nil) }
                catch { return (entry.root, error) }
            }
        }.value
        if let primaryError = created.first?.error { throw primaryError }
        guard cards.contains(where: { $0 === card }), canAddFootage(card),
              case .online(let after)? = shoots.first(where: { $0.id == shootID })?.availability, after.folder == folder else {
            throw CoverageUnavailableError()
        }
        if planWasNil, card.plan != nil { throw PendingPlanError() }
        var roots = [folder]
        for entry in created.dropFirst() {
            if let error = entry.error {
                NSLog("Auto: skipping copy \(entry.root.path) for this ingest: \(error.localizedDescription)")
            } else if after.mirrors.contains(entry.root) {
                roots.append(entry.root)
            }
        }
        stopVerifier(card)
        dequeue(card)
        card.plan = ShootPlanner.plan(jobs: jobs.filter { job in roots.contains { $0 == job.root } }, shoot: folder, workRoot: folder,
                                      roots: roots, shootID: shootID)
        addTargets[cardID] = shootID
        if includeDuplicates { includeDuplicatePlans.insert(cardID) } else { includeDuplicatePlans.remove(cardID) }
        card.phase = .ready
        cardSettledAfterStop(card)
        shootSheet = nil
        shootSheetCard = nil
    }

    struct ShootCoverageError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Card browser: plans and starts a copy of exactly `urls` (minus anything already verified in the
    /// shoot) into the shoot, through the same checks as the Add Footage sheet.
    func addFiles(_ urls: Set<URL>, from cardID: Card.ID, toShoot shootID: UUID, includeDuplicates: Bool = false) async throws {
        guard let card = cards.first(where: { $0.id == cardID }) else { throw UnknownTargetError() }
        // Never replace a copy the user already has waiting on this card.
        guard card.plan == nil else { throw PendingPlanError() }
        let chosen = card.files.filter { urls.contains($0.url) }
        guard !chosen.isEmpty else { throw EmptySelectionError() }
        let selection = ShootSelection(missing: chosen, cameras: card.cameras, calendar: calendar)
        // addFootage closes the sheets for its own flow; an unrelated open sheet should survive this one.
        let sheet = shootSheet, sheetCard = shootSheetCard
        try await addFootage(shootID: shootID, cardID: cardID, cameras: card.cameras, selection: selection, onlyFiles: urls,
                                  includeDuplicates: includeDuplicates)
        shootSheet = sheet
        shootSheetCard = sheetCard
        copy(card)
    }

    private struct PendingPlanError: LocalizedError {
        var errorDescription: String? { "This card already has a copy waiting. Copy or discard it first." }
    }

    /// Shows files in Finder (read-only).
    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Opens the Quick Look panel on `urls`, starting at `index` (read-only). With `toggle` (Space),
    /// a press while the panel is up closes it, like Finder; explicit opens always switch to `urls`.
    func quickLook(_ urls: [URL], at index: Int = 0, toggle: Bool = false) {
        if toggle, QuickLookPreviewer.shared.isVisible {
            QuickLookPreviewer.shared.close()
        } else {
            QuickLookPreviewer.shared.show(urls, at: index)
        }
    }

    /// Preview for one file in the card browser (read-only QuickLook; nil when none can be made).
    /// Keyed by file identity (card + path + size + mtime), so a different card with the same volume
    /// name and file names never shows this card's pictures.
    func fileThumbnail(for file: MediaFile) async -> CGImage? {
        let key = file.identity
        if let cached = fileThumbnails[key] { return cached }
        if missingThumbnails.contains(key) { return nil }
        let image: CGImage
        do {
            image = try await thumbnails.thumbnail(for: file.url, maxPixels: 320)
        } catch {
            if !(error is CancellationError) && !Task.isCancelled { missingThumbnails.insert(key) }
            return nil
        }
        if fileThumbnails.count >= 300 { fileThumbnails.removeAll() }
        fileThumbnails[key] = image
        return image
    }

    #if DEBUG
    func _testVolumesChanged(cards urls: [URL]) { volumesChanged(cards: urls, drives: [], mountedNew: false) }
    func _testInsert(card: Card) { cards.append(card) }
    #endif
}

/// Runs one mirror check: `copies[0]` is the effective primary.
typealias SyncCheckRunner = @Sendable (_ copies: [URL], _ cache: ChecksumStore, _ deep: Bool,
                                       _ onSizePass: @escaping @MainActor @Sendable (ShootSyncReport) -> Void,
                                       _ progress: @escaping @MainActor @Sendable (SyncProgress) -> Void) async -> ShootSyncReport?

/// One queued check or Sync Now. Checks for the same shoot coalesce.
fileprivate struct SyncWork {
    enum Kind { case check, sync }
    var id: UUID
    var kind: Kind
    var force: Bool
    var deep: Bool
    var notBefore: ContinuousClock.Instant
}

extension AppModel {
    // MARK: Mirror sync

    nonisolated static let realSyncChecker: SyncCheckRunner = { copies, cache, deep, onSizePass, progress in
        await ShootSyncChecker.run(copies: copies, cache: cache, hasher: FileHasher(), deep: deep,
                                   onSizePass: onSizePass, progress: progress)
    }

    var syncMetaURL: URL { registryURL.deletingLastPathComponent().appendingPathComponent("sync-meta.json") }

    private static func copyKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// What the UI shows for a shoot.
    func syncBadge(for shootID: UUID) -> SyncBadge {
        func counts(_ r: ShootSyncReport) -> SyncBadge {
            .outOfSync(missing: r.missing.values.reduce(0) { $0 + $1.count }, conflicts: r.conflicts.count)
        }
        switch syncStates[shootID] {
        case nil:
            guard let record = registry.records.first(where: { $0.id == shootID }), record.copyPaths.count >= 2 else { return .none }
            return .unknown(reason: "Not checked yet")
        case .single?:
            return .none
        case .unknown(let reason)?:
            return .unknown(reason: reason)
        case .failed(let message)?:
            return .unknown(reason: message)
        case .checking(let progress, let partial)?:
            if let partial, partial.isOutOfSync { return counts(partial) }
            return .checking(progress)
        case .done(let report, let at)?:
            if let stale = staleReason(shootID, report) { return .unknown(reason: stale) }
            if report.isOutOfSync { return counts(report) }
            if report.isInSync {
                if registry.records.first(where: { $0.id == shootID })?.pendingSync.isEmpty == false {
                    return .unknown(reason: "Updating sync status…")
                }
                return .inSync(copies: report.copies.count, checkedAt: at, deepVerifiedAt: lastDeepVerify[shootID])
            }
            return .unknown(reason: "Not fully checked yet")
        case .syncing(let progress)?:
            return .syncing(progress)
        }
    }

    /// Why a finished report no longer describes the shoot (a copy went away or was added, an ingest is writing), or nil.
    private func staleReason(_ id: UUID, _ report: ShootSyncReport) -> String? {
        guard let item = shoots.first(where: { $0.id == id }) else { return "Shoot not found" }
        if item.copies.contains(where: { $0.availability != .online }) { return unknownReason(item) }
        guard case .online(let shoot)? = item.availability,
              shoot.copies.map({ Self.copyKey($0.path) }) == report.copies.map({ Self.copyKey($0.path) }) else {
            return "The copies changed · checking again"
        }
        if let checked = syncMounts[id], let now = syncCurrentMounts[id], checked != now {
            return "A drive was remounted · checking again"
        }
        if isIngesting(into: shoot.copies, shootID: id) { return "Copying footage…" }
        return nil
    }

    nonisolated static func mountIDs(_ paths: [String], _ provider: @Sendable (URL) -> String?) -> [String] {
        paths.map { provider(URL(fileURLWithPath: $0, isDirectory: true)) ?? "?" }
    }

    /// A card is about to write into these roots: checks of the overlapping shoots are stale, so cancel them.
    fileprivate func noteIngestStarting(roots: [URL]) {
        for item in shoots {
            guard item.record.copyPaths.contains(where: { path in roots.contains { Self.overlap($0, URL(fileURLWithPath: path)) } }) else { continue }
            let id = item.id
            guard item.record.copyPaths.count >= 2 else { continue }
            syncGenerations[id, default: 0] += 1
            if let running = syncRunning, running.id == id { running.task.cancel() }
            syncWork.removeAll { $0.id == id && $0.kind == .check }
            syncStates[id] = .unknown("Copying footage…")
            syncDeferred.insert(id)
        }
    }

    fileprivate func flushDeferredSyncChecks() {
        guard !syncDeferred.isEmpty else { return }
        let ids = syncDeferred
        syncDeferred = []
        scheduleSyncCheck(ids, force: true)
    }

    fileprivate func syncBusyOverlapping(_ roots: [URL]) -> Bool {
        syncActive.contains { id in
            guard let item = shoots.first(where: { $0.id == id }) else { return false }
            return item.record.copyPaths.contains { path in roots.contains { Self.overlap($0, URL(fileURLWithPath: path)) } }
        }
    }

    /// Queued behind a Sync Now rather than another card (`queuedBehind` points at the card itself).
    fileprivate func enqueueBehindSync(_ card: Card) {
        if !copyQueue.contains(card.id) { copyQueue.append(card.id) }
        card.queuedBehind = card.id
        card.queueNote = "Waiting for Sync Now to finish"
    }

    /// Queues a check for each shoot (debounced; coalesced per shoot). `force` skips the throttle; `deep`
    /// re-reads every byte (and implies `force`). A newer request cancels a check of the same shoot that is running.
    func scheduleSyncCheck(_ ids: Set<UUID>, force: Bool, deep: Bool = false) {
        enqueueSync(ids, kind: .check, force: force || deep, deep: deep, delay: syncDebounce)
    }

    /// User-initiated check ("Check Again", with `deep` for "Verify Contents"): forced, starts right away.
    func checkSync(shootID: UUID, deep: Bool = false) {
        enqueueSync([shootID], kind: .check, force: true, deep: deep, delay: .zero)
    }

    /// Copies what is missing between the copies of a shoot. Only acts on a complete `.checksums` report that
    /// is out of sync; it re-checks first (cache hits) so it never plans from a stale report. Returns whether it was
    /// queued: false while a check is still at the size pass, while syncing, or when nothing is missing.
    @discardableResult
    /// Whether Sync Now can be offered for `shootID`: a finished checksum check found files missing and every
    /// copy is online. Shared by the popover and the shoot tile's menu.
    func canSyncNow(shootID: UUID) -> Bool {
        guard let item = shoots.first(where: { $0.id == shootID }),
              !item.copies.isEmpty, item.copies.allSatisfy({ $0.availability == .online }) else { return false }
        guard case .outOfSync(let missing, _) = syncBadge(for: shootID), missing > 0 else { return false }
        guard case .done(let report, _)? = syncStates[shootID] else { return false }
        return report.depth == .checksums && report.notChecked == nil
    }

    @discardableResult
    func syncNow(shootID: UUID) -> Bool {
        guard !cullApplying else { return false }   // a cull is moving files: try again when it finishes
        guard case .done(let report, _)? = syncStates[shootID], report.notChecked == nil, report.depth == .checksums,
              report.missing.values.contains(where: { !$0.isEmpty }) else { return false }
        enqueueSync([shootID], kind: .sync, force: true, deep: false, delay: .zero)
        return true
    }

    /// Stops a running check or Sync Now (files already copied stay; nothing is removed) and drops queued work.
    func stopSync(shootID: UUID) {
        syncWork.removeAll { $0.id == shootID }
        syncGenerations[shootID, default: 0] += 1
        if let running = syncRunning, running.id == shootID { running.task.cancel() }
        if let engine = syncEngines[shootID] {
            engine.cancel()
        } else if case .syncing? = syncStates[shootID] {
            syncStopped.insert(shootID)   // still preparing: the job notices before it writes
        } else if case .checking? = syncStates[shootID] {
            syncStates[shootID] = .unknown("Check stopped")
        }
    }

    fileprivate func forgetSyncState(_ id: UUID) {
        stopSync(shootID: id)
        syncStopped.remove(id)
        syncStates[id] = nil
        syncNotes[id] = nil
        syncSignatures[id] = nil
        syncMounts[id] = nil
        syncCurrentMounts[id] = nil
        syncDoneAt[id] = nil
        syncDeferred.remove(id)
        if lastDeepVerify.removeValue(forKey: id) != nil { persistDeepVerify() }
    }

    private func persistDeepVerify() {
        let dates = lastDeepVerify, url = syncMetaURL
        let previous = metaSave
        // Chained so an older snapshot can never be written after a newer one.
        metaSave = Task.detached {
            await previous?.value
            SyncMetaStore.save(dates, to: url)
        }
    }

    private func enqueueSync(_ ids: Set<UUID>, kind: SyncWork.Kind, force: Bool, deep: Bool, delay: Duration) {
        let due = ContinuousClock.now.advanced(by: delay)
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            if kind == .check {
                // Anything that started before this request is stale: its result is dropped.
                syncGenerations[id, default: 0] += 1
                if let running = syncRunning, running.id == id { running.task.cancel() }
            }
            if let i = syncWork.firstIndex(where: { $0.id == id && $0.kind == kind }) {
                syncWork[i].force = syncWork[i].force || force
                syncWork[i].deep = syncWork[i].deep || deep
                syncWork[i].notBefore = due
            } else {
                syncWork.append(SyncWork(id: id, kind: kind, force: force, deep: deep, notBefore: due))
            }
        }
        if syncRunner == nil {
            syncRunner = Task { [weak self] in
                if let self { await self.runSyncLoop() }
            }
        } else {
            syncSleeper?.cancel()   // re-evaluate what is due
        }
    }

    /// The one serial worker: at most one check or sync at a time, app-wide.
    private func runSyncLoop() async {
        await startupLoad?.value
        while true {
            let now = ContinuousClock.now
            guard let index = syncWork.firstIndex(where: { $0.notBefore <= now }) else {
                guard let next = syncWork.map(\.notBefore).min() else { break }
                let sleeper = Task<Void, Never> { _ = try? await Task.sleep(until: next, clock: .continuous) }
                syncSleeper = sleeper
                await sleeper.value
                continue
            }
            let work = syncWork.remove(at: index)
            // Checks and syncs read or write the shoot's files: never alongside a cull apply or undo.
            let locked = await acquireApplyLock(excludingIngest: false)
            switch work.kind {
            case .check: await performCheck(work.id, force: work.force, deep: work.deep)
            case .sync: await performSyncNow(work.id)
            }
            if locked { releaseApplyLock() }
        }
        syncRunner = nil
        syncSleeper = nil
    }

    private func isIngesting(into copies: [URL], shootID: UUID) -> Bool {
        cards.contains { card in
            guard card.engine != nil else { return false }
            if addTargets[card.id] == shootID || card.plan?.shootID == shootID { return true }
            return (card.plan?.copyRoots ?? []).contains { root in copies.contains { Self.overlap(root, $0) } }
        }
    }

    private func unknownReason(_ item: ShootItem) -> String {
        guard !item.copies.isEmpty else { return "Not checked yet" }
        for copy in item.copies where copy.availability != .online {
            let drive = copy.volumeName
            var text: String
            switch copy.availability {
            case .offline: text = "\(drive) isn't connected"
            case .missing: text = "The copy on \(drive) can't be found"
            case .mismatch: text = "The folder on \(drive) is a different shoot"
            case .sameVolume: text = "\(drive) holds more than one copy of this shoot, so it isn't a mirror"
            case .online: continue
            }
            if item.record.pendingSync.contains(where: { Self.copyKey($0) == Self.copyKey(copy.path) }) {
                text += " · new footage isn't on it yet"
            }
            return text
        }
        return "Not checked yet"
    }

    /// The effective-primary-first copy URLs when the shoot has 2+ copies and every one is online; otherwise
    /// the `.single` / `.unknown` state to show.
    private func checkableCopies(_ id: UUID) -> (copies: [URL], blocked: ShootSyncState?) {
        guard let item = shoots.first(where: { $0.id == id }) else { return ([], .unknown("Shoot not found")) }
        guard item.record.copyPaths.count >= 2 else { return ([], .single) }
        guard case .online(let shoot)? = item.availability, !item.copies.isEmpty,
              item.copies.allSatisfy({ $0.availability == .online }),
              shoot.copies.count == item.record.copyPaths.count else { return ([], .unknown(unknownReason(item))) }
        if isIngesting(into: shoot.copies, shootID: id) {
            syncDeferred.insert(id)
            return ([], .unknown("Waiting for a copy into this shoot to finish"))
        }
        return (shoot.copies, nil)
    }

    private func performCheck(_ id: UUID, force: Bool, deep: Bool) async {
        guard let item = shoots.first(where: { $0.id == id }) else { syncStates[id] = nil; return }
        // Mount identity of every copy (a remounted or swapped drive is a new volume): read off main, before
        // the synchronous part below, so the generation captured there cannot miss a bump.
        let provider = volumeIDProvider
        let paths = item.record.copyPaths
        let mounts = await Task.detached { Self.mountIDs(paths, provider) }.value
        syncCurrentMounts[id] = mounts
        let (urls, blocked) = checkableCopies(id)
        if let blocked { syncStates[id] = blocked; return }
        if !force, case .done(let last, _)? = syncStates[id], last.notChecked == nil, last.depth == .checksums,
           let doneAt = syncDoneAt[id], ContinuousClock.now - doneAt < syncThrottle, syncMounts[id] == mounts,
           last.copies.map({ Self.copyKey($0.path) }) == urls.map({ Self.copyKey($0.path) }) {
            return
        }
        // Only copies that were pending when this check began may be cleared by it.
        let pendingAtStart = registry.records.first(where: { $0.id == id })?.pendingSync ?? []
        let gen = syncGenerations[id, default: 0]
        syncChecksStarted += 1
        syncStates[id] = .checking(SyncProgress(phase: .listing), partial: nil)
        let runner = syncChecker, store = checksums
        let onSize: @MainActor @Sendable (ShootSyncReport) -> Void = { [weak self] partial in
            guard let self, gen == self.syncGenerations[id, default: 0], case .checking(let p, _)? = self.syncStates[id] else { return }
            self.syncStates[id] = .checking(p, partial: partial)
        }
        let onProgress: @MainActor @Sendable (SyncProgress) -> Void = { [weak self] progress in
            guard let self, gen == self.syncGenerations[id, default: 0], case .checking(_, let partial)? = self.syncStates[id] else { return }
            self.syncStates[id] = .checking(progress, partial: partial)
        }
        let task = Task<ShootSyncReport?, Never> { await runner(urls, store, deep, onSize, onProgress) }
        syncRunning = (id, task)
        let report = await task.value
        syncRunning = nil
        // A newer request, a stop or a forget superseded this run: its result is dropped.
        guard gen == syncGenerations[id, default: 0], shoots.contains(where: { $0.id == id }) else { return }
        guard let report else { syncStates[id] = .unknown("Check cancelled"); return }
        switch report.notChecked {
        case .singleCopy?: syncStates[id] = .single
        case .copyUnreadable(let url, let message)?:
            syncStates[id] = .unknown("The copy on \(Self.driveLabel(url)) couldn't be read: \(message)")
        case nil:
            syncStates[id] = .done(report, at: Date())
            syncDoneAt[id] = .now
            syncMounts[id] = mounts
            if deep && report.isInSync {
                lastDeepVerify[id] = Date()
                persistDeepVerify()
            }
            await clearPendingSync(id, after: report, only: pendingAtStart)
        }
    }

    /// After a complete check: a copy that is missing nothing and takes part in no conflict is no longer pending.
    private func clearPendingSync(_ id: UUID, after report: ShootSyncReport, only snapshot: [String]) async {
        guard report.notChecked == nil, report.depth == .checksums,
              let record = registry.records.first(where: { $0.id == id }), !record.pendingSync.isEmpty else { return }
        var changed = false
        let allowed = Set(snapshot.map(Self.copyKey))
        for path in record.pendingSync where allowed.contains(Self.copyKey(path)) {
            guard let root = report.copies.first(where: { Self.copyKey($0.path) == Self.copyKey(path) }) else { continue }
            let incomplete = !(report.missing[root] ?? []).isEmpty
                || report.conflicts.contains { $0.copies.contains { Self.copyKey($0.path) == Self.copyKey(path) } }
            if !incomplete { registry.setPendingSync(id: id, path: path, false); changed = true }
        }
        guard changed else { return }
        if let i = shoots.firstIndex(where: { $0.id == id }), let updated = registry.records.first(where: { $0.id == id }) {
            shoots[i].record = updated
        }
        await saveRegistry()
    }

    // MARK: Sync Now

    private static let syncWaitedNote = "Sync Now waited for a copy into this shoot; press Sync Now again when it finishes."

    private func performSyncNow(_ id: UUID) async {
        syncStopped.remove(id)
        syncActive.insert(id)
        defer {
            syncActive.remove(id)
            releaseQueuedCopies()
        }
        let (syncCopies, blocked) = checkableCopies(id)
        if let blocked {
            syncStates[id] = blocked
            if hasActiveIngest(into: id) { syncNotes[id] = Self.syncWaitedNote }
            return
        }
        // Bring every copy up to date with the cull journals first, so rejects are never copied back.
        let replayNote = await Self.replayCullJournals(copies: syncCopies, cardVolumes: cardVolumes())
        // Never plan from a stale report: look again first (cache hits make this cheap).
        await performCheck(id, force: true, deep: false)
        guard case .done(let report, _)? = syncStates[id], report.notChecked == nil, report.depth == .checksums,
              report.missing.values.contains(where: { !$0.isEmpty }) else {
            // Still "checking" means a newer request superseded our check: say so rather than dropping the click silently.
            if case .checking? = syncStates[id] { syncNotes[id] = "Sync stopped: the copies changed. Press Sync Now again." }
            return
        }
        if syncStopped.remove(id) != nil { return }

        syncStates[id] = .syncing(CopyProgress())
        let volumes = cardVolumes(), provider = volumeIDProvider, store = checksums
        let plan: SyncPlan
        do {
            plan = try await Self.prepareSync(report: report, shootID: id, cache: store, cardVolumes: volumes, volumeID: provider)
        } catch {
            syncStates[id] = .failed(error.localizedDescription)
            return
        }
        #if DEBUG
        await _testAfterSyncPrepare?(id)
        #endif
        // Stopped or forgotten while preparing: nothing was written yet.
        if syncStopped.remove(id) != nil || !shoots.contains(where: { $0.id == id }) {
            if shoots.contains(where: { $0.id == id }) { syncStates[id] = .unknown("Sync stopped") }
            return
        }
        // An ingest copy may have started while this was preparing: it and Sync Now never write at once.
        if let blocked = checkableCopies(id).blocked {
            syncStates[id] = blocked
            if hasActiveIngest(into: id) { syncNotes[id] = Self.syncWaitedNote }
            return
        }
        let engine = CopyEngine()
        #if DEBUG
        _testSyncEngineHook?(engine)
        #endif
        syncEngines[id] = engine
        syncStates[id] = .syncing(CopyProgress(filesTotal: plan.jobs.count, bytesTotal: plan.jobs.reduce(0) { $0 + $1.file.size }))
        let outcome = await engine.run(plan.jobs) { [weak self] progress in
            guard let self, self.syncEngines[id] === engine else { return }
            self.syncStates[id] = .syncing(progress)
        }
        syncEngines[id] = nil

        // Seed the cache with what landed (off main), so the re-check below is all hits.
        let landed = outcome.copied
        await Task.detached {
            for copied in landed { store.record(copied) }
            await store.saveIfDirty()
        }.value

        // Forgotten while copying: nothing more to record or show.
        guard shoots.contains(where: { $0.id == id }) else { return }
        // Stopped by the user: leave the state as it is, with no re-check or refresh.
        if outcome.cancelled {
            syncStates[id] = .unknown("Sync stopped")
            return
        }
        if outcome.failures.isEmpty {
            syncNotes[id] = replayNote
        } else {
            let first = outcome.failures[0]
            let more = outcome.failures.count > 1 ? " (+\(outcome.failures.count - 1) more)" : ""
            syncNotes[id] = "\(first.name): \(first.reason)\(more)"
        }
        // Forced re-check: clears pendingSync for copies that are now complete, and shows what is left.
        await performCheck(id, force: true, deep: false)
        await refreshShoots()
        // New files in the shoot's copies change which card files count as backed up and what the browser shows.
        if !outcome.copied.isEmpty {
            refreshBrowserMembership(force: true)
            for card in cards where card.engine == nil && !copyQueue.contains(card.id) {
                switch card.phase {
                case .copying, .backed: continue
                default: break
                }
                if addInFlight.contains(card.id) { recomputeAfterAdd.insert(card.id) } else { recompute(card) }
            }
        }
    }

    /// Off main. Every copy must still be off a card, resolve to a drive of its own, and carry this shoot's
    /// sidecar (the planner checks it); every destination folder is validated, then created below its root.
    @concurrent
    nonisolated private static func prepareSync(report: ShootSyncReport, shootID: UUID, cache: ChecksumStore,
                                                cardVolumes: [URL], volumeID: @Sendable (URL) -> String?) async throws -> SyncPlan {
        var drives = Set<String>()
        for root in report.copies {
            if VolumeClassifier.isOnCard(root, cards: cardVolumes) { throw ShootError.onCard }
            guard let drive = volumeID(root) else { throw ShootError.parentMissing }
            guard drives.insert(drive).inserted else { throw ShootError.sameVolumeAsCopy }
        }
        let plan = try await ShootSyncPlanner.plan(report: report, cache: cache, shootID: shootID)
        var roots: [URL] = []
        for job in plan.jobs {
            guard let root = job.root else { throw SyncPlanError.destinationNotThisShoot(job.destDir.path) }
            try ShootPlanner.checkDestination(job.destDir, root: root, cardVolumes: cardVolumes)
            if !roots.contains(root) { roots.append(root) }
        }
        try await ShootSyncPlanner.checkSpace(plan, free: { url in
            let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        })
        for root in roots {
            try ShootPlanner.createDirectories(ShootPlanner.directories(for: plan.jobs.filter { $0.root == root }),
                                               root: root, cardVolumes: cardVolumes)
        }
        return plan
    }

    #if DEBUG
    /// Waits until no check or sync is queued or running.
    func _testSyncIdle() async {
        while let runner = syncRunner { await runner.value }
    }
    #endif
}

// MARK: - Photo cull

extension AppModel {
    // MARK: Locking

    private var ingestRunning: Bool { cards.contains { $0.engine != nil } }

    /// Takes the app-wide mutex. With `excludingIngest` (a cull apply/undo) it also waits for every running ingest
    /// and makes new ingests queue until `releaseApplyLock`. Returns false if the task was cancelled while waiting.
    fileprivate func acquireApplyLock(excludingIngest: Bool) async -> Bool {
        do {
            while applyLockHeld || (excludingIngest && ingestRunning) { try await cullWaiters.wait() }
        } catch { return false }
        applyLockHeld = true
        cullApplying = excludingIngest
        return true
    }

    fileprivate func releaseApplyLock() {
        let wasCull = cullApplying
        applyLockHeld = false
        cullApplying = false
        cullWaiters.wake()
        if wasCull { releaseQueuedCopies() }   // ingests that queued behind the apply
    }

    /// Cards that asked to copy while a cull was applying wait here.
    fileprivate func enqueueBehindCull(_ card: Card) {
        if !copyQueue.contains(card.id) { copyQueue.append(card.id) }
        card.queuedBehind = card.id
        card.queueNote = "Waiting for a photo cull to finish"
    }

    /// Pauses a cull between groups while any ingest or sync runs.
    fileprivate func cullGate() async {
        while ingestRunning || !syncActive.isEmpty {
            if Task.isCancelled { return }
            do { try await cullWaiters.wait() } catch { return }
        }
    }

    fileprivate func cullWithApplyLock(_ body: @Sendable () async throws -> Void) async throws {
        guard await acquireApplyLock(excludingIngest: true) else { throw CancellationError() }
        defer { releaseApplyLock() }
        try await body()
    }

    // MARK: Queries

    /// Why a cull can't start for `shootID` (nil: it can). Ingest and sync don't block: the cull waits for them.
    func cullBlockReason(shootID: UUID) -> String? {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return "Shoot not found" }
        switch cullStates[shootID] {
        case .waiting?, .running?: return "Already culling this shoot"
        default: break
        }
        if cullTasks[shootID] != nil { return "Already culling this shoot" }
        guard item.copies.contains(where: { $0.availability == .online }) else { return "Shoot is offline" }
        return nil
    }

    /// Shown before starting: a cull started now waits for the running ingest or sync.
    func cullBusyNotice() -> String? {
        if ingestRunning { return "Ingest in progress. The cull will start when it finishes." }
        if !syncActive.isEmpty { return "Sync in progress. The cull will start when it finishes." }
        return nil
    }

    var cullRunPromptPreview: String { CullPromptBuilder.runSection(settings: cullSettings) }

    func revealCullWorkspace() { NSWorkspace.shared.activateFileViewerSelecting([cullWorkspaceRoot]) }

    func lastCullRun(shootID: UUID) -> CullRunSummary? { cullLastRuns[shootID] }

    /// Reads the primary's journal (off main) and caches the run the UI should offer to undo, else the newest.
    func loadLastCullRun(shootID: UUID) async {
        guard let primary = onlineCullCopies(shootID).first else { cullLastRuns[shootID] = nil; return }
        let runs = await Self.readCullRuns(primary)
        cullLastRuns[shootID] = runs.first(where: { !$0.undone }) ?? runs.first
    }

    /// Photo count and cost estimate for the sheet, catalogued off main. Nil when the shoot is offline or unreadable.
    func cullPreflight(shootID: UUID) async -> (photos: Int, estimate: (low: Double, high: Double, calls: Int))? {
        guard let primary = onlineCullCopies(shootID).first else { return nil }
        let volumes = cardVolumes()
        guard let count = await Self.countPhotos(primary, cardVolumes: volumes) else { return nil }
        return (count, CullEstimator.estimate(photoCount: count, model: cullSettings.model, settings: cullSettings.clamped()))
    }

    /// Online copies of the shoot, primary first.
    private func onlineCullCopies(_ shootID: UUID) -> [URL] {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return [] }
        let online = item.copies.filter { $0.availability == .online }
        let ordered = online.filter(\.isPrimary) + online.filter { !$0.isPrimary }
        return ordered.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    // MARK: Run

    /// Starts a cull of the whole shoot on every online copy. False when refused (see `cullBlockReason`).
    @discardableResult
    func startCull(shootID: UUID) -> Bool {
        guard cullBlockReason(shootID: shootID) == nil, let item = shoots.first(where: { $0.id == shootID }) else { return false }
        let copies = onlineCullCopies(shootID)
        guard let primary = copies.first else { return false }
        let shoot = Shoot(id: shootID, name: item.record.name, date: item.date, folder: primary, mirrors: Array(copies.dropFirst()))
        let runner = CullRunner(analyzer: photoAnalyzer, claude: claude, applier: cullApplier, workspaceRoot: cullWorkspaceRoot)
        let settings = cullSettings.clamped()
        let volumes = cardVolumes()
        cullNotes[shootID] = nil
        if let notice = cullBusyNotice() {
            cullStates[shootID] = .waiting(notice)
        } else {
            cullStates[shootID] = .running(CullProgress(phase: .cataloging, fraction: 0, spentUSD: 0))
        }
        cullTasks[shootID] = Task { [weak self] in
            // Starts when the running ingest or sync finishes (state stays `.waiting` until then).
            await self?.cullGate()
            if Task.isCancelled { await self?.finishCull(shootID, .stopped(nil)); return }
            self?.cullStates[shootID] = .running(CullProgress(phase: .cataloging, fraction: 0, spentUSD: 0))
            let outcome = await runner.run(
                shoot: shoot, copies: copies, cardVolumes: volumes, settings: settings,
                gate: { [weak self] in await self?.cullGate() },
                withApplyLock: { [weak self] body in
                    guard let self else { throw CancellationError() }
                    try await self.cullWithApplyLock(body)
                },
                onProgress: { [weak self] progress in
                    guard let self, self.cullTasks[shootID] != nil else { return }
                    if case .waiting(let note) = progress.phase { self.cullStates[shootID] = .waiting(note) } else { self.cullStates[shootID] = .running(progress) }
                })
            await self?.finishCull(shootID, outcome)
        }
        return true
    }

    /// Cancels the run. During apply the runner rolls this run's moves back (outcome `.stopped`).
    func stopCull(shootID: UUID) {
        cullTasks[shootID]?.cancel()
    }

    private func finishCull(_ shootID: UUID, _ outcome: CullOutcome) async {
        cullTasks[shootID] = nil
        cullStates[shootID] = .finished(outcome)
        guard case .completed(let summary) = outcome else { return }
        await afterCullChangedFiles(shootID, moved: summary.rejected > 0)
    }

    /// Offline copies missed the moves (sync replays the journal later), the summaries/thumbnails change,
    /// and the copies get re-checked.
    private func afterCullChangedFiles(_ shootID: UUID, moved: Bool) async {
        if moved { await markOfflineCopiesPending(shootID) }
        await refreshShoots()
        await loadLastCullRun(shootID: shootID)
        scheduleSyncCheck([shootID], force: true)
    }

    private func markOfflineCopiesPending(_ shootID: UUID) async {
        guard let item = shoots.first(where: { $0.id == shootID }) else { return }
        let offline = item.copies.filter { $0.availability != .online }
        guard !offline.isEmpty else { return }
        for copy in offline { registry.setPendingSync(id: shootID, path: copy.path, true) }
        if let i = shoots.firstIndex(where: { $0.id == shootID }), let updated = registry.records.first(where: { $0.id == shootID }) {
            shoots[i].record = updated
        }
        do { try await ShootStore.save(registry, to: registryURL) } catch { NSLog("Auto: couldn't save shoots.json: \(error)") }
    }

    /// Undoes the latest cull that isn't undone, on every online copy, under the apply lock.
    func undoLastCull(shootID: UUID) async -> Bool {
        guard cullBlockReason(shootID: shootID) == nil else { return false }
        let copies = onlineCullCopies(shootID)
        guard !copies.isEmpty else { return false }
        cullNotes[shootID] = nil
        cullStates[shootID] = .waiting(cullBusyNotice() ?? "Waiting to undo…")
        guard await acquireApplyLock(excludingIngest: true) else { cullStates[shootID] = nil; return false }
        cullStates[shootID] = .running(CullProgress(phase: .undoing(done: 0, total: 0), fraction: 0, spentUSD: 0))
        let volumes = cardVolumes()
        let result = await Self.performUndo(copies: copies, cardVolumes: volumes) { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self, case .running? = self.cullStates[shootID] else { return }
                self.cullStates[shootID] = .running(CullProgress(
                    phase: .undoing(done: done, total: total), fraction: total > 0 ? Double(done) / Double(total) : 1, spentUSD: 0))
            }
        }
        releaseApplyLock()
        cullStates[shootID] = nil
        switch result {
        case .success(let summary):
            await afterCullChangedFiles(shootID, moved: summary.rejected > 0)
            return true
        case .failure(let error):
            cullNotes[shootID] = error.localizedDescription
            return false
        }
    }

    // MARK: Off-main work

    @concurrent
    nonisolated private static func performUndo(copies: [URL], cardVolumes: [URL],
                                                onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Result<CullRunSummary, Error> {
        do { return .success(try CullApplier.undo(runID: nil, copies: copies, cardVolumes: cardVolumes, onProgress: onProgress)) }
        catch { return .failure(error) }
    }

    @concurrent
    nonisolated private static func readCullRuns(_ copy: URL) async -> [CullRunSummary] {
        (try? CullJournal.runs(in: copy)) ?? []
    }

    @concurrent
    nonisolated private static func countPhotos(_ copy: URL, cardVolumes: [URL]) async -> Int? {
        (try? PhotoCatalog.scan(shoot: copy, cardVolumes: cardVolumes))?.count
    }

    /// Sync Now step: copies the most advanced cull journal onto the other copies (moves only; nothing is
    /// copied or deleted), so the sync planner sees matching paths. Returns a note when pairs couldn't be replayed.
    @concurrent
    nonisolated fileprivate static func replayCullJournals(copies: [URL], cardVolumes: [URL]) async -> String? {
        guard copies.count >= 2 else { return nil }
        var best = copies[0]
        var bestCount = -1
        for copy in copies {
            let n = (try? CullJournal.runs(in: copy).count) ?? 0
            if n > bestCount { best = copy; bestCount = n }
        }
        guard bestCount > 0 else { return nil }
        var skipped = 0
        var failed: String?
        for copy in copies where copy.standardizedFileURL != best.standardizedFileURL {
            do { skipped += try CullReplay.replay(from: best, to: copy, cardVolumes: cardVolumes).skipped.count }
            catch { failed = error.localizedDescription }
        }
        if let failed { return "Cull replay: \(failed)" }
        return skipped > 0 ? "\(Format.count(skipped, "culled photo", "culled photos")) couldn't be matched on every copy." : nil
    }
}

enum Format {
    nonisolated static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
