import CoreGraphics

/// Dialogs (alerts, password prompts, Open and Save panels) float, centered on
/// their screen, instead of slicing the tiled windows apart.
public enum Dialogs {
    /// The subroles macOS gives dialogs.
    public static let subroles: Set<String> = ["AXDialog", "AXSystemDialog"]

    /// Whether a window is a dialog rather than a document window. Some look
    /// like ordinary resizable windows (a standalone Open panel), so this checks
    /// more than the window's subrole.
    /// - looksLikeWindow: it resizes and has close, minimize and zoom buttons. A window
    ///   macOS calls a dialog that has all of that, and isn't asking anything, is a window
    ///   in all but name (Little Arc says it's a system dialog).
    public static func isDialog(subrole: String?, identifier: String?, hasDefaultButton: Bool,
                                hasCancelButton: Bool, modal: Bool, looksLikeWindow: Bool = false) -> Bool {
        if identifier == "open-panel" || identifier == "save-panel" { return true }
        if hasDefaultButton && hasCancelButton { return true } // OK and Cancel: asking something
        if modal { return true }
        if let subrole, subroles.contains(subrole) { return !looksLikeWindow }
        return false
    }

    /// Where a dialog of `size` sits centered in `area` (top-left coordinates),
    /// kept on screen when it's bigger than the area.
    public static func centeredOrigin(for size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(x: max(area.minX, (area.midX - size.width / 2).rounded()),
                y: max(area.minY, (area.midY - size.height / 2).rounded()))
    }
}
