import Foundation

nonisolated enum ShootError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case corruptSidecar
    case folderExistsWithoutSidecar(String)
    case alreadyAShoot(UUID)
    case parentMissing
    case onCard
    case notAFolder(String)
    case sidecarMismatch
    case shootOffline
    case invalidName

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "This shoot was made by a newer version of Auto. Update Auto to open it."
        case .corruptSidecar:
            return "This shoot's info file is damaged and can't be read."
        case .folderExistsWithoutSidecar(let name):
            return "A folder named \"\(name)\" already exists and isn't an Auto shoot."
        case .alreadyAShoot:
            return "That folder is already an Auto shoot."
        case .parentMissing:
            return "That location isn't available. Connect the drive or choose another folder."
        case .onCard:
            return "Shoots can't be stored on a camera card."
        case .notAFolder(let name):
            return "\"\(name)\" isn't a folder."
        case .sidecarMismatch:
            return "The shoot folder doesn't match its saved info."
        case .shootOffline:
            return "This shoot's drive isn't connected."
        case .invalidName:
            return "Enter a shoot name that works as a folder name."
        }
    }
}

/// The `.auto-shoot.json` file stored inside a shoot folder.
nonisolated struct ShootSidecar: Sendable, Equatable, Codable {
    static let fileName = ".auto-shoot.json"
    static let currentVersion = 1

    var version: Int
    var id: UUID
    var name: String
    /// "yyyy-MM-dd", calendar-local.
    var day: String
    var createdAt: Date

    static func encode(_ s: ShootSidecar) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(s)
    }

    static func decode(_ data: Data) throws -> ShootSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar: ShootSidecar
        do {
            sidecar = try decoder.decode(ShootSidecar.self, from: data)
        } catch {
            throw ShootError.corruptSidecar
        }
        if sidecar.version > currentVersion {
            throw ShootError.unsupportedVersion(sidecar.version)
        }
        return sidecar
    }

    private static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar).string(from: date)
    }

    func date(in calendar: Calendar) -> Date? {
        guard let parsed = Self.formatter(calendar).date(from: day) else { return nil }
        return calendar.startOfDay(for: parsed)
    }

    func shoot(folder: URL, calendar: Calendar) -> Shoot? {
        guard let date = date(in: calendar) else { return nil }
        return Shoot(id: id, name: name, date: date, folder: folder)
    }
}
