import CoreGraphics
import Testing
@testable import TesselCore

// The LG 5K's usable area (below the menu bar), in top-left-origin points.
let screen = CGRect(x: 0, y: 25, width: 2560, height: 1415)
let gap: CGFloat = 8

func layout(_ columns: [[WindowID]]) -> Layout {
    Layout(columns: columns.map { Column(windows: $0) })
}

@Suite struct SingleWindow {
    @Test func centeredAtSixteenByTenNotFullscreen() throws {
        let frame = try #require(layout([[1]]).frames(in: screen, gap: gap)[1])
        #expect(frame.width < screen.width * 0.7)
        #expect(abs(frame.width / frame.height - 1.6) < 0.01)
        #expect(abs(frame.midX - screen.midX) <= 1)
        #expect(abs(frame.midY - screen.midY) <= 1)
    }

    @Test func growsAroundCenterAndFillsAtMax() throws {
        var l = layout([[1]])
        let before = try #require(l.frames(in: screen, gap: gap)[1])
        do { let r = l.resize(1, by: 0.1); #expect(r) }
        let after = try #require(l.frames(in: screen, gap: gap)[1])
        #expect(after.width > before.width)
        #expect(abs(after.midX - before.midX) <= 1)
        for _ in 0..<10 { l.resize(1, by: 0.1) }
        let full = try #require(l.frames(in: screen, gap: gap)[1])
        #expect(full == screen.insetBy(dx: gap, dy: gap))
        do { let r = l.resize(1, by: 0.1); #expect(!r) } // already at max
    }

    @Test func shrinkStopsAtMinimum() {
        var l = layout([[1]])
        for _ in 0..<10 { l.resize(1, by: -0.1) }
        #expect(abs(l.singleScale - Layout.singleScaleRange.lowerBound) < 0.0001)
    }
}

@Suite struct Tiling {
    @Test func twoWindowsSplitTheScreen() throws {
        let frames = layout([[1], [2]]).frames(in: screen, gap: gap)
        let a = try #require(frames[1]), b = try #require(frames[2])
        #expect(a.minX == gap)
        #expect(b.maxX == screen.maxX - gap)
        #expect(b.minX - a.maxX == gap)
        #expect(a.height == screen.height - 2 * gap)
        #expect(abs(a.width - b.width) <= 1)
    }

    @Test func stackedColumnSplitsHeight() throws {
        let frames = layout([[1], [2, 3]]).frames(in: screen, gap: gap)
        let top = try #require(frames[2]), bottom = try #require(frames[3])
        #expect(top.minX == bottom.minX)
        #expect(bottom.minY - top.maxY == gap)
        #expect(bottom.maxY == screen.maxY - gap)
    }

    @Test func framesNeverOverlap() {
        let frames = Array(layout([[1, 2], [3], [4, 5, 6]]).frames(in: screen, gap: gap).values)
        for i in frames.indices {
            for j in frames.indices where j > i {
                #expect(!frames[i].intersects(frames[j]))
            }
        }
    }
}

@Suite struct Inserting {
    @Test func newWindowsGetColumnsUntilFull() {
        var l = Layout()
        l.insert(1, near: nil, maxColumns: 3)
        l.insert(2, near: 1, maxColumns: 3)
        l.insert(3, near: 2, maxColumns: 3)
        #expect(l.columns.map(\.windows) == [[1], [2], [3]])
        l.insert(4, near: 3, maxColumns: 3)
        #expect(l.columns.map(\.windows) == [[1], [2], [3, 4]])
        l.insert(5, near: 4, maxColumns: 3)
        // Column 3 now has two windows, so the fewest-windows rule picks the last single column.
        #expect(l.columns.map(\.windows) == [[1], [2, 5], [3, 4]])
    }

    @Test func newColumnGoesRightOfFocused() {
        var l = layout([[1], [2]])
        l.insert(3, near: 1, maxColumns: 3)
        #expect(l.columns.map(\.windows) == [[1], [3], [2]])
    }

    @Test func removingLastInColumnDropsColumn() {
        var l = layout([[1], [2, 3]])
        l.remove(1)
        #expect(l.columns.map(\.windows) == [[2, 3]])
        l.remove(2)
        l.remove(3)
        #expect(l.isEmpty)
    }

    @Test func enteringFromNeighborDisplay() {
        var l = layout([[1], [2]])
        l.insert(9, entering: .right)
        #expect(l.columns.first?.windows == [9])
        l.insert(8, entering: .left)
        #expect(l.columns.last?.windows == [8])
    }
}

@Suite struct Moving {
    @Test func windowTravelsLeftThroughStackedPositions() {
        var l = layout([[1], [2], [3]])
        do { let r = l.move(3, .left); #expect(r == .moved) }
        #expect(l.columns.map(\.windows) == [[1], [2, 3]])
        do { let r = l.move(3, .left); #expect(r == .moved) }
        #expect(l.columns.map(\.windows) == [[1], [3], [2]])
        do { let r = l.move(3, .left); #expect(r == .moved) }
        #expect(l.columns.map(\.windows) == [[1, 3], [2]])
        do { let r = l.move(3, .left); #expect(r == .moved) }
        #expect(l.columns.map(\.windows) == [[3], [1], [2]])
        do { let r = l.move(3, .left); #expect(r == .edge) }
    }

    @Test func rightIsTheMirrorOfLeft() {
        var l = layout([[1], [2]])
        do { let r = l.move(1, .right); #expect(r == .moved) }
        #expect(l.columns.map(\.windows) == [[2, 1]])
        do { let r = l.move(1, .right); #expect(r == .moved) }
        #expect(l.columns.map(\.windows) == [[2], [1]])
        do { let r = l.move(1, .right); #expect(r == .edge) }
    }

    @Test func upAndDownSwapInTheStack() {
        var l = layout([[1, 2, 3]])
        do { let r = l.move(3, .up); #expect(r == .moved) }
        #expect(l.columns[0].windows == [1, 3, 2])
        do { let r = l.move(1, .up); #expect(r == .edge) }
        do { let r = l.move(2, .down); #expect(r == .edge) }
    }

    @Test func loneWindowHitsTheEdge() {
        var l = layout([[1]])
        for d in Direction.allCases { #expect((l.move(1, d)) == .edge) }
        do { let r = l.move(42, .left); #expect(r == .notFound) }
    }

    @Test func swapAndReplace() {
        var l = layout([[1], [2, 3]])
        do { let r = l.swap(1, 3); #expect(r) }
        #expect(l.columns.map(\.windows) == [[3], [2, 1]])
        do { let r = l.replace(2, with: 7); #expect(r) }
        #expect(l.columns.map(\.windows) == [[3], [7, 1]])
    }
}

@Suite struct Sizing {
    @Test func growWidensColumnAndHeightInStack() throws {
        var l = layout([[1], [2, 3]])
        let before = l.frames(in: screen, gap: gap)
        do { let r = l.resize(2, by: 0.1); #expect(r) }
        let after = l.frames(in: screen, gap: gap)
        #expect(try #require(after[2]).width > before[2]!.width)
        #expect(try #require(after[2]).height > before[2]!.height)
        #expect(try #require(after[1]).width < before[1]!.width)
    }

    @Test func sharesStayWithinBounds() {
        var l = layout([[1], [2]])
        for _ in 0..<20 { l.resize(1, by: 0.1) }
        let widths = l.columns.map(\.weight)
        let share = widths[1] / widths.reduce(0, +)
        #expect(share >= Layout.minFraction - 0.0001)
    }

    @Test func adoptTakesTheDraggedWidth() throws {
        var l = layout([[1], [2]])
        do { let r = l.adopt(1, size: CGSize(width: 1500, height: 1399), in: screen, gap: gap); #expect(r) }
        let a = try #require(l.frames(in: screen, gap: gap)[1])
        #expect(abs(a.width - 1500) <= 2)
    }

    @Test func balanceResets() {
        var l = layout([[1], [2, 3]])
        l.resize(1, by: 0.2)
        l.resize(3, by: 0.2)
        l.toggleSpotlight(2)
        l.balance()
        #expect(l.columns.map(\.weight) == [1, 1])
        #expect(l.columns[1].weights == [1, 1])
        #expect(l.spotlight == nil)
        #expect(l.shelved.isEmpty)
    }

    @Test func maxColumnsByWidth() {
        #expect(Layout.maxColumns(forWidth: 2560) == 3)
        #expect(Layout.maxColumns(forWidth: 1920) == 2)
        #expect(Layout.maxColumns(forWidth: 700) == 1)
    }
}

@Suite struct DirectionalFocus {
    let frames = layout([[1], [2, 3], [4]]).frames(in: screen, gap: gap)

    @Test func neighbors() throws {
        let one = try #require(frames[1])
        var others = frames
        others[1] = nil
        #expect(nearest(from: one, direction: .right, in: others) == 2) // top of the stack wins the tie
        #expect(nearest(from: one, direction: .left, in: others) == nil)

        let three = try #require(frames[3])
        others = frames
        others[3] = nil
        #expect(nearest(from: three, direction: .up, in: others) == 2)
        #expect(nearest(from: three, direction: .right, in: others) == 4)
        #expect(nearest(from: three, direction: .left, in: others) == 1)
        #expect(nearest(from: three, direction: .down, in: others) == nil)
    }

    @Test func crossesToAnotherDisplay() {
        // A display to the left, top-aligned with the main one.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let candidates: [WindowID: CGRect] = [10: left.insetBy(dx: 8, dy: 8)]
        let source = frames[1]!
        #expect(nearest(from: source, direction: .left, in: candidates) == 10)
        #expect(nearest(from: source, direction: .right, in: candidates) == nil)
    }

    @Test func floatingSourceUsesCenters() {
        // A source overlapping the tiles still finds the tile whose center is beyond its own.
        let source = CGRect(x: 900, y: 300, width: 400, height: 300)
        #expect(nearest(from: source, direction: .right, in: frames) != nil)
    }
}

@Suite struct Spotlight {
    @Test func centersOneAndShelvesTheRestOnTheLeft() throws {
        var l = layout([[1], [2, 3]])
        do { let r = l.toggleSpotlight(2); #expect(r) }
        let frames = l.frames(in: screen, gap: gap)
        let center = try #require(frames[2])
        #expect(abs(center.midX - screen.midX) <= 1)
        #expect(abs(center.width / center.height - 1.6) < 0.01)
        for id: WindowID in [1, 3] {
            let small = try #require(frames[id])
            #expect(small.minX == gap)
            #expect(small.maxX <= center.minX)
            #expect(small.width < center.width / 2)
        }
        #expect(!frames[1]!.intersects(frames[3]!))
    }

    @Test func shelvedIsEverythingButTheSpotlight() {
        var l = layout([[1], [2, 3]])
        #expect(l.shelved.isEmpty)
        l.toggleSpotlight(3)
        #expect(l.shelved == [1, 2])
    }

    @Test func toggleEndsItAndLoneWindowsIgnoreIt() {
        var l = layout([[1], [2]])
        do { let r = l.toggleSpotlight(1); #expect(r) }
        do { let r = l.toggleSpotlight(1); #expect(r) }
        #expect(l.spotlight == nil)
        var lone = layout([[1]])
        do { let r = lone.toggleSpotlight(1); #expect(!r) }
        #expect(lone.spotlight == nil)
    }

    @Test func anyLayoutChangeEndsIt() {
        var l = layout([[1], [2], [3]])
        l.toggleSpotlight(1)
        l.insert(4, near: 1, maxColumns: 4)
        #expect(l.spotlight == nil)
        l.toggleSpotlight(1)
        l.remove(3)
        #expect(l.spotlight == nil)
        l.toggleSpotlight(1)
        _ = l.move(2, .left)
        #expect(l.spotlight == nil)
    }

    @Test func growResizesTheCenteredWindow() throws {
        var l = layout([[1], [2]])
        l.toggleSpotlight(1)
        let before = try #require(l.frames(in: screen, gap: gap)[1])
        do { let r = l.resize(1, by: 0.1); #expect(r) }
        let after = try #require(l.frames(in: screen, gap: gap)[1])
        #expect(after.width > before.width)
        #expect(l.spotlight == 1)
    }
}
