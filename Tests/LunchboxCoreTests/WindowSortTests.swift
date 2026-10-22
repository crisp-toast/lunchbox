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

    @Test func aBigKindSpillsIntoAFreeWorkspaceBeforeAnythingHides() {
        let items = [item(1, xcode)] + (2...10).map { item(WindowID($0), safari) }
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.windows) == [[1], [2, 3, 4, 5, 6, 7], [8, 9, 10]])
        #expect(plan.workspaces.map(\.groups) == [[.work], [.web], [.web]])
        #expect(plan.hidden.isEmpty)
    }

    @Test func pastThreeFullWorkspacesTheOldestAreHidden() {
        let items = (1...20).map { item(WindowID($0), safari) }
        let plan = WindowSort.plan(items)
        #expect(plan.workspaces.map(\.windows) == [[1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12], [13, 14, 15, 16, 17, 18]])
        #expect(plan.hidden == [19, 20])
    }

    @Test func onlyAsManyWorkspacesAsItTakes() {
        #expect(WindowSort.plan([]).workspaces.isEmpty)
        #expect(WindowSort.plan([item(1, safari)]).workspaces.count == 1)
        let items = (1...6).map { item(WindowID($0), xcode) }
        #expect(WindowSort.plan(items).workspaces.count == 1)
        #expect(WindowSort.plan(items, limit: 1).workspaces.count == 1)
    }
}
