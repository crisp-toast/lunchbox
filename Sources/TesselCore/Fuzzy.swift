/// Scores how well a typed query matches a name, for the launcher.
///
/// Higher is better; nil means no match. In order of strength: the whole name,
/// the start of the name, the start of a later word ("code" in "Visual Studio
/// Code"), the word initials ("vsc"), anywhere in the name, and finally the
/// query's letters in order with gaps ("xcd" in "Xcode"). Shorter names win ties,
/// so "Notes" beats "Notes Helper".
public enum Fuzzy {
    public static func score(_ query: String, _ name: String) -> Int? {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return nil }
        let n = name.lowercased()
        let compact = n.filter { !$0.isWhitespace }
        let lengthPenalty = min(n.count, 60)

        if compact == q { return 10_000 }
        if compact.hasPrefix(q) { return 9_000 - lengthPenalty }

        let words = Self.words(in: name)
        if let index = words.firstIndex(where: { $0.hasPrefix(q) }) {
            return 8_000 - index * 10 - lengthPenalty
        }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(q) { return 7_000 - lengthPenalty }
        if let range = compact.range(of: q) {
            return 6_000 - compact.distance(from: compact.startIndex, to: range.lowerBound) * 5 - lengthPenalty
        }

        // Letters in order, fewer and shorter gaps scoring higher.
        var gaps = 0
        var qi = q.startIndex
        var lastMatch: String.Index?
        for ci in compact.indices where qi < q.endIndex {
            if compact[ci] == q[qi] {
                if let last = lastMatch, compact.index(after: last) != ci { gaps += 1 }
                lastMatch = ci
                qi = q.index(after: qi)
            }
        }
        guard qi == q.endIndex else { return nil }
        return max(1, 4_000 - gaps * 100 - lengthPenalty)
    }

    /// Lowercased words, split on spaces, punctuation, and camelCase humps
    /// ("PhotoCraft" -> photo, craft).
    static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in name {
            if !ch.isLetter && !ch.isNumber {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if ch.isUppercase, let p = previous, p.isLowercase {
                if !current.isEmpty { words.append(current) }
                current = String(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}
