import Foundation

nonisolated struct ShootDay: Sendable, Equatable {
    /// `calendar.startOfDay` of the recording day.
    let start: Date
    let fileCount: Int
}

nonisolated enum ShootDays {
    /// Distinct recording days per camera, ascending. Keyed by `MediaFile.cameraID` (the same
    /// value as `Camera.id`); files with an empty `cameraID` group under "".
    static func byCamera(_ files: [MediaFile], calendar: Calendar) -> [String: [ShootDay]] {
        var counts: [String: [Date: Int]] = [:]
        for file in files {
            counts[file.cameraID, default: [:]][calendar.startOfDay(for: file.date), default: 0] += 1
        }
        return counts.mapValues { days in
            days.map { ShootDay(start: $0.key, fileCount: $0.value) }.sorted { $0.start < $1.start }
        }
    }
}
