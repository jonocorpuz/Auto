import AppKit
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
        updateIcon()
        observeStatus()
        model.openMainWindow = { [weak self] in self?.openMainWindow() }
        model.start()
        if model.workRoot == nil { openMainWindow() }
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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.setContentSize(NSSize(width: 900, height: 600))
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

    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
