import SwiftUI

/// Add Files: drop or choose files and folders, review what will be copied where, and add them to a shoot.
struct AddFilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let staging: ImportStaging

    @State private var error: String?
    @State private var expanded: Set<String> = []
    @State private var targeted = false

    private var shootName: String { model.shoots.first { $0.id == staging.shootID }?.record.name ?? "this shoot" }
    private var addCount: Int { staging.selected.count }
    private var sizes: [URL: Int64] { Dictionary(staging.items.map { ($0.id, $0.file.size) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Add Files", subtitle: shootName)

            dropZone
            status

            if !staging.groups.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(staging.groups) { group in groupView(group) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 280)
            }

            duplicatesBlock
            notes

            if let error {
                ErrorLabel(error)
            }

            HStack {
                Spacer()
                Button("Cancel") { close(cancelling: true) }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Button(addCount == 0 ? "Add Files" : "Add \(Format.count(addCount, "file", "files"))") { add() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .frame(width: 160)
                    .keyboardShortcut(.defaultAction)
                    .disabled(addCount == 0 || staging.phase != .ready)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.panel)
    }

    // MARK: Drop zone

    private var dropZone: some View {
        Button { model.chooseImportSources(for: staging) } label: {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 24, weight: .light))
                Text("Drop files or folders here").font(.system(size: 13, weight: .medium))
                Text("or Choose…").font(.caption).foregroundStyle(Theme.accent)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: staging.items.isEmpty ? 120 : 76)
            .background((targeted ? Theme.accent.opacity(0.08) : Theme.surfaceMuted),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.addSources(files, to: staging)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityLabel("Drop files or folders here, or choose")
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch staging.phase {
        case .scanning(let n):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(n > 0 ? "Scanning… \(Format.count(n, "file", "files")) found" : "Scanning…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking what's already in the shoot…").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            ErrorLabel(reason)
        case .ready:
            if staging.items.isEmpty && staging.sources.isEmpty == false && staging.refused.isEmpty {
                Text("No photos, videos or audio found.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Groups

    private func groupView(_ group: ImportStaging.Group) -> some View {
        let open = expanded.contains(group.id)
        return SurfaceCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "Collapse" : "Expand")
                    Image(systemName: group.kind == .photo ? "photo" : group.kind == .audio ? "waveform" : "film")
                        .foregroundStyle(.secondary)
                    Text("\(kindName(group.kind)) → \(group.folder)").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Format.count(group.count, "file", "files")) · \(Format.bytes(group.bytes))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { remove(group.urls) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Remove these files from the list")
                        .accessibilityLabel("Remove group")
                }
                if open {
                    VStack(spacing: 0) {
                        ForEach(group.urls, id: \.self) { url in
                            HStack(spacing: 8) {
                                Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                if staging.duplicates.contains(url) {
                                    Text("duplicate").font(.caption2).foregroundStyle(Theme.warning)
                                }
                                Spacer()
                                Text(Format.bytes(sizes[url] ?? 0)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Button { remove([url]) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                            }
                            .padding(.vertical, 3)
                            .padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    private func kindName(_ kind: MediaKind) -> String {
        switch kind {
        case .video: "Video"
        case .photo: "Photo"
        case .audio: "Audio"
        }
    }

    private func remove(_ urls: [URL]) { staging.removed.formUnion(urls) }

    // MARK: Duplicates and notes

    @ViewBuilder private var duplicatesBlock: some View {
        let live = staging.items.filter { !staging.removed.contains($0.id) && staging.duplicates.contains($0.id) }
        if !live.isEmpty {
            let all = Set(live.map(\.id))
            HStack {
                Label("\(live.count) already in this shoot, \(staging.includeDuplicates.isSuperset(of: all) ? "added anyway" : "skipped")",
                      systemImage: "doc.on.doc")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Copy anyway", isOn: Binding(
                    get: { staging.includeDuplicates.isSuperset(of: all) },
                    set: { on in
                        if on { staging.includeDuplicates.formUnion(all) } else { staging.includeDuplicates.subtract(all) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if let warning = staging.warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warning)
        }
        ForEach(Array(staging.refused.enumerated()), id: \.offset) { _, entry in
            Label("\(entry.0.lastPathComponent): \(entry.1.localizedDescription)", systemImage: "nosign")
                .font(.caption).foregroundStyle(.secondary)
        }
        if staging.ignoredCount > 0 {
            Text("\(Format.count(staging.ignoredCount, "other file", "other files")) ignored (not photo, video or audio)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Add

    private func add() {
        error = nil
        do {
            _ = try model.commitImport(staging)
            close(cancelling: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Works whichever view presented the sheet: the shoot browser (local state) or MainView (`shootSheet`).
    private func close(cancelling: Bool) {
        if cancelling { staging.cancel() }
        if case .addFiles(let s)? = model.shootSheet, s.id == staging.id { model.shootSheet = nil }
        dismiss()
    }
}
