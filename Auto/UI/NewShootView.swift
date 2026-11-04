import SwiftUI

/// Sheet for creating a shoot folder for a card: a name, per-camera folders and a live preview.
struct NewShootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var shootName = ""
    @State private var cameras: [Camera] = []
    @State private var error: String?
    @State private var selection: ShootSelection?
    @State private var days: [String: [ShootDay]] = [:]
    @FocusState private var nameFocused: Bool

    private var currentSelection: ShootSelection {
        selection ?? ShootSelection(missing: card.missing, cameras: card.cameras, calendar: model.calendar)
    }
    private var isValid: Bool { model.isValidShootName(shootName) }
    private var preview: ShootPreview {
        model.shootPreview(card: card, name: shootName, cameras: cameras, selection: currentSelection)
    }

    /// Applies a change to the selection, writing it back to state.
    private func mutate(_ change: (inout ShootSelection) -> Void) {
        var sel = currentSelection
        change(&sel)
        selection = sel
    }

    var body: some View {
        let preview = preview
        let sel = currentSelection
        let canCreate = isValid && !sel.isEmpty && preview.problem == nil
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Shoot").font(.system(size: 20, weight: .semibold))
                Text("Creates folders in \(model.workRootBreadcrumb)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            nameCard(preview)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !card.cameras.isEmpty { camerasSection(preview, sel) }
                    foldersSection(preview, sel)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)

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
                    .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.panel)
        .onAppear {
            cameras = card.cameras
            days = ShootSelection.days(missing: card.missing, cameras: card.cameras, calendar: model.calendar)
            selection = ShootSelection(missing: card.missing, cameras: card.cameras, calendar: model.calendar)
            nameFocused = true
        }
    }

    // MARK: Name

    private func nameCard(_ preview: ShootPreview) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shoot name").font(.system(size: 13, weight: .medium))
                TextField("Shoot name", text: $shootName, prompt: Text("e.g. Brand film"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .inputStyle(focused: nameFocused)
                    .focused($nameFocused)
                    .onSubmit { if isValid { create() } }
                if let problem = preview.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    Text(nameCaption(preview)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nameCaption(_ preview: ShootPreview) -> String {
        if shootName.trimmingCharacters(in: .whitespaces).isEmpty { return "The shoot folder is named after this." }
        guard isValid else { return "Not a usable folder name." }
        if let shoot = preview.folders.first, shoot.exists {
            return "Adds to the existing “\(shoot.name)” folder. Nothing in it is overwritten."
        }
        return "Creates a new folder."
    }

    // MARK: Cameras

    private func camerasSection(_ preview: ShootPreview, _ sel: ShootSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Cameras") {
                Text(selectedSummary(preview)).font(.caption).foregroundStyle(.secondary)
            }
            SurfaceCard(padding: 12) {
                VStack(spacing: 0) {
                    ForEach(Array($cameras.enumerated()), id: \.element.id) { index, $cam in
                        if index > 0 { divider }
                        groupBlock(id: cam.id, sel: sel) {
                            Image(systemName: "video")
                        } title: {
                            Text(cam.label)
                        } caption: {
                            Text(selectedCaption(cam.id, sel))
                        } trailing: {
                            TextField("Folder", text: $cam.folderName)
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .inputStyle(focused: false)
                                .frame(width: 160)
                                .disabled(!sel.isIncluded(camera: cam.id))
                        }
                    }
                    if let other = days[ShootSelection.otherID], !other.isEmpty {
                        if !cameras.isEmpty { divider }
                        groupBlock(id: ShootSelection.otherID, sel: sel) {
                            Image(systemName: "doc")
                        } title: {
                            Text("Other files")
                        } caption: {
                            Text("Goes in “\(card.name)”")
                        } trailing: {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 10)
    }

    private func groupBlock<Icon: View, Title: View, Caption: View, Trailing: View>(
        id: String, sel: ShootSelection,
        @ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title,
        @ViewBuilder caption: () -> Caption, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let on = sel.isIncluded(camera: id)
        let groupDays = days[id] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { on },
                    set: { value in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mutate { $0.setCamera(id, included: value, days: groupDays.map(\.start)) }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                icon()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    title().lineLimit(1)
                    caption().font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .opacity(on ? 1 : 0.5)

            if on {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groupDays, id: \.start) { day in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { sel.isIncluded(camera: id, day: day.start) },
                                set: { value in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        mutate { $0.set(camera: id, day: day.start, included: value) }
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            DayChip(day: day, calendar: model.calendar)
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 40)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func selectedCaption(_ id: String, _ sel: ShootSelection) -> String {
        let n = (days[id] ?? []).filter { sel.isIncluded(camera: id, day: $0.start) }.reduce(0) { $0 + $1.fileCount }
        return Format.count(n, "file", "files")
    }

    private func selectedSummary(_ preview: ShootPreview) -> String {
        if preview.videoCount > 0 && preview.photoCount > 0 {
            return "\(Format.count(preview.videoCount, "video", "videos")) · \(Format.count(preview.photoCount, "photo", "photos"))"
        }
        if preview.photoCount > 0 { return Format.count(preview.photoCount, "photo", "photos") }
        return Format.count(preview.videoCount, "file", "files")
    }

    // MARK: Folders

    private func foldersSection(_ preview: ShootPreview, _ sel: ShootSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Folders")
            SurfaceCard {
                if preview.folders.isEmpty {
                    Text(shootName.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Enter a shoot name to preview the folders."
                         : "Select at least one camera day.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.folders) { folderRow($0) }
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
                Text(folder.isPhoto ? Format.count(folder.fileCount, "photo", "photos")
                                    : Format.count(folder.fileCount, "file", "files"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(folder.depth) * 18)
    }

    private func create() {
        do {
            try model.createShoot(card: card, name: shootName, cameras: cameras, selection: currentSelection)
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
