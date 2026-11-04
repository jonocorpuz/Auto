import Testing
@testable import Auto

struct GridSelectionTests {
    /// Two sections, 3 columns: [0 1 2 / 3 4] and [5 6 7 / 8].
    private let layout = GridLayout(sections: [[0, 1, 2, 3, 4], [5, 6, 7, 8]], columns: 3)

    private func clicked(_ id: Int) -> GridSelection<Int> {
        var s = GridSelection<Int>()
        s.click(id)
        return s
    }

    @Test func columnCountMatchesAdaptiveGrid() {
        // (600 - 24 + 6) / (126 + 6) = 4.4
        #expect(GridLayout<Int>.columnCount(width: 600, itemMinimum: 126, spacing: 6, padding: 12) == 4)
        #expect(GridLayout<Int>.columnCount(width: 10, itemMinimum: 126, spacing: 6, padding: 12) == 1)
    }

    @Test func clickReplaces() {
        var s = clicked(1)
        s.click(4)
        #expect(s.selected == [4] && s.anchor == 4 && s.cursor == 4)
    }

    @Test func commandClickToggles() {
        var s = clicked(1)
        s.toggle(2)
        #expect(s.selected == [1, 2] && s.anchor == 2)
        s.toggle(1)
        #expect(s.selected == [2])
    }

    @Test func shiftClickSelectsRangeFromAnchor() {
        var s = clicked(1)
        s.extend(to: 6, in: layout)
        #expect(s.selected == [1, 2, 3, 4, 5, 6] && s.anchor == 1 && s.cursor == 6)
        s.extend(to: 0, in: layout)
        #expect(s.selected == [0, 1])
    }

    @Test func shiftClickWithoutAnchorIsClick() {
        var s = GridSelection<Int>()
        s.extend(to: 3, in: layout)
        #expect(s.selected == [3])
    }

    @Test func selectAll() {
        var s = GridSelection<Int>()
        s.selectAll(in: layout)
        #expect(s.selected == Set(0...8))
    }

    @Test func arrowOnEmptySelectsFirst() {
        for dir in [GridSelection<Int>.Direction.left, .right, .up, .down] {
            var s = GridSelection<Int>()
            s.move(dir, extend: false, in: layout)
            #expect(s.selected == [0])
        }
    }

    @Test func leftRightWalkAcrossSectionsAndClamp() {
        var s = clicked(4)
        s.move(.right, extend: false, in: layout)
        #expect(s.selected == [5])
        s.move(.left, extend: false, in: layout)
        #expect(s.selected == [4])
        s.click(0)
        s.move(.left, extend: false, in: layout)
        #expect(s.selected == [0])
        s.click(8)
        s.move(.right, extend: false, in: layout)
        #expect(s.selected == [8])
    }

    @Test func upDownKeepColumn() {
        var s = clicked(1)
        s.move(.down, extend: false, in: layout)
        #expect(s.selected == [4])
        s.move(.up, extend: false, in: layout)
        #expect(s.selected == [1])
    }

    @Test func downClampsToShortRow() {
        var s = clicked(2)
        s.move(.down, extend: false, in: layout)
        #expect(s.selected == [4])
    }

    @Test func downCrossesSectionBoundaryToSameColumn() {
        var s = clicked(4) // column 1, last row of section 0
        s.move(.down, extend: false, in: layout)
        #expect(s.selected == [6]) // section 1, first row, column 1
        s.click(3)
        s.move(.down, extend: false, in: layout)
        #expect(s.selected == [5])
    }

    @Test func downIntoShortNextSectionClamps() {
        let l = GridLayout(sections: [[0, 1, 2], [3]], columns: 3)
        var s = clicked(2)
        s.move(.down, extend: false, in: l)
        #expect(s.selected == [3])
    }

    @Test func upCrossesSectionBoundaryClampingToLastItem() {
        var s = clicked(7) // section 1, row 0, column 2
        s.move(.up, extend: false, in: layout)
        #expect(s.selected == [4]) // section 0 last row is [3 4]; column 2 clamps to 4
        s.click(5)
        s.move(.up, extend: false, in: layout)
        #expect(s.selected == [3])
    }

    @Test func upDownStayAtEdges() {
        var s = clicked(1)
        s.move(.up, extend: false, in: layout)
        #expect(s.selected == [1])
        s.click(8)
        s.move(.down, extend: false, in: layout)
        #expect(s.selected == [8])
    }

    @Test func shiftArrowExtendsFromAnchor() {
        var s = clicked(1)
        s.move(.right, extend: true, in: layout)
        s.move(.right, extend: true, in: layout)
        #expect(s.selected == [1, 2, 3] && s.anchor == 1 && s.cursor == 3)
        s.move(.left, extend: true, in: layout)
        s.move(.left, extend: true, in: layout)
        s.move(.left, extend: true, in: layout)
        #expect(s.selected == [0, 1] && s.cursor == 0)
        s.move(.down, extend: true, in: layout)
        #expect(s.selected == [1, 2, 3] && s.cursor == 3)
    }

    @Test func shiftArrowOnEmptySelectsFirst() {
        var s = GridSelection<Int>()
        s.move(.right, extend: true, in: layout)
        #expect(s.selected == [0])
    }

    @Test func homeAndEnd() {
        var s = clicked(4)
        s.move(.end, extend: false, in: layout)
        #expect(s.selected == [8])
        s.move(.home, extend: true, in: layout)
        #expect(s.selected == Set(0...8))
    }

    @Test func pruneDropsMissing() {
        var s = clicked(1)
        s.toggle(2)
        s.prune(keeping: [1, 5])
        #expect(s.selected == [1] && s.anchor == nil && s.cursor == nil)
    }

    @Test func emptyLayoutIsNoOp() {
        var s = GridSelection<Int>()
        let empty = GridLayout<Int>(sections: [], columns: 3)
        s.move(.down, extend: false, in: empty)
        s.selectAll(in: empty)
        #expect(s.selected.isEmpty)
    }
}
