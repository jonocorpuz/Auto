import Foundation

/// One row in the shoot browser: a file or folder directly inside the folder being shown.
nonisolated struct ShootEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isFolder: Bool
    let size: Int64
    let date: Date
    /// nil for folders and for files Auto doesn't classify as media (they still show, read-only).
    let kind: MediaKind?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Where a drop onto a folder in the shoot browser lands.
nonisolated enum DropTarget: Equatable, Sendable {
    /// Top level, `Video` or `Photo`: the normal sorted import (camera folders chosen by the planner).
    case sorted
    /// Any deeper folder: copy flat into exactly this folder.
    case exact(URL)
}

/// Read-only listing and path rules for the shoot browser. Listing is cheap I/O, so callers run it
/// from a detached task per navigation. Path rules are lexical (see `ShootPlanner.relativeComponents`).
nonisolated enum ShootBrowser {
    /// Folders first, then everything else; both groups sorted with `localizedStandard`.
    /// Hides dotfiles, `.auto-cull`, and symlinks unless `root` is given and the link resolves inside it.
    /// Symlinks are never followed out of `root`. Unreadable folders list as empty.
    static func list(_ folder: URL, root: URL? = nil) -> [ShootEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        let resolvedRoot = root.map { ShootPlanner.resolvedPath($0) }
        var entries: [ShootEntry] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), name != CullJournal.directoryName else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            var target = url
            if values.isSymbolicLink == true {
                guard let resolvedRoot else { continue }
                let resolved = ShootPlanner.resolvedPath(url)
                guard ShootPlanner.isInside(resolved, root: resolvedRoot) else { continue }
                target = resolved
            }
            guard let targetValues = try? target.resourceValues(forKeys: Set(keys)) else { continue }
            let isFolder = targetValues.isDirectory == true
            entries.append(ShootEntry(url: url,
                                      isFolder: isFolder,
                                      size: isFolder ? 0 : Int64(targetValues.fileSize ?? 0),
                                      date: targetValues.contentModificationDate ?? .distantPast,
                                      kind: isFolder ? nil : MediaTypes.kind(for: url)))
        }
        return entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// `root` followed by one entry per folder between it and `folder`, in order. The first name is
    /// `root`'s own last path component. nil when `folder` is not equal to or inside `root`.
    static func breadcrumb(from root: URL, to folder: URL) -> [(name: String, url: URL)]? {
        guard let rel = ShootPlanner.relativeComponents(folder, to: root) else { return nil }
        var crumbs: [(name: String, url: URL)] = [(root.lastPathComponent, root)]
        var current = root
        for part in rel {
            current = current.appendingPathComponent(part, isDirectory: true)
            crumbs.append((part, current))
        }
        return crumbs
    }

    /// `folder` if it is equal to or inside `root`, otherwise `root`. `../` escapes are resolved
    /// lexically first, so the browser can never navigate above the shoot.
    static func clamp(_ folder: URL, root: URL) -> URL {
        guard let rel = ShootPlanner.relativeComponents(folder, to: root) else { return root }
        var current = root
        for part in rel { current = current.appendingPathComponent(part, isDirectory: true) }
        return current
    }

    /// Top level, `Video` and `Photo` (exact case) drop sorted; any other folder, including anything
    /// under `_Rejects` or `.auto-cull`, drops exactly there (the planner refuses reserved targets).
    /// A folder outside `root` is treated as the top level.
    static func dropTarget(for folder: URL, root: URL) -> DropTarget {
        guard let rel = ShootPlanner.relativeComponents(folder, to: root) else { return .sorted }
        if rel.isEmpty || (rel.count == 1 && (rel[0] == "Video" || rel[0] == "Photo")) { return .sorted }
        return .exact(clamp(folder, root: root))
    }
}
