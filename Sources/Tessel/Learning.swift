import AppKit
import os
import TesselCore

private let learningLog = Logger(subsystem: "com.tyleryouens.tessel", category: "learning")

/// Tessel learns where your windows go (docs/learning.md): which windows you float, how you
/// arrange each set of apps, and which Workspace each app lives in. One switch, Settings ›
/// Learn Where Windows Go (the `learning` default), off unless turned on for now.
///
/// Everything it learns is in ~/Library/Application Support/Tessel/Learning, kept out of
/// backups, and none of it is ever sent anywhere. Float decisions are made on each app's own
/// queue, where Tessel reads the window anyway. Arrangements and homes are dictionary reads
/// on the main thread, where windows are placed. Disk work runs on a queue of its own.
final class Learning {
    static let shared = Learning()

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tessel/Learning")
    }

    /// A window Tessel has decided about.
    struct Seen: Codable, Sendable {
        var features: FloatFeatures
        var decision: FloatDecision
        /// Wall-clock seconds when it was first seen.
        var seenAt: Double
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
    private let io = DispatchQueue(label: "com.tyleryouens.tessel.learning", qos: .utility)
    private let floatLog = EventLog<FloatEvent>(folder: Learning.folder, name: "float")
    private let arrangeLog = EventLog<ArrangeEvent>(folder: Learning.folder, name: "arrange")
    private let workspaceLog = EventLog<WorkspaceMemory.Event>(folder: Learning.folder, name: "workspace", maxBytes: 512 << 10)
    private var snapshotURL: URL { Learning.folder.appendingPathComponent("memory.json") }
    /// Held while everything is read back, so no window is decided before the lessons are in
    /// (a window you taught Tessel to float would otherwise tile after a relaunch).
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
        scheduleSave()
        return decision
    }

    /// What was decided for a window, if anything.
    func decision(for id: CGWindowID) -> FloatDecision? {
        state.withLock { $0.on ? $0.seen[id]?.decision : nil }
    }

    /// The size a window had when it first appeared, before Tessel tiled it.
    func openingSize(of id: CGWindowID) -> CGSize? {
        state.withLock { s in s.seen[id].map { CGSize(width: $0.features.width, height: $0.features.height) } }
    }

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

    func loneShape(of app: String, on display: String) -> LoneShape? {
        state.withLock { s in
            guard s.on, s.ledger.allows(ArrangementMemory.loneKey(display: display, app: app)) else { return nil }
            return s.arrangements.loneShape(of: app, on: display)
        }
    }

    /// An arrangement you made (or let stand) stood for `dwell` seconds.
    func arranged(_ a: Arrangement, on display: String, dwell: Double) {
        guard dwell >= 1 else { return }
        let now = Self.now
        let on = state.withLock { s in
            guard s.on else { return false }
            s.arrangements.record(a, on: display, dwell: dwell, at: now)
            return true
        }
        if on { write(ArrangeEvent.arranged(a, on: display, dwell: dwell, at: now), to: arrangeLog) }
    }

    /// You gave a lone window of an app a shape of its own.
    func shaped(_ app: String, shape: LoneShape, on display: String) {
        let on = state.withLock { s in
            guard s.on else { return false }
            s.arrangements.recordLone(app, shape: shape, on: display)
            s.ledger.forget(ArrangementMemory.loneKey(display: display, app: app)) // a new shape: try again
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

    func placed(_ app: String, in space: Int) {
        write(WorkspaceMemory.Event(.placed, app: app, space: space, at: Self.now), to: workspaceLog)
    }

    // MARK: Undo

    /// You pressed the undo key for something Tessel did on its own. True when that thing
    /// now stops (undone twice in a row).
    @discardableResult
    func undone(_ key: String) -> Bool {
        let stopped = state.withLock { $0.ledger.undone(key) }
        if key.hasPrefix("place|") {
            write(WorkspaceMemory.Event(.undone, app: String(key.dropFirst(6)), at: Self.now), to: workspaceLog)
        }
        learningLog.notice("undone: \(key, privacy: .public)\(stopped ? " (stops now)" : "", privacy: .public)")
        scheduleSave()
        return stopped
    }

    /// Something Tessel did on its own stood.
    func kept(_ key: String) {
        state.withLock { $0.ledger.kept(key) }
        scheduleSave()
    }

    // MARK: Lessons

    /// What Tessel learned, in words, each with the key `forget` takes. Main thread.
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
        for (key, _) in s.arrangements.lone where s.ledger.allows(key) {
            let app = String(key.split(separator: "|").last ?? "")
            out.append((key, "\(Self.appName(app)): the size you gave it when it's alone"))
        }
        for app in s.workspaces.homes.keys {
            if !s.ledger.allows("place|\(app)") {
                out.append(("place|\(app)", "\(Self.appName(app)): opens where you are (you undid moving it twice)"))
            } else if let home = s.workspaces.home(of: app) {
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

    /// Settings › Reset What Tessel Learned: forgets every lesson and deletes the folder.
    /// Windows open now stay as they are.
    func reset() {
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
            learningLog.notice("forgot everything Tessel learned")
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

    /// What a window looks like to the classifier. Runs on its app's queue. `subrole` and
    /// `resizable` are passed in from the read Tessel already made.
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
