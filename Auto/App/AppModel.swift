import AppKit
import Foundation
import Observation

/// Shared app state. Views read it via `@Environment(AppModel.self)`.
///
/// This file holds the stored state only. Behaviour lives in the `AppModel+<Area>.swift` extensions,
/// which is why most of the state below is internal rather than private.
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

    /// UserDefaults keys for the app-level settings.
    enum Keys {
        static let workRoot = "workRoot"
        static let autoOpen = "autoOpen"
        static let appearance = "appearance"
        static let lastParent = "shoots.lastParent"
    }

    // MARK: Dependencies

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let registryURL: URL
    @ObservationIgnored let thumbnails: any ThumbnailProvider
    /// MD5 cache (`checksums.json` next to the registry). Seeded by every verified copy so a later sync check is all hits.
    @ObservationIgnored let checksums: ChecksumStore
    @ObservationIgnored let verifications = VerificationCache()
    /// Calendar used to split recordings into days (scan and New Shoot selection).
    let calendar = Calendar.current
    /// Runtime mount identity of the volume holding a URL (nil: unknown). Injectable so tests can fake
    /// distinct drives; every mirror / same-volume decision goes through it.
    @ObservationIgnored var volumeIDProvider: @Sendable (URL) -> String? = ShootStore.realVolumeID(of:)
    @ObservationIgnored lazy var watcher = VolumeWatcher(workingVolume: { [weak self] in self?.workingVolume })
    /// Provided by AppDelegate.
    @ObservationIgnored var openMainWindow: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}

    // MARK: Settings

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

    // MARK: Navigation

    /// Sidebar selection in the main window.
    var selectedTab: AppTab = .media {
        didSet {
            guard selectedTab != .media else { return }
            browsingCardID = nil
            browsingShootID = nil
        }
    }

    /// Card open in the Media tab's file browser; nil shows the overview.
    var browsingCardID: Card.ID? {
        didSet {
            guard browsingCardID != oldValue else { return }
            if browsingCardID != nil, browsingShootID != nil { browsingShootID = nil }
            fileThumbnails.removeAll()
            missingThumbnails.removeAll()
            browserCache = nil
            refreshBrowserMembership()
        }
    }

    /// Shoot open in the Media tab's file browser. Mutually exclusive with `browsingCardID`.
    var browsingShootID: UUID? {
        didSet { if browsingShootID != nil, browsingCardID != nil { browsingCardID = nil } }
    }

    /// Whether the main window is showing (not closed or minimized). Membership hashing only runs while
    /// it is: the window object outlives a close, so the browser's onDisappear can't be relied on.
    var mainWindowVisible = true {
        didSet { if mainWindowVisible != oldValue { refreshBrowserMembership() } }
    }

    /// The New Shoot sheet request currently showing, if any.
    var shootSheet: ShootSheetRequest?
    /// Card the legacy copy-flow sheet (`.create`) should use; nil picks the first card with work to do.
    var shootSheetCard: Card?

    // MARK: Cards and drives (see AppModel+Volumes)

    var cards: [Card] = []
    var drives: [DriveVolume] = []
    var indexing = false
    /// Backup candidates on the working drive, as built by `DriveIndex`.
    @ObservationIgnored var index: [String: [URL]] = [:]
    @ObservationIgnored var indexGeneration = 0
    /// Identity of the working volume the current index was built for (nil: none).
    @ObservationIgnored var indexedVolumeID: String?
    /// Cards whose recompute (stat-triage Task) is in flight: the verdict isn't settled yet even though
    /// `verifier` is nil.
    @ObservationIgnored var recomputePending: Set<Card.ID> = []
    /// Online shoot folders the current backup verification considered (to detect changes).
    @ObservationIgnored var backupShootFolders: Set<String> = []

    // MARK: Shoots (see AppModel+Shoots)

    /// Known shoots for the Shoots grid, newest first.
    var shoots: [ShootItem] = []
    var registry = ShootRegistry()
    @ObservationIgnored var shootsGeneration = 0
    @ObservationIgnored var thumbnailCache: [String: CGImage] = [:]
    /// Shoots with a mirror operation (add / relocate / remove copy) in flight; one at a time per shoot.
    @ObservationIgnored var copyOpsInFlight: Set<UUID> = []

    // MARK: Card browser (see AppModel+Browser and AppModel+BrowserMembership)

    /// Which shoots hold a verified copy of the browsed card's files. Browsed card only; separate from
    /// `coverage` (which Add Footage awaits).
    var browserMembership: [UUID: BrowserMembershipState] = [:]
    /// The card whose browser is on screen (nil: none). Membership only runs while it is the browsed card.
    @ObservationIgnored var browserOnScreen: Card.ID?
    @ObservationIgnored var browserCache: (key: BrowserKey, groups: [CardBrowser.Group])?
    /// Card browser previews, keyed by file identity. Cleared wholesale when it grows large.
    @ObservationIgnored var fileThumbnails: [String: CGImage] = [:]
    /// Files QuickLook couldn't preview, so they aren't retried on every scroll.
    @ObservationIgnored var missingThumbnails: Set<String> = []
    @ObservationIgnored var membershipTask: Task<Void, Never>?
    @ObservationIgnored var membershipGeneration = 0
    @ObservationIgnored var membershipInputs: MembershipInputs?

    // MARK: Copying (see AppModel+Copy and AppModel+Import)

    /// Add Files runs (queued, copying and finished), oldest first. Driven by `AppModel+Import`.
    var imports: [ImportJob] = []
    /// Files CopyEngine copied and verified this session, with their exact destinations.
    @ObservationIgnored var sessionCopies: [CopiedFile] = []
    /// Cards waiting for another card's copy into an overlapping folder, in the order they asked.
    @ObservationIgnored var copyQueue: [Card.ID] = []
    /// Number of CopyEngine runs in flight (engine.run started, not yet returned). The cull gate and apply lock wait on it.
    @ObservationIgnored var ingestRunCount = 0

    // MARK: Add footage (see AppModel+AddFootage)

    /// Per (shoot, card) coverage checks for the Add Footage sheet.
    var coverage: [CoverageKey: CoverageState] = [:]
    @ObservationIgnored var coverageTasks: [CoverageKey: Task<Void, Never>] = [:]
    @ObservationIgnored var coverageGenerations: [CoverageKey: Int] = [:]
    @ObservationIgnored var coverageCounter = 0
    /// Card id -> shoot a pending add-footage plan copies into.
    @ObservationIgnored var addTargets: [Card.ID: UUID] = [:]
    /// Cards whose current plan was made with "copy duplicates anyway" (no copy-time pruning).
    @ObservationIgnored var includeDuplicatePlans: Set<Card.ID> = []
    /// Cards with an addFootage/addFiles call in flight, and those that should be recomputed when it ends.
    @ObservationIgnored var addInFlight: Set<Card.ID> = []
    @ObservationIgnored var recomputeAfterAdd: Set<Card.ID> = []

    // MARK: Mirror sync (see AppModel+Sync)

    /// Where each shoot's mirror check / Sync Now stands. Absent until first scheduled.
    var syncStates: [UUID: ShootSyncState] = [:]
    /// When each shoot's contents were last fully re-read (a deep check that came back in sync). Persisted.
    var lastDeepVerify: [UUID: Date] = [:]
    /// Failures from the last Sync Now per shoot (e.g. a different file appeared at the destination).
    var syncNotes: [UUID: String] = [:]
    /// Quiet period before a scheduled check starts; requests inside it coalesce.
    @ObservationIgnored var syncDebounce: Duration = .seconds(2)
    /// A non-forced check is skipped when the last complete one is younger than this and the copies are unchanged.
    @ObservationIgnored var syncThrottle: Duration = .seconds(600)
    /// Runs one check. Injectable so tests can hold or fake it; the default is `ShootSyncChecker.run`.
    @ObservationIgnored var syncChecker: SyncCheckRunner = AppModel.realSyncChecker
    /// Checks actually started (a throttled, deferred or offline request doesn't count). For tests.
    @ObservationIgnored var syncChecksStarted = 0
    @ObservationIgnored var syncWork: [SyncWork] = []
    @ObservationIgnored var syncRunner: Task<Void, Never>?
    @ObservationIgnored var syncSleeper: Task<Void, Never>?
    @ObservationIgnored var syncRunning: (id: UUID, task: Task<ShootSyncReport?, Never>)?
    @ObservationIgnored var syncGenerations: [UUID: Int] = [:]
    @ObservationIgnored var syncEngines: [UUID: CopyEngine] = [:]
    @ObservationIgnored var syncStopped: Set<UUID> = []
    @ObservationIgnored var syncSignatures: [UUID: [String]] = [:]
    @ObservationIgnored var startupLoad: Task<Void, Never>?
    /// Shoots whose check was held back (or invalidated) by an ingest copy: re-checked once an engine ends.
    @ObservationIgnored var syncDeferred: Set<UUID> = []
    /// Shoots with a Sync Now job in flight (its first check through its re-check).
    @ObservationIgnored var syncActive: Set<UUID> = []
    /// Mount identity of each copy and the time of the last complete check, for the throttle.
    @ObservationIgnored var syncMounts: [UUID: [String]] = [:]
    @ObservationIgnored var syncCurrentMounts: [UUID: [String]] = [:]
    @ObservationIgnored var syncDoneAt: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored var metaSave: Task<Void, Never>?

    // MARK: Photo cull (see AppModel+Cull)

    /// Per-shoot cull state, keyed by shoot id. Absent = idle.
    var cullStates: [UUID: CullState] = [:]
    /// Settings for the next cull; clamped and saved to defaults on every set.
    var cullSettings: CullSettings {
        didSet {
            let clamped = cullSettings.clamped()
            if clamped != cullSettings { cullSettings = clamped; return }
            CullSettingsStore.save(cullSettings, to: defaults)
        }
    }
    /// Notes from the last cull action per shoot (e.g. why an undo failed).
    var cullNotes: [UUID: String] = [:]
    /// Rejects streamed during a cull (newest last), kept after the run for review.
    var cullLiveRejects: [UUID: [CullLiveReject]] = [:]
    /// Whether the listed rejects were actually moved (true only after a completed run).
    var cullLiveRejectsApplied: [UUID: Bool] = [:]
    /// Most relevant run per shoot, read from the primary's journal by `loadLastCullRun`.
    var cullLastRuns: [UUID: CullRunSummary] = [:]
    @ObservationIgnored let claude: any ClaudeRunner
    @ObservationIgnored let photoAnalyzer: any PhotoAnalyzer
    @ObservationIgnored let cullApplier: any CullApplying
    @ObservationIgnored let cullWorkspaceRoot: URL
    @ObservationIgnored var cullTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored let cullWaiters = CullWaiters()
    /// The app-wide mutex for anything that moves or reads files being moved: cull apply/undo, and each sync-loop job.
    @ObservationIgnored var applyLockHeld = false
    /// True while a cull apply/undo holds the mutex: ingest queues behind it.
    @ObservationIgnored var cullApplying = false
    /// Shoots whose cull reached the apply step (files may have moved even if the run then failed or was stopped).
    @ObservationIgnored var cullApplyEntered: Set<UUID> = []

    // MARK: Video edit (see AppModel+VideoEdit)

    /// Options for the next video edit; clamped and saved to defaults on every set.
    var videoEditSettings: VideoEditSettings {
        didSet {
            let clamped = videoEditSettings.clamped()
            if clamped != videoEditSettings { videoEditSettings = clamped; return }
            VideoEditSettingsStore.save(videoEditSettings, to: defaults)
        }
    }
    /// Whether `~/.claude.json` registers the Resolve MCP server. nil until checked.
    var resolveMCPRegistered: Bool?
    /// Whether DaVinci Resolve is running, as of the last refresh.
    var resolveRunning = false

    // MARK: Test seams

    #if DEBUG
    @ObservationIgnored var _testEngineHook: ((CopyEngine) -> Void)?
    var _testSessionCopyDestinations: [URL] { sessionCopies.map(\.destination) }
    @ObservationIgnored var _testFreeSpace: (@Sendable (URL) -> Int64?)?
    /// Sync Now: awaited after the plan is prepared and before the engine is created.
    @ObservationIgnored var _testAfterSyncPrepare: (@MainActor (UUID) async -> Void)?
    @ObservationIgnored var _testSyncEngineHook: ((CopyEngine) -> Void)?
    @ObservationIgnored var _testMembershipRunner: MembershipRunner?
    #endif

    // MARK: Init

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
        self.videoEditSettings = VideoEditSettingsStore.load(from: defaults)
        self.registryURL = registryURL
        self.checksums = ChecksumStore(url: registryURL.deletingLastPathComponent().appendingPathComponent("checksums.json"))
        self.thumbnails = thumbnails
        autoOpen = defaults.object(forKey: Keys.autoOpen) as? Bool ?? true
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init) ?? .system
        if let path = defaults.string(forKey: Keys.workRoot) {
            workRoot = URL(fileURLWithPath: path)
        }
    }
}

// MARK: - Derived state and app-level actions

extension AppModel {
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

    var browsingCard: Card? {
        guard let id = browsingCardID else { return nil }
        return cards.first { $0.id == id }
    }

    var accountInitials: String {
        let letters = accountName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
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
        let shootDay = calendar.startOfDay(for: day)
        let cardWithFilesThatDay = cards.first { card in
            card.shootDays.values.contains { days in
                days.contains { calendar.startOfDay(for: $0.start) == shootDay }
            }
        }
        return cardWithFilesThatDay ?? cards.first
    }

    // MARK: Working drive

    /// The mounted volume that holds the work folder.
    var workingVolume: URL? {
        guard let root = workRoot, FileManager.default.fileExists(atPath: root.path) else { return nil }
        return try? root.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    var workingDriveName: String {
        if let volume = workingVolume { return Self.volumeName(volume) }
        // Not mounted: fall back to the drive name in a "/Volumes/<drive>/..." path.
        if let root = workRoot, root.pathComponents.count > 2, root.pathComponents[1] == "Volumes" {
            return root.pathComponents[2]
        }
        return "your drive"
    }

    static func volumeName(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeURLKey])
        // Fixture folders are not volume roots, so name them after the folder.
        guard let root = values?.volume, root.standardizedFileURL == url.standardizedFileURL else { return url.lastPathComponent }
        return values?.volumeName ?? url.lastPathComponent
    }
}
