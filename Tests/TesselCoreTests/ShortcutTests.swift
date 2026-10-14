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

@Suite struct ShortcutMapping {
    func action(_ code: Int64, _ f: CGEventFlags) -> KeyAction? {
        Shortcuts.action(for: code, flags: f, spaceKeys: spaceKeys)
    }

    @Test func arrowsFocusAndMove() {
        #expect(action(123, flags()) == .focus(.left))
        #expect(action(126, flags()) == .focus(.up))
        #expect(action(124, flags(shift: true)) == .move(.right))
        #expect(action(125, flags(shift: true)) == .move(.down))
    }

    @Test func rightCommandIsLeftAlone() {
        #expect(action(123, flags(leftCommand: false, rightCommand: true)) == nil)
        #expect(action(51, flags(leftCommand: false, rightCommand: true, shift: true)) == nil)
    }

    @Test func closeAndHide() {
        #expect(action(51, flags(shift: true)) == .close)
        #expect(action(4, flags(shift: true)) == .hideToNextSpace)
        // Without Shift these stay with the app: ⌘-Delete and ⌘-H keep their usual jobs.
        #expect(action(51, flags()) == nil)
        #expect(action(4, flags()) == nil)
    }

    @Test func growAndShrinkNeedShift() {
        #expect(action(24, flags(shift: true)) == .grow)
        #expect(action(27, flags(shift: true)) == .shrink)
        #expect(action(24, flags()) == nil)
    }

    @Test func spaceKeysWorkWithEitherCommand() {
        #expect(action(116, flags(shift: true)) == .switchSpace(0))
        #expect(action(119, flags(leftCommand: false, rightCommand: true, shift: true)) == .switchSpace(2))
        #expect(action(121, flags(shift: true, option: true)) == .sendToSpace(1))
        #expect(action(116, flags()) == nil)
    }

    @Test func controlOrNoCommandPassesThrough() {
        var withControl = flags(shift: true)
        withControl.insert(.maskControl)
        #expect(action(123, withControl) == nil)
        #expect(action(123, CGEventFlags(rawValue: 0)) == nil)
    }
}
