import AppKit
import os
import TesselCore

let log = Logger(subsystem: "com.tyleryouens.tessel", category: "tiler")

final class ManagedWindow {
    let handle: WindowHandle
    /// Last frame read from the app.
    var frame: CGRect
    /// Last frame we asked for.
    var target: CGRect?
    /// Parked off screen because it belongs to another space.
    var hidden = false
    var minimized = false
    /// A normal document window (not a panel, sheet or helper window).
    var standard = false
    /// When Tessel first saw it.
    let seenAt = CACurrentMediaTime()
    /// It opened just now: only new windows are placed by what Tessel learned.
    var isNew: Bool { CACurrentMediaTime() - seenAt < 10 }
    /// It opened while Tessel was running (not one already open when it started), so how
    /// long it lived means something.
    var openedWhileRunning = false

    init(handle: WindowHandle, frame: CGRect) {
        self.handle = handle
        self.frame = frame
    }

    var id: CGWindowID { handle.id }
    var pid: pid_t { handle.app.pid }
}

private struct WindowInfo {
    let id: CGWindowID
    let element: AXUIElement
    let frame: CGRect
    let tileable: Bool
    let minimized: Bool
    let standard: Bool
    /// A full window in all but name: resizable, with close, minimize and zoom
    /// buttons, but not marked standard (Little Arc says it's a system dialog).
    let windowLike: Bool
    /// An alert, prompt, or Open or Save panel: it floats, centered, never tiled.
    let dialog: Bool
    /// In a Space of its own from the green button.
    let fullScreen: Bool
    /// How many tabs its native tab bar shows (0 without one). macOS lists only the tab in
    /// front; each tab is a window of its own, and the ones behind aren't on screen.
    let tabs: Int
    /// Whether it floats, by what you taught Tessel (nil unless Learning is on).
    let learned: FloatDecision?
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let app = Unmanaged<AppHandle>.fromOpaque(refcon).takeUnretainedValue()
    Tiler.shared?.received(notification as String, element: element, app: app)
}

/// Keeps every visible window tiled, per display and per space.
final class Tiler {
    static weak var shared: Tiler?

    static let gap: CGFloat = 8
    static let spaceCount = 3
    static let resizeStep = 0.08
    /// Apps whose windows always float.
    static let floatingApps: Set<String> = [
        "com.apple.systempreferences", "com.apple.iphonesimulator", "com.1password.1password",
        "com.apple.calculator", "com.apple.QuickTimePlayerX", "com.apple.ScreenSharing",
        "com.apple.screencaptureui", "com.tyleryouens.tessel",
    ]

    private(set) var enabled = false
    private(set) var currentSpace = 0
    private(set) var displays: [Display] = []
    /// Off: Tessel uses only the main display and ignores the others (e.g. a dummy display plug).
    private(set) var useAllDisplays = UserDefaults.standard.object(forKey: "useAllDisplays") as? Bool ?? true
    /// The displays Tessel tiles on.
    private var activeDisplays: [Display] {
        useAllDisplays ? displays : displays.filter(\.isMain)
    }
    /// When Tessel last gave a window focus itself.
    private var lastActivation: CFTimeInterval = 0
    private var apps: [pid_t: AppHandle] = [:]
    private var windows: [CGWindowID: ManagedWindow] = [:]
    /// The layout of each display (by UUID) in each space.
    private var spaces: [[String: Layout]] = Array(repeating: [:], count: Tiler.spaceCount)
    private var userFloating = Set<CGWindowID>()
    private(set) var focusedID: CGWindowID?
    private var lastFocused: [Int: CGWindowID] = [:]
    private var savedPlacement: [CGWindowID: (space: Int, display: String)] = [:]
    /// Each layout as it was when Tessel last ran (or was paused), by "space|display".
    /// A window coming back takes its old spot: same stack, column order and shares.
    private var savedLayouts: [String: Layout] = [:]
    private var settlingUntil: [CGWindowID: CFTimeInterval] = [:]
    private var lastReassert: [CGWindowID: CFTimeInterval] = [:]
    /// Windows that moved on their own, waiting to hold still before they go back.
    private var pendingReassert: [CGWindowID: DispatchWorkItem] = [:]
    /// When the user last let go of a dragged window. Dropped at a screen edge, macOS 15 and
    /// later animates it into a tile of its own right after Tessel sends it back.
    private var droppedAt: [CGWindowID: CFTimeInterval] = [:]
    private var draggedByUser = Set<CGWindowID>()
    private var mouseDown: CGPoint?
    private var notificationTokens: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    /// A slow safety net for windows that vanish without any event at all.
    private var ghostTimer: Timer?

    private let animator = Animator()
    private let ring = FocusRing()
    private let badge = SpaceBadge()
    var onChange: (() -> Void)?

    init() {
        Tiler.shared = self
        animator.onSettled = { [weak self] id, actual, _ in self?.settled(id, at: actual) }
        shelf.onPick = { [weak self] id in
            guard let self else { return }
            self.activate(id)
            self.showRing(on: id)
        }
        // Dragging a file onto a card: Focus ends and the windows come back to their tiles,
        // so the drop can land in any of them. Nothing is activated mid-drag.
        shelf.onDragRest = { [weak self] _ in self?.exitSpotlight() }
        let defaults = UserDefaults.standard
        currentSpace = min(Self.spaceCount - 1, max(0, defaults.integer(forKey: "currentSpace")))
        // Window numbers stay the same while a window lives, so this survives a relaunch.
        adopted = Set(((defaults.array(forKey: "adopted") as? [Int]) ?? []).map(CGWindowID.init))
        // Left from when lone windows took their app's own size; they're always 16:10 now.
        defaults.removeObject(forKey: "tileSizes")
        defaults.removeObject(forKey: "appSizes")
    }

    /// Reads where every window was when Tessel last ran or was paused, so the
    /// windows still open go back to the same Workspace, display and spot.
    /// Window numbers stay the same while a window lives, so this survives a relaunch.
    private func loadSaved() {
        let defaults = UserDefaults.standard
        savedPlacement = [:]
        for (key, value) in (defaults.dictionary(forKey: "placement") as? [String: String]) ?? [:] {
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            if let id = CGWindowID(key), parts.count == 2, let space = Int(parts[0]) {
                savedPlacement[id] = (space, parts[1])
            }
        }
        let json = defaults.string(forKey: "layouts").map { Data($0.utf8) }
        savedLayouts = json.flatMap { try? JSONDecoder().decode([String: Layout].self, from: $0) } ?? [:]
    }

    // MARK: Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        initialScanDone = false
        // Windows put back after Tessel starts again count as time back; after a pause, they
        // only undo the pause.
        countsRestores = !startedBefore
        startedBefore = true
        loadSaved()
        displays = Display.current()
        TimeBackLedger.shared.load()
        Learning.shared.start(alive: allWindowIDs())
        Learning.shared.setScreens(displays.map(\.visible))
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        func on(_ name: Notification.Name, _ center: NotificationCenter = NSWorkspace.shared.notificationCenter, _ body: @escaping (Notification) -> Void) {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: body))
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.track(app) }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] n in
            // When an app quits, even a helper with no windows, macOS activates whichever app
            // was before it, maybe one in another space. That isn't a request to go there.
            self?.quietFocus(for: 0.8)
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.untrack(app.processIdentifier)
                self?.stopExpecting(app.bundleIdentifier, pid: app.processIdentifier, why: "it quit")
            }
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.appActivated(app) }
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] n in self?.rescan(n) }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] n in self?.rescan(n) }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.scanAll(after: [0.03, 0.8, 1.6]) }
        on(NSApplication.didChangeScreenParametersNotification, .default) { [weak self] _ in self?.displaysMayHaveChanged() }
        // Showing or hiding the Dock changes the usable area of the screen.
        on(Notification.Name("com.apple.dock.prefchanged"), DistributedNotificationCenter.default()) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.displaysChanged() }
        }

        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return }
                let point = NSScreen.topLeftPoint(fromCocoa: NSEvent.mouseLocation)
                self.mouseDown = point
                self.lastClick = (CACurrentMediaTime(), point)
                self.draggedByUser.removeAll()
                if event.modifierFlags.contains(.control), self.isDockClick(point) { self.dockMenuOpenedAt = CACurrentMediaTime() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
                guard let self else { return }
                let point = NSScreen.topLeftPoint(fromCocoa: NSEvent.mouseLocation)
                if self.isDockClick(point) { self.dockMenuOpenedAt = CACurrentMediaTime() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() },
        ].compactMap { $0 }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkForGhosts() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        ghostTimer = timer
        let minute = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.learningTick() }
        minute.tolerance = 5
        RunLoop.main.add(minute, forMode: .common)
        learningTimer = minute

        for app in NSWorkspace.shared.runningApplications { track(app, scan: false) }
        mergeInactiveDisplays()
        initialScan()
        log.notice("started with \(self.displays.count) displays, space \(self.currentSpace + 1)")
    }

    /// Stops managing windows and brings every parked window back into view.
    func stop() {
        guard enabled else { return }
        persist() // resuming puts everything back where it is now
        revealHiddenWindows()
        for key in Array(standing.keys) { flushStanding(key) }
        automatic = nil
        placedForYou = [:]
        requested = []
        learningTimer?.invalidate()
        learningTimer = nil
        Learning.shared.stop()
        TimeBackLedger.shared.saveNow()
        enabled = false
        notificationTokens.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        notificationTokens = []
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        expected.forEach { $0.tile.dismiss(animated: false) }
        expected = []
        placeholderCheck?.cancel()
        placeholderCheck = nil
        ghostTimer?.invalidate()
        ghostTimer = nil
        mouseMonitors = []
        for pid in Array(apps.keys) { detach(apps[pid]!) }
        apps = [:]
        windows = [:]
        spaces = Array(repeating: [:], count: Self.spaceCount)
        onChange?()
    }

    /// Moves every window parked for another space back onto its display.
    /// Runs synchronously so it finishes before Tessel quits.
    func revealHiddenWindows() {
        shelf.hide(animated: false)
        for s in spaces.indices { for uuid in spaces[s].keys { spaces[s][uuid]?.spotlight = nil } }
        for (_, layouts) in spaces.enumerated() {
            for (uuid, layout) in layouts {
                let display = displays.first { $0.uuid == uuid } ?? displays.first
                guard let d = display else { continue }
                for (id, frame) in layout.frames(in: d.visible, gap: Self.gap) {
                    guard let w = windows[id], w.hidden else { continue }
                    let size = w.target?.size ?? w.frame.size
                    let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
                    w.handle.element.setPosition(CGPoint(x: max(d.visible.minX, origin.x), y: max(d.visible.minY, origin.y)))
                    w.hidden = false
                }
            }
        }
    }

    // MARK: Apps and windows

    private func track(_ running: NSRunningApplication, scan: Bool = true) {
        let pid = running.processIdentifier
        guard enabled, running.activationPolicy == .regular, pid != getpid(), apps[pid] == nil else { return }
        let app = AppHandle(pid: pid, bundleID: running.bundleIdentifier)
        apps[pid] = app
        // An app Tessel is holding a tile for has started: from now on it's this process.
        for e in expected where e.pid == nil && e.bundleID == running.bundleIdentifier { e.pid = pid }
        // Started right after a key press or click (Spotlight, Finder, a launcher): you opened it.
        if scan, Self.secondsSinceInput() < 1.5 { launchedByYou[pid] = CACurrentMediaTime() }
        attachObserver(app)
        if scan { scheduleScan(app, after: [0.1, 0.5, 1.5]) }
    }

    private func attachObserver(_ app: AppHandle) {
        var observer: AXObserver?
        guard AXObserverCreate(app.pid, axCallback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(app).toOpaque()
        let names = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification]
        let results = names.map { AXObserverAddNotification(observer, app.element, $0 as CFString, refcon) }
        if results.contains(.cannotComplete), app.observerAttempts < 6 {
            // The app is still starting up; try again shortly.
            app.observerAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak app] in
                guard let self, let app, self.apps[app.pid] === app else { return }
                self.attachObserver(app)
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        app.observer = observer
    }

    private func detach(_ app: AppHandle) {
        app.pendingScan?.cancel()
        if let observer = app.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            app.observer = nil
        }
    }

    private func untrack(_ pid: pid_t) {
        launchedByYou[pid] = nil
        guard let app = apps.removeValue(forKey: pid) else { return }
        detach(app)
        let gone = windows.values.filter { $0.pid == pid }.map(\.id)
        let focusedFrame = focusedID.flatMap { id in gone.contains(id) ? visibleFrames()[id] : nil }
        if !gone.isEmpty { quietFocus(for: 1) }
        gone.forEach { forget($0, appQuit: true) }
        if !gone.isEmpty {
            relayout(animated: true)
            persist()
        }
        // An app that quits with its last window hands focus to whichever app was
        // before it, maybe one parked in another space. Stay where the user was looking.
        if let focusedFrame { focusNearest(to: focusedFrame) }
    }

    private func rescan(_ n: Notification) {
        guard let running = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let app = apps[running.processIdentifier] else { return }
        scheduleScan(app)
    }

    func scanAll(after delays: [Double] = [0.03]) {
        guard enabled else { return }
        for app in apps.values { scheduleScan(app, after: delays) }
    }

    private func scheduleScan(_ app: AppHandle, after delays: [Double] = [0.03]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak app] in
                guard let self, let app, self.apps[app.pid] === app else { return }
                app.queue.async {
                    let infos = Self.readWindows(of: app)
                    DispatchQueue.main.async { self.apply(infos, for: app) }
                }
            }
        }
    }

    /// Runs on the app's queue.
    private static func readWindows(of app: AppHandle) -> [WindowInfo] {
        let all = app.element.elements(kAXWindowsAttribute)
        return all.compactMap { element in
            guard let id = element.windowID, let frame = element.frame else { return nil }
            let standard = element.role == kAXWindowRole && element.subrole == kAXStandardWindowSubrole
            let minimized = element.isMinimized
            let dialog = Dialogs.isDialog(subrole: element.subrole, identifier: element.string(kAXIdentifierAttribute),
                                          hasDefaultButton: element.element(kAXDefaultButtonAttribute) != nil,
                                          hasCancelButton: element.element(kAXCancelButtonAttribute) != nil,
                                          modal: element.bool(kAXModalAttribute))
            let fullScreen = element.isFullScreen
            let usable = !minimized && !fullScreen && element.isResizable && !dialog
            let tileable = standard && usable
            let windowLike = tileable || (usable && element.role == kAXWindowRole
                && element.element(kAXCloseButtonAttribute) != nil
                && element.element(kAXMinimizeButtonAttribute) != nil
                && element.element(kAXZoomButtonAttribute) != nil)
            let tabs = element.elements(kAXChildrenAttribute)
                .first { $0.role == "AXTabGroup" }.map { $0.elements(kAXTabsAttribute).count } ?? 0
            // The first time a window that could tile shows up, Learning decides how it behaves:
            // the window classifier, then your own corrections. Off, it's the rules as always.
            let verdict = windowLike ? Learning.shared.decide(id) { screens in
                app.bundleID.map { bundleID in
                    WindowReader.traits(of: element, id: id, bundleID: bundleID,
                                        appName: NSRunningApplication(processIdentifier: app.pid)?.localizedName,
                                        frame: frame, screens: screens, appWindows: all.count)
                }
            } : nil
            return WindowInfo(id: id, element: element, frame: frame, tileable: tileable, minimized: minimized,
                              standard: standard, windowLike: windowLike,
                              // A window asking something that the rules missed floats centered too.
                              dialog: dialog || verdict?.behavior == .dialog, fullScreen: fullScreen,
                              tabs: tabs, learned: verdict?.decision)
        }
    }

    /// Reads every app at once at startup so existing windows can be laid out
    /// left to right in the order they already sit on screen.
    private func initialScan() {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [(AppHandle, [WindowInfo])] = []
        for app in apps.values {
            group.enter()
            app.queue.async {
                let infos = Self.readWindows(of: app)
                lock.lock(); results.append((app, infos)); lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.enabled else { return }
            let onScreen = onScreenWindowIDs()
            let shown = shownSpaces()
            var all: [(AppHandle, WindowInfo)] = []
            for (app, infos) in results { infos.forEach { all.append((app, $0)) } }
            all.sort { ($0.1.frame.minX, $0.1.frame.minY) < ($1.1.frame.minX, $1.1.frame.minY) }
            for (app, info) in all { self.consider(info, app: app, onScreen: onScreen, shown: shown) }
            // Windows closed while Tessel wasn't running don't come back, and their
            // numbers get reused by new windows: forget their spots.
            let alive = allWindowIDs()
            if !alive.isEmpty { self.savedPlacement = self.savedPlacement.filter { alive.contains($0.key) } }
            self.relayout(animated: false)
            self.persist()
            self.refreshFocus()
            self.initialScanDone = true
        }
    }

    private func apply(_ infos: [WindowInfo], for app: AppHandle) {
        guard enabled, apps[app.pid] === app else { return }
        let onScreen = onScreenWindowIDs()
        let shown = shownSpaces()
        let seen = Set(infos.map(\.id))
        let visibleBefore = visibleFrames().filter { windows[$0.key]?.pid == app.pid }
        let focusedBefore = focusedID
        var changed = false
        let now = CACurrentMediaTime()
        for id in seen { unlistedSince[id] = nil }
        for w in windows.values where w.pid == app.pid && !seen.contains(w.id) {
            if isOutOfView(w.id, shown: shown) { continue } // behind a full screen app: it keeps its tile
            // Going in or out of full screen, a window isn't on any Space for a moment.
            // A closed window says so and is forgotten right then; a tiled one that only
            // went missing gets a moment to show up again (one in full screen, longer).
            if place(of: w.id) != nil || fullScreenSpots[w.id] != nil {
                let since = unlistedSince[w.id] ?? now
                unlistedSince[w.id] = since
                let wait = fullScreenSpots[w.id] != nil ? 6.0 : 1.5
                if now - since < wait {
                    scheduleScan(app, after: [wait + 0.1 - (now - since)])
                    continue
                }
            }
            forget(w.id)
            changed = true
        }
        // Whatever window answers a Summon open belongs in the layout, even one its app
        // doesn't call standard, like the Little Arc window a web search opens in.
        var arrived: CGWindowID?
        if let arrival = summonedArrival, arrival.bundleID == app.bundleID {
            if CACurrentMediaTime() > arrival.until {
                summonedArrival = nil
            } else if let fresh = infos.first(where: { !arrival.existing.contains($0.id) && $0.windowLike && onScreen.contains($0.id) }) {
                summonedArrival = nil
                if !fresh.tileable { adopted.insert(fresh.id) }
                arrived = fresh.id
            }
        }
        // Windows on screen first: a tab coming forward takes over its tab group's tile
        // before the tab that just went back is looked at.
        let ordered = infos.filter { onScreen.contains($0.id) } + infos.filter { !onScreen.contains($0.id) }
        if let arrived { requested.insert(arrived) }
        for info in ordered where consider(info, app: app, onScreen: onScreen, shown: shown) { changed = true }
        if changed {
            relayout(animated: true)
            persist()
        }
        if let arrived, place(of: arrived) != nil {
            activate(arrived)
            showRing(on: arrived)
        }
        // A window you were using left without saying so (Chess after ⌘W): keep
        // the keyboard on a window you can see. Not one that went full screen: that
        // would take you straight back out of it.
        let after = visibleFrames()
        if arrived == nil, let (_, frame) = visibleBefore.first(where: { after[$0.key] == nil && fullScreenSpots[$0.key] == nil }),
           visibleBefore.keys.contains(where: { $0 == focusedBefore }) || NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid {
            focusNearest(to: frame)
        }
        // A window the launcher asked for has appeared: bring it forward.
        if let pending = pendingNewWindow, pending.pid == app.pid {
            if CACurrentMediaTime() > pending.deadline {
                pendingNewWindow = nil
            } else if let fresh = infos.map(\.id).first(where: { !pending.existing.contains($0) && place(of: $0) != nil }) {
                pendingNewWindow = nil
                activate(fresh)
                showRing(on: fresh)
            }
        }
    }

    private var pendingNewWindow: (pid: pid_t, existing: Set<CGWindowID>, deadline: CFTimeInterval)?

    /// Registers a window and adds it to or removes it from the layout as needed.
    /// Returns true when the layout changed.
    @discardableResult
    private func consider(_ info: WindowInfo, app: AppHandle, onScreen: Set<CGWindowID>, shown: Set<Int>) -> Bool {
        let isNew = windows[info.id] == nil
        let window = windows[info.id] ?? register(info, app: app)
        let spot = place(of: info.id)
        // A dialog floats, centered on the screen it opened on, instead of slicing the
        // tiled windows apart: once, the first time it's on screen (apps often make the
        // window a moment before showing it). Ones open before Tessel started stay put.
        if info.dialog, !centeredDialogs.contains(info.id) {
            if !initialScanDone {
                centeredDialogs.insert(info.id)
            } else if onScreen.contains(info.id) || isDialogShowing(info.id, pid: app.pid, frame: info.frame) {
                centeredDialogs.insert(info.id)
                center(info, app: app)
            } else {
                centerOnceShown(info, app: app)
            }
        }
        if !window.hidden { window.frame = info.frame }
        window.minimized = info.minimized
        window.standard = info.standard
        let appHidden = NSRunningApplication(processIdentifier: app.pid)?.isHidden ?? false
        let ruleTiles = (info.tileable || (adopted.contains(info.id) && info.windowLike))
            && !Self.floatingApps.contains(app.bundleID ?? "")
        let wantsTile = tiles(info, rule: ruleTiles, placed: spot != nil)
            && !offDisplay.contains(info.id)
            && !leftAloneApps.contains(app.bundleID ?? "")
            && !appHidden
            && !userFloating.contains(info.id)
            // While a display shows a full screen app, its desktop's windows are out of
            // sight, not gone: they keep their tiles.
            && (onScreen.contains(info.id) || window.hidden
                || (spot != nil && isOutOfView(info.id, shown: shown)))
        // A new window going against the rules because of what you taught Tessel: one quiet line.
        if initialScanDone, window.isNew, info.windowLike, onScreen.contains(info.id), savedPlacement[info.id] == nil,
           !announced.contains(info.id), let d = Learning.shared.decision(for: info.id), d.source == .learned {
            announced.insert(info.id)
            let name = Learning.appName(app.bundleID ?? "")
            let display = displays.first { $0.frame.contains(info.frame.center) }
            didOnItsOwn(d.choice == .float ? .floated(app: name) : .tiled(app: name),
                        undo: d.choice == .float ? .float(info.id) : .tile(info.id),
                        key: "float|\(info.id)", from: currentSpace, on: display)
        }
        let placed = spot != nil
        if wantsTile && !placed {
            // A tab of a native tab group came forward (switched to, or just opened): each tab is
            // a window of its own and only the front one shows. It takes over the tile of the
            // app's window that just went out of view: the one in the same frame, else the one
            // last used.
            let behind = info.tabs >= 2 && onScreen.contains(info.id) ? windows.values.filter { other in
                other.pid == app.pid && other.id != info.id && !other.hidden && !onScreen.contains(other.id)
                    && place(of: other.id) != nil
            } : []
            let tab = behind.first { $0.frame.isClose(to: info.frame, tolerance: 2) }
                ?? behind.first { $0.id == focusedID } ?? behind.first { lastFocused.values.contains($0.id) } ?? behind.first
            if let tab, let (s, uuid) = place(of: tab.id) {
                spaces[s][uuid]?.replace(tab.id, with: info.id)
                window.target = tab.target
                tab.target = nil
                offScreenSince[tab.id] = nil
                log.notice("window \(info.id) is a tab of \(tab.id): took over its tile")
                return true
            }
            insert(window)
            if initialScanDone { confirmPlacement(of: info.id) }
            return true
        }
        // A tiled window that only went out of view (a tab sent back, a window on its way to
        // full screen, a closed window an app keeps around) keeps its tile a moment, so a
        // tab coming forward can take it over instead of the layout reshuffling.
        if !wantsTile && placed, initialScanDone, !onScreen.contains(info.id), !window.hidden, !info.minimized,
           !info.fullScreen, !appHidden, info.tileable || info.windowLike {
            let now = CACurrentMediaTime()
            let since = offScreenSince[info.id] ?? now
            offScreenSince[info.id] = since
            if now - since < 0.6 {
                scheduleScan(app, after: [0.65 - (now - since)])
                return false
            }
        }
        if wantsTile { offScreenSince[info.id] = nil }
        if !wantsTile && placed {
            offScreenSince[info.id] = nil
            // The green button: the window leaves for a Space of its own (first vanishing
            // for a moment on the way). Remember exactly where it was, and whether it was
            // in Focus, so it comes back to the same spot.
            if let spot, info.fullScreen || (!onScreen.contains(info.id) && !window.hidden && !info.minimized && !appHidden),
               fullScreenSpots[info.id] == nil, let layout = spaces[spot.space][spot.display] {
                fullScreenSpots[info.id] = (spot.space, spot.display, layout, layout.spotlight == info.id)
            }
            removeFromLayouts(info.id)
            window.target = nil
            return true
        }
        if !wantsTile, isNew, initialScanDone, info.windowLike, onScreen.contains(info.id) {
            // The app Tessel is holding a tile for answered with a window that doesn't
            // tile (a fixed-size window, say). Its real one may be right behind; if
            // not, close the gap soon instead of waiting it out.
            let soon = CACurrentMediaTime() + Self.placeholderAfterOtherWindow
            for e in expected where e.matches(window) { e.deadline = min(e.deadline, soon) }
        }
        return false
    }

    private func register(_ info: WindowInfo, app: AppHandle) -> ManagedWindow {
        let window = ManagedWindow(handle: WindowHandle(id: info.id, element: info.element, app: app), frame: info.frame)
        window.openedWhileRunning = initialScanDone
        windows[info.id] = window
        app.windowIDs[info.element] = info.id
        if let observer = app.observer {
            let refcon = Unmanaged.passUnretained(app).toOpaque()
            for name in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverAddNotification(observer, info.element, name as CFString, refcon)
            }
        }
        return window
    }

    /// Whether a window tiles: what the rules say, unless you taught Tessel otherwise
    /// (Learning, off by default). Your own choice for this window always stands. Otherwise
    /// a window Summon opened tiles as the rules say, and a window already tiled (or tiled
    /// before a relaunch or a pause) stays tiled: what Tessel learns never moves a window
    /// that's already in place.
    private func tiles(_ info: WindowInfo, rule: Bool, placed: Bool) -> Bool {
        guard info.windowLike, let learned = Learning.shared.decision(for: info.id) ?? info.learned else { return rule }
        if learned.source != .you, adopted.contains(info.id) || placed || savedPlacement[info.id] != nil {
            let choice: FloatChoice = (adopted.contains(info.id) ? rule : true) ? .tile : .float
            if learned.choice != choice { Learning.shared.overrule(info.id, to: choice) }
            return choice == .tile
        }
        return learned.choice == .tile
    }

    /// Floats the focused window, or tiles a floating one (the `float` command and menu item,
    /// with Learning on). Tessel learns from it: the next window of the same kind follows.
    func toggleFloating() {
        guard enabled, let id = focusedID else { return }
        toggleFloating(id)
    }

    private func toggleFloating(_ id: CGWindowID) {
        guard Learning.shared.isOn, let w = windows[id], !w.hidden else { return }
        let tiled = place(of: id) != nil
        guard Learning.shared.corrected(id, to: tiled ? .float : .tile, by: .toggle) else { return }
        log.notice("window \(id) (\(w.handle.app.bundleID ?? "?", privacy: .public)) \(tiled ? "floats" : "tiles", privacy: .public) now")
        if tiled {
            float(w)
        } else {
            scheduleScan(w.handle.app) // consider() tiles it, next to the focused window
        }
    }

    /// Whether the focused window floats, for the menu: nil without one that could go
    /// either way.
    var focusedFloats: Bool? {
        guard let id = focusedID, let w = windows[id], !w.hidden, Learning.shared.decision(for: id) != nil else { return nil }
        return place(of: id) == nil
    }

    /// Takes a window out of the layout; the others close the gap. It goes back to the size
    /// it opened at: centered where its tile was, or with its top-left corner where you
    /// dropped it (`droppedAt`), kept on screen either way.
    private func float(_ w: ManagedWindow, droppedAt: CGPoint? = nil) {
        let from = droppedAt == nil ? (w.target ?? w.frame) : w.frame
        removeFromLayouts(w.id)
        w.target = nil
        relayout(animated: true)
        persist()
        if let size = Learning.shared.openingSize(of: w.id), size.width >= 100, size.height >= 60,
           let d = displays.first(where: { $0.frame.contains(from.center) }) ?? displays.first(where: \.isMain) {
            let origin = droppedAt ?? CGPoint(x: from.midX - size.width / 2, y: from.midY - size.height / 2)
            let width = min(size.width, d.visible.width), height = min(size.height, d.visible.height)
            let x = min(max(origin.x, d.visible.minX), d.visible.maxX - width)
            let y = min(max(origin.y, d.visible.minY), d.visible.maxY - height)
            let frame = CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
            if !frame.isClose(to: from, tolerance: 2) {
                animator.run([(w.handle, from, frame, animationsAllowed ? .animate : .snap)])
                w.frame = frame
            }
        }
        showRing(on: w.id)
    }

    // MARK: Learning: what Tessel does on its own

    /// `learning-lived:<seconds>`: counts that much window time in each Workspace at once, to
    /// try Workspace homes without waiting ten minutes.
    func countLivedForTesting(_ seconds: Double) { learningTick(seconds: seconds, testing: true) }

    /// Settings › Learn Where Windows Go. Windows already open stay as they are until Tessel
    /// looks at them again.
    func setLearning(_ on: Bool) {
        Learning.shared.setSwitch(on, alive: allWindowIDs())
        if !on {
            for key in Array(standing.keys) { flushStanding(key) }
            automatic = nil
        }
        scanAll()
        onChange?()
    }

    /// Says what Tessel did on its own, and which key undoes it.
    private let quietLine = QuietLineView()
    /// Names the undo key for a Workspace, like "⌘ Page Up" (set by the app, which knows the keys).
    var undoKeyName: ((Int) -> String?)?

    /// What Tessel just did on its own, undoable for a few seconds with ⌘ and the key of the
    /// Workspace you were in (Etiquette). Things done within a second of each other (windows
    /// coming back after a login) share one line and one undo.
    private struct Automatic {
        enum Undo {
            /// It floated by itself: tile it.
            case float(CGWindowID)
            /// It tiled by itself: float it.
            case tile(CGWindowID)
            /// It took its usual spot: put it where it would have gone.
            case layout(space: Int, display: String, applied: Layout, plain: Layout)
            /// It went to its app's Workspace: bring it to the one you were in.
            case place(CGWindowID, from: Int)
        }
        var actions: [AutomaticAction]
        var undos: [Undo]
        var keys: [String]
        /// The Workspace you were in: its key undoes this.
        var from: Int
        var at: CFTimeInterval
        var until: CFTimeInterval
        var display: Display?
    }
    private var automatic: Automatic?
    /// Windows Tessel opened in their app's Workspace while you stayed here: their app reaching
    /// for focus isn't you asking to go there.
    private var placedForYou: [CGWindowID: CFTimeInterval] = [:]
    /// Windows that answered something you opened from Tessel (Summon): they come to you.
    private var requested = Set<CGWindowID>()
    /// New windows whose learned float or tile was already announced.
    private var announced = Set<CGWindowID>()
    /// Apps you just launched yourself (Spotlight, Finder, a launcher), and when: when their
    /// window goes to its home, you go with it.
    private var launchedByYou: [pid_t: CFTimeInterval] = [:]
    /// Arrangements you made (or let stand), and since when, by "space|display".
    private var standing: [String: (arrangement: Arrangement, display: String, since: CFTimeInterval)] = [:]
    private var learningTimer: Timer?
    private var learningTicks = 0

    private func didOnItsOwn(_ action: AutomaticAction, undo: Automatic.Undo, key: String, from: Int, on display: Display?) {
        let now = CACurrentMediaTime()
        // Following you to another Workspace, the undo key also just takes you back: it only
        // brings the window along while the line is up.
        let window: Double
        if case .followed = action { window = Etiquette.lineSeconds + 1 } else { window = Etiquette.undoSeconds }
        if var a = automatic, now - a.at < Etiquette.batchSeconds, a.from == from {
            a.actions.append(action)
            a.undos.append(undo)
            a.keys.append(key)
            a.until = min(a.until, now + window)
            automatic = a
        } else {
            if let a = automatic { a.keys.forEach { Learning.shared.kept($0) } }
            automatic = Automatic(actions: [action], undos: [undo], keys: [key], from: from, at: now, until: now + window,
                                  display: display ?? displays.first(where: \.isMain))
            DispatchQueue.main.asyncAfter(deadline: .now() + Etiquette.undoSeconds + 0.1) { [weak self] in
                guard let self, let a = self.automatic, a.at == now else { return }
                a.keys.forEach { Learning.shared.kept($0) }
                self.automatic = nil
            }
        }
        guard let a = automatic else { return }
        quietLine.show(QuietLine.text(for: a.actions, undoKey: undoKeyName?(a.from)), on: a.display)
        log.notice("on its own: \(String(describing: action), privacy: .public)")
    }

    /// ⌘ and the key of the Workspace you were in, right after Tessel did something on its own:
    /// undo it. False when there's nothing to undo, so the key does what it always does.
    private func undoAutomatic(pressed index: Int) -> Bool {
        guard let a = automatic, a.from == index, CACurrentMediaTime() < a.until else { return false }
        automatic = nil
        for key in a.keys where !key.hasPrefix("float|") { Learning.shared.undone(key) }
        var back: [CGWindowID] = []
        for undo in a.undos.reversed() {
            switch undo {
            case .float(let id):
                if place(of: id) == nil { toggleFloating(id) } // tiles it; Tessel learns from that
            case .tile(let id):
                if place(of: id) != nil { toggleFloating(id) }
            case .layout(let space, let display, let applied, var plain):
                guard var now = spaces[space][display] else { continue }
                // A placeholder that has since been filled by its window counts as the same.
                for id in applied.placeholders where !now.contains(id) {
                    if let filled = now.windows.first(where: { !applied.contains($0) }) {
                        plain.replace(id, with: filled)
                        now.replace(filled, with: id)
                    }
                }
                if now == applied { spaces[space][display] = plain }
            case .place(let id, let from):
                guard windows[id] != nil, let (space, uuid) = place(of: id), space != from else { continue }
                removeFromLayouts(id)
                var layout = spaces[from][uuid] ?? Layout()
                let near = lastFocused[from].flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
                let width = displays.first { $0.uuid == uuid }?.visible.width ?? 1600
                layout.insert(id, near: near, maxColumns: Layout.maxColumns(forWidth: width))
                spaces[from][uuid] = layout
                placedForYou[id] = nil
                back.append(id)
            }
        }
        quietLine.show("Undone", on: a.display)
        if currentSpace != index {
            switchSpace(to: index, focusing: back.first)
        } else {
            relayout(animated: true)
            persist()
        }
        if let id = back.first {
            activate(id)
            showRing(on: id)
        }
        return true
    }

    /// Something you opened from Tessel is on its way to this app: its window comes to you.
    private func isRequested(_ w: ManagedWindow) -> Bool {
        if requested.contains(w.id) { return true }
        let now = CACurrentMediaTime()
        let bundleID = w.handle.app.bundleID
        if let p = pendingNewWindow, p.pid == w.pid, now < p.deadline { return true }
        if let m = dockMenuActivation, m.pid == w.pid, now < m.until { return true }
        if let d = dockClick, d.pid == w.pid, now < d.until { return true }
        if let a = summonedArrival, a.bundleID == bundleID, now < a.until { return true }
        if let e = expectedArrival, e.bundleID == bundleID, now < e.until { return true }
        return false
    }

    /// You opened this window yourself, just now (outside Tessel): you go where it goes.
    private func openedByYou(_ w: ManagedWindow) -> Bool {
        if let at = launchedByYou[w.pid], CACurrentMediaTime() - at < 30 { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid && Self.secondsSinceInput() < 2
    }

    /// Seconds since your last key press or click.
    static func secondsSinceInput() -> Double {
        min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))
    }

    /// The Workspaces an app's windows are in right now.
    private func spacesOf(_ app: String, excluding id: CGWindowID) -> Set<Int> {
        Set(spaces.indices.filter { s in
            spaces[s].values.contains { layout in layout.windows.contains { $0 != id && windows[$0]?.handle.app.bundleID == app } }
        })
    }

    /// The app of a window or of a placeholder.
    private func appID(of id: CGWindowID) -> String? {
        windows[id]?.handle.app.bundleID ?? expected.first { $0.id == id }?.bundleID
    }

    /// What a display is remembered by: its size, so the same arrangement comes back on any
    /// display that size (and the same display, wherever it's plugged in).
    static func displayKey(_ d: Display) -> String { "\(Int(d.frame.width))x\(Int(d.frame.height))" }

    /// Where a new window (or a placeholder) usually goes next to the windows in `layout`: its
    /// usual spot and share, or the shape you gave its app's windows when alone.
    private func usualPlace(_ id: CGWindowID, app: String, in layout: Layout,
                            display: Display) -> (Layout, AutomaticAction, String)? {
        guard Learning.shared.isOn else { return nil }
        let key = Self.displayKey(display)
        let name = Learning.appName(app)
        if layout.isEmpty {
            guard let shape = Learning.shared.loneShape(of: app, on: key) else { return nil }
            var lone = Layout(columns: [Column(windows: [id])])
            lone.singleOwner = id
            lone.singleScale = shape.scale
            lone.singleHeight = shape.height
            return (lone, .shaped(app: name), ArrangementMemory.loneKey(display: key, app: app))
        }
        var apps: [WindowID: String] = [:]
        for wid in layout.windows { apps[wid] = appID(of: wid) }
        guard apps.count == layout.windowCount else { return nil }
        let all = Array(apps.values) + [app]
        guard let usual = Learning.shared.arrangement(display: key, apps: all),
              let placed = usual.place(id, app: app, in: layout, apps: apps) else { return nil }
        return (placed, .arranged(app: name), ArrangementMemory.key(display: key, apps: all))
    }

    /// A new window went to the Workspace its app lives in. If you just opened it, you go
    /// with it, the way the Dock takes you to an app's window. If it opened by itself, you
    /// stay, and so does the keyboard.
    private func placedInHome(_ window: ManagedWindow, app: String, home: Int, display: Display) {
        let from = currentSpace
        let name = Learning.appName(app)
        Learning.shared.placed(app, in: home)
        if openedByYou(window) {
            didOnItsOwn(.followed(app: name, space: home), undo: .place(window.id, from: from), key: "place|\(app)",
                        from: from, on: display)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.place(of: window.id)?.space == home else { return }
                self.lastFocused[home] = window.id
                self.switchSpace(to: home, focusing: window.id)
                self.activate(window.id)
                self.showRing(on: window.id)
            }
        } else {
            placedForYou[window.id] = CACurrentMediaTime() + 3
            didOnItsOwn(.sent(app: name, space: home), undo: .place(window.id, from: from), key: "place|\(app)",
                        from: from, on: display)
            // Its app may have taken the keyboard on its way: give it back.
            for delay in [0.1, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
                        || self.focusedID == window.id else { return }
                    if self.focusedID == window.id { self.focusedID = self.lastFocused[self.currentSpace] }
                    self.reclaimFocus()
                }
            }
        }
    }

    /// You arranged a layout (or let Tessel's arrangement stand): from now on it counts,
    /// for as long as it stays the same. `shaped`: you resized a lone window (or Tidied it),
    /// and that shape is kept right away.
    private func noteArranged(space: Int, display uuid: String, byYou: Bool = true, shaped: Bool = false) {
        guard Learning.shared.isOn, let d = displays.first(where: { $0.uuid == uuid }) else { return }
        let key = "\(space)|\(uuid)"
        flushStanding(key)
        guard let layout = spaces[space][uuid]?.withoutPlaceholders() else { return }
        if shaped, layout.windowCount == 1, let id = layout.windows.first, let app = appID(of: id) {
            // The shape you left it at; after Tidy, the default one.
            let shape = layout.singleOwner == id ? LoneShape(scale: layout.singleScale, height: layout.singleHeight)
                : LoneShape(scale: Layout.defaultSingleScale, height: nil)
            Learning.shared.shaped(app, shape: shape, on: Self.displayKey(d))
            return
        }
        var apps: [WindowID: String] = [:]
        for id in layout.windows { apps[id] = appID(of: id) }
        guard let a = Arrangement(layout, apps: apps) else { return }
        standing[key] = (a, Self.displayKey(d), CACurrentMediaTime())
    }

    /// Counts the time an arrangement stood, and stops counting.
    private func flushStanding(_ key: String) {
        guard let s = standing.removeValue(forKey: key) else { return }
        Learning.shared.arranged(s.arrangement, on: s.display, dwell: CACurrentMediaTime() - s.since)
    }

    /// An arrangement that changed by itself (a window closed or opened) stops counting.
    private func checkStanding() {
        for (key, s) in standing {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let space = Int(parts[0]), let layout = spaces[space][parts[1]]?.withoutPlaceholders() else {
                flushStanding(key)
                continue
            }
            var apps: [WindowID: String] = [:]
            for id in layout.windows { apps[id] = appID(of: id) }
            if Arrangement(layout, apps: apps) != s.arrangement { flushStanding(key) }
        }
    }

    /// Once a minute: how long each app's windows spent in each Workspace (while you're at
    /// the Mac: a night away isn't a night in Workspace 2), and every ten minutes, the time
    /// arrangements stood.
    private func learningTick(seconds: Double = 60, testing: Bool = false) {
        guard enabled, Learning.shared.isOn else { return }
        guard !testing else { return countLived(seconds) }
        learningTicks += 1
        if learningTicks % 10 == 0 {
            for (key, s) in standing {
                Learning.shared.arranged(s.arrangement, on: s.display, dwell: CACurrentMediaTime() - s.since)
                standing[key]?.since = CACurrentMediaTime()
            }
        }
        guard Self.secondsSinceInput() < 300 else { return }
        countLived(seconds)
    }

    private func countLived(_ seconds: Double) {
        var lived: [String: [Int: Double]] = [:]
        for (s, layouts) in spaces.enumerated() {
            for layout in layouts.values {
                for id in layout.windows {
                    if let app = windows[id]?.handle.app.bundleID { lived[app, default: [:]][s, default: 0] += seconds }
                }
            }
        }
        Learning.shared.lived(lived.flatMap { app, bySpace in bySpace.map { (app: app, space: $0.key, seconds: $0.value) } })
    }

    /// The window last dragged out of its tile (it glided back), and when.
    private var lastDragOut: (id: CGWindowID, at: CFTimeInterval)?

    /// Set once the windows that were already open at launch are placed, so
    /// only windows opened afterwards count as new.
    private var initialScanDone = false
    /// Tiling has started before in this run of Tessel (so this start is a resume).
    private var startedBefore = false
    /// Windows put back where they were count as time back: true after a launch, not a resume.
    private var countsRestores = false

    private func insert(_ window: ManagedWindow) {
        if returnFromFullScreen(window) { return }
        let saved = savedPlacement.removeValue(forKey: window.id)
        if saved == nil, initialScanDone, takePlaceholder(for: window) { return }
        let display = saved.flatMap { s in activeDisplays.first { $0.uuid == s.display } }
            ?? activeDisplays.first { $0.frame.contains(window.frame.center) }
            ?? activeDisplays.first { $0.isMain }
            ?? activeDisplays.first
        guard let display else { return }
        // A window that just opened: not one back from before a relaunch or a pause, nor one
        // that was around already (floating, minimized, in full screen) and is tiling again.
        let fresh = saved == nil && initialScanDone && window.isNew
        let app = window.handle.app.bundleID
        var space = saved?.space ?? currentSpace
        // Learned: a new window you didn't open from Tessel goes to the Workspace its app lives in.
        var home: Int?
        if fresh, let app {
            home = Learning.shared.home(for: app, requested: isRequested(window), current: currentSpace,
                                        appSpaces: spacesOf(app, excluding: window.id))
            if let home { space = home }
        }
        var layout = spaces[space][display.uuid] ?? Layout()
        // Back from before a relaunch: the same stack and column it had, else a new spot.
        let before = saved.flatMap { s in s.display == display.uuid ? savedLayouts["\(s.space)|\(s.display)"] : nil }
        var usual: (action: AutomaticAction, undo: Automatic.Undo, key: String)?
        if !(before.map { layout.restore(window.id, from: $0) } ?? false) {
            var plain = layout
            let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
            plain.insert(window.id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width))
            // Learned: the spot and share it usually has next to these apps.
            if fresh, let app, let (placed, action, key) = usualPlace(window.id, app: app, in: layout, display: display) {
                layout = placed
                usual = (action, .layout(space: space, display: display.uuid, applied: placed, plain: plain), key)
            } else {
                layout = plain
            }
        }
        spaces[space][display.uuid] = layout
        log.notice("tiling window \(window.id) (\(app ?? "?")) in space \(space + 1)")
        if let usual, home == nil {
            didOnItsOwn(usual.action, undo: usual.undo, key: usual.key, from: currentSpace, on: display)
            standing["\(space)|\(display.uuid)"] = nil // it starts standing once you leave it be
            DispatchQueue.main.async { [weak self] in self?.noteArranged(space: space, display: display.uuid, byYou: false) }
        }
        if let home, let app {
            placedInHome(window, app: app, home: home, display: display) // counted as sent, in Learning
        } else if usual != nil {
            TimeBackLedger.shared.count(.arranged)
        } else if fresh {
            TimeBackLedger.shared.count(.tiled)
        } else if saved != nil, countsRestores {
            TimeBackLedger.shared.count(.restored) // back in its Workspace and spot after Tessel started again
        }
    }

    /// Where each window in full screen was tiled: its Workspace, display, the layout
    /// then, and whether it was in Focus.
    private var fullScreenSpots: [CGWindowID: (space: Int, display: String, layout: Layout, focus: Bool)] = [:]

    /// Puts a window that left full screen back where it was, in Focus again if it
    /// was. One that left from another Workspace than the one in view joins this one.
    private func returnFromFullScreen(_ window: ManagedWindow) -> Bool {
        guard let spot = fullScreenSpots.removeValue(forKey: window.id), spot.space == currentSpace,
              let display = activeDisplays.first(where: { $0.uuid == spot.display }) else { return false }
        var layout = spaces[spot.space][spot.display] ?? Layout()
        if !layout.restore(window.id, from: spot.layout) {
            layout.insert(window.id, near: layout.windows.last, maxColumns: Layout.maxColumns(forWidth: display.visible.width))
        }
        if spot.focus, layout.windowCount > 1 {
            layout.spotlight = window.id
            Snapshotter.capture(layout.shelved) { [weak self] images in
                for (wid, image) in images { self?.shelf.setSnapshot(image, for: wid) }
            }
        }
        spaces[spot.space][spot.display] = layout
        log.notice("window \(window.id) back from full screen in space \(spot.space + 1)")
        return true
    }

    /// When a window still around first went missing from its app's list.
    private var unlistedSince: [CGWindowID: CFTimeInterval] = [:]
    /// When a tiled window first went out of view without closing.
    private var offScreenSince: [CGWindowID: CFTimeInterval] = [:]

    /// - appQuit: it closed because its app quit, which says nothing about the window.
    private func forget(_ id: CGWindowID, appQuit: Bool = false) {
        if let w = windows[id] {
            Learning.shared.closed(id, lifetime: CACurrentMediaTime() - w.seenAt, counts: w.openedWhileRunning && !appQuit)
        }
        requested.remove(id)
        announced.remove(id)
        placedForYou[id] = nil
        fullScreenSpots[id] = nil
        unlistedSince[id] = nil
        offScreenSince[id] = nil
        removeFromLayouts(id)
        if let w = windows.removeValue(forKey: id) {
            w.handle.app.windowIDs.removeValue(forKey: w.handle.element)
        }
        if focusedID == id { focusedID = nil }
        adopted.remove(id)
        offDisplay.remove(id)
        centeredDialogs.remove(id)
        dialogsAwaitingScreen.remove(id)
        settlingUntil[id] = nil
        lastReassert[id] = nil
        pendingReassert.removeValue(forKey: id)?.cancel()
        droppedAt[id] = nil
    }

    private func removeFromLayouts(_ id: CGWindowID) {
        guard let (space, uuid) = place(of: id), var layout = spaces[space][uuid] else { return }
        layout.remove(id)
        spaces[space][uuid] = layout.isEmpty ? nil : layout
    }

    private func place(of id: CGWindowID) -> (space: Int, display: String)? {
        for (s, layouts) in spaces.enumerated() {
            for (uuid, layout) in layouts where layout.contains(id) { return (s, uuid) }
        }
        return nil
    }

    // MARK: Notifications

    func received(_ notification: String, element: AXUIElement, app: AppHandle) {
        guard enabled, apps[app.pid] === app else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            scheduleScan(app, after: [0.03, 0.3])
        case kAXUIElementDestroyedNotification:
            if let id = app.windowIDs[element] {
                quietFocus()
                let wasFocused = focusedID == id
                let frame = windows[id].flatMap { $0.hidden ? nil : ($0.target ?? $0.frame) }
                // A dialog or other floating window hands focus back to the tile used before
                // it, not to whichever tile is nearest the middle of the screen.
                let before = place(of: id) == nil ? lastFocused[currentSpace] : nil
                forget(id)
                relayout(animated: true)
                persist()
                // macOS would hand focus to another window of the same app, which may be
                // parked in another space. Keep focus where the user was looking instead.
                if wasFocused, let frame {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                        self?.focusNearest(to: frame, excluding: id, preferring: before)
                    }
                }
            } else {
                scheduleScan(app)
            }
        case kAXFocusedWindowChangedNotification:
            app.queue.async { [weak self] in
                let id = element.windowID
                DispatchQueue.main.async {
                    if let id { self?.focusChanged(to: id, app: app) } else { self?.checkForGhosts() }
                }
            }
        case kAXWindowMiniaturizedNotification:
            // Same as closing: keep focus near where the user was looking.
            if let id = app.windowIDs[element], id == focusedID, let w = windows[id], !w.hidden {
                let frame = w.target ?? w.frame
                let before = place(of: id) == nil ? lastFocused[currentSpace] : nil
                quietFocus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.focusNearest(to: frame, excluding: id, preferring: before)
                }
            }
            scheduleScan(app)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = app.windowIDs[element] { windowChangedOnItsOwn(id) }
        default:
            scheduleScan(app)
        }
    }

    /// Where and when the last click happened, to tell a Dock click from ⌘-Tab.
    private var lastClick: (at: CFTimeInterval, point: CGPoint)?
    /// An app just activated from the Dock: its window comes to this space.
    /// Summon opened something in this app: its window joins the Workspace being viewed.
    private var summonActivation: (pid: pid_t, until: CFTimeInterval)?
    /// A click on this app's Dock icon brought it forward: go to its window, wherever it is.
    private var dockClick: (pid: pid_t, until: CFTimeInterval)?
    /// When the Dock's menu for an icon was opened (right-click, ⌃-click).
    private var dockMenuOpenedAt: CFTimeInterval?
    /// The app brought forward from the Dock's menu, and the windows it had then.
    private var dockMenuActivation: (pid: pid_t, existing: Set<CGWindowID>, until: CFTimeInterval)?
    /// A window to go to shortly, unless the app opens a new window here first.
    private var followLater: CGWindowID?

    /// Whether a click was on the Dock (wherever it sits, shown or auto-hidden).
    private func isDockClick(_ point: CGPoint) -> Bool {
        let side = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        guard let d = displays.first(where: { $0.frame.contains(point) }) else { return false }
        let reach: CGFloat = 110
        switch side {
        case "left": return point.x < d.frame.minX + reach
        case "right": return point.x > d.frame.maxX - reach
        default: return point.y > d.frame.maxY - reach
        }
    }

    /// Something Tessel opened (from Summon) is on its way: when its app comes
    /// forward, its window joins the Workspace being viewed.
    private var expectedArrival: (bundleID: String, until: CFTimeInterval)?

    /// Call before Summon opens something: leaves Focus here and makes the app
    /// that will show it bring its window to this Workspace instead of taking
    /// you to wherever that window was.
    func prepareForOpening(with bundleID: String?) {
        exitSpotlight()
        guard let bundleID else { return }
        expectedArrival = (bundleID, CACurrentMediaTime() + 6)
        let existing = Set(windows.values.filter { $0.handle.app.bundleID == bundleID }.map(\.id))
        summonedArrival = (bundleID, existing, CACurrentMediaTime() + 6)
    }

    /// The next new window from an app Summon just opened something in.
    private var summonedArrival: (bundleID: String, existing: Set<CGWindowID>, until: CFTimeInterval)?
    /// Windows tiled because they answered a Summon open, though their app doesn't call them standard.
    private var adopted: Set<CGWindowID> = []
    /// Windows something moved onto a display Tessel doesn't manage (Use All Displays
    /// off): agents test there, on a display Tyler can't see. Left alone while there.
    private var offDisplay: Set<CGWindowID> = []
    /// Apps an agent is testing on the spoof display: Tessel doesn't tile their windows
    /// at all, so opening one never shuffles Tyler's layout. Set with leave-app:<bundle id>.
    private var leftAloneApps: Set<String> = []

    func setLeftAlone(_ bundleID: String, _ leave: Bool) {
        guard !bundleID.isEmpty else { return }
        log.notice("\(leave ? "leaving" : "tiling", privacy: .public) \(bundleID, privacy: .public)")
        if leave {
            leftAloneApps.insert(bundleID)
            scanAll()
            return
        }
        // Windows it still has on the unmanaged display stay there, not on Tyler's screen.
        // Tessel never tracked where they went, so ask where they are now.
        let mine = windows.values.filter { $0.handle.app.bundleID == bundleID }
        guard let app = mine.first?.handle.app else {
            leftAloneApps.remove(bundleID)
            return
        }
        let elements = mine.map { ($0.id, $0.handle.element) }
        app.queue.async {
            let frames = elements.compactMap { id, element in element.frame.map { (id, $0) } }
            DispatchQueue.main.async {
                for (id, frame) in frames where self.isOnUnmanagedDisplay(frame) { self.offDisplay.insert(id) }
                self.leftAloneApps.remove(bundleID)
                self.scheduleScan(app)
            }
        }
    }

    private func isOnUnmanagedDisplay(_ frame: CGRect) -> Bool {
        guard !useAllDisplays else { return false }
        let center = frame.center
        return displays.contains { !$0.isMain && $0.frame.contains(center) }
    }

    /// Stops tiling a window something moved onto an unmanaged display, and closes its gap.
    private func leaveAlone(_ id: CGWindowID) {
        guard let w = windows[id], place(of: id) != nil else { return }
        offDisplay.insert(id)
        removeFromLayouts(id)
        w.target = nil
        relayout(animated: true)
        persist()
        log.notice("window \(id) moved to an unmanaged display; leaving it there")
    }

    private func appActivated(_ running: NSRunningApplication) {
        guard let app = apps[running.processIdentifier] else { return }
        let now = CACurrentMediaTime()
        if let opened = dockMenuOpenedAt {
            // The next app to come forward after the Dock's menu opened came from that menu.
            dockMenuOpenedAt = nil
            if now - opened < 20 {
                dockMenuActivation = (app.pid, Set(windows.values.filter { $0.pid == app.pid }.map(\.id)), now + 1.5)
            }
        } else if let click = lastClick, now - click.at < 1.2, isDockClick(click.point) {
            dockClick = (app.pid, now + 1.5)
        }
        if let arrival = expectedArrival, arrival.bundleID == running.bundleIdentifier, now < arrival.until {
            expectedArrival = nil
            summonActivation = (app.pid, now + 2)
        }
        app.queue.async { [weak self] in
            let id = app.element.element(kAXFocusedWindowAttribute)?.windowID
            DispatchQueue.main.async { if let id { self?.focusChanged(to: id, app: app) } }
        }
    }

    /// Some apps keep a closed window around instead of destroying it (Chess
    /// does), so it never says it's gone and would hold its tile forever. Any
    /// tiled window here that's no longer on screen gets its app asked again,
    /// which drops it.
    private func checkForGhosts() {
        guard enabled else { return }
        let onScreen = onScreenWindowIDs()
        let now = CACurrentMediaTime()
        var stale: [pid_t: AppHandle] = [:]
        var shown: Set<Int>?
        for id in visibleFrames().keys where !onScreen.contains(id) {
            guard let w = windows[id], !w.hidden, now > settlingUntil[id] ?? 0 else { continue }
            if shown == nil { shown = shownSpaces() }
            if let shown, isOutOfView(id, shown: shown) { continue }
            stale[w.pid] = w.handle.app
        }
        for app in stale.values { scheduleScan(app) }
        reparkStrays()
    }

    /// macOS 27 now and then pulls a parked window back into view, sometimes in front
    /// of the tiles (AeroSpace users see it too). A parked window shows a sliver in the
    /// corner at most; one showing more than that goes back.
    private func reparkStrays() {
        let parked = windows.values.filter { $0.hidden }
        guard !parked.isEmpty else { return }
        let bounds = onScreenWindowBounds()
        let spot = Display.hidingSpot(in: displays)
        let now = CACurrentMediaTime()
        for w in parked {
            guard now > settlingUntil[w.id] ?? 0, let frame = bounds[w.id] else { continue }
            let showing = displays.contains { d in
                let part = d.frame.intersection(frame)
                return !part.isNull && part.width > 40 && part.height > 40
            }
            guard showing else { continue }
            log.notice("window \(w.id) came back into view while parked; parking it again")
            settlingUntil[w.id] = now + 0.6
            let element = w.handle.element
            w.handle.app.queue.async { element.setPosition(spot) }
        }
    }

    private func refreshFocus() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        appActivated(front)
    }

    private func focusChanged(to id: CGWindowID, app: AppHandle) {
        guard enabled else { return }
        checkForGhosts()
        guard let (space, _) = place(of: id) else {
            // A dialog or other floating window: remember the tile it took focus from (which
            // may have been tiled only after it got focus), so focus goes back there after.
            if let tile = focusedID, place(of: tile)?.space == currentSpace { lastFocused[currentSpace] = tile }
            focusedID = id
            if windows[id] == nil { scheduleScan(app) }
            return
        }
        let now = CACurrentMediaTime()
        if space != currentSpace {
            let summoned = summonActivation.map { $0.pid == app.pid && now < $0.until } ?? false
            let menu = dockMenuActivation.flatMap { $0.pid == app.pid && now < $0.until ? $0 : nil }
            let clicked = dockClick.map { $0.pid == app.pid && now < $0.until } ?? false
            if summoned { summonActivation = nil }
            if menu != nil { dockMenuActivation = nil }
            if clicked { dockClick = nil }
            switch ForeignFocus.decide(summoned: summoned, fromDockMenu: menu != nil, fromDockClick: clicked,
                                       windowHere: clicked ? windowHere(ofApp: app.pid) : nil,
                                       settling: now <= quietFocusUntil,
                                       placedForYou: (placedForYou[id] ?? 0) > now) {
            case .bringHere:
                bringToCurrentSpace(id)
            case .waitForNewWindow:
                let existing = menu?.existing ?? []
                followLater = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.followLater == id else { return }
                    self.followLater = nil
                    let opened = self.windows.values.contains { $0.pid == app.pid && !existing.contains($0.id) }
                    guard !opened, let (space, _) = self.place(of: id), space != self.currentSpace else { return }
                    self.go(to: id, in: space)
                }
            case .focusHere(let here):
                activate(here)
                showRing(on: here)
            case .goThere:
                go(to: id, in: space)
            case .stay:
                // Right after we switch spaces or a window closes, macOS often hands focus
                // to some other window of the app, which may be parked in another space.
                // That isn't a request to go there; only a later ⌘-Tab or click is.
                reclaimFocus()
            }
            return
        }
        followLater = nil // a window here got focus, like the Dock menu's New Window
        focusedID = id
        lastFocused[space] = id
        endSpotlight(unlessShowing: id)
    }

    /// Switches to the Workspace a window is in and focuses it there.
    private func go(to id: CGWindowID, in space: Int) {
        focusedID = id
        lastFocused[space] = id
        switchSpace(to: space, focusing: id)
    }

    /// One of the app's windows in the Workspace being viewed: the one used last, else any.
    private func windowHere(ofApp pid: pid_t) -> CGWindowID? {
        let mine = visibleFrames().keys.filter { windows[$0]?.pid == pid }
        return [lastFocused[currentSpace], focusedID].compactMap { $0 }.first(where: mine.contains) ?? mine.first
    }

    /// Moves a window from another space into the one being viewed, next to
    /// the focused window, and focuses it.
    private func bringToCurrentSpace(_ id: CGWindowID) {
        guard let (space, _) = place(of: id), space != currentSpace, windows[id] != nil else { return }
        let point = lastClick?.point ?? .zero
        guard let display = activeDisplays.first(where: { $0.frame.contains(point) })
            ?? activeDisplays.first(where: \.isMain) ?? activeDisplays.first else { return }
        removeFromLayouts(id)
        var layout = spaces[currentSpace][display.uuid] ?? Layout()
        let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
        layout.insert(id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width))
        spaces[currentSpace][display.uuid] = layout
        quietFocus()
        relayout(animated: true)
        persist()
        activate(id)
        showRing(on: id)
        log.notice("brought window \(id) to space \(self.currentSpace + 1) from the Dock")
    }

    /// Focus changes before this time don't switch spaces.
    private var quietFocusUntil: CFTimeInterval = 0

    private func quietFocus(for seconds: CFTimeInterval = 0.6) {
        quietFocusUntil = max(quietFocusUntil, CACurrentMediaTime() + seconds)
    }

    /// macOS just handed focus to a window parked in another space. Take it back
    /// to the window Tessel had focused here, so typing can't land out of sight.
    private func reclaimFocus() {
        let visible = visibleFrames()
        if let id = focusedID, visible[id] != nil {
            activate(id)
        } else if let display = activeDisplays.first(where: { spaces[currentSpace][$0.uuid] != nil }) ?? activeDisplays.first {
            focusNearest(to: display.visible)
        }
    }

    private var centeredDialogs: Set<CGWindowID> = []

    private var dialogsAwaitingScreen: Set<CGWindowID> = []

    private func center(_ info: WindowInfo, app: AppHandle) {
        center(info.element, frame: info.frame, app: app)
    }

    private func center(_ element: AXUIElement, frame: CGRect, app: AppHandle) {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = displays.first(where: { $0.frame.contains(middle) }) ?? displays.first(where: \.isMain) else { return }
        let origin = Dialogs.centeredOrigin(for: frame.size, in: display.visible)
        app.queue.async { element.setPosition(origin) }
    }

    /// A dialog can tell Tessel it exists a moment before the window server shows it,
    /// and nothing more happens after that. Look again until it's up.
    private func centerOnceShown(_ info: WindowInfo, app: AppHandle) {
        guard dialogsAwaitingScreen.insert(info.id).inserted else { return }
        let element = info.element
        for delay in [0.1, 0.25, 0.5, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.windows[info.id] != nil, !self.centeredDialogs.contains(info.id),
                      isDialogShowing(info.id, pid: app.pid, frame: info.frame) else { return }
                self.centeredDialogs.insert(info.id)
                self.dialogsAwaitingScreen.remove(info.id)
                app.queue.async {
                    guard let frame = element.frame else { return }
                    DispatchQueue.main.async { self.center(element, frame: frame, app: app) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in self?.dialogsAwaitingScreen.remove(info.id) }
    }

    /// Some apps reposition a window they just opened, after Tessel has placed it
    /// (Little Arc animates itself to the middle of the screen). Look again once
    /// it has settled and put it back in its tile.
    private func confirmPlacement(of id: CGWindowID, after delays: [Double] = [0.8, 1.6]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let w = self.windows[id], !w.hidden, w.target != nil else { return }
                let element = w.handle.element
                w.handle.app.queue.async {
                    let actual = element.frame
                    DispatchQueue.main.async {
                        guard let actual, let w = self.windows[id], let target = w.target, !w.hidden,
                              !self.draggedByUser.contains(id), NSEvent.pressedMouseButtons & 1 == 0,
                              !actual.isClose(to: target, tolerance: 2) else { return }
                        // Placed, then moved to the display agents test on: leave it there.
                        if self.isOnUnmanagedDisplay(actual), !self.isOnUnmanagedDisplay(target) { self.leaveAlone(id); return }
                        w.frame = actual
                        w.target = nil
                        self.relayout(animated: true)
                    }
                }
            }
        }
    }

    /// A tiled window moved or resized without us asking.
    private func windowChangedOnItsOwn(_ id: CGWindowID) {
        if fullScreenSpots[id] != nil, let w = windows[id] {
            scheduleScan(w.handle.app, after: [0.15, 0.7])
            return
        }
        if offDisplay.contains(id), let w = windows[id] {
            let element = w.handle.element
            w.handle.app.queue.async {
                let actual = element.frame
                DispatchQueue.main.async {
                    guard let actual, !self.isOnUnmanagedDisplay(actual), let w = self.windows[id] else { return }
                    self.offDisplay.remove(id)
                    w.frame = actual
                    self.scheduleScan(w.handle.app)
                }
            }
            return
        }
        let now = CACurrentMediaTime()
        // Moves just after a drop count even while Tessel's own glide back settles: the check
        // below waits for the window to hold still and acts only on a real difference.
        let justDropped = now - (droppedAt[id] ?? 0) < 1.5
        guard now > settlingUntil[id] ?? 0 || justDropped, let w = windows[id], !w.hidden, w.target != nil else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            draggedByUser.insert(id)
            return
        }
        // The app moved itself (some do when opening), or macOS did: Window › Fill and the
        // other window tiling commands (macOS 15 and later) animate for about half a second,
        // and a move back mid-way is lost under the rest of it. So wait until the window
        // holds still, then put it back, but never wrestle with an app that insists: once
        // every two seconds at most.
        pendingReassert[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReassert[id] = nil
            let now = CACurrentMediaTime()
            guard now - (self.lastReassert[id] ?? 0) > 2, let w = self.windows[id], !w.hidden else { return }
            self.lastReassert[id] = now
            let element = w.handle.element
            w.handle.app.queue.async {
                let actual = element.frame
                let fullScreen = element.isFullScreen
                DispatchQueue.main.async {
                    if fullScreen, let w = self.windows[id] { self.scheduleScan(w.handle.app); return }
                    // Late notifications from our own moves land here too; only act on a real difference.
                    guard let actual, let w = self.windows[id], let target = w.target, !w.hidden,
                          !actual.isClose(to: target, tolerance: 2) else { return }
                    if self.isOnUnmanagedDisplay(actual) { self.leaveAlone(id); return }
                    w.frame = actual
                    w.target = nil
                    self.relayout(animated: true)
                }
            }
        }
        pendingReassert[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func mouseUp() {
        // A click may have been a window's close button.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkForGhosts() }
        let down = mouseDown
        mouseDown = nil
        let dragged = draggedByUser
        draggedByUser.removeAll()
        let up = NSScreen.topLeftPoint(fromCocoa: NSEvent.mouseLocation)
        // A plain click on a Dock icon (not a drag, a long press for its menu, or ⌘/⌥-click).
        if enabled, let down, let click = lastClick, hypot(up.x - down.x, up.y - down.y) < 6,
           CACurrentMediaTime() - click.at < 0.6, NSEvent.modifierFlags.isDisjoint(with: [.command, .option, .control]),
           isDockClick(up) {
            dockClicked(at: up, since: click.at)
        }
        guard enabled, let down, !dragged.isEmpty else { return }
        for id in dragged {
            guard let w = windows[id], let target = w.target, target.insetBy(dx: -12, dy: -12).contains(down) else { continue }
            droppedAt[id] = CACurrentMediaTime()
            let element = w.handle.element
            w.handle.app.queue.async { [weak self] in
                let frame = element.frame
                DispatchQueue.main.async { self?.userDropped(id, frame: frame, at: up) }
            }
        }
    }

    /// The user dragged a tiled window. A resize becomes the new proportions;
    /// a drop onto another window swaps the two; a drop on another display
    /// moves the window there. Anything else glides back into its slot.
    private func userDropped(_ id: CGWindowID, frame: CGRect?, at point: CGPoint) {
        guard let frame, let w = windows[id], let target = w.target, let (space, uuid) = place(of: id) else { return }
        w.frame = frame
        // A centered window (alone, or in spotlight) keeps whatever shape the user
        // drags it to and glides back to the middle; a plain drag just re-centers it.
        if let layout = spaces[space][uuid], layout.windowCount == 1 || layout.spotlight == id {
            if abs(frame.width - target.width) > 4 || abs(frame.height - target.height) > 4,
               let d = displays.first(where: { $0.uuid == uuid }) {
                spaces[space][uuid]?.adopt(id, size: frame.size, in: d.visible, gap: Self.gap)
            }
            w.target = nil
            relayout(animated: true)
            persist()
            noteArranged(space: space, display: uuid, shaped: true)
            return
        }
        if abs(frame.width - target.width) > 4 || abs(frame.height - target.height) > 4 {
            if let d = displays.first(where: { $0.uuid == uuid }), var layout = spaces[space][uuid] {
                layout.adopt(id, size: frame.size, in: d.visible, gap: Self.gap)
                spaces[space][uuid] = layout
            }
        } else if !frame.isClose(to: target, tolerance: 4) {
            let visible = visibleFrames()
            if let other = visible.first(where: { $0.key != id && $0.value.contains(point) })?.key {
                swapWindows(id, other)
            } else if let d = activeDisplays.first(where: { $0.frame.contains(point) }), d.uuid != uuid {
                removeFromLayouts(id)
                var layout = spaces[currentSpace][d.uuid] ?? Layout()
                layout.insert(id, near: layout.windows.last, maxColumns: Layout.maxColumns(forWidth: d.visible.width))
                spaces[currentSpace][d.uuid] = layout
            } else if Learning.shared.isOn {
                // Dragged out of its tile, it glides back. Dragged out again right away,
                // it stays where you put it, floating, and Tessel learns from that.
                let now = CACurrentMediaTime()
                if let last = lastDragOut, last.id == id, now - last.at < 10,
                   Learning.shared.corrected(id, to: .float, by: .dragOut) {
                    lastDragOut = nil
                    log.notice("window \(id) dragged out twice: it floats now")
                    float(w, droppedAt: frame.origin)
                    return
                }
                lastDragOut = (id, now)
            }
        }
        w.target = nil
        relayout(animated: true)
        persist()
        // A resize, a swap or a move to another display: an arrangement you made.
        if let (s, d) = place(of: id) { noteArranged(space: s, display: d) }
        if place(of: id)?.display != uuid { noteArranged(space: space, display: uuid) }
    }

    private func swapWindows(_ a: CGWindowID, _ b: CGWindowID) {
        guard let pa = place(of: a), let pb = place(of: b) else { return }
        if pa == pb {
            spaces[pa.space][pa.display]?.swap(a, b)
        } else {
            spaces[pa.space][pa.display]?.replace(a, with: b)
            spaces[pb.space][pb.display]?.replace(b, with: a)
        }
    }

    /// Displays come and go in bursts (waking, a dock reconnecting, a display blinking off
    /// for a moment): act once things have settled.
    private var pendingDisplayChange: DispatchWorkItem?

    private func displaysMayHaveChanged() {
        pendingDisplayChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.displaysChanged() }
        pendingDisplayChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func displaysChanged() {
        guard enabled else { return }
        displays = Display.current()
        welcomeBackDisplays(counting: true)
        mergeInactiveDisplays()
        relayout(animated: false)
        persist()
    }

    /// Each display's layouts (one per Workspace) from when it went away, so its windows
    /// can go back when it returns.
    private var departed: [String: [Layout?]] = [:]

    /// A display that went away is back: its windows, if still in the same Workspace,
    /// go back to the spots they had on it. `counting`: it really came back (plugged in, or
    /// awake again), rather than Use All Displays being turned on, so it counts as time back.
    private func welcomeBackDisplays(counting: Bool = false) {
        for display in activeDisplays {
            guard let before = departed.removeValue(forKey: display.uuid) else { continue }
            var returned = 0
            for (s, snapshot) in before.enumerated() {
                guard let snapshot, spaces.indices.contains(s) else { continue }
                var layout = spaces[s][display.uuid] ?? Layout()
                for id in snapshot.windows where windows[id] != nil {
                    guard let (space, uuid) = place(of: id), space == s, uuid != display.uuid,
                          var elsewhere = spaces[s][uuid] else { continue }
                    elsewhere.remove(id)
                    spaces[s][uuid] = elsewhere.isEmpty ? nil : elsewhere
                    if !layout.restore(id, from: snapshot) {
                        layout.insert(id, near: layout.windows.last, maxColumns: Layout.maxColumns(forWidth: display.visible.width))
                    }
                    returned += 1
                }
                spaces[s][display.uuid] = layout.isEmpty ? nil : layout
            }
            if counting, returned > 0 {
                TimeBackLedger.shared.count(.restored, times: returned)
                TimeBackLedger.shared.count(.displayReturned)
            }
            log.notice("display \(display.name, privacy: .public) is back; \(returned) windows returned")
        }
    }

    /// Moves windows from displays Tessel doesn't tile on (unplugged, or ignored
    /// because "Use All Displays" is off) onto the main display.
    private func mergeInactiveDisplays() {
        guard let main = displays.first(where: \.isMain) else { return }
        let active = Set(activeDisplays.map(\.uuid))
        for s in spaces.indices {
            for (uuid, layout) in spaces[s] where !active.contains(uuid) {
                // Remember where everything was, for when the display comes back.
                if departed[uuid] == nil { departed[uuid] = Array(repeating: nil, count: spaces.count) }
                departed[uuid]?[s] = layout
                var merged = spaces[s][main.uuid] ?? Layout()
                for id in layout.windows {
                    merged.insert(id, near: merged.windows.last, maxColumns: Layout.maxColumns(forWidth: main.visible.width))
                }
                spaces[s][main.uuid] = merged
                spaces[s][uuid] = nil
            }
        }
    }

    func setUseAllDisplays(_ on: Bool) {
        guard on != useAllDisplays else { return }
        useAllDisplays = on
        if on { offDisplay.removeAll() } // every display is managed now
        UserDefaults.standard.set(on, forKey: "useAllDisplays")
        log.notice("use all displays: \(on)")
        guard enabled else { return }
        if on { welcomeBackDisplays() }
        mergeInactiveDisplays()
        // Pick up windows sitting on a display that just became active (or inactive).
        for w in windows.values where !w.hidden { w.target = nil }
        scanAll()
        relayout(animated: true)
        persist()
    }

    // MARK: Applying the layout

    private var animationsAllowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Sends every window whose slot changed to its new frame. Windows of other
    /// spaces are parked off screen.
    func relayout(animated: Bool) {
        // Pick up a Dock that was just shown, hidden, or resized: the usable area
        // changes without the set of displays changing.
        let fresh = Display.current()
        if Set(fresh.map(\.uuid)) == Set(displays.map(\.uuid)) { displays = fresh }
        Learning.shared.setScreens(displays.map(\.visible))
        let now = CACurrentMediaTime()
        let spot = Display.hidingSpot(in: displays)
        var moves: [(window: WindowHandle, from: CGRect, to: CGRect, kind: Animator.Kind)] = []
        func park(_ w: ManagedWindow) {
            guard !w.hidden else { return }
            let parked = CGRect(origin: spot, size: (w.target ?? w.frame).size)
            w.target = parked
            w.hidden = true
            settlingUntil[w.id] = now + 0.4
            moves.append((w.handle, parked, parked, .positionOnly))
        }
        for (s, layouts) in spaces.enumerated() {
            for (uuid, layout) in layouts {
                if s == currentSpace, let d = activeDisplays.first(where: { $0.uuid == uuid }) {
                    // Spotlight: the shelved windows wait off screen; the shelf shows cards for them.
                    let shelved = Set(layout.shelved)
                    for (id, frame) in layout.frames(in: d.visible, gap: Self.gap) {
                        if let tile = tile(for: id) {
                            if shelved.contains(id) { tile.conceal() } else { tile.show(at: frame, animated: animated) }
                            continue
                        }
                        guard let w = windows[id] else { continue }
                        if shelved.contains(id) {
                            if !w.hidden, let t = w.target { shelfOrigins[id] = t }
                            park(w)
                            continue
                        }
                        if !w.hidden, let t = w.target, t.isClose(to: frame, tolerance: 0.5) { continue }
                        let from = w.hidden ? frame : (w.target ?? w.frame)
                        let kind: Animator.Kind = animated && animationsAllowed && !w.hidden ? .animate : .snap
                        w.target = frame
                        w.hidden = false
                        settlingUntil[id] = now + Animator.duration + 0.3
                        moves.append((w.handle, from, frame, kind))
                    }
                } else {
                    for id in layout.windows {
                        if let w = windows[id] { park(w) } else { tile(for: id)?.conceal() }
                    }
                }
            }
        }
        animator.run(moves)
        updateShelf()
        if !standing.isEmpty { checkStanding() }
        onChange?()
    }

    /// Where each real window in view sits (placeholders aren't windows: nothing can focus them).
    private func visibleFrames() -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        for d in activeDisplays {
            guard let layout = spaces[currentSpace][d.uuid] else { continue }
            result.merge(layout.frames(in: d.visible, gap: Self.gap)) { a, _ in a }
        }
        return result.filter { !Placeholder.isPlaceholder($0.key) }
    }

    private func persist() {
        // Paused, the layouts are empty: what was saved when tiling stopped stands.
        guard enabled else { return }
        var placement: [String: String] = [:]
        var saved: [String: Layout] = [:]
        for (s, layouts) in spaces.enumerated() {
            for (uuid, waiting) in layouts {
                let layout = waiting.withoutPlaceholders() // they only last while Tessel waits
                guard !layout.isEmpty else { continue }
                for id in layout.windows { placement[String(id)] = "\(s)|\(uuid)" }
                saved["\(s)|\(uuid)"] = layout
            }
        }
        // Keep entries for windows not seen yet this session (e.g. right after a relaunch).
        for (id, p) in savedPlacement where placement[String(id)] == nil { placement[String(id)] = "\(p.space)|\(p.display)" }
        for (key, before) in savedLayouts {
            for id in before.windows where savedPlacement[id] != nil { saved[key, default: Layout()].restore(id, from: before) }
        }
        UserDefaults.standard.set(placement, forKey: "placement")
        if let json = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(String(decoding: json, as: UTF8.self), forKey: "layouts")
        }
        UserDefaults.standard.set(currentSpace, forKey: "currentSpace")
        UserDefaults.standard.set(adopted.filter { windows[$0] != nil || savedPlacement[$0] != nil }.map(Int.init), forKey: "adopted")
    }

    // MARK: Keyboard actions

    func perform(_ action: KeyAction) {
        guard enabled else { return }
        checkForGhosts()
        // Tessel's idea of the focused window can go stale (a click it never heard
        // about, an app that didn't come forward). Acting on the wrong window is what
        // made "down" look like "up", so ask the front app which window really has
        // focus, unless Tessel focused one itself a moment ago and the app may still
        // be catching up.
        let recentlyFocused = CACurrentMediaTime() - lastActivation < 0.35
        if case .switchSpace = action {} else if !recentlyFocused,
           let front = NSWorkspace.shared.frontmostApplication, let app = apps[front.processIdentifier] {
            app.queue.async { [weak self] in
                let id = app.element.element(kAXFocusedWindowAttribute)?.windowID
                DispatchQueue.main.async {
                    guard let self else { return }
                    log.debug("resolve \(front.bundleIdentifier ?? "?", privacy: .public): \(id.map(String.init) ?? "nil", privacy: .public), Tessel had \(self.focusedID.map(String.init) ?? "nil", privacy: .public)")
                    self.focusedID = id
                    self.run(action)
                }
            }
            return
        }
        run(action)
    }

    private func run(_ action: KeyAction) {
        guard enabled else { return }
        let t0 = CACurrentMediaTime()
        switch action {
        case .focus(let direction): if !leaveFocusMode() { focus(direction) }
        case .move(let direction): if !leaveFocusMode() { move(direction) }
        case .grow: resize(by: Self.resizeStep)
        case .shrink: resize(by: -Self.resizeStep)
        case .switchSpace(let i): switchSpace(to: i, focusing: nil)
        case .sendToSpace(let i): send(toSpace: i, follow: true)
        case .close: closeFocused()
        case .hide: send(toSpace: Self.spaceCount - 1, caption: "Hidden in Workspace \(Self.spaceCount)", follow: false)
        case .spotlight: toggleSpotlight()
        case .normalize: normalize()
        case .launcher, .help: break // handled by the app delegate
        }
        let ms = (CACurrentMediaTime() - t0) * 1000
        log.notice("\(String(describing: action), privacy: .public) handled in \(ms, format: .fixed(precision: 2)) ms")
    }

    private func focusedFrame(in visible: [CGWindowID: CGRect]) -> CGRect {
        if let id = focusedID {
            if let frame = visible[id] { return frame }
            if let w = windows[id], !w.hidden { return w.frame }
        }
        let main = displays.first(where: \.isMain)?.visible ?? .zero
        return CGRect(x: main.midX - 1, y: main.midY - 1, width: 2, height: 2)
    }

    private func focus(_ direction: Direction) {
        let visible = visibleFrames()
        let source = focusedFrame(in: visible)
        var candidates = visible
        if let id = focusedID { candidates[id] = nil }
        guard let next = nearest(from: source, direction: direction, in: candidates) else {
            if let id = focusedID, visible[id] != nil { showRing(on: id) }
            return
        }
        activate(next)
        showRing(on: next)
    }

    private func move(_ direction: Direction) {
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace,
              var layout = spaces[space][uuid] else { return }
        let before = layout.columns.map(\.windows)
        switch layout.move(id, direction) {
        case .moved:
            spaces[space][uuid] = layout
        case .edge:
            guard let here = displays.first(where: { $0.uuid == uuid }) else { return }
            var others: [String: CGRect] = [:]
            for d in activeDisplays where d.uuid != uuid { others[d.uuid] = d.frame }
            guard let targetUUID = nearest(from: here.frame, direction: direction, in: others, tolerance: 2),
                  let target = displays.first(where: { $0.uuid == targetUUID }) else {
                showRing(on: id)
                return
            }
            let relativeX = Double(((windows[id]?.target?.midX ?? here.frame.midX) - here.frame.minX) / here.frame.width)
            layout.remove(id)
            spaces[space][uuid] = layout.isEmpty ? nil : layout
            var destination = spaces[space][target.uuid] ?? Layout()
            destination.insert(id, entering: direction, relativeX: relativeX)
            spaces[space][target.uuid] = destination
        case .notFound:
            return
        }
        relayout(animated: true)
        persist()
        if let (s, d) = place(of: id) { noteArranged(space: s, display: d) }
        if uuid != place(of: id)?.display { noteArranged(space: space, display: uuid) }
        let after = place(of: id).flatMap { spaces[$0.space][$0.display]?.columns.map(\.windows) } ?? []
        log.notice("move \(direction.rawValue, privacy: .public): window \(id) (\(self.windows[id]?.handle.app.bundleID ?? "?", privacy: .public)) \(String(describing: before), privacy: .public) -> \(String(describing: after), privacy: .public)")
        showRing(on: id)
    }

    private func resize(by delta: Double) {
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace,
              var layout = spaces[space][uuid] else { return }
        if layout.resize(id, by: delta) {
            spaces[space][uuid] = layout
            relayout(animated: true)
            persist()
            noteArranged(space: space, display: uuid, shaped: true)
        }
        showRing(on: id)
    }

    func switchSpace(to index: Int, focusing preferred: CGWindowID?) {
        guard enabled, (0..<Self.spaceCount).contains(index) else { return }
        // Right after Tessel did something on its own, the key of the Workspace you were in undoes it.
        if preferred == nil, undoAutomatic(pressed: index) { return }
        let display = focusedID.flatMap { id in windows[id].flatMap { w in displays.first { $0.frame.contains((w.target ?? w.frame).center) } } }
        guard index != currentSpace else {
            badge.show(space: index, count: Self.spaceCount, on: display)
            return
        }
        if let id = focusedID, place(of: id)?.space == currentSpace { lastFocused[currentSpace] = id }
        quietFocus()
        currentSpace = index
        relayout(animated: false)
        persist()

        if let preferred {
            _ = preferred // the caller focuses it
        } else if let rightmost = visibleFrames().max(by: { a, b in
            // Right-most window; between two equally far right, the top one.
            (a.value.maxX, -a.value.minY) < (b.value.maxX, -b.value.minY)
        })?.key {
            // Entering a space always lands on its right-most window.
            activate(rightmost)
            showRing(on: rightmost)
        } else {
            // Nothing here yet: hand focus to the desktop so typing can't land in a parked window.
            focusDesktop()
        }
        badge.show(space: index, count: Self.spaceCount, on: display)
    }

    /// Moves the focused window to another space. With `follow`, you go along
    /// and it stays focused; without, focus moves to its nearest neighbor here.
    private func send(toSpace index: Int, caption: String? = nil, follow: Bool) {
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace, index != space,
              (0..<Self.spaceCount).contains(index) else { return }
        let display = displays.first { $0.uuid == uuid }
        let oldFrame = windows[id]?.target
        quietFocus()
        removeFromLayouts(id)
        var destination = spaces[index][uuid] ?? Layout()
        destination.insert(id, near: destination.windows.last, maxColumns: Layout.maxColumns(forWidth: display?.visible.width ?? 1600))
        spaces[index][uuid] = destination
        // You put this app's window in that Workspace (hiding a window is putting it away, not a home).
        if caption == nil, let app = windows[id]?.handle.app.bundleID { Learning.shared.moved(app, to: index) }
        noteArranged(space: space, display: uuid)
        noteArranged(space: index, display: uuid)
        if follow {
            lastFocused[index] = id
            switchSpace(to: index, focusing: id) // shows the space badge
            activate(id)
            showRing(on: id)
            return
        }
        relayout(animated: true)
        persist()

        if let oldFrame { focusNearest(to: oldFrame) } else { focusedID = nil }
        badge.show(space: index, count: Self.spaceCount, caption: caption ?? "Moved to Workspace \(index + 1)", on: display)
    }

    /// Focuses `preferred` if it's visible, else the visible window closest to `frame`, or the
    /// desktop when this space is empty.
    private func focusNearest(to frame: CGRect, excluding excluded: CGWindowID? = nil, preferring preferred: CGWindowID? = nil) {
        var visible = visibleFrames()
        if let excluded { visible[excluded] = nil }
        let nearest = visible.min(by: {
            hypot($0.value.midX - frame.midX, $0.value.midY - frame.midY) < hypot($1.value.midX - frame.midX, $1.value.midY - frame.midY)
        })?.key
        if let next = preferred.flatMap({ visible[$0] == nil ? nil : $0 }) ?? nearest {
            activate(next)
            showRing(on: next)
        } else {
            focusDesktop()
        }
    }

    /// Gives keyboard focus to the desktop (Finder's desktop window), for a
    /// space with no windows, so typing can't land in a window parked elsewhere.
    private func focusDesktop() {
        focusedID = nil
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let pid = finder.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let desktop = list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 0) < 0
        }?[kCGWindowNumber as String] as? CGWindowID
        if let desktop, WindowFocus.focus(pid: pid, windowID: desktop) { return }
        AXUIElementCreateApplication(pid).set(kAXFrontmostAttribute, true)
    }

    /// Presses the focused window's close button, exactly like clicking it, so apps
    /// still ask about unsaved changes. Focus moves on once the window is gone.
    private func closeFocused() {
        // Closing hands focus to another app, which may only have windows in another space.
        quietFocus(for: 1.5)
        let running = NSWorkspace.shared.frontmostApplication
        let front = running.flatMap { apps[$0.processIdentifier] }
        let known = focusedID.flatMap { id in visibleFrames()[id] != nil ? windows[id] : nil }
        log.notice("close: front \(running?.bundleIdentifier ?? "?", privacy: .public) (tracked: \(front != nil)), Tessel focus \(self.focusedID.map(String.init) ?? "nil", privacy: .public)")
        if let front, known?.handle.app !== front {
            // The front app's own key window: a dialog, or a window Tessel doesn't tile.
            front.queue.async {
                if let window = front.element.element(kAXFocusedWindowAttribute) { Self.pressClose(window) }
            }
            scheduleScan(front, after: [0.3, 1.0])
            return
        }
        // The window Tessel has focused here. Also used when the front app isn't one
        // Tessel tiles (a helper that took focus, or Tessel itself).
        guard let known else { return }
        let element = known.handle.element
        known.handle.app.queue.async { Self.pressClose(element) }
        scheduleScan(known.handle.app, after: [0.3, 1.0])
    }

    /// Closes one specific window, whatever has focus. Used by the `close-<id>` script command.
    func close(windowID id: CGWindowID) {
        guard let w = windows[id] else { return }
        let element = w.handle.element
        w.handle.app.queue.async { Self.pressClose(element) }
        scheduleScan(w.handle.app, after: [0.3, 1.0])
    }

    private static func pressClose(_ window: AXUIElement) {
        guard let button = window.element(kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private func activate(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        focusedID = id
        if let space = place(of: id)?.space { lastFocused[space] = id }
        endSpotlight(unlessShowing: id)
        lastActivation = CACurrentMediaTime()
        let element = w.handle.element, app = w.handle.app
        let focused = WindowFocus.focus(pid: app.pid, windowID: id)
        app.queue.async {
            element.raise()
            element.set(kAXMainAttribute, true)
            if !focused { app.element.set(kAXFrontmostAttribute, true) }
        }
    }

    // MARK: Launcher

    /// Windows of an app you can actually get to: tiled in one of the spaces,
    /// minimized (they can be restored), or a normal window floating on screen.
    /// A running app with none of these (in the background, or with windows
    /// only on another macOS desktop) doesn't count as open.
    private func reachableWindows(ofApp pid: pid_t) -> [ManagedWindow] {
        let onScreen = recentOnScreenWindowIDs()
        return windows.values.filter { w in
            guard w.pid == pid else { return false }
            if place(of: w.id) != nil { return true }
            return w.standard && (w.minimized || onScreen.contains(w.id))
                && w.frame.width >= 100 && w.frame.height >= 80
        }
    }

    func hasReachableWindow(ofApp pid: pid_t) -> Bool { !reachableWindows(ofApp: pid).isEmpty }

    private var onScreenCache: (ids: Set<CGWindowID>, at: CFTimeInterval)?

    /// The launcher asks once per app per keystroke; one window-server query a
    /// quarter second is plenty.
    private func recentOnScreenWindowIDs() -> Set<CGWindowID> {
        let now = CACurrentMediaTime()
        if let cache = onScreenCache, now - cache.at < 0.25 { return cache.ids }
        let ids = onScreenWindowIDs()
        onScreenCache = (ids, now)
        return ids
    }

    /// Focuses one of the app's windows in the Workspace being viewed (the focused
    /// one, else the one used last, else the left-most), so a web search can open
    /// as a tab right where you are. Returns false when the app has none here.
    func focusWindowHere(ofApp bundleID: String) -> Bool {
        let visible = visibleFrames()
        let mine = visible.keys.filter { windows[$0]?.handle.app.bundleID == bundleID }
        guard !mine.isEmpty else { return false }
        let pick = [focusedID, lastFocused[currentSpace]].compactMap { $0 }.first(where: mine.contains)
            ?? mine.min { a, b in (visible[a]!.minX, visible[a]!.minY) < (visible[b]!.minX, visible[b]!.minY) }!
        activate(pick)
        showRing(on: pick)
        return true
    }

    /// Focuses the app's most recently used window, switching spaces or
    /// restoring it from the Dock if needed. Returns false when the app has no
    /// window you could get to.
    func goToWindow(ofApp pid: pid_t) -> Bool {
        let mine = reachableWindows(ofApp: pid)
        guard !mine.isEmpty else { return false }
        let recent = ([currentSpace] + (0..<Self.spaceCount).filter { $0 != currentSpace })
            .compactMap { lastFocused[$0] }
            .first { windows[$0]?.pid == pid }
        let choice = recent.flatMap { windows[$0] }
            ?? mine.first { place(of: $0.id)?.space == currentSpace }
            ?? mine.first { place(of: $0.id) != nil }
            ?? mine.first { !$0.minimized }
            ?? mine.first
        guard let w = choice, mine.contains(where: { $0 === w }) else { return false }
        // Only Summon comes here. A jump that took you somewhere counts as time back; one to
        // the window you were already in doesn't.
        let elsewhere = place(of: w.id).map { $0.space != currentSpace } ?? false
        if w.minimized || w.id != focusedID || elsewhere {
            TimeBackLedger.shared.count(.summoned)
        }
        if w.minimized {
            // Restore it; Tessel tiles it again when it comes back.
            let element = w.handle.element
            w.handle.app.queue.async { element.set(kAXMinimizedAttribute, false) }
        }
        if let space = place(of: w.id)?.space, space != currentSpace { switchSpace(to: space, focusing: w.id) }
        activate(w.id)
        showRing(on: w.id)
        return true
    }

    /// Opens a new window of a running app, tiled in the current space and
    /// focused once it appears. Brings the app forward first (many apps ignore
    /// menu commands while in the background), without jumping to a space where
    /// its other windows live; then uses its own File › New Window (or the
    /// like). Reports false when the app has no such command. (No ⌘N fallback:
    /// in Music that's New Playlist, in Notes New Note.)
    func openNewWindow(ofApp pid: pid_t, completion: @escaping (Bool) -> Void) {
        guard let app = apps[pid] else { return completion(false) }
        let mine = windows.values.filter { $0.pid == pid }
        let existing = Set(mine.map(\.id))
        quietFocus()
        lastActivation = CACurrentMediaTime()
        pendingNewWindow = (pid, existing, CACurrentMediaTime() + 4)
        let anchor = mine.first { place(of: $0.id)?.space == currentSpace && !$0.hidden }
            ?? mine.first { !$0.minimized } ?? mine.first
        if !(anchor.map { WindowFocus.focus(pid: pid, windowID: $0.id) } ?? false) {
            app.element.set(kAXFrontmostAttribute, true)
        }
        app.queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            let opened = Self.newWindowMenuItem(in: app.element)
                .map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
            DispatchQueue.main.async {
                if !opened { self?.pendingNewWindow = nil }
                completion(opened)
            }
        }
    }

    /// Whether each app (by bundle ID) has a real New Window command.
    private(set) var newWindowSupport: [String: Bool] = [:]

    /// Whether an app can open a new window: true/false when known, nil while
    /// Tessel looks at its menus (then `changed` runs once with the answer).
    func supportsNewWindow(pid: pid_t, bundleID: String?, changed: @escaping () -> Void) -> Bool? {
        guard let bundleID else { return false }
        if let known = newWindowSupport[bundleID] { return known }
        guard let app = apps[pid] else { return false }
        app.queue.async { [weak self] in
            let found = Self.newWindowMenuItem(in: app.element) != nil
            DispatchQueue.main.async {
                self?.newWindowSupport[bundleID] = found
                changed()
            }
        }
        return nil
    }

    /// Runs on the app's queue. Looks through the File, Shell and Window menus
    /// for "New Window" (or "New Finder Window", or File › New › Window in
    /// Xcode). Only an item that says "window" counts.
    private static func newWindowMenuItem(in app: AXUIElement) -> AXUIElement? {
        guard let bar = app.element(kAXMenuBarAttribute) else { return nil }
        // Terminal's Shell › New Window is a submenu (one entry per profile): pressing it only
        // opens the submenu. Use the entry ⌘N runs, or else the first one that's enabled.
        func command(in item: AXUIElement) -> AXUIElement {
            guard let sub = item.elements(kAXChildrenAttribute).first else { return item }
            let entries = sub.elements(kAXChildrenAttribute).filter { $0.bool(kAXEnabledAttribute) && !title($0).isEmpty }
            return entries.first { ($0.string(kAXMenuItemCmdCharAttribute) ?? "").uppercased() == "N" } ?? entries.first ?? item
        }
        func title(_ e: AXUIElement) -> String { (e.string(kAXTitleAttribute) ?? "").lowercased() }
        let preferred = ["file", "shell", "window"]
        let menus = bar.elements(kAXChildrenAttribute)
            .filter { preferred.contains(title($0)) }
            .sorted { (preferred.firstIndex(of: title($0)) ?? 9) < (preferred.firstIndex(of: title($1)) ?? 9) }
        for top in menus {
            guard let menu = top.elements(kAXChildrenAttribute).first else { continue }
            for item in menu.elements(kAXChildrenAttribute) where item.bool(kAXEnabledAttribute) {
                let t = title(item)
                if t == "new window" { return command(in: item) }
                if t.hasPrefix("new "), t.hasSuffix(" window"), !t.contains("private"), !t.contains("incognito") { return command(in: item) }
                if t == "new", let sub = item.elements(kAXChildrenAttribute).first,
                   let window = sub.elements(kAXChildrenAttribute).first(where: { title($0) == "window" && $0.bool(kAXEnabledAttribute) }) {
                    return window
                }
            }
        }
        return nil
    }

    // MARK: Placeholders

    /// A window Tessel knows is on its way, and the tile it holds for it.
    private final class Expected {
        let id: CGWindowID
        let bundleID: String
        /// The app's process, once it's running.
        var pid: pid_t?
        /// Windows the app already had: only a new one takes the tile.
        let existing: Set<CGWindowID>
        let started: CFTimeInterval
        var deadline: CFTimeInterval
        let tile: PlaceholderTile
        /// It took the window's usual spot (Learning).
        var usual = false

        init(id: CGWindowID, bundleID: String, pid: pid_t?, existing: Set<CGWindowID>, deadline: CFTimeInterval,
             tile: PlaceholderTile) {
            self.id = id
            self.bundleID = bundleID
            self.pid = pid
            self.existing = existing
            self.started = CACurrentMediaTime()
            self.deadline = deadline
            self.tile = tile
        }

        func matches(_ window: ManagedWindow) -> Bool {
            window.handle.app.bundleID == bundleID && (pid == nil || pid == window.pid) && !existing.contains(window.id)
        }
    }

    /// How long a tile waits for its window...
    static let placeholderWait: CFTimeInterval = 8
    /// ...or, while the app is visibly still starting up (a big app's first launch), up to this long.
    static let placeholderLongestWait: CFTimeInterval = 20
    /// How long it waits once the app showed some other window instead (one that doesn't tile).
    static let placeholderAfterOtherWindow: CFTimeInterval = 1.5

    /// Tiles held for windows on their way, oldest first.
    private var expected: [Expected] = []
    private var placeholderCount = 0
    private var placeholderCheck: DispatchWorkItem?

    private func tile(for id: CGWindowID) -> PlaceholderTile? {
        guard Placeholder.isPlaceholder(id) else { return nil }
        return expected.first { $0.id == id }?.tile
    }

    /// Summon or a Dock click is about to open a window of this app: make room
    /// now, so a slow launch never looks like nothing happened. The windows here
    /// glide aside and a placeholder holds the exact spot and size the window
    /// will get; the app's first new window takes it (`takePlaceholder`). Only
    /// for opens Tessel is sure of, never just any app starting up.
    /// - another: hold one more even if the app already has one waiting (⇧↩ twice).
    /// - since: when the click was, so a window that beat Tessel here counts.
    /// - point: where you are, which picks the display (the mouse, by default).
    func expectWindow(from bundleID: String, another: Bool = false, since: CFTimeInterval? = nil, near point: CGPoint? = nil) {
        guard enabled, initialScanDone, !Self.floatingApps.contains(bundleID), !leftAloneApps.contains(bundleID),
              another || !expected.contains(where: { $0.bundleID == bundleID }) else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
        // A hidden app brings back the windows it has; nothing new is coming.
        guard running?.isHidden != true else { return }
        let mine = windows.values.filter { $0.handle.app.bundleID == bundleID }
        if let since, mine.contains(where: { $0.seenAt >= since }) { return }
        let point = point ?? NSScreen.topLeftPoint(fromCocoa: NSEvent.mouseLocation)
        guard let display = activeDisplays.first(where: { $0.frame.contains(point) })
            ?? activeDisplays.first(where: \.isMain) ?? activeDisplays.first else { return }

        let id = Placeholder.id(placeholderCount)
        placeholderCount += 1
        var layout = spaces[currentSpace][display.uuid] ?? Layout()
        var plain = layout
        let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
        plain.insert(id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width))
        // Learned: the placeholder takes the spot the window usually has next to these apps.
        let usual = usualPlace(id, app: bundleID, in: layout, display: display)
        if let (placed, action, key) = usual {
            layout = placed
            didOnItsOwn(action, undo: .layout(space: currentSpace, display: display.uuid, applied: placed, plain: plain),
                        key: key, from: currentSpace, on: display)
        } else {
            layout = plain
        }
        spaces[currentSpace][display.uuid] = layout

        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        var name = running?.localizedName ?? url.map { FileManager.default.displayName(atPath: $0.path) } ?? ""
        if name.hasSuffix(".app") { name.removeLast(4) }
        let icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        let e = Expected(id: id, bundleID: bundleID, pid: running?.processIdentifier, existing: Set(mine.map(\.id)),
                         deadline: CACurrentMediaTime() + Self.placeholderWait, tile: PlaceholderTile(icon: icon, name: name))
        e.usual = usual != nil
        expected.append(e)
        relayout(animated: true)
        schedulePlaceholderCheck()
        log.notice("holding a tile for \(bundleID, privacy: .public) in space \(self.currentSpace + 1)")
    }

    /// A new window from an app Tessel is holding a tile for takes that tile,
    /// share and all, so it's the only thing that moves. False when no tile is
    /// waiting for it here: one left in another Workspace (you moved on while the
    /// app started) is let go, and the window joins the Workspace in view.
    private func takePlaceholder(for window: ManagedWindow) -> Bool {
        guard let e = expected.first(where: { $0.matches(window) }) else { return false }
        guard let (space, uuid) = place(of: e.id), space == currentSpace,
              spaces[space][uuid]?.fill(e.id, with: window.id) == true else {
            giveUp([e], why: "its window opened in another Workspace")
            return false
        }
        expected.removeAll { $0 === e }
        e.tile.dismiss(animated: animationsAllowed)
        TimeBackLedger.shared.count(e.usual ? .arranged : .tiled)
        let waited = CACurrentMediaTime() - e.started
        log.notice("window \(window.id) (\(e.bundleID, privacy: .public)) took its tile after \(waited, format: .fixed(precision: 2)) s")
        return true
    }

    /// Summon couldn't open the app, or it quit before showing a window.
    func stopExpecting(_ bundleID: String?, pid: pid_t? = nil, why: String) {
        let gone = expected.filter { $0.bundleID == bundleID && (pid == nil || $0.pid == nil || $0.pid == pid) }
        guard !gone.isEmpty else { return }
        giveUp(gone, why: why)
        relayout(animated: true)
    }

    /// Stops holding tiles: each fades away as the windows around it close the
    /// gap (the caller lays out again).
    private func giveUp(_ gone: [Expected], why: String) {
        for e in gone {
            expected.removeAll { $0 === e }
            removeFromLayouts(e.id)
            e.tile.dismiss(animated: animationsAllowed)
            log.notice("let go of the tile for \(e.bundleID, privacy: .public): \(why, privacy: .public)")
        }
    }

    private func schedulePlaceholderCheck() {
        guard placeholderCheck == nil, !expected.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.placeholderCheck = nil
            self?.checkPlaceholders()
        }
        placeholderCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Lets go of tiles whose window didn't come in time.
    private func checkPlaceholders() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        let late = expected.filter { e in
            guard now >= e.deadline else { return false }
            let app = e.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: e.bundleID).first { !$0.isTerminated }
            let starting = app.map { !$0.isFinishedLaunching && !$0.isTerminated } ?? false
            return !starting || now - e.started >= Self.placeholderLongestWait
        }
        if !late.isEmpty {
            giveUp(late, why: "no window came")
            relayout(animated: true)
        }
        schedulePlaceholderCheck()
    }

    /// A plain click on a Dock icon. An app that isn't running, or is running
    /// with no windows, is about to open one: hold its spot. Which icon it was
    /// comes from the Dock itself, asked off the main thread.
    private func dockClicked(at point: CGPoint, since: CFTimeInterval) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let url = Dock.app(at: point) else { return }
            DispatchQueue.main.async {
                guard let self, self.enabled, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }),
                   self.hasReachableWindow(ofApp: running.processIdentifier) {
                    return // the click goes to that window
                }
                log.notice("Dock click on \(bundleID, privacy: .public), which has no windows")
                self.expectWindow(from: bundleID, since: since, near: point)
            }
        }
    }

    // MARK: Spotlight

    /// ⌘⇧F: the focused window alone in the center, the rest of its space
    /// shelved as small windows on the left. Again (or focusing any shelved
    /// window) puts everything back.
    private func toggleSpotlight() {
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace,
              var layout = spaces[space][uuid] else { return }
        guard layout.toggleSpotlight(id) else {
            showRing(on: id) // already alone: nothing to do
            return
        }
        spaces[space][uuid] = layout
        let shelved = layout.shelved
        if !shelved.isEmpty {
            // Grab what the windows look like while they're still on screen.
            Snapshotter.capture(shelved) { [weak self] images in
                for (wid, image) in images { self?.shelf.setSnapshot(image, for: wid) }
            }
        }
        relayout(animated: true)
        if layout.spotlight != nil { activate(id) }
        showRing(on: id)
    }

    /// In Focus, ⌘ or ⇧⌘ with any arrow just ends it, whichever way it points: back to
    /// the tiles, with the keyboard still on the same window.
    private func leaveFocusMode() -> Bool {
        guard activeDisplays.contains(where: { spaces[currentSpace][$0.uuid]?.spotlight != nil }) else { return false }
        exitSpotlight()
        return true
    }

    private func endSpotlight(unlessShowing id: CGWindowID) {
        guard let (space, uuid) = place(of: id), var layout = spaces[space][uuid],
              let spot = layout.spotlight, spot != id else { return }
        layout.spotlight = nil
        spaces[space][uuid] = layout
        relayout(animated: true)
    }

    // MARK: Spotlight shelf

    private let shelf = Shelf()
    /// Where each shelved window was before it went to the shelf.
    private var shelfOrigins: [CGWindowID: CGRect] = [:]

    /// Shows the shelf for the space being viewed when one of its displays has a
    /// spotlight, and hides it otherwise.
    private func updateShelf() {
        for d in activeDisplays {
            guard let layout = spaces[currentSpace][d.uuid], !layout.shelved.isEmpty else { continue }
            let cards = layout.shelved.compactMap { id -> Shelf.Card? in
                guard let w = windows[id] else { return nil }
                let running = NSRunningApplication(processIdentifier: w.pid)
                return Shelf.Card(
                    id: id, name: running?.localizedName ?? "Window",
                    icon: running?.icon ?? NSWorkspace.shared.icon(for: .application),
                    aspect: max(0.4, min(2.5, (shelfOrigins[id] ?? w.frame).width / max(1, (shelfOrigins[id] ?? w.frame).height)))
                )
            }
            shelf.show(cards, on: d)
            return
        }
        shelf.hide(animated: true)
    }

    /// Leaves Focus in the Workspace being viewed, keeping focus where it is.
    func exitSpotlight() {
        var changed = false
        for uuid in spaces[currentSpace].keys where spaces[currentSpace][uuid]?.spotlight != nil {
            spaces[currentSpace][uuid]?.spotlight = nil
            changed = true
        }
        guard changed else { return }
        relayout(animated: true)
        if let id = focusedID { showRing(on: id) }
    }

    // MARK: Focus ring

    /// The window the ring is outlining right now.
    private var ringWindow: CGWindowID?

    /// Outlines a window where it really is: its target while it's still
    /// moving, otherwise its last known frame, double-checked with the app.
    private func showRing(on id: CGWindowID) {
        guard let w = windows[id], !w.hidden else { return }
        let moving = CACurrentMediaTime() < (settlingUntil[id] ?? 0)
        let frame = moving ? (w.target ?? w.frame) : w.frame
        ringWindow = id
        ring.flash(frame, on: displays)
        guard !moving else { return } // the move's own read-back corrects it
        let element = w.handle.element
        w.handle.app.queue.async { [weak self] in
            let actual = element.frame
            DispatchQueue.main.async {
                guard let self, let actual, self.ringWindow == id, self.ring.isShowing,
                      !actual.isClose(to: frame, tolerance: 2) else { return }
                self.windows[id]?.frame = actual
                self.ring.flash(actual, on: self.displays)
            }
        }
    }

    /// A move finished: remember where the window really is, and slide the ring
    /// there if it was outlining a spot the window didn't reach.
    private func settled(_ id: CGWindowID, at actual: CGRect?) {
        guard let w = windows[id] else { return }
        // Couldn't even read the window: it may be gone. Asking its app again settles it.
        guard let actual else { scheduleScan(w.handle.app); return }
        guard !w.hidden else { return }
        w.frame = actual
        if let target = w.target, abs(actual.width - target.width) > 2 || abs(actual.height - target.height) > 2 {
            Learning.shared.sizeLimited(id) // it has a minimum or maximum size
        }
        if ringWindow == id, ring.isShowing, let target = w.target, !actual.isClose(to: target, tolerance: 2) {
            ring.flash(actual, on: displays)
        }
    }

    // MARK: Menu commands

    /// Whether a display in the Workspace being viewed is in Focus.
    var focusModeIsOn: Bool { activeDisplays.contains { spaces[currentSpace][$0.uuid]?.spotlight != nil } }

    /// ⌘⇧0: even out every split in the space being viewed (stacks and columns
    /// back to equal shares, a lone window back to its default size), end
    /// spotlight, and send every window back to its slot, so a window an app
    /// nudged out of place snaps back too.
    func normalize() {
        guard enabled else { return }
        scanAll() // drops any window that's gone without saying so
        for uuid in spaces[currentSpace].keys { spaces[currentSpace][uuid]?.balance() }
        for id in spaces[currentSpace].values.flatMap(\.windows) {
            if let w = windows[id], !w.hidden { w.target = nil }
        }
        relayout(animated: true)
        persist()
        // Even shares (and default sizes) are an arrangement you chose too.
        for uuid in spaces[currentSpace].keys { noteArranged(space: currentSpace, display: uuid, shaped: true) }
        if let id = focusedID { showRing(on: id) }
    }

    func retile() {
        guard enabled else { return }
        for w in windows.values where !w.hidden { w.target = nil }
        displays = Display.current()
        scanAll()
        relayout(animated: true)
    }

    // MARK: Diagnostics

    func stateDescription() -> [String: Any] {
        var spaceList: [[String: Any]] = []
        for (s, layouts) in spaces.enumerated() {
            var entry: [String: Any] = ["space": s + 1]
            for (uuid, layout) in layouts {
                let name = displays.first { $0.uuid == uuid }?.name ?? uuid
                entry[name] = layout.columns.map { $0.windows.map { id in
                    "\(id) \(windows[id]?.handle.app.bundleID ?? "?")"
                } }
            }
            spaceList.append(entry)
        }
        let windowList = windows.values.sorted { $0.id < $1.id }.map { w -> [String: Any] in
            [
                "id": w.id, "app": w.handle.app.bundleID ?? "?", "hidden": w.hidden,
                "target": w.target.map { NSStringFromRect($0) } ?? "none",
                "latencyMs": (w.handle.app.latency * 1000).rounded(),
            ]
        }
        let now = CACurrentMediaTime()
        let placeholders = expected.map { e -> [String: Any] in
            let spot = place(of: e.id)
            let display = spot.flatMap { s in activeDisplays.first { $0.uuid == s.display } }
            let frame = spot.flatMap { s in display.flatMap { spaces[s.space][s.display]?.frames(in: $0.visible, gap: Self.gap)[e.id] } }
            return ["id": e.id, "app": e.bundleID, "pid": e.pid ?? 0, "space": spot.map { $0.space + 1 } ?? 0,
                    "waitingSeconds": (now - e.started).rounded(), "frame": frame.map { NSStringFromRect($0) } ?? "none"]
        }
        return [
            "enabled": enabled, "currentSpace": currentSpace + 1, "focused": focusedID ?? 0, "placeholders": placeholders,
            "useAllDisplays": useAllDisplays, "windowServerFocus": WindowFocus.isAvailable,
            "newWindowSupport": newWindowSupport,
            "displays": displays.map { "\($0.name) \(NSStringFromRect($0.visible))" },
            "spaces": spaceList, "windows": windowList,
        ]
    }
}
