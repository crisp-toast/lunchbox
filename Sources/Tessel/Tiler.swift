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
    private var settlingUntil: [CGWindowID: CFTimeInterval] = [:]
    private var lastReassert: [CGWindowID: CFTimeInterval] = [:]
    private var draggedByUser = Set<CGWindowID>()
    private var mouseDown: CGPoint?
    private var notificationTokens: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []

    private let animator = Animator()
    private let ring = FocusRing()
    private let badge = SpaceBadge()
    var onChange: (() -> Void)?

    init() {
        Tiler.shared = self
        animator.onSettled = { [weak self] id, actual, _ in self?.settled(id, at: actual) }
        let defaults = UserDefaults.standard
        currentSpace = min(Self.spaceCount - 1, max(0, defaults.integer(forKey: "currentSpace")))
        for (key, value) in (defaults.dictionary(forKey: "placement") as? [String: String]) ?? [:] {
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            if let id = CGWindowID(key), parts.count == 2, let space = Int(parts[0]) {
                savedPlacement[id] = (space, parts[1])
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        displays = Display.current()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        func on(_ name: Notification.Name, _ center: NotificationCenter = NSWorkspace.shared.notificationCenter, _ body: @escaping (Notification) -> Void) {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: body))
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.track(app) }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.untrack(app.processIdentifier) }
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.appActivated(app) }
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] n in self?.rescan(n) }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] n in self?.rescan(n) }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.scanAll() }
        on(NSApplication.didChangeScreenParametersNotification, .default) { [weak self] _ in self?.displaysChanged() }
        // Showing or hiding the Dock changes the usable area of the screen.
        on(Notification.Name("com.apple.dock.prefchanged"), DistributedNotificationCenter.default()) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.displaysChanged() }
        }

        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                self?.mouseDown = NSScreen.topLeftPoint(fromCocoa: NSEvent.mouseLocation)
                self?.draggedByUser.removeAll()
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() },
        ].compactMap { $0 }

        for app in NSWorkspace.shared.runningApplications { track(app, scan: false) }
        mergeInactiveDisplays()
        initialScan()
        log.notice("started with \(self.displays.count) displays, space \(self.currentSpace + 1)")
    }

    /// Stops managing windows and brings every parked window back into view.
    func stop() {
        guard enabled else { return }
        revealHiddenWindows()
        enabled = false
        notificationTokens.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        notificationTokens = []
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
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
        for (s, layouts) in spaces.enumerated() where s != currentSpace {
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
        guard let app = apps.removeValue(forKey: pid) else { return }
        detach(app)
        let gone = windows.values.filter { $0.pid == pid }.map(\.id)
        gone.forEach(forget)
        if !gone.isEmpty { relayout(animated: true) }
    }

    private func rescan(_ n: Notification) {
        guard let running = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let app = apps[running.processIdentifier] else { return }
        scheduleScan(app)
    }

    func scanAll() {
        guard enabled else { return }
        for app in apps.values { scheduleScan(app) }
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
        app.element.elements(kAXWindowsAttribute).compactMap { element in
            guard let id = element.windowID, let frame = element.frame else { return nil }
            let tileable = element.role == kAXWindowRole
                && element.subrole == kAXStandardWindowSubrole
                && !element.isMinimized
                && !element.isFullScreen
                && element.isResizable
            return WindowInfo(id: id, element: element, frame: frame, tileable: tileable)
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
            var all: [(AppHandle, WindowInfo)] = []
            for (app, infos) in results { infos.forEach { all.append((app, $0)) } }
            all.sort { ($0.1.frame.minX, $0.1.frame.minY) < ($1.1.frame.minX, $1.1.frame.minY) }
            for (app, info) in all { self.consider(info, app: app, onScreen: onScreen) }
            self.relayout(animated: false)
            self.persist()
            self.refreshFocus()
        }
    }

    private func apply(_ infos: [WindowInfo], for app: AppHandle) {
        guard enabled, apps[app.pid] === app else { return }
        let onScreen = onScreenWindowIDs()
        let seen = Set(infos.map(\.id))
        var changed = false
        for w in windows.values where w.pid == app.pid && !seen.contains(w.id) {
            forget(w.id)
            changed = true
        }
        for info in infos where consider(info, app: app, onScreen: onScreen) { changed = true }
        if changed {
            relayout(animated: true)
            persist()
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
    private func consider(_ info: WindowInfo, app: AppHandle, onScreen: Set<CGWindowID>) -> Bool {
        let window = windows[info.id] ?? register(info, app: app)
        if !window.hidden { window.frame = info.frame }
        let appHidden = NSRunningApplication(processIdentifier: app.pid)?.isHidden ?? false
        let wantsTile = info.tileable
            && !appHidden
            && !userFloating.contains(info.id)
            && !Self.floatingApps.contains(app.bundleID ?? "")
            && (onScreen.contains(info.id) || window.hidden)
        let placed = place(of: info.id) != nil
        if wantsTile && !placed {
            insert(window)
            return true
        }
        if !wantsTile && placed {
            removeFromLayouts(info.id)
            window.target = nil
            return true
        }
        return false
    }

    private func register(_ info: WindowInfo, app: AppHandle) -> ManagedWindow {
        let window = ManagedWindow(handle: WindowHandle(id: info.id, element: info.element, app: app), frame: info.frame)
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

    private func insert(_ window: ManagedWindow) {
        let saved = savedPlacement.removeValue(forKey: window.id)
        let display = saved.flatMap { s in activeDisplays.first { $0.uuid == s.display } }
            ?? activeDisplays.first { $0.frame.contains(window.frame.center) }
            ?? activeDisplays.first { $0.isMain }
            ?? activeDisplays.first
        guard let display else { return }
        let space = saved?.space ?? currentSpace
        var layout = spaces[space][display.uuid] ?? Layout()
        let near = focusedID.flatMap { layout.contains($0) ? $0 : nil } ?? layout.windows.last
        layout.insert(window.id, near: near, maxColumns: Layout.maxColumns(forWidth: display.visible.width))
        spaces[space][display.uuid] = layout
        log.notice("tiling window \(window.id) (\(window.handle.app.bundleID ?? "?")) in space \(space + 1)")
    }

    private func forget(_ id: CGWindowID) {
        removeFromLayouts(id)
        if let w = windows.removeValue(forKey: id) {
            w.handle.app.windowIDs.removeValue(forKey: w.handle.element)
        }
        if focusedID == id { focusedID = nil }
        settlingUntil[id] = nil
        lastReassert[id] = nil
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
                forget(id)
                relayout(animated: true)
                persist()
                // macOS would hand focus to another window of the same app, which may be
                // parked in another space. Keep focus where the user was looking instead.
                if wasFocused, let frame {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                        self?.focusNearest(to: frame, excluding: id)
                    }
                }
            } else {
                scheduleScan(app)
            }
        case kAXFocusedWindowChangedNotification:
            app.queue.async { [weak self] in
                let id = element.windowID
                DispatchQueue.main.async { if let id { self?.focusChanged(to: id, app: app) } }
            }
        case kAXWindowMiniaturizedNotification:
            // Same as closing: keep focus near where the user was looking.
            if let id = app.windowIDs[element], id == focusedID, let w = windows[id], !w.hidden {
                let frame = w.target ?? w.frame
                quietFocus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.focusNearest(to: frame, excluding: id)
                }
            }
            scheduleScan(app)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = app.windowIDs[element] { windowChangedOnItsOwn(id) }
        default:
            scheduleScan(app)
        }
    }

    private func appActivated(_ running: NSRunningApplication) {
        guard let app = apps[running.processIdentifier] else { return }
        app.queue.async { [weak self] in
            let id = app.element.element(kAXFocusedWindowAttribute)?.windowID
            DispatchQueue.main.async { if let id { self?.focusChanged(to: id, app: app) } }
        }
    }

    private func refreshFocus() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        appActivated(front)
    }

    private func focusChanged(to id: CGWindowID, app: AppHandle) {
        guard enabled else { return }
        guard let (space, _) = place(of: id) else {
            focusedID = id
            if windows[id] == nil { scheduleScan(app) }
            return
        }
        if space != currentSpace {
            // Right after we switch spaces or a window closes, macOS often hands focus
            // to some other window of the app, which may be parked in another space.
            // That isn't a request to go there; only a later ⌘-Tab or click is.
            guard CACurrentMediaTime() > quietFocusUntil else { return }
            focusedID = id
            lastFocused[space] = id
            switchSpace(to: space, focusing: id)
            return
        }
        focusedID = id
        lastFocused[space] = id
        endSpotlight(unlessShowing: id)
    }

    /// Focus changes before this time don't switch spaces.
    private var quietFocusUntil: CFTimeInterval = 0

    private func quietFocus() { quietFocusUntil = CACurrentMediaTime() + 0.6 }

    /// A tiled window moved or resized without us asking.
    private func windowChangedOnItsOwn(_ id: CGWindowID) {
        let now = CACurrentMediaTime()
        guard now > settlingUntil[id] ?? 0, let w = windows[id], !w.hidden, w.target != nil else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            draggedByUser.insert(id)
            return
        }
        // The app moved itself (some do when opening). Put it back, but never
        // wrestle with an app that insists: once every two seconds at most.
        guard now - (lastReassert[id] ?? 0) > 2 else { return }
        lastReassert[id] = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let w = self.windows[id], !w.hidden else { return }
            let element = w.handle.element
            w.handle.app.queue.async {
                let actual = element.frame
                DispatchQueue.main.async {
                    // Late notifications from our own moves land here too; only act on a real difference.
                    guard let actual, let w = self.windows[id], let target = w.target, !w.hidden,
                          !actual.isClose(to: target, tolerance: 2) else { return }
                    w.frame = actual
                    w.target = nil
                    self.relayout(animated: true)
                }
            }
        }
    }

    private func mouseUp() {
        let down = mouseDown
        mouseDown = nil
        let dragged = draggedByUser
        draggedByUser.removeAll()
        guard enabled, let down, !dragged.isEmpty else { return }
        let up = NSScreen.topLeftPoint(fromCocoa: NSEvent.mouseLocation)
        for id in dragged {
            guard let w = windows[id], let target = w.target, target.insetBy(dx: -12, dy: -12).contains(down) else { continue }
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

    private func displaysChanged() {
        guard enabled else { return }
        displays = Display.current()
        mergeInactiveDisplays()
        relayout(animated: false)
        persist()
    }

    /// Moves windows from displays Tessel doesn't tile on (unplugged, or ignored
    /// because "Use All Displays" is off) onto the main display.
    private func mergeInactiveDisplays() {
        guard let main = displays.first(where: \.isMain) else { return }
        let active = Set(activeDisplays.map(\.uuid))
        for s in spaces.indices {
            for (uuid, layout) in spaces[s] where !active.contains(uuid) {
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
        UserDefaults.standard.set(on, forKey: "useAllDisplays")
        log.notice("use all displays: \(on)")
        guard enabled else { return }
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
        for (s, layouts) in spaces.enumerated() {
            for (uuid, layout) in layouts {
                if s == currentSpace, let d = activeDisplays.first(where: { $0.uuid == uuid }) {
                    for (id, frame) in layout.frames(in: d.visible, gap: Self.gap) {
                        guard let w = windows[id] else { continue }
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
                        guard let w = windows[id], !w.hidden else { continue }
                        let parked = CGRect(origin: spot, size: (w.target ?? w.frame).size)
                        w.target = parked
                        w.hidden = true
                        settlingUntil[id] = now + 0.4
                        moves.append((w.handle, parked, parked, .positionOnly))
                    }
                }
            }
        }
        animator.run(moves)
        onChange?()
    }

    private func visibleFrames() -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        for d in activeDisplays {
            guard let layout = spaces[currentSpace][d.uuid] else { continue }
            result.merge(layout.frames(in: d.visible, gap: Self.gap)) { a, _ in a }
        }
        return result
    }

    private func persist() {
        var placement: [String: String] = [:]
        for (s, layouts) in spaces.enumerated() {
            for (uuid, layout) in layouts {
                for id in layout.windows { placement[String(id)] = "\(s)|\(uuid)" }
            }
        }
        // Keep entries for windows not seen yet this session (e.g. right after a relaunch).
        for (id, p) in savedPlacement where placement[String(id)] == nil { placement[String(id)] = "\(p.space)|\(p.display)" }
        UserDefaults.standard.set(placement, forKey: "placement")
        UserDefaults.standard.set(currentSpace, forKey: "currentSpace")
    }

    // MARK: Keyboard actions

    func perform(_ action: KeyAction) {
        guard enabled else { return }
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
        case .focus(let direction): focus(direction)
        case .move(let direction): move(direction)
        case .grow: resize(by: Self.resizeStep)
        case .shrink: resize(by: -Self.resizeStep)
        case .switchSpace(let i): switchSpace(to: i, focusing: nil)
        case .sendToSpace(let i): send(toSpace: i)
        case .close: closeFocused()
        case .hide: send(toSpace: Self.spaceCount - 1, caption: "Hidden in space \(Self.spaceCount)")
        case .spotlight: toggleSpotlight()
        case .launcher: break // handled by the app delegate
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

    private func resize(by delta: Double) {
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace,
              var layout = spaces[space][uuid] else { return }
        if layout.resize(id, by: delta) {
            spaces[space][uuid] = layout
            relayout(animated: true)
        }
        showRing(on: id)
    }

    func switchSpace(to index: Int, focusing preferred: CGWindowID?) {
        guard enabled, (0..<Self.spaceCount).contains(index) else { return }
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

        let remembered = lastFocused[index].flatMap { place(of: $0)?.space == index ? $0 : nil }
        let mainUUID = displays.first(where: \.isMain)?.uuid ?? ""
        let fallback = spaces[index][mainUUID]?.windows.first ?? spaces[index].values.first?.windows.first
        if let target = preferred ?? remembered ?? fallback {
            if preferred == nil { activate(target) }
        } else {
            // Nothing here yet: hand focus to the desktop so typing can't land in a parked window.
            focusedID = nil
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                AXUIElementCreateApplication(finder.processIdentifier).set(kAXFrontmostAttribute, true)
            }
        }
        badge.show(space: index, count: Self.spaceCount, on: display)
    }

    private func send(toSpace index: Int, caption: String? = nil) {
        guard let id = focusedID, let (space, uuid) = place(of: id), space == currentSpace, index != space,
              (0..<Self.spaceCount).contains(index) else { return }
        let display = displays.first { $0.uuid == uuid }
        let oldFrame = windows[id]?.target
        quietFocus()
        removeFromLayouts(id)
        var destination = spaces[index][uuid] ?? Layout()
        destination.insert(id, near: destination.windows.last, maxColumns: Layout.maxColumns(forWidth: display?.visible.width ?? 1600))
        spaces[index][uuid] = destination
        relayout(animated: true)
        persist()

        if let oldFrame { focusNearest(to: oldFrame) } else { focusedID = nil }
        badge.show(space: index, count: Self.spaceCount, caption: caption ?? "Window moved to space \(index + 1)", on: display)
    }

    /// Focuses the visible window closest to `frame`, or the desktop when this space is empty.
    private func focusNearest(to frame: CGRect, excluding excluded: CGWindowID? = nil) {
        var visible = visibleFrames()
        if let excluded { visible[excluded] = nil }
        if let next = visible.min(by: {
            hypot($0.value.midX - frame.midX, $0.value.midY - frame.midY) < hypot($1.value.midX - frame.midX, $1.value.midY - frame.midY)
        })?.key {
            activate(next)
            showRing(on: next)
        } else {
            focusedID = nil
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                AXUIElementCreateApplication(finder.processIdentifier).set(kAXFrontmostAttribute, true)
            }
        }
    }

    /// Presses the focused window's close button, exactly like clicking it, so apps
    /// still ask about unsaved changes. Focus moves on once the window is gone.
    private func closeFocused() {
        guard let front = NSWorkspace.shared.frontmostApplication, let app = apps[front.processIdentifier] else { return }
        let known = focusedID.flatMap { id in windows[id].flatMap { $0.handle.app === app ? $0.handle.element : nil } }
        app.queue.async {
            guard let window = known ?? app.element.element(kAXFocusedWindowAttribute) else { return }
            Self.pressClose(window)
        }
    }

    /// Closes one specific window, whatever has focus. Used by the `close-<id>` script command.
    func close(windowID id: CGWindowID) {
        guard let w = windows[id] else { return }
        let element = w.handle.element
        w.handle.app.queue.async { Self.pressClose(element) }
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

    /// Focuses the app's most recently used window, switching spaces if needed.
    /// Returns false when Tessel doesn't know any window of that app.
    func goToWindow(ofApp pid: pid_t) -> Bool {
        let mine = windows.values.filter { $0.pid == pid }
        guard !mine.isEmpty else { return false }
        let recent = ([currentSpace] + (0..<Self.spaceCount).filter { $0 != currentSpace })
            .compactMap { lastFocused[$0] }
            .first { windows[$0]?.pid == pid }
        let choice = recent.flatMap { windows[$0] }
            ?? mine.first { place(of: $0.id)?.space == currentSpace }
            ?? mine.first { place(of: $0.id) != nil }
            ?? mine.first
        guard let w = choice else { return false }
        if let space = place(of: w.id)?.space, space != currentSpace { switchSpace(to: space, focusing: w.id) }
        activate(w.id)
        showRing(on: w.id)
        return true
    }

    /// Opens a new window of a running app with its own menu command (File ›
    /// New Window and the like, as if chosen by hand). Tessel tiles it in the
    /// current space and focuses it when it appears. Reports false when the app
    /// has no such command.
    func openNewWindow(ofApp pid: pid_t, completion: @escaping (Bool) -> Void) {
        guard let app = apps[pid] else { return completion(false) }
        let existing = Set(windows.values.filter { $0.pid == pid }.map(\.id))
        app.queue.async { [weak self] in
            let pressed = Self.newWindowMenuItem(in: app.element)
                .map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
            DispatchQueue.main.async {
                if pressed { self?.pendingNewWindow = (pid, existing, CACurrentMediaTime() + 4) }
                completion(pressed)
            }
        }
    }

    /// Runs on the app's queue. Looks through the File, Shell and Window menus
    /// for "New Window" (or "New Finder Window", or File › New › Window in
    /// Xcode), falling back to the plain ⌘N item.
    private static func newWindowMenuItem(in app: AXUIElement) -> AXUIElement? {
        guard let bar = app.element(kAXMenuBarAttribute) else { return nil }
        func title(_ e: AXUIElement) -> String { (e.string(kAXTitleAttribute) ?? "").lowercased() }
        let preferred = ["file", "shell", "window"]
        let menus = bar.elements(kAXChildrenAttribute)
            .filter { preferred.contains(title($0)) }
            .sorted { (preferred.firstIndex(of: title($0)) ?? 9) < (preferred.firstIndex(of: title($1)) ?? 9) }
        var commandN: AXUIElement?
        for top in menus {
            guard let menu = top.elements(kAXChildrenAttribute).first else { continue }
            for item in menu.elements(kAXChildrenAttribute) where item.bool(kAXEnabledAttribute) {
                let t = title(item)
                if t == "new window" { return item }
                if t.hasPrefix("new "), t.hasSuffix(" window"), !t.contains("private"), !t.contains("incognito") { return item }
                if t == "new", let sub = item.elements(kAXChildrenAttribute).first,
                   let window = sub.elements(kAXChildrenAttribute).first(where: { title($0) == "window" && $0.bool(kAXEnabledAttribute) }) {
                    return window
                }
                if commandN == nil, item.string(kAXMenuItemCmdCharAttribute)?.uppercased() == "N",
                   (item.value(kAXMenuItemCmdModifiersAttribute) as? Int) == 0 {
                    commandN = item
                }
            }
        }
        return commandN
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
        relayout(animated: true)
        // Keep the centered window in front of any shelved app that can't shrink that small.
        if layout.spotlight != nil { activate(id) }
        showRing(on: id)
    }

    private func endSpotlight(unlessShowing id: CGWindowID) {
        guard let (space, uuid) = place(of: id), var layout = spaces[space][uuid],
              let spot = layout.spotlight, spot != id else { return }
        layout.spotlight = nil
        spaces[space][uuid] = layout
        relayout(animated: true)
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
        guard let actual, let w = windows[id], !w.hidden else { return }
        w.frame = actual
        if ringWindow == id, ring.isShowing, let target = w.target, !actual.isClose(to: target, tolerance: 2) {
            ring.flash(actual, on: displays)
        }
    }

    // MARK: Menu commands

    var focusedIsTiled: Bool { focusedID.map { place(of: $0) != nil } ?? false }

    func toggleFloatingForFocused() {
        guard let id = focusedID, let w = windows[id] else { return }
        if place(of: id) != nil {
            userFloating.insert(id)
            removeFromLayouts(id)
            w.target = nil
            relayout(animated: true)
        } else {
            userFloating.remove(id)
            scheduleScan(w.handle.app)
        }
        persist()
    }

    func balance() {
        for uuid in spaces[currentSpace].keys { spaces[currentSpace][uuid]?.balance() }
        relayout(animated: true)
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
        return [
            "enabled": enabled, "currentSpace": currentSpace + 1, "focused": focusedID ?? 0,
            "useAllDisplays": useAllDisplays, "windowServerFocus": WindowFocus.isAvailable,
            "displays": displays.map { "\($0.name) \(NSStringFromRect($0.visible))" },
            "spaces": spaceList, "windows": windowList,
        ]
    }
}
