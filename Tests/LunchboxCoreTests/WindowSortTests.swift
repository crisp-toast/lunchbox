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
        for count in 0...60 {
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
