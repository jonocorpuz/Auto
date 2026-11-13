import Foundation

/// Sets aside a file Auto wrote but can no longer read, so a fresh one can be started without losing it.
nonisolated enum CorruptFileQuarantine {
    /// Renames `url` to `<name>.corrupt-<timestamp>` next to it (adding `-1`, `-2`, ... while that name
    /// is taken). Never deletes. `description` names the file in the log when the rename fails.
    static func quarantine(_ url: URL, description: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent + ".corrupt-" + timestamp
        var target = folder.appendingPathComponent(baseName)
        var suffix = 1
        while fileManager.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(baseName + "-\(suffix)")
            suffix += 1
        }

        do {
            try fileManager.moveItem(at: url, to: target)
        } catch {
            NSLog("Auto: could not back up corrupt \(description): \(error)")
        }
    }
}
