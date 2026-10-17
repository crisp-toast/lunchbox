import Foundation

/// The rules that keep what Tessel learns from ever being annoying, in one place and tested
/// like everything else (docs/learning.md, "Not annoying, as hard rules"):
///
/// - It only decides where a new window lands. It never rearranges what you're looking at.
/// - It never takes focus from what you're doing.
/// - No popups, notifications or questions. When it isn't sure, it does what it always did,
///   silently.
/// - Everything it does on its own is one quiet line, and one key undoes it: ⌘ and the key of
///   the Workspace you were in.
/// - Undo the same thing twice in a row, and it stops doing it.
/// - It's never slower than without it.
/// - What it learned is listed in words, and each lesson can be forgotten.
public enum Etiquette {
    /// How long the undo key works after Tessel does something on its own.
    public static let undoSeconds = 10.0
    /// How long the quiet line stays.
    public static let lineSeconds = 2.5
    /// Things Tessel does within this long of each other share one line and one undo
    /// (windows coming back after a login, say).
    public static let batchSeconds = 1.0
    /// Undone this many times in a row, a thing stops happening.
    public static let undosToStop = 2
}

/// Something Tessel did on its own, from what it learned.
public enum AutomaticAction: Equatable, Sendable {
    /// A new window floats, because you floated windows like it.
    case floated(app: String)
    /// A new window tiles, because you tiled windows like it.
    case tiled(app: String)
    /// A new window took the place and size it usually has next to these apps.
    case arranged(app: String)
    /// A lone window took the shape you gave that app's windows before.
    case shaped(app: String)
    /// Four windows took the shape you gave them before: this app's window with a column to
    /// itself, at full height, on the `side` ("left", "right" or "middle").
    case anchored(app: String, side: String)
    /// A new window opened in the Workspace its app lives in, and you stayed where you were.
    case sent(app: String, space: Int)
    /// A new window you opened went to the Workspace its app lives in, and you went with it.
    case followed(app: String, space: Int)
}

/// The one line Tessel shows when it did something on its own.
public enum QuietLine {
    /// `undoKey` names the undo key ("Left ⌘ 1"), nil when there isn't one.
    public static func text(for actions: [AutomaticAction], undoKey: String?) -> String {
        guard let first = actions.first else { return "" }
        let what: String
        let undo: String
        if actions.count > 1 {
            let spaces = actions.allSatisfy { if case .sent = $0 { return true }; if case .followed = $0 { return true }; return false }
            what = spaces ? "\(actions.count) windows went to their Workspaces" : "\(actions.count) windows went where they usually go"
            undo = spaces ? "keeps them here" : "undoes"
        } else {
            switch first {
            case .floated(let app): (what, undo) = ("\(app) floats, like the last one", "tiles it")
            case .tiled(let app): (what, undo) = ("\(app) tiles, like the last one", "floats it")
            case .arranged(let app): (what, undo) = ("\(app) is back in its usual spot", "undoes")
            case .shaped(let app): (what, undo) = ("\(app) is the size you gave it", "undoes")
            case .anchored(let app, let side): (what, undo) = ("\(app) has the \(side) to itself, like last time", "makes a grid")
            case .sent(let app, let space): (what, undo) = ("\(app) opened in Workspace \(space + 1)", "keeps it here")
            case .followed(let app, let space): (what, undo) = ("\(app) lives in Workspace \(space + 1)", "takes it back")
            }
        }
        guard let undoKey else { return what }
        return "\(what) · \(undoKey) \(undo)"
    }
}

/// What you keep undoing, so Tessel stops doing it. A thing is anything Tessel does on its
/// own, named by a key ("place|com.apple.mail", "arrange|…"). Undone `Etiquette.undosToStop`
/// times in a row, it stops until you forget the lesson or reset what Tessel learned. Any
/// time you leave it be, the count starts over.
public struct UndoLedger: Codable, Equatable, Sendable {
    public private(set) var streak: [String: Int] = [:]
    public private(set) var stopped: Set<String> = []

    public init() {}

    public func allows(_ key: String) -> Bool { !stopped.contains(key) }

    /// You undid it. True when that was once too often and it stops now.
    @discardableResult
    public mutating func undone(_ key: String) -> Bool {
        let n = streak[key, default: 0] + 1
        streak[key] = n
        guard n >= Etiquette.undosToStop else { return false }
        stopped.insert(key)
        return true
    }

    /// It stood (the undo key wasn't pressed in time).
    public mutating func kept(_ key: String) {
        streak[key] = nil
    }

    /// Forgets everything about a thing, or every thing starting with `prefix`.
    public mutating func forget(_ key: String) {
        streak[key] = nil
        stopped.remove(key)
    }

    public mutating func forget(prefix: String) {
        streak = streak.filter { !$0.key.hasPrefix(prefix) }
        stopped = stopped.filter { !$0.hasPrefix(prefix) }
    }
}
