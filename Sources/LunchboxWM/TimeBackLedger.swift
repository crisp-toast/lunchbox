import Foundation
import os
import LunchboxCore

private let timeBackLog = Logger(subsystem: logSubsystem, category: "timeback")

/// The time LunchboxWM gives back (`TimeBack`, docs/worth-paying-for.md), counted where each thing
/// happens: Tiler for windows it places and puts back, Learning for homes, corrections and
/// undos, Summon for jumps.
///
/// Kept as daily counts in the learning folder (timeback.json), under the same rules as the
/// learning logs: yours alone, out of backups, days older than 90 pruned, and cleared by Reset
/// What LunchboxWM Learned. It counts whether or not learning is on, since most of it is plain
/// tiling. Only numbers and dates, and nothing leaves the Mac. It's shown in the menu, What
/// LunchboxWM Learned and the trial-end screen, and never as a notification.
final class TimeBackLedger {
    static let shared = TimeBackLedger()

    private struct State: Sendable {
        var timeBack = TimeBack()
        /// Asked to read the file back.
        var loading = false
        /// Read back: from now on the file may be written (never before, or history is lost).
        var ready = false
        var saveScheduled = false
        /// Goes up on every reset, so a read from before one is dropped.
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let io = DispatchQueue(label: "com.sentientdonut.lunchbox.timeback", qos: .utility)
    private let file = TimeBackFile(folder: Learning.folder)

    /// Reads back what was counted before, once, off the main thread, and prunes old days.
    func load() {
        let generation: Int? = state.withLock { s in
            guard !s.loading else { return nil }
            s.loading = true
            return s.generation
        }
        guard let generation else { return }
        io.async { [self] in
            var stored = file.read()
            stored.prune(now: Date())
            let read = stored
            let counted = state.withLock { s -> Bool in
                if s.generation == generation {
                    var merged = read
                    merged.add(s.timeBack) // counted while it was being read
                    s.timeBack = merged
                }
                s.ready = true
                return !s.timeBack.isEmpty
            }
            if counted { scheduleSave() }
            timeBackLog.notice("read back \(read.days.count) days of time back")
        }
    }

    /// LunchboxWM did something you'd otherwise do by hand (or you corrected it). Any thread.
    func count(_ action: TimeBackAction, times: Int = 1, at date: Date = Date()) {
        guard times > 0 else { return }
        state.withLock { $0.timeBack.count(action, times: times, at: date) }
        scheduleSave()
    }

    /// Today and the six days before.
    var week: TimeBack.Tally {
        state.withLock { $0.timeBack.week(endingAt: Date()) }
    }

    /// Everything from the day of `start` through today (or `end`).
    func tally(since start: Date, through end: Date = Date()) -> TimeBack.Tally {
        state.withLock { $0.timeBack.tally(from: start, through: end) }
    }

    /// Reset What LunchboxWM Learned: forgets every count.
    func reset() {
        state.withLock { s in
            s.timeBack = TimeBack()
            s.generation += 1
        }
        io.async { [self] in file.erase() }
    }

    // MARK: Disk

    /// Writes the file a couple of seconds after things settle, so a burst of windows is one write.
    private func scheduleSave() {
        let already = state.withLock { s in
            defer { s.saveScheduled = true }
            return s.saveScheduled
        }
        guard !already else { return }
        io.asyncAfter(deadline: .now() + 2) { [self] in
            state.withLock { $0.saveScheduled = false }
            save()
        }
    }

    /// Writes it now (pausing, quitting).
    func saveNow() {
        io.sync { save() }
    }

    /// On the IO queue.
    private func save() {
        let (stored, ready) = state.withLock { ($0.timeBack, $0.ready) }
        guard ready else { return }
        var pruned = stored
        pruned.prune(now: Date())
        // Nothing counted yet: no file, and no learning folder just for that.
        guard !pruned.isEmpty || FileManager.default.fileExists(atPath: file.url.path) else { return }
        do { try file.write(pruned) } catch {
            timeBackLog.error("couldn't write the time back: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Diagnostics

    /// For `dump`.
    var stateDescription: [String: Any] {
        let week = self.week
        return [
            "week": TimeBackWords.menuLine(week),
            "weekSeconds": week.seconds,
            "breakdown": TimeBackWords.breakdown(week),
            "days": state.withLock { $0.timeBack.days },
        ]
    }
}
