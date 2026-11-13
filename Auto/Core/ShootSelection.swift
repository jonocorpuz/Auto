import Foundation

/// Which (camera, recording day) pairs the user wants in a shoot. An explicit include-set, so
/// pairs that appear later (e.g. a new scan) are not auto-included.
nonisolated struct ShootSelection: Sendable, Equatable {
    struct Pair: Hashable, Sendable {
        let cameraID: String
        let day: Date
    }

    /// Group for files with no camera, or a camera not in `knownCameraIDs`.
    static let otherID = ""

    let calendar: Calendar
    let knownCameraIDs: Set<String>
    private(set) var included: Set<Pair>

    /// Everything checked.
    init(missing: [MediaFile], cameras: [Camera], calendar: Calendar) {
        self.calendar = calendar
        self.knownCameraIDs = Set(cameras.map(\.id))
        self.included = []
        for file in missing { included.insert(pair(file)) }
    }

    /// Only the pairs (every camera) whose day is `onlyDay`'s day; all other days stay unchecked.
    init(files: [MediaFile], cameras: [Camera], calendar: Calendar, onlyDay: Date) {
        self.calendar = calendar
        self.knownCameraIDs = Set(cameras.map(\.id))
        self.included = []
        let day = calendar.startOfDay(for: onlyDay)
        for file in files {
            let filePair = pair(file)
            if filePair.day == day { included.insert(filePair) }
        }
    }

    func groupID(_ file: MediaFile) -> String {
        knownCameraIDs.contains(file.cameraID) ? file.cameraID : Self.otherID
    }

    func pair(_ file: MediaFile) -> Pair {
        Pair(cameraID: groupID(file), day: calendar.startOfDay(for: file.date))
    }

    func contains(_ file: MediaFile) -> Bool { included.contains(pair(file)) }

    func filter(_ files: [MediaFile]) -> [MediaFile] { files.filter(contains) }

    func isIncluded(camera: String) -> Bool { included.contains { $0.cameraID == camera } }

    func isIncluded(camera: String, day: Date) -> Bool {
        included.contains(Pair(cameraID: camera, day: calendar.startOfDay(for: day)))
    }

    /// Checking re-checks all given days; unchecking removes every day of the camera.
    mutating func setCamera(_ id: String, included on: Bool, days: [Date]) {
        if on {
            for day in days { included.insert(Pair(cameraID: id, day: calendar.startOfDay(for: day))) }
        } else {
            included = included.filter { $0.cameraID != id }
        }
    }

    mutating func set(camera: String, day: Date, included on: Bool) {
        let changed = Pair(cameraID: camera, day: calendar.startOfDay(for: day))
        if on { included.insert(changed) } else { included.remove(changed) }
    }

    /// Recording days grouped by `groupID` (unknown cameras under `otherID`), ascending.
    static func days(missing: [MediaFile], cameras: [Camera], calendar: Calendar) -> [String: [ShootDay]] {
        let known = Set(cameras.map(\.id))
        let regrouped = missing.map { file -> MediaFile in
            guard !known.contains(file.cameraID) else { return file }
            return MediaFile(url: file.url, size: file.size, date: file.date, kind: file.kind,
                             cameraID: otherID, cardID: file.cardID)
        }
        return ShootDays.byCamera(regrouped, calendar: calendar)
    }
}
