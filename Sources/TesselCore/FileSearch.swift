import Foundation

/// Summon's files: which of Spotlight's matches to show, in what order, and how to name their
/// folders. Spotlight finds every file and folder whose name has each typed word in it; this
/// keeps out the noise and puts the likeliest first.
public enum FileSearch {
    /// The query's words for Spotlight: split on spaces, without Spotlight's wildcards.
    public static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { String($0.filter { !"*?\"\\".contains($0) }) }
            .filter { !$0.isEmpty }
    }

    /// Whether a name has every term in it, ignoring case and accents: what Spotlight was
    /// asked for, so its last answer can stay up while you keep typing.
    public static func matches(_ terms: [String], name: String) -> Bool {
        let n = fold(name)
        return !terms.isEmpty && terms.allSatisfy { n.contains(fold($0)) }
    }

    /// Paths Summon never shows: hidden files, apps and their insides, caches, build output, and
    /// Library folders, except the two that hold your own files: iCloud Drive (where Desktop and
    /// Documents live when they sync to iCloud) and CloudStorage (Dropbox, Google Drive, OneDrive).
    public static func isHidden(_ path: String, home: String) -> Bool {
        if path.hasSuffix(".app") || path.contains(".app/") { return true }
        if ["/.", "/node_modules/", "/DerivedData/", "/Caches/"].contains(where: { path.contains($0) }) { return true }
        if path.contains("/Library/") {
            return ![home + "/Library/Mobile Documents/", home + "/Library/CloudStorage/"].contains { path.hasPrefix($0) }
        }
        return false
    }

    /// The folder a path is in, as Summon shows it: iCloud Drive by name, your home as ~.
    public static func folder(of path: String, home: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let cloud = iCloudDrive(home)
        if dir == cloud || dir.hasPrefix(cloud + "/") { return "iCloud Drive" + dir.dropFirst(cloud.count) }
        if dir == home || dir.hasPrefix(home + "/") { return "~" + dir.dropFirst(home.count) }
        return dir
    }

    /// The paths, best first. By name: the query itself, then names that start with it, then
    /// names where each typed word starts a word, then the rest. Within each, files in Desktop,
    /// Documents and Downloads (on this Mac or in iCloud Drive) come first, then shallow paths,
    /// then deep ones. Ties keep the order given: Spotlight's, most recently used first.
    public static func rank(_ paths: [String], query: String, home: String) -> [String] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        let wanted = WindowSearch.words(in: query, splittingHumps: false)
        return paths.enumerated().map { i, path -> (path: String, score: Int, index: Int) in
            let name = (path as NSString).lastPathComponent
            let folded = fold(name)
            let match: Int
            if folded == q || fold((name as NSString).deletingPathExtension) == q {
                match = 3
            } else if folded.hasPrefix(q) {
                match = 2
            } else if !wanted.isEmpty, case let words = WindowSearch.words(in: name, splittingHumps: true),
                      wanted.allSatisfy({ w in words.contains { $0.hasPrefix(w) } }) {
                match = 1
            } else {
                match = 0
            }
            return (path, match * 10 + place(of: path, home: home), i)
        }
        .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
        .map(\.path)
    }

    /// 2: in Desktop, Documents or Downloads, at most two folders further down. 1: at most three
    /// folders below your home, iCloud Drive or a drive's top. 0: deeper.
    static func place(of path: String, home: String) -> Int {
        var base: String?
        for root in [iCloudDrive(home), home] where path.hasPrefix(root + "/") {
            base = root
            break
        }
        if base == nil, path.hasPrefix("/Volumes/"), let drive = path.split(separator: "/").dropFirst().first {
            base = "/Volumes/" + drive
        }
        let parts = (base.map { path.dropFirst($0.count + 1) } ?? path.dropFirst()).split(separator: "/")
        let folders = parts.count - 1
        if base != nil, let top = parts.first, ["Desktop", "Documents", "Downloads"].contains(top), folders <= 3 { return 2 }
        return folders <= 3 ? 1 : 0
    }

    static func iCloudDrive(_ home: String) -> String { home + "/Library/Mobile Documents/com~apple~CloudDocs" }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

/// Summon's list, put together.
public enum Summon {
    /// One row in Summon's list.
    public enum Row<App, Window, File> {
        case app(App)
        case window(Window)
        case file(File)
    }

    /// Summon's order: apps whose name matches what you typed (the whole name, its start, a
    /// word's start or the initials), then windows, then files, then apps that only loosely
    /// match, like "lunch" in Launchpad. Files keep at least two rows when Spotlight found any,
    /// however many apps and windows match.
    ///
    /// `apps` in the order they should show, each with its `Fuzzy.score` for the name alone.
    public static func order<App, Window, File>(apps: [(app: App, nameScore: Int)], windows: [Window], files: [File] = [],
                                                limit: Int) -> [Row<App, Window, File>] {
        let named = apps.filter { Fuzzy.matchesName($0.nameScore) }.map { Row<App, Window, File>.app($0.app) }
        let loose = apps.filter { !Fuzzy.matchesName($0.nameScore) }.map { Row<App, Window, File>.app($0.app) }
        let head = named + windows.map { .window($0) }
        let room = max(0, limit - min(2, files.count))
        return Array((Array(head.prefix(room)) + files.map { .file($0) } + loose).prefix(limit))
    }
}
