import CoreGraphics
import Foundation
import Testing
@testable import LunchboxCore

/// A 2×2 grid with shares the user dragged to: a wide left column, uneven stacks.
let grid = Layout(columns: [
    Column(windows: [1, 2], weights: [0.7, 0.3], weight: 0.6),
    Column(windows: [3, 4], weights: [0.25, 0.75], weight: 0.4),
])

func permutations(_ ids: [WindowID]) -> [[WindowID]] {
    guard ids.count > 1 else { return [ids] }
    return ids.indices.flatMap { i in
        permutations(Array(ids[..<i] + ids[(i + 1)...])).map { [ids[i]] + $0 }
    }
}

@Suite struct RestoreAfterRelaunch {
    @Test func gridComesBackInAnyOrder() {
        for order in permutations([1, 2, 3, 4]) {
            var l = Layout()
            for id in order { let r = l.restore(id, from: grid); #expect(r) }
            #expect(l == grid, "order \(order)")
        }
    }

    @Test func threeColumnsAndAStackComeBackInAnyOrder() {
        let saved = Layout(columns: [
            Column(windows: [5], weight: 0.2),
            Column(windows: [6, 7, 8], weights: [1, 2, 3], weight: 0.5),
            Column(windows: [9], weight: 0.3),
        ])
        for order in permutations([5, 6, 7, 8, 9]) {
            var l = Layout()
            for id in order { l.restore(id, from: saved) }
            #expect(l == saved, "order \(order)")
        }
    }

    @Test func aWindowThatDidNotComeBackLeavesTheRestInPlace() {
        var l = Layout()
        for id: WindowID in [4, 1, 3] { l.restore(id, from: grid) }
        #expect(l.columns.map(\.windows) == [[1], [3, 4]])
        #expect(l.columns.map(\.weight) == [0.6, 0.4])
        #expect(l.columns[1].weights == [0.25, 0.75])
    }

    @Test func aWindowItNeverHadIsLeftAlone() {
        var l = layout([[1]])
        do { let r = l.restore(7, from: grid); #expect(!r) }
        do { let r = l.restore(1, from: grid); #expect(!r) } // already there
        #expect(l == layout([[1]]))
    }

    @Test func newWindowsKeepTheirPlaceBesideRestoredOnes() {
        var l = Layout()
        l.insert(7, near: nil, maxColumns: 3)
        for id: WindowID in [3, 2, 4, 1] { l.restore(id, from: grid) }
        #expect(l.windowCount == 5)
        #expect(l.columns.map(\.windows).contains([1, 2]))
        #expect(l.columns.map(\.windows).contains([3, 4]))
        let left = l.position(of: 1)!.column, right = l.position(of: 3)!.column
        #expect(left < right)
    }

    @Test func aWindowReturnsToItsStackAfterTheUserRearranged() {
        // After the relaunch 2 is still missing and the user moved 4 out on its own.
        var l = Layout()
        for id: WindowID in [1, 3, 4] { l.restore(id, from: grid) }
        do { let r = l.move(4, .right); #expect(r == .moved) }
        #expect(l.columns.map(\.windows) == [[1], [3], [4]])
        l.restore(2, from: grid)
        #expect(l.columns.map(\.windows) == [[1, 2], [3], [4]])
    }

    @Test func aLoneWindowGetsItsShapeBack() {
        var saved = layout([[1]])
        saved.adopt(1, size: CGSize(width: 900, height: 1200), in: screen, gap: gap)
        var l = Layout()
        l.restore(1, from: saved)
        #expect(l == saved)
        #expect(l.frames(in: screen, gap: gap) == saved.frames(in: screen, gap: gap))
    }
}

@Suite struct SavingLayouts {
    @Test func roundTripKeepsStacksSharesAndShape() throws {
        var saved = grid
        saved.singleOwner = 3
        saved.singleScale = 0.45
        saved.singleHeight = 0.8
        saved.spotlight = 2
        let data = try JSONEncoder().encode(["0|display": saved])
        let back = try #require(try JSONDecoder().decode([String: Layout].self, from: data)["0|display"])
        saved.spotlight = nil // Focus isn't saved
        #expect(back == saved)
    }

    @Test func damagedSharesStartOverEven() throws {
        let json = #"{"columns":[{"windows":[1,2],"weights":[0.5],"weight":-1},{"windows":[3],"weights":[0]}],"singleScale":0.6}"#
        let l = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        #expect(l.columns.map(\.weights) == [[1, 1], [1]])
        #expect(l.columns.map(\.weight) == [1, 1])
        #expect(l.frames(in: screen, gap: gap).count == 3)
    }
}
