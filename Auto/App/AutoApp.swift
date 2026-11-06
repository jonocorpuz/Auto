import SwiftUI

/// Auto lives in the menu bar (LSUIElement = YES, so there is no Dock icon until the window opens).
/// AppDelegate owns the main and settings windows. SwiftUI still needs one scene, so the Settings scene is
/// an empty placeholder and its menu item is replaced so Cmd-comma opens the AppDelegate's window instead.
@main
struct AutoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
