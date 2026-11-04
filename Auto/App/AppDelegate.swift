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

    private func updateIcon() {
        let title = NSMutableAttributedString(
            string: "a",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .heavy),
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: 1,
            ]
        )
        title.append(NSAttributedString(
            string: ".",
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .black),
                .foregroundColor: model.status.tint,
                .baselineOffset: 1,
            ]
        ))
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = "Auto: \(model.status.label)"
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

    @objc func openMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: MainView().environment(model)
            ))
            window.title = "Auto"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentMinSize = NSSize(width: 820, height: 540)
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.setFrameAutosaveName("MainWindow")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
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

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
