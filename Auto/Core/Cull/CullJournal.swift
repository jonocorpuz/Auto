import Foundation

/// Append-only JSONL record of every cull move, one file per run under `<copy>/.auto-cull/`.
/// Each line is fsynced, and a truncated or undecodable line is ignored when reading.
nonisolated enum CullJournal {
    static let directoryName = ".auto-cull"

    static func directory(in copy: URL) -> URL {
        copy.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `<ISO-date>_<runID>.jsonl`. Reuses the run's existing file so the name stays stable.
    static func url(runID: UUID, in copy: URL) -> URL {
        let dir = directory(in: copy)
        let suffix = "_\(runID.uuidString).jsonl"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           let existing = names.first(where: { $0.hasSuffix(suffix) }) {
            return dir.appendingPathComponent(existing)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return dir.appendingPathComponent(f.string(from: Date()) + suffix)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func append(_ event: CullJournalEvent, runID: UUID, in copy: URL) throws {
        let dir = directory(in: copy)
        try ShootPlanner.createDirectories([dir], root: copy, cardVolumes: [])
        var line = try encoder().encode(event)
        line.append(0x0A)
        let path = url(runID: runID, in: copy).path
        var existing = stat()
        let isNew = lstat(path, &existing) != 0
        let fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        // A crash can leave a torn last line; start a fresh line so the new event stays decodable.
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size > 0 {
            var last: UInt8 = 0x0A
            if pread(fd, &last, 1, st.st_size - 1) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
        }
        var offset = 0
        try line.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path)
                }
                offset += n
            }
        }
        guard fullSync(fd) else { throw posixError(path) }
        if isNew {
            let dfd = open(dir.path, O_RDONLY | O_CLOEXEC)
            if dfd >= 0 { _ = fullSync(dfd); close(dfd) }
        }
    }

    /// F_FULLFSYNC flushes the drive cache; plain fsync is the fallback where unsupported.
    static func fullSync(_ fd: Int32) -> Bool {
        fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
    }

    private static func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }

    /// Every decodable event in the copy's journal, in file order (files sorted by name).
    static func events(in copy: URL) throws -> [CullJournalEvent] {
        let dir = directory(in: copy)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let dec = decoder()
        var result: [CullJournalEvent] = []
        for name in names.filter({ $0.hasSuffix(".jsonl") }).sorted() {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            for line in data.split(separator: 0x0A) {
                // A line cut short by a crash simply fails to decode.
                if let e = try? dec.decode(CullJournalEvent.self, from: Data(line)) { result.append(e) }
            }
        }
        return result
    }

    /// One summary per run, newest first. Unfinished runs get a partial summary from their moves.
    static func runs(in copy: URL) throws -> [CullRunSummary] {
        struct Acc {
            var run: (date: Date, model: CullModel)?
            var moved = Set<String>()
            var finished: CullRunSummary?
            var undone = false
        }
        var order: [UUID] = []
        var acc: [UUID: Acc] = [:]
        func touch(_ id: UUID) { if acc[id] == nil { acc[id] = Acc(); order.append(id) } }
        for e in try events(in: copy) {
            switch e {
            case .run(let id, let date, let model, _):
                touch(id); acc[id]?.run = (date, model)
            case .moved(let id, _, _, _, _, _, let photoID):
                touch(id); acc[id]?.moved.insert(photoID)
            case .movedPair(let id, _, _, _, _, let photoID):
                touch(id); acc[id]?.moved.insert(photoID)
            case .intent(let id, _, _, _, _):
                touch(id)
            case .finished(let id, let summary):
                touch(id); acc[id]?.finished = summary
            case .undone(let id, _):
                touch(id); acc[id]?.undone = true
            case .restored, .restoreSkipped:
                break
            }
        }
        var out: [CullRunSummary] = []
        for id in order {
            guard let a = acc[id] else { continue }
            if var s = a.finished {
                s.undone = a.undone
                out.append(s)
            } else if let r = a.run {
                out.append(CullRunSummary(runID: id, date: r.date, model: r.model, photos: a.moved.count,
                                          rejected: a.moved.count, groupsDone: 0, groupsTotal: 0,
                                          spentUSD: 0, undone: a.undone, status: "failed"))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    struct MoveEntry: Equatable {
        let from: String
        let to: String
        /// Only an `intent` was journaled: the rename may or may not have happened.
        let intentOnly: Bool
        let size: Int64?
        /// The photo this member belongs to, so a pair is restored together.
        var photoID: String? = nil
    }

    /// Moves of a run that haven't been restored, in the order they were made. Intents without a
    /// matching movedPair or restored are included as recovery candidates.
    static func moveEntries(runID: UUID, in copy: URL) throws -> [MoveEntry] {
        var out: [MoveEntry] = []
        for e in try events(in: copy) {
            switch e {
            case .moved(let id, let from, let to, _, _, _, let photoID) where id == runID:
                out.append(MoveEntry(from: from, to: to, intentOnly: false, size: nil, photoID: photoID))
            case .intent(let id, let from, let to, let photoID, let size) where id == runID:
                out.removeAll { $0.from == from }
                out.append(MoveEntry(from: from, to: to, intentOnly: true, size: size, photoID: photoID))
            case .movedPair(let id, let members, _, _, _, let photoID) where id == runID:
                for m in members {
                    out.removeAll { $0.from == m.from }
                    out.append(MoveEntry(from: m.from, to: m.to, intentOnly: false, size: nil, photoID: photoID))
                }
            case .restored(let id, let from, _) where id == runID:
                out.removeAll { $0.from == from }
            default:
                break
            }
        }
        return out
    }

    static func moves(runID: UUID, in copy: URL) throws -> [(from: String, to: String)] {
        try moveEntries(runID: runID, in: copy).map { ($0.from, $0.to) }
    }
}
