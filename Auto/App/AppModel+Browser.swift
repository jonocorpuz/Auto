import AppKit
import Foundation

/// Card browser: grouping the browsed card's files, and the read-only file actions on them.
extension AppModel {
    private static let thumbnailMaxPixels: CGFloat = 320
    /// The preview cache is emptied once it holds this many images.
    private static let thumbnailCacheLimit = 300

    // MARK: Groups

    /// The browsed card's files grouped into "Not Backed Up", then by the shoot holding their copy.
    /// Memoized on its inputs, so selection clicks and copy-progress ticks don't regroup the card.
    func browserGroups(for card: Card) -> [CardBrowser.Group] {
        // Every registered shoot, online or not: a copy in a shoot that just went offline still belongs
        // to it until the re-verify drops it, rather than falling into "Backed Up Elsewhere".
        // A missing or mismatched shoot's folder is no longer that shoot: it isn't a group.
        let refs = shoots.compactMap { item -> CardBrowser.ShootRef? in
            let folder: URL
            switch item.availability {
            case .online(let shoot)?: folder = shoot.folder
            case .missing?, .mismatch?: return nil
            case .offline?, nil: folder = URL(fileURLWithPath: item.record.path, isDirectory: true)
            }
            return CardBrowser.ShootRef(id: item.id, name: item.record.name, folder: folder)
        }
        // A `.failed` shoot (its coverage check couldn't run) still gets a group through the lexical
        // `card.backups` fallback in `CardBrowser.group`: that copy was checksum-verified by the card
        // verifier, so hiding it would mislead. Only checked memberships can add *more* shoots.
        // Only complete, verified results, and only for the card being browsed.
        var memberships: [UUID: Set<URL>] = [:]
        if card.id == browsingCardID {
            for (id, state) in browserMembership {
                if case .done(let urls, _) = state { memberships[id] = urls }
            }
        }
        let key = BrowserKey(cardID: card.id, files: card.files, backups: card.backups,
                             missing: Set(card.missing.map(\.url)), shoots: refs, memberships: memberships)
        if let browserCache, browserCache.key == key { return browserCache.groups }
        let groups = CardBrowser.group(files: card.files, backups: card.backups, missing: key.missing,
                                       shoots: refs, memberships: memberships)
        browserCache = (key, groups)
        return groups
    }

    struct BrowserKey: Equatable {
        let cardID: Card.ID
        let files: [MediaFile]
        let backups: [URL: URL]
        let missing: Set<URL>
        let shoots: [CardBrowser.ShootRef]
        let memberships: [UUID: Set<URL>]
    }

    /// Verified copies to reveal for `files`: inside a shoot group, that shoot's own copies (when its
    /// check is done); otherwise the card's backup verdict.
    func browserBackupCopies(_ files: [MediaFile], in kind: CardBrowser.GroupKind?) -> [URL] {
        if case .shoot(let id)? = kind, case .done(_, let copies)? = browserMembership[id] {
            return files.compactMap { copies[$0.url] }
        }
        guard let card = browsingCard else { return [] }
        return files.compactMap { card.backups[$0.url] }
    }

    // MARK: File actions

    /// Shows files in Finder (read-only).
    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Opens the Quick Look panel on `urls`, starting at `index` (read-only). With `toggle` (Space),
    /// a press while the panel is up closes it, like Finder; explicit opens always switch to `urls`.
    func quickLook(_ urls: [URL], at index: Int = 0, toggle: Bool = false) {
        if toggle, QuickLookPreviewer.shared.isVisible {
            QuickLookPreviewer.shared.close()
        } else {
            QuickLookPreviewer.shared.show(urls, at: index)
        }
    }

    /// Preview for one file in the card browser (read-only QuickLook; nil when none can be made).
    /// Keyed by file identity (card + path + size + mtime), so a different card with the same volume
    /// name and file names never shows this card's pictures.
    func fileThumbnail(for file: MediaFile) async -> CGImage? {
        let key = file.identity
        if let cached = fileThumbnails[key] { return cached }
        if missingThumbnails.contains(key) { return nil }
        let image: CGImage
        do {
            image = try await thumbnails.thumbnail(for: file.url, maxPixels: Self.thumbnailMaxPixels)
        } catch {
            // A cancelled request says nothing about the file: let it be retried.
            let wasCancelled = error is CancellationError || Task.isCancelled
            if !wasCancelled { missingThumbnails.insert(key) }
            return nil
        }
        if fileThumbnails.count >= Self.thumbnailCacheLimit { fileThumbnails.removeAll() }
        fileThumbnails[key] = image
        return image
    }
}
