import AppKit
import os
import TesselCore

/// Watches the keyboard with a CGEventTap on its own high-priority thread, so a
/// busy main thread can never delay typing. Only the left Command key triggers
/// the arrow and size shortcuts; right Command passes through untouched, so
/// right-⌘ + arrows still move the text cursor.
final class HotkeyTap {
    private struct State {
        var enabled = false
        var spaceKeys: [Int64] = []
        var learner: ((Int64) -> Void)?
        /// Esc leaves spotlight; only while it's on, so Esc reaches apps otherwise.
        var escapeLeavesSpotlight = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onAction: (KeyAction) -> Void
    private var port: CFMachPort?
    /// Key codes whose key-down we swallowed; their key-up is swallowed too.
    /// Only touched on the tap thread.
    private var swallowed = Set<Int64>()
    /// ⇧Space detection; tap thread only.
    private var chord = ShiftSpaceChord()

    init(onAction: @escaping (KeyAction) -> Void) {
        self.onAction = onAction
    }

    var enabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }

    var spaceKeys: [Int64] {
        get { state.withLock { $0.spaceKeys } }
        set { state.withLock { $0.spaceKeys = newValue } }
    }

    var escapeLeavesSpotlight: Bool {
        get { state.withLock { $0.escapeLeavesSpotlight } }
        set { state.withLock { $0.escapeLeavesSpotlight = newValue } }
    }

    /// While set, the next key press goes to `learner` instead of the app in front.
    func learnNextKey(_ learner: ((Int64) -> Void)?) {
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
            DispatchQueue.main.async { learner(code) }
            return nil
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if code == 53, s.enabled, s.escapeLeavesSpotlight, event.flags.intersection(modifiers).isEmpty {
            _ = chord.keyDown(code: code, flags: event.flags, isRepeat: isRepeat)
            swallowed.insert(code)
            DispatchQueue.main.async { [onAction] in onAction(.escape) }
            return nil
        }
        if chord.keyDown(code: code, flags: event.flags, isRepeat: isRepeat), s.enabled {
            swallowed.insert(code)
            DispatchQueue.main.async { [onAction] in onAction(.launcher) }
            return nil
        }
        guard s.enabled, let action = Shortcuts.action(for: code, flags: event.flags, spaceKeys: s.spaceKeys) else {
            return pass
        }
        swallowed.insert(code)
        DispatchQueue.main.async { [onAction] in onAction(action) }
        return nil
    }
}
