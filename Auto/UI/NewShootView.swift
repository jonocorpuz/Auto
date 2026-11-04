import SwiftUI

/// Sheet for creating a shoot folder for a card: a name, per-camera folders and a live preview.
struct NewShootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var shootName = ""
    @State private var cameras: [Camera] = []
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var isValid: Bool { model.isValidShootName(shootName) }
    private var folders: [PlannedFolder] { model.shootFolders(card: card, name: shootName, cameras: cameras) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Shoot").font(.system(size: 20, weight: .semibold))
                Text("Creates folders in \(model.workRootBreadcrumb)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            nameCard
            if !card.cameras.isEmpty { camerasSection }
            foldersSection

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.editingShoot = nil }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Create Shoot") { create() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .frame(width: 160)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.panel)
        .onAppear {
            cameras = card.cameras
            nameFocused = true
        }
    }

    // MARK: Name

    private var nameCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shoot name").font(.system(size: 13, weight: .medium))
                TextField("Shoot name", text: $shootName, prompt: Text("e.g. Brand film"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .inputStyle(focused: nameFocused)
                    .focused($nameFocused)
                    .onSubmit { if isValid { create() } }
                Text(nameCaption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var nameCaption: String {
        if shootName.trimmingCharacters(in: .whitespaces).isEmpty { return "The shoot folder is named after this." }
        guard isValid else { return "Not a usable folder name." }
        if let shoot = folders.first, shoot.exists {
            return "Adds to the existing “\(shoot.name)” folder. Nothing in it is overwritten."
        }
        return "Creates a new folder."
    }

    // MARK: Cameras

    private var camerasSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Cameras") {
                Text("\(card.missing.count) files").font(.caption).foregroundStyle(.secondary)
            }
            SurfaceCard(padding: 12) {
                VStack(spacing: 0) {
                    ForEach(Array($cameras.enumerated()), id: \.element.id) { index, $cam in
                        if index > 0 {
                            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 10)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "video")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cam.model).lineLimit(1)
                                Text("\(fileCount(cam)) files").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            TextField("Folder", text: $cam.folderName)
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .inputStyle(focused: false)
                                .frame(width: 160)
                        }
                    }
                }
            }
        }
    }

    private func fileCount(_ camera: Camera) -> Int {
        card.missing.filter { $0.cameraID == camera.id }.count
    }

    // MARK: Folders

    private var foldersSection: some View {
        let rows = folders
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Folders")
            SurfaceCard {
                if rows.isEmpty {
                    Text("Enter a shoot name to preview the folders.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { folderRow($0) }
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: PlannedFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(folder.exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
            Text(folder.name).fontWeight(folder.depth == 0 ? .semibold : .regular)
            Text(folder.exists ? "already there" : "new")
                .font(.caption)
                .foregroundStyle(folder.exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(folder.exists ? Theme.surfaceMuted : Theme.accent.opacity(0.12)))
            Spacer()
            if folder.fileCount > 0 {
                Text("\(folder.fileCount) \(folder.isPhoto ? "photos" : "files")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(folder.depth) * 18)
    }

    private func create() {
        do {
            try model.createShoot(card: card, name: shootName, cameras: cameras)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension View {
    /// Rounded text input look used inside cards.
    func inputStyle(focused: Bool) -> some View {
        padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(focused ? Theme.accent : Theme.border))
            .frame(maxWidth: .infinity)
    }
}
