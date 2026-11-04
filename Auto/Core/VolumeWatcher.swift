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
    private let readVolumes: () -> [VolumeDescriptor]
    private var observers: [NSObjectProtocol] = []

    private(set) var cards: [URL] = []
    private(set) var drives: [DriveVolume] = []

    init(workingVolume: @escaping () -> URL? = { nil },
         defaults: UserDefaults = .standard,
         readVolumes: (() -> [VolumeDescriptor])? = nil) {
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

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            let announce = name == NSWorkspace.didMountNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(mountedNew: announce) }
            })
        }
        refresh()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    func refresh(mountedNew: Bool = false) {
        let result = Self.classify(readVolumes(), workingVolume: workingVolume(), fixtureCard: fixtureCard)
        cards = result.cards
        drives = result.drives
        onChange?(cards, drives, mountedNew)
    }

    // MARK: System access

    nonisolated static func systemVolumes() -> [VolumeDescriptor] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return mounted.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return VolumeDescriptor(
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                isInternal: v.volumeIsInternal ?? false,
                isRemovable: v.volumeIsRemovable ?? false,
                isLocal: v.volumeIsLocal ?? true,
                isRootFileSystem: v.volumeIsRootFileSystem ?? false,
                isDiskImage: isDiskImage(url),
                hasCardLayout: VolumeClassifier.hasCardLayout(at: url))
        }
    }

    nonisolated static func isDiskImage(_ url: URL) -> Bool {
        if ProcessInfo.processInfo.environment["AUTO_ALLOW_DISK_IMAGES"] != nil { return false }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let info = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return (info[kDADiskDescriptionDeviceModelKey] as? String) == "Disk Image"
    }
}
