import Foundation

/// Where one shoot's mirror check / Sync Now stands. Owned by `AppModel.syncStates`.
enum ShootSyncState: Equatable {
    /// One copy: nothing to compare.
    case single
    /// Not checkable right now (a copy is offline or unreadable, a copy is running, not checked yet). The reason is shown to the user.
    case unknown(String)
    /// `partial` is the size-pass report: provisional (never "in sync", never drives Sync Now), but it may already be out of sync.
    case checking(SyncProgress, partial: ShootSyncReport?)
    /// A complete check. `depth == .checksums` unless `notChecked` is set.
    case done(ShootSyncReport, at: Date)
    case syncing(CopyProgress)
    case failed(String)
}

/// What the UI shows for a shoot, derived from `ShootSyncState` plus the last deep verification.
enum SyncBadge: Equatable {
    /// Single copy: no badge.
    case none
    /// GREEN: all copies match. `deepVerifiedAt` is when every byte was last re-read (nil = never, or not since this build).
    case inSync(copies: Int, checkedAt: Date, deepVerifiedAt: Date?)
    /// YELLOW.
    case outOfSync(missing: Int, conflicts: Int)
    /// GREY.
    case unknown(reason: String)
    case checking(SyncProgress)
    case syncing(CopyProgress)
}

/// `lastDeepVerify` per shoot: a small JSON file next to `checksums.json`. It is only a note for the UI, so an
/// unreadable file means "never verified" (and is left alone until the next save replaces it).
nonisolated enum SyncMetaStore {
    private struct File: Codable {
        var version = 1
        var deepVerified: [String: Date] = [:]
    }

    static func load(from url: URL) -> [UUID: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return [:] }
        var result: [UUID: Date] = [:]
        for (key, date) in file.deepVerified { if let id = UUID(uuidString: key) { result[id] = date } }
        return result
    }

    static func save(_ dates: [UUID: Date], to url: URL) {
        var file = File()
        for (id, date) in dates { file.deepVerified[id.uuidString] = date }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
