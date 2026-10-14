import CoreGraphics

public enum KeyAction: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    case grow
    case shrink
    case close
    /// Sends the focused window to the next space (1 → 2 → 3 → 1).
    case hideToNextSpace
    case switchSpace(Int)
    case sendToSpace(Int)
}

public enum Shortcuts {
    /// NX_DEVICELCMDKEYMASK: set only while the left Command key is down.
    public static let leftCommandMask: UInt64 = 0x08

    /// Maps a key-down to a Tessel action, or nil to let it through to the app.
    ///
    /// Everything except the space keys needs the *left* Command key, so right
    /// Command keeps its usual meaning (right-⌘ + arrows still move the text cursor).
    public static func action(for code: Int64, flags: CGEventFlags, spaceKeys: [Int64]) -> KeyAction? {
        guard flags.contains(.maskCommand), !flags.contains(.maskControl) else { return nil }
        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)

        // Shift-⌘ + one of the three space keys (either Command key).
        if shift, let index = spaceKeys.firstIndex(of: code) {
            return option ? .sendToSpace(index) : .switchSpace(index)
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
        case 4: return shift ? .hideToNextSpace : nil // H
        default: return nil
        }
    }
}
