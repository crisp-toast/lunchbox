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
        let items = [item(1, xcode)] + (2...10).map { item(WindowID($0), safari) }
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.windows) == [[1], [2, 3, 4, 5], [6, 7, 8, 9]])
        #expect(plan.workspaces.map(\.groups) == [[.work], [.web], [.web]])
        #expect(plan.hidden == [10])
    }

    @Test func pastThreeFullWorkspacesTheOldestAreHidden() {
        let items = (1...20).map { item(WindowID($0), safari) }
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.windows) == [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]])
        #expect(plan.hidden == Array(13...20))
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
