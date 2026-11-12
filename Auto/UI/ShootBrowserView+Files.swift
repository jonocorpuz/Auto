import SwiftUI

/// The two ways the shoot browser shows a folder: the icon grid and the list table.
extension ShootBrowserView {
    // MARK: Icon grid

    var iconGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: BrowserGrid.columns(iconSize: iconSize),
                          alignment: .leading, spacing: BrowserGrid.rowSpacing) {
                    ForEach(entries) { entry in
                        icon(for: entry)
                    }
                }
                .onGeometryChange(for: Double.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(12)
            }
            .background(Theme.surface)
            .contentShape(Rectangle())
            .onTapGesture { clickEmptySpace() }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .task { gridFocused = true }
            .onKeyPress(phases: [.down, .repeat]) { handleKey($0, proxy: proxy) }
        }
    }

    private func icon(for entry: ShootEntry) -> some View {
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
            .modifier(FolderDrop(entry: entry, hover: $dropHover) { handleDrop($0, into: entry.url) })
    }

    /// The whole folder is one section.
    var gridLayout: GridLayout<URL> {
        let columns = BrowserGrid.columnCount(gridWidth: gridWidth, iconSize: iconSize)
        return GridLayout(sections: [entries.map(\.id)], columns: columns)
    }

    private func clickEmptySpace() {
        gridFocused = true
        grid.clear()
        selection = []
    }

    /// ⌘-click toggles, ⇧-click extends the range, a plain click selects just this entry.
    private func click(_ entry: ShootEntry) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            grid.toggle(entry.id, section: 0)
        } else if modifiers.contains(.shift) {
            grid.extend(to: entry.id, section: 0, in: gridLayout)
        } else {
            grid.click(entry.id, section: 0)
        }
        selection = grid.selected
    }

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        if press.hasOptionOrControl { return .ignored }
        let layout = gridLayout

        if press.modifiers.contains(.command) {
            let isSelectAll = press.characters == "a" && !press.modifiers.contains(.shift)
            guard isSelectAll else { return .ignored }
            grid.selectAll(in: layout)
            selection = grid.selected
            return .handled
        }

        if press.key == .return, selection.count == 1, let onlySelected = selectedEntries.first {
            activate(onlySelected)
            return .handled
        }

        guard let direction: GridSelection<URL>.Direction = press.gridDirection() else { return .ignored }
        grid.move(direction, extend: press.modifiers.contains(.shift), in: layout)
        selection = grid.selected
        if let cursor = grid.cursor { proxy.scrollTo(cursor) }
        return .handled
    }

    // MARK: List

    var listView: some View {
        Table(entries, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.symbol).foregroundStyle(.secondary).frame(width: 16)
                    Text(entry.name)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(FolderDrop(entry: entry, hover: $dropHover) { handleDrop($0, into: entry.url) })
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
                Text(entry.kindLabel).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: URL.self) { ids in
            let clicked = entries.filter { ids.contains($0.id) }
            if !clicked.isEmpty { entryMenu(clicked) }
        } primaryAction: { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) { activate(entry) }
        }
    }

    // MARK: Context menu

    /// Right-clicking a selected entry acts on the whole selection; otherwise on just that entry.
    private func targets(for entry: ShootEntry) -> [ShootEntry] {
        selection.contains(entry.id) ? selectedEntries : [entry]
    }

    @ViewBuilder private func entryMenu(_ targets: [ShootEntry]) -> some View {
        if targets.count == 1, let onlyTarget = targets.first, onlyTarget.isFolder {
            Button("Open") { activate(onlyTarget) }
        }
        let files = targets.filter { !$0.isFolder }
        if !files.isEmpty {
            Button("Quick Look") { model.quickLook(files.map(\.url)) }
        }
        Button("Show in Finder") { model.revealInFinder(targets.map(\.url)) }
    }
}
