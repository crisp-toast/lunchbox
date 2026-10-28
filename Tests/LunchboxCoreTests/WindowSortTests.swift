import CoreGraphics
import Testing
@testable import LunchboxCore

/// Sorting a messy desktop into Workspaces by kind, only as many as it takes.
@Suite struct WindowSorting {
    func item(_ id: WindowID, _ bundle: String?, category: String? = nil) -> WindowSort.Item {
        WindowSort.Item(id: id, bundleID: bundle, category: category)
    }
    let xcode = "com.apple.dt.Xcode", safari = "com.apple.Safari", slack = "com.tinyspeck.slackmacgap"
    let notes = "com.apple.Notes", music = "com.apple.Music", arc = "company.thebrowser.Browser"

    @Test func kindsComeFromTheAppAndItsCategory() {
        #expect(WindowSort.group(of: item(1, safari)) == .web)
        #expect(WindowSort.group(of: item(1, slack)) == .talk)
        #expect(WindowSort.group(of: item(1, "com.example.chat", category: "public.app-category.social-networking")) == .talk)
        #expect(WindowSort.group(of: item(1, xcode, category: "public.app-category.developer-tools")) == .work)
        #expect(WindowSort.group(of: item(1, nil)) == .work)
    }

    @Test func aFewWindowsStayTogether() {
        let plan = WindowSort.plan([item(1, xcode), item(2, safari), item(3, slack), item(4, music)])
        #expect(plan.workspaces.map(\.windows) == [[1, 2, 3, 4]])
        #expect(plan.hidden.isEmpty)
        #expect(plan.landing == 0)
    }

    @Test func aMessSortsIntoThreeKindsInOrder() {
        let items = [item(1, safari), item(2, notes), item(3, xcode), item(4, arc), item(5, safari),
                     item(6, slack), item(7, music), item(8, "com.apple.mail")]
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.groups) == [[.work], [.web], [.talk]])
        #expect(plan.workspaces.map(\.windows) == [[2, 3], [1, 4, 5], [6, 7, 8]])
        // It ends up where the window used last went.
        #expect(plan.landing == 1)
    }

    @Test func smallKindsJoinUpWhileTheyFitACalmWorkspace() {
        // Work 3, web 1, chat 1: the web and chat join, and fit beside each other.
        let items = [item(1, xcode), item(2, notes), item(3, "com.apple.Terminal"), item(4, safari), item(5, slack)]
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.groups) == [[.work], [.web, .talk]])
        #expect(plan.workspaces.map(\.windows) == [[1, 2, 3], [4, 5]])
        #expect(plan.workspaces[1].title == "The web · Chat & music")
    }

    @Test func joinedWindowsKeepTheirOrderOfUse() {
        // Web 2 and chat 2 join (4 fit calmly), in the order they were last used.
        let items = [item(1, slack), item(2, safari), item(3, xcode), item(4, xcode), item(5, xcode),
                     item(6, xcode), item(7, music), item(8, arc)]
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.windows) == [[3, 4, 5, 6], [1, 2, 7, 8]])
        #expect(plan.landing == 1)
    }

    @Test func aBigKindSpillsIntoAFreeWorkspaceBeforeAnyWorkspaceGetsCrowded() {
        // Five of one kind: a 2×2 and one more Workspace, never five squeezed into one.
        let five = (1...5).map { item(WindowID($0), xcode) }
        #expect(WindowSort.plan(five).workspaces.map(\.windows) == [[1, 2, 3, 4], [5]])
        // Nine of one kind and every Workspace taken: its two share a third row, nothing hidden.
        let items = [item(1, xcode)] + (2...10).map { item(WindowID($0), safari) }
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.windows) == [[1], [2, 3, 4, 5, 6], [7, 8, 9, 10]])
        #expect(plan.workspaces.map(\.groups) == [[.work], [.web], [.web]])
        #expect(plan.hidden.isEmpty)
    }

    @Test func whatSpillsCanShareWithASmallKind() {
        // Six of your work and one chat: a 2×2, then the two left over beside the chat.
        let items = (1...6).map { item(WindowID($0), xcode) } + [item(7, slack)]
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.windows) == [[1, 2, 3, 4], [5, 6, 7]])
        #expect(plan.workspaces.map(\.groups) == [[.work], [.work, .talk]])
    }

    @Test func whenEveryWorkspaceIsTakenTheyShareAThirdRow() {
        // Five of each kind: three Workspaces of five, none hidden.
        let items = (1...15).map { item(WindowID($0), [xcode, safari, slack][($0 - 1) % 3]) }
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map { $0.windows.count } == [5, 5, 5])
        #expect(plan.hidden.isEmpty)
    }

    @Test func aTonOfWindowsShowsSixAWorkspaceAndHidesTheOldest() {
        // Thirty: three Workspaces of six (three rows of two), the twelve used least lately hidden.
        let items = (1...30).map { item(WindowID($0), [xcode, safari, slack][($0 - 1) % 3]) }
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map { $0.windows.count } == [6, 6, 6])
        #expect(plan.hidden == Array(19...30))
        // One kind alone fills all three, evenly.
        let web = WindowSort.plan((1...20).map { item(WindowID($0), safari) })
        #expect(web.workspaces.map(\.windows) == [Array(1...6), Array(7...12), Array(13...18)])
        #expect(web.hidden == [19, 20])
    }

    @Test func noWindowIsEverLostOrDoubled() {
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % n
        }
        let apps = [xcode, safari, slack, notes, music, arc, nil]
        for count in Array(0...60) + [80, 150, 400] {
            for fit in [2, 4, 6] {
                for limit in [1, 2, 3] {
                    let items = (0..<count).map { item(WindowID(1000 + $0), apps[next(apps.count)]) }
                    let plan = WindowSort.plan(items, limit: limit, fit: fit)
                    let placed = plan.workspaces.flatMap(\.windows) + plan.hidden
                    #expect(placed.sorted() == items.map(\.id).sorted(), "count \(count) fit \(fit) limit \(limit)")
                    #expect(plan.workspaces.count <= limit)
                    #expect(plan.workspaces.allSatisfy { !$0.windows.isEmpty && $0.windows.count <= fit + max(1, fit / 2) })
                    // Crowding and hiding only once every Workspace is taken.
                    if plan.workspaces.contains(where: { $0.windows.count > fit }) || !plan.hidden.isEmpty {
                        #expect(plan.workspaces.count == limit, "count \(count) fit \(fit) limit \(limit)")
                    }
                    if count > 0 { #expect(plan.workspaces.indices.contains(plan.landing)) }
                    #expect(!plan.hidden.contains(items.first?.id ?? 0))
                }
            }
        }
    }

    @Test func aWorkspaceHoldsTwoWindowsAColumn() {
        #expect(WindowSort.fit(forWidth: 1920) == 4)
        #expect(WindowSort.fit(forWidth: 2560) == 4)
        #expect(WindowSort.fit(forWidth: 3440) == 6)
        #expect(WindowSort.fit(forWidth: 900) == 2)
        // An ultrawide takes six of a kind in one Workspace.
        let six = (1...6).map { item(WindowID($0), xcode) }
        #expect(WindowSort.plan(six, fit: 6).workspaces.count == 1)
        #expect(WindowSort.plan(six).workspaces.count == 2)
    }

    @Test func sortedWorkspacesShareTheScreenEvenly() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        // Three: one column and an even stack of two, not a half and two quarters.
        let three = WindowSort.layout([1, 2, 3], maxColumns: 2).frames(in: screen, gap: 8)
        #expect(abs(three[2]!.height - three[3]!.height) <= 1)
        #expect(abs(three[1]!.width - three[2]!.width) <= 1)
        // Four: a 2×2 of equal tiles.
        let four = WindowSort.layout([1, 2, 3, 4], maxColumns: 2).frames(in: screen, gap: 8)
        let sizes = Set(four.values.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" })
        #expect(sizes.count == 1)
        // Six, every Workspace taken: two even stacks of three, no strips.
        let crowded = WindowSort.layout(Array(1...6), maxColumns: 2).frames(in: screen, gap: 8).values
        #expect(crowded.map(\.height).max()! - crowded.map(\.height).min()! <= 1) // a point of rounding
        #expect(crowded.map(\.width).max()! - crowded.map(\.width).min()! <= 1)
        // Six on an ultrawide: three columns of two, all the same.
        let wide = WindowSort.layout(Array(1...6), maxColumns: 3).frames(in: CGRect(x: 0, y: 0, width: 3440, height: 1400), gap: 8)
        #expect(Set(wide.values.map { Int($0.height.rounded()) }).count == 1)
        #expect(Set(wide.values.map { Int($0.width.rounded()) }).count == 1)
    }

    @Test func onlyAsManyWorkspacesAsItTakes() {
        #expect(WindowSort.plan([]).workspaces.isEmpty)
        #expect(WindowSort.plan([item(1, safari)]).workspaces.count == 1)
        let items = (1...4).map { item(WindowID($0), xcode) }
        #expect(WindowSort.plan(items).workspaces.count == 1)
        #expect(WindowSort.plan((1...6).map { item(WindowID($0), xcode) }, limit: 1).workspaces.count == 1)
    }
}

/// Sorting by how you work: what you've been in decides where you land, what stays together and
/// what gets the most room.
@Suite struct SortingByUse {
    func item(_ id: WindowID, _ bundle: String?, use: Double = 0, title: String? = nil, category: String? = nil) -> WindowSort.Item {
        WindowSort.Item(id: id, bundleID: bundle, category: category, title: title, use: use)
    }
    let xcode = "com.apple.dt.Xcode", safari = "com.apple.Safari", slack = "com.tinyspeck.slackmacgap", chrome = "com.google.Chrome"
    let messages = "com.apple.MobileSMS", music = "com.apple.Music", terminal = "com.apple.Terminal", notes = "com.apple.Notes"
    let code = "com.microsoft.VSCode", figma = "com.figma.Desktop"

    @Test func makingMusicIsWorkListeningIsNot() {
        #expect(WindowSort.group(of: item(1, "com.apple.logic10", category: "public.app-category.music")) == .work)
        #expect(WindowSort.group(of: item(1, "ai.storyteller.soundcraft", category: "public.app-category.music")) == .work)
        #expect(WindowSort.group(of: item(1, "com.steinberg.cubase14", category: "public.app-category.music")) == .work)
        #expect(WindowSort.group(of: item(1, music, category: "public.app-category.music")) == .talk)
        #expect(WindowSort.group(of: item(1, "com.example.radio", category: "public.app-category.music")) == .talk)
    }

    @Test func howMuchRoomAWindowWantsComesFromItsApp() {
        #expect(WindowSort.comfort(of: item(1, safari)) == .wide)
        #expect(WindowSort.comfort(of: item(1, xcode)) == .wide)
        #expect(WindowSort.comfort(of: item(1, "com.jetbrains.intellij")) == .wide)
        #expect(WindowSort.comfort(of: item(1, "com.example.paint", category: "public.app-category.graphics-design")) == .wide)
        #expect(WindowSort.comfort(of: item(1, messages)) == .narrow)
        #expect(WindowSort.comfort(of: item(1, terminal)) == .narrow)
        #expect(WindowSort.comfort(of: item(1, "com.apple.mail")) == .usual)
        #expect(WindowSort.comfort(of: item(1, "com.example.thing")) == .usual)
    }

    @Test func theWindowYouveBeenInMattersMoreThanTheOneYouGlancedAt() {
        // An hour in Xcode, then a glance at Messages: you land in your work, Xcode first.
        let items = [item(1, messages, use: 5), item(2, xcode, use: 1800), item(3, notes, use: 200), item(4, safari, use: 60),
                     item(5, chrome, use: 30), item(6, slack, use: 20)]
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces[plan.landing].groups.first == .work)
        #expect(plan.workspaces[plan.landing].windows.first == 2)
        #expect(plan.weights[2]! > 2 * plan.weights[1]!)
        // Chatting for half an hour is what you're doing, though.
        let chatting = [item(1, messages, use: 1800), item(2, xcode, use: 600)] + items.dropFirst(2)
        let later = WindowSort.plan(Array(chatting))
        #expect(later.workspaces[later.landing].windows.first == 1)
        // With no history yet, the window used last decides, as before.
        let fresh = WindowSort.plan(items.map { item($0.id, $0.bundleID) })
        #expect(fresh.workspaces[fresh.landing].windows.first == 1)
    }

    @Test func aBrowserWindowYouKeepGoingBackToStaysWithYourWork() {
        let items = [item(1, xcode, use: 1500), item(2, safari, use: 400), item(3, terminal, use: 300), item(4, safari, use: 20),
                     item(5, chrome, use: 10), item(6, slack, use: 60), item(7, notes, use: 5), item(8, music, use: 1)]
        let tied = WindowSort.plan(items, together: [WindowUsage.Pair(1, 2): 6])
        #expect(tied.workspaces[0].windows.contains(2))
        #expect(tied.workspaces[0].groups == [.work])
        #expect(!tied.workspaces[1].windows.contains(2))
        // One trip there and back isn't a habit, and a page you mostly read alongside other pages stays with the web.
        #expect(!WindowSort.plan(items, together: [WindowUsage.Pair(1, 2): 2]).workspaces[0].windows.contains(2))
        let webby = WindowSort.plan(items, together: [WindowUsage.Pair(1, 2): 6, WindowUsage.Pair(2, 4): 8])
        #expect(!webby.workspaces[0].windows.contains(2))
        // Chat never comes along, however often you check it.
        #expect(!WindowSort.plan(items, together: [WindowUsage.Pair(1, 6): 20]).workspaces[0].windows.contains(6))
    }

    @Test func aBigKindSplitsByProject() {
        let items = [item(1, xcode, use: 900, title: "Lunchbox — Tiler.swift"), item(2, xcode, use: 700, title: "DeltaBinder — App.swift"),
                     item(3, terminal, use: 300, title: "deltabinder — zsh — 120×40"), item(4, terminal, use: 200, title: "lunchbox — zsh"),
                     item(5, code, use: 100, title: "notes.md — lunchbox"), item(6, code, use: 50, title: "README.md — deltabinder"),
                     item(7, notes, use: 20)]
        let plan = WindowSort.plan(items)
        #expect(Set(plan.workspaces[0].windows) == [1, 4, 5, 7])
        #expect(Set(plan.workspaces[1].windows) == [2, 3, 6])
        #expect(plan.workspaces.map(\.groups) == [[.work], [.work]])
        // Windows you go between belong together too, whatever their titles.
        let used = WindowSort.plan(items.map { item($0.id, $0.bundleID, use: $0.use) },
                                   together: [WindowUsage.Pair(1, 6): 6, WindowUsage.Pair(2, 3): 6])
        #expect(used.workspaces[0].windows.contains(6))
        #expect(Set(used.workspaces[1].windows).isSuperset(of: [2, 3]))
    }

    @Test func anAppsWindowsStayTogetherWhenAKindSplits() {
        // Nine Safari windows and three Chrome: the Chrome ones share a Workspace.
        let items = (1...9).map { item(WindowID($0), safari, use: Double(10 * $0)) } + (10...12).map { item(WindowID($0), chrome, use: 5) }
        let plan = WindowSort.plan(items, limit: 3)
        let chromes = plan.workspaces.indices.filter { s in plan.workspaces[s].windows.contains { $0 >= 10 } }
        #expect(chromes.count == 1)
    }

    @Test func whatGoesOutOfTheWayIsWhatYouUseLeast() {
        // Thirty windows: one you used long ago but for ages stays; one used recently for a moment goes.
        var items = (1...30).map { item(WindowID($0), [xcode, safari, slack][($0 - 1) % 3], use: 30) }
        items[27] = item(28, xcode, use: 3000)
        let plan = WindowSort.plan(items)
        #expect(!plan.hidden.contains(28))
        #expect(plan.hidden.count == 12)
        #expect(plan.workspaces.flatMap(\.windows).count == 18)
    }

    // MARK: Layout

    let desk = CGRect(x: 0, y: 0, width: 1920, height: 1050)
    func room(_ screen: CGRect) -> (area: CGSize, gap: CGFloat) { (CGSize(width: screen.width - 16, height: screen.height - 16), 8) }
    func frames(_ items: [WindowSort.Item], on screen: CGRect, limits: [WindowID: SizeLimits] = [:]) -> [WindowID: CGRect] {
        let plan = WindowSort.plan(items, fit: WindowSort.fit(forWidth: screen.width))
        var all: [WindowID: CGRect] = [:]
        for w in plan.workspaces {
            let layout = WindowSort.layout(w.windows, maxColumns: Layout.maxColumns(forWidth: screen.width), weights: plan.weights,
                                           comforts: plan.comforts, limits: limits, room: room(screen))
            all.merge(layout.frames(in: screen, gap: 8, limits: limits)) { a, _ in a }
        }
        return all
    }

    @Test func theWindowYouUseMostGetsTheBigTile() {
        let f = frames([item(2, safari, use: 60), item(1, xcode, use: 1800)], on: desk)
        #expect(f[1]!.width > f[2]!.width + 150)
        #expect(f[1]!.minX < f[2]!.minX)
        // Two windows used about as much, or before there's any history, share it evenly.
        let even = frames([item(1, xcode, use: 900), item(2, safari, use: 850)], on: desk)
        #expect(abs(even[1]!.width - even[2]!.width) <= 1)
        let fresh = frames([item(1, xcode), item(2, safari)], on: desk)
        #expect(abs(fresh[1]!.width - fresh[2]!.width) <= 1)
    }

    @Test func chatAndTerminalsTakeANarrowColumn() {
        let f = frames([item(1, xcode), item(2, messages)], on: desk)
        #expect(f[2]!.width < 800 && f[1]!.width > 1100)
        // Your work and two narrow windows: the work full height on the left, the others stacked beside it.
        let three = frames([item(1, xcode), item(2, terminal), item(3, notes)], on: desk)
        #expect(three[1]!.height > 1000 && three[1]!.width > three[2]!.width)
        #expect(three[2]!.minX == three[3]!.minX)
        // Three chats on a desktop display: a tall column each.
        let chats = frames([item(1, messages), item(2, slack), item(3, music)], on: desk)
        #expect(chats.values.allSatisfy { $0.height > 1000 && $0.width > 600 })
        // Two that want width and two that don't, used about as much: the wide ones get the wide column.
        let four = frames([item(1, xcode, use: 600), item(2, terminal, use: 500), item(3, notes, use: 550), item(4, figma, use: 580)], on: desk)
        #expect(four[1]!.minX == four[4]!.minX && four[1]!.width > four[2]!.width)
    }

    @Test func aCrowdedWorkspaceStaysEven() {
        let ids: [WindowID] = Array(1...6)
        let weights = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == 1 ? 3.4 : 1.1) })
        let smart = WindowSort.layout(ids, maxColumns: 2, weights: weights, room: room(desk))
        #expect(smart == WindowSort.layout(ids, maxColumns: 2))
    }

    @Test func noWindowIsSqueezedToMakeRoomForAnother() {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % n
        }
        let apps = [xcode, safari, slack, notes, music, terminal, code, messages, "com.apple.mail", nil]
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 870), desk, CGRect(x: 0, y: 0, width: 2560, height: 1410),
                       CGRect(x: 0, y: 0, width: 3440, height: 1410), CGRect(x: 0, y: 0, width: 900, height: 1200)]
        for round in 0..<300 {
            let screen = screens[round % screens.count]
            let count = 2 + next(5)
            let ids = (0..<count).map { WindowID(100 + $0) }
            let items = ids.map { item($0, apps[next(apps.count)], use: Double(next(4) == 0 ? 0 : next(3000))) }
            let plan = WindowSort.plan(items)
            let maxColumns = Layout.maxColumns(forWidth: screen.width)
            let order = plan.workspaces.flatMap(\.windows)
            let smart = WindowSort.layout(order, maxColumns: maxColumns, weights: plan.weights, comforts: plan.comforts, room: room(screen))
            let even = WindowSort.layout(order, maxColumns: maxColumns)
            #expect(smart.windows.sorted() == ids.sorted(), "round \(round)")
            let a = smart.frames(in: screen, gap: 8), b = even.frames(in: screen, gap: 8)
            for id in ids {
                let smallest = plan.comforts[id]!.smallest
                func usable(_ r: CGRect) -> Bool { r.width >= smallest.width && r.height >= smallest.height }
                if usable(b[id]!) { #expect(usable(a[id]!), "round \(round) window \(id)") }
                #expect(screen.insetBy(dx: 7, dy: 7).contains(a[id]!), "round \(round) window \(id)")
            }
            // Stacks read top down: the bigger window on top.
            for column in smart.columns {
                let heights = column.windows.map { a[$0]!.height }
                #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 >= $1 - 1 }, "round \(round)")
            }
        }
    }

    @Test func windowsKeepTheSizesTheyNeed() {
        // A window that's at least 900 wide still gets that, beside the one you use most.
        let limits: [WindowID: SizeLimits] = [2: SizeLimits(minWidth: 900)]
        let f = frames([item(1, xcode, use: 1800), item(2, "com.example.wide", use: 10)], on: desk, limits: limits)
        #expect(f[2]!.width >= 900)
        #expect(f[1]!.maxX <= f[2]!.minX)
    }
}

/// How long each window had focus lately, and which you go between.
@Suite struct WindowUsageTests {
    @Test func useFadesByHalfEveryHalfHour() {
        var usage = WindowUsage()
        usage.used(1, for: 600, at: 0)
        #expect(abs(usage.seconds(1, at: WindowUsage.halfLife) - 300) < 0.01)
        usage.used(1, for: 100, at: WindowUsage.halfLife)
        #expect(abs(usage.seconds(1, at: WindowUsage.halfLife) - 400) < 0.01)
        #expect(usage.seconds(2, at: 0) == 0)
    }

    @Test func goingBetweenTwoWindowsTiesThem() {
        var usage = WindowUsage()
        usage.switched(from: 1, to: 2, at: 0)
        usage.switched(from: 2, to: 1, at: 10)
        usage.switched(from: 1, to: 1, at: 20)
        #expect(abs((usage.together(at: 10)[WindowUsage.Pair(2, 1)] ?? 0) - 2) < 0.01)
        #expect(usage.together(at: 10).count == 1)
        // A day later the tie is gone.
        #expect(usage.together(at: 86_400).isEmpty)
    }

    @Test func aClosedWindowIsForgotten() {
        var usage = WindowUsage()
        usage.used(1, for: 60, at: 0)
        usage.switched(from: 1, to: 2, at: 0)
        usage.switched(from: 2, to: 3, at: 0)
        usage.forget(1)
        #expect(usage.seconds(1, at: 0) == 0)
        #expect(usage.together(at: 0).keys.map { [$0.a, $0.b] } == [[2, 3]])
    }
}

@Suite struct SortedArrangements {
    @Test func theSameArrangementAtAnyScale() {
        let a = Layout(columns: [Column(windows: [1], weight: 0.6), Column(windows: [2, 3], weights: [0.5, 0.5], weight: 0.4)])
        let b = Layout(columns: [Column(windows: [1], weight: 3), Column(windows: [2, 3], weights: [2, 2], weight: 2)])
        #expect(WindowSort.sameArrangement(a, b))
        // Other shares, another order or another window: not the same.
        let wider = Layout(columns: [Column(windows: [1], weight: 0.65), Column(windows: [2, 3], weight: 0.35)])
        #expect(!WindowSort.sameArrangement(a, wider))
        let swapped = Layout(columns: [Column(windows: [1], weight: 0.6), Column(windows: [3, 2], weight: 0.4)])
        #expect(!WindowSort.sameArrangement(a, swapped))
        #expect(!WindowSort.sameArrangement(a, nil))
        #expect(WindowSort.sameArrangement(nil, nil))
    }
}

/// Windows that can't all be on screen at once don't share a Workspace.
@Suite struct SortingWhatFits {
    let area = CGSize(width: 1904, height: 1034)
    let music = CGSize(width: 980, height: 600), podcasts = CGSize(width: 1000, height: 512)

    @Test func whatCanShareAScreen() {
        // Music and Podcasts: too wide side by side, too tall stacked.
        #expect(!WindowSort.canShare([music, podcasts], area: area, gap: 8, columns: 3))
        #expect(!WindowSort.canShare([music, podcasts, .zero], area: area, gap: 8, columns: 3))
        // Either one with windows that take any size is fine, and so are both on a big display.
        #expect(WindowSort.canShare([music, .zero, .zero, .zero], area: area, gap: 8, columns: 3))
        #expect(WindowSort.canShare([music, podcasts], area: CGSize(width: 2544, height: 1394), gap: 8, columns: 3))
        // Two tall ones stack only if the height allows.
        #expect(WindowSort.canShare([CGSize(width: 0, height: 500), CGSize(width: 0, height: 500)], area: area, gap: 8, columns: 1))
        #expect(!WindowSort.canShare([CGSize(width: 0, height: 600), CGSize(width: 0, height: 600)], area: area, gap: 8, columns: 1))
        #expect(WindowSort.canShare([.zero, .zero], area: area, gap: 8, columns: 2))
    }

    func item(_ id: WindowID, _ bundle: String) -> WindowSort.Item { WindowSort.Item(id: id, bundleID: bundle, category: nil) }

    @Test func windowsThatCantShareGetTheirOwnWorkspace() {
        let mins: [WindowID: CGSize] = [5: podcasts, 6: music]
        func fits(_ ids: [WindowID]) -> Bool {
            WindowSort.canShare(ids.map { mins[$0] ?? .zero }, area: area, gap: 8, columns: 3)
        }
        // Your work, Safari, Podcasts and Music: Music, used least, gets a Workspace of its own.
        let items = [item(1, "com.apple.TextEdit"), item(2, "com.anthropic.claudefordesktop"), item(3, "com.apple.Terminal"),
                     item(4, "com.apple.Safari"), item(5, "com.apple.podcasts"), item(6, "com.apple.Music")]
        let plan = WindowSort.plan(items, fits: fits)
        #expect(plan.workspaces.map(\.windows) == [[1, 2, 3], [4, 5], [6]])
        #expect(plan.workspaces.map(\.groups) == [[.work], [.web, .talk], [.talk]])
        #expect(plan.workspaces.allSatisfy { fits($0.windows) })
        // A few windows together, but two can't share: they part.
        let few = WindowSort.plan([item(5, "com.apple.podcasts"), item(6, "com.apple.Music"), item(1, "com.apple.TextEdit")], fits: fits)
        #expect(few.workspaces.count == 2)
        #expect(few.workspaces.allSatisfy { fits($0.windows) })
        // Every Workspace taken: it joins one where it fits instead.
        let tight = WindowSort.plan(items, limit: 2, fits: fits)
        #expect(tight.workspaces.count == 2)
        #expect(tight.workspaces.allSatisfy { fits($0.windows) })
        #expect(Set(tight.workspaces.flatMap(\.windows)) == Set(1...6))
    }
}
