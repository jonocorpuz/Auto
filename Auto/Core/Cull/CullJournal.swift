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
        return dir.appendingPathComponent(fileNameDateStamp(for: Date()) + suffix)
    }

    /// UTC timestamp used as the leading part of journal and analysis file names, e.g. `2026-01-31T142501Z`.
    static func fileNameDateStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: date)
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

    // MARK: - Writing

    static func append(_ event: CullJournalEvent, runID: UUID, in copy: URL) throws {
        let dir = directory(in: copy)
        try ShootPlanner.createDirectories([dir], root: copy, cardVolumes: [])
        var line = try encoder().encode(event)
        line.append(newline)
        let path = url(runID: runID, in: copy).path
        var existing = stat()
        let isNewFile = lstat(path, &existing) != 0
        let fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        // A crash can leave a torn last line; start a fresh line so the new event stays decodable.
        if lastByteIsNotNewline(fd) { line.insert(newline, at: 0) }
        try writeFully(line, to: fd, path: path)
        guard fullSync(fd) else { throw posixError(path) }
        if isNewFile { syncDirectory(dir) }
    }

    private static let newline: UInt8 = 0x0A

    /// True when the file is non-empty and doesn't end in a newline.
    private static func lastByteIsNotNewline(_ fd: Int32) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return false }
        var last: UInt8 = newline
        return pread(fd, &last, 1, info.st_size - 1) == 1 && last != newline
    }

    /// Writes every byte, retrying on EINTR.
    private static func writeFully(_ data: Data, to fd: Int32, path: String) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path)
                }
                offset += written
            }
        }
    }

    /// Makes a newly created file's directory entry durable too. Best effort.
    private static func syncDirectory(_ dir: URL) {
        let dirFD = open(dir.path, O_RDONLY | O_CLOEXEC)
        guard dirFD >= 0 else { return }
        _ = fullSync(dirFD)
        close(dirFD)
    }

    /// F_FULLFSYNC flushes the drive cache; plain fsync is the fallback where unsupported.
    static func fullSync(_ fd: Int32) -> Bool {
        fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
    }

    private static func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }

    // MARK: - Reading

    /// Every decodable event in the copy's journal, in file order (files sorted by name).
    static func events(in copy: URL) throws -> [CullJournalEvent] {
        let dir = directory(in: copy)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let jsonDecoder = decoder()
        let journalNames = names.filter { $0.hasSuffix(".jsonl") }.sorted()
        var result: [CullJournalEvent] = []
        for name in journalNames {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            for line in data.split(separator: newline) {
                // A line cut short by a crash simply fails to decode.
                if let event = try? jsonDecoder.decode(CullJournalEvent.self, from: Data(line)) { result.append(event) }
            }
        }
        return result
    }

    /// One summary per run, newest first. Unfinished runs get a partial summary from their moves.
    static func runs(in copy: URL) throws -> [CullRunSummary] {
        var runOrder: [UUID] = []
        var runsByID: [UUID: RunEvents] = [:]
        func track(_ id: UUID) {
            guard runsByID[id] == nil else { return }
            runsByID[id] = RunEvents()
            runOrder.append(id)
        }
        for event in try events(in: copy) {
            switch event {
            case .run(let id, let date, let model, _):
                track(id); runsByID[id]?.start = (date, model)
            case .moved(let id, _, _, _, _, _, let photoID):
                track(id); runsByID[id]?.movedPhotoIDs.insert(photoID)
            case .movedPair(let id, _, _, _, _, let photoID):
                track(id); runsByID[id]?.movedPhotoIDs.insert(photoID)
            case .intent(let id, _, _, _, _):
                track(id)
            case .finished(let id, let summary):
                track(id); runsByID[id]?.finished = summary
            case .undone(let id, _):
                track(id); runsByID[id]?.undone = true
            case .restored, .restoreSkipped:
                break
            }
        }
        let summaries = runOrder.compactMap { id in runsByID[id]?.summary(runID: id) }
        return summaries.sorted { $0.date > $1.date }
    }

    /// What the journal says about one run, gathered while reading it.
    private struct RunEvents {
        var start: (date: Date, model: CullModel)?
        var movedPhotoIDs = Set<String>()
        var finished: CullRunSummary?
        var undone = false

        /// The finished summary, or a partial "failed" one built from the moves of a run that never finished.
        /// nil when even the run's start line is missing.
        func summary(runID: UUID) -> CullRunSummary? {
            if var finished {
                finished.undone = undone
                return finished
            }
            guard let start else { return nil }
            return CullRunSummary(runID: runID, date: start.date, model: start.model, photos: movedPhotoIDs.count,
                                  rejected: movedPhotoIDs.count, groupsDone: 0, groupsTotal: 0,
                                  spentUSD: 0, undone: undone, status: "failed")
        }
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
        for event in try events(in: copy) {
            switch event {
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
}
