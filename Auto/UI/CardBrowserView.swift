import SwiftUI

/// Finder-style, read-only view of one card's files, grouped into "Not Backed Up" and the shoots
/// that hold verified copies. Read-only except "Add to Shoot", which goes through the same checked
/// add-footage flow as the sheet. Space or double-click opens Quick Look.
///
/// The icon grid and list live in `CardBrowserView+Files.swift`, the Add to Shoot flow in
/// `CardBrowserView+AddToShoot.swift`, and the small row/cell views in `CardBrowserPieces.swift`.
/// State is not `private` so those extensions can reach it.
struct CardBrowserView: View {
    @Environment(AppModel.self) var model
    let card: Card

    /// What the locations sidebar has selected.
    enum Place: Hashable {
        case all
        case group(CardBrowser.GroupKind)
    }

    /// An Add to Shoot request that found duplicates and is waiting for the user's call.
    struct PendingAdd {
        let files: [MediaFile]
        let shootID: UUID
        let duplicateCount: Int
        let places: String
        /// Set when every selected file is already inside the target shoot.
        var inShootName: String?
        var allDuplicates: Bool { duplicateCount >= files.count }
    }

    @State private var place: Place? = .all
    @State var selection = Set<MediaFile.ID>()
    /// Anchor/cursor bookkeeping for icon-view clicks and keys; `selection` stays the source of truth.
    @State var grid = GridSelection<MediaFile.ID>()
    @State var gridWidth = BrowserGrid.initialWidth
    @FocusState var gridFocused: Bool
    @AppStorage("cardBrowserMode") var mode: BrowserViewMode = .icons
    @AppStorage("cardBrowserIconSize") var iconSize = BrowserGrid.defaultIconSize
    @State var adding = false
    @State var actionError: String?
    @State var pendingAdd: PendingAdd?

    /// The group the sidebar is filtered to; nil shows every group.
    var location: CardBrowser.GroupKind? {
        if case .group(let kind)? = place { kind } else { nil }
    }

    // MARK: Body

    var body: some View {
        let groups = model.browserGroups(for: card)
        let shown = shownGroups(from: groups)
        let shownIDs = Set(CardBrowser.uniqueFiles(shown).map(\.id))

        layout(groups: groups, shown: shown)
            .onAppear { model.browserAppeared(card.id) }
            .onChange(of: mode) { _, newMode in
                if newMode == .icons { gridFocused = true }
            }
            .onDisappear { model.browserDisappeared(card.id) }
            .onChange(of: groups.map(\.kind)) { _, kinds in
                showAllFilesIfLocationIsGone(remainingKinds: kinds)
            }
            .onChange(of: place) { selection = [] }
            // Selection only ever holds files that are shown (membership can move files out of this place).
            .onChange(of: shownIDs) { _, present in
                grid.prune(keeping: present)
                selection = selection.filter(present.contains)
            }
            // Keep the grid's anchor/cursor in step with outside changes (Esc, list mode, place changes).
            .onChange(of: selection) { _, newSelection in
                if grid.selected != newSelection { grid = GridSelection(selected: newSelection) }
            }
            .confirmationDialog(
                pendingAdd.map(dialogTitle) ?? "",
                isPresented: isPendingAddShown,
                titleVisibility: .visible,
                presenting: pendingAdd
            ) { pending in
                pendingAddButtons(pending)
            }
            .alert("Couldn't add to shoot", isPresented: isActionErrorShown) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            // Esc clears the selection, then goes back.
            .hiddenShortcut(.cancelAction) { clearSelectionOrGoBack() }
            // ⌘A as a key equivalent too, so it works even when the grid or table doesn't have focus
            // (or the Edit menu's Select All would otherwise swallow it).
            .hiddenShortcut(KeyboardShortcut("a", modifiers: .command)) { selectAll(in: shown) }
    }

    private func layout(groups: [CardBrowser.Group], shown: [CardBrowser.Group]) -> some View {
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
    }

    private func shownGroups(from groups: [CardBrowser.Group]) -> [CardBrowser.Group] {
        guard let location else { return groups }
        return groups.filter { $0.kind == location }
    }

    // MARK: Reacting to changes

    private func showAllFilesIfLocationIsGone(remainingKinds: [CardBrowser.GroupKind]) {
        if let location, !remainingKinds.contains(location) { place = .all }
    }

    private func clearSelectionOrGoBack() {
        if selection.isEmpty {
            model.browsingCardID = nil
        } else {
            selection = []
        }
    }

    private func selectAll(in shown: [CardBrowser.Group]) {
        if mode == .icons {
            grid.selectAll(in: gridLayout(shown))
            selection = grid.selected
        } else {
            selection = Set(shown.flatMap(\.files).map(\.id))
        }
    }

    private var isPendingAddShown: Binding<Bool> {
        Binding(get: { pendingAdd != nil }, set: { if !$0 { pendingAdd = nil } })
    }

    private var isActionErrorShown: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: Toolbar

    private func toolbar(groups: [CardBrowser.Group]) -> some View {
        let chosen = selectedFiles(groups)
        return HStack(spacing: 10) {
            BrowserBackButton { model.browsingCardID = nil }

            pathLabel(groups: groups)

            Spacer()

            BrowserQuickLookButton(isDisabled: chosen.isEmpty) { quickLook(chosen, toggle: true) }

            Button { model.revealInFinder(chosen.isEmpty ? [card.volume] : chosen.map(\.url)) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(chosen.isEmpty ? "Show card in Finder" : "Show selection in Finder")

            addToShootMenu(chosen, groups: groups)

            BrowserViewControls(mode: $mode, iconSize: $iconSize)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// "Card name › Location": the card, then the sidebar location when one is picked.
    private func pathLabel(groups: [CardBrowser.Group]) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sdcard.fill").foregroundStyle(.secondary)
            Text(card.name).fontWeight(.semibold)
            if let title = locationTitle(in: groups) {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Text(title)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

    private func locationTitle(in groups: [CardBrowser.Group]) -> String? {
        guard let location else { return nil }
        return groups.first { $0.kind == location }?.title
    }

    // MARK: Locations sidebar

    private func locations(_ groups: [CardBrowser.Group]) -> some View {
        let notBackedUp = groups.filter { $0.kind == .notBackedUp }
        let backedUp = groups.filter { $0.kind != .notBackedUp }
        let shootsStillChecking = hiddenShootsStillChecking(groups: groups)

        return List(selection: $place) {
            Section(card.name) {
                LocationRow(title: "All Files", symbol: "sdcard", tint: .secondary, count: card.files.count)
                    .tag(Place.all)
                ForEach(notBackedUp) { group in
                    LocationRow(title: group.title, symbol: "exclamationmark.circle.fill",
                                tint: Color(nsColor: AppModel.Status.unbacked.tint), count: group.files.count)
                        .tag(Place.group(group.kind))
                }
            }
            if !backedUp.isEmpty || shootsStillChecking > 0 {
                Section("Backed Up") {
                    ForEach(backedUp) { group in
                        backedUpRow(group)
                    }
                    if shootsStillChecking > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking \(Format.count(shootsStillChecking, "shoot", "shoots"))…")
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

    private func backedUpRow(_ group: CardBrowser.Group) -> some View {
        let membership = group.kind.shootID.flatMap { model.browserMembership[$0] }
        var failureReason: String?
        if case .failed(let reason)? = membership { failureReason = reason }

        return LocationRow(title: group.title,
                           symbol: group.kind.backedUpSymbol,
                           tint: Theme.accent,
                           count: group.files.count,
                           checking: membership == .checking,
                           failure: failureReason)
            .tag(Place.group(group.kind))
    }

    /// Shoots whose membership check is still running and that have no row in the sidebar yet.
    private func hiddenShootsStillChecking(groups: [CardBrowser.Group]) -> Int {
        let shootsWithARow = Set(groups.compactMap { $0.kind.shootID })
        return model.browserMembership
            .filter { shootID, state in state == .checking && !shootsWithARow.contains(shootID) }
            .count
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

    // MARK: Status bar

    private func statusBar(_ groups: [CardBrowser.Group]) -> some View {
        BrowserStatusBar(text: statusText(groups))
    }

    private func statusText(_ groups: [CardBrowser.Group]) -> String {
        let files = CardBrowser.uniqueFiles(groups)
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        var text = BrowserStatusBar.summary(itemCount: files.count, bytes: bytes, selectedCount: selection.count)

        if card.phase == .scanning || card.phase == .verifying {
            text += " — Checking backup…"
        } else if card.phase == .copying {
            let progress = card.progress
            let currentFileNumber = min(progress.filesDone + 1, progress.filesTotal)
            text += " — Copying \(currentFileNumber) of \(progress.filesTotal)…"
        }
        if model.browserMembership.values.contains(.checking) { text += " — Checking shoots…" }
        return text
    }

    // MARK: Selection and Quick Look

    /// Selected files in on-screen order.
    func selectedFiles(_ groups: [CardBrowser.Group]) -> [MediaFile] {
        CardBrowser.uniqueFiles(groups).filter { selection.contains($0.id) }
    }

    /// Right-clicking a selected file acts on the whole selection; otherwise on just that file.
    func targets(for file: MediaFile, in groups: [CardBrowser.Group]) -> [MediaFile] {
        selection.contains(file.id) ? selectedFiles(groups) : [file]
    }

    /// Previews `files`; does nothing with no files, like Finder. Only Space toggles the panel closed.
    func quickLook(_ files: [MediaFile], toggle: Bool = false) {
        guard !files.isEmpty else { return }
        model.quickLook(files.map(\.url), toggle: toggle)
    }
}

nonisolated extension CardBrowser.GroupKind {
    var shootID: UUID? {
        if case .shoot(let id) = self { id } else { nil }
    }

    /// Icon for a group of backed-up files: a drive when they sit outside every shoot, else a folder.
    var backedUpSymbol: String {
        self == .elsewhere ? "externaldrive.fill" : "folder.fill"
    }
}
