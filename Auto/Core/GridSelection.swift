import Foundation

/// The on-screen arrangement of an icon grid: sections of IDs laid out in `columns` columns. Each
/// section starts a new row, like a sectioned `LazyVGrid`. An ID may appear in several sections (a
/// file in two groups); navigation works on section-qualified positions so it never gets stuck.
nonisolated struct GridLayout<ID: Hashable> {
    typealias Position = (section: Int, index: Int)

    /// Section order is preserved as given (empty sections stay, so section numbers match the caller's).
    let sections: [[ID]]
    let columns: Int

    init(sections: [[ID]], columns: Int) {
        self.sections = sections
        self.columns = max(1, columns)
    }

    /// Distinct items in on-screen (reading) order; an ID shown in several sections counts once, at
    /// its first occurrence.
    var flat: [ID] {
        var seen = Set<ID>()
        return sections.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// Every on-screen slot in reading order, duplicates included.
    var positions: [Position] {
        sections.enumerated().flatMap { section, items in
            items.indices.map { (section: section, index: $0) }
        }
    }

    func id(at position: Position) -> ID { sections[position.section][position.index] }

    /// Columns SwiftUI fits for `GridItem(.adaptive(minimum:), spacing:)` in `width` with horizontal padding.
    static func columnCount(width: Double, itemMinimum: Double, spacing: Double, padding: Double) -> Int {
        let usable = width - 2 * padding
        return max(1, Int(((usable + spacing) / (itemMinimum + spacing)).rounded(.down)))
    }

    /// First occurrence of `id`.
    func position(of id: ID) -> Position? {
        for (section, items) in sections.enumerated() {
            if let index = items.firstIndex(of: id) { return (section, index) }
        }
        return nil
    }

    /// `id` within `section` if it is there, otherwise its first occurrence.
    func position(of id: ID, preferring section: Int?) -> Position? {
        if let section, sections.indices.contains(section), let index = sections[section].firstIndex(of: id) {
            return (section, index)
        }
        return position(of: id)
    }

    /// The slot one row up or down in the same column, crossing sections and clamping to the last
    /// item of a short row. nil at the top or bottom edge.
    func vertical(from position: Position, down: Bool) -> Position? {
        let (section, index) = position
        let row = index / columns
        let column = index % columns
        let count = sections[section].count
        if down {
            let nextRowStart = (row + 1) * columns
            if nextRowStart < count { return (section, min(nextRowStart + column, count - 1)) }
            let laterSections = section + 1..<sections.count
            guard let next = laterSections.first(where: { !sections[$0].isEmpty }) else { return nil }
            return (next, min(column, sections[next].count - 1))
        } else {
            if row > 0 { return (section, (row - 1) * columns + column) }
            guard let previous = (0..<section).last(where: { !sections[$0].isEmpty }) else { return nil }
            let previousCount = sections[previous].count
            let lastRowStart = ((previousCount - 1) / columns) * columns
            return (previous, min(lastRowStart + column, previousCount - 1))
        }
    }
}

/// Finder-style icon-view selection: click, ⌘-click, ⇧-click, ⌘A and arrow keys. `anchor` is where a
/// range starts; `cursor` is the lead item that arrows move and the view scrolls to. Both remember the
/// section they were last on, so a file shown in two groups navigates from the icon that was used.
nonisolated struct GridSelection<ID: Hashable> {
    enum Direction { case left, right, up, down, home, end }

    private(set) var selected = Set<ID>()
    private(set) var anchor: ID?
    private(set) var cursor: ID?
    private(set) var anchorSection: Int?
    private(set) var cursorSection: Int?

    init() {}

    init(selected: Set<ID>) {
        self.selected = selected
        if selected.count == 1 { anchor = selected.first; cursor = selected.first }
    }

    mutating func clear() { self = GridSelection() }

    /// Plain click: select just `id`. `section` is the group whose icon was used.
    mutating func click(_ id: ID, section: Int? = nil) {
        selected = [id]; anchor = id; cursor = id; anchorSection = section; cursorSection = section
    }

    /// ⌘-click: toggle `id`; it becomes the anchor.
    mutating func toggle(_ id: ID, section: Int? = nil) {
        if selected.remove(id) == nil { selected.insert(id) }
        anchor = id; cursor = id; anchorSection = section; cursorSection = section
    }

    /// ⇧-click: select anchor...id, replacing the selection. Without an anchor this is a plain click.
    mutating func extend(to id: ID, section: Int? = nil, in layout: GridLayout<ID>) {
        guard let from = anchorPosition(in: layout), let to = layout.position(of: id, preferring: section) else {
            click(id, section: section); return
        }
        selectRange(from: from, to: to, in: layout)
        cursor = id; cursorSection = to.section
    }

    /// ⌘A. The anchor and cursor are kept if still present, otherwise the first and last items.
    mutating func selectAll(in layout: GridLayout<ID>) {
        let flat = layout.flat
        guard !flat.isEmpty else { return }
        selected = Set(flat)
        if anchorPosition(in: layout) == nil { anchor = flat.first; anchorSection = nil }
        if cursorPosition(in: layout) == nil { cursor = flat.last; cursorSection = nil }
    }

    /// Arrow/Home/End. `extend` (⇧) grows the range from the anchor; otherwise the selection becomes
    /// the new cursor item. With nothing selected the first item is selected; with a selection made
    /// elsewhere (no cursor) the last selected item in reading order is the cursor and anchor.
    mutating func move(_ direction: Direction, extend: Bool, in layout: GridLayout<ID>) {
        let all = layout.positions
        guard let first = all.first, let last = all.last else { return }
        if cursorPosition(in: layout) == nil, !selected.isEmpty,
           let lead = layout.flat.last(where: selected.contains) {
            anchor = lead; cursor = lead; anchorSection = nil; cursorSection = nil
        }
        guard let current = cursorPosition(in: layout) else {
            click(layout.id(at: first), section: first.section)
            return
        }
        let target: GridLayout<ID>.Position
        switch direction {
        case .home: target = first
        case .end: target = last
        case .left, .right:
            // Skip slots showing the same file as the cursor, so the highlight always moves.
            let currentIndex = all.firstIndex { $0 == current } ?? 0
            let currentID = layout.id(at: current)
            let step = direction == .left ? -1 : 1
            var candidate = currentIndex + step
            while all.indices.contains(candidate), layout.id(at: all[candidate]) == currentID { candidate += step }
            target = all.indices.contains(candidate) ? all[candidate] : current
        case .up, .down:
            target = layout.vertical(from: current, down: direction == .down) ?? current
        }
        let targetID = layout.id(at: target)
        if extend {
            let from = anchorPosition(in: layout) ?? current
            anchor = layout.id(at: from); anchorSection = from.section
            selectRange(from: from, to: target, in: layout)
            cursor = targetID; cursorSection = target.section
        } else {
            click(targetID, section: target.section)
        }
    }

    /// Drops IDs that are no longer present (and a stale anchor/cursor).
    mutating func prune(keeping present: Set<ID>) {
        selected = selected.filter(present.contains)
        if let anchor, !present.contains(anchor) { self.anchor = nil; anchorSection = nil }
        if let cursor, !present.contains(cursor) { self.cursor = nil; cursorSection = nil }
    }

    // MARK: Private

    private func anchorPosition(in layout: GridLayout<ID>) -> GridLayout<ID>.Position? {
        anchor.flatMap { layout.position(of: $0, preferring: anchorSection) }
    }

    private func cursorPosition(in layout: GridLayout<ID>) -> GridLayout<ID>.Position? {
        guard !selected.isEmpty else { return nil }
        return cursor.flatMap { layout.position(of: $0, preferring: cursorSection) }
    }

    /// Selects every file between two slots (inclusive) in on-screen order.
    private mutating func selectRange(from start: GridLayout<ID>.Position, to end: GridLayout<ID>.Position,
                                      in layout: GridLayout<ID>) {
        let all = layout.positions
        guard let startIndex = all.firstIndex(where: { $0 == start }),
              let endIndex = all.firstIndex(where: { $0 == end }) else { return }
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        selected = Set(all[range].map(layout.id(at:)))
    }
}
