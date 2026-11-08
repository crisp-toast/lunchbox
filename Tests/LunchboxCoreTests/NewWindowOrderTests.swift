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

    /// The LG's usable area less the gaps, as the Tiler gives it.
    let room = (area: CGSize(width: screen.width - 2 * gap, height: screen.height - 2 * gap), gap: gap)

    @Test func theThirdNeverOpensBeneathANarrowColumn() {
        // Sorted: a browser wide, chat narrow. A new window goes beneath the browser, at a tile's
        // usual shape, not a sliver beneath the chat.
        var l = Layout(columns: [Column(windows: [1], weight: 0.7), Column(windows: [2], weight: 0.3)])
        l.insert(3, near: 2, maxColumns: columns, room: room)
        #expect(l.columns.map(\.windows) == [[1, 3], [2]])
        // Evenly split, it's beneath the right one as always.
        var even = layout([[1], [2]])
        even.insert(3, near: 1, maxColumns: columns, room: room)
        #expect(even.columns.map(\.windows) == [[1], [2, 3]])
    }

    @Test func notBeneathAWindowThatKeepsItsOwnNarrowWidth() {
        // A phone in Simulator keeps its column narrow whatever its share.
        let phone: [WindowID: SizeLimits] = [2: SizeLimits(maxWidth: 440)]
        var l = layout([[1], [2]])
        l.insert(3, near: 2, maxColumns: columns, limits: phone, room: room)
        #expect(l.position(of: 3)?.column == l.position(of: 1)?.column)
    }

    @Test func ultrawideDisplaysStillGetColumns() {
        var l = Layout()
        for id: WindowID in [1, 2, 3] { l.insert(id, near: l.windows.last, maxColumns: Layout.maxColumns(forWidth: 3440)) }
        #expect(l.columns.map(\.windows) == [[1], [2], [3]])
    }
}
