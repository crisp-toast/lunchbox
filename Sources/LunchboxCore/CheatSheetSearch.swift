/// One line in the Cheat Sheet.
public struct CheatEntry: Equatable, Sendable {
    public let id: String
    public let keys: [String]
    public let title: String
    public let group: String
    public let keywords: [String]

    public init(id: String, keys: [String], title: String, group: String, keywords: [String]) {
        self.id = id
        self.keys = keys
        self.title = title
        self.group = group
        self.keywords = keywords
    }
}

/// Search that forgives: synonyms, symbols (⌘, ⇧, ←), partial words, letters
/// in order, and typos. When nothing fully matches, it still offers the
/// closest lines instead of an empty list.
public enum CheatSheetSearch {
    public struct Result: Equatable, Sendable {
        public let entries: [CheatEntry]
        /// True when these are near misses rather than real matches.
        public let closest: Bool
    }

    public static func search(_ query: String, in entries: [CheatEntry]) -> Result {
        let words = normalizedWords(query)
        guard !words.isEmpty else { return Result(entries: entries, closest: false) }
        var strong: [(CheatEntry, Int, Int)] = []
        var partial: [(CheatEntry, Int, Int)] = []
        for (index, entry) in entries.enumerated() {
            let titleTokens = tokens(of: [entry.title] + entry.keys)
            let otherTokens = tokens(of: [entry.group] + entry.keywords)
            // A word found in the title counts a little more than one found in keywords.
            let scores = words.map { w -> Int in
                let inTitle = titleTokens.map { score(w, $0) }.max() ?? 0
                let elsewhere = otherTokens.map { score(w, $0) }.max() ?? 0
                return max(inTitle > 0 ? inTitle + 1 : 0, elsewhere)
            }
            let total = scores.reduce(0, +)
            if scores.allSatisfy({ $0 > 0 }) { strong.append((entry, total, index)) }
            else if total > 0 { partial.append((entry, total, index)) }
        }
        let order: ((CheatEntry, Int, Int), (CheatEntry, Int, Int)) -> Bool = { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.2 < b.2
        }
        if !strong.isEmpty { return Result(entries: strong.sorted(by: order).map(\.0), closest: false) }
        return Result(entries: partial.sorted(by: order).prefix(6).map(\.0), closest: true)
    }

    // MARK: Words

    /// Symbols and abbreviations people type, mapped to the words entries use.
    static let aliases: [String: [String]] = [
        "⌘": ["command"], "cmd": ["command"], "command": ["command"],
        "⇧": ["shift"], "shft": ["shift"],
        "⌥": ["option"], "alt": ["option"], "opt": ["option"],
        "⌃": ["control"], "ctrl": ["control"], "ctl": ["control"],
        "←": ["left"], "→": ["right"], "↑": ["up"], "↓": ["down"],
        "↩": ["return"], "enter": ["return"], "⌫": ["delete"], "backspace": ["delete"], "esc": ["escape"],
        "+": ["plus"], "=": ["plus"], "-": ["minus"], "−": ["minus"],
        "desktops": ["desktop"], "spaces": ["workspace"], "space": ["workspace", "space"],
        "workspaces": ["workspace"], "windows": ["window"], "apps": ["app"], "maximise": ["maximize"],
        "?": ["help"], "1": ["1", "one"], "2": ["2", "two"], "3": ["3", "three"],
    ]

    /// Filler that carries no meaning in a search ("how do I make it bigger").
    static let stopwords: Set<String> = [
        "a", "an", "the", "to", "my", "it", "its", "is", "how", "do", "does", "i", "can", "make", "of", "for",
        "on", "in", "with", "and", "me", "this", "that", "please", "want", "way", "be", "by", "from",
    ]

    static func normalizedWords(_ text: String) -> [String] {
        var out: [String] = []
        for raw in split(text.lowercased()) where !stopwords.contains(raw) {
            if let mapped = aliases[raw] { out.append(contentsOf: mapped.prefix(1)) } else { out.append(raw) }
        }
        return out
    }

    /// Splits on spaces and punctuation but keeps key symbols as their own words.
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let symbols: Set<Character> = ["⌘", "⇧", "⌥", "⌃", "←", "→", "↑", "↓", "↩", "⌫", "+", "=", "−", "?"]
        for ch in text {
            if symbols.contains(ch) {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(String(ch))
            } else if ch.isLetter || ch.isNumber || ch == "/" {
                current.append(ch)
            } else {
                if !current.isEmpty { words.append(current); current = "" }
                if ch == "-" { words.append("-") }
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func tokens(of phrases: [String]) -> [String] {
        var all: [String] = []
        for phrase in phrases {
            for w in split(phrase.lowercased()) {
                all.append(contentsOf: aliases[w] ?? [w])
            }
            // "full screen" also matches "fullscreen".
            let joined = phrase.lowercased().filter { $0.isLetter || $0.isNumber }
            if joined.count > 3 { all.append(joined) }
        }
        return Array(Set(all))
    }

    // MARK: Scoring

    /// How well one typed word matches one token: 0 means not at all.
    static func score(_ word: String, _ token: String) -> Int {
        if word == token { return 6 }
        if word.count >= 2, token.hasPrefix(word) { return 5 }
        if word.count >= 4, token.contains(word) { return 3 }
        let allowed = word.count >= 8 ? 2 : (word.count >= 4 ? 1 : 0)
        if allowed > 0, abs(word.count - token.count) <= allowed, editDistance(word, token, limit: allowed) <= allowed { return 3 }
        if word.count >= 3, token.count <= word.count * 2, inOrder(word, token) { return 1 }
        return 0
    }

    static func inOrder(_ word: String, _ token: String) -> Bool {
        var it = token.makeIterator()
        for ch in word {
            var found = false
            while let t = it.next() { if t == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// Levenshtein distance, giving up early past `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMin = current[0]
            for j in 1...max(1, b.count) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
