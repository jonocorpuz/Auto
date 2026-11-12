import SwiftUI

/// Finder-style, read-only view of one shoot's primary online copy. Folders open on double-click,
/// the breadcrumb climbs back out, Space opens Quick Look. Nothing here deletes, renames or moves.
///
/// The icon grid and list live in `ShootBrowserView+Files.swift`, Finder drops in
/// `ShootBrowserView+Dropping.swift`, and the small cell views in `ShootBrowserPieces.swift`.
/// State is not `private` so those extensions can reach it.
struct ShootBrowserView: View {
    @Environment(AppModel.self) var model
    let item: ShootItem

    /// A Finder drop into an exact folder, staged and waiting for the user's confirmation.
    struct PendingDrop {
        let staging: ImportStaging
        let label: String
        let count: Int
        let skipped: Int
    }

    /// The folder being shown; nil means the shoot's top level.
    @State var folder: URL?
    @State var entries: [ShootEntry] = []
    @State private var loaded = false
    @State var selection = Set<URL>()
    @State var grid = GridSelection<URL>()
    @State var gridWidth = BrowserGrid.initialWidth
    @FocusState var gridFocused: Bool
    @AppStorage("shootBrowserMode") var mode: BrowserViewMode = .icons
    @AppStorage("shootBrowserIconSize") var iconSize = BrowserGrid.defaultIconSize
    /// The Add Files sheet, when it was opened from this browser's toolbar.
    @State private var staging: ImportStaging?
    /// The folder cell a Finder drag is currently over.
    @State var dropHover: URL?
    @State private var backgroundTargeted = false
    @State var pendingDrop: PendingDrop?
    @State var dropError: String?

    /// The shoot's effective primary copy, when it is online.
    var root: URL? {
        item.copies.first { $0.availability == .online }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    var selectedEntries: [ShootEntry] {
        entries.filter { selection.contains($0.id) }
    }

    /// This shoot's Add Files runs, running or finished.
    private var importJobs: [ImportJob] {
        model.imports.filter { $0.shootID == item.id }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ThemedDivider()
            if let root {
                browser(root: root)
            } else {
                ContentUnavailableView("Shoot not available",
                                       systemImage: "externaldrive.badge.xmark",
                                       description: Text("Connect the drive that holds this shoot to browse it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: loadKey) { await reload() }
        .onChange(of: root) { folder = nil; selection = [] }
        .onChange(of: mode) { _, newMode in
            if newMode == .icons { gridFocused = true }
        }
        .onChange(of: entries) { _, newEntries in
            let present = Set(newEntries.map(\.id))
            grid.prune(keeping: present)
            selection = selection.filter(present.contains)
        }
        .onChange(of: selection) { _, newSelection in
            if grid.selected != newSelection { grid = GridSelection(selected: newSelection) }
        }
        .sheet(item: $staging) { staging in
            AddFilesSheet(staging: staging)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls, into: folder ?? root)
        } isTargeted: { backgroundTargeted = $0 }
        .overlay {
            // A folder cell under the drag shows its own highlight instead.
            if backgroundTargeted && dropHover == nil {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 2).padding(2).allowsHitTesting(false)
            }
        }
        .confirmationDialog(dropConfirmTitle, isPresented: isDropConfirmShown, presenting: pendingDrop) { drop in
            dropConfirmButtons(drop)
        } message: { drop in
            Text(dropConfirmMessage(drop))
        }
        .alert("Couldn't add files", isPresented: isDropErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dropError ?? "")
        }
        // Esc clears the selection, then goes up a folder, then back to the shoots grid.
        .hiddenShortcut(.cancelAction) { clearSelectionOrGoUp() }
        .hiddenShortcut(KeyboardShortcut("a", modifiers: .command)) { selectAll() }
    }

    private func browser(root: URL) -> some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            let jobs = importJobs
            if !jobs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(jobs) { ImportProgressRow(job: $0) }
                }
                .padding(12)
            }
            ThemedDivider()
            statusBar
        }
        // A new identity per folder, so scroll position and focus start fresh.
        .id(folder ?? root)
    }

    private func clearSelectionOrGoUp() {
        if !selection.isEmpty {
            selection = []
        } else if let root, let folder, folder != root {
            open(folder.deletingLastPathComponent(), root: root)
        } else {
            model.browsingShootID = nil
        }
    }

    private func selectAll() {
        if mode == .icons {
            grid.selectAll(in: gridLayout)
            selection = grid.selected
        } else {
            selection = Set(entries.map(\.id))
        }
    }

    // MARK: Loading

    /// Reload when the folder changes, and when one of this shoot's imports starts or finishes.
    private struct LoadKey: Hashable {
        let folder: URL?
        let imports: [ImportState]
    }

    private struct ImportState: Hashable {
        let id: UUID
        let finished: Bool
    }

    private var loadKey: LoadKey {
        let imports = importJobs.map { ImportState(id: $0.id, finished: $0.isFinished) }
        return LoadKey(folder: folder, imports: imports)
    }

    private func reload() async {
        guard let root else {
            entries = []
            loaded = true
            return
        }
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

    /// Double-click or Return: folders open, files preview.
    func activate(_ entry: ShootEntry) {
        guard let root else { return }
        if entry.isFolder {
            open(entry.url, root: root)
        } else {
            model.quickLook([entry.url])
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let selectedFiles = selectedEntries.filter { !$0.isFolder }
        return HStack(spacing: 10) {
            BrowserBackButton { model.browsingShootID = nil }

            breadcrumb

            Spacer()

            BrowserQuickLookButton(isDisabled: selectedFiles.isEmpty) {
                model.quickLook(selectedFiles.map(\.url), toggle: true)
            }

            Button { revealSelectionOrFolder() } label: {
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

            BrowserViewControls(mode: $mode, iconSize: $iconSize)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func revealSelectionOrFolder() {
        let selectedURLs = selectedEntries.map(\.url)
        if !selectedURLs.isEmpty {
            model.revealInFinder(selectedURLs)
        } else if let shownFolder = folder ?? root {
            model.revealInFinder([shownFolder])
        } else {
            model.revealInFinder([])
        }
    }

    @ViewBuilder private var breadcrumb: some View {
        if let root, let crumbs = ShootBrowser.breadcrumb(from: root, to: folder ?? root) {
            HStack(spacing: 5) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    let isShootRoot = index == 0
                    let isCurrentFolder = index == crumbs.count - 1
                    if !isShootRoot {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button {
                        open(crumb.url, root: root)
                    } label: {
                        HStack(spacing: 4) {
                            if isShootRoot { Image(systemName: "film.stack").foregroundStyle(.secondary) }
                            Text(isShootRoot ? item.record.name : crumb.name)
                                .fontWeight(isCurrentFolder ? .semibold : .regular)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrentFolder)
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)
        } else {
            Text(item.record.name).font(.system(size: 13, weight: .semibold))
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
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

    // MARK: Status bar

    private var statusBar: some View {
        BrowserStatusBar(text: statusText)
    }

    private var statusText: String {
        let files = entries.filter { !$0.isFolder }
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        var text = BrowserStatusBar.summary(itemCount: entries.count, bytes: bytes, selectedCount: selection.count)
        let isAddingFiles = importJobs.contains { $0.isActive }
        if isAddingFiles { text += " — Adding files…" }
        return text
    }
}
