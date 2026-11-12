import Foundation

/// How views read a shoot's availability and label it.
extension ShootItem {
    /// The shoot's folder was found on a connected drive, so files can be added to it.
    var isConfirmedOnline: Bool {
        if case .online = availability { return true }
        return false
    }

    /// Online, or not resolved yet. Shoots are shown at full strength until they are known to be
    /// offline or missing.
    var isOnlineOrUnresolved: Bool {
        availability == nil || isConfirmedOnline
    }

    /// "Brand film — Mar 22, 2026", for menus that list shoots.
    var menuLabel: String {
        "\(record.name) — \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
