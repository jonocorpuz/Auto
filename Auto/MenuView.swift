import SwiftUI

/// The popover shown when clicking the menu bar icon.
struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Auto").font(.headline)
                Spacer()
                Label(model.status.label, systemImage: model.status.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let root = model.workRoot {
                Label(root.lastPathComponent, systemImage: "folder")
                    .font(.callout)
            } else {
                Text("No work folder set yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 300)
    }
}

#Preview {
    MenuView().environment(AppModel())
}
