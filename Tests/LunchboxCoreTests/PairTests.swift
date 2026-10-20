import CoreGraphics
import Foundation
import Testing
@testable import LunchboxCore

/// Two windows resize as a centered pair from their outer edges, staying touching in the middle.
@Suite struct CenteredPairs {
    let usable = CGRect(x: 8, y: 33, width: 2544, height: 1399)

    func frames(_ l: Layout) -> [WindowID: CGRect] { l.frames(in: screen, gap: gap) }

    @Test func draggingAFarSideInMirrorsTheOtherSide() throws {
        let l = layout([[1], [2]])
        let before = try #require(frames(l)[1])
        var dragged = before
        dragged.origin.x += 200
        dragged.size.width -= 200 // the left edge moved in; the middle stayed
        let r = try #require(l.pairResize(1, dragged: dragged, target: before, in: screen, gap: gap))
        #expect(r.other == 2)
        #expect(r.area.minX == usable.minX + 200 && r.area.maxX == usable.maxX - 200) // both sides in
        #expect(r.otherFrame.minX == dragged.maxX + gap && r.otherFrame.maxX == r.area.maxX) // touching, mirrored
    }

    @Test func lettingGoKeepsThePairCenteredAndTouching() throws {
        var l = layout([[1], [2]])
        let before = try #require(frames(l)[1])
        var dragged = before
        dragged.origin.x += 200
        dragged.size.width -= 200
        let adopted1 = l.adoptPair(1, dragged: dragged, target: before, in: screen, gap: gap)
        #expect(adopted1)
        let f = frames(l)
        let left = try #require(f[1]), right = try #require(f[2])
        #expect(abs(left.minX - (usable.minX + 200)) <= 1 && abs(right.maxX - (usable.maxX - 200)) <= 1)
        #expect(right.minX - left.maxX == gap)
        #expect(abs((left.minX + right.maxX) / 2 - usable.midX) <= 1)
        #expect(left.height == usable.height && right.height == usable.height)
    }

    @Test func aTopEdgeMakesThePairShorterAroundTheMiddle() throws {
        var l = layout([[1], [2]])
        let before = try #require(frames(l)[2])
        // With ⌥ (the event tap adds it), the top and bottom move together.
        let dragged = before.insetBy(dx: 0, dy: 150)
        let adopted2 = l.adoptPair(2, dragged: dragged, target: before, in: screen, gap: gap)
        #expect(adopted2)
        let f = frames(l)
        for id: WindowID in [1, 2] {
            let w = try #require(f[id])
            #expect(abs(w.height - (usable.height - 300)) <= 1)
            #expect(abs(w.midY - usable.midY) <= 1)
        }
    }

    @Test func theOtherWindowIsTheDraggedOnesMirrorImage() throws {
        // Even after the split was moved, the pair resizes as two identical windows.
        var l = layout([[1], [2]])
        l.columns[0].weight = 2
        let before = try #require(frames(l)[2])
        var dragged = before
        dragged.size.width -= 150 // the right window's far edge moved in
        let r = try #require(l.pairResize(2, dragged: dragged, target: before, in: screen, gap: gap))
        #expect(r.otherFrame.size == dragged.size)
        #expect(abs((r.otherFrame.minX + dragged.maxX) / 2 - usable.midX) <= 1) // mirrored across the middle
        let adopted101 = l.adoptPair(2, dragged: dragged, target: before, in: screen, gap: gap)
        #expect(adopted101)
        let f = frames(l)
        #expect(try #require(f[1]).size == (try #require(f[2])).size) // identical once you let go
    }

    @Test func aDraggedTopKeepsThePairCenteredUpAndDown() throws {
        // Without ⌥ only the top moves: the pair is still the dragged window's height, centered.
        let l = layout([[1], [2]])
        let before = try #require(frames(l)[1])
        var dragged = before
        dragged.origin.y += 200
        dragged.size.height -= 200
        let r = try #require(l.pairResize(1, dragged: dragged, target: before, in: screen, gap: gap))
        #expect(abs(r.area.midY - usable.midY) <= 1)
        #expect(r.area.height == dragged.height)
    }

    @Test func neverSmallerThanTheirMinimums() throws {
        let limits: [WindowID: SizeLimits] = [1: SizeLimits(minWidth: 900), 2: SizeLimits(minHeight: 700)]
        let l = layout([[1], [2]])
        let before = try #require(frames(l)[1])
        var dragged = before
        dragged.origin.x += 1000
        dragged.size.width -= 1000
        let r = try #require(l.pairResize(1, dragged: dragged, target: before, in: screen, gap: gap, limits: limits))
        #expect(r.area.width >= 2 * 900 + gap)
    }

    @Test func theEdgeBetweenThemIsTheSplit() throws {
        let l = layout([[1], [2]])
        let before = try #require(frames(l)[1])
        var dragged = before
        dragged.size.width += 300 // only the middle moved
        #expect(l.pairResize(1, dragged: dragged, target: before, in: screen, gap: gap) == nil)
    }

    @Test func aSizedPairSplitsItsOwnWidth() throws {
        var l = layout([[1], [2]])
        l.pair = Layout.Pair(width: 0.6, height: 1, windows: [1, 2])
        let area = try #require(frames(l)[1]).union(try #require(frames(l)[2]))
        #expect(abs(area.width - (usable.width * 0.6).rounded()) <= 1)
        // Dragging the middle to give the left window two thirds of the pair.
        let left = try #require(frames(l)[1])
        l.adopt(1, size: CGSize(width: (area.width - gap) * 2 / 3, height: left.height), in: screen, gap: gap)
        let newLeft = try #require(frames(l)[1]), newRight = try #require(frames(l)[2])
        #expect(abs(newLeft.width - 2 * newRight.width) <= 2)
        #expect(abs(newLeft.union(newRight).width - area.width) <= 1) // the pair keeps its size
    }

    @Test func stackedPairsWorkTheSameWayUpAndDown() throws {
        var l = layout([[1, 2]])
        let before = try #require(frames(l)[1])
        var dragged = before
        dragged.origin.y += 100
        dragged.size.height -= 100 // the top edge moved down; the middle stayed
        let adopted3 = l.adoptPair(1, dragged: dragged, target: before, in: screen, gap: gap)
        #expect(adopted3)
        let top = try #require(frames(l)[1]), bottom = try #require(frames(l)[2])
        #expect(abs(top.minY - (usable.minY + 100)) <= 1 && abs(bottom.maxY - (usable.maxY - 100)) <= 1)
        #expect(bottom.minY - top.maxY == gap)
    }

    @Test func onlyForThoseTwoWindows() throws {
        var l = layout([[1], [2]])
        l.pair = Layout.Pair(width: 0.5, height: 0.8, windows: [1, 2])
        l.remove(2)
        l.insert(3, near: 1, maxColumns: 3)
        let f = frames(l)
        #expect(try #require(f[1]).union(try #require(f[3])).width == usable.width) // a new pair fills the screen
    }

    @Test func tidyAndSavingKnowAboutIt() throws {
        var l = layout([[1], [2]])
        l.pair = Layout.Pair(width: 0.5, height: 0.8, windows: [1, 2])
        let saved = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(l))
        #expect(saved.pair == l.pair)
        l.balance()
        #expect(l.pair == nil)
    }
}
