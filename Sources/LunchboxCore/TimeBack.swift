import Foundation

/// Something LunchboxWM did that you'd otherwise do by hand on a plain Mac (docs/worth-paying-for.md).
/// Each counts at a conservative number of seconds, kept here and nowhere else.
public enum TimeBackAction: String, Codable, CaseIterable, Sendable {
    /// A new window tiled into place.
    case tiled
    /// An app opened into its usual spot and share (or a lone window took the shape you gave it).
    case arranged
    /// A new window sent to the Workspace its app lives in.
    case sent
    /// A window put back where it was: its display came back (after waking, say), or LunchboxWM
    /// started again after a restart.
    case restored
    /// A jump to a window from Summon.
    case summoned
    /// You corrected what LunchboxWM did, or undid it.
    case corrected
    /// A display came back. Still counted, though no words use it since the trial-end screen
    /// went with the free trial: the windows that went back to it count as `restored`.
    case displayReturned

    /// Seconds each saves you (or costs you, for a correction).
    public var seconds: Int {
        switch self {
        case .tiled: 2
        case .arranged: 2
        case .sent: 3 // switch Workspace, find the window, move it
        case .restored: 2
        case .summoned: 1
        case .corrected: -3
        case .displayReturned: 0
        }
    }

    /// Counted in "windows placed".
    public var placesAWindow: Bool {
        switch self {
        case .tiled, .arranged, .sent, .restored: true
        case .summoned, .corrected, .displayReturned: false
        }
    }
}

/// The time LunchboxWM gives back: how many times it did each `TimeBackAction` on each day. It
/// counts the drags and moves you didn't make, nothing more ("time back", never
/// "productivity"), and every place that shows the number says how it was counted.
///
/// Only numbers and dates: no app names, no window titles, nothing that leaves the Mac.
public struct TimeBack: Codable, Equatable, Sendable {
    /// Days are kept this long, then pruned.
    public static let keptDays = 90

    /// Counts by day ("2026-10-17", in your time zone), then by action. An action this
    /// version doesn't know (written by a newer LunchboxWM) is kept and left out of tallies.
    public private(set) var days: [String: [String: Int]] = [:]

    public init() {}

    public var isEmpty: Bool { days.isEmpty }

    /// The day a moment falls on, as days are kept.
    public static func day(of date: Date, in calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// LunchboxWM did `action` (`times` times at once) at `date`.
    public mutating func count(_ action: TimeBackAction, times: Int = 1, at date: Date, in calendar: Calendar = .current) {
        guard times > 0 else { return }
        days[Self.day(of: date, in: calendar), default: [:]][action.rawValue, default: 0] += times
    }

    /// Adds everything another count holds (what was counted while this one was read from disk).
    public mutating func add(_ other: TimeBack) {
        for (day, counts) in other.days {
            for (name, n) in counts { days[day, default: [:]][name, default: 0] += n }
        }
    }

    /// Everything counted from the day of `start` through the day of `end`.
    public func tally(from start: Date, through end: Date, in calendar: Calendar = .current) -> Tally {
        let first = Self.day(of: start, in: calendar), last = Self.day(of: end, in: calendar)
        var tally = Tally()
        for (day, counts) in days where day >= first && day <= last {
            for (name, n) in counts {
                if let action = TimeBackAction(rawValue: name) { tally.add(action, n) }
            }
        }
        return tally
    }

    /// This week: today and the six days before it.
    public func week(endingAt now: Date, in calendar: Calendar = .current) -> Tally {
        tally(from: calendar.date(byAdding: .day, value: -6, to: now) ?? now, through: now, in: calendar)
    }

    /// Drops days older than `keptDays`, and days more than a day ahead (a clock that was
    /// set forward and back again).
    public mutating func prune(now: Date, in calendar: Calendar = .current) {
        let oldest = Self.day(of: calendar.date(byAdding: .day, value: -(Self.keptDays - 1), to: now) ?? now, in: calendar)
        let newest = Self.day(of: calendar.date(byAdding: .day, value: 1, to: now) ?? now, in: calendar)
        days = days.filter { $0.key >= oldest && $0.key <= newest }
    }

    /// What was counted over some days.
    public struct Tally: Equatable, Sendable {
        public private(set) var counts: [TimeBackAction: Int] = [:]

        public init() {}

        public subscript(_ action: TimeBackAction) -> Int { counts[action, default: 0] }

        mutating func add(_ action: TimeBackAction, _ n: Int) {
            counts[action, default: 0] += n
        }

        public var isEmpty: Bool { counts.values.allSatisfy { $0 == 0 } }

        /// Seconds back, after corrections (below zero if LunchboxWM cost you time).
        public var seconds: Int { counts.reduce(0) { $0 + $1.key.seconds * $1.value } }

        /// Whole minutes back, rounded down, never below zero.
        public var minutes: Int { max(0, seconds / 60) }

        /// Windows LunchboxWM put in place for you: tiled, in their usual spot, sent to their
        /// Workspace, or put back.
        public var windowsPlaced: Int { counts.reduce(0) { $0 + ($1.key.placesAWindow ? $1.value : 0) } }
    }
}

/// Where `TimeBack` is kept: one small JSON file in LunchboxWM's own folder, under the same rules
/// as the event logs. The file is yours alone (0600), and the folder (0700) stays out of Time
/// Machine and other backups.
///
/// Not thread-safe: the app calls it from one serial queue, off the main thread.
public struct TimeBackFile {
    public let url: URL

    public init(folder: URL, name: String = "timeback") {
        url = folder.appendingPathComponent("\(name).json")
    }

    /// What's kept, or nothing when there's no file or it can't be read.
    public func read() -> TimeBack {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TimeBack.self, from: $0) } ?? TimeBack()
    }

    /// Replaces the file in one step, so a crash mid-write never leaves half of it.
    public func write(_ timeBack: TimeBack) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(timeBack)
        let folder = url.deletingLastPathComponent()
        try PrivateFolder.make(folder)
        let fm = FileManager.default
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? fm.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func erase() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The words wherever the time back shows: the menu. Never a
/// notification or a popup (Etiquette).
public enum TimeBackWords {
    /// "23 minutes back", "under a minute back", or "no time back yet".
    public static func back(_ tally: TimeBack.Tally) -> String {
        if tally.minutes >= 1 { return "\(count(tally.minutes, "minute")) back" }
        return tally.seconds > 0 ? "under a minute back" : "no time back yet"
    }

    /// The menu: "This week: 23 minutes back · 412 windows placed".
    public static func menuLine(_ week: TimeBack.Tally) -> String {
        "This week: \(back(week)) · \(count(week.windowsPlaced, "window")) placed"
    }

    /// How it's counted, in two short lines for a menu, made from the seconds each action
    /// counts at (so it can't drift from them).
    public static var howCounted: [String] {
        let window = TimeBackAction.tiled.seconds, sent = TimeBackAction.sent.seconds
        return ["Counted at \(window) s a window placed, \(sent) s one sent to its Workspace,",
                "\(TimeBackAction.summoned.seconds) s a Summon jump, and \(signed(TimeBackAction.corrected.seconds)) s a correction or undo."]
    }

    /// Each count and what it's worth: "380 new windows tiled × 2 s".
    public static func breakdown(_ tally: TimeBack.Tally) -> [String] {
        let rows: [(TimeBackAction, String, String)] = [
            (.tiled, "new window tiled", "new windows tiled"),
            (.arranged, "app in its usual spot", "apps in their usual spot"),
            (.sent, "window sent to its Workspace", "windows sent to their Workspace"),
            (.restored, "window put back", "windows put back"),
            (.summoned, "Summon jump", "Summon jumps"),
            (.corrected, "correction or undo", "corrections and undos"),
        ]
        return rows.compactMap { action, one, many in
            let n = tally[action]
            guard n > 0 else { return nil }
            return "\(n.formatted()) \(n == 1 ? one : many) × \(signed(action.seconds)) s"
        }
    }

    // MARK: Words

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    /// "2", or "−3" with a real minus sign.
    static func signed(_ n: Int) -> String {
        n < 0 ? "\u{2212}\(-n)" : "\(n)"
    }
}
