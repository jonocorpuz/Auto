import Foundation
import Observation

/// Shared app state. Views read it via `@Environment(AppModel.self)`.
@Observable
final class AppModel {
    enum Status {
        case idle, working, done, error

        var symbol: String {
            switch self {
            case .idle: "a.circle"
            case .working: "arrow.triangle.2.circlepath.circle"
            case .done: "checkmark.circle"
            case .error: "exclamationmark.circle"
            }
        }

        var label: String {
            switch self {
            case .idle: "Idle"
            case .working: "Working…"
            case .done: "Done"
            case .error: "Something went wrong"
            }
        }
    }

    var status: Status = .idle

    /// Root folder Auto works in. Persisted in UserDefaults.
    var workRoot: URL? {
        didSet { UserDefaults.standard.set(workRoot?.path, forKey: Keys.workRoot) }
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Keys.workRoot) {
            workRoot = URL(fileURLWithPath: path)
        }
    }

    private enum Keys {
        static let workRoot = "workRoot"
    }
}
