import Foundation

/// Options for the next video edit (sync + Resolve build).
nonisolated struct VideoEditSettings: Sendable, Codable, Equatable {
    /// Leave accidental records (very short, black, dark + silent + static) off the timelines. Files are never moved.
    var leaveOutAccidental = true
    /// Line up cameras and recorders by audio, one timeline per event (speech, ceremony).
    var syncByAudio = true
    var model: CullModel = .sonnet
    var maxRunBudgetUSD = 5.0

    static let budgetRange = 0.5...50.0

    func clamped() -> VideoEditSettings {
        var s = self
        s.maxRunBudgetUSD = min(max(maxRunBudgetUSD, Self.budgetRange.lowerBound), Self.budgetRange.upperBound)
        return s
    }
}

nonisolated enum VideoEditSettingsStore {
    static let key = "videoEditSettings"

    static func load(from defaults: UserDefaults) -> VideoEditSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(VideoEditSettings.self, from: data) else { return VideoEditSettings() }
        return s.clamped()
    }

    static func save(_ s: VideoEditSettings, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
}
