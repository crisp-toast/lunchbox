import CoreGraphics
import Testing
@testable import LunchboxCore

/// In Focus, clicking a card on the Shelf swaps it with the window in the center.
@Suite struct FocusSwap {
    @Test func thePickedCardTakesTheCenterAndTheOldOneTakesItsPlace() throws {
        var l = layout([[1, 2], [3, 4]])
        l.toggleSpotlight(1)
        #expect(l.shelved == [2, 3, 4])
        let before = l.frames(in: screen, gap: gap)
        let swapped = l.swapSpotlight(with: 3)
        #expect(swapped)
        #expect(l.spotlight == 3)
        #expect(l.shelved == [2, 1, 4]) // 1 sits where 3's card was
        let after = l.frames(in: screen, gap: gap)
        #expect(after[1] == before[3] && after[3] == before[1]) // the two trade places exactly
        #expect(after[2] == before[2] && after[4] == before[4]) // the other cards stay put
    }

    @Test func endingFocusBringsBackTheSameTiles() {
        var l = layout([[1, 2], [3, 4]])
        let tiles = l.frames(in: screen, gap: gap)
        l.toggleSpotlight(1)
        l.swapSpotlight(with: 4)
        l.swapSpotlight(with: 2)
        l.toggleSpotlight(2)
        #expect(l.spotlight == nil && l.frames(in: screen, gap: gap) == tiles)
    }

    @Test func onlyACardOnTheShelfSwaps() {
        var l = layout([[1], [2]])
        let notInFocus = l.swapSpotlight(with: 2)
        #expect(!notInFocus)
        l.toggleSpotlight(1)
        let alreadyCentered = l.swapSpotlight(with: 1)
        let notHere = l.swapSpotlight(with: 9)
        #expect(!alreadyCentered && !notHere)
        #expect(l.spotlight == 1)
    }

    @Test func aWindowOpenedDuringFocusStillGetsACard() {
        var l = layout([[1], [2]])
        l.toggleSpotlight(1)
        l.swapSpotlight(with: 2)
        l.insert(3, near: 2, maxColumns: 3)
        #expect(Set(l.shelved) == [1, 3] || l.spotlight == nil)
    }
}
