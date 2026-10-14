import CoreGraphics

public enum KeyAction: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    case grow
    case shrink
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
}

public enum Shortcuts {
    /// NX_DEVICELCMDKEYMASK: set only while the left Command key is down.
    public static let leftCommandMask: UInt64 = 0x08

    /// Maps a key-down to a Tessel action, or nil to let it through to the app.
    ///
    /// ⌘ goes somewhere (focus a window, go to a space); ⌘⇧ moves or changes
    /// something (move the window, resize, send it to a space, close it).
    /// Everything except the space keys needs the *left* Command key, so right
    /// Command keeps its usual meaning (right-⌘ + arrows still move the text cursor).
    public static func action(for code: Int64, flags: CGEventFlags, spaceKeys: [Int64]) -> KeyAction? {
        guard flags.contains(.maskCommand), !flags.contains(.maskControl) else { return nil }
        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)

        // ⌘ + a space key goes to that space; ⌘⇧ moves the focused window there.
        // Either Command key works for these.
        if let index = spaceKeys.firstIndex(of: code) {
            guard !option else { return nil }
            return shift ? .sendToSpace(index) : .switchSpace(index)
        }

        guard flags.rawValue & leftCommandMask != 0, !option else { return nil }
        switch code {
        case 123: return shift ? .move(.left) : .focus(.left)
        case 124: return shift ? .move(.right) : .focus(.right)
        case 125: return shift ? .move(.down) : .focus(.down)
        case 126: return shift ? .move(.up) : .focus(.up)
        case 24, 69: return shift ? .grow : nil   // = (plus with Shift), keypad +
        case 27, 78: return shift ? .shrink : nil // -, keypad -
        case 51: return shift ? .close : nil      // Delete (Backspace)
        case 4: return shift ? .hide : nil        // H
        case 3: return shift ? .spotlight : nil   // F
        case 29: return shift ? .normalize : nil  // 0
        default: return nil
        }
    }
}

/// Recognizes a deliberate Shift-Space: Shift pressed on its own, then Space,
/// with no other key in between. Typing rollover ("I am" with Shift still held
/// from the "I") never counts, so the launcher can't pop up mid-sentence.
public struct ShiftSpaceChord: Sendable {
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

    /// Returns true when this key-down completes the chord.
    public mutating func keyDown(code: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        let onlyShift = flags.contains(.maskShift) && flags.intersection(Self.otherModifiers).isEmpty
        let fires = code == 49 && onlyShift && clean && !isRepeat
        clean = false // any key while Shift is held spoils the chord
        return fires
    }
}
