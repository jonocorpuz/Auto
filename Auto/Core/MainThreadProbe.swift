import Foundation

/// Records whether instrumented async engines ever ran on the main thread, so tests can
/// assert heavy file walks stay off the main actor. One lock per call; cheap enough to keep on.
nonisolated final class MainThreadProbe: @unchecked Sendable {
    static let shared = MainThreadProbe()

    private let lock = NSLock()
    private var ranOnMain: [String: Bool] = [:]

    func mark(_ name: String) {
        let onMain = pthread_main_np() != 0
        lock.lock(); ranOnMain[name] = (ranOnMain[name] ?? false) || onMain; lock.unlock()
    }

    /// nil if `name` never ran; true if any call ran on the main thread.
    func everRanOnMain(_ name: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return ranOnMain[name]
    }
}
