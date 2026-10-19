import Foundation

/// "Sends new windows to the Workspace they belong in": where you keep each app.
///
/// An app gets a home when you move one of its windows to a Workspace yourself (⌘⇧ and the
/// Workspace's number), and Lunchbox trusts that home once the app's windows have spent ten
/// minutes there, all told, and nine tenths of their time since the move. Moving one of its
/// windows somewhere else starts over from there. Hiding a window (to the last Workspace) is
/// putting it away, not a home, so it doesn't count as a move.
public struct WorkspaceMemory: Codable, Equatable, Sendable {
    public struct Home: Codable, Equatable, Sendable {
        public var space: Int
        /// When you moved it there.
        public var since: Double
        /// Seconds the app's windows have spent in each Workspace since then.
        public var lived: [Double]
    }

    public private(set) var homes: [String: Home] = [:]

    /// Window time in its home before Lunchbox trusts it.
    public static let settleSeconds = 600.0
    /// The share of the app's window time that must be in its home.
    public static let share = 0.9

    public init() {}

    /// You moved one of the app's windows to `space`.
    public mutating func moved(_ app: String, to space: Int, at time: Double, spaces: Int = 3) {
        guard (0..<spaces).contains(space) else { return }
        if let home = homes[app], home.space == space { return } // already its home: keep the time it has
        homes[app] = Home(space: space, since: time, lived: Array(repeating: 0, count: spaces))
    }

    /// The app's windows spent `seconds` in `space`.
    public mutating func lived(_ app: String, in space: Int, seconds: Double) {
        guard var home = homes[app], home.lived.indices.contains(space), seconds > 0 else { return }
        home.lived[space] += seconds
        homes[app] = home
    }

    /// The Workspace the app lives in, once Lunchbox is sure of it.
    public func home(of app: String) -> Int? {
        guard let home = homes[app] else { return nil }
        let there = home.lived[home.space]
        let total = home.lived.reduce(0, +)
        guard there >= Self.settleSeconds, total > 0, there / total >= Self.share else { return nil }
        return home.space
    }

    public mutating func forget(_ app: String) {
        homes[app] = nil
    }

    /// Where a new window of `app` opens: its home, or nil for "here, as always".
    /// - requested: Summon or the Dock opened it; what you open from Lunchbox always comes to you.
    /// - current: the Workspace you're in.
    /// - appSpaces: the Workspaces the app's other windows are in right now.
    /// - allowed: false once you've undone this twice in a row (`UndoLedger`).
    public func placement(for app: String, requested: Bool, current: Int, appSpaces: Set<Int>, allowed: Bool) -> Int? {
        guard !requested, allowed, let home = home(of: app), home != current else { return nil }
        // A window of it here (or anywhere but its home) means it's not that simple today.
        guard appSpaces.isSubset(of: [home]) else { return nil }
        return home
    }

    /// A line in `workspace.jsonl`, which keeps the story (what the snapshot doesn't say).
    public struct Event: LoggedEvent, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// You moved a window of `app` to `space`.
            case moved
            /// Lunchbox opened a new window of `app` in `space`, its home.
            case placed
            /// You undid that.
            case undone
            /// You forgot what Lunchbox knew about `app`.
            case forgot
        }

        public var kind: Kind
        public var time: Double
        public var app: String
        public var space: Int?

        public init(_ kind: Kind, app: String, space: Int? = nil, at time: Double) {
            self.kind = kind
            self.app = app
            self.space = space
            self.time = time.rounded()
        }
    }
}
