import CoreGraphics
import Testing
@testable import TesselCore

// Tyler's Boop65: Page Up, Page Down, End.
let spaceKeys: [Int64] = [116, 121, 119]

/// Flags as macOS reports them: the generic Command bit plus which physical key.
func flags(leftCommand: Bool = true, rightCommand: Bool = false, shift: Bool = false, option: Bool = false) -> CGEventFlags {
    var raw: UInt64 = 0
    if leftCommand { raw |= Shortcuts.leftCommandMask }
    if rightCommand { raw |= 0x10 }
    var f = CGEventFlags(rawValue: raw)
    if leftCommand || rightCommand { f.insert(.maskCommand) }
    if shift { f.insert(.maskShift) }
    if option { f.insert(.maskAlternate) }
    return f
}

@Suite struct ShiftSpace {
    let shift = CGEventFlags.maskShift

    @Test func deliberateChordFires() {
        var chord = ShiftTapChord()
        chord.flagsChanged(shift)
        do { let r = chord.keyDown(code: 49, flags: shift, isRepeat: false); #expect(r) }
    }

    @Test func typingRolloverDoesNot() {
        // "I am": Shift down, I, then Space before Shift comes up. Only the I is
        // the first key after Shift (and nothing is bound to ⇧ then I).
        var chord = ShiftTapChord()
        chord.flagsChanged(shift)
        do { let r = chord.keyDown(code: 34, flags: shift, isRepeat: false); #expect(r) }
        do { let r = chord.keyDown(code: 49, flags: shift, isRepeat: false); #expect(!r) }
    }

    @Test func firesOncePerShiftPress() {
        var chord = ShiftTapChord()
        chord.flagsChanged(shift)
        do { let r = chord.keyDown(code: 49, flags: shift, isRepeat: false); #expect(r) }
        do { let r = chord.keyDown(code: 49, flags: shift, isRepeat: false); #expect(!r) }
        chord.flagsChanged([])
        chord.flagsChanged(shift)
        do { let r = chord.keyDown(code: 49, flags: shift, isRepeat: false); #expect(r) }
    }

    @Test func otherModifiersOrPlainSpaceDoNot() {
        var chord = ShiftTapChord()
        chord.flagsChanged([.maskShift, .maskCommand])
        do { let r = chord.keyDown(code: 49, flags: [.maskShift, .maskCommand], isRepeat: false); #expect(!r) }
        var plain = ShiftTapChord()
        do { let r = plain.keyDown(code: 49, flags: [], isRepeat: false); #expect(!r) }
    }
}
