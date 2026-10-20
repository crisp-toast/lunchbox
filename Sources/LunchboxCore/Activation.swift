/// What LunchboxWM does when one of an app's windows in another Workspace takes focus.
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
    /// The app came forward on this window to open a new one here (Summon's New Window): the
    /// window stays where it is, and nothing else happens. The new window is on its way.
    case leaveIt

    /// - placedForYou: LunchboxWM just opened this window in its app's Workspace while you stayed
    ///   here. Its app reaching for focus isn't you asking to go there.
    /// - openingNewWindow: LunchboxWM is opening a new window of this app here, and this is one of
    ///   the windows the app already had.
    public static func decide(summoned: Bool, fromDockMenu: Bool, fromDockClick: Bool,
                              windowHere: WindowID?, settling: Bool, placedForYou: Bool = false,
                              openingNewWindow: Bool = false) -> ForeignFocus {
        if openingNewWindow { return .leaveIt }
        if placedForYou { return .stay }
        if summoned { return .bringHere }
        if fromDockMenu { return .waitForNewWindow }
        if fromDockClick { return windowHere.map(ForeignFocus.focusHere) ?? .goThere }
        return settling ? .stay : .goThere
    }
}
