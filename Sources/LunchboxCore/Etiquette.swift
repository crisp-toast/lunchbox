import Foundation

/// How LunchboxWM tells you it did something on its own (a restarted app's window went back to
/// its Workspace): one quiet line, never a popup, and ⌘ and the key of the Workspace you were in
/// undoes it for a few seconds.
public enum Etiquette {
    /// How long the undo key works after LunchboxWM does something on its own.
    public static let undoSeconds = 10.0
    /// How long the quiet line stays.
    public static let lineSeconds = 2.5
    /// Things LunchboxWM does within this long of each other share one line and one undo
    /// (an app reopening several windows at once).
    public static let batchSeconds = 1.0
}

/// Something LunchboxWM did on its own.
public enum AutomaticAction: Equatable, Sendable {
    /// A restarted app's window went back to the Workspace it was in when the app quit; with
    /// `followed`, you went with it.
    case reopened(app: String, space: Int, followed: Bool)
}

/// The one line LunchboxWM shows when it did something on its own.
public enum QuietLine {
    /// `undoKey` names the undo key ("Left ⌘ 1"), nil when there isn't one.
    public static func text(for actions: [AutomaticAction], undoKey: String?) -> String {
        guard let first = actions.first else { return "" }
        let what: String
        let undo: String
        if actions.count > 1 {
            (what, undo) = ("\(actions.count) windows went back to their Workspaces", "keeps them here")
        } else {
            switch first {
            case .reopened(let app, let space, let followed):
                (what, undo) = ("\(app) reopened in Workspace \(space + 1), where it was", followed ? "takes it back" : "keeps it here")
            }
        }
        guard let undoKey else { return what }
        return "\(what) · \(undoKey) \(undo)"
    }
}
