import SwiftUI

/// The app's main window: connected cards, the working drive and any other drives.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $model.editingShoot) { card in
            NewShootView(card: card)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: Color(nsColor: model.status.tint))
            Text(model.status.label).font(.headline)
            Spacer()
            if let root = model.workRoot {
                Label(root.lastPathComponent, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .help(root.path)
            }
            Button("Settings…", systemImage: "gearshape", action: showSettings)
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        if model.workRoot == nil {
            ContentUnavailableView {
                Label("Where do shoots go?", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Pick your client work folder on your working drive.")
            } actions: {
                Button("Choose Work Folder…") { model.setWorkRoot() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.cards.isEmpty {
                        ContentUnavailableView(
                            "No cards connected",
                            systemImage: "sdcard",
                            description: Text("Connect a camera card and Auto checks it against \(model.workingDriveName).")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ForEach(model.cards) { card in CardRow(card: card) }
                    }
                    drivesSection
                }
                .padding()
            }
        }
    }

    @ViewBuilder private var drivesSection: some View {
        if !model.drives.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Drives").font(.subheadline).foregroundStyle(.secondary)
                ForEach(model.drives) { drive in
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        Text(drive.name)
                        Spacer()
                        if drive.url == model.workingVolume {
                            Text("Working drive").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}

#Preview {
    MainView().environment(AppModel())
}
