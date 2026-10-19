import CoreGraphics
import Foundation

/// The support summary Settings › Copy Diagnostics puts on the clipboard, for someone to paste
/// into an email. It's made of plain facts that can't hold anything private: a window is its
/// app's bundle ID and what Tessel made of it, never its title; the license is only whether
/// there is one; and every log line goes through `scrub` first.
public struct SupportSummary: Sendable {
    public struct Screen: Sendable {
        public var name: String
        /// Top-left-origin points, like the rest of Tessel.
        public var frame: CGRect
        public var visible: CGRect
        public var scale: Double
        public var isMain: Bool
        /// Tessel tiles on it (Use All Displays, or the main display).
        public var tiled: Bool

        public init(name: String, frame: CGRect, visible: CGRect, scale: Double, isMain: Bool, tiled: Bool) {
            self.name = name
            self.frame = frame
            self.visible = visible
            self.scale = scale
            self.isMain = isMain
            self.tiled = tiled
        }
    }

    public struct Window: Sendable {
        public var id: UInt32
        /// The app's bundle ID.
        public var app: String
        /// How Tessel handles it now: "tiled", "floats", "minimized"…
        public var state: String
        /// What the window classifier made of it (it runs while learning is on).
        public var kind: WindowBehavior?
        /// The size limits Tessel learned for it.
        public var limits: SizeLimits?
        public var resizable: Bool

        public init(id: UInt32, app: String, state: String, kind: WindowBehavior? = nil, limits: SizeLimits? = nil, resizable: Bool = true) {
            self.id = id
            self.app = app
            self.state = state
            self.kind = kind
            self.limits = limits
            self.resizable = resizable
        }
    }

    /// One display's tiles in one Workspace.
    public struct Tiles: Sendable {
        public var display: String
        public var columns: [[Window]]
        /// Focus is on there.
        public var focus: Bool

        public init(display: String, columns: [[Window]], focus: Bool = false) {
            self.display = display
            self.columns = columns
            self.focus = focus
        }
    }

    public struct Workspace: Sendable {
        /// From 1.
        public var number: Int
        public var tiles: [Tiles]

        public init(number: Int, tiles: [Tiles]) {
            self.number = number
            self.tiles = tiles
        }
    }

    /// "Tessel 1.0 (52), release build".
    public var app: String
    /// "macOS 15.7.1 (24G231), Mac16,10".
    public var system: String
    /// "licensed", "free trial, 5 days left"…
    public var license: String
    /// Short "name: value" facts, like "tiling: on".
    public var settings: [String]
    public var screens: [Screen]
    /// From 1.
    public var currentWorkspace: Int
    public var workspaces: [Workspace]
    /// Windows Tessel knows that aren't in a tile: floating, minimized, waiting.
    public var untiled: [Window]
    /// Errors from Tessel's log in the last day, oldest first, already through `scrub`.
    public var errors: [String]
    public var made: Date

    public init(app: String, system: String, license: String, settings: [String], screens: [Screen],
                currentWorkspace: Int, workspaces: [Workspace], untiled: [Window], errors: [String] = [], made: Date = Date()) {
        self.app = app
        self.system = system
        self.license = license
        self.settings = settings
        self.screens = screens
        self.currentWorkspace = currentWorkspace
        self.workspaces = workspaces
        self.untiled = untiled
        self.errors = errors
        self.made = made
    }

    /// The summary as plain text, narrow enough to read in an email on a phone.
    public var text: String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm ZZZZZ"
        var out = ["Tessel diagnostics, \(stamp.string(from: made))", app, system, "License: \(license)"]
        out += settings.map { "  \($0)" }

        out += ["", "Displays (\(screens.count))"]
        for s in screens {
            var line = "- \(s.name)\(s.isMain ? " (main)" : ""): \(Self.size(s.frame.size)) at \(Self.point(s.frame.origin)), @\(Self.number(s.scale))x, usable \(Self.size(s.visible.size)) at \(Self.point(s.visible.origin))"
            if !s.tiled { line += ", not tiled" }
            out.append(line)
        }

        out += ["", "Workspaces: \(workspaces.count), current \(currentWorkspace)"]
        for w in workspaces {
            let name = "Workspace \(w.number)\(w.number == currentWorkspace ? " (current)" : "")"
            let shown = w.tiles.filter { !$0.columns.isEmpty }
            guard !shown.isEmpty else { out.append("\(name): no windows"); continue }
            out.append(name)
            for t in shown {
                out.append("  \(t.display)\(t.focus ? " (Focus on)" : "")")
                for (i, column) in t.columns.enumerated() {
                    let head = "    column \(i + 1): "
                    for (j, window) in column.enumerated() {
                        out.append((j == 0 ? head : String(repeating: " ", count: head.count)) + Self.describe(window))
                    }
                }
            }
        }

        out += ["", "Not in a tile (\(untiled.count))"]
        out += untiled.isEmpty ? ["  none"] : untiled.map { "- \(Self.describe($0))" }

        out += ["", "Errors in the last day (\(errors.count))"]
        out += errors.isEmpty ? ["  none"] : errors.map { "- \($0)" }
        return out.joined(separator: "\n") + "\n"
    }

    /// "1234 com.apple.Safari: tiled, document, min 500×400".
    static func describe(_ w: Window) -> String {
        var bits = [w.state]
        if let kind = w.kind { bits.append(kind.rawValue) }
        if !w.resizable { bits.append("fixed size") }
        if let limits = w.limits, !limits.isEmpty { bits.append(limitsText(limits)) }
        return "\(w.id) \(w.app): \(bits.joined(separator: ", "))"
    }

    /// "min 500×400, max 1200×–": a dash for a side with no limit.
    public static func limitsText(_ l: SizeLimits) -> String {
        func side(_ v: CGFloat?) -> String { v.map { number(Double($0)) } ?? "–" }
        if l.minWidth != nil, l.minWidth == l.maxWidth, l.minHeight != nil, l.minHeight == l.maxHeight {
            return "fixed \(side(l.minWidth))×\(side(l.minHeight))"
        }
        var parts: [String] = []
        if l.minWidth != nil || l.minHeight != nil { parts.append("min \(side(l.minWidth))×\(side(l.minHeight))") }
        if l.maxWidth != nil || l.maxHeight != nil { parts.append("max \(side(l.maxWidth))×\(side(l.maxHeight))") }
        return parts.joined(separator: ", ")
    }

    /// A log line made safe to share: anything in quotes (NSError puts file and folder names in
    /// them), paths (to the end of the clause, since they can have spaces), links, email addresses
    /// and anything shaped like a license key become placeholders, and it's cut to a sensible length.
    public static func scrub(_ line: String, home: String = NSHomeDirectory()) -> String {
        var s = line
        if home.count > 1 { s = s.replacingOccurrences(of: home, with: "~") }
        let rules: [(String, String)] = [
            ("[A-Za-z][A-Za-z0-9+.-]*://\\S+", "<link>"),
            ("\(License.prefix)[A-Za-z0-9._~+/=-]*", "<license>"),
            ("[^\\s@<>\"“”]+@[^\\s@<>\"“”]+\\.[A-Za-z]{2,}", "<email>"),
            ("“[^”]*”", "“…”"),
            ("‘[^’]*’", "‘…’"),
            ("\"[^\"]*\"", "\"…\""),
            // A path runs to the next delimiter, spaces and all ("Application Support").
            ("(?<![\\w.:])~?/[^\\s/\"“”'‘’,;()\\[\\]{}][^\"“”'‘’,;()\\[\\]{}\\n]*", "<path>"),
        ]
        for (pattern, replacement) in rules {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s.count > 240 ? String(s.prefix(239)) + "…" : s
    }

    private static func number(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func size(_ s: CGSize) -> String { "\(number(Double(s.width)))×\(number(Double(s.height)))" }

    private static func point(_ p: CGPoint) -> String { "\(number(Double(p.x))),\(number(Double(p.y)))" }
}
