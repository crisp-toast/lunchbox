import Testing
@testable import LunchboxCore

@Suite struct DockAndSummon {
    @Test func dockClickGoesToTheAppsWorkspace() {
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: true, windowHere: nil, settling: false) == .goThere)
    }

    @Test func dockClickPrefersAWindowAlreadyHere() {
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: true, windowHere: 7, settling: false) == .focusHere(7))
    }

    @Test func dockClickIsDeliberateEvenRightAfterAClose() {
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: true, windowHere: nil, settling: true) == .goThere)
    }

    @Test func dockMenuWaitsForANewWindow() {
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: true, fromDockClick: true, windowHere: 7, settling: false) == .waitForNewWindow)
    }

    @Test func summonBringsTheWindowHere() {
        #expect(ForeignFocus.decide(summoned: true, fromDockMenu: false, fromDockClick: true, windowHere: nil, settling: false) == .bringHere)
    }

    @Test func macOSHandingFocusOverIsIgnored() {
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: false, windowHere: nil, settling: true) == .stay)
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: false, windowHere: nil, settling: false) == .goThere)
    }

    @Test func openingANewWindowLeavesTheAppsOtherWindowsWhereTheyAre() {
        // Summon's New Window for Arc in Workspace 3: Arc comes forward on its window parked in
        // Workspace 1 first. That window isn't what Summon opened, and isn't a reason to go there.
        #expect(ForeignFocus.decide(summoned: true, fromDockMenu: false, fromDockClick: false, windowHere: nil,
                                    settling: false, openingNewWindow: true) == .leaveIt)
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: false, windowHere: nil,
                                    settling: false, openingNewWindow: true) == .leaveIt)
    }
}

@Suite struct MenuBarApps {
    @Test func aMenuBarAppIsWatchedUntilItGetsADockIcon() {
        // 1Password at login: in the menu bar, no Dock icon.
        #expect(AppTracking.decide(hasDockIcon: false, isLunchbox: false, tracked: false, terminated: false) == .watch)
        // Its main window opens and the Dock icon comes with it.
        #expect(AppTracking.decide(hasDockIcon: true, isLunchbox: false, tracked: false, terminated: false) == .track)
    }

    @Test func goingBackToTheMenuBarKeepsItTracked() {
        #expect(AppTracking.decide(hasDockIcon: false, isLunchbox: false, tracked: true, terminated: false) == .ignore)
    }

    @Test func lunchboxAndQuitAppsAreLeftAlone() {
        #expect(AppTracking.decide(hasDockIcon: true, isLunchbox: true, tracked: false, terminated: false) == .ignore)
        #expect(AppTracking.decide(hasDockIcon: false, isLunchbox: false, tracked: false, terminated: true) == .ignore)
    }
}
