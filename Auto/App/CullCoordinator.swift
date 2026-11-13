import Foundation

/// Per-shoot cull state shown by the UI.
enum CullState {
    case idle
    /// Waiting for an ingest or sync to finish (or for the apply lock).
    case waiting(String)
    case running(CullProgress)
    case finished(CullOutcome)
}

/// Wake-up list shared by everything that waits on "ingest/sync/apply state changed". Waiters re-check
/// their own condition after every wake. Main actor only, so a check and the following `wait()` are atomic.
@MainActor
final class CullWaiters {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Suspends until the next `wake()`. Throws `CancellationError` if the task is cancelled meanwhile.
    func wait() async throws {
        let key = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[key] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.cancel(key) }
        }
    }

    func wake() {
        let woken = waiters
        waiters = [:]
        for continuation in woken.values { continuation.resume() }
    }

    private func cancel(_ key: UUID) {
        waiters.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }
}

/// Persistence of the cull settings (JSON under `settings.cull.v1`).
enum CullSettingsStore {
    static let key = "settings.cull.v1"

    static func load(from defaults: UserDefaults) -> CullSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CullSettings.self, from: data) else { return CullSettings() }
        return settings.clamped()
    }

    static func save(_ settings: CullSettings, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(settings.clamped()) { defaults.set(data, forKey: key) }
    }
}
