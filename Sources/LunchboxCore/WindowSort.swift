import Foundation

/// Sorting a messy desktop into Workspaces by kind: setup's "Organize your open windows?" and
/// Sort My Windows in the menu. Three kinds, always in this order: your work, the web, chat and
/// music. Only as many Workspaces as it takes: a few windows stay together, small kinds join up
/// while they fit a calm Workspace, a big kind spills into a Workspace that's free, and a
/// Workspace holds up to six. Anything past that (the least recently used) is hidden, still
/// open: Summon finds it.
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

    public struct Item: Equatable, Sendable {
        public let id: WindowID
        public let bundleID: String?
        /// Its app's App Store category (`LSApplicationCategoryType`), if it has one.
        public let category: String?

        public init(id: WindowID, bundleID: String?, category: String?) {
            self.id = id
            self.bundleID = bundleID
            self.category = category
        }
    }

    public struct Workspace: Equatable, Sendable {
        /// The kinds sorted into it, in order.
        public var groups: [Group]
        /// Its windows, most recently used first.
        public var windows: [WindowID]

        public var title: String { groups.map(\.title).joined(separator: " · ") }
    }

    public struct Plan: Equatable, Sendable {
        /// Workspace 1 first.
        public var workspaces: [Workspace]
        /// Past what fits: hidden, still open.
        public var hidden: [WindowID]
        /// The Workspace to end up in: the one with the window used last.
        public var landing: Int
    }

    /// As many windows as a Workspace holds calmly (a 2×2), and the most it takes (two stacks of three).
    public static let calm = 4
    public static let most = 6

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.kagi.kagimacOS", "app.zen-browser.zen", "com.duckduckgo.macos.browser", "org.chromium.Chromium",
        "com.sigmaos.sigmaos.macos",
    ]
    static let talkApps: Set<String> = [
        "com.apple.MobileSMS", "com.apple.mail", "com.apple.iCal", "com.apple.FaceTime", "com.apple.Music",
        "com.apple.podcasts", "com.spotify.client", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "us.zoom.xos",
        "com.microsoft.teams2", "com.microsoft.teams", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "org.whispersystems.signal-desktop", "com.readdle.SparkDesktop",
        "com.readdle.smartemail-Mac", "com.microsoft.Outlook", "com.superhuman.electron", "com.flexibits.fantastical2.mac",
        "com.facebook.archon", "com.mimestream.Mimestream",
    ]
    static let talkCategories: Set<String> = ["public.app-category.social-networking", "public.app-category.music"]

    /// The kind of window, from its app: anything not a browser, chat or music is your work.
    public static func group(of item: Item) -> Group {
        if let id = item.bundleID {
            if browsers.contains(id) { return .web }
            if talkApps.contains(id) { return .talk }
        }
        if let category = item.category, talkCategories.contains(category) { return .talk }
        return .work
    }

    /// Where `items` (most recently used first) go: at most `limit` Workspaces.
    public static func plan(_ items: [Item], limit: Int = 3) -> Plan {
        guard !items.isEmpty else { return Plan(workspaces: [], hidden: [], landing: 0) }
        let rank = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        func byUse(_ ids: [WindowID]) -> [WindowID] { ids.sorted { rank[$0]! < rank[$1]! } }
        // A few windows stay together.
        guard items.count > calm else {
            return Plan(workspaces: [Workspace(groups: [.work], windows: items.map(\.id))], hidden: [], landing: 0)
        }
        var workspaces = Group.allCases.compactMap { g -> Workspace? in
            let ids = items.filter { group(of: $0) == g }.map(\.id)
            return ids.isEmpty ? nil : Workspace(groups: [g], windows: ids)
        }
        // The two smallest join up while together they still fit a calm Workspace.
        while workspaces.count > 1 {
            let bySize = workspaces.indices.sorted { workspaces[$0].windows.count < workspaces[$1].windows.count }
            let (a, b) = (bySize[0], bySize[1])
            guard workspaces[a].windows.count + workspaces[b].windows.count <= calm || workspaces.count > limit else { break }
            let (keep, gone) = (min(a, b), max(a, b))
            workspaces[keep].groups += workspaces[gone].groups
            workspaces[keep].windows = byUse(workspaces[keep].windows + workspaces[gone].windows)
            workspaces.remove(at: gone)
        }
        // A kind with more than a Workspace holds spills into the next one, while there's one free.
        var i = 0
        while i < workspaces.count, workspaces.count < limit {
            if workspaces[i].windows.count > most {
                let rest = Array(workspaces[i].windows[most...])
                workspaces[i].windows = Array(workspaces[i].windows.prefix(most))
                workspaces.insert(Workspace(groups: workspaces[i].groups, windows: rest), at: i + 1)
            }
            i += 1
        }
        // Past that, the least recently used are hidden.
        var hidden: [WindowID] = []
        for i in workspaces.indices where workspaces[i].windows.count > most {
            hidden += workspaces[i].windows[most...]
            workspaces[i].windows = Array(workspaces[i].windows.prefix(most))
        }
        let landing = workspaces.firstIndex { $0.windows.contains(items[0].id) } ?? 0
        return Plan(workspaces: workspaces, hidden: byUse(hidden), landing: landing)
    }
}
