import SwiftUI

/// The New Shoot sheet. Create mode makes a shoot folder; add mode copies a card's footage into one.
struct NewShootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.shootSheet {
        case .create:
            CreateShootSheet()
        case .add(let shootID, let cardID):
            AddFootageSheet(shootID: shootID, initialCardID: cardID)
                .id(shootID)
        case nil:
            EmptyView()
        }
    }
}

/// Create mode: name, date, location and a live check of the target folder.
private struct CreateShootSheet: View {
    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var date = Date()
    @State private var parent: URL?
    @State private var error: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var collision: ShootFolders.FolderCollision? {
        guard let parent, !trimmed.isEmpty else { return nil }
        return model.classifyShootFolder(parent: parent, name: trimmed)
    }
    private var canCreate: Bool {
        guard parent != nil, !working, model.isValidShootName(name), let collision else { return false }
        if case .free = collision { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Shoot").font(.system(size: 20, weight: .semibold))
                Text("Name it and pick the day it was shot. You can add footage next.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shoot name").font(.system(size: 13, weight: .medium))
                    TextField("Shoot name", text: $name, prompt: Text("e.g. Brand film"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .inputStyle(focused: nameFocused)
                        .focused($nameFocused)
                        .onSubmit { if canCreate { create() } }

                    HStack {
                        Text("Date").font(.system(size: 13, weight: .medium))
                        Spacer()
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }

                    HStack(spacing: 8) {
                        Text("Location").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(parent?.path ?? "No folder chosen")
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(parent?.path ?? "")
                        Button("Choose…") { if let url = model.chooseShootParent() { parent = url } }
                            .buttonStyle(.bordered)
                    }

                    collisionLine
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.shootSheet = nil }
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
            parent = model.defaultShootParent
            nameFocused = true
        }
    }

    @ViewBuilder private var collisionLine: some View {
        if let parent {
            if trimmed.isEmpty {
                caption("The shoot folder is named after this.")
            } else if let collision {
                switch collision {
                case .free:
                    caption("Creates \(parent.appendingPathComponent(trimmed).path)")
                case .plainFolder:
                    HStack(spacing: 8) {
                        Label("A folder named “\(trimmed)” already exists", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Use this folder") { adopt(parent) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(working || !model.isValidShootName(name))
                    }
                case .existingShoot:
                    Label("That's already a shoot", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                case .notAFolder:
                    problem("A file with that name already exists there.")
                case .unreadableShoot:
                    problem("That folder is a shoot Auto can't read. It won't be touched.")
                case .invalidName:
                    problem("Not a usable folder name.")
                }
            }
        } else {
            problem("Choose where the shoot folder should go.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red)
    }

    private func create() {
        guard let parent, canCreate else { return }
        run { try await model.createShoot(name: trimmed, date: date, parent: parent) }
    }

    private func adopt(_ parent: URL) {
        let folder = parent.appendingPathComponent(trimmed, isDirectory: true)
        run { try await model.adoptFolder(folder, name: trimmed, date: date) }
    }

    private func run(_ work: @escaping () async throws -> Shoot) {
        working = true
        error = nil
        Task {
            do {
                let shoot = try await work()
                if let card = model.shootSheetCard {
                    model.shootSheet = .add(shootID: shoot.id, cardID: card.id)
                } else {
                    model.shootSheet = nil
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

extension View {
    /// Rounded text input look used inside cards.
    func inputStyle(focused: Bool) -> some View {
        padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(focused ? Theme.accent : Theme.border))
            .frame(maxWidth: .infinity)
    }
}
