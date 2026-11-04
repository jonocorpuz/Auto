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
        for f in missing { included.insert(pair(f)) }
    }

    func groupID(_ f: MediaFile) -> String {
        knownCameraIDs.contains(f.cameraID) ? f.cameraID : Self.otherID
    }

    func pair(_ f: MediaFile) -> Pair {
        Pair(cameraID: groupID(f), day: calendar.startOfDay(for: f.date))
    }

    func contains(_ f: MediaFile) -> Bool { included.contains(pair(f)) }

    func filter(_ files: [MediaFile]) -> [MediaFile] { files.filter(contains) }

    func isIncluded(camera: String) -> Bool { included.contains { $0.cameraID == camera } }

    func isIncluded(camera: String, day: Date) -> Bool {
        included.contains(Pair(cameraID: camera, day: calendar.startOfDay(for: day)))
    }

    /// Checking re-checks all given days; unchecking removes every day of the camera.
    mutating func setCamera(_ id: String, included on: Bool, days: [Date]) {
        if on {
            for d in days { included.insert(Pair(cameraID: id, day: calendar.startOfDay(for: d))) }
        } else {
            included = included.filter { $0.cameraID != id }
        }
    }

    mutating func set(camera: String, day: Date, included on: Bool) {
        let p = Pair(cameraID: camera, day: calendar.startOfDay(for: day))
        if on { included.insert(p) } else { included.remove(p) }
    }

    var isEmpty: Bool { included.isEmpty }

    /// Recording days grouped by `groupID` (unknown cameras under `otherID`), ascending.
    static func days(missing: [MediaFile], cameras: [Camera], calendar: Calendar) -> [String: [ShootDay]] {
        let known = Set(cameras.map(\.id))
        let regrouped = missing.map { f -> MediaFile in
            guard !known.contains(f.cameraID) else { return f }
            return MediaFile(url: f.url, size: f.size, date: f.date, kind: f.kind,
                             cameraID: otherID, cardID: f.cardID)
        }
        return ShootDays.byCamera(regrouped, calendar: calendar)
    }
}
