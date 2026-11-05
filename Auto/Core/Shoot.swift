import Foundation

/// A shoot: a named folder for one day of footage.
nonisolated struct Shoot: Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Local start of day.
    var date: Date
    /// The copy Auto reads from: the first online copy in record order.
    var folder: URL
    /// The other online copies, each on a distinct volume.
    var mirrors: [URL] = []
    var copies: [URL] { [folder] + mirrors }
}
