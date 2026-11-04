import Foundation

/// The on-screen arrangement of an icon grid: sections of IDs laid out in `columns` columns. Each
/// section starts a new row, like a sectioned `LazyVGrid`.
nonisolated struct GridLayout<ID: Hashable> {
    let sections: [[ID]]
    let columns: Int

    init(sections: [[ID]], columns: Int) {
        self.sections = sections.filter { !$0.isEmpty }
        self.columns = max(1, columns)
    }

    /// Items in on-screen (reading) order.
    var flat: [ID] { sections.flatMap { $0 } }

    /// Columns SwiftUI fits for `GridItem(.adaptive(minimum:), spacing:)` in `width` with horizontal padding.
    static func columnCount(width: Double, itemMinimum: Double, spacing: Double, padding: Double) -> Int {
        let usable = width - 2 * padding
        return max(1, Int(((usable + spacing) / (itemMinimum + spacing)).rounded(.down)))
    }

    func position(of id: ID) -> (section: Int, index: Int)? {
        for (s, items) in sections.enumerated() {
            if let i = items.firstIndex(of: id) { return (s, i) }
        }
        return nil
    }

    /// The item one row up or down in the same column, crossing sections and clamping to the last
    /// item of a short row. nil at the top or bottom edge.
    func vertical(from id: ID, down: Bool) -> ID? {
        guard let (s, i) = position(of: id) else { return nil }
        let row = i / columns, col = i % columns
        let items = sections[s]
        if down {
            if (row + 1) * columns < items.count {
                return items[min((row + 1) * columns + col, items.count - 1)]
            }
            guard s + 1 < sections.count else { return nil }
            return sections[s + 1][min(col, sections[s + 1].count - 1)]
        } else {
            if row > 0 { return items[(row - 1) * columns + col] }
            guard s > 0 else { return nil }
            let prev = sections[s - 1]
            let lastRow = (prev.count - 1) / columns
            return prev[min(lastRow * columns + col, prev.count - 1)]
        }
    }
}

/// Finder-style icon-view selection: click, ⌘-click, ⇧-click, ⌘A and arrow keys. `anchor` is where a
/// range starts; `cursor` is the lead item that arrows move and the view scrolls to.
nonisolated struct GridSelection<ID: Hashable> {
    enum Direction { case left, right, up, down, home, end }

    private(set) var selected = Set<ID>()
    private(set) var anchor: ID?
    private(set) var cursor: ID?

    init() {}

    init(selected: Set<ID>) {
        self.selected = selected
        if selected.count == 1 { anchor = selected.first; cursor = selected.first }
    }

    mutating func clear() { self = GridSelection() }

    /// Plain click: select just `id`.
    mutating func click(_ id: ID) {
        selected = [id]; anchor = id; cursor = id
    }

    /// ⌘-click: toggle `id`; it becomes the anchor.
    mutating func toggle(_ id: ID) {
        if selected.remove(id) == nil { selected.insert(id) }
        anchor = id; cursor = id
    }

    /// ⇧-click: select anchor...id, replacing the selection. Without an anchor this is a plain click.
    mutating func extend(to id: ID, in layout: GridLayout<ID>) {
        guard let anchor = validAnchor(in: layout) else { click(id); return }
        selectRange(from: anchor, to: id, in: layout)
        cursor = id
    }

    /// ⌘A. The anchor and cursor are kept if still present, otherwise the first and last items.
    mutating func selectAll(in layout: GridLayout<ID>) {
        let flat = layout.flat
        guard !flat.isEmpty else { return }
        selected = Set(flat)
        if validAnchor(in: layout) == nil { anchor = flat.first }
        if cursor.map({ layout.position(of: $0) != nil }) != true { cursor = flat.last }
    }

    /// Arrow/Home/End. `extend` (⇧) grows the range from the anchor; otherwise the selection becomes
    /// the new cursor item. With nothing selected the first item is selected.
    mutating func move(_ direction: Direction, extend: Bool, in layout: GridLayout<ID>) {
        let flat = layout.flat
        guard let first = flat.first, let last = flat.last else { return }
        guard let current = validCursor(in: layout) else {
            click(first)
            return
        }
        let target: ID
        switch direction {
        case .home: target = first
        case .end: target = last
        case .left, .right:
            let i = flat.firstIndex(of: current) ?? 0
            target = flat[direction == .left ? max(i - 1, 0) : min(i + 1, flat.count - 1)]
        case .up, .down:
            target = layout.vertical(from: current, down: direction == .down) ?? current
        }
        if extend {
            let from = validAnchor(in: layout) ?? current
            anchor = from
            selectRange(from: from, to: target, in: layout)
            cursor = target
        } else {
            click(target)
        }
    }

    /// Drops IDs that are no longer present (and a stale anchor/cursor).
    mutating func prune(keeping present: Set<ID>) {
        selected = selected.filter(present.contains)
        if let a = anchor, !present.contains(a) { anchor = nil }
        if let c = cursor, !present.contains(c) { cursor = nil }
    }

    // MARK: Private

    private func validAnchor(in layout: GridLayout<ID>) -> ID? {
        anchor.flatMap { layout.position(of: $0) != nil ? $0 : nil }
    }

    private func validCursor(in layout: GridLayout<ID>) -> ID? {
        guard !selected.isEmpty else { return nil }
        return cursor.flatMap { layout.position(of: $0) != nil ? $0 : nil }
    }

    private mutating func selectRange(from a: ID, to b: ID, in layout: GridLayout<ID>) {
        let flat = layout.flat
        guard let i = flat.firstIndex(of: a), let j = flat.firstIndex(of: b) else { return }
        selected = Set(flat[min(i, j)...max(i, j)])
    }
}
