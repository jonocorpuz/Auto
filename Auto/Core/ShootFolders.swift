import Foundation

/// Creating, adopting and reading shoot folders. Never overwrites: a sidecar is written exactly once
/// (exclusive rename) and an existing folder only becomes a shoot through an explicit `adopt`.
nonisolated enum ShootFolders {
    enum FolderCollision: Sendable, Equatable {
        case free
        case existingShoot(ShootSidecar)
        /// A folder with no sidecar. Only `adopt` (an explicit user action) may turn it into a shoot.
        case plainFolder
        case notAFolder
        /// A sidecar exists but can't be read (damaged or from a newer Auto). Never adopted or overwritten.
        case unreadableShoot(ShootError)
        /// The name can't be used as a folder name.
        case invalidName
    }

    // MARK: Reading

    private static func posix(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// lstat of the last component (never follows it). nil with ENOENT means truly absent.
    private enum Entry { case absent, directory, regular, symlink, other, failed(Int32) }

    private static func entry(at url: URL) -> Entry {
        var st = stat()
        if lstat(url.path, &st) != 0 { return errno == ENOENT ? .absent : .failed(errno) }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// The sidecar in `folder`, or nil if there is none (ENOENT only). Anything else that stops it
    /// being read (not a plain file, I/O error, bad JSON) throws; it is never treated as absent.
    static func readSidecar(in folder: URL) throws -> ShootSidecar? {
        let url = folder.appendingPathComponent(ShootSidecar.fileName)
        switch entry(at: url) {
        case .absent: return nil
        case .failed(let code): throw posix(code)
        case .directory, .symlink, .other: throw ShootError.corruptSidecar
        case .regular: break
        }
        guard let data = try? Data(contentsOf: url) else { throw ShootError.corruptSidecar }
        return try ShootSidecar.decode(data)
    }

    static func classify(parent: URL, name: String) -> FolderCollision {
        guard let component = ShootPlanner.safeComponent(name) else { return .invalidName }
        let url = parent.appendingPathComponent(component, isDirectory: true)
        return classify(folder: url)
    }

    static func classify(folder url: URL) -> FolderCollision {
        switch entry(at: url) {
        case .absent: return .free
        // A symlink (dangling or not) occupies the name but is never a shoot folder.
        case .symlink, .regular, .other: return .notAFolder
        case .failed: return .unreadableShoot(.corruptSidecar)
        case .directory: break
        }
        do {
            if let sidecar = try readSidecar(in: url) { return .existingShoot(sidecar) }
            return .plainFolder
        } catch let error as ShootError {
            return .unreadableShoot(error)
        } catch {
            return .unreadableShoot(.corruptSidecar)
        }
    }

    // MARK: Writing

    /// Writes the sidecar once, via the folder's file descriptor so nothing is resolved twice:
    /// open dir (no symlink) -> verify not on a card -> temp (exclusive create) -> F_FULLFSYNC ->
    /// exclusive rename -> sync dir. An existing sidecar is never replaced.
    static func writeSidecar(_ s: ShootSidecar, in folder: URL, cardVolumes: [URL] = []) throws {
        let data = try ShootSidecar.encode(s)
        let dfd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dfd >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR { throw ShootError.notAFolder(folder.lastPathComponent) }
            throw posix(code)
        }
        defer { close(dfd) }

        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(dfd, F_GETPATH, &buf) == 0 else { throw posix(errno) }
        let real = URL(fileURLWithPath: String(cString: buf), isDirectory: true)
        if VolumeClassifier.isOnCard(real, cards: cardVolumes) { throw ShootError.onCard }

        let tmpName = ".auto-shoot-\(UUID().uuidString).tmp"
        let fd = openat(dfd, tmpName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posix(errno) }
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; failure = errno; break }
                offset += n
            }
        }
        if failure == 0, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { failure = errno }
        close(fd)
        guard failure == 0 else {
            unlinkat(dfd, tmpName, 0)
            throw posix(failure)
        }

        if renameatx_np(dfd, tmpName, dfd, ShootSidecar.fileName, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            unlinkat(dfd, tmpName, 0)
            if code == EEXIST, let existing = try readSidecar(in: folder) { throw ShootError.alreadyAShoot(existing.id) }
            throw posix(code)
        }
        // Best effort: the sidecar is already in place, so a failed directory sync isn't an error.
        if fcntl(dfd, F_FULLFSYNC) != 0 { _ = fsync(dfd) }
    }

    private static func makeSidecar(name: String, date: Date, calendar: Calendar, now: Date) -> ShootSidecar {
        ShootSidecar(version: ShootSidecar.currentVersion, id: UUID(), name: name,
                     day: ShootSidecar.dayString(date, calendar: calendar), createdAt: now)
    }

    private static func shoot(_ sidecar: ShootSidecar, folder: URL, date: Date, calendar: Calendar) -> Shoot {
        Shoot(id: sidecar.id, name: sidecar.name, date: calendar.startOfDay(for: date), folder: folder)
    }

    private static func checkSafe(_ dir: URL, root: URL, cardVolumes: [URL], name: String) throws {
        do {
            try ShootPlanner.checkDestination(dir, root: root, cardVolumes: cardVolumes)
        } catch let error as ShootPlanner.PathError {
            switch error {
            case .onCard: throw ShootError.onCard
            case .notAFolder(let n): throw ShootError.notAFolder(n)
            // A symlink (dangling or leading elsewhere) at the name: same answer classify gives.
            case .outsideWorkFolder: throw ShootError.notAFolder(name)
            case .workFolderMissing: throw ShootError.parentMissing
            case .invalidName: throw ShootError.invalidName
            }
        }
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Create / adopt

    /// Makes `parent/<name>` (parent must already exist and is never created) and writes its sidecar.
    static func create(name: String, date: Date, parent: URL, cardVolumes: [URL], calendar: Calendar, now: Date = Date()) throws -> Shoot {
        guard isExistingDirectory(parent) else { throw ShootError.parentMissing }
        try checkSafe(parent, root: parent, cardVolumes: cardVolumes, name: parent.lastPathComponent)
        guard let component = ShootPlanner.safeComponent(name) else { throw ShootError.invalidName }
        let sidecar = makeSidecar(name: component, date: date, calendar: calendar, now: now)
        let folder = try makeFolder(sidecar: sidecar, parent: parent, cardVolumes: cardVolumes)
        return shoot(sidecar, folder: folder, date: date, calendar: calendar)
    }

    /// Makes another copy of an existing shoot: `parent/<sidecar.name>` with a sidecar byte-identical to
    /// the original (same id, name, day, createdAt). Never writes into a folder that already exists.
    @discardableResult
    static func createCopy(of sidecar: ShootSidecar, parent: URL, cardVolumes: [URL]) throws -> URL {
        try makeFolder(sidecar: sidecar, parent: parent, cardVolumes: cardVolumes)
    }

    /// What is at `parent/<sidecar.name>`, from the point of view of a copy of `sidecar`.
    enum CopyCollision: Sendable, Equatable {
        case free
        case sameShoot
        case otherShoot(UUID)
        case plainFolder
        case notAFolder
        case unreadable(ShootError)
    }

    static func classifyCopy(parent: URL, sidecar: ShootSidecar) -> CopyCollision {
        switch classify(parent: parent, name: sidecar.name) {
        case .free: return .free
        case .existingShoot(let s): return s.id == sidecar.id ? .sameShoot : .otherShoot(s.id)
        case .plainFolder: return .plainFolder
        case .notAFolder: return .notAFolder
        case .unreadableShoot(let e): return .unreadable(e)
        case .invalidName: return .unreadable(.invalidName)
        }
    }

    /// Turns an existing plain folder into a copy of `sidecar` by writing that exact sidecar. A folder
    /// that is already a copy of the same shoot is accepted without a write; any other shoot is refused.
    static func adoptCopy(folder: URL, sidecar: ShootSidecar, cardVolumes: [URL]) throws {
        guard isExistingDirectory(folder) else { throw ShootError.notAFolder(folder.lastPathComponent) }
        try checkSafe(folder, root: folder, cardVolumes: cardVolumes, name: folder.lastPathComponent)
        switch classify(folder: folder) {
        case .existingShoot(let s):
            if s.id == sidecar.id { return }
            throw ShootError.alreadyAShoot(s.id)
        case .unreadableShoot(let e): throw e
        case .notAFolder, .free: throw ShootError.notAFolder(folder.lastPathComponent)
        case .invalidName: throw ShootError.invalidName
        case .plainFolder: break
        }
        try writeSidecar(sidecar, in: folder, cardVolumes: cardVolumes)
    }

    /// Shared by `create` and `createCopy`: exclusive mkdir of `parent/<sidecar.name>`, then the sidecar.
    private static func makeFolder(sidecar: ShootSidecar, parent: URL, cardVolumes: [URL]) throws -> URL {
        guard isExistingDirectory(parent) else { throw ShootError.parentMissing }
        try checkSafe(parent, root: parent, cardVolumes: cardVolumes, name: parent.lastPathComponent)
        guard let component = ShootPlanner.safeComponent(sidecar.name) else { throw ShootError.invalidName }
        let folder = parent.appendingPathComponent(component, isDirectory: true)
        try checkSafe(folder, root: parent, cardVolumes: cardVolumes, name: component)

        // mkdir is the exclusive step: it fails if anything (even a symlink) occupies the name.
        guard mkdir(folder.path, 0o755) == 0 else {
            let code = errno
            guard code == EEXIST else { throw posix(code) }
            switch classify(folder: folder) {
            case .existingShoot(let s): throw ShootError.alreadyAShoot(s.id)
            case .plainFolder: throw ShootError.folderExistsWithoutSidecar(component)
            case .notAFolder: throw ShootError.notAFolder(component)
            case .unreadableShoot(let e): throw e
            case .invalidName: throw ShootError.invalidName
            case .free: throw posix(code)
            }
        }
        do {
            try writeSidecar(sidecar, in: folder, cardVolumes: cardVolumes)
        } catch {
            rmdir(folder.path) // we made this directory just now; rmdir only succeeds while it is empty
            throw error
        }
        return folder
    }

    /// Turns an existing plain folder into a shoot by adding the sidecar. Nothing else is touched.
    static func adopt(folder: URL, name: String, date: Date, cardVolumes: [URL], calendar: Calendar, now: Date = Date()) throws -> Shoot {
        guard isExistingDirectory(folder) else { throw ShootError.notAFolder(folder.lastPathComponent) }
        try checkSafe(folder, root: folder, cardVolumes: cardVolumes, name: folder.lastPathComponent)
        guard let clean = ShootPlanner.safeComponent(name) else { throw ShootError.invalidName }
        switch classify(folder: folder) {
        case .existingShoot(let s): throw ShootError.alreadyAShoot(s.id)
        case .unreadableShoot(let e): throw e
        case .notAFolder, .free: throw ShootError.notAFolder(folder.lastPathComponent)
        case .invalidName: throw ShootError.invalidName
        case .plainFolder: break
        }
        let sidecar = makeSidecar(name: clean, date: date, calendar: calendar, now: now)
        try writeSidecar(sidecar, in: folder, cardVolumes: cardVolumes)
        return shoot(sidecar, folder: folder, date: date, calendar: calendar)
    }
}
