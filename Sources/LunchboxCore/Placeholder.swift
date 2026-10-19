/// A tile held for a window that's on its way: Lunchbox makes room the moment it
/// knows a window is coming (Summon, a Dock click), and the window takes the
/// spot when it appears. In a layout a placeholder is just another window ID,
/// so it gets exactly the slot and size the new window would.
public enum Placeholder {
    /// Placeholder IDs sit at the very top of the window number range. The window
    /// server numbers windows upward from 1 and never gets anywhere near here.
    public static let firstID: WindowID = 0xFFFF_0000

    public static func isPlaceholder(_ id: WindowID) -> Bool { id >= firstID }

    /// The `n`th placeholder ID (wrapping around long before real windows could be reached).
    public static func id(_ n: Int) -> WindowID {
        firstID + WindowID(truncatingIfNeeded: n) % (WindowID.max - firstID)
    }
}

extension Layout {
    /// The placeholders waiting in this layout.
    public var placeholders: [WindowID] { windows.filter(Placeholder.isPlaceholder) }

    /// The real window arrived: it takes the placeholder's spot, share and Focus
    /// exactly, so nothing else moves. False when the placeholder isn't here or
    /// the window already is.
    @discardableResult
    public mutating func fill(_ placeholder: WindowID, with window: WindowID) -> Bool {
        guard Placeholder.isPlaceholder(placeholder), replace(placeholder, with: window) else { return false }
        if spotlight == placeholder { spotlight = window }
        if beforeGrid?.placeholder == placeholder { beforeGrid = nil }
        return true
    }

    /// The layout as it should be saved: placeholders only last while Lunchbox waits.
    public func withoutPlaceholders() -> Layout {
        var copy = self
        // The one that made the grid goes last, so the grid can go back to how it was.
        let grid = placeholders.filter { $0 == beforeGrid?.placeholder }
        for id in placeholders.filter({ $0 != beforeGrid?.placeholder }) + grid { copy.remove(id) }
        copy.spotlight = placeholders.contains(spotlight ?? 0) ? nil : spotlight
        return copy
    }
}
