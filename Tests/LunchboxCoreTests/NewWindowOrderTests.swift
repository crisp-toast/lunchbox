import CoreGraphics
import Testing
@testable import LunchboxCore

/// Where new windows go on a laptop or desktop display: side by side, then the right half splits,
/// then the left, so nothing ever crosses the screen.
@Suite struct NewWindowOrder {
    let columns = Layout.maxColumns(forWidth: 2560)

    func open(_ ids: [WindowID], focusing focus: (Layout) -> WindowID? = { $0.windows.last }) -> Layout {
        var l = Layout()
        for id in ids { l.insert(id, near: focus(l), maxColumns: columns) }
        return l
    }

    @Test func twoSitSideBySide() {
        #expect(open([1, 2]).columns.map(\.windows) == [[1], [2]])
        var laptop = Layout()
        for id: WindowID in [1, 2] { laptop.insert(id, near: laptop.windows.last, maxColumns: Layout.maxColumns(forWidth: 1470)) }
        #expect(laptop.columns.map(\.windows) == [[1], [2]])
    }

    @Test func theThirdGoesBeneathTheRightOne() {
        #expect(open([1, 2, 3]).columns.map(\.windows) == [[1], [2, 3]])
        // Even with the left window focused: the first keeps its half.
        #expect(open([1, 2, 3], focusing: { $0.windows.first }).columns.map(\.windows) == [[1], [2, 3]])
    }

    @Test func theFourthGoesBeneathTheLeftOneAndNothingCrossesTheScreen() {
        let three = open([1, 2, 3]), four = open([1, 2, 3, 4])
        #expect(four.columns.map(\.windows) == [[1, 4], [2, 3]])
        let before = three.frames(in: screen, gap: gap), after = four.frames(in: screen, gap: gap)
        for id: WindowID in [1, 2, 3] {
            // Each stays on its side of the screen.
            #expect((before[id]!.midX < screen.midX) == (after[id]!.midX < screen.midX))
        }
    }

    @Test func ultrawideDisplaysStillGetColumns() {
        var l = Layout()
        for id: WindowID in [1, 2, 3] { l.insert(id, near: l.windows.last, maxColumns: Layout.maxColumns(forWidth: 3440)) }
        #expect(l.columns.map(\.windows) == [[1], [2], [3]])
    }
}
