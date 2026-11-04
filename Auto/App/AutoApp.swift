import SwiftUI

/// Auto lives in the menu bar (LSUIElement = YES, so there is no Dock icon until the window opens).
@main
struct AutoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}
