import CoreGraphics
import Foundation

/// Whether a window takes a tile or floats over the tiles.
public enum FloatChoice: String, Codable, Sendable {
    case tile, float

    public var opposite: FloatChoice { self == .tile ? .float : .tile }
}

/// What a window's title says about it, without keeping the title: Tessel never writes
/// a title down, only which of these it was.
public enum TitleKind: String, Codable, Sendable {
    /// No title at all (palettes, pop-overs, splash screens).
    case empty
    /// Just the app's name (a main window, or a lone utility window).
    case app
    /// Names a utility window: settings, an inspector, a download list, Picture in Picture.
    case utility
    /// Anything else, usually a document, a page or a folder.
    case document

    /// Words that name utility windows. English only for now.
    static let utilityWords: Set<String> = [
        "settings", "preferences", "inspector", "info", "about", "palette", "downloads", "progress",
        "picture in picture", "mini player", "miniplayer", "colors", "fonts", "activity", "welcome",
        "sign in", "log in", "login", "update", "find", "properties", "toolbox", "tools", "library",
    ]

    /// Every word of `text`, and every run of two or three words.
    static func phrases(in text: String) -> Set<String> {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var out = Set(words)
        for n in 2...3 where words.count >= n {
            for i in 0...(words.count - n) { out.insert(words[i..<(i + n)].joined(separator: " ")) }
        }
        return out
    }

    public init(title: String?, appName: String?) {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty {
            self = .empty
        } else if let app = appName?.lowercased(), !app.isEmpty, t == app {
            self = .app
        } else if !Self.utilityWords.isDisjoint(with: Self.phrases(in: t)) {
            self = .utility
        } else {
            self = .document
        }
    }
}

/// The title-bar buttons a window has.
public struct WindowButtons: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let close = WindowButtons(rawValue: 1)
    public static let minimize = WindowButtons(rawValue: 2)
    public static let zoom = WindowButtons(rawValue: 4)
    public static let fullScreen = WindowButtons(rawValue: 8)
}

/// What Tessel can tell about a window from Accessibility the moment it shows up:
/// enough to recognize the same kind of window next time, and nothing personal.
public struct FloatFeatures: Codable, Equatable, Sendable {
    /// The app's bundle ID.
    public var app: String
    /// The window's Accessibility subrole (AXStandardWindow for a normal window).
    public var subrole: String?
    public var resizable: Bool
    public var buttons: WindowButtons
    /// Size in points when it appeared.
    public var width: Int
    public var height: Int
    /// Its area as a share of the usable area of its display.
    public var screenShare: Double
    public var title: TitleKind
    /// It has a native tab bar.
    public var tabs: Bool
    /// It wouldn't take the size of its tile (macOS has no Accessibility attribute for a
    /// window's minimum or maximum size, so Tessel finds out when it asks). Only known
    /// once Tessel has tiled it, so it's logged for later models but not in `signature`.
    public var sizeLimited: Bool

    public init(app: String, subrole: String?, resizable: Bool, buttons: WindowButtons, size: CGSize,
                screenShare: Double, title: TitleKind, tabs: Bool = false, sizeLimited: Bool = false) {
        self.app = app
        self.subrole = subrole
        self.resizable = resizable
        self.buttons = buttons
        self.width = Int(size.width.rounded())
        self.height = Int(size.height.rounded())
        self.screenShare = (screenShare * 1000).rounded() / 1000
        self.title = title
        self.tabs = tabs
        self.sizeLimited = sizeLimited
    }

    /// The kind of window, from what the window classifier reads (`WindowTraits`).
    public init(_ t: WindowTraits) {
        self.init(app: t.app, subrole: t.subrole, resizable: t.resizable, buttons: t.buttons,
                  size: CGSize(width: t.width, height: t.height), screenShare: t.screenShare,
                  title: TitleKind(title: t.title, appName: t.appName), tabs: t.hasTabs)
    }

    public var standard: Bool { subrole == "AXStandardWindow" }

    /// A full document window: standard, every title-bar button, not small, titled like a
    /// document or the app. Floating one of these is often a one-off, so it takes two
    /// corrections before the next one floats; a small or tool-like window takes one.
    public var looksLikeDocument: Bool {
        standard && buttons.isSuperset(of: [.close, .minimize, .zoom]) && sizeClass != "s"
            && (title == .document || title == .app)
    }

    /// Small, medium or large next to its screen.
    public var sizeClass: String {
        screenShare < 0.12 ? "s" : screenShare < 0.4 ? "m" : "l"
    }

    /// The kind of window in a few words, for the list of what Tessel learned: "small tool windows".
    public var kindInWords: String {
        let size = ["s": "small", "m": "medium", "l": "large"][sizeClass] ?? ""
        guard standard else { return "\(size) panels" }
        switch title {
        case .utility: return "\(size) tool windows"
        case .document: return "\(size) document windows"
        case .app: return "\(size) main windows"
        case .empty: return "\(size) untitled windows"
        }
    }

    /// Windows with the same signature are the same kind of window: what you teach Tessel
    /// about one applies to the rest. Coarse on purpose, so a lesson carries over.
    public var signature: String {
        "\(app)|\(standard ? "std" : subrole ?? "-")|\(buttons.rawValue)|\(sizeClass)|\(title.rawValue)"
    }
}

/// Where a choice came from.
public enum FloatSource: String, Codable, Sendable {
    /// Tessel's built-in rules (standard windows tile; dialogs and a few apps float).
    case rule
    /// What you taught it.
    case learned
    /// You chose it for this very window.
    case you
}

/// How you told Tessel it got a window wrong.
public enum FloatGesture: String, Codable, Sendable {
    /// The Float/Tile command.
    case toggle
    /// You dragged a tiled window out of its tile twice in a row: it stays where you put it.
    case dragOut
}

/// One line in the log Tessel learns floating from.
public struct FloatEvent: LoggedEvent, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// You floated a tiled window, or tiled a floating one.
        case corrected
        /// A window closed. How long it lived says whether its choice was right.
        case closed
    }

    public var kind: Kind
    public var time: Double
    public var features: FloatFeatures
    /// For `corrected`, what you wanted; for `closed`, what the window was when it closed.
    public var choice: FloatChoice
    /// For `closed`: who made the choice it closed with.
    public var source: FloatSource?
    /// For `closed`: seconds it was open.
    public var lifetime: Double?
    /// For `corrected`: how you said so.
    public var gesture: FloatGesture?

    public static func corrected(_ features: FloatFeatures, to choice: FloatChoice, by gesture: FloatGesture,
                                 at time: Double) -> FloatEvent {
        FloatEvent(kind: .corrected, time: tenths(time), features: features, choice: choice, gesture: gesture)
    }

    public static func closed(_ features: FloatFeatures, as choice: FloatChoice, source: FloatSource,
                              lifetime: Double, at time: Double) -> FloatEvent {
        FloatEvent(kind: .closed, time: tenths(time), features: features, choice: choice, source: source,
                   lifetime: tenths(lifetime))
    }

    /// Times are kept to a tenth of a second: plenty to learn from, no more.
    static func tenths(_ seconds: Double) -> Double { (seconds * 10).rounded() / 10 }
}

/// What Tessel does with a window it just saw.
public struct FloatDecision: Codable, Equatable, Sendable {
    public var choice: FloatChoice
    public var source: FloatSource
    /// How sure it is the window should float, 0 to 1.
    public var floatProbability: Double

    public init(choice: FloatChoice, source: FloatSource, floatProbability: Double) {
        self.choice = choice
        self.source = source
        self.floatProbability = floatProbability
    }
}

/// Learns which windows you want floating, from your corrections. Counting statistics:
/// how much evidence there is that each kind of window (`FloatFeatures.signature`), and
/// each app, should float or tile, with older evidence counting for less.
///
/// It fails safe. With nothing learned it does exactly what the rules say. It only goes
/// against the rules in the direction of your latest correction of that kind of window (or,
/// failing that, of that app), so hints alone never move a window and it never undoes what
/// you last told it. Windows you simply left as Tessel placed them don't count against a
/// correction: that's not you saying so, and someone who finds the Float command after a
/// year of tiling shouldn't have to say it ten times.
public struct FloatClassifier: Sendable {
    public struct Evidence: Codable, Equatable, Sendable {
        public var float = 0.0
        public var tile = 0.0
        /// The way you corrected it last, and when.
        public var lastCorrection: FloatChoice?
        public var lastCorrectionTime = 0.0
        /// A window of this kind you corrected, to put the lesson into words.
        public var example: FloatFeatures?

        public var total: Double { float + tile }

        mutating func add(_ weight: Double, to choice: FloatChoice) {
            if choice == .float { float += weight } else { tile += weight }
        }
    }

    public private(set) var bySignature: [String: Evidence] = [:]
    public private(set) var byApp: [String: Evidence] = [:]

    /// Evidence counts half as much after this long: a lesson you never use again fades
    /// after a couple of months, one you live with keeps itself fresh.
    public var halfLife: Double = 180 * 86_400

    /// A correction you made: the strongest evidence there is.
    public static let correctionWeight = 1.0
    /// A window that stayed open a while the way Tessel learned to place it: the lesson holds.
    public static let acceptedWeight = 0.25
    /// ...after this many seconds.
    public static let acceptedAfter = 60.0
    /// A tiled window that closed almost at once (a splash screen, a progress window)
    /// probably shouldn't have shaken up the tiles.
    public static let fleetingWeight = 0.25
    /// ...under this many seconds.
    public static let fleetingUnder = 3.0

    /// How strongly the rules hold before anything is learned...
    static let rulePrior = 0.1
    /// ...and how many corrections' worth an app's evidence, then the rules, weigh against a
    /// kind of window's own.
    static let appStrength = 2.0
    static let signatureStrength = 0.5
    /// A document window's rules hold three times as hard (see `looksLikeDocument`).
    static let documentStrength = 1.5
    /// How sure it must be to go against the rules.
    public static let threshold = 0.75

    public init() {}

    /// Learns from a whole log at once, as when Tessel starts.
    public static func replay(_ events: [FloatEvent], now: Double) -> FloatClassifier {
        var model = FloatClassifier()
        for event in events.sorted(by: { $0.time < $1.time }) { model.learn(event, now: now) }
        return model
    }

    /// How much an event from `time` counts at `now`.
    public func decay(from time: Double, to now: Double) -> Double {
        pow(0.5, max(0, now - time) / halfLife)
    }

    /// What an event says, and how strongly: nil when it says nothing, so it isn't kept.
    /// A window you chose for yourself already counted when you chose, and one the rules
    /// placed that you simply left alone says nothing either way.
    public static func evidence(in event: FloatEvent) -> (choice: FloatChoice, weight: Double)? {
        switch event.kind {
        case .corrected:
            return (event.choice, correctionWeight)
        case .closed:
            guard let lifetime = event.lifetime else { return nil }
            if event.source == .learned, lifetime >= acceptedAfter { return (event.choice, acceptedWeight) }
            if event.source == .rule, event.choice == .tile, lifetime < fleetingUnder { return (.float, fleetingWeight) }
            return nil
        }
    }

    public mutating func learn(_ event: FloatEvent, now: Double) {
        guard let (choice, weight) = Self.evidence(in: event) else { return }
        let f = event.features
        let w = weight * decay(from: event.time, to: now)
        bySignature[f.signature, default: Evidence()].add(w, to: choice)
        byApp[f.app, default: Evidence()].add(w, to: choice)
        if event.kind == .corrected {
            bySignature[f.signature]?.noteCorrection(at: event.time, to: choice)
            bySignature[f.signature]?.example = f
            byApp[f.app]?.noteCorrection(at: event.time, to: choice)
        }
    }

    /// The kinds of window Tessel now treats differently from its rules, with an example of
    /// each. `rule` says what the rules would do with a window.
    public func lessons(rule: (FloatFeatures) -> FloatChoice) -> [(signature: String, example: FloatFeatures, choice: FloatChoice)] {
        bySignature.compactMap { key, e in
            guard let example = e.example else { return nil }
            let d = decide(example, rule: rule(example))
            return d.source == .learned ? (key, example, d.choice) : nil
        }
        .sorted { $0.signature < $1.signature }
    }

    /// Whether a window just seen should tile or float. `rule` is what Tessel's built-in
    /// rules say. Pure arithmetic over two lookups: about a microsecond.
    public func decide(_ f: FloatFeatures, rule: FloatChoice) -> FloatDecision {
        let prior = rule == .float ? 1 - Self.rulePrior : Self.rulePrior
        let app = byApp[f.app] ?? Evidence()
        let kind = bySignature[f.signature] ?? Evidence()
        let pApp = (app.float + Self.appStrength * prior) / (app.total + Self.appStrength)
        let strength = rule == .tile && f.looksLikeDocument ? Self.documentStrength : Self.signatureStrength
        let p = (kind.float + strength * pApp) / (kind.total + strength)
        // Your latest word on this kind of window, else on the app.
        let told = kind.lastCorrection ?? app.lastCorrection
        if rule == .tile, p >= Self.threshold, told == .float {
            return FloatDecision(choice: .float, source: .learned, floatProbability: p)
        }
        if rule == .float, p <= 1 - Self.threshold, told == .tile {
            return FloatDecision(choice: .tile, source: .learned, floatProbability: p)
        }
        return FloatDecision(choice: rule, source: .rule, floatProbability: p)
    }

}

private extension FloatClassifier.Evidence {
    mutating func noteCorrection(at time: Double, to choice: FloatChoice) {
        guard time >= lastCorrectionTime else { return }
        lastCorrection = choice
        lastCorrectionTime = time
    }
}
