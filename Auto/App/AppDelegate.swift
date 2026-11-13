import AppKit
import Quartz
import SwiftUI

/// Owns the status item and the main window. Left-click opens the app; right-click shows a small menu.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.applyAppearance()
        updateIcon()
        observeStatus()
        model.openMainWindow = { [weak self] in self?.openMainWindow() }
        model.openSettings = { [weak self] in self?.openSettings() }
        model.start()
        // Dev convenience: a fixture card also opens the window at launch, since no mount event fires for it.
        if model.workRoot == nil || VolumeWatcher.fixtureCard(from: .standard) != nil { openMainWindow() }
    }

    /// Launching the app again (Finder, Spotlight, `open`) brings the window forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Status item

    private func observeStatus() {
        withObservationTracking {
            _ = model.status
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateIcon()
                self?.observeStatus()
            }
        }
    }

    /// The menu bar mark: an "a" with a status-coloured dot.
    private func updateIcon() {
        let title = NSMutableAttributedString(string: "a", attributes: Self.iconAttributes(
            size: 16, weight: .heavy, color: .labelColor))
        title.append(NSAttributedString(string: ".", attributes: Self.iconAttributes(
            size: 18, weight: .black, color: model.status.tint)))
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = "Auto: \(model.status.label)"
    }

    private static func iconAttributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .baselineOffset: 1]
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            openMainWindow()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Auto", action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Auto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attach only for this click so left-click keeps its action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: Windows

    private static let mainWindowMinSize = NSSize(width: 820, height: 540)
    private static let mainWindowDefaultSize = NSSize(width: 1100, height: 720)

    @objc func openMainWindow() {
        if mainWindow == nil { mainWindow = makeMainWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        model.mainWindowVisible = true
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView().environment(model)))
        window.title = "Auto"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentMinSize = Self.mainWindowMinSize
        window.setContentSize(Self.mainWindowDefaultSize)
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Settings is a tab in the main window. Owned here (not SwiftUI's `openSettings`), which is unreliable
    /// from a status-item menu in an accessory app.
    @objc func openSettings() {
        model.selectedTab = .settings
        openMainWindow()
    }

    // MARK: Quick Look panel control
    // QLPreviewPanel walks the responder chain of the key window (views, window, window delegate) and
    // then the application delegate, asking each for control. We are both the main window's delegate
    // and the application delegate, so whichever way it walks, it finds us.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        QuickLookPreviewer.shared.acceptsControl()
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookPreviewer.shared.beginControl(of: panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookPreviewer.shared.endControl(of: panel)
    }

    // MARK: Main window lifecycle

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
        // The window object survives a close, so SwiftUI's onDisappear may never fire: stop background work.
        model.mainWindowVisible = false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        model.mainWindowVisible = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        model.mainWindowVisible = true
    }
}
