import CoreGraphics
import Foundation
import Testing
@testable import TesselCore

private let t0 = 1_800_000_000.0

@Suite struct NotAnnoying {
    @Test func twoUndosInARowAndItStops() {
        var ledger = UndoLedger()
        #expect(ledger.allows("place|com.apple.mail"))
        let once = ledger.undone("place|com.apple.mail")
        #expect(!once)
        #expect(ledger.allows("place|com.apple.mail"))
        let twice = ledger.undone("place|com.apple.mail")
        #expect(twice)
        #expect(!ledger.allows("place|com.apple.mail"))
        #expect(ledger.allows("place|com.apple.Notes")) // only that thing
    }

    @Test func leavingItBeStartsTheCountOver() {
        var ledger = UndoLedger()
        ledger.undone("arrange|x")
        ledger.kept("arrange|x")
        ledger.undone("arrange|x")
        #expect(ledger.allows("arrange|x"))
    }

    @Test func forgettingALessonLetsItTryAgain() {
        var ledger = UndoLedger()
        ledger.undone("place|com.apple.mail")
        ledger.undone("place|com.apple.mail")
        ledger.forget("place|com.apple.mail")
        #expect(ledger.allows("place|com.apple.mail"))
        ledger.undone("arrange|a|1")
        ledger.undone("arrange|a|1")
        ledger.forget(prefix: "arrange|")
        #expect(ledger.allows("arrange|a|1"))
    }

    @Test func oneQuietLineSaysWhatHappenedAndWhichKeyUndoesIt() {
        #expect(QuietLine.text(for: [.floated(app: "TextEdit")], undoKey: "⌘ Page Up")
                == "TextEdit floats, like the last one · ⌘ Page Up tiles it")
        #expect(QuietLine.text(for: [.sent(app: "Mail", space: 1)], undoKey: "⌘ Page Up")
                == "Mail opened in Workspace 2 · ⌘ Page Up keeps it here")
        #expect(QuietLine.text(for: [.followed(app: "Mail", space: 1)], undoKey: "⌘ Page Up")
                == "Mail lives in Workspace 2 · ⌘ Page Up takes it back")
        #expect(QuietLine.text(for: [.arranged(app: "Simulator")], undoKey: nil) == "Simulator is back in its usual spot")
    }

    @Test func manyThingsAtOnceShareOneLine() {
        let login: [AutomaticAction] = [.sent(app: "Mail", space: 1), .sent(app: "Messages", space: 1), .sent(app: "Slack", space: 2)]
        #expect(QuietLine.text(for: login, undoKey: "⌘ Page Up") == "3 windows went to their Workspaces · ⌘ Page Up keeps them here")
        #expect(QuietLine.text(for: [.floated(app: "A"), .arranged(app: "B")], undoKey: nil) == "2 windows went where they usually go")
    }

    @Test func aWindowPlacedForYouNeverTakesYouThere() {
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: false, windowHere: nil,
                                    settling: false, placedForYou: true) == .stay)
        // Without it, focusing a window elsewhere still goes there, as before.
        #expect(ForeignFocus.decide(summoned: false, fromDockMenu: false, fromDockClick: false, windowHere: nil,
                                    settling: false) == .goThere)
    }
}

@Suite struct WorkspaceHomes {
    private func settled(_ app: String, in space: Int) -> WorkspaceMemory {
        var m = WorkspaceMemory()
        m.moved(app, to: space, at: t0)
        m.lived(app, in: space, seconds: 700)
        return m
    }

    @Test func nothingUntilYouMoveSomething() {
        var m = WorkspaceMemory()
        m.lived("com.apple.mail", in: 1, seconds: 10_000)
        #expect(m.home(of: "com.apple.mail") == nil)
        #expect(m.placement(for: "com.apple.mail", requested: false, current: 0, appSpaces: [], allowed: true) == nil)
    }

    @Test func movedAndLeftThereTenMinutesMakesAHome() {
        var m = WorkspaceMemory()
        m.moved("com.apple.mail", to: 1, at: t0)
        m.lived("com.apple.mail", in: 1, seconds: 300)
        #expect(m.home(of: "com.apple.mail") == nil) // five minutes isn't enough
        m.lived("com.apple.mail", in: 1, seconds: 300)
        #expect(m.home(of: "com.apple.mail") == 1)
        #expect(m.placement(for: "com.apple.mail", requested: false, current: 0, appSpaces: [], allowed: true) == 1)
        #expect(m.placement(for: "com.apple.mail", requested: false, current: 0, appSpaces: [1], allowed: true) == 1)
    }

    @Test func whatYouOpenFromTesselComesToYou() {
        let m = settled("com.apple.mail", in: 1)
        #expect(m.placement(for: "com.apple.mail", requested: true, current: 0, appSpaces: [], allowed: true) == nil)
    }

    @Test func silentWhenTheAppIsAlsoElsewhere() {
        let m = settled("com.apple.mail", in: 1)
        #expect(m.placement(for: "com.apple.mail", requested: false, current: 0, appSpaces: [0], allowed: true) == nil)
        #expect(m.placement(for: "com.apple.mail", requested: false, current: 0, appSpaces: [1, 2], allowed: true) == nil)
    }

    @Test func alreadyThereOrStoppedMeansNothingHappens() {
        let m = settled("com.apple.mail", in: 1)
        #expect(m.placement(for: "com.apple.mail", requested: false, current: 1, appSpaces: [], allowed: true) == nil)
        #expect(m.placement(for: "com.apple.mail", requested: false, current: 0, appSpaces: [], allowed: false) == nil)
    }

    @Test func aHomeYouDontKeepItInIsntTrusted() {
        var m = settled("com.apple.mail", in: 1)
        m.lived("com.apple.mail", in: 0, seconds: 200) // 700 of 900 seconds is under nine tenths
        #expect(m.home(of: "com.apple.mail") == nil)
    }

    @Test func movingItElsewhereStartsOver() {
        var m = settled("com.apple.mail", in: 1)
        m.moved("com.apple.mail", to: 2, at: t0 + 1000)
        #expect(m.home(of: "com.apple.mail") == nil)
        m.lived("com.apple.mail", in: 2, seconds: 600)
        #expect(m.home(of: "com.apple.mail") == 2)
        // Moving it to the home it already has keeps the time it built up.
        m.moved("com.apple.mail", to: 2, at: t0 + 2000)
        #expect(m.home(of: "com.apple.mail") == 2)
    }

    @Test func forgettingAnAppForgetsItsHome() {
        var m = settled("com.apple.mail", in: 1)
        m.forget("com.apple.mail")
        #expect(m.home(of: "com.apple.mail") == nil)
    }

    @Test func itsSnapshotSurvivesARelaunch() throws {
        let m = settled("com.apple.mail", in: 1)
        let back = try JSONDecoder().decode(WorkspaceMemory.self, from: try JSONEncoder().encode(m))
        #expect(back == m)
        #expect(back.home(of: "com.apple.mail") == 1)
    }
}

@Suite struct UsualArrangements {
    /// Xcode wide on the left, Simulator narrow on the right, as you left them.
    private let apps: [WindowID: String] = [1: "com.apple.dt.Xcode", 2: "com.apple.iphonesimulator", 3: "com.apple.Terminal"]
    private var xcodeAndSimulator: Layout {
        Layout(columns: [Column(windows: [1], weight: 0.7), Column(windows: [2], weight: 0.3)])
    }

    @Test func anArrangementForgetsWindowNumbers() throws {
        let a = try #require(Arrangement(xcodeAndSimulator, apps: apps))
        #expect(a.apps == ["com.apple.dt.Xcode", "com.apple.iphonesimulator"])
        #expect(a.columns.map(\.slots) == [[Slot(app: "com.apple.dt.Xcode", n: 0)], [Slot(app: "com.apple.iphonesimulator", n: 0)]])
        #expect(abs(a.columns[0].weight - 0.7) < 1e-9)
        #expect(Arrangement(Layout(columns: [Column(windows: [1])]), apps: apps) == nil) // lone: see LoneShape
    }

    @Test func aNewWindowTakesItsUsualPlaceAndShare() throws {
        let a = try #require(Arrangement(xcodeAndSimulator, apps: apps))
        // Simulator quit and came back as window 9, with Xcode alone on screen.
        let now = Layout(columns: [Column(windows: [1])])
        var withApps = apps
        withApps[9] = "com.apple.iphonesimulator"
        let placed = try #require(a.place(9, app: "com.apple.iphonesimulator", in: now, apps: withApps))
        #expect(placed.columns.map(\.windows) == [[1], [9]])
        #expect(abs(placed.columns[0].weight - 0.7) < 1e-9)
        #expect(abs(placed.columns[1].weight - 0.3) < 1e-9)
    }

    @Test func itGoesOnTheSideItWasOnEvenWhenFocusIsElsewhere() throws {
        // Notes left of Safari, as you keep them; a new Notes window arrives.
        let ids: [WindowID: String] = [1: "com.apple.Notes", 2: "com.apple.Safari", 7: "com.apple.Notes"]
        let a = try #require(Arrangement(Layout(columns: [Column(windows: [1]), Column(windows: [2])]), apps: ids))
        let placed = try #require(a.place(7, app: "com.apple.Notes", in: Layout(columns: [Column(windows: [2])]), apps: ids))
        #expect(placed.columns.map(\.windows) == [[7], [2]])
    }

    @Test func stacksComeBackAsStacks() throws {
        let ids: [WindowID: String] = [1: "com.apple.mail", 2: "com.apple.MobileSMS", 3: "com.apple.Safari", 8: "com.apple.MobileSMS"]
        let usual = Layout(columns: [Column(windows: [1, 2], weights: [0.6, 0.4], weight: 0.4), Column(windows: [3], weight: 0.6)])
        let a = try #require(Arrangement(usual, apps: ids))
        let now = Layout(columns: [Column(windows: [1], weight: 0.5), Column(windows: [3], weight: 0.5)])
        let placed = try #require(a.place(8, app: "com.apple.MobileSMS", in: now, apps: ids))
        #expect(placed.columns.map(\.windows) == [[1, 8], [3]])
        #expect(placed.columns[0].weights.map { ($0 * 10).rounded() / 10 } == [0.6, 0.4])
    }

    @Test func windowsAlreadyThereNeverChangeOrder() throws {
        // You keep Xcode left of Simulator, but today Simulator is on the left. A new Terminal
        // that usually goes on the right goes right, and the other two stay where they are.
        let usual = Layout(columns: [Column(windows: [1]), Column(windows: [2]), Column(windows: [3])])
        let a = try #require(Arrangement(usual, apps: apps))
        let today = Layout(columns: [Column(windows: [2]), Column(windows: [1])])
        let placed = try #require(a.place(3, app: "com.apple.Terminal", in: today, apps: apps))
        #expect(placed.columns.map(\.windows) == [[2], [1], [3]])
    }

    @Test func otherAppsGetNothing() throws {
        let a = try #require(Arrangement(xcodeAndSimulator, apps: apps))
        #expect(a.place(3, app: "com.apple.Terminal", in: Layout(columns: [Column(windows: [1])]), apps: apps) == nil)
    }

    @Test func theArrangementThatStoodLongestWins() throws {
        var memory = ArrangementMemory()
        let wide = try #require(Arrangement(xcodeAndSimulator, apps: apps))
        let even = try #require(Arrangement(Layout(columns: [Column(windows: [2]), Column(windows: [1])]), apps: apps))
        memory.record(wide, on: "2560x1415", dwell: 20, at: t0)
        #expect(memory.arrangement(display: "2560x1415", apps: wide.apps, now: t0) == nil) // 20 s isn't a habit yet
        memory.record(wide, on: "2560x1415", dwell: 600, at: t0 + 600)
        memory.record(even, on: "2560x1415", dwell: 120, at: t0 + 700)
        #expect(memory.arrangement(display: "2560x1415", apps: wide.apps, now: t0 + 800) == wide)
        #expect(memory.arrangement(display: "1920x1050", apps: wide.apps, now: t0 + 800) == nil) // another display
        memory.record(even, on: "2560x1415", dwell: 3600, at: t0 + 4400)
        #expect(memory.arrangement(display: "2560x1415", apps: wide.apps, now: t0 + 4400) == even)
    }

    @Test func loneShapesAndForgetting() throws {
        var memory = ArrangementMemory()
        memory.recordLone("com.apple.Safari", shape: LoneShape(scale: 0.8, height: 0.9), on: "2560x1415")
        #expect(memory.loneShape(of: "com.apple.Safari", on: "2560x1415") == LoneShape(scale: 0.8, height: 0.9))
        #expect(memory.loneShape(of: "com.apple.Safari", on: "1920x1050") == nil)
        memory.forget(ArrangementMemory.loneKey(display: "2560x1415", app: "com.apple.Safari"))
        #expect(memory.loneShape(of: "com.apple.Safari", on: "2560x1415") == nil)
    }

    @Test func replayingTheLogRemembersTheSame() throws {
        let wide = try #require(Arrangement(xcodeAndSimulator, apps: apps))
        let events: [ArrangeEvent] = [
            .arranged(wide, on: "2560x1415", dwell: 600, at: t0),
            .lone("com.apple.Safari", shape: LoneShape(scale: 0.7, height: nil), on: "2560x1415", at: t0 + 1),
            .forgot(ArrangementMemory.loneKey(display: "2560x1415", app: "com.apple.Safari"), at: t0 + 2),
        ]
        let memory = ArrangementMemory.replay(events, now: t0 + 10)
        #expect(memory.arrangement(display: "2560x1415", apps: wide.apps, now: t0 + 10) == wide)
        #expect(memory.loneShape(of: "com.apple.Safari", on: "2560x1415") == nil)
    }
}
