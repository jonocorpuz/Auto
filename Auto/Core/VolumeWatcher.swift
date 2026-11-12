import Foundation
import DiskArbitration
import AppKit // NSWorkspace mount notifications only; no UI.

/// Watches mounted volumes and reports cards and drives.
/// Mock mode: `-AutoFixtureCard <folder>` (UserDefaults key `AutoFixtureCard`)
/// always adds that folder as an extra card.
final class VolumeWatcher {
    nonisolated static let fixtureCardKey = "AutoFixtureCard"

    /// Called on the main actor after every refresh.
    var onChange: ((_ cards: [URL], _ drives: [DriveVolume], _ mountedNew: Bool) -> Void)?
    /// Supplies the volume holding the work folder (for working-first drive sorting).
    var workingVolume: () -> URL?
    private let fixtureCard: URL?
    private let readVolumes: @Sendable () -> [VolumeDescriptor]
    /// Bumped by every refresh, so a slow earlier refresh can tell it has been superseded.
    private var generation = 0
    /// A mount seen by a superseded refresh is still announced by the refresh that publishes.
    private var pendingMountedNew = false

    init(workingVolume: @escaping () -> URL? = { nil },
         defaults: UserDefaults = .standard,
         readVolumes: (@Sendable () -> [VolumeDescriptor])? = nil) {
        self.workingVolume = workingVolume
        self.fixtureCard = Self.fixtureCard(from: defaults)
        self.readVolumes = readVolumes ?? { VolumeWatcher.systemVolumes() }
    }

    /// Fixture folder from defaults, only if it is an existing directory.
    nonisolated static func fixtureCard(from defaults: UserDefaults) -> URL? {
        guard let path = defaults.string(forKey: fixtureCardKey), !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Classification plus the fixture card (appended once, never duplicated).
    nonisolated static func classify(_ volumes: [VolumeDescriptor], workingVolume: URL?, fixtureCard: URL?) -> VolumeClassification {
        var result = VolumeClassifier.classify(volumes, workingVolume: workingVolume)
        if let fixture = fixtureCard, !result.cards.contains(where: { $0.standardizedFileURL == fixture }) {
            result.cards.append(fixture)
        }
        return result
    }

    // MARK: Refreshing

    /// Refreshes now and again on every mount, unmount and volume rename, for the life of the app.
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let volumeEvents = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for event in volumeEvents {
            let isMount = event == NSWorkspace.didMountNotification
            _ = center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(mountedNew: isMount) }
            }
        }
        refresh()
    }

    /// Reads and classifies volumes off the main actor, then publishes on main.
    /// Results from superseded refreshes are dropped (generation counter).
    func refresh(mountedNew: Bool = false) {
        _ = startRefresh(mountedNew: mountedNew)
    }

    /// Like `refresh`, but returns once the result has been published (or superseded). Test seam.
    func refreshAndWait(mountedNew: Bool = false) async {
        await startRefresh(mountedNew: mountedNew).value
    }

    private func startRefresh(mountedNew: Bool) -> Task<Void, Never> {
        generation += 1
        let myGeneration = generation
        pendingMountedNew = pendingMountedNew || mountedNew
        let read = readVolumes
        let working = workingVolume()
        let fixture = fixtureCard
        return Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.classify(read(), workingVolume: working, fixtureCard: fixture)
            }.value
            guard let self, self.generation == myGeneration else { return }
            let announce = self.pendingMountedNew
            self.pendingMountedNew = false
            self.onChange?(result.cards, result.drives, announce)
        }
    }

    // MARK: System access

    private nonisolated static func systemVolumes() -> [VolumeDescriptor] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        ]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return mounted.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return VolumeDescriptor(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isLocal: values.volumeIsLocal ?? true,
                isRootFileSystem: values.volumeIsRootFileSystem ?? false,
                isDiskImage: isDiskImage(url),
                hasCardLayout: VolumeClassifier.hasCardLayout(at: url))
        }
    }

    /// Disk images are ignored unless `AUTO_ALLOW_DISK_IMAGES` is set (so a .dmg can stand in for a card).
    private nonisolated static func isDiskImage(_ url: URL) -> Bool {
        if ProcessInfo.processInfo.environment["AUTO_ALLOW_DISK_IMAGES"] != nil { return false }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let info = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return (info[kDADiskDescriptionDeviceModelKey] as? String) == "Disk Image"
    }
}
