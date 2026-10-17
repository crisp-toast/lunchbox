import AppKit
import os
import TesselCore

private let learningLog = Logger(subsystem: "com.tyleryouens.tessel", category: "learning")

/// What Tessel learns from how you work: for now, which windows you want floating
/// (docs/learning.md). Off unless the `learnFloating` default is on:
/// `defaults write com.tyleryouens.tessel learnFloating -bool YES`, then pause and resume tiling.
///
/// Everything it learns is in ~/Library/Application Support/Tessel/Learning, kept out of
/// backups, and none of it is ever sent anywhere. Decisions are made on each app's own
/// queue, where Tessel reads the window anyway; the log is written on a queue of its own.
final class Learning {
    static let shared = Learning()

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tessel/Learning")
    }

    /// A window Tessel has decided about.
    struct Seen: Sendable {
        var features: FloatFeatures
        var decision: FloatDecision
        /// Wall-clock seconds when it was first seen.
        var seenAt: Double
    }

    private struct State: Sendable {
        var on = false
        var model = FloatClassifier()
        var seen: [CGWindowID: Seen] = [:]
        /// Usable area of each display, top-left coordinates.
        var screens: [CGRect] = []
        /// Goes up on every reset, so lessons read back from before one are dropped.
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let io = DispatchQueue(label: "com.tyleryouens.tessel.learning", qos: .utility)
    private let floatLog = EventLog<FloatEvent>(folder: Learning.folder, name: "float")
    /// Held while the log is read back, so no window is decided before the lessons are in
    /// (a window you taught Tessel to float would otherwise tile after a relaunch).
    private let loading = DispatchGroup()

    var isOn: Bool { state.withLock { $0.on } }

    private static var now: Double { Date().timeIntervalSince1970 }

    // MARK: Lifecycle

    /// Tiling started: picks up the setting and learns again from the log, off the main thread.
    func start() {
        let on = UserDefaults.standard.bool(forKey: "learnFloating")
        let generation = state.withLock { $0.on = on; return $0.generation }
        guard on else { return }
        loading.enter()
        io.async { [floatLog] in
            let now = Self.now
            try? floatLog.prune(now: now)
            let events = floatLog.read(now: now)
            let model = FloatClassifier.replay(events, now: now)
            self.state.withLock { if $0.generation == generation { $0.model = model } }
            self.loading.leave()
            learningLog.notice("learned floating from \(events.count) events")
        }
    }

    /// Tiling paused. Windows you chose for yourself keep their choice for when it resumes;
    /// the rest are decided again then.
    func stop() {
        state.withLock { s in s.seen = s.seen.filter { $0.value.decision.source == .you } }
    }

    func setScreens(_ screens: [CGRect]) {
        state.withLock { $0.screens = screens }
    }

    // MARK: Deciding

    /// The first time Tessel sees a window that could tile: whether it should. Runs on the
    /// window's app queue. nil when learning is off. `features` reads the window over
    /// Accessibility and runs outside the lock.
    func decide(_ id: CGWindowID, rule: FloatChoice, features: ([CGRect]) -> FloatFeatures?) -> FloatDecision? {
        let (on, known, screens) = state.withLock { ($0.on, $0.seen[id]?.decision, $0.screens) }
        guard on else { return nil }
        if let known { return known }
        guard let f = features(screens) else { return nil }
        // Only ever an app's own queue waits here, and only right after tiling starts.
        if loading.wait(timeout: .now() + 1) == .timedOut {
            learningLog.error("the learning log took over a second to read; deciding window \(id) by the rules")
        }
        let decision = state.withLock { s in
            if let known = s.seen[id] { return known.decision }
            let decision = s.model.decide(f, rule: rule)
            s.seen[id] = Seen(features: f, decision: decision, seenAt: Self.now)
            return decision
        }
        if decision.source == .learned {
            learningLog.notice("window \(id) (\(f.app, privacy: .public)) will \(decision.choice.rawValue, privacy: .public): learned, p(float) \(decision.floatProbability, format: .fixed(precision: 2))")
        }
        return decision
    }

    /// What was decided for a window, if anything.
    func decision(for id: CGWindowID) -> FloatDecision? {
        state.withLock { $0.on ? $0.seen[id]?.decision : nil }
    }

    // MARK: What you do

    /// You floated a tiled window or tiled a floating one. It's learned right away, so the
    /// next window of the same kind follows. False for a window Tessel never decided about.
    @discardableResult
    func corrected(_ id: CGWindowID, to choice: FloatChoice, by gesture: FloatGesture) -> Bool {
        let now = Self.now
        let event: FloatEvent? = state.withLock { s in
            guard s.on, var seen = s.seen[id] else { return nil }
            seen.decision = FloatDecision(choice: choice, source: .you, floatProbability: choice == .float ? 1 : 0)
            s.seen[id] = seen
            let event = FloatEvent.corrected(seen.features, to: choice, by: gesture, at: now)
            s.model.learn(event, now: now)
            return event
        }
        guard let event else { return false }
        learningLog.notice("window \(id) (\(event.features.app, privacy: .public)): you chose \(choice.rawValue, privacy: .public) (\(gesture.rawValue, privacy: .public))")
        write(event)
        return true
    }

    /// The rules won over what was learned for this window (Summon opened it, or it was
    /// tiled already): it's what the window gets, so it's what its close is counted as.
    func overrule(_ id: CGWindowID, to choice: FloatChoice) {
        state.withLock { s in
            guard let seen = s.seen[id] else { return }
            s.seen[id]?.decision = FloatDecision(choice: choice, source: .rule, floatProbability: seen.decision.floatProbability)
        }
    }

    /// A window closed (or its app quit): how long it lived with its choice is a quiet hint.
    /// Only a close that says something is written down, which keeps the log to a few
    /// kilobytes a day.
    func closed(_ id: CGWindowID) {
        let now = Self.now
        let event: FloatEvent? = state.withLock { s in
            guard let seen = s.seen.removeValue(forKey: id), s.on else { return nil }
            let event = FloatEvent.closed(seen.features, as: seen.decision.choice, source: seen.decision.source,
                                          lifetime: now - seen.seenAt, at: now)
            guard FloatClassifier.evidence(in: event) != nil else { return nil }
            s.model.learn(event, now: now)
            return event
        }
        if let event { write(event) }
    }

    /// The window wouldn't take the size of its tile: it has a minimum or maximum size.
    func sizeLimited(_ id: CGWindowID) {
        state.withLock { $0.seen[id]?.features.sizeLimited = true }
    }

    /// Settings › Reset What Tessel Learned: forgets every lesson and deletes the log.
    /// Windows open now stay as they are.
    func reset() {
        state.withLock {
            $0.model = FloatClassifier()
            $0.generation += 1
        }
        io.async { [floatLog] in
            floatLog.erase()
            try? FileManager.default.removeItem(at: Learning.folder)
            learningLog.notice("forgot everything Tessel learned")
        }
    }

    private func write(_ event: FloatEvent) {
        io.async { [floatLog] in
            do { try floatLog.append(event) } catch {
                learningLog.error("couldn't write the learning log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Reading a window

    /// What a window looks like to the classifier. Runs on its app's queue.
    static func features(of element: AXUIElement, app: AppHandle, frame: CGRect, subrole: String?,
                         resizable: Bool, tabs: Int, screens: [CGRect]) -> FloatFeatures? {
        guard let bundleID = app.bundleID else { return nil }
        var buttons: WindowButtons = []
        if element.element(kAXCloseButtonAttribute) != nil { buttons.insert(.close) }
        if element.element(kAXMinimizeButtonAttribute) != nil { buttons.insert(.minimize) }
        if element.element(kAXZoomButtonAttribute) != nil { buttons.insert(.zoom) }
        if element.element(kAXFullScreenButtonAttribute) != nil { buttons.insert(.fullScreen) }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first { $0.contains(center) }
            ?? screens.max { $0.intersection(frame).area < $1.intersection(frame).area }
        let share = screen.map { frame.area / max(1, $0.area) } ?? 0.5
        let name = NSRunningApplication(processIdentifier: app.pid)?.localizedName
        return FloatFeatures(app: bundleID, subrole: subrole, resizable: resizable, buttons: buttons, size: frame.size,
                             screenShare: share, title: TitleKind(title: element.string(kAXTitleAttribute), appName: name),
                             tabs: tabs > 0)
    }

    // MARK: Diagnostics

    /// For `dump`: what's switched on and what's been learned.
    var stateDescription: [String: Any] {
        let s = state.withLock { $0 }
        return [
            "floating": s.on,
            "logBytes": floatLog.bytes,
            "windows": s.seen.map { id, seen in
                "\(id) \(seen.features.signature) \(seen.decision.choice.rawValue) (\(seen.decision.source.rawValue))"
            }.sorted(),
            "lessons": s.model.lessons().map { "\($0.signature) → \($0.choice.rawValue) ×\(String(format: "%.1f", $0.corrections))" },
        ]
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
