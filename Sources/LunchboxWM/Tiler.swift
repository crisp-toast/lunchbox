import AppKit
import os
import LunchboxCore

/// LunchboxWM's log subsystem: Console and `log stream` filter by it, and Copy Diagnostics reads its errors.
let logSubsystem = "com.sentientdonut.lunchbox"
let log = Logger(subsystem: logSubsystem, category: "tiler")

final class ManagedWindow {
    let handle: WindowHandle
    /// Last frame read from the app.
    var frame: CGRect
    /// Last frame we asked for.
    var target: CGRect?
    /// Parked off screen because it belongs to another space.
    var hidden = false
    var minimized = false
    /// In a Space of its own from the green button.
    var fullScreen = false
    /// When it last came back from the Dock (minimized, or put away with Hide).
    var restoredAt: CFTimeInterval = 0
    /// A normal document window (not a panel, sheet or helper window).
    var standard = false
    /// How many tabs its native tab bar shows (0 without one).
    var tabs = 0
    /// Whether it can be resized at all (a fixed-size window tiles at its own size).
    var resizable = true
    /// The size it had after LunchboxWM last placed it: a different size later means it
    /// resized itself.
    var settledSize: CGSize?
    /// When LunchboxWM first saw it.
    let seenAt = CACurrentMediaTime()
    /// Its size when LunchboxWM first saw it: floated, it goes back to that.
    let openedSize: CGSize
    /// It opened just now.
    var isNew: Bool { CACurrentMediaTime() - seenAt < 10 }
    /// It opened while LunchboxWM was running (not one already open when it started), so how
    /// long it lived means something.
    var openedWhileRunning = false
    /// Its title when Summon last opened, so Summon can find it. Kept in memory only.
    var title: String?

    init(handle: WindowHandle, frame: CGRect) {
        self.handle = handle
        self.frame = frame
        openedSize = frame.size
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
    /// buttons, but not marked standard.
    let windowLike: Bool
    /// Whether it can be resized at all.
    let resizable: Bool
    /// An alert, prompt, or Open or Save panel: it floats, centered, never tiled.
    let dialog: Bool
    /// In a Space of its own from the green button.
    let fullScreen: Bool
    /// How many tabs its native tab bar shows (0 without one). macOS lists only the tab in
    /// front; each tab is a window of its own, and the ones behind aren't on screen.
    let tabs: Int
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
    static let resizeStep = 0.08
    /// Apps whose windows always float: overlays, not windows you work in. (Simulator,
    /// Calculator, System Settings and the like tile, at the size they take.)
    static let floatingApps = WindowBehavior.floatingApps

    private(set) var enabled = false
    private(set) var currentSpace = 0
    /// How many Workspaces there are: three to start, more if you add them (up to nine).
    private(set) var spaceCount = min(Command.maxWorkspaces, max(Command.defaultWorkspaces,
                                                                 UserDefaults.standard.integer(forKey: "workspaceCount")))
    /// The number of Workspaces changed (the shortcuts for the new ones start working).
    var onSpaceCountChange: ((Int) -> Void)?
    private(set) var displays: [Display] = []
    /// Off: LunchboxWM uses only the main display and ignores the others (e.g. a dummy display plug).
    private(set) var useAllDisplays = UserDefaults.standard.object(forKey: "useAllDisplays") as? Bool ?? true
    /// The displays LunchboxWM tiles on.
    private var activeDisplays: [Display] {
        useAllDisplays ? displays : displays.filter(\.isMain)
    }
    /// When LunchboxWM last gave a window focus itself.
    private var lastActivation: CFTimeInterval = 0
    private var apps: [pid_t: AppHandle] = [:]
    private var windows: [CGWindowID: ManagedWindow] = [:]
    /// The layout of each display (by UUID) in each space.
    private var spaces: [[String: Layout]] = []
    private var userFloating = Set<CGWindowID>()
    private(set) var focusedID: CGWindowID? {
        didSet {
            guard let id = focusedID, recentlyFocused.first != id else { return }
            recentlyFocused.removeAll { $0 == id }
            recentlyFocused.insert(id, at: 0)
        }
    }
    /// Windows by when they last had focus, the latest first: the order Summon lists them in.
    private var recentlyFocused: [CGWindowID] = []
    private var lastFocused: [Int: CGWindowID] = [:]
    private var savedPlacement: [CGWindowID: (space: Int, display: String)] = [:]
    /// Each layout as it was when LunchboxWM last ran (or was paused), by "space|display".
    /// A window coming back takes its old spot: same stack, column order and shares.
    private var savedLayouts: [String: Layout] = [:]
    private var settlingUntil: [CGWindowID: CFTimeInterval] = [:]
    private var lastReassert: [CGWindowID: CFTimeInterval] = [:]
    /// Windows that moved on their own, waiting to hold still before they go back.
    private var pendingReassert: [CGWindowID: DispatchWorkItem] = [:]
    /// When the user last let go of a dragged window. Dropped at a screen edge, macOS 15 and
    /// later animates it into a tile of its own right after LunchboxWM sends it back.
    private var droppedAt: [CGWindowID: CFTimeInterval] = [:]
    private var draggedByUser = Set<CGWindowID>()
    private var mouseDown: CGPoint?
    private var notificationTokens: [NSObjectProtocol] = []
    private var launchWatch: NSKeyValueObservation?
    private var mouseMonitors: [Any] = []
    /// A slow safety net for windows that vanish without any event at all.
    private var ghostTimer: Timer?

    private let animator = Animator()
    private let ring = FocusRing()
    private let badge = SpaceBadge()
    /// Mission Control, App Exposé and Show Desktop: windows out of sight keep their tiles.
    private let overview = DockOverview()
    private var cover = CoverWatch()
    /// Where tiled windows that went out of view without closing were, so they come back there.
    private var away = AwayMemory()
    var onChange: (() -> Void)?

    init() {
        Tiler.shared = self
        animator.onSettled = { [weak self] id, actual, _ in self?.settled(id, at: actual) }
        // Back from Mission Control: the windows never left their tiles. Look again anyway, for
        // anything closed or opened meanwhile.
        overview.onEnd = { [weak self] in self?.scanAll(after: [0.05, 0.4, 1.0]) }
        shelf.onPick = { [weak self] id in
            guard let self else { return }
            self.activate(id)
            self.showRing(on: id)
        }
        // Dragging a file onto a card: Focus ends and the windows come back to their tiles,
        // so the drop can land in any of them. Nothing is activated mid-drag.
        shelf.onDragRest = { [weak self] _ in self?.exitSpotlight() }
        let defaults = UserDefaults.standard
        spaces = Array(repeating: [:], count: spaceCount)
        currentSpace = min(spaceCount - 1, max(0, defaults.integer(forKey: "currentSpace")))
        // Window numbers stay the same while a window lives, so this survives a relaunch.
        adopted = Set(((defaults.array(forKey: "adopted") as? [Int]) ?? []).map(CGWindowID.init))
        // Left from when lone windows took their app's own size; they're always 16:10 now.
        defaults.removeObject(forKey: "tileSizes")
        defaults.removeObject(forKey: "appSizes")
    }

    /// Reads where every window was when LunchboxWM last ran or was paused, so the
    /// windows still open go back to the same Workspace, display and spot.
    /// Window numbers stay the same while a window lives, so this survives a relaunch.
    private func loadSaved() {
        let defaults = UserDefaults.standard
        savedPlacement = [:]
        for (key, value) in (defaults.dictionary(forKey: "placement") as? [String: String]) ?? [:] {
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            if let id = CGWindowID(key), parts.count == 2, let space = Int(parts[0]) {
                // A Workspace taken away since: its windows are in the last one now.
                savedPlacement[id] = (min(space, spaceCount - 1), parts[1])
            }
        }
        let json = defaults.string(forKey: "layouts").map { Data($0.utf8) }
        savedLayouts = json.flatMap { try? JSONDecoder().decode([String: Layout].self, from: $0) } ?? [:]
        // Hidden when LunchboxWM stopped without putting them back (a crash): still hidden.
        stashed = Dictionary(((defaults.array(forKey: "hiddenWindows") as? [Int]) ?? []).map { (CGWindowID($0), 0) },
                             uniquingKeysWith: { a, _ in a })
        // What windows still open from before take, so they're fitted from the start. Window numbers
        // start over when the Mac restarts, so after a restart none of it applies; and each entry is
        // only believed for a window of the same app at the same size (`consider`).
        let saved = defaults.string(forKey: "limits").flatMap { try? JSONDecoder().decode(SavedLimits.self, from: Data($0.utf8)) }
        limits = [:]
        savedLimits = saved?.boot == Self.bootTime && saved?.version == SavedLimits.currentVersion ? saved!.windows : [:]
    }

    // MARK: Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        initialScanDone = false
        // Windows put back after LunchboxWM starts again count as time back; after a pause, they
        // only undo the pause.
        countsRestores = !startedBefore
        startedBefore = true
        loadSaved()
        displays = Display.current()
        TimeBackLedger.shared.load()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        func on(_ name: Notification.Name, _ center: NotificationCenter = NSWorkspace.shared.notificationCenter, _ body: @escaping (Notification) -> Void) {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: body))
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.track(app)
            // The Dock restarted: listen to the new one once it's up.
            if app.bundleIdentifier == "com.apple.dock" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if self?.enabled == true { self?.overview.attach() } }
            }
        }
        // An app is listed here as soon as it starts, well before it says it has finished
        // launching (by then its first windows are often up): watch it from the start.
        launchWatch = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let started = change.newValue ?? []
            DispatchQueue.main.async { for app in started { self?.track(app) } }
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
        on(NSWorkspace.didHideApplicationNotification) { [weak self] n in self?.rescan(n, after: [0.03, 0.3]) }
        // An app shown again (its Dock icon, ⌘-Tab, Show All after Hide Others) can take a moment to
        // put its windows back on screen, longer with several apps at once: look until they're up.
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] n in self?.rescan(n, after: [0.03, 0.2, 0.6, 1.5]) }
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

        for app in NSWorkspace.shared.runningApplications { track(app, scan: false) }
        overview.attach()
        mergeInactiveDisplays()
        initialScan()
        log.notice("started with \(self.displays.count) displays, space \(self.currentSpace + 1)")
    }

    /// Stops managing windows and brings every parked window back into view.
    func stop() {
        guard enabled else { return }
        persist() // resuming puts everything back where it is now
        revealHiddenWindows()
        automatic = nil
        placedForYou = [:]
        requested = []
        TimeBackLedger.shared.saveNow()
        enabled = false
        notificationTokens.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        notificationTokens = []
        launchWatch = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        expected.forEach { $0.tile.dismiss(animated: false) }
        expected = []
        placeholderCheck?.cancel()
        placeholderCheck = nil
        ghostTimer?.invalidate()
        ghostTimer = nil
        mouseMonitors = []
        for pid in Array(apps.keys) { detach(apps[pid]!) }
        overview.detach()
        away.forgetAll() // resuming puts windows back from what persist() saved
        cover = CoverWatch()
        apps = [:]
        windows = [:]
        spaces = Array(repeating: [:], count: spaceCount)
        onChange?()
    }

    /// Moves every window parked for another space back onto its display.
    /// Runs synchronously so it finishes before LunchboxWM quits.
    func revealHiddenWindows() {
        shelf.hide(animated: false)
        // Windows put out of sight with Hide come back too, so none is ever lost off screen.
        stashed = [:]
        UserDefaults.standard.removeObject(forKey: "hiddenWindows")
        for s in spaces.indices { for uuid in spaces[s].keys { spaces[s][uuid]?.spotlight = nil } }
        for (_, layouts) in spaces.enumerated() {
            for (uuid, layout) in layouts {
                let display = displays.first { $0.uuid == uuid } ?? displays.first
                guard let d = display else { continue }
                for (id, frame) in layout.frames(in: d.visible, gap: Self.gap, limits: limits) {
                    guard let w = windows[id], w.hidden else { continue }
                    let size = w.target?.size ?? w.frame.size
                    let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
                    w.handle.element.setPosition(CGPoint(x: max(d.visible.minX, origin.x), y: max(d.visible.minY, origin.y)))
                    w.hidden = false
                }
            }
        }
        // Parked, then its app was hidden (so it's in no layout): into the middle of its display,
        // so it isn't stranded in the corner when the app is shown again.
        for w in windows.values where w.hidden {
            guard let d = away[w.id].flatMap({ s in displays.first { $0.uuid == s.display } })
                ?? displays.first(where: \.isMain) ?? displays.first else { continue }
            let size = w.frame.size
            w.handle.element.setPosition(CGPoint(x: max(d.visible.minX, d.visible.midX - size.width / 2),
                                                 y: max(d.visible.minY, d.visible.midY - size.height / 2)))
            w.hidden = false
        }
    }

    // MARK: Apps and windows

    private func track(_ running: NSRunningApplication, scan: Bool = true) {
        let pid = running.processIdentifier
        guard enabled, running.activationPolicy == .regular, pid != getpid(), apps[pid] == nil else { return }
        let app = AppHandle(pid: pid, bundleID: running.bundleIdentifier)
        apps[pid] = app
        // An app LunchboxWM is holding a tile for has started: from now on it's this process.
        for e in expected where e.pid == nil && e.bundleID == running.bundleIdentifier { e.pid = pid }
        // Started right after a key press or click (Spotlight, Finder, a launcher): you opened it.
        if scan, Self.secondsSinceInput() < 1.5 { launchedByYou[pid] = CACurrentMediaTime() }
        attachObserver(app)
        if scan { scheduleScan(app, after: [0.05, 0.15, 0.3, 0.5, 1.0, 1.5]) }
    }

    private func attachObserver(_ app: AppHandle) {
        var observer: AXObserver?
        guard AXObserverCreate(app.pid, axCallback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(app).toOpaque()
        let names = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification]
        let results = names.map { AXObserverAddNotification(observer, app.element, $0 as CFString, refcon) }
        if results.contains(.cannotComplete), app.observerAttempts < 40 {
            // The app is still starting up; try again shortly (often, at first).
            app.observerAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + (app.observerAttempts < 20 ? 0.05 : 0.5)) { [weak self, weak app] in
                guard let self, let app, self.apps[app.pid] === app else { return }
                self.attachObserver(app)
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        app.observer = observer
        // Windows it made while LunchboxWM couldn't listen yet won't be announced.
        if app.observerAttempts > 0 { scheduleScan(app, after: [0]) }
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
        lastCreated[pid] = nil
        burstSince[pid] = nil
        burstPause[pid] = nil
        heldArrivals[pid] = nil
        burstEnd.removeValue(forKey: pid)?.cancel()
        guard let app = apps.removeValue(forKey: pid) else { return }
        detach(app)
        let gone = windows.values.filter { $0.pid == pid }.map(\.id)
        let focusedFrame = focusedID.flatMap { id in gone.contains(id) ? visibleFrames()[id] : nil }
        if !gone.isEmpty { quietFocus(for: 1) }
        gone.forEach { forget($0, appQuit: true) }
        if let bundleID = app.bundleID { quitMemory.quit(bundleID, at: CACurrentMediaTime()) }
        if !gone.isEmpty {
            relayout(animated: true)
            persist()
        }
        // An app that quits with its last window hands focus to whichever app was
        // before it, maybe one parked in another space. Stay where the user was looking.
        if let focusedFrame { focusNearest(to: focusedFrame) }
    }

    private func rescan(_ n: Notification, after delays: [Double]) {
        guard let running = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let app = apps[running.processIdentifier] else { return }
        scheduleScan(app, after: delays)
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
        return all.compactMap { readWindow($0, app: app) }
    }

    /// Runs on the app's queue.
    private static func readWindow(_ element: AXUIElement, app: AppHandle) -> WindowInfo? {
        guard let id = element.windowID, let frame = element.frame else { return nil }
        let role = element.role, subrole = element.subrole
        let resizable = element.isResizable
        func hasWindowButtons() -> Bool {
            element.element(kAXCloseButtonAttribute) != nil && element.element(kAXMinimizeButtonAttribute) != nil
                && element.element(kAXZoomButtonAttribute) != nil
        }
        // Only a window macOS calls a dialog needs a closer look at its title bar.
        let dialogSubrole = subrole.map(Dialogs.subroles.contains) ?? false
        let looksLikeWindow = dialogSubrole && resizable && hasWindowButtons()
        let dialog = Dialogs.isDialog(subrole: subrole, identifier: element.string(kAXIdentifierAttribute),
                                      hasDefaultButton: element.element(kAXDefaultButtonAttribute) != nil,
                                      hasCancelButton: element.element(kAXCancelButtonAttribute) != nil,
                                      modal: element.bool(kAXModalAttribute), looksLikeWindow: looksLikeWindow)
        // A "dialog" that turned out to be a window (Little Arc) tiles like one.
        let windowRole = role == kAXWindowRole && (subrole == kAXStandardWindowSubrole || (dialogSubrole && !dialog))
        // A window that can't be resized still tiles, at its own size, if it can be minimized
        // like any app window (Calculator, a game). One that can do neither is a small panel
        // (an About box, a progress window): it floats, centered, like a dialog.
        let minimizable = resizable || (element.element(kAXMinimizeButtonAttribute).map { $0.bool(kAXEnabledAttribute) } ?? false)
        // A downloaded app's disk image window ("drag the app to Applications"): Finder, titled
        // with the image's name, drawn at the size its maker chose around a fixed picture. It
        // floats at that size, centered, like a dialog.
        let installer = windowRole && app.bundleID == "com.apple.finder"
            && (element.string(kAXTitleAttribute).map(DiskImages.isMounted(named:)) ?? false)
        let panel = windowRole && (!minimizable || installer)
        let standard = windowRole && !panel
        let minimized = element.isMinimized
        let fullScreen = element.isFullScreen
        let usable = !minimized && !fullScreen && !dialog && !panel
        let tileable = standard && usable
        let windowLike = tileable || (usable && resizable && role == kAXWindowRole && hasWindowButtons())
        return WindowInfo(id: id, element: element, frame: frame, tileable: tileable, minimized: minimized,
                          standard: standard, windowLike: windowLike, resizable: resizable,
                          dialog: dialog || panel,
                          fullScreen: fullScreen,
                          tabs: element.elements(kAXChildrenAttribute)
                            .first { $0.role == "AXTabGroup" }.map { $0.elements(kAXTabsAttribute).count } ?? 0)
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
            // Windows closed while LunchboxWM wasn't running don't come back, and their
            // numbers get reused by new windows: forget their spots.
            let alive = allWindowIDs()
            if !alive.isEmpty { self.savedPlacement = self.savedPlacement.filter { alive.contains($0.key) } }
            if !alive.isEmpty { self.stashed = self.stashed.filter { alive.contains($0.key) } }
            self.savedLimits = [:]
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
            if overview.isActive { continue } // under Mission Control: still there
            // Going in or out of full screen, a window isn't on any Space for a moment.
            // A closed window says so and is forgotten right then; a tiled one that only
            // went missing gets a moment to show up again (one away, longer).
            if place(of: w.id) != nil || away[w.id] != nil {
                let since = unlistedSince[w.id] ?? now
                unlistedSince[w.id] = since
                let wait = away[w.id] != nil ? 6.0 : 1.5
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
        if layoutChangedSize { layoutChangedSize = false; changed = true }
        if changed, heldArrivals[app.pid] != nil {
            scheduleBurstEnd(app) // laid out together once the app stops making windows
        } else if changed {
            relayout(animated: true)
            persist()
        }
        if let arrived, place(of: arrived) != nil {
            activate(arrived)
            showRing(on: arrived)
        }
        // A window you were using left without saying so (Chess after ⌘W), or its app was
        // hidden: keep the keyboard on a window you can see. Not one that went full screen
        // (that would take you straight back out of it) or only went out of sight.
        let after = visibleFrames()
        if arrived == nil, let (_, frame) = visibleBefore.first(where: { after[$0.key] == nil && (away[$0.key].map { $0.why == .appHidden } ?? true) }),
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
    /// An app brought forward to open a new window here, and the windows it had: focus landing on
    /// one of those in another Workspace meanwhile is the app coming forward, nothing more.
    private var comingForward: (pid: pid_t, existing: Set<CGWindowID>, until: CFTimeInterval)?

    /// Registers a window and adds it to or removes it from the layout as needed.
    /// Returns true when the layout changed.
    @discardableResult
    private func consider(_ info: WindowInfo, app: AppHandle, onScreen: Set<CGWindowID>, shown: Set<Int>) -> Bool {
        let isNew = windows[info.id] == nil
        let window = windows[info.id] ?? register(info, app: app)
        let spot = place(of: info.id)
        // A dialog floats, centered on the screen it opened on, instead of slicing the
        // tiled windows apart: once, the first time it's on screen (apps often make the
        // window a moment before showing it). Ones open before LunchboxWM started stay put.
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
        // Hidden with Hide before LunchboxWM last stopped without bringing it back: still parked.
        if isNew, stashed[info.id] != nil {
            window.hidden = true
            window.target = CGRect(origin: Display.hidingSpot(in: displays), size: info.frame.size)
        }
        if !window.hidden { window.frame = info.frame }
        if isNew, let saved = savedLimits.removeValue(forKey: String(info.id)), saved.app == app.bundleID,
           abs(saved.width - info.frame.width) <= 2, abs(saved.height - info.frame.height) <= 2 {
            limits[info.id] = saved.limits
        }
        window.minimized = info.minimized
        window.fullScreen = info.fullScreen
        // Gone out of sight a moment ago, and now in full screen: the green button after all.
        if info.fullScreen, away[info.id] != nil { away.wentFullScreen(info.id) }
        window.standard = info.standard
        window.tabs = info.tabs
        window.resizable = info.resizable
        // A window that can't be resized tiles at its own size.
        if !info.resizable, info.tileable, !window.hidden, limits[info.id] != .fixed(info.frame.size) {
            limits[info.id] = .fixed(info.frame.size)
            if place(of: info.id) != nil { layoutChangedSize = true }
        }
        let appHidden = NSRunningApplication(processIdentifier: app.pid)?.isHidden ?? false
        let ruleTiles = (info.tileable || (adopted.contains(info.id) && info.windowLike))
            && !Self.floatingApps.contains(app.bundleID ?? "")
        // Everything but being in view.
        let tiles = ruleTiles
            && !offDisplay.contains(info.id)
            && !leftAloneApps.contains(app.bundleID ?? "")
            && !appHidden
            && !userFloating.contains(info.id)
            && stashed[info.id] == nil
        let wantsTile = tiles
            // While a display shows a full screen app, its desktop's windows are out of
            // sight, not gone: they keep their tiles.
            && (onScreen.contains(info.id) || window.hidden
                || (spot != nil && isOutOfView(info.id, shown: shown)))
        let placed = spot != nil
        // Mission Control, App Exposé or Show Desktop: the window is covered, not gone. It keeps
        // its tile, and the windows around it stay where they are.
        if tiles, !wantsTile, placed, initialScanDone, !window.hidden, screenCovered(onScreen: onScreen, shown: shown) {
            offScreenSince[info.id] = nil
            return false
        }
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
            if initialScanDone {
                // New to LunchboxWM: straight into its tile, not on a glide from wherever its app put it.
                if CACurrentMediaTime() - window.seenAt < 2 { arriving.insert(info.id) }
                if isBursting(app.pid) {
                    heldArrivals[app.pid, default: []].append(info.id)
                } else {
                    confirmPlacement(of: info.id)
                }
            }
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
            // Out of view without closing: the green button (the window leaves for a Space of its
            // own, first vanishing for a moment on the way), its app hidden (windows parked in
            // other Workspaces too), or out of sight with nothing said. Remember exactly where it
            // was, and whether it was in Focus, so it comes back to the same spot.
            let why: AwayMemory.Why? = info.fullScreen ? .fullScreen : appHidden ? .appHidden
                : !onScreen.contains(info.id) && !window.hidden && !info.minimized ? .outOfView : nil
            if let spot, let why, let layout = spaces[spot.space][spot.display] {
                away.left(info.id, space: spot.space, display: spot.display, layout: layout, why: why, at: CACurrentMediaTime())
            }
            removeFromLayouts(info.id)
            window.target = nil
            return true
        }
        if !wantsTile, initialScanDone, onScreen.contains(info.id), !info.minimized {
            // The app LunchboxWM is holding a tile for answered with something that doesn't tile: a
            // welcome window or a template chooser (Xcode, Pages), a dialog, a fixed-size window.
            // Once the app has finished starting up, that's its answer for now, so the gap closes
            // in a moment (a window-like one waits a little longer: its real window may be right
            // behind). A splash while the app is still starting up doesn't count.
            let launched = NSRunningApplication(processIdentifier: app.pid)?.isFinishedLaunching ?? true
            for e in expected where launched && !e.answeredOtherwise && e.matches(window) {
                e.answeredOtherwise = true
                let wait = info.windowLike ? Self.placeholderAfterOtherWindow : Self.placeholderAfterPanel
                e.deadline = min(e.deadline, CACurrentMediaTime() + wait)
                checkPlaceholders(after: wait)
                log.notice("\(e.bundleID, privacy: .public) answered with a window that doesn't tile; letting its tile go")
            }
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

    /// Floats the focused window, or tiles a floating one (the `float` command and menu item).
    func toggleFloating() {
        guard enabled, let id = focusedID else { return }
        toggleFloating(id)
    }

    private func toggleFloating(_ id: CGWindowID) {
        guard let w = windows[id], !w.hidden else { return }
        let tiled = place(of: id) != nil
        if tiled { userFloating.insert(id) } else { userFloating.remove(id) }
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
        guard let id = focusedID, let w = windows[id], !w.hidden, w.standard else { return nil }
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
        let size = w.openedSize
        if size.width >= 100, size.height >= 60,
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

    // MARK: What LunchboxWM does on its own

    /// Says what LunchboxWM did on its own, and which key undoes it.
    private let quietLine = QuietLineView()
    /// Names the undo key for a Workspace, like "Left ⌘ 1" (set by the app, which knows the keys).
    var undoKeyName: ((Int) -> String?)?

    /// What LunchboxWM just did on its own, undoable for a few seconds with ⌘ and the key of the
    /// Workspace you were in (Etiquette). Things done within a second of each other (windows
    /// coming back after a login) share one line and one undo.
    private struct Automatic {
        enum Undo {
            /// It went back to its Workspace: bring it to the one you were in.
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
    /// Windows LunchboxWM opened in their app's Workspace while you stayed here: their app reaching
    /// for focus isn't you asking to go there.
    private var placedForYou: [CGWindowID: CFTimeInterval] = [:]
    /// Windows that answered something you opened from LunchboxWM (Summon): they come to you.
    private var requested = Set<CGWindowID>()
    /// Apps you just launched yourself (Spotlight, Finder, a launcher), and when: when their
    /// window goes to its home, you go with it.
    private var launchedByYou: [pid_t: CFTimeInterval] = [:]

    private func didOnItsOwn(_ action: AutomaticAction, undo: Automatic.Undo, key: String, from: Int, on display: Display?) {
        let now = CACurrentMediaTime()
        // Following you to another Workspace, the undo key also just takes you back: it only
        // brings the window along while the line is up.
        let window: Double
        switch action {
        case .reopened(_, _, true): window = Etiquette.lineSeconds + 1
        default: window = Etiquette.undoSeconds
        }
        if var a = automatic, now - a.at < Etiquette.batchSeconds, a.from == from {
            a.actions.append(action)
            a.undos.append(undo)
            a.keys.append(key)
            a.until = min(a.until, now + window)
            automatic = a
        } else {
            automatic = Automatic(actions: [action], undos: [undo], keys: [key], from: from, at: now, until: now + window,
                                  display: display ?? displays.first(where: \.isMain))
            DispatchQueue.main.asyncAfter(deadline: .now() + Etiquette.undoSeconds + 0.1) { [weak self] in
                guard let self, let a = self.automatic, a.at == now else { return }
                self.automatic = nil
            }
        }
        guard let a = automatic else { return }
        quietLine.show(QuietLine.text(for: a.actions, undoKey: undoKeyName?(a.from)), on: a.display)
        log.notice("on its own: \(String(describing: action), privacy: .public)")
    }

    /// ⌘ and the key of the Workspace you were in, right after LunchboxWM did something on its own:
    /// undo it. False when there's nothing to undo, so the key does what it always does.
    private func undoAutomatic(pressed index: Int) -> Bool {
        guard let a = automatic, a.from == index, CACurrentMediaTime() < a.until else { return false }
        automatic = nil
        var back: [CGWindowID] = []
        for undo in a.undos.reversed() {
            switch undo {
            case .place(let id, let from):
                guard windows[id] != nil, let (space, uuid) = place(of: id), space != from, spaces.indices.contains(from) else { continue }
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

    /// Something you opened from LunchboxWM is on its way to this app: its window comes to you.
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

    /// You opened this window yourself, just now (outside LunchboxWM): you go where it goes.
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


    /// Set once the windows that were already open at launch are placed, so
    /// only windows opened afterwards count as new.
    private var initialScanDone = false
    /// Tiling has started before in this run of LunchboxWM (so this start is a resume).
    private var startedBefore = false
    /// Windows put back where they were count as time back: true after a launch, not a resume.
    private var countsRestores = false

    private func insert(_ window: ManagedWindow) {
        if returnToSpot(window) { return }
        let saved = savedPlacement.removeValue(forKey: window.id)
        // Its app restarted: back to the Workspace and spot it had when the app quit, wherever you are.
        let back = saved == nil && initialScanDone && window.isNew ? restartSpot(for: window, take: true) : nil
        if back != nil, let app = window.handle.app.bundleID {
            // Not the tile Summon or the Dock held for it here: it's going back where it was.
            let held = expected.filter { $0.bundleID == app }
            if !held.isEmpty { giveUp(held, why: "it went back where it was before it quit") }
        }
        if saved == nil, back == nil, initialScanDone, takePlaceholder(for: window) { return }
        // The app brought back a window it already had (a minimized one, say) instead of making a
        // new one: that's the window you were waiting for, so the tile held for it goes.
        if initialScanDone {
            let answered = expected.filter { $0.existing.contains(window.id) && $0.bundleID == window.handle.app.bundleID }
            if !answered.isEmpty { giveUp(answered, why: "it brought back a window it already had") }
        }
        let display = back.flatMap { b in activeDisplays.first { $0.uuid == b.display } }
            ?? saved.flatMap { s in activeDisplays.first { $0.uuid == s.display } } ?? arrivalDisplay(for: window.frame)
        guard let display else { return }
        // A window that just opened: not one back from before a relaunch or a pause, nor one
        // that was around already (floating, minimized, in full screen) and is tiling again.
        let fresh = saved == nil && back == nil && initialScanDone && window.isNew
        let app = window.handle.app.bundleID
        let space = back?.space ?? saved?.space ?? currentSpace
        var layout = spaces[space][display.uuid] ?? Layout()
        // Back from before a relaunch: the same stack and column it had, else a new spot.
        let before = back.map { QuitMemory.layout(of: $0, as: window.id) }
            ?? saved.flatMap { s in s.display == display.uuid ? savedLayouts["\(s.space)|\(s.display)"] : nil }
        if !(before.map { layout.restore(window.id, from: $0) } ?? false) {
            let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
            layout.insert(window.id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width),
                          limits: limits, room: room(on: display))
        }
        spaces[space][display.uuid] = layout
        log.notice("tiling window \(window.id) (\(app ?? "?")) in space \(space + 1)")
        if back != nil, let app {
            reopened(window, app: app, space: space, display: display)
            TimeBackLedger.shared.count(.restored)
        } else if fresh {
            TimeBackLedger.shared.count(.tiled)
        } else if saved != nil, countsRestores {
            TimeBackLedger.shared.count(.restored) // back in its Workspace and spot after LunchboxWM started again
        }
    }

    /// What a layout on this display has to fit windows into, for windows that can't be squeezed.
    private func room(on display: Display) -> (area: CGSize, gap: CGFloat) {
        (CGSize(width: display.visible.width - 2 * Self.gap, height: display.visible.height - 2 * Self.gap), Self.gap)
    }

    /// The display a new window joins: the one it opened on, else the main one.
    private func arrivalDisplay(for frame: CGRect) -> Display? {
        activeDisplays.first { $0.frame.contains(frame.center) } ?? activeDisplays.first { $0.isMain } ?? activeDisplays.first
    }

    /// What each window that can't fill a tile takes (see `SizeLimits`): fixed for one that
    /// can't be resized, learned from how the others answer being asked for a size.
    private var limits: [CGWindowID: SizeLimits] = [:]
    /// Limits saved when LunchboxWM last ran, waiting for their windows to be seen again.
    private var savedLimits: [String: SavedLimits.Entry] = [:]

    private struct SavedLimits: Codable {
        struct Entry: Codable { let app: String; let width: CGFloat; let height: CGFloat; let limits: SizeLimits }
        /// Saves from before version 2 may hold limits learned from windows macOS had held to the
        /// screen (a size-then-move bug, 2026-10-18), so they're dropped.
        static let currentVersion = 2
        var version = currentVersion
        let boot: Double
        let windows: [String: Entry]
    }

    /// When the Mac started up: window numbers are only good until the next restart.
    private static let bootTime: Double = {
        var time = timeval(), size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &time, &size, nil, 0)
        return Double(time.tv_sec)
    }()
    /// A fixed-size window changed size during a scan: lay out again.
    private var layoutChangedSize = false

    /// Windows that just joined a layout for the first time: they snap into their tiles
    /// instead of gliding there from wherever their app opened them.
    private var arriving: Set<CGWindowID> = []

    /// When each app last made a window, since when it's been making them in a burst, and the
    /// longest pause between two of them so far.
    private var lastCreated: [pid_t: CFTimeInterval] = [:]
    private var burstSince: [pid_t: CFTimeInterval] = [:]
    private var burstPause: [pid_t: CFTimeInterval] = [:]
    /// Windows that joined during a burst, waiting for it to end to be laid out together.
    private var heldArrivals: [pid_t: [CGWindowID]] = [:]
    private var burstEnd: [pid_t: DispatchWorkItem] = [:]
    /// Windows made closer together than this are a burst (an app restoring its windows).
    static let burstGap: CFTimeInterval = 0.12
    /// A burst is laid out after this long even if windows keep coming.
    static let burstMax: CFTimeInterval = 0.6

    /// An app making several windows in a row (restoring them at launch, opening a set):
    /// lay them out once when it's done, instead of reflowing everything once per window.
    private func isBursting(_ pid: pid_t) -> Bool {
        guard let since = burstSince[pid], let last = lastCreated[pid] else { return false }
        let now = CACurrentMediaTime()
        return now - last < burstWait(pid) && now - since < Self.burstMax
    }

    /// How long after its last window a burst is over: half again its longest pause so far, so
    /// an app that makes them all at once isn't kept waiting for more.
    private func burstWait(_ pid: pid_t) -> CFTimeInterval {
        min(Self.burstGap, max(0.05, (burstPause[pid] ?? 0) * 1.5))
    }

    private func noteCreated(by pid: pid_t) {
        let now = CACurrentMediaTime()
        if let last = lastCreated[pid], now - last < (burstSince[pid] == nil ? Self.burstGap : burstWait(pid)) {
            if burstSince[pid] == nil { burstSince[pid] = last }
            burstPause[pid] = max(burstPause[pid] ?? 0, now - last)
        } else {
            burstSince[pid] = nil
            burstPause[pid] = nil
        }
        lastCreated[pid] = now
    }

    /// Lays out the windows held during a burst once it's over (or has gone on long enough).
    private func scheduleBurstEnd(_ app: AppHandle) {
        burstEnd[app.pid]?.cancel()
        let work = DispatchWorkItem { [weak self, weak app] in
            guard let self, let app else { return }
            self.burstEnd[app.pid] = nil
            if self.isBursting(app.pid) { self.scheduleBurstEnd(app); return }
            let since = self.burstSince.removeValue(forKey: app.pid) ?? CACurrentMediaTime()
            self.burstPause[app.pid] = nil
            let held = self.heldArrivals.removeValue(forKey: app.pid) ?? []
            guard self.enabled, self.apps[app.pid] === app else { return }
            // The window that started the burst, laid out alone a moment ago, lands with the rest.
            for w in self.windows.values where w.pid == app.pid && w.seenAt >= since && !w.hidden { self.arriving.insert(w.id) }
            self.relayout(animated: true)
            self.persist()
            for id in held where self.windows[id] != nil { self.confirmPlacement(of: id) }
        }
        burstEnd[app.pid] = work
        let now = CACurrentMediaTime()
        let last = lastCreated[app.pid] ?? now, since = burstSince[app.pid] ?? now
        let at = min(last + burstWait(app.pid), since + Self.burstMax)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.005, at - now), execute: work)
    }

    /// A window was just made. Put it where it's going before it shows (`prePlace`), then
    /// lay it out the moment it's on screen instead of on the next routine scan.
    private func windowCreated(_ element: AXUIElement, app: AppHandle) {
        // Opened from the Dock or Summon, a placeholder already holds the window's tile: it goes
        // straight there, ahead of the full look at it below, which waits on its app (busy starting
        // up) and behind any scan of its windows, so the window showed where its app put it for a
        // moment first. Only a standard window that can take the tile's size; anything else (a
        // dialog, a welcome window at its own size) goes the usual way.
        if let held = heldTile(forNewWindowOf: app) {
            Self.arrivalQueue.async {
                guard element.subrole == kAXStandardWindowSubrole as String, element.isResizable,
                      let id = element.windowID else { return }
                WindowHandle.queue(for: id).async { _ = element.place(in: held) }
            }
        }
        app.queue.async { [weak self] in
            let info = Self.readWindow(element, app: app)
            DispatchQueue.main.async {
                guard let self, self.enabled, self.apps[app.pid] === app else { return }
                guard let info else {
                    self.scheduleScan(app, after: [0.03, 0.3])
                    return
                }
                // Only windows that will tile make a burst: the helper windows, pop-ups and
                // tooltips apps make alongside a real window (Claude, Arc) don't hold it back.
                if info.tileable { self.noteCreated(by: app.pid) }
                // In a burst, windows go to their tiles together (a tile planned now would be one of
                // a layout about to change again), and wait out of sight until then rather than
                // where their app put them.
                self.prePlace(info, app: app, park: self.isBursting(app.pid))
                self.scheduleScan(app, after: [0, 0.4])
                // Some apps make their window seconds before they show it, while they start (Claude
                // and other Electron apps): one that will tile is watched for longer, so it still
                // gets its tile when it shows.
                if !isOnScreen(info.id) {
                    let now = CACurrentMediaTime()
                    self.scanWhenOnScreen(info.id, app: app, since: now, until: now + (info.tileable ? 30 : 2))
                }
            }
        }
    }

    /// Where a new window first goes when its tile is already held: its own queue, so it never
    /// waits behind other work for its app.
    private static let arrivalQueue = DispatchQueue(label: "com.sentientdonut.lunchbox.arrival", qos: .userInteractive, attributes: .concurrent)

    /// The tile a placeholder holds in the Workspace you're in for the next window of `app`, if any.
    private func heldTile(forNewWindowOf app: AppHandle) -> CGRect? {
        guard initialScanDone, NSEvent.pressedMouseButtons & 1 == 0,
              // It may be about to become a tab, which would drag its whole tab group along.
              !windows.values.contains(where: { $0.pid == app.pid && $0.tabs >= 2 }),
              let e = expected.first(where: { $0.bundleID == app.bundleID && ($0.pid == nil || $0.pid == app.pid) }),
              let (s, uuid) = place(of: e.id), s == currentSpace,
              let d = activeDisplays.first(where: { $0.uuid == uuid }) else { return nil }
        return spaces[s][uuid]?.frames(in: d.visible, gap: Self.gap, limits: limits)[e.id]
    }

    /// Looks every few milliseconds until a window that was just made is on screen: every 8 ms
    /// for its first 2 s, then every 50 ms until `deadline`.
    private func scanWhenOnScreen(_ id: CGWindowID, app: AppHandle, since start: CFTimeInterval, until deadline: CFTimeInterval) {
        let wait = CACurrentMediaTime() - start < 2 ? 0.008 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak app] in
            guard let self, let app, self.enabled, self.apps[app.pid] === app else { return }
            if isOnScreen(id) { self.scheduleScan(app, after: [0]); return }
            guard CACurrentMediaTime() < deadline else { return }
            self.scanWhenOnScreen(id, app: app, since: start, until: deadline)
        }
    }

    /// Moves a window that was just made straight into the tile it's about to get. Apps often
    /// make a window a moment before showing it, so it shows up where it belongs instead of
    /// where its app put it; the rest of the layout makes room once it's on screen.
    private func prePlace(_ info: WindowInfo, app: AppHandle, park: Bool = false) {
        guard initialScanDone, windows[info.id] == nil, info.tileable, info.tabs < 2,
              savedPlacement[info.id] == nil, away[info.id] == nil,
              !leftAloneApps.contains(app.bundleID ?? ""), !Self.floatingApps.contains(app.bundleID ?? ""),
              NSRunningApplication(processIdentifier: app.pid)?.isHidden != true,
              !isOnUnmanagedDisplay(info.frame),
              // It may be about to become a tab, which would drag its whole tab group along.
              !windows.values.contains(where: { $0.pid == app.pid && $0.tabs >= 2 }),
              // A tab being dragged out into a window of its own follows the mouse.
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        if !info.resizable { limits[info.id] = .fixed(info.frame.size) } // it goes in at its own size
        let planned = park ? CGRect(origin: Display.hidingSpot(in: displays), size: info.frame.size) : plannedFrame(for: info, app: app)
        guard let target = planned else {
            log.notice("window \(info.id) (\(app.bundleID ?? "?", privacy: .public)) arrives where its app put it")
            return
        }
        guard !info.frame.isClose(to: target, tolerance: 1) else { return }
        log.notice("window \(info.id) (\(app.bundleID ?? "?", privacy: .public)) \(park ? "waits out of sight for the rest of its burst" : "goes straight to its tile", privacy: .public)")
        let element = info.element, resizable = info.resizable
        WindowHandle.queue(for: info.id).async { [weak self] in
            guard let actual = element.place(in: target), resizable,
                  abs(actual.width - target.width) > 2 || abs(actual.height - target.height) > 2 else { return }
            DispatchQueue.main.async { self?.fittedOnArrival(info, app: app, asked: target, got: actual) }
        }
    }

    /// A window being placed didn't take its tile's size: it has a minimum, a maximum or a shape
    /// of its own (Simulator, 1Password). Learn that now and send it straight to the frame it fits,
    /// rather than leaving it centered in the tile and moving it again once `learnLimits` notices.
    private func fittedOnArrival(_ info: WindowInfo, app: AppHandle, asked target: CGRect, got actual: CGRect) {
        guard enabled, apps[app.pid] === app, abs(actual.midX - target.midX) <= 3, abs(actual.midY - target.midY) <= 3 else { return }
        let before = limits[info.id] ?? SizeLimits()
        let after = before.learning(asked: target.size, got: actual.size)
        guard after != before, !after.isEmpty else { return }
        limits[info.id] = after
        log.notice("window \(info.id) (\(app.bundleID ?? "?", privacy: .public)) can't fill its tile: it takes \(String(describing: after), privacy: .public)")
        if let w = windows[info.id], place(of: info.id) != nil {
            // Already laid out: fit it now, in one move.
            guard !w.hidden, w.target == target else { return }
            w.frame = actual
            w.settledSize = actual.size
            reconsiderColumn(of: info.id)
            arriving.insert(info.id)
            relayout(animated: true)
            persist()
        } else if windows[info.id] == nil {
            prePlaced[info.id] = nil
            guard let fitted = plannedFrame(for: info, app: app), !fitted.isClose(to: actual, tolerance: 2) else { return }
            let element = info.element
            WindowHandle.queue(for: info.id).async { element.place(in: fitted) }
        }
    }

    /// Windows moved into place before they're laid out, with the display and when: others
    /// arriving at the same moment (an app opening two at once) are planned around them.
    private var prePlaced: [CGWindowID: (display: String, at: CFTimeInterval)] = [:]

    /// Where a window on its way will tile, worked out without changing anything.
    private func plannedFrame(for info: WindowInfo, app: AppHandle) -> CGRect? {
        let probe = ManagedWindow(handle: WindowHandle(id: info.id, element: info.element, app: app), frame: info.frame)
        // Its app restarted: it's going back where it was (`insert`).
        if let back = restartSpot(for: probe, take: false) {
            guard back.space == currentSpace, let d = activeDisplays.first(where: { $0.uuid == back.display }) else {
                // To another Workspace: out of sight right away, unless you're about to go there with it.
                return openedByYou(probe) ? nil : CGRect(origin: Display.hidingSpot(in: displays), size: info.frame.size)
            }
            var layout = spaces[currentSpace][d.uuid] ?? Layout()
            guard layout.restore(info.id, from: QuitMemory.layout(of: back, as: info.id)) else { return nil }
            return layout.frames(in: d.visible, gap: Self.gap, limits: limits)[info.id]
        }
        if let e = expected.first(where: { $0.matches(probe) }), let (s, uuid) = place(of: e.id), s == currentSpace,
           let d = activeDisplays.first(where: { $0.uuid == uuid }) {
            return spaces[s][uuid]?.frames(in: d.visible, gap: Self.gap, limits: limits)[e.id] // the tile held for it
        }
        guard let display = arrivalDisplay(for: info.frame) else { return nil }
        var layout = spaces[currentSpace][display.uuid] ?? Layout()
        let maxColumns = Layout.maxColumns(forWidth: display.visible.width)
        let now = CACurrentMediaTime()
        prePlaced = prePlaced.filter { now - $0.value.at < 1.5 && place(of: $0.key) == nil }
        for (id, _) in prePlaced.filter({ $0.value.display == display.uuid }).sorted(by: { $0.value.at < $1.value.at }) {
            layout.insert(id, near: layout.windows.last, maxColumns: maxColumns)
        }
        let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
        var planned = layout
        planned.insert(info.id, near: near, maxColumns: maxColumns, limits: limits, room: room(on: display))
        prePlaced[info.id] = (display.uuid, now)
        return planned.frames(in: display.visible, gap: Self.gap, limits: limits)[info.id]
    }

    /// Puts a window that was out of view back where it was (`away`): back from full screen, its
    /// app shown again, or back in sight. Same Workspace, same stack and shares, in Focus again
    /// if it was. One that leaves full screen while another Workspace is in view joins that one.
    private func returnToSpot(_ window: ManagedWindow) -> Bool {
        guard let spot = away.take(window.id),
              let space = AwayMemory.destination(of: spot, currentSpace: currentSpace), spaces.indices.contains(space),
              let display = activeDisplays.first(where: { $0.uuid == spot.display }) else { return false }
        var layout = spaces[space][spot.display] ?? Layout()
        if !layout.restore(window.id, from: spot.layout) {
            layout.insert(window.id, near: layout.windows.last, maxColumns: Layout.maxColumns(forWidth: display.visible.width))
        }
        if spot.focus, space == currentSpace, layout.windowCount > 1 {
            layout.spotlight = window.id
            Snapshotter.capture(layout.shelved) { [weak self] images in
                for (wid, image) in images { self?.shelf.setSnapshot(image, for: wid) }
            }
        }
        spaces[space][spot.display] = layout
        let from = switch spot.why {
        case .fullScreen: "full screen"
        case .appHidden: "its app being hidden"
        case .outOfView: "out of sight"
        }
        log.notice("window \(window.id) back from \(from, privacy: .public) in space \(space + 1)")
        // Its app came back in front with it (a Dock click or ⌘-Tab to a hidden app whose window is
        // in another Workspace): go there with it, so the keyboard isn't on a window out of sight.
        if space != currentSpace {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusedID == window.id, self.place(of: window.id)?.space == space else { return }
                self.go(to: window.id, in: space)
                self.activate(window.id)
                self.showRing(on: window.id)
            }
        }
        return true
    }

    /// When a window still around first went missing from its app's list.
    private var unlistedSince: [CGWindowID: CFTimeInterval] = [:]
    /// When a tiled window first went out of view without closing.
    private var offScreenSince: [CGWindowID: CFTimeInterval] = [:]

    /// - appQuit: it closed because its app quit, which says nothing about the window.
    private func forget(_ id: CGWindowID, appQuit: Bool = false) {
        // Where it was, in case its app is quitting (`QuitMemory`): a restart brings the next window back there.
        if enabled, let w = windows[id], let app = w.handle.app.bundleID, !Placeholder.isPlaceholder(id),
           let (space, uuid) = place(of: id), let layout = spaces[space][uuid]?.withoutPlaceholders() {
            quitMemory.closed(app, spot: .init(window: id, space: space, display: uuid, frame: w.frame, layout: layout,
                                               usedLast: focusedID == id || lastFocused[space] == id),
                              at: CACurrentMediaTime())
        }
        requested.remove(id)
        placedForYou[id] = nil
        away.forget(id)
        unlistedSince[id] = nil
        offScreenSince[id] = nil
        removeFromLayouts(id)
        if let w = windows.removeValue(forKey: id) {
            w.handle.app.windowIDs.removeValue(forKey: w.handle.element)
        }
        WindowHandle.forget(id)
        if focusedID == id { focusedID = nil }
        recentlyFocused.removeAll { $0 == id }
        adopted.remove(id)
        offDisplay.remove(id)
        centeredDialogs.remove(id)
        dialogsAwaitingScreen.remove(id)
        preCentered.remove(id)
        settlingUntil[id] = nil
        lastReassert[id] = nil
        pendingReassert.removeValue(forKey: id)?.cancel()
        droppedAt[id] = nil
        limits[id] = nil
        prePlaced[id] = nil
        headedBack[id] = nil
        stashed[id] = nil
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
            windowCreated(element, app: app)
        case kAXUIElementDestroyedNotification:
            if let id = app.windowIDs[element] {
                quietFocus()
                let wasFocused = focusedID == id
                let frame = windows[id].flatMap { $0.hidden ? nil : ($0.target ?? $0.frame) }
                // A dialog or other floating window hands focus back to the tile used before
                // it, not to whichever tile is nearest the middle of the screen.
                let before = place(of: id) == nil ? lastFocused[currentSpace] : nil
                forget(id)
                // An app LunchboxWM is holding a tile for closed what it showed instead (Xcode's welcome
                // window, say) and has nothing else up: no window is coming, so close the gap now.
                let pending = expected.filter { $0.answeredOtherwise && ($0.pid == app.pid || ($0.pid == nil && $0.bundleID == app.bundleID)) }
                if !pending.isEmpty, !windows.values.contains(where: { $0.pid == app.pid && !$0.minimized && !$0.hidden }) {
                    giveUp(pending, why: "it closed the window it showed instead")
                }
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
        case kAXWindowDeminiaturizedNotification:
            // Back from the Dock (clicked there, or Summoned after Hide): it's on screen only once
            // the Dock's animation is over, which takes a moment. Look until it is.
            if let id = app.windowIDs[element] { windows[id]?.restoredAt = CACurrentMediaTime() }
            scheduleScan(app, after: [0.03, 0.3, 0.7, 1.5])
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

    /// Something LunchboxWM opened (from Summon) is on its way: when its app comes
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
        // An app already in front doesn't activate again, so what it focuses next counts as
        // Summon's straight away: a page that still lands in a window parked in another
        // Workspace brings that window here instead of taking you there.
        if let app = apps.values.first(where: { $0.bundleID == bundleID }) {
            summonActivation = (app.pid, CACurrentMediaTime() + 3)
        }
    }

    /// The next new window from an app Summon just opened something in.
    private var summonedArrival: (bundleID: String, existing: Set<CGWindowID>, until: CFTimeInterval)?
    /// Windows tiled because they answered a Summon open, though their app doesn't call them standard.
    private var adopted: Set<CGWindowID> = []
    /// Windows you moved onto a display LunchboxWM doesn't manage (Use All Displays off): left
    /// alone while there. (An app moving its own window there gets it back in its tile.)
    private var offDisplay: Set<CGWindowID> = []
    /// Apps an agent is testing on the spoof display: LunchboxWM doesn't tile their windows
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
        // LunchboxWM never tracked where they went, so ask where they are now.
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

    /// Whether you moved this tiled window onto a display LunchboxWM doesn't tile (dragged it, or
    /// with a key or a menu just then), rather than its app moving it there by itself.
    private func movedThereByYou(_ id: CGWindowID) -> Bool {
        guard let w = windows[id] else { return false }
        let dragged = draggedByUser.contains(id) || CACurrentMediaTime() - (droppedAt[id] ?? 0) < 1.5
        let inFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid
        return OffDisplayMove.decide(dragged: dragged, inputAgo: Self.secondsSinceInput(), appInFront: inFront) == .leaveThere
    }

    /// Stops tiling a window you moved onto an unmanaged display, and closes its gap.
    private func leaveAlone(_ id: CGWindowID) {
        guard let w = windows[id], place(of: id) != nil else { return }
        offDisplay.insert(id)
        removeFromLayouts(id)
        w.target = nil
        relayout(animated: true)
        persist()
        log.notice("window \(id) was moved onto an unmanaged display by hand; leaving it there")
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

    /// Mission Control, App Exposé (which hides every other app's windows) or Show Desktop is up:
    /// windows in view are out of sight without going anywhere, and keep their tiles. The Dock
    /// says so (`overview`); failing that, several tiles in view out of sight at once, their apps
    /// not hidden, is the same (`CoverWatch`).
    private func screenCovered(onScreen: Set<CGWindowID>, shown: Set<Int>? = nil) -> Bool {
        if overview.isActive { return true }
        var shown = shown
        var gone = 0
        for id in visibleFrames().keys where !onScreen.contains(id) {
            guard let w = windows[id], !w.hidden, !w.minimized,
                  NSRunningApplication(processIdentifier: w.pid)?.isHidden != true else { continue }
            // Behind a full screen app: out of view for another reason.
            if shown == nil { shown = shownSpaces() }
            if let shown, isOutOfView(id, shown: shown) { continue }
            gone += 1
        }
        let covered = cover.covered(gone: gone, at: CACurrentMediaTime())
        if covered, gone >= 2, !wasCovered { log.notice("\(gone) tiles in view went out of sight at once: they keep their tiles") }
        wasCovered = covered
        return covered
    }
    private var wasCovered = false

    /// Some apps keep a closed window around instead of destroying it (Chess
    /// does), so it never says it's gone and would hold its tile forever. Any
    /// tiled window here that's no longer on screen gets its app asked again,
    /// which drops it.
    private func checkForGhosts() {
        guard enabled else { return }
        let onScreen = onScreenWindowIDs()
        // Under Mission Control, App Exposé or Show Desktop, windows out of sight are still there.
        if screenCovered(onScreen: onScreen) { return }
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
        rescanUntiled(onScreen: onScreen)
    }

    /// The other way round: a window on screen without a tile is looked at again (every 2 s at
    /// most) if it arrived in the last two minutes (an app may make a window long before it
    /// shows it, or only make it a normal window later, without telling anyone), came back from
    /// the Dock in the last half minute, or had a tile until it went out of view (`away`): back in
    /// sight with nothing said (Show Desktop or App Exposé over, its app shown again), it goes
    /// back to its spot.
    private func rescanUntiled(onScreen: Set<CGWindowID>) {
        let now = CACurrentMediaTime()
        var apps: [pid_t: AppHandle] = [:]
        for w in windows.values where (now - w.seenAt < 120 || now - w.restoredAt < 30 || away[w.id] != nil)
            && (w.standard || adopted.contains(w.id)) && (!w.hidden || away[w.id] != nil) && !w.minimized && !w.fullScreen
            && onScreen.contains(w.id) && place(of: w.id) == nil && !offDisplay.contains(w.id)
            && !leftAloneApps.contains(w.handle.app.bundleID ?? "") && !Self.floatingApps.contains(w.handle.app.bundleID ?? "") {
            guard (rechecked[w.id].map { now - $0 >= 2 } ?? true), recheck(w.id) else { continue }
            apps[w.pid] = w.handle.app
        }
        for app in apps.values { scheduleScan(app) }
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
            w.handle.queue.async { element.setPosition(spot) }
        }
    }

    private func refreshFocus() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        appActivated(front)
    }

    /// Where apps' tiled windows were when they quit: a restart puts them back.
    private var quitMemory = QuitMemory()

    /// Which remembered spot each window placed early (`prePlace`) was headed for.
    private var headedBack: [CGWindowID: WindowID] = [:]

    /// The spot a new window of a restarted app goes back to, if its Workspace and display are
    /// still there. `take`: it's being placed now, so the app's next window gets another spot.
    private func restartSpot(for window: ManagedWindow, take: Bool) -> QuitMemory.Spot? {
        guard let app = window.handle.app.bundleID else { return nil }
        let now = CACurrentMediaTime()
        let spot = take
            ? quitMemory.take(for: app, frame: window.frame, now: now, preferring: headedBack.removeValue(forKey: window.id))
            : quitMemory.spot(for: app, frame: window.frame, now: now)
        guard let spot, spot.space < spaceCount, activeDisplays.contains(where: { $0.uuid == spot.display }) else { return nil }
        if !take { headedBack[window.id] = spot.window }
        return spot
    }

    /// A restarted app's window went back to the Workspace it was in. If you just opened the app,
    /// you go with it, the way the Dock takes you to an app's window. If it came back by itself
    /// (an update, a crash), you stay where you are, and so does the keyboard.
    private func reopened(_ window: ManagedWindow, app: String, space: Int, display: Display) {
        let from = currentSpace
        guard space != from else { return }
        let name = Self.appName(app)
        if openedByYou(window) {
            didOnItsOwn(.reopened(app: name, space: space, followed: true), undo: .place(window.id, from: from),
                        key: "reopen|\(app)", from: from, on: display)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.place(of: window.id)?.space == space else { return }
                self.lastFocused[space] = window.id
                self.switchSpace(to: space, focusing: window.id)
                self.activate(window.id)
                self.showRing(on: window.id)
            }
        } else {
            placedForYou[window.id] = CACurrentMediaTime() + 3
            didOnItsOwn(.reopened(app: name, space: space, followed: false), undo: .place(window.id, from: from),
                        key: "reopen|\(app)", from: from, on: display)
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

    /// An app's name as Finder shows it ("Claude"), from its bundle ID.
    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Windows that took focus without a tile, and when they were last looked at again.
    private var rechecked: [CGWindowID: CFTimeInterval] = [:]

    /// Whether to look again at a known window that took focus without a tile: not one you
    /// floated or a dialog (they float on purpose), and at most once a second each.
    private func recheck(_ id: CGWindowID) -> Bool {
        guard windows[id] != nil, !userFloating.contains(id), !centeredDialogs.contains(id) else { return false }
        let now = CACurrentMediaTime()
        if let last = rechecked[id], now - last < 1 { return false }
        if rechecked.count > 500 { rechecked = rechecked.filter { now - $0.value < 60 } }
        rechecked[id] = now
        return true
    }

    private func focusChanged(to id: CGWindowID, app: AppHandle) {
        guard enabled else { return }
        checkForGhosts()
        if let hiddenAt = stashed[id] {
            // You went to it yourself since hiding it (⌘-Tab, its app in the Dock): it comes back
            // here. macOS handing focus to it by itself (its app was in front) isn't that.
            let input = Self.secondsSinceInput(), now = CACurrentMediaTime()
            if input < 1.5, now - input > hiddenAt + 0.05, now > quietFocusUntil {
                unhide(id)
            } else {
                reclaimFocus()
            }
            return
        }
        guard let (space, _) = place(of: id) else {
            // A dialog or other floating window: remember the tile it took focus from (which
            // may have been tiled only after it got focus), so focus goes back there after.
            if let tile = focusedID, place(of: tile)?.space == currentSpace { lastFocused[currentSpace] = tile }
            focusedID = id
            // One LunchboxWM doesn't know yet, or knows but never tiled: an app that showed its
            // window long after making it (Claude, while it starts) has it ready only now.
            if windows[id] == nil || recheck(id) { scheduleScan(app) }
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
                                       placedForYou: (placedForYou[id] ?? 0) > now,
                                       openingNewWindow: comingForward.map { $0.pid == app.pid && now < $0.until && $0.existing.contains(id) } ?? false) {
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
            case .leaveIt:
                // Coming forward to open a new window here: it stays where it is.
                break
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
        layout.insert(id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width), limits: limits, room: room(on: display))
        spaces[currentSpace][display.uuid] = layout
        quietFocus()
        relayout(animated: true)
        persist()
        activate(id)
        showRing(on: id)
        log.notice("brought window \(id) to space \(self.currentSpace + 1) for Summon")
    }

    /// Focus changes before this time don't switch spaces.
    private var quietFocusUntil: CFTimeInterval = 0

    private func quietFocus(for seconds: CFTimeInterval = 0.6) {
        quietFocusUntil = max(quietFocusUntil, CACurrentMediaTime() + seconds)
    }

    /// macOS just handed focus to a window parked in another space. Take it back
    /// to the window LunchboxWM had focused here, so typing can't land out of sight.
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
    /// Dialogs already moved to the middle while still out of sight.
    private var preCentered: Set<CGWindowID> = []

    private func center(_ info: WindowInfo, app: AppHandle) {
        center(info.element, frame: info.frame, app: app)
    }

    private func center(_ element: AXUIElement, frame: CGRect, app: AppHandle) {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = displays.first(where: { $0.frame.contains(middle) }) ?? displays.first(where: \.isMain) else { return }
        let origin = Dialogs.centeredOrigin(for: frame.size, in: display.visible)
        app.queue.async { element.setPosition(origin) }
    }

    /// A dialog can tell LunchboxWM it exists a moment before the window server shows it,
    /// and nothing more happens after that. Look again until it's up.
    private func centerOnceShown(_ info: WindowInfo, app: AppHandle) {
        guard dialogsAwaitingScreen.insert(info.id).inserted else { return }
        // Center it now, while it's out of sight, so it shows up in the middle (once: some
        // apps keep a dialog around hidden). The app may still place it itself as it shows
        // it, so look again once it's up.
        if preCentered.insert(info.id).inserted { center(info, app: app) }
        let element = info.element
        for delay in [0.02, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0] {
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

    /// Some apps move a window they just opened after LunchboxWM has placed it (Little Arc
    /// animates itself to the middle of the screen). Watch it for its first moments and,
    /// as soon as it holds still anywhere but its tile, put it straight back.
    private func confirmPlacement(of id: CGWindowID, poll: Int = 0, last: CGRect? = nil, corrected: CGRect? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let w = self.windows[id], !w.hidden, w.target != nil else { return }
            let element = w.handle.element
            w.handle.app.queue.async {
                let actual = element.frame
                DispatchQueue.main.async {
                    guard let actual, let w = self.windows[id], let target = w.target, !w.hidden else { return }
                    var corrected = corrected
                    // Centered where LunchboxWM put it at another size is a window that can't fill its tile
                    // (`learnLimits` handles it); anywhere else, it moved.
                    let moved = abs(actual.midX - target.midX) > 3 || abs(actual.midY - target.midY) > 3
                    if moved, last.map({ actual.isClose(to: $0, tolerance: 1) }) == true,
                       CACurrentMediaTime() > self.settlingUntil[id] ?? 0,
                       !self.draggedByUser.contains(id), NSEvent.pressedMouseButtons & 1 == 0 {
                        // Placed, then moved onto a display LunchboxWM doesn't tile: left there if you
                        // moved it, else (its app did) put back like any other move.
                        let offDisplay = self.isOnUnmanagedDisplay(actual) && !self.isOnUnmanagedDisplay(target)
                        if offDisplay, self.movedThereByYou(id) { self.leaveAlone(id); return }
                        // Back where it was before the last correction: the app insists (a window with a
                        // minimum size, say). No tug of war, except over a display you may not see.
                        if !offDisplay, let corrected, actual.isClose(to: corrected, tolerance: 2) { return }
                        if offDisplay { log.notice("window \(id) (\(w.handle.app.bundleID ?? "?", privacy: .public)) moved itself onto a display LunchboxWM doesn't tile; putting it back") }
                        w.frame = actual
                        w.target = nil
                        self.arriving.insert(id)
                        self.relayout(animated: true)
                        corrected = actual
                    }
                    guard poll < 32 else { return } // about 1.6 s
                    self.confirmPlacement(of: id, poll: poll + 1, last: actual, corrected: corrected)
                }
            }
        }
    }

    /// A tiled window moved or resized without us asking.
    private func windowChangedOnItsOwn(_ id: CGWindowID) {
        if away[id] != nil, let w = windows[id] {
            scheduleScan(w.handle.app, after: [0.15, 0.7])
            return
        }
        // Show Desktop and Mission Control move windows aside for a while: nothing to put back.
        if overview.isActive { return }
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
        // Moves just after a drop count even while LunchboxWM's own glide back settles: the check
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
            guard let w = self.windows[id], !w.hidden else { return }
            let element = w.handle.element
            w.handle.app.queue.async {
                let actual = element.frame
                let fullScreen = element.isFullScreen
                DispatchQueue.main.async {
                    if fullScreen, let w = self.windows[id] { self.scheduleScan(w.handle.app); return }
                    // Late notifications from our own moves land here too; only act on a real difference.
                    guard let actual, let w = self.windows[id], let target = w.target, !w.hidden,
                          !actual.isClose(to: target, tolerance: 2) else { return }
                    // Onto a display LunchboxWM doesn't tile: left there if you moved it. If its app did
                    // (Simulator going back to where an agent once left it), it comes back, even when it
                    // insists: a window must never end up somewhere you may not see.
                    let offDisplay = self.isOnUnmanagedDisplay(actual)
                    if offDisplay, self.movedThereByYou(id) { self.leaveAlone(id); return }
                    let now = CACurrentMediaTime()
                    let wait = 2 - (now - (self.lastReassert[id] ?? 0))
                    if wait > 0 {
                        if offDisplay {
                            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.windowChangedOnItsOwn(id) }
                        }
                        return
                    }
                    self.lastReassert[id] = now
                    if offDisplay {
                        log.notice("window \(id) (\(w.handle.app.bundleID ?? "?", privacy: .public)) moved itself onto a display LunchboxWM doesn't tile; putting it back")
                        w.frame = actual
                        w.target = nil
                        self.relayout(animated: true)
                        return
                    }
                    // Centered where LunchboxWM put it at another size: it can't fill its tile. That's
                    // for `learnLimits`, not a reason to move it.
                    if abs(actual.midX - target.midX) <= 3, abs(actual.midY - target.midY) <= 3 {
                        if w.resizable { self.learnLimits(of: id, askedFor: target) }
                        return
                    }
                    // A window that can't fill its tile changed its own size (another Simulator
                    // device, a different video): that's the most it wants now. Fit it at that size.
                    if w.resizable, self.limits[id] != nil, let before = w.settledSize,
                       abs(actual.width - before.width) > 8 || abs(actual.height - before.height) > 8 {
                        self.limits[id] = SizeLimits(maxWidth: actual.width, maxHeight: actual.height)
                    }
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
        // Dragged onto a display LunchboxWM doesn't tile: it stays there, untiled.
        if isOnUnmanagedDisplay(frame) {
            leaveAlone(id)
            return
        }
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
            return
        }
        // An outer edge resized the usual way (begun just outside the zone LunchboxWM takes over):
        // the arrangement takes that size around the middle, as if dragged there.
        if let d = displays.first(where: { $0.uuid == uuid }), let layout = spaces[space][uuid], resizesAsArrangement(layout) {
            func side(_ now: CGFloat, _ was: CGFloat, _ outer: Bool, _ s: Layout.Handle.Side) -> Layout.Handle.Side? {
                abs(now - was) > 4 && outer ? s : nil
            }
            let h = side(frame.minX, target.minX, layout.isOuter(id, horizontal: .low), .low)
                ?? side(frame.maxX, target.maxX, layout.isOuter(id, horizontal: .high), .high)
            let v = side(frame.minY, target.minY, layout.isOuter(id, vertical: .low), .low)
                ?? side(frame.maxY, target.maxY, layout.isOuter(id, vertical: .high), .high)
            if h != nil || v != nil {
                let point = CGPoint(x: h == .low ? frame.minX : h == .high ? frame.maxX : frame.midX,
                                    y: v == .low ? frame.minY : v == .high ? frame.maxY : frame.midY)
                if let next = layout.dragged(id, handle: Layout.Handle(horizontal: h, vertical: v), to: point,
                                             in: d.visible, gap: Self.gap, limits: limits) {
                    spaces[space][uuid] = next
                    w.target = nil
                    relayout(animated: true)
                    persist()
                    return
                }
            }
        }
        if abs(frame.width - target.width) > 4 || abs(frame.height - target.height) > 4 {
            if w.resizable { limits[id] = nil } // it took a size of the user's choosing
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
            }
        }
        w.target = nil
        relayout(animated: true)
        persist()
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

    /// Moves windows from displays LunchboxWM doesn't tile on (unplugged, or ignored
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
                    for (id, frame) in layout.frames(in: d.visible, gap: Self.gap, limits: limits) {
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
                        // Start from where it really is: a window that couldn't fill its last target sits
                        // centered inside it, not in its corner. One sent back to its slot on purpose (Tidy,
                        // a drag let go, an app that moved it) has no target: it glides from where it is.
                        let filled = w.target.map { t in w.settledSize.map { abs($0.width - t.width) <= 2 && abs($0.height - t.height) <= 2 } ?? true } ?? true
                        let from = w.hidden ? frame : (filled ? w.target ?? w.frame : w.frame)
                        let new = arriving.contains(id)
                        // A window that keeps its own size or shape slides at its final size (resizing it
                        // every frame would jitter); one whose sizes aren't known yet goes in one move.
                        let kind: Animator.Kind = w.hidden ? .reveal : !animated || !animationsAllowed || new ? .snap
                            : limits[id] != nil ? .slide : filled ? .animate : .snap
                        w.target = frame
                        w.hidden = false
                        // A snap lands in one go, so a new window's own moves count again almost at once.
                        settlingUntil[id] = now + (new ? 0.15 : Animator.duration + 0.3)
                        moves.append((w.handle, from, frame, kind))
                    }
                } else {
                    for id in layout.windows {
                        if let w = windows[id] { park(w) } else { tile(for: id)?.conceal() }
                    }
                }
            }
        }
        arriving.removeAll()
        animator.run(moves)
        updateShelf()
        onChange?()
    }

    /// Where each real window in view sits (placeholders aren't windows: nothing can focus them).
    private func visibleFrames() -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        for d in activeDisplays {
            guard let layout = spaces[currentSpace][d.uuid] else { continue }
            result.merge(layout.frames(in: d.visible, gap: Self.gap, limits: limits)) { a, _ in a }
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
                let layout = waiting.withoutPlaceholders() // they only last while LunchboxWM waits
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
        UserDefaults.standard.set(stashed.keys.map(Int.init), forKey: "hiddenWindows")
        UserDefaults.standard.set(adopted.filter { windows[$0] != nil || savedPlacement[$0] != nil }.map(Int.init), forKey: "adopted")
        var entries: [String: SavedLimits.Entry] = [:]
        for (id, l) in limits {
            guard let w = windows[id], let app = w.handle.app.bundleID else { continue }
            entries[String(id)] = .init(app: app, width: w.frame.width, height: w.frame.height, limits: l)
        }
        if let json = try? JSONEncoder().encode(SavedLimits(boot: Self.bootTime, windows: entries)) {
            UserDefaults.standard.set(String(decoding: json, as: UTF8.self), forKey: "limits")
        }
    }

    // MARK: Keyboard actions

    func perform(_ action: KeyAction) {
        guard enabled else { return }
        checkForGhosts()
        // LunchboxWM's idea of the focused window can go stale (a click it never heard
        // about, an app that didn't come forward). Acting on the wrong window is what
        // made "down" look like "up", so ask the front app which window really has
        // focus, unless LunchboxWM focused one itself a moment ago and the app may still
        // be catching up.
        let recentlyFocused = CACurrentMediaTime() - lastActivation < 0.35
        if case .switchSpace = action {} else if !recentlyFocused,
           let front = NSWorkspace.shared.frontmostApplication, let app = apps[front.processIdentifier] {
            app.queue.async { [weak self] in
                let t0 = CACurrentMediaTime()
                let id = app.element.element(kAXFocusedWindowAttribute)?.windowID
                // How quickly it answers says whether its windows can glide right now.
                app.recordLatency(CACurrentMediaTime() - t0, calls: 2)
                DispatchQueue.main.async {
                    guard let self else { return }
                    log.debug("resolve \(front.bundleIdentifier ?? "?", privacy: .public): \(id.map(String.init) ?? "nil", privacy: .public), LunchboxWM had \(self.focusedID.map(String.init) ?? "nil", privacy: .public)")
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
        case .resizeMode(let on): resizeMode(on)
        case .resizeAlong(let direction): resize(toward: direction)
        case .switchSpace(let i): switchSpace(to: i, focusing: nil)
        case .sendToSpace(let i): send(toSpace: i, follow: true)
        case .close: closeFocused()
        case .hide: hideFocused()
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
        let after = place(of: id).flatMap { spaces[$0.space][$0.display]?.columns.map(\.windows) } ?? []
        log.notice("move \(direction.rawValue, privacy: .public): window \(id) (\(self.windows[id]?.handle.app.bundleID ?? "?", privacy: .public)) \(String(describing: before), privacy: .public) -> \(String(describing: after), privacy: .public)")
        showRing(on: id)
    }

    /// How much one arrow press in resize mode changes a side (a share of the screen).
    static let sideStep = 0.05

    private static let resizeHelp = "Resize:  the arrows push the window's edges   ↩  done"

    /// Resize mode on (⌘⇧R) or off: the line says what the arrows do while it's on.
    private func resizeMode(_ on: Bool) {
        guard on else { endResizeMode(); return }
        guard let id = focusedID, place(of: id) != nil else { quietLine.show("Resize: focus a tiled window first", on: focusedDisplay); return }
        resizingWindow = id
        quietLine.show(Self.resizeHelp, on: focusedDisplay, seconds: HotkeyTap.resizeModeSeconds)
        keepResizeModeOn()
        showRing(on: id)
    }

    /// The window resize mode is working on: outlined in green while the mode is on.
    private var resizingWindow: CGWindowID?
    private var resizeModeTimeout: DispatchWorkItem?

    /// Resize mode ends by itself after a few seconds without a key (the event tap stops taking the
    /// arrows then too): the outline goes with it.
    private func keepResizeModeOn() {
        // The arrows work on the focused window: if you clicked another, the outline goes to it.
        if resizingWindow != nil, let id = focusedID, id != resizingWindow { resizingWindow = id }
        resizeModeTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endResizeMode() }
        resizeModeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HotkeyTap.resizeModeSeconds, execute: work)
    }

    private func endResizeMode() {
        resizeModeTimeout?.cancel()
        resizeModeTimeout = nil
        guard resizingWindow != nil else { return }
        resizingWindow = nil
        quietLine.dismiss()
        ring.hide()
    }

    /// The display the focused window is on.
    private var focusedDisplay: Display? {
        focusedID.flatMap { id in windows[id].flatMap { w in displays.first { $0.frame.contains((w.target ?? w.frame).center) } } }
    }

    /// Resize mode's arrows: they push the window's edge on their side (`Layout.resize(_:toward:)`).
    private func resize(toward direction: Direction) {
        if resizingWindow != nil { keepResizeModeOn() }
        let horizontal = direction == .left || direction == .right
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace,
              var layout = spaces[space][uuid], let d = activeDisplays.first(where: { $0.uuid == uuid }) else { return }
        if layout.resize(id, toward: direction, by: Self.sideStep, in: d.visible, gap: Self.gap, limits: limits) {
            spaces[space][uuid] = layout
            relayout(animated: true)
            persist()
            quietLine.show(Self.resizeHelp, on: d, seconds: HotkeyTap.resizeModeSeconds)
        } else if layout.resize(id, toward: direction, by: Self.sideStep, in: d.visible, gap: Self.gap) {
            // The shares could move, but the window (or its neighbor) is as small or as big as it goes.
            quietLine.show("Resize: it won't go any further that way", on: d, seconds: HotkeyTap.resizeModeSeconds)
        } else {
            // A window alone in its column already has the full height; one column, the full width.
            quietLine.show(horizontal ? "Resize: it already has the full width here" : "Resize: it already has the full height here",
                           on: d, seconds: HotkeyTap.resizeModeSeconds)
        }
        showRing(on: id)
    }

    private func resize(by delta: Double) {
        if resizingWindow != nil { keepResizeModeOn() }
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace,
              var layout = spaces[space][uuid], let d = activeDisplays.first(where: { $0.uuid == uuid }) else { return }
        // Only steps that show: a window already at its smallest takes no more shrinks.
        if layout.resize(id, by: delta, in: d.visible, gap: Self.gap, limits: limits) {
            spaces[space][uuid] = layout
            relayout(animated: true)
            persist()
        }
        showRing(on: id)
    }

    /// Adds Workspaces up to `count`, or takes the last ones away: their windows join the last
    /// Workspace that stays, and if you were in one of them, so do you.
    func setSpaceCount(_ count: Int) {
        let count = min(Command.maxWorkspaces, max(Command.defaultWorkspaces, count))
        guard count != spaceCount else { return }
        if count > spaceCount {
            spaces += Array(repeating: [:], count: count - spaceCount)
        } else {
            let last = count - 1
            for s in count..<spaceCount {
                for (uuid, layout) in spaces[s] {
                    let display = displays.first { $0.uuid == uuid }
                    let width = display?.visible.width ?? 1600
                    var into = spaces[last][uuid] ?? Layout()
                    for id in layout.windows {
                        into.insert(id, near: into.windows.last, maxColumns: Layout.maxColumns(forWidth: width),
                                    limits: limits, room: display.map(room(on:)))
                    }
                    spaces[last][uuid] = into
                }
            }
            spaces.removeLast(spaceCount - count)
            for s in count..<spaceCount {
                lastFocused[s] = nil
            }
            if currentSpace > last { currentSpace = last }
        }
        spaceCount = count
        UserDefaults.standard.set(count, forKey: "workspaceCount")
        log.notice("now \(count) Workspaces")
        onSpaceCountChange?(count)
        if enabled {
            relayout(animated: true)
            persist()
            badge.show(space: currentSpace, count: spaceCount, caption: "\(count) Workspaces", on: displays.first(where: \.isMain))
        }
        onChange?()
    }

    func switchSpace(to index: Int, focusing preferred: CGWindowID?) {
        guard enabled, (0..<spaceCount).contains(index) else { return }
        // Right after LunchboxWM did something on its own, the key of the Workspace you were in undoes it.
        if preferred == nil, undoAutomatic(pressed: index) { return }
        let display = focusedID.flatMap { id in windows[id].flatMap { w in displays.first { $0.frame.contains((w.target ?? w.frame).center) } } }
        guard index != currentSpace else {
            badge.show(space: index, count: spaceCount, on: display)
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
        badge.show(space: index, count: spaceCount, on: display)
    }

    /// Windows put out of sight with Hide (⌘⇧H), in no Workspace, and when: parked just off the
    /// screen like a window in another Workspace, still open. Summon, the Dock or ⌘-Tab brings one
    /// back into the Workspace you're in.
    private var stashed: [CGWindowID: CFTimeInterval] = [:]

    /// Hide (⌘⇧H): the focused window goes out of sight, parked off the screen the way windows in
    /// other Workspaces wait, still open. The windows here close the gap at once.
    private func hideFocused() {
        guard enabled, let id = focusedID, let w = windows[id], !w.hidden, !w.minimized else { return }
        let frame = visibleFrames()[id] ?? w.target ?? w.frame
        let display = displays.first { $0.frame.contains(frame.center) }
        quietFocus()
        removeFromLayouts(id)
        stashed[id] = CACurrentMediaTime()
        park(w)
        relayout(animated: true)
        persist()
        focusNearest(to: frame, excluding: id)
        let name = w.handle.app.bundleID.map(Self.appName) ?? "The window"
        quietLine.show("\(name) is hidden · Summon (⇧ Space) brings it back", on: display)
        log.notice("hid window \(id)")
    }

    /// Parks a window just off the screen, where windows in other Workspaces wait.
    private func park(_ w: ManagedWindow) {
        let parked = CGRect(origin: Display.hidingSpot(in: displays), size: (w.target ?? w.frame).size)
        w.target = parked
        w.hidden = true
        settlingUntil[w.id] = CACurrentMediaTime() + 0.4
        animator.run([(w.handle, parked, parked, .positionOnly)])
    }

    /// A hidden window comes back: into the Workspace you're in, beside the window you're in.
    private func unhide(_ id: CGWindowID) {
        guard stashed.removeValue(forKey: id) != nil, windows[id] != nil else { return }
        // Still parked: the layout reveals it the way a Workspace switch does.
        guard let display = focusedDisplay ?? activeDisplays.first(where: \.isMain) ?? activeDisplays.first else { return }
        var layout = spaces[currentSpace][display.uuid] ?? Layout()
        let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
        layout.insert(id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width), limits: limits, room: room(on: display))
        spaces[currentSpace][display.uuid] = layout
        quietFocus()
        relayout(animated: true)
        persist()
        activate(id)
        showRing(on: id)
        log.notice("unhid window \(id) into space \(self.currentSpace + 1)")
    }

    /// Moves the focused window to another space. With `follow`, you go along
    /// and it stays focused; without, focus moves to its nearest neighbor here.
    private func send(toSpace index: Int, caption: String? = nil, follow: Bool) {
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace, index != space,
              (0..<spaceCount).contains(index) else { return }
        let display = displays.first { $0.uuid == uuid }
        let oldFrame = windows[id]?.target
        quietFocus()
        removeFromLayouts(id)
        var destination = spaces[index][uuid] ?? Layout()
        destination.insert(id, near: destination.windows.last, maxColumns: Layout.maxColumns(forWidth: display?.visible.width ?? 1600),
                           limits: limits, room: display.map(room(on:)))
        spaces[index][uuid] = destination
        // You put this app's window in that Workspace (hiding a window is putting it away, not a home).
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
        badge.show(space: index, count: spaceCount, caption: caption ?? "Moved to Workspace \(index + 1)", on: display)
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
        log.notice("close: front \(running?.bundleIdentifier ?? "?", privacy: .public) (tracked: \(front != nil)), LunchboxWM focus \(self.focusedID.map(String.init) ?? "nil", privacy: .public)")
        if let front, known?.handle.app !== front {
            // The front app's own key window: a dialog, or a window LunchboxWM doesn't tile.
            front.queue.async {
                if let window = front.element.element(kAXFocusedWindowAttribute) { Self.pressClose(window) }
            }
            scheduleScan(front, after: [0.3, 1.0])
            return
        }
        // The window LunchboxWM has focused here. Also used when the front app isn't one
        // LunchboxWM tiles (a helper that took focus, or LunchboxWM itself).
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
        return windows.values.filter { $0.pid == pid && isReachable($0, onScreen: onScreen) }
    }

    private func isReachable(_ w: ManagedWindow, onScreen: Set<CGWindowID>) -> Bool {
        if place(of: w.id) != nil || stashed[w.id] != nil { return true }
        return w.standard && (w.minimized || onScreen.contains(w.id))
            && w.frame.width >= 100 && w.frame.height >= 80
    }

    func hasReachableWindow(ofApp pid: pid_t) -> Bool { !reachableWindows(ofApp: pid).isEmpty }

    /// A window Summon can go to, for its window rows.
    struct OpenWindow {
        let id: CGWindowID
        let pid: pid_t
        let appID: String?
        let appName: String
        let appURL: URL?
        /// As read when Summon last opened ("" before that, or when it has none).
        let title: String
        /// The Workspace it's tiled in, from 0; nil when it floats or is minimized.
        let space: Int?
        /// The display it's on, by name, when LunchboxWM tiles more than one; else nil.
        let display: String?
        let minimized: Bool
        /// Put out of sight with Hide.
        let hidden: Bool
    }

    /// Every window Summon can go to (the same ones its app rows count as open), the most
    /// recently used first and the focused one last. In memory only: no Accessibility reads.
    func openWindows() -> [OpenWindow] {
        let onScreen = recentOnScreenWindowIDs()
        let recency = Dictionary(recentlyFocused.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        func order(_ w: ManagedWindow) -> (Int, Int, CGWindowID) { (w.id == focusedID ? 1 : 0, recency[w.id] ?? .max, w.id) }
        var appInfo: [pid_t: (name: String, url: URL?)] = [:]
        let several = activeDisplays.count > 1
        return windows.values.filter { isReachable($0, onScreen: onScreen) }
            .sorted { order($0) < order($1) }
            .map { w in
                if appInfo[w.pid] == nil {
                    let running = NSRunningApplication(processIdentifier: w.pid)
                    appInfo[w.pid] = (running?.localizedName ?? w.handle.app.bundleID ?? "", running?.bundleURL)
                }
                let app = appInfo[w.pid]!
                let spot = place(of: w.id)
                let display = several ? (spot.flatMap { s in displays.first { $0.uuid == s.display } }
                    ?? displays.first { $0.frame.contains(w.frame.center) })?.name : nil
                return OpenWindow(id: w.id, pid: w.pid, appID: w.handle.app.bundleID, appName: app.name, appURL: app.url,
                                  title: w.title ?? "", space: spot?.space, display: display, minimized: w.minimized,
                                  hidden: stashed[w.id] != nil)
            }
    }

    /// Reads the title of every window Summon can go to, each app's on its own queue, and calls
    /// `done` on the main thread once all are in, or after a quarter second if an app is slow to
    /// answer (its titles still land, for the next search).
    func readWindowTitles(then done: @escaping () -> Void) {
        let onScreen = recentOnScreenWindowIDs()
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done()
        }
        let group = DispatchGroup()
        for (pid, list) in Dictionary(grouping: windows.values.filter { isReachable($0, onScreen: onScreen) }, by: \.pid) {
            guard let app = apps[pid] else { continue }
            let elements = list.map { ($0.id, $0.handle.element) }
            group.enter()
            app.queue.async { [weak self] in
                let titles = elements.map { id, element in (id, element.string(kAXTitleAttribute) ?? "") }
                DispatchQueue.main.async {
                    for (id, title) in titles { self?.windows[id]?.title = title }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main, execute: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: finish)
    }

    /// Focuses one window wherever it is: in another Workspace, on another display, or
    /// minimized in the Dock. Returns false when it's gone.
    func goToWindow(_ id: CGWindowID) -> Bool {
        if stashed[id] != nil { unhide(id); return true }
        guard let w = windows[id], isReachable(w, onScreen: recentOnScreenWindowIDs()) else { return false }
        bringForward(w)
        return true
    }

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
    /// as a tab right where you are. Calls back once the app itself says that window
    /// is in front (or after half a second either way) with its frame, or with nil
    /// when the app has no window here. Only then is the browser's "front window"
    /// this one, not one parked in another Workspace.
    func focusWindowHere(ofApp bundleID: String, completion: @escaping (CGRect?) -> Void) {
        let visible = visibleFrames()
        let mine = visible.keys.filter { windows[$0]?.handle.app.bundleID == bundleID }
        guard !mine.isEmpty else { return completion(nil) }
        let pick = [focusedID, lastFocused[currentSpace]].compactMap { $0 }.first(where: mine.contains)
            ?? mine.min { a, b in (visible[a]!.minX, visible[a]!.minY) < (visible[b]!.minX, visible[b]!.minY) }!
        activate(pick)
        showRing(on: pick)
        let frame = visible[pick]!
        guard let app = windows[pick]?.handle.app else { return completion(frame) }
        whenFocused(app, timeout: 0.5, where: { $0 == pick }) { _ in completion(frame) }
    }

    /// Opens a new window of the app here (its own New Window command) and calls back once
    /// it's in front, or with false if the app has no such command or nothing came in 2 s.
    func openNewWindowHere(ofApp pid: pid_t, then: @escaping (Bool) -> Void) {
        guard let app = apps[pid] else { return then(false) }
        let existing = Set(windows.values.filter { $0.pid == pid }.map(\.id))
        openNewWindow(ofApp: pid) { [weak self] opened in
            guard opened, let self else { return then(false) }
            self.whenFocused(app, timeout: 2, where: { !existing.contains($0) }, then: then)
        }
    }

    /// Calls `then` on the main queue once the app's focused window, read through
    /// Accessibility every 40 ms, passes `test`, or after `timeout` (with false).
    private func whenFocused(_ app: AppHandle, timeout: CFTimeInterval, where test: @escaping (CGWindowID) -> Bool,
                             then: @escaping (Bool) -> Void) {
        let deadline = CACurrentMediaTime() + timeout
        func check() {
            app.queue.async {
                let id = app.element.element(kAXFocusedWindowAttribute)?.windowID
                DispatchQueue.main.async {
                    if let id, test(id) { return then(true) }
                    guard CACurrentMediaTime() < deadline else { return then(false) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { check() }
                }
            }
        }
        check()
    }

    /// Focuses the app's most recently used window, switching spaces or
    /// restoring it from the Dock if needed. Returns false when the app has no
    /// window you could get to.
    func goToWindow(ofApp pid: pid_t) -> Bool {
        let mine = reachableWindows(ofApp: pid)
        guard !mine.isEmpty else { return false }
        let recent = ([currentSpace] + (0..<spaceCount).filter { $0 != currentSpace })
            .compactMap { lastFocused[$0] }
            .first { windows[$0]?.pid == pid }
        let choice = recent.flatMap { windows[$0] }
            ?? mine.first { place(of: $0.id)?.space == currentSpace }
            ?? mine.first { place(of: $0.id) != nil }
            ?? mine.first { !$0.minimized }
            ?? mine.first
        guard let w = choice, mine.contains(where: { $0 === w }) else { return false }
        bringForward(w)
        return true
    }

    /// Restores the window if it's minimized, switches to its Workspace, and focuses it.
    /// Only Summon comes here, by app or by window title.
    private func bringForward(_ w: ManagedWindow) {
        // A jump that took you somewhere counts as time back; one to the window you were
        // already in doesn't.
        let elsewhere = place(of: w.id).map { $0.space != currentSpace } ?? false
        if w.minimized || w.id != focusedID || elsewhere {
            TimeBackLedger.shared.count(.summoned)
        }
        if w.minimized {
            // Restore it; LunchboxWM tiles it again when it comes back.
            let element = w.handle.element
            w.handle.app.queue.async { element.set(kAXMinimizedAttribute, false) }
        }
        if let space = place(of: w.id)?.space, space != currentSpace { switchSpace(to: space, focusing: w.id) }
        activate(w.id)
        showRing(on: w.id)
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
        // What's coming here is a new window. The app comes forward on one of the windows it has,
        // maybe one in another Workspace: that one stays where it is, rather than being taken for
        // what Summon opened and brought along.
        comingForward = (pid, existing, CACurrentMediaTime() + 2)
        if summonActivation?.pid == pid { summonActivation = nil }
        if expectedArrival?.bundleID == app.bundleID { expectedArrival = nil }
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
    /// LunchboxWM looks at its menus (then `changed` runs once with the answer).
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

    /// A window LunchboxWM knows is on its way, and the tile it holds for it.
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
        /// The app, done starting up, showed something that doesn't tile instead (a welcome
        /// window, a template chooser, a dialog): its answer for now. The tile lets go soon.
        var answeredOtherwise = false

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
    /// How long it waits once the app showed some other window instead: one that looks like a
    /// window but doesn't tile (its real one may be right behind)...
    static let placeholderAfterOtherWindow: CFTimeInterval = 1.5
    /// ...or a panel or dialog, like Xcode's welcome window or a template chooser.
    static let placeholderAfterPanel: CFTimeInterval = 0.4

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
    /// for opens LunchboxWM is sure of, never just any app starting up.
    /// - another: hold one more even if the app already has one waiting (⇧↩ twice).
    /// - since: when the click was, so a window that beat LunchboxWM here counts.
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
        let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
        layout.insert(id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width),
                      limits: limits, room: room(on: display))
        spaces[currentSpace][display.uuid] = layout

        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        var name = running?.localizedName ?? url.map { FileManager.default.displayName(atPath: $0.path) } ?? ""
        if name.hasSuffix(".app") { name.removeLast(4) }
        let icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        let e = Expected(id: id, bundleID: bundleID, pid: running?.processIdentifier, existing: Set(mine.map(\.id)),
                         deadline: CACurrentMediaTime() + Self.placeholderWait, tile: PlaceholderTile(icon: icon, name: name))
        expected.append(e)
        relayout(animated: true)
        schedulePlaceholderCheck()
        log.notice("holding a tile for \(bundleID, privacy: .public) in space \(self.currentSpace + 1)")
    }

    /// A new window from an app LunchboxWM is holding a tile for takes that tile,
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
        TimeBackLedger.shared.count(.tiled)
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
    /// Looks again right when a tile's shortened wait runs out, not at the next routine check.
    private func checkPlaceholders(after delay: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.02) { [weak self] in self?.checkPlaceholders() }
    }

    private func checkPlaceholders() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        // An app that put up its other window while still starting up (Xcode's welcome window can
        // beat the end of its launch) has answered once it's done starting up.
        for e in expected where !e.answeredOtherwise {
            guard let pid = e.pid, NSRunningApplication(processIdentifier: pid)?.isFinishedLaunching == true,
                  windows.values.contains(where: { $0.pid == pid && !e.existing.contains($0.id) && !$0.minimized && !$0.hidden
                      && place(of: $0.id) == nil && isOnScreen($0.id) }) else { continue }
            e.answeredOtherwise = true
            e.deadline = min(e.deadline, now + Self.placeholderAfterPanel)
            checkPlaceholders(after: Self.placeholderAfterPanel)
            log.notice("\(e.bundleID, privacy: .public) answered with a window that doesn't tile; letting its tile go")
        }
        let late = expected.filter { e in
            guard now >= e.deadline else { return false }
            let app = e.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: e.bundleID).first { !$0.isTerminated }
            let starting = app.map { !$0.isFinishedLaunching && !$0.isTerminated } ?? false
            return e.answeredOtherwise || !starting || now - e.started >= Self.placeholderLongestWait
        }
        if !late.isEmpty {
            let answered = late.filter(\.answeredOtherwise)
            if !answered.isEmpty { giveUp(answered, why: "it showed a window that doesn't tile instead") }
            let empty = late.filter { !$0.answeredOtherwise }
            if !empty.isEmpty { giveUp(empty, why: "no window came") }
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
        let resizing = resizingWindow == id
        ring.flash(frame, on: displays, color: resizing ? .systemGreen : .controlAccentColor, hold: resizing)
        guard !moving else { return } // the move's own read-back corrects it
        let element = w.handle.element
        w.handle.app.queue.async { [weak self] in
            let actual = element.frame
            DispatchQueue.main.async {
                guard let self, let actual, self.ringWindow == id, self.ring.isShowing,
                      !actual.isClose(to: frame, tolerance: 2) else { return }
                self.windows[id]?.frame = actual
                let resizing = self.resizingWindow == id
                self.ring.flash(actual, on: self.displays, color: resizing ? .systemGreen : .controlAccentColor, hold: resizing)
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
        w.settledSize = actual.size
        if ringWindow == id, ring.isShowing, let target = w.target, !actual.isClose(to: target, tolerance: 2) {
            let resizing = resizingWindow == id
            ring.flash(actual, on: displays, color: resizing ? .systemGreen : .controlAccentColor, hold: resizing)
        }
        if w.resizable, let target = w.target, abs(actual.width - target.width) > 2 || abs(actual.height - target.height) > 2 {
            learnLimits(of: id, askedFor: target)
        }
    }

    /// A window's minimum height was just discovered (only squeezing a window shows it), and
    /// its column can't hold everything in it any more. The window that arrived there last, if
    /// it's only just arrived, moves to a column that fits it, or to one of its own; windows that
    /// have been in place a while are never shuffled.
    private func reconsiderColumn(of id: CGWindowID) {
        guard let (s, uuid) = place(of: id), var layout = spaces[s][uuid], layout.spotlight == nil,
              let display = activeDisplays.first(where: { $0.uuid == uuid }) else { return }
        let r = room(on: display)
        let now = CACurrentMediaTime()
        func overfull(_ column: [CGWindowID]) -> Bool {
            column.map { max(limits[$0]?.minHeight ?? 0, 80) }.reduce(0, +) + r.gap * CGFloat(column.count - 1) > r.area.height
        }
        var moved: Set<CGWindowID> = []
        for _ in 0..<2 {
            guard let (c, _) = layout.position(of: id), overfull(layout.columns[c].windows), layout.columns[c].windows.count > 1,
                  let newest = layout.columns[c].windows.filter({ !moved.contains($0) && windows[$0].map { now - $0.seenAt < 4 } == true })
                    .max(by: { windows[$0]!.seenAt < windows[$1]!.seenAt }) else { break }
            layout.remove(newest)
            layout.insert(newest, near: layout.windows.last, maxColumns: Layout.maxColumns(forWidth: display.visible.width),
                          limits: limits, room: r)
            moved.insert(newest)
            log.notice("window \(newest) didn't fit its column; moved to one with room")
        }
        // A window that just arrived turned out narrow (it keeps its own width): a column of its own,
        // if that leaves the others their room.
        if moved.isEmpty, let w = windows[id], now - w.seenAt < 4, limits[id]?.maxWidth != nil,
           let (c, _) = layout.position(of: id), layout.columns[c].windows.count > 1 {
            var trial = layout
            trial.remove(id)
            trial.insert(id, near: trial.windows.last, maxColumns: Layout.maxColumns(forWidth: display.visible.width), limits: limits, room: r)
            if let (tc, _) = trial.position(of: id), trial.columns[tc].windows == [id] {
                layout = trial
                moved.insert(id)
                log.notice("window \(id) keeps its own width; gave it a column")
            }
        }
        if !moved.isEmpty { spaces[s][uuid] = layout }
    }

    /// A window settled at another size than it was asked for. Look again a moment later
    /// (a slow app may still be catching up), and if it's still that size, centered where
    /// LunchboxWM put it, remember what it takes and lay out around it.
    private func learnLimits(of id: CGWindowID, askedFor target: CGRect) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let w = self.windows[id], !w.hidden, w.target == target else { return } // moved on since
            let element = w.handle.element
            w.handle.app.queue.async {
                let frame = element.frame
                DispatchQueue.main.async {
                    guard let frame, let w = self.windows[id], !w.hidden, w.target == target,
                          abs(frame.midX - target.midX) <= 3, abs(frame.midY - target.midY) <= 3 else { return }
                    let before = self.limits[id] ?? SizeLimits()
                    let after = before.learning(asked: target.size, got: frame.size)
                    guard after != before else { return }
                    self.limits[id] = after.isEmpty ? nil : after
                    w.settledSize = frame.size
                    self.reconsiderColumn(of: id)
                    log.notice("window \(id) (\(w.handle.app.bundleID ?? "?", privacy: .public)) can't fill its tile: it takes \(String(describing: after), privacy: .public)")
                    w.frame = frame
                    self.relayout(animated: true)
                    self.persist()
                }
            }
        }
    }

    // MARK: Menu commands

    /// The windows sitting centered right now, alone on a display or in Focus: dragging one's
    /// edge stretches both sides (`HotkeyTap`).
    var centeredWindows: [(id: CGWindowID, frame: CGRect)] {
        guard enabled else { return [] }
        return activeDisplays.compactMap { d in
            guard let layout = spaces[currentSpace][d.uuid],
                  let id = layout.spotlight ?? (layout.windowCount == 1 ? layout.windows.first : nil),
                  !Placeholder.isPlaceholder(id), let w = windows[id], !w.hidden else { return nil }
            return (id, w.target ?? w.frame)
        }
    }

    /// The windows of the arrangements in view (two or more windows, not in Focus), and which of
    /// their sides are on the outside: dragging one of those, or any corner, resizes the arrangement
    /// (`HotkeyTap`, `arrangementDrag`).
    var arrangedWindows: [HotkeyTap.ArrangedWindow] {
        guard enabled else { return [] }
        return activeDisplays.flatMap { d -> [HotkeyTap.ArrangedWindow] in
            guard let layout = spaces[currentSpace][d.uuid], resizesAsArrangement(layout) else { return [] }
            return layout.windows.compactMap { id in
                guard let w = windows[id], !w.hidden else { return nil }
                return HotkeyTap.ArrangedWindow(id: id, frame: w.target ?? w.frame)
            }
        }
    }

    /// Two or more windows, none a placeholder or one that stops at a size of its own (Simulator, a
    /// fixed window). A minimum is fine: the arrangement just doesn't get smaller than it.
    private func resizesAsArrangement(_ layout: Layout) -> Bool {
        layout.isArrangement && layout.windows.allSatisfy {
            !Placeholder.isPlaceholder($0) && windows[$0] != nil && limits[$0]?.maxWidth == nil && limits[$0]?.maxHeight == nil
        }
    }

    /// A drag on an arrangement's outer edge or a corner, handed over by `HotkeyTap`: the window, the
    /// handle, and the layout as the drag began.
    private var arrangementDrag: (id: CGWindowID, handle: Layout.Handle, space: Int, display: Display, start: Layout, grab: CGVector)?

    /// The arrangement follows the drag live: the dragged edge or corner under the pointer, the
    /// opposite ones moving with it, everything centered (`Layout.dragged`); letting go keeps it.
    func arrangementDrag(_ event: HotkeyTap.ArrangementDragEvent) {
        switch event {
        case .began(let id, let handle, let press):
            guard enabled, let (space, uuid) = place(of: id), space == currentSpace, let layout = spaces[space][uuid],
                  resizesAsArrangement(layout), let d = activeDisplays.first(where: { $0.uuid == uuid }) else { arrangementDrag = nil; return }
            // The edge keeps the distance it had from the pointer when grabbed, instead of jumping
            // to the pointer on the first move.
            var grab = CGVector.zero
            if let f = layout.frames(in: d.visible, gap: Self.gap, limits: limits)[id] {
                if let h = handle.horizontal { grab.dx = (h == .low ? f.minX : f.maxX) - press.x }
                if let v = handle.vertical { grab.dy = (v == .low ? f.minY : f.maxY) - press.y }
            }
            arrangementDrag = (id, handle, space, d, layout, grab)
            activate(id)
        case .moved(let pointer):
            guard let drag = arrangementDrag else { return }
            let point = CGPoint(x: pointer.x + drag.grab.dx, y: pointer.y + drag.grab.dy)
            guard let next = drag.start.dragged(drag.id, handle: drag.handle, to: point, in: drag.display.visible, gap: Self.gap, limits: limits)
            else { return }
            for (id, frame) in next.frames(in: drag.display.visible, gap: Self.gap, limits: limits) { moveLive(id, to: frame) }
        case .ended(let pointer):
            guard let drag = arrangementDrag else { return }
            arrangementDrag = nil
            let point = CGPoint(x: pointer.x + drag.grab.dx, y: pointer.y + drag.grab.dy)
            guard let next = drag.start.dragged(drag.id, handle: drag.handle, to: point, in: drag.display.visible, gap: Self.gap, limits: limits),
                  spaces[drag.space][drag.display.uuid]?.windows.sorted() == next.windows.sorted()
            else { relayout(animated: true); return }
            spaces[drag.space][drag.display.uuid] = next
            // They glide (barely) from where the drag left them.
            for id in next.windows { windows[id]?.target = nil }
            relayout(animated: true)
            persist()
        }
    }

    /// The newest frame each window should take during a corner drag, and which windows have a
    /// move on its way: only the latest pointer position is ever sent, so a slow app doesn't fall behind.
    private var liveTargets: [CGWindowID: CGRect] = [:]
    private var liveMoving: Set<CGWindowID> = []

    private func moveLive(_ id: CGWindowID, to frame: CGRect) {
        guard let w = windows[id] else { return }
        settlingUntil[id] = CACurrentMediaTime() + 0.5 // its move notifications are LunchboxWM's own
        w.frame = frame
        guard !liveMoving.contains(id) else { liveTargets[id] = frame; return }
        liveMoving.insert(id)
        let element = w.handle.element
        WindowHandle.queue(for: id).async { [weak self] in
            _ = element.place(in: frame)
            DispatchQueue.main.async {
                guard let self else { return }
                self.liveMoving.remove(id)
                if let next = self.liveTargets.removeValue(forKey: id) { self.moveLive(id, to: next) }
            }
        }
    }

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
            // Start over on what each window takes, in case LunchboxWM ever learned it wrong.
            if windows[id]?.resizable == true { limits[id] = nil }
        }
        relayout(animated: true)
        persist()
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

    /// For Copy Diagnostics: each Workspace's tiles, and the windows that aren't in one, as their
    /// apps' bundle IDs and what LunchboxWM made of them. Never titles.
    func supportWindows() -> (workspaces: [SupportSummary.Workspace], untiled: [SupportSummary.Window]) {
        func entry(_ w: ManagedWindow, _ state: String) -> SupportSummary.Window {
            SupportSummary.Window(id: w.id, app: w.handle.app.bundleID ?? "no bundle ID", state: state,
                                  kind: nil, limits: limits[w.id], resizable: w.resizable)
        }
        var tiled = Set<CGWindowID>()
        let workspaces = (0..<spaceCount).map { s -> SupportSummary.Workspace in
            let layouts = s < spaces.count ? spaces[s] : [:]
            let tiles = layouts.sorted { $0.key < $1.key }.map { uuid, layout -> SupportSummary.Tiles in
                let columns = layout.columns.map { column in
                    column.windows.compactMap { id -> SupportSummary.Window? in
                        tiled.insert(id)
                        if let w = windows[id] { return entry(w, layout.shelved.contains(id) ? "on the shelf" : "tiled") }
                        return expected.first { $0.id == id }.map {
                            SupportSummary.Window(id: id, app: $0.bundleID, state: "placeholder, waiting for its window")
                        }
                    }
                }
                let name = displays.first { $0.uuid == uuid }?.name ?? "a display that isn't connected"
                return SupportSummary.Tiles(display: name, columns: columns, focus: layout.spotlight != nil)
            }
            return SupportSummary.Workspace(number: s + 1, tiles: tiles)
        }
        let untiled = windows.values.filter { !tiled.contains($0.id) }.sorted { $0.id < $1.id }.map { w -> SupportSummary.Window in
            let state: String
            if w.minimized { state = "minimized" }
            else if userFloating.contains(w.id) { state = "floated by you" }
            else if leftAloneApps.contains(w.handle.app.bundleID ?? "") { state = "app left alone" }
            else if Self.floatingApps.contains(w.handle.app.bundleID ?? "") { state = "floats (its app always does)" }
            else if !w.standard { state = "floats (panel or dialog)" }
            else { state = w.hidden ? "not tiled, off screen" : "not tiled" }
            return entry(w, state)
        }
        return (workspaces, untiled)
    }

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
                "resizable": w.resizable, "tiled": place(of: w.id) != nil,
                "limits": limits[w.id].map { String(describing: $0) } ?? "none",
            ]
        }
        let now = CACurrentMediaTime()
        let placeholders = expected.map { e -> [String: Any] in
            let spot = place(of: e.id)
            let display = spot.flatMap { s in activeDisplays.first { $0.uuid == s.display } }
            let frame = spot.flatMap { s in display.flatMap { spaces[s.space][s.display]?.frames(in: $0.visible, gap: Self.gap, limits: limits)[e.id] } }
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
