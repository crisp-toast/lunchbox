import AppKit
import os
import LunchboxCore

/// Watches the keyboard with a CGEventTap on its own high-priority thread, so a
/// busy main thread can never delay typing. Key presses are matched against the
/// user's keymap; anything that isn't a LunchboxWM shortcut passes straight through.
///
/// It also sees mouse presses and drags, for one thing: dragging the edge of a centered window
/// (alone, or in Focus) stretches both sides, the way macOS resizes with ⌥ held, since the
/// window stays centered anyway.
final class HotkeyTap {
    private struct State {
        var enabled = false
        var workspaceKeys: [Int64] = []
        var spaces = Command.defaultWorkspaces
        var keymap = Keymap()
        var learner: ((Int64, CGEventFlags) -> Void)?
        var centered: [(id: CGWindowID, frame: CGRect)] = []
        /// Resize mode lasts until this moment (each resize key extends it).
        var resizeUntil: CFTimeInterval = 0
    }

    /// How long resize mode waits for the next key before it ends by itself.
    static let resizeModeSeconds: CFTimeInterval = 5

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onAction: (KeyAction) -> Void
    private var port: CFMachPort?
    /// Key codes whose key-down we swallowed; their key-up is swallowed too.
    /// Only touched on the tap thread.
    private var swallowed = Set<Int64>()
    /// "⇧ then key" detection; tap thread only.
    private var chord = ShiftTapChord()
    /// A drag on a centered window's edge is under way; tap thread only.
    private var stretching = false
    /// A press just inside a centered window's edge: it's a resize only if the window starts
    /// changing size as the drag goes. The window, its size at the press, and where the press
    /// was; tap thread only.
    private var maybeStretching: (id: CGWindowID, size: CGSize, at: CGPoint)?

    init(onAction: @escaping (KeyAction) -> Void) {
        self.onAction = onAction
    }

    var enabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }

    /// The three keys earlier versions had you choose for Workspaces 1, 2 and 3: only a
    /// shortcut you changed back then still uses them.
    var spaceKeys: [Int64] {
        get { state.withLock { $0.workspaceKeys } }
        set { state.withLock { $0.workspaceKeys = newValue } }
    }

    /// How many Workspaces there are: ⌘ and a higher number stays the app's own.
    var spaceCount: Int {
        get { state.withLock { $0.spaces } }
        set { state.withLock { $0.spaces = newValue } }
    }

    var keymap: Keymap {
        get { state.withLock { $0.keymap } }
        set { state.withLock { $0.keymap = newValue } }
    }

    /// The centered windows and where they are (top-left coordinates, like the mouse events):
    /// a drag on one of their edges resizes from the center.
    var centeredWindows: [(id: CGWindowID, frame: CGRect)] {
        get { state.withLock { $0.centered } }
        set { state.withLock { $0.centered = newValue } }
    }

    /// While set, the next key press (with its modifiers) goes to `learner`
    /// instead of the app in front.
    func learnNextKey(_ learner: ((Int64, CGEventFlags) -> Void)?) {
        state.withLock { $0.learner = learner }
    }

    /// Starts the tap. Fails when Accessibility access hasn't been granted.
    func start() -> Bool {
        guard port == nil else { return true }
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let thread = Thread { [self] in
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                    return tap.handle(type, event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                ready.signal()
                return
            }
            self.port = port
            created = true
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "LunchboxWM hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return created
    }

    /// How far outside (or inside) a window's edge a press can start a resize.
    static let edgeReach: CGFloat = 7

    /// Where the window server has a window right now: cheap enough to ask on every drag event.
    private func windowBounds(_ id: CGWindowID) -> CGRect? {
        var raw = UnsafeRawPointer(bitPattern: UInt(id))
        guard let array = CFArrayCreate(nil, &raw, 1, nil),
              let info = (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowed.remove(code) != nil ? nil : pass
        case .flagsChanged:
            chord.flagsChanged(event.flags)
            return pass
        case .leftMouseDown:
            // macOS starts a resize from just outside a window's edge, or just inside it. ⌥ makes
            // it stretch both sides. Not when another modifier is held (⇧ keeps the shape, ⌘
            // moves without activating).
            stretching = false
            maybeStretching = nil
            let (on, centered) = state.withLock { ($0.enabled, $0.centered) }
            guard on, event.flags.isDisjoint(with: [.maskShift, .maskCommand, .maskControl, .maskAlternate]) else { return pass }
            let p = event.location
            if centered.contains(where: { $0.frame.insetBy(dx: -Self.edgeReach, dy: -Self.edgeReach).contains(p) && !$0.frame.contains(p) }) {
                // Outside the window: nothing there but its edge.
                stretching = true
                event.flags.insert(.maskAlternate)
            } else if let w = centered.first(where: { $0.frame.contains(p) && !$0.frame.insetBy(dx: Self.edgeReach, dy: Self.edgeReach).contains(p) }),
                      let size = windowBounds(w.id)?.size {
                // Inside: it may be the edge, or something in the window near it (a scroll bar, text).
                // Only a press that starts resizing the window gets ⌥, as soon as it does.
                maybeStretching = (w.id, size, p)
            }
            return pass
        case .leftMouseDragged:
            if let maybe = maybeStretching {
                if let now = windowBounds(maybe.id)?.size, abs(now.width - maybe.size.width) > 1 || abs(now.height - maybe.size.height) > 1 {
                    stretching = true
                    maybeStretching = nil
                } else if hypot(event.location.x - maybe.at.x, event.location.y - maybe.at.y) > 40 {
                    maybeStretching = nil // dragging something in the window, not its edge
                }
            }
            if stretching { event.flags.insert(.maskAlternate) }
            return pass
        case .leftMouseUp:
            if stretching { event.flags.insert(.maskAlternate) }
            stretching = false
            maybeStretching = nil
            return pass
        case .keyDown:
            break
        default:
            return pass
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let s = state.withLock { $0 }

        if let learner = s.learner {
            swallowed.insert(code)
            let flags = event.flags
            DispatchQueue.main.async { learner(code, flags) }
            return nil
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let afterShiftTap = chord.keyDown(code: code, flags: event.flags, isRepeat: isRepeat)
        guard s.enabled else { return pass }

        // Resize mode (⌘⇧R): the arrows push the window's edge on their side; + and − (either row,
        // or the number pad) grow or shrink it all round, the same as ⌘⇧+ and ⌘⇧−; held, they
        // keep going. Return, Esc or ⌘⇧R ends it; any other key ends it and does what it always
        // does, and so does an arrow with ⌘ (⌘ and an arrow moves focus, as ever).
        let now = CACurrentMediaTime()
        if now < s.resizeUntil {
            let along: [Int64: Direction] = [124: .right, 123: .left, 126: .up, 125: .down]
            var step: KeyAction?
            if let direction = along[code], !event.flags.contains(.maskCommand) { step = .resizeAlong(direction) }
            else if code == 24 || code == 69 { step = .grow } else if code == 27 || code == 78 { step = .shrink }
            if let step {
                state.withLock { $0.resizeUntil = now + Self.resizeModeSeconds }
                swallowed.insert(code)
                DispatchQueue.main.async { [onAction] in onAction(step) }
                return nil
            }
            state.withLock { $0.resizeUntil = 0 }
            DispatchQueue.main.async { [onAction] in onAction(.resizeMode(false)) }
            let ends = [36, 76, 53].contains(code) || s.keymap.command(for: code, flags: event.flags, workspaceKeys: s.workspaceKeys) == .resize
            if ends {
                swallowed.insert(code)
                return nil
            }
        }

        var command: Command?
        if afterShiftTap { command = s.keymap.shiftTapCommand(for: code, workspaceKeys: s.workspaceKeys) }
        if command == nil { command = s.keymap.command(for: code, flags: event.flags, workspaceKeys: s.workspaceKeys, spaces: s.spaces) }
        guard let command else { return pass }

        swallowed.insert(code)
        if command == .resize { state.withLock { $0.resizeUntil = now + Self.resizeModeSeconds } }
        let action = command.action
        DispatchQueue.main.async { [onAction] in onAction(action) }
        return nil
    }
}
