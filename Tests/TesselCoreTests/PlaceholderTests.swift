import CoreGraphics
import Foundation
import Testing
@testable import TesselCore

let p1 = Placeholder.id(0), p2 = Placeholder.id(1)

/// Layouts a new window can arrive in: empty, one window, side by side, a full
/// row of columns (so it stacks), and uneven shares the user dragged to.
let arrivals: [(layout: Layout, focused: WindowID?)] = [
    (Layout(), nil),
    (layout([[1]]), 1),
    (layout([[1], [2]]), 1),
    (layout([[1], [2], [3]]), 3),
    (Layout(columns: [Column(windows: [1, 2], weights: [0.7, 0.3], weight: 0.65), Column(windows: [3], weight: 0.35)]), 2),
]

@Suite struct Placeholders {
    @Test func idsNeverLookLikeWindowNumbers() {
        #expect(Placeholder.isPlaceholder(p1))
        #expect(Placeholder.isPlaceholder(Placeholder.id(1_000_000)))
        #expect(p1 != p2)
        for id: WindowID in [1, 42, 9655, 250_000, 10_000_000] { #expect(!Placeholder.isPlaceholder(id)) }
    }

    @Test func holdsTheSlotTheWindowWillGet() {
        for (start, focused) in arrivals {
            var direct = start
            direct.insert(9, near: focused, maxColumns: 3)
            var held = start
            held.insert(p1, near: focused, maxColumns: 3)
            #expect(held.frames(in: screen, gap: gap)[p1] == direct.frames(in: screen, gap: gap)[9])
            do { let r = held.fill(p1, with: 9); #expect(r) }
            #expect(held == direct, "from \(start.columns.map(\.windows))")
        }
    }

    @Test func onlyTheNewWindowMovesWhenItArrives() throws {
        for (start, focused) in arrivals {
            var l = start
            l.insert(p1, near: focused, maxColumns: 3)
            let waiting = l.frames(in: screen, gap: gap)
            l.fill(p1, with: 9)
            let arrived = l.frames(in: screen, gap: gap)
            #expect(arrived[9] == waiting[p1])
            for id in start.windows { #expect(arrived[id] == waiting[id]) }
            #expect(arrived[p1] == nil)
        }
    }

    @Test func givingUpClosesTheGap() {
        for (start, focused) in arrivals {
            var l = start
            l.insert(p1, near: focused, maxColumns: 3)
            l.remove(p1)
            #expect(l == start, "from \(start.columns.map(\.windows))")
        }
    }

    @Test func aLonePlaceholderSitsCenteredAtSixteenByTen() throws {
        let l = layout([[p1]])
        let frame = try #require(l.frames(in: screen, gap: gap)[p1])
        #expect(abs(frame.width / frame.height - Layout.singleAspect) < 0.01)
        #expect(abs(frame.midX - screen.midX) <= 1 && abs(frame.midY - screen.midY) <= 1)
        // The window lands right where the placeholder was.
        var filled = l
        filled.fill(p1, with: 9)
        #expect(filled.frames(in: screen, gap: gap)[9] == frame)
    }

    @Test func aPlaceholderInFocusHandsFocusToItsWindow() throws {
        var l = layout([[1], [2]])
        l.insert(p1, near: 2, maxColumns: 3)
        l.spotlight = p1
        let waiting = l.frames(in: screen, gap: gap)
        #expect(l.shelved == [1, 2])
        let center = try #require(waiting[p1])
        #expect(abs(center.width / center.height - Layout.singleAspect) < 0.01)
        l.fill(p1, with: 9)
        #expect(l.spotlight == 9)
        #expect(l.shelved == [1, 2])
        let arrived = l.frames(in: screen, gap: gap)
        #expect(arrived[9] == waiting[p1])
        #expect(arrived[1] == waiting[1] && arrived[2] == waiting[2])
    }

    @Test func onlyAPlaceholderCanBeFilledAndOnlyByANewWindow() {
        var l = layout([[1], [p1]])
        do { let r = l.fill(1, with: 9); #expect(!r) }  // not a placeholder
        do { let r = l.fill(p1, with: 1); #expect(!r) } // already tiled
        do { let r = l.fill(p2, with: 9); #expect(!r) } // not waiting here
        #expect(l == layout([[1], [p1]]))
    }

    @Test func twoLaunchesFillTheirOwnSpotsInAnyOrder() {
        var direct = layout([[1]])
        direct.insert(8, near: 1, maxColumns: 3)
        direct.insert(9, near: 8, maxColumns: 3)
        var held = layout([[1]])
        held.insert(p1, near: 1, maxColumns: 3)
        held.insert(p2, near: p1, maxColumns: 3)
        held.fill(p2, with: 9) // the second app was quicker
        held.fill(p1, with: 8)
        #expect(held == direct)
        // A further window from the same app tiles as usual.
        held.insert(10, near: 9, maxColumns: 3)
        direct.insert(10, near: 9, maxColumns: 3)
        #expect(held == direct)
    }

    @Test func placeholdersAreNeverSaved() throws {
        var l = Layout(columns: [Column(windows: [1, 2], weights: [0.6, 0.4], weight: 0.7), Column(windows: [3], weight: 0.3)])
        let saved = l
        l.insert(p1, near: 2, maxColumns: 2) // no room for a column: it stacks
        l.insert(p2, near: 3, maxColumns: 3) // a column of its own
        #expect(l.placeholders.sorted() == [p1, p2])
        #expect(l.withoutPlaceholders() == saved)
        let json = String(decoding: try JSONEncoder().encode(l.withoutPlaceholders()), as: UTF8.self)
        #expect(!json.contains(String(p1)) && !json.contains(String(p2)))
        // Focus on a real window survives; Focus on a placeholder doesn't.
        l.spotlight = 3
        #expect(l.withoutPlaceholders().spotlight == 3)
        l.spotlight = p1
        #expect(l.withoutPlaceholders().spotlight == nil)
    }
}
