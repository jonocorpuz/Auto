import SwiftUI

/// Finder-style, read-only view of one shoot's primary online copy. Folders open on double-click,
/// the breadcrumb climbs back out, Space opens Quick Look. Nothing here deletes, renames or moves.
struct ShootBrowserView: View {
    @Environment(AppModel.self) private var model
    let item: ShootItem

    enum Mode: String { case icons, list }

    @State private var folder: URL?
    @State private var entries: [ShootEntry] = []
    @State private var loaded = false
    @State private var selection = Set<URL>()
    @State private var grid = GridSelection<URL>()
    @State private var gridWidth: Double = 600
    @FocusState private var gridFocused: Bool
    @AppStorage("shootBrowserMode") private var mode: Mode = .icons
    @AppStorage("shootBrowserIconSize") private var iconSize: Double = 110
    @State private var staging: ImportStaging?
    @State private var dropHover: URL?
    @State private var backgroundTargeted = false
    @State private var pendingDrop: PendingDrop?
    @State private var dropError: String?

    /// A Finder drop into an exact folder, staged and waiting for the user's confirmation.
    private struct PendingDrop: Identifiable {
        let id = UUID()
        let staging: ImportStaging
        let label: String
        let count: Int
        let skipped: Int
    }

    private static let gridSpacing = 6.0

    /// The shoot's effective primary copy, when it is online.
    private var root: URL? {
        item.copies.first { $0.availability == .online }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    private struct LoadKey: Hashable {
        let folder: URL?
        let imports: [ImportState]
    }
    private struct ImportState: Hashable {
        let id: UUID
        let finished: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(folder: folder,
                imports: model.imports.filter { $0.shootID == item.id }.map { ImportState(id: $0.id, finished: $0.isFinished) })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if let root {
                let current = folder ?? root
                VStack(spacing: 0) {
                    content(root: root)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().overlay(Theme.border)
                    statusBar
                }
                .id(current)
            } else {
                ContentUnavailableView("Shoot not available",
                                       systemImage: "externaldrive.badge.xmark",
                                       description: Text("Connect the drive that holds this shoot to browse it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: loadKey) { await reload() }
        .onChange(of: root) { folder = nil; selection = [] }
        .onChange(of: mode) { _, new in if new == .icons { gridFocused = true } }
        .onChange(of: entries) { _, new in
            let present = Set(new.map(\.id))
            grid.prune(keeping: present)
            selection = selection.filter(present.contains)
        }
        .onChange(of: selection) { _, new in
            if grid.selected != new { grid = GridSelection(selected: new) }
        }
        .sheet(item: $staging) { staging in
            AddFilesSheet(staging: staging)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls, into: folder ?? root)
        } isTargeted: { backgroundTargeted = $0 }
        .overlay {
            if backgroundTargeted && dropHover == nil {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 2).padding(2).allowsHitTesting(false)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: confirmBinding, presenting: pendingDrop) { drop in
            Button("Copy") {
                do { try model.commitImport(drop.staging) } catch { dropError = error.localizedDescription }
                pendingDrop = nil
            }
            Button("Cancel", role: .cancel) { drop.staging.cancel(); pendingDrop = nil }
        } message: { drop in
            Text(drop.skipped > 0 ? "\(Format.count(drop.skipped, "file", "files")) already in this shoot will be skipped." : "Files are copied; the originals are not touched.")
        }
        .alert("Couldn't add files", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(dropError ?? "") }
        // Esc clears the selection, then goes up a folder, then back to the shoots grid.
        .background {
            Button("") {
                if !selection.isEmpty { selection = [] }
                else if let root, let folder, folder != root { open(parentOf: folder, root: root) }
                else { model.browsingShootID = nil }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .background {
            Button("") {
                if mode == .icons {
                    grid.selectAll(in: gridLayout)
                    selection = grid.selected
                } else {
                    selection = Set(entries.map(\.id))
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Dropping

    private var confirmTitle: String {
        guard let drop = pendingDrop else { return "" }
        return "Copy \(Format.count(drop.count, "file", "files")) into \(drop.label)?"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pendingDrop != nil },
                set: { if !$0, let drop = pendingDrop { drop.staging.cancel(); pendingDrop = nil } })
    }

    /// Finder drops are copies only. Top level, Video and Photo open the Add Files sheet pre-staged; any
    /// other folder is staged, then confirmed with a dialog before anything is copied.
    private func handleDrop(_ urls: [URL], into target: URL?) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, let root, pendingDrop == nil else { return false }
        let dest = target ?? root
        switch ShootBrowser.dropTarget(for: dest, root: root) {
        case .sorted:
            model.addFiles(to: item.id, urls: files, target: .sorted)
        case .exact(let exact):
            let staged = model.beginImport(shootID: item.id, urls: files, target: .exact(exact))
            let label = (ShootPlanner.relativeComponents(exact, to: root) ?? []).joined(separator: "/")
            Task {
                while true {
                    switch staged.phase {
                    case .ready:
                        if staged.selected.isEmpty {
                            dropError = staged.items.isEmpty ? "There was nothing to copy in what you dropped."
                                : "Everything you dropped is already in this shoot."
                            staged.cancel()
                        } else {
                            pendingDrop = PendingDrop(staging: staged, label: label.isEmpty ? item.record.name : label,
                                                      count: staged.selected.count, skipped: staged.skippedDuplicateCount)
                        }
                        return
                    case .failed(let message):
                        dropError = message
                        return
                    default:
                        try? await Task.sleep(for: .milliseconds(100))
                        if Task.isCancelled { staged.cancel(); return }
                    }
                }
            }
        }
        return true
    }

    // MARK: Loading

    private func reload() async {
        guard let root else { entries = []; loaded = true; return }
        let target = ShootBrowser.clamp(folder ?? root, root: root)
        let listed = await Task.detached(priority: .userInitiated) {
            ShootBrowser.list(target, root: root)
        }.value
        guard !Task.isCancelled else { return }
        entries = listed
        loaded = true
    }

    // MARK: Navigation

    private func open(_ url: URL, root: URL) {
        folder = ShootBrowser.clamp(url, root: root)
        selection = []
        grid.clear()
        loaded = false
    }

    private func open(parentOf url: URL, root: URL) {
        open(url.deletingLastPathComponent(), root: root)
    }

    private func activate(_ entry: ShootEntry) {
        guard let root else { return }
        if entry.isFolder { open(entry.url, root: root) } else { model.quickLook([entry.url]) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.browsingShootID = nil } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Back to Media")
            .keyboardShortcut("[", modifiers: .command)

            breadcrumb

            Spacer()

            let chosen = selectedEntries.filter { !$0.isFolder }
            Button { model.quickLook(chosen.map(\.url), toggle: true) } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Quick Look (Space)")
            .keyboardShortcut(.space, modifiers: [])
            .disabled(chosen.isEmpty)

            Button {
                let picked = selectedEntries.map(\.url)
                model.revealInFinder(picked.isEmpty ? [folder ?? root].compactMap { $0 } : picked)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(root == nil)
            .help(selection.isEmpty ? "Show folder in Finder" : "Show selection in Finder")

            Button {
                staging = model.beginImport(shootID: item.id, urls: [], target: .sorted)
            } label: {
                Label("Add Files…", systemImage: "plus")
            }
            .disabled(root == nil)
            .help("Copy files and folders into this shoot")

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

    @ViewBuilder private var breadcrumb: some View {
        if let root, let crumbs = ShootBrowser.breadcrumb(from: root, to: folder ?? root) {
            HStack(spacing: 5) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    let isLast = index == crumbs.count - 1
                    Button {
                        open(crumb.url, root: root)
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 { Image(systemName: "film.stack").foregroundStyle(.secondary) }
                            Text(index == 0 ? item.record.name : crumb.name)
                                .fontWeight(isLast ? .semibold : .regular)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)
        } else {
            Text(item.record.name).font(.system(size: 13, weight: .semibold))
        }
    }

    // MARK: Content

    private var selectedEntries: [ShootEntry] { entries.filter { selection.contains($0.id) } }

    @ViewBuilder private func content(root: URL) -> some View {
        if !loaded {
            ProgressView().controlSize(.small)
        } else if entries.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else if mode == .icons {
            iconGrid
        } else {
            listView
        }
    }

    private var gridLayout: GridLayout<URL> {
        let columns = GridLayout<URL>.columnCount(width: gridWidth, itemMinimum: iconSize + 16,
                                                   spacing: Self.gridSpacing, padding: 0)
        return GridLayout(sections: [entries.map(\.id)], columns: columns)
    }

    private var iconGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize + 16), spacing: Self.gridSpacing)],
                          alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        EntryIcon(entry: entry, size: iconSize, selected: selection.contains(entry.id))
                            .id(entry.id)
                            .onTapGesture {
                                gridFocused = true
                                click(entry)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                grid.click(entry.id, section: 0)
                                selection = grid.selected
                                activate(entry)
                            })
                            .contextMenu { entryMenu(targets(for: entry)) }
                            .modifier(FolderDrop(entry: entry, hover: $dropHover, highlight: true) { handleDrop($0, into: entry.url) })
                    }
                }
                .onGeometryChange(for: Double.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(12)
            }
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
            .task { gridFocused = true }
            .onKeyPress(phases: [.down, .repeat]) { handleKey($0, proxy: proxy) }
        }
    }

    private func click(_ entry: ShootEntry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            grid.toggle(entry.id, section: 0)
        } else if flags.contains(.shift) {
            grid.extend(to: entry.id, section: 0, in: gridLayout)
        } else {
            grid.click(entry.id, section: 0)
        }
        selection = grid.selected
    }

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        if press.modifiers.contains(.option) || press.modifiers.contains(.control) { return .ignored }
        let layout = gridLayout
        if press.modifiers.contains(.command) {
            guard press.characters == "a", !press.modifiers.contains(.shift) else { return .ignored }
            grid.selectAll(in: layout)
            selection = grid.selected
            return .handled
        }
        if press.key == .return, let only = selectedEntries.first, selection.count == 1 {
            activate(only)
            return .handled
        }
        let direction: GridSelection<URL>.Direction
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
        if let cursor = grid.cursor { proxy.scrollTo(cursor) }
        return .handled
    }

    private var listView: some View {
        Table(entries, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(entry)).foregroundStyle(.secondary).frame(width: 16)
                    Text(entry.name)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(FolderDrop(entry: entry, hover: $dropHover, highlight: true) { handleDrop($0, into: entry.url) })
            }
            .width(min: 140, ideal: 240)
            TableColumn("Date Modified") { entry in
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Size") { entry in
                Text(entry.isFolder ? "--" : Format.bytes(entry.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 55, ideal: 70)
            TableColumn("Kind") { entry in
                Text(Self.kindLabel(entry)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: URL.self) { ids in
            let picked = entries.filter { ids.contains($0.id) }
            if !picked.isEmpty { entryMenu(picked) }
        } primaryAction: { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) { activate(entry) }
        }
    }

    // MARK: Actions

    private func targets(for entry: ShootEntry) -> [ShootEntry] {
        selection.contains(entry.id) ? selectedEntries : [entry]
    }

    @ViewBuilder private func entryMenu(_ picked: [ShootEntry]) -> some View {
        if picked.count == 1, let one = picked.first, one.isFolder {
            Button("Open") { activate(one) }
        }
        let files = picked.filter { !$0.isFolder }
        if !files.isEmpty {
            Button("Quick Look") { model.quickLook(files.map(\.url)) }
        }
        Button("Show in Finder") { model.revealInFinder(picked.map(\.url)) }
    }

    private var statusBar: some View {
        let files = entries.filter { !$0.isFolder }
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        var text = "\(Format.count(entries.count, "item", "items")) · \(Format.bytes(bytes))"
        if !selection.isEmpty { text = "\(selection.count) of " + text + " selected" }
        let running = model.imports.filter { $0.shootID == item.id && $0.isActive }.count
        if running > 0 { text += " — Adding files…" }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Theme.surface)
    }

    static func symbol(_ entry: ShootEntry) -> String {
        if entry.isFolder { return "folder.fill" }
        switch entry.kind {
        case .video: return "film"
        case .photo: return "photo"
        case .audio: return "waveform"
        case nil: return "doc"
        }
    }

    static func kindLabel(_ entry: ShootEntry) -> String {
        if entry.isFolder { return "Folder" }
        let ext = entry.url.pathExtension.uppercased()
        let kind = switch entry.kind {
        case .video: "Video"
        case .photo: "Photo"
        case .audio: "Audio"
        case nil: "Document"
        }
        return ext.isEmpty ? kind : "\(ext) \(kind)"
    }
}

/// Makes a folder cell a drop target for Finder files, highlighted while a drag is over it.
private struct FolderDrop: ViewModifier {
    let entry: ShootEntry
    @Binding var hover: URL?
    let highlight: Bool
    let drop: ([URL]) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        if entry.isFolder {
            content
                .background(targeted ? Theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: {
                    targeted = $0
                    if $0 { hover = entry.url } else if hover == entry.url { hover = nil }
                }
        } else {
            content
        }
    }
}

/// One file or folder in icon view: thumbnail over a name, like Finder.
private struct EntryIcon: View {
    @Environment(AppModel.self) private var model
    let entry: ShootEntry
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
                    Image(systemName: ShootBrowserView.symbol(entry))
                        .font(.system(size: size * 0.3, weight: .light))
                        .foregroundStyle(entry.isFolder ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(width: size, height: size * 0.75)
            .padding(6)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))

            Text(entry.name)
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
        .help("\(entry.name)\(entry.isFolder ? "" : " · \(Format.bytes(entry.size))") · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
        .task(id: entry.id) {
            guard !entry.isFolder, entry.kind != nil else { image = nil; return }
            image = try? await model.thumbnails.thumbnail(for: entry.url, maxPixels: 320)
        }
    }
}
