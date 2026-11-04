import SwiftUI

/// Sheet for creating a shoot folder for a card: client, name, date, per-camera folders and a live preview.
struct NewShootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var client = ""
    @State private var shootName = ""
    @State private var date = Date()
    @State private var cameras: [Camera] = []
    @State private var clients: [String] = []
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case client, shoot }

    private var trimmedClient: String { client.trimmingCharacters(in: .whitespaces) }
    private var suggestions: [String] { ShootPlanner.suggestions(for: client, in: clients) }
    private var existingClient: String? { clients.first { $0.caseInsensitiveCompare(trimmedClient) == .orderedSame } }
    private var sections: (video: Bool, photo: Bool) { ShootPlanner.sections(for: card.missing) }

    private func count(_ camera: Camera, photos: Bool) -> Int {
        card.missing.filter { $0.cameraID == camera.id && ($0.kind == .photo) == photos }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Shoot").font(.title3.weight(.semibold))
                Text("Creates the folders on \(model.workRootBreadcrumb)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                clientField
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shoot name").font(.callout.weight(.medium))
                    TextField("e.g. Brand film", text: $shootName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .shoot)
                    HStack(spacing: 6) {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.stepperField)
                        if card.shootDate != nil {
                            Text("from the card").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            camerasSection
            preview

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedClient.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            clients = model.existingClients()
            date = card.shootDate ?? Date()
            cameras = card.cameras
            focus = .client
        }
    }

    private var clientField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Client").font(.callout.weight(.medium))
            TextField("Start typing a name", text: $client)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .client)
                .onSubmit {
                    if let first = suggestions.first { client = first }
                    focus = .shoot
                }
            if focus == .client && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { name in
                        Button {
                            client = name
                            focus = .shoot
                        } label: {
                            Text(name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            } else {
                Text(clientCaption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clientCaption: String {
        if trimmedClient.isEmpty { return "Finds existing clients as you type" }
        if let existing = existingClient { return "Adds to existing \(existing) folder" }
        return "Creates a new client folder"
    }

    private var camerasSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cameras.count == 1 ? "Camera on this card" : "Cameras on this card").font(.callout.weight(.medium))
            ForEach($cameras) { $cam in
                HStack(spacing: 8) {
                    Image(systemName: "video").foregroundStyle(.secondary)
                    Text(cam.label)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                    TextField("Folder", text: $cam.folderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("\(card.missing.filter { $0.cameraID == cam.id }.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var preview: some View {
        let shootName = model.shootFolderName(date: date, name: self.shootName)
        let shootExists = existingClient != nil && model.shootFolderExists(client: trimmedClient, date: date, name: self.shootName)
        return VStack(alignment: .leading, spacing: 3) {
            folderRow(trimmedClient.isEmpty ? "Client" : trimmedClient, depth: 0, exists: existingClient != nil)
            folderRow(shootName, depth: 1, exists: shootExists, bold: true)
            if sections.video {
                folderRow("Footage", depth: 2, exists: shootExists)
                ForEach(cameras.filter { count($0, photos: false) > 0 }) { cam in
                    folderRow(cam.folderName.isEmpty ? cam.model : cam.folderName, depth: 3, exists: false, note: "\(count(cam, photos: false)) files")
                }
            }
            if sections.photo {
                folderRow("Photo", depth: 2, exists: shootExists)
                ForEach(cameras.filter { count($0, photos: true) > 0 }) { cam in
                    folderRow(cam.folderName.isEmpty ? cam.model : cam.folderName, depth: 3, exists: false, note: "\(count(cam, photos: true)) photos")
                }
            }
            folderRow("Project", depth: 2, exists: shootExists)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func folderRow(_ name: String, depth: Int, exists: Bool, bold: Bool = false, note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(exists ? Color.secondary : Color.accentColor)
            Text(name).fontWeight(bold ? .semibold : .regular)
            Text(exists ? "already there" : "new")
                .font(.caption)
                .foregroundStyle(exists ? Color.secondary : Color.accentColor)
            Spacer()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private func create() {
        do {
            try model.createShoot(card: card, client: existingClient ?? trimmedClient, shootName: shootName, date: date, cameras: cameras)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
