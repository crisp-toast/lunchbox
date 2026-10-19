import Foundation
import Testing
@testable import LunchboxCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// 2027-01-15 08:00 UTC.
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func daysAgo(_ n: Int) -> Date { utc.date(byAdding: .day, value: -n, to: now)! }

private func tally(_ counts: [TimeBackAction: Int]) -> TimeBack.Tally {
    var t = TimeBack()
    for (action, n) in counts { t.count(action, times: n, at: now, in: utc) }
    return t.week(endingAt: now, in: utc)
}

@Suite struct TimeBackCounts {
    @Test func eachThingCountsItsConservativeSeconds() {
        #expect(TimeBackAction.tiled.seconds == 2)
        #expect(TimeBackAction.arranged.seconds == 2)
        #expect(TimeBackAction.sent.seconds == 3)
        #expect(TimeBackAction.restored.seconds == 2)
        #expect(TimeBackAction.summoned.seconds == 1)
        #expect(TimeBackAction.corrected.seconds == -3)
        #expect(TimeBackAction.displayReturned.seconds == 0)
    }

    @Test func aWeekIsTodayAndTheSixDaysBefore() {
        var t = TimeBack()
        t.count(.tiled, times: 10, at: now, in: utc)
        t.count(.tiled, times: 5, at: daysAgo(6), in: utc)
        t.count(.tiled, times: 100, at: daysAgo(7), in: utc) // last week
        let week = t.week(endingAt: now, in: utc)
        #expect(week[.tiled] == 15)
        #expect(week.seconds == 30)
    }

    @Test func daysEndAtMidnightWhereYouAre() {
        var t = TimeBack()
        let lateMonday = utc.date(from: DateComponents(year: 2027, month: 1, day: 11, hour: 23, minute: 59))!
        let earlyTuesday = utc.date(from: DateComponents(year: 2027, month: 1, day: 12, hour: 0, minute: 1))!
        t.count(.sent, at: lateMonday, in: utc)
        t.count(.sent, at: earlyTuesday, in: utc)
        #expect(t.days.keys.sorted() == ["2027-01-11", "2027-01-12"])
        #expect(t.tally(from: earlyTuesday, through: earlyTuesday, in: utc)[.sent] == 1)
    }

    @Test func minutesAreWholeRoundedDownAndAfterCorrections() {
        // 600 tiled (1,200 s) + 41 sent (123 s) − 10 corrections (30 s) = 1,293 s: 21 minutes, not 22.
        let week = tally([.tiled: 600, .sent: 41, .corrected: 10])
        #expect(week.seconds == 1_293)
        #expect(week.minutes == 21)
    }

    @Test func moreCorrectionsThanHelpIsNoTimeBackNeverLess() {
        let week = tally([.tiled: 1, .corrected: 4])
        #expect(week.seconds == -10)
        #expect(week.minutes == 0)
        #expect(TimeBackWords.back(week) == "no time back yet")
    }

    @Test func windowsPlacedAreTheOnesLunchboxPutInPlace() {
        let week = tally([.tiled: 5, .arranged: 2, .sent: 3, .restored: 4, .summoned: 50, .corrected: 1, .displayReturned: 2])
        #expect(week.windowsPlaced == 14)
    }

    @Test func nothingCountedIsEmpty() {
        #expect(TimeBack().isEmpty)
        #expect(TimeBack().week(endingAt: now, in: utc).isEmpty)
        var t = TimeBack()
        t.count(.tiled, times: 0, at: now, in: utc) // nothing happened
        #expect(t.isEmpty)
    }

    @Test func oldDaysArePrunedLikeTheLogs() {
        var t = TimeBack()
        t.count(.tiled, at: now, in: utc)
        t.count(.tiled, at: daysAgo(TimeBack.keptDays - 1), in: utc)
        t.count(.tiled, at: daysAgo(TimeBack.keptDays), in: utc)
        t.count(.tiled, at: utc.date(byAdding: .day, value: 30, to: now)!, in: utc) // a clock set forward
        t.prune(now: now, in: utc)
        #expect(t.days.keys.sorted() == [TimeBack.day(of: daysAgo(TimeBack.keptDays - 1), in: utc), "2027-01-15"])
    }

    @Test func countsMadeWhileReadingAreAddedOnTop() {
        var stored = TimeBack()
        stored.count(.tiled, times: 3, at: daysAgo(1), in: utc)
        stored.count(.sent, at: now, in: utc)
        var meanwhile = TimeBack()
        meanwhile.count(.sent, times: 2, at: now, in: utc)
        meanwhile.count(.summoned, at: now, in: utc)
        stored.add(meanwhile)
        let week = stored.week(endingAt: now, in: utc)
        #expect(week[.tiled] == 3)
        #expect(week[.sent] == 3)
        #expect(week[.summoned] == 1)
    }

    @Test func whatANewerLunchboxCountedIsKeptButNotAdded() throws {
        let json = #"{"days":{"2027-01-15":{"tiled":3,"zoomed":7}}}"#
        var t = try JSONDecoder().decode(TimeBack.self, from: Data(json.utf8))
        #expect(t.week(endingAt: now, in: utc).seconds == 6)
        t.count(.tiled, at: now, in: utc)
        #expect(t.days["2027-01-15"] == ["tiled": 4, "zoomed": 7])
    }
}

private func scratchFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lunchbox-timeback-\(UUID().uuidString)")
}

@Suite struct TimeBackStaysOnThisMac {
    @Test func itComesBackAsItWent() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = TimeBackFile(folder: folder)
        var t = TimeBack()
        t.count(.sent, times: 2, at: now, in: utc)
        try file.write(t)
        #expect(file.read() == t)
        t.count(.tiled, at: now, in: utc)
        try file.write(t) // replaces it
        #expect(file.read() == t)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["timeback.json"])
    }

    @Test func onlyYouCanReadItAndBackupsSkipIt() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = TimeBackFile(folder: folder)
        try file.write(TimeBack())
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func onlyNumbersAndDatesAreKept() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = TimeBackFile(folder: folder)
        var t = TimeBack()
        for action in TimeBackAction.allCases { t.count(action, at: now, in: utc) }
        try file.write(t)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        #expect(words.isSubset(of: Set(["days"] + TimeBackAction.allCases.map(\.rawValue))))
    }

    @Test func aDamagedOrMissingFileIsAFreshStart() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = TimeBackFile(folder: folder)
        #expect(file.read().isEmpty)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"days\":{\"2027-".utf8).write(to: file.url)
        #expect(file.read().isEmpty)
    }

    @Test func eraseForgetsIt() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = TimeBackFile(folder: folder)
        var t = TimeBack()
        t.count(.tiled, at: now, in: utc)
        try file.write(t)
        file.erase()
        #expect(file.read().isEmpty)
    }
}

@Suite struct TimeBackInWords {
    @Test func theMenuLine() {
        #expect(TimeBackWords.menuLine(tally([.tiled: 600, .sent: 41, .corrected: 10])) == "This week: 21 minutes back · 641 windows placed")
        #expect(TimeBackWords.menuLine(tally([.tiled: 30])) == "This week: 1 minute back · 30 windows placed")
        #expect(TimeBackWords.menuLine(tally([.tiled: 1])) == "This week: under a minute back · 1 window placed")
    }

    @Test func howItsCountedSaysWhatTheSecondsSay() {
        #expect(TimeBackWords.howCounted == [
            "Counted at 2 s a window placed, 3 s one sent to its Workspace,",
            "1 s a Summon jump, and \u{2212}3 s a correction or undo.",
        ])
        // The line says one number for every window placed except a sent one.
        let placed = TimeBackAction.allCases.filter { $0.placesAWindow && $0 != .sent }
        #expect(Set(placed.map(\.seconds)) == [TimeBackAction.tiled.seconds])
    }

    @Test func theBreakdownShowsTheWorking() {
        #expect(TimeBackWords.breakdown(tally([.tiled: 380, .sent: 1, .corrected: 2])) == [
            "380 new windows tiled × 2 s",
            "1 window sent to its Workspace × 3 s",
            "2 corrections and undos × \u{2212}3 s",
        ])
    }

    @Test func theTrialLineCarriesTheMinutesInItsLastTwoDays() {
        let soFar = tally([.tiled: 630]) // 21 minutes
        #expect(TimeBackWords.trialLine(daysLeft: 5, soFar: soFar) == "Free trial: 5 days left")
        #expect(TimeBackWords.trialLine(daysLeft: 3, soFar: soFar) == "Free trial: 3 days left")
        #expect(TimeBackWords.trialLine(daysLeft: 2, soFar: soFar) == "Free trial: 2 days left · 21 minutes back so far")
        #expect(TimeBackWords.trialLine(daysLeft: 1, soFar: soFar) == "Free trial: 1 day left · 21 minutes back so far")
        #expect(TimeBackWords.trialLine(daysLeft: 1, soFar: tally([.tiled: 10])) == "Free trial: 1 day left")
    }

    @Test func theTrialEndScreenInTheProposedWords() {
        // docs/worth-paying-for.md: 26 minutes, 412 windows, 9 apps, 41 sent, 6 displays, 14 lessons.
        let week = tally([.tiled: 332, .arranged: 9, .sent: 41, .restored: 30, .summoned: 700, .displayReturned: 6])
        #expect(week.minutes == 26)
        let words = TimeBackWords.trialEnded(week: week, lessons: 14)
        #expect(words.eyebrow == "Your free trial has ended")
        #expect(words.heading == "This week, LunchboxWM gave you back 26 minutes.")
        #expect(words.summary == "It placed 412 windows, put 9 apps back the way you like them, sent 41 windows to their Workspace, and put everything back the 6 times your display came back. It learned 14 things about how you work.")
        #expect(words.keep == "Keep LunchboxWM: $9.99, once.")
        #expect(words.stays == "What it learned stays on your Mac either way.")
    }

    @Test func theTrialEndScreenOnlySaysWhatHappened() {
        let words = TimeBackWords.trialEnded(week: tally([.tiled: 40, .sent: 1, .displayReturned: 1]), lessons: 1)
        #expect(words.heading == "This week, LunchboxWM gave you back 1 minute.")
        #expect(words.summary == "It placed 41 windows, sent 1 window to its Workspace, and put everything back when your display came back. It learned 1 thing about how you work.")
        let quiet = TimeBackWords.trialEnded(week: tally([.tiled: 3]), lessons: 0)
        #expect(quiet.eyebrow == nil)
        #expect(quiet.heading == "Your free trial has ended")
        #expect(quiet.summary == "It placed 3 windows.")
        #expect(quiet.stays == "Your windows stay right where they are either way.")
        let nothing = TimeBackWords.trialEnded(week: TimeBack.Tally(), lessons: 0)
        #expect(nothing.summary == nil)
    }
}
