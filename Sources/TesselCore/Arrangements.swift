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

    /// These windows (by app) in this arrangement: every window in its slot, with the shares
    /// you gave them. nil unless the windows are exactly the arrangement's apps.
    public func layout(of windows: [WindowID], apps: [WindowID: String]) -> Layout? {
        var byApp: [String: [WindowID]] = [:]
        for id in windows {
            guard let a = apps[id] else { return nil }
            byApp[a, default: []].append(id)
        }
        var need: [String: Int] = [:]
        for slot in columns.flatMap(\.slots) { need[slot.app, default: 0] += 1 }
        guard need == byApp.mapValues(\.count) else { return nil }
        return Layout(columns: columns.map { stack in
            Column(windows: stack.slots.map { byApp[$0.app]![$0.n] }, weights: stack.weights, weight: stack.weight)
        })
    }

    /// Puts `newcomer` (a window of `app`, just arrived) into `layout` where this arrangement
    /// has it. The windows already there don't move: the newcomer goes beside or into the
    /// stack of the same windows it had before (`Layout.restore`), and only when everything
    /// then matches the arrangement exactly do the shares become the arrangement's too. The
    /// newcomer takes its app's last slot. nil when the arrangement is for other apps.
    public func place(_ newcomer: WindowID, app: String, in layout: Layout, apps: [WindowID: String]) -> Layout? {
        guard !layout.contains(newcomer) else { return nil }
        var all = apps
        all[newcomer] = app
        guard let saved = self.layout(of: layout.windows + [newcomer], apps: all) else { return nil }
        var result = layout
        guard result.restore(newcomer, from: saved) else { return nil }
        if result.columns.map(\.windows) == saved.columns.map(\.windows) { result.columns = saved.columns }
        return result
    }
}

/// The shape you gave four windows when one app's window had a column to itself, at full
/// height ("with four windows, Claude takes the left side"): how many windows each column
/// holds, the shares, and which column was that app's.
public struct AnchoredShape: Codable, Equatable, Sendable {
    /// Windows per column, left to right, e.g. [1, 3].
    public var stacks: [Int]
    /// Each column's share of the width, and each window's share of its column's height.
    public var widths: [Double]
    public var heights: [[Double]]
    /// The column the app's window has to itself.
    public var column: Int
    /// How long you've kept this shape, all told, and when last.
    public var dwell: Double
    public var lastSeen: Double

    /// The shape `a` gives `app`'s window, if it has a column to itself; nil if the app has
    /// no window there, or more than one.
    public init?(_ a: Arrangement, app: String, dwell: Double, at time: Double) {
        guard a.columns.flatMap(\.slots).filter({ $0.app == app }).count == 1,
              let column = a.columns.firstIndex(where: { $0.slots.count == 1 && $0.slots[0].app == app }) else { return nil }
        stacks = a.columns.map(\.slots.count)
        widths = a.columns.map(\.weight)
        heights = a.columns.map(\.weights)
        self.column = column
        self.dwell = dwell
        lastSeen = time
    }

    public func sameShape(as other: AnchoredShape) -> Bool { stacks == other.stacks && column == other.column }

    /// "left", "right" or "middle", for the quiet line.
    public var side: String { column == 0 ? "left" : column == stacks.count - 1 ? "right" : "middle" }

    /// `anchor` alone in its column, and `others` filling the other columns in their order.
    public func layout(anchor: WindowID, others: [WindowID]) -> Layout? {
        guard others.count == stacks.reduce(0, +) - 1, stacks.indices.contains(column), stacks[column] == 1,
              widths.count == stacks.count, heights.count == stacks.count else { return nil }
        var rest = others[...]
        var columns: [Column] = []
        for (c, n) in stacks.enumerated() {
            let ids = c == column ? [anchor] : Array(rest.prefix(n))
            if c != column { rest = rest.dropFirst(n) }
            let heights = self.heights[c].count == ids.count ? self.heights[c] : Array(repeating: 1.0 / Double(ids.count), count: ids.count)
            columns.append(Column(windows: ids, weights: heights, weight: widths[c]))
        }
        return Layout(columns: columns)
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
    /// For `arranged`: you made this arrangement (moved, sized or dragged windows into it),
    /// rather than letting one Tessel made stand. Missing in older logs.
    public var byYou: Bool?

    public static func arranged(_ a: Arrangement, on display: String, dwell: Double, byYou: Bool = false,
                                at time: Double) -> ArrangeEvent {
        ArrangeEvent(kind: .arranged, time: time.rounded(), display: display, arrangement: a, dwell: dwell.rounded(),
                     byYou: byYou ? true : nil)
    }

    public static func lone(_ app: String, shape: LoneShape, on display: String, at time: Double) -> ArrangeEvent {
        ArrangeEvent(kind: .lone, time: time.rounded(), display: display, app: app, shape: shape)
    }

    public static func forgot(_ key: String, at time: Double) -> ArrangeEvent {
        ArrangeEvent(kind: .forgot, time: time.rounded(), display: "", key: key)
    }
}

/// "Opens apps in your usual arrangement": the arrangements you made and kept, per display
/// and set of apps, the shapes you gave lone windows, per app, and the shape four windows
/// take around one app's window. Counting again: each arrangement keeps how long it stood,
/// older time counting for less, and the one that stood longest wins. A four-window shape is
/// the latest you made and kept.
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
    /// By `shapeKey(display:app:)`: the shape four windows take with this app's window among them.
    public private(set) var anchored: [String: AnchoredShape] = [:]

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

    public static func shapeKey(display: String, app: String) -> String { "shape|\(display)|\(app)" }

    /// How many windows a learned shape is for: the fourth window is where the grid starts.
    public static let anchoredWindows = 4

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
            if event.byYou == true { recordShape(a, on: event.display, dwell: dwell, at: event.time) }
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

    /// A four-window arrangement you made stood for `dwell` seconds. Each app whose window
    /// had a column to itself learns that shape (a different shape replaces the old one: the
    /// latest wins). An app whose window shared a column for as long as a lesson takes to
    /// learn unlearns its shape: you changed your mind.
    public mutating func recordShape(_ a: Arrangement, on display: String, dwell: Double, at time: Double) {
        let apps = a.columns.flatMap { $0.slots.map(\.app) }
        guard apps.count == Self.anchoredWindows else { return }
        for app in Set(apps) where apps.filter({ $0 == app }).count == 1 {
            let key = Self.shapeKey(display: display, app: app)
            if var shape = AnchoredShape(a, app: app, dwell: dwell, at: time) {
                if let old = anchored[key], old.sameShape(as: shape) { shape.dwell += old.dwell }
                anchored[key] = shape
            } else if dwell >= Self.minimumDwell {
                anchored[key] = nil
            }
        }
    }

    /// The shape for these four windows' apps on this display: one learned for an app with a
    /// single window among them, once kept long enough. When several have one, the one you
    /// kept most recently.
    public func anchoredShape(display: String, apps: [String]) -> (app: String, shape: AnchoredShape)? {
        guard apps.count == Self.anchoredWindows else { return nil }
        return Set(apps).filter { app in apps.filter { $0 == app }.count == 1 }
            .compactMap { app in anchored[Self.shapeKey(display: display, app: app)].map { (app: app, shape: $0) } }
            .filter { $0.shape.dwell >= Self.minimumDwell }
            .max { ($0.shape.lastSeen, $0.app) < ($1.shape.lastSeen, $1.app) }
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
        anchored[key] = nil
    }
}
