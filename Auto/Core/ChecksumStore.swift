import Foundation

/// Persistent cache of file MD5s, so unchanged files are never re-hashed. Thread-safe (NSLock).
/// It is only a cache: a corrupt file means an empty cache. It never vouches for a card backup.
nonisolated final class ChecksumStore: @unchecked Sendable {
    struct FileStamp: Sendable, Hashable, Codable {
        let volume: String
        let relPath: String
        let size: Int64
        let mtime: Int64   // nanoseconds
        let inode: UInt64
        /// Inode change time (ns): changes on any rewrite even if mtime was restored. Entries persisted
        /// before this field existed decode as 0, never match a real stamp, and so are re-hashed.
        var ctime: Int64 = 0

        init(volume: String, relPath: String, size: Int64, mtime: Int64, inode: UInt64, ctime: Int64 = 0) {
            self.volume = volume
            self.relPath = relPath
            self.size = size
            self.mtime = mtime
            self.inode = inode
            self.ctime = ctime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            volume = try container.decode(String.self, forKey: .volume)
            relPath = try container.decode(String.self, forKey: .relPath)
            size = try container.decode(Int64.self, forKey: .size)
            mtime = try container.decode(Int64.self, forKey: .mtime)
            inode = try container.decode(UInt64.self, forKey: .inode)
            ctime = try container.decodeIfPresent(Int64.self, forKey: .ctime) ?? 0
        }
    }

    private struct Entry: Codable {
        var stamp: FileStamp
        var md5: String
    }

    private struct Payload: Codable {
        var version = 1
        var entries: [Entry]
    }

    private let url: URL?
    private let lock = NSLock()
    private let saveGate = NSLock()
    private var map: [FileStamp: Data] = [:]
    private var dirty = false

    /// `nil` = memory only (tests).
    init(url: URL?) { self.url = url }

    // MARK: Stamps

    /// lstat-based stamp; nil if the path is not a regular file.
    static func stamp(_ url: URL, volumeID: String, volumeRoot: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let relPath = relativePath(of: url, under: volumeRoot)
        return FileStamp(volume: volumeID, relPath: relPath, size: Int64(info.st_size),
                         mtime: nanoseconds(info.st_mtimespec), inode: UInt64(info.st_ino),
                         ctime: nanoseconds(info.st_ctimespec))
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    /// Stamp using the file's volume UUID, falling back to `"path@" + absolute path` when it has none.
    static func stamp(_ url: URL) -> FileStamp? {
        if let volume = volumeID(of: url) { return stamp(url, volumeID: volume.id, volumeRoot: volume.root) }
        return stamp(url, volumeID: "path@", volumeRoot: URL(fileURLWithPath: "/"))
    }

    /// Volume UUID and mount root of the volume holding `url`.
    static func volumeID(of url: URL) -> (id: String, root: URL)? {
        // Fresh URL: URL objects cache resource values.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey]),
              let id = values.volumeUUIDString, let root = values.volume else { return nil }
        return (id, root)
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        if base == "/" { return String(path.drop(while: { $0 == "/" })) }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return path
    }

    // MARK: Lookup

    func checksum(for stamp: FileStamp) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return map[stamp]
    }

    func record(_ checksum: Data, for stamp: FileStamp) {
        lock.lock(); defer { lock.unlock() }
        if map[stamp] != checksum { map[stamp] = checksum; dirty = true }
    }

    /// Seeds the cache from a verified copy: the destination's checksum equals the source's.
    /// Only when the destination's mtime still equals the one read right after verification
    /// (a file edited since is not vouched for), for new and preexisting copies alike.
    func record(_ copied: CopiedFile) {
        guard let checksum = copied.checksum,
              let verifiedAt = copied.destinationModified,
              VerificationCache.modificationDate(copied.destination) == verifiedAt,
              let stamp = Self.stamp(copied.destination) else { return }
        record(checksum, for: stamp)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }

    // MARK: Persistence

    @concurrent func load() async {
        guard let url else { return }
        guard let data = try? Data(contentsOf: url) else { return } // missing = empty cache
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            var loaded: [FileStamp: Data] = [:]
            for entry in payload.entries {
                if let checksum = Self.data(fromHex: entry.md5) { loaded[entry.stamp] = checksum }
            }
            // Anything recorded before load finishes wins.
            // Dirty when the merge added entries: a save that ran before the load must not leave the file short.
            lock.withLock {
                let before = map.count
                map.merge(loaded) { current, _ in current }
                if map.count > before { dirty = true }
            }
        } else {
            CorruptFileQuarantine.quarantine(url, description: "checksums")
        }
    }

    /// Saves are serialized: a snapshot taken earlier can never overwrite a later one on disk.
    @concurrent func saveIfDirty() async {
        guard let url else { return }
        saveGate.withLock { writeSnapshot(to: url) }
    }

    private func writeSnapshot(to url: URL) {
        let snapshot: [Entry]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return map.map { Entry(stamp: $0.key, md5: Self.hex($0.value)) }
        }
        guard let entries = snapshot else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Payload(entries: entries))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Auto: could not save checksums: \(error)")
            lock.withLock { dirty = true }
        }
    }

    // MARK: Hex

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
