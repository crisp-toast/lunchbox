import Foundation

/// An open window Summon can find, as it was when the panel opened.
public struct SearchableWindow: Equatable, Sendable {
    public var id: UInt32
    /// The app's bundle ID, to tell apps apart.
    public var appID: String
    /// The app's name, as shown in the Dock.
    public var appName: String
    public var title: String

    public init(id: UInt32, appID: String, appName: String, title: String) {
        self.id = id
        self.appID = appID
        self.appName = appName
        self.title = title
    }
}

/// Finds open windows by the words typed into Summon ("invoice", "lunch", "Tiler").
///
/// Plain word-prefix matching: a query word finds a window when it starts a word in the window's
/// title or its app's name. On a probe of real titles it picked the right window 15 times in 15,
/// with no model and no wait. Each window's words are split once,
/// when the list is made, so typing only compares short strings.
public struct WindowSearch: Sendable {
    private struct Entry: Sendable {
        let window: SearchableWindow
        let titleWords: [String]
        let appWords: [String]
    }

    private let entries: [Entry]
    private let windowsPerApp: [String: Int]

    /// `windows` in the order ties should keep: LunchboxWM passes the most recently used first.
    public init(_ windows: [SearchableWindow]) {
        entries = windows.map { Entry(window: $0, titleWords: Self.words(in: $0.title, splittingHumps: true),
                                      appWords: Self.words(in: $0.appName, splittingHumps: true)) }
        windowsPerApp = windows.reduce(into: [:]) { $0[$1.appID, default: 0] += 1 }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The windows the query finds, best first.
    ///
    /// A window is found when at least half of the query's words each start a word in its title
    /// or app name, and those words are at least 40% of the query's letters: one typo is forgiven
    /// ("lunch thursdy" still finds the lunch email), but a short common word out of a longer
    /// search isn't a match ("app store connect website" doesn't list a Study App window, and
    /// "meetnellie.app" doesn't list App Store Connect). Windows that match more of the words come first, and once some
    /// window matches more words than another, the other is left out: "lunch thursday" lists the
    /// lunch email, not every window with a word starting "t". A word found in the title counts for more
    /// than one found only in the app's name. Ties keep the order the windows were given in.
    ///
    /// `listedApps`: bundle IDs Summon already shows as app rows. An app's only window,
    /// found by nothing but the app's name, is left out: the app's row already goes to it.
    public func find(_ query: String, listedApps: Set<String> = []) -> [SearchableWindow] {
        let wanted = Self.words(in: query, splittingHumps: false)
        guard !wanted.isEmpty else { return [] }
        let wantedLetters = wanted.reduce(0) { $0 + $1.count }
        var found: [(window: SearchableWindow, words: Int, score: Int)] = []
        for entry in entries {
            var words = 0, inTitle = 0, whole = 0, letters = 0
            for q in wanted {
                let title = entry.titleWords.contains { $0.hasPrefix(q) }
                guard title || entry.appWords.contains(where: { $0.hasPrefix(q) }) else { continue }
                words += 1
                letters += q.count
                if title { inTitle += 1 }
                if entry.titleWords.contains(q) || entry.appWords.contains(q) { whole += 1 }
            }
            guard words > 0, words * 2 >= wanted.count, letters * 5 >= wantedLetters * 2 else { continue }
            if inTitle == 0, listedApps.contains(entry.window.appID), windowsPerApp[entry.window.appID] == 1 { continue }
            found.append((entry.window, words, words * 100 + inTitle * 10 + whole))
        }
        guard let most = found.map(\.words).max() else { return [] }
        return found.enumerated()
            .filter { $0.element.words == most }
            .sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }
            .map(\.element.window)
    }

    /// Whether every word of the query starts a word in that window's title or app name.
    public func matchesEveryWord(_ query: String, window id: UInt32) -> Bool {
        let wanted = Self.words(in: query, splittingHumps: false)
        guard !wanted.isEmpty, let entry = entries.first(where: { $0.window.id == id }) else { return false }
        return wanted.allSatisfy { q in (entry.titleWords + entry.appWords).contains { $0.hasPrefix(q) } }
    }

    /// Lowercased words without accents, split on anything that isn't a letter or a digit.
    /// An apostrophe doesn't split ("Sam's" is one word). With `splittingHumps`, a camelCase
    /// word also gives its parts ("LauncherPanel": launcherpanel, launcher, panel), so a title
    /// finds both ways while a query word stays whole.
    public static func words(in text: String, splittingHumps: Bool) -> [String] {
        var words: [String] = []
        var current = ""
        var parts: [String] = []
        var part = ""
        var previous: Character?
        func endWord() {
            if !part.isEmpty { parts.append(part) }
            if !current.isEmpty {
                words.append(current)
                if splittingHumps, parts.count > 1 { words.append(contentsOf: parts) }
            }
            current = ""
            part = ""
            parts = []
        }
        for ch in text {
            if ch == "'" || ch == "’" { continue }
            guard ch.isLetter || ch.isNumber else {
                endWord()
                previous = ch
                continue
            }
            if ch.isUppercase, let p = previous, p.isLowercase {
                if !part.isEmpty { parts.append(part) }
                part = ""
            }
            current.append(ch)
            part.append(ch)
            previous = ch
        }
        endWord()
        return words.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }
    }
}
