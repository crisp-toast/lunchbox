import CoreGraphics
import Testing
@testable import LunchboxCore

/// A restarted app's windows go back to the Workspace and spot they had when it quit.
@Suite struct RestartsGoBackWhereTheyWere {
    let claude = "com.anthropic.claudefordesktop"
    let left = CGRect(x: 8, y: 38, width: 1268, height: 1394)
    let right = CGRect(x: 1284, y: 38, width: 1268, height: 1394)

    func spot(_ window: WindowID, space: Int, frame: CGRect, usedLast: Bool = false) -> QuitMemory.Spot {
        QuitMemory.Spot(window: window, space: space, display: "LG", frame: frame, layout: layout([[window], [99]]), usedLast: usedLast)
    }

    @Test func aWindowClosedAsItsAppQuitIsRemembered() {
        var memory = QuitMemory()
        memory.closed(claude, spot: spot(1, space: 0, frame: left), at: 100)
        memory.quit(claude, at: 100.5)
        let back = memory.spot(for: claude, frame: .zero, now: 110)
        #expect(back?.space == 0)
        #expect(back?.window == 1)
    }

    @Test func aWindowClosedLongBeforeTheAppQuitIsNot() {
        // You closed it and kept using the app: that's not where a restart goes.
        var memory = QuitMemory()
        memory.closed(claude, spot: spot(1, space: 2, frame: left), at: 100)
        memory.quit(claude, at: 200)
        #expect(memory.spot(for: claude, frame: left, now: 201) == nil)
    }

    @Test func everySpotIsListedForANewWindowToPickFrom() {
        // The window used last first, so a restart that opens one window brings back that one.
        var memory = QuitMemory()
        memory.closed(claude, spot: spot(1, space: 0, frame: left), at: 100)
        memory.closed(claude, spot: spot(2, space: 0, frame: right, usedLast: true), at: 100.2)
        memory.quit(claude, at: 100.5)
        #expect(memory.spots(for: claude, now: 110).map(\.window) == [2, 1])
        #expect(memory.spots(for: claude, now: 100.5 + 3601).isEmpty)
        #expect(QuitMemory.close(right, right.offsetBy(dx: 3, dy: -3)) && !QuitMemory.close(right, left))
    }

    @Test func onlyForAnHour() {
        var memory = QuitMemory()
        memory.closed(claude, spot: spot(1, space: 0, frame: left), at: 100)
        memory.quit(claude, at: 100)
        #expect(memory.spot(for: claude, frame: left, now: 100 + 3599) != nil)
        #expect(memory.spot(for: claude, frame: left, now: 100 + 3601) == nil)
    }

    @Test func eachWindowGoesBackToTheSpotItReopensAt() {
        var memory = QuitMemory()
        memory.closed(claude, spot: spot(1, space: 0, frame: left), at: 100)
        memory.closed(claude, spot: spot(2, space: 1, frame: right, usedLast: true), at: 100.1)
        memory.quit(claude, at: 100.2)
        // The app reopens a window where the first one was: it goes back to that one's spot.
        #expect(memory.take(for: claude, frame: left, now: 105)?.window == 1)
        // The next takes what's left.
        #expect(memory.take(for: claude, frame: .zero, now: 105)?.window == 2)
        #expect(memory.take(for: claude, frame: .zero, now: 105) == nil)
    }

    @Test func otherwiseTheWindowYouUsedLast() {
        var memory = QuitMemory()
        memory.closed(claude, spot: spot(1, space: 0, frame: left), at: 100)
        memory.closed(claude, spot: spot(2, space: 1, frame: right, usedLast: true), at: 100.1)
        memory.quit(claude, at: 100.2)
        #expect(memory.take(for: claude, frame: CGRect(x: 300, y: 300, width: 800, height: 600), now: 105)?.window == 2)
    }

    @Test func otherAppsAreUntouched() {
        var memory = QuitMemory()
        memory.closed(claude, spot: spot(1, space: 0, frame: left), at: 100)
        memory.quit(claude, at: 100)
        #expect(memory.spot(for: "com.apple.mail", frame: left, now: 101) == nil)
    }

    @Test func theNewWindowTakesTheOldOnesPlaceBesideTheSameWindows() {
        let saved = layout([[7], [1, 8]]) // the quitting window (1) shared a stack with 8, beside 7
        let spot = QuitMemory.Spot(window: 1, space: 0, display: "LG", frame: right, layout: saved, usedLast: true)
        var now = layout([[7], [8]])
        let restored = now.restore(42, from: QuitMemory.layout(of: spot, as: 42))
        #expect(restored)
        #expect(now.columns.map(\.windows) == [[7], [42, 8]])
    }
}
