/// Where tiled windows were when they went out of view without closing: into full screen (the
/// green button), with their app hidden (⌘H, Hide Others), or out of sight with nothing said
/// (Mission Control or App Exposé covering them, a window on its way into full screen). Each
/// comes back to the same spot.
public struct AwayMemory: Sendable {
    public enum Why: Sendable, Equatable {
        /// The green button.
        case fullScreen
        /// Its app was hidden.
        case appHidden
        /// It went out of sight with nothing said.
        case outOfView
    }

    public struct Spot: Sendable, Equatable {
        public let space: Int
        public let display: String
        /// The layout it left. Windows that left together all keep the one from before the first
        /// of them went, so they come back to it in whatever order they return.
        public let layout: Layout
        /// It was in Focus.
        public let focus: Bool
        public internal(set) var why: Why
        public let at: Double
    }

    /// Windows leaving one layout within this long of each other left together.
    public static let togetherSeconds = 5.0

    private var spots: [WindowID: Spot] = [:]

    public init() {}

    public subscript(id: WindowID) -> Spot? { spots[id] }

    /// A tiled window is leaving `layout`, in `space` on `display`. Only the first time counts: a
    /// window already away keeps the spot it had.
    public mutating func left(_ id: WindowID, space: Int, display: String, layout: Layout, why: Why, at time: Double) {
        guard spots[id] == nil, layout.contains(id) else { return }
        let earlier = spots.values
            .filter { $0.space == space && $0.display == display && time - $0.at < Self.togetherSeconds && $0.layout.contains(id) }
            .min { $0.at < $1.at }?.layout
        let before = earlier ?? layout
        spots[id] = Spot(space: space, display: display, layout: before, focus: before.spotlight == id, why: why, at: time)
    }

    /// It turned out to be on its way into full screen.
    public mutating func wentFullScreen(_ id: WindowID) {
        spots[id]?.why = .fullScreen
    }

    /// It's back: its spot, once.
    public mutating func take(_ id: WindowID) -> Spot? {
        spots.removeValue(forKey: id)
    }

    public mutating func forget(_ id: WindowID) {
        spots[id] = nil
    }

    public mutating func forgetAll() {
        spots = [:]
    }

    /// The Workspace a window coming back goes to: its own. Except from full screen: leaving it
    /// while another Workspace is in view, it joins that one (nil), since that's where you are.
    public static func destination(of spot: Spot, currentSpace: Int) -> Int? {
        spot.why == .fullScreen && spot.space != currentSpace ? nil : spot.space
    }
}

/// Mission Control, App Exposé (which hides every other app's windows) and Show Desktop take
/// windows out of sight without them going anywhere. When the Dock doesn't say so, it shows as
/// several tiles in view out of sight at once, with no app hidden and nothing minimized. Those
/// keep their tiles, for `hold` at most: two windows really closed at once by an app that keeps
/// closed windows around (Chess does) let theirs go after that.
public struct CoverWatch: Sendable {
    public static let hold = 20.0
    private var since: Double?

    public init() {}

    /// `gone`: tiles in view out of sight right now. True while that's the screen being covered.
    public mutating func covered(gone: Int, at time: Double) -> Bool {
        guard gone >= 2 else {
            since = nil
            return false
        }
        let start = since ?? time
        since = start
        return time - start < Self.hold
    }
}

/// A tiled window that went onto a display LunchboxWM doesn't tile (Use All Displays off): a
/// dummy plug agents test on, or a screen you keep for windows you'd rather not tile.
public enum OffDisplayMove: Equatable, Sendable {
    /// You put it there: it stays, untiled.
    case leaveThere
    /// Its app moved it there by itself (Simulator going back to where an agent left it): it goes
    /// back to its tile, so it never ends up somewhere you can't see.
    case backToTile

    /// How soon after a key press or a click a move counts as yours (a window tool's shortcut,
    /// Window › Move to).
    public static let inputSeconds = 0.6

    /// - dragged: you dragged it there.
    /// - inputAgo: seconds since your last key press or click.
    /// - appInFront: its app is the one in front, where that key press or menu click went.
    public static func decide(dragged: Bool, inputAgo: Double, appInFront: Bool) -> OffDisplayMove {
        dragged || (appInFront && inputAgo < inputSeconds) ? .leaveThere : .backToTile
    }
}
