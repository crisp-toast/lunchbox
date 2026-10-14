import AppKit
import ServiceManagement
import TesselCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tiler = Tiler()
    private lazy var tap: HotkeyTap = HotkeyTap { [weak self] action in
        guard let self else { return }
        switch action {
        case .launcher: self.launcher.toggle()
        case .help: self.help.toggle()
        case .escape: self.escape()
        default: self.tiler.perform(action)
        }
    }
    private lazy var launcher: Launcher = Launcher(tiler: tiler)
    private lazy var help: HelpPanel = HelpPanel { [weak self] in self?.tap.spaceKeys ?? [] }
    private lazy var menu: StatusMenu = StatusMenu(tiler: tiler)
    private lazy var teacher: KeyTeacher = KeyTeacher(tap: tap) { [weak self] keys in self?.saveSpaceKeys(keys) }
    private var trustPoll: Timer?
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        tiler.onChange = { [weak self] in self?.menu.refresh() }
        tiler.onSpotlightChange = { [weak self] on in self?.tap.escapeLeavesSpotlight = on }
        menu.onToggle = { [weak self] in self?.toggleTiling() }
        menu.onTeachKeys = { [weak self] in self?.teacher.begin() }
        menu.onShowHelp = { [weak self] in self?.help.show() }
        menu.onGrantAccess = { Self.openAccessibilitySettings() }
        tap.spaceKeys = (UserDefaults.standard.array(forKey: "spaceKeys") as? [Int]).map { $0.map(Int64.init) } ?? []

        // Quit cleanly on `kill`, so parked windows come back.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source

        listenForCommands()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            begin()
        } else {
            log.notice("waiting for Accessibility access")
            menu.refresh()
            trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.begin()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tiler.revealHiddenWindows()
    }

    private func begin() {
        menu.trusted = true
        guard tap.start() else {
            // Access was just granted; the event tap can take a moment to be allowed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.begin() }
            return
        }
        tap.enabled = true
        tiler.start()
        menu.refresh()
        // Start at login by default, once; the menu can turn it off and that sticks.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            } catch {
                log.error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
        }
        if tap.spaceKeys.count != 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.teacher.begin() }
        }
    }

    /// Esc while spotlight is on: close the launcher or help if open, else leave spotlight.
    private func escape() {
        if launcher.isVisible { launcher.hide() }
        else if help.isVisible { help.hide() }
        else { tiler.exitSpotlight() }
    }

    private func toggleTiling() {
        setTiling(!tiler.enabled)
    }

    /// Pauses or resumes tiling and the shortcuts together. Pausing brings windows parked in other
    /// spaces back and lets every keystroke through. Asking for the current state does nothing.
    private func setTiling(_ on: Bool) {
        guard on != tiler.enabled, menu.trusted || !on else { return }
        if on {
            tiler.start()
            tap.enabled = true
        } else {
            tiler.stop()
            tap.enabled = false
        }
        log.notice("tiling \(on ? "resumed" : "paused", privacy: .public)")
        menu.refresh()
    }

    private func saveSpaceKeys(_ keys: [Int64]) {
        tap.spaceKeys = keys
        UserDefaults.standard.set(keys.map(Int.init), forKey: "spaceKeys")
        log.notice("space keys set to \(keys.map(String.init).joined(separator: ","), privacy: .public)")
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Lets scripts drive Tessel without the keyboard, e.g.
    /// `osascript -l JavaScript -e '…postNotificationName("com.tyleryouens.tessel.command", "focus-left")…'`.
    /// Commands: focus-/move-left|right|up|down, grow, shrink, space-1…3, send-1…3,
    /// balance, retile, pause, resume, dump (writes the state to ~/Library/Application Support/Tessel/state.json).
    private func listenForCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.tyleryouens.tessel.command"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            self.run(command)
        }
    }

    private func run(_ command: String) {
        if command.hasPrefix("find:") {
            launcher.show(query: String(command.dropFirst(5)))
            return
        }
        if command.hasPrefix("help:") {
            help.show(query: String(command.dropFirst(5)))
            return
        }
        let parts = command.split(separator: "-").map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("focus", let d?): if let dir = Direction(rawValue: d) { tiler.perform(.focus(dir)) }
        case ("move", let d?): if let dir = Direction(rawValue: d) { tiler.perform(.move(dir)) }
        case ("grow", _): tiler.perform(.grow)
        case ("shrink", _): tiler.perform(.shrink)
        case ("close", let id?): if let id = CGWindowID(id) { tiler.close(windowID: id) }
        case ("close", _): tiler.perform(.close)
        case ("hide", _): tiler.perform(.hide)
        case ("spotlight", _): tiler.perform(.spotlight)
        case ("launcher", "open"?): launcher.openSelection()
        case ("launcher", "new"?): launcher.openSelection(newWindow: true)
        case ("launcher", "down"?): launcher.moveSelection(by: 1)
        case ("launcher", "up"?): launcher.moveSelection(by: -1)
        case ("launcher", _): launcher.toggle()
        case ("help", _): help.toggle()
        case ("escape", _): escape()
        case ("space", let n?): if let i = Int(n) { tiler.perform(.switchSpace(i - 1)) }
        case ("send", let n?): if let i = Int(n) { tiler.perform(.sendToSpace(i - 1)) }
        case ("displays", "all"?): tiler.setUseAllDisplays(true)
        case ("displays", "main"?): tiler.setUseAllDisplays(false)
        case ("balance", _), ("normalize", _): tiler.normalize()
        case ("retile", _): tiler.retile()
        case ("pause", _): setTiling(false)
        case ("resume", _): setTiling(true)
        case ("dump", _): dumpState()
        default: log.error("unknown command \(command, privacy: .public)")
        }
    }

    private func dumpState() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tessel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = tiler.stateDescription()
        state["spaceKeys"] = tap.spaceKeys
        state["launcher"] = launcher.stateDescription
        state["help"] = help.stateDescription
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
