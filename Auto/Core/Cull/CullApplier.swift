import Foundation

/// Low-level hooks, injectable so tests can force ENOTSUP, cross-volume and mid-pair failures.
nonisolated struct CullIO: Sendable {
    /// `renameatx_np(RENAME_EXCL)`: returns 0, or -1 with errno set.
    var renameExclusive: @Sendable (_ srcDir: Int32, _ srcName: String, _ dstDir: Int32, _ dstName: String) -> Int32
    /// Volume of an open directory.
    var deviceID: @Sendable (_ dirFD: Int32) -> dev_t?

    static let live = CullIO(
        renameExclusive: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
        deviceID: { fd in
            var st = stat()
            return fstat(fd, &st) == 0 ? st.st_dev : nil
        })
}

/// Moves rejected photos into `_Rejects` folders. Renames only (never copies or deletes), never
/// overwrites, and never touches a card. Every pair is journaled write-ahead (`intent` per member,
/// fsynced, before any rename) and committed with one atomic `movedPair` line once verified.
///
/// All paths are walked with `openat(O_DIRECTORY | O_NOFOLLOW)` from the copy's `Photo` folder and
/// renamed with `renameatx_np(RENAME_EXCL)` on those directory fds, so a symlink swapped in after
/// checking can't redirect a move.
///
/// The apply and undo flows live in `CullApplier+Apply.swift` and `CullApplier+Undo.swift`; this file
/// holds the path and file-descriptor primitives they (and `CullReplay`) share.
nonisolated enum CullApplier {
    // MARK: - Paths

    /// `Photo/<cam>/<sub…>/X` → `Photo/<cam>/_Rejects/<sub…>/X`; `Photo/X` → `Photo/_Rejects/X`.
    static func rejectsDestination(for relPath: String) -> String {
        var parts = relPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] == "Photo" else { return relPath }
        parts.insert("_Rejects", at: parts.count == 2 ? 1 : 2)
        return parts.joined(separator: "/")
    }

    // MARK: - File descriptors

    struct Info {
        let dev: dev_t
        let ino: ino_t
        let size: Int64
        let mtime: Double
        let mode: mode_t
    }

    static func statAt(_ dir: Int32, _ name: String) -> Info? {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let t = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return Info(dev: st.st_dev, ino: st.st_ino, size: Int64(st.st_size), mtime: t, mode: st.st_mode)
    }

    static func isRegular(_ i: Info) -> Bool { (i.mode & S_IFMT) == S_IFREG }

    static let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Walks `parts` from `parent` through real directories only. With `create`, missing folders
    /// are made with mkdirat (EEXIST just re-opens). Returns an owned fd, or nil on any symlink,
    /// non-directory or error.
    static func openDir(_ parent: Int32, _ parts: ArraySlice<String>, create: Bool) -> Int32? {
        var cur = dup(parent)
        guard cur >= 0 else { return nil }
        for p in parts {
            var next = openat(cur, p, dirFlags)
            if next < 0, create, errno == ENOENT {
                if mkdirat(cur, p, 0o755) != 0, errno != EEXIST { close(cur); return nil }
                next = openat(cur, p, dirFlags)
            }
            close(cur)
            guard next >= 0 else { return nil }
            cur = next
        }
        return cur
    }

    // MARK: - Path safety

    /// Components of a shoot-relative path under `Photo/`, or nil if any is unsafe.
    static func safeParts(_ rel: String, allowRejects: Bool) -> [String]? {
        guard !rel.hasPrefix("/") else { return nil }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "Photo" else { return nil }
        for p in parts {
            if p.isEmpty || p == "." || p == ".." || p.hasPrefix(".") { return nil }
            if p == "_Rejects", !allowRejects { return nil }
        }
        return parts
    }

    static func openCopy(_ copy: URL) -> Int32? {
        let fd = open(copy.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    // MARK: - Renaming

    enum RenameResult { case success, exists, failed }

    /// Exclusive rename on dir fds. A volume without RENAME_EXCL (ENOTSUP) fails the move: a
    /// plain `renameat` could replace a file created in the check-to-rename window, and Auto
    /// never overwrites (same policy as CopyEngine).
    static func renameExclusive(_ io: CullIO, _ sd: Int32, _ sn: String, _ dd: Int32, _ dn: String) -> RenameResult {
        if io.renameExclusive(sd, sn, dd, dn) == 0 { return .success }
        switch errno {
        case EEXIST:
            return .exists
        default:
            return .failed
        }
    }

    /// `IMG_1.CR3` with n=2 → `IMG_1 2.CR3`; n=1 is the name unchanged (same style as CopyEngine.uniqueURL).
    static func suffixed(_ rel: String, n: Int) -> String {
        guard n > 1 else { return rel }
        let url = URL(fileURLWithPath: rel)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = (rel as NSString).deletingLastPathComponent
        let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        return dir.isEmpty ? name : dir + "/" + name
    }

    // MARK: - Copies

    static func checkCopies(_ copies: [URL], cardVolumes: [URL]) throws -> [URL] {
        var online: [URL] = []
        for copy in copies {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: copy.path, isDirectory: &isDir), isDir.boolValue {
                online.append(copy)
            }
        }
        guard !online.isEmpty else { throw CullError.noCopiesOnline }
        for copy in online {
            do { try ShootPlanner.checkDestination(copy, root: copy, cardVolumes: cardVolumes) }
            catch ShootPlanner.PathError.onCard { throw CullError.onCard }
            catch { throw CullError.outsideShoot(copy.path) }
        }
        return online
    }

    // MARK: - Cleanup

    /// Removes now-empty folders from the file's `_Rejects` location up through `_Rejects` itself.
    static func pruneRejects(copy: URL, rel: String) {
        guard let parts = safeParts(rel, allowRejects: true), let idx = parts.firstIndex(of: "_Rejects") else { return }
        var dirParts = Array(parts.dropLast())
        while dirParts.count > idx {
            let path = dirParts.reduce(copy) { $0.appendingPathComponent($1, isDirectory: true) }.path
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, rmdir(path) == 0 else { return }
            dirParts.removeLast()
        }
    }
}
