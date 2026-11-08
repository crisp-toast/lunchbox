import CoreGraphics
import Testing
@testable import LunchboxCore

/// Windows that can't fill a tile: Simulator (keeps its shape), Calculator and System
/// Settings (fixed or capped width), apps with a minimum size.
@Suite struct FittedWindows {
    let phone = SizeLimits(maxWidth: 430, maxHeight: 932) // a Simulator device at its size
    let usable = CGRect(x: 8, y: 33, width: 2544, height: 1399)

    func noOverlap(_ frames: [WindowID: CGRect]) -> Bool {
        let all = Array(frames.values)
        for i in all.indices { for j in all.indices where i < j { if all[i].intersects(all[j]) { return false } } }
        return true
    }

    @Test func aNarrowWindowGetsANarrowColumnAndItsNeighborTheRest() throws {
        let f = layout([[1], [2]]).frames(in: screen, gap: gap, limits: [2: phone])
        let doc = try #require(f[1]), sim = try #require(f[2])
        #expect(sim.size == CGSize(width: 430, height: 932))
        #expect(doc.width == usable.width - gap - 430) // not half the screen
        #expect(abs(sim.midY - usable.midY) <= 1) // vertically centered in its column
        #expect(noOverlap(f))
    }

    @Test func withoutLimitsNothingChanges() {
        let l = layout([[1, 2], [3]])
        #expect(l.frames(in: screen, gap: gap) == l.frames(in: screen, gap: gap, limits: [:]))
        #expect(l.frames(in: screen, gap: gap) == l.frames(in: screen, gap: gap, limits: [1: SizeLimits()]))
    }

    @Test func aLoneFittedWindowSitsCenteredAtItsSize() throws {
        let f = try #require(layout([[2]]).frames(in: screen, gap: gap, limits: [2: phone])[2])
        #expect(f.size == CGSize(width: 430, height: 932))
        #expect(abs(f.midX - usable.midX) <= 1 && abs(f.midY - usable.midY) <= 1)
    }

    @Test func inFocusItIsCenteredAtItsSize() throws {
        var l = layout([[1], [2]])
        l.toggleSpotlight(2)
        let f = try #require(l.frames(in: screen, gap: gap, limits: [2: phone])[2])
        #expect(f.size == CGSize(width: 430, height: 932))
        #expect(abs(f.midX - usable.midX) <= 1)
    }

    @Test func fixedWindowsTogetherSitInTheMiddle() throws {
        let calc = SizeLimits.fixed(CGSize(width: 320, height: 500))
        let f = layout([[1], [2]]).frames(in: screen, gap: gap, limits: [1: calc, 2: phone])
        let a = try #require(f[1]), b = try #require(f[2])
        #expect(a.size == CGSize(width: 320, height: 500) && b.size == CGSize(width: 430, height: 932))
        #expect(b.minX - a.maxX == gap)
        #expect(abs((a.minX + b.maxX) / 2 - usable.midX) <= 1) // the pair is centered
    }

    @Test func aMinimumWidthTakesRoomFromTheOthers() throws {
        let wide = SizeLimits(minWidth: 1400)
        let f = layout([[1], [2], [3]]).frames(in: screen, gap: gap, limits: [2: wide])
        let b = try #require(f[2])
        #expect(b.width == 1400)
        let a = try #require(f[1]), c = try #require(f[3])
        #expect(a.width == c.width)
        #expect(noOverlap(f))
        #expect(f.values.allSatisfy { usable.contains($0) })
    }

    @Test func inAStackAShortWindowGetsItsHeightAndTheOtherTheRest() throws {
        let short = SizeLimits(maxHeight: 300)
        let f = layout([[1, 2], [3]]).frames(in: screen, gap: gap, limits: [2: short])
        let top = try #require(f[1]), bottom = try #require(f[2])
        #expect(bottom.height == 300)
        #expect(top.height == usable.height - gap - 300)
        #expect(top.width == bottom.width) // nothing capped its width
        #expect(noOverlap(f))
    }

    @Test func aCappedWindowStackedWithAFullOneIsCenteredInItsSlot() throws {
        let capped = SizeLimits(maxWidth: 500)
        let f = layout([[1, 2], [3]]).frames(in: screen, gap: gap, limits: [2: capped])
        let top = try #require(f[1]), bottom = try #require(f[2])
        #expect(bottom.width == 500)
        #expect(abs(bottom.midX - top.midX) <= 1) // the column is as wide as the full window needs
    }

    @Test func aWindowBiggerThanTheScreenStaysOnIt() throws {
        let huge = SizeLimits.fixed(CGSize(width: 3000, height: 2000))
        let f = try #require(layout([[1]]).frames(in: screen, gap: gap, limits: [1: huge])[1])
        #expect(f.minX == usable.minX && f.minY == usable.minY)
    }
}

@Suite struct PlacingWindowsThatCantSqueeze {
    let room = (area: CGSize(width: 1904, height: 944), gap: CGFloat(8))

    @Test func aTallWindowStacksWhereItFits() {
        // Column 0 holds Calculator (408) and Chess (407 at least); column 1 has room.
        var l = layout([[1, 2], [3]])
        let limits: [WindowID: SizeLimits] = [1: .fixed(CGSize(width: 230, height: 408)), 2: SizeLimits(maxWidth: 500, minHeight: 407),
                                              9: SizeLimits(minHeight: 532)]
        l.insert(9, near: 1, maxColumns: 2, limits: limits, room: room)
        #expect(l.position(of: 9)?.column == 1)
    }

    @Test func noRoomAnywhereButWidthToSpareMeansAColumnOfItsOwn() {
        let limits: [WindowID: SizeLimits] = [1: .fixed(CGSize(width: 230, height: 600)), 2: .fixed(CGSize(width: 500, height: 600)),
                                              9: SizeLimits(minHeight: 532)]
        var l = layout([[1], [2]])
        l.insert(9, near: 2, maxColumns: 2, limits: limits, room: room)
        #expect(l.columns.count == 3)
    }

    @Test func aNarrowWindowGetsItsOwnColumnWhenThereIsRoom() {
        // A document window and a phone-shaped Simulator; then Calculator.
        let limits: [WindowID: SizeLimits] = [2: SizeLimits(maxWidth: 421, maxHeight: 943), 9: .fixed(CGSize(width: 230, height: 408))]
        var l = layout([[1], [2]])
        l.insert(9, near: 2, maxColumns: 2, limits: limits, room: room)
        #expect(l.columns.count == 3)
        // With two document windows already there, it stacks instead: they keep their room.
        var crowded = layout([[1], [3]])
        crowded.insert(9, near: 3, maxColumns: 2, limits: limits, room: (area: CGSize(width: 1500, height: 944), gap: 8))
        #expect(crowded.columns.count == 2)
    }

    @Test func withoutLimitsItStacksAsAlways() {
        var a = layout([[1, 2], [3]]), b = a
        a.insert(9, near: 1, maxColumns: 2)
        b.insert(9, near: 1, maxColumns: 2, limits: [:], room: room)
        #expect(a == b)
    }
}

@Suite struct LearningLimits {
    let ask = CGSize(width: 1268, height: 1399)

    @Test func biggerThanAskedMeansAMinimum() {
        let l = SizeLimits().learning(asked: ask, got: CGSize(width: 1400, height: 1399))
        #expect(l == SizeLimits(minWidth: 1400))
    }

    @Test func smallerThanAskedMeansAMaximum() {
        // Simulator keeps its shape: asked for a tall half of the screen, it stays phone-sized.
        let l = SizeLimits().learning(asked: ask, got: CGSize(width: 430, height: 932))
        #expect(l == SizeLimits(maxWidth: 430, maxHeight: 932))
    }

    @Test func takingWhatWasAskedTeachesNothing() {
        #expect(SizeLimits().learning(asked: ask, got: ask) == SizeLimits())
        #expect(SizeLimits().learning(asked: ask, got: CGSize(width: 1269, height: 1398)) == SizeLimits())
    }

    @Test func takingASizeOutsideTheLimitsDropsThem() {
        // It was capped at 430 wide; now it took 900 (the user picked a bigger device).
        let l = SizeLimits(maxWidth: 430, maxHeight: 932).learning(asked: CGSize(width: 900, height: 932),
                                                                   got: CGSize(width: 900, height: 932))
        #expect(l.maxWidth == nil && l.maxHeight == 932)
    }

    @Test func settlesInTwoRoundsForAWindowThatKeepsItsShape() {
        // Round 1: asked for half the screen, the phone kept its height-limited shape.
        var l = SizeLimits().learning(asked: CGSize(width: 1268, height: 800), got: CGSize(width: 369, height: 800))
        #expect(l == SizeLimits(maxWidth: 369))
        // Round 2: its column is now 369 wide and the full height; it's width-limited.
        l = l.learning(asked: CGSize(width: 369, height: 1399), got: CGSize(width: 369, height: 800))
        #expect(l == SizeLimits(maxWidth: 369, maxHeight: 800))
        // Round 3 asks for exactly what it takes: nothing changes.
        #expect(l.learning(asked: CGSize(width: 369, height: 800), got: CGSize(width: 369, height: 800)) == l)
    }

    @Test func aFewPointsShortIsntAMaximum() {
        // Terminal snaps to whole character cells: a little narrower and shorter than asked.
        #expect(SizeLimits().learning(asked: ask, got: CGSize(width: 1261, height: 1386)) == SizeLimits())
    }

    @Test func noMaximumFromATinySlotOrWhileGrowingTheOtherWay() {
        // Squeezed into a crowded column: taller than asked (a minimum) but narrower; ambiguous.
        let l = SizeLimits().learning(asked: CGSize(width: 470, height: 91), got: CGSize(width: 428, height: 130))
        #expect(l == SizeLimits(minHeight: 130))
        // A slot only 200 wide says little about how wide the window can be.
        #expect(SizeLimits().learning(asked: CGSize(width: 200, height: 900), got: CGSize(width: 150, height: 900)) == SizeLimits())
    }

    @Test func clampKeepsWithinBothBounds() {
        let l = SizeLimits(minWidth: 400, maxWidth: 600, maxHeight: 500)
        #expect(l.clamp(CGSize(width: 300, height: 900)) == CGSize(width: 400, height: 500))
        #expect(l.clamp(CGSize(width: 900, height: 100)) == CGSize(width: 600, height: 100))
    }
}

@Suite struct Distributing {
    @Test func byWeightWithoutBounds() {
        #expect(Layout.distribute(1000, weights: [1, 1], mins: [0, 0], maxs: [.infinity, .infinity]) == [500, 500])
        #expect(Layout.distribute(1000, weights: [3, 1], mins: [0, 0], maxs: [.infinity, .infinity]) == [750, 250])
    }

    @Test func boundsHoldAndTheRestShares() {
        #expect(Layout.distribute(1000, weights: [1, 1, 1], mins: [0, 0, 0], maxs: [100, .infinity, .infinity]) == [100, 450, 450])
        #expect(Layout.distribute(1000, weights: [1, 1, 1], mins: [600, 0, 0], maxs: [.infinity, .infinity, .infinity]) == [600, 200, 200])
    }

    @Test func roundingLeavesNoGap() {
        let sizes = Layout.distribute(1001, weights: [1, 1, 1], mins: [0, 0, 0], maxs: [.infinity, .infinity, .infinity])
        #expect(sizes.reduce(0, +) == 1001)
    }

    @Test func minimumsThatDontFitAreLetGo() {
        // Eight Finder windows (at least 252 tall each) and one with no minimum in an 888-point column.
        let sizes = Layout.distribute(888, weights: Array(repeating: 1, count: 9), mins: Array(repeating: 252, count: 8) + [0],
                                      maxs: Array(repeating: .infinity, count: 9))
        #expect(sizes.allSatisfy { $0 >= 80 })
        #expect(sizes.prefix(8).allSatisfy { $0 > 98 }) // more than an even share: as near their minimum as fits
        #expect(sizes.reduce(0, +) == 888)
    }

    @Test func minimumWidthsThatDontFitShrinkInProportion() {
        // System Settings (740), Screen Sharing (715) and Chess (500) on a screen 1888 points wide.
        let sizes = Layout.distribute(1888, weights: [1, 1, 1], mins: [500, 740, 715], maxs: [.infinity, .infinity, .infinity])
        #expect(sizes.reduce(0, +) == 1888)
        #expect(sizes[1] > sizes[2] && sizes[2] > sizes[0]) // each keeps most of its own minimum
        #expect(sizes[1] > 700)
    }

    @Test func aCrowdedColumnStaysOnTheScreen() {
        let finder = SizeLimits(minHeight: 252)
        var limits: [WindowID: SizeLimits] = [9: .fixed(CGSize(width: 230, height: 408))]
        for id: WindowID in 1...8 { limits[id] = finder }
        let f = layout([[1, 2, 3, 4], [5, 6, 7, 8, 9, 10]]).frames(in: screen, gap: gap, limits: limits)
        let usable = CGRect(x: 8, y: 33, width: 2544, height: 1399)
        #expect(f.values.allSatisfy { usable.contains($0) && $0.height > 0 })
    }

    @Test func allCappedLeavesRoomOver() {
        #expect(Layout.distribute(1000, weights: [1, 1], mins: [0, 0], maxs: [200, 300]) == [200, 300])
    }
}

/// ⌘⇧− on a window with a minimum size stops when the window does, so the next ⌘⇧+ always
/// shows; the same for resize mode's arrows.
@Suite struct ResizingStopsAtTheLimit {
    let wide = SizeLimits(minWidth: 1000, minHeight: 500) // won't go narrower than 1000 or shorter than 500

    func width(_ l: Layout, _ id: WindowID, _ limits: [WindowID: SizeLimits]) -> CGFloat {
        l.frames(in: screen, gap: gap, limits: limits)[id]?.width ?? 0
    }

    /// Shrinks until a press is refused; every press that counted made the window smaller.
    func shrinkAll(_ l: inout Layout, _ id: WindowID, _ limits: [WindowID: SizeLimits]) -> Int {
        var presses = 0
        while presses < 30 {
            let before = l.frames(in: screen, gap: gap, limits: limits)[id]!.size
            guard l.resize(id, by: -0.08, in: screen, gap: gap, limits: limits) else { break }
            let after = l.frames(in: screen, gap: gap, limits: limits)[id]!.size
            #expect(after.width < before.width - 1 || after.height < before.height - 1)
            presses += 1
        }
        return presses
    }

    @Test func aTiledWindowStopsShrinkingAtItsMinimumAndGrowsRightBack() {
        let limits: [WindowID: SizeLimits] = [1: wide]
        var l = layout([[1], [2]])
        let presses = shrinkAll(&l, 1, limits)
        #expect(presses >= 1 && presses < 10)
        #expect(width(l, 1, limits) == 1000)
        let held = l
        let r1 = l.resize(1, by: -0.08, in: screen, gap: gap, limits: limits)
        #expect(!r1)
        #expect(l == held) // the refused press changed nothing, not even on paper
        let r2 = l.resize(1, by: 0.08, in: screen, gap: gap, limits: limits)
        #expect(r2)
        #expect(width(l, 1, limits) > 1150) // a whole step, not one spent getting back to the minimum
    }

    @Test func aStackedWindowStopsAtItsMinimumHeight() throws {
        let limits: [WindowID: SizeLimits] = [1: SizeLimits(minHeight: 600)]
        var l = layout([[1, 2], [3]])
        _ = shrinkAll(&l, 1, limits)
        let f = try #require(l.frames(in: screen, gap: gap, limits: limits)[1])
        #expect(f.height == 600)
        let r3 = l.resize(1, by: 0.08, in: screen, gap: gap, limits: limits)
        #expect(r3)
        #expect(try #require(l.frames(in: screen, gap: gap, limits: limits)[1]).height > 650)
    }

    @Test func aLoneWindowStopsShrinkingAtItsMinimum() throws {
        let limits: [WindowID: SizeLimits] = [1: SizeLimits(minWidth: 900, minHeight: 600)]
        var l = layout([[1]])
        _ = shrinkAll(&l, 1, limits)
        let small = try #require(l.frames(in: screen, gap: gap, limits: limits)[1])
        #expect(small.size == CGSize(width: 900, height: 600))
        let r4 = l.resize(1, by: 0.08, in: screen, gap: gap, limits: limits)
        #expect(r4)
        let grown = try #require(l.frames(in: screen, gap: gap, limits: limits)[1])
        #expect(grown.width > 900 && grown.height > 600)
    }

    @Test func aShareShrunkBeforeTheMinimumWasKnownIsSkipped() {
        // Shrunk to a fifth of the screen before LunchboxWM learned the window won't go under 1000.
        var l = layout([[1], [2]])
        l.columns[0].weight = 0.2
        l.columns[1].weight = 0.8
        let limits: [WindowID: SizeLimits] = [1: wide]
        #expect(width(l, 1, limits) == 1000)
        let r5 = l.resize(1, by: 0.08, in: screen, gap: gap, limits: limits)
        #expect(r5)
        #expect(width(l, 1, limits) > 1150)
    }

    @Test func aWindowAtItsLargestTakesNoMoreGrowing() {
        let limits: [WindowID: SizeLimits] = [2: SizeLimits(maxWidth: 430, maxHeight: 932)]
        var l = layout([[1], [2]])
        let held = l
        let r6 = l.resize(2, by: 0.08, in: screen, gap: gap, limits: limits)
        #expect(!r6)
        #expect(l == held)
        let r7 = l.resize(1, by: -0.08, in: screen, gap: gap, limits: limits) // its neighbor can't take the room
        #expect(!r7)
    }

    @Test func withoutLimitsItIsThePlainStep() {
        for ids in [[[1], [2]], [[1, 2], [3]], [[1]]] as [[[WindowID]]] {
            for delta in [0.08, -0.08] {
                var a = layout(ids), b = layout(ids)
                let ra = a.resize(1, by: delta), rb = b.resize(1, by: delta, in: screen, gap: gap, limits: [:])
                #expect(ra == rb)
                #expect(a == b)
            }
        }
    }

    @Test func resizeModesArrowsStopAtTheMinimumToo() {
        // In the right column → pushes the window's right edge in: it gets narrower.
        let limits: [WindowID: SizeLimits] = [2: wide]
        var l = layout([[1], [2]])
        var presses = 0
        while presses < 40, l.resize(2, toward: .right, by: 0.05, in: screen, gap: gap, limits: limits) { presses += 1 }
        #expect(width(l, 2, limits) == 1000)
        let r8 = l.resize(2, toward: .left, by: 0.05, in: screen, gap: gap, limits: limits)
        #expect(r8)
        #expect(width(l, 2, limits) > 1080)
    }
}
