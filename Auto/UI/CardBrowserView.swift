import SwiftUI

/// Finder-style, read-only view of one card's files, grouped into "Not Backed Up" and the shoots
/// that hold verified copies. Selecting files does nothing yet; it's just another way to look.
struct CardBrowserView: View {
    @Environment(AppModel.self) private var model
    let card: Card

    enum Mode: String { case icons, list }
    /// nil: every group.
    @State private var location: CardBrowser.GroupKind?
    @State private var selection = Set<MediaFile.ID>()
    @AppStorage("cardBrowserMode") private var mode: Mode = .icons
    @AppStorage("cardBrowserIconSize") private var iconSize: Double = 110

    var body: some View {
        let groups = model.browserGroups(for: card)
        let shown = location.map { kind in groups.filter { $0.kind == kind } } ?? groups
        VStack(spacing: 0) {
            toolbar(groups: groups)
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                locations(groups)
                    .frame(width: 200)
                Divider().overlay(Theme.border)
                VStack(spacing: 0) {
                    content(shown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().overlay(Theme.border)
                    statusBar(shown)
                }
            }
        }
        .onChange(of: groups.map(\.kind)) { _, kinds in
            if let location, !kinds.contains(location) { self.location = nil }
        }
        .onKeyPress(.escape) {
            if selection.isEmpty { model.browsingCardID = nil } else { selection = [] }
            return .handled
        }
    }

    // MARK: Toolbar

    private func toolbar(groups: [CardBrowser.Group]) -> some View {
        HStack(spacing: 10) {
            Button { model.browsingCardID = nil } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Back to Media")
            .keyboardShortcut("[", modifiers: .command)

            HStack(spacing: 5) {
                Image(systemName: "sdcard.fill").foregroundStyle(.secondary)
                Text(card.name).fontWeight(.semibold)
                if let title = location.flatMap({ kind in groups.first { $0.kind == kind }?.title }) {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(title)
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)

            Spacer()

            if mode == .icons {
                Slider(value: $iconSize, in: 72...200)
                    .controlSize(.mini)
                    .frame(width: 90)
                    .help("Icon size")
            }
            Picker("View", selection: $mode) {
                Image(systemName: "square.grid.2x2").tag(Mode.icons).help("Icons")
                Image(systemName: "list.bullet").tag(Mode.list).help("List")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: Locations sidebar

    private func locations(_ groups: [CardBrowser.Group]) -> some View {
        List(selection: $location) {
            Section(card.name) {
                LocationRow(title: "All Files", symbol: "sdcard", tint: .secondary, count: card.files.count)
                    .tag(nil as CardBrowser.GroupKind?)
                ForEach(groups.filter { $0.kind == .notBackedUp }) { group in
                    LocationRow(title: group.title, symbol: "exclamationmark.circle.fill",
                                tint: Color(nsColor: AppModel.Status.unbacked.tint), count: group.files.count)
                        .tag(group.kind as CardBrowser.GroupKind?)
                }
            }
            let backed = groups.filter { $0.kind != .notBackedUp }
            if !backed.isEmpty {
                Section("Backed Up") {
                    ForEach(backed) { group in
                        LocationRow(title: group.title,
                                    symbol: group.kind == .elsewhere ? "externaldrive.fill" : "folder.fill",
                                    tint: Theme.accent, count: group.files.count)
                            .tag(group.kind as CardBrowser.GroupKind?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.surfaceMuted.opacity(0.5))
    }

    // MARK: Content

    @ViewBuilder private func content(_ groups: [CardBrowser.Group]) -> some View {
        if card.files.isEmpty {
            ContentUnavailableView(card.phase == .scanning ? "Reading card…" : "No media",
                                   systemImage: "sdcard")
        } else if mode == .icons {
            iconGrid(groups)
        } else {
            listView(groups)
        }
    }

    private func iconGrid(_ groups: [CardBrowser.Group]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize + 16), spacing: 6)], alignment: .leading,
                      spacing: 10, pinnedViews: .sectionHeaders) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            FileIcon(file: file, size: iconSize, selected: selection.contains(file.id))
                                .onTapGesture { select(file, extend: NSEvent.modifierFlags.contains(.command)) }
                        }
                    } header: {
                        GroupHeader(group: group)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Theme.surface)
        .contentShape(Rectangle())
        .onTapGesture { selection = [] }
    }

    private func listView(_ groups: [CardBrowser.Group]) -> some View {
        Table(of: MediaFile.self, selection: $selection) {
            TableColumn("Name") { file in
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(file.kind)).foregroundStyle(.secondary).frame(width: 16)
                    Text(file.name)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Date Recorded") { file in
                Text(file.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
            TableColumn("Size") { file in
                Text(Format.bytes(file.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind") { file in
                Text(Self.kindLabel(file)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.files) { TableRow($0) }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func statusBar(_ groups: [CardBrowser.Group]) -> some View {
        let count = groups.reduce(0) { $0 + $1.files.count }
        let bytes = groups.reduce(Int64(0)) { $0 + $1.bytes }
        var text = "\(Format.count(count, "item", "items")) · \(Format.bytes(bytes))"
        if !selection.isEmpty { text = "\(selection.count) of " + text + " selected" }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Theme.surface)
    }

    private func select(_ file: MediaFile, extend: Bool) {
        if extend {
            if selection.remove(file.id) == nil { selection.insert(file.id) }
        } else {
            selection = [file.id]
        }
    }

    static func symbol(_ kind: MediaKind) -> String {
        switch kind {
        case .video: "film"
        case .photo: "photo"
        case .audio: "waveform"
        }
    }

    static func kindLabel(_ file: MediaFile) -> String {
        let ext = file.url.pathExtension.uppercased()
        let kind = switch file.kind {
        case .video: "Video"
        case .photo: "Photo"
        case .audio: "Audio"
        }
        return ext.isEmpty ? kind : "\(ext) \(kind)"
    }
}

// MARK: - Pieces

private struct LocationRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int

    var body: some View {
        HStack {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct GroupHeader: View {
    let group: CardBrowser.Group

    var body: some View {
        HStack(spacing: 6) {
            if group.kind == .notBackedUp {
                StatusDot(color: Color(nsColor: AppModel.Status.unbacked.tint))
            } else {
                Image(systemName: group.kind == .elsewhere ? "externaldrive.fill" : "folder.fill")
                    .foregroundStyle(Theme.accent)
            }
            Text(group.title).font(.system(size: 12, weight: .semibold))
            Text("\(group.files.count) · \(Format.bytes(group.bytes))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Theme.surface.opacity(0.95))
    }
}

/// One file in icon view: thumbnail over a (selectable) name, like Finder.
private struct FileIcon: View {
    @Environment(AppModel.self) private var model
    let file: MediaFile
    let size: Double
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                } else {
                    Image(systemName: CardBrowserView.symbol(file.kind))
                        .font(.system(size: size * 0.3, weight: .light))
                        .foregroundStyle(.tertiary)
                }
                if file.kind == .video, image != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                }
            }
            .frame(width: size, height: size * 0.75)
            .padding(6)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))

            Text(file.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(selected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: size + 16)
        .contentShape(Rectangle())
        .help("\(file.name) · \(Format.bytes(file.size)) · \(file.date.formatted(date: .abbreviated, time: .shortened))")
        .task(id: file.url) {
            image = await model.fileThumbnail(for: file.url)
        }
    }
}
