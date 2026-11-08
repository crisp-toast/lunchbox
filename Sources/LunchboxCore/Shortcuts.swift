import CoreGraphics

public enum KeyAction: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    case grow
    case shrink
    /// Resize mode on or off: while it's on, arrows change only the width or only the height.
    case resizeMode(Bool)
    /// Resize mode's arrow: pushes the window's edge on that side (see `Layout.resize(_:toward:)`).
    case resizeAlong(Direction)
    case close
    /// Hides the focused window by moving it to space 3.
    case hide
    /// Puts the focused window alone in the center, the rest shelved at the side.
    case spotlight
    /// Evens out every split in the space being viewed and puts windows back in their slots.
    case normalize
    case switchSpace(Int)
    case sendToSpace(Int)
    /// Shows or hides the launcher.
    case launcher
    /// Shows or hides the list of every shortcut.
    case help
}

public enum Shortcuts {
    /// NX_DEVICELCMDKEYMASK: set only while the left Command key is down.
    public static let leftCommandMask: UInt64 = 0x08
}

/// Recognizes a deliberate "⇧ then key": Shift pressed on its own, then one key,
/// with nothing typed in between. Typing rollover ("I am" with Shift still held
/// from the "I") never counts as Shift-Space, so Summon can't pop up mid-sentence.
public struct ShiftTapChord: Sendable {
    private var clean = false
    private var shiftDown = false

    public init() {}

    private static let otherModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    public mutating func flagsChanged(_ flags: CGEventFlags) {
        let shift = flags.contains(.maskShift)
        if !flags.intersection(Self.otherModifiers).isEmpty || !shift {
            clean = false
        } else if !shiftDown {
            clean = true
        }
        shiftDown = shift
    }

    /// Returns true when this key is the first one pressed after a clean ⇧ tap.
    public mutating func keyDown(code: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        let onlyShift = flags.contains(.maskShift) && flags.intersection(Self.otherModifiers).isEmpty
        let fires = onlyShift && clean && !isRepeat
        clean = false // any key while Shift is held spoils the chord
        return fires
    }
}
