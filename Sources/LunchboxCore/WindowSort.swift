import Foundation
import CoreGraphics

/// Sorting a messy desktop into Workspaces by kind: setup's "Organize your open windows?" and
/// Sort My Windows in the menu. Three kinds, always in this order: your work, the web, chat and
/// music. Only as many Workspaces as it takes, each holding only as many windows as fit two to a
/// column (`fit`: four on most displays, a 2×2), so none gets squeezed while a Workspace is free:
/// a few windows stay together, small kinds join up while they fit, and a big kind spills into a
/// Workspace that's free. With every Workspace taken, they share a third row; anything past that
/// (what you've used least lately) is hidden, still open: Summon finds it, and Undo brings it back.
///
/// It goes by how you work, not just what the windows are (`importance`): how recently you used
/// each window and how long it's had focus lately. The window you're most into decides where you
/// land and gets the most room (`layout`); a browser window you keep going back to from your work
/// stays beside it (`companions`); and a big kind splits by what belongs together (`tasks`).
public enum WindowSort {
    public enum Group: Int, CaseIterable, Sendable {
        case work, web, talk

        public var title: String {
            switch self {
            case .work: return "Your work"
            case .web: return "The web"
            case .talk: return "Chat & music"
            }
        }
    }

    /// How much room a window is at home in, from its app: a browser, an editor or a design app
    /// wants width; chat, music, a terminal or notes are fine in a narrow column.
    public enum Comfort: Sendable {
        case wide, usual, narrow

        /// Past this, more room adds little.
        var comfortable: CGSize {
            switch self {
            case .wide: return CGSize(width: 1440, height: 900)
            case .usual: return CGSize(width: 1100, height: 760)
            case .narrow: return CGSize(width: 640, height: 560)
            }
        }

        /// Smaller than this, it's hard to use.
        var smallest: CGSize {
            switch self {
            case .wide: return CGSize(width: 760, height: 420)
            case .usual: return CGSize(width: 560, height: 340)
            case .narrow: return CGSize(width: 340, height: 240)
            }
        }

        /// How well a window gets on at `size`, from 0 to 1: 1 once it's comfortable, less as it
        /// gets smaller, and much less once it's below the smallest it's easy to use at.
        func value(of size: CGSize) -> Double {
            guard size.width > 0, size.height > 0 else { return 0 }
            let c = comfortable, s = smallest
            var v = Double(min(1, size.width / c.width) * min(1, size.height / c.height)).squareRoot()
            if size.width < s.width { v *= pow(Double(size.width / s.width), 2) }
            if size.height < s.height { v *= pow(Double(size.height / s.height), 2) }
            return v
        }
    }

    public struct Item: Equatable, Sendable {
        public let id: WindowID
        public let bundleID: String?
        /// Its app's App Store category (`LSApplicationCategoryType`), if it has one.
        public let category: String?
        /// Its title, for telling which windows are part of the same thing: "Lunchbox — Tiler.swift"
        /// in Xcode and "lunchbox — zsh" in Terminal.
        public let title: String?
        /// How long it's had focus lately, in seconds, the longer ago the less (`WindowUsage`).
        public let use: Double

        public init(id: WindowID, bundleID: String?, category: String?, title: String? = nil, use: Double = 0) {
            self.id = id
            self.bundleID = bundleID
            self.category = category
            self.title = title
            self.use = use
        }
    }

    public struct Workspace: Equatable, Sendable {
        /// The kinds sorted into it, in order.
        public var groups: [Group]
        /// Its windows, the one that matters most first.
        public var windows: [WindowID]

        public var title: String { groups.map(\.title).joined(separator: " · ") }
    }

    public struct Plan: Equatable, Sendable {
        /// Workspace 1 first.
        public var workspaces: [Workspace]
        /// Past what fits: hidden, still open.
        public var hidden: [WindowID]
        /// The Workspace to end up in: the one with the window that matters most right now.
        public var landing: Int
        /// How much each window counts for when its Workspace's room is shared out (`layout`):
        /// more the longer it's had focus lately, a little more the more recently it was used.
        public var weights: [WindowID: Double] = [:]
        /// How much room each window is at home in.
        public var comforts: [WindowID: Comfort] = [:]
    }

    /// How many windows a Workspace holds on a display `width` points wide: two to a column, so
    /// four (a 2×2) on most displays, six on an ultrawide, two on a narrow one.
    public static func fit(forWidth width: CGFloat) -> Int { 2 * Layout.maxColumns(forWidth: width) }

    // MARK: Kinds

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.kagi.kagimacOS", "app.zen-browser.zen", "com.duckduckgo.macos.browser", "org.chromium.Chromium",
        "com.sigmaos.sigmaos.macos",
    ]
    static let chatApps: Set<String> = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "org.whispersystems.signal-desktop", "com.facebook.archon",
        "com.automattic.beeper.desktop", "com.tapbots.Ivory", "com.mastodon.mona",
    ]
    static let listeningApps: Set<String> = [
        "com.apple.Music", "com.apple.podcasts", "com.spotify.client", "com.tidal.desktop", "com.amazon.music",
        "com.deezer.deezer-desktop", "com.plexamp.plexamp", "com.coppertino.Vox",
    ]
    /// Mail, calendars and calls: chat too, but they want more room than a chat column.
    static let talkApps: Set<String> = chatApps.union(listeningApps).union([
        "com.apple.mail", "com.apple.iCal", "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac", "com.microsoft.Outlook", "com.superhuman.electron",
        "com.flexibits.fantastical2.mac", "com.mimestream.Mimestream", "Cisco-Systems.Spark",
    ])
    static let talkCategories: Set<String> = ["public.app-category.social-networking", "public.app-category.music"]
    /// Apps for making music and editing sound are your work, though they say they're music apps.
    static let musicMakers = [
        "com.apple.logic10", "com.apple.garageband10", "com.apple.mainstage3", "com.ableton.live", "com.image-line.flstudio",
        "com.bitwig.BitwigStudio", "com.cockos.reaper", "com.avid.ProTools", "com.steinberg.", "com.presonus.studioone",
        "com.adobe.Audition", "org.audacityteam.audacity", "ai.storyteller.soundcraft",
    ]

    /// The kind of window, from its app: anything not a browser, chat or music is your work.
    public static func group(of item: Item) -> Group {
        if let id = item.bundleID {
            if browsers.contains(id) { return .web }
            if talkApps.contains(id) { return .talk }
            if musicMakers.contains(where: { id.hasPrefix($0) }) { return .work }
        }
        if let category = item.category, talkCategories.contains(category) { return .talk }
        return .work
    }

    static let wideApps = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.",
        "com.panic.Nova", "com.barebones.bbedit", "com.jetbrains.", "com.google.android.studio", "com.figma.Desktop",
        "com.bohemiancoding.sketch3", "com.adobe.", "com.seriflabs.", "com.pixelmatorteam.", "org.blenderfoundation.blender",
        "com.apple.FinalCut", "com.apple.motionapp", "com.blackmagic-design.", "com.apple.iWork.", "com.apple.Pages",
        "com.apple.Numbers", "com.apple.Keynote", "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
        "com.apple.freeform", "notion.id", "ai.storyteller.",
    ]
    static let wideCategories: Set<String> = ["public.app-category.graphics-design", "public.app-category.photography",
                                              "public.app-category.video"]
    static let narrowApps: Set<String> = chatApps.union(listeningApps).union([
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "org.alacritty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.apple.Notes", "com.apple.reminders", "com.apple.Stickies",
        "com.culturedcode.ThingsMac", "com.todoist.mac.Todoist", "com.apple.calculator",
    ])

    /// How much room a window is at home in, from its app.
    public static func comfort(of item: Item) -> Comfort {
        if let id = item.bundleID {
            if narrowApps.contains(id) { return .narrow }
            if browsers.contains(id) || wideApps.contains(where: { id.hasPrefix($0) })
                || musicMakers.contains(where: { id.hasPrefix($0) }) { return .wide }
            if talkApps.contains(id) { return .usual }
        }
        if let category = item.category {
            if wideCategories.contains(category) { return .wide }
            if category == "public.app-category.social-networking" || category == "public.app-category.music" { return .narrow }
        }
        return .usual
    }

    // MARK: What matters

    /// How much each window matters right now, and how much room it should get. Mostly how long
    /// it's had focus lately, partly how recently it was used (the order `items` come in: the one
    /// used last first). So a glance at Messages after an hour in Xcode leaves Xcode the one that
    /// matters. Before there's half a minute of use to go by (just after Lunchbox started), only
    /// how recently, and the room stays close to even.
    static func standing(_ items: [Item]) -> (importance: [WindowID: Double], weights: [WindowID: Double]) {
        let most = items.map(\.use).max() ?? 0
        let known = most >= 30
        var importance: [WindowID: Double] = [:], weights: [WindowID: Double] = [:]
        for (rank, item) in items.enumerated() where importance[item.id] == nil {
            let recent = pow(0.5, Double(rank) / 2)
            let used = known ? item.use / most : 0
            importance[item.id] = known ? 0.6 * used + 0.4 * recent : recent
            weights[item.id] = 1 + 2 * used + 0.4 * recent
        }
        return (importance, weights)
    }

    /// The words in a window's title that could name what it's part of: a project, a document,
    /// a client. Words of four letters or more, other than ones in all sorts of titles.
    static func words(in title: String?) -> Set<String> {
        guard let title, !title.isEmpty else { return [] }
        return Set(title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter {
            $0.count >= 4 && !$0.allSatisfy(\.isNumber) && !commonWords.contains($0)
        })
    }

    static let commonWords: Set<String> = [
        "untitled", "window", "document", "documents", "desktop", "downloads", "home", "inbox", "edited", "with", "from",
        "your", "this", "that", "page", "tab", "tabs", "new", "bash", "fish", "terminal", "default", "main", "master",
        "swift", "html", "json", "text", "index", "readme", "users", "volumes", "code", "draft", "drafts", "preview",
    ]

    /// Browser windows you've been going back and forth with something of your work (the docs
    /// beside your code, the page you're building): they stay with your work instead of going off
    /// with the rest of the web. Only a tie of a couple of round trips lately, stronger than any
    /// it has with other browser windows, and at most `room` of them, the closest ties first.
    static func companions(_ items: [Item], kinds: [WindowID: Group], together: [WindowUsage.Pair: Double],
                           room: Int) -> [WindowID] {
        guard room > 0, !together.isEmpty else { return [] }
        var ties: [WindowID: (work: Double, web: Double)] = [:]
        for (pair, strength) in together {
            guard let ka = kinds[pair.a], let kb = kinds[pair.b] else { continue }
            for (web, other) in [(pair.a, kb), (pair.b, ka)] where kinds[web] == .web {
                if other == .work { ties[web, default: (0, 0)].work += strength }
                if other == .web { ties[web, default: (0, 0)].web += strength }
            }
        }
        return ties.filter { $0.value.work >= 4 && $0.value.work > $0.value.web }
            .sorted { $0.value.work > $1.value.work || ($0.value.work == $1.value.work && $0.key < $1.key) }
            .prefix(room).map(\.key)
    }

    /// A kind's windows (the one that matters most first) in the order they fill its Workspaces,
    /// `fit` at a time: each Workspace starts with the window that matters most of those left,
    /// then takes the ones most tied to what it has (used together lately, the same app, the same
    /// project in their titles) and least to what's left, so another project's windows wait for
    /// a Workspace of their own; with no ties, the ones that matter most. Nothing to split: the
    /// order stays.
    static func tasks(_ ids: [WindowID], fit: Int, tie: (WindowID, WindowID) -> Double) -> [WindowID] {
        guard ids.count > fit else { return ids }
        // By position in `ids`, worked out once: a desk of hundreds of windows still sorts at once.
        let n = ids.count
        var ties = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in i + 1 ..< n {
                let t = tie(ids[i], ids[j])
                (ties[i][j], ties[j][i]) = (t, t)
            }
        }
        var left = Array(0..<n)
        // Each one's closest tie among those left, and how many it has that close.
        var closest = Array(repeating: 0.0, count: n), closeCount = Array(repeating: 0, count: n)
        func refresh(_ r: Int) {
            closest[r] = left.reduce(0) { $1 == r ? $0 : max($0, ties[$1][r]) }
            closeCount[r] = closest[r] > 0 ? left.filter { $0 != r && ties[$0][r] == closest[r] }.count : 0
        }
        for r in left { refresh(r) }
        var order: [WindowID] = []
        var toGroup = Array(repeating: 0.0, count: n)
        func take(_ k: Int) {
            let w = left.remove(at: k)
            order.append(ids[w])
            for r in left {
                toGroup[r] += ties[w][r]
                if closest[r] > 0, ties[w][r] == closest[r] {
                    closeCount[r] -= 1
                    if closeCount[r] == 0 { refresh(r) }
                }
            }
        }
        while !left.isEmpty {
            for r in left { toGroup[r] = 0 }
            take(0)
            for _ in 1..<fit where !left.isEmpty {
                // Its ties to the windows here, less its closest tie among those left; the first
                // of the best, so with no ties at all, the one that matters most.
                func score(_ k: Int) -> Double { toGroup[left[k]] - closest[left[k]] }
                take(left.indices.max { score($0) < score($1) }!)
            }
        }
        return order
    }

    // MARK: The plan

    /// Where `items` (the one used last first) go: at most `limit` Workspaces of `fit` windows
    /// each while there's a Workspace free; when every one is taken, a kind's Workspaces share a
    /// third row (half as many again), and only past that are the ones that matter least hidden.
    /// - together: how often you've gone between each two windows lately (`WindowUsage`).
    /// - fits: whether windows can all be on screen at once without overlapping, going by the sizes
    ///   they take (`canShare`); two that can't (Music and Podcasts on a 1920 × 1080 display) don't
    ///   share a Workspace.
    public static func plan(_ items: [Item], together: [WindowUsage.Pair: Double] = [:], limit: Int = 3, fit: Int = 4,
                            fits: (([WindowID]) -> Bool)? = nil) -> Plan {
        let fit = max(1, fit), limit = max(1, limit)
        let crowded = fit + max(1, fit / 2)
        guard !items.isEmpty else { return Plan(workspaces: [], hidden: [], landing: 0) }
        let (importance, weights) = standing(items)
        let comforts = Dictionary(items.map { ($0.id, comfort(of: $0)) }, uniquingKeysWith: { a, _ in a })
        // The one that matters most first; ties (and no history) in the order they were used.
        let byItems = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        let ordered = Array(Set(items.map(\.id))).sorted {
            (importance[$0]!, -byItems[$0]!) > (importance[$1]!, -byItems[$1]!)
        }
        let rank = Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        func byImportance(_ ids: [WindowID]) -> [WindowID] { ids.sorted { rank[$0]! < rank[$1]! } }
        func finished(_ workspaces: [Workspace], hidden: [WindowID]) -> Plan {
            let landing = workspaces.firstIndex { $0.windows.contains(ordered[0]) } ?? 0
            return Plan(workspaces: workspaces, hidden: byImportance(hidden), landing: landing, weights: weights, comforts: comforts)
        }
        var kinds = Dictionary(items.map { ($0.id, group(of: $0)) }, uniquingKeysWith: { a, _ in a })
        // Windows that can't all be on screen at once: the one that matters least of those whose
        // going would leave the rest room (else the one that matters least) goes to a Workspace of
        // its own while one is free, else to one where it fits, one with its kind first. When it
        // fits nowhere, it stays: they overlap, as they would anyway.
        func untangle(_ workspaces: inout [Workspace]) {
            guard let fits else { return }
            var i = 0
            while i < workspaces.count {
                var tries = 0
                while workspaces[i].windows.count > 1, !fits(workspaces[i].windows), tries < 6 {
                    tries += 1
                    let here = byImportance(workspaces[i].windows)
                    let id = here.last { w in fits(here.filter { $0 != w }) } ?? here.last!
                    let kind = kinds[id] ?? .work
                    if workspaces.count < limit {
                        workspaces[i].windows.removeAll { $0 == id }
                        workspaces.insert(Workspace(groups: [kind], windows: [id]), at: i + 1)
                        continue
                    }
                    let elsewhere = workspaces.indices.filter { $0 != i && fits(workspaces[$0].windows + [id]) }
                    guard let j = elsewhere.min(by: {
                        (workspaces[$0].groups.contains(kind) ? 0 : 1, workspaces[$0].windows.count)
                            < (workspaces[$1].groups.contains(kind) ? 0 : 1, workspaces[$1].windows.count)
                    }) else { break }
                    workspaces[i].windows.removeAll { $0 == id }
                    workspaces[j].windows = byImportance(workspaces[j].windows + [id])
                    if !workspaces[j].groups.contains(kind) { workspaces[j].groups.append(kind) }
                }
                i += 1
            }
        }
        // A few windows stay together, if they can, named for the kinds they are.
        guard ordered.count > fit else {
            var few = [Workspace(groups: [.work], windows: ordered)]
            untangle(&few)
            for i in few.indices { few[i].groups = Group.allCases.filter { g in few[i].windows.contains { kinds[$0] == g } } }
            return finished(few, hidden: [])
        }

        if kinds.values.contains(.work) {
            for id in companions(items, kinds: kinds, together: together, room: max(1, fit / 2)) { kinds[id] = .work }
        }
        let info = Dictionary(items.map { ($0.id, (app: $0.bundleID, words: words(in: $0.title))) }, uniquingKeysWith: { a, _ in a })
        func tie(_ a: WindowID, _ b: WindowID) -> Double {
            var t = min(together[WindowUsage.Pair(a, b)] ?? 0, 4) / 2
            if let app = info[a]?.app, app == info[b]?.app { t += 0.5 }
            if let x = info[a]?.words, let y = info[b]?.words, !x.isDisjoint(with: y) { t += 1 }
            return t
        }
        var workspaces = Group.allCases.compactMap { g -> Workspace? in
            let ids = ordered.filter { kinds[$0] == g }
            return ids.isEmpty ? nil : Workspace(groups: [g], windows: tasks(ids, fit: fit, tie: tie))
        }
        // Small kinds join up while together they still fit, and a kind with more than fits spills
        // into the next Workspace while one is free; again until nothing changes, since what spills
        // can share with a small kind.
        for _ in 0..<12 {
            let before = workspaces
            while workspaces.count > 1 {
                let bySize = workspaces.indices.sorted { workspaces[$0].windows.count < workspaces[$1].windows.count }
                let (a, b) = (bySize[0], bySize[1])
                guard workspaces[a].windows.count + workspaces[b].windows.count <= fit || workspaces.count > limit else { break }
                let (keep, gone) = (min(a, b), max(a, b))
                workspaces[keep].groups += workspaces[gone].groups
                workspaces[keep].windows = byImportance(workspaces[keep].windows + workspaces[gone].windows)
                workspaces.remove(at: gone)
            }
            var i = 0
            while i < workspaces.count, workspaces.count < limit {
                if workspaces[i].windows.count > fit {
                    let rest = Array(workspaces[i].windows[fit...])
                    workspaces[i].windows = Array(workspaces[i].windows.prefix(fit))
                    workspaces.insert(Workspace(groups: workspaces[i].groups, windows: rest), at: i + 1)
                }
                i += 1
            }
            if workspaces == before { break }
        }
        untangle(&workspaces)
        // Every Workspace taken and still more: a kind's Workspaces take a third row, shared
        // evenly; past that, the ones that matter least are hidden, and the rest keep the order
        // they fill in (what belongs together stays together).
        var hidden: [WindowID] = []
        var start = 0
        while start < workspaces.count {
            var end = start + 1
            while end < workspaces.count, workspaces[end].groups == workspaces[start].groups { end += 1 }
            var all = (start..<end).flatMap { workspaces[$0].windows }
            let count = end - start
            if all.count > fit * count {
                let shown = min(all.count, crowded * count)
                let keep = Set(byImportance(all).prefix(shown))
                hidden += all.filter { !keep.contains($0) }
                all = all.filter(keep.contains)
                var next = 0
                for (k, w) in (start..<end).enumerated() {
                    let n = shown / count + (k < shown % count ? 1 : 0)
                    workspaces[w].windows = Array(all[next..<next + n])
                    next += n
                }
            }
            start = end
        }
        for i in workspaces.indices { workspaces[i].windows = byImportance(workspaces[i].windows) }
        return finished(workspaces, hidden: hidden)
    }
}
