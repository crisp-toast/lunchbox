import Foundation
import NaturalLanguage

/// Turns a window into numbers, in two views: how it's built (Accessibility role, buttons,
/// window level, size, app) and what its title says (`BehaviorModel` reads both).
public enum BehaviorFeatures {
    // MARK: Structure

    public static let structureNames: [String] = [
        "subrole.standard", "subrole.dialog", "subrole.systemDialog", "subrole.floating", "subrole.systemFloating", "subrole.other",
        "role.notWindow",
        "button.close", "button.minimize", "button.zoom", "button.fullScreen",
        "resizable", "modal", "defaultButton", "cancelButton", "toolbar", "tabs", "document", "main",
        "layer.normal", "layer.floating", "layer.overlay",
        "share.tiny", "share.small", "share.medium", "share.large", "share.huge",
        "log.width", "log.height", "aspect",
        "openSavePanel",
        "category.productivity", "category.developer", "category.media", "category.social", "category.utilities",
        "category.graphics", "category.games", "category.none",
        "appWindows.one", "appWindows.few", "appWindows.many",
    ]

    public static func structure(_ t: WindowTraits) -> [Double] {
        var v: [Double] = []
        let subroles = ["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"]
        v += subroles.map { t.subrole == $0 ? 1 : 0 }
        v.append(subroles.contains(t.subrole ?? "") ? 0 : 1)
        v.append(t.role == "AXWindow" ? 0 : 1)
        v += [WindowButtons.close, .minimize, .zoom, .fullScreen].map { t.buttons.contains($0) ? 1 : 0 }
        v += [t.resizable, t.modal, t.hasDefaultButton, t.hasCancelButton, t.hasToolbar, t.hasTabs, t.isDocument, t.isMain].map { $0 ? 1 : 0 }
        v += [t.layer == 0, (1...8).contains(t.layer), t.layer > 8 || t.layer < 0].map { $0 ? 1 : 0 }
        let s = t.screenShare
        v += [s < 0.03, (0.03..<0.08).contains(s), (0.08..<0.2).contains(s), (0.2..<0.45).contains(s), s >= 0.45].map { $0 ? 1 : 0 }
        v.append(log2(max(50, t.width) / 1000))
        v.append(log2(max(50, t.height) / 1000))
        v.append(log(max(50, t.width) / max(50, t.height)))
        v.append(t.identifier == "open-panel" || t.identifier == "save-panel" ? 1 : 0)
        let group = categoryGroup(t.appCategory)
        v += ["productivity", "developer", "media", "social", "utilities", "graphics", "games", "none"].map { group == $0 ? 1 : 0 }
        v += [t.appWindows <= 1, (2...3).contains(t.appWindows), t.appWindows >= 4].map { $0 ? 1 : 0 }
        return v
    }

    static func categoryGroup(_ category: String?) -> String {
        guard let c = category?.replacingOccurrences(of: "public.app-category.", with: "") else { return "none" }
        switch c {
        case "productivity", "business", "finance", "education", "reference", "lifestyle", "news": return "productivity"
        case "developer-tools": return "developer"
        case "video", "music", "entertainment", "photography", "sports": return "media"
        case "social-networking": return "social"
        case "utilities": return "utilities"
        case "graphics-design": return "graphics"
        default: return c.hasSuffix("games") ? "games" : "none"
        }
    }

    // MARK: Title

    /// Words that say what kind of window it is. A title isn't kept, only which of these it had.
    static let lexicon: [WindowBehavior: Set<String>] = [
        .panel: ["inspector", "info", "properties", "palette", "colors", "colours", "fonts", "font", "library", "toolbox", "tools",
                 "navigator", "preferences", "settings", "options", "attributes", "layers", "styles", "history", "characters",
                 "tape", "equalizer", "meter", "monitor", "console", "log", "keyboard", "emoji", "inspect", "adjust", "adjustments"],
        .transient: ["copying", "moving", "downloading", "uploading", "installing", "updating", "preparing", "loading", "progress",
                     "connecting", "welcome", "starting", "launching", "syncing", "exporting", "importing", "processing", "verifying",
                     "archive", "expanding", "compressing", "deleting", "emptying", "indexing", "untitled-splash", "setup", "signing"],
        .media: ["picture", "pip", "player", "miniplayer", "mini", "playing", "video", "meeting", "call", "facetime", "camera", "huddle", "stream"],
        .dialog: ["open", "save", "print", "export", "alert", "warning", "error", "confirm", "password", "authenticate", "sign",
                  "login", "permission", "allow", "replace", "delete", "quit", "choose", "select", "rename"],
        .document: ["untitled", "document", "edited", "readme", "draft", "copy"],
    ]

    public static let titleNames: [String] = [
        "title.empty", "title.isApp", "title.hasApp", "title.fileName", "title.short", "title.medium", "title.long", "title.digits",
        "title.separator", "word.panel", "word.transient", "word.media", "word.dialog", "word.document",
    ]

    public static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 2 }
    }

    public static func title(_ t: WindowTraits) -> [Double] {
        let title = (t.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        let app = (t.appName ?? "").lowercased()
        let words = Set(Self.words(title))
        var v: [Double] = []
        v.append(title.isEmpty ? 1 : 0)
        v.append(!app.isEmpty && lower == app ? 1 : 0)
        v.append(!app.isEmpty && lower != app && lower.contains(app) ? 1 : 0)
        v.append(lower.range(of: #"\.[a-z0-9]{1,5}(\s|$)"#, options: .regularExpression) != nil ? 1 : 0)
        v += [!title.isEmpty && title.count <= 12, (13...40).contains(title.count), title.count > 40].map { $0 ? 1 : 0 }
        v.append(title.contains { $0.isNumber } ? 1 : 0)
        v.append(title.contains("—") || title.contains(" - ") || title.contains(" | ") ? 1 : 0)
        for kind in [WindowBehavior.panel, .transient, .media, .dialog, .document] {
            v.append(words.isDisjoint(with: lexicon[kind]!) ? 0 : 1)
        }
        return v
    }
}

/// Apple's on-device word vectors, averaged over a title's words: what a title means, beyond
/// the words LunchboxWM knows. Loads in about a millisecond, about 0.02 ms a word; nil when the
/// Mac has none for English.
public final class TitleMeaning: @unchecked Sendable {
    public static let shared = TitleMeaning()
    private let embedding: NLEmbedding?
    private let lock = NSLock()

    init() { embedding = NLEmbedding.wordEmbedding(for: .english) }

    public var dimension: Int { embedding?.dimension ?? 0 }

    /// The average vector of the title's words it knows, or zeros.
    public func vector(_ title: String?) -> [Double] {
        guard let embedding else { return [] }
        let words = BehaviorFeatures.words(title ?? "")
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var n = 0
        lock.lock()
        defer { lock.unlock() }
        for word in words {
            guard let v = embedding.vector(for: word) else { continue }
            for i in sum.indices { sum[i] += v[i] }
            n += 1
        }
        return n == 0 ? sum : sum.map { $0 / Double(n) }
    }
}

/// The window classifier, shaped like a System One decision model (Jev's typed `choice`): a
/// window's state goes in, one probability per behavior comes out, and nothing is generated.
/// It reads the window's two views (`BehaviorFeatures`), standardized, with a softmax head.
///
/// Small on purpose (a few thousand numbers): a decision takes about 0.05 ms. The open System One
/// models (Laya, Julia 1) were tried in its place and did worse on windows; see
/// docs/system-one-research.md.
public struct BehaviorModel: Codable, Sendable {
    public var structureMean: [Double]
    public var structureScale: [Double]
    public var titleMean: [Double]
    public var titleScale: [Double]
    /// Projects Apple's word vectors (`TitleMeaning`) to a few dimensions; empty without them.
    public var meaning: [[Double]]
    /// Rows by `classes`, over both views plus a bias.
    public var head: [[Double]]
    public var classes: [WindowBehavior]
    /// Below this probability, the rules decide.
    public var threshold: Double
    public var trainedOn: Int
    public var note: String

    public init(structureMean: [Double], structureScale: [Double], titleMean: [Double], titleScale: [Double],
                meaning: [[Double]], head: [[Double]], classes: [WindowBehavior], threshold: Double,
                trainedOn: Int, note: String) {
        self.structureMean = structureMean
        self.structureScale = structureScale
        self.titleMean = titleMean
        self.titleScale = titleScale
        self.meaning = meaning
        self.head = head
        self.classes = classes
        self.threshold = threshold
        self.trainedOn = trainedOn
        self.note = note
    }

    /// What the head reads: both views, standardized. `meaning` is the title's word vectors
    /// (`TitleMeaning`), or empty.
    public func inputs(_ t: WindowTraits, meaning words: [Double]) -> [Double] {
        let s = zip(BehaviorFeatures.structure(t), zip(structureMean, structureScale)).map { ($0 - $1.0) / $1.1 }
        var titleView = BehaviorFeatures.title(t)
        if !meaning.isEmpty {
            titleView += words.count == meaning.first?.count ? Self.apply(meaning, words) : [Double](repeating: 0, count: meaning.count)
        }
        return s + zip(titleView, zip(titleMean, titleScale)).map { ($0 - $1.0) / $1.1 }
    }

    /// Probabilities for each of `classes`.
    public func probabilities(_ t: WindowTraits, meaning: [Double]) -> [Double] {
        let x = inputs(t, meaning: meaning) + [1]
        let logits = head.map { row in zip(row, x).reduce(0) { $0 + $1.0 * $1.1 } }
        let m = logits.max() ?? 0
        let e = logits.map { exp($0 - m) }
        let total = e.reduce(0, +)
        return e.map { $0 / total }
    }

    /// The behavior it would give a window, and how sure it is.
    public func classify(_ t: WindowTraits, meaning: [Double]) -> (behavior: WindowBehavior, confidence: Double) {
        let p = probabilities(t, meaning: meaning)
        let best = p.indices.max { p[$0] < p[$1] } ?? 0
        return (classes[best], p[best])
    }

    static func apply(_ m: [[Double]], _ x: [Double]) -> [Double] {
        m.map { row in zip(row, x).reduce(0) { $0 + $1.0 * $1.1 } }
    }
}

/// Deciding a window's behavior: the hard rules first, then the model where it's sure, then
/// the rules.
public enum BehaviorDecision {
    public static func decide(_ t: WindowTraits, model: BehaviorModel?, meaning: [Double],
                              floatingApps: Set<String>) -> (behavior: WindowBehavior, byModel: Bool, confidence: Double) {
        let rule = WindowBehavior.byRules(t, floatingApps: floatingApps)
        guard let model, !floatingApps.contains(t.app), WindowBehavior.hardRule(t) == nil else { return (rule, false, 1) }
        let (behavior, confidence) = model.classify(t, meaning: meaning)
        let decided = combine(t, rule: rule, model: behavior, confidence: confidence, threshold: model.threshold,
                              floatingApps: floatingApps)
        return (decided, decided != rule, confidence)
    }

    /// The safety floor around what the model says:
    /// - the rules decide every window LunchboxWM never asks the model about: an app's that always
    ///   floats, and (`hardRule`) dialogs, About boxes and the like, and windows that aren't
    ///   window-like;
    /// - the model only counts when it's at least `threshold` sure.
    ///
    /// A window that can't be resized may tile: the model is only asked about one the rules
    /// already tile at its own size (Calculator), and may float it instead.
    public static func combine(_ t: WindowTraits, rule: WindowBehavior, model: WindowBehavior, confidence: Double,
                               threshold: Double, floatingApps: Set<String>) -> WindowBehavior {
        if floatingApps.contains(t.app) { return rule }
        if let hard = WindowBehavior.hardRule(t) { return hard }
        guard confidence >= threshold else { return rule }
        return model
    }
}
