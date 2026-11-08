import Foundation

/// How you've used each window lately, for Sort My Windows: how long it had focus while you were
/// at the Mac, and which windows you go back and forth between. Both fade by half every
/// `halfLife`, so an hour in Xcode this morning counts for less than ten minutes just now. Kept
/// in memory only, and a window's history goes when it closes.
public struct WindowUsage: Sendable {
    public static let halfLife: TimeInterval = 30 * 60

    /// Two windows, in either order.
    public struct Pair: Hashable, Sendable {
        public let a: WindowID
        public let b: WindowID

        public init(_ x: WindowID, _ y: WindowID) {
            (a, b) = x < y ? (x, y) : (y, x)
        }

        public func contains(_ id: WindowID) -> Bool { a == id || b == id }
    }

    /// An amount as of `at`, fading from then on.
    private struct Fading: Sendable {
        var amount: Double
        var at: TimeInterval

        func value(at now: TimeInterval) -> Double {
            amount * pow(0.5, max(0, now - at) / WindowUsage.halfLife)
        }
    }

    private var focus: [WindowID: Fading] = [:]
    private var switches: [Pair: Fading] = [:]

    public init() {}

    /// `id` had focus for `time` seconds more, ending `now` (seconds on any clock that keeps going).
    public mutating func used(_ id: WindowID, for time: Double, at now: TimeInterval) {
        guard time > 0 else { return }
        focus[id] = Fading(amount: seconds(id, at: now) + time, at: now)
    }

    /// You went from one window to another, and stayed a moment.
    public mutating func switched(from: WindowID, to: WindowID, at now: TimeInterval) {
        guard from != to else { return }
        let pair = Pair(from, to)
        switches[pair] = Fading(amount: (switches[pair]?.value(at: now) ?? 0) + 1, at: now)
        // Ties that faded to nothing go, so this stays small.
        if switches.count > 400 { switches = switches.filter { $0.value.value(at: now) >= 0.05 } }
    }

    /// How long `id` has had focus lately, counting the older the less.
    public func seconds(_ id: WindowID, at now: TimeInterval) -> Double {
        focus[id]?.value(at: now) ?? 0
    }

    /// How often you've gone between each two windows lately, the older the less: one trip there
    /// and back is two.
    public func together(at now: TimeInterval) -> [Pair: Double] {
        switches.compactMapValues { f in
            let v = f.value(at: now)
            return v >= 0.05 ? v : nil
        }
    }

    /// A window that closed.
    public mutating func forget(_ id: WindowID) {
        focus[id] = nil
        switches = switches.filter { !$0.key.contains(id) }
    }
}
