/// What Tessel does when one of an app's windows in another Workspace takes focus.
public enum ForeignFocus: Equatable, Sendable {
    /// Summon opened something in the app: its window joins this Workspace.
    case bringHere
    /// Picked from the Dock's menu: "New Window" should open here, while choosing
    /// one of the app's windows goes to it. Wait a moment for a new window first.
    case waitForNewWindow
    /// A Dock click on an app that also has a window in this Workspace: use that one.
    case focusHere(WindowID)
    /// Go to the Workspace the window is in.
    case goThere
    /// macOS handed focus over by itself (right after a close or a switch): stay put.
    case stay

    public static func decide(summoned: Bool, fromDockMenu: Bool, fromDockClick: Bool,
                              windowHere: WindowID?, settling: Bool) -> ForeignFocus {
        if summoned { return .bringHere }
        if fromDockMenu { return .waitForNewWindow }
        if fromDockClick { return windowHere.map(ForeignFocus.focusHere) ?? .goThere }
        return settling ? .stay : .goThere
    }
}
