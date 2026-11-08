import CoreGraphics
import Foundation
import Testing
@testable import LunchboxCore

@Suite struct FourWindows {
    @Test func theFourthMakesATwoByTwoGrid() {
        var l = layout([[1], [2], [3]])
        l.columns[0].weight = 1.4
        l.insert(4, near: 3, maxColumns: 3)
        #expect(l.columns.map(\.windows) == [[1, 2], [3, 4]])
        #expect(l.columns.allSatisfy { $0.weight == 1 && $0.weights == [1, 1] })
    }

    @Test func windowsMoveAsLittleAsTheyCan() {
        var stackLeft = layout([[1, 2], [3]])
        stackLeft.insert(4, near: 1, maxColumns: 3)
        #expect(stackLeft.columns.map(\.windows) == [[1, 2], [3, 4]])
        var stackRight = layout([[1], [2, 3]])
        stackRight.insert(4, near: 3, maxColumns: 3)
        #expect(stackRight.columns.map(\.windows) == [[1, 4], [2, 3]])
        // Even on a display narrow enough for one column.
        var one = layout([[1, 2, 3]])
        one.insert(4, near: 3, maxColumns: 1)
        #expect(one.columns.map(\.windows) == [[1, 2], [3, 4]])
    }

    @Test func notWhenAWindowCantShareAColumn() {
        // A window that needs 950 of 1000 points of height can't sit over another one.
        let room = (area: CGSize(width: 2560, height: 1000), gap: CGFloat(8))
        var tall = layout([[1], [2], [3]])
        tall.insert(4, near: 3, maxColumns: 3, limits: [4: SizeLimits(minHeight: 950)], room: room)
        #expect(tall.columns.allSatisfy { col in !(col.windows.contains(4) && col.windows.count > 1) })
        var fine = layout([[1], [2], [3]])
        fine.insert(4, near: 3, maxColumns: 3, limits: [4: SizeLimits(minHeight: 300)], room: room)
        #expect(fine.columns.map(\.windows) == [[1, 2], [3, 4]])
    }

    @Test func aPlaceholderThatGivesUpPutsEverythingBack() {
        let start = Layout(columns: [Column(windows: [1], weight: 1.5), Column(windows: [2]), Column(windows: [3], weight: 0.5)])
        var l = start
        l.insert(p1, near: 3, maxColumns: 3)
        #expect(l.columns.map(\.windows) == [[1, 2], [3, p1]])
        l.remove(p1)
        #expect(l == start)
        // Filled, the grid stays.
        var filled = start
        filled.insert(p1, near: 3, maxColumns: 3)
        filled.fill(p1, with: 4)
        filled.remove(4)
        #expect(filled.columns.map(\.windows) == [[1, 2], [3]])
    }
}
