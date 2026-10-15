import CoreGraphics

/// Dialogs (alerts, password prompts, Open and Save panels) float, centered on
/// their screen, instead of slicing the tiled windows apart.
public enum Dialogs {
    /// Whether a window is a dialog rather than a document window. Some look
    /// like ordinary resizable windows (a standalone Open panel), so this checks
    /// more than the window's subrole.
    public static func isDialog(subrole: String?, identifier: String?, hasDefaultButton: Bool,
                                hasCancelButton: Bool, modal: Bool) -> Bool {
        if subrole == "AXDialog" || subrole == "AXSystemDialog" { return true }
        if identifier == "open-panel" || identifier == "save-panel" { return true }
        if hasDefaultButton && hasCancelButton { return true } // OK and Cancel: asking something
        return modal
    }

    /// Where a dialog of `size` sits centered in `area` (top-left coordinates),
    /// kept on screen when it's bigger than the area.
    public static func centeredOrigin(for size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(x: max(area.minX, (area.midX - size.width / 2).rounded()),
                y: max(area.minY, (area.midY - size.height / 2).rounded()))
    }
}
