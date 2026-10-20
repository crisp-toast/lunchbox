import CoreGraphics
import Foundation
import Testing
@testable import LunchboxCore

/// Any arrangement resizes around the middle from its outer edges and corners; edges between
/// windows move the split.
@Suite struct ArrangementSizes {
    let usable = CGRect(x: 8, y: 33, width: 2544, height: 1399)
    typealias Handle = Layout.Handle

    func frames(_ l: Layout) -> [WindowID: CGRect] { l.frames(in: screen, gap: gap) }
    func drag(_ l: Layout, _ id: WindowID, _ h: Layout.Handle.Side?, _ v: Layout.Handle.Side?, to p: CGPoint,
              limits: [WindowID: SizeLimits] = [:]) throws -> Layout {
        try #require(l.dragged(id, handle: Handle(horizontal: h, vertical: v), to: p, in: screen, gap: gap, limits: limits))
    }
    func centered(_ f: [WindowID: CGRect]) -> Bool {
        let all = f.values.reduce(CGRect.null) { $0.union($1) }
        return abs(all.midX - usable.midX) <= 1 && abs(all.midY - usable.midY) <= 1
    }

    // MARK: Two windows

    @Test func aFarSideResizesThePairAroundTheMiddle() throws {
        let next = try drag(layout([[1], [2]]), 1, .low, nil, to: CGPoint(x: usable.minX + 200, y: 500))
        let f = frames(next)
        let left = try #require(f[1]), right = try #require(f[2])
        #expect(abs(left.minX - (usable.minX + 200)) <= 1 && abs(right.maxX - (usable.maxX - 200)) <= 1)
        #expect(left.size == right.size && right.minX - left.maxX == gap)
        #expect(left.height == usable.height)
    }

    @Test func aTopResizesThePairUpAndDownAroundTheMiddle() throws {
        let next = try drag(layout([[1], [2]]), 2, nil, .low, to: CGPoint(x: 1800, y: usable.minY + 150))
        for (_, w) in frames(next) {
            #expect(abs(w.minY - (usable.minY + 150)) <= 1 && abs(w.maxY - (usable.maxY - 150)) <= 1)
        }
    }

    @Test func aFarCornerFollowsThePointerAndTheOppositeCornersFollow() throws {
        let p = CGPoint(x: usable.minX + 200, y: usable.minY + 100)
        let f = frames(try drag(layout([[1], [2]]), 1, .low, .low, to: p))
        let left = try #require(f[1]), right = try #require(f[2])
        #expect(abs(left.minX - p.x) <= 1 && abs(left.minY - p.y) <= 1)
        #expect(abs(right.maxX - (usable.maxX - 200)) <= 1 && abs(right.maxY - (usable.maxY - 100)) <= 1)
        #expect(left.size == right.size)
    }

    @Test func aCornerByTheOtherWindowMovesTheSplitAndTheHeight() throws {
        let p = CGPoint(x: 1000, y: usable.minY + 50)
        let f = frames(try drag(layout([[1], [2]]), 1, .high, .low, to: p))
        let left = try #require(f[1]), right = try #require(f[2])
        #expect(abs(left.maxX - p.x) <= 2)
        #expect(abs(left.minX - usable.minX) <= 1 && abs(right.maxX - usable.maxX) <= 1)
        #expect(abs(left.minY - p.y) <= 1 && centered(f))
    }

    @Test func aFarSideKeepsTheSplitYouMade() throws {
        var l = layout([[1], [2]])
        l.columns[0].weight = 2 // the left window has two thirds
        let f = frames(try drag(l, 2, .high, nil, to: CGPoint(x: usable.maxX - 300, y: 500)))
        let left = try #require(f[1]), right = try #require(f[2])
        #expect(abs(left.width - 2 * right.width) <= 2)
        #expect(centered(f))
    }

    @Test func stackedPairsWorkTheSameWayUpAndDown() throws {
        let f = frames(try drag(layout([[1, 2]]), 1, nil, .low, to: CGPoint(x: 900, y: usable.minY + 100)))
        let top = try #require(f[1]), bottom = try #require(f[2])
        #expect(abs(top.minY - (usable.minY + 100)) <= 1 && abs(bottom.maxY - (usable.maxY - 100)) <= 1)
        #expect(bottom.minY - top.maxY == gap && top.width == bottom.width && abs(top.height - bottom.height) <= 1)
    }

    // MARK: More windows

    @Test func threeColumnsKeepTheirSharesAsTheyResize() throws {
        let f = frames(try drag(layout([[1], [2], [3]]), 3, .high, nil, to: CGPoint(x: usable.maxX - 400, y: 600)))
        let widths = [1, 2, 3].compactMap { f[WindowID($0)]?.width }
        #expect(widths.count == 3 && widths.max()! - widths.min()! <= 2) // still even thirds
        #expect(abs(try #require(f[1]).minX - (usable.minX + 400)) <= 1)
        #expect(centered(f))
    }

    @Test func aGridsFarCornerResizesItBothWaysAroundTheMiddle() throws {
        let grid = layout([[1, 2], [3, 4]])
        let p = CGPoint(x: usable.minX + 300, y: usable.minY + 120)
        let f = frames(try drag(grid, 1, .low, .low, to: p))
        let topLeft = try #require(f[1]), bottomRight = try #require(f[4])
        #expect(abs(topLeft.minX - p.x) <= 1 && abs(topLeft.minY - p.y) <= 1)
        #expect(abs(bottomRight.maxX - (usable.maxX - 300)) <= 1 && abs(bottomRight.maxY - (usable.maxY - 120)) <= 1)
        #expect(centered(f))
    }

    @Test func aGridsMiddleCornerMovesBothSplits() throws {
        let grid = layout([[1, 2], [3, 4]])
        let p = CGPoint(x: 900, y: 500)
        let f = frames(try drag(grid, 1, .high, .high, to: p)) // the corner where all four meet
        let topLeft = try #require(f[1])
        #expect(abs(topLeft.maxX - p.x) <= 2 && abs(topLeft.maxY - p.y) <= 2)
        #expect(abs(topLeft.minX - usable.minX) <= 1 && abs(topLeft.minY - usable.minY) <= 1) // the grid keeps its size
    }

    @Test func aStacksOuterBottomResizesEveryColumnUpAndDown() throws {
        let l = layout([[1], [2, 3]])
        let f = frames(try drag(l, 3, nil, .high, to: CGPoint(x: 2000, y: usable.maxY - 200)))
        for (_, w) in f { #expect(w.minY >= usable.minY + 199 && w.maxY <= usable.maxY - 199) }
        #expect(abs(try #require(f[1]).height - (usable.height - 400)) <= 1)
        #expect(centered(f))
    }

    @Test func outerEdgesAreTheOnesOnTheOutside() {
        let l = layout([[1], [2, 3], [4]])
        #expect(l.isOuter(1, horizontal: .low) && !l.isOuter(1, horizontal: .high))
        #expect(!l.isOuter(2, horizontal: .low) && !l.isOuter(2, horizontal: .high))
        #expect(l.isOuter(2, vertical: .low) && !l.isOuter(2, vertical: .high))
        #expect(l.isOuter(3, vertical: .high) && l.isOuter(4, horizontal: .high))
    }

    // MARK: Limits, resets, saving

    @Test func neverSmallerThanAnyWindowsMinimum() throws {
        let limits: [WindowID: SizeLimits] = [1: SizeLimits(minWidth: 1000, minHeight: 900)]
        let next = try drag(layout([[1], [2]]), 1, .low, .low, to: CGPoint(x: usable.midX - 50, y: usable.midY - 50), limits: limits)
        let f = next.frames(in: screen, gap: gap, limits: limits) // as LunchboxWM lays it out
        #expect(try #require(f[1]).width >= 999 && (try #require(f[1])).height >= 899)
    }

    @Test func theSizeIsForThoseWindowsOnly() throws {
        var l = try drag(layout([[1], [2]]), 1, .low, .low, to: CGPoint(x: usable.minX + 300, y: usable.minY + 200))
        #expect(l.area != nil)
        l.insert(3, near: 2, maxColumns: 3)
        let f = frames(l)
        #expect(f.values.reduce(CGRect.null) { $0.union($1) }.width == usable.width) // a new window: the screen again
    }

    @Test func dragsInsideTheScreenEdgesWithoutShrinkingLeaveItFull() throws {
        let l = try drag(layout([[1], [2]]), 1, .high, nil, to: CGPoint(x: 1500, y: 600)) // only the split
        #expect(l.area == nil)
    }

    @Test func tidyAndSavingKnowAboutIt() throws {
        var l = try drag(layout([[1], [2], [3]]), 1, .low, nil, to: CGPoint(x: usable.minX + 300, y: 500))
        let saved = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(l))
        #expect(saved.area == l.area && saved.area != nil)
        l.balance()
        #expect(l.area == nil)
    }
}
