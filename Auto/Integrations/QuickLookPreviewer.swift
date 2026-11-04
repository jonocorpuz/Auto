import AppKit
import Quartz

/// Pure item-list state for the Quick Look panel, kept separate from AppKit so it can be unit-tested.
struct QuickLookItems: Equatable {
    private(set) var urls: [URL] = []
    private(set) var index = 0

    var isEmpty: Bool { urls.isEmpty }
    var count: Int { urls.count }

    /// Replaces the items and clamps `index` into range. Empty lists are ignored (returns false).
    @discardableResult
    mutating func set(_ urls: [URL], at index: Int) -> Bool {
        guard !urls.isEmpty else { return false }
        self.urls = urls
        self.index = min(max(index, 0), urls.count - 1)
        return true
    }

    func url(at index: Int) -> URL? { urls.indices.contains(index) ? urls[index] : nil }
}

/// Drives the shared Quick Look panel for a list of files. Read-only: Quick Look only opens files
/// to render them.
///
/// The panel must be taken over through the responder chain: AppKit asks a responder
/// (`acceptsPreviewPanelControl`), then calls `beginPreviewPanelControl`, and only then may the
/// data source / delegate be set. `AppDelegate` forwards those three calls to `acceptsControl`,
/// `beginControl` and `endControl`.
final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewer()

    private(set) var items = QuickLookItems()
    private var isControlling = false

    /// Shows the panel on `urls`, starting at `index`. If we already control the panel the items are
    /// swapped in place; otherwise ordering it front makes it ask the responder chain for control.
    func show(_ urls: [URL], at index: Int) {
        guard items.set(urls, at: index), let panel = QLPreviewPanel.shared() else { return }
        if isControlling {
            panel.reloadData()
            panel.currentPreviewItemIndex = items.index
        }
        if panel.isVisible {
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Hides the panel if it's showing.
    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    // MARK: Panel control (called from the responder chain)

    /// Only accept control while there is something to show.
    func acceptsControl() -> Bool { !items.isEmpty }

    func beginControl(of panel: QLPreviewPanel) {
        isControlling = true
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = items.index
    }

    func endControl(of panel: QLPreviewPanel) {
        isControlling = false
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { items.url(at: index) as NSURL? }
    }

    // MARK: QLPreviewPanelDelegate

    /// Space closes the panel again, like Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}
