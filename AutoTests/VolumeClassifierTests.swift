import Testing
import Foundation
@testable import Auto

struct VolumeClassifierTests {
    nonisolated static func vol(_ name: String, internal i: Bool = false, removable: Bool = false, local: Bool = true,
                    root: Bool = false, image: Bool = false, layout: Bool = false, path: String? = nil) -> VolumeDescriptor {
        VolumeDescriptor(url: URL(fileURLWithPath: path ?? "/Volumes/\(name)"), name: name, isInternal: i,
                         isRemovable: removable, isLocal: local, isRootFileSystem: root, isDiskImage: image, hasCardLayout: layout)
    }
    nonisolated static let working = URL(fileURLWithPath: "/Volumes/Work")

    @Test("card/drive/excluded", arguments: [
        (vol("SD", removable: true, layout: true), "card"),
        (vol("SD", layout: true), "card"),
        (vol("Stick", removable: true), "card"),
        (vol("Work", layout: true), "drive"),
        (vol("SSD"), "drive"),
        (vol("Internal2", internal: true), "none"),
        (vol("DMG", image: true), "none"),
        (vol("Macintosh HD", root: true, path: "/"), "none"),
        (vol("NAS", local: false), "none"),
        (vol("Odd", path: "/private/mnt/odd"), "none"),
    ])
    func rules(v: VolumeDescriptor, expected: String) {
        let r = VolumeClassifier.classify([v], workingVolume: Self.working)
        switch expected {
        case "card": #expect(r.cards == [v.url] && r.drives.isEmpty)
        case "drive": #expect(r.drives.map(\.url) == [v.url] && r.cards.isEmpty)
        default: #expect(r.cards.isEmpty && r.drives.isEmpty)
        }
    }

    @Test func internalWorkingVolumeIsDrive() {
        let r = VolumeClassifier.classify([Self.vol("Work", internal: true)], workingVolume: Self.working)
        #expect(r.drives.map(\.name) == ["Work"])
    }

    @Test func drivesSortWorkingFirstThenName() {
        let r = VolumeClassifier.classify([Self.vol("Zed"), Self.vol("Alpha"), Self.vol("Work")], workingVolume: Self.working)
        #expect(r.drives.map(\.name) == ["Work", "Alpha", "Zed"])
    }

    @Test func hasCardLayoutDetectsMarkers() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("vc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let empty = base.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!VolumeClassifier.hasCardLayout(at: empty))
        for marker in VolumeClassifier.cardMarkers {
            let dir = base.appendingPathComponent(marker.replacingOccurrences(of: "/", with: "_"))
            try fm.createDirectory(at: dir.appendingPathComponent(marker), withIntermediateDirectories: true)
            #expect(VolumeClassifier.hasCardLayout(at: dir), "\(marker)")
        }
    }

    @Test func fixtureCardInjectedOnce() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fx-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let suite = "fx-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VolumeWatcher.fixtureCard(from: defaults) == nil)
        defaults.set(dir.path, forKey: VolumeWatcher.fixtureCardKey)
        let fixture = try #require(VolumeWatcher.fixtureCard(from: defaults))

        let r = VolumeWatcher.classify([Self.vol("SD", layout: true)], workingVolume: nil, fixtureCard: fixture)
        #expect(r.cards.count == 2 && r.cards.last == fixture)
        let again = VolumeWatcher.classify([], workingVolume: nil, fixtureCard: fixture)
        #expect(again.cards == [fixture])
    }

    @MainActor @Test func watcherReportsViaOnChange() {
        let suite = "w-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let watcher = VolumeWatcher(defaults: defaults, readVolumes: { [Self.vol("SD", layout: true), Self.vol("SSD")] })
        var got: ([URL], [DriveVolume], Bool)?
        watcher.onChange = { got = ($0, $1, $2) }
        watcher.refresh(mountedNew: true)
        #expect(got?.0.count == 1 && got?.1.count == 1 && got?.2 == true)
    }
}
