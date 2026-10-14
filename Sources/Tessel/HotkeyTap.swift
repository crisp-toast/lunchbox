import AppKit
import os
import TesselCore

/// Watches the keyboard with a CGEventTap on its own high-priority thread, so a
/// busy main thread can never delay typing. Key presses are matched against the
/// user's keymap; anything that isn't a Tessel shortcut passes straight through.
final class HotkeyTap {
    private struct State {
        var enabled = false
        var workspaceKeys: [Int64] = []
        var keymap = Keymap()
        var learner: ((Int64, CGEventFlags) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onAction: (KeyAction) -> Void
    private var port: CFMachPort?
    /// Key codes whose key-down we swallowed; their key-up is swallowed too.
    /// Only touched on the tap thread.
    private var swallowed = Set<Int64>()
    /// "⇧ then key" detection; tap thread only.
    private var chord = ShiftTapChord()

    init(onAction: @escaping (KeyAction) -> Void) {
        self.onAction = onAction
    }

    var enabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }

    /// The three keys chosen for Workspaces 1, 2 and 3.
    var spaceKeys: [Int64] {
        get { state.withLock { $0.workspaceKeys } }
        set { state.withLock { $0.workspaceKeys = newValue } }
    }

    var keymap: Keymap {
        get { state.withLock { $0.keymap } }
        set { state.withLock { $0.keymap = newValue } }
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
                | (1 << CGEventType.flagsChanged.rawValue)
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
        thread.name = "Tessel hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return created
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

        var command: Command?
        if afterShiftTap { command = s.keymap.shiftTapCommand(for: code, workspaceKeys: s.workspaceKeys) }
        if command == nil { command = s.keymap.command(for: code, flags: event.flags, workspaceKeys: s.workspaceKeys) }
        guard let command else { return pass }

        swallowed.insert(code)
        let action = command.action
        DispatchQueue.main.async { [onAction] in onAction(action) }
        return nil
    }
}
