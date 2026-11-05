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
            self.volume = volume; self.relPath = relPath; self.size = size
            self.mtime = mtime; self.inode = inode; self.ctime = ctime
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            volume = try c.decode(String.self, forKey: .volume)
            relPath = try c.decode(String.self, forKey: .relPath)
            size = try c.decode(Int64.self, forKey: .size)
            mtime = try c.decode(Int64.self, forKey: .mtime)
            inode = try c.decode(UInt64.self, forKey: .inode)
            ctime = try c.decodeIfPresent(Int64.self, forKey: .ctime) ?? 0
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
    private var map: [FileStamp: Data] = [:]
    private var dirty = false

    /// `nil` = memory only (tests).
    init(url: URL?) { self.url = url }

    // MARK: Stamps

    /// lstat-based stamp; nil if the path is not a regular file.
    static func stamp(_ url: URL, volumeID: String, volumeRoot: URL) -> FileStamp? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let rel = relativePath(of: url, under: volumeRoot)
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        let ctime = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
        return FileStamp(volume: volumeID, relPath: rel, size: Int64(st.st_size), mtime: mtime, inode: UInt64(st.st_ino), ctime: ctime)
    }

    /// Stamp using the file's volume UUID, falling back to `"path@" + absolute path` when it has none.
    static func stamp(_ url: URL) -> FileStamp? {
        if let v = volumeID(of: url) { return stamp(url, volumeID: v.id, volumeRoot: v.root) }
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
            for e in payload.entries {
                if let d = Self.data(fromHex: e.md5) { loaded[e.stamp] = d }
            }
            // Anything recorded before load finishes wins.
            lock.withLock { map.merge(loaded) { current, _ in current } }
        } else {
            Self.quarantine(url)
        }
    }

    @concurrent func saveIfDirty() async {
        guard let url else { return }
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

    /// Renames an undecodable cache to `<name>.corrupt-<timestamp>` next to it. Never deletes.
    private static func quarantine(_ url: URL) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp)
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp + "-\(n)")
            n += 1
        }
        do { try fm.moveItem(at: url, to: target) } catch { NSLog("Auto: could not back up corrupt checksums: \(error)") }
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private static func data(fromHex s: String) -> Data? {
        guard s.count % 2 == 0, !s.isEmpty else { return nil }
        var out = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}
