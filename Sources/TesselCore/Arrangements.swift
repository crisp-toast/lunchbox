import CoreGraphics
import Foundation

/// One window's place in an arrangement: the `n`th window of an app, counting left to
/// right and top to bottom.
public struct Slot: Codable, Hashable, Sendable {
    public var app: String
    public var n: Int

    public init(app: String, n: Int) {
        self.app = app
        self.n = n
    }
}

/// How a set of apps was arranged on a display, without window numbers (which die with the
/// window): which app's window sits in which column and stack, and the shares you gave them.
public struct Arrangement: Codable, Equatable, Sendable {
    public struct Stack: Codable, Equatable, Sendable {
        public var slots: [Slot]
        /// Each window's share of the column's height, summing to 1.
        public var weights: [Double]
        /// The column's share of the width.
        public var weight: Double
    }

    public var columns: [Stack]

    /// The arrangement of a layout of two or more windows, given each window's app. nil for a
    /// lone window, or when a window has no app (a placeholder).
    public init?(_ layout: Layout, apps: [WindowID: String]) {
        guard layout.windowCount >= 2 else { return nil }
        let widthTotal = layout.columns.map(\.weight).reduce(0, +)
        guard widthTotal > 0 else { return nil }
        var counts: [String: Int] = [:]
        var columns: [Stack] = []
        for column in layout.columns {
            var slots: [Slot] = []
            for id in column.windows {
                guard let app = apps[id] else { return nil }
                slots.append(Slot(app: app, n: counts[app, default: 0]))
                counts[app, default: 0] += 1
            }
            let total = column.weights.reduce(0, +)
            guard total > 0 else { return nil }
            columns.append(Stack(slots: slots, weights: column.weights.map { $0 / total }, weight: column.weight / widthTotal))
        }
        self.columns = columns
    }

    /// One entry per window, sorted: what an arrangement is remembered by.
    public var apps: [String] { columns.flatMap { $0.slots.map(\.app) }.sorted() }

    /// The same columns and stacks, whatever the shares.
    public func sameShape(as other: Arrangement) -> Bool { columns.map(\.slots) == other.columns.map(\.slots) }

    /// Puts `newcomer` (a window of `app`, just arrived) into `layout` where this arrangement
    /// has it. The windows already there don't move: the newcomer goes beside or into the
    /// stack of the same windows it had before (`Layout.restore`), and only when everything
    /// then matches the arrangement exactly do the shares become the arrangement's too. The
    /// newcomer takes its app's last slot. nil when the arrangement is for other apps.
    public func place(_ newcomer: WindowID, app: String, in layout: Layout, apps: [WindowID: String]) -> Layout? {
        var byApp: [String: [WindowID]] = [:]
        for id in layout.windows {
            guard let a = apps[id] else { return nil }
            byApp[a, default: []].append(id)
        }
        byApp[app, default: []].append(newcomer)
        var need: [String: Int] = [:]
        for slot in columns.flatMap(\.slots) { need[slot.app, default: 0] += 1 }
        guard need == byApp.mapValues(\.count), !layout.contains(newcomer) else { return nil }
        let saved = Layout(columns: columns.map { stack in
            Column(windows: stack.slots.map { byApp[$0.app]![$0.n] }, weights: stack.weights, weight: stack.weight)
        })
        var result = layout
        guard result.restore(newcomer, from: saved) else { return nil }
        if result.columns.map(\.windows) == saved.columns.map(\.windows) { result.columns = saved.columns }
        return result
    }
}

/// The shape you gave a lone (centered) window: `Layout.singleScale` and `singleHeight`.
public struct LoneShape: Codable, Equatable, Sendable {
    public var scale: Double
    public var height: Double?

    public init(scale: Double, height: Double?) {
        self.scale = scale
        self.height = height
    }
}

/// A line in `arrange.jsonl`.
public struct ArrangeEvent: LoggedEvent, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// An arrangement you made (or let stand) stayed for `dwell` seconds.
        case arranged
        /// You gave a lone window of `app` a shape of its own.
        case lone
        /// You forgot this lesson.
        case forgot
    }

    public var kind: Kind
    public var time: Double
    /// The display's usable size in points ("1920x1050"): what it's remembered by.
    public var display: String
    public var arrangement: Arrangement?
    public var dwell: Double?
    public var app: String?
    public var shape: LoneShape?
    /// For `forgot`: the lesson's key.
    public var key: String?

    public static func arranged(_ a: Arrangement, on display: String, dwell: Double, at time: Double) -> ArrangeEvent {
        ArrangeEvent(kind: .arranged, time: time.rounded(), display: display, arrangement: a, dwell: dwell.rounded())
    }

    public static func lone(_ app: String, shape: LoneShape, on display: String, at time: Double) -> ArrangeEvent {
        ArrangeEvent(kind: .lone, time: time.rounded(), display: display, app: app, shape: shape)
    }

    public static func forgot(_ key: String, at time: Double) -> ArrangeEvent {
        ArrangeEvent(kind: .forgot, time: time.rounded(), display: "", key: key)
    }
}

/// "Opens apps in your usual arrangement": the arrangements you made and kept, per display
/// and set of apps, and the shapes you gave lone windows, per app. Counting again: each
/// arrangement keeps how long it stood, older time counting for less, and the one that
/// stood longest wins.
public struct ArrangementMemory: Sendable {
    public struct Variant: Codable, Equatable, Sendable {
        public var arrangement: Arrangement
        public var dwell: Double
        public var lastSeen: Double
    }

    /// By `key(display:apps:)`, at most three each.
    public private(set) var variants: [String: [Variant]] = [:]
    /// By `loneKey(display:app:)`.
    public private(set) var lone: [String: LoneShape] = [:]

    /// Time an arrangement stood counts half after this long.
    public var halfLife = 30 * 86_400.0
    /// An arrangement is only used once it has stood this long, all told.
    public static let minimumDwell = 30.0
    static let maxVariants = 3
    static let maxContexts = 500

    public init() {}

    public static func key(display: String, apps: [String]) -> String {
        "arrange|\(display)|" + apps.sorted().joined(separator: ",")
    }

    public static func loneKey(display: String, app: String) -> String { "lone|\(display)|\(app)" }

    public static func replay(_ events: [ArrangeEvent], now: Double) -> ArrangementMemory {
        var memory = ArrangementMemory()
        for e in events.sorted(by: { $0.time < $1.time }) { memory.learn(e, now: now) }
        return memory
    }

    public mutating func learn(_ event: ArrangeEvent, now: Double) {
        switch event.kind {
        case .arranged:
            guard let a = event.arrangement, let dwell = event.dwell else { return }
            record(a, on: event.display, dwell: dwell, at: event.time)
        case .lone:
            guard let app = event.app, let shape = event.shape else { return }
            lone[Self.loneKey(display: event.display, app: app)] = shape
        case .forgot:
            guard let key = event.key else { return }
            forget(key)
        }
    }

    private func decayed(_ v: Variant, at now: Double) -> Double {
        v.dwell * pow(0.5, max(0, now - v.lastSeen) / halfLife)
    }

    /// An arrangement stood for `dwell` more seconds.
    public mutating func record(_ a: Arrangement, on display: String, dwell: Double, at time: Double) {
        let key = Self.key(display: display, apps: a.apps)
        var list = variants[key] ?? []
        if let i = list.firstIndex(where: { $0.arrangement.sameShape(as: a) }) {
            list[i].dwell = decayed(list[i], at: time) + dwell
            list[i].arrangement = a // the shares as you left them last
            list[i].lastSeen = time
        } else {
            list.append(Variant(arrangement: a, dwell: dwell, lastSeen: time))
        }
        list.sort { decayed($0, at: time) > decayed($1, at: time) }
        variants[key] = Array(list.prefix(Self.maxVariants))
        if variants.count > Self.maxContexts,
           let oldest = variants.min(by: { ($0.value.map(\.lastSeen).max() ?? 0) < ($1.value.map(\.lastSeen).max() ?? 0) })?.key {
            variants[oldest] = nil
        }
    }

    public mutating func recordLone(_ app: String, shape: LoneShape, on display: String) {
        lone[Self.loneKey(display: display, app: app)] = shape
    }

    /// The arrangement for these apps on this display, if one has stood long enough.
    public func arrangement(display: String, apps: [String], now: Double) -> Arrangement? {
        guard let best = variants[Self.key(display: display, apps: apps)]?
            .max(by: { decayed($0, at: now) < decayed($1, at: now) }),
              best.dwell >= Self.minimumDwell else { return nil }
        return best.arrangement
    }

    public func loneShape(of app: String, on display: String) -> LoneShape? {
        lone[Self.loneKey(display: display, app: app)]
    }

    public mutating func forget(_ key: String) {
        variants[key] = nil
        lone[key] = nil
    }
}
