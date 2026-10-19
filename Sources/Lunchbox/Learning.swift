import AppKit
import os
import LunchboxCore

private let learningLog = Logger(subsystem: logSubsystem, category: "learning")

/// Lunchbox learns where your windows go (docs/learning.md): which windows you float, how you
/// arrange each set of apps, and which Workspace each app lives in. One switch, Settings ›
/// Learn Where Windows Go (the `learning` default), off unless turned on for now.
///
/// Everything it learns is in ~/Library/Application Support/Lunchbox/Learning, kept out of
/// backups, and none of it is ever sent anywhere. Float decisions are made on each app's own
/// queue, where Lunchbox reads the window anyway. Arrangements and homes are dictionary reads
/// on the main thread, where windows are placed. Disk work runs on a queue of its own.
final class Learning {
    static let shared = Learning()

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lunchbox/Learning")
    }

    /// A window Lunchbox has decided about.
    struct Seen: Codable, Sendable {
        var features: FloatFeatures
        var decision: FloatDecision
        /// Wall-clock seconds when it was first seen.
        var seenAt: Double
        /// What the window classifier made of it, and whether that went against the rules.
        var behavior: WindowBehavior? = nil
        var byModel: Bool? = nil
    }

    /// What Lunchbox decided for a window it just saw.
    struct Verdict {
        var decision: FloatDecision
        var behavior: WindowBehavior
    }

    /// What isn't a log: kept as it is now, in memory.json.
    private struct Snapshot: Codable {
        var workspaces = WorkspaceMemory()
        var ledger = UndoLedger()
        /// Windows open now, by number, so a relaunch keeps your choices and their kinds.
        var windows: [String: Seen] = [:]
    }

    private struct State: Sendable {
        var on = false
        var model = FloatClassifier()
        var arrangements = ArrangementMemory()
        var workspaces = WorkspaceMemory()
        var ledger = UndoLedger()
        var seen: [CGWindowID: Seen] = [:]
        /// Usable area of each display, top-left coordinates.
        var screens: [CGRect] = []
        /// Goes up on every reset, so lessons read back from before one are dropped.
        var generation = 0
        var saveScheduled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let io = DispatchQueue(label: "com.sentientdonut.lunchbox.learning", qos: .utility)
    private let floatLog = EventLog<FloatEvent>(folder: Learning.folder, name: "float")
    private let arrangeLog = EventLog<ArrangeEvent>(folder: Learning.folder, name: "arrange")
    private let workspaceLog = EventLog<WorkspaceMemory.Event>(folder: Learning.folder, name: "workspace", maxBytes: 512 << 10)
    private var snapshotURL: URL { Learning.folder.appendingPathComponent("memory.json") }
    /// Held while everything is read back, so no window is decided before the lessons are in
    /// (a window you taught Lunchbox to float would otherwise tile after a relaunch).
    private let loading = DispatchGroup()

    var isOn: Bool { state.withLock { $0.on } }

    /// The switch: `learning`, or `learnFloating` from the first prototype.
    static var switchedOn: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "learning") as? Bool ?? d.bool(forKey: "learnFloating")
    }

    private static var now: Double { Date().timeIntervalSince1970 }

    // MARK: Lifecycle

    /// Tiling started: picks up the switch and reads back everything learned, off the main thread.
    /// `alive` is every window that exists, so choices for windows still open survive a relaunch.
    func start(alive: Set<CGWindowID>) {
        let on = Self.switchedOn
        let generation = state.withLock { $0.on = on; return $0.generation }
        guard on else { return }
        loading.enter()
        io.async { [self] in
            let now = Self.now
            try? floatLog.prune(now: now)
            try? arrangeLog.prune(now: now)
            try? workspaceLog.prune(now: now)
            let floats = floatLog.read(now: now)
            let model = FloatClassifier.replay(floats, now: now)
            let arrangements = ArrangementMemory.replay(arrangeLog.read(now: now), now: now)
            let snapshot = (try? Data(contentsOf: snapshotURL)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
            var still: [CGWindowID: Seen] = [:]
            for (key, value) in snapshot.windows {
                if let id = CGWindowID(key), alive.contains(id) { still[id] = value }
            }
            let seen = still
            state.withLock { s in
                guard s.generation == generation else { return }
                s.model = model
                s.arrangements = arrangements
                s.workspaces = snapshot.workspaces
                s.ledger = snapshot.ledger
                // Decided earlier this session (pause and resume) beats the snapshot.
                s.seen = seen.merging(s.seen) { _, new in new }
            }
            loading.leave()
            learningLog.notice("read back \(floats.count) float events, \(arrangements.variants.count) arrangements, \(snapshot.workspaces.homes.count) homes")
        }
    }

    /// Tiling paused. Windows you chose for yourself keep their choice for when it resumes;
    /// the rest are decided again then.
    func stop() {
        state.withLock { s in s.seen = s.seen.filter { $0.value.decision.source == .you } }
        saveNow()
    }

    /// Settings › Learn Where Windows Go.
    func setSwitch(_ on: Bool, alive: Set<CGWindowID>) {
        UserDefaults.standard.set(on, forKey: "learning")
        if on { start(alive: alive) } else { state.withLock { $0.on = false } }
        learningLog.notice("learning \(on ? "on" : "off", privacy: .public)")
    }

    func setScreens(_ screens: [CGRect]) {
        state.withLock { $0.screens = screens }
    }

    // MARK: Float or tile

    /// The first time Lunchbox sees a window that could tile: how it behaves. Runs on the window's
    /// app queue; nil when learning is off. `read` reads the window over Accessibility (outside
    /// the lock); its title is used here and not kept.
    ///
    /// The window classifier (`BehaviorModel.base`, under the rules' safety floor) says what kind
    /// of window it is; that's the starting point your own corrections (`FloatClassifier`) adjust.
    func decide(_ id: CGWindowID, read: ([CGRect]) -> WindowTraits?) -> Verdict? {
        let (on, known, screens) = state.withLock { ($0.on, $0.seen[id], $0.screens) }
        guard on else { return nil }
        if let known { return Verdict(decision: known.decision, behavior: known.behavior ?? (known.decision.choice == .tile ? .document : .panel)) }
        guard let traits = read(screens) else { return nil }
        let started = CACurrentMediaTime()
        let meaning = TitleMeaning.shared.vector(traits.title)
        let kind = BehaviorDecision.decide(traits, model: Self.model, meaning: meaning, floatingApps: Tiler.floatingApps)
        let classified = CACurrentMediaTime() - started
        let f = FloatFeatures(traits)
        // Only ever an app's own queue waits here, and only right after tiling starts.
        if loading.wait(timeout: .now() + 1) == .timedOut {
            learningLog.error("the learning log took over a second to read; deciding window \(id) by the rules")
        }
        let decision = state.withLock { s in
            if let known = s.seen[id] { return known.decision }
            let decision = s.model.decide(f, rule: kind.behavior.tiles ? .tile : .float)
            s.seen[id] = Seen(features: f, decision: decision, seenAt: Self.now, behavior: kind.behavior, byModel: kind.byModel)
            return decision
        }
        if kind.byModel {
            learningLog.notice("window \(id) (\(f.app, privacy: .public)) is a \(kind.behavior.rawValue, privacy: .public) (\(kind.confidence, format: .fixed(precision: 2)) sure, the rules said otherwise), decided in \(classified * 1000, format: .fixed(precision: 3)) ms")
        }
        if decision.source == .learned {
            learningLog.notice("window \(id) (\(f.app, privacy: .public)) will \(decision.choice.rawValue, privacy: .public): learned, p(float) \(decision.floatProbability, format: .fixed(precision: 2))")
        }
        scheduleSave()
        return Verdict(decision: decision, behavior: kind.behavior)
    }

    /// The window classifier Lunchbox ships with.
    static let model = BehaviorModel.base

    /// What was decided for a window, if anything.
    func decision(for id: CGWindowID) -> FloatDecision? {
        state.withLock { $0.on ? $0.seen[id]?.decision : nil }
    }

    /// What the window classifier made of a window, if it's seen it (it runs while learning is on).
    func behavior(of id: CGWindowID) -> WindowBehavior? {
        state.withLock { $0.on ? $0.seen[id]?.behavior : nil }
    }

    /// The size a window had when it first appeared, before Lunchbox tiled it.
    func openingSize(of id: CGWindowID) -> CGSize? {
        state.withLock { s in s.seen[id].map { CGSize(width: $0.features.width, height: $0.features.height) } }
    }

    /// You floated a tiled window or tiled a floating one. It's learned right away, so the
    /// next window of the same kind follows. False for a window Lunchbox never decided about.
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
        TimeBackLedger.shared.count(.corrected)
        learningLog.notice("window \(id) (\(event.features.app, privacy: .public)): you chose \(choice.rawValue, privacy: .public) (\(gesture.rawValue, privacy: .public))")
        write(event, to: floatLog)
        scheduleSave()
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

    /// A window closed: how long it lived with its choice is a quiet hint. `lifetime` is from
    /// when Lunchbox first saw it; `counts` is false for a window that was open before Lunchbox
    /// started, or closed because its app quit. Only a close that says something is written
    /// down, which keeps the log to a few kilobytes a day.
    func closed(_ id: CGWindowID, lifetime: Double, counts: Bool) {
        let now = Self.now
        let event: FloatEvent? = state.withLock { s in
            guard let seen = s.seen.removeValue(forKey: id), s.on, counts else { return nil }
            let event = FloatEvent.closed(seen.features, as: seen.decision.choice, source: seen.decision.source,
                                          lifetime: lifetime, at: now)
            guard FloatClassifier.evidence(in: event) != nil else { return nil }
            s.model.learn(event, now: now)
            return event
        }
        if let event { write(event, to: floatLog) }
        scheduleSave()
    }

    /// The window wouldn't take the size of its tile: it has a minimum or maximum size.
    func sizeLimited(_ id: CGWindowID) {
        state.withLock { $0.seen[id]?.features.sizeLimited = true }
    }

    // MARK: Usual arrangements

    /// The arrangement you usually have for these apps on this display, if any (and you
    /// haven't undone it twice).
    func arrangement(display: String, apps: [String]) -> Arrangement? {
        let now = Self.now
        return state.withLock { s in
            guard s.on, s.ledger.allows(ArrangementMemory.key(display: display, apps: apps)) else { return nil }
            return s.arrangements.arrangement(display: display, apps: apps, now: now)
        }
    }

    /// The shape you gave four windows around one of these apps' window, if any (and you
    /// haven't undone it twice): that app, and the shape.
    func anchoredShape(display: String, apps: [String]) -> (app: String, shape: AnchoredShape)? {
        state.withLock { s in
            guard s.on, let found = s.arrangements.anchoredShape(display: display, apps: apps),
                  s.ledger.allows(ArrangementMemory.shapeKey(display: display, app: found.app)) else { return nil }
            return found
        }
    }

    func loneShape(of app: String, on display: String) -> LoneShape? {
        state.withLock { s in
            guard s.on, s.ledger.allows(ArrangementMemory.loneKey(display: display, app: app)) else { return nil }
            return s.arrangements.loneShape(of: app, on: display)
        }
    }

    /// An arrangement you made (`byYou`) or let stand stood for `dwell` seconds.
    func arranged(_ a: Arrangement, on display: String, dwell: Double, byYou: Bool = false) {
        guard dwell >= 1 else { return }
        let now = Self.now
        let on = state.withLock { s in
            guard s.on else { return false }
            s.arrangements.record(a, on: display, dwell: dwell, at: now)
            if byYou {
                s.arrangements.recordShape(a, on: display, dwell: dwell, at: now)
                // A shape you made yourself is a new lesson, even one you'd undone before.
                for app in a.apps { s.ledger.forget(ArrangementMemory.shapeKey(display: display, app: app)) }
            }
            return true
        }
        if on { write(ArrangeEvent.arranged(a, on: display, dwell: dwell, byYou: byYou, at: now), to: arrangeLog) }
    }

    /// You gave a lone window of an app a shape of its own (or put it back to the default
    /// one, which forgets the lesson).
    func shaped(_ app: String, shape: LoneShape, on display: String) {
        let key = ArrangementMemory.loneKey(display: display, app: app)
        if shape.height == nil, abs(shape.scale - Layout.defaultSingleScale) < 0.001 {
            if state.withLock({ $0.on && $0.arrangements.loneShape(of: app, on: display) != nil }) { forget(key) }
            return
        }
        let on = state.withLock { s in
            guard s.on else { return false }
            s.arrangements.recordLone(app, shape: shape, on: display)
            s.ledger.forget(key) // a new shape: a new lesson
            return true
        }
        if on { write(ArrangeEvent.lone(app, shape: shape, on: display, at: Self.now), to: arrangeLog) }
    }

    // MARK: Workspace homes

    /// Where a new window of `app` opens, or nil for "here, as always".
    func home(for app: String, requested: Bool, current: Int, appSpaces: Set<Int>) -> Int? {
        state.withLock { s in
            guard s.on else { return nil }
            return s.workspaces.placement(for: app, requested: requested, current: current, appSpaces: appSpaces,
                                          allowed: s.ledger.allows("place|\(app)"))
        }
    }

    /// You moved a window of `app` to a Workspace yourself.
    func moved(_ app: String, to space: Int) {
        let on = state.withLock { s in
            guard s.on else { return false }
            s.workspaces.moved(app, to: space, at: Self.now)
            return true
        }
        guard on else { return }
        write(WorkspaceMemory.Event(.moved, app: app, space: space, at: Self.now), to: workspaceLog)
        scheduleSave()
    }

    /// Windows spent time in Workspaces: `[(app, space, seconds)]`.
    func lived(_ spans: [(app: String, space: Int, seconds: Double)]) {
        let on = state.withLock { s in
            guard s.on else { return false }
            for span in spans { s.workspaces.lived(span.app, in: span.space, seconds: span.seconds) }
            return true
        }
        if on { scheduleSave() }
    }

    /// A new window went to the Workspace its app lives in.
    func placed(_ app: String, in space: Int) {
        TimeBackLedger.shared.count(.sent)
        write(WorkspaceMemory.Event(.placed, app: app, space: space, at: Self.now), to: workspaceLog)
    }

    // MARK: Undo

    /// You pressed the undo key for something Lunchbox did on its own. Undone twice in a row,
    /// Lunchbox forgets that lesson (and stops doing it) until you teach it again. True then.
    @discardableResult
    func undone(_ key: String) -> Bool {
        let stopped = state.withLock { $0.ledger.undone(key) }
        TimeBackLedger.shared.count(.corrected)
        if key.hasPrefix("place|") {
            write(WorkspaceMemory.Event(.undone, app: String(key.dropFirst(6)), at: Self.now), to: workspaceLog)
        }
        learningLog.notice("undone: \(key, privacy: .public)\(stopped ? " (twice: forgetting it)" : "", privacy: .public)")
        if stopped { forget(key) } else { scheduleSave() }
        return stopped
    }

    /// Something Lunchbox did on its own stood.
    func kept(_ key: String) {
        state.withLock { $0.ledger.kept(key) }
        scheduleSave()
    }

    // MARK: Lessons

    /// What Lunchbox learned, in words, each with the key `forget` takes. Main thread.
    func lessons() -> [(key: String, text: String)] {
        let s = state.withLock { $0 }
        guard s.on else { return [] }
        var out: [(String, String)] = []
        for lesson in s.model.lessons(rule: { f in f.standard && !Tiler.floatingApps.contains(f.app) ? .tile : .float }) {
            let verb = lesson.choice == .float ? "float" : "tile"
            out.append(("float|\(lesson.signature)", "\(Self.appName(lesson.example.app)): \(lesson.example.kindInWords) \(verb)"))
        }
        for (key, list) in s.arrangements.variants where s.ledger.allows(key) {
            guard let best = list.first, best.dwell >= ArrangementMemory.minimumDwell else { continue }
            let names = Array(NSOrderedSet(array: best.arrangement.apps.map(Self.appName))) as? [String] ?? []
            out.append((key, "\(names.joined(separator: " and ")): your usual arrangement"))
        }
        for (key, shape) in s.arrangements.anchored where s.ledger.allows(key) && shape.dwell >= ArrangementMemory.minimumDwell {
            let app = String(key.split(separator: "|").last ?? "")
            out.append((key, "\(Self.appName(app)): the \(shape.side) side to itself, with four windows"))
        }
        for (key, _) in s.arrangements.lone where s.ledger.allows(key) {
            let app = String(key.split(separator: "|").last ?? "")
            out.append((key, "\(Self.appName(app)): the size you gave it when it's alone"))
        }
        for app in s.workspaces.homes.keys {
            if let home = s.workspaces.home(of: app) {
                out.append(("place|\(app)", "\(Self.appName(app)): new windows open in Workspace \(home + 1)"))
            }
        }
        return out.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// Forgets one lesson, from its log too.
    func forget(_ key: String) {
        let now = Self.now
        if key.hasPrefix("float|") {
            let signature = String(key.dropFirst(6))
            let generation = state.withLock { $0.generation += 1; return $0.generation }
            io.async { [self] in
                let kept = floatLog.read(now: now).filter { $0.features.signature != signature }
                floatLog.erase()
                for e in kept { try? floatLog.append(e) }
                let model = FloatClassifier.replay(kept, now: now)
                state.withLock { s in if s.generation == generation { s.model = model } }
            }
        } else if key.hasPrefix("place|") {
            let app = String(key.dropFirst(6))
            state.withLock { s in
                s.workspaces.forget(app)
                s.ledger.forget(key)
            }
            write(WorkspaceMemory.Event(.forgot, app: app, at: now), to: workspaceLog)
        } else {
            state.withLock { s in
                s.arrangements.forget(key)
                s.ledger.forget(key)
            }
            write(ArrangeEvent.forgot(key, at: now), to: arrangeLog)
        }
        scheduleSave()
        learningLog.notice("forgot \(key, privacy: .public)")
    }

    /// Settings › Reset What Lunchbox Learned: forgets every lesson and deletes the folder,
    /// the time back counted in it too. Windows open now stay as they are.
    func reset() {
        TimeBackLedger.shared.reset()
        state.withLock { s in
            s.model = FloatClassifier()
            s.arrangements = ArrangementMemory()
            s.workspaces = WorkspaceMemory()
            s.ledger = UndoLedger()
            s.seen = [:]
            s.generation += 1
        }
        io.async { [self] in
            floatLog.erase()
            arrangeLog.erase()
            workspaceLog.erase()
            try? FileManager.default.removeItem(at: Learning.folder)
            learningLog.notice("forgot everything Lunchbox learned")
        }
    }

    // MARK: Disk

    private func write<E: LoggedEvent>(_ event: E, to log: EventLog<E>) {
        io.async {
            do { try log.append(event) } catch {
                learningLog.error("couldn't write the learning log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes memory.json a couple of seconds after things settle.
    private func scheduleSave() {
        let already = state.withLock { s in
            defer { s.saveScheduled = true }
            return s.saveScheduled || !s.on
        }
        guard !already else { return }
        io.asyncAfter(deadline: .now() + 2) { [self] in
            state.withLock { $0.saveScheduled = false }
            save()
        }
    }

    /// Writes memory.json now (pausing, quitting).
    func saveNow() {
        io.sync { save() }
    }

    /// On the IO queue.
    private func save() {
        let s = state.withLock { $0 }
        guard s.on else { return }
        var snapshot = Snapshot(workspaces: s.workspaces, ledger: s.ledger)
        for (id, seen) in s.seen { snapshot.windows[String(id)] = seen }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: Learning.folder.path) {
            try? fm.createDirectory(at: Learning.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var url = Learning.folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        if (try? data.write(to: snapshotURL, options: .atomic)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        }
    }

    // MARK: Reading a window

    /// An app's name for people, from its bundle ID.
    static func appName(_ bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            return name
        }
        return bundleID
    }

    // MARK: Diagnostics

    /// For `dump`: what's switched on and what's been learned.
    var stateDescription: [String: Any] {
        let s = state.withLock { $0 }
        return [
            "on": s.on,
            "logBytes": floatLog.bytes + arrangeLog.bytes + workspaceLog.bytes,
            "windows": s.seen.map { id, seen in
                "\(id) \(seen.features.signature) \(seen.decision.choice.rawValue) (\(seen.decision.source.rawValue))"
            }.sorted(),
            "lessons": lessons().map(\.text),
            "homes": s.workspaces.homes.mapValues { "\($0.space + 1) lived \($0.lived.map { Int($0) })" },
            "stopped": Array(s.ledger.stopped).sorted(),
        ]
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
