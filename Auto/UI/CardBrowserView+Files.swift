import SwiftUI

/// The two ways the card browser shows files: the icon grid and the list table.
extension CardBrowserView {
    /// Approximate height of the pinned group header.
    private static let headerHeight = 34.0

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

    // MARK: Icon grid

    func iconGrid(_ groups: [CardBrowser.Group]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: BrowserGrid.columns(iconSize: iconSize), alignment: .leading,
                          spacing: BrowserGrid.rowSpacing, pinnedViews: .sectionHeaders) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { section, group in
                        Section {
                            ForEach(group.files) { file in
                                icon(for: file, in: group, section: section, groups: groups)
                            }
                        } header: {
                            GroupHeader(group: group)
                        }
                    }
                }
                // Measured inside the scroll view, so an always-visible scrollbar is already excluded.
                .onGeometryChange(for: Double.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .background(Theme.surface)
            .contentShape(Rectangle())
            .onTapGesture { clickEmptySpace() }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .task { gridFocused = true }
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKey(press, groups: groups, proxy: proxy)
            }
        }
    }

    private func icon(for file: MediaFile, in group: CardBrowser.Group, section: Int,
                      groups: [CardBrowser.Group]) -> some View {
        FileIcon(file: file, size: iconSize, selected: selection.contains(file.id))
            // Scroll target sits a header's height above the cell so a minimal
            // scroll upward doesn't leave the icon under the pinned header.
            .overlay(alignment: .top) {
                Color.clear.frame(width: 1, height: 1)
                    .offset(y: -Self.headerHeight)
                    .id(IconID(kind: group.kind, file: file.id))
            }
            .onTapGesture {
                gridFocused = true
                clickIcon(file, section: section, groups: groups)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                grid.click(file.id, section: section)
                selection = grid.selected
                quickLook([file])
            })
            // Built only when the menu opens, not for every cell on every body pass.
            .contextMenu { LazyFileMenu(owner: self, file: file, groups: groups) }
    }

    func gridLayout(_ groups: [CardBrowser.Group]) -> GridLayout<MediaFile.ID> {
        let columns = BrowserGrid.columnCount(gridWidth: gridWidth, iconSize: iconSize)
        return GridLayout(sections: groups.map { $0.files.map(\.id) }, columns: columns)
    }

    private func clickEmptySpace() {
        gridFocused = true
        grid.clear()
        selection = []
    }

    /// ⌘-click toggles, ⇧-click extends the range, a plain click selects just this file.
    private func clickIcon(_ file: MediaFile, section: Int, groups: [CardBrowser.Group]) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            grid.toggle(file.id, section: section)
        } else if modifiers.contains(.shift) {
            grid.extend(to: file.id, section: section, in: gridLayout(groups))
        } else {
            grid.click(file.id, section: section)
        }
        selection = grid.selected
    }

    private func handleKey(_ press: KeyPress, groups: [CardBrowser.Group], proxy: ScrollViewProxy) -> KeyPress.Result {
        // Cmd-Up/Down aren't supported either: the only Command key handled here is ⌘A.
        if press.hasOptionOrControl { return .ignored }
        let layout = gridLayout(groups)

        if press.modifiers.contains(.command) {
            let isSelectAll = press.characters == "a" && !press.modifiers.contains(.shift)
            guard isSelectAll else { return .ignored }
            grid.selectAll(in: layout)
            selection = grid.selected
            return .handled
        }

        guard let direction: GridSelection<MediaFile.ID>.Direction = press.gridDirection() else { return .ignored }
        grid.move(direction, extend: press.modifiers.contains(.shift), in: layout)
        selection = grid.selected
        scrollToCursor(layout: layout, groups: groups, proxy: proxy)
        return .handled
    }

    /// A file can sit in several groups; scroll to the icon the cursor is on.
    private func scrollToCursor(layout: GridLayout<MediaFile.ID>, groups: [CardBrowser.Group], proxy: ScrollViewProxy) {
        guard let cursor = grid.cursor,
              let position = layout.position(of: cursor, preferring: grid.cursorSection) else { return }
        proxy.scrollTo(IconID(kind: groups[position.section].kind, file: cursor))
    }

    // MARK: List

    func listView(_ groups: [CardBrowser.Group]) -> some View {
        Table(of: Row.self, selection: rowSelection(groups)) {
            TableColumn("Name") { row in
                HStack(spacing: 6) {
                    Image(systemName: row.file.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                    Text(row.file.name)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Date Recorded") { row in
                Text(row.file.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Size") { row in
                Text(Format.bytes(row.file.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 55, ideal: 70)
            TableColumn("Kind") { row in
                Text(BrowserKindLabel.text(for: row.file.url, kindName: row.file.kind.displayName))
                    .foregroundStyle(.secondary)
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
        .contextMenu(forSelectionType: Row.ID.self) { rowIDs in
            let files = files(for: rowIDs, groups)
            if !files.isEmpty { fileMenu(files, groups: groups) }
        } primaryAction: { rowIDs in
            quickLook(files(for: rowIDs, groups))
        }
    }

    /// Table selection is per row; the browser selects files. Selecting a row selects its file, and
    /// every row of a selected file shows selected.
    private func rowSelection(_ groups: [CardBrowser.Group]) -> Binding<Set<Row.ID>> {
        Binding {
            selectedRows(groups)
        } set: { newRows in
            // A plain click or arrow selects exactly that row's file.
            if newRows.count <= 1, !NSEvent.modifierFlags.contains(.command) {
                selection = Set(newRows.map(\.file))
                return
            }
            // Otherwise diff against the rows shown selected: a file with several rows is deselected
            // when any of its rows is removed and selected when any is added.
            let oldRows = selectedRows(groups)
            let removedRows = oldRows.subtracting(newRows)
            let addedRows = newRows.subtracting(oldRows)
            var newSelection = selection
            newSelection.subtract(removedRows.map(\.file))
            newSelection.formUnion(addedRows.map(\.file))
            selection = newSelection
        }
    }

    /// Every row whose file is selected.
    private func selectedRows(_ groups: [CardBrowser.Group]) -> Set<Row.ID> {
        var rows = Set<Row.ID>()
        for group in groups {
            for file in group.files where selection.contains(file.id) {
                rows.insert(Row.ID(kind: group.kind, file: file.id))
            }
        }
        return rows
    }

    /// The files behind some list rows, in on-screen order.
    private func files(for rows: Set<Row.ID>, _ groups: [CardBrowser.Group]) -> [MediaFile] {
        let fileIDs = Set(rows.map(\.file))
        return CardBrowser.uniqueFiles(groups).filter { fileIDs.contains($0.id) }
    }
}
