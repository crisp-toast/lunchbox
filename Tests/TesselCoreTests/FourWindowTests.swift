import CoreGraphics
import Foundation
import Testing
@testable import TesselCore

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

@Suite struct LearnedFourWindowShapes {
    let display = "2560x1415"
    let claude = "com.anthropic.claudefordesktop"

    func arrangement(_ columns: [[String]], widths: [Double]? = nil) -> Arrangement {
        var apps: [WindowID: String] = [:]
        var next: WindowID = 1
        var cols: [Column] = []
        for (i, column) in columns.enumerated() {
            var ids: [WindowID] = []
            for app in column {
                apps[next] = app
                ids.append(next)
                next += 1
            }
            cols.append(Column(windows: ids, weight: widths?[i] ?? 1))
        }
        return Arrangement(Layout(columns: cols), apps: apps)!
    }

    var claudeLeft: Arrangement { arrangement([[claude], ["mail", "notes", "safari"]], widths: [1.2, 0.8]) }
    var others: [String] { [claude, "slack", "xcode", "terminal"] }

    @Test func aColumnToItselfIsLearned() throws {
        var m = ArrangementMemory()
        m.learn(.arranged(claudeLeft, on: display, dwell: 45, byYou: true, at: 100), now: 100)
        let found = try #require(m.anchoredShape(display: display, apps: others))
        #expect(found.app == claude)
        #expect(found.shape.stacks == [1, 3] && found.shape.column == 0 && found.shape.side == "left")
        // Laid out: Claude alone on the left at the share you gave it, the others stacked in order.
        let l = try #require(found.shape.layout(anchor: 9, others: [6, 7, 8]))
        #expect(l.columns.map(\.windows) == [[9], [6, 7, 8]])
        #expect(abs(l.columns[0].weight - 0.6) < 1e-9)
    }

    @Test func onlyAShapeYouMadeAndKeptCounts() {
        var m = ArrangementMemory()
        m.learn(.arranged(claudeLeft, on: display, dwell: 600, at: 100), now: 100) // Tessel's, let stand
        #expect(m.anchoredShape(display: display, apps: others) == nil)
        m.learn(.arranged(claudeLeft, on: display, dwell: 10, byYou: true, at: 200), now: 200) // not long enough yet
        #expect(m.anchoredShape(display: display, apps: others) == nil)
        m.learn(.arranged(claudeLeft, on: display, dwell: 25, byYou: true, at: 300), now: 300)
        #expect(m.anchoredShape(display: display, apps: others)?.app == claude)
    }

    @Test func theLatestShapeWinsAndTheGridUnlearnsIt() {
        var m = ArrangementMemory()
        m.learn(.arranged(claudeLeft, on: display, dwell: 3600, byYou: true, at: 100), now: 100)
        let right = arrangement([["mail", "notes", "safari"], [claude]])
        m.learn(.arranged(right, on: display, dwell: 40, byYou: true, at: 200), now: 200)
        #expect(m.anchoredShape(display: display, apps: others)?.shape.side == "right")
        // You went back to a grid with Claude in it, and kept it: Tessel stops.
        m.learn(.arranged(arrangement([[claude, "mail"], ["notes", "safari"]]), on: display, dwell: 60, byYou: true, at: 300), now: 300)
        #expect(m.anchoredShape(display: display, apps: others) == nil)
    }

    @Test func onlyForFourWindowsOnThatDisplay() {
        var m = ArrangementMemory()
        m.learn(.arranged(claudeLeft, on: display, dwell: 60, byYou: true, at: 100), now: 100)
        #expect(m.anchoredShape(display: "1470x956", apps: others) == nil)
        #expect(m.anchoredShape(display: display, apps: [claude, "slack", "xcode"]) == nil)
        #expect(m.anchoredShape(display: display, apps: [claude, claude, "xcode", "terminal"]) == nil)
        // Five windows teach nothing about four.
        var five = ArrangementMemory()
        five.learn(.arranged(arrangement([["xcode"], ["a", "b", "c", "d"]]), on: display, dwell: 60, byYou: true, at: 1), now: 1)
        #expect(five.anchored.isEmpty)
    }

    @Test func survivesARelaunchAndCanBeForgotten() throws {
        let events = [ArrangeEvent.arranged(claudeLeft, on: display, dwell: 60, byYou: true, at: 100)]
        let json = try JSONEncoder().encode(events)
        let back = try JSONDecoder().decode([ArrangeEvent].self, from: json)
        var m = ArrangementMemory.replay(back, now: 200)
        #expect(m.anchoredShape(display: display, apps: others)?.app == claude)
        // A line from before this existed (no byYou) teaches no shape.
        var old = events[0]
        old.byYou = nil
        #expect(ArrangementMemory.replay([old], now: 200).anchored.isEmpty)
        m.forget(ArrangementMemory.shapeKey(display: display, app: claude))
        #expect(m.anchoredShape(display: display, apps: others) == nil)
    }

    @Test func theQuietLineSaysSo() {
        #expect(QuietLine.text(for: [.anchored(app: "Claude", side: "left")], undoKey: "Left ⌘ 1")
            == "Claude has the left to itself, like last time · Left ⌘ 1 makes a grid")
    }
}
