import CoreGraphics

/// Where an app's tiled windows were when it quit. When it starts again within the hour (a
/// restart: an update, a crash, ⌘Q and back), each new window goes back to one of those spots,
/// its Workspace, display and place among the windows there, instead of wherever you happen to
/// be. An app closes its windows one by one as it quits, a moment before it's gone, so each
/// closed window's spot is noted, and kept if its app quits right after.
public struct QuitMemory: Sendable {
    public struct Spot: Sendable, Equatable {
        /// The window that was there (gone now).
        public let window: WindowID
        public let space: Int
        public let display: String
        /// Where it was on screen: apps that reopen their windows mostly put them back there.
        public let frame: CGRect
        /// Its Workspace's layout on that display as it closed, with it still in.
        public let layout: Layout
        /// It was the window you were in, or the last one you used in its Workspace.
        public let usedLast: Bool

        public init(window: WindowID, space: Int, display: String, frame: CGRect, layout: Layout, usedLast: Bool) {
            self.window = window
            self.space = space
            self.display = display
            self.frame = frame
            self.layout = layout
            self.usedLast = usedLast
        }
    }

    /// How long after quitting an app's spots are kept: a restart, not a reopen the next day.
    public static let lifetime: Double = 3600
    /// Windows that closed this long before their app quit closed as it quit.
    public static let closingWindow: Double = 5

    private var closed: [String: [(at: Double, spot: Spot)]] = [:]
    private var quits: [String: (at: Double, spots: [Spot])] = [:]

    public init() {}

    /// A tiled window of `app` closed. If the app quits soon after, its spot is kept.
    public mutating func closed(_ app: String, spot: Spot, at time: Double) {
        var list = closed[app, default: []].filter { time - $0.at < Self.closingWindow }
        list.append((time, spot))
        closed[app] = list
    }

    /// `app` quit: the windows that closed as it quit are where its next windows go.
    public mutating func quit(_ app: String, at time: Double) {
        let spots = (closed.removeValue(forKey: app) ?? []).filter { time - $0.at < Self.closingWindow }.map(\.spot)
        // The window you used last first: a restart that opens one window brings back that one.
        let ordered = spots.filter(\.usedLast) + spots.filter { !$0.usedLast }
        quits[app] = ordered.isEmpty ? nil : (time, ordered)
        quits = quits.filter { time - $0.value.at < Self.lifetime }
    }

    /// Where a new window of `app`, opening at `frame`, goes back to, if the app quit within the
    /// hour: the spot it opened at (apps mostly reopen windows where they were), else the window
    /// used last.
    public func spot(for app: String, frame: CGRect, now: Double) -> Spot? {
        guard let q = quits[app], now - q.at < Self.lifetime else { return nil }
        return q.spots.first { Self.close($0.frame, frame) } ?? q.spots.first
    }

    /// Every spot `app`'s next windows go back to, if it quit within the hour: `spot(for:)` picks
    /// one of these for a window by where it opened.
    public func spots(for app: String, now: Double) -> [Spot] {
        guard let q = quits[app], now - q.at < Self.lifetime else { return [] }
        return q.spots
    }

    /// Takes that spot, so the app's next window gets another one. `preferring`: the old window
    /// whose spot this one was already headed for (it may have moved since).
    public mutating func take(for app: String, frame: CGRect, now: Double, preferring old: WindowID? = nil) -> Spot? {
        guard var q = quits[app], now - q.at < Self.lifetime,
              let spot = q.spots.first(where: { $0.window == old }) ?? spot(for: app, frame: frame, now: now) else { return nil }
        q.spots.removeAll { $0.window == spot.window }
        quits[app] = q.spots.isEmpty ? nil : q
        return spot
    }

    /// The layout `spot` was in, with `id` where the old window was: `Layout.restore` then puts
    /// the new window beside the same windows, if they're still there.
    public static func layout(of spot: Spot, as id: WindowID) -> Layout {
        var layout = spot.layout
        _ = layout.replace(spot.window, with: id)
        return layout
    }

    public static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4 && abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }
}
