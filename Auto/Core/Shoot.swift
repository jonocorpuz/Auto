import Foundation

/// A shoot: a named folder for one day of footage.
nonisolated struct Shoot: Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Local start of day.
    var date: Date
    var folder: URL
}
