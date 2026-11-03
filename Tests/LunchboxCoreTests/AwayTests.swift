import Testing
@testable import LunchboxCore

/// Windows going out of view one at a time (App Exposé hiding every other app's windows, an app
/// hidden with ⌘H, Show Desktop) and coming back in whatever order their apps answer.
@Suite struct WindowsComingBack {
    /// Each window leaves the layout as LunchboxWM removes it, one after another.
    func leave(_ ids: [WindowID], from start: Layout, why: AwayMemory.Why = .outOfView,
               at times: [Double]? = nil) -> (memory: AwayMemory, left: Layout) {
        var memory = AwayMemory()
        var layout = start
        for (i, id) in ids.enumerated() {
            memory.left(id, space: 1, display: "LG", layout: layout, why: why, at: times?[i] ?? Double(i) * 0.1)
            layout.remove(id)
        }
        return (memory, layout)
    }

    @Test func aGridThatWentOutOfSightComesBackInAnyOrder() {
        for leaving in permutations([1, 2, 3, 4]) {
            let (memory, empty) = leave(leaving, from: grid)
            #expect(empty.isEmpty)
            for returning in permutations([1, 2, 3, 4]) {
                var m = memory, layout = empty
                for id in returning {
                    let spot = m.take(id)
                    #expect(spot != nil)
                    if let spot { layout.restore(id, from: spot.layout) }
                }
                #expect(layout.columns == grid.columns, "left \(leaving), back \(returning)")
            }
        }
    }

    @Test func theWindowThatStayedKeepsItsPlaceAndTheOthersGoBackAroundIt() {
        let three = Layout(columns: [Column(windows: [1], weight: 0.5), Column(windows: [2], weight: 0.3), Column(windows: [3], weight: 0.2)])
        // App Exposé for window 2's app: the other two go out of sight.
        for leaving in permutations([1, 3]) {
            let (memory, rest) = leave(leaving, from: three)
            #expect(rest.columns.map(\.windows) == [[2]])
            for returning in permutations([1, 3]) {
                var m = memory, layout = rest
                for id in returning { if let spot = m.take(id) { layout.restore(id, from: spot.layout) } }
                #expect(layout.columns == three.columns, "left \(leaving), back \(returning)")
            }
        }
    }

    @Test func onlyTheFirstLeavingCounts() {
        var memory = AwayMemory()
        memory.left(1, space: 0, display: "LG", layout: grid, why: .appHidden, at: 0)
        memory.left(1, space: 2, display: "LG", layout: Layout(columns: [Column(windows: [1])]), why: .outOfView, at: 1)
        #expect(memory[1]?.space == 0)
        #expect(memory[1]?.why == .appHidden)
        #expect(memory[1]?.layout == grid)
    }

    @Test func aWindowNotInTheLayoutIsNotRemembered() {
        var memory = AwayMemory()
        memory.left(9, space: 0, display: "LG", layout: grid, why: .outOfView, at: 0)
        #expect(memory[9] == nil)
    }

    @Test func windowsLeavingLongApartKeepTheirOwnLayouts() {
        // Window 1 went full screen a minute ago; window 2's app is hidden now.
        let (memory, _) = leave([1, 2], from: grid, at: [0, 60])
        #expect(memory[2]?.layout.contains(1) == false)
        // Within a few seconds of each other, they left together.
        let (together, _) = leave([1, 2], from: grid, at: [0, 2])
        #expect(together[2]?.layout == grid)
    }

    @Test func otherWorkspacesAndDisplaysAreSeparate() {
        var memory = AwayMemory()
        let two = Layout(columns: [Column(windows: [1]), Column(windows: [2])])
        memory.left(1, space: 0, display: "LG", layout: two, why: .outOfView, at: 0)
        memory.left(2, space: 1, display: "LG", layout: two, why: .outOfView, at: 0.1)
        memory.left(2, space: 0, display: "Other", layout: two, why: .outOfView, at: 0.1)
        #expect(memory[2]?.space == 1)
        #expect(memory[2]?.layout == two)
    }

    @Test func focusIsRememberedEvenIfAShelvedWindowLeftFirst() {
        var focused = grid
        focused.spotlight = 3
        let (memory, _) = leave([1, 3], from: focused)
        #expect(memory[3]?.focus == true)
        #expect(memory[1]?.focus == false)
    }

    @Test func eachComesBackToItsOwnWorkspaceButFullScreenJoinsTheOneInView() {
        func spot(_ why: AwayMemory.Why, space: Int) -> AwayMemory.Spot {
            AwayMemory.Spot(space: space, display: "LG", layout: grid, focus: false, why: why, at: 0)
        }
        #expect(AwayMemory.destination(of: spot(.appHidden, space: 0), currentSpace: 2) == 0)
        #expect(AwayMemory.destination(of: spot(.outOfView, space: 0), currentSpace: 2) == 0)
        #expect(AwayMemory.destination(of: spot(.fullScreen, space: 0), currentSpace: 2) == nil)
        #expect(AwayMemory.destination(of: spot(.fullScreen, space: 2), currentSpace: 2) == 2)
    }

    @Test func outOfSightThenFullScreenIsTheGreenButton() {
        var memory = AwayMemory()
        memory.left(1, space: 0, display: "LG", layout: grid, why: .outOfView, at: 0)
        memory.wentFullScreen(1)
        #expect(memory[1]?.why == .fullScreen)
        let first = memory.take(1), second = memory.take(1)
        #expect(first != nil)
        #expect(second == nil)
    }
}

@Suite struct CoveredScreen {
    @Test func oneWindowOutOfSightIsThatWindow() {
        var cover = CoverWatch()
        let none = cover.covered(gone: 0, at: 0), one = cover.covered(gone: 1, at: 1)
        #expect(!none)
        #expect(!one)
    }

    @Test func severalAtOnceIsTheScreenCoveredForAWhile() {
        var cover = CoverWatch()
        let start = cover.covered(gone: 2, at: 10)
        let later = cover.covered(gone: 3, at: 10 + CoverWatch.hold - 1)
        // Still out of sight after that: really gone (Chess keeps closed windows around).
        let after = cover.covered(gone: 3, at: 10 + CoverWatch.hold + 1)
        #expect(start)
        #expect(later)
        #expect(!after)
    }

    @Test func eachCoveringStartsOver() {
        var cover = CoverWatch()
        let first = cover.covered(gone: 2, at: 0)
        let over = cover.covered(gone: 0, at: 5)
        let again = cover.covered(gone: 2, at: 100)
        #expect(first)
        #expect(!over)
        #expect(again)
    }
}

@Suite struct OntoAnotherDisplay {
    @Test func draggedThereStays() {
        #expect(OffDisplayMove.decide(dragged: true, inputAgo: 30, appInFront: false) == .leaveThere)
    }

    @Test func aShortcutOrMenuInItsAppStays() {
        #expect(OffDisplayMove.decide(dragged: false, inputAgo: 0.2, appInFront: true) == .leaveThere)
    }

    @Test func itsAppMovingItComesBack() {
        // Simulator going back to where an agent left it, seconds after a build started it.
        #expect(OffDisplayMove.decide(dragged: false, inputAgo: 9, appInFront: true) == .backToTile)
        // Typing in another app just then isn't moving this window.
        #expect(OffDisplayMove.decide(dragged: false, inputAgo: 0.1, appInFront: false) == .backToTile)
    }

    @Test func anAppAnAgentClaimedStays() {
        // spoof.sh move, or Simulator reopening where the agent's test left it.
        #expect(OffDisplayMove.decide(dragged: false, inputAgo: 40, appInFront: false, claimed: true) == .leaveThere)
    }
}

@Suite struct AgentClaimsLapse {
    @Test func aClaimLastsAnHourFromWhenItWasLastMade() {
        var claims = AgentClaims()
        claims.claim("com.apple.dt.Devices", at: 100)
        #expect(claims.contains("com.apple.dt.Devices", at: 100 + 3599))
        #expect(!claims.contains("com.apple.dt.Devices", at: 100 + 3600))
        // Claimed again: another hour.
        claims.claim("com.apple.dt.Devices", at: 3000)
        #expect(claims.contains("com.apple.dt.Devices", at: 3000 + 3599))
        #expect(claims.current(at: 3000 + 10) == ["com.apple.dt.Devices"])
    }

    @Test func releasedOrNeverClaimedIsNotClaimed() {
        var claims = AgentClaims()
        claims.claim("company.thebrowser.Browser", at: 0)
        claims.release("company.thebrowser.Browser")
        #expect(!claims.contains("company.thebrowser.Browser", at: 1))
        #expect(!claims.contains("com.apple.Safari", at: 1))
        #expect(!claims.contains(nil, at: 1))
        #expect(claims.current(at: 1).isEmpty)
    }
}

/// A laptop's lid closed and opened again, the displays asleep, the lock screen: windows keep
/// their tiles through it, whatever their apps say, until the Mac has been back in use a moment.
@Suite struct BackFromSleep {
    @Test func awakeAndUnlockedNothingHolds() {
        #expect(!SleepWatch().holding(at: 100, locked: false))
    }

    @Test func holdsWhileAsleepAndForAMomentAfterWaking() {
        var watch = SleepWatch()
        watch.willSleep()
        #expect(watch.holding(at: 10, locked: false))
        // Asleep for hours: the clock it's given doesn't matter until it wakes.
        #expect(watch.holding(at: 10_000, locked: false))
        watch.didWake(at: 20)
        #expect(!watch.asleep)
        #expect(watch.holding(at: 20 + SleepWatch.settle - 0.5, locked: false))
        #expect(!watch.holding(at: 20 + SleepWatch.settle + 0.5, locked: false))
    }

    @Test func holdsWhileTheDisplaysSleep() {
        var watch = SleepWatch()
        watch.displaysDidSleep()
        #expect(watch.asleep)
        watch.displaysDidWake(at: 5)
        #expect(watch.holding(at: 6, locked: false))
        #expect(!watch.holding(at: 5 + SleepWatch.settle + 1, locked: false))
    }

    @Test func holdsWhileLockedAndForAMomentAfterUnlocking() {
        var watch = SleepWatch()
        #expect(watch.holding(at: 50, locked: true))
        watch.didUnlock(at: 60)
        #expect(watch.holding(at: 61, locked: false))
        #expect(!watch.holding(at: 60 + SleepWatch.settle + 1, locked: false))
    }

    @Test func theLockScreenIsOnlyAskedAboutWhenNothingElseHolds() {
        var watch = SleepWatch()
        watch.willSleep()
        var asked = false
        _ = watch.holding(at: 1, locked: { asked = true; return false }())
        #expect(!asked)
    }

    @Test func aLaterWakeKeepsTheLaterSettle() {
        var watch = SleepWatch()
        watch.didUnlock(at: 100)
        watch.displaysDidWake(at: 90) // reported late: doesn't shorten the moment
        #expect(watch.holding(at: 100 + SleepWatch.settle - 0.5, locked: false))
    }
}
