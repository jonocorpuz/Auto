import SwiftUI

/// The app's main window. Cards will appear in the content area as they are connected.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(nsColor: model.status.tint))
                .frame(width: 10, height: 10)
            Text(model.status.label)
                .font(.headline)
            Spacer()
            if let root = model.workRoot {
                Label(root.lastPathComponent, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .help(root.path)
            } else {
                Button("Choose Work Folder…", action: showSettings)
            }
        }
        .padding()
    }

    private var content: some View {
        ContentUnavailableView(
            "No cards connected",
            systemImage: "sdcard",
            description: Text(model.workRoot == nil
                ? "Choose a work folder to get started, then connect a camera card."
                : "Connect a camera card to back it up.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}

#Preview {
    MainView().environment(AppModel())
}
