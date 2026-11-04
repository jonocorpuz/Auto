import Foundation

nonisolated enum CardPhase: Equatable, Sendable {
    case scanning, verifying, needsBackup, ready, copying, backed, failed(String)
    /// Scanned fine but no recognized media. Never backed: there may be files Auto doesn't know.
    case empty
    /// The card (or part of it) couldn't be read, so Auto can't say what's on it.
    case unreadable(String)

    /// Phase straight after a scan when verification can't apply: a scan error wins over
    /// an empty result, and neither ever becomes `.backed`. nil means go on and verify.
    static func afterScan(fileCount: Int, error: String?) -> CardPhase? {
        if let error { return .unreadable(error) }
        if fileCount == 0 { return .empty }
        return nil
    }
}

nonisolated struct CopyPlan: Sendable {
    var jobs: [CopyJob]
    var destinationLabel: String
    var destinationRoot: URL
    var bytes: Int64 { jobs.reduce(0) { $0 + $1.file.size } }
}

/// Pure helpers for naming shoot folders and turning missing files into copy jobs.
nonisolated enum ShootPlanner {
    static let defaultDateFormat = "dd.MM.yy"

    /// "<formatted date> <name>", or just the date when the name is blank.
    static func folderName(date: Date, name: String, dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat.isEmpty ? defaultDateFormat : dateFormat
        let stamp = formatter.string(from: date)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? stamp : "\(stamp) \(trimmed)"
    }

    /// Shoot folder: root/Client/<date name>.
    static func shootURL(root: URL, client: String, date: Date, name: String, dateFormat: String) -> URL {
        root.appendingPathComponent(client.trimmingCharacters(in: .whitespaces))
            .appendingPathComponent(folderName(date: date, name: name, dateFormat: dateFormat))
    }

    /// Footage/Photo/<camera folder> per missing file. Cameras with an empty folder name use their model;
    /// files from unknown cameras go to `fallback`.
    static func jobs(missing: [MediaFile], shoot: URL, cameras: [Camera], fallback: String) -> [CopyJob] {
        var folderFor: [String: String] = [:]
        for camera in cameras {
            let trimmed = camera.folderName.trimmingCharacters(in: .whitespaces)
            folderFor[camera.id] = trimmed.isEmpty ? camera.model : trimmed
        }
        return missing.map { file in
            let section = file.kind == .photo ? "Photo" : "Footage"
            let dir = shoot.appendingPathComponent(section).appendingPathComponent(folderFor[file.cameraID] ?? fallback)
            return CopyJob(file: file, destDir: dir)
        }
    }

    static func plan(jobs: [CopyJob], shoot: URL) -> CopyPlan {
        let labels = Set(jobs.map { $0.destDir.lastPathComponent }).sorted()
        return CopyPlan(jobs: jobs, destinationLabel: labels.joined(separator: ", "), destinationRoot: shoot)
    }

    /// Everything into one chosen folder.
    static func flatPlan(missing: [MediaFile], into dir: URL) -> CopyPlan {
        CopyPlan(jobs: missing.map { CopyJob(file: $0, destDir: dir) }, destinationLabel: dir.lastPathComponent, destinationRoot: dir)
    }

    /// Photos only or video only decides which sections the preview shows.
    static func sections(for missing: [MediaFile]) -> (video: Bool, photo: Bool) {
        (missing.contains { $0.kind != .photo }, missing.contains { $0.kind == .photo })
    }

    /// Client names matching what the user typed (hides the list once it is an exact single match).
    static func suggestions(for typed: String, in clients: [String], limit: Int = 5) -> [String] {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let matches = clients.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        if matches.count == 1, matches[0].caseInsensitiveCompare(trimmed) == .orderedSame { return [] }
        return Array(matches.prefix(limit))
    }
}

/// Aggregate status across cards.
nonisolated enum StatusAggregator {
    enum Result: Equatable, Sendable { case idle, unbacked, copying, backed, error }

    /// Priority: copying > error > unbacked > (anything still verifying, or empty: idle) > backed > idle.
    /// An unreadable card is an error; an empty card is neutral but never lets the total go green.
    /// A failed card is reported as `error` because the user has to act on it; it still means unbacked data,
    /// which `error` outranks so the failure isn't masked by another card needing backup.
    static func aggregate(_ phases: [CardPhase]) -> Result {
        if phases.contains(.copying) { return .copying }
        if phases.contains(where: {
            switch $0 { case .failed, .unreadable: true; default: false }
        }) { return .error }
        if phases.contains(where: { $0 == .needsBackup || $0 == .ready }) { return .unbacked }
        // Never show green while a card's files are still being checksum-checked.
        if phases.contains(.verifying) || phases.contains(.empty) { return .idle }
        if phases.contains(.backed) { return .backed }
        return .idle
    }
}
