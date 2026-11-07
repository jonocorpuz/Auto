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
        case .addFiles(let staging):
            AddFilesSheet(staging: staging)
                .id(staging.id)
        case nil:
            EmptyView()
        }
    }
}

/// One destination in the create sheet.
private struct Destination: Identifiable {
    let id = UUID()
    var url: URL?
    /// Mount identity of `url`'s volume; nil until resolved (or if unknown).
    var volumeID: String?
    var resolved = false
}

/// Create mode: name, date, destinations and a live check of each target folder.
private struct CreateShootSheet: View {
    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var date = Date()
    @State private var destinations = [Destination()]
    @State private var classified: [UUID: Classified] = [:]
    @State private var error: String?
    @State private var finished = false
    @State private var working = false
    @State private var separateCameras = true
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    /// The folder check for one row, made off main by the `.task` below and reused across renders.
    private struct Classified {
        let url: URL
        let name: String
        let result: ShootFolders.FolderCollision
    }

    /// Re-runs the checks when a row's folder, the set of rows, or the name changes.
    private struct CollisionKey: Hashable {
        let urls: [URL?]
        let name: String
    }

    private var collisionKey: CollisionKey { CollisionKey(urls: destinations.map(\.url), name: trimmed) }

    /// nil until the check for this row's current folder and name has finished.
    private func collision(_ dest: Destination) -> ShootFolders.FolderCollision? {
        guard let url = dest.url, !trimmed.isEmpty, let known = classified[dest.id],
              known.url == url, known.name == trimmed else { return nil }
        return known.result
    }

    private func classifyDestinations() async {
        let name = trimmed
        guard !name.isEmpty else { classified = [:]; return }
        for dest in destinations {
            guard let url = dest.url else { continue }
            let result = await model.classifyShootFolder(parent: url, name: name)
            guard !Task.isCancelled else { return }
            classified[dest.id] = Classified(url: url, name: name, result: result)
        }
    }

    /// Index of the earlier row sharing this row's drive, if any.
    private func duplicateOf(_ index: Int) -> Int? {
        guard let id = destinations[index].volumeID else { return nil }
        return destinations[..<index].firstIndex { $0.volumeID == id }
    }

    private func isFree(_ dest: Destination) -> Bool {
        if case .free = collision(dest) { return true }
        return false
    }

    private var canCreate: Bool {
        guard !working, !finished, model.isValidShootName(name) else { return false }
        for (i, dest) in destinations.enumerated() {
            guard dest.url != nil, dest.resolved, isFree(dest), duplicateOf(i) == nil else { return false }
        }
        return true
    }

    private func driveName(_ url: URL?) -> String {
        guard let url else { return "No folder chosen" }
        let parts = url.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts[2] }
        return url.lastPathComponent
    }

    private func rowTitle(_ index: Int) -> String {
        index == 0 ? "Primary" : "Mirror \(index)"
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

                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Separate folders per camera", isOn: $separateCameras)
                            .disabled(working || finished)
                        Text("Off: files go straight into Video/ and Photo/.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Destinations").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button {
                            destinations.append(Destination())
                        } label: {
                            Label("Add Mirror Drive", systemImage: "plus")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(working || finished)
                    }

                    ForEach(Array(destinations.enumerated()), id: \.element.id) { index, dest in
                        destinationRow(index, dest)
                    }
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(finished ? .orange : .red).font(.callout)
            }

            HStack {
                Spacer()
                Button(finished ? "Close" : "Cancel") { model.shootSheet = nil }
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
        .task(id: collisionKey) { await classifyDestinations() }
        .onAppear {
            if let parent = model.defaultShootParent { setURL(parent, at: destinations[0].id) }
            nameFocused = true
        }
    }

    private func destinationRow(_ index: Int, _ dest: Destination) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(rowTitle(index)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(driveName(dest.url))
                    .font(.callout)
                    .lineLimit(1).truncationMode(.middle)
                    .help(dest.url?.path ?? "")
                Spacer()
                Button("Choose…") {
                    let url = index == 0 ? model.chooseShootParent() : model.chooseMirrorParent()
                    if let url { setURL(url, at: dest.id) }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(working || finished)
                if index > 0 {
                    Button {
                        destinations.removeAll { $0.id == dest.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this drive")
                    .disabled(working || finished)
                }
            }
            collisionLine(index, dest)
                .padding(.leading, 68)
        }
    }

    /// Stores the chosen folder and resolves its volume off the main actor.
    private func setURL(_ url: URL, at id: UUID) {
        guard let i = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[i].url = url
        destinations[i].volumeID = nil
        destinations[i].resolved = false
        Task {
            let volume = await model.volumeIdentity(of: url)
            guard let i = destinations.firstIndex(where: { $0.id == id }), destinations[i].url == url else { return }
            destinations[i].volumeID = volume
            destinations[i].resolved = true
        }
    }

    @ViewBuilder private func collisionLine(_ index: Int, _ dest: Destination) -> some View {
        if let url = dest.url {
            if let other = duplicateOf(index) {
                problem("Same drive as \(rowTitle(other)) \u{2014} pick another drive")
            } else if trimmed.isEmpty {
                caption(index == 0 ? "The shoot folder is named after this." : "A mirror copy goes here.")
            } else if let collision = collision(dest) {
                switch collision {
                case .free:
                    caption("Creates \(url.appendingPathComponent(trimmed).path)")
                case .plainFolder:
                    HStack(spacing: 8) {
                        Label("A folder named “\(trimmed)” already exists", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        if index == 0 {
                            Button("Use this folder") { adopt(url) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(working || finished || !model.isValidShootName(name))
                        }
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
        guard canCreate else { return }
        let parents = destinations.compactMap(\.url)
        run { try await model.createShoot(name: trimmed, date: date, parents: parents, layout: separateCameras ? .cameraFolders : .flat) }
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
            } catch ShootError.partialCreate(let created, let failed) {
                // The shoot exists on the drives that worked; don't offer Create again.
                finished = true
                let bad = failed.map { "\($0.name) (\($0.reason))" }.joined(separator: ", ")
                let made = created.isEmpty ? "" : " The shoot was created on \(created.joined(separator: ", "))."
                self.error = "Couldn't create on \(bad).\(made) Use Add Mirror\u{2026} on the shoot to retry."
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
