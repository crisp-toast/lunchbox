import Testing
@testable import LunchboxCore

@Suite struct WindowSearching {
    /// A probe desktop: 15 windows a person might have open, each found by its own words.
    static let desktop: [(String, String)] = [
        ("Slack", "#design-reviews"), ("Slack", "Huddle with Maya"), ("Mail", "Re: lunch Thursday? — Inbox"),
        ("Preview", "INV-2026-0042.pdf"), ("Google Chrome", "Pull request #142 · crisp-toast/tessel"),
        ("Google Chrome", "Flights SFO to JFK — Google Flights"), ("Xcode", "tessel — Tiler.swift"),
        ("Terminal", "~/code/tessel — zsh"), ("zoom.us", "Zoom Meeting"), ("Notes", "Groceries"),
        ("Numbers", "Q3 Budget"), ("Spotify", "Spotify Premium"), ("Calendar", "Calendar"),
        ("Finder", "Downloads"), ("Messages", "Mom"),
    ]

    static func windows(_ list: [(String, String)]) -> [SearchableWindow] {
        list.enumerated().map { i, w in
            SearchableWindow(id: UInt32(i), appID: "app." + w.0.lowercased(), appName: w.0, title: w.1)
        }
    }

    let search = WindowSearch(Self.windows(Self.desktop))

    func titles(_ query: String, listedApps: Set<String> = []) -> [String] {
        search.find(query, listedApps: listedApps).map(\.title)
    }

    @Test func findsTheProbesWindowsByTheirTitleWords() {
        let queries: [(String, Int)] = [
            ("design reviews", 0), ("huddle", 1), ("lunch thursday", 2), ("INV-2026-0042", 3),
            ("pull request 142", 4), ("google flights", 5), ("Tiler.swift", 6), ("terminal", 7),
            ("zoom meeting", 8), ("groceries", 9), ("q3 budget", 10), ("spotify", 11), ("calendar", 12),
            ("downloads", 13), ("messages mom", 14),
        ]
        var right = 0
        for (query, target) in queries where search.find(query).first?.id == UInt32(target) { right += 1 }
        #expect(right == 15)
    }

    @Test func aWordFindsWhereItStartsAWord() {
        #expect(titles("lunch") == ["Re: lunch Thursday? — Inbox"])
        #expect(titles("thu") == ["Re: lunch Thursday? — Inbox"])
        #expect(titles("tiler") == ["tessel — Tiler.swift"])
        #expect(titles("maya") == ["Huddle with Maya"])
        // Inside a word isn't the start of one.
        #expect(titles("unch").isEmpty)
        #expect(titles("iler").isEmpty)
    }

    @Test func theAppsNameFindsItsWindows() {
        #expect(titles("slack") == ["#design-reviews", "Huddle with Maya"])
        #expect(titles("chrome").count == 2)
        #expect(titles("zsh") == ["~/code/tessel — zsh"])
    }

    @Test func moreWordsMatchedLeavesTheRestOut() {
        // Every window with "tessel" matches the first word; only one has both.
        #expect(titles("tessel").count == 3)
        #expect(titles("tessel tiler") == ["tessel — Tiler.swift"])
        // A word nothing has doesn't hide what the other words find.
        #expect(titles("lunch thursdy") == ["Re: lunch Thursday? — Inbox"])
        #expect(titles("slack design") == ["#design-reviews"])
    }

    @Test func oneCommonWordOutOfALongSearchIsNoMatch() {
        // The search that listed Study App first: only "app" matched, one word of four.
        let search = WindowSearch(Self.windows([("Study App", "Study App"), ("Arc", "App Store Connect")]))
        #expect(search.find("app store connect website").map(\.title) == ["App Store Connect"])
        let none = WindowSearch(Self.windows([("Study App", "Study App")]))
        #expect(none.find("app store connect website").isEmpty)
        // Half the words is enough: a typo, or a word the title doesn't have.
        #expect(none.find("study ap").map(\.title) == ["Study App"])
        #expect(none.find("study notes").map(\.title) == ["Study App"])
    }

    @Test func everyWordOrNot() {
        #expect(search.matchesEveryWord("Tiler.swift", window: 6))
        #expect(!search.matchesEveryWord("github.com", window: 4))
        #expect(!search.matchesEveryWord("lunch", window: 99))
    }

    @Test func aShortCommonWordIsntEnoughOfTheQuery() {
        // "meetnellie.app" splits into meetnellie and app: app alone is too little of it.
        let search = WindowSearch(Self.windows([("Arc", "App Store Connect"), ("Arc", "Nellie — Meet Nellie")]))
        #expect(search.find("meetnellie.app").isEmpty)
        #expect(search.find("meet nellie").map(\.title) == ["Nellie — Meet Nellie"])
        #expect(search.find("app store").map(\.title) == ["App Store Connect"])
    }

    @Test func titleWordsCountForMoreThanTheAppsName() {
        let search = WindowSearch(Self.windows([("Notes", "Ideas"), ("Mail", "Notes from the offsite")]))
        #expect(search.find("notes").map(\.title) == ["Notes from the offsite", "Ideas"])
    }

    @Test func tiesKeepTheOrderGiven() {
        let list = Self.windows([("Safari", "Apple"), ("Safari", "GitHub"), ("Safari", "Maps")])
        #expect(WindowSearch(list).find("safari").map(\.title) == ["Apple", "GitHub", "Maps"])
        #expect(WindowSearch(list.reversed()).find("safari").map(\.title) == ["Maps", "GitHub", "Apple"])
    }

    @Test func aWholeWordBeatsTheStartOfOne() {
        let search = WindowSearch(Self.windows([("Xcode", "Tilers.md"), ("Xcode", "Tiler.swift")]))
        #expect(search.find("tiler").map(\.title) == ["Tiler.swift", "Tilers.md"])
    }

    @Test func anAppsOnlyWindowIsLeftToItsAppRow() {
        // Notes has one window; its app row in Summon already goes there.
        #expect(titles("notes", listedApps: ["app.notes"]).isEmpty)
        #expect(titles("notes") == ["Groceries"])
        // Unless the title says it too.
        #expect(titles("calendar", listedApps: ["app.calendar"]) == ["Calendar"])
        // Two windows: Summon lists both so you can pick.
        #expect(titles("slack", listedApps: ["app.slack"]).count == 2)
    }

    @Test func caseAccentsAndPunctuationDontMatter() {
        let search = WindowSearch(Self.windows([
            ("Pages", "Café menu"), ("Notes", "Tyler’s list"), ("Xcode", "LauncherPanel.swift"), ("Finder", "my_files"),
        ]))
        #expect(search.find("CAFE").map(\.title) == ["Café menu"])
        #expect(search.find("tylers").map(\.title) == ["Tyler’s list"])
        #expect(search.find("tyler").map(\.title) == ["Tyler’s list"])
        #expect(search.find("panel").map(\.title) == ["LauncherPanel.swift"])
        #expect(search.find("launcherpan").map(\.title) == ["LauncherPanel.swift"])
        #expect(search.find("files").map(\.title) == ["my_files"])
        #expect(search.find("  ").isEmpty)
        #expect(search.find("—").isEmpty)
    }

    @Test func words() {
        #expect(WindowSearch.words(in: "tessel — Tiler.swift", splittingHumps: true) == ["tessel", "tiler", "swift"])
        #expect(WindowSearch.words(in: "iPhone Mirroring", splittingHumps: true) == ["iphone", "i", "phone", "mirroring"])
        #expect(WindowSearch.words(in: "iPhone Mirroring", splittingHumps: false) == ["iphone", "mirroring"])
        #expect(WindowSearch.words(in: "INV-2026-0042.pdf", splittingHumps: true) == ["inv", "2026", "0042", "pdf"])
    }

    @Test func findingIsInstantForHundredsOfWindows() {
        var list: [(String, String)] = []
        for i in 0..<500 { list.append(("App \(i % 40)", "Document \(i) — draft for review, version \(i * 7)")) }
        let search = WindowSearch(Self.windows(list))
        let clock = ContinuousClock()
        var found = 0
        // A word typed one letter at a time, then a second word.
        let keystrokes = ["d", "dr", "dra", "draf", "draft", "draft r", "draft re", "draft rev", "draft revi", "draft review"]
        let elapsed = clock.measure {
            for query in keystrokes { found += search.find(query).count }
        }
        #expect(found > 0)
        // Generous, so a busy machine or a debug build doesn't fail it: 10 ms a keystroke at most.
        #expect(elapsed < .milliseconds(100))
    }
}

@Suite struct SummonOrder {
    typealias Row = Summon.Row<String, String>

    func names(_ rows: [Row]) -> [String] {
        rows.map {
            switch $0 {
            case .app(let a): return "app:" + a
            case .window(let w): return "window:" + w
            }
        }
    }

    func order(_ query: String, apps: [String], windows: [String], limit: Int = 8) -> [String] {
        let scored = apps.compactMap { name in Fuzzy.score(query, name).map { (app: name, nameScore: $0) } }
            .sorted { $0.nameScore > $1.nameScore }
        return names(Summon.order(apps: scored, windows: windows, limit: limit))
    }

    @Test func appsByNameThenWindowsThenLooseApps() {
        // "lunch" is in Launchpad only as letters in order: the lunch email comes first.
        #expect(order("lunch", apps: ["Launchpad"], windows: ["Re: lunch"]) == ["window:Re: lunch", "app:Launchpad"])
        // An app named by what you typed stays on top.
        #expect(order("mail", apps: ["Mail"], windows: ["Re: mail merge"]) == ["app:Mail", "window:Re: mail merge"])
        #expect(order("code", apps: ["Visual Studio Code"], windows: ["code review"])
            == ["app:Visual Studio Code", "window:code review"])
    }

    @Test func theListStopsAtItsLimit() {
        let windows = (1...10).map { "Notes \($0)" }
        let rows = order("notes", apps: ["Notes"], windows: windows, limit: 8)
        #expect(rows.count == 8)
        #expect(rows.first == "app:Notes")
    }

    @Test func appsGoByTheirOtherNamesToo() {
        // Xcode 27 has no Simulator app: it's in Device Hub.
        #expect(AppNames.score("simulator", name: "DeviceHub", bundleID: "com.apple.dt.Devices") != nil)
        #expect(Fuzzy.matchesName(AppNames.score("simulator", name: "DeviceHub", bundleID: "com.apple.dt.Devices")!))
        #expect(AppNames.score("system pref", name: "System Settings", bundleID: "com.apple.systempreferences") != nil)
        #expect(AppNames.score("simulator", name: "Notes", bundleID: "com.apple.Notes") == nil)
    }

    @Test func theListStopsAtTheLimit() {
        let windows = (1...10).map { "Notes \($0)" }
        let rows = order("notes", apps: ["Notes"], windows: windows, limit: 8)
        #expect(rows.count == 8)
        #expect(rows.first == "app:Notes")
    }

    @Test func nameMatchesAreTheStrongOnes() {
        #expect(Fuzzy.matchesName(Fuzzy.score("safari", "Safari")!))
        #expect(Fuzzy.matchesName(Fuzzy.score("saf", "Safari")!))
        #expect(Fuzzy.matchesName(Fuzzy.score("code", "Visual Studio Code")!))
        #expect(Fuzzy.matchesName(Fuzzy.score("vsc", "Visual Studio Code")!))
        #expect(!Fuzzy.matchesName(Fuzzy.score("afar", "Safari")!))
        #expect(!Fuzzy.matchesName(Fuzzy.score("xcd", "Xcode")!))
    }
}
