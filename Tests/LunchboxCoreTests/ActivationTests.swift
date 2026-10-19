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
}
