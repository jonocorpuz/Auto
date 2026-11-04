import SwiftUI

/// Finder-style, read-only view of one card's files, grouped into "Not Backed Up" and the shoots
/// that hold verified copies. Read-only except "Add to Shoot", which goes through the same checked
/// add-footage flow as the sheet. Space or double-click opens Quick Look.
struct CardBrowserView: View {
    @Environment(AppModel.self) private var model
    let card: Card

    enum Mode: String { case icons, list }
    enum Place: Hashable {
        case all
        case group(CardBrowser.GroupKind)
    }
    @State private var place: Place? = .all
    /// nil: every group.
    private var location: CardBrowser.GroupKind? {
        if case .group(let kind)? = place { kind } else { nil }
    }
    @State private var selection = Set<MediaFile.ID>()
    /// Anchor/cursor bookkeeping for icon-view clicks and keys; `selection` stays the source of truth.
    @State private var grid = GridSelection<MediaFile.ID>()
    @State private var gridWidth: Double = 600
    @FocusState private var gridFocused: Bool
    @AppStorage("cardBrowserMode") private var mode: Mode = .icons
    @AppStorage("cardBrowserIconSize") private var iconSize: Double = 110
    @State private var adding = false
    @State private var actionError: String?

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
        .onAppear { model.browserAppeared(card.id) }
        .onDisappear { model.browserDisappeared(card.id) }
        .onChange(of: groups.map(\.kind)) { _, kinds in
            if let location, !kinds.contains(location) { place = .all }
        }
        .onChange(of: place) { selection = [] }
        .onChange(of: card.files) { _, files in
            let present = Set(files.map(\.id))
            grid.prune(keeping: present)
            selection = selection.filter(present.contains)
        }
        // Keep the grid's anchor/cursor in step with outside changes (Esc, list mode, place changes).
        .onChange(of: selection) { _, new in
            if grid.selected != new { grid = GridSelection(selected: new) }
        }
        .alert("Couldn't add to shoot", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        // Esc clears the selection, then goes back. A hidden button's shortcut works without focus.
        .background {
            Button("") {
                if selection.isEmpty { model.browsingCardID = nil } else { selection = [] }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
        }
        // ⌘A as a key equivalent too, so it works even when the grid or table doesn't have focus
        // (or the Edit menu's Select All would otherwise swallow it).
        .background {
            Button("") {
                if mode == .icons {
                    grid.selectAll(in: gridLayout(shown, spacing: 6))
                    selection = grid.selected
                } else {
                    selection = Set(shown.flatMap(\.files).map(\.id))
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
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

            let chosen = selectedFiles(groups)
            Button { quickLook(chosen, toggle: true) } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Quick Look (Space)")
            .keyboardShortcut(.space, modifiers: [])
            .disabled(chosen.isEmpty)

            Button { model.revealInFinder(chosen.isEmpty ? [card.volume] : chosen.map(\.url)) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(chosen.isEmpty ? "Show card in Finder" : "Show selection in Finder")

            addToShootMenu(chosen, groups: groups)

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
        List(selection: $place) {
            Section(card.name) {
                LocationRow(title: "All Files", symbol: "sdcard", tint: .secondary, count: card.files.count)
                    .tag(Place.all)
                ForEach(groups.filter { $0.kind == .notBackedUp }) { group in
                    LocationRow(title: group.title, symbol: "exclamationmark.circle.fill",
                                tint: Color(nsColor: AppModel.Status.unbacked.tint), count: group.files.count)
                        .tag(Place.group(group.kind))
                }
            }
            let backed = groups.filter { $0.kind != .notBackedUp }
            let shownShoots = Set(groups.compactMap { group -> UUID? in
                if case .shoot(let id) = group.kind { id } else { nil }
            })
            let pending = model.browserMembership.filter { $0.value == .checking && !shownShoots.contains($0.key) }.count
            if !backed.isEmpty || pending > 0 {
                Section("Backed Up") {
                    ForEach(backed) { group in
                        let state = group.kind.shootID.flatMap { model.browserMembership[$0] }
                        LocationRow(title: group.title,
                                    symbol: group.kind == .elsewhere ? "externaldrive.fill" : "folder.fill",
                                    tint: Theme.accent, count: group.files.count,
                                    checking: state == .checking,
                                    failure: { if case .failed(let reason)? = state { reason } else { nil } }())
                            .tag(Place.group(group.kind))
                    }
                    if pending > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking \(Format.count(pending, "shoot", "shoots"))…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
        let spacing = 6.0
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize + 16), spacing: spacing)], alignment: .leading,
                          spacing: 10, pinnedViews: .sectionHeaders) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.files) { file in
                                FileIcon(file: file, size: iconSize, selected: selection.contains(file.id))
                                    .id(IconID(kind: group.kind, file: file.id))
                                    .onTapGesture {
                                        gridFocused = true
                                        clickIcon(file, groups: groups)
                                    }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                                        grid.click(file.id)
                                        selection = grid.selected
                                        quickLook([file])
                                    })
                                    .contextMenu { fileMenu(targets(for: file, in: groups), groups: groups) }
                            }
                        } header: {
                            GroupHeader(group: group)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { gridWidth = $0 }
            .background(Theme.surface)
            .contentShape(Rectangle())
            .onTapGesture {
                gridFocused = true
                grid.clear()
                selection = []
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onAppear { gridFocused = true }
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKey(press, groups: groups, proxy: proxy, spacing: spacing)
            }
        }
    }

    /// Icon identity for `ScrollViewReader`: a file shown in two groups has two icons.
    private struct IconID: Hashable {
        let kind: CardBrowser.GroupKind
        let file: MediaFile.ID
    }

    /// One list row. A file in two groups has two rows, so rows need ids of their own.
    private struct Row: Identifiable {
        struct ID: Hashable {
            let kind: CardBrowser.GroupKind
            let file: MediaFile.ID
        }
        let kind: CardBrowser.GroupKind
        let file: MediaFile
        var id: ID { ID(kind: kind, file: file.id) }
    }

    private func gridLayout(_ groups: [CardBrowser.Group], spacing: Double) -> GridLayout<MediaFile.ID> {
        let columns = GridLayout<MediaFile.ID>.columnCount(
            width: gridWidth, itemMinimum: iconSize + 16, spacing: spacing, padding: 12)
        return GridLayout(sections: groups.map { $0.files.map(\.id) }, columns: columns)
    }

    private func clickIcon(_ file: MediaFile, groups: [CardBrowser.Group]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            grid.toggle(file.id)
        } else if flags.contains(.shift) {
            grid.extend(to: file.id, in: gridLayout(groups, spacing: 6))
        } else {
            grid.click(file.id)
        }
        selection = grid.selected
    }

    private func handleKey(_ press: KeyPress, groups: [CardBrowser.Group], proxy: ScrollViewProxy,
                           spacing: Double) -> KeyPress.Result {
        let layout = gridLayout(groups, spacing: spacing)
        if press.modifiers.contains(.command) {
            guard press.characters == "a", !press.modifiers.contains(.shift) else { return .ignored }
            grid.selectAll(in: layout)
            selection = grid.selected
            return .handled
        }
        let direction: GridSelection<MediaFile.ID>.Direction
        switch press.key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        case .home: direction = .home
        case .end: direction = .end
        default: return .ignored
        }
        grid.move(direction, extend: press.modifiers.contains(.shift), in: layout)
        selection = grid.selected
        // A file can sit in several groups; the grid resolves the cursor to its first occurrence.
        if let cursor = grid.cursor, let group = groups.first(where: { $0.files.contains { $0.id == cursor } }) {
            proxy.scrollTo(IconID(kind: group.kind, file: cursor))
        }
        return .handled
    }

    private func listView(_ groups: [CardBrowser.Group]) -> some View {
        Table(of: Row.self, selection: rowSelection(groups)) {
            TableColumn("Name") { row in
                let file = row.file
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(file.kind)).foregroundStyle(.secondary).frame(width: 16)
                    Text(file.name)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Date Recorded") { row in
                let file = row.file
                Text(file.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Size") { row in
                let file = row.file
                Text(Format.bytes(file.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 55, ideal: 70)
            TableColumn("Kind") { row in
                let file = row.file
                Text(Self.kindLabel(file)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        } rows: {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.files.map { Row(kind: group.kind, file: $0) }) { TableRow($0) }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            let files = files(for: ids, groups)
            if !files.isEmpty { fileMenu(files, groups: groups) }
        } primaryAction: { ids in
            quickLook(files(for: ids, groups))
        }
    }

    /// Table selection is per row; the browser selects files. Selecting a row selects its file, and
    /// every row of a selected file shows selected.
    private func rowSelection(_ groups: [CardBrowser.Group]) -> Binding<Set<Row.ID>> {
        Binding {
            Set(groups.flatMap { group in
                group.files.filter { selection.contains($0.id) }.map { Row.ID(kind: group.kind, file: $0.id) }
            })
        } set: { rows in
            selection = Set(rows.map(\.file))
        }
    }

    private func files(for rows: Set<Row.ID>, _ groups: [CardBrowser.Group]) -> [MediaFile] {
        let ids = Set(rows.map(\.file))
        return orderedFiles(groups).filter { ids.contains($0.id) }
    }

    // MARK: Actions

    private func orderedFiles(_ groups: [CardBrowser.Group]) -> [MediaFile] {
        CardBrowser.uniqueFiles(groups)
    }

    /// Selected files in on-screen order.
    private func selectedFiles(_ groups: [CardBrowser.Group]) -> [MediaFile] {
        orderedFiles(groups).filter { selection.contains($0.id) }
    }

    /// Right-clicking a selected file acts on the whole selection; otherwise on just that file.
    private func targets(for file: MediaFile, in groups: [CardBrowser.Group]) -> [MediaFile] {
        selection.contains(file.id) ? selectedFiles(groups) : [file]
    }

    /// Previews `files`; does nothing with no files, like Finder. Only Space toggles the panel closed.
    private func quickLook(_ files: [MediaFile], toggle: Bool = false) {
        guard !files.isEmpty else { return }
        model.quickLook(files.map(\.url), toggle: toggle)
    }

    @ViewBuilder private func fileMenu(_ files: [MediaFile], groups: [CardBrowser.Group]) -> some View {
        Button("Quick Look") { quickLook(files) }
        Button("Show in Finder") { model.revealInFinder(files.map(\.url)) }
        let copies = model.browserBackupCopies(files, in: location)
        if !copies.isEmpty {
            Button(copies.count == files.count ? "Show Backup in Finder" : "Show Backups in Finder (\(copies.count))") {
                model.revealInFinder(copies)
            }
        }
        Divider()
        addToShootItems(files, groups: groups)
    }

    private var onlineShoots: [ShootItem] {
        model.shoots.filter { if case .online? = $0.availability { true } else { false } }
    }

    private var canAdd: Bool {
        guard !adding, card.plan == nil else { return false }
        switch card.phase {
        case .scanning, .copying, .empty, .unreadable: return false
        default: return card.engine == nil
        }
    }

    private func addToShootMenu(_ files: [MediaFile], groups: [CardBrowser.Group]) -> some View {
        Menu {
            addToShootItems(files, groups: groups)
        } label: {
            Label(adding ? "Adding…" : "Add to Shoot", systemImage: "plus.rectangle.on.folder")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(files.isEmpty || !canAdd || onlineShoots.isEmpty)
        .help(files.isEmpty ? "Select files to add them to a shoot" : "Copy the selected files into a shoot")
    }

    @ViewBuilder private func addToShootItems(_ files: [MediaFile], groups: [CardBrowser.Group]) -> some View {
        let shoots = onlineShoots
        if shoots.isEmpty {
            Text("No shoots online")
        } else {
            Section("Add \(Format.count(files.count, "file", "files")) to") {
                ForEach(shoots) { item in
                    // Files already verified inside this shoot are skipped; disable if that's all of them.
                    let inShoot = filesAlreadyIn(item.id, groups: groups)
                    Button("\(item.record.name) — \(item.date.formatted(date: .abbreviated, time: .omitted))") {
                        add(files, to: item.id)
                    }
                    .disabled(!canAdd || files.allSatisfy { inShoot.contains($0.id) })
                }
            }
        }
    }

    /// Prefer the shoot's verified membership; until it is known, use what the group shows.
    private func filesAlreadyIn(_ shootID: UUID, groups: [CardBrowser.Group]) -> Set<MediaFile.ID> {
        if case .done(let urls, _)? = model.browserMembership[shootID] {
            return Set(card.files.filter { urls.contains($0.url) }.map(\.id))
        }
        return Set(groups.first { $0.kind == .shoot(shootID) }?.files.map(\.id) ?? [])
    }

    private func add(_ files: [MediaFile], to shootID: UUID) {
        adding = true
        let urls = Set(files.map(\.url))
        Task {
            defer { adding = false }
            do {
                try await model.addFiles(urls, from: card.id, toShoot: shootID)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func statusBar(_ groups: [CardBrowser.Group]) -> some View {
        let unique = orderedFiles(groups)
        let count = unique.count
        let bytes = unique.reduce(Int64(0)) { $0 + $1.size }
        var text = "\(Format.count(count, "item", "items")) · \(Format.bytes(bytes))"
        if !selection.isEmpty { text = "\(selection.count) of " + text + " selected" }
        if card.phase == .scanning || card.phase == .verifying {
            text += " — Checking backup…"
        } else if card.phase == .copying {
            let p = card.progress
            text += " — Copying \(min(p.filesDone + 1, p.filesTotal)) of \(p.filesTotal)…"
        }
        if model.browserMembership.values.contains(.checking) { text += " — Checking shoots…" }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Theme.surface)
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

private extension CardBrowser.GroupKind {
    var shootID: UUID? { if case .shoot(let id) = self { id } else { nil } }
}

private struct LocationRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int
    var checking = false
    var failure: String?

    var body: some View {
        HStack {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Spacer()
            if checking {
                ProgressView().controlSize(.mini)
            } else if let failure {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .help("Couldn't check this shoot: \(failure)")
            }
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
        .task(id: file.identity) {
            image = await model.fileThumbnail(for: file)
        }
    }
}
